#!/usr/bin/env bash

# ols has no release binary for the pin the corpus carries, so the oracle builds it from the
# corpus checkout into this directory. The binary is ignored; `just oracle` rebuilds it.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../.." && pwd)"
source_root="$root/corpus/sources/ols"

if [ ! -d "$source_root" ]; then
    echo "the ols source is not in the corpus at $source_root" >&2

    exit 1
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

cp -r "$source_root" "$work/ols"
(cd "$work/ols" && ./build.sh)
cp "$work/ols/ols" "$here/ols"

echo "built ols into $here/ols"
