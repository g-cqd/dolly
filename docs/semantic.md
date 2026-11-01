# Semantic clones (experimental, macOS)

The token engine cannot see two regions that compute the same result through different shapes, such as a `for` loop and `reduce`,
or iteration and recursion. `--semantic` embeds each function and initializer, groups regions whose embeddings are close (cosine)
and whose identifiers overlap (Jaccard), and reports `semantic-clone` for groups the other rules did not already claim.

```sh
dolly analyze --semantic Sources
dolly analyze --semantic --embedding-preset strict .
dolly analyze --semantic --embedding-bundle Models/MiniLM Sources
dolly analyze --semantic --semantic-max-group 25 .
```

It is for hunting, not for gating: it is slow, depends on the model, and on the default model is limited in precision. Review the
groups by hand.

## Models

- **Default: Apple's on-device `NLContextualEmbedding`.** Nothing to download. It reads English prose, not code, so it recovers
  idiom swaps that are lexically close and misses distant ones. On large, boilerplate-heavy code it over-clusters, and it runs
  one inference per snippet: about 90 s on 330 files, against 0.1 s for the token pass.
- **Better: a sentence-embedding bundle.** `--embedding-bundle DIR` takes a Core ML model (`.mlpackage` or `.mlmodelc`) and its
  WordPiece vocabulary (`vocab.txt`, or the one in `tokenizer.json`), such as all-MiniLM-L6-v2. On 156 files it ran 4.6 times faster
  than the default and produced tighter groups. BPE and SentencePiece bundles fall back to the default provider.
- **Choose a sentence-embedding model, not a masked-language-model checkpoint.** Masked-LM vectors crowd into one cone, so everything
  looks similar: on the same corpus MiniLM found 4 candidate groups where CodeBERT found 30.
- **The `dolly-full` archive** ships MiniLM in `Models/` next to the binary, which dolly finds on its own. Delete the folder to
  go back to the default. `DOLLY_EMBEDDING_BUNDLE=DIR` overrides the search for installs that keep resources apart (`bin/` and
  `share/`); `--embedding-bundle` wins over both. The status note names the model that ran.

## Controls

| Option | |
| --- | --- |
| `--embedding-preset` | `balanced` (cosine ≥ 0.85, Jaccard ≥ 0.20, the default), `strict` (0.90, 0.30) or `loose` (0.80, 0.10). |
| `--semantic-max-group N` | Drop groups larger than `N` (default 25; `0` disables). A group that large is embedding collapse, not a clone family; the default model once fused 272 plain declarations into one. Tight bundles are unaffected. |

On Linux, or when no model is available, `--semantic` prints a note and carries on with the token rules; it never fails the run.
Without `--semantic`, the output is byte-identical to the token-only default.
