# StockfishEmbedded

Embeds the Stockfish chess engine as an in-process static library for iOS (device + simulator) and macOS, exposed through a tiny Objective-C wrapper (`SFEngine`) that is safe to call from Swift.

Clone normally; Stockfish sources are vendored in-tree:
```
git clone <repo-url>
```

## Layout
- `StockfishEmbedded.xcodeproj` – Xcode project with static library targets (`SFEngine-iOS`, `SFEngine-macOS`), smoke tests (`SFEngineCLITestObjC`, `SFEngineCLITestSwift`, `SFEngineTestSwiftUI`), and soak components (`SFEngineSoak` runner + `SFEngineCLISoakTestSwift`).
- `Sources/SFEngine` – adapter layer (ObjC++ wrapper and stream/queue helpers).
- `Sources/CLIObjC` – minimal macOS Objective-C CLI smoke test.
- `Sources/CLISwift` – minimal macOS Swift CLI smoke test.
- `Sources/SFEngineSoak` – shared soak test runner used by the CLI (and included in the SwiftUI target for future use).
- `Sources/CLISoakSwift` – macOS Swift CLI soak test.
- `IOSSwiftUI` – iOS/iPadOS SwiftUI smoke test app (iOS 26+).
- `ThirdParty/Stockfish` – vendored Stockfish source (tracked via git subtree).
- `Resources/NNUE` – NNUE networks referenced by the build (net files not tracked in repo - see below).
- `Resources/Soak` – default FEN position files for soak tests.

## NNUE weights (required immediately after clone)
To keep the repo binary-free (and because GitHub blocks files >100 MB), the NNUE nets are **not in Git**. Use the Stockfish test server and download both nets before you build or run anything:
```
mkdir -p Resources/NNUE
curl -L --fail https://tests.stockfishchess.org/api/nn/nn-c288c895ea92.nnue -o Resources/NNUE/nn-c288c895ea92.nnue
curl -L --fail https://tests.stockfishchess.org/api/nn/nn-37f18f62d772.nnue -o Resources/NNUE/nn-37f18f62d772.nnue
```

If you prefer, you can run `ThirdParty/Stockfish/scripts/net.sh` (from within `ThirdParty/Stockfish/src`), then copy the downloaded `.nnue` files into `Resources/NNUE`.

## Building
### Xcode
1. Open `StockfishEmbedded.xcodeproj`.
2. Build `SFEngine-iOS` for device or simulator, or `SFEngine-macOS` for macOS to produce `libSFEngine-*.a`.
3. Build/run `SFEngineCLITestObjC` or `SFEngineCLITestSwift` (macOS) to run the minimal UCI smoke tests.
4. Build/run `SFEngineTestSwiftUI` (iOS/iPadOS) for the SwiftUI smoke test app.
Note: Building `SFEngineTestSwiftUI` for device requires selecting a Development Team in Xcode (Signing & Capabilities).

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

# iOS/iPadOS SwiftUI smoke test (build only)
xcodebuild -project StockfishEmbedded.xcodeproj -scheme SFEngineTestSwiftUI -configuration Debug -destination 'generic/platform=iOS' -derivedDataPath build
```

Tip: If you see stale-file warnings after switching build output locations, delete `build/` or clean DerivedData.

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
- `--continue-on-timeout` – keep going after timeouts.
- `--chess960` plus `--chess960-positions PATH` – include Chess960 positions.

Positions files are one FEN per line; `startpos` is also accepted. Relative paths are resolved against the current
working directory and the repo root.

## Design approach
This repo embeds Stockfish as an in-process static library with a minimal shim and keeps upstream
Stockfish sources unmodified. The goal is a small, maintainable adaptation layer that is easy to update when
Stockfish changes.

Highlights:
- Upstream Stockfish sources are untouched; the wrapper lives in `Sources/SFEngine`.
- Stockfish is vendored via git subtree, so updates are explicit and reviewable.
- NNUE networks are embedded into the static library at build time (once downloaded) for out-of-the-box `go` searches.
- Stream redirection is scoped to the shim instead of global source edits.
- The API surface is small and Swift-friendly (thread-safe command queue + line callback).
- Xcode targets include macOS CLI smoke tests and an iOS/iPadOS SwiftUI smoke app.

## Adapter details
- `SFEngine` spins the engine on a background thread, swapping `std::cin/std::cout` to custom stream buffers that talk to a thread-safe queue.
- `stop` enqueues `stop` + `quit`, closes the queue (to guarantee EOF), and waits briefly for a clean shutdown.
- Stockfish sources are unmodified; the tiny `EmbeddedUCI` shim calls the upstream UCI loop after redirecting streams and performing the normal initialization from `main.cpp`.

## Known limitations
- Engines are intended for single start/stop per instance; create a new `SFEngine` if you need to restart.
- Bitcode is disabled for iOS builds.

## Stockfish versioning
Stockfish sources are vendored in `ThirdParty/Stockfish` via `git subtree` and track the official `master` branch. Updates are manual; clones always include the exact snapshot committed here.

Key points:
- Updates are explicit and reviewable; there is no submodule.
- Updating Stockfish is a single subtree pull from upstream.
- If Stockfish changes the default NNUE filenames, revisit the NNUE section above and download the matching nets.
  You can confirm the required filenames in `ThirdParty/Stockfish/src/evaluate.h` (`EvalFileDefaultNameBig` / `EvalFileDefaultNameSmall`).
- Warning: Updating Stockfish (to `master` or a release tag) can break the parent repo's shim or build setup due to upstream API or initialization changes. If a build fails after an update, you may need to adjust the wrapper code in `Sources/SFEngine` to match the new Stockfish expectations.
- Typical update workflow: pull the subtree from upstream, check if the NNUE filenames changed, download any new nets, then build the CLI/SwiftUI smoke tests. If you see build errors in `Sources/SFEngine`, update the shim to match Stockfish's current initialization path.
- Even if the project successfully compiles, compare the current Stockfish `main.cpp` initialization sequence with the shim in `Sources/SFEngine/EmbeddedUCI.cpp` to catch new init steps that could affect runtime behavior.

To see the most recent subtree update commit (and upstream SHA):
```
git log -1 --pretty=%B -- ThirdParty/Stockfish
```

To pin to an official release tag (example: `sf_17.1`):
```
git subtree pull --prefix ThirdParty/Stockfish https://github.com/official-stockfish/Stockfish.git sf_17.1
```

To update to the latest commit on `master`:
```
git subtree pull --prefix ThirdParty/Stockfish https://github.com/official-stockfish/Stockfish.git master
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
