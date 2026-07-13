//
// StockfishEmbedded embeds Stockfish as an in-process engine for Apple platforms.
//
// See README.md and ThirdParty/Stockfish/Copying.txt for upstream attribution and license details.
//
// Licensed under the GNU General Public License v3.0.
// You may obtain a copy of the License at: https://www.gnu.org/licenses/gpl-3.0.html
// See the LICENSE file for more information.
//

// Stream buffer backed by a blocking queue of strings.

#pragma once

#include <istream>
#include <streambuf>
#include <string>

#include "ThreadSafeQueue.hpp"

namespace SFEmbedded {

// std::streambuf implementation that exposes a ThreadSafeQueue as an input stream.
// The Stockfish UCI loop reads from this as if it were std::cin.
class CommandStreambuf: public std::streambuf {
   public:
    explicit CommandStreambuf(ThreadSafeQueue<std::string>& queue) :
        queue_(queue) {
        // setg requires non-null pointers even before data is available.
        setg(buffer_, buffer_, buffer_);
    }

   protected:
    int_type underflow() override {
        // If we still have unread characters in the get area, return them.
        if (gptr() < egptr())
            return traits_type::to_int_type(*gptr());

        // Block until a command is available or the queue is closed.
        if (!queue_.pop(current_))
            return traits_type::eof();

        // Ensure each command ends with a newline so UCI parsing works.
        if (current_.empty() || current_.back() != '\n')
            current_.push_back('\n');

        char* data = current_.data();
        setg(data, data, data + current_.size());
        return traits_type::to_int_type(*gptr());
    }

   private:
    ThreadSafeQueue<std::string>& queue_;
    std::string                   current_;
    // Placeholder buffer used only to satisfy setg during construction.
    char                          buffer_[1];
};

}  // namespace SFEmbedded
