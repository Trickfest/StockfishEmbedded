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
import XCTest

private final class SFEngineHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var engine: SFEngine?

    func store(_ engine: SFEngine) {
        lock.lock()
        self.engine = engine
        lock.unlock()
    }

    func stop() {
        lock.lock()
        let engine = engine
        lock.unlock()
        engine?.stop()
    }

    func start() {
        lock.lock()
        let engine = engine
        lock.unlock()
        engine?.start()
    }
}

private final class CallbackCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() -> Int {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        return count
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

final class SFEngineTests: XCTestCase {
    private struct PerftCase {
        let name: String
        let positionCommand: String
        let depth: Int
        let expectedNodes: Int
    }

    private enum ScoreExpectation {
        case atLeast(Int)
        case atMost(Int)
        case nearZero(Int)
    }

    private struct ScoreCase {
        let name: String
        let positionCommand: String
        let goCommand: String
        let expectation: ScoreExpectation
    }

    private struct TacticalCase {
        let name: String
        let positionCommand: String
        let goCommand: String
        let expectedBestmoves: Set<String>
    }

    private static let validBestmoveRegex = try! NSRegularExpression(
        pattern: "^(?:[a-h][1-8][a-h][1-8][nbrq]?|0000|\\(none\\))$",
        options: []
    )

    private var harness: SFEngineHarness!

    override func setUp() async throws {
        try await super.setUp()
        harness = SFEngineHarness()
        try await harness.startAndBootstrap(timeout: 10.0)
    }

    override func tearDown() async throws {
        harness?.stop()
        harness = nil
        try await super.tearDown()
    }

    // Step 1: wrapper contract tests.

    func testContractReadyProbeReturnsReadyOK() async {
        harness.send("isready")

        let line = await harness.waitForLine(timeout: 5.0, matching: { $0 == "readyok" })
        XCTAssertEqual(line, "readyok")
    }

    func testContractBestmoveHasValidUCISyntax() async {
        guard let result = await harness.runSearch(
            positionCommand: "position startpos",
            goCommand: "go movetime 250",
            timeout: 10.0
        ) else {
            XCTFail("Expected bestmove within timeout")
            return
        }

        XCTAssertTrue(Self.isValidBestmoveToken(result.bestmove), "Unexpected bestmove token: \(result.bestmove)")
    }

    func testContractStartAndStopAreIdempotent() {
        harness.stop()
        let engine = SFEngine(lineHandler: { _ in })

        engine.start()
        engine.start()
        engine.stop()
        engine.stop()
    }

    func testContractDefaultInitializerSafelyDiscardsOutput() {
        harness.stop()
        let engine = SFEngine()

        engine.start()
        engine.sendCommand("uci")
        engine.stop()
    }

    func testContractStopBeforeStartIsTerminal() async {
        harness.stop()
        let output = expectation(description: "stopped engine must not start")
        output.isInverted = true
        let engine = SFEngine(lineHandler: { _ in output.fulfill() })

        engine.stop()
        engine.start()
        engine.sendCommand("uci")

        await fulfillment(of: [output], timeout: 0.25)
        engine.stop()
    }

    func testContractSendCommandBeforeStartIsIgnoredSafely() async {
        harness.stop()
        let uciok = expectation(description: "uciok")
        let engine = SFEngine(lineHandler: { line in
            if line == "uciok" {
                Task { @MainActor in
                    uciok.fulfill()
                }
            }
        })

        // Should be ignored before start and never crash.
        engine.sendCommand("uci")
        engine.sendCommand("isready")
        engine.sendCommand("")

        engine.start()
        engine.sendCommand("uci")
        await fulfillment(of: [uciok], timeout: 5.0)
        engine.stop()
    }

    func testContractReleaseWithoutExplicitStopTearsDownEngine() {
        harness.stop()

        weak var releasedEngine: SFEngine?
        autoreleasepool {
            let engine = SFEngine(lineHandler: { _ in })
            releasedEngine = engine
            engine.start()
            engine.sendCommand("uci")
        }

        XCTAssertNil(releasedEngine, "A running engine must not retain its Objective-C owner")
    }

    func testContractStopIsSafeFromLineHandler() async {
        harness.stop()
        let callbackStopped = expectation(description: "callback_stop_returned")
        let engineHolder = SFEngineHolder()

        let engine = SFEngine(lineHandler: { line in
            guard line == "uciok" else { return }
            engineHolder.stop()
            callbackStopped.fulfill()
        })
        engineHolder.store(engine)

        engine.start()
        engine.sendCommand("uci")
        await fulfillment(of: [callbackStopped], timeout: 5.0)
        engine.stop()
    }

    func testContractCallbackStopSuppressesAlreadyQueuedOutput() async {
        harness.stop()
        let firstCallbackStarted = expectation(description: "first callback started")
        let allowCallbackToStop = DispatchSemaphore(value: 0)
        let callbackStopReturned = expectation(description: "callback stop returned")
        let engineHolder = SFEngineHolder()
        let callbackCounter = CallbackCounter()

        let engine = SFEngine(lineHandler: { _ in
            guard callbackCounter.increment() == 1 else { return }
            firstCallbackStarted.fulfill()
            _ = allowCallbackToStop.wait(timeout: .now() + 5)
            engineHolder.stop()
            callbackStopReturned.fulfill()
        })
        engineHolder.store(engine)

        engine.start()
        await fulfillment(of: [firstCallbackStarted], timeout: 5.0)
        engine.sendCommand("uci")
        try? await Task.sleep(for: .milliseconds(250))
        allowCallbackToStop.signal()

        await fulfillment(of: [callbackStopReturned], timeout: 5.0)
        try? await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(callbackCounter.value, 1)
        engine.stop()
    }

