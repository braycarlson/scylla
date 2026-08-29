#!/usr/bin/env bash

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../.." && pwd)"
results="${SCYLLA_RESULTS:-$root/results}"
lock="$results/lock"
fork="${SCYLLA_FUZZ_FORK:-$(nproc)}"
session="${SCYLLA_FUZZ_SESSION_SECONDS:-3600}"

mkdir -p "$results"

seed() {
    local target="$1"
    shift

    local corpus="$root/fuzz/corpus/$target"

    if [ -d "$corpus" ]; then
        return 0
    fi

    mkdir -p "$corpus"

    local extension
    for extension in "$@"; do
        find "$root/tests/fixtures" -name "*.$extension" \
            -exec cp {} "$corpus/" \; 2>/dev/null || true
    done

    echo "fuzz: seeded $target with $(ls "$corpus" | wc -l) fixtures"
}

targets() {
    local held
    for held in "$root"/fuzz/fuzz_targets/*.rs; do
        basename "$held" .rs
    done
}

echo "fuzz: building targets"
(cd "$root" && cargo +nightly fuzz build)

seed lex css go js odin py rs ts tsx zig
seed markup html
seed parse_css css
seed parse_go go
seed parse_javascript cjs js jsx mjs
seed parse_odin odin
seed parse_python py
seed parse_rust rs
seed parse_tsx tsx
seed parse_typescript cts mts ts
seed parse_zig zig
mkdir -p "$root/fuzz/corpus/edits"

while true; do
    for target in $(targets); do
        echo "fuzz: $target session of ${session}s with $fork workers"

        (
            flock 9
            cd "$root"

            timeout --signal=INT $((session + 600)) \
                cargo +nightly fuzz run "$target" -- \
                -fork="$fork" \
                -ignore_crashes=1 \
                -ignore_ooms=1 \
                -ignore_timeouts=1 \
                -max_total_time="$session" \
                -rss_limit_mb=8192 \
                -timeout=10 \
                || echo "fuzz: $target session exited $?"
        ) 9>"$lock"

        python3 "$here/triage.py" || echo "fuzz: triage exited $?"
        python3 "$here/report.py" "$results/$(date --utc +%F)" > /dev/null \
            || echo "fuzz: report exited $?"
    done
done
