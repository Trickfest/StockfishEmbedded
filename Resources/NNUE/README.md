# NNUE Files

NNUE stands for *Efficiently Updatable Neural Network*. Stockfish uses this
roughly 99 MB (94 MiB) data file to evaluate chess positions. It is required for engine
searches, but it is not source code or an executable.

This repository does not track the `.nnue` file, and the Swift package does not
download it. From a repository clone, run:

```
Scripts/download-nnue.sh
```

The current source expects `nn-252f33942263.nnue`. The script reads that name
from Stockfish's `EvalFileDefaultName`, downloads the matching network from the
official Stockfish test server into this directory, and verifies that its
SHA-256 digest begins with the hash encoded in the filename. Existing files are
verified before reuse; pass `--force` to download a fresh copy.

The complete expected SHA-256 value for the current file is:

```text
252f33942263bc8b8f740ba8aec3fed5a159ff148113c47a55c18c33d6627ab3
```

File size: 98,668,604 bytes.

The `SFEngine` Swift package itself builds without this file. Runtime package
clients supply a local network URL with
`SFEngine(networkFileURL:lineHandler:)`; they may bundle this downloaded file or
manage a verified copy in app-owned storage. See the main README's
**Quick start with Swift Package Manager** section for the Xcode resource and
Swift initialization steps.

Update the app's copy whenever an engine update changes this filename. The
current snapshot removes Stockfish's older PSQT network data, so the previous
network cannot be reused with this build.

If you need to download it manually from the repository root:

```
mkdir -p Resources/NNUE
curl --proto '=https' --tlsv1.2 --location --fail --show-error \
  https://tests.stockfishchess.org/api/nn/nn-252f33942263.nnue \
  --output Resources/NNUE/nn-252f33942263.nnue
shasum -a 256 Resources/NNUE/nn-252f33942263.nnue
```
