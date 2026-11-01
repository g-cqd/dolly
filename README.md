# dolly

Finds code that exists twice: copy-paste, copy-paste with renamed variables, and near-copies whose statements drifted apart. It
reads Swift source with [swift-syntax](https://github.com/swiftlang/swift-syntax), so it needs no build, and it is fast enough to
run on every push.

```swift
// Orders.swift
func total(discount: Double) -> Double {
    var sum = 0.0
    for line in lines where line > 0 { sum += line }
    // …
}

// Invoices.swift: the same function with other names
func total(discount: Double) -> Double {
    var amount = 0.0
    for item in items where item > 0 { amount += item }
    // …
}
```

```text
Invoices.swift:1:1: warning: [near-clone] 2 duplicated regions of ~65 tokens (similarity 1.00) — duplicates: Orders.swift:1
```

## What it finds

- **Exact clones:** identical token sequences.
- **Near clones:** identical up to identifiers and literals.
- **Structural clones:** similar regions with the statements in the same order, above a similarity threshold you set.
- **Semantic clones** (experimental, macOS): code that does the same thing in a different shape, found with an embedding model.

A clone group is one finding with every member listed. Generated files and previews are left out, and a group found only in tests
is a note. See [Rules](docs/rules.md).

## Install

Download an archive from the [releases](https://github.com/g-cqd/dolly/releases), or build with Swift 6.4 on macOS 15 or later,
or Linux:

```sh
swift build -c release
cp .build/release/dolly /usr/local/bin/
```

## Use

```sh
dolly analyze Sources             # diagnostics in Xcode's format
dolly analyze --strict Sources    # warnings fail too
dolly analyze --format sarif .    # for GitHub code scanning
dolly analyze --semantic Sources  # also clones in different idioms (macOS)
```

Duplication that is intentional, such as two backends kept in step, is accepted at the source with a reason
(`// @dl:accept -- why`), or recorded once in a baseline so the gate flags only new duplication.

## Learn more

[User guide](docs/README.md): getting started, rules, configuration, CI, reports, semantic clones.

dolly is one of a family of analyzers with the same options and reports:
[arcleak](https://github.com/g-cqd/arcleak) (leaks), [deadwood](https://github.com/g-cqd/deadwood) (unused code),
[fcheck](https://github.com/g-cqd/fcheck) and [modeler](https://github.com/g-cqd/modeler).

[MIT](LICENSE)
