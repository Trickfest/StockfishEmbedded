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
        matching predicate: (String) -> Bool
    ) -> String? {
        let deadline = Date().addingTimeInterval(timeout)

        condition.lock()
        defer { condition.unlock() }

        while true {
            if let line = lines.first(where: predicate) {
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
// A real network from the prior PSQT layout is a stronger migration check than
// arbitrary corrupt bytes. This remains optional in clean source-only builds.
private let previousNetworkURL = localNetwork(named: "nn-134a887f4c8f.nnue")

@Suite(.serialized)
struct SFEnginePackageRuntimeTests {
    @Test
    func defaultNetworkMatchesVendoredSnapshot() {
        #expect(SFEngine.defaultNetworkFileName == "nn-252f33942263.nnue")
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

    @Test(
        .enabled(
            if: previousNetworkURL != nil,
            "The previous-layout network is an optional local migration fixture"
        )
    )
    func previousNetworkLayoutIsRejectedWithoutTerminatingTheProcess() throws {
        let networkURL = try #require(previousNetworkURL)
        let sink = PackageLineSink()
        let engine = SFEngine(networkFileURL: networkURL) { sink.append($0) }
        defer { engine.stop() }

        engine.start()
        #expect(sink.wait(timeout: 10.0) {
            $0.contains("incompatible with this Stockfish build")
        } != nil)
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

        engine.start()
        engine.sendCommand("uci")
        engine.sendCommand("setoption name EvalFile value /tmp/unvalidated.nnue")
        engine.sendCommand("isready")
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

        engine.start()
        engine.sendCommand("uci")
        engine.sendCommand("isready")
        #expect(sink.wait(timeout: 10.0) { $0 == "readyok" } != nil)

        engine.sendCommand("position startpos")
        engine.sendCommand("go depth 8")
        #expect(sink.wait(timeout: 10.0) { $0.hasPrefix("bestmove ") } != nil)

        engine.suspend()
        sink.removeAll()
        engine.resume()
        engine.sendCommand("uci")
        engine.sendCommand("isready")
        #expect(sink.wait(timeout: 2.0) { $0 == "readyok" } != nil)

        engine.sendCommand("ucinewgame")
        engine.sendCommand("position startpos moves e2e4")
        engine.sendCommand("go depth 8")
        #expect(sink.wait(timeout: 5.0) { $0.hasPrefix("bestmove ") } != nil)
        engine.stop()
    }
}
