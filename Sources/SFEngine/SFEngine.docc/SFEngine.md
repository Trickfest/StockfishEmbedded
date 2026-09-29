# ``SFEngine``

Run Stockfish in-process from an iOS, iPadOS, or macOS app.

## Overview

StockfishEmbedded exposes the Stockfish UCI engine through a small Objective-C
API that imports into Swift as `SFEngine`. The package provides the engine
bridge, not a chess board, rules layer, or UCI parser. Its Stockfish code is
licensed under GPL-3.0; review the [license](https://github.com/Trickfest/StockfishEmbedded/blob/main/LICENSE)
before distributing an app that links it.

The Swift package builds without an NNUE file, but Stockfish cannot search
without one. NNUE is the evaluation-network data Stockfish uses to score chess
positions. Download the network named by `SFEngine.defaultNetworkFileName`
from Stockfish's official server, verify it, and either bundle it with your
app or keep it in app-owned storage. The [README quick start](https://github.com/Trickfest/StockfishEmbedded#quick-start-with-swift-package-manager)
provides the current download URL, checksum, and Xcode setup steps.

Then pass the local file URL to `SFEngine`:

```swift
import Foundation
import SFEngine

guard let networkURL = Bundle.main.url(
    forResource: SFEngine.defaultNetworkFileName,
    withExtension: nil
) else {
    fatalError("Missing Stockfish NNUE network in the app bundle")
}

let engine = SFEngine(networkFileURL: networkURL) { line in
    print(line)
}

engine.start()
engine.sendCommand("uci")
engine.sendCommand("isready")
// After receiving both `uciok` and `readyok` in the line handler:
engine.sendCommand("position startpos")
engine.sendCommand("go depth 8")
```

Keep the network file unchanged and the engine strongly referenced until
`engine.stop()`. A missing or incompatible network reports an
`info string StockfishEmbedded error` line instead of entering the UCI loop.

> Important: Only one `SFEngine` may be active in a process. UCI output arrives
> on a background serial queue; dispatch UI updates to the main actor. `stop()`
> waits for the engine thread to finish, so avoid calling it from the main actor
> during a long search.

When switching between in-process engines, wait for `bestmove`, call
`suspend()` to release Stockfish's process-wide stream ownership, and later
call `resume()` on the same instance. Unlike `stop()`, suspension preserves
the loaded NNUE network. Repeat the UCI handshake after resuming.

## Topics

### Engine API

- ``SFEngine``
