#[path = "common/corpus.rs"]
mod corpus;
#[path = "common/floor.rs"]
mod floor;

use std::fs;
use std::path::{Path, PathBuf};

use scylla::bounded::BoundedVec;
use scylla::language::Lexer as _;
use scylla::lex::CSS;
use scylla::syntax::Structure;
use scylla::syntax::css::classify::classify;
use scylla::syntax::css::kind::CSSKind;
use scylla::syntax::css::parse;
use scylla::syntax::css::semantic::{DefinitionKind, Semantic, UseKind};
use scylla::token::{Lex, Tokens};
use scylla::tree::{Events, NONE, Tree};

const ERROR_COUNT_MAX: u32 = 1 << 12;
const EVENT_COUNT_MAX: u32 = 1 << 21;
const NODE_COUNT_MAX: u32 = 1 << 18;
const TABLE_COUNT_MAX: u32 = 1 << 16;
const TOKEN_COUNT_MAX: u32 = 1 << 18;

#[derive(Clone, Debug, Eq, Ord, PartialEq, PartialOrd)]
struct Row {
    kind: String,
    name: String,
    offset: u32,
}

struct Golden {
    broken: bool,
    definitions: Vec<Row>,
    uses: Vec<Row>,
}

struct Fixture {
    name: String,
    source: Vec<u8>,
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

fn rows_of(text: &[u8], key: &[u8]) -> Vec<Row> {
    let Some(start) = find(text, key) else {
        return Vec::new();
    };

    let mut offset = start + key.len();
    let mut found = Vec::new();

    while offset < text.len() && text[offset] == b'[' {
        let Some((kind, after)) = quoted(text, offset) else {
            break;
        };

        let Some((name, named)) = quoted(text, after) else {
            break;
        };

        let mut cursor = named;

        while cursor < text.len() && !text[cursor].is_ascii_digit() {
            cursor += 1;
        }

        let mut number = 0_u32;

        while cursor < text.len() && text[cursor].is_ascii_digit() {
            number = number * 10 + u32::from(text[cursor] - b'0');
            cursor += 1;
        }

        found.push(Row {
            kind,
            name,
            offset: number,
        });

        while cursor < text.len() && text[cursor] != b']' {
            cursor += 1;
        }

        cursor += 1;

        if cursor < text.len() && text[cursor] == b',' {
            cursor += 1;
        }

        offset = cursor;
    }

    found.sort();

    found
}

fn golden(root: &Path, name: &str) -> Option<Golden> {
    let text = fs::read(root.join(format!("{name}.json"))).ok()?;

    Some(Golden {
        broken: find(&text, b"\"broken\":true").is_some(),
        definitions: rows_of(&text, b"\"definitions\":["),
        uses: rows_of(&text, b"\"uses\":["),
    })
}

struct Machine {
    events: Events<CSSKind>,
    lexed: Tokens,
    raw: BoundedVec<CSSKind>,
    semantic: Semantic,
    tokens: Tokens,
    tree: Tree<CSSKind>,
}

impl Machine {
    fn reserve() -> Self {
        Self {
            events: Events::reserve(EVENT_COUNT_MAX),
            lexed: Tokens::reserve(TOKEN_COUNT_MAX),
            raw: BoundedVec::reserve(TOKEN_COUNT_MAX),
            semantic: Semantic::reserve(TABLE_COUNT_MAX, TABLE_COUNT_MAX, TABLE_COUNT_MAX),
            tokens: Tokens::reserve(TOKEN_COUNT_MAX),
            tree: Tree::reserve(NODE_COUNT_MAX, ERROR_COUNT_MAX),
        }
    }

