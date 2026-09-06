<p align="center">
    <picture>
        <source media="(prefers-color-scheme: dark)" srcset="https://raw.githubusercontent.com/braycarlson/scylla/main/assets/scylla-wordmark-on-dark.svg">
        <source media="(prefers-color-scheme: light)" srcset="https://raw.githubusercontent.com/braycarlson/scylla/main/assets/scylla-wordmark-on-light.svg">
        <img alt="scylla" src="https://raw.githubusercontent.com/braycarlson/scylla/main/assets/scylla-wordmark-on-light.svg" width="240">
    </picture>
</p>

&nbsp;

<p align="center">
    A statically allocated parser, formatter, and tooling substrate.
</p>

<p align="center">
    <a href="https://github.com/braycarlson/scylla/actions/workflows/ci.yml"><img alt="ci" src="https://img.shields.io/github/actions/workflow/status/braycarlson/scylla/ci.yml?branch=main&amp;style=flat-square&amp;label=ci"></a>
    <a href="https://www.rust-lang.org"><img alt="rust" src="https://img.shields.io/badge/rust-2024-orange.svg?style=flat-square"></a>
    <a href="LICENSE"><img alt="license" src="https://img.shields.io/badge/license-MIT-blue.svg?style=flat-square"></a>
</p>

## Overview

scylla lexes, parses, and formats several languages, and hands back the bindings, scopes,
and references of each through one shared view. Every table is reserved from a `Limits`
struct before the first byte is read, and a file that outgrows the reservation is refused
rather than served by a growing buffer. The memory ceiling is a constant you choose rather than a property of the input.

## Features

- **Static allocation**: The `allocation::freeze` call arms `GuardAllocator`, and each
  heap request after it panics with the operation and the byte count.
- **Bounded containers**: Each container takes its capacity in `reserve` and refuses to
  grow past it. A file that outgrows the reservation is reported as truncated.
- **Languages**: There are lexers, parsers, and formatters for CSS, Go, JavaScript, Odin,
  Python, Rust, TypeScript, TSX, Zig, and markup.
- **One semantic shape**: A built `Front` hands back the bindings, scopes, references, and exports of any language through the same `View`.
- **Oracle tests**: The output is compared against ruff, rustfmt, gofmt, `zig fmt`, biome,
  oxlint, tree-sitter, `syn`, and `go/types`, each pinned to a version under `tools/`.
- **Tooling modules**: The pieces every linter or language server built on the parsers
  needs, each reserved once and allocation-free afterwards: a rule registry and selector
  (`rule`), diagnostics and fixes (`diagnostic`, `fix`), suppression comments (`suppress`),
  a multi-file store and dependency graph (`project`), a TOML reader (`toml`), config
  discovery with an `extend` chain (`config`), a JSON codec (`json`), LSP framing
  (`transport`), byte-path helpers (`path`), a poll watcher (`watch`), an argument parser
  (`arguments`), a worker pool (`pool`), and a bounded logger (`log`). Nothing in them
  names a product: rule codes, marker words, config file names, and template tag names are
  all parameters the caller supplies.

## Install

The crate is a library with no dependencies and no binary. Nothing is published to
crates.io yet.

```toml
[dependencies]
scylla = { git = "https://github.com/braycarlson/scylla" }
```

scylla requires Rust 1.98.0, which `rust-toolchain.toml` pins.

## Usage

The reservation happens once, the lexer fills a `Tokens` buffer, and `Front::build` turns
that buffer into a tree with its semantic tables beside it.

```rust
use scylla::allocation;
use scylla::language::Language;
use scylla::syntax::front::{self, Front, Limits, Options, Scratch};
use scylla::syntax::python::stdlib::PythonVersion;
use scylla::token::{Lex, Tokens};
use scylla::tree::Structure;

const LIMITS: Limits = Limits {
    binding_count_max: 1 << 12,
    error_count_max: 1 << 8,
    event_count_max: 1 << 18,
    export_count_max: 1 << 10,
    fact_count_max: 1 << 10,
    node_count_max: 1 << 16,
    reference_count_max: 1 << 13,
    scope_count_max: 1 << 10,
    segment_count_max: 1 << 10,
    token_count_max: 1 << 16,
};

fn main() {
    const SOURCE: &[u8] = b"class Held:\n    def run(self):\n        return self\n";

    let mut wanted = [false; Language::COUNT];

    wanted[Language::Python.index()] = true;

    let mut front = Front::reserve(Language::Python, &LIMITS);
    let mut scratch = Scratch::reserve(&LIMITS, wanted);
    let mut lexed = Tokens::reserve(LIMITS.token_count_max);

    let options = Options {
        globals: &[],
        python_version: PythonVersion::Py310,
        template_imports: &[],
    };

    let lexer = front::lexer_of(Language::Python).expect("a code language has a lexer");

    assert_eq!(lexer.lex(SOURCE, &mut lexed), Lex::Complete);

    let outcome = allocation::frozen(|| {
        front.build(SOURCE, lexed.as_slice(), &mut scratch, &options)
    });

    assert_eq!(outcome, Structure::Complete);

    println!("{} nodes, {} bindings", front.count(), front.bindings().count());
}
```

The `allocation::frozen` wrapper is the check rather than the mechanism. Removing it does
not change what `build` does. It removes the proof that `build` touched no heap.

## Development

| Command | What it runs |
|---|---|
| `just` | The format gate, clippy, and each suite, in that order. |
| `just fmt` | The format gate, which is nightly because stable rustfmt ignores `imports_layout`. |
| `just clippy` | Clippy, which the manifest sets to warn on `restriction`. |
| `just test` | Each suite in debug and release, including the tidy law over `src` and `tests`. |
| `just bench` | The pipeline benchmarks, each of which fails if its measured loop allocates. |
| `just lint` | The sibling linter, `tigerstyle-lsp`, over this tree. |
| `just oracle` | Each oracle under `tools/`, skipping the ones whose toolchain is absent. |

## Licence

MIT. See [LICENSE](LICENSE).
