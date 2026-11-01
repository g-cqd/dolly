# Rules

dolly finds the four kinds of clone. `dolly rules <id>` prints each rule's rationale and suggested fix.

| Rule | Finds | Default |
| --- | --- | --- |
| `exact-clone` | Identical token sequences (Type 1) duplicated across the corpus. | warning |
| `near-clone` | Sequences identical up to identifiers and literals (Type 2). | warning |
| `structural-clone` | Similar regions above the similarity threshold, with their statements in the same order (Type 3). | warning |
| `semantic-clone` | Behaviorally equivalent regions written in different idioms (Type 4), by embedding similarity. Opt-in with `--semantic`, macOS. | warning |

The first three are always on. A group found only in test code is a note whatever its severity.

## How it works

Tokens are interned into compact records. Exact and near clones come from a suffix-array pass over each token lane (raw for exact,
normalized for near), with declaration boundaries as separators so a duplicate in the same file behaves like one across files.
Structural clones use prefix filtering, which keeps every pair above the threshold, then an exact Jaccard check and a token
longest-common-subsequence gate that rejects scrambled statement bags. A cache of per-file facts lets a warm run skip parsing.

## What it misses

Periodic runs inside one type, dense-edit pairs below the threshold, and the Type 4 clones `--semantic` aims at are accepted
misses of the token engine. They are listed in `Tests/DollyCoreTests/Fixtures/KnownGaps.md`, each pinned by a test.
