//
// StockfishEmbedded embeds Stockfish as an in-process engine for Apple platforms.
//
// See README.md and ThirdParty/Stockfish/Copying.txt for upstream attribution and license details.
//
// Licensed under the GNU General Public License v3.0.
// You may obtain a copy of the License at: https://www.gnu.org/licenses/gpl-3.0.html
// See the LICENSE file for more information.
//

// Stream buffer that emits complete lines via a callback.

#pragma once

#include <functional>
#include <ostream>
#include <streambuf>
#include <string>

namespace SFEmbedded {

// std::streambuf implementation that collects stdout into lines.
// Each completed line is forwarded through the provided callback.
class LineBufferStreambuf: public std::streambuf {
   public:
    using LineCallback = std::function<void(const std::string&)>;

    explicit LineBufferStreambuf(LineCallback cb) :
        callback_(std::move(cb)) {}

   protected:
    int_type overflow(int_type ch) override {
        // Ignore EOF and carriage returns; flush on newline.
        if (traits_type::eq_int_type(ch, traits_type::eof()))
            return traits_type::not_eof(ch);

        const char c = traits_type::to_char_type(ch);
        if (c == '\r')
            return traits_type::not_eof(ch);  // Ignore carriage returns

        if (c == '\n') {
            flush_line();
        } else {
            buffer_.push_back(c);
        }
        return traits_type::not_eof(ch);
    }

    int sync() override {
        // Flush any buffered partial line.
        flush_line();
        return 0;
    }

   private:
    void flush_line() {
        if (!callback_ || buffer_.empty())
            return;
        // The callback receives the line without the trailing newline.
        callback_(buffer_);
        buffer_.clear();
    }

    LineCallback callback_;
    std::string  buffer_;
};

}  // namespace SFEmbedded
