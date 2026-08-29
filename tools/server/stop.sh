#!/usr/bin/env bash
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
session="${SCYLLA_FUZZ_SESSION:-scylla-fuzz}"
lock="${SCYLLA_RESULTS:-$root/results}/lock"

alive() {
    pgrep -f '[c]argo-fuzz fuzz run' 2>/dev/null
    pgrep -f '[t]imeout --signal=INT' 2>/dev/null
    pgrep -f '[r]epos/scylla/fuzz' 2>/dev/null
    pgrep -f '[s]erver/triage.py' 2>/dev/null
}

sweep() {
    local signal="$1" pid
    local pids
    pids="$(alive | sort -u)"

    [ -n "$pids" ] || return 1

    for pid in $pids; do
        kill "-$signal" "$pid" 2>/dev/null
    done

    return 0
}

if tmux has-session -t "$session" 2>/dev/null; then
    tmux kill-session -t "$session"
    echo "  killed session: $session"
else
    echo "  no session: $session"
fi

if sweep TERM; then
    sleep 3
    sweep KILL
    sleep 1
    sweep KILL > /dev/null
    echo "  orphans swept"
else
    echo "  orphans: none"
fi

for scratch in "${TMPDIR:-}" /var/tmp/scratch /tmp; do
    [ -n "$scratch" ] && [ -d "$scratch" ] || continue
    rm -rf "$scratch"/libFuzzerTemp.FuzzWithFork*.dir 2>/dev/null
done

remaining="$(alive | sort -u | tr '\n' ' ')"

if [ -n "${remaining// /}" ]; then
    echo "  STILL RUNNING: $remaining" >&2
    exit 1
fi

if [ -e "$lock" ] && ! flock --nonblock "$lock" true; then
    echo "  STILL LOCKED: $lock is held" >&2
    exit 1
fi

echo "  stopped clean, no fuzz processes remain and $lock is free"
