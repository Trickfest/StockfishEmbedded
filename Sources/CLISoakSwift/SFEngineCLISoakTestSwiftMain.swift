import ArgumentParser
import Foundation

/// Command-line soak test runner for the embedded Stockfish engine.
///
/// This CLI is intentionally verbose and opinionated: it exercises the same
/// `SFEngineSoakRunner` used by other test apps, and lets you tune search limits,
/// timeouts, and iteration counts from the command line.
///
/// Usage examples:
/// ```
/// # 1) Finite run at a fixed depth
/// SFEngineCLISoakTestSwift --iterations 100 --depth 10
/// ```
///
/// ```
/// # 2) Time-based searches with a small delay between positions
/// SFEngineCLISoakTestSwift --iterations 200 --movetime 200 --delay-ms 250
/// ```
///
/// ```
/// # 3) Chess960 positions and verbose engine output
/// SFEngineCLISoakTestSwift --chess960 --log-output --iterations 50
/// ```
@main
@available(macOS 26.0, *)
struct SFEngineCLISoakTestSwift: AsyncParsableCommand {
    static var configuration = CommandConfiguration(
        commandName: "SFEngineCLISoakTestSwift",
        abstract: "Long-running soak test for SFEngine.",
        discussion: "Loads FENs from one or more files and repeatedly searches them using the embedded Stockfish engine."
    )

    // MARK: - Arguments & Options
    //
    // All options are optional; defaults are noted below. The only "required"
    // input is that at least one position is loaded (from the default files or
    // explicit paths).

    /// One or more position files (one FEN per line). Defaults to
    /// `Resources/Soak/positions.txt` when empty.
    @Option(
        name: .long,
        parsing: .upToNextOption,
        help: "One or more position files (one FEN per line). Defaults to Resources/Soak/positions.txt."
    )
    var positions: [String] = []

    /// Chess960 positions file. Only used when `--chess960` is enabled.
    @Option(
        name: .customLong("chess960-positions"),
        help: "Chess960 position file (one FEN per line). Requires --chess960. Defaults to Resources/Soak/positions_chess960.txt."
    )
    var chess960Positions: String?

    /// Enable Chess960 mode (passes `setoption name UCI_Chess960 value true`).
    @Flag(
        name: .long,
        help: "Enable Chess960 mode for the soak run."
    )
    var chess960: Bool = false

    /// Search depth limit. Mutually exclusive with `--nodes` and `--movetime`.
    @Option(name: .long, help: "Search depth.")
    var depth: Int?

    /// Node limit. Mutually exclusive with `--depth` and `--movetime`.
    @Option(name: .long, help: "Node limit.")
    var nodes: Int?

    /// Move time in milliseconds. Mutually exclusive with `--depth` and `--nodes`.
    @Option(name: .long, help: "Move time in milliseconds.")
    var movetime: Int?

    /// Maximum number of iterations. If omitted, the soak runs forever.
    @Option(name: .long, help: "Maximum number of iterations.")
    var iterations: Int?

    /// Per-move timeout in seconds (default: 30).
    @Option(name: .long, help: "Per-move timeout in seconds.")
    var timeout: Int = 30

    /// Timeout (seconds) after sending `stop` (default: 5).
    @Option(name: .customLong("stop-timeout"), help: "Timeout after sending stop, in seconds.")
    var stopTimeout: Int = 5

    /// Timeout (seconds) waiting for `uciok` / `readyok` (default: 10).
    @Option(name: .customLong("handshake-timeout"), help: "Timeout waiting for uciok/readyok, in seconds.")
    var handshakeTimeout: Int = 10

    /// Delay between iterations in milliseconds.
    @Option(name: .customLong("delay-ms"), help: "Delay between iterations in milliseconds.")
    var delayMs: Int?

    /// If set, sends `isready` before every iteration.
    @Flag(name: .customLong("ready-each"), help: "Send isready before each iteration.")
    var readyEach: Bool = false

    /// If set, prints all engine output lines (not just bestmove).
    @Flag(name: .customLong("log-output"), help: "Print all engine output lines.")
    var logOutput: Bool = false

    /// If set, the run continues after a timeout rather than stopping.
    @Flag(name: .customLong("continue-on-timeout"), help: "Continue after a timeout instead of stopping.")
    var continueOnTimeout: Bool = false

    // MARK: - Validation

    mutating func validate() throws {
        let providedLimits = [depth != nil, nodes != nil, movetime != nil].filter { $0 }.count
        if providedLimits > 1 {
            throw ValidationError("Choose only one of --depth, --nodes, or --movetime.")
        }
        if chess960Positions != nil && !chess960 {
            throw ValidationError("--chess960-positions requires --chess960.")
        }
    }

    // MARK: - Run

