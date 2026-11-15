# scylla

A statically allocated parser and formatter. The library parses and formats Zig, Rust, Go, Odin, Python, JavaScript, TypeScript, CSS, HTML, and Django templates, and a semantic layer resolves scopes and references over the parse. The memory is reserved at startup from fixed capacities rather than allocated during a parse. The parsers and formatters are held to reference tools such as ruff, rustfmt, gofmt, biome, and `zig fmt` across a corpus of pinned open source projects, with a fuzzer for each language.
