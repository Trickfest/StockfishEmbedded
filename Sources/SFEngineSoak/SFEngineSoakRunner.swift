import Foundation

/// Runs a long-lived "soak" session against the embedded Stockfish engine.
///
/// This type is also a practical example of how to drive `SFEngine` from Swift:
/// - start the engine
/// - send `uci`, wait for `uciok`
/// - send any `setoption` commands
/// - send `isready`, wait for `readyok`
/// - for each position: `position ...` + `go ...`, wait for `bestmove`
/// - stop / quit on shutdown
///
/// Usage examples:
/// ```
/// // 1) Small finite run at a fixed depth
/// let config = SFEngineSoakRunner.Configuration(
///     positions: [.startpos],
///     searchLimit: .depth(8),
///     maxIterations: 10
/// )
/// let runner = SFEngineSoakRunner(configuration: config)
/// let summary = await runner.run { event in
///     if case let .iterationCompleted(_, bestmove, elapsed) = event {
///         print("bestmove \(bestmove) in \(elapsed)")
///     }
/// }
/// print(summary)
/// ```
///
/// ```
/// // 2) Time-based searches with a delay between iterations
/// let config = SFEngineSoakRunner.Configuration(
///     positions: [.fen("rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1")],
///     searchLimit: .moveTimeMillis(200),
///     maxIterations: 50,
///     delayBetweenIterations: .milliseconds(250)
/// )
/// let runner = SFEngineSoakRunner(configuration: config)
/// _ = await runner.run { _ in }
/// ```
///
/// ```
/// // 3) Chess960 + options (setoption commands)
/// let config = SFEngineSoakRunner.Configuration(
///     positions: [.fen("bbrqknnr/pppppppp/8/8/8/8/PPPPPPPP/BBRQKNNR w KQkq - 0 1")],
///     searchLimit: .nodes(10_000),
///     maxIterations: 20,
///     engineOptions: [
///         "setoption name UCI_Chess960 value true",
///         "setoption name Threads value 2"
///     ]
/// )
/// let runner = SFEngineSoakRunner(configuration: config)
/// _ = await runner.run { event in
///     if case let .error(message) = event {
///         print("error: \(message)")
///     }
/// }
/// ```
public final class SFEngineSoakRunner {
    private final class State: @unchecked Sendable {
        private let queue = DispatchQueue(label: "SFEngineSoakRunner.State")
        private var engine: SFEngine?
        private var stopRequested = false

        func start(engine: SFEngine) {
            queue.sync {
                self.engine = engine
                stopRequested = false
            }
        }

        func requestStop() -> SFEngine? {
            queue.sync {
                stopRequested = true
                return engine
            }
        }

        func clearEngine() {
            queue.sync {
                engine = nil
            }
        }

        func shouldStop() -> Bool {
            queue.sync { stopRequested }
        }
    }

    /// A position to analyze, expressed as a UCI `position` command.
    ///
    /// Use `.startpos` for the standard chess starting position, or `.fen`
    /// for explicit FEN strings.
    public enum PositionSpec: Equatable {
        case startpos
        case fen(String)

        var uciCommand: String {
            switch self {
            case .startpos:
                return "position startpos"
            case .fen(let fen):
                return "position fen \(fen)"
            }
        }
    }

    /// A single UCI search limit for each iteration.
    ///
    /// Only one limit should be used per run (depth, nodes, or movetime).
    public enum SearchLimit: Equatable {
        case depth(Int)
        case nodes(Int)
        case moveTimeMillis(Int)

        var uciCommand: String {
            switch self {
            case .depth(let depth):
                return "go depth \(depth)"
            case .nodes(let nodes):
                return "go nodes \(nodes)"
            case .moveTimeMillis(let ms):
                return "go movetime \(ms)"
            }
        }
    }

    /// Configuration for a soak run.
    ///
    /// Required:
    /// - `positions`: non-empty list of positions to loop over.
    ///
    /// Optional (defaults shown):
    /// - `searchLimit`: `.depth(8)`
    /// - `maxIterations`: `nil` (run forever)
    /// - `perMoveTimeout`: 30s (wait for `bestmove`)
    /// - `stopTimeout`: 5s (wait for `bestmove` after `stop`)
    /// - `handshakeTimeout`: 10s (wait for `uciok` / `readyok`)
    /// - `delayBetweenIterations`: `nil` (no delay)
    /// - `readyCheckEveryIteration`: `false` (skip per-iteration `isready`)
    /// - `stopOnTimeoutFailure`: `true` (treat timeout-after-stop as error)
    /// - `engineOptions`: `[]` (UCI commands like `setoption name ...`)
    public struct Configuration: Equatable {
        public var positions: [PositionSpec]
        public var searchLimit: SearchLimit
        public var maxIterations: Int?
        public var perMoveTimeout: Duration
        public var stopTimeout: Duration
        public var handshakeTimeout: Duration
        public var delayBetweenIterations: Duration?
        public var readyCheckEveryIteration: Bool
        public var stopOnTimeoutFailure: Bool
        public var engineOptions: [String]

