# Project Integration (No SwiftPM)

This document describes how to use StockfishEmbedded from another Xcode project
without Swift Package Manager. Consumers build it from source by adding the
StockfishEmbedded Xcode project to their app project or workspace.

Important:
- NNUE files are required at build time because they are embedded into the library.
  See `Resources/NNUE/README.md` for download steps.
- The current static libraries require iOS/iPadOS 26 or macOS 26.
- Consumer targets must link the C++ standard library with
  `OTHER_LDFLAGS = $(inherited) -lc++`.
- GPL-3.0 obligations apply when you distribute apps that link this library.

## Add as a Subproject (Source Integration)

Best when you want Xcode to build StockfishEmbedded from source as part of your app build.

### Quickstart
1) Add `StockfishEmbedded.xcodeproj` to your app project (or create a workspace and add both projects).
2) App target -> Build Phases -> Target Dependencies -> add `SFEngine-iOS`.
   Then Link Binary With Libraries -> add `libSFEngine-iOS.a`.
3) Create or reuse a bridging header and import:
   ```
   #import "SFEngine.h"
   ```
   Set `Objective-C Bridging Header` to the header path and add a Header Search Path for
   `Sources/SFEngine`. Example:
   ```
   $(PROJECT_DIR)/MyApp/MyApp-Bridging-Header.h
   $(PROJECT_DIR)/../StockfishEmbedded/Sources/SFEngine
   ```
4) Add `-lc++` to the app target's Other Linker Flags, then build for device or
   simulator.

### For non-Xcode folks (details)
- Xcode settings are per target. Make changes on your app target, not the project.
- `$(PROJECT_DIR)` resolves to the folder that contains your app's `.xcodeproj`.
- A workspace (`.xcworkspace`) is a container that lets multiple projects build together and
  keeps schemes visible in one place.
- Step 1 detail: drag the `.xcodeproj` into the Project Navigator, or create a workspace and
  add both projects to it.
- Step 2 detail: if `SFEngine-iOS` is greyed out, you are likely editing a macOS target or the
  projects are not in the same workspace/subproject tree.
- Step 3 detail: the bridging header is how Swift sees Objective-C. If you already have one,
  add the import line to it; do not create a second bridging header.
- `-lc++` is required because the static archive contains unresolved C++
  standard-library symbols.

## Optional: Use an .xcconfig (recommended for repeatability)

If you want these settings in source control (and don't want to re-click them in Xcode),
create a small `.xcconfig` file in your app repo and attach it to your app target.

Example: `Configs/StockfishEmbedded.xcconfig`
```
// StockfishEmbedded.xcconfig
SWIFT_OBJC_BRIDGING_HEADER = $(PROJECT_DIR)/MyApp/MyApp-Bridging-Header.h
OTHER_LDFLAGS = $(inherited) -lc++

HEADER_SEARCH_PATHS = $(inherited) "$(PROJECT_DIR)/../StockfishEmbedded/Sources/SFEngine"
```

Where it lives:
- Any folder in your app repo is fine; `Configs/` or next to the `.xcodeproj` are common.

How to apply it:
- In Xcode: select the project -> Info -> Configurations -> set the base configuration
  for your app target to this `.xcconfig` (for Debug/Release as needed).

## Runtime behavior for app integrators

`SFEngine` embeds Stockfish in your app process. Calling `start()` creates a
wrapper-owned C++ thread that runs the Stockfish UCI loop, and app code sends
commands through the thread-safe `sendCommand(_:)` queue. Stockfish performs
best-move search on its own search worker thread or threads, not on the app's
main thread. The vendored engine's default UCI `Threads` value is `1`; apps that
want more search workers must explicitly send a `setoption name Threads value N`
command before searching.

Prefer UCI search limits for normal move timing, especially
`go movetime <milliseconds>` when the UI needs predictable pacing. App-side
timeouts are safety cutoffs around waiting for a result. If a timeout fires, the
app can send `stop`, but that is a cooperative request to Stockfish rather than
a forced thread interruption.

## Verification checklist (sanity check)
- You downloaded NNUE files before building StockfishEmbedded.
- Your app target depends on `SFEngine-iOS` and links `libSFEngine-iOS.a`.
- The bridging header imports `SFEngine.h`.
- The app target's Other Linker Flags include `$(inherited) -lc++`.
- The app builds for both device and simulator.

## Common errors and fixes
- `SFEngine-iOS` is greyed out: check you are on an iOS app target, and both projects
  are in the same workspace/subproject tree.
- `'SFEngine.h' file not found`: fix the bridging header path or header search paths.
- `Undefined symbols for architecture ...`: confirm `-lc++` is present and that
  you are linking the slice for the active platform/architecture.
- `building for iOS Simulator, but linking in object file built for iOS`: ensure
  the app target depends on `SFEngine-iOS` and lets Xcode build it for the active
  destination.
