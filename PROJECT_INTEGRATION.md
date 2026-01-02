# Project Integration (No SwiftPM)

This document describes two ways to use StockfishEmbedded from another Xcode project
without Swift Package Manager.

Important:
- NNUE files are required at build time because they are embedded into the library.
  See `Resources/NNUE/README.md` for download steps.
- GPL-3.0 obligations apply when you distribute apps or binaries that link this library.

## Option 1: Add as a Subproject (Source Integration)

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
4) Build for device or simulator.

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
- If the linker complains about C++ symbols, add `-lc++` to `Other Linker Flags`.

## Option 2: Build an XCFramework (Binary Integration)

Best when you want to drop a single binary into multiple projects.

### Quickstart
1) Build device + simulator static libraries:
   ```
   xcodebuild -project StockfishEmbedded.xcodeproj \
     -scheme SFEngine-iOS -configuration Release \
     -destination 'generic/platform=iOS' \
     -derivedDataPath build

   xcodebuild -project StockfishEmbedded.xcodeproj \
     -scheme SFEngine-iOS -configuration Release \
     -destination 'generic/platform=iOS Simulator' \
     -derivedDataPath build
   ```

2) Create the XCFramework:
   ```
   xcodebuild -create-xcframework \
     -library build/Build/Products/Release-iphoneos/libSFEngine-iOS.a -headers Sources/SFEngine \
     -library build/Build/Products/Release-iphonesimulator/libSFEngine-iOS.a -headers Sources/SFEngine \
     -output build/SFEngine.xcframework
   ```

3) Integrate into your app:
   - Drag `build/SFEngine.xcframework` into your project.
   - In your app target, add it under "Frameworks, Libraries, and Embedded Content"
     and set it to "Do Not Embed".

4) Expose the Objective-C API to Swift:
   - Bridging header with:
     ```
     #import <SFEngine/SFEngine.h>
     ```

### For non-Xcode folks (details)
- iOS device and iOS simulator are different platforms; you must build both slices.
- The XCFramework packaging step combines the slices and exposes headers in a stable location.
- "Do Not Embed" is correct for static libraries; the app links it at build time.
- With an XCFramework you normally do not need Header Search Paths; the framework provides headers.
- If you already use a bridging header, just add the import line there.

Note: To support both Apple Silicon and Intel simulators, you may need to build the
simulator slice on both architectures or pass `ARCHS="arm64 x86_64"` when building
the simulator library.

## Optional: Use an .xcconfig (recommended for repeatability)

If you want these settings in source control (and don't want to re-click them in Xcode),
create a small `.xcconfig` file in your app repo and attach it to your app target.

Example: `Configs/StockfishEmbedded.xcconfig`
```
// StockfishEmbedded.xcconfig
SWIFT_OBJC_BRIDGING_HEADER = $(PROJECT_DIR)/MyApp/MyApp-Bridging-Header.h
OTHER_LDFLAGS = $(inherited) -lc++

// Option 1 (subproject) only:
HEADER_SEARCH_PATHS = $(inherited) "$(PROJECT_DIR)/../StockfishEmbedded/Sources/SFEngine"
```

Where it lives:
- Any folder in your app repo is fine; `Configs/` or next to the `.xcodeproj` are common.

How to apply it:
- In Xcode: select the project -> Info -> Configurations -> set the base configuration
  for your app target to this `.xcconfig` (for Debug/Release as needed).

If you use **Option 2** (XCFramework), remove the `HEADER_SEARCH_PATHS` line because the
framework exposes its own headers. Keep the bridging header line if you still use one.

## Verification checklist (sanity check)
- You downloaded NNUE files before building StockfishEmbedded.
- Option 1: your app target depends on `SFEngine-iOS` and links `libSFEngine-iOS.a`.
- Option 2: `SFEngine.xcframework` is added under "Frameworks, Libraries, and Embedded Content".
- The bridging header imports `SFEngine.h` (Option 1) or `<SFEngine/SFEngine.h>` (Option 2).
- The app builds for both device and simulator.

## Common errors and fixes
- `SFEngine-iOS` is greyed out: check you are on an iOS app target, and both projects
  are in the same workspace/subproject tree.
- `'SFEngine.h' file not found`: fix the bridging header path or header search paths (Option 1).
- `Undefined symbols for architecture ...`: you may be linking the wrong slice or missing `-lc++`.
- `building for iOS Simulator, but linking in object file built for iOS`: rebuild the
  simulator library (Option 2) or ensure you are linking `SFEngine-iOS` (Option 1).