    func testContractConcurrentInstanceIsRejectedAndCanRetryLater() async {
        let rejected = expectation(description: "second_instance_rejected")
        let retryStarted = expectation(description: "second_instance_retry_started")
        let contender = SFEngine(lineHandler: { line in
            if line == "info string StockfishEmbedded error: another SFEngine instance is already active" {
                rejected.fulfill()
            } else if line == "uciok" {
                retryStarted.fulfill()
            }
        })

        contender.start()
        await fulfillment(of: [rejected], timeout: 2.0)

        harness.send("isready")
        let originalReady = await harness.waitForLine(timeout: 5.0, matching: { $0 == "readyok" })
        XCTAssertEqual(originalReady, "readyok")

        harness.stop()
        contender.start()
        contender.sendCommand("uci")
        await fulfillment(of: [retryStarted], timeout: 5.0)
        contender.stop()
    }

    func testContractRejectsUnsafeCommandShapesWithoutBreakingUCI() async {
        harness.stop()
        let multilineRejected = expectation(description: "multiline_rejected")
        let nulRejected = expectation(description: "nul_rejected")
        let debugLogRejected = expectation(description: "debug_log_rejected")
        let uciAccepted = expectation(description: "single_line_accepted")

        let engine = SFEngine(lineHandler: { line in
            switch line {
            case "info string StockfishEmbedded error: command contains more than one line":
                multilineRejected.fulfill()
            case "info string StockfishEmbedded error: command contains NUL":
                nulRejected.fulfill()
            case "info string StockfishEmbedded error: Debug Log File is unsupported by the embedded stream bridge":
                debugLogRejected.fulfill()
            case "uciok":
                uciAccepted.fulfill()
            default:
                break
            }
        })

        engine.start()
        engine.sendCommand("uci\nisready")
        engine.sendCommand("\0uci")
        engine.sendCommand("setoption name Debug Log File value /tmp/stockfish.log")
        engine.sendCommand("uci\r\n")

        await fulfillment(
            of: [multilineRejected, nulRejected, debugLogRejected, uciAccepted],
            timeout: 5.0
        )
        engine.stop()
    }

    func testContractConcurrentStartAndStopCallsDoNotRaceLifecycle() {
        harness.stop()
        let engine = SFEngine(lineHandler: { _ in })
        let engineHolder = SFEngineHolder()
        engineHolder.store(engine)

        DispatchQueue.concurrentPerform(iterations: 100) { index in
            if index.isMultiple(of: 2) {
                engineHolder.start()
            } else {
                engineHolder.stop()
            }
        }
        engine.stop()
    }

    func testContractSendCommandAfterStopIsIgnoredSafely() {
        harness.stop()
        harness.send("uci")
        harness.send("isready")
        harness.send("go depth 12")
    }

    func testContractRepeatedReadyProbesReturnReadyOKEachTime() async {
        for attempt in 1...3 {
            harness.send("isready")
            let line = await harness.waitForLine(timeout: 5.0, matching: { $0 == "readyok" })
            XCTAssertEqual(line, "readyok", "Expected readyok for attempt \(attempt)")
        }
    }

    func testContractUCICommandCanBeIssuedAgain() async {
        harness.send("uci")
        let uciok = await harness.waitForLine(timeout: 10.0, matching: { $0 == "uciok" })
        XCTAssertEqual(uciok, "uciok")

        harness.send("isready")
        let readyok = await harness.waitForLine(timeout: 5.0, matching: { $0 == "readyok" })
        XCTAssertEqual(readyok, "readyok")
    }

    func testContractConcurrentCommandEnqueueDoesNotDeadlock() async {
        let enqueueComplete = expectation(description: "concurrent_setoption_enqueued")
        enqueueComplete.expectedFulfillmentCount = 200
        let localHarness = harness!

        for _ in 0..<200 {
            Thread.detachNewThread {
                localHarness.send("setoption name Hash value 16")
                Task { @MainActor in
                    enqueueComplete.fulfill()
                }
            }
        }
        await fulfillment(of: [enqueueComplete], timeout: 10.0)

        harness.send("isready")
        let readyok = await harness.waitForLine(timeout: 10.0, matching: { $0 == "readyok" })
        XCTAssertEqual(readyok, "readyok")
    }

    func testContractBackToBackSearchesProduceBestmoves() async {
        let searches = [
            ("position startpos", "go depth 6"),
            ("position startpos moves e2e4", "go depth 6"),
            ("position fen 4k3/8/8/8/4q3/8/4Q3/4K3 w - - 0 1", "go depth 6")
        ]

        for (index, search) in searches.enumerated() {
            guard let result = await harness.runSearch(
                positionCommand: search.0,
                goCommand: search.1,
                timeout: 15.0
            ) else {
                XCTFail("Expected bestmove for search \(index + 1)")
                return
            }

            XCTAssertTrue(
                Self.isValidBestmoveToken(result.bestmove),
                "Unexpected bestmove token for search \(index + 1): \(result.bestmove)"
            )
        }
    }

    func testContractStopDuringLongSearchReturnsPromptly() async {
        harness.stop()
        let localHarness = SFEngineHarness()

        do {
            try await localHarness.startAndBootstrap(timeout: 10.0)
        } catch {
            XCTFail("Failed to bootstrap local harness: \(error)")
            return
        }

        localHarness.send("position startpos")
        localHarness.send("go depth 40")

        // Give the search a brief head start, then stop.
        try? await Task.sleep(nanoseconds: 100_000_000)
        let start = Date()
        localHarness.stop()
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertLessThan(elapsed, 3.0, "Stop took too long: \(elapsed)s")
    }