    fn build(&mut self, source: &[u8]) -> bool {
        self.lexed.clear();

        if CSS.lex(source, &mut self.lexed) != Lex::Complete {
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

        self.semantic
            .build(source, self.tokens.as_slice(), &self.raw, &self.tree)
            == Structure::Complete
    }

    fn rows(&self, source: &[u8]) -> (Vec<Row>, Vec<Row>) {
        let mut definitions = Vec::new();
        let mut uses = Vec::new();

        for held in self.semantic.definitions() {
            let named = match held.kind {
                DefinitionKind::CustomProperty => "custom-property",
                DefinitionKind::FontFamily => "font-family",
                DefinitionKind::Keyframes => "keyframes",
                DefinitionKind::Class | DefinitionKind::Id => continue,
            };

            definitions.push(Row {
                kind: named.to_owned(),
                name: String::from_utf8_lossy(&source[held.name.range()]).into_owned(),
                offset: held.name.offset,
            });
        }

        for held in self.semantic.uses() {
            let named = match held.kind {
                UseKind::CustomProperty => "custom-property",
                UseKind::FontFamily => "font-family",
                UseKind::Keyframes => "keyframes",
            };

            uses.push(Row {
                kind: named.to_owned(),
                name: String::from_utf8_lossy(&source[held.name.range()]).into_owned(),
                offset: held.name.offset,
            });
        }

        definitions.sort();
        uses.sort();

        (definitions, uses)
    }

    fn names(&self, source: &[u8], kind: DefinitionKind) -> Vec<String> {
        self.semantic
            .definitions()
            .iter()
            .filter(|held| held.kind == kind)
            .map(|held| String::from_utf8_lossy(&source[held.name.range()]).into_owned())
            .collect()
    }

    fn unresolved(&self, source: &[u8]) -> Vec<String> {
        self.semantic
            .uses()
            .iter()
            .filter(|held| held.definition == NONE)
            .map(|held| String::from_utf8_lossy(&source[held.name.range()]).into_owned())
            .collect()
    }
}

fn invariants_hold(machine: &Machine, source: &[u8], name: &str) {
    let length = source.len();
    let count = machine.semantic.count();

    for (position, held) in machine.semantic.definitions().iter().enumerate() {
        let index = u32::try_from(position).expect("a definition count fits in u32");

        assert!(
            held.name.end() as usize <= length,
            "{name}: definition {index} names bytes past the source"
        );

        assert!(
            held.name.length > 0,
            "{name}: definition {index} names nothing"
        );

        assert!(
            held.name_previous == NONE || held.name_previous < count,
            "{name}: definition {index} chains to a definition that is not there"
        );

        assert!(
            held.name_previous == NONE || held.name_previous != index,
            "{name}: definition {index} chains to itself"
        );
    }

    for (index, held) in machine.semantic.uses().iter().enumerate() {
        assert!(
            held.name.end() as usize <= length,
            "{name}: use {index} names bytes past the source"
        );

        if held.definition == NONE {
            continue;
        }

        let Some(definition) = machine.semantic.get(held.definition) else {
            panic!("{name}: use {index} resolves to a definition that is not there");
        };

        assert!(
            definition.kind.reads(held.kind),
            "{name}: use {index} resolves to a definition of the wrong kind"
        );

        assert_eq!(
            &source[definition.name.range()],
            &source[held.name.range()],
            "{name}: use {index} resolves to a definition of another name"
        );
    }

    for index in 0..count {
        for held in machine.semantic.uses_of(index) {
            assert_eq!(
                machine.semantic.uses()[held as usize].definition,
                index,
                "{name}: uses_of({index}) yielded a use of another definition"
            );
        }
    }
}

fn fixtures() -> Vec<Fixture> {
    let root = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/css-semantic");
    let mut found = Vec::new();

    collect(&root, &root, &mut found);
    found.sort_by(|left, right| left.name.cmp(&right.name));

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

        if path.extension().is_none_or(|extension| extension != "css") {
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

fn residue() -> Vec<String> {
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/residue-css-semantic.json");
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

fn report(
    name: &str,
    definitions: &[Row],
    wanted: &[Row],
    uses: &[Row],
    expected: &[Row],
) -> String {
    use core::fmt::Write as _;

    let mut written = format!("=== {name}\n");

    for (label, mine, theirs) in [
        ("definitions", definitions, wanted),
        ("uses", uses, expected),
    ] {
        for row in mine {
            if !theirs.contains(row) {
                let _ = writeln!(
                    written,
                    "  scylla only {label} {} {} {}",
                    row.kind, row.name, row.offset
                );
            }
        }

        for row in theirs {
            if !mine.contains(row) {
                let _ = writeln!(
                    written,
                    "  postcss only {label} {} {} {}",
                    row.kind, row.name, row.offset
                );
            }
        }
    }

    written
}

#[test]
fn a_custom_property_reaches_the_declaration_that_names_it() {
    let source = fs::read(
        PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("tests/fixtures/css-semantic/properties.css"),
    )
    .expect("the fixture is readable");

    let mut machine = Machine::reserve();

    assert!(machine.build(&source));

    let mut named = machine.names(&source, DefinitionKind::CustomProperty);

    named.sort();
    named.dedup();

    assert_eq!(named, vec!["--brand", "--space"]);
    assert_eq!(machine.unresolved(&source), vec!["--missing"]);

    invariants_hold(&machine, &source, "properties.css");
}

#[test]
fn a_keyframes_name_reaches_the_at_rule_that_declares_it() {
    let source = fs::read(
        PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/css-semantic/keyframes.css"),
    )
    .expect("the fixture is readable");

    let mut machine = Machine::reserve();

    assert!(machine.build(&source));
    assert_eq!(
        machine.names(&source, DefinitionKind::Keyframes),
        vec!["slide"]
    );

    assert!(
        machine
            .semantic
            .uses()
            .iter()
            .any(|held| held.kind == UseKind::Keyframes && held.definition != NONE),
        "the animation name reaches no keyframes"
    );

    invariants_hold(&machine, &source, "keyframes.css");
}

#[test]
fn every_fixture_holds_the_table_invariants() {
    let found = fixtures();

    assert!(
        !found.is_empty(),
        "tests/fixtures/css-semantic holds no source"
    );

    let mut machine = Machine::reserve();

    for fixture in &found {
        assert!(
            machine.build(&fixture.source),
            "{} does not build",
            fixture.name
        );

        invariants_hold(&machine, &fixture.source, &fixture.name);
    }
}

#[test]
fn every_fixture_names_what_postcss_names() {
    let Some(held) = corpus::css() else {
        return;
    };

    let root = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/golden-css-semantic");

    if !root.is_dir() && !held.is_dir() {
        return;
    }

    let found = fixtures();
    let mut machine = Machine::reserve();
    let mut compared = 0;

    for fixture in &found {
        let Some(recorded) = golden(&root, &fixture.name) else {
            continue;
        };

        assert!(
            machine.build(&fixture.source),
            "{} does not build",
            fixture.name
        );

        let (definitions, uses) = machine.rows(&fixture.source);

        assert_eq!(definitions, recorded.definitions, "{}", fixture.name);
        assert_eq!(uses, recorded.uses, "{}", fixture.name);

        compared += 1;
    }

    assert_eq!(compared, found.len(), "a fixture went uncompared");
}

#[test]
fn the_corpus_names_what_postcss_names() {
    let Some(held) = corpus::css() else {
        return;
    };

    let found = corpus_files();

    if found.is_empty() {
        return;
    }

    let carried = residue();
    let mut abstained = 0;
    let mut differing = Vec::new();
    let mut machine = Machine::reserve();
    let mut compared = 0;

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

        let (definitions, uses) = machine.rows(&fixture.source);

        if definitions != recorded.definitions || uses != recorded.uses {
            differing.push(report(
                &fixture.name,
                &definitions,
                &recorded.definitions,
                &uses,
                &recorded.uses,
            ));
        }

        compared += 1;
    }

    assert!(
        compared + carried.len() >= floor::CORPUS_POSTCSS_CSS,
        "the corpus lost its CSS files: {} named, {abstained} abstained, floor {}",
        compared + carried.len(),
        floor::CORPUS_POSTCSS_CSS
    );

    if !differing.is_empty() {
        if let Ok(path) = std::env::var("SCYLLA_REPORT") {
            fs::write(path, differing.join("")).expect("the report is writable");
        }

        let mut shown = differing.clone();

        shown.truncate(3);

        panic!(
            "{} files name something else\n{}",
            differing.len(),
            shown.join("")
        );
    }
}

#[test]
fn every_corpus_file_holds_the_table_invariants() {
    let found = corpus_files();

    if found.is_empty() {
        return;
    }

    let mut machine = Machine::reserve();
    let mut compared = 0;

    for fixture in &found {
        if !machine.build(&fixture.source) {
            continue;
        }

        invariants_hold(&machine, &fixture.source, &fixture.name);

        compared += 1;
    }

    assert!(
        compared >= floor::CORPUS_SEMANTIC_CSS,
        "{compared} corpus files built, floor {}",
        floor::CORPUS_SEMANTIC_CSS
    );
}
