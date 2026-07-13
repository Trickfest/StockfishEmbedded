# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- Added lifecycle, concurrent-instance, callback-stop/drain, unsafe-command,
  timeout-attribution, and soak runner regression coverage.
- Added `Scripts/validate.sh` as a single complete local validation entry point.
- Began tracking the Swift package lockfile for reproducible ArgumentParser
  resolution.

### Changed

- Deliver engine output in order on a wrapper-owned serial callback queue and
  make callback-initiated shutdown safe; Swift now imports the handler as
  `@Sendable` so its cross-thread capture contract is compiler-visible.
- Make `stop` a terminal instance transition even when called before `start`,
  eliminating an ambiguous concurrent start/stop window.
- Enforce one active `SFEngine` per process because the upstream UCI loop uses
  process-wide C++ streams; rejected concurrent starts now report an
  `info string StockfishEmbedded error` line and may be retried later.
- Move the owned Swift smoke, soak, and test targets to Swift 6.
- Make Swift Debug builds explicitly unoptimized and testable instead of
  inheriting release-style compiler defaults from the sparse project settings.
- Align Release engine libraries with Stockfish's normal optimized build policy
  by using `-O3` and `NDEBUG`; Debug builds continue to retain assertions.
- Make the soak runner validate configuration/position input, preserve callback
  order, expose only the parsed best-move token, reject concurrent runs, and
  observe stop requests promptly during handshakes and delays.
- Verify the SHA-256 prefix encoded in NNUE filenames for cached and downloaded
  networks.
- Clarify the OS 26 deployment floor, required `-lc++` consumer setting,
  process-global stream boundary, trusted-command boundary, and GPL
  release checklist.
- Document that GitHub-hosted validation is intentionally deferred while the
  NNUE-backed local validation gate remains the expected release evidence.

### Fixed

- Break the engine thread's unintended retain of its `SFEngine` owner so
  releasing a running wrapper reaches deterministic shutdown instead of
  leaking or potentially attempting a fatal self-join.
- Serialize lifecycle state so concurrent `start`, `sendCommand`, and `stop`
  calls cannot race the thread handle or a closed command queue.
- Reject embedded NULs, multiple UCI lines, oversized commands, and Stockfish's
  incompatible process-static `Debug Log File` option at the owned boundary.
- Clear callback-less output buffers and protect line assembly from concurrent
  writers.
- Normalize C++ stream formatting/locale for UCI and restore the host's prior
  formatting, locale, tie, buffers, and safely restorable stream state.
- Stop the soak runner after an unrecovered timeout instead of allowing a late
  best move to be attributed to the next position; align emitted error events
  with summary error counts.
- Preserve a line consumed exactly at a timeout boundary instead of discarding
  a terminal `bestmove`, and suppress queued callbacks after handler-initiated
  shutdown returns.
- Return failure from the Objective-C and Swift CLI smoke tests unless `uciok`,
  `readyok`, and a legal best move are observed.
- Prevent the SwiftUI smoke app from starting a new engine until asynchronous
  teardown completes, and ignore output from stale run tokens.

### Removed

- Removed the unsafe soak `--continue-on-timeout` option and the corresponding
  `Configuration.stopOnTimeoutFailure` property. Recovered timeouts now consume
  that search's terminal `bestmove`; unrecovered timeouts always stop the run.
- Removed the XCFramework integration path from the current documentation;
  StockfishEmbedded is supported as source through its Xcode project rather
  than as a published binary package.

## [1.7.0] - 2026-07-02

### Changed

- Documented `SFEngine` threading, Stockfish search workers, and the difference
  between UCI search limits, app-side timeouts, and cooperative `stop` requests.
- Updated vendored Stockfish subtree to upstream commit
  `6088838797d6333711c17fe2c0962fa0858517ec` (official `master` as of
  2026-07-02).
- Updated NNUE instructions to use `nn-af1339a6dea3.nnue`.
- Audited the embedded UCI shim against upstream `main.cpp`; no shim code
  changes were required for this Stockfish snapshot.

## [1.6.2] - 2026-06-29

### Fixed

- Detach `std::cin` from `std::cout` while Stockfish runs against
  wrapper-provided streams, avoiding flushes against redirected output during
  engine shutdown and restart.
- Join the engine thread during shutdown instead of detaching it after a timeout,
  so redirected stream buffers outlive the running UCI loop.

### Tests

- Added repeated stop/search lifecycle coverage for active searches and fresh
  engine starts.

## [1.6.1] - 2026-06-22

### Added

- Added `Scripts/download-nnue.sh` to download the NNUE file required by the
  current vendored Stockfish snapshot.

### Changed

- Updated NNUE setup docs to use the helper script as the primary setup path.

## [1.6.0] - 2026-06-21

### Changed
- Updated vendored Stockfish subtree to upstream commit
  `74a0a73715322608332038f7c0151ddf0609a59a` (official `master` as of
  2026-06-21).
- Updated NNUE instructions to use `nn-71d6d32cb962.nnue`.
- Audited the embedded UCI shim against upstream `main.cpp`; no shim code
  changes were required for this Stockfish snapshot.

## [1.5.1] - 2026-06-21

### Changed
- Added a README reference to `SwiftChessDemo` showing how
  `StockfishEmbedded` combines with `SwiftChessTools` in a realistic iOS chess
  app.
- Clarified the unsigned command-line build path for the iOS/iPadOS SwiftUI
  smoke app when a Development Team is not configured.
- Standardized GPL source headers across owned wrapper, smoke-test, and test
  sources while leaving vendored Stockfish files untouched.

## [1.5.0] - 2026-05-26
### Added
- Added an `EmbeddedUCI` parity regression test that compares the wrapper startup lifecycle against the vendored Stockfish `main.cpp` path.

### Changed
- Updated vendored Stockfish subtree to upstream commit `77a8f6ccf31846d63452f79e143fbc6dc62ae3a8` (official `master` as of 2026-05-25).
- Updated NNUE instructions to use `nn-83a0d6daf7e5.nnue`.
- Updated the embedded UCI shim to mirror Stockfish's new `Attacks::init()` startup step.
- Clarified the vendored Stockfish update instructions to compare the actual `ThirdParty/Stockfish` tree against upstream before using subtree metadata to report how far the vendored source is behind.

## [1.4.0] - 2026-05-04
### Changed
- Updated vendored Stockfish subtree to upstream commit `5095cd16c97e7596f2d2a02eb05ed8e030af991f` (official `master` as of 2026-05-04).
- Updated NNUE instructions to use `nn-fcf986aea78a.nnue`.
- Updated the embedded UCI shim to mirror Stockfish `main.cpp` more closely.
- Added documented steps for future vendored Stockfish updates.

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
