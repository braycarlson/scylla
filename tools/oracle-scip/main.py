import json
import os
import shutil
import subprocess
import sys
import tempfile

SECONDS_MAX = 900

def pin(root):
    with open(os.path.join(root, "PIN"), encoding="utf-8") as held:
        return held.read().strip()

def version():
    outcome = subprocess.run(
        ["rust-analyzer", "--version"], capture_output=True, text=True, check=False
    )

    return outcome.stdout.strip()

def projects(root):
    found = []

    for directory, names, files in os.walk(root, followlinks=True):
        names[:] = [name for name in names if name != "target"]

        if "Cargo.toml" in files:
            found.append(directory)

    found.sort(key=lambda held: (held.count(os.sep), held))

    return found

def sources(project):
    found = set()

    for directory, names, files in os.walk(project, followlinks=True):
        names[:] = [name for name in names if name != "target"]

        for name in files:
            if name.endswith(".rs"):
                found.add(os.path.join(directory, name))

    return found

def nightly():
    outcome = subprocess.run(
        ["rustup", "which", "--toolchain", "nightly", "cargo"],
        capture_output=True,
        text=True,
        check=False,
    )

    held = outcome.stdout.strip()

    return held if outcome.returncode == 0 and os.path.exists(held) else None

def varint(data, offset):
    value = 0
    shift = 0

    while True:
        byte = data[offset]
        offset += 1
        value |= (byte & 0x7F) << shift

        if not byte & 0x80:
            return value, offset

        shift += 7

def fields(data, start=0, stop=None):
    stop = len(data) if stop is None else stop
    offset = start

    while offset < stop:
        tag, offset = varint(data, offset)
        number, wire = tag >> 3, tag & 7

        if wire == 0:
            value, offset = varint(data, offset)

            yield number, value, None
        elif wire == 2:
            length, offset = varint(data, offset)

            yield number, None, data[offset : offset + length]
            offset += length
        elif wire == 5:
            offset += 4
        elif wire == 1:
            offset += 8
        else:
            raise ValueError(f"unknown wire type {wire}")

def packed(blob):
    found = []
    offset = 0

    while offset < len(blob):
        value, offset = varint(blob, offset)
        found.append(value)

    return found

class Places:
    def __init__(self, text):
        self.text = text
        self.starts = [0]

        for index, byte in enumerate(text):
            if byte == "\n":
                self.starts.append(index + 1)

    def offset_of(self, line, character):
        if line >= len(self.starts):
            return None

        start = self.starts[line]
        stop = self.text.find("\n", start)
        stop = len(self.text) if stop < 0 else stop
        held = self.text[start:stop].encode("utf-16-le")
        prefix = held[: character * 2].decode("utf-16-le", "ignore")

        return start + len(prefix)

    def bytes_of(self, offset):
        return len(self.text[:offset].encode("utf-8"))

def read(path):
    try:
        with open(path, encoding="utf-8") as held:
            return held.read()
    except (OSError, UnicodeDecodeError):
        return None

def documents_of(data):
    for number, _, blob in fields(data):
        if number != 2:
            continue

        path = None
        rows = []

        for held, _, inner in fields(blob):
            if held == 1 and inner is not None:
                path = inner.decode("utf-8", "replace")

                continue

            if held != 2 or inner is None:
                continue

            span = None
            symbol = None
            roles = 0

            for tag, value, piece in fields(inner):
                if tag == 1 and piece is not None:
                    span = packed(piece)
                elif tag == 2 and piece is not None:
                    symbol = piece.decode("utf-8", "replace")
                elif tag == 3 and value is not None:
                    roles = value

            if span and symbol:
                rows.append((span, symbol, roles))

        if path is not None:
            yield path, rows

