# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

## [1.3.0] - 2026-04-30
### Changed
- Updated vendored Stockfish subtree to upstream commit `1a882efc7fc22b3b16893a406e6060916022fcc4` (official `master` as of 2026-04-30).
- Updated NNUE instructions to use `nn-f68ec79f0fe3.nnue` (big net) and `nn-47fc8b7fff06.nnue` (small net).
- Clarified README wording around the engine worker thread.

## [1.2.0] - 2026-03-11
### Added
- Added `SFEngineTests` XCTest harness with baseline coverage for wrapper contracts, perft node counts, tactical checks, and score-band assertions.
- Expanded `SFEngineTests` coverage with additional contract checks, perft positions, score-band cases, and a larger data-driven tactical mate-in-one regression set.

### Changed
- Refactored the `SFEngineTests` harness and tests to async/await, replacing semaphore-based waits and cursor polling with an async line mailbox and async XCTest expectations.
- Shared CLI Xcode schemes for `SFEngineCLITestObjC`, `SFEngineCLITestSwift`, and `SFEngineCLISoakTestSwift`; enabled `NSUnbufferedIO=YES` for immediate console output during Run; and set default soak Run arguments to `--iterations 5 --movetime 500 --log-output`.
- Updated vendored Stockfish subtree to upstream commit `b3a810a1c4201059bb97f6917df3276c03167a50` (official `master` as of 2026-03-11).
- Updated NNUE instructions to use `nn-9a0cc2a62c52.nnue` (big net) and `nn-47fc8b7fff06.nnue` (small net).
- Applied minor Xcode project file tweaks.

## [1.1.0] - 2026-02-09
### Changed
- Updated vendored Stockfish subtree to upstream commit `21b0974f8d1603e695aaa8148ba7fcd28bc47704` (official `master` as of 2026-02-09).
- Updated NNUE instructions to use `nn-3dd094f3dfcf.nnue` (big net) and `nn-37f18f62d772.nnue` (small net).

## [1.0.0] - 2026-01-02
### Added
- Embedded Stockfish as in-process static libraries for iOS and macOS with a minimal Objective-C shim.
- CLI smoke tests (ObjC + Swift) and a SwiftUI smoke test app.
- CLI soak test runner with FEN corpus support.
- NNUE download instructions and required resources layout.
- Integration guide covering subproject and XCFramework workflows.
- Stockfish vendored snapshot at upstream commit `44d5467bbe06789e8a3cbaee87e699e033b3081a`.
