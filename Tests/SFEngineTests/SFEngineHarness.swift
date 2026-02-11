import Foundation

final class SFEngineHarness {
    enum Score: Equatable {
        case cp(Int)
        case mate(Int)
    }

    struct SearchResult {
        let bestmove: String
        let transcript: [String]
        let latestScore: Score?
    }

    enum HarnessError: Error, CustomStringConvertible {
        case timedOutWaitingForUCI
        case timedOutWaitingForReady

        var description: String {
            switch self {
            case .timedOutWaitingForUCI:
                return "Timed out waiting for uciok"
            case .timedOutWaitingForReady:
                return "Timed out waiting for readyok"
            }
        }
    }

    private var engine: SFEngine?
    private let lock = NSLock()
    private var lines: [String] = []
    private let lineSignal = DispatchSemaphore(value: 0)

    init() {
        engine = SFEngine { [weak self] line in
            self?.append(line)
        }
    }

    deinit {
        engine?.stop()
    }

    func startAndBootstrap(timeout: TimeInterval = 10.0) throws -> Int {
        engine?.start()

        var cursor = 0
        send("uci")
        guard waitForLine(after: &cursor, timeout: timeout, matching: { $0 == "uciok" }) != nil else {
            throw HarnessError.timedOutWaitingForUCI
        }

        // Keep search behavior deterministic enough for stable assertions.
        send("setoption name Threads value 1")
        send("setoption name Hash value 16")
        send("setoption name MultiPV value 1")
        send("setoption name UCI_Chess960 value false")
        send("setoption name Clear Hash")

        send("isready")
        guard waitForLine(after: &cursor, timeout: timeout, matching: { $0 == "readyok" }) != nil else {
            throw HarnessError.timedOutWaitingForReady
        }

        return cursor
    }

    func stop() {
        engine?.stop()
    }

    func send(_ command: String) {
        engine?.sendCommand(command)
    }

    @discardableResult
    func waitForLine(
        after cursor: inout Int,
        timeout: TimeInterval,
        collecting collector: ((String) -> Void)? = nil,
        matching predicate: (String) -> Bool
    ) -> String? {
        let deadline = Date().addingTimeInterval(timeout)

        while true {
            let pendingLines = consumePending(after: &cursor)
            if !pendingLines.isEmpty {
                for line in pendingLines {
                    collector?(line)
                    if predicate(line) {
                        return line
                    }
                }
            }

            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 {
                return nil
            }

            let waitResult = lineSignal.wait(timeout: .now() + remaining)
            if waitResult == .timedOut {
                return nil
            }
        }
    }

    func runSearch(
        positionCommand: String,
        goCommand: String,
        timeout: TimeInterval,
        cursor: inout Int
    ) -> SearchResult? {
        send(positionCommand)
        send(goCommand)

        var transcript: [String] = []
        guard let bestmoveLine = waitForLine(
            after: &cursor,
            timeout: timeout,
            collecting: { transcript.append($0) },
            matching: { $0.hasPrefix("bestmove ") }
        ) else {
            return nil
        }

        guard let bestmove = Self.parseBestmove(bestmoveLine) else {
            return nil
        }

        return SearchResult(
            bestmove: bestmove,
            transcript: transcript,
            latestScore: Self.latestScore(in: transcript)
        )
    }

    func runPerft(
        positionCommand: String,
        depth: Int,
        timeout: TimeInterval,
        cursor: inout Int
    ) -> Int? {
        send(positionCommand)
        send("go perft \(depth)")

        guard let nodesLine = waitForLine(
            after: &cursor,
            timeout: timeout,
            matching: { $0.hasPrefix("Nodes searched:") }
        ) else {
            return nil
        }

        // Drain any remaining output before the next command sequence.
        send("isready")
        _ = waitForLine(after: &cursor, timeout: timeout, matching: { $0 == "readyok" })

        return Self.parseNodesSearched(nodesLine)
    }

    static func parseBestmove(_ line: String) -> String? {
        let parts = line.split(separator: " ")
        guard parts.count >= 2, parts[0] == "bestmove" else {
            return nil
        }
        return String(parts[1])
    }

    static func parseNodesSearched(_ line: String) -> Int? {
        let valuePart = line.split(separator: " ").last
        guard let valuePart, let value = Int(valuePart) else {
            return nil
        }
        return value
    }

    static func latestScore(in lines: [String]) -> Score? {
        lines.compactMap(parseScore).last
    }

    static func parseScore(_ line: String) -> Score? {
        let parts = line.split(separator: " ")
        guard let scoreIndex = parts.firstIndex(of: "score"), scoreIndex + 2 < parts.count else {
            return nil
        }

        let scoreType = parts[scoreIndex + 1]
        let valueToken = parts[scoreIndex + 2]
        guard let value = Int(valueToken) else {
            return nil
        }

        if scoreType == "cp" {
            return .cp(value)
        }
        if scoreType == "mate" {
            return .mate(value)
        }

        return nil
    }

    private func append(_ line: String) {
        lock.lock()
        lines.append(line)
        lock.unlock()
        lineSignal.signal()
    }

    private func consumePending(after cursor: inout Int) -> [String] {
        lock.lock()
        defer { lock.unlock() }

        guard cursor < lines.count else {
            return []
        }

        let pending = Array(lines[cursor...])
        cursor = lines.count
        return pending
    }
}