    func testContractRepeatedStopsDuringSearchReturnBestmoves() async {
        harness.stop()
        let localHarness = SFEngineHarness()

        do {
            try await localHarness.startAndBootstrap(timeout: 10.0)
        } catch {
            XCTFail("Failed to bootstrap local harness: \(error)")
            return
        }
        defer { localHarness.stop() }

        for attempt in 1...5 {
            localHarness.send("position startpos")
            localHarness.send("go movetime 500")
            try? await Task.sleep(nanoseconds: 50_000_000)

            let start = Date()
            localHarness.send("stop")
            guard let bestmoveLine = await localHarness.waitForLine(
                timeout: 3.0,
                matching: { $0.hasPrefix("bestmove ") }
            ) else {
                XCTFail("Expected bestmove after stop on attempt \(attempt)")
                return
            }

            let elapsed = Date().timeIntervalSince(start)
            guard let bestmove = SFEngineHarness.parseBestmove(bestmoveLine) else {
                XCTFail("Could not parse bestmove line on attempt \(attempt): \(bestmoveLine)")
                return
            }

            XCTAssertLessThan(elapsed, 3.0, "Stop attempt \(attempt) took too long: \(elapsed)s")
            XCTAssertTrue(
                Self.isValidBestmoveToken(bestmove),
                "Unexpected bestmove token on attempt \(attempt): \(bestmove)"
            )
        }
    }

    func testContractRepeatedActiveSearchStopsAllowFreshEngineStarts() async {
        harness.stop()
        for attempt in 1...5 {
            let localHarness = SFEngineHarness()

            do {
                try await localHarness.startAndBootstrap(timeout: 10.0)
            } catch {
                XCTFail("Failed to bootstrap local harness on attempt \(attempt): \(error)")
                return
            }

            localHarness.send("position startpos")
            localHarness.send("go depth 40")
            try? await Task.sleep(nanoseconds: 50_000_000)

            let start = Date()
            localHarness.stop()
            let elapsed = Date().timeIntervalSince(start)

            XCTAssertLessThan(elapsed, 10.0, "Fresh-start stop attempt \(attempt) took too long: \(elapsed)s")
        }
    }

    // Step 2: perft correctness tests.

    func testPerftRegressionSuiteCoversCanonicalPositions() async {
        let cases: [PerftCase] = [
            PerftCase(name: "startpos_d2", positionCommand: "position startpos", depth: 2, expectedNodes: 400),
            PerftCase(name: "startpos_d3", positionCommand: "position startpos", depth: 3, expectedNodes: 8902),
            PerftCase(name: "startpos_d4", positionCommand: "position startpos", depth: 4, expectedNodes: 197281),
            PerftCase(name: "king_vs_king_d2", positionCommand: "position fen 8/8/8/8/8/8/8/K6k w - - 0 1", depth: 2, expectedNodes: 9),
            PerftCase(
                name: "kiwipete_d2",
                positionCommand: "position fen r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq -",
                depth: 2,
                expectedNodes: 2039
            ),
            PerftCase(
                name: "kiwipete_d3",
                positionCommand: "position fen r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq -",
                depth: 3,
                expectedNodes: 97862
            ),
            PerftCase(
                name: "kiwipete_d4",
                positionCommand: "position fen r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq -",
                depth: 4,
                expectedNodes: 4085603
            ),
            PerftCase(
                name: "position3_d2",
                positionCommand: "position fen 8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 w - -",
                depth: 2,
                expectedNodes: 191
            ),
            PerftCase(
                name: "position3_d3",
                positionCommand: "position fen 8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 w - -",
                depth: 3,
                expectedNodes: 2812
            ),
            PerftCase(
                name: "position3_d4",
                positionCommand: "position fen 8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 w - -",
                depth: 4,
                expectedNodes: 43238
            ),
            PerftCase(
                name: "position4_d2",
                positionCommand: "position fen r3k2r/Pppp1ppp/1b3nbN/nP6/BBP1P3/q4N2/Pp1P2PP/R2Q1RK1 w kq - 0 1",
                depth: 2,
                expectedNodes: 264
            ),
            PerftCase(
                name: "position4_d3",
                positionCommand: "position fen r3k2r/Pppp1ppp/1b3nbN/nP6/BBP1P3/q4N2/Pp1P2PP/R2Q1RK1 w kq - 0 1",
                depth: 3,
                expectedNodes: 9467
            ),
            PerftCase(
                name: "position4_d4",
                positionCommand: "position fen r3k2r/Pppp1ppp/1b3nbN/nP6/BBP1P3/q4N2/Pp1P2PP/R2Q1RK1 w kq - 0 1",
                depth: 4,
                expectedNodes: 422333
            ),
            PerftCase(
                name: "position5_d2",
                positionCommand: "position fen rnbq1k1r/pp1Pbppp/2p5/8/2B5/8/PPP1NnPP/RNBQK2R w KQ - 1 8",
                depth: 2,
                expectedNodes: 1486
            ),
            PerftCase(
                name: "position6_d2",
                positionCommand: "position fen r4rk1/1pp1qppp/p1np1n2/2b1p1B1/2B1P1b1/P1NP1N2/1PP1QPPP/R4RK1 w - - 0 10",
                depth: 2,
                expectedNodes: 2079
            )
        ]

        for testCase in cases {
            guard let nodes = await harness.runPerft(
                positionCommand: testCase.positionCommand,
                depth: testCase.depth,
                timeout: 60.0
            ) else {
                XCTFail("No perft result for \(testCase.name)")
                return
            }

            XCTAssertEqual(
                nodes,
                testCase.expectedNodes,
                "Perft mismatch for \(testCase.name)"
            )
        }
    }

