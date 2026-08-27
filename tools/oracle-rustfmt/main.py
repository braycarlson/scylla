import os
import shutil
import subprocess
import sys
import tempfile


BINARY = os.environ.get("RUSTFMT", "rustfmt")


def pin(root):
    with open(os.path.join(root, "PIN"), encoding="utf-8") as held:
        return held.read().strip()


def version():
    held = subprocess.run(
        [BINARY, "--version"],
        capture_output=True,
        text=True,
        check=False,
    )

    words = held.stdout.split()

    return words[1] if len(words) > 1 else ""


def sources(root):
    found = []

    for directory, _, names in os.walk(root, followlinks=True):
        for name in names:
            if not name.endswith(".rs"):
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
    wanted = pin(root)
    held = version()

    if held != wanted:
        print(f"rustfmt is {held}, and the pin is {wanted}", file=sys.stderr)

        return 1

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

            outcome = subprocess.run(
                [BINARY, "--edition", "2024", "--emit", "stdout", "--quiet", target],
                capture_output=True,
                check=False,
            )

            if outcome.returncode != 0:
                continue

            final = os.path.join(destination, name)

            os.makedirs(os.path.dirname(final), exist_ok=True)

            with open(final, "wb") as out:
                out.write(outcome.stdout)

            written += 1

    print(f"wrote {written} files for rustfmt {wanted}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
