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
