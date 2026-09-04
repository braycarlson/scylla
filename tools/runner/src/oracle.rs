use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::process::Command;

use oracle_treesitter::{walk, Correction};
use tree_sitter::Parser;

use crate::blob::blob_of;

pub struct Read {
    pub accepted: bool,
    pub nodes: Vec<(String, u32, u32)>,
    pub tokens: Vec<(u32, u32)>,
}

pub trait Oracle {
    fn identifier(&self) -> &'static str;
    fn read(&mut self, source: &[u8]) -> Option<Read>;
    fn reads_nodes(&self) -> bool;
    fn reads_tokens(&self) -> bool;
}

pub struct TreeSitter {
    correction: Correction,
    identifier: &'static str,
    parser: Parser,
}

impl TreeSitter {
    pub fn of(
        identifier: &'static str,
        language: &tree_sitter::Language,
        correction: Correction,
    ) -> Result<Self, String> {
        let mut parser = Parser::new();

        parser
            .set_language(language)
            .map_err(|error| format!("the {identifier} grammar is unusable: {error}"))?;

        Ok(Self {
            correction,
            identifier,
            parser,
        })
    }
}

impl Oracle for TreeSitter {
    fn identifier(&self) -> &'static str {
        self.identifier
    }

    fn read(&mut self, source: &[u8]) -> Option<Read> {
        let tree = self.parser.parse(source, None)?;
        let root = tree.root_node();
        let (rows, broken) = walk(root, source, &self.correction);

        let nodes = rows
            .into_iter()
            .map(|row| (row.0, row.1 as u32, row.2 as u32))
            .collect();

        let tokens = vec![(root.start_byte() as u32, root.end_byte() as u32)];

        Some(Read {
            accepted: !broken,
            nodes,
            tokens,
        })
    }

    fn reads_nodes(&self) -> bool {
        true
    }

    fn reads_tokens(&self) -> bool {
        true
    }
}

pub struct Syn;

impl Oracle for Syn {
    fn identifier(&self) -> &'static str {
        "syn"
    }

    fn read(&mut self, source: &[u8]) -> Option<Read> {
        let text = core::str::from_utf8(source).ok()?;

        Some(Read {
            accepted: syn::parse_file(text).is_ok(),
            nodes: Vec::new(),
            tokens: Vec::new(),
        })
    }

    fn reads_nodes(&self) -> bool {
        false
    }

    fn reads_tokens(&self) -> bool {
        false
    }
}

pub struct Ruff;

impl Oracle for Ruff {
    fn identifier(&self) -> &'static str {
        "ruff"
    }

    fn read(&mut self, source: &[u8]) -> Option<Read> {
        let text = core::str::from_utf8(source).ok()?;

        Some(Read {
            accepted: ruff_python_parser::parse_module(text).is_ok(),
            nodes: Vec::new(),
            tokens: Vec::new(),
        })
    }

    fn reads_nodes(&self) -> bool {
        false
    }

    fn reads_tokens(&self) -> bool {
        false
    }
}

const CACHE_COUNT_MAX: usize = 1 << 12;

pub struct Batch {
    binary: PathBuf,
    cache: HashMap<String, Option<Read>>,
    extension: &'static str,
    identifier: &'static str,
    scratch: PathBuf,
}

impl Batch {
    pub fn of(
        identifier: &'static str,
        binary: PathBuf,
        extension: &'static str,
        version: &Version<'_>,
    ) -> Result<Self, String> {
        if !binary.is_file() {
            return Err(format!(
                "the {identifier} oracle is not built at {}; run `just oracle`",
                binary.display()
            ));
        }

        version.enforce(identifier)?;

        let scratch = std::env::temp_dir().join(format!(
            "scylla-runner-{identifier}-{}",
            std::process::id()
        ));

        Ok(Self {
            binary,
            cache: HashMap::new(),
            extension,
            identifier,
            scratch,
        })
    }