    // Step 3: tactical tests (mate signal + allowed move set).

    func testTacticalMateInOneRegressionSuite() async {
        let cases: [TacticalCase] = [
            TacticalCase(
                name: "kqk_f6_h8_qa7",
                positionCommand: "position fen 7k/Q7/5K2/8/8/8/8/8 w - - 0 1",
                goCommand: "go depth 4",
                expectedBestmoves: ["a7g7"]
            ),
            TacticalCase(
                name: "kqk_f6_h8_qb7",
                positionCommand: "position fen 7k/1Q6/5K2/8/8/8/8/8 w - - 0 1",
                goCommand: "go depth 4",
                expectedBestmoves: ["b7g7"]
            ),
            TacticalCase(
                name: "kqk_f6_h8_qc7",
                positionCommand: "position fen 7k/2Q5/5K2/8/8/8/8/8 w - - 0 1",
                goCommand: "go depth 4",
                expectedBestmoves: ["c7g7"]
            ),
            TacticalCase(
                name: "kqk_f6_h8_qd7",
                positionCommand: "position fen 7k/3Q4/5K2/8/8/8/8/8 w - - 0 1",
                goCommand: "go depth 4",
                expectedBestmoves: ["d7g7"]
            ),
            TacticalCase(
                name: "kqk_f6_h8_qe7",
                positionCommand: "position fen 7k/4Q3/5K2/8/8/8/8/8 w - - 0 1",
                goCommand: "go depth 4",
                expectedBestmoves: ["e7g7"]
            ),
            TacticalCase(
                name: "kqk_f6_h8_qf7",
                positionCommand: "position fen 7k/5Q2/5K2/8/8/8/8/8 w - - 0 1",
                goCommand: "go depth 4",
                expectedBestmoves: ["f7g7"]
            ),
            TacticalCase(
                name: "kqk_f6_h8_qg1",
                positionCommand: "position fen 7k/8/5K2/8/8/8/8/6Q1 w - - 0 1",
                goCommand: "go depth 4",
                expectedBestmoves: ["g1g7"]
            ),
            TacticalCase(
                name: "kqk_f6_h8_qg2",
                positionCommand: "position fen 7k/8/5K2/8/8/8/6Q1/8 w - - 0 1",
                goCommand: "go depth 4",
                expectedBestmoves: ["g2g7"]
            ),
            TacticalCase(
                name: "kqk_f6_h8_qg3",
                positionCommand: "position fen 7k/8/5K2/8/8/6Q1/8/8 w - - 0 1",
                goCommand: "go depth 4",
                expectedBestmoves: ["g3g7"]
            ),
            TacticalCase(
                name: "kqk_f6_h8_qg4",
                positionCommand: "position fen 7k/8/5K2/8/6Q1/8/8/8 w - - 0 1",
                goCommand: "go depth 4",
                expectedBestmoves: ["g4g7"]
            ),
            TacticalCase(
                name: "kqk_f6_h8_qg5",
                positionCommand: "position fen 7k/8/5K2/6Q1/8/8/8/8 w - - 0 1",
                goCommand: "go depth 4",
                expectedBestmoves: ["g5g7"]
            ),
            TacticalCase(
                name: "kqk_f6_h8_qg6",
                positionCommand: "position fen 7k/8/5KQ1/8/8/8/8/8 w - - 0 1",
                goCommand: "go depth 4",
                expectedBestmoves: ["g6g7"]
            ),
            TacticalCase(
                name: "kqk_f7_h8_qa2",
                positionCommand: "position fen 7k/5K2/8/8/8/8/Q7/8 w - - 0 1",
                goCommand: "go depth 4",
                expectedBestmoves: ["a2h2"]
            ),
            TacticalCase(
                name: "kqk_f7_h8_qa3",
                positionCommand: "position fen 7k/5K2/8/8/8/Q7/8/8 w - - 0 1",
                goCommand: "go depth 4",
                expectedBestmoves: ["a3h3"]
            ),
            TacticalCase(
                name: "kqk_f7_h8_qa4",
                positionCommand: "position fen 7k/5K2/8/8/Q7/8/8/8 w - - 0 1",
                goCommand: "go depth 4",
                expectedBestmoves: ["a4h4"]
            ),
            TacticalCase(
                name: "kqk_f7_h8_qa5",
                positionCommand: "position fen 7k/5K2/8/Q7/8/8/8/8 w - - 0 1",
                goCommand: "go depth 4",
                expectedBestmoves: ["a5h5"]
            ),
            TacticalCase(
                name: "kqk_f7_h8_qa6",
                positionCommand: "position fen 7k/5K2/Q7/8/8/8/8/8 w - - 0 1",
                goCommand: "go depth 4",
                expectedBestmoves: ["a6h6"]
            ),
            TacticalCase(
                name: "kqk_f7_h8_qb1",
                positionCommand: "position fen 7k/5K2/8/8/8/8/8/1Q6 w - - 0 1",
                goCommand: "go depth 4",
                expectedBestmoves: ["b1h1"]
            ),
            TacticalCase(
                name: "kqk_f7_h8_qb3",
                positionCommand: "position fen 7k/5K2/8/8/8/1Q6/8/8 w - - 0 1",
                goCommand: "go depth 4",
                expectedBestmoves: ["b3h3"]
            ),
            TacticalCase(
                name: "kqk_f7_h8_qb4",
                positionCommand: "position fen 7k/5K2/8/8/1Q6/8/8/8 w - - 0 1",
                goCommand: "go depth 4",
                expectedBestmoves: ["b4h4"]
            ),
            TacticalCase(
                name: "kqk_f7_h8_qb5",
                positionCommand: "position fen 7k/5K2/8/1Q6/8/8/8/8 w - - 0 1",
                goCommand: "go depth 4",
                expectedBestmoves: ["b5h5"]
            ),
            TacticalCase(
                name: "kqk_f7_h8_qb6",
                positionCommand: "position fen 7k/5K2/1Q6/8/8/8/8/8 w - - 0 1",
                goCommand: "go depth 4",
                expectedBestmoves: ["b6h6"]
            ),
            TacticalCase(
                name: "kqk_f7_h8_qb7",
                positionCommand: "position fen 7k/1Q3K2/8/8/8/8/8/8 w - - 0 1",
                goCommand: "go depth 4",
                expectedBestmoves: ["b7h1"]
            ),
            TacticalCase(
                name: "kqk_f7_h8_qc1",
                positionCommand: "position fen 7k/5K2/8/8/8/8/8/2Q5 w - - 0 1",
                goCommand: "go depth 4",
                expectedBestmoves: ["c1h1"]
            ),
            TacticalCase(
                name: "kqk_f7_h8_qc2",
                positionCommand: "position fen 7k/5K2/8/8/8/8/2Q5/8 w - - 0 1",
                goCommand: "go depth 4",
                expectedBestmoves: ["c2h2"]
            ),
            TacticalCase(
                name: "kqk_f7_h8_qc4",
                positionCommand: "position fen 7k/5K2/8/8/2Q5/8/8/8 w - - 0 1",
                goCommand: "go depth 4",
                expectedBestmoves: ["c4h4"]
            ),
            TacticalCase(
                name: "kqk_f7_h8_qc5",
                positionCommand: "position fen 7k/5K2/8/2Q5/8/8/8/8 w - - 0 1",
                goCommand: "go depth 4",
                expectedBestmoves: ["c5h5"]
            ),
            TacticalCase(
                name: "kqk_f7_h8_qc6",
                positionCommand: "position fen 7k/5K2/2Q5/8/8/8/8/8 w - - 0 1",
                goCommand: "go depth 4",
                expectedBestmoves: ["c6h1"]
            ),
            TacticalCase(
                name: "kqk_f7_h8_qc7",
                positionCommand: "position fen 7k/2Q2K2/8/8/8/8/8/8 w - - 0 1",
                goCommand: "go depth 4",
                expectedBestmoves: ["c7h2"]
            ),
            TacticalCase(
                name: "kqk_f7_h8_qd1",
                positionCommand: "position fen 7k/5K2/8/8/8/8/8/3Q4 w - - 0 1",
                goCommand: "go depth 4",
                expectedBestmoves: ["d1h1"]
            ),
            TacticalCase(
                name: "kqk_f7_h8_qd2",
                positionCommand: "position fen 7k/5K2/8/8/8/8/3Q4/8 w - - 0 1",
                goCommand: "go depth 4",
                expectedBestmoves: ["d2h2"]
            ),
            TacticalCase(
                name: "kqk_f7_h8_qd3",
                positionCommand: "position fen 7k/5K2/8/8/8/3Q4/8/8 w - - 0 1",
                goCommand: "go depth 4",
                expectedBestmoves: ["d3h3"]
            ),
            TacticalCase(
                name: "kqk_f7_h8_qd5",
                positionCommand: "position fen 7k/5K2/8/3Q4/8/8/8/8 w - - 0 1",
                goCommand: "go depth 4",
                expectedBestmoves: ["d5h1"]
            ),
            TacticalCase(
                name: "kqk_f7_h8_qd6",
                positionCommand: "position fen 7k/5K2/3Q4/8/8/8/8/8 w - - 0 1",
                goCommand: "go depth 4",
                expectedBestmoves: ["d6h2"]
            ),
            TacticalCase(
                name: "kqk_f7_h8_qd7",
                positionCommand: "position fen 7k/3Q1K2/8/8/8/8/8/8 w - - 0 1",
                goCommand: "go depth 4",
                expectedBestmoves: ["d7h3"]
            ),
            TacticalCase(
                name: "kqk_f7_h8_qe1",
                positionCommand: "position fen 7k/5K2/8/8/8/8/8/4Q3 w - - 0 1",
                goCommand: "go depth 4",
                expectedBestmoves: ["e1h1"]
            ),
            TacticalCase(
                name: "kqk_f7_h8_qe2",
                positionCommand: "position fen 7k/5K2/8/8/8/8/4Q3/8 w - - 0 1",
                goCommand: "go depth 4",
                expectedBestmoves: ["e2h2"]
            ),
            TacticalCase(
                name: "kqk_f7_h8_qe3",
                positionCommand: "position fen 7k/5K2/8/8/8/4Q3/8/8 w - - 0 1",
                goCommand: "go depth 4",
                expectedBestmoves: ["e3h3"]
            ),
            TacticalCase(
                name: "kqk_f7_h8_qe4",
                positionCommand: "position fen 7k/5K2/8/8/4Q3/8/8/8 w - - 0 1",
                goCommand: "go depth 4",
                expectedBestmoves: ["e4h1"]
            ),
            TacticalCase(
                name: "kqk_f7_h8_qe6",
                positionCommand: "position fen 7k/5K2/4Q3/8/8/8/8/8 w - - 0 1",
                goCommand: "go depth 4",
                expectedBestmoves: ["e6h3"]
            ),
            TacticalCase(
                name: "kqk_f7_h8_qe7",
                positionCommand: "position fen 7k/4QK2/8/8/8/8/8/8 w - - 0 1",
                goCommand: "go depth 4",
                expectedBestmoves: ["e7h4"]
            ),
            TacticalCase(
                name: "kqk_f7_h8_qf1",
                positionCommand: "position fen 7k/5K2/8/8/8/8/8/5Q2 w - - 0 1",
                goCommand: "go depth 4",
                expectedBestmoves: ["f1h1"]
            ),
            TacticalCase(
                name: "kqk_f7_h8_qf2",
                positionCommand: "position fen 7k/5K2/8/8/8/8/5Q2/8 w - - 0 1",
                goCommand: "go depth 4",
                expectedBestmoves: ["f2h2"]
            ),
            TacticalCase(
                name: "kqk_f7_h8_qf3",
                positionCommand: "position fen 7k/5K2/8/8/8/5Q2/8/8 w - - 0 1",
                goCommand: "go depth 4",
                expectedBestmoves: ["f3h1"]
            ),
            TacticalCase(
                name: "kqk_f7_h8_qf4",
                positionCommand: "position fen 7k/5K2/8/8/5Q2/8/8/8 w - - 0 1",
                goCommand: "go depth 4",
                expectedBestmoves: ["f4h2"]
            ),
            TacticalCase(
                name: "kqk_f7_h8_qf5",
                positionCommand: "position fen 7k/5K2/8/5Q2/8/8/8/8 w - - 0 1",
                goCommand: "go depth 4",
                expectedBestmoves: ["f5h3"]
            ),
            TacticalCase(
                name: "kqk_f7_h8_qg1",
                positionCommand: "position fen 7k/5K2/8/8/8/8/8/6Q1 w - - 0 1",
                goCommand: "go depth 4",
                expectedBestmoves: ["g1h1"]
            ),
            TacticalCase(
                name: "kqk_f7_h8_qg2",
                positionCommand: "position fen 7k/5K2/8/8/8/8/6Q1/8 w - - 0 1",
                goCommand: "go depth 4",
                expectedBestmoves: ["g2h1"]
            ),
            TacticalCase(
                name: "kqk_f7_h8_qg3",
                positionCommand: "position fen 7k/5K2/8/8/8/6Q1/8/8 w - - 0 1",
                goCommand: "go depth 4",
                expectedBestmoves: ["g3h2"]
            ),
            TacticalCase(
                name: "kqk_f7_h8_qg4",
                positionCommand: "position fen 7k/5K2/8/8/6Q1/8/8/8 w - - 0 1",
                goCommand: "go depth 4",
                expectedBestmoves: ["g4h3"]
            ),
            TacticalCase(
                name: "kqk_f7_h8_qg5",
                positionCommand: "position fen 7k/5K2/8/6Q1/8/8/8/8 w - - 0 1",
                goCommand: "go depth 4",
                expectedBestmoves: ["g5h4"]
            ),
            TacticalCase(
                name: "kqk_f7_h8_qg6",
                positionCommand: "position fen 7k/5K2/6Q1/8/8/8/8/8 w - - 0 1",
                goCommand: "go depth 4",
                expectedBestmoves: ["g6h5"]
            )
        ]

        for testCase in cases {
            guard let result = await harness.runSearch(
                positionCommand: testCase.positionCommand,
                goCommand: testCase.goCommand,
                timeout: 10.0
            ) else {
                XCTFail("Expected search result for \(testCase.name)")
                return
            }

            if testCase.name.hasPrefix("kqk_f6_h8_") {
                XCTAssertTrue(
                    testCase.expectedBestmoves.contains(result.bestmove),
                    "Expected one of \(testCase.expectedBestmoves.sorted()) for \(testCase.name), got \(result.bestmove)"
                )
            } else {
                XCTAssertTrue(
                    Self.isValidBestmoveToken(result.bestmove),
                    "Unexpected bestmove token for \(testCase.name): \(result.bestmove)"
                )
            }

            guard case .mate(let matePly)? = result.latestScore else {
                XCTFail("Expected a mate score for \(testCase.name): \(result.transcript.joined(separator: " | "))")
                return
            }

            XCTAssertGreaterThan(matePly, 0, "Expected positive mate score for \(testCase.name)")
        }
    }

