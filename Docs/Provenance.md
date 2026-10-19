# Provenance

StockfishEmbedded vendors an exact source snapshot from
[official Stockfish](https://github.com/official-stockfish/Stockfish) under
`ThirdParty/Stockfish`:

```text
49ea5ded38315cff8e67f4a677a9e7811612fbf6
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

This snapshot expects `nn-252f33942263.nnue`, 98,668,604 bytes, with SHA-256:

```text
252f33942263bc8b8f740ba8aec3fed5a159ff148113c47a55c18c33d6627ab3
```

The file is an ignored local asset, not a package resource. The download helper
verifies the hash prefix encoded in its filename; the full local gate also
checks the documented full digest against the file. See
[network setup](../Resources/NNUE/README.md). The previous PSQT network layout
is incompatible with this snapshot.

## Test fixtures and notices

The default soak files are attributed to Stockfish's GPL benchmark positions
in [Resources/Soak/README.md](../Resources/Soak/README.md). Preserve attribution
when reusing them; do not copy GPL test code/corpora into a permissive package
for superficial test parity.

Keep the root [GPL license](../LICENSE), upstream
[Copying.txt](../ThirdParty/Stockfish/Copying.txt), and upstream attribution.
For the existing distribution notice, see [Licensing](../README.md#licensing).
Do not prune vendored notices or documentation while reorganizing wrapper docs.
