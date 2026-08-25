tool_dir := "tools"

default: fmt clippy test

fmt:
    cargo +nightly fmt --check

clippy:
    cargo clippy --all-targets -- --deny warnings
    cargo clippy --all-targets --features fuzzing -- --deny warnings

test:
    cargo test
    cargo test --release

bench:
    cargo bench

lint:
    cargo run --release --quiet --manifest-path ../tigerstyle-lsp/Cargo.toml -- check --no-cache .

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

coverage:
    cargo llvm-cov --all-targets --summary-only

mutants:
    cargo mutants --in-place --timeout 60