    fn dump(&self, source: &[u8]) -> Option<Read> {
        let sources = self.scratch.join("sources");
        let goldens = self.scratch.join("goldens");

        let _ = std::fs::remove_dir_all(&self.scratch);

        std::fs::create_dir_all(&sources).ok()?;
        std::fs::create_dir_all(&goldens).ok()?;

        let name = format!("input.{}", self.extension);

        std::fs::write(sources.join(&name), source).ok()?;

        let outcome = Command::new(&self.binary)
            .arg(&sources)
            .arg(&goldens)
            .output()
            .ok()?;

        if !outcome.status.success() {
            return None;
        }

        let Ok(text) = std::fs::read(goldens.join(format!("{name}.json"))) else {
            return Some(Read {
                accepted: false,
                nodes: Vec::new(),
                tokens: Vec::new(),
            });
        };

        let nodes = rows_of(&text);

        Some(Read {
            accepted: !find(&text, b"\"broken\":true"),
            nodes,
            tokens: Vec::new(),
        })
    }
}

impl Oracle for Batch {
    fn identifier(&self) -> &'static str {
        self.identifier
    }

    fn read(&mut self, source: &[u8]) -> Option<Read> {
        let blob = blob_of(source);

        if let Some(held) = self.cache.get(&blob) {
            return held.as_ref().map(|read| Read {
                accepted: read.accepted,
                nodes: read.nodes.clone(),
                tokens: read.tokens.clone(),
            });
        }

        let read = self.dump(source);

        if self.cache.len() >= CACHE_COUNT_MAX {
            self.cache.clear();
        }

        self.cache.insert(
            blob,
            read.as_ref().map(|held| Read {
                accepted: held.accepted,
                nodes: held.nodes.clone(),
                tokens: held.tokens.clone(),
            }),
        );

        read
    }

    fn reads_nodes(&self) -> bool {
        true
    }

    fn reads_tokens(&self) -> bool {
        false
    }
}

pub struct Version<'run> {
    pub arguments: &'run [&'run str],
    pub pin: &'run Path,
    pub program: &'run str,
}

impl Version<'_> {
    pub fn enforce(&self, identifier: &str) -> Result<(), String> {
        let wanted = std::fs::read_to_string(self.pin)
            .map_err(|error| format!("{} is unreadable: {error}", self.pin.display()))?;

        let wanted = wanted.trim();

        let outcome = Command::new(self.program)
            .args(self.arguments)
            .output()
            .map_err(|error| format!("`{}` does not run: {error}", self.program))?;

        let held = String::from_utf8_lossy(&outcome.stdout);

        if held.contains(wanted) {
            return Ok(());
        }

        Err(format!(
            "the {identifier} oracle is pinned to `{wanted}` and `{} {}` reports `{}`",
            self.program,
            self.arguments.join(" "),
            held.trim()
        ))
    }
}

fn find(text: &[u8], key: &[u8]) -> bool {
    text.windows(key.len()).any(|window| window == key)
}

fn rows_of(text: &[u8]) -> Vec<(String, u32, u32)> {
    let key = b"\"ast\":[";

    let Some(start) = text
        .windows(key.len())
        .position(|window| window == key)
        .map(|offset| offset + key.len())
    else {
        return Vec::new();
    };

    let mut found = Vec::new();
    let mut offset = start;

    while offset < text.len() {
        if text[offset] != b'[' {
            break;
        }

        let Some((name, after)) = quoted(text, offset) else {
            break;
        };

        let (first, next) = number(text, after);
        let (second, tail) = number(text, next);

        found.push((name, first, second));
        offset = tail;

        if offset < text.len() && text[offset] == b']' {
            offset += 1;
        }

        if offset < text.len() && text[offset] == b',' {
            offset += 1;

            continue;
        }

        break;
    }

    found
}

fn number(text: &[u8], from: usize) -> (u32, usize) {
    let mut offset = from;

    while offset < text.len() && !text[offset].is_ascii_digit() {
        offset += 1;
    }

    let mut value = 0_u32;

    while offset < text.len() && text[offset].is_ascii_digit() {
        value = value * 10 + u32::from(text[offset] - b'0');
        offset += 1;
    }

    (value, offset)
}

pub fn quoted(text: &[u8], from: usize) -> Option<(String, usize)> {
    let mut offset = from;

    while offset < text.len() && text[offset] != b'"' {
        offset += 1;
    }

    if offset >= text.len() {
        return None;
    }

    offset += 1;

    let mut found = String::new();

    while offset < text.len() {
        let byte = text[offset];

        offset += 1;

        if byte == b'"' {
            return Some((found, offset));
        }

        found.push(byte as char);
    }

    None
}