    func testTacticalHangingQueenMoveInAllowedSet() async {
        guard let result = await harness.runSearch(
            positionCommand: "position fen 4k3/8/8/8/4q3/8/4Q3/4K3 w - - 0 1",
            goCommand: "go depth 6",
            timeout: 10.0
        ) else {
            XCTFail("Expected search result")
            return
        }

        let allowedMoves: Set<String> = ["e2e4"]
        XCTAssertTrue(
            allowedMoves.contains(result.bestmove),
            "Expected one of \(allowedMoves.sorted()) but got \(result.bestmove)"
        )
    }

    // Step 4: score-band tests.

    func testScoreBandRegressionSuite() async {
        let cases: [ScoreCase] = [
            ScoreCase(
                name: "white_to_move_white_up_queen",
                positionCommand: "position fen 4k3/8/8/8/3Q4/8/8/4K3 w - - 0 1",
                goCommand: "go depth 8",
                expectation: .atLeast(300)
            ),
            ScoreCase(
                name: "white_to_move_white_down_queen",
                positionCommand: "position fen 4k3/8/8/8/4q3/8/8/4K3 w - - 0 1",
                goCommand: "go depth 8",
                expectation: .atMost(-300)
            ),
            ScoreCase(
                name: "white_to_move_white_up_rook",
                positionCommand: "position fen 4k3/8/8/8/3R4/8/8/4K3 w - - 0 1",
                goCommand: "go depth 8",
                expectation: .atLeast(300)
            ),
            ScoreCase(
                name: "white_to_move_white_down_rook",
                positionCommand: "position fen 4k3/8/8/8/3r4/8/8/4K3 w - - 0 1",
                goCommand: "go depth 8",
                expectation: .atMost(-300)
            ),
            ScoreCase(
                name: "black_to_move_white_up_queen",
                positionCommand: "position fen 4k3/8/8/8/3Q4/8/8/4K3 b - - 0 1",
                goCommand: "go depth 8",
                expectation: .atMost(-300)
            ),
            ScoreCase(
                name: "black_to_move_white_down_queen",
                positionCommand: "position fen 4k3/8/8/8/3q4/8/8/4K3 b - - 0 1",
                goCommand: "go depth 8",
                expectation: .atLeast(300)
            ),
            ScoreCase(
                name: "black_to_move_white_up_rook",
                positionCommand: "position fen 4k3/8/8/8/3R4/8/8/4K3 b - - 0 1",
                goCommand: "go depth 8",
                expectation: .atMost(-300)
            ),
            ScoreCase(
                name: "black_to_move_white_down_rook",
                positionCommand: "position fen 4k3/8/8/8/3r4/8/8/4K3 b - - 0 1",
                goCommand: "go depth 8",
                expectation: .atLeast(300)
            ),
            ScoreCase(
                name: "white_to_move_two_bishops_advantage",
                positionCommand: "position fen 4k3/8/8/8/3BB3/8/8/4K3 w - - 0 1",
                goCommand: "go depth 8",
                expectation: .atLeast(150)
            ),
            ScoreCase(
                name: "white_to_move_two_bishops_disadvantage",
                positionCommand: "position fen 4k3/8/8/8/3bb3/8/8/4K3 w - - 0 1",
                goCommand: "go depth 8",
                expectation: .atMost(-150)
            ),
            ScoreCase(
                name: "white_to_move_kings_only",
                positionCommand: "position fen 8/8/8/8/8/8/8/K6k w - - 0 1",
                goCommand: "go depth 8",
                expectation: .nearZero(40)
            ),
            ScoreCase(
                name: "black_to_move_kings_only",
                positionCommand: "position fen 8/8/8/8/8/8/8/K6k b - - 0 1",
                goCommand: "go depth 8",
                expectation: .nearZero(40)
            )
        ]

        for testCase in cases {
            guard let result = await harness.runSearch(
                positionCommand: testCase.positionCommand,
                goCommand: testCase.goCommand,
                timeout: 20.0
            ) else {
                XCTFail("Expected search result for \(testCase.name)")
                return
            }

            guard let score = result.latestScore else {
                XCTFail("Expected score in transcript for \(testCase.name)")
                return
            }

            assert(score: score, expectation: testCase.expectation, caseName: testCase.name)
        }
    }

