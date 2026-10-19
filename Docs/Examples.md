# Examples

Start with the complete, readiness-gated [README example](../README.md#quick-start-with-swift-package-manager).
The snippets below assume a retained, running engine whose handshake has
completed, and no other active search. They are session fragments, not complete
app implementations.

## Search from FEN

```swift
engine.sendCommand("position fen 6k1/8/8/8/8/8/8/6KQ w - - 0 1")
engine.sendCommand("go depth 4")
```

Validate user positions in the app's rules layer before generating UCI. For a
new independent game, send `ucinewgame`, probe `isready`, and await `readyok`
before setting its position/search.

## Search limits and cancellation

Choose one limit for each search:

```swift
engine.sendCommand("position startpos moves e2e4")
engine.sendCommand("go movetime 250")
```

`go depth 8` and `go nodes 10000` are alternatives. To end an active search,
send `engine.sendCommand("stop")` and wait for `bestmove`. This does not shut
down the wrapper. `engine.stop()` is terminal and blocks until teardown.

`movetime` is a wall-clock search budget in milliseconds, `depth` is measured
in plies, and `nodes` caps the search-node count. These are engine search
limits, not app-side response deadlines.

## Switch between engines

After Stockfish returns `bestmove`, call `suspend()` off the UI actor and wait
for it to return before starting Arasan. After Arasan has stopped, resume the
same Stockfish instance, send `uci`, wait for `uciok`, then send `isready` and
wait for `readyok`. Only then submit another search. Suspension preserves the
loaded network; terminal stop does not.

Use SwiftChessDemo's lifecycle coordinator for a complete example. Do not start
another SFEngine while a suspended instance retains the ownership lease.

## UI ownership

Keep one session owner, its task/engine, and the verified network URL alive for
the session. Dispatch output-derived UI changes to the main actor. Bound startup
and searches with client timeouts, reject replies belonging to old requests,
and schedule blocking shutdown off the UI actor when leaving a screen.

The README's detached task demonstrates one search, not a full UI session
manager. Its returned task can be cancelled; an async command-line client must
await its value before exiting. The package never downloads the network for
your app. See [network setup](../Resources/NNUE/README.md).

## CLI soak

Use the existing Xcode CLI for repeated searches, rather than adding another
demo app. See [Testing](Testing.md#cli-soak) for build commands and options.
