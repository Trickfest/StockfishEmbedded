# Architecture

StockfishEmbedded keeps upstream Stockfish unmodified and puts its adaptation
layer in `Sources/SFEngine`. The wrapper owns transport and lifecycle, not chess
rules, game state, UI, or a typed UCI model.

## Engine lifecycle

`SFEngine` owns a worker thread running the UCI loop. The shim mirrors the
initialization in upstream `main.cpp`, then redirects process-wide `std::cin`
and `std::cout` to queue-backed streams. Stockfish has its own search workers;
the UCI `Threads` option is distinct from the wrapper's loop thread.
App/UI code submits commands through the thread-safe `sendCommand(_:)` queue;
neither the UCI loop nor best-move search runs on the app's main thread.

In this snapshot, `Threads` defaults to `1`, so a normal search uses one
Stockfish search worker. To request more workers, send an option such as
`setoption name Threads value 4` after `uciok` and before the `isready` probe
that precedes searching. Even one busy search worker can consume roughly one
CPU core while thinking; that does not mean search is running on the UI thread.

The caller sends `uci`, waits for `uciok`, applies supported options, then sends
`isready` and waits for `readyok`. A returned `start()` call is not a completed
handshake. Send one search at a time, and consume its terminal `bestmove` before
reusing that session for an independent search.

`stop()` enqueues `stop` and `quit`, closes the input queue to guarantee EOF,
joins the engine thread, and waits for teardown. It is terminal even before
first startup. `suspend()` instead joins the current loop thread
while retaining the loaded Stockfish engine and network. Use it only after a
completed search; `resume()` restarts the loop around that retained engine and
requires another handshake.

## Threads and process ownership

Callbacks arrive in order on a wrapper-owned serial background queue; Swift
imports the line handler as `@Sendable`. Off that queue, shutdown drains pending
callbacks. Callback-initiated shutdown suppresses later queued callbacks so
another handler invocation does not begin after it returns. Dispatch UI work
to the main actor and perform blocking teardown away from that actor.

Only one SFEngine instance may own its native engine slot. A suspended instance
retains that lease, although it releases the stream redirect. Start a rejected
contender only after the owning instance has stopped. Stockfish and Arasan do
not share a native ownership guard; the consuming app must serialize them.
Unrelated host C++ `std::cout` output can be captured while streams are
redirected, so avoid such output during an engine session.

## Commands and runtime assets

`sendCommand(_:)` accepts a trusted single UCI line, optionally ending in LF or
CRLF. NULs, multiple lines, commands over 1 MiB, and `Debug Log File` are
rejected. The logger is process-static and does not fit per-session streams.
SwiftPM also rejects raw EvalFile changes: the initializer fixes the network
path and Stockfish's loader preflights compatibility before entering the loop.

SwiftPM defines `NNUE_EMBEDDING_OFF` and expects a caller-owned network URL.
Calling `start()` without the external-network initializer is rejected in a
SwiftPM build. The default initializer remains available for legacy Xcode
library targets, which embed the locally downloaded network. These paths
share wrapper code but need separate integration tests. The soak runner belongs
to the Xcode infrastructure: it is compiled into the CLI, XCTest, and existing
SwiftUI smoke-app targets, not the exported SwiftPM library. The CLI exercises
it; inclusion in the SwiftUI target is not proof that the app runs a soak.

The SwiftPM target's explicit NEON compilation configuration is intentional
and makes it Apple-arm64-only; Intel macOS and x86_64 simulators are unsupported.

Search limits (`go movetime`, `go depth`, `go nodes`) are not the same as a
client safety timeout. UCI `stop` is cooperative, not a native thread kill.
If a client timeout expires, send `stop` and wait for terminal `bestmove` before
advancing; discard/shut down a session that never reaches its terminal boundary.

## Repository layout

- `Package.swift`: external-network SFEngine source library.
- `.spi.yml`: Swift Package Index build and DocC configuration.
- `Sources/SFEngine`: Objective-C++ wrapper, shim, queues, public headers, DocC.
- `ThirdParty/Stockfish`: exact upstream snapshot with its license notices.
- `StockfishEmbedded.xcodeproj`: legacy static libraries and smoke/test targets.
- `Tests/SFEnginePackageTests`: SwiftPM tests with external-network behavior.
- `Tests/SFEngineTests`: legacy XCTest, soak, and startup-parity suites.
- `Sources/CLIObjC`, `Sources/CLISwift`: macOS smoke executables.
- `Sources/SFEngineSoak`, `Sources/CLISoakSwift`: runner and CLI.
- `IOSSwiftUI`: existing iOS/iPadOS smoke app.
- `Resources/NNUE`: ignored local network; `Resources/Soak`: attributed corpus.

The legacy Xcode Release engine libraries use `-O3` and `NDEBUG=1`, matching
Stockfish's optimized, non-debug build policy. SwiftPM Release builds also
define `NDEBUG`, with optimization controlled by the SwiftPM toolchain.
Debug builds retain native assertions. See [Testing](Testing.md) for the actual
validation commands, rather than treating one successful build as proof that
every integration path works.