    mutating func run() async throws {
        // Defaults are relative to the repo root (or current working directory).
        let defaultPositionsPath = "Resources/Soak/positions.txt"
        let defaultChess960Path = "Resources/Soak/positions_chess960.txt"

        let positionFiles = positions.isEmpty ? [defaultPositionsPath] : positions
        var specs: [SFEngineSoakRunner.PositionSpec] = []

        // Load all requested FEN files.
        for file in positionFiles {
            specs.append(contentsOf: try loadPositions(from: resolvePath(file)))
        }

        // Optional Chess960 support.
        var engineOptions: [String] = []
        if chess960 {
            engineOptions.append("setoption name UCI_Chess960 value true")
            let chess960File = resolvePath(chess960Positions ?? defaultChess960Path)
            specs.append(contentsOf: try loadPositions(from: chess960File))
        }

        guard !specs.isEmpty else {
            throw ValidationError("No positions were loaded.")
        }

        // Determine the search limit (exactly one is used).
        let searchLimit: SFEngineSoakRunner.SearchLimit
        if let depth {
            searchLimit = .depth(depth)
        } else if let nodes {
            searchLimit = .nodes(nodes)
        } else if let movetime {
            searchLimit = .moveTimeMillis(movetime)
        } else {
            searchLimit = .depth(8)
        }

        let config = SFEngineSoakRunner.Configuration(
            positions: specs,
            searchLimit: searchLimit,
            maxIterations: iterations,
            perMoveTimeout: .seconds(timeout),
            stopTimeout: .seconds(stopTimeout),
            handshakeTimeout: .seconds(handshakeTimeout),
            delayBetweenIterations: delayMs.map { .milliseconds($0) },
            readyCheckEveryIteration: readyEach,
            stopOnTimeoutFailure: !continueOnTimeout,
            engineOptions: engineOptions
        )

        // Run the soak test and emit log lines as events arrive.
        let runner = SFEngineSoakRunner(configuration: config)
        let logOutputEnabled = logOutput

        let summary = await runner.run { event in
            switch event {
            case .started(let configuration):
                print("Starting soak test (positions: \(configuration.positions.count))")
            case .engineOutput(let line):
                if logOutputEnabled {
                    print("uci> \(line)")
                }
            case .iterationStarted(let index, let position):
                print("[#\(index + 1)] \(describe(position))")
            case .iterationCompleted(let index, let bestmove, let elapsed):
                print("[#\(index + 1)] bestmove \(bestmove) in \(formatDuration(elapsed))")
            case .timeout(let index, _, let elapsed):
                fputs("[#\(index + 1)] timeout after \(formatDuration(elapsed))\n", stderr)
            case .error(let message):
                fputs("error: \(message)\n", stderr)
            case .stopped:
                print("Stopped")
            case .finished:
                break
            }
        }

        // Summary output + exit status.
        print("Completed \(summary.iterationsCompleted)/\(summary.iterationsAttempted) iterations")
        print("Timeouts: \(summary.timeouts), Errors: \(summary.errors)")
        print("Elapsed: \(formatDuration(summary.elapsed))")

        if summary.errors > 0 || summary.timeouts > 0 {
            throw ExitCode.failure
        }
    }
}

// MARK: - Helpers

/// Resolve paths relative to the current working directory and the repo root.
/// This keeps defaults working when the binary runs from DerivedData.
private func resolvePath(_ path: String) -> String {
    let expandedPath = (path as NSString).expandingTildeInPath
    if expandedPath.hasPrefix("/") {
        return expandedPath
    }

    let cwdPath = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent(expandedPath)
        .path
    if FileManager.default.fileExists(atPath: cwdPath) {
        return cwdPath
    }

    let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let repoPath = repoRoot.appendingPathComponent(expandedPath).path
    if FileManager.default.fileExists(atPath: repoPath) {
        return repoPath
    }

    return cwdPath
}

/// Load a positions file where each non-empty line is a FEN or `startpos`.
private func loadPositions(from path: String) throws -> [SFEngineSoakRunner.PositionSpec] {
    guard FileManager.default.fileExists(atPath: path) else {
        throw ValidationError("Positions file not found: \(path)")
    }
    let contents = try String(contentsOfFile: path, encoding: .utf8)
    var specs: [SFEngineSoakRunner.PositionSpec] = []

    for rawLine in contents.split(whereSeparator: \.isNewline) {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        if line.isEmpty || line.hasPrefix("#") {
            continue
        }
        if line == "startpos" {
            specs.append(.startpos)
        } else {
            specs.append(.fen(line))
        }
    }

    return specs
}

/// Make long FENs easier to scan in the console output.
private func describe(_ position: SFEngineSoakRunner.PositionSpec) -> String {
    switch position {
    case .startpos:
        return "startpos"
    case .fen(let fen):
        if fen.count > 80 {
            let index = fen.index(fen.startIndex, offsetBy: 77)
            return String(fen[..<index]) + "..."
        }
        return fen
    }
}

/// Format a `Duration` as a simple seconds string.
private func formatDuration(_ duration: Duration) -> String {
    let components = duration.components
    let seconds = Double(components.seconds) + Double(components.attoseconds) / 1e18
    return String(format: "%.3fs", seconds)
}
