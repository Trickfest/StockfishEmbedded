//
// StockfishEmbedded embeds Stockfish as an in-process engine for Apple platforms.
//
// See README.md and ThirdParty/Stockfish/Copying.txt for upstream attribution and license details.
//
// Licensed under the GNU General Public License v3.0.
// You may obtain a copy of the License at: https://www.gnu.org/licenses/gpl-3.0.html
// See the LICENSE file for more information.
//

// Provides an entry point to run Stockfish's UCI loop with custom streams.

#pragma once

#include <iosfwd>
#include <memory>
#include <optional>
#include <string>
#include <string_view>

namespace SFEmbedded {

// Owns one Stockfish UCI engine across temporary stream-ownership suspensions.
// Each run redirects process-wide std::cin/std::cout only until the UCI loop
// receives quit. Keeping this session alive preserves the parsed NNUE network
// while another embedded engine temporarily owns those streams.
class EmbeddedUCISession {
   public:
    explicit EmbeddedUCISession(std::optional<std::string> networkFilePath = std::nullopt);
    ~EmbeddedUCISession();

    EmbeddedUCISession(const EmbeddedUCISession&)            = delete;
    EmbeddedUCISession(EmbeddedUCISession&&)                 = delete;
    EmbeddedUCISession& operator=(const EmbeddedUCISession&) = delete;
    EmbeddedUCISession& operator=(EmbeddedUCISession&&)      = delete;

    void run(std::istream& in, std::ostream& out);

   private:
    class Impl;
    std::unique_ptr<Impl> impl_;
};

// Returns the official NNUE filename declared by the vendored Stockfish build.
std::string_view DefaultNetworkFileName();

}  // namespace SFEmbedded
