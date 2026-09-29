//
// StockfishEmbedded embeds Stockfish as an in-process engine for Apple platforms.
//
// See README.md and ThirdParty/Stockfish/Copying.txt for upstream attribution and license details.
//
// Licensed under the GNU General Public License v3.0.
// You may obtain a copy of the License at: https://www.gnu.org/licenses/gpl-3.0.html
// See the LICENSE file for more information.
//

// Minimal shim to run Stockfish's UCI loop against caller-provided streams.

#include "EmbeddedUCI.hpp"

#include <filesystem>
#include <iostream>
#include <locale>
#include <memory>
#include <sstream>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

#include "attacks.h"
#include "evaluate.h"
#include "misc.h"
#include "nnue/network.h"
#include "nnue/nnue_misc.h"
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
    StreamRedirector(std::istream& in, std::ostream& out) :
        oldInFlags_(std::cin.flags()),
        oldOutFlags_(std::cout.flags()),
        oldInPrecision_(std::cin.precision()),
        oldOutPrecision_(std::cout.precision()),
        oldInWidth_(std::cin.width()),
        oldOutWidth_(std::cout.width()),
        oldInFill_(std::cin.fill()),
        oldOutFill_(std::cout.fill()),
        oldInState_(std::cin.rdstate()),
        oldOutState_(std::cout.rdstate()),
        oldInLocale_(std::cin.getloc()),
        oldOutLocale_(std::cout.getloc()) {
        oldInTie_  = std::cin.tie(nullptr);
        oldInBuf_  = std::cin.rdbuf(in.rdbuf());
        oldOutBuf_ = std::cout.rdbuf(out.rdbuf());

        // Host formatting such as hex or unitbuf must not alter UCI text or
        // fragment it into partial callback lines.
        std::cin.flags(std::ios_base::skipws | std::ios_base::dec);
        std::cout.flags(std::ios_base::skipws | std::ios_base::dec);
        std::cin.precision(6);
        std::cout.precision(6);
        std::cin.width(0);
        std::cout.width(0);
        std::cin.fill(' ');
        std::cout.fill(' ');
        std::cin.imbue(std::locale::classic());
        std::cout.imbue(std::locale::classic());
    }
    ~StreamRedirector() {
        std::cout.flush();
        std::cin.rdbuf(oldInBuf_);
        std::cout.rdbuf(oldOutBuf_);
        std::cin.tie(oldInTie_);

        std::cin.flags(oldInFlags_);
        std::cout.flags(oldOutFlags_);
        std::cin.precision(oldInPrecision_);
        std::cout.precision(oldOutPrecision_);
        std::cin.width(oldInWidth_);
        std::cout.width(oldOutWidth_);
        std::cin.fill(oldInFill_);
        std::cout.fill(oldOutFill_);
        std::cin.imbue(oldInLocale_);
        std::cout.imbue(oldOutLocale_);

        // rdbuf() clears stream state. Restore the host's prior state when it
        // cannot trigger a host-configured iostream exception in this
        // no-exceptions build.
        if ((oldInState_ & std::cin.exceptions()) == std::ios_base::goodbit)
            std::cin.clear(oldInState_);
        if ((oldOutState_ & std::cout.exceptions()) == std::ios_base::goodbit)
            std::cout.clear(oldOutState_);
    }
    
private:
    std::streambuf* oldInBuf_  = nullptr;
    std::streambuf* oldOutBuf_ = nullptr;
    std::ostream*   oldInTie_  = nullptr;
    std::ios_base::fmtflags oldInFlags_;
    std::ios_base::fmtflags oldOutFlags_;
    std::streamsize         oldInPrecision_;
    std::streamsize         oldOutPrecision_;
    std::streamsize         oldInWidth_;
    std::streamsize         oldOutWidth_;
    char                    oldInFill_;
    char                    oldOutFill_;
    std::ios_base::iostate  oldInState_;
    std::ios_base::iostate  oldOutState_;
    std::locale             oldInLocale_;
    std::locale             oldOutLocale_;
};

}  // namespace

std::string_view DefaultNetworkFileName() {
    return EvalFileDefaultName;
}

class EmbeddedUCISession::Impl {
   public:
    explicit Impl(std::optional<std::string> networkFilePath) :
        networkFilePath_(std::move(networkFilePath)) {}

    void run(std::istream& in, std::ostream& out) {
        if (!uci_ && !initialize(in, out))
            return;

        // Redirect only while Stockfish owns and services this command stream.
        // The UCI engine itself remains alive after quit so a later run can
        // reuse its already-loaded NNUE network.
        StreamRedirector redirect(in, out);
        uci_->loop();
    }

   private:
    bool initialize(std::istream& in, std::ostream& out) {
        using namespace Stockfish;

#if defined(NNUE_EMBEDDING_OFF)
        if (!networkFilePath_.has_value()) {
            out << "info string StockfishEmbedded error: this build requires a caller-provided "
                   "NNUE network file"
                << std::endl;
            return false;
        }
#endif

        if (networkFilePath_.has_value()) {
            const auto path = path_from_utf8(*networkFilePath_);
            std::error_code fileError;
            if (!std::filesystem::is_regular_file(path, fileError)) {
                out << "info string StockfishEmbedded error: the configured NNUE network file "
                       "is missing or unreadable"
                    << std::endl;
                return false;
            }

            // Stockfish's search path terminates the process when no compatible
            // network is loaded. Preflight with the same parser so a bad caller-
            // supplied file becomes an ordinary wrapper error instead.
            auto                 network = std::make_unique<Eval::NNUE::Network>();
            Eval::NNUE::EvalFile evalFile;
            network->load_external({}, path, evalFile);
            if (!evalFile.current.has_value()) {
                out << "info string StockfishEmbedded error: the configured NNUE network is "
                       "incompatible with this Stockfish build"
                    << std::endl;
                return false;
            }
        }

        // Construction can write through Stockfish's process-wide output, so
        // initialize under the same scoped redirect used by the UCI loop.
        StreamRedirector redirect(in, out);
        std::cout << engine_info() << std::endl;

        // Mimic Stockfish's main() setup so evaluation tables and options are ready.
        Attacks::init();
        Position::init();

        // Stockfish expects argc/argv through CommandLine; fake them.
        std::vector<std::string> argvStorage = {"stockfish"};
        std::vector<char*>       argv;
        argv.reserve(argvStorage.size());
        for (auto& arg : argvStorage)
            argv.push_back(arg.data());

        // Construct the UCI engine and initialize tuning/options. This mirrors the
        // CommandLine handoff in the vendored Stockfish main.cpp.
        auto cli = CommandLine(static_cast<int>(argv.size()), argv.data());
        uci_     = std::make_unique<UCIEngine>(std::move(cli));

        if (networkFilePath_.has_value()) {
            std::istringstream evalFileOption("name EvalFile value " + *networkFilePath_);
            uci_->engine_options().setoption(evalFileOption);
        }

        Tune::init(uci_->engine_options());
        return true;
    }

    const std::optional<std::string> networkFilePath_;
    std::unique_ptr<Stockfish::UCIEngine> uci_;
};

EmbeddedUCISession::EmbeddedUCISession(std::optional<std::string> networkFilePath) :
    impl_(std::make_unique<Impl>(std::move(networkFilePath))) {}

EmbeddedUCISession::~EmbeddedUCISession() = default;

void EmbeddedUCISession::run(std::istream& in, std::ostream& out) { impl_->run(in, out); }

}  // namespace SFEmbedded
