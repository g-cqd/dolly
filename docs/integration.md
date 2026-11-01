# Using dolly in CI

Analyze the whole repository and scope the report to the change. A region is a clone because a match exists elsewhere, so
analyzing only the changed files hides real clones and surfaces ones that belong elsewhere
([why](https://github.com/g-cqd/analyzerkit/blob/main/docs/analyzer-contract.md#scoping-a-report-to-some-files)).

```sh
git diff --name-only origin/main... -- '*.swift' > changed.txt
dolly analyze . --only-from changed.txt --baseline .dolly-baseline.json --strict
```

For code scanning, add `--format sarif --relative-to .` and upload the result ([SARIF](https://github.com/g-cqd/analyzerkit/blob/main/docs/analyzer-contract.md#sarif)). A composite GitHub Action
(`action.yml`) builds dolly, analyzes, and uploads it.

## Only new findings

```sh
dolly analyze . --write-baseline base.json                                # on the base branch
dolly analyze . --baseline base.json --only-from changed.txt              # on the pull request
```

## A group touching the change

A clone group is kept when any member is in scope, and reported at its first in-scope member, with the original anchor first in
`related`. Its fingerprint still hashes the original anchor (kept as `fingerprintAnchor`), so baselines keep matching.

## Where to keep the cache

Keep an explicit `--cache-path` outside the repository, or a cache file inside it changes the working tree on every run.
The cache holds extraction facts only, and depends on no configuration, so changing rules or thresholds reuses it. A cache over
256 MiB is neither read nor written.