        /// Creates a configuration. `positions` must be non-empty.
        ///
        /// `engineOptions` entries are sent after `uciok` and before the first
        /// `isready` (typical usage: `setoption name Threads value 2`).
        public init(
            positions: [PositionSpec],
            searchLimit: SearchLimit = .depth(8),
            maxIterations: Int? = nil,
            perMoveTimeout: Duration = .seconds(30),
            stopTimeout: Duration = .seconds(5),
            handshakeTimeout: Duration = .seconds(10),
            delayBetweenIterations: Duration? = nil,
            readyCheckEveryIteration: Bool = false,
            stopOnTimeoutFailure: Bool = true,
            engineOptions: [String] = []
        ) {
            self.positions = positions
            self.searchLimit = searchLimit
            self.maxIterations = maxIterations
            self.perMoveTimeout = perMoveTimeout
            self.stopTimeout = stopTimeout
            self.handshakeTimeout = handshakeTimeout
            self.delayBetweenIterations = delayBetweenIterations
            self.readyCheckEveryIteration = readyCheckEveryIteration
            self.stopOnTimeoutFailure = stopOnTimeoutFailure
            self.engineOptions = engineOptions
        }
    }

    /// Summary counters for the run. `elapsed` is set when the run finishes.
    public struct Summary: Equatable {
        public var iterationsAttempted: Int
        public var iterationsCompleted: Int
        public var timeouts: Int
        public var errors: Int
        public var elapsed: Duration
    }

    /// Emitted events in the order they occur during a run.
    ///
    /// `engineOutput` forwards raw UCI output lines.
    /// `iterationCompleted` / `timeout` include per-iteration elapsed time.
    public enum Event: Equatable {
        case started(Configuration)
        case engineOutput(String)
        case iterationStarted(index: Int, position: PositionSpec)
        case iterationCompleted(index: Int, bestmove: String, elapsed: Duration)
        case timeout(index: Int, position: PositionSpec, elapsed: Duration)
        case stopped
        case error(String)
        case finished(Summary)
    }

    private let configuration: Configuration
    private let state = State()

    /// Creates a runner for the given configuration.
    public init(configuration: Configuration) {
        self.configuration = configuration
    }

    /// Requests a stop. Safe to call from any thread.
    /// Sends `stop` then shuts the engine down.
    public func stop() {
        let engineToStop = state.requestStop()

        engineToStop?.sendCommand("stop")
        engineToStop?.stop()
    }

