#[path = "common/corpus.rs"]
mod corpus;
#[path = "common/floor.rs"]
mod floor;

use std::fs;
use std::path::{Path, PathBuf};

use scylla::markup::semantic::{DefinitionKind, Semantic, UseKind};
use scylla::markup::tree::{self, Step, Structure, Tree, walk};
use scylla::markup::view::View;
use scylla::markup::{self, MarkupKind, NONE, Token, Tokens};

const DEFINITION_COUNT_MAX: u32 = 1 << 14;
const ERROR_COUNT_MAX: u32 = 1 << 10;
const NODE_COUNT_MAX: u32 = 1 << 17;
const TOKEN_COUNT_MAX: u32 = 1 << 18;
const USE_COUNT_MAX: u32 = 1 << 14;

#[derive(Clone, Debug, Eq, Ord, PartialEq, PartialOrd)]
struct Row {
    kind: String,
    name: String,
    offset: u32,
}

struct Golden {
    attributes: Vec<Row>,
    broken: bool,
    definitions: Vec<Row>,
    elements: Vec<Row>,
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

    let mut found = Vec::new();

    while offset < text.len() {
        let byte = text[offset];

        offset += 1;

        if byte == b'"' {
            return Some((String::from_utf8_lossy(&found).into_owned(), offset));
        }

        if byte != b'\\' {
            found.push(byte);

            continue;
        }

        let held = *text.get(offset)?;

        offset += 1;

        match held {
            b'n' => found.push(b'\n'),
            b'r' => found.push(b'\r'),
            b't' => found.push(b'\t'),
            b'u' => {
                let mut value = 0_u32;

                for _ in 0..4 {
                    let digit = *text.get(offset)?;

                    offset += 1;
                    value = value * 16 + char::from(digit).to_digit(16)?;
                }

                let mut buffer = [0_u8; 4];

                found.extend_from_slice(char::from_u32(value)?.encode_utf8(&mut buffer).as_bytes());
            }
            other => found.push(other),
        }
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
        attributes: rows_of(&text, b"\"attributes\":["),
        broken: find(&text, b"\"broken\":true").is_some(),
        definitions: rows_of(&text, b"\"definitions\":["),
        elements: rows_of(&text, b"\"elements\":["),
        uses: rows_of(&text, b"\"uses\":["),
    })
}

struct Machine {
    semantic: Semantic,
    tokens: Tokens,
    tree: Tree,
}

impl Machine {
    fn reserve() -> Self {
        Self {
            semantic: Semantic::reserve(DEFINITION_COUNT_MAX, USE_COUNT_MAX),
            tokens: Tokens::reserve(TOKEN_COUNT_MAX),
            tree: Tree::reserve(NODE_COUNT_MAX, ERROR_COUNT_MAX),
        }
    }

    fn build(&mut self, source: &[u8]) -> bool {
        markup::lex(source, &mut self.tokens);

        if tree::build(source, self.tokens.as_slice(), &mut self.tree) != Structure::Complete {
            return false;
        }

        self.semantic
            .build(source, self.tokens.as_slice(), &self.tree)
            == Structure::Complete
    }

    fn named(&self, source: &[u8]) -> (Vec<Row>, Vec<Row>) {
        let mut attributes = Vec::new();
        let mut elements = Vec::new();

        for step in walk(&self.tree) {
            let Step::Enter(node) = step else {
                continue;
            };

            let view = View::new(&self.tree, self.tokens.as_slice(), node);

            if let Some(held) = view.as_element() {
                if let Some(index) = held.name_token() {
                    elements.push(self.row("element", source, index));
                }

                continue;
            }

            if let Some(held) = view.as_attribute() {
                if let Some(index) = held.name_token() {
                    attributes.push(self.row("attribute", source, index));
                }
            }
        }

        attributes.sort();
        elements.sort();

        (attributes, elements)
    }

    fn row(&self, kind: &str, source: &[u8], index: u32) -> Row {
        let token = self.tokens.as_slice()[index as usize];

        Row {
            kind: kind.to_owned(),
            name: String::from_utf8_lossy(token.text(source)).into_owned(),
            offset: token.offset,
        }
    }

