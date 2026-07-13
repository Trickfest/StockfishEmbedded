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

    return CommandValidation::accepted;
}

class EngineState final: public std::enable_shared_from_this<EngineState> {
   public:
    explicit EngineState(SFLineHandler handler) :
        handler_([handler copy]),
        callbackQueue_(dispatch_queue_create("com.stockfishembedded.SFEngine.callback",
                                             DISPATCH_QUEUE_SERIAL)) {
        dispatch_queue_set_specific(callbackQueue_, &kCallbackQueueSpecificKey, this, nullptr);
    }

    ~EngineState() {
        stop();
    }

    void start() {
        bool alreadyActive = false;

        {
            std::lock_guard<std::mutex> lock(lifecycleMutex_);
            if (lifecycle_ != Lifecycle::idle)
                return;

            if (!activeEngineRegistry().claim(this)) {
                alreadyActive = true;
            } else {
                ownsActiveLease_.store(true);
                lifecycle_ = Lifecycle::running;

                auto state = shared_from_this();
                engineThread_ = std::make_unique<std::thread>([state] {
                    @autoreleasepool {
                        state->runEngineLoop();
                    }
                });
            }
        }

        if (alreadyActive)
            deliverWrapperError("another SFEngine instance is already active");
    }

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
                commandQueue_.push(std::move(normalized));
                return;
            }
            if (validation == CommandValidation::ignored)
                return;
        }

        deliverWrapperError(rejectionReason);
    }

    void stop() {
        std::unique_ptr<std::thread> threadToJoin;

        {
            std::unique_lock<std::mutex> lock(lifecycleMutex_);
            if (lifecycle_ == Lifecycle::idle) {
                lifecycle_ = Lifecycle::stopped;
                lock.unlock();
                finishCallbackDelivery();
                return;
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
            if (loopMayStillBeRunning) {
                commandQueue_.push("stop");
                commandQueue_.push("quit");
            }
            commandQueue_.close();
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
            lifecycle_ = Lifecycle::stopped;
        }
        lifecycleChanged_.notify_all();

        finishCallbackDelivery();
    }

   private:
    void runEngineLoop() {
        LineBufferStreambuf::LineCallback callback;
        if (handler_) {
            auto state = shared_from_this();
            callback = [state](const std::string& line) {
                state->deliverLine(line);
            };
        }

        CommandStreambuf    inputBuffer(commandQueue_);
        LineBufferStreambuf outputBuffer(std::move(callback));
        std::istream        input(&inputBuffer);
        std::ostream        output(&outputBuffer);

        RunStockfishUCI(input, output);
        commandQueue_.close();
        releaseActiveLease();

        {
            std::lock_guard<std::mutex> lock(lifecycleMutex_);
            if (lifecycle_ == Lifecycle::running)
                lifecycle_ = Lifecycle::finished;
        }
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
    ThreadSafeQueue<std::string>        commandQueue_;
    std::unique_ptr<std::thread>        engineThread_;
    std::mutex                          lifecycleMutex_;
    std::condition_variable             lifecycleChanged_;
    Lifecycle                          lifecycle_ = Lifecycle::idle;
    std::atomic<bool>                   ownsActiveLease_{false};
    std::atomic<bool>                   callbacksEnabled_{true};
};

}  // namespace

@implementation SFEngine {
    std::shared_ptr<EngineState> _state;
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

- (void)dealloc {
    [self stop];
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
