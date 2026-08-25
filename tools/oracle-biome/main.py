import os
import shutil
import subprocess
import sys
import tempfile


PACKAGE = "@biomejs/biome"


def pin(root):
    with open(os.path.join(root, "PIN"), encoding="utf-8") as held:
        return held.read().strip()


def sources(root, extension):
    found = []

    for directory, _, names in os.walk(root):
        for name in names:
            if not name.endswith(extension):
                continue

            path = os.path.join(directory, name)
            found.append((os.path.relpath(path, root).replace(os.sep, "/"), path))

    found.sort()

    return found


def main():
    if len(sys.argv) != 4:
        print("usage: dump.py <extension> <source-root> <destination>", file=sys.stderr)

        return 2

    root = os.path.dirname(os.path.abspath(__file__))
    version = pin(root)
    extension = sys.argv[1]
    source_root = os.path.abspath(sys.argv[2])
    destination = os.path.abspath(sys.argv[3])
    found = sources(source_root, extension)

    if not found:
        print(f"no {extension} sources under {source_root}", file=sys.stderr)

        return 1

    written = 0

    with tempfile.TemporaryDirectory() as staged:
        shutil.copyfile(
            os.path.join(root, "biome.json"),
            os.path.join(staged, "biome.json"),
        )

        for name, path in found:
            target = os.path.join(staged, name)

            os.makedirs(os.path.dirname(target), exist_ok=True)
            shutil.copyfile(path, target)

            outcome = subprocess.run(
                [
                    "npx",
                    "--yes",
                    f"{PACKAGE}@{version}",
                    "format",
                    "--write",
                    name,
                ],
                capture_output=True,
                cwd=staged,
                check=False,
                text=True,
            )

            if "No fixes applied" in outcome.stdout and "×" in outcome.stdout:
                continue

            final = os.path.join(destination, name)

            os.makedirs(os.path.dirname(final), exist_ok=True)
            shutil.copyfile(target, final)

            written += 1

    print(f"wrote {written} files for biome {version}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
