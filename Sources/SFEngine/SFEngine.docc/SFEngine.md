# ``SFEngine``

Run Stockfish in-process from an iOS, iPadOS, or macOS app.

## Overview

StockfishEmbedded provides an engine bridge, not chess rules, game state, UI,
or a typed UCI parser. Its Objective-C API imports into Swift as `SFEngine`.
Stockfish and this wrapper are GPL-3.0; review the repository's
[licensing notice](https://github.com/Trickfest/StockfishEmbedded#licensing)
before distributing a linked app.

## Getting started

Add the `SFEngine` package product, then supply its required local NNUE file.
NNUE is evaluation-network data, not another executable. SwiftPM does not
download or bundle it. The
[README quick start](https://github.com/Trickfest/StockfishEmbedded#quick-start-with-swift-package-manager)
provides the matching download, checksum, and app-resource setup.

The following one-search task waits for UCI readiness and shuts down off the UI
actor:

```swift
import Foundation
import SFEngine

guard let networkURL = Bundle.main.url(
    forResource: SFEngine.defaultNetworkFileName,
    withExtension: nil
) else {
    fatalError("Missing \(SFEngine.defaultNetworkFileName) in the app bundle")
}

let searchTask = Task.detached {
    let (lines, output) = AsyncStream<String>.makeStream()
    let engine = SFEngine(networkFileURL: networkURL) { line in
        output.yield(line)
    }
    defer {
        engine.stop()
        output.finish()
    }

    engine.start()
    engine.sendCommand("uci")

    for await line in lines {
        print(line)
        if line.hasPrefix("info string StockfishEmbedded error")
            || line.hasPrefix("bestmove ") {
            break
        }
        if line == "uciok" {
            engine.sendCommand("isready")
        } else if line == "readyok" {
            engine.sendCommand("position startpos")
            engine.sendCommand("go depth 8")
        }
    }
}
```

Keep the task handle to cancel it with the owning screen. An async command-line
client must await `searchTask.value` before exiting. This example has no startup
deadline; production clients should use timeouts and request attribution as
shown by SwiftChessDemo.

## Runtime assets

`SFEngine.defaultNetworkFileName` identifies the required network. Keep its
verified local file accessible and unchanged until the engine stops. On upgrades,
replace it when the expected filename or format changes. This snapshot uses
SFNNv18 and cannot reuse networks from earlier architectures. A missing or
incompatible file reports an `info string StockfishEmbedded error` line; the
UCI loop is not entered. Legacy Xcode targets have a different,
embedded-network build path.

## Lifecycle and threading

`start()` does not perform a handshake: callers send `uci` and `isready` and
wait for replies. Output is ordered on a serial background queue. Dispatch UI
work to the main actor and keep blocking teardown away from it.

UCI `stop` requests a search's terminal bestmove; wrapper `stop()` is terminal
for that instance. After completed searches, `suspend()`/`resume()` can preserve
loaded NNUE while releasing the stream redirect. A suspended instance retains
its SFEngine ownership lease; resume that instance and repeat the handshake.

Generate single-line UCI from validated app state. Only one SFEngine may own
its native slot, and the app must serialize Stockfish with Arasan because both
use process-wide streams. They do not share a cross-package native scheduler.

## Reference app and validation

[SwiftChessDemo](https://github.com/Trickfest/SwiftChessDemo) uses both embedded
engines with SwiftChessTools. See the repository's
[Examples](https://github.com/Trickfest/StockfishEmbedded/blob/main/Docs/Examples.md),
[Testing](https://github.com/Trickfest/StockfishEmbedded/blob/main/Docs/Testing.md),
and [Troubleshooting](https://github.com/Trickfest/StockfishEmbedded/blob/main/Docs/Troubleshooting.md)
guides. The existing soak runner is Xcode test/CLI infrastructure, not an
exported SwiftPM API.

## Topics

### Engine API

- ``SFEngine``
