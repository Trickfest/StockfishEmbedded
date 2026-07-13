# Soak Positions

The FEN positions in `positions.txt` and `positions_chess960.txt` are derived
from Stockfish's benchmark defaults in `ThirdParty/Stockfish/src/benchmark.cpp`
from the Stockfish project (GPL-3.0). See `ThirdParty/Stockfish/Copying.txt`
for the license.

Each non-comment line is either `startpos` or a four/six-field FEN. A FEN may
end with `moves` followed by one or more UCI coordinate moves, matching
Stockfish's benchmark-position format.