    private func assert(
        score: SFEngineHarness.Score,
        expectation: ScoreExpectation,
        caseName: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        switch score {
        case .mate(let value):
            switch expectation {
            case .atLeast:
                XCTAssertGreaterThan(value, 0, "Expected positive mate score for \(caseName)", file: file, line: line)
            case .atMost:
                XCTAssertLessThan(value, 0, "Expected negative mate score for \(caseName)", file: file, line: line)
            case .nearZero:
                XCTFail("Expected near-zero cp score for \(caseName), got mate \(value)", file: file, line: line)
            }
        case .cp(let value):
            switch expectation {
            case .atLeast(let minimum):
                XCTAssertGreaterThanOrEqual(value, minimum, "Expected cp >= \(minimum) for \(caseName), got \(value)", file: file, line: line)
            case .atMost(let maximum):
                XCTAssertLessThanOrEqual(value, maximum, "Expected cp <= \(maximum) for \(caseName), got \(value)", file: file, line: line)
            case .nearZero(let maxAbs):
                XCTAssertLessThanOrEqual(abs(value), maxAbs, "Expected |cp| <= \(maxAbs) for \(caseName), got \(value)", file: file, line: line)
            }
        }
    }

    private static func isValidBestmoveToken(_ token: String) -> Bool {
        let range = NSRange(token.startIndex..<token.endIndex, in: token)
        return validBestmoveRegex.firstMatch(in: token, options: [], range: range) != nil
    }
}

private final class SoakEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [SFEngineSoakRunner.Event] = []

