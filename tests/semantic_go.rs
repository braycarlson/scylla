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
use scylla::lex::GO;
use scylla::syntax::Structure;
use scylla::syntax::go::classify::classify;
use scylla::syntax::go::kind::GoKind;
use scylla::syntax::go::parse;
use scylla::syntax::go::semantic::{Resolution, Semantic};
use scylla::token::{Lex, Tokens};
use scylla::tree::{Events, NONE, Tree};

const BINDING_COUNT_MAX: u32 = 1 << 16;
const ERROR_COUNT_MAX: u32 = 1 << 12;
const EVENT_COUNT_MAX: u32 = 1 << 21;
const EVERY_CATEGORY: [&str; 3] = ["gotypes", "not-go", "scylla"];
const FACT_COUNT_MAX: u32 = 1 << 13;
const NODE_COUNT_MAX: u32 = 1 << 19;
const REFERENCE_COUNT_MAX: u32 = 1 << 18;
const SCOPE_COUNT_MAX: u32 = 1 << 16;
const TOKEN_COUNT_MAX: u32 = 1 << 19;

const UNIVERSE: [&[u8]; 44] = [
    b"any",
    b"append",
    b"bool",
    b"byte",
    b"cap",
    b"clear",
    b"close",
    b"comparable",
    b"complex",
    b"complex128",
    b"complex64",
    b"copy",
    b"delete",
    b"error",
    b"false",
    b"float32",
    b"float64",
    b"imag",
    b"int",
    b"int16",
    b"int32",
    b"int64",
    b"int8",
    b"iota",
    b"len",
    b"make",
    b"max",
    b"min",
    b"new",
    b"nil",
    b"panic",
    b"print",
    b"println",
    b"real",
    b"recover",
    b"rune",
    b"string",
    b"true",
    b"uint",
    b"uint16",
    b"uint32",
    b"uint64",
    b"uint8",
    b"uintptr",
];

struct Fixture {
    name: String,
    source: Vec<u8>,
}

