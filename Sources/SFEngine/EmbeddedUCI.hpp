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

namespace SFEmbedded {

// Runs the Stockfish UCI loop using caller-provided streams instead of std::cin/std::cout.
// This is the core shim that lets the engine live inside an app without touching global IO.
void RunStockfishUCI(std::istream& in, std::ostream& out);

}  // namespace SFEmbedded
