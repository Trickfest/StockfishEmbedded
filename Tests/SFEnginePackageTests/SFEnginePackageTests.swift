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
import SFEngine
import Testing

@Test
func packageExposesTheExistingEngineAPI() {
    let engine = SFEngine { _ in }
    engine.stop()
}

private final class PackageLineSink: @unchecked Sendable {
    private let condition = NSCondition()
    private var lines: [String] = []

    var lineCount: Int {
        condition.lock()
        defer { condition.unlock() }
        return lines.count
    }

    func allLines() -> [String] {
        condition.lock()
        defer { condition.unlock() }
        return lines
    }

    func append(_ line: String) {
        condition.lock()
        lines.append(line)
        condition.broadcast()
        condition.unlock()
    }

    func removeAll() {
        condition.lock()
        lines.removeAll()
        condition.unlock()
    }

    func wait(
        timeout: TimeInterval,
        after startIndex: Int = 0,
        matching predicate: (String) -> Bool
    ) -> String? {
        let deadline = Date().addingTimeInterval(timeout)

        condition.lock()
        defer { condition.unlock() }

        while true {
            if let line = lines.dropFirst(startIndex).first(where: predicate) {
                return line
            }
            guard condition.wait(until: deadline) else {
                return nil
            }
        }
    }
}

private func localNetwork(named filename: String) -> URL? {
    let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let networkURL = repositoryRoot
        .appendingPathComponent("Resources/NNUE", isDirectory: true)
        .appendingPathComponent(filename)

    return FileManager.default.fileExists(atPath: networkURL.path) ? networkURL : nil
}

private let localNetworkURL = localNetwork(named: SFEngine.defaultNetworkFileName)
// Real networks from the preceding layout and the older PSQT layout are
// stronger migration checks than arbitrary corrupt bytes. These remain
// optional in clean source-only builds; never download them just for a test.
private let previousNetworkURLs = ["nn-252f33942263.nnue", "nn-134a887f4c8f.nnue"]
    .compactMap { localNetwork(named: $0) }

// Instrumenting native NNUE startup with TSan exceeds the normal ten-second
// handshake bound on this Mac. This is a startup safety deadline, not a search
// budget; ordinary Debug/Release runs still complete as soon as ready.
private let packageStartupTimeout: TimeInterval = 60

private final class PackageEngineReference: @unchecked Sendable {
    private let lock = NSLock()
    private weak var engine: SFEngine?

    func set(_ engine: SFEngine) {
        lock.withLock { self.engine = engine }
    }

    func stop() {
        let current = lock.withLock { engine }
        current?.stop()
    }
}

private func negotiate(_ engine: SFEngine, sink: PackageLineSink) throws {
    let startIndex = sink.lineCount
    engine.sendCommand("uci")
    _ = try #require(sink.wait(timeout: packageStartupTimeout, after: startIndex) { $0 == "uciok" },
                     "Startup transcript: \(sink.allLines())")
    let readyIndex = sink.lineCount
    engine.sendCommand("isready")
    _ = try #require(sink.wait(timeout: 10, after: readyIndex) { $0 == "readyok" })
}

@Suite(.serialized)
struct SFEnginePackageRuntimeTests {
    @Test
    func defaultNetworkMatchesVendoredSnapshot() {
        #expect(SFEngine.defaultNetworkFileName == "nn-c9e480e92425.nnue")
    }

    @Test
    func packageBuildRequiresExternalNetworkConfiguration() {
        let sink = PackageLineSink()
        let engine = SFEngine { sink.append($0) }

        engine.start()
        let line = sink.wait(timeout: 2.0) {
            $0.contains("requires initWithNetworkFileURL:lineHandler:")
        }
        engine.stop()

        #expect(line != nil)
    }

    @Test
    func incompatibleNetworkIsRejectedWithoutTerminatingTheProcess() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let invalidNetwork = directory.appendingPathComponent("invalid.nnue")
        try Data("not an NNUE network".utf8).write(to: invalidNetwork)

