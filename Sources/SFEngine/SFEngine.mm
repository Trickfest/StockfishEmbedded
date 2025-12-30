// SFEngine.mm
// Objective-C++ wrapper around the embedded Stockfish engine.
#import "SFEngine.h"

#include <atomic>
#include <chrono>
#include <future>
#include <mutex>
#include <string>
#include <thread>

#import <Foundation/Foundation.h>

#include "CommandStream.hpp"
#include "EmbeddedUCI.hpp"
#include "LineBufferStream.hpp"
#include "ThreadSafeQueue.hpp"

using namespace SFEmbedded;

@interface SFEngine ()
// Captured on init and invoked for each line of UCI output.
@property(nonatomic, copy) SFLineHandler lineHandler;
@end

@implementation SFEngine {
    // Queue of UCI commands consumed by the engine's stdin stream.
    ThreadSafeQueue<std::string> _commandQueue;
    // Dedicated engine thread running the UCI loop.
    std::unique_ptr<std::thread> _engineThread;
    // Serializes sendCommand/stop to preserve ordering and avoid races.
    std::mutex                    _sendMutex;
    // Atomic running flag used to gate start/stop.
    std::atomic<bool>             _running;
    // Signals when the engine loop exits, used to avoid blocking forever.
    std::promise<void>            _donePromise;
    std::future<void>             _doneFuture;
}

- (instancetype)initWithLineHandler:(SFLineHandler)handler {
    self = [super init];
    if (self) {
        _lineHandler = [handler copy];
        _running.store(false);
    }
    return self;
}

- (void)dealloc {
    // Ensure a clean shutdown if the wrapper is released while running.
    [self stop];
}

- (void)start {
    // Idempotent start: only spawn the engine thread once.
    bool wasRunning = _running.exchange(true);
    if (wasRunning)
        return;

    // Reset the completion signal for this run.
    _donePromise = std::promise<void>();
    _doneFuture  = _donePromise.get_future();

    __weak typeof(self) weakSelf = self;
    _engineThread.reset(new std::thread([weakSelf] {
        @autoreleasepool {
            if (!weakSelf)
                return;
            [weakSelf runEngineLoop];
        }
    }));
}

- (void)sendCommand:(NSString *)command {
    if (!_running.load() || command.length == 0)
        return;

    // Serialize command pushes so stop/quit can't interleave mid-command.
    std::lock_guard<std::mutex> lock(_sendMutex);
    _commandQueue.push(std::string([command UTF8String]));
}

- (void)stop {
    // Idempotent stop: only shut down once.
    bool wasRunning = _running.exchange(false);
    if (!wasRunning)
        return;

    {
        // Push the normal UCI stop/quit sequence, then close input.
        std::lock_guard<std::mutex> lock(_sendMutex);
        _commandQueue.push("stop");
        _commandQueue.push("quit");
        _commandQueue.close();
    }

    if (_engineThread && _engineThread->joinable()) {
        // Wait briefly for the UCI loop to exit; detach if it hangs.
        if (_doneFuture.valid()
            && _doneFuture.wait_for(std::chrono::seconds(2))
                 == std::future_status::timeout) {
            _engineThread->detach();  // Avoid blocking forever
        } else {
            _engineThread->join();
        }
    }
    _engineThread.reset();
}

#pragma mark - Internal

- (void)runEngineLoop {
    // Bridge the line callback to Objective-C and keep UTF-8 decoding local.
    auto handler = self.lineHandler;
    LineBufferStreambuf::LineCallback callback;
    if (handler) {
        callback = [handler](const std::string& line) {
            NSString* nsLine =
              [[NSString alloc] initWithBytes:line.data()
                                       length:line.size()
                                     encoding:NSUTF8StringEncoding];
            if (!nsLine)
                return;

            handler(nsLine);
        };
    }

    // Replace stdin/stdout with stream buffers backed by our queue/callback.
    CommandStreambuf    inputBuf(_commandQueue);
    LineBufferStreambuf outputBuf(std::move(callback));

    std::istream in(&inputBuf);
    std::ostream out(&outputBuf);

    // Run the embedded Stockfish UCI loop until it exits.
    RunStockfishUCI(in, out);

    // Ensure input is closed and signal completion for the stopper.
    _commandQueue.close();
    _donePromise.set_value();
}

@end
