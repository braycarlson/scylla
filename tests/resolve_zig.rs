#[path = "common/corpus.rs"]
mod corpus;
#[path = "common/floor.rs"]
mod floor;

use std::fs;
use std::path::{Path, PathBuf};

use scylla::bounded::BoundedVec;
use scylla::language::Lexer as _;
use scylla::lex::ZIG;
use scylla::syntax::Structure;
use scylla::syntax::zig::classify::classify;
use scylla::syntax::zig::kind::ZigKind;
use scylla::syntax::zig::parse;
use scylla::syntax::zig::semantic::{Resolution, Semantic};
use scylla::token::{Lex, Tokens};
use scylla::tree::{Events, NONE, Tree};

const ERROR_COUNT_MAX: u32 = 1 << 12;
const EVENT_COUNT_MAX: u32 = 1 << 21;
const NODE_COUNT_MAX: u32 = 1 << 18;
const TABLE_COUNT_MAX: u32 = 1 << 16;
const TOKEN_COUNT_MAX: u32 = 1 << 18;

const UNIVERSE: [&[u8]; 12] = [
    b"None",
    b"Self",
    b"Some",
    b"bool",
    b"console",
    b"error",
    b"int",
    b"len",
    b"print",
    b"string",
    b"usize",
    b"void",
];

struct Fixture {
    name: String,
    source: Vec<u8>,
}

struct Machine {
    events: Events<ZigKind>,
    lexed: Tokens,
    raw: BoundedVec<ZigKind>,
    semantic: Semantic,
    tokens: Tokens,
    tree: Tree<ZigKind>,
}

impl Machine {
    fn reserve() -> Self {
        Self {
            events: Events::reserve(EVENT_COUNT_MAX),
            lexed: Tokens::reserve(TOKEN_COUNT_MAX),
            raw: BoundedVec::reserve(TOKEN_COUNT_MAX),
            semantic: Semantic::reserve(
                TABLE_COUNT_MAX,
                TABLE_COUNT_MAX,
                TABLE_COUNT_MAX,
                TABLE_COUNT_MAX,
            ),
            tokens: Tokens::reserve(TOKEN_COUNT_MAX),
            tree: Tree::reserve(NODE_COUNT_MAX, ERROR_COUNT_MAX),
        }
    }

    fn build(&mut self, source: &[u8]) -> bool {
        self.lexed.clear();

        if ZIG.lex(source, &mut self.lexed) != Lex::Complete {
            return false;
        }

        if !classify(
            source,
            self.lexed.as_slice(),
            &mut self.tokens,
            &mut self.raw,
        ) {
            return false;
        }

        parse::build(
            source,
            self.tokens.as_slice(),
            &self.raw,
            &mut self.events,
            &mut self.tree,
        );

        if !self.tree.errors().is_empty() {
            return false;
        }

        self.semantic.build(
            source,
            self.tokens.as_slice(),
            &self.raw,
            &self.tree,
            &UNIVERSE,
        ) == Structure::Complete
    }

    fn reachable(&self, offset: u32, landing: u32) -> bool {
        let Some(reference) = self
            .semantic
            .references()
            .iter()
            .find(|held| held.name.offset == offset)
        else {
            return false;
        };

        let Some(binding) = self
            .semantic
            .bindings()
            .iter()
            .find(|held| held.name.offset == landing)
        else {
            return false;
        };

        let mut scope = reference.scope;

        for _ in 0..=self.semantic.scopes().len() {
            if scope == binding.scope {
                return true;
            }

            let Some(held) = self.semantic.scopes().get(scope as usize) else {
                return false;
            };

            if held.parent == NONE {
                return false;
            }

            scope = held.parent;
        }

        false
    }

    fn conditional(&self, source: &[u8], offset: u32) -> bool {
        let Some(reference) = self
            .semantic
            .references()
            .iter()
            .find(|held| held.name.offset == offset)
        else {
            return false;
        };

        let Resolution::Bound(index) = reference.resolution else {
            return false;
        };

        let Some(binding) = self.semantic.get(index) else {
            return false;
        };

        let Some(scope) = self.semantic.scopes().get(binding.scope as usize) else {
            return false;
        };

        if scope.kind.is_ordered() {
            return false;
        }

        let name = &source[binding.name.range()];

        self.semantic
            .bindings()
            .iter()
            .filter(|held| held.scope == binding.scope)
            .filter(|held| &source[held.name.range()] == name)
            .count()
            > 1
    }

    fn landing(&self, offset: u32) -> Option<i64> {
        let held = self
            .semantic
            .references()
            .iter()
            .find(|held| held.name.offset == offset)?;

        match held.resolution {
            Resolution::Bound(index) => {
                let binding = self.semantic.get(index)?;

                Some(i64::from(binding.name.offset))
            }
            Resolution::Builtin | Resolution::Unresolved => Some(-1),
        }
    }
}

fn named(source: &[u8], offset: u32) -> &[u8] {
    let start = offset as usize;

    if start >= source.len() {
        return &[];
    }

    let mut end = start;

    while end < source.len() && (source[end].is_ascii_alphanumeric() || source[end] == b'_') {
        end += 1;
    }

    &source[start..end]
}

fn find(text: &[u8], needle: &[u8]) -> Option<usize> {
    text.windows(needle.len()).position(|held| held == needle)
}

fn quoted(text: &[u8], from: usize) -> Option<(String, usize)> {
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

        if byte == b'\\' {
            offset += 1;

            continue;
        }

        if byte == b'"' {
            return Some((found, offset));
        }

        found.push(byte as char);
    }

    None
}

