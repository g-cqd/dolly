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
