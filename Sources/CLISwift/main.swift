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
import Foundation

let finished = DispatchSemaphore(value: 0)

let engine = SFEngine(lineHandler: { line in
    print(line)
    if line.hasPrefix("bestmove") {
        finished.signal()
    }
})

engine.start()
engine.sendCommand("uci")
engine.sendCommand("isready")
engine.sendCommand("position startpos moves e2e4")
engine.sendCommand("go depth 8")

let timeout = DispatchTime.now() + .seconds(30)
_ = finished.wait(timeout: timeout)
engine.stop()