struct Golden {
    broken: bool,
    rows: Vec<(u32, i64)>,
}

fn golden(root: &Path, name: &str) -> Option<Golden> {
    let text = fs::read(root.join(format!("{name}.json"))).ok()?;
    let broken = find(&text, b"\"broken\":true").is_some();
    let Some(start) = find(&text, b"\"rows\":[") else {
        return Some(Golden {
            broken,
            rows: Vec::new(),
        });
    };

    let mut offset = start + b"\"rows\":[".len();
    let mut rows = Vec::new();

    while offset < text.len() && text[offset] == b'[' {
        offset += 1;

        let mut use_offset = 0_u32;

        while offset < text.len() && text[offset].is_ascii_digit() {
            use_offset = use_offset * 10 + u32::from(text[offset] - b'0');
            offset += 1;
        }

        while offset < text.len() && text[offset] != b',' {
            offset += 1;
        }

        offset += 1;

        let negative = offset < text.len() && text[offset] == b'-';

        if negative {
            offset += 1;
        }

        let mut landed = 0_i64;

        while offset < text.len() && text[offset].is_ascii_digit() {
            landed = landed * 10 + i64::from(text[offset] - b'0');
            offset += 1;
        }

        rows.push((use_offset, if negative { -landed } else { landed }));

        while offset < text.len() && text[offset] != b']' {
            offset += 1;
        }

        offset += 1;

        if offset < text.len() && text[offset] == b',' {
            offset += 1;
        }
    }

    Some(Golden { broken, rows })
}

fn residue() -> Vec<String> {
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/residue-zig-resolve.json");
    let Ok(text) = fs::read(&path) else {
        return Vec::new();
    };

    let mut found = Vec::new();
    let mut offset = 0;

    while let Some(start) = find(&text[offset..], b"\"fixture\":") {
        let Some((name, next)) = quoted(&text, offset + start + 10) else {
            break;
        };

        found.push(name);
        offset = next;
    }

    found
}

fn corpus_files() -> Vec<Fixture> {
    let Some(root) = corpus::root() else {
        return Vec::new();
    };

    let mut found = Vec::new();

    collect(&root, &root, &mut found);
    found.sort_by(|left, right| left.name.cmp(&right.name));

    found
}

fn collect(root: &Path, base: &Path, found: &mut Vec<Fixture>) {
    let Ok(entries) = fs::read_dir(root) else {
        return;
    };

    for entry in entries.flatten() {
        let path = entry.path();
        let Ok(held) = fs::metadata(&path) else {
            continue;
        };

        if held.is_dir() {
            collect(&path, base, found);

            continue;
        }

        if path.extension().is_none_or(|extension| extension != "zig") {
            continue;
        }

        let Ok(source) = fs::read(&path) else {
            continue;
        };

        found.push(Fixture {
            name: path
                .strip_prefix(base)
                .unwrap_or(&path)
                .to_string_lossy()
                .replace('\\', "/"),
            source,
        });
    }
}

fn moved_rows(
    source: &[u8],
    recorded: &[(u32, i64)],
    machine: &Machine,
    rows: &mut usize,
) -> Vec<String> {
    let mut moved = Vec::new();

    for (offset, landed) in recorded {
        let Ok(landing) = u32::try_from(*landed) else {
            continue;
        };

        if named(source, *offset) != named(source, landing) {
            continue;
        }

        if machine.conditional(source, *offset) || !machine.reachable(*offset, landing) {
            continue;
        }

        let Some(mine) = machine.landing(*offset) else {
            continue;
        };

        *rows += 1;

        if mine != *landed {
            moved.push(format!("  {offset} zls {landed} scylla {mine}\n"));
        }
    }

    moved.truncate(6);

    moved
}

#[test]
fn the_corpus_resolves_what_zls_resolves() {
    let Some(held) = corpus::zls() else {
        return;
    };

    let found = corpus_files();

    if found.is_empty() {
        return;
    }

    let carried = residue();
    let mut abstained = 0;
    let mut compared = 0;
    let mut differing = Vec::new();
    let mut machine = Machine::reserve();
    let mut rows = 0_usize;

    for fixture in &found {
        if carried.contains(&fixture.name) {
            continue;
        }

        let Some(recorded) = golden(&held, &fixture.name) else {
            abstained += 1;

            continue;
        };

        if recorded.broken || !machine.build(&fixture.source) {
            abstained += 1;

            continue;
        }

        let moved = moved_rows(&fixture.source, &recorded.rows, &machine, &mut rows);

        if !moved.is_empty() {
            differing.push(format!("=== {}\n{}", fixture.name, moved.join("")));
        }

        compared += 1;
    }

    assert!(
        compared + carried.len() >= floor::CORPUS_RESOLVE_ZIG.files,
        "the corpus lost its Zig files: {} named, {abstained} abstained, floor {}",
        compared + carried.len(),
        floor::CORPUS_RESOLVE_ZIG.files
    );

    assert!(
        rows >= floor::CORPUS_RESOLVE_ZIG.rows,
        "{rows} names compared, floor {}",
        floor::CORPUS_RESOLVE_ZIG.rows
    );

    if !differing.is_empty() {
        if let Ok(path) = std::env::var("SCYLLA_REPORT") {
            fs::write(path, differing.join("")).expect("the report is writable");
        }

        let mut shown = differing.clone();

        shown.truncate(3);

        panic!(
            "{} files resolve differently\n{}",
            differing.len(),
            shown.join("")
        );
    }
}
