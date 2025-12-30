// EmbeddedUCI.cpp
// Minimal shim to run Stockfish's UCI loop against caller-provided streams.
#include "EmbeddedUCI.hpp"

#include <iostream>
#include <memory>
#include <string>
#include <vector>

#include "bitboard.h"
#include "misc.h"
#include "position.h"
#include "tune.h"
#include "uci.h"

namespace SFEmbedded {
namespace {

// RAII helper to swap std::cin/std::cout rdbuf for the duration of the engine run.
// Stockfish reads from std::cin and writes to std::cout, so redirecting those
// buffers lets us feed commands and capture output without modifying upstream code.
class StreamRedirector {
public:
    StreamRedirector(std::istream& in, std::ostream& out) {
        oldInBuf_  = std::cin.rdbuf(in.rdbuf());
        oldOutBuf_ = std::cout.rdbuf(out.rdbuf());
    }
    ~StreamRedirector() {
        std::cin.rdbuf(oldInBuf_);
        std::cout.rdbuf(oldOutBuf_);
    }
    
private:
    std::streambuf* oldInBuf_  = nullptr;
    std::streambuf* oldOutBuf_ = nullptr;
};

}  // namespace

void RunStockfishUCI(std::istream& in, std::ostream& out) {
    using namespace Stockfish;

    // Redirect std::cin/std::cout for the duration of the UCI loop.
    StreamRedirector redirect(in, out);
    std::cout << engine_info() << std::endl;

    // Mimic Stockfish's main() setup so evaluation tables and options are ready.
    Bitboards::init();
    Position::init();

    // Stockfish expects argc/argv in its UCIEngine constructor; fake them.
    std::vector<std::string> argvStorage = {"stockfish"};
    std::vector<char*>       argv;
    argv.reserve(argvStorage.size());
    for (auto& arg : argvStorage)
        argv.push_back(arg.data());

    // Construct the UCI engine and initialize tuning/options.
    UCIEngine uci(static_cast<int>(argv.size()), argv.data());
    Tune::init(uci.engine_options());

    // Blocking UCI loop; returns when "quit" is received or input closes.
    uci.loop();
}

}  // namespace SFEmbedded
