import json
import os
import subprocess
import sys

EXTENSIONS = (".cjs", ".cts", ".js", ".mjs", ".mts", ".ts", ".tsx")
RULES = ("no-redeclare", "no-undef", "no-unused-vars")
BATCH = 256

def pin(root):
    with open(os.path.join(root, "PIN"), encoding="utf-8") as held:
        return held.read().strip()

def sources(root):
    found = []

    for directory, _, names in os.walk(root, followlinks=True):
        for name in names:
            if not name.endswith(EXTENSIONS):
                continue

            path = os.path.join(directory, name)
            found.append((os.path.relpath(path, root).replace(os.sep, "/"), path))

    found.sort()

    return found

def code_of(row):
    held = row.get("code", "")
    open_at = held.find("(")
    close_at = held.rfind(")")

    if open_at == -1 or close_at == -1:
        return held

    return held[open_at + 1 : close_at]

def payload(text):
    start = text.find("{")

    if start == -1:
        return {"diagnostics": []}

    return json.loads(text[start:])

def rows(text, held, broken):
    for row in payload(text)["diagnostics"]:
        code = code_of(row)
        name = os.path.abspath(row["filename"])

        if code not in RULES:
            if not code:
                broken.add(name)

            continue

        labels = row.get("labels", [])

        if not labels:
            continue

        label = labels[-1] if code == "no-redeclare" else labels[0]
        offset = label["span"]["offset"]
        held.setdefault(name, []).append([code, offset])

def run(prefix, batch):
    held = subprocess.run(
        prefix + batch,
        capture_output=True,
        text=True,
        check=False,
    )

    if held.returncode not in (0, 1):
        print(held.stderr, file=sys.stderr)

        return None

    return held.stdout, payload(held.stdout).get("number_of_files", len(batch))

def decline(prefix, batch):
    found = set()
    stack = [batch]

    while stack:
        held = stack.pop()
        outcome = run(prefix, held)

        if outcome is None:
            continue

        _, taken = outcome

        if taken == len(held):
            continue

        if len(held) == 1:
            found.add(held[0])

            continue

        middle = len(held) // 2

        stack.append(held[:middle])
        stack.append(held[middle:])

    return found

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
        "npx",
        "--yes",
        f"oxlint@{version}",
        "--format=json",
        "--no-ignore",
        "-A",
        "all",
    ]

    for rule in RULES:
        prefix += ["-D", rule]

    reported = {}
    broken = set()
    declined = set()

    for start in range(0, len(found), BATCH):
        batch = [path for _, path in found[start : start + BATCH]]
        outcome = run(prefix, batch)

        if outcome is None:
            return 2

        text, taken = outcome

        rows(text, reported, broken)

        if taken != len(batch):
            declined |= decline(prefix, batch)

    written = 0

    for name, path in found:
        if path in declined:
            continue

        rendered = reported.get(path, [])
        rendered.sort()
        target = os.path.join(destination, f"{name}.json")

        os.makedirs(os.path.dirname(target), exist_ok=True)

        with open(target, "w", encoding="utf-8") as out:
            json.dump(
                {
                    "oxlint": version,
                    "ast": rendered,
                    "broken": path in broken,
                },
                out,
                separators=(",", ":"),
            )
            out.write("\n")

        written += 1

    print(f"wrote {written} files for oxlint {version}")

    return 0

if __name__ == "__main__":
    raise SystemExit(main())
