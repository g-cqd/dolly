# Configuration

dolly reads `.dolly.json`, or a `"dolly"` section of the shared `.swift-analyzers.json`
([how files are found and merged](https://github.com/g-cqd/analyzerkit/blob/main/docs/analyzer-contract.md#configuration)).

```json
{
  "rules": {
    "exact-clone": { "severity": "error" },
    "structural-clone": { "enabled": true, "severity": "warning" }
  },
  "exclude": ["Generated/"],
  "duplication": { "minimumTokens": 50, "minimumSimilarity": 0.8 }
}
```

An unknown rule id or key is an error.

| Setting | Default | Allowed | |
| --- | --- | --- | --- |
| `duplication.minimumTokens` | `50` | 1–10000 | The clone floor for exact, near and structural clones. |
| `duplication.minimumSimilarity` | `0.8` | 0.0–1.0 | The floor for `structural-clone`. `near-clone` ignores it. |
| `rules.<id>.severity` | `warning` | `note`, `warning`, `error` | The severity of the rule's findings. |
| `rules.<id>.enabled` | `true` | `true`, `false` | Whether the rule runs; `semantic-clone` also needs `--semantic`. |

A value out of range exits `78`. Numeric options like `--semantic-max-group` are flags, not settings.

## Tuning

- **Keep 50 tokens and 0.8** for a CI gate.
- **Noisy boilerplate:** raise `minimumTokens` (80 or 100 are starting points) rather than lowering the gate. Count findings on
  your own tree first.
- **Structural noise:** raise `minimumSimilarity` toward 0.9. Lowering it adds findings.

## A policy that does not get switched off

Judging duplication is subjective, so failing on everything gets a check rubber-stamped or removed. Fail on `exact-clone` only,
which is byte-identical and needs no judgement, and leave the rest advisory:

```json
{
  "rules": {
    "exact-clone": { "severity": "error" },
    "near-clone": { "severity": "warning" },
    "structural-clone": { "severity": "warning" }
  },
  "duplication": { "minimumTokens": 50, "minimumSimilarity": 0.8 }
}
```

Run it **without** `--strict`: dolly then exits `1` on errors only. On one 39-finding corpus that gated on 11 objective findings
and still reported the other 28.
