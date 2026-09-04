#[path = "common/corpus.rs"]
mod corpus;
#[path = "common/floor.rs"]
mod floor;
#[path = "common/oracle.rs"]
mod oracle;

use std::fs;
use std::path::{Path, PathBuf};

use scylla::bounded::BoundedVec;
use scylla::language::Lexer as _;
use scylla::lex::{JAVASCRIPT, TYPESCRIPT};
use scylla::syntax::Structure;
use scylla::syntax::javascript::classify::classify;
use scylla::syntax::javascript::kind::JavaScriptKind;
use scylla::syntax::javascript::parse;
use scylla::syntax::javascript::semantic::{Resolution, Semantic};
use scylla::syntax::typescript::classify::classify as typescript_classify;
use scylla::syntax::typescript::dialect::Dialect;
use scylla::syntax::typescript::kind::TypeScriptKind;
use scylla::syntax::typescript::parse as typescript_parse;
use scylla::token::Tokens;
use scylla::tree::{Events, NONE, Tree};

const BINDING_COUNT_MAX: u32 = 1 << 16;
const ERROR_COUNT_MAX: u32 = 1 << 12;
const EVENT_COUNT_MAX: u32 = 1 << 21;
const EVERY_CATEGORY: [&str; 3] = ["function-body-scope", "not-javascript", "type-query-value"];
const FACT_COUNT_MAX: u32 = 1 << 14;
const NODE_COUNT_MAX: u32 = 1 << 19;
const REFERENCE_COUNT_MAX: u32 = 1 << 18;
const SCOPE_COUNT_MAX: u32 = 1 << 16;
const TOKEN_COUNT_MAX: u32 = 1 << 19;

const GLOBALS: [&[u8]; 61] = [
    b"AggregateError",
    b"arguments",
    b"Array",
    b"ArrayBuffer",
    b"Atomics",
    b"BigInt",
    b"BigInt64Array",
    b"BigUint64Array",
    b"Boolean",
    b"DataView",
    b"Date",
    b"decodeURI",
    b"decodeURIComponent",
    b"encodeURI",
    b"encodeURIComponent",
    b"Error",
    b"escape",
    b"eval",
    b"EvalError",
    b"FinalizationRegistry",
    b"Float32Array",
    b"Float64Array",
    b"Function",
    b"globalThis",
    b"Infinity",
    b"Int16Array",
    b"Int32Array",
    b"Int8Array",
    b"Intl",
    b"isFinite",
    b"isNaN",
    b"JSON",
    b"Map",
    b"Math",
    b"NaN",
    b"Number",
    b"Object",
    b"parseFloat",
    b"parseInt",
    b"Promise",
    b"Proxy",
    b"RangeError",
    b"ReferenceError",
    b"Reflect",
    b"RegExp",
    b"Set",
    b"SharedArrayBuffer",
    b"String",
    b"Symbol",
    b"SyntaxError",
    b"TypeError",
    b"Uint16Array",
    b"Uint32Array",
    b"Uint8Array",
    b"Uint8ClampedArray",
    b"undefined",
    b"unescape",
    b"URIError",
    b"WeakMap",
    b"WeakRef",
    b"WeakSet",
];

struct Fixture {
    dialect: Option<Dialect>,
    name: String,
    source: Vec<u8>,
}

struct Machine {
    events: Events<JavaScriptKind>,
    lexed: Tokens,
    raw: BoundedVec<JavaScriptKind>,
    semantic: Semantic,
    tokens: Tokens,
    tree: Tree<JavaScriptKind>,
    typed_events: Events<TypeScriptKind>,
    typed_raw: BoundedVec<TypeScriptKind>,
    typed_tokens: Tokens,
    typed_tree: Tree<TypeScriptKind>,
}

impl Machine {
    fn reserve() -> Self {
        Self {
            events: Events::reserve(EVENT_COUNT_MAX),
            lexed: Tokens::reserve(TOKEN_COUNT_MAX),
            raw: BoundedVec::reserve(TOKEN_COUNT_MAX),
            semantic: Semantic::reserve(
                BINDING_COUNT_MAX,
                REFERENCE_COUNT_MAX,
                SCOPE_COUNT_MAX,
                FACT_COUNT_MAX,
            ),
            tokens: Tokens::reserve(TOKEN_COUNT_MAX),
            tree: Tree::reserve(NODE_COUNT_MAX, ERROR_COUNT_MAX),
            typed_events: Events::reserve(EVENT_COUNT_MAX),
            typed_raw: BoundedVec::reserve(TOKEN_COUNT_MAX),
            typed_tokens: Tokens::reserve(TOKEN_COUNT_MAX),
            typed_tree: Tree::reserve(NODE_COUNT_MAX, ERROR_COUNT_MAX),
        }
    }

