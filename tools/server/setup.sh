#!/usr/bin/env bash

set -euo pipefail

rustup toolchain install nightly \
    --component llvm-tools \
    --component miri \
    --component rust-src

rustup toolchain install 1.98.0 --component clippy --component rustfmt

command -v cargo-fuzz > /dev/null || cargo install cargo-fuzz
command -v cargo-mutants > /dev/null || cargo install cargo-mutants
command -v cargo-llvm-cov > /dev/null || cargo install cargo-llvm-cov
command -v just > /dev/null || cargo install just

echo
echo "setup: cargo-fuzz $(cargo fuzz --version)"
echo "setup: cargo-mutants $(cargo mutants --version)"
echo "setup: cargo-llvm-cov $(cargo llvm-cov --version)"
echo "setup: just $(just --version)"
echo "setup: nightly $(cargo +nightly --version)"
echo
echo "setup: install go, zig, python3, and uv separately if the oracles need them"