def index(project, config, cargo=None):
    environment = dict(os.environ)

    if cargo is not None:
        environment["CARGO"] = cargo

    with tempfile.TemporaryDirectory() as work:
        target = os.path.join(work, "index.scip")

        try:
            outcome = subprocess.run(
                [
                    "rust-analyzer",
                    "scip",
                    project,
                    "--config-path",
                    config,
                    "--output",
                    target,
                ],
                capture_output=True,
                text=True,
                check=False,
                env=environment,
                timeout=SECONDS_MAX,
            )
        except subprocess.TimeoutExpired:
            return None

        if outcome.returncode != 0 or not os.path.exists(target):
            return None

        with open(target, "rb") as held:
            return held.read()

def indexed(project, config, cargo, source_root):
    data = index(project, config)

    if not data or not any(True for _ in documents_of(data)):
        data = index(project, config, cargo) if cargo else data

    if data is not None:
        return rows_of(data, project, source_root)

    with tempfile.TemporaryDirectory() as work:
        detached = os.path.join(work, os.path.basename(project))

        try:
            shutil.copytree(
                project, detached, symlinks=True, ignore=shutil.ignore_patterns("target")
            )
        except OSError:
            return None

        data = index(detached, config, cargo)

        if data is None:
            return None

        found = {}

        for path, rows in rows_of(data, detached, detached).items():
            named = os.path.join(project, os.path.relpath(path, detached))

            if named.startswith(source_root):
                found[named] = rows

    return found

def rows_of(data, project, source_root):
    found = {}

    for path, rows in documents_of(data):
        full = os.path.normpath(os.path.join(project, path))

        if not full.startswith(source_root):
            continue

        text = read(full)

        if text is None:
            continue

        places = Places(text)
        settled = {}

        for span, symbol, roles in rows:
            if roles & 1:
                settled.setdefault(symbol, []).append(span)

        settled = {symbol: held[0] for symbol, held in settled.items() if len(held) == 1}

        for span, symbol, roles in rows:
            if roles & 1:
                continue

            offset = places.offset_of(span[0], span[1])

            if offset is None:
                continue

            landing = settled.get(symbol)

            if landing is None:
                found.setdefault(full, []).append([places.bytes_of(offset), -1])

                continue

            held = places.offset_of(landing[0], landing[1])

            if held is None:
                continue

            found.setdefault(full, []).append(
                [places.bytes_of(offset), places.bytes_of(held)]
            )

    for rows in found.values():
        rows.sort()

    return found

def main():
    if len(sys.argv) != 3:
        print("usage: main.py <source-root> <destination>", file=sys.stderr)

        return 2

    root = os.path.dirname(os.path.abspath(__file__))
    wanted = pin(root)
    held = version()

    if wanted not in held:
        print(f"rust-analyzer is {held or 'missing'} and the pin is {wanted}", file=sys.stderr)

        return 2

    config = os.path.join(root, "config.json")
    source_root = os.path.abspath(sys.argv[1])
    destination = os.path.abspath(sys.argv[2])
    found = projects(source_root)

    if not found:
        print(f"no cargo projects under {source_root}", file=sys.stderr)

        return 1

    written = 0
    skipped = 0
    covered = set()
    cargo = nightly()

    for project in found:
        if sources(project) <= covered:
            continue

        held = indexed(project, config, cargo, source_root)

        if held is None:
            skipped += 1
            print(f"{project} did not index", file=sys.stderr)

            continue

        covered |= set(held)

        for path, rows in held.items():
            name = os.path.relpath(path, source_root).replace(os.sep, "/")
            target = os.path.join(destination, f"{name}.json")

            os.makedirs(os.path.dirname(target), exist_ok=True)

            with open(target, "w", encoding="utf-8") as out:
                json.dump(
                    {"rust-analyzer": wanted, "broken": False, "rows": rows},
                    out,
                    separators=(",", ":"),
                )
                out.write("\n")

            written += 1

    print(f"wrote {written} files for rust-analyzer {wanted}, {skipped} projects skipped")

    return 0

if __name__ == "__main__":
    raise SystemExit(main())
