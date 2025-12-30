// EmbeddedUCI.hpp
// Provides an entry point to run Stockfish's UCI loop with custom streams.
#pragma once

#include <iosfwd>

namespace SFEmbedded {

// Runs the Stockfish UCI loop using caller-provided streams instead of std::cin/std::cout.
// This is the core shim that lets the engine live inside an app without touching global IO.
void RunStockfishUCI(std::istream& in, std::ostream& out);

}  // namespace SFEmbedded
