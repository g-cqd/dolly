# Command line and reports

Shared options, exit codes and the report format are described in [how the analyzers behave](https://github.com/g-cqd/analyzerkit/blob/main/docs/analyzer-contract.md). This page lists what dolly
adds.

## Options

| Option | |
| --- | --- |
| `analyze PATHS…` | Files or directories (default `.`). |
| `--format xcode\|json\|sarif` | The output format (default `xcode`). |
| `--only FILE`, `--only-from FILE` | Report only findings that touch these files; the whole corpus is still analyzed. |
| `--report-new-since BASELINE` | With `--only`, also report findings outside it that the baseline does not hold. |
| `--baseline FILE`, `--write-baseline FILE` | Drop accepted findings; record the current ones. |
| `--relative-to DIR` | Print paths relative to `DIR`; the hashed path follows it. |
| `--config FILE` | Read this configuration file. |
| `--cache-path DIR`, `--no-cache` | Move or disable the [cache](https://github.com/g-cqd/analyzerkit/blob/main/docs/analyzer-contract.md#the-facts-cache). |
| `--strict` | Warnings fail the gate too. |
| `--include-regions`, `--exclude-regions` | `preview`, `debug`, `test`, `mock`, `generated`, `script` or `all`. |
| `--exclude-path PATTERN` | Leave paths out of the corpus; repeatable. |
| `--rules IDS` | Run only these rules (comma-separated). |
| `--quiet`, `--verbose`, `--timings` | Say less or more on stderr; time each phase. |
| `--semantic`, `--embedding-bundle`, `--embedding-preset`, `--semantic-max-group` | [Semantic clones](semantic.md). |
| `--define NAME` | Accepted for the shared surface and ignored: dolly compares the tokens of every `#if` clause. |

## The JSON report

The shared keys are in [the contract](https://github.com/g-cqd/analyzerkit/blob/main/docs/analyzer-contract.md#the-json-report). dolly adds:

| Key | |
| --- | --- |
| `semanticNote`, `contextNote` | Present when there is something to say: how the semantic pass ran, what the project model left out. |
| `findings[].related` | The other members of the group (`[{path, line, column}]`). |
| `findings[].fingerprintAnchor` | The group's original anchor, when `--only` moved the finding. For provenance, not for recomputing fingerprints. |

A finding's `note` lists the other members (`duplicates: …`).

## Fingerprints

A fingerprint hashes the rule, path, line, column and message. The path is relative to the repository root by default. With
`--relative-to DIR`, it is relative to `DIR`, so baselines match only between runs that use the same value. At the repository root
that is the same as none.

## Stability

The `schemaVersion` is `1`. Within it, `dolly analyze`, the stable options above, the exit codes, the JSON field names and the
fingerprint do not change incompatibly. Not covered: `--semantic` and the other experimental options, other commands, and the
`DollyCore` library.
