from __future__ import annotations

import json
import os
import sys

from datetime import datetime, timezone
from pathlib import Path


HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
CORPUS = ROOT / 'fuzz' / 'corpus'
RESULTS = Path(os.environ.get('SCYLLA_RESULTS', ROOT / 'results'))
KNOWN_CRASHES = RESULTS / 'known_crashes.json'
KNOWN_DIVERGENCES = RESULTS / 'known_divergences.json'


def corpus_sizes() -> dict[str, int]:
    if not CORPUS.is_dir():
        return {}

    sizes = {
        held.name: sum(1 for entry in held.iterdir() if entry.is_file())
        for held in sorted(CORPUS.iterdir())
        if held.is_dir()
    }

    return sizes


def crash_counts(day: Path) -> dict[str, int]:
    fresh = line_count(day / 'crashes.jsonl')
    known = 0

    if KNOWN_CRASHES.is_file():
        known = len(json.loads(KNOWN_CRASHES.read_text()).get('crashes', {}))

    return {'known': known, 'new': fresh}


def divergences_folded(day: Path) -> dict[str, int]:
    raw = day / 'divergences-raw.jsonl'
    out = day / 'divergences.jsonl'
    known = {}

    if KNOWN_DIVERGENCES.is_file():
        known = json.loads(KNOWN_DIVERGENCES.read_text())

    fresh = []

    if raw.is_file():
        for line in raw.read_text().splitlines():
            if not line.strip():
                continue

            row = json.loads(line)
            signature = row.get('signature', '')

            if signature in known:
                continue

            known[signature] = {
                'first_seen': today(),
                'language': row.get('language', ''),
                'level': row.get('level', ''),
                'summary': row.get('summary', ''),
            }

            fresh.append(line)

    if fresh:
        with out.open('a') as held:
            for line in fresh:
                held.write(line + '\n')

    KNOWN_DIVERGENCES.parent.mkdir(parents=True, exist_ok=True)
    KNOWN_DIVERGENCES.write_text(json.dumps(known, indent=4, sort_keys=True) + '\n')

    return {'known': len(known), 'new': len(fresh)}


def line_count(path: Path) -> int:
    if not path.is_file():
        return 0

    return sum(1 for line in path.read_text().splitlines() if line.strip())


def log_status(day: Path, name: str) -> str:
    held = day / name

    if not held.is_file():
        return 'not run'

    if held.stat().st_size == 0:
        return 'passed'

    return 'failed'


def survivor_counts(day: Path) -> dict[str, int] | None:
    held = day / 'survivors.json'

    if not held.is_file():
        return None

    outcomes = json.loads(held.read_text()).get('outcomes', [])
    counts: dict[str, int] = {}

    for outcome in outcomes:
        summary = str(outcome.get('summary', 'unknown'))
        counts[summary] = counts.get(summary, 0) + 1

    return counts


def today() -> str:
    return datetime.now(timezone.utc).date().isoformat()


def main() -> int:
    if len(sys.argv) != 2:
        message = 'usage: report.py <date-directory>'
        raise SystemExit(message)

    day = Path(sys.argv[1])
    day.mkdir(parents=True, exist_ok=True)

    summary = {
        'corpus': corpus_sizes(),
        'crashes': crash_counts(day),
        'date': day.name,
        'divergences': divergences_folded(day),
        'generated': datetime.now(timezone.utc).isoformat(),
        'miri': log_status(day, 'miri.log'),
        'mutants': survivor_counts(day),
        'sanitizer': log_status(day, 'sanitizer.log'),
    }

    (day / 'summary.json').write_text(json.dumps(summary, indent=4, sort_keys=True) + '\n')
    print(json.dumps(summary, indent=4, sort_keys=True))

    return 0


if __name__ == '__main__':
    sys.exit(main())
