# Troubleshooting

## The package builds but the engine cannot search

SwiftPM deliberately builds without NNUE. Check `SFEngine.defaultNetworkFileName`,
download/verify that file, include it in the app or app-owned storage, and use
`SFEngine(networkFileURL:lineHandler:)`. The default initializer is for legacy
embedded-network targets, not a working SwiftPM network configuration.

Inspect `info string StockfishEmbedded error` output. Confirm the URL is local,
the file is readable, and its bytes match the documented network. A renamed old
model is not a compatible new model. Keep the file unchanged until shutdown.

## Startup returned but no move arrives

`start()` is not a readiness promise. Send `uci`, wait for `uciok`, send
`isready`, and wait for `readyok` before position/go commands. Keep the engine
owner alive and consume callbacks off the main actor. The README's async sample
must be awaited in a command-line program so the process does not exit early.
Set client deadlines; a sample without one is not a production timeout policy.

## Switching engines is slow or ownership is rejected

A concurrent second `start()` is rejected without starting its engine thread.
Its handler receives:

```text
info string StockfishEmbedded error: another SFEngine instance is already active
```

After the owner stops, the rejected instance can retry `start()` if it has not
itself been stopped.

Serialize native sessions across packages. For Stockfish, use suspend/resume
after completed searches to retain NNUE instead of reloading it every turn.
A suspended engine keeps its SFEngine lease: resume that instance, not a second
SFEngine. After terminal `stop()`, create a new instance. See
[Architecture](Architecture.md#threads-and-process-ownership).

## A search takes longer than its move budget

`go movetime` budgets search, not initial network loading, app pacing, callback
work, or UI animation. Measure those separately. On a client timeout, send UCI
`stop` and wait for terminal bestmove before reusing the session. Blocking
wrapper teardown belongs off the UI actor.

## A build or test is unsupported or skipped

Intel/x86_64 targets are unsupported. Use Apple arm64. Missing-network skips in
plain `swift test` are expected; run the full local gate for asset-backed
coverage. Legacy Xcode builds require the downloaded local file. If build-cache
warnings follow a toolchain/output-path change, use a fresh ignored DerivedData
directory or clean the existing DerivedData/generated `build/` output rather
than changing vendored engine code. Do not remove source files or runtime
network assets when clearing build products.

See [Testing](Testing.md) for the distinction between package tests, legacy
tests, build-only checks, and shared consumer validation.
