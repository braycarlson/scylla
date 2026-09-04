tool_dir := "tools"

default: fmt clippy test

fmt:
    cargo +nightly fmt --check
    cargo +nightly fmt --check --manifest-path {{tool_dir}}/runner/Cargo.toml

clippy:
    cargo clippy --all-targets -- --deny warnings
    cargo clippy --all-targets --features fuzzing -- --deny warnings
    cargo clippy --all-targets --manifest-path {{tool_dir}}/runner/Cargo.toml -- --deny warnings

test:
    cargo test
    cargo test --release
    cargo test --release --manifest-path {{tool_dir}}/runner/Cargo.toml

lane:
    cargo test --release --no-fail-fast \
        --test format_javascript --test format_rust --test format_typescript --test tidy

bench:
    cargo bench

lint:
    cargo run --release --quiet --manifest-path ../tigerstyle-lsp/Cargo.toml -- check --no-cache src tests benches

adversarial rounds="64":
    SCYLLA_ADVERSARIAL={{rounds}} cargo test --release --test adversarial --test project_parallel

oracle:
    #!/usr/bin/env bash
    set -euo pipefail
    (cd {{tool_dir}}/oracle-syn && cargo build --release)
    (cd {{tool_dir}}/oracle-treesitter && cargo build --release)
    if command -v go > /dev/null; then
        (cd {{tool_dir}}/oracle-go && go build -o oracle-go .)
        (cd {{tool_dir}}/oracle-gotypes && go build -o oracle-gotypes .)
    else
        echo "go is not installed; the go oracles are skipped"
    fi
    if command -v zig > /dev/null; then
        (cd {{tool_dir}}/oracle-zig && zig build -Doptimize=ReleaseFast)
    else
        echo "zig is not installed; the zig oracle is skipped"
    fi
    if command -v odin > /dev/null; then
        {{tool_dir}}/oracle-ols/build.sh
    else
        echo "odin is not installed; the ols oracle is skipped"
    fi

coverage:
    cargo llvm-cov --all-targets --summary-only

runner corpus level="tree" out="divergences.jsonl":
    cargo run --release --manifest-path {{tool_dir}}/runner/Cargo.toml --bin runner -- \
        --corpus {{corpus}} --level {{level}} --out {{out}} --minimize

generate out="generated":
    #!/usr/bin/env bash
    set -euo pipefail
    manifest="{{tool_dir}}/runner/Cargo.toml"
    lock="{{tool_dir}}/runner/Cargo.lock"
    registry="$(ls -d "$HOME"/.cargo/registry/src/* | head -1)"
    cargo build --release --manifest-path "$manifest" --bin generate
    generate="{{tool_dir}}/runner/target/release/generate"
    version_of() {
        awk -v name="$1" '
            $1 == "name" && $3 == "\"" name "\"" { found = 1; next }
            found && $1 == "version" { gsub(/"/, "", $3); print $3; exit }
        ' "$lock"
    }
    for pair in "css:css:src" "javascript:js:src" "odin:odin:src"; do
        crate="${pair%%:*}"
        rest="${pair#*:}"
        extension="${rest%%:*}"
        held="$registry/tree-sitter-$crate-$(version_of "tree-sitter-$crate")/src/grammar.json"
        "$generate" --grammar "$held" --extension "$extension" --out "{{out}}"
    done
    held="$registry/tree-sitter-typescript-$(version_of tree-sitter-typescript)"
    "$generate" --grammar "$held/typescript/src/grammar.json" --extension ts --out "{{out}}"
    "$generate" --grammar "$held/tsx/src/grammar.json" --extension tsx --out "{{out}}"

fuzz target seconds="600":
    cargo +nightly fuzz run {{target}} -- -max_total_time={{seconds}} -rss_limit_mb=8192 -timeout=10

triage:
    python3 tools/server/triage.py --minimize

mutants:
    cargo mutants --in-place --timeout 60

mutants-of language:
    cargo mutants --in-place --timeout 60 \
        --file "src/syntax/{{language}}/**/*.rs" \
        --file "src/lex/{{language}}.rs"
