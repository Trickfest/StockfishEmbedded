# Project Integration (No SwiftPM)

This document describes two ways to use StockfishEmbedded from another Xcode project
without Swift Package Manager.

Important:
- NNUE files are required at build time because they are embedded into the library.
  See `Resources/NNUE/README.md` for download steps.
- GPL-3.0 obligations apply when you distribute apps or binaries that link this library.

## Option 1: Add as a Subproject (Source Integration)

Best when you want Xcode to build StockfishEmbedded from source as part of your app build.

1) Add the project:
   - In your app project, drag `StockfishEmbedded.xcodeproj` into the Project Navigator
     (or create a workspace and add both projects).

2) Add the library to your app target:
   - Select your app target -> Build Phases -> Target Dependencies -> add `SFEngine-iOS`.
   - Build Phases -> Link Binary With Libraries -> add `libSFEngine-iOS.a`.

3) Expose the Objective-C API to Swift:
   - Create a bridging header (e.g., `MyApp-Bridging-Header.h`) and add:
     ```
     #import "SFEngine.h"
     ```
   - Set Build Settings -> Objective-C Bridging Header to the header path.
   - Add a Header Search Path pointing at:
     `path/to/StockfishEmbedded/Sources/SFEngine`

4) Build your app for device or simulator. Xcode will compile StockfishEmbedded for
   the active destination automatically.

Note: If the linker complains about C++ symbols, add `-lc++` to
`Other Linker Flags` in your app target.

## Option 2: Build an XCFramework (Binary Integration)

Best when you want to drop a single binary into multiple projects.

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

Note: To support both Apple Silicon and Intel simulators, you may need to build the
simulator slice on both architectures or pass `ARCHS="arm64 x86_64"` when building
the simulator library.
