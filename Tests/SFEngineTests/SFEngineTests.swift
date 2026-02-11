import Foundation
import XCTest

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

    private static let validBestmoveRegex = try! NSRegularExpression(
        pattern: "^(?:[a-h][1-8][a-h][1-8][nbrq]?|0000|\\(none\\))$",
        options: []
    )

    private var harness: SFEngineHarness!
    private var cursor: Int = 0

    override func setUpWithError() throws {
        try super.setUpWithError()
        harness = SFEngineHarness()
        cursor = try harness.startAndBootstrap(timeout: 10.0)
    }

    override func tearDownWithError() throws {
        harness?.stop()
        harness = nil
        try super.tearDownWithError()
    }

    // Step 1: wrapper contract tests.

    func testContractReadyProbeReturnsReadyOK() {
        harness.send("isready")

        let line = harness.waitForLine(after: &cursor, timeout: 5.0, matching: { $0 == "readyok" })
        XCTAssertEqual(line, "readyok")
    }

    func testContractBestmoveHasValidUCISyntax() {
        guard let result = harness.runSearch(
            positionCommand: "position startpos",
            goCommand: "go movetime 250",
            timeout: 10.0,
            cursor: &cursor
        ) else {
            XCTFail("Expected bestmove within timeout")
            return
        }

        XCTAssertTrue(Self.isValidBestmoveToken(result.bestmove), "Unexpected bestmove token: \(result.bestmove)")
    }

    func testContractStartAndStopAreIdempotent() {
        let engine = SFEngine(lineHandler: { _ in })

        engine.start()
        engine.start()
        engine.stop()
        engine.stop()
    }

    func testContractSendCommandBeforeStartIsIgnoredSafely() {
        let uciok = DispatchSemaphore(value: 0)
        let engine = SFEngine(lineHandler: { line in
            if line == "uciok" {
                uciok.signal()
            }
        })

        // Should be ignored before start and never crash.
        engine.sendCommand("uci")
        engine.sendCommand("isready")
        engine.sendCommand("")

        engine.start()
        engine.sendCommand("uci")
        let waitResult = uciok.wait(timeout: .now() + .seconds(5))
        XCTAssertEqual(waitResult, .success, "Expected uciok after start")
        engine.stop()
    }

    func testContractSendCommandAfterStopIsIgnoredSafely() {
        harness.stop()
        harness.send("uci")
        harness.send("isready")
        harness.send("go depth 12")
    }

    func testContractRepeatedReadyProbesReturnReadyOKEachTime() {
        for attempt in 1...3 {
            harness.send("isready")
            let line = harness.waitForLine(after: &cursor, timeout: 5.0, matching: { $0 == "readyok" })
            XCTAssertEqual(line, "readyok", "Expected readyok for attempt \(attempt)")
        }
    }

    func testContractUCICommandCanBeIssuedAgain() {
        harness.send("uci")
        let uciok = harness.waitForLine(after: &cursor, timeout: 10.0, matching: { $0 == "uciok" })
        XCTAssertEqual(uciok, "uciok")

        harness.send("isready")
        let readyok = harness.waitForLine(after: &cursor, timeout: 5.0, matching: { $0 == "readyok" })
        XCTAssertEqual(readyok, "readyok")
    }

    func testContractConcurrentCommandEnqueueDoesNotDeadlock() {
        DispatchQueue.concurrentPerform(iterations: 200) { _ in
            harness.send("setoption name Hash value 16")
        }

        harness.send("isready")
        let readyok = harness.waitForLine(after: &cursor, timeout: 10.0, matching: { $0 == "readyok" })
        XCTAssertEqual(readyok, "readyok")
    }

    func testContractBackToBackSearchesProduceBestmoves() {
        let searches = [
            ("position startpos", "go depth 6"),
            ("position startpos moves e2e4", "go depth 6"),
            ("position fen 4k3/8/8/8/4q3/8/4Q3/4K3 w - - 0 1", "go depth 6")
        ]

        for (index, search) in searches.enumerated() {
            guard let result = harness.runSearch(
                positionCommand: search.0,
                goCommand: search.1,
                timeout: 15.0,
                cursor: &cursor
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

    func testContractStopDuringLongSearchReturnsPromptly() {
        let localHarness = SFEngineHarness()
        var localCursor = 0

        do {
            localCursor = try localHarness.startAndBootstrap(timeout: 10.0)
        } catch {
            XCTFail("Failed to bootstrap local harness: \(error)")
            return
        }

        localHarness.send("position startpos")
        localHarness.send("go depth 40")

        // Give the search a brief head start, then stop.
        Thread.sleep(forTimeInterval: 0.1)
        let start = Date()
        localHarness.stop()
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertLessThan(elapsed, 3.0, "Stop took too long: \(elapsed)s")

        // Cursor remains intentionally unused, but keeping it avoids accidental
        // compiler optimization stripping the setup in release test runs.
        XCTAssertGreaterThanOrEqual(localCursor, 0)
    }

    // Step 2: perft correctness tests.

    func testPerftRegressionSuiteCoversCanonicalPositions() {
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
            guard let nodes = harness.runPerft(
                positionCommand: testCase.positionCommand,
                depth: testCase.depth,
                timeout: 60.0,
                cursor: &cursor
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

    func testTacticalMateInOneReportsPositiveMateScore() {
        guard let result = harness.runSearch(
            positionCommand: "position fen 7k/8/5KQ1/8/8/8/8/8 w - - 0 1",
            goCommand: "go depth 4",
            timeout: 10.0,
            cursor: &cursor
        ) else {
            XCTFail("Expected search result")
            return
        }

        guard case .mate(let matePly)? = result.latestScore else {
            XCTFail("Expected a mate score in transcript: \(result.transcript.joined(separator: " | "))")
            return
        }

        XCTAssertGreaterThan(matePly, 0)
    }

    func testTacticalHangingQueenMoveInAllowedSet() {
        guard let result = harness.runSearch(
            positionCommand: "position fen 4k3/8/8/8/4q3/8/4Q3/4K3 w - - 0 1",
            goCommand: "go depth 6",
            timeout: 10.0,
            cursor: &cursor
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

    func testScoreBandRegressionSuite() {
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
            guard let result = harness.runSearch(
                positionCommand: testCase.positionCommand,
                goCommand: testCase.goCommand,
                timeout: 20.0,
                cursor: &cursor
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
