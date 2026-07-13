//
// StockfishEmbedded embeds Stockfish as an in-process engine for Apple platforms.
//
// See README.md and ThirdParty/Stockfish/Copying.txt for upstream attribution and license details.
//
// Licensed under the GNU General Public License v3.0.
// You may obtain a copy of the License at: https://www.gnu.org/licenses/gpl-3.0.html
// See the LICENSE file for more information.
//

import Dispatch
import Darwin
import Foundation

private final class SmokeState: @unchecked Sendable {
    private let lock = NSLock()
    private var sawUCIOK = false
    private var sawReadyOK = false
    private var sawLegalBestmove = false

    func record(_ line: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        if line == "uciok" {
            sawUCIOK = true
        } else if line == "readyok" {
            sawReadyOK = true
        } else if line.range(
            of: #"^bestmove [a-h][1-8][a-h][1-8][nbrq]?(?: |$)"#,
            options: .regularExpression
        ) != nil {
            sawLegalBestmove = true
            return true
        }
        return false
    }

    var succeeded: Bool {
        lock.lock()
        defer { lock.unlock() }
        return sawUCIOK && sawReadyOK && sawLegalBestmove
    }
}

private func runSmoke() -> Int32 {
    let finished = DispatchSemaphore(value: 0)
    let state = SmokeState()

    let engine = SFEngine(lineHandler: { line in
        print(line)
        if state.record(line) {
            finished.signal()
        }
    })

    engine.start()
    engine.sendCommand("uci")
    engine.sendCommand("isready")
    engine.sendCommand("position startpos moves e2e4")
    engine.sendCommand("go depth 8")

    let timeout = DispatchTime.now() + .seconds(30)
    let waitResult = finished.wait(timeout: timeout)
    engine.stop()

    guard waitResult == .success, state.succeeded else {
        fputs("SFEngine Swift smoke test failed: expected uciok, readyok, and a legal bestmove.\n", stderr)
        return EXIT_FAILURE
    }
    return EXIT_SUCCESS
}

exit(runSmoke())
