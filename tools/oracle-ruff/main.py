import json
import os
import subprocess
import sys

BATCH = 512
CODES = "F401,F404,F622,F704,F706,F707,F811,F821,F841,PLE0117,PLE0118,PLE1142"

def pin(root):
    with open(os.path.join(root, "PIN"), encoding="utf-8") as held:
        return held.read().strip()

def sources(root):
    found = []

    for directory, _, names in os.walk(root, followlinks=True):
        for name in names:
            if not name.endswith(".py"):
                continue

            path = os.path.join(directory, name)
            found.append((os.path.relpath(path, root).replace(os.sep, "/"), path))

    found.sort()

    return found

def rows(text):
    held = {}

    for row in json.loads(text):
        name = row["filename"]
        start = row["location"]
        held.setdefault(name, []).append([row["code"], start["row"], start["column"]])

    return held

def main():
    if len(sys.argv) != 3:
        print("usage: dump.py <source-root> <destination>", file=sys.stderr)

        return 2

    root = os.path.dirname(os.path.abspath(__file__))
    version = pin(root)
    source_root = os.path.abspath(sys.argv[1])
    destination = os.path.abspath(sys.argv[2])
    found = sources(source_root)

    if not found:
        print(f"no sources under {source_root}", file=sys.stderr)

        return 1

    prefix = [
        "uvx",
        f"ruff@{version}",
        "check",
        "--no-cache",
        "--isolated",
        "--config",
        "exclude = []",
        "--select",
        CODES,
        "--output-format",
        "json",
        "--force-exclude",
    ]
    reported = {}

    for start in range(0, len(found), BATCH):
        batch = [path for _, path in found[start : start + BATCH]]
        held = subprocess.run(prefix + batch, capture_output=True, text=True, check=False)

        if held.returncode not in (0, 1):
            print(held.stderr, file=sys.stderr)

            return held.returncode

        for name, rendered in rows(held.stdout).items():
            reported.setdefault(name, []).extend(rendered)
    written = 0

    for name, path in found:
        rendered = reported.get(path, [])
        rendered.sort()
        target = os.path.join(destination, f"{name}.json")

        os.makedirs(os.path.dirname(target), exist_ok=True)

        with open(target, "w", encoding="utf-8") as out:
            json.dump({"ruff": version, "ast": rendered}, out, separators=(",", ":"))
            out.write("\n")

        written += 1

    print(f"wrote {written} files for ruff {version}")

    return 0

if __name__ == "__main__":
    raise SystemExit(main())