    fn run(&mut self, fixture: &Fixture) -> Structure {
        match fixture.dialect {
            None => self.run_plain(&fixture.source),
            Some(dialect) => self.run_typed(&fixture.source, dialect),
        }
    }

    fn run_plain(&mut self, source: &[u8]) -> Structure {
        self.lexed.clear();
        JAVASCRIPT.lex(source, &mut self.lexed);

        if !classify(
            source,
            self.lexed.as_slice(),
            &mut self.tokens,
            &mut self.raw,
        ) {
            return Structure::Truncated;
        }

        parse::build(
            source,
            self.tokens.as_slice(),
            &self.raw,
            &mut self.events,
            &mut self.tree,
        );

        self.semantic.build(
            source,
            self.tokens.as_slice(),
            &self.raw,
            &self.tree,
            None,
            &GLOBALS,
        )
    }

    fn run_typed(&mut self, source: &[u8], dialect: Dialect) -> Structure {
        self.lexed.clear();
        TYPESCRIPT.lex(source, &mut self.lexed);

        if !typescript_classify(
            source,
            self.lexed.as_slice(),
            &mut self.typed_tokens,
            &mut self.typed_raw,
            dialect,
        ) {
            return Structure::Truncated;
        }

        typescript_parse::build(
            source,
            self.typed_tokens.as_slice(),
            &self.typed_raw,
            &mut self.typed_events,
            &mut self.typed_tree,
            dialect,
        );

        self.semantic.build(
            source,
            self.typed_tokens.as_slice(),
            &self.typed_raw,
            &self.typed_tree,
            None,
            &GLOBALS,
        )
    }

    fn head_of(&self, index: u32) -> u32 {
        let bindings = self.semantic.bindings();
        let mut held = index;

        while bindings[held as usize].previous != NONE {
            held = bindings[held as usize].previous;
        }

        held
    }

    fn rows(&self) -> Vec<(u32, i64)> {
        let mut found = Vec::new();

        for held in self.semantic.bindings() {
            found.push((held.name.offset, i64::from(held.name.offset)));
        }

        for held in self.semantic.references() {
            let definition = match held.resolution {
                Resolution::Bound(index) => {
                    let head = self.head_of(index);

                    i64::from(self.semantic.bindings()[head as usize].name.offset)
                }
                Resolution::Builtin | Resolution::Maybe | Resolution::Unresolved => -1,
            };

            found.push((held.name.offset, definition));
        }

        found.sort_unstable();
        found.dedup();

        found
    }
}

fn corpus() -> Vec<Fixture> {
    let Some(held) = corpus::root() else {
        return Vec::new();
    };

    let mut found = Vec::new();

    collect(&held, &held, &mut found);
    found.sort_by(|left, right| left.name.cmp(&right.name));

    found
}

fn fixtures() -> Vec<Fixture> {
    let mut found = Vec::new();

    for name in [
        "tests/fixtures/javascript-semantic",
        "tests/fixtures/typescript-semantic",
    ] {
        let root = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join(name);

        if !root.is_dir() {
            continue;
        }

        collect(&root, &root, &mut found);
    }

    found.sort_by(|left, right| left.name.cmp(&right.name));

    found
}

fn collect(root: &Path, base: &Path, found: &mut Vec<Fixture>) {
    let Ok(entries) = fs::read_dir(root) else {
        return;
    };

    let mut stack: Vec<PathBuf> = entries
        .filter_map(|entry| Some(entry.ok()?.path()))
        .collect();

    while let Some(path) = stack.pop() {
        if path.is_dir() {
            let Ok(nested) = fs::read_dir(&path) else {
                continue;
            };

            stack.extend(nested.filter_map(|entry| Some(entry.ok()?.path())));

            continue;
        }

        let extension = path.extension().and_then(|held| held.to_str());

        let dialect = match extension {
            Some("cjs" | "js" | "mjs") => None,
            Some(held) => match Dialect::of_extension(held) {
                None => continue,
                Some(dialect) => Some(dialect),
            },
            None => continue,
        };

        let Ok(source) = fs::read(&path) else {
            continue;
        };

        let name = path
            .strip_prefix(base)
            .unwrap_or(&path)
            .to_string_lossy()
            .replace('\\', "/");

        found.push(Fixture {
            dialect,
            name,
            source,
        });
    }
}

