# Updating Stockfish

Use this procedure for an explicitly requested engine refresh, not for ordinary
documentation/test work. It can create commits and change consumer runtime
assets; obtain publication approval separately.

## Pin the source

Refresh the official `stockfish` remote and select an exact upstream revision:

```sh
git remote get-url stockfish
git fetch stockfish master
git log -1 --oneline stockfish/master
git diff --stat 'stockfish/master^{tree}' HEAD:ThirdParty/Stockfish
```

If the remote is absent, add
`https://github.com/official-stockfish/Stockfish.git` under that name. Record the
pinned SHA in [Provenance](Provenance.md), the README, and the update commit.
Do not derive lag only from old subtree metadata; compare the actual tree.

To inspect the most recent committed vendored-source update and its recorded
upstream SHA:

```sh
git log -1 --pretty=%B -- ThirdParty/Stockfish
```

This reports committed history, not any uncommitted candidate. Verify the
actual tree as described above rather than assuming that every historical
subtree marker identifies the current snapshot.

## Refresh and reconcile

When a commit is authorized, a squashed subtree pull is one option:

```sh
git subtree pull --prefix ThirdParty/Stockfish stockfish master --squash
```

To pin an explicitly chosen official release tag instead, use that tag rather
than `master`. For example, the following selects the historical `sf_18` tag;
it is an illustration, not the snapshot currently vendored by this package:

```sh
git subtree pull --prefix ThirdParty/Stockfish https://github.com/official-stockfish/Stockfish.git sf_18 --squash
```

Both commands create commits. When validation must remain uncommitted, export
the pinned upstream tree instead and verify exact tree identity before release.
Keep upstream files unmodified; integration belongs in the package-owned shim.

Upstream API or initialization changes can break the wrapper or its build
settings. Reconcile package-owned integration code rather than editing upstream
Stockfish merely to make an update compile.

Compare upstream `src/main.cpp` with `Sources/SFEngine/EmbeddedUCI.cpp`, even if
the build passes. Reconcile initialization, the retained UCI loop, network
preflight, source lists, and build definitions. Preserve stream redirection,
fake argv handling, ownership guards, callback ordering, and suspend/resume.
The startup-parity XCTest helps detect initialization drift.

## Reconcile assets and consumers

Check `EvalFileDefaultName` in `ThirdParty/Stockfish/src/evaluate.h`. If it
changes, download/verify the new network and update README, AGENTS,
Resources/NNUE/README, provenance, and filename-specific regression assertions.
Never commit the downloaded network or make SwiftPM fetch it during a build.

Update SwiftChessDemo's resource reference and bundled-network assertion when
needed. Keep an old local network until consumers no longer reference it, then
remove obsolete files during the coordinated release pass. A network-layout
change can require a new app asset even if the public wrapper API is unchanged.

## Validate and publish deliberately

Run [the full local gate](Testing.md#full-local-validation), inspect the
consumer's bundled assets, and exercise SwiftChessDemo when integration changes.
Update the changelog and retain GPL notices in source distributions. Compare
the pinned upstream tree with the vendored tree before publication; older
subtree metadata may remain stale after an exported-tree update.

Do not tag, push, create a release, or dispatch hosted work without the user's
corresponding approval. See [Provenance](Provenance.md) for the current identity.
