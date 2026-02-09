# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]
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
