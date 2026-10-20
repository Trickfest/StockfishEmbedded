# Provenance

StockfishEmbedded vendors an exact source snapshot from
[official Stockfish](https://github.com/official-stockfish/Stockfish) under
`ThirdParty/Stockfish`:

```text
effdc3fd3f6de6e75fe1374a51a7a7eed66f880b
```

## Source identity

Clones include the snapshot directly; there is no engine submodule to fetch.
The repository originated with `git subtree --squash`. Later updates may use an
exported upstream tree so a candidate can be tested before committing. In that
case older `git-subtree-split` metadata is not the current source identity.
These updates retain reviewable vendored snapshots, not the complete upstream
commit history. Compare actual trees before reporting upstream lag.

Upstream Stockfish files are unmodified. The embedded adaptation, stream
transport, external-network preflight, and lifecycle handling live outside
that tree, principally in `Sources/SFEngine`.

## Network identity

This SFNNv18 snapshot expects `nn-c9e480e92425.nnue`, 113,178,980 bytes, with
SHA-256:

```text
c9e480e92425f887df6ab9b05c6180fbd762b07879df9d9845f1aa75440caa73
```

The file is an ignored local asset, not a package resource. The download helper
verifies the hash prefix encoded in its filename; the full local gate also
checks the documented full digest against the file. See
[network setup](../Resources/NNUE/README.md). The preceding SFNNv17 network
`nn-252f33942263.nnue` and older PSQT-layout networks are incompatible with
this snapshot.

## Test fixtures and notices

The default soak files are attributed to Stockfish's GPL benchmark positions
in [Resources/Soak/README.md](../Resources/Soak/README.md). Preserve attribution
when reusing them; do not copy GPL test code/corpora into a permissive package
for superficial test parity.

Keep the root [GPL license](../LICENSE), upstream
[Copying.txt](../ThirdParty/Stockfish/Copying.txt), and upstream attribution.
For the existing distribution notice, see [Licensing](../README.md#licensing).
Do not prune vendored notices or documentation while reorganizing wrapper docs.
