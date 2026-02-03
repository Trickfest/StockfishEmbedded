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
NNUE weights are not in Git. Download both nets before building:
```
mkdir -p Resources/NNUE
curl -L --fail https://tests.stockfishchess.org/api/nn/nn-c288c895ea92.nnue -o Resources/NNUE/nn-c288c895ea92.nnue
curl -L --fail https://tests.stockfishchess.org/api/nn/nn-37f18f62d772.nnue -o Resources/NNUE/nn-37f18f62d772.nnue
```

## Build (Xcode)
1. Open `StockfishEmbedded.xcodeproj`.
2. Build `SFEngine-iOS` or `SFEngine-macOS` for static libs.
3. Run `SFEngineCLITestObjC` or `SFEngineCLITestSwift` for smoke tests.
4. Run `SFEngineTestSwiftUI` for the iOS/iPadOS smoke app.

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

## License
GPL-3.0. Using the static library in a distributed app generally requires the entire app
to be GPL-3.0 and source-available. See `LICENSE` for details.
