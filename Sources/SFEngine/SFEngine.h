// SFEngine.h
// Objective-C wrapper exposing Stockfish as an in-process engine.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^SFLineHandler)(NSString *line);

/// Thin Objective-C wrapper around the embedded Stockfish UCI loop.
/// - Owns a dedicated engine thread.
/// - Forwards each UCI output line through `SFLineHandler`.
/// - `start` is idempotent; `stop` is safe to call multiple times.
/// - Intended for a single start/stop per instance.
@interface SFEngine : NSObject

/// Creates an engine with a line handler called for each output line.
/// The handler is invoked on the engine thread; dispatch to the main queue
/// if you need to update UI.
- (instancetype)initWithLineHandler:(SFLineHandler)handler;

/// Starts the engine loop on a background thread.
- (void)start;

/// Sends a single UCI command line (newline optional).
/// Safe to call from any thread while the engine is running.
- (void)sendCommand:(NSString *)command;

/// Sends "stop" then "quit" and tears down the engine thread.
- (void)stop;

@end

NS_ASSUME_NONNULL_END
