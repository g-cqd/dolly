# dolly

Duplicate-code detection for Swift: exact, near, and structural clones.

Built on [swift-syntax], modeled on [arcleak]: source-level analysis (no build
required), fixture-gated precision, a comment directive DSL for auditable
acceptance, baselines for adoption on legacy code, and SARIF for code scanning.

**Status: working detector.** The engine runs a zero-copy interned token
pipeline: extraction interns every token into 16-byte records (normalization
at intern time), the exact and near stages each run a suffix-array (SA-IS +
LCP) pass over their own id lane — raw ids for exact, normalized ids for
near — with declaration-boundary separators so same-file duplicates
behave exactly like cross-file ones, and the structural stage uses
SourcererCC-style prefix+position filtering (deterministic candidates —
provably a superset of every pair above the similarity threshold) verified
by exact Jaccard plus a NIL-style token-LCS gate that rejects scrambled
statement bags. The structural stage runs concurrently with the serial
suffix-array work. A fail-open facts cache makes warm runs skip parsing
and extraction entirely.

## Rules

| Rule | Detects | Default |
|------|---------|---------|
| `exact-clone` | identical token sequences (Type-1) duplicated across the corpus | warning |
| `near-clone` | sequences identical up to identifiers and literals (Type-2) | warning |
| `structural-clone` | similar regions above the similarity threshold, order-verified (Type-3) | warning |
| `semantic-clone` | behaviorally equivalent regions in different idioms (Type-4), by embedding similarity — opt-in `--semantic`, macOS-only | warning |

