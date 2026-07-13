# StockfishEmbedded

Embeds the Stockfish chess engine as an in-process static library for iOS (device + simulator) and macOS, exposed through a tiny Objective-C wrapper (`SFEngine`) that is safe to call from Swift.

Clone normally; Stockfish sources are vendored in-tree:
```
git clone <repo-url>
```

## Reference App

For a realistic iOS app that uses this engine wrapper, see
[SwiftChessDemo](https://github.com/Trickfest/SwiftChessDemo). The demo combines
`StockfishEmbedded` with
[SwiftChessTools](https://github.com/Trickfest/SwiftChessTools) to show a
playable SwiftUI chess app with app-owned game state, legal move validation,
serialized Stockfish searches, UCI parsing, evaluation display, move
suggestions, move history, and engine status feedback.

`StockfishEmbedded` provides the embedded engine bridge only; reusable chess
rules, notation, SwiftUI board UI, and UCI helper types live in
`SwiftChessTools`. Distributed apps that link this project must comply with
Stockfish's GPL-3.0 licensing requirements.

The current library targets require iOS/iPadOS 26 or macOS 26. The smoke and
test targets use Swift 6; the public engine API itself is Objective-C.

## Layout
- `StockfishEmbedded.xcodeproj` – Xcode project with static library targets (`SFEngine-iOS`, `SFEngine-macOS`), smoke tests (`SFEngineCLITestObjC`, `SFEngineCLITestSwift`, `SFEngineTestSwiftUI`), and soak components (`SFEngineSoak` runner + `SFEngineCLISoakTestSwift`).
- `Sources/SFEngine` – adapter layer (ObjC++ wrapper and stream/queue helpers).
- `Sources/CLIObjC` – minimal macOS Objective-C CLI smoke test.
- `Sources/CLISwift` – minimal macOS Swift CLI smoke test.
- `Sources/SFEngineSoak` – shared soak test runner used by the CLI (and included in the SwiftUI target for future use).
- `Sources/CLISoakSwift` – macOS Swift CLI soak test.
- `Tests/SFEngineTests` – XCTest harness with contract, perft, tactical, and score-band assertions.
- `IOSSwiftUI` – iOS/iPadOS SwiftUI smoke test app (iOS 26+).
- `ThirdParty/Stockfish` – vendored Stockfish source (snapshot tracked via git subtree).
- `Resources/NNUE` – NNUE networks referenced by the build (net files not tracked in repo - see below).
- `Resources/Soak` – default FEN position files for soak tests.

## NNUE weights (required immediately after clone)
To keep the repository source-only and avoid committing large engine assets,
the NNUE net is **not in Git**. Before building or running the engine, download
the network expected by the vendored Stockfish snapshot:

```
Scripts/download-nnue.sh
```

The script reads Stockfish's current `EvalFileDefaultName` from
`ThirdParty/Stockfish/src/evaluate.h`, downloads the matching network from the
Stockfish test server, verifies that its SHA-256 digest matches the hash prefix
encoded in the filename, and stores it in `Resources/NNUE`. Re-running the
script is safe; it verifies and reuses a valid existing file. Pass `--force` to
download and verify a fresh copy.

If you prefer to run the commands manually, use the filename reported in
`ThirdParty/Stockfish/src/evaluate.h`:
```
mkdir -p Resources/NNUE
curl -L --fail https://tests.stockfishchess.org/api/nn/nn-af1339a6dea3.nnue -o Resources/NNUE/nn-af1339a6dea3.nnue
```

If you prefer, you can run `ThirdParty/Stockfish/scripts/net.sh` (from within `ThirdParty/Stockfish/src`), then copy the downloaded `.nnue` file into `Resources/NNUE`.

## Building
### Xcode
1. Open `StockfishEmbedded.xcodeproj`.
2. Build `SFEngine-iOS` for device or simulator, or `SFEngine-macOS` for macOS to produce `libSFEngine-*.a`.
3. Build/run `SFEngineCLITestObjC` or `SFEngineCLITestSwift` (macOS) to run the minimal UCI smoke tests.
4. Build/run `SFEngineTestSwiftUI` (iOS/iPadOS) for the SwiftUI smoke test app.

Note: Running `SFEngineTestSwiftUI` on a device requires selecting a Development
Team in Xcode (Signing & Capabilities). For command-line build-only checks,
disable code signing as shown below.

### Command line
```
# macOS static lib (Debug)
xcodebuild -project StockfishEmbedded.xcodeproj -scheme SFEngine-macOS -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath build

# iOS static lib (Release)
xcodebuild -project StockfishEmbedded.xcodeproj -scheme SFEngine-iOS -configuration Release -destination 'generic/platform=iOS' -derivedDataPath build

# macOS CLI smoke test (ObjC)
xcodebuild -project StockfishEmbedded.xcodeproj -scheme SFEngineCLITestObjC -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath build
./build/Build/Products/Debug/SFEngineCLITestObjC

# macOS CLI smoke test (Swift)
xcodebuild -project StockfishEmbedded.xcodeproj -scheme SFEngineCLITestSwift -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath build
./build/Build/Products/Debug/SFEngineCLITestSwift

# macOS CLI soak test (Swift, short run)
xcodebuild -project StockfishEmbedded.xcodeproj -scheme SFEngineCLISoakTestSwift -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath build
./build/Build/Products/Debug/SFEngineCLISoakTestSwift --iterations 5 --movetime 500

# macOS XCTest harness
xcodebuild -project StockfishEmbedded.xcodeproj -scheme SFEngineTests -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath build test

# iOS/iPadOS SwiftUI smoke test (unsigned build only)
xcodebuild -project StockfishEmbedded.xcodeproj -scheme SFEngineTestSwiftUI -configuration Debug -destination 'generic/platform=iOS' -derivedDataPath build CODE_SIGNING_ALLOWED=NO build
```

Tip: If you see stale-file warnings after switching build output locations, delete `build/` or clean DerivedData.

Run the complete local gate (macOS library, both CLI smokes, short soak,
XCTest, and iOS Simulator app build) with:

```
Scripts/validate.sh
```

GitHub-hosted validation is intentionally deferred. This repository has no
active root GitHub Actions workflow; run the gate above on a local Apple-silicon
Mac instead. A future manually dispatched workflow may download and verify the
required NNUE network before testing, but neither a hosted run nor hosted
success is currently a completion or release requirement. Workflows retained
inside `ThirdParty/Stockfish` belong to the vendored upstream snapshot and are
not active for this wrapper repository.

## CLI soak tests
The CLI soak test (`SFEngineCLISoakTestSwift`) runs repeated searches against a FEN corpus. By default it loads
`Resources/Soak/positions.txt` and loops forever until you stop it.

Build and run (macOS 26+):
```
xcodebuild -project StockfishEmbedded.xcodeproj -scheme SFEngineCLISoakTestSwift -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath build
./build/Build/Products/Debug/SFEngineCLISoakTestSwift --iterations 100 --depth 10
```

Key options:
- `--iterations N` – cap the run (otherwise it repeats forever).
- `--depth N`, `--nodes N`, or `--movetime MS` – choose one search limit.
- `--timeout S` – per-move timeout (default 30s).
- `--delay-ms MS` – pause between iterations.
- `--log-output` – print all engine output lines.
- `--ready-each` – send `isready` before each iteration.
- `--chess960` plus `--chess960-positions PATH` – include Chess960 positions.

When a move timeout occurs, the runner sends `stop` and waits for that search's
terminal `bestmove` before advancing. If the engine does not produce one within
`--stop-timeout`, the run ends instead of risking attribution of a late move to
the next position.

Position files contain one four/six-field FEN per line; `startpos` and a FEN
suffix of `moves <uci-move> ...` are also accepted. Obvious syntax errors are
rejected before native engine startup. Relative paths are resolved against the
current working directory and the repo root.

## Design approach
This repo embeds Stockfish as an in-process static library with a minimal shim and keeps upstream
Stockfish sources unmodified. The goal is a small, maintainable adaptation layer that is easy to update when
Stockfish changes.

Highlights:
- Upstream Stockfish sources are untouched; the wrapper lives in `Sources/SFEngine`.
- Stockfish is vendored via git subtree; updates are explicit and squashed to keep history small.
- NNUE networks are embedded into the static library at build time (once downloaded) for out-of-the-box `go` searches.
- Release engine libraries use `-O3` and `NDEBUG`, matching Stockfish's normal
  optimized, non-debug build policy; Debug libraries retain assertions.
- Stream redirection is scoped to the shim instead of global source edits.
- The API surface is small and Swift-friendly (thread-safe command queue + ordered serial line callback).
- Xcode targets include macOS CLI smoke tests and an iOS/iPadOS SwiftUI smoke app.

## Adapter details
- `SFEngine` spins the engine on a dedicated worker thread, swapping process-wide
  `std::cin/std::cout` to custom stream buffers that talk to a thread-safe queue.
- Output callbacks are delivered in order on a wrapper-owned serial background
  queue, away from Stockfish search workers. Swift imports the handler as
  `@Sendable`; calling `stop` from a callback is safe.
- `stop` enqueues `stop` + `quit`, closes the queue (to guarantee EOF), joins the
  engine thread, and drains already-enqueued callbacks when called off the
  callback queue. When a handler itself calls `stop`, later queued callbacks are
  suppressed so no additional handler invocation begins after `stop` returns.
- Stockfish sources are unmodified; the tiny `EmbeddedUCI` shim calls the upstream UCI loop after redirecting streams and performing the normal initialization from `main.cpp`.

## Threading and search control
`SFEngine` is an in-process wrapper, not a separate engine process. Starting an
engine instance creates one wrapper-owned C++ thread that runs Stockfish's UCI
loop. Swift, SwiftUI, and app main-thread code should send commands through
`sendCommand(_:)`; best-move search does not run on the app's main thread.

Stockfish also has its own internal search thread pool. The UCI `Threads` option
defaults to `1` in the vendored engine, so a normal search uses one Stockfish
search worker unless your app explicitly sends a command such as
`setoption name Threads value 4`. A single busy search worker can still consume
roughly one CPU core while it is thinking.

Search duration should normally be controlled with Stockfish UCI limits:
`go movetime <milliseconds>` for a wall-clock move budget, `go depth <plies>`
for a fixed-depth search, or `go nodes <count>` for a node budget. These limits
are different from an app-side timeout in a test runner or UI. If your app-side
timeout fires, the usual recovery is to send `stop` and use the best `bestmove`
Stockfish returns, but `stop` is cooperative. It asks Stockfish to stop; it does
not forcibly interrupt or kill a native thread.

### Process-wide engine and command boundaries

Because the upstream UCI loop uses process-wide C++ standard streams and
process-global engine initialization, only one `SFEngine` may be active in a
process at a time. A concurrent second `start` is rejected without starting a
thread and its handler receives:

```
info string StockfishEmbedded error: another SFEngine instance is already active
```

After the active engine stops, a rejected instance that has not itself been
stopped may call `start` again.
While an engine is active, unrelated host C++ code that writes to `std::cout`
can be captured by the bridge, so avoid such output during an engine session.

`sendCommand(_:)` is a trusted native-control boundary, not a parser for
untrusted user text. Generate UCI commands from validated app state. The wrapper
accepts exactly one command per call (with one optional trailing LF or CRLF),
rejects NUL/multiline/oversized commands, and intentionally rejects Stockfish's
`Debug Log File` option because its process-static logger is incompatible with
the wrapper's per-session stream buffers.

## Known limitations
- Engines are intended for single start/stop per instance. `stop` is terminal,
  including when called before `start`; create a new `SFEngine` to restart.
- Only one engine can be active per process because the embedded UCI loop uses
  process-wide C++ streams.

## Stockfish versioning
Stockfish sources are vendored in `ThirdParty/Stockfish` via `git subtree` as a snapshot (history is not kept). Updates are manual; clones always include the exact snapshot committed here.

Key points:
- Updates are explicit and reviewable; there is no submodule.
- Updating Stockfish is a single, squashed subtree pull from upstream.
- The upstream commit hash is recorded in the subtree metadata lines in the update commit message.
- Current vendored upstream commit: `6088838797d6333711c17fe2c0962fa0858517ec`.
- If Stockfish changes the default NNUE filenames, revisit the NNUE section above and download the matching nets.
  You can confirm the required filename in `ThirdParty/Stockfish/src/evaluate.h` (`EvalFileDefaultName`).
- Warning: Updating Stockfish (to `master` or a release tag) can break the parent repo's shim or build setup due to upstream API or initialization changes. If a build fails after an update, you may need to adjust the wrapper code in `Sources/SFEngine` to match the new Stockfish expectations.
- Typical update workflow: fetch upstream, pull the subtree with `--squash`, check if the NNUE filenames changed, download any new nets, then build the CLI/SwiftUI smoke tests. If you see build errors in `Sources/SFEngine`, update the shim to match Stockfish's current initialization path.
- Even if the project successfully compiles, compare the current Stockfish `main.cpp` initialization sequence with the shim in `Sources/SFEngine/EmbeddedUCI.cpp` to catch new (or deleted) init steps that could affect runtime behavior.

To see the most recent subtree update commit (and upstream SHA):
```
git log -1 --pretty=%B -- ThirdParty/Stockfish
```

To pin to an official release tag (example: `sf_18`):
```
git subtree pull --prefix ThirdParty/Stockfish https://github.com/official-stockfish/Stockfish.git sf_18 --squash
```

To update to the latest commit on `master`:
```
git subtree pull --prefix ThirdParty/Stockfish https://github.com/official-stockfish/Stockfish.git master --squash
```

## License

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
