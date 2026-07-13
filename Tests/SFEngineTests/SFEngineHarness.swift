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

final class SFLineMailbox: @unchecked Sendable {
    private let lock = NSLock()
    private var buffered: [String] = []
    private var waiters: [(UUID, CheckedContinuation<String?, Never>)] = []

    func append(_ line: String) {
        lock.lock()
        if !waiters.isEmpty {
            let (_, continuation) = waiters.removeFirst()
            lock.unlock()
            continuation.resume(returning: line)
            return
        }

        buffered.append(line)
        lock.unlock()
    }

    func nextLine() async -> String? {
        let token = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                lock.lock()
                if !buffered.isEmpty {
                    let line = buffered.removeFirst()
                    lock.unlock()
                    continuation.resume(returning: line)
                    return
                }
                if Task.isCancelled {
                    lock.unlock()
                    continuation.resume(returning: nil)
                    return
                }

                waiters.append((token, continuation))
                lock.unlock()
            }
        } onCancel: {
            self.cancelWaiter(token: token)
        }
    }

    private func cancelWaiter(token: UUID) {
        lock.lock()
        guard let index = waiters.firstIndex(where: { $0.0 == token }) else {
            lock.unlock()
            return
        }

        let (_, continuation) = waiters.remove(at: index)
        lock.unlock()
        continuation.resume(returning: nil)
    }
}

final class SFEngineHarness: @unchecked Sendable {
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
    private let lineMailbox = SFLineMailbox()

    init() {
        engine = SFEngine { [weak self] line in
            self?.lineMailbox.append(line)
        }
    }

    deinit {
        engine?.stop()
    }

    func startAndBootstrap(timeout: TimeInterval = 10.0) async throws {
        engine?.start()

        send("uci")
        guard await waitForLine(timeout: timeout, matching: { $0 == "uciok" }) != nil else {
            throw HarnessError.timedOutWaitingForUCI
        }

        // Keep search behavior deterministic enough for stable assertions.
        send("setoption name Threads value 1")
        send("setoption name Hash value 16")
        send("setoption name MultiPV value 1")
        send("setoption name UCI_Chess960 value false")
        send("setoption name Clear Hash")

        send("isready")
        guard await waitForLine(timeout: timeout, matching: { $0 == "readyok" }) != nil else {
            throw HarnessError.timedOutWaitingForReady
        }
    }

    func stop() {
        engine?.stop()
    }

    func send(_ command: String) {
        engine?.sendCommand(command)
    }

    @discardableResult
    func waitForLine(
        timeout: TimeInterval,
        collecting collector: ((String) -> Void)? = nil,
        matching predicate: (String) -> Bool
    ) async -> String? {
        let deadline = Date().addingTimeInterval(timeout)

        while true {
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 {
                return nil
            }

            guard let line = await nextLine(timeout: remaining) else {
                return nil
            }

            collector?(line)
            if predicate(line) {
                return line
            }
        }
    }

    func runSearch(
        positionCommand: String,
        goCommand: String,
        timeout: TimeInterval
    ) async -> SearchResult? {
        send(positionCommand)
        send(goCommand)

        var transcript: [String] = []
        guard let bestmoveLine = await waitForLine(
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
        timeout: TimeInterval
    ) async -> Int? {
        send(positionCommand)
        send("go perft \(depth)")

        guard let nodesLine = await waitForLine(
            timeout: timeout,
            matching: { $0.hasPrefix("Nodes searched:") }
        ) else {
            return nil
        }

        // Drain any remaining output before the next command sequence.
        send("isready")
        _ = await waitForLine(timeout: timeout, matching: { $0 == "readyok" })

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

    private func nextLine(timeout: TimeInterval) async -> String? {
        let clampedTimeout = max(0, timeout)
        if clampedTimeout == 0 {
            return nil
        }

        let timeoutNanoseconds = UInt64(clampedTimeout * 1_000_000_000)
        return await withTaskGroup(of: String?.self) { group in
            group.addTask {
                await self.lineMailbox.nextLine()
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                return nil
            }

            let firstResult = await group.next() ?? nil
            group.cancelAll()
            if let firstResult {
                return firstResult
            }
            while let trailingResult = await group.next() {
                if let trailingResult {
                    return trailingResult
                }
            }
            return nil
        }
    }
}
