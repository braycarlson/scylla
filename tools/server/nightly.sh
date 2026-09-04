#!/usr/bin/env bash

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../.." && pwd)"
results="${SCYLLA_RESULTS:-$root/results}"
day="$results/$(date --utc +%F)"
target="$(rustc --print host-tuple)"

mkdir -p "$day"

exec 9>"$results/lock"
flock 9

cd "$root"

echo "nightly: corpus fetch"
corpus/fetch.sh || echo "nightly: corpus fetch failed with $?"

echo "nightly: oracle build"
just oracle || echo "nightly: oracle build failed with $?"

echo "nightly: differential sweep"
cargo run --release --quiet --manifest-path tools/runner/Cargo.toml --bin runner -- \
    --corpus corpus/sources \
    --level tree \
    --out "$day/divergences-raw.jsonl" \
    --minimize \
    || echo "nightly: runner exited $?"

export SCYLLA_CORPUS="$root/corpus/sources"

if [ -d "$root/corpus/goldens/treesitter" ]; then
    export SCYLLA_CORPUS_GOLDEN="$root/corpus/goldens/treesitter"
fi

if [ -d "$root/corpus/goldens/gotypes" ]; then
    export SCYLLA_CORPUS_GOTYPES="$root/corpus/goldens/gotypes"
fi

if [ -d "$root/corpus/goldens/oxlint" ]; then
    export SCYLLA_CORPUS_OXLINT="$root/corpus/goldens/oxlint"
fi

if [ -d "$root/corpus/goldens/ruff" ]; then
    export SCYLLA_CORPUS_RUFF="$root/corpus/goldens/ruff"
fi

if [ -d "$root/corpus/goldens/tsscope" ]; then
    export SCYLLA_CORPUS_TSSCOPE="$root/corpus/goldens/tsscope"
fi

if [ -d "$root/corpus/goldens/css" ]; then
    export SCYLLA_CORPUS_CSS="$root/corpus/goldens/css"
fi

if [ -d "$root/corpus/goldens/zls" ]; then
    export SCYLLA_CORPUS_ZLS="$root/corpus/goldens/zls"
fi

if [ -d "$root/corpus/goldens/scip" ]; then
    export SCYLLA_CORPUS_SCIP="$root/corpus/goldens/scip"
fi

if [ -d "$root/corpus/goldens/ols" ]; then
    export SCYLLA_CORPUS_OLS="$root/corpus/goldens/ols"
fi

if [ -d "$root/corpus/goldens/markup" ]; then
    export SCYLLA_CORPUS_MARKUP="$root/corpus/goldens/markup"
fi

sanitize() {
    local name="$1" flag="$2"
    shift 2

    local log
    log="$(mktemp)"

    echo "nightly: $name"

    if ! CARGO_TARGET_DIR="target/$name" RUSTFLAGS="$flag" \
        cargo +nightly test --release -Zbuild-std --target "$target" "$@" \
        > "$log" 2>&1
    then
        {
            echo "==== $name failed ===="
            tail -n 300 "$log"
        } >> "$day/sanitizer.log"
    fi

    rm -f "$log"
}

: > "$day/sanitizer.log"
sanitize asan -Zsanitizer=address
sanitize tsan -Zsanitizer=thread --test project_parallel

echo "nightly: triage"
python3 "$here/triage.py" --minimize || echo "nightly: triage exited $?"

python3 "$here/report.py" "$day"
