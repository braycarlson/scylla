#!/usr/bin/env bash

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../.." && pwd)"
source_root="$root/corpus/sources/odin"

if [ ! -d "$source_root" ]; then
    echo "the odin source is not in the corpus at $source_root" >&2

    exit 1
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

cp -r "$source_root" "$work/odin"
(cd "$work/odin" && ./build_odin.sh release)
cp "$work/odin/odin" "$here/odin"

for collection in base core vendor; do
    ln -sfn "$source_root/$collection" "$here/$collection"
done

echo "built odin into $here/odin"
