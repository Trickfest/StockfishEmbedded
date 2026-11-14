# NNUE Files

NNUE stands for *Efficiently Updatable Neural Network*. Stockfish uses this
roughly 138 MB (132 MiB) data file to evaluate chess positions. It is required
for engine searches, but it is not source code or an executable.

This repository does not track the `.nnue` file, and the Swift package does not
download it. From a repository clone, run:

```
Scripts/download-nnue.sh
```

The current source expects `nn-68752b755c93.nnue`. The script reads that name
from Stockfish's `EvalFileDefaultName`, downloads the matching network from the
official Stockfish test server into this directory, and verifies that its
SHA-256 digest begins with the hash encoded in the filename. Existing files are
verified before reuse; pass `--force` to download a fresh copy.

The complete expected SHA-256 value for the current file is:

```text
68752b755c93e419e714829c4aac1bbd66e9509a96cf175be28a00164b6d7f21
```

File size: 138,360,528 bytes.

The `SFEngine` Swift package itself builds without this file. Runtime package
clients supply a local network URL with
`SFEngine(networkFileURL:lineHandler:)`; they may bundle this downloaded file or
manage a verified copy in app-owned storage. See the main README's
**Quick start with Swift Package Manager** section for the Xcode resource and
Swift initialization steps.

Update the app's copy whenever an engine update changes this filename. The
current snapshot uses Stockfish's SFNNv20 architecture. The preceding SFNNv18
`nn-c9e480e92425.nnue`, SFNNv17 `nn-252f33942263.nnue`, and older PSQT-layout
`nn-134a887f4c8f.nnue` cannot be
reused with this build, even if renamed. Keep an old local file only while a
consumer still needs its matching older engine; update both engine and app
resource together.

If you need to download it manually from the repository root:

```
mkdir -p Resources/NNUE
curl --proto '=https' --tlsv1.2 --location --fail --show-error \
  https://tests.stockfishchess.org/api/nn/nn-68752b755c93.nnue \
  --output Resources/NNUE/nn-68752b755c93.nnue
shasum -a 256 Resources/NNUE/nn-68752b755c93.nnue
```
