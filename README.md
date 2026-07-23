# dolly

Duplicate-code detection for Swift: exact, near, and structural clones.

Built on [swift-syntax], modeled on [arcleak]: source-level analysis (no build
required), fixture-gated precision, a comment directive DSL for auditable
acceptance, baselines for adoption on legacy code, and SARIF for code scanning.

**Status: skeleton.** The pipeline (CLI, suppression, baseline, reporting,
CI) is in place; the detection engine is being extracted from
[SwiftStaticAnalysis] and lands next.

## CLI

```sh
dolly analyze Sources            # xcode-format diagnostics, exit 1 on errors
dolly analyze --format sarif .   # SARIF 2.1.0 (also: --format json)
dolly analyze --strict Sources   # exit 1 on any finding
dolly rules                      # list rules; `rules <id>` explains one
```

## Accepting a finding

Directives use the `@` sigil with the `@dl:` or `@dolly:` namespace:

```swift
// @dl:accept -- <why this finding is intentional>
// @dl:accept:this <rule|all> [-- reason]
// @dl:disable <rule|all> … // @dl:enable <rule|all>
```

## License

MIT — see `LICENSE`.

[swift-syntax]: https://github.com/swiftlang/swift-syntax
[arcleak]: https://github.com/g-cqd/arcleak
[SwiftStaticAnalysis]: https://github.com/g-cqd/SwiftStaticAnalysis
