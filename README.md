# dolly

Duplicate-code detection for Swift: exact, near, and structural clones.

Built on [swift-syntax], modeled on [arcleak]: source-level analysis (no build
required), fixture-gated precision, a comment directive DSL for auditable
acceptance, baselines for adoption on legacy code, and SARIF for code scanning.

**Status: working detector.** The engine runs a zero-copy interned token
pipeline: extraction interns every token into 16-byte records (normalization
at intern time), the exact and near stages share one suffix-array (SA-IS +
LCP) pass with declaration-boundary separators so same-file duplicates
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
dolly analyze --strict Sources   # exit 1 on any finding
dolly analyze --semantic Sources # + Type-4 (idiom-level) clones, macOS-only
dolly rules                      # list rules; `rules <id>` explains one
```

Clone-group findings anchor at the first member and carry every other
member both in the note text and as structured locations (SARIF
`relatedLocations`, JSON `related`).

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
  directory holding a Core ML model (`Model.mlpackage` / `*.mlmodelc`) plus a
  HuggingFace tokenizer (`tokenizer.json`, …) — e.g. a CodeBERT/GraphCodeBERT/
  MiniLM export. Code-trained bundles catch clones the NL model can't.
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

Warm runs skip parsing and extraction via a per-file facts cache keyed by
content fingerprint, version-gated and fail-open (a corrupt or stale cache
behaves as empty and is rewritten; entries for deleted files are pruned).

```sh
dolly analyze Sources                       # cache at <user caches>/dolly/facts.json
dolly analyze --no-cache Sources            # disable for this run
dolly analyze --cache-path .dolly-cache Sources
```

The cache stores extraction facts only — detection always re-runs, so
findings can never go stale relative to engine or configuration changes.

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
  structural, one shared suffix-array build) runs in ~0.1 s on those 330 files
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
  identical value types or generated files — exclude generated code with
  `exclude` and accept intentional parallel backends rather than lowering the
  token floor (a low `minimumTokens` turns ordinary boilerplate into noise).

### `--semantic` (Type-4) — targeted, not CI

```sh
# Best precision on code: a code-trained bundle, tight preset, capped groups.
dolly analyze --semantic --embedding-bundle Models/MiniLM \
              --embedding-preset strict --semantic-max-group 25 Sources
```

- **Prefer a code bundle.** `--embedding-bundle <CodeBERT/MiniLM dir>` is the
  path to real precision on source: code-trained embeddings stay tight (small,
  meaningful groups). This is what to use when you actually want Type-4 results.
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
  and detection is token-only. The `swift-transformers` dependency links its
  `Tokenizers` product on macOS only, so Linux resolution/build is unaffected.
- Implementation policy: warnings as errors, strict memory safety (the
  one `unsafe` fingerprint fast path is isolated and invariant-commented),
  Swift concurrency only (no GCD), swift-format gated.

## License

MIT — see `LICENSE`.

[swift-syntax]: https://github.com/swiftlang/swift-syntax
[arcleak]: https://github.com/g-cqd/arcleak
[SwiftStaticAnalysis]: https://github.com/g-cqd/SwiftStaticAnalysis