    func append(_ event: SFEngineSoakRunner.Event) {
        lock.lock()
        storage.append(event)
        lock.unlock()
    }

    var events: [SFEngineSoakRunner.Event] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

final class SFEngineSoakRunnerTests: XCTestCase {
    func testInvalidConfigurationFailsBeforeStartingEngine() async {
        let recorder = SoakEventRecorder()
        let runner = SFEngineSoakRunner(configuration: .init(
            positions: [.startpos],
            searchLimit: .depth(0),
            maxIterations: 1
        ))

        let summary = await runner.run { recorder.append($0) }

        XCTAssertEqual(summary.iterationsAttempted, 0)
        XCTAssertEqual(summary.errors, 1)
        XCTAssertTrue(recorder.events.contains(.error("Search depth must be greater than zero")))
    }

    func testCompletedIterationEmitsOnlyBestmoveToken() async {
        let recorder = SoakEventRecorder()
        let runner = SFEngineSoakRunner(configuration: .init(
            positions: [.startpos],
            searchLimit: .moveTimeMillis(20),
            maxIterations: 1,
            perMoveTimeout: .seconds(5)
        ))

        let summary = await runner.run { recorder.append($0) }
        let moves = recorder.events.compactMap { event -> String? in
            guard case .iterationCompleted(_, let bestmove, _) = event else { return nil }
            return bestmove
        }

        XCTAssertEqual(summary.iterationsCompleted, 1)
        XCTAssertEqual(moves.count, 1)
        XCTAssertNotNil(
            moves[0].range(of: #"^[a-h][1-8][a-h][1-8][nbrq]?$"#, options: .regularExpression)
        )
    }

    func testRecoveredTimeoutConsumesTerminalBestmoveBeforeNextPosition() async {
        let recorder = SoakEventRecorder()
        let runner = SFEngineSoakRunner(configuration: .init(
            positions: [
                .startpos,
                .fen("rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1")
            ],
            searchLimit: .moveTimeMillis(5_000),
            maxIterations: 2,
            perMoveTimeout: .milliseconds(1),
            stopTimeout: .seconds(5)
        ))

        let summary = await runner.run { recorder.append($0) }
        let timeoutIndices = recorder.events.compactMap { event -> Int? in
            guard case .timeout(let index, _, _) = event else { return nil }
            return index
        }

        XCTAssertEqual(summary.iterationsAttempted, 2)
        XCTAssertEqual(summary.iterationsCompleted, 0)
        XCTAssertEqual(summary.timeouts, 2)
        XCTAssertEqual(summary.errors, 0)
        XCTAssertEqual(timeoutIndices, [0, 1])
    }

    func testStopFromStartedEventIsObservedPromptly() async {
        let recorder = SoakEventRecorder()
        let runner = SFEngineSoakRunner(configuration: .init(
            positions: [.startpos],
            searchLimit: .depth(30),
            maxIterations: 10,
            handshakeTimeout: .seconds(5),
            delayBetweenIterations: .seconds(10)
        ))

        let clock = ContinuousClock()
        let start = clock.now
        let summary = await runner.run { event in
            recorder.append(event)
            if case .started = event {
                runner.stop()
            }
        }
        let elapsed = start.duration(to: clock.now)

        XCTAssertEqual(summary.iterationsAttempted, 0)
        XCTAssertEqual(summary.errors, 0)
        XCTAssertTrue(recorder.events.contains(.stopped))
        XCTAssertLessThan(elapsed, .seconds(2))
    }
}

final class EmbeddedUCIParityTests: XCTestCase {
    func testEmbeddedUCIStartupLifecycleMatchesVendoredMain() throws {
        let repositoryRoot = try Self.repositoryRoot()
        let mainSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent("ThirdParty/Stockfish/src/main.cpp"),
            encoding: .utf8
        )
        let shimSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent("Sources/SFEngine/EmbeddedUCI.cpp"),
            encoding: .utf8
        )

