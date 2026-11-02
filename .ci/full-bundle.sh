#!/bin/bash
# The `dolly-full-<version>-macos-arm64` release archive: dolly with all-MiniLM-L6-v2 (Core ML) beside it, for
# --semantic. Run by swift-ci after the macOS archive of a tag; what it leaves in .build/swift-ci/dist is published
# with the release. Best effort, as before swift-ci: a failure here warns and never drops the plain archive.
set -uo pipefail

bundle() {
    set -euo pipefail
    local bin version name dist model
    bin="$(swift build -c release --show-bin-path)/dolly"
    version="$("$bin" --version)"
    dist=.build/swift-ci/dist
    model=.build/swift-ci/model
    mkdir -p "$dist" "$model"
    # A public release asset: no token needed.
    local base=https://github.com/g-cqd/dolly/releases/download/embedding-models-v1
    curl -fsSL --retry 3 -o "$model/dolly-minilm.tar.gz" "$base/dolly-minilm.tar.gz"
    curl -fsSL --retry 3 -o "$model/dolly-minilm.tar.gz.sha256" "$base/dolly-minilm.tar.gz.sha256"
    local expected actual
    expected="$(cut -d' ' -f1 "$model/dolly-minilm.tar.gz.sha256")"
    actual="$(shasum -a 256 "$model/dolly-minilm.tar.gz" | cut -d' ' -f1)"
    [ "$expected" = "$actual" ] || { echo "MiniLM checksum mismatch (expected $expected, got $actual)" >&2; return 1; }
    name="dolly-full-$version-macos-arm64"
    rm -rf "${dist:?}/$name"
    mkdir -p "$dist/$name/Models"
    cp "$bin" LICENSE README.md "$dist/$name/"
    # Release builds keep their debug map on macOS (v0.7.0: 26 MiB -> 14 MiB); both flags keep it runnable.
    strip -S -x "$dist/$name/dolly"
    tar -xzf "$model/dolly-minilm.tar.gz" -C "$dist/$name/Models" # -> Models/MiniLM/...
    printf '%s\n' \
        '# Bundled model' \
        '' \
        'This archive bundles all-MiniLM-L6-v2 (Models/MiniLM), a sentence-embedding' \
        'model by the Sentence-Transformers authors, converted to Core ML.' \
        '' \
        'Licensed under the Apache License 2.0.' \
        'https://huggingface.co/sentence-transformers/all-MiniLM-L6-v2' \
        '' \
        'dolly loads it automatically for --semantic when it sits next to the' \
        'executable. Delete Models/ to fall back to the on-device NLContextual' \
        'provider, or override with --embedding-bundle / DOLLY_EMBEDDING_BUNDLE.' \
        > "$dist/$name/THIRD_PARTY_NOTICES.md"
    (cd "$dist" && tar -czf "$name.tar.gz" "$name" && shasum -a 256 "$name.tar.gz" > "$name.tar.gz.sha256")
    rm -rf "${dist:?}/$name"
    ls -lh "$dist/$name.tar.gz"
}

if ! (bundle); then
    echo "::warning::the dolly-full bundle could not be made; the plain archive is published without it"
fi
exit 0
