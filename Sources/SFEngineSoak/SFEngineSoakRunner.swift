//
// StockfishEmbedded embeds Stockfish as an in-process engine for Apple platforms.
//
// See README.md and ThirdParty/Stockfish/Copying.txt for upstream attribution and license details.
//
// Licensed under the GNU General Public License v3.0.
// You may obtain a copy of the License at: https://www.gnu.org/licenses/gpl-3.0.html
// See the LICENSE file for more information.
//

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
public final class SFEngineSoakRunner: @unchecked Sendable {
    private final class State: @unchecked Sendable {
        struct StopTargets {
            let engine: SFEngine?
            let lineQueue: LineQueue?
        }

        private let queue = DispatchQueue(label: "SFEngineSoakRunner.State")
        private var engine: SFEngine?
        private var lineQueue: LineQueue?
        private var stopRequested = false

        func start(engine: SFEngine, lineQueue: LineQueue) -> Bool {
            queue.sync {
                guard self.engine == nil else { return false }
                self.engine = engine
                self.lineQueue = lineQueue
                stopRequested = false
                return true
            }
        }

        func requestStop() -> StopTargets {
            queue.sync {
                stopRequested = true
                return StopTargets(engine: engine, lineQueue: lineQueue)
            }
        }

        func clearEngine() {
            queue.sync {
                engine = nil
                lineQueue = nil
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
    public enum PositionSpec: Equatable, Sendable {
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
    public enum SearchLimit: Equatable, Sendable {
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
    /// - `engineOptions`: `[]` (UCI commands like `setoption name ...`)
    public struct Configuration: Equatable, Sendable {
        public var positions: [PositionSpec]
        public var searchLimit: SearchLimit
        public var maxIterations: Int?
        public var perMoveTimeout: Duration
        public var stopTimeout: Duration
        public var handshakeTimeout: Duration
        public var delayBetweenIterations: Duration?
        public var readyCheckEveryIteration: Bool
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
            self.engineOptions = engineOptions
        }

        var validationError: String? {
            guard !positions.isEmpty else { return "No positions provided" }
            guard positions.allSatisfy(\.isValid) else {
                return "Every position must be startpos or a plausible four/six-field FEN with optional UCI moves"
            }

            switch searchLimit {
            case .depth(let value) where value <= 0:
                return "Search depth must be greater than zero"
            case .nodes(let value) where value <= 0:
                return "Node limit must be greater than zero"
            case .moveTimeMillis(let value) where value <= 0:
                return "Move time must be greater than zero"
            default:
                break
            }

            if let maxIterations, maxIterations <= 0 {
                return "Maximum iterations must be greater than zero"
            }
            guard perMoveTimeout > .zero else { return "Per-move timeout must be greater than zero" }
            guard stopTimeout > .zero else { return "Stop timeout must be greater than zero" }
            guard handshakeTimeout > .zero else { return "Handshake timeout must be greater than zero" }
            if let delayBetweenIterations, delayBetweenIterations < .zero {
                return "Delay between iterations cannot be negative"
            }
            return nil
        }
    }

    /// Summary counters for the run. `elapsed` is set when the run finishes.
    public struct Summary: Equatable, Sendable {
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
    public enum Event: Equatable, Sendable {
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
        let targets = state.requestStop()
        targets.lineQueue?.finish()
        targets.engine?.stop()
    }

    /// Runs the soak loop and returns a summary when it finishes.
    ///
    /// `eventHandler` receives events as they happen. It may be called from
    /// background contexts; avoid touching UI directly in the handler.
    public func run(eventHandler: @escaping @Sendable (Event) -> Void) async -> Summary {
        let clock = ContinuousClock()
        let start = clock.now

        // Reject invalid configuration before creating native engine state.
        if let validationError = configuration.validationError {
            var summary = Summary(iterationsAttempted: 0,
                                  iterationsCompleted: 0,
                                  timeouts: 0,
                                  errors: 1,
                                  elapsed: .zero)
            summary.elapsed = clock.now - start
            eventHandler(.error(validationError))
            eventHandler(.finished(summary))
            return summary
        }

        // Marshal the engine's line callback into an async stream.
        let lineQueue = LineQueue()

        // Create the engine and enqueue each output line.
        let engine = SFEngine(lineHandler: { line in
            lineQueue.push(line)
        })

        guard state.start(engine: engine, lineQueue: lineQueue) else {
            let summary = Summary(iterationsAttempted: 0,
                                  iterationsCompleted: 0,
                                  timeouts: 0,
                                  errors: 1,
                                  elapsed: clock.now - start)
            eventHandler(.error("This soak runner is already running"))
            eventHandler(.finished(summary))
            lineQueue.finish()
            return summary
        }

        engine.start()
        eventHandler(.started(configuration))

        var summary = Summary(iterationsAttempted: 0,
                              iterationsCompleted: 0,
                              timeouts: 0,
                              errors: 0,
                              elapsed: .zero)

        // Always shut the engine down and emit a final summary.
        defer {
            engine.stop()
            lineQueue.finish()
            state.clearEngine()
            eventHandler(.finished(summary))
        }

        // Compute elapsed at the end so the returned summary and .finished match.
        func finalizeSummary() -> Summary {
            summary.elapsed = clock.now - start
            return summary
        }

        let state = self.state
        let shouldStop: @Sendable () -> Bool = {
            if Task.isCancelled { return true }
            return state.shouldStop()
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
            if shouldStop() {
                eventHandler(.stopped)
                return finalizeSummary()
            }
            summary.errors += 1
            eventHandler(.error("Timed out waiting for uciok"))
            return finalizeSummary()
        }

        for option in configuration.engineOptions where !option.isEmpty {
            engine.sendCommand(option)
        }

        engine.sendCommand("isready")
        guard await waitForPrefix("readyok", timeout: configuration.handshakeTimeout) != nil else {
            if shouldStop() {
                eventHandler(.stopped)
                return finalizeSummary()
            }
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
            if shouldStop() { break }

            if configuration.readyCheckEveryIteration {
                engine.sendCommand("isready")
                let ready = await waitForPrefix("readyok", timeout: configuration.handshakeTimeout)
                if ready == nil {
                    if shouldStop() { break }
                    summary.errors += 1
                    eventHandler(.error("Timed out waiting for readyok"))
                    break
                }
            }

            engine.sendCommand(position.uciCommand)
            engine.sendCommand(configuration.searchLimit.uciCommand)

            summary.iterationsAttempted += 1
            let iterStart = clock.now
            let bestmoveLine = await waitForPrefix("bestmove", timeout: configuration.perMoveTimeout)

            if let bestmoveLine {
                guard let bestmove = parseBestmove(bestmoveLine) else {
                    summary.errors += 1
                    eventHandler(.error("Received malformed bestmove"))
                    break
                }
                summary.iterationsCompleted += 1
                eventHandler(.iterationCompleted(index: index,
                                                  bestmove: bestmove,
                                                  elapsed: clock.now - iterStart))
            } else if shouldStop() {
                break
            } else {
                summary.timeouts += 1
                eventHandler(.timeout(index: index,
                                      position: position,
                                      elapsed: clock.now - iterStart))

                engine.sendCommand("stop")
                let stopped = await waitForPrefix("bestmove", timeout: configuration.stopTimeout)
                if stopped == nil {
                    if shouldStop() {
                        break
                    }
                    summary.errors += 1
                    eventHandler(.error("Timed out waiting for bestmove after stop"))
                    break
                }
                if stopped.flatMap(parseBestmove) == nil {
                    summary.errors += 1
                    eventHandler(.error("Received malformed bestmove after stop"))
                    break
                }
            }

            index += 1

            if let delay = configuration.delayBetweenIterations {
                let deadline = clock.now.advanced(by: delay)
                while !shouldStop() {
                    let remaining = clock.now.duration(to: deadline)
                    if remaining <= .zero { break }
                    try? await Task.sleep(for: min(remaining, .milliseconds(50)))
                }
            }
        }

        if shouldStop() {
            eventHandler(.stopped)
        }

        return finalizeSummary()
    }
}

/// Lock-backed ordered line buffer to bridge the serial engine callback to async consumers.
private final class LineQueue: @unchecked Sendable {
    private struct Waiter {
        let id: Int
        let continuation: CheckedContinuation<String?, Never>
    }

    private var buffer: [String] = []
    private var waiters: [Waiter] = []
    private var nextWaiterID = 0
    private var finished = false
    private let lock = NSLock()

    func push(_ line: String) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        if !waiters.isEmpty {
            let waiter = waiters.removeFirst()
            lock.unlock()
            waiter.continuation.resume(returning: line)
        } else {
            buffer.append(line)
            lock.unlock()
        }
    }

    func next() async -> String? {
        let id = allocateWaiterID()

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                lock.lock()
                if !buffer.isEmpty {
                    let line = buffer.removeFirst()
                    lock.unlock()
                    continuation.resume(returning: line)
                    return
                }
                if finished || Task.isCancelled {
                    lock.unlock()
                    continuation.resume(returning: nil)
                    return
                }

                waiters.append(Waiter(id: id, continuation: continuation))
                lock.unlock()
            }
        } onCancel: {
            self.cancelWaiter(id: id)
        }
    }

    private func allocateWaiterID() -> Int {
        lock.lock()
        defer { lock.unlock() }
        let id = nextWaiterID
        nextWaiterID += 1
        return id
    }

    func finish() {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        let continuations = waiters.map(\.continuation)
        waiters.removeAll()
        buffer.removeAll()
        lock.unlock()

        for continuation in continuations {
            continuation.resume(returning: nil)
        }
    }

    private func cancelWaiter(id: Int) {
        lock.lock()
        guard let index = waiters.firstIndex(where: { $0.id == id }) else {
            lock.unlock()
            return
        }
        let waiter = waiters.remove(at: index)
        lock.unlock()
        waiter.continuation.resume(returning: nil)
    }
}

// Runs an async operation with a timeout; returns `nil` on timeout.
private func withTimeout<T: Sendable>(
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
        let firstResult = await group.next() ?? nil
        group.cancelAll()
        if let firstResult {
            return firstResult
        }

        // If the timeout task won just as the line waiter consumed a line,
        // preserve that line instead of discarding the terminal engine output.
        while let trailingResult = await group.next() {
            if let trailingResult {
                return trailingResult
            }
        }
        return nil
    }
}

private func parseBestmove(_ line: String) -> String? {
    let parts = line.split(separator: " ")
    guard parts.count >= 2, parts[0] == "bestmove" else { return nil }

    let move = String(parts[1])
    guard move.range(of: #"^(?:[a-h][1-8][a-h][1-8][nbrq]?|0000|\(none\))$"#,
                     options: .regularExpression) != nil else {
        return nil
    }
    return move
}

func isValidFENWithOptionalMoves(_ value: String) -> Bool {
    let tokens = value.split(whereSeparator: \Character.isWhitespace).map(String.init)
    guard !tokens.isEmpty else { return false }

    let movesIndex = tokens.firstIndex(of: "moves") ?? tokens.endIndex
    let fen = Array(tokens[..<movesIndex])
    guard fen.count == 4 || fen.count == 6 else { return false }
    let ranks = fen[0].split(separator: "/", omittingEmptySubsequences: false)
    guard ranks.count == 8 else { return false }
    for rank in ranks {
        var squares = 0
        for character in rank {
            if let asciiValue = character.asciiValue, (49...56).contains(asciiValue) {
                squares += Int(asciiValue - 48)
            } else {
                guard "prnbqkPRNBQK".contains(character) else { return false }
                squares += 1
            }
        }
        guard squares == 8 else { return false }
    }
    guard fen[1] == "w" || fen[1] == "b" else { return false }
    guard fen[2] == "-" || fen[2].allSatisfy({ "KQkqABCDEFGHabcdefgh".contains($0) }) else {
        return false
    }
    guard fen[3] == "-" || fen[3].range(of: #"^[a-h][36]$"#, options: .regularExpression) != nil else {
        return false
    }
    if fen.count == 6 {
        guard let halfmove = Int(fen[4]), halfmove >= 0,
              let fullmove = Int(fen[5]), fullmove >= 1 else {
            return false
        }
    }

    if movesIndex < tokens.endIndex {
        let moves = tokens[(movesIndex + 1)...]
        guard !moves.isEmpty else { return false }
        guard moves.allSatisfy({
            $0.range(of: #"^[a-h][1-8][a-h][1-8][nbrq]?$"#, options: .regularExpression) != nil
        }) else {
            return false
        }
    }
    return true
}

private extension SFEngineSoakRunner.PositionSpec {
    var isValid: Bool {
        switch self {
        case .startpos:
            return true
        case .fen(let value):
            return isValidFENWithOptionalMoves(value)
        }
    }
}