        let mainLifecycle = Self.extractStartupLifecycle(from: mainSource)
        let shimLifecycle = Self.extractStartupLifecycle(from: shimSource)

        XCTAssertEqual(mainLifecycle.last, "UCIEngine loop")
        XCTAssertEqual(shimLifecycle.last, "UCIEngine loop")
        XCTAssertEqual(
            shimLifecycle,
            mainLifecycle,
            "EmbeddedUCI.cpp must mirror the vendored Stockfish main.cpp startup lifecycle."
        )
    }

    private static func repositoryRoot(filePath: String = #filePath) throws -> URL {
        var url = URL(fileURLWithPath: filePath)
        for _ in 0..<3 {
            url.deleteLastPathComponent()
        }

        let marker = url.appendingPathComponent("ThirdParty/Stockfish/src/main.cpp")
        guard FileManager.default.fileExists(atPath: marker.path) else {
            throw RepositoryLayoutError.missingVendoredMain(marker.path)
        }
        return url
    }

    private static func extractStartupLifecycle(from source: String) -> [String] {
        var lifecycle: [String] = []
        var isCapturing = false

        for rawLine in source.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("//") else {
                continue
            }

            if line.contains("std::cout << engine_info()") {
                isCapturing = true
                lifecycle.append("engine_info banner")
                continue
            }

            guard isCapturing else {
                continue
            }

            if line.contains("Bitboards::init()") {
                lifecycle.append("Bitboards::init")
            } else if line.contains("Position::init()") {
                lifecycle.append("Position::init")
            } else if line.contains("std::make_unique<UCIEngine>") {
                lifecycle.append("UCIEngine heap construction")
            } else if line.range(of: #"^UCIEngine\s+\w+\("#, options: .regularExpression) != nil {
                lifecycle.append("UCIEngine stack construction")
            } else if line.contains("Tune::init") && line.contains("engine_options") {
                lifecycle.append("Tune::init engine options")
            } else if line.range(of: #"\buci(->|\.)loop\(\);"#, options: .regularExpression) != nil {
                lifecycle.append("UCIEngine loop")
                break
            } else if line.hasPrefix("return ")
                        || line.hasPrefix("for ")
                        || line == "{"
                        || line == "}"
                        || line.contains("argv") {
                continue
            } else {
                // Preserve unknown setup statements so upstream additions fail until mirrored here.
                lifecycle.append(line)
            }
        }

        return lifecycle
    }

    private enum RepositoryLayoutError: Error {
        case missingVendoredMain(String)
    }
}
