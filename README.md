# StockfishEmbedded

[![Swift versions](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2FTrickfest%2FStockfishEmbedded%2Fbadge%3Ftype%3Dswift-versions)](https://swiftpackageindex.com/Trickfest/StockfishEmbedded) [![Supported platforms](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2FTrickfest%2FStockfishEmbedded%2Fbadge%3Ftype%3Dplatforms)](https://swiftpackageindex.com/Trickfest/StockfishEmbedded)

StockfishEmbedded runs the Stockfish chess engine in-process from an iOS,
iPadOS, or macOS app. Its small Objective-C API imports into Swift as
`SFEngine`.

This package is the engine bridge, not a chess rules library, board UI, or UCI
parser. Use [SwiftChessTools](https://github.com/Trickfest/SwiftChessTools) for
those pieces. [SwiftChessDemo](https://github.com/Trickfest/SwiftChessDemo)
shows both embedded engines working in one app.

## Before you start

- **License:** This package and Stockfish are GPL-3.0. Review
  [Licensing](#licensing) before distributing an app that links the engine.
- **Requirements:** Swift 6.2 or newer and Xcode 26 or newer, targeting
  iOS/iPadOS 26 or macOS 26 and later. Apple arm64 is supported; Intel Macs and
  x86_64 simulators are not.
- **Network:** The package builds without a network file, but searches require
  a matching NNUE file supplied by your app. There is no automatic download
  during package resolution, building, or engine startup.

The badges link to the Swift Package Index's compatibility results. They are
separate from this repository's local validation instructions.

## Installation

In Xcode, choose **File > Add Package Dependencies**, enter
`https://github.com/Trickfest/StockfishEmbedded.git`, and add the `SFEngine`
product to your app target.

For a manifest-based client, add these entries to its existing manifest:

```swift
dependencies: [
    .package(
        url: "https://github.com/Trickfest/StockfishEmbedded.git",
        from: "1.14.0"
    ),
],
targets: [
    .target(
        name: "MyApp",
        dependencies: [
            .product(name: "SFEngine", package: "StockfishEmbedded"),
        ]
    ),
]
```

This example selects the source generation described below. When choosing
another version, use that version's network filename and setup instructions.

## Quick start with Swift Package Manager

### Prepare the network

NNUE stands for *Efficiently Updatable Neural Network*. It is the data
Stockfish uses to evaluate chess positions, not another executable. This
snapshot requires `nn-c9e480e92425.nnue`, 113,178,980 bytes: roughly 113 MB
(108 MiB).

From a repository clone, run:

```sh
Scripts/download-nnue.sh
```

The helper verifies and reuses a matching local file in `Resources/NNUE`.
For an app that only resolves the package through Xcode, download the file
directly:

```sh
curl --proto '=https' --tlsv1.2 --location --fail --show-error \
  https://tests.stockfishchess.org/api/nn/nn-c9e480e92425.nnue \
  --output nn-c9e480e92425.nnue
shasum -a 256 nn-c9e480e92425.nnue
```

Compare the result with the expected SHA-256:

```text
c9e480e92425f887df6ab9b05c6180fbd762b07879df9d9845f1aa75440caa73
```

Drag the verified file into your app project, enable the app target's
membership, and confirm **Build Phases > Copy Bundle Resources** includes it.
Keep its filename unchanged. See [network setup](Resources/NNUE/README.md)
for app-managed storage and upgrade details.

### Run one search

This example buffers output, waits for readiness, then stops after one
`bestmove`. The detached task keeps blocking shutdown off the UI actor.

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

Keep `searchTask` so you can cancel it when leaving the screen. In an async
command-line client, await `searchTask.value` to keep the process alive.
This one-search example has no startup deadline; a production session also
needs timeouts and error handling. See [Examples](Docs/Examples.md) and
SwiftChessDemo's engine providers for a fuller lifecycle.

## Runtime assets

The app owns the network's local file URL and must keep that file accessible
and unchanged until the engine stops. It may bundle the verified file or store
it in an app-owned Application Support or cache directory. If using a cache,
ensure the file remains available throughout the engine session. The path must
be representable as one safe UCI option line. Package startup checks
compatibility using Stockfish's own loader before
entering the UCI loop; a missing or incompatible file reports an
`info string StockfishEmbedded error` line without terminating the host app.

When upgrading, check `SFEngine.defaultNetworkFileName` again. Network layouts
can change: this snapshot uses SFNNv18. The preceding `nn-252f33942263.nnue`
and older PSQT-layout `nn-134a887f4c8f.nnue` are incompatible; replace the app's
network when upgrading. The older Xcode static-library targets instead embed
the ignored local network at build time; see
[legacy integration](PROJECT_INTEGRATION.md).

## Lifecycle and threading

- `start()` launches the UCI loop. The caller sends `uci` and `isready` and
  waits for their replies before searching; returning from `start()` is not
  a readiness signal.
- Output arrives in order on a serial background queue. Dispatch UI updates
  to the main actor, and keep handlers brief.
- `sendCommand(_:)` accepts one trusted UCI line. Generate it from validated
  app state; do not pass arbitrary user text through to native code.
- `sendCommand("stop")` requests the current search's terminal `bestmove`.
  `engine.stop()` instead shuts down the wrapper and is terminal for that
  instance, even before its first start. Create a new instance afterward.
- `suspend()` may be used after `bestmove` to release the C++ stream redirect
  while retaining the loaded engine/network. Resume the same instance and
  repeat the handshake. A suspended instance retains its SFEngine ownership
  lease; do not create a second SFEngine instead.
- Shutdown blocks through native teardown. Call it off the UI actor. Calling
  it from the output handler is supported.

Both embedded engines use process-wide C++ streams. Their native ownership
guards are not a cross-package scheduler: your app must serialize Stockfish
and Arasan sessions. See [Architecture](Docs/Architecture.md) for the stream
boundary, command restrictions, search limits, and repository layout.

## Reference app

[SwiftChessDemo](https://github.com/Trickfest/SwiftChessDemo) combines
StockfishEmbedded, [ArasanEmbedded](https://github.com/Trickfest/ArasanEmbedded),
and SwiftChessTools for human-versus-engine and engine-versus-engine play,
evaluation display, suggestions, and move history.

The app owns game state and legal move validation, serializes native engine
searches, parses UCI output, and displays engine status feedback.

The built app already includes its verified Stockfish network; end users do
not download a model separately. Use the demo as the shared end-to-end example
rather than creating a second integration app.

## Testing and troubleshooting

From a clone on an Apple-silicon Mac, run `Scripts/validate.sh` for the full
local gate. It downloads/verifies the network when needed. A plain
`swift build` or `swift test` does not download anything and can run without it,
with explicit skips for tests that require local network fixtures.

[Testing](Docs/Testing.md) distinguishes SwiftPM tests, legacy Xcode tests,
CLI smokes/soaks, build-only checks, and manual app checks.
[Troubleshooting](Docs/Troubleshooting.md) covers network failures, readiness,
engine switching, and unsupported targets. GitHub-hosted validation is
deferred; local validation remains the required evidence.

## Maintenance and provenance

- [Architecture](Docs/Architecture.md): wrapper design and source layout.
- [Examples](Docs/Examples.md): search and shutdown patterns.
- [Provenance](Docs/Provenance.md): source and network identity.
- [Updating Stockfish](Docs/UpdatingStockfish.md): maintainer update procedure.
- [Changelog](CHANGELOG.md): package change history.

Current vendored upstream commit: `effdc3fd3f6de6e75fe1374a51a7a7eed66f880b`.
Upstream sources remain unmodified; wrapper code lives outside
`ThirdParty/Stockfish`. The DocC catalog at
`Sources/SFEngine/SFEngine.docc` documents the public SwiftPM API.

## Licensing

**StockfishEmbedded** is licensed under the **GNU General Public License, version 3 (GPL-3.0)**. See `LICENSE`.
Stockfish itself is GPL-3.0; see `ThirdParty/Stockfish/Copying.txt`.

This package embeds Stockfish and produces static libraries, so the strong copyleft requirements apply when you distribute builds that include it. This is a high-level summary, not legal advice.

### Important Notice for App Developers

If you **include StockfishEmbedded in a distributed product** (including apps distributed via the Apple App Store), the GPL-3.0 requires that:

- **Your entire application must be licensed under GPL-3.0**
- **Complete corresponding source code** for the entire application must be made available to recipients
- Recipients must be allowed to **modify and redistribute** the application under GPL-3.0 terms

Because this project produces **static libraries**, using it in an iOS, iPadOS, macOS, watchOS, or tvOS app will generally cause the entire app to be considered a derivative work under the GPL.

If you do **not distribute** your builds (for example, purely internal/private use), the GPL's source-distribution obligations are typically not triggered.

### Suitability

This package **is not suitable** for:
- Closed-source or proprietary applications
- Commercial apps that cannot release full source code under GPL-3.0

This package **is suitable** for:
- Open-source GPL-compatible applications
- Research, educational, and experimental projects
- Command-line tools
- Personal or internal use where GPL obligations can be met

### No Additional Restrictions

No additional restrictions are imposed beyond those of GPL-3.0.  
There is **no alternative or commercial license** offered for this package.

If you are unsure whether GPL-3.0 is compatible with your project, you should consult a qualified licensing expert before use.
