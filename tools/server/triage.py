from __future__ import annotations

import base64
import hashlib
import json
import os
import re
import subprocess
import sys

from datetime import datetime, timezone
from pathlib import Path


FRAME_COUNT_MAX = 8
HERE = Path(__file__).resolve().parent
INPUT_BYTES_MAX = 1 << 12
MINIMIZE_SECONDS_MAX = 600
REPRO_SECONDS_MAX = 120
ROOT = HERE.parent.parent
ARTIFACTS = ROOT / 'fuzz' / 'artifacts'
BINARIES = ROOT / 'fuzz' / 'target' / 'x86_64-unknown-linux-gnu' / 'release'
RESULTS = Path(os.environ.get('SCYLLA_RESULTS', ROOT / 'results'))
KNOWN = RESULTS / 'known_crashes.json'
FRAME_PATTERN = re.compile(r'^\s+\d+:\s+(?:0x[0-9a-f]+ - )?(.+?)(?:\s+at\s+\S+)?$')
PANIC_PATTERN = re.compile(r'panicked at |ERROR: AddressSanitizer|ERROR: libFuzzer|SUMMARY: ')


def artifact_paths() -> list[Path]:
    if not ARTIFACTS.is_dir():
        return []

    found = [
        held
        for target_dir in sorted(ARTIFACTS.iterdir())
        if target_dir.is_dir()
        for held in sorted(target_dir.iterdir())
        if held.is_file() and not held.name.startswith('minimized-from-')
    ]

    return found


def backtrace_of(stderr: str) -> list[str]:
    frames = []
    inside = False

    for line in stderr.splitlines():
        if 'stack backtrace:' in line or 'ERROR: AddressSanitizer' in line:
            inside = True
            continue

        if not inside:
            continue

        if line.strip().startswith('at '):
            continue

        match = FRAME_PATTERN.match(line)

        if match is None:
            if frames:
                break

            continue

        symbol = match.group(1).strip()

        if symbol.startswith(('core::panicking', 'rust_begin_unwind', 'std::panicking')):
            continue

        frames.append(symbol)

        if len(frames) >= FRAME_COUNT_MAX:
            break

    return frames


def hash_of(panic: str, frames: list[str]) -> str:
    text = panic + '\n' + '\n'.join(frames)

    return hashlib.sha256(text.encode()).hexdigest()[:16]


def today() -> str:
    return datetime.now(timezone.utc).date().isoformat()


def known_load() -> dict:
    if not KNOWN.is_file():
        return {'artifacts': {}, 'crashes': {}}

    return json.loads(KNOWN.read_text())


def known_save(known: dict) -> None:
    KNOWN.parent.mkdir(parents=True, exist_ok=True)
    KNOWN.write_text(json.dumps(known, indent=4, sort_keys=True) + '\n')


def minimized_of(target: str, artifact: Path) -> Path:
    before = set(artifact.parent.glob('minimized-from-*'))
    command = [
        'cargo',
        '+nightly',
        'fuzz',
        'tmin',
        target,
        str(artifact),
    ]

    try:
        subprocess.run(
            command,
            capture_output=True,
            check=False,
            cwd=ROOT,
            timeout=MINIMIZE_SECONDS_MAX,
        )
    except subprocess.TimeoutExpired:
        return artifact

    grown = sorted(
        set(artifact.parent.glob('minimized-from-*')) - before,
        key=lambda held: held.stat().st_size,
    )

    if not grown:
        return artifact

    return grown[0]


def panic_of(stderr: str) -> str:
    lines = stderr.splitlines()

    for position, line in enumerate(lines):
        if not PANIC_PATTERN.search(line):
            continue

        held = line.strip()

        if 'panicked at' in held and position + 1 < len(lines):
            held = held + ' ' + lines[position + 1].strip()

        return held

    return ''


def reproduced(target: str, artifact: Path) -> tuple[int, str]:
    binary = BINARIES / target

    if not binary.is_file():
        return (0, '')

    environment = dict(os.environ)
    environment['RUST_BACKTRACE'] = '1'

    try:
        held = subprocess.run(
            [str(binary), str(artifact)],
            capture_output=True,
            check=False,
            env=environment,
            timeout=REPRO_SECONDS_MAX,
        )
    except subprocess.TimeoutExpired:
        return (1, 'triage: the repro run timed out; the artifact hangs the target')

    return (held.returncode, held.stderr.decode(errors='replace'))


def row_of(target: str, artifact: Path, minimize: bool) -> dict | None:
    code, stderr = reproduced(target, artifact)

    if code == 0:
        return None

    repro = artifact

    if minimize:
        repro = minimized_of(target, artifact)

    content = repro.read_bytes()
    panic = panic_of(stderr)
    frames = backtrace_of(stderr)
    row = {
        'artifact': str(artifact.relative_to(ROOT)),
        'backtrace': frames,
        'backtrace_hash': hash_of(panic, frames),
        'first_seen': today(),
        'input_base64': base64.b64encode(content[:INPUT_BYTES_MAX]).decode(),
        'input_clipped': len(content) > INPUT_BYTES_MAX,
        'input_sha256': hashlib.sha256(content).hexdigest(),
        'panic': panic,
        'size_bytes': len(content),
        'target': target,
    }

    return row


def main() -> int:
    minimize = '--minimize' in sys.argv[1:]
    known = known_load()
    fresh = []

    for artifact in artifact_paths():
        target = artifact.parent.name
        seen_key = f'{target}/{artifact.name}'

        if seen_key in known['artifacts']:
            continue

        known['artifacts'][seen_key] = today()
        row = row_of(target, artifact, minimize)

        if row is None:
            continue

        crash_key = f'{target}:{row["backtrace_hash"]}'

        if crash_key in known['crashes']:
            continue

        known['crashes'][crash_key] = {
            'artifact': row['artifact'],
            'first_seen': row['first_seen'],
            'panic': row['panic'],
        }

        fresh.append(row)

    if fresh:
        day = RESULTS / today()
        day.mkdir(parents=True, exist_ok=True)

        with (day / 'crashes.jsonl').open('a') as held:
            for row in fresh:
                held.write(json.dumps(row, sort_keys=True) + '\n')

    known_save(known)
    print(f'triage: {len(fresh)} new, {len(known["crashes"])} known')

    return 0


if __name__ == '__main__':
    sys.exit(main())
