//
// StockfishEmbedded embeds Stockfish as an in-process engine for Apple platforms.
//
// See README.md and ThirdParty/Stockfish/Copying.txt for upstream attribution and license details.
//
// Licensed under the GNU General Public License v3.0.
// You may obtain a copy of the License at: https://www.gnu.org/licenses/gpl-3.0.html
// See the LICENSE file for more information.
//

// Objective-C wrapper exposing Stockfish as an in-process engine.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^NS_SWIFT_SENDABLE SFLineHandler)(NSString *line);

/// Thin Objective-C wrapper around the embedded Stockfish UCI loop.
/// - Owns a dedicated engine thread.
/// - Forwards each UCI output line through `SFLineHandler`.
/// - `start` is idempotent; `stop` is safe to call multiple times.
/// - Intended for a single start/stop per instance.
/// - Only one `SFEngine` may be active in a process at a time because the
///   embedded UCI shim temporarily redirects process-wide C++ standard streams.
@interface SFEngine : NSObject

/// Creates an engine that discards UCI output. Prefer `initWithLineHandler:`
/// when the caller needs engine responses.
- (instancetype)init;

/// Creates an engine with a line handler called for each output line.
/// The handler is invoked in order on a wrapper-owned serial background queue;
/// dispatch to the main queue if you need to update UI. It is safe to call
/// `stop` from the handler.
- (instancetype)initWithLineHandler:(SFLineHandler)handler NS_DESIGNATED_INITIALIZER;

/// Starts the engine loop on a background thread.
- (void)start;

/// Sends a single trusted UCI command line (one trailing newline is optional).
/// Safe to call from any thread while the engine is running.
/// Empty commands are ignored. Multiline, NUL-containing, oversized, and
/// unsupported debug-log commands are rejected and reported to the line
/// handler as an `info string` error.
- (void)sendCommand:(NSString *)command;

/// Sends "stop" then "quit" and tears down the engine thread.
/// This is a terminal transition even when called before `start`.
- (void)stop;

@end

NS_ASSUME_NONNULL_END
