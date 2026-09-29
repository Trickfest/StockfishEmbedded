//
// StockfishEmbedded embeds Stockfish as an in-process engine for Apple platforms.
//
// See README.md and ThirdParty/Stockfish/Copying.txt for upstream attribution and license details.
//
// Licensed under the GNU General Public License v3.0.
// You may obtain a copy of the License at: https://www.gnu.org/licenses/gpl-3.0.html
// See the LICENSE file for more information.
//

// Objective-C++ wrapper around the embedded Stockfish engine.

#import "SFEngine.h"

#include <atomic>
#include <cctype>
#include <condition_variable>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <thread>

#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>

#include "CommandStream.hpp"
#include "EmbeddedUCI.hpp"
#include "LineBufferStream.hpp"
#include "ThreadSafeQueue.hpp"

using namespace SFEmbedded;

namespace {

constexpr std::size_t kMaximumCommandBytes = 1024 * 1024;
char                  kCallbackQueueSpecificKey;

class ActiveEngineRegistry {
   public:
    bool claim(const void* owner) {
        std::lock_guard<std::mutex> lock(mutex_);
        if (owner_ != nullptr)
            return false;

        owner_ = owner;
        return true;
    }

    void release(const void* owner) {
        std::lock_guard<std::mutex> lock(mutex_);
        if (owner_ == owner)
            owner_ = nullptr;
    }

