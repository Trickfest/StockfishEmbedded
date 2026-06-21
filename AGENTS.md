# AGENTS.md

This repo embeds the Stockfish chess engine as an in-process static library for iOS and macOS,
wrapped by a small Objective-C API (`SFEngine`) that is safe to call from Swift.

## Layout
- `StockfishEmbedded.xcodeproj` – Xcode project and build targets.
- `Sources/` – adapter layer, CLI smoke tests, and soak runner.
- `IOSSwiftUI/` – SwiftUI smoke test app (iOS/iPadOS).
- `ThirdParty/Stockfish/` – vendored Stockfish sources.
- `Resources/NNUE/` – NNUE network files (download required).
- `Resources/Soak/` – default soak test positions.

## Required assets
NNUE weights are not in Git. Download the required net before building:
```
mkdir -p Resources/NNUE
curl -L --fail https://tests.stockfishchess.org/api/nn/nn-71d6d32cb962.nnue -o Resources/NNUE/nn-71d6d32cb962.nnue
```

## Updating vendored Stockfish
Stockfish is vendored in `ThirdParty/Stockfish` with `git subtree --squash`.
Keep upstream Stockfish sources unmodified; make repo-specific integration changes
only in this repo's wrapper/build files.

1. Ensure the official upstream remote exists and is fresh:
```
git remote get-url stockfish
git fetch stockfish master
git log -1 --oneline stockfish/master
```
If the `stockfish` remote is missing, add it first:
```
git remote add stockfish https://github.com/official-stockfish/Stockfish.git
git fetch stockfish master
```

2. Check the actual vendored tree before treating subtree metadata as current:
```
git log --grep='git-subtree-dir: ThirdParty/Stockfish' --pretty=format:'%B' -n 1
git diff --quiet 'stockfish/master^{tree}' HEAD:ThirdParty/Stockfish && echo "vendored tree matches stockfish/master"
git diff --stat 'stockfish/master^{tree}' HEAD:ThirdParty/Stockfish
git rev-list --count <git-subtree-split>..stockfish/master
```
If the tree comparison succeeds, the vendored source is 0 commits behind
`stockfish/master` even if the last `git-subtree-split` line points at an older
upstream commit. Use the `git-subtree-split` count as metadata freshness only
after checking the actual tree; it can be stale when a vendoring update was
committed manually instead of through `git subtree pull`.

3. Pull the latest official Stockfish `master` into the vendored subtree:
```
git subtree pull --prefix ThirdParty/Stockfish stockfish master --squash
```

4. Audit the embedded UCI shim against upstream `main.cpp`:
```
git show stockfish/master:src/main.cpp
```
Compare Stockfish's initialization sequence with
`Sources/SFEngine/EmbeddedUCI.cpp`. Port any new or removed setup steps while
preserving the repo-specific stream redirection, fake `argv`, and embedded
entry point. This shim intentionally mimics Stockfish `main()` before calling
`UCIEngine::loop()`.

5. Check whether Stockfish changed its required NNUE files:
```
rg -n 'EvalFileDefaultName|nn-[a-f0-9]+\.nnue' ThirdParty/Stockfish/src
```
Download any new required nets into `Resources/NNUE/` and update this file,
delete obsolete local `.nnue` files that are no longer referenced by the
current Stockfish snapshot, and update this file, `README.md`, and
`Resources/NNUE/README.md` if the filenames changed. NNUE files are ignored
local assets and should not be committed.

6. Refresh versioning documentation for the new snapshot:
```
git log --grep='git-subtree-dir: ThirdParty/Stockfish' --pretty=format:'%B' -n 1
rg -n '<old-subtree-split>|sf_[0-9]|Stockfish [0-9]|snapshot|Current vendored upstream commit' README.md Resources/NNUE/README.md
```
Replace `<old-subtree-split>` with the split recorded before the subtree pull.
Update `README.md`'s "Stockfish versioning" section so `Current vendored
upstream commit` matches the new `git-subtree-split` line. Also check nearby
versioning examples and release/snapshot wording so they do not keep pointing
at the previous pre-update snapshot or an obsolete release tag. Historical
`CHANGELOG.md` entries should keep the SHAs from their original releases; update
only the new/current changelog entry if you add one for the Stockfish update.

7. Build and run smoke tests after the subtree and shim updates:
```
xcodebuild -project StockfishEmbedded.xcodeproj -scheme SFEngine-macOS -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath build
xcodebuild -project StockfishEmbedded.xcodeproj -scheme SFEngineCLITestObjC -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath build
./build/Build/Products/Debug/SFEngineCLITestObjC
xcodebuild -project StockfishEmbedded.xcodeproj -scheme SFEngineCLITestSwift -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath build
./build/Build/Products/Debug/SFEngineCLITestSwift
```

8. Run a short soak test when smoke tests pass:
```
xcodebuild -project StockfishEmbedded.xcodeproj -scheme SFEngineCLISoakTestSwift -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath build
./build/Build/Products/Debug/SFEngineCLISoakTestSwift --iterations 5 --movetime 500
```

## Build (Xcode)
1. Open `StockfishEmbedded.xcodeproj`.
2. Build `SFEngine-iOS` or `SFEngine-macOS` for static libs.
3. Run `SFEngineCLITestObjC` or `SFEngineCLITestSwift` for smoke tests.
4. Run `SFEngineTestSwiftUI` for the iOS/iPadOS smoke app. Generic device
   builds of the app require a Development Team unless code signing is disabled
   for build-only validation.

## Build (CLI)
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

# iOS/iPadOS SwiftUI smoke test (unsigned build only)
xcodebuild -project StockfishEmbedded.xcodeproj -scheme SFEngineTestSwiftUI -configuration Debug -destination 'generic/platform=iOS' -derivedDataPath build CODE_SIGNING_ALLOWED=NO build
```

## Soak tests (CLI)
```
xcodebuild -project StockfishEmbedded.xcodeproj -scheme SFEngineCLISoakTestSwift -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath build
./build/Build/Products/Debug/SFEngineCLISoakTestSwift --iterations 5 --movetime 500
```

## Notes
- Stockfish sources are vendored via `git subtree` and kept unmodified.
- `SFEngine` is intended for single start/stop per instance.
- Bitcode is disabled for iOS builds.
- Keep standardized GPL source headers on this repo's owned wrapper, smoke-test,
  and test sources. Do not rewrite or normalize headers inside
  `ThirdParty/Stockfish`; those files belong to upstream Stockfish.

## License
GPL-3.0. Using the static library in a distributed app generally requires the entire app
to be GPL-3.0 and source-available. See `LICENSE` for details.