struct Golden {
    broken: bool,
    rows: Vec<(u32, i64)>,
}

fn golden(root: &Path, name: &str) -> Option<Golden> {
    let path = root.join(format!("{name}.json"));
    let text = fs::read(&path).ok()?;
    let broken = find(&text, b"\"broken\":true").is_some();
    let mut found = Vec::new();
    let key = b"\"ast\":[";

    let Some(start) = find(&text, key) else {
        return Some(Golden {
            broken,
            rows: found,
        });
    };

    let mut offset = start + key.len();

    while offset < text.len() && text[offset] == b'[' {
        let (position, after) = number(&text, offset);

        let Some((kind, tail)) = quoted(&text, after) else {
            break;
        };

        let Some((_, next)) = quoted(&text, tail) else {
            break;
        };

        let (definition, rest) = signed(&text, next);

        if kind != "Signature" {
            found.push((position, definition));
        }

        offset = rest;

        if offset < text.len() && text[offset] == b']' {
            offset += 1;
        }

        if offset < text.len() && text[offset] == b',' {
            offset += 1;

            continue;
        }

        break;
    }

    found.sort_unstable();
    found.dedup();

    Some(Golden {
        broken,
        rows: found,
    })
}

fn find(text: &[u8], key: &[u8]) -> Option<usize> {
    text.windows(key.len()).position(|window| window == key)
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

fn signed(text: &[u8], from: usize) -> (i64, usize) {
    let mut offset = from;

    while offset < text.len() && !text[offset].is_ascii_digit() && text[offset] != b'-' {
        offset += 1;
    }

    let negative = offset < text.len() && text[offset] == b'-';

    if negative {
        offset += 1;
    }

    let mut value = 0_i64;

    while offset < text.len() && text[offset].is_ascii_digit() {
        value = value * 10 + i64::from(text[offset] - b'0');
        offset += 1;
    }

    if negative {
        return (-value, offset);
    }

    (value, offset)
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

fn placed(held: &[(u32, i64)], expected: &[(u32, i64)]) -> Vec<(u32, i64)> {
    let mut found = Vec::new();
    let mut theirs = 0;

    for row in held {
        while theirs < expected.len() && expected[theirs].0 < row.0 {
            theirs += 1;
        }

        if theirs < expected.len() && expected[theirs].0 == row.0 {
            found.push(*row);
        }
    }

    found
}

fn fixture_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/golden-tsscope")
}

fn diverges(machine: &mut Machine, root: &Path, fixture: &Fixture) -> bool {
    let Some(expected) = golden(root, &fixture.name) else {
        return true;
    };

    if expected.broken {
        return true;
    }

    if machine.run(fixture) != Structure::Complete {
        return true;
    }

    placed(&machine.rows(), &expected.rows) != expected.rows
}

fn report(name: &str, held: &[(u32, i64)], expected: &[(u32, i64)]) -> String {
    use core::fmt::Write as _;

    let mut text = String::new();
    let mut ours = 0;
    let mut theirs = 0;
    let mut shown = 0;

    let _ = writeln!(text, "{name}:");

    while (ours < held.len() || theirs < expected.len()) && shown < 8 {
        let left = held.get(ours);
        let right = expected.get(theirs);

        match (left, right) {
            (Some(one), Some(two)) if one == two => {
                ours += 1;
                theirs += 1;
            }
            (Some(one), Some(two)) if one.0 == two.0 => {
                let _ = writeln!(
                    text,
                    "  {} resolves to {} and scope-manager resolves it to {}",
                    one.0, one.1, two.1
                );

                ours += 1;
                theirs += 1;
                shown += 1;
            }
            (Some(one), Some(two)) if one.0 < two.0 => {
                let _ = writeln!(text, "  scylla-only row at {}", one.0);

                ours += 1;
                shown += 1;
            }
            (Some(_), Some(two)) => {
                let _ = writeln!(text, "  scope-manager-only row at {}", two.0);

                theirs += 1;
                shown += 1;
            }
            (Some(one), None) => {
                let _ = writeln!(text, "  scylla-only row at {}", one.0);

                ours += 1;
                shown += 1;
            }
            (None, Some(two)) => {
                let _ = writeln!(text, "  scope-manager-only row at {}", two.0);

                theirs += 1;
                shown += 1;
            }
            (None, None) => break,
        }
    }

    text
}

#[test]
fn the_fixtures_resolve_what_scope_manager_resolves() {
    let root = fixture_root();

    if !root.is_dir() {
        return;
    }

    let carried = oracle::residue_of("residue-javascript-resolve.json", &EVERY_CATEGORY);
    let mut differing = Vec::new();
    let mut machine = Machine::reserve();
    let mut compared = 0;

    for fixture in &fixtures() {
        if carried.contains(&fixture.name) {
            continue;
        }

        let Some(expected) = golden(&root, &fixture.name) else {
            continue;
        };

        assert!(!expected.broken, "{} has no golden to match", fixture.name);
        assert_eq!(
            machine.run(fixture),
            Structure::Complete,
            "{} does not parse",
            fixture.name
        );

        let rows = placed(&machine.rows(), &expected.rows);

        if rows != expected.rows {
            differing.push(report(&fixture.name, &rows, &expected.rows));
        }

        compared += 1;
    }

    assert!(
        compared >= floor::FIXTURE_RESOLVE_JAVASCRIPT,
        "the semantic fixtures lost a file: {compared} compared, floor {}",
        floor::FIXTURE_RESOLVE_JAVASCRIPT
    );

    assert!(
        differing.is_empty(),
        "{} of {compared} fixtures differ\n{}",
        differing.len(),
        differing.concat()
    );
}

#[test]
fn the_corpus_resolves_what_scope_manager_resolves() {
    let Some(held) = corpus::tsscope() else {
        return;
    };

    let found = corpus();

    if found.is_empty() {
        return;
    }

    let carried = oracle::residue_of("residue-javascript-resolve.json", &EVERY_CATEGORY);
    let mut differing = Vec::new();
    let mut machine = Machine::reserve();
    let mut compared = 0;

    for fixture in &found {
        if carried.contains(&fixture.name) {
            continue;
        }

        let Some(expected) = golden(&held, &fixture.name) else {
            continue;
        };

        if expected.broken {
            continue;
        }

        if machine.run(fixture) != Structure::Complete {
            continue;
        }

        let rows = placed(&machine.rows(), &expected.rows);

        if rows != expected.rows {
            differing.push(report(&fixture.name, &rows, &expected.rows));
        }

        compared += 1;
    }

    assert!(
        compared >= floor::CORPUS_RESOLVE_JAVASCRIPT,
        "the corpus lost its JavaScript files: {compared} compared, floor {}",
        floor::CORPUS_RESOLVE_JAVASCRIPT
    );

    if !differing.is_empty() {
        if let Ok(path) = std::env::var("SCYLLA_REPORT") {
            fs::write(path, differing.join("")).expect("the report is writable");
        }

        let shown: Vec<&str> = differing.iter().take(3).map(String::as_str).collect();

        panic!(
            "{} of {compared} corpus files differ\n{}",
            differing.len(),
            shown.concat()
        );
    }
}

#[test]
fn every_residue_row_names_a_file_that_diverges() {
    let carried = oracle::residue_of("residue-javascript-resolve.json", &EVERY_CATEGORY);
    let root = fixture_root();
    let mut machine = Machine::reserve();
    let mut named = Vec::new();

    if root.is_dir() {
        for fixture in &fixtures() {
            if !carried.contains(&fixture.name) {
                continue;
            }

            named.push(fixture.name.clone());

            assert!(
                diverges(&mut machine, &root, fixture),
                "{} matches its golden and needs no residue row",
                fixture.name
            );
        }
    }

    let Some(held) = corpus::tsscope() else {
        return;
    };

    for fixture in &corpus() {
        if !carried.contains(&fixture.name) {
            continue;
        }

        named.push(fixture.name.clone());

        assert!(
            diverges(&mut machine, &held, fixture),
            "{} matches its golden and needs no residue row",
            fixture.name
        );
    }

    for row in &carried {
        assert!(
            named.contains(row),
            "residue names `{row}`, which no fixture or corpus file carries"
        );
    }
}
