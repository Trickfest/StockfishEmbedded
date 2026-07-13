# NNUE Files

This repo does not track the `.nnue` file. Download it before you build or run
anything. From the repo root:

```
Scripts/download-nnue.sh
```

The script reads the required filename from Stockfish's current
`EvalFileDefaultName`, downloads the matching network into this directory, and
verifies that its SHA-256 digest begins with the hash encoded in the `nn-*.nnue`
filename. Existing files are verified before they are reused; pass `--force`
to download a fresh copy.
If you need to do it manually, use the filename in
`ThirdParty/Stockfish/src/evaluate.h`:

```
mkdir -p Resources/NNUE
curl -L --fail https://tests.stockfishchess.org/api/nn/nn-af1339a6dea3.nnue -o Resources/NNUE/nn-af1339a6dea3.nnue
```