        let sink = PackageLineSink()
        let engine = SFEngine(networkFileURL: invalidNetwork) { sink.append($0) }

        engine.start()
        let line = sink.wait(timeout: 5.0) {
            $0.contains("incompatible with this Stockfish build")
        }
        engine.stop()

        #expect(line != nil)
    }

    @Test
    func missingExternalFileReportsAnErrorWithoutEnteringUCI() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-network-\(UUID().uuidString).nnue")
        let sink = PackageLineSink()
        let engine = SFEngine(networkFileURL: missing) { sink.append($0) }
        defer { engine.stop() }

        engine.start()
        engine.sendCommand("uci")
        #expect(sink.wait(timeout: 5) {
            $0.hasPrefix("info string StockfishEmbedded error")
        } != nil)
        engine.stop()
        #expect(!sink.allLines().contains("uciok"))
    }

    @Test
    func stopBeforeStartIsTerminalEvenWithoutARuntimeAsset() {
        let sink = PackageLineSink()
        let engine = SFEngine { sink.append($0) }
        engine.stop()
        engine.start()
        engine.sendCommand("uci")
        engine.stop()
        #expect(sink.allLines().isEmpty)
    }

    @Test(.enabled(if: localNetworkURL != nil, "Run Scripts/download-nnue.sh for runtime contract tests"))
    func failedStartupCanBeTornDownBeforeAValidSession() throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-network-\(UUID().uuidString).nnue")
        let rejectedSink = PackageLineSink()
        let rejected = SFEngine(networkFileURL: missing) { rejectedSink.append($0) }
        defer { rejected.stop() }
        rejected.start()
        _ = try #require(rejectedSink.wait(timeout: 5) {
            $0.hasPrefix("info string StockfishEmbedded error")
        })
        rejected.stop()

        let sink = PackageLineSink()
        let valid = SFEngine(networkFileURL: try #require(localNetworkURL)) { sink.append($0) }
        defer { valid.stop() }
        valid.start()
        try negotiate(valid, sink: sink)
    }

    @Test(.enabled(if: localNetworkURL != nil, "Run Scripts/download-nnue.sh for runtime contract tests"))
    func overlappingInstanceIsRejectedThenCanRetry() throws {
        let network = try #require(localNetworkURL)
        let ownerSink = PackageLineSink()
        let owner = SFEngine(networkFileURL: network) { ownerSink.append($0) }
        defer { owner.stop() }
        owner.start()
        try negotiate(owner, sink: ownerSink)

        let contenderSink = PackageLineSink()
        let contender = SFEngine(networkFileURL: network) { contenderSink.append($0) }
        defer { contender.stop() }
        contender.start()
        _ = try #require(contenderSink.wait(timeout: 5) {
            $0 == "info string StockfishEmbedded error: another SFEngine instance is already active"
        })
        #expect(!contenderSink.allLines().contains("uciok"))

        // A rejected start must not disturb the original owner's protocol.
        let readyIndex = ownerSink.lineCount
        owner.sendCommand("isready")
        _ = try #require(ownerSink.wait(timeout: 5, after: readyIndex) { $0 == "readyok" })
        owner.stop()
        contender.start()
        try negotiate(contender, sink: contenderSink)
    }

    @Test(.enabled(if: localNetworkURL != nil, "Run Scripts/download-nnue.sh for runtime contract tests"))
    func callbackInitiatedStopReturnsAndSuppressesLaterOutput() throws {
        let sink = PackageLineSink()
        let reference = PackageEngineReference()
        let engine = SFEngine(networkFileURL: try #require(localNetworkURL)) { line in
            sink.append(line)
            if line == "uciok" {
                reference.stop()
                sink.append("TEST callback stop returned")
            }
        }
        reference.set(engine)
        defer { engine.stop() }
        engine.start()
        engine.sendCommand("uci")
        // Queue further replies behind uciok; none may be delivered after
        // the callback has completed its terminal stop.
        for _ in 0..<20 { engine.sendCommand("isready") }
        _ = try #require(sink.wait(timeout: packageStartupTimeout) { $0 == "TEST callback stop returned" })
        engine.stop()
        #expect(sink.allLines().last == "TEST callback stop returned")
    }

    @Test(.enabled(if: localNetworkURL != nil, "Run Scripts/download-nnue.sh for runtime contract tests"))
    func repeatedReadinessAndTerminalStopRespectLineBoundaries() throws {
        let sink = PackageLineSink()
        let engine = SFEngine(networkFileURL: try #require(localNetworkURL)) { sink.append($0) }
        defer { engine.stop() }
        engine.sendCommand("uci") // Must not be replayed when startup begins.
        engine.start()
        engine.start()
        try negotiate(engine, sink: sink)
        #expect(sink.allLines().filter { $0 == "uciok" }.count == 1)
        for _ in 0..<3 {
            let startIndex = sink.lineCount
            engine.sendCommand("isready")
            _ = try #require(sink.wait(timeout: 5, after: startIndex) { $0 == "readyok" })
        }
        engine.stop()
        engine.stop()
        let stoppedCount = sink.lineCount
        engine.start() // Stockfish stop is terminal; do not infer Arasan's restart policy.
        engine.sendCommand("uci")
        engine.sendCommand("isready")
        engine.stop()
        #expect(sink.lineCount == stoppedCount)
    }

    @Test(.enabled(if: localNetworkURL != nil, "Run Scripts/download-nnue.sh for common position checks"))
    func commonPositionContractIncludesTacticsPromotionMateAndStalemate() throws {
        // BEGIN COMMON ENGINE CONTRACT FIXTURES (CC0-1.0)
        // Independently authored data, not copied from either upstream corpus.
        // Keep these tuples identical in the other embedded engine's tests.
        let cases: [(name: String, fen: String, allowed: Set<String>)] = [
            ("opening-white", "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1",
             Set("a2a3 a2a4 b2b3 b2b4 c2c3 c2c4 d2d3 d2d4 e2e3 e2e4 f2f3 f2f4 g2g3 g2g4 h2h3 h2h4 b1a3 b1c3 g1f3 g1h3".split(separator: " ").map(String.init))),
            ("opening-black", "rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1",
             Set("a7a6 a7a5 b7b6 b7b5 c7c6 c7c5 d7d6 d7d5 e7e6 e7e5 f7f6 f7f5 g7g6 g7g5 h7h6 h7h5 b8a6 b8c6 g8f6 g8h6".split(separator: " ").map(String.init))),
            ("mate-in-one", "7k/8/5KQ1/8/8/8/8/8 w - - 0 1", ["g6g7"]),
            ("promotion-mate", "7k/P7/6K1/8/8/8/8/8 w - - 0 1", ["a7a8q", "a7a8r"]),
            ("checkmate", "7k/6Q1/5K2/8/8/8/8/8 b - - 0 1", []),
            ("stalemate", "7k/5Q2/6K1/8/8/8/8/8 b - - 0 1", []),
        ]
        // END COMMON ENGINE CONTRACT FIXTURES

        let sink = PackageLineSink()
        let engine = SFEngine(networkFileURL: try #require(localNetworkURL)) { sink.append($0) }
        defer { engine.stop() }
        engine.start()
        try negotiate(engine, sink: sink)
        // Search the opening again after both terminal positions to prove recovery.
        for fixture in cases + [cases[0]] {
            let readyIndex = sink.lineCount
            engine.sendCommand("ucinewgame")
            engine.sendCommand("isready")
            _ = try #require(sink.wait(timeout: 5, after: readyIndex) { $0 == "readyok" })
            let startIndex = sink.lineCount
            engine.sendCommand("position fen \(fixture.fen)")
            engine.sendCommand("go depth 6")
            let line = try #require(sink.wait(timeout: 20, after: startIndex) { $0.hasPrefix("bestmove ") })
            let move = try #require(line.split(separator: " ").dropFirst().first).description
            if fixture.allowed.isEmpty {
                #expect(move == "(none)", "\(fixture.name): expected Stockfish's no-move token, got \(line)")
            } else {
                #expect(fixture.allowed.contains(move), "\(fixture.name): unexpected move \(move)")
            }
            #expect(sink.allLines().dropFirst(startIndex).filter { $0.hasPrefix("bestmove ") }.count == 1)
        }
    }

    @Test(
        .enabled(
            if: !previousNetworkURLs.isEmpty,
            "Previous-layout networks are optional local migration fixtures"
        )
    )
    func previousNetworkLayoutIsRejectedWithoutTerminatingTheProcess() throws {
        for networkURL in previousNetworkURLs {
            let sink = PackageLineSink()
            let engine = SFEngine(networkFileURL: networkURL) { sink.append($0) }
            defer { engine.stop() }

            engine.start()
            #expect(sink.wait(timeout: 10.0) {
                $0.contains("incompatible with this Stockfish build")
            } != nil, "Expected rejection of \(networkURL.lastPathComponent)")
        }
    }

    @Test(
        .enabled(
            if: localNetworkURL != nil,
            "Run Scripts/download-nnue.sh to exercise the external-network search"
        )
    )
    func callerProvidedNetworkCompletesSearch() throws {
        let networkURL = try #require(localNetworkURL)
        #expect(networkURL.lastPathComponent == SFEngine.defaultNetworkFileName)

        let sink = PackageLineSink()
        let engine = SFEngine(networkFileURL: networkURL) { sink.append($0) }
        defer { engine.stop() }

        engine.start()
        try negotiate(engine, sink: sink)
        let readyIndex = sink.lineCount
        engine.sendCommand("setoption name EvalFile value /tmp/unvalidated.nnue")
        engine.sendCommand("isready")
        _ = try #require(sink.wait(timeout: 10, after: readyIndex) { $0 == "readyok" })
        engine.sendCommand("position startpos moves e2e4")
        engine.sendCommand("go depth 8")

        let evalFileRejected = sink.wait(timeout: 2.0) {
            $0.contains("EvalFile must be configured with initWithNetworkFileURL:lineHandler:")
        }
        let bestmove = sink.wait(timeout: 20.0) { $0.hasPrefix("bestmove ") }
        let networkLoaded = sink.wait(timeout: 2.0) {
            $0.contains("NNUE evaluation using") && $0.contains(SFEngine.defaultNetworkFileName)
        }
        engine.stop()

        #expect(evalFileRejected != nil)
        #expect(bestmove != nil)
        #expect(networkLoaded != nil)
    }

    @Test(
        .enabled(
            if: localNetworkURL != nil,
            "Run Scripts/download-nnue.sh to exercise suspend/resume with the external network"
        )
    )
    func suspendedEngineResumesWithoutReloadingItsNetwork() throws {
        let networkURL = try #require(localNetworkURL)
        let sink = PackageLineSink()
        let engine = SFEngine(networkFileURL: networkURL) { sink.append($0) }
        defer { engine.stop() }

        engine.start()
        try negotiate(engine, sink: sink)

        engine.sendCommand("position startpos")
        engine.sendCommand("go depth 8")
        #expect(sink.wait(timeout: 10.0) { $0.hasPrefix("bestmove ") } != nil)

        engine.suspend()
        sink.removeAll()
        engine.resume()
        try negotiate(engine, sink: sink)

        let readyIndex = sink.lineCount
        engine.sendCommand("ucinewgame")
        engine.sendCommand("isready")
        _ = try #require(sink.wait(timeout: 5, after: readyIndex) { $0 == "readyok" })
        engine.sendCommand("position startpos moves e2e4")
        engine.sendCommand("go depth 8")
        #expect(sink.wait(timeout: 5.0) { $0.hasPrefix("bestmove ") } != nil)
        engine.stop()
    }
}
