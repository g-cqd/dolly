# Getting started

dolly reads Swift source and finds code that exists twice. It needs no build.

## Install

Download an archive from the [releases](https://github.com/g-cqd/dolly/releases) (macOS arm64, Linux x86_64), or build with a
Swift 6.4 toolchain on macOS 15 or later, or Linux:

```sh
git clone https://github.com/g-cqd/dolly.git && cd dolly
swift build -c release
cp .build/release/dolly /usr/local/bin/
```

## Run it

```sh
dolly analyze Sources             # Xcode-style diagnostics; exit 1 on errors
dolly analyze --format sarif .    # also: --format json
dolly analyze --strict Sources    # warnings fail too; notes never do
dolly analyze --semantic Sources  # also behaviorally equal code (macOS, experimental)
dolly rules                       # list the rules; `rules <id>` explains one
```

A clone group is one finding, anchored at its first member. Every other member is listed in the note and as a related location
(SARIF `relatedLocations`, JSON `related`).

Exit `0` means the gate passed and `1` means findings. `64`, `70`, `74` and `78` mean the run itself broke
([exit codes](https://github.com/g-cqd/analyzerkit/blob/main/docs/analyzer-contract.md#exit-codes)).

## A fast gate

`dolly analyze --strict Sources` runs exact, near and structural detection in about a tenth of a second on a 330-file codebase,
deterministically, with no model and no network. That makes it suitable for every push.

- **`exact-clone` and `near-clone` are the high-signal rules.** They fire on shared helpers, copy-paste, and families kept in
  step on purpose, such as an `epoll` and a `kqueue` backend. Ask "did I mean to duplicate this?", and [accept](#accepting-a-finding)
  the standing ones so the gate is about *new* duplication.
- **`structural-clone`** finds near-copies with edited statements: drift between things once identical. Raise
  `minimumSimilarity` if a codebase is boilerplate-heavy.
- **Do not lower the token floor** to find more. A low `minimumTokens` turns ordinary boilerplate into noise.

See [Configuration](configuration.md) for a policy that fails only on `exact-clone`.

## Where duplication lives

dolly weighs a clone by where it lives, using the project model:

- **Generated files** (a generator's header, a `Generated` directory, `*.generated.swift`) are left out: generators repeat
  themselves and nobody edits their output.
- **Previews** (`#Preview`, `PreviewProvider`) repeat a view with small changes and never ship. A copy lying mostly in a preview
  is dropped.
- **Test code** is often repetitive on purpose. A group found only in tests is a note. A group that spans production and tests
  keeps its severity, since tests re-implementing production logic are worth knowing about.

A line on stderr (`contextNote` in JSON) says what was left out.

## Adopting it on existing code

```sh
dolly analyze Sources --write-baseline .dolly-baseline.json
dolly analyze Sources --baseline .dolly-baseline.json  # only new findings fail
```

See [baselines](https://github.com/g-cqd/analyzerkit/blob/main/docs/analyzer-contract.md#baselines-and-fingerprints).

## Accepting a finding

Keep the rule on and accept each intentional instance with a reason. `@dl:` and `@dolly:` are the same directive:

```swift
// @dl:accept -- epoll and kqueue transports are kept parallel on purpose
// @dl:accept:this exact-clone -- reason
// @dl:disable near-clone
// @dl:enable near-clone
```
