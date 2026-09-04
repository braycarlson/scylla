import os
import subprocess
import sys

PACKAGES = ("@typescript-eslint/parser", "@typescript-eslint/scope-manager")

def pin(root):
    with open(os.path.join(root, "PIN"), encoding="utf-8") as held:
        return held.read().strip()

def installed(root, version):
    marker = os.path.join(root, "node_modules", ".pin")

    if os.path.exists(marker):
        with open(marker, encoding="utf-8") as held:
            if held.read().strip() == version:
                return True

    outcome = subprocess.run(
        [
            "npm",
            "install",
            "--silent",
            "--no-fund",
            "--no-audit",
            "--prefix",
            root,
            *[f"{name}@{version}" for name in PACKAGES],
        ],
        capture_output=True,
        text=True,
        check=False,
    )

    if outcome.returncode != 0:
        print(outcome.stderr.strip(), file=sys.stderr)

        return False

    with open(marker, "w", encoding="utf-8") as held:
        held.write(version)

    return True

def main():
    if len(sys.argv) != 3:
        print("usage: main.py <source-root> <destination>", file=sys.stderr)

        return 2

    root = os.path.dirname(os.path.abspath(__file__))
    version = pin(root)

    if not installed(root, version):
        print(f"the scope-manager oracle is not installed at {version}", file=sys.stderr)

        return 2

    environment = dict(os.environ)
    environment["NODE_PATH"] = os.path.join(root, "node_modules")

    outcome = subprocess.run(
        [
            "node",
            os.path.join(root, "dump.mjs"),
            os.path.abspath(sys.argv[1]),
            os.path.abspath(sys.argv[2]),
        ],
        cwd=root,
        env=environment,
        check=False,
    )

    return outcome.returncode

if __name__ == "__main__":
    sys.exit(main())
