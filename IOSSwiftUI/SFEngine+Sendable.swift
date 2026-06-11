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

// SFEngine uses internal threads but is invoked from controlled contexts in this app.
// Mark it @unchecked Sendable so we can pass it across concurrency boundaries safely.
extension SFEngine: @unchecked Sendable {}
