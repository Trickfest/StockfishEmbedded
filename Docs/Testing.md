# Testing

StockfishEmbedded has two runtime paths: the SwiftPM product takes a local NNUE
URL, while legacy Xcode targets embed the downloaded network. Test both. A
successful legacy smoke does not replace package-path coverage.

## Full local validation

From the repository root on an Apple-silicon Mac:

```sh
Scripts/validate.sh
```

The gate downloads/verifies the current network if needed, checks its identity
in the setup documentation, and runs:

- Debug and Release SwiftPM builds/tests.
- An arm64 iOS Simulator package build.
- A disposable clean copy without NNUE: manifest, build/tests, and the exact
  source-only SPI scheme for macOS and generic iOS Release builds.
- The macOS legacy library, Objective-C and Swift CLI smokes, a short soak,
  and the macOS XCTest harness.
- An iOS Simulator smoke-app build and generic-device Release library build.

The script's iOS checks are builds, not runtime XCTest sessions on a device.
Its five-iteration soak is a short check, not an exhaustive corpus run. It has
no explicit Thread Sanitizer invocation, API-baseline comparison, source-archive
notice check, or DocC build. Do not describe those as part of the current gate.

## Package tests

These commands do not download a model:

```sh
swift package dump-package
swift build
swift test
swift test -c release
```

`Tests/SFEnginePackageTests` covers importing SFEngine, required external-network
configuration, incompatible files, valid searches, raw EvalFile rejection, and
suspend/resume. Valid-network tests require the ignored current network under
`Resources/NNUE`. The previous-layout network is an optional migration fixture.
Their `.enabled` conditions make absent asset-dependent cases visible as skips;
unconfigured and corrupt-network checks still run without a downloaded model.

## Legacy Xcode tests and smoke

Run `Scripts/download-nnue.sh` first. The legacy targets embed that file.
The helper verifies/reuses a valid existing download; pass `--force` only when
you want to download a fresh copy.

In Xcode, open `StockfishEmbedded.xcodeproj`. Build `SFEngine-macOS` or
`SFEngine-iOS` to produce `libSFEngine-macOS.a` or `libSFEngine-iOS.a` for the
chosen destination. The equivalent standalone library commands are:

```sh
xcodebuild -project StockfishEmbedded.xcodeproj -scheme SFEngine-macOS \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build build

xcodebuild -project StockfishEmbedded.xcodeproj -scheme SFEngine-iOS \
  -configuration Release -destination 'generic/platform=iOS' \
  -derivedDataPath build build
```

Build/run the CLI smoke schemes or run the XCTest harness:

```sh
xcodebuild -project StockfishEmbedded.xcodeproj -scheme SFEngineTests \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build test

xcodebuild -project StockfishEmbedded.xcodeproj -scheme SFEngineCLITestSwift \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build build
./build/Build/Products/Debug/SFEngineCLITestSwift

xcodebuild -project StockfishEmbedded.xcodeproj -scheme SFEngineCLITestObjC \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build build
./build/Build/Products/Debug/SFEngineCLITestObjC
```

`Tests/SFEngineTests` includes lifecycle/ownership, callback-safe shutdown,
concurrent commands, active-search stops, perft counts, tactical allowed moves,
score bands, soak behavior, and shim-startup parity. Several tests contain many
positions; method counts are not a useful comparison with another engine.

To build the existing iOS smoke app for Simulator or as an unsigned device
build-only check:

```sh
xcodebuild -project StockfishEmbedded.xcodeproj -scheme SFEngineTestSwiftUI \
  -configuration Debug -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath build CODE_SIGNING_ALLOWED=NO build

xcodebuild -project StockfishEmbedded.xcodeproj -scheme SFEngineTestSwiftUI \
  -configuration Debug -destination 'generic/platform=iOS' \
  -derivedDataPath build CODE_SIGNING_ALLOWED=NO build
```

Run that app in Xcode and tap Run to exercise it. Running on a physical device
requires selecting your Development Team under Signing & Capabilities;
an unsigned build alone cannot run there. For old static-library embedding, see
[legacy integration](../PROJECT_INTEGRATION.md).

## CLI soak

```sh
xcodebuild -project StockfishEmbedded.xcodeproj -scheme SFEngineCLISoakTestSwift \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build build
./build/Build/Products/Debug/SFEngineCLISoakTestSwift --iterations 5 --movetime 500
./build/Build/Products/Debug/SFEngineCLISoakTestSwift --iterations 100 --depth 10 --ready-each
```

The CLI uses the existing SFEngineSoakRunner and defaults to
`Resources/Soak/positions.txt` with a depth-8 search. Without `--iterations`, it
repeats until stopped. Its main options are:

- `--iterations N`: cap the run rather than repeating indefinitely.
- `--positions PATH...`: explicit position files.
- `--depth N`, `--nodes N`, or `--movetime MS`: choose one search limit.
- `--timeout S`: per-move deadline, 30 seconds by default.
- `--stop-timeout S`: deadline after sending `stop`, 5 seconds by default.
- `--handshake-timeout S`: deadline for `uciok`/`readyok`, 10 seconds by default.
- `--delay-ms MS`: pause between iterations, in milliseconds.
- `--ready-each`: send `isready` and await `readyok` before each iteration.
- `--log-output`: print every engine output line.
- `--chess960`, optionally `--chess960-positions PATH`: the separate Chess960
  set, defaulting to `Resources/Soak/positions_chess960.txt`.

On timeout, the runner sends `stop` and consumes terminal `bestmove` before the
next position. If that boundary never arrives, it ends the run. Relative input
paths are resolved against the working directory and repository root. Files
accept one `startpos` or four/six-field FEN per line, optionally followed by
`moves <uci-move> ...`.
Obvious syntax errors are rejected before native engine startup; this is not a
substitute for a chess rules layer validating user positions. See
[corpus provenance](../Resources/Soak/README.md).

## Shared consumer checks

[SwiftChessDemo](https://github.com/Trickfest/SwiftChessDemo) is the shared
end-to-end app for both engines. Its local gate includes real provider and
simulator UI tests alongside deterministic/fake-transport tests. Keep those
categories distinct. Hands-on device gameplay remains a separate check for
consumer lifecycle or native-startup changes.

## Hosted validation

There is no active root GitHub Actions workflow. Local validation is required;
a hosted run is not a completion or release condition. Inactive workflows under
`ThirdParty/Stockfish` belong to upstream and should not be repurposed here.
A future manually dispatched hosted gate would need explicit NNUE downloading
and integrity verification before asset-backed tests; that workflow is deferred.

## Adding tests

Prefer observable protocol and lifecycle guarantees: readiness before search,
terminal bestmove before reuse, bounded teardown, ownership, and callback order.
Use small, attributed fixtures with known acceptable moves for search checks;
do not compare exact evaluations or claim strength from a smoke/soak run.
Retain engine-specific perft and migration regressions. Broader SwiftPM and
soak-cancellation/event-order coverage is follow-up work, not an existing gate
guarantee. See [Troubleshooting](Troubleshooting.md) when a check fails.