struct Machine {
    events: Events<GoKind>,
    lexed: Tokens,
    raw: BoundedVec<GoKind>,
    semantic: Semantic,
    tokens: Tokens,
    tree: Tree<GoKind>,
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
        }
    }

    fn run(&mut self, source: &[u8]) -> Structure {
        self.lexed.clear();

        if GO.lex(source, &mut self.lexed) != Lex::Complete {
            return Structure::Truncated;
        }

        assert!(classify(
            source,
            self.lexed.as_slice(),
            &mut self.tokens,
            &mut self.raw
        ));

        let parsed = parse::build(
            source,
            self.tokens.as_slice(),
            &self.raw,
            &mut self.events,
            &mut self.tree,
        );

        let held = self.semantic.build(
            source,
            self.tokens.as_slice(),
            &self.raw,
            &self.tree,
            &UNIVERSE,
        );

        if parsed != Structure::Complete {
            return parsed;
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
                    i64::from(self.semantic.bindings()[index as usize].name.offset)
                }
                Resolution::Builtin | Resolution::Maybe => -1,
                Resolution::Unresolved => continue,
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
    let root = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/go-semantic");

    if !root.is_dir() {
        return Vec::new();
    }

    let mut found = Vec::new();

    collect(&root, &root, &mut found);
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

        if path.extension().and_then(|held| held.to_str()) != Some("go") {
            continue;
        }

        let Ok(source) = fs::read(&path) else {
            continue;
        };

        let name = path
            .strip_prefix(base)
            .unwrap_or(&path)
            .to_string_lossy()
            .replace('\\', "/");

        found.push(Fixture { name, source });
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

        let Some((_, tail)) = quoted(&text, after) else {
            break;
        };

        let Some((_, next)) = quoted(&text, tail) else {
            break;
        };

        let (definition, rest) = signed(&text, next);

        found.push((position, definition));

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

fn fixture_diverges(machine: &mut Machine, root: &Path, fixture: &Fixture) -> bool {
    let Some(expected) = golden(root, &fixture.name) else {
        return true;
    };

    let _ = machine.run(&fixture.source);

    machine.rows() != expected.rows
}

fn corpus_diverges(machine: &mut Machine, root: &Path, fixture: &Fixture) -> bool {
    let Some(expected) = golden(root, &fixture.name) else {
        return true;
    };

    if expected.broken {
        return true;
    }

    if machine.run(&fixture.source) != Structure::Complete {
        return true;
    }

    placed(&machine.rows(), &expected.rows) != expected.rows
}

fn report(name: &str, held: &[(u32, i64)], expected: &[(u32, i64)]) -> String {
    use core::fmt::Write as _;

    let mut lines = format!("{name}: the pairs differ\n");
    let mut shown = 0;
    let mut mine = 0;
    let mut theirs = 0;

    while shown < 24 && (mine < held.len() || theirs < expected.len()) {
        if theirs >= expected.len() || (mine < held.len() && held[mine] < expected[theirs]) {
            let row = &held[mine];
            let _ = writeln!(lines, "  extra   {} -> {}", row.0, row.1);

            mine += 1;
            shown += 1;

            continue;
        }

        if mine >= held.len() || expected[theirs] < held[mine] {
            let row = &expected[theirs];
            let _ = writeln!(lines, "  missing {} -> {}", row.0, row.1);

            theirs += 1;
            shown += 1;

            continue;
        }

        mine += 1;
        theirs += 1;
    }

    lines
}

#[test]
fn a_name_neither_side_can_place_is_absent_from_the_rows_both_are_compared_through() {
    let source = b"package p\n\nfunc run() {\n\t_ = sibling\n}\n";
    let mut machine = Machine::reserve();

    assert_eq!(machine.run(source), Structure::Complete);

    let unresolved = machine
        .semantic
        .references()
        .iter()
        .find(|held| held.resolution == Resolution::Unresolved)
        .expect("a name no file in the set declares is unresolved");

    assert!(
        !machine
            .rows()
            .iter()
            .any(|(offset, _)| *offset == unresolved.name.offset)
    );
}

#[test]
fn the_model_is_total_over_the_fixtures() {
    let found = fixtures();

    assert!(
        !found.is_empty(),
        "tests/fixtures/go-semantic holds no source"
    );

    let mut machine = Machine::reserve();

    for fixture in &found {
        let outcome = machine.run(&fixture.source);

        assert_eq!(outcome, Structure::Complete, "{}", fixture.name);
        assert!(machine.semantic.count() > 0, "{}", fixture.name);
    }
}

#[test]
fn a_range_over_a_written_out_composite_literal_binds_inside_the_loop_body() {
    const SOURCE: &[u8] =
        b"package p\n\nfunc f() {\n\tfor _, po := range []*poset{a, b} {\n\t\tuse(po)\n\t}\n}\n";

    let mut machine = Machine::reserve();
    let _ = machine.run(SOURCE);

    let bound = machine
        .semantic
        .references()
        .iter()
        .filter(|held| {
            matches!(held.resolution, Resolution::Bound(_))
                && &SOURCE[held.name.range()] == b"po".as_slice()
        })
        .count();

    assert_eq!(bound, 2, "the loop variable is unresolved inside the body");
}

#[test]
fn every_scope_a_reference_resolves_into_is_on_its_own_chain() {
    let found = fixtures();

    assert!(
        !found.is_empty(),
        "tests/fixtures/go-semantic holds no source"
    );

    let mut machine = Machine::reserve();

    for fixture in &found {
        let _ = machine.run(&fixture.source);

        for held in machine.semantic.references() {
            let Resolution::Bound(index) = held.resolution else {
                continue;
            };

            let binding = machine.semantic.bindings()[index as usize];
            let mut scope = held.scope;
            let mut steps = 0;
            let mut walked = false;

            while scope != NONE && steps <= 1 << 8 {
                if scope == binding.scope {
                    walked = true;

                    break;
                }

                scope = machine.semantic.scopes()[scope as usize].parent;
                steps += 1;
            }

            assert!(
                walked,
                "{}: a reference resolves outside its own scope chain",
                fixture.name
            );
        }
    }
}

#[test]
fn every_fixture_names_what_go_types_names() {
    let root = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/golden-gotypes");
    let carried = oracle::residue_of("residue-go-semantic.json", &EVERY_CATEGORY);
    let found = fixtures();

    assert!(
        !found.is_empty(),
        "tests/fixtures/go-semantic holds no source"
    );

    let mut machine = Machine::reserve();
    let mut compared = 0;

    for fixture in &found {
        if carried.contains(&fixture.name) {
            continue;
        }

        let expected = golden(&root, &fixture.name)
            .unwrap_or_else(|| panic!("{} has no golden", fixture.name));

        assert!(!expected.broken, "{} does not parse", fixture.name);

        let _ = machine.run(&fixture.source);

        let held = machine.rows();

        assert!(
            held == expected.rows,
            "{}",
            report(&fixture.name, &held, &expected.rows)
        );

        compared += 1;
    }

    assert!(
        compared >= floor::FIXTURE_SEMANTIC_GO,
        "the Go fixtures lost a binding table: {compared} compared, floor {}",
        floor::FIXTURE_SEMANTIC_GO
    );
}

#[test]
fn the_corpus_names_what_go_types_names() {
    let Some(held) = corpus::gotypes() else {
        return;
    };

    let found = corpus();

    if found.is_empty() {
        return;
    }

    let carried = oracle::residue_of("residue-go-semantic.json", &EVERY_CATEGORY);
    let mut machine = Machine::reserve();
    let mut differing = Vec::new();
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

        if machine.run(&fixture.source) != Structure::Complete {
            continue;
        }

        let rows = placed(&machine.rows(), &expected.rows);

        if rows != expected.rows {
            differing.push(report(&fixture.name, &rows, &expected.rows));
        }

        compared += 1;
    }

    assert!(
        compared >= floor::CORPUS_SEMANTIC_GO,
        "the corpus lost its Go files: {compared} compared, floor {}",
        floor::CORPUS_SEMANTIC_GO
    );

    if !differing.is_empty() {
        if let Ok(path) = std::env::var("SCYLLA_REPORT") {
            fs::write(path, differing.join("")).expect("the report is writable");
        }

        let shown: Vec<&String> = differing.iter().take(3).collect();

        panic!(
            "{} of {compared} corpus files differ\n{}",
            differing.len(),
            shown
                .iter()
                .map(|line| line.as_str())
                .collect::<Vec<&str>>()
                .join("")
        );
    }
}

#[test]
fn every_residue_row_names_a_file_that_diverges() {
    let carried = oracle::residue_of("residue-go-semantic.json", &EVERY_CATEGORY);
    let root = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/golden-gotypes");
    let mut machine = Machine::reserve();
    let mut named = Vec::new();

    for fixture in &fixtures() {
        if !carried.contains(&fixture.name) {
            continue;
        }

        named.push(fixture.name.clone());

        assert!(
            fixture_diverges(&mut machine, &root, fixture),
            "{} matches its golden and needs no residue row",
            fixture.name
        );
    }

    let Some(held) = corpus::gotypes() else {
        return;
    };

    for fixture in &corpus() {
        if !carried.contains(&fixture.name) {
            continue;
        }

        named.push(fixture.name.clone());

        assert!(
            corpus_diverges(&mut machine, &held, fixture),
            "{} matches its corpus golden and needs no residue row",
            fixture.name
        );
    }

    for name in &carried {
        assert!(
            named.contains(name),
            "the residue names `{name}` and neither the fixtures nor the corpus carry it"
        );
    }
}
