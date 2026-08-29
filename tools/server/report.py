from __future__ import annotations

import json
import os
import sys

from datetime import datetime, timezone
from pathlib import Path

DIGEST_LINE_MAX = 12
HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
CORPUS = ROOT / 'fuzz' / 'corpus'
RESULTS = Path(os.environ.get('SCYLLA_RESULTS', ROOT / 'results'))
KNOWN_CRASHES = RESULTS / 'known_crashes.json'
KNOWN_DIVERGENCES = RESULTS / 'known_divergences.json'
FAILURE_MARKERS = (
    '====',
    'AddressSanitizer',
    'ThreadSanitizer',
    'error:',
    'error[',
    'panicked at',
    'test result: FAILED',
)

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

    return {'known': len(known_crashes()), 'new': fresh}

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

def known_crashes() -> dict:
    if not KNOWN_CRASHES.is_file():
        return {}

    return json.loads(KNOWN_CRASHES.read_text()).get('crashes', {})

def line_count(path: Path) -> int:
    if not path.is_file():
        return 0

    return sum(1 for line in path.read_text().splitlines() if line.strip())

def log_digest(day: Path, name: str) -> list[str]:
    held = day / name

    if not held.is_file() or held.stat().st_size == 0:
        return []

    lines = [
        line.strip()
        for line in held.read_text(errors='replace').splitlines()
        if any(marker in line for marker in FAILURE_MARKERS)
    ]

    return lines[:DIGEST_LINE_MAX]

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

def divergence_languages(day: Path) -> dict[str, int]:
    held = day / 'divergences.jsonl'

    if not held.is_file():
        return {}

    counts: dict[str, int] = {}

    for line in held.read_text().splitlines():
        if not line.strip():
            continue

        language = json.loads(line).get('language', 'unknown')
        counts[language] = counts.get(language, 0) + 1

    return counts

def report_of(day: Path, summary: dict) -> str:
    crashes = known_crashes()
    lines = [
        f'# scylla {summary["date"]}',
        '',
        f'Generated {summary["generated"]}.',
        '',
        '## Crashes',
        '',
    ]

    if not crashes:
        lines += ['No crash signature is on record.', '']
    else:
        lines += [
            f'{len(crashes)} distinct signatures, {summary["crashes"]["new"]} first seen today.',
            '',
            '| target | signature | seen | first | bytes | panic |',
            '| --- | --- | --- | --- | --- | --- |',
        ]

        for key in sorted(crashes, key=lambda name: -crashes[name].get('count', 1)):
            held = crashes[key]
            target, signature = key.split(':', 1)
            panic = held.get('panic', '').replace('|', r'\|')

            lines.append(
                f'| {target} | `{signature}` | {held.get("count", 1)} '
                f'| {held.get("first_seen", "")} | {held.get("size_bytes", "")} | {panic} |'
            )

        lines += ['', f'Rows with the input attached are in `{day.name}/crashes.jsonl`.', '']

    lines += [
        '## Divergences',
        '',
        f'{summary["divergences"]["known"]} known, {summary["divergences"]["new"]} first seen today.',
        '',
    ]

    languages = divergence_languages(day)

    if languages:
        lines += ['| language | rows |', '| --- | --- |']
        lines += [
            f'| {language} | {count} |'
            for language, count in sorted(languages.items(), key=lambda pair: -pair[1])
        ]
        lines.append('')

    lines += ['## Runs', '', '| job | outcome |', '| --- | --- |']
    lines.append(f'| sanitizer | {summary["sanitizer"]} |')
    lines.append(f'| miri | {summary["miri"]} |')

    survivors = summary['mutants']

    if survivors is None:
        lines.append('| mutants | not run |')
    else:
        held = ', '.join(f'{name} {count}' for name, count in sorted(survivors.items()))
        lines.append(f'| mutants | {held} |')

    lines.append('')

    for name in ('sanitizer.log', 'miri.log'):
        digest = log_digest(day, name)

        if not digest:
            continue

        lines += [f'### {name}', '', '```']
        lines += digest
        lines += ['```', '']

    lines += ['## Corpus', '', '| target | inputs |', '| --- | --- |']
    lines += [f'| {name} | {count} |' for name, count in sorted(summary['corpus'].items())]
    lines.append('')

    return '\n'.join(lines)

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
    (day / 'report.md').write_text(report_of(day, summary))
    print(json.dumps(summary, indent=4, sort_keys=True))

    return 0

if __name__ == '__main__':
    sys.exit(main())
