#!/usr/bin/env bash

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
manifest="$here/manifest.txt"
destination="${1:-$here/sources}"

if [ ! -f "$manifest" ]; then
    echo "fetch: $manifest is missing" >&2
    exit 1
fi

mkdir -p "$destination"

fetch_git() {
    local name="$1" origin="$2" pin="$3"
    local path="$destination/$name"

    if [ -d "$path/.git" ]; then
        local held
        held="$(git -C "$path" rev-parse HEAD)"

        if [ "$held" = "$pin" ]; then
            echo "$name: already at $pin"
            return 0
        fi
    else
        rm -rf "$path"
        git init --quiet "$path"
        git -C "$path" remote add origin "$origin"
    fi

    echo "$name: fetching $pin from $origin"

    if ! git -C "$path" fetch --quiet --depth 1 origin "$pin" 2>/dev/null; then
        git -C "$path" fetch --quiet origin
    fi

    git -C "$path" checkout --quiet --detach "$pin"

    local held
    held="$(git -C "$path" rev-parse HEAD)"

    if [ "$held" != "$pin" ]; then
        echo "fetch: $name checked out $held and the manifest pins $pin" >&2
        exit 1
    fi
}

fetch_local() {
    local name="$1" origin="$2" pin="$3"
    local path="$destination/$name"
    local root

    if ! root="$(eval "$origin" 2>/dev/null)"; then
        echo "fetch: $name does not resolve; \`$origin\` failed" >&2
        exit 1
    fi

    case "$name" in
        go) root="$root/src" ;;
        rust) root="$root/lib/rustlib/src/rust/library" ;;
    esac

    if [ ! -d "$root" ]; then
        echo "fetch: $name resolves to $root, which is not a directory" >&2
        exit 1
    fi

    case "$name" in
        go) held="$(go env GOVERSION)" ;;
        rust) held="$(rustup run "$pin" rustc --version | cut -d' ' -f2)" ;;
        python) held="$("$root/../../bin/python3" -c 'import platform; print(platform.python_version())')" ;;
        *) held="$pin" ;;
    esac

    if [ "$held" != "$pin" ]; then
        echo "fetch: $name reports $held and the manifest pins $pin" >&2
        exit 1
    fi

    rm -f "$path"
    ln -s "$root" "$path"

    echo "$name: linked $root at $pin"
}

while IFS=$'\t' read -r kind name language license origin pin; do
    case "${kind:-}" in
        ''|'#'*) continue ;;
    esac

    : "$language" "$license"

    case "$kind" in
        git) fetch_git "$name" "$origin" "$pin" ;;
        local) fetch_local "$name" "$origin" "$pin" ;;
        *)
            echo "fetch: \`$kind\` names no source kind" >&2
            exit 1
            ;;
    esac
done < "$manifest"

echo
echo "corpus at $destination"
