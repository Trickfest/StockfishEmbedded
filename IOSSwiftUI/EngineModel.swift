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
import Observation

// View model for the SwiftUI smoke test. It owns a single SFEngine instance,
// drives a short UCI command sequence, and exposes log/status for the UI.
@MainActor
@Observable
final class EngineModel {
    // Active engine for the current run; set to nil when idle to release C++ resources.
    private var engine: SFEngine?
    // Timeout task for the current run; cancelled whenever a run finishes.
    private var timeoutTask: Task<Void, Never>?
    // Token used to ignore stale timeout callbacks after a new run starts.
    private var runToken = UUID()

    // Accumulated engine output, shown in the scrollable log view.
    var log: String = ""
    // Whether the engine is currently running a search.
    var isRunning = false
    // Whether native teardown is still in progress.
    var isStopping = false
    // User-facing status text (Idle / Running / Finished).
    var status: String = "Idle"

    var canRun: Bool {
        !isRunning && !isStopping
    }

    // Starts a fixed smoke-test sequence: init UCI, set a position, run a short search.
    func runSmokeTest() {
        guard canRun else { return }
        startNewRun()
        let token = runToken

        // Capture engine output and forward it onto the main actor for UI updates.
        let engine = SFEngine(lineHandler: { [weak self] line in
            DispatchQueue.main.async { [weak self] in
                self?.handleLine(line, token: token)
            }
        })
        self.engine = engine

        // Minimal UCI handshake + one search.
        append("starting engine...")
        engine.start()
        engine.sendCommand("uci")
        engine.sendCommand("isready")
        engine.sendCommand("position startpos moves e2e4")
        engine.sendCommand("go depth 8")

        startTimeout()
    }

    // Stops the current run early (best-effort).
    func stop() {
        guard isRunning else { return }
        finishRun(reason: "stopped")
    }

    // Clears the log but keeps the running status intact.
    func clear() {
        log = ""
        if isRunning {
            status = "Running"
        } else if !isStopping {
            status = "Idle"
        }
    }

    // Reset state and cancel any prior run before starting a new one.
    private func startNewRun() {
        log = ""
        status = "Running"
        isRunning = true
        isStopping = false
        runToken = UUID()
        timeoutTask?.cancel()
        timeoutTask = nil
    }

    // Fails the run if we never see a bestmove within the timeout window.
    private func startTimeout() {
        let token = runToken
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            await MainActor.run {
                guard let self, self.isRunning, self.runToken == token else { return }
                self.append("timeout waiting for bestmove")
                self.finishRun(reason: "timeout")
            }
        }
    }

    // Append each line and finish when we see the UCI "bestmove".
    private func handleLine(_ line: String, token: UUID) {
        guard token == runToken, isRunning else { return }
        append(line)
        if line.hasPrefix("bestmove") {
            finishRun(reason: "bestmove")
        }
    }

    // Cleanly shut down the engine and update the UI state.
    private func finishRun(reason: String) {
        guard isRunning else { return }
        isRunning = false
        isStopping = true
        timeoutTask?.cancel()
        timeoutTask = nil

        let engineToStop = engine
        engine = nil
        status = "Stopping (\(reason))"
        let token = runToken

        // Stop the engine off the main thread to avoid blocking UI updates.
        if let engineToStop {
            DispatchQueue.global(qos: .userInitiated).async {
                engineToStop.stop()
                DispatchQueue.main.async { [weak self] in
                    self?.completeStop(reason: reason, token: token)
                }
            }
        } else {
            completeStop(reason: reason, token: token)
        }
    }

    private func completeStop(reason: String, token: UUID) {
        guard token == runToken, isStopping else { return }
        isStopping = false
        status = "Finished (\(reason))"
    }

    // Append a line to the log without losing existing output.
    private func append(_ line: String) {
        if log.isEmpty {
            log = line
        } else {
            log.append("\n")
            log.append(line)
        }
    }
}
