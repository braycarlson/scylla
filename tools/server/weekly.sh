#!/usr/bin/env bash

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../.." && pwd)"
results="${SCYLLA_RESULTS:-$root/results}"
day="$results/$(date --utc +%F)"

mkdir -p "$day"

exec 9>"$results/lock"
flock 9

cd "$root"

echo "weekly: mutants"
cargo mutants --in-place --timeout 60 || echo "weekly: mutants exited $?"

if [ -f mutants.out/outcomes.json ]; then
    cp mutants.out/outcomes.json "$day/survivors.json"
fi

echo "weekly: miri"
: > "$day/miri.log"

if ! timeout 21600 cargo +nightly miri test --lib > "$day/miri-run.log" 2>&1; then
    {
        echo "==== miri failed ===="
        tail -n 300 "$day/miri-run.log"
    } >> "$day/miri.log"
fi

rm -f "$day/miri-run.log"

echo "weekly: coverage"
cargo llvm-cov --all-targets --summary-only > "$day/coverage.txt" 2>&1 \
    || echo "weekly: coverage exited $?"

python3 "$here/report.py" "$day"