`dolly rules <id>` prints each rule's rationale and suggested fix.
`semantic-clone` is off unless `--semantic` is passed (see [Semantic
clones](#semantic-clones-opt-in-macos-only) below); the token/structural
rules are the always-on default. Accepted misses of the token engine
(in-type periodic runs, dense-edit pairs below threshold, and the Type-4
clones `--semantic` targets) are catalogued in
`Tests/DollyCoreTests/Fixtures/KnownGaps.md`, each pinned by a
characterization test.

## CLI

```sh
dolly analyze Sources            # xcode-format diagnostics, exit 1 on errors
dolly analyze --format sarif .   # SARIF 2.1.0 (also: --format json)
dolly analyze --strict Sources   # exit 1 on any warning or error; notes never fail
dolly analyze --semantic Sources # + Type-4 (idiom-level) clones, macOS-only
dolly rules                      # list rules; `rules <id>` explains one
```

Clone-group findings anchor at the first member and carry every other
member both in the note text and as structured locations (SARIF
`relatedLocations`, JSON `related`).

## CLI and JSON contract (1.x)

Within 1.x, these do not change incompatibly: the `analyze` command and the
flags below, the exit codes, the JSON field names, and the fingerprint.

### Stable surface

| Flag | Meaning |
|------|---------|
| `analyze <paths…>` | files or directories to analyze (default `.`) |
| `--format` | `xcode` (default), `json` or `sarif` |
| `--only <file>` | report only findings touching this file; repeatable |
| `--only-from <file>` | the same, one path per line; `-` reads stdin |
| `--relative-to <dir>` | print paths relative to `<dir>`; see [Baselines and fingerprints](#baselines-and-fingerprints) |
| `--baseline <file>` | filter out findings the baseline records |
| `--write-baseline <file>` | write the current findings as a baseline, then exit 0 |
| `--config <file>` | configuration file (default `./.dolly.json`) |
| `--cache-path <file>`, `--no-cache` | facts cache file; or disable the cache |
| `--strict` | fail on any warning or error; notes never fail |
| `--include`, `--exclude` | region filters: `preview`, `debug`, `test`, `mock`, `generated`, `script`, `all` |

### Exit codes

| Code | Meaning |
|------|---------|
| `0` | the gate passed; see [Exit codes](#exit-codes) |
| `1` | the gate failed on findings, and nothing else |
| `64` | usage error, including `--write-baseline` with a scope |
| `70` | nothing analyzed (stdout names the skipped files), or cancelled (stdout empty) |
| `78` | invalid configuration, or a missing or malformed baseline |

### `--only` scope

The whole corpus is analyzed; only the report is scoped. A finding is kept
when any of its locations (anchor or `related`) is in scope, and it is reported
at its first in-scope location. The rest go to `outOfScope` in JSON and to the
summary count. Scope entries are canonicalized like finding paths, so
`--relative-to` does not change which findings are in scope. An empty scope
reports nothing and exits 0. See [Scope-file hygiene](#scope-file-hygiene).

A clone group in scope only through a non-anchor member is reported at that
member, with the original anchor first in `related`. Its `fingerprint` and
`fingerprintAnchor` stay those of the original anchor, so baselines keep matching.

### JSON report

`--format json` prints one object. Optional keys are omitted when unset.

| Top-level field | Meaning |
|-----------------|---------|
| `schemaVersion` | `1`, shared by arcleak, dolly and deadwood |
| `findings`, `outOfScope` | findings to act on; findings outside `--only` |
| `suppressed` | findings silenced by a directive, each `{finding, reason}` |
| `degradedFiles` | files skipped or read with errors, each `{path, detail}` |
| `analyzedFileCount`, `cacheHits`, `cacheMisses` | counts for the run |
| `wasCancelled` | always `false` in printed output (a cancelled run prints nothing) |
| `semanticNote`, `contextNote` | optional notes, present when there is something to say |

| Finding field | Meaning |
|---------------|---------|
| `rule` | `exact-clone`, `near-clone`, `structural-clone` or `semantic-clone` |
| `severity` | `note`, `warning` or `error` |
| `path`, `line`, `column` | the anchor; `line` is 1-based, `column` counts UTF-8 bytes |
| `message`, `note` | one-line description; `note` is optional (clone groups list `duplicates: …`) |
| `related` | optional `[{path, line, column}]`, the other members; omitted when empty |
| `fingerprint` | stable identity hash; baselines match on it |
| `fingerprintAnchor` | optional `{path, line, column}`: the original anchor of a finding moved by `--only` |

`fingerprintPath` is never emitted, although the decoder reads it.

`schemaVersion` changes only on a breaking change: a field removed, renamed,
retyped or made required; a meaning changed; or a closed value set (rule ids,
severities) changed. Consumers ignore unknown fields and reject a higher version.

### Facts cache

The default is `~/Library/Caches/dolly/<workspace>/facts.json` on macOS, where
`<workspace>` hashes the repository root found from the working directory (the
working directory itself, outside a repository). Writes are atomic and each
entry is checked against its file's content, so concurrent runs never read torn
or wrong facts; at worst one run's update is lost. Each run rewrites the file
with its own files, so parallel CI jobs on one machine should each pass their
own `--cache-path`, which avoids lost updates and evictions. See
[Facts cache](#facts-cache).

### Baselines and fingerprints

- `fingerprint` hashes rule, path, line, column and message. The path is
  repository-relative by default, so a committed baseline matches on any machine
  ([details](#fingerprints-are-portable-by-default)).
- `--relative-to <dir>` makes the hashed path relative to `<dir>` too. Baselines
  match only between runs with the same `--relative-to`, or both without it. At
  the repository root it hashes the same paths as none.
- Line and column are hashed, so an edit above a baselined finding re-surfaces
  it. Regenerate baselines after large refactors.
- New findings only: `dolly analyze . --write-baseline base.json` on the base
  branch, then `dolly analyze . --baseline base.json --only-from changed.txt`
  on the pull request.

## Semantic clones (opt-in, macOS-only)

The default engine is token-based, so it cannot see Type-4 clones — two
regions that compute the same result through different token shapes (a
`for` loop vs `reduce`, iteration vs recursion). `--semantic` adds a pass
that embeds each function/initializer snippet with a semantic model,
groups regions whose embeddings are close (cosine) and whose identifier
vocabularies overlap (Jaccard), and reports the `semantic-clone` rule for
groups the token/structural stages did not already claim.

```sh
dolly analyze --semantic Sources                       # NLContextual (default)
dolly analyze --semantic --embedding-preset strict .   # tighter thresholds
dolly analyze --semantic --embedding-bundle Models/MiniLM Sources
dolly analyze --semantic --semantic-max-group 25 .     # cap group size (default)
```

- **Default provider — zero download.** With just `--semantic`, dolly uses
  Apple's on-device `NLContextualEmbedding` (macOS 14+). **Honest caveat:**
  that is an English *natural-language* model, not code-trained, so its
  recall on idiom-level clones is materially lower than a code embedding
  model. It reliably recovers lexically-close idiom swaps; it misses more
  distant ones. On large, boilerplate-heavy corpora it also tends to
  *over-cluster* (many similar-looking visitor/handler methods collapse into
  one big group) — prefer `--embedding-bundle` or `--embedding-preset strict`
  there.
- **Group-size cap.** A semantic group larger than `--semantic-max-group`
  (default 25) is dropped as noise: a group that big is the embedding-collapse
  pathology, not a clone family (the NL model fuses hundreds of plain
  declarations into one cone — measured on a 330-file corpus, a 272-member
  group). The cap only ever removes oversized groups, so tight code-trained
  bundles (typical max ~5 members) are unaffected; `0` disables it.
- **Higher recall — bring a bundle.** `--embedding-bundle <dir>` points at a
  directory holding a Core ML model (`Model.mlpackage` / `*.mlmodelc`) plus its
  WordPiece vocabulary (`vocab.txt`, or the vocab inside `tokenizer.json`) — e.g.
  an all-MiniLM-L6-v2 export. Such bundles catch clones the NL model can't.
  Tokenization is **WordPiece** (BERT-family) and in-house — dolly links no
  HuggingFace stack, and `WordPieceTokenizer` is pinned token-for-token against
  `swift-transformers`. BPE/SentencePiece bundles fall back to the default
  provider rather than tokenizing wrongly.
  **Prefer a sentence-embedding model over a masked-LM checkpoint:** byte-level
  BPE shipped briefly in v0.5.0 to allow CodeBERT, then was withdrawn once
  measured — on arcleak/Sources, MiniLM produced 4 candidate groups where
  CodeBERT produced 30, because a masked-LM's raw vectors are anisotropic, so
  everything looks similar and the groups smear. "Code-trained" is not the
  property that matters; cosine-comparability is.
- **Batteries included — the `dolly-full` build.** The
  `dolly-full-<version>-macos-arm64` release archive ships an all-MiniLM-L6-v2
  (Apache-2.0) Core ML bundle at `Models/` next to the binary. dolly discovers
  a model adjacent to the executable automatically (checked before the
  NLContextual default), so `dolly --semantic` uses the embedding model out of
  the box — no `--embedding-bundle` flag. Delete `Models/` to fall back to the
  on-device provider. `DOLLY_EMBEDDING_BUNDLE=<dir>` overrides the search for
  installs that separate the binary from its resources (`bin/` + `share/`); an
  explicit `--embedding-bundle` still wins over both. The plain `dolly` archive
  has no model and behaves exactly as before (NLContextual default). The
  status note names the model that actually ran (`… via bundle:MiniLM` vs
  `… via NLContextualEmbedding`).
- **Presets.** `--embedding-preset balanced` (default: cosine ≥ 0.85,
  Jaccard ≥ 0.20), `strict` (0.90 / 0.30), or `loose` (0.80 / 0.10).
- **macOS-only, graceful.** The capability needs CoreML / NaturalLanguage.
  On Linux (or when a provider/asset is unavailable), `--semantic` prints a
  note and proceeds structural-only — it never fails the run. Without
  `--semantic`, output is byte-identical to the token-only default.

`semantic-clone` findings reuse the clone-group shape: one finding per
group, anchored at the first member, with every other member in the note
and as SARIF `relatedLocations` / JSON `related`.

### Facts cache

Warm runs skip parsing and extraction via a per-file facts cache. Each entry
uses a content fingerprint; the file also names the executable build and the
complete configuration, including rules. A rebuild or configuration change
starts cold even when the displayed version is unchanged. The loader checks
that identity before decoding the payload. A corrupt or stale cache behaves
as empty and is rewritten; entries for deleted files are pruned. A cache
larger than 256 MiB is neither read nor written.

```sh
dolly analyze Sources                       # cache at <user caches>/dolly/<workspace>/facts.json
dolly analyze --no-cache Sources            # disable for this run
dolly analyze --cache-path ~/Library/Caches/dolly/ci-facts.json Sources
```

The default cache lives in the user caches directory, one file per
repository. Keep an explicit `--cache-path` outside the analyzed repository
too: a cache file inside it changes the working tree on every run, which
`git status` and file watchers see.

The cache stores extraction facts only. Detection runs on every invocation;
the build and configuration identity keeps cached extraction facts tied to
the run that produced them.

## Configuration

`.dolly.json` in the working directory (or `--config`):

```json
{
  "rules": { "structural-clone": { "enabled": true, "severity": "warning" } },
  "exclude": ["Generated/"],
  "duplication": { "minimumTokens": 50, "minimumSimilarity": 0.8 }
}
```

Unknown rule ids fail closed. `minimumTokens` (1...10000) is the clone
floor; `minimumSimilarity` (0...1) gates near/structural similarity.

## Recommended configuration for real-world use

Guidance below is calibrated against a real 330-file Swift server codebase
(HTTP/1–3, TLS, HPACK/QPACK, epoll/kqueue/SwiftSystem transports).

### Default (token clones) — your CI gate

```sh
dolly analyze --strict Sources        # exact + near + structural, fail on any finding
```

- **Fast enough to gate every push.** The default token pass (exact + near +
  structural, one suffix-array build per id lane) runs in ~0.1 s on those 330 files
  (release) — sub-second, deterministic, no model, no network. This is the
  configuration to wire into CI.
- **`exact` / `near` are the high-signal rules.** They fire on genuinely shared
  helpers, copy-paste, and *parallel backend* families — e.g. `epoll` ↔ `kqueue`
  ↔ SwiftSystem connection bodies, or HTTP/2 ↔ HTTP/3 frame handling. Those are
  *true* clones but usually *intentional and idiomatic*: two backends kept in
  lockstep on purpose. **Review them; don't auto-fail on them.** Treat a new
  `exact`/`near` finding as "did I mean to duplicate this?", and accept the
  standing ones (below) so the gate stays about *new* duplication.
- **`structural` (Type-3)** catches near-copies with edited statements — real
  drift between things that were once identical. High value, slightly noisier
  than exact/near; keep it on, tune `minimumSimilarity` up if a codebase is
  boilerplate-heavy.
- **Least useful when** a codebase legitimately contains many small, near-
  identical value types — accept intentional parallel backends rather than
  lowering the token floor (a low `minimumTokens` turns ordinary boilerplate
  into noise).

### Where duplication lives

dolly weighs a clone by where it lives, with analyzerkit's project model:

- **Generated files** (a header naming a generator, a `Generated` directory,
  `*.generated.swift`) are left out of the corpus: generators repeat
  themselves by design and nobody edits their output.
- **Previews** (`#Preview` bodies, `PreviewProvider` types) repeat a view with
  small variations and never ship: a copy lying mostly in a preview is
  dropped, and a group left with one copy with it.
- **Test code** (a file importing XCTest or Testing, or a test path) is often
  deliberately repetitive, each test readable on its own: a group found only
  in test code is a note. A group spanning production and tests keeps its
  severity: tests re-implementing production logic are worth knowing about.

A line on stderr (`contextNote` in JSON) says what was left out.

### `--semantic` (Type-4) — targeted, not CI

```sh
# Best precision on code: a code-trained bundle, tight preset, capped groups.
dolly analyze --semantic --embedding-bundle Models/MiniLM \
              --embedding-preset strict --semantic-max-group 25 Sources
```

- **Prefer a bundle over the NL default.** `--embedding-bundle <MiniLM dir>` (or
  just the `dolly-full` build, which finds it automatically) is the path to real
  precision on source: it stays tight — small, meaningful groups — where the NL
  model smears. This is what to use when you actually want Type-4 results.
  Measured on a 156-file corpus: MiniLM ran **4.6× faster** than NLContextual
  (18.3 s vs 84.5 s) and produced tighter groups (275 vs 328 findings).
- **The zero-download NLContextual default is convenient but limited.** It is an
  English natural-language model, not code-trained, so on large homogeneous
  codebases it *over-clusters* (measured: a single 272-member group before the
  cap) and it is **orders of magnitude slower** — ~90 s vs ~0.1 s for the token
  default on the same 330 files (one on-device inference per snippet). Reserve
  it for small or quick scans, and **always keep the group-size cap on**
  (default `--semantic-max-group 25`).
- **What semantic is uniquely good at:** token-*invisible* idiom clones — two
  implementations that compute the same thing through different shapes, which
  `exact`/`near`/`structural` cannot see by construction (e.g. a TLS
  `SecurityChainValidator` ↔ `BoringSSLChainValidator` pair that validate the
  same chain via different platform APIs). **Least useful:** as a CI gate — it
  is slow, provider-dependent, and (on the NL model) precision-limited. Run it
  ad hoc when hunting for behavioral duplication, review the groups by hand.

### Accept intentional duplication, don't suppress the rule

Parallel backends and generated code are *meant* to be duplicated. Rather than
disabling `exact`/`near` globally (which would hide unintended copy-paste too),
accept each intentional instance at the source with a reason:

```swift
// @dl:accept -- epoll/kqueue transports are kept byte-for-byte parallel on purpose
```

or take a one-time baseline (`--write-baseline`) of the standing duplication so
CI only flags *new* findings. Keep the rule on; accept the instances.

## Accepting a finding

Directives use the `@` sigil with the `@dl:` or `@dolly:` namespace:

```swift
// @dl:accept -- <why this finding is intentional>
// @dl:accept:this <rule|all> [-- reason]
// @dl:disable <rule|all> … // @dl:enable <rule|all>
```

Baselines (`--write-baseline` / `--baseline`) filter pre-existing debt
without a wall of noise.

## Production notes

- Precision is fixture-gated: `Clean/` fixtures must stay silent, and
  `Findings/`/`Corpus/` goldens pin exact outputs. Run the whole gate with
  `Scripts/ci-local.sh`.
- dolly analyzes its own sources clean under `--strict` — that gate has
  already caught real duplication introduced during refactors.
- `Benchmarks/` is a local-only package-benchmark setup (never in CI);
  committed baselines track wallClock and mallocCountTotal per stage, plus
  an opt-in `--semantic` (NLContextual) benchmark.
- The semantic module is macOS-only and gated behind `canImport(CoreML)` /
  `canImport(NaturalLanguage)`; on Linux the embedding providers compile out
  and detection is token-only. Tokenization is built in (`WordPieceTokenizer`,
  pinned token-for-token against `swift-transformers` before that dependency was
  dropped), so the package resolves to swift-syntax + swift-argument-parser only.
- Implementation policy: warnings as errors, strict memory safety (the
  one `unsafe` fingerprint fast path is isolated and invariant-commented),
  Swift concurrency only (no GCD), swift-format gated.

## Using it as a pull-request gate

The corpus is always **everything**; only the *report* is scoped. Passing a
pull request's changed files as the input produces a different and wrong
answer, because these are whole-program analyses — a region is a clone because a matching region exists elsewhere in the corpus; shrink it and real clones vanish while intra-subset ones surface that the whole corpus attributes elsewhere.

```sh
git diff --name-only origin/main... -- '*.swift' > changed.txt
dolly analyze . --only-from changed.txt --baseline .dolly-baseline.json
```

`--only` (repeatable) and `--only-from <file|->` scope the report. Findings
outside the scope are kept on `outOfScope` and counted in the summary, so a
scoped run can never be mistaken for a clean one. An empty scope reports
nothing — a pull request that changed no Swift is not a licence to report the
whole repository.

### Fingerprints are portable by default

`Finding.fingerprint` — what `--baseline` matches and what SARIF exports as
`partialFingerprints` — hashes the path **relative to the repository root**,
found by walking up for `.git`. So a baseline committed to the repository
matches on any machine, and it does not matter whether the corpus was named as
a directory or as an explicit file list, or where the checkout lives.

`--relative-to <dir>` additionally changes the paths that are *displayed* (and
re-anchors fingerprints to that directory, which from the repository root is
the same anchor). SARIF uris must be repository-relative for code scanning to
link them, so pass it when uploading SARIF.

### SARIF locations

Every `artifactLocation.uri` in `--format sarif` is an RFC 3986 URI
reference, in one of two forms, the convention arcleak and deadwood share:

- **Relative**, when `--relative-to <dir>` is given, the file lies inside
  `<dir>`, and its path below `<dir>` is made only of `A–Z a–z 0–9`,
  `- . _ ~ ! $ & ' ( ) * + , = @` and `/`: the uri is that path, unescaped
  (`Sources/App/Box.swift`), with `"uriBaseId": "SRCROOT"`. The run's
  `originalUriBaseIds.SRCROOT.uri` is `<dir>` as a `file://` URI ending in `/`.
- **Absolute** otherwise: `file://` and the absolute path, every other byte
  percent-encoded as UTF-8 (`file:///Users/me/My%20Repo/Sources/Box%231.swift`),
  with no `uriBaseId`. Without `--relative-to`, every location takes this form.

Related locations and degraded-file notes follow the same rules. Paths are
canonical — absolute, symlinks resolved, and on macOS without `/private`
(`/var/folders/…`, `/tmp/…`) — whichever spelling of `<dir>` or of the
analyzed paths the command line used: through a symlink, or with `/private`.

A relative uri is never percent-encoded, so a reader that takes it as a plain
path still finds the file. A path that would need escapes — a space, a `#`,
any non-ASCII letter — is written as an absolute `file://` URI instead, which
every reader decodes. Those uris name the checkout, so they are the one part
of a `--relative-to` report that depends on where the repository lives;
GitHub code scanning converts absolute uris under the checkout directory to
relative ones.

SARIF columns count UTF-16 code units, and the run says so
(`"columnKind": "utf16CodeUnits"`: SARIF requires a run with results to
declare its unit, and this is the one consumers assume and editors index
lines in); a byte-order mark does not count. The `xcode` and `json` formats
keep swift-syntax's 1-based UTF-8 byte columns, the unit compilers print and
the one fingerprints hash.

### Scope-file hygiene

Scope lines tolerate CRLF endings and strip git's simple C-quoting, but paths
with non-ASCII bytes come out of `git diff --name-only` octal-escaped
(`"So\303\251.swift"`), which no unquoting here decodes. Set
`git config core.quotepath false` in the CI checkout so `git diff` emits raw
paths — one line, and every filename matches. When a non-empty scope matches no
analyzed file, dolly prints a warning to stderr rather than silently
reporting nothing.

### Exit codes

| Code | Meaning |
|---|---|
| `0` | the gate passed: no error-severity finding, so warnings and notes alone pass; with `--strict`, no warning or error. Also after `--write-baseline` |
| `1` | the gate failed on findings: an error-severity finding, or with `--strict` any warning or error — and nothing else |
| `64` | usage error: a bad argument, a path that does not exist, an unreadable `--only-from` file |
| `70` | nothing was analyzed: every file was skipped, and the report on stdout says which and why; or the run was cancelled, and stdout is empty |
| `78` | invalid configuration, or a missing or malformed baseline |

`1` means findings *only*, so a step that posts a review comment on `1` will
not fire on a typo in the config file. Every rule defaults to warning (test-
only groups are notes), so findings are always reported, but only an `error`
severity or `--strict` makes them fail the gate, and a note never does. A cancelled run reports **no** findings
and exits `70` rather than looking clean: a whole-program analysis over a
partial corpus does not report less, it reports wrongly.

When every file is skipped (unreadable, not UTF-8, or over the 10 MiB cap),
dolly still prints the report in the requested format — one
`dolly/degraded-file` note per file in SARIF, whose invocation records
`"executionSuccessful": false` with an error notification — and then exits
`70`. A caller tells the two `70`s apart by standard output: a report there
means nothing could be analyzed; empty means the run itself failed.

### Gating policy

Duplicate-code judgement is subjective enough that failing on everything gets
the check rubber-stamped or switched off. Fail on `exact-clone` only — Type-1,
byte-identical token sequences, no threshold and no judgement — and leave
`near-clone` and `structural-clone` advisory:

```json
{
  "rules": {
    "exact-clone":      { "severity": "error" },
    "near-clone":       { "severity": "warning" },
    "structural-clone": { "severity": "warning" }
  }
}
```

Then run **without** `--strict`: dolly exits `1` on errors only. Measured on a
39-finding corpus, that gates on 11 objective findings while still reporting
the other 28.

## License

MIT — see `LICENSE`.

[swift-syntax]: https://github.com/swiftlang/swift-syntax
[arcleak]: https://github.com/g-cqd/arcleak
[SwiftStaticAnalysis]: https://github.com/g-cqd/SwiftStaticAnalysis
