# Known gaps

Accepted detection misses, each pinned by a characterization test so a
change that closes (or widens) a gap surfaces as a test delta. These are
deliberate trade-offs, not TODOs; if a pin fails because behavior
improved, update this catalogue and re-pin.

## In-type runs of 3+ identical-after-rename members

Three or more normalized-identical adjacent declarations INSIDE one type
(nesting depth >= 1) form a periodic token run whose overlapping shifted
repeats outrank the true group in `mergeOverlappingGroups`;
`filterOverlappingClones` then discards the survivor. Top-level runs were
fixed by boundary separators (Stage 1 / D1), which deliberately stop at
depth 0: separators between members would sever whole-type clone groups
and boilerplate families (for example arcleak's 8-way rule-file group,
whose matched region spans a struct header plus two members) — verified
against the golden fixtures and the arcleak dogfood corpus. Pairs of
identical members in one type ARE found; only runs of 3+ are lost.

- Pinned by: `KnownGapsTests.inTypeMethodRunsAreMissed`
- Counterpart that works: `DuplicationPropertyTests.sameFileMatchesSplitFiles`
  (top level), `Findings/SameFileNearClones.swift` (golden)

## Dense-edit structural pairs below 0.8

The structural stage verifies candidates with exact Jaccard over 5-gram
shingles at the configured threshold (default 0.8). Pairs with edits
dense enough to fall below it are silent by design — the threshold IS the
noise floor, and lowering it floods reports on repetitive-but-unrelated
code (see the `Clean/` false-positive gate).

- Pinned by: `KnownGapsTests.denseEditPairIsSilent`
- Counterpart that works: `Fixtures/Corpus/StructuralPair` (sparse-edit
  pair above the threshold, LCS-ordered)

## Scrambled-statement bags

High bag-of-shingles similarity with scrambled statement ORDER is
rejected by the NIL-style token-LCS gate (>= 0.7 over normalized ids):
a caller could not extract a shared function from reordered logic. This
is a deliberate precision choice, not a recall gap.

- Pinned by: `StructuralVerificationTests.scrambledBlocksRejected`
- Counterpart that works: `StructuralVerificationTests.gappedOrderedAccepted`

## Sub-threshold clones (< 50 tokens)

Regions below `duplication.minimumTokens` (default 50) are never
reported; tiny helpers legitimately repeat. The floor is configurable per
project.

- Pinned by: `DuplicationPropertyTests.duplicationSettingsRespected`
  (silent at the default floor, found at `minimumTokens: 20`)

## Semantic (Type-4) clones

Same behavior under a different token shape (loop vs filter/map/reduce,
recursion vs iteration) is invisible to a token-based engine. Out of
scope.

- Pinned by: `KnownGapsTests.semanticClonesAreMissed`

## Macro-expansion sources

Files containing `#sourceLocation(...)` directives are excluded from the
suffix-array stages: clone groups spanning a macro's definition and its
expansion are expected, not actionable.

- Pinned by: extraction-time flag (`SourceText.containsSourceLocationDirective`);
  behavior inherited from the lifted engine