    fn rows(&self, source: &[u8]) -> (Vec<Row>, Vec<Row>) {
        let mut definitions: Vec<Row> = self
            .semantic
            .definitions()
            .iter()
            .map(|held| Row {
                kind: "id".to_owned(),
                name: String::from_utf8_lossy(&source[held.name.range()]).into_owned(),
                offset: held.name.offset,
            })
            .collect();

        let mut uses: Vec<Row> = self
            .semantic
            .uses()
            .iter()
            .map(|held| Row {
                kind: "id".to_owned(),
                name: String::from_utf8_lossy(&source[held.name.range()]).into_owned(),
                offset: held.name.offset,
            })
            .collect();

        definitions.sort();
        uses.sort();

        (definitions, uses)
    }
}

fn invariants_hold(machine: &Machine, source: &[u8], name: &str) {
    let length = u32::try_from(source.len()).expect("a fixture fits in u32");
    let count = machine.semantic.definitions().len();

    for (index, definition) in machine.semantic.definitions().iter().enumerate() {
        assert!(
            definition.name.end() <= length,
            "{name}: definition {index} names bytes past the source"
        );

        assert!(
            definition.name.length > 0,
            "{name}: definition {index} names nothing"
        );

        assert!(
            definition.name_previous == NONE || (definition.name_previous as usize) < index,
            "{name}: definition {index} chains forward"
        );
    }

    for (index, held) in machine.semantic.uses().iter().enumerate() {
        assert!(
            held.name.end() <= length,
            "{name}: use {index} names bytes past the source"
        );

        assert!(held.name.length > 0, "{name}: use {index} names nothing");

        if held.definition == NONE {
            assert_eq!(held.count, 0, "{name}: use {index} counts an absent id");

            continue;
        }

        assert!(
            (held.definition as usize) < count,
            "{name}: use {index} resolves past the table"
        );

        let definition = machine
            .semantic
            .get(held.definition)
            .expect("a resolved use names a definition");

        assert!(
            definition.kind.reads(held.kind),
            "{name}: use {index} resolves to a definition that does not read it"
        );

        assert_eq!(
            &source[definition.name.range()],
            &source[held.name.range()],
            "{name}: use {index} resolves to a name spelled differently"
        );
    }

    for index in 0..u32::try_from(count).expect("a table fits in u32") {
        for held in machine.semantic.uses_of(index) {
            assert_eq!(
                machine.semantic.uses()[held as usize].definition,
                index,
                "{name}: uses_of({index}) yields a use of something else"
            );
        }
    }
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

        if path.extension().is_none_or(|extension| extension != "html") {
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
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/residue-markup-semantic.json");
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

fn report(name: &str, held: &[Row], wanted: &[Row], label: &str) -> String {
    use core::fmt::Write as _;

    let mut lines = format!("=== {name} {label}\n");

    for row in held.iter().filter(|row| !wanted.contains(row)).take(4) {
        let _ = writeln!(lines, "  scylla {} {} {}", row.kind, row.name, row.offset);
    }

    for row in wanted.iter().filter(|row| !held.contains(row)).take(4) {
        let _ = writeln!(lines, "  parse5 {} {} {}", row.kind, row.name, row.offset);
    }

    lines
}

#[test]
fn an_id_reaches_every_attribute_that_names_it() {
    let source: &[u8] =
        b"<div id=\"main\"><a href=\"#main\">go</a><label for=\"main\">l</label></div>";
    let mut machine = Machine::reserve();

    assert!(machine.build(source));
    assert_eq!(machine.semantic.definitions().len(), 1);
    assert_eq!(machine.semantic.uses().len(), 2);

    for held in machine.semantic.uses() {
        assert_eq!(held.definition, 0);
        assert_eq!(held.count, 1);
    }

    invariants_hold(&machine, source, "an id and its references");
}

#[test]
fn a_templated_value_names_nothing() {
    let source: &[u8] = b"<div id=\"{{ slug }}\"><a href=\"#{{ slug }}\">go</a></div>";
    let mut machine = Machine::reserve();

    assert!(machine.build(source));
    assert_eq!(machine.semantic.definitions().len(), 0);
    assert_eq!(machine.semantic.uses().len(), 0);
}

#[test]
fn a_listed_relation_names_each_id_it_holds() {
    let source: &[u8] = b"<i id=\"a\"></i><i id=\"b\"></i><p aria-labelledby=\"a b missing\">x</p>";
    let mut machine = Machine::reserve();

    assert!(machine.build(source));
    assert_eq!(machine.semantic.uses().len(), 3);

    let unresolved = machine
        .semantic
        .uses()
        .iter()
        .filter(|held| held.definition == NONE)
        .count();

    assert_eq!(unresolved, 1);

    invariants_hold(&machine, source, "a listed relation");
}

fn differing_of(
    name: &str,
    held: (&[Row], &[Row]),
    rows: (&[Row], &[Row]),
    wanted: &Golden,
) -> String {
    let (attributes, elements) = held;
    let (definitions, uses) = rows;
    let mut lines = String::new();

    if elements != wanted.elements {
        lines.push_str(&report(name, elements, &wanted.elements, "elements"));
    }

    if attributes != wanted.attributes {
        lines.push_str(&report(name, attributes, &wanted.attributes, "attributes"));
    }

    if definitions != wanted.definitions {
        lines.push_str(&report(
            name,
            definitions,
            &wanted.definitions,
            "definitions",
        ));
    }

    if uses != wanted.uses {
        lines.push_str(&report(name, uses, &wanted.uses, "uses"));
    }

    lines
}

#[test]
fn the_corpus_names_what_parse5_names() {
    let Some(held) = corpus::markup() else {
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

        let (attributes, elements) = machine.named(&fixture.source);
        let (definitions, uses) = machine.rows(&fixture.source);

        rows += attributes.len() + elements.len() + definitions.len() + uses.len();

        let lines = differing_of(
            &fixture.name,
            (&attributes, &elements),
            (&definitions, &uses),
            &recorded,
        );

        if !lines.is_empty() {
            differing.push(lines);
        }

        compared += 1;
    }

    assert!(
        compared + carried.len() >= floor::CORPUS_PARSE5_MARKUP.files,
        "the corpus lost its markup files: {} named, {abstained} abstained, floor {}",
        compared + carried.len(),
        floor::CORPUS_PARSE5_MARKUP.files
    );

    assert!(
        rows >= floor::CORPUS_PARSE5_MARKUP.rows,
        "{rows} names compared, floor {}",
        floor::CORPUS_PARSE5_MARKUP.rows
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
        compared >= floor::CORPUS_MARKUP_TREE,
        "{compared} markup files held the invariants, floor {}",
        floor::CORPUS_MARKUP_TREE
    );
}

#[test]
fn every_residue_row_names_a_file_that_diverges() {
    let Some(held) = corpus::markup() else {
        return;
    };

    let carried = residue();
    let mut machine = Machine::reserve();
    let mut named = Vec::new();

    for fixture in &corpus_files() {
        if !carried.contains(&fixture.name) {
            continue;
        }

        named.push(fixture.name.clone());

        let Some(recorded) = golden(&held, &fixture.name) else {
            continue;
        };

        if recorded.broken || !machine.build(&fixture.source) {
            continue;
        }

        let (attributes, elements) = machine.named(&fixture.source);
        let (definitions, uses) = machine.rows(&fixture.source);

        assert!(
            !differing_of(
                &fixture.name,
                (&attributes, &elements),
                (&definitions, &uses),
                &recorded,
            )
            .is_empty(),
            "{} names what parse5 names and needs no residue row",
            fixture.name
        );
    }

    for name in &carried {
        assert!(
            named.contains(name),
            "the residue names `{name}` and the corpus does not carry it"
        );
    }
}

#[expect(
    dead_code,
    reason = "the kinds are named so a new one has to be placed in the suite"
)]
fn kinds_are_named(definition: DefinitionKind, held: UseKind, kind: MarkupKind, token: Token) {
    let _ = (definition, held, kind, token);
}
