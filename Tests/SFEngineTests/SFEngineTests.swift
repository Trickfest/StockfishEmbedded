import Foundation
import XCTest

final class SFEngineTests: XCTestCase {
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

    // Step 2: perft correctness tests.

    func testPerftStartPositionDepth2Is400() {
        let nodes = harness.runPerft(
            positionCommand: "position startpos",
            depth: 2,
            timeout: 10.0,
            cursor: &cursor
        )

        XCTAssertEqual(nodes, 400)
    }

    func testPerftKingVsKingDepth2Is9() {
        let nodes = harness.runPerft(
            positionCommand: "position fen 8/8/8/8/8/8/8/K6k w - - 0 1",
            depth: 2,
            timeout: 10.0,
            cursor: &cursor
        )

        XCTAssertEqual(nodes, 9)
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

    func testScoreBandWhiteUpQueenIsClearlyPositive() {
        guard let result = harness.runSearch(
            positionCommand: "position fen 4k3/8/8/8/3Q4/8/8/4K3 w - - 0 1",
            goCommand: "go depth 6",
            timeout: 10.0,
            cursor: &cursor
        ) else {
            XCTFail("Expected search result")
            return
        }

        guard let score = result.latestScore else {
            XCTFail("Expected score in transcript")
            return
        }

        assertClearlyPositive(score)
    }

    func testScoreBandWhiteDownQueenIsClearlyNegative() {
        guard let result = harness.runSearch(
            positionCommand: "position fen 4k3/8/8/8/4q3/8/8/4K3 w - - 0 1",
            goCommand: "go depth 6",
            timeout: 10.0,
            cursor: &cursor
        ) else {
            XCTFail("Expected search result")
            return
        }

        guard let score = result.latestScore else {
            XCTFail("Expected score in transcript")
            return
        }

        assertClearlyNegative(score)
    }

    private func assertClearlyPositive(_ score: SFEngineHarness.Score, file: StaticString = #filePath, line: UInt = #line) {
        switch score {
        case .cp(let value):
            XCTAssertGreaterThan(value, 300, file: file, line: line)
        case .mate(let value):
            XCTAssertGreaterThan(value, 0, file: file, line: line)
        }
    }

    private func assertClearlyNegative(_ score: SFEngineHarness.Score, file: StaticString = #filePath, line: UInt = #line) {
        switch score {
        case .cp(let value):
            XCTAssertLessThan(value, -300, file: file, line: line)
        case .mate(let value):
            XCTAssertLessThan(value, 0, file: file, line: line)
        }
    }

    private static func isValidBestmoveToken(_ token: String) -> Bool {
        let range = NSRange(token.startIndex..<token.endIndex, in: token)
        return validBestmoveRegex.firstMatch(in: token, options: [], range: range) != nil
    }
}