   private:
    std::mutex  mutex_;
    const void* owner_ = nullptr;
};

ActiveEngineRegistry& activeEngineRegistry() {
    static ActiveEngineRegistry registry;
    return registry;
}

enum class Lifecycle {
    idle,
    running,
    suspending,
    suspended,
    stopping,
    finished,
    stopped,
};

enum class CommandValidation {
    accepted,
    ignored,
    rejected,
};

bool startsWithDebugLogOption(const std::string& command) {
    std::string normalized;
    normalized.reserve(command.size());

    bool pendingSpace = false;
    for (const unsigned char character : command) {
        if (std::isspace(character)) {
            pendingSpace = !normalized.empty();
            continue;
        }

        if (pendingSpace) {
            normalized.push_back(' ');
            pendingSpace = false;
        }
        normalized.push_back(static_cast<char>(std::tolower(character)));
    }

    constexpr char prefix[] = "setoption name debug log file";
    if (normalized == prefix)
        return true;

    return normalized.size() > sizeof(prefix) - 1
        && normalized.compare(0, sizeof(prefix) - 1, prefix) == 0
        && normalized[sizeof(prefix) - 1] == ' ';
}

#if defined(NNUE_EMBEDDING_OFF)
bool startsWithEvalFileOption(const std::string& command) {
    std::string normalized;
    normalized.reserve(command.size());

    bool pendingSpace = false;
    for (const unsigned char character : command) {
        if (std::isspace(character)) {
            pendingSpace = !normalized.empty();
            continue;
        }

        if (pendingSpace) {
            normalized.push_back(' ');
            pendingSpace = false;
        }
        normalized.push_back(static_cast<char>(std::tolower(character)));
    }

    constexpr char prefix[] = "setoption name evalfile";
    if (normalized == prefix)
        return true;

    return normalized.size() > sizeof(prefix) - 1
        && normalized.compare(0, sizeof(prefix) - 1, prefix) == 0
        && normalized[sizeof(prefix) - 1] == ' ';
}
#endif

bool isSupportedNetworkPath(const std::string& path) {
    bool previousWasSpace = false;
    for (const unsigned char character : path) {
        if (character == '\n' || character == '\r' || character == '\t')
            return false;
        if (character == ' ') {
            if (previousWasSpace)
                return false;
            previousWasSpace = true;
        } else {
            previousWasSpace = false;
        }
    }
    return !path.empty();
}

CommandValidation validateCommand(NSString* command,
                                  std::string& normalized,
                                  std::string& rejectionReason) {
    if (command.length == 0)
        return CommandValidation::ignored;

    const NSUInteger byteCount = [command lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
    if (byteCount == 0 || byteCount > kMaximumCommandBytes) {
        rejectionReason = byteCount > kMaximumCommandBytes ? "command exceeds 1 MiB" : "command is not UTF-8";
        return CommandValidation::rejected;
    }

    NSData* data = [command dataUsingEncoding:NSUTF8StringEncoding allowLossyConversion:NO];
    if (!data) {
        rejectionReason = "command is not UTF-8";
        return CommandValidation::rejected;
    }

    normalized.assign(static_cast<const char*>(data.bytes), data.length);

    // The public contract accepts one optional trailing LF or CRLF.
    if (!normalized.empty() && normalized.back() == '\n') {
        normalized.pop_back();
        if (!normalized.empty() && normalized.back() == '\r')
            normalized.pop_back();
    }

    if (normalized.empty())
        return CommandValidation::ignored;

    if (normalized.find('\0') != std::string::npos) {
        rejectionReason = "command contains NUL";
        return CommandValidation::rejected;
    }
    if (normalized.find('\n') != std::string::npos || normalized.find('\r') != std::string::npos) {
        rejectionReason = "command contains more than one line";
        return CommandValidation::rejected;
    }
    if (startsWithDebugLogOption(normalized)) {
        rejectionReason = "Debug Log File is unsupported by the embedded stream bridge";
        return CommandValidation::rejected;
    }
#if defined(NNUE_EMBEDDING_OFF)
    if (startsWithEvalFileOption(normalized)) {
        rejectionReason = "EvalFile must be configured with initWithNetworkFileURL:lineHandler:";
        return CommandValidation::rejected;
    }
#endif

    return CommandValidation::accepted;
}

class EngineState final: public std::enable_shared_from_this<EngineState> {
   public:
    explicit EngineState(SFLineHandler             handler,
                         std::optional<std::string> networkFilePath = std::nullopt,
                         std::optional<std::string> configurationError = std::nullopt) :
        handler_([handler copy]),
        callbackQueue_(dispatch_queue_create("com.stockfishembedded.SFEngine.callback",
                                             DISPATCH_QUEUE_SERIAL)),
        networkFilePath_(std::move(networkFilePath)),
        configurationError_(std::move(configurationError)) {
        dispatch_queue_set_specific(callbackQueue_, &kCallbackQueueSpecificKey, this, nullptr);
        uciSession_ = std::make_unique<EmbeddedUCISession>(networkFilePath_);
    }

    ~EngineState() {
        stop();
    }

    void start() {
        activate(Lifecycle::idle);
    }

    void resume() {
        activate(Lifecycle::suspended);
    }

    void suspend() {
        std::unique_ptr<std::thread> threadToJoin;

        {
            std::unique_lock<std::mutex> lock(lifecycleMutex_);
            if (lifecycle_ == Lifecycle::suspended || lifecycle_ == Lifecycle::idle
                || lifecycle_ == Lifecycle::finished || lifecycle_ == Lifecycle::stopped)
                return;
            if (lifecycle_ == Lifecycle::suspending) {
                lifecycleChanged_.wait(lock, [this] { return lifecycle_ != Lifecycle::suspending; });
                return;
            }
            if (lifecycle_ != Lifecycle::running)
                return;

            lifecycle_ = Lifecycle::suspending;
            if (commandQueue_) {
                // Suspend is intended for the post-bestmove idle boundary. The
                // stop is harmless there and makes an accidental in-search
                // suspension cooperative before quit releases the UCI loop.
                commandQueue_->push("stop");
                commandQueue_->push("quit");
                commandQueue_->close();
            }
            threadToJoin = std::move(engineThread_);
        }

        if (threadToJoin && threadToJoin->joinable()) {
            if (threadToJoin->get_id() == std::this_thread::get_id())
                threadToJoin->detach();
            else
                threadToJoin->join();
        }

        {
            std::lock_guard<std::mutex> lock(lifecycleMutex_);
            commandQueue_.reset();
            if (lifecycle_ == Lifecycle::suspending)
                lifecycle_ = Lifecycle::suspended;
        }
        lifecycleChanged_.notify_all();
    }

    void stop() {
        std::unique_ptr<std::thread> threadToJoin;

        {
            std::unique_lock<std::mutex> lock(lifecycleMutex_);
            if (lifecycle_ == Lifecycle::suspending) {
                lifecycleChanged_.wait(lock, [this] { return lifecycle_ != Lifecycle::suspending; });
            }
            if (lifecycle_ == Lifecycle::stopped) {
                lock.unlock();
                finishCallbackDelivery();
                return;
            }
            if (lifecycle_ == Lifecycle::stopping) {
                lifecycleChanged_.wait(lock, [this] { return lifecycle_ == Lifecycle::stopped; });
                lock.unlock();
                finishCallbackDelivery();
                return;
            }

            const bool loopMayStillBeRunning = lifecycle_ == Lifecycle::running;
            lifecycle_ = Lifecycle::stopping;
            if (loopMayStillBeRunning && commandQueue_) {
                commandQueue_->push("stop");
                commandQueue_->push("quit");
            }
            if (commandQueue_)
                commandQueue_->close();
            threadToJoin = std::move(engineThread_);
        }

        if (threadToJoin && threadToJoin->joinable()) {
            if (threadToJoin->get_id() == std::this_thread::get_id())
                threadToJoin->detach();
            else
                threadToJoin->join();
        }

        releaseActiveLease();

        {
            std::lock_guard<std::mutex> lock(lifecycleMutex_);
            commandQueue_.reset();
            uciSession_.reset();
            lifecycle_ = Lifecycle::stopped;
        }
        lifecycleChanged_.notify_all();

        finishCallbackDelivery();
    }

   private:
    void activate(Lifecycle expectedLifecycle) {
        bool alreadyActive = false;
        std::optional<std::string> startupError;

        {
            std::lock_guard<std::mutex> lock(lifecycleMutex_);
            if (lifecycle_ != expectedLifecycle)
                return;

            if (expectedLifecycle == Lifecycle::idle && configurationError_.has_value()) {
                startupError = configurationError_;
                lifecycle_   = Lifecycle::finished;
            }
#if defined(NNUE_EMBEDDING_OFF)
            else if (expectedLifecycle == Lifecycle::idle && !networkFilePath_.has_value()) {
                startupError = "this build requires initWithNetworkFileURL:lineHandler:";
                lifecycle_   = Lifecycle::finished;
            }
#endif
            else if (expectedLifecycle == Lifecycle::idle && !activeEngineRegistry().claim(this)) {
                alreadyActive = true;
            } else {
                if (expectedLifecycle == Lifecycle::idle)
                    ownsActiveLease_.store(true);
                lifecycle_ = Lifecycle::running;
                commandQueue_ = std::make_shared<ThreadSafeQueue<std::string>>();

                auto state = shared_from_this();
                auto commandQueue = commandQueue_;
                engineThread_ = std::make_unique<std::thread>([state, commandQueue] {
                    @autoreleasepool {
                        state->runEngineLoop(commandQueue);
                    }
                });
            }
        }

        if (startupError.has_value()) {
            deliverWrapperError(*startupError);
            return;
        }
        if (alreadyActive)
            deliverWrapperError("another SFEngine instance is already active");
    }

   public:
    void sendCommand(NSString* command) {
        std::string normalized;
        std::string rejectionReason;

        {
            std::lock_guard<std::mutex> lock(lifecycleMutex_);
            if (lifecycle_ != Lifecycle::running)
                return;

            const CommandValidation validation =
              validateCommand(command, normalized, rejectionReason);
            if (validation == CommandValidation::accepted) {
                if (commandQueue_)
                    commandQueue_->push(std::move(normalized));
                return;
            }
            if (validation == CommandValidation::ignored)
                return;
        }

        deliverWrapperError(rejectionReason);
    }

   private:
    void runEngineLoop(const std::shared_ptr<ThreadSafeQueue<std::string>>& commandQueue) {
        LineBufferStreambuf::LineCallback callback;
        if (handler_) {
            auto state = shared_from_this();
            callback = [state](const std::string& line) {
                state->deliverLine(line);
            };
        }

        CommandStreambuf    inputBuffer(*commandQueue);
        LineBufferStreambuf outputBuffer(std::move(callback));
        std::istream        input(&inputBuffer);
        std::ostream        output(&outputBuffer);

        uciSession_->run(input, output);
        commandQueue->close();

        bool shouldReleaseActiveLease = false;

        {
            std::lock_guard<std::mutex> lock(lifecycleMutex_);
            if (lifecycle_ == Lifecycle::running) {
                lifecycle_ = Lifecycle::finished;
                shouldReleaseActiveLease = true;
            } else if (lifecycle_ == Lifecycle::stopping) {
                shouldReleaseActiveLease = true;
            }
        }
        if (shouldReleaseActiveLease)
            releaseActiveLease();
        lifecycleChanged_.notify_all();
    }

    void deliverWrapperError(const std::string& reason) {
        deliverLine("info string StockfishEmbedded error: " + reason);
    }

    void deliverLine(const std::string& line) {
        SFLineHandler handler;
        {
            std::lock_guard<std::mutex> lock(handlerMutex_);
            handler = [handler_ copy];
        }
        if (!handler)
            return;

        NSString* nsLine = [[NSString alloc] initWithBytes:line.data()
                                                   length:line.size()
                                                 encoding:NSUTF8StringEncoding];
        if (!nsLine)
            return;

        std::weak_ptr<EngineState> state = shared_from_this();
        dispatch_async(callbackQueue_, ^{
            @autoreleasepool {
                auto strongState = state.lock();
                if (!strongState || !strongState->callbacksEnabled_.load())
                    return;
                handler(nsLine);
            }
        });
    }

    void finishCallbackDelivery() {
        drainCallbacks();
        callbacksEnabled_.store(false);
        std::lock_guard<std::mutex> lock(handlerMutex_);
        handler_ = nil;
    }

    void drainCallbacks() {
        if (dispatch_get_specific(&kCallbackQueueSpecificKey) == this)
            return;

        dispatch_sync(callbackQueue_, ^{});
    }

    void releaseActiveLease() {
        if (ownsActiveLease_.exchange(false))
            activeEngineRegistry().release(this);
    }

    SFLineHandler                       handler_;
    std::mutex                          handlerMutex_;
    dispatch_queue_t                    callbackQueue_;
    std::shared_ptr<ThreadSafeQueue<std::string>> commandQueue_;
    std::unique_ptr<std::thread>        engineThread_;
    std::mutex                          lifecycleMutex_;
    std::condition_variable             lifecycleChanged_;
    Lifecycle                          lifecycle_ = Lifecycle::idle;
    std::atomic<bool>                   ownsActiveLease_{false};
    std::atomic<bool>                   callbacksEnabled_{true};
    const std::optional<std::string>    networkFilePath_;
    const std::optional<std::string>    configurationError_;
    std::unique_ptr<EmbeddedUCISession> uciSession_;
};

}  // namespace

@implementation SFEngine {
    std::shared_ptr<EngineState> _state;
}

+ (NSString*)defaultNetworkFileName {
    const std::string_view filename = DefaultNetworkFileName();
    return [[NSString alloc] initWithBytes:filename.data()
                                   length:filename.size()
                                 encoding:NSUTF8StringEncoding];
}

- (instancetype)init {
    return [self initWithLineHandler:^(NSString* line) {
        (void) line;
    }];
}

- (instancetype)initWithLineHandler:(SFLineHandler)handler {
    self = [super init];
    if (self)
        _state = std::make_shared<EngineState>(handler);
    return self;
}

- (instancetype)initWithNetworkFileURL:(NSURL*)networkFileURL
                           lineHandler:(SFLineHandler)handler {
    self = [super init];
    if (!self)
        return nil;

    std::optional<std::string> networkFilePath;
    std::optional<std::string> configurationError;

    if (!networkFileURL.isFileURL) {
        configurationError = "the NNUE network URL must be a local file URL";
    } else {
        const char* fileSystemRepresentation = networkFileURL.fileSystemRepresentation;
        if (!fileSystemRepresentation) {
            configurationError = "the NNUE network URL has no filesystem representation";
        } else {
            std::string path(fileSystemRepresentation);
            if (!isSupportedNetworkPath(path))
                configurationError = "the NNUE network path contains unsupported whitespace";
            else
                networkFilePath = std::move(path);
        }
    }

    _state = std::make_shared<EngineState>(handler,
                                           std::move(networkFilePath),
                                           std::move(configurationError));
    return self;
}

- (void)dealloc {
    [self stop];
}

- (void)suspend {
    if (_state)
        _state->suspend();
}

- (void)resume {
    if (_state)
        _state->resume();
}

- (void)start {
    if (_state)
        _state->start();
}

- (void)sendCommand:(NSString*)command {
    if (_state)
        _state->sendCommand(command);
}

- (void)stop {
    if (_state)
        _state->stop();
}

@end
