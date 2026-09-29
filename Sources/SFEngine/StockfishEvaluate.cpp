//
// StockfishEmbedded embeds Stockfish as an in-process engine for Apple platforms.
//
// See README.md and ThirdParty/Stockfish/Copying.txt for upstream attribution and license details.
//
// Licensed under the GNU General Public License v3.0.
// You may obtain a copy of the License at: https://www.gnu.org/licenses/gpl-3.0.html
// See the LICENSE file for more information.
//

// Keep package-specific warning policy outside the vendored Stockfish snapshot.
// The result is intentionally narrowed to `int` in the upstream implementation.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wshorten-64-to-32"

#include "../../ThirdParty/Stockfish/src/evaluate.cpp"

#pragma clang diagnostic pop