    /// Runs the soak loop and returns a summary when it finishes.
    ///
    /// `eventHandler` receives events as they happen. It may be called from
    /// background contexts; avoid touching UI directly in the handler.
    public func run(eventHandler: @escaping @Sendable (Event) -> Void) async -> Summary {
        let clock = ContinuousClock()
        let start = clock.now

        // Positions are required; stop immediately with an error if missing.
        guard !configuration.positions.isEmpty else {
            var summary = Summary(iterationsAttempted: 0,
                                  iterationsCompleted: 0,
                                  timeouts: 0,
                                  errors: 1,
                                  elapsed: .zero)
            summary.elapsed = clock.now - start
            eventHandler(.error("No positions provided"))
            eventHandler(.finished(summary))
            return summary
        }

        eventHandler(.started(configuration))

        // Marshal the engine's line callback into an async stream.
        let lineQueue = LineQueue()

        // Create the engine and enqueue each output line.
        let engine = SFEngine(lineHandler: { line in
            Task {
                await lineQueue.push(line)
            }
        })

        state.start(engine: engine)

        engine.start()

        var summary = Summary(iterationsAttempted: 0,
                              iterationsCompleted: 0,
                              timeouts: 0,
                              errors: 0,
                              elapsed: .zero)

        // Always shut the engine down and emit a final summary.
        defer {
            engine.stop()
            Task {
                await lineQueue.finish()
            }
            state.clearEngine()
            eventHandler(.finished(summary))
        }

        // Compute elapsed at the end so the returned summary and .finished match.
        func finalizeSummary() -> Summary {
            summary.elapsed = clock.now - start
            return summary
        }

        let shouldStop: @Sendable () -> Bool = {
            if Task.isCancelled { return true }
            return self.state.shouldStop()
        }

        // Pull one line at a time, forwarding raw output events.
        @Sendable func nextLine() async -> String? {
            while !shouldStop() {
                guard let line = await lineQueue.next() else {
                    return nil
                }
                eventHandler(.engineOutput(line))
                return line
            }
            return nil
        }

        // Wait for a specific UCI prefix or time out.
        func waitForPrefix(_ prefix: String, timeout: Duration) async -> String? {
            await withTimeout(timeout) {
                while let line = await nextLine() {
                    if line.hasPrefix(prefix) {
                        return line
                    }
                }
                return nil
            }
        }

        // Handshake: `uci` -> `uciok`, then apply options, then `isready`.
        engine.sendCommand("uci")
        guard await waitForPrefix("uciok", timeout: configuration.handshakeTimeout) != nil else {
            summary.errors += 1
            eventHandler(.error("Timed out waiting for uciok"))
            return finalizeSummary()
        }

        for option in configuration.engineOptions where !option.isEmpty {
            engine.sendCommand(option)
        }

        engine.sendCommand("isready")
        guard await waitForPrefix("readyok", timeout: configuration.handshakeTimeout) != nil else {
            summary.errors += 1
            eventHandler(.error("Timed out waiting for readyok"))
            return finalizeSummary()
        }

        // Main loop: issue `position` + `go`, wait for `bestmove`, repeat.
        var index = 0
        while !shouldStop() {
            if let maxIterations = configuration.maxIterations,
               index >= maxIterations {
                break
            }

            let position = configuration.positions[index % configuration.positions.count]
            eventHandler(.iterationStarted(index: index, position: position))

            if configuration.readyCheckEveryIteration {
                engine.sendCommand("isready")
                let ready = await waitForPrefix("readyok", timeout: configuration.handshakeTimeout)
                if ready == nil {
                    summary.errors += 1
                    eventHandler(.error("Timed out waiting for readyok"))
                    break
                }
            }

            engine.sendCommand(position.uciCommand)
            engine.sendCommand(configuration.searchLimit.uciCommand)

            summary.iterationsAttempted += 1
            let iterStart = clock.now
            let bestmove = await waitForPrefix("bestmove", timeout: configuration.perMoveTimeout)

            if let bestmove {
                summary.iterationsCompleted += 1
                eventHandler(.iterationCompleted(index: index,
                                                 bestmove: bestmove,
                                                 elapsed: clock.now - iterStart))
            } else {
                summary.timeouts += 1
                eventHandler(.timeout(index: index,
                                      position: position,
                                      elapsed: clock.now - iterStart))

                engine.sendCommand("stop")
                let stopped = await waitForPrefix("bestmove", timeout: configuration.stopTimeout)
                if stopped == nil && configuration.stopOnTimeoutFailure {
                    eventHandler(.error("Timed out waiting for bestmove after stop"))
                    break
                }
            }

            index += 1

            if let delay = configuration.delayBetweenIterations {
                try? await Task.sleep(for: delay)
            }
        }

        if shouldStop() {
            eventHandler(.stopped)
        }

        return finalizeSummary()
    }
}

/// Actor-backed line buffer to bridge the engine callback to async consumers.
private actor LineQueue {
    private struct Waiter {
        let id: Int
        let continuation: CheckedContinuation<String?, Never>
    }

    private var buffer: [String] = []
    private var waiters: [Waiter] = []
    private var nextWaiterID = 0
    private var finished = false

    func push(_ line: String) {
        guard !finished else { return }
        if !waiters.isEmpty {
            let waiter = waiters.removeFirst()
            waiter.continuation.resume(returning: line)
        } else {
            buffer.append(line)
        }
    }

    func next() async -> String? {
        if !buffer.isEmpty {
            return buffer.removeFirst()
        }
        if finished {
            return nil
        }

        let id = nextWaiterID
        nextWaiterID += 1

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                waiters.append(Waiter(id: id, continuation: continuation))
            }
        } onCancel: {
            Task {
                await self.cancelWaiter(id: id)
            }
        }
    }

    func finish() {
        guard !finished else { return }
        finished = true
        for waiter in waiters {
            waiter.continuation.resume(returning: nil)
        }
        waiters.removeAll()
        buffer.removeAll()
    }

    private func cancelWaiter(id: Int) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else {
            return
        }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(returning: nil)
    }
}

// Runs an async operation with a timeout; returns `nil` on timeout.
private func withTimeout<T>(
    _ timeout: Duration,
    operation: @escaping @Sendable () async -> T?
) async -> T? {
    await withTaskGroup(of: T?.self) { group in
        group.addTask {
            await operation()
        }
        group.addTask {
            try? await Task.sleep(for: timeout)
            return nil
        }
        let result = await group.next() ?? nil
        group.cancelAll()
        return result
    }
}
