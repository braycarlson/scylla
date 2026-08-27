import os
import shutil
import subprocess
import sys
import tempfile


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

    written = 0

    with tempfile.TemporaryDirectory() as staged:
        for name, path in found:
            target = os.path.join(staged, name)

            os.makedirs(os.path.dirname(target), exist_ok=True)
            shutil.copyfile(path, target)

        command = [
            "uvx",
            f"ruff@{version}",
            "format",
            "--no-cache",
            "--isolated",
            "--force-exclude",
            staged,
        ]
        held = subprocess.run(command, capture_output=True, text=True, check=False)

        if held.returncode != 0:
            print(held.stderr, file=sys.stderr)

            return held.returncode

        for name, _ in found:
            source = os.path.join(staged, name)
            target = os.path.join(destination, name)

            os.makedirs(os.path.dirname(target), exist_ok=True)
            shutil.copyfile(source, target)

            written += 1

    print(f"wrote {written} files for ruff {version}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
