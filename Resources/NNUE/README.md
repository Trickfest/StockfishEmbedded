# NNUE Files

This repo does not track the `.nnue` file. Download it before you build or run
anything. From the repo root:

```
Scripts/download-nnue.sh
```

The script reads the required filename from Stockfish's current
`EvalFileDefaultName` and downloads the matching network into this directory.
If you need to do it manually, use the filename in
`ThirdParty/Stockfish/src/evaluate.h`:

```
mkdir -p Resources/NNUE
curl -L --fail https://tests.stockfishchess.org/api/nn/nn-af1339a6dea3.nnue -o Resources/NNUE/nn-af1339a6dea3.nnue
```
