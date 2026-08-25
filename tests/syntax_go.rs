#[path = "common/oracle.rs"]
mod oracle;

use std::fs;
use std::path::{Path, PathBuf};

use scylla::bounded::{BoundedVec, Random};
use scylla::language::Lexer as _;
use scylla::lex::GO;
use scylla::syntax::Structure;
use scylla::syntax::go::classify::classify;
use scylla::syntax::go::kind::GoKind;
use scylla::syntax::go::parse;
use scylla::token::{Token, Tokens};
use scylla::tree::{Events, Tree};
use scylla::trivia::{self, Gap};

const CONTINUATION: u8 = 0;
const ERROR_COUNT_MAX: u32 = 0x0000_0400;
const EVENT_COUNT_MAX: u32 = 0x000C_0000;
const EVERY_CATEGORY: [&str; 2] = ["not-go", "shape"];
const NODE_COUNT_MAX: u32 = 0x0004_0000;
const NOT_GO: [&str; 1] = ["not-go"];
const RAW_COUNT_MAX: u32 = 0x0004_0000;
const TOKEN_COUNT_MAX: u32 = 0x0004_0000;

const STATEMENTS: [&str; 20] = [
    "AssignStmt",
    "BlockStmt",
    "BranchStmt",
    "CaseClause",
    "CommClause",
    "DeclStmt",
    "DeferStmt",
    "ExprStmt",
    "ForStmt",
    "FuncDecl",
    "GenDecl",
    "GoStmt",
    "IfStmt",
    "IncDecStmt",
    "LabeledStmt",
    "RangeStmt",
    "ReturnStmt",
    "SelectStmt",
    "SendStmt",
    "SwitchStmt",
];

const SKIPPED: [&str; 1] = ["ErrorNode"];

struct Fixture {
    name: String,
    source: Vec<u8>,
}

struct Machine {
    events: Events<GoKind>,
    lexed: Tokens,
    raw: BoundedVec<GoKind>,
    tokens: Tokens,
    tree: Tree<GoKind>,
}

impl Machine {
    fn reserve() -> Self {
        Self {
            events: Events::reserve(EVENT_COUNT_MAX),
            lexed: Tokens::reserve(TOKEN_COUNT_MAX),
            raw: BoundedVec::reserve(RAW_COUNT_MAX),
            tokens: Tokens::reserve(TOKEN_COUNT_MAX),
            tree: Tree::reserve(NODE_COUNT_MAX, ERROR_COUNT_MAX),
        }
    }

    fn run(&mut self, source: &[u8]) -> bool {
        self.lexed.clear();
        GO.lex(source, &mut self.lexed);

        classify(
            source,
            self.lexed.as_slice(),
            &mut self.tokens,
            &mut self.raw,
        )
    }

    fn tokens(&self) -> &[Token] {
        self.tokens.as_slice()
    }

    fn parse(&mut self, source: &[u8]) -> Structure {
        assert!(self.run(source));

        parse::build(
            source,
            self.tokens.as_slice(),
            &self.raw,
            &mut self.events,
            &mut self.tree,
        )
    }

    fn walk(&self, length: u32) -> Vec<(String, u32, u32)> {
        let mut found = Vec::new();

        if self.tree.count() == 0 {
            return found;
        }

        for node in self.tree.as_slice() {
            let name = node.kind.name();

            if SKIPPED.contains(&name) {
                continue;
            }

            let span = node.span(self.tokens());

            if name == "File" {
                found.push((name.to_owned(), 0, length));

                continue;
            }

            found.push((name.to_owned(), span.offset, span.end()));
        }

        found.sort();

        found
    }

    fn comments(&self) -> Vec<(u32, u32)> {
        let mut found = Vec::new();

        for (position, kind) in self.raw.iter().enumerate() {
            if *kind != GoKind::Comment {
                continue;
            }

            let token = self.tokens()[position];

            found.push((token.offset, token.end()));
        }

        found
    }

    fn census(&self) -> Vec<(String, u32)> {
        let mut found = Vec::new();

        for name in STATEMENTS {
            let kind = GoKind::of_name(name).expect("the plan names a kind the library holds");
            let count = self
                .tree
                .as_slice()
                .iter()
                .filter(|node| node.kind == kind)
                .count();

            if count > 0 {
                found.push((name.to_owned(), u32::try_from(count).expect("small")));
            }
        }

        found
    }
}

fn wanted(
    source: &[u8],
    comments: &[(u32, u32)],
    rows: &[(String, u32, u32)],
) -> Vec<(String, u32, u32)> {
    let length = u32::try_from(source.len()).expect("a file fits in u32");
    let mut found: Vec<(String, u32, u32)> = Vec::new();

    for row in rows {
        if row.0 == "File" {
            found.push((row.0.clone(), 0, length));

            continue;
        }

        if row.1 >= row.2 {
            continue;
        }

        if comments
            .iter()
            .any(|comment| row.1 >= comment.0 && row.2 <= comment.1)
        {
            continue;
        }

        let mut start = row.1;

        for _ in 0..=comments.len() + rows.len() {
            let held = start;

            start = advanced(source, comments, start, row.2);

            if row.0.starts_with("Expr") {
                start = past_attributes(source, rows, start, row.2);
            }

            if start == held {
                break;
            }
        }

        found.push((row.0.clone(), start, row.2));
    }

    found.sort();

    found
}

fn past_attributes(source: &[u8], rows: &[(String, u32, u32)], offset: u32, end: u32) -> u32 {
    let mut held = offset;

    for _ in 0..rows.len() {
        let Some(found) = rows
            .iter()
            .find(|row| row.0 == "Attribute" && row.1 == held && row.2 <= end)
        else {
            return held;
        };

        held = found.2;

        while held < end && source[held as usize].is_ascii_whitespace() {
            held += 1;
        }
    }

    held
}

fn advanced(source: &[u8], comments: &[(u32, u32)], offset: u32, end: u32) -> u32 {
    let mut held = offset;

    for _ in 0..=comments.len() {
        let Some(comment) = comments
            .iter()
            .find(|comment| held >= comment.0 && held < comment.1)
        else {
            break;
        };

        held = comment.1;

        while held < end && source[held as usize].is_ascii_whitespace() {
            held += 1;
        }
    }

    held
}

fn census_of(rows: &[(String, u32, u32)]) -> Vec<(String, u32)> {
    let mut found = Vec::new();

    for name in STATEMENTS {
        let count = rows.iter().filter(|row| row.0 == name).count();

        if count > 0 {
            found.push((name.to_owned(), u32::try_from(count).expect("small")));
        }
    }

    found
}

fn corpus() -> Vec<Fixture> {
    let Ok(root) = std::env::var("SCYLLA_CORPUS") else {
        return Vec::new();
    };

    let held = PathBuf::from(root);
    let mut found = Vec::new();

    collect(&held, &held, &mut found);
    found.sort_by(|left, right| left.name.cmp(&right.name));

    found
}

fn fixtures() -> Vec<Fixture> {
    let root = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/go");

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

        let extension = path.extension().and_then(|held| held.to_str());

        if extension != Some("go") {
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

fn soup(random: &mut Random, length: u32) -> Vec<u8> {
    const ALPHABET: &[u8] =
        b"abc_09 \t\n\r()[]{}:,.=+-*/%<>!&|^~;'\"\\`funcvarypeinterfaceswitch\x00\xff\xc3\xa9";

    let width = u32::try_from(ALPHABET.len()).expect("the alphabet is small");
    let mut found = Vec::with_capacity(length as usize);

    for _ in 0..length {
        found.push(ALPHABET[random.below(width) as usize]);
    }

    found
}

fn gaps_are_blank(source: &[u8], tokens: &[Token], name: &str) {
    let length = u32::try_from(source.len()).expect("a fixture fits in u32");
    let mut end_previous = 0;
    let mut count = 0;

    for Gap { span, token } in trivia::gaps(length, tokens) {
        assert!(
            trivia::gap_is_blank(source, span, CONTINUATION),
            "{name} carries a non-blank gap at {} of {} bytes",
            span.offset,
            span.length
        );

        assert!(
            span.offset >= end_previous,
            "{name} runs its gaps backwards"
        );

        assert_eq!(token, count, "{name} numbers its gaps out of order");

        end_previous = span.end();
        count += 1;
    }

    assert_eq!(
        count as usize,
        tokens.len() + 1,
        "{name} owes one gap per token plus a trailing one"
    );

    assert_eq!(
        end_previous,
        length,
        "{name} leaves bytes past its last gap"
    );
}

fn invariants_hold(machine: &Machine, name: &str) {
    let walk = machine.tree.as_slice();
    let tokens = machine.tokens();
    let count = u32::try_from(walk.len()).expect("a tree fits in u32");

    for (position, node) in walk.iter().enumerate() {
        let index = u32::try_from(position).expect("a tree fits in u32");

        assert!(node.token_start <= node.token_end, "{name}: node {index}");

        assert!(
            node.token_end as usize <= tokens.len(),
            "{name}: node {index} runs past the tokens"
        );

        assert!(
            node.parent == scylla::tree::NONE || node.parent < index,
            "{name}: node {index} names a parent out of preorder"
        );

        assert!(
            node.child_first == scylla::tree::NONE || node.child_first > index,
            "{name}: node {index} names a child out of preorder"
        );

        assert!(
            node.sibling_next == scylla::tree::NONE || node.sibling_next < count,
            "{name}: node {index} names a sibling out of bounds"
        );

        let mut child = node.child_first;
        let mut end_previous = node.token_start;
        let mut seen = 0;

        while child != scylla::tree::NONE {
            let held = walk[child as usize];

            assert_eq!(
                held.parent,
                index,
                "{name}: node {child} disowns its parent"
            );

            assert!(
                held.token_start >= end_previous,
                "{name}: node {child} overlaps its sibling"
            );

            assert!(
                held.token_end <= node.token_end,
                "{name}: node {child} runs past its parent"
            );

            end_previous = held.token_end;
            child = held.sibling_next;
            seen += 1;

            assert!(
                seen <= count,
                "{name}: node {index} loops over its children"
            );
        }
    }
}

fn report(name: &str, held: &[(String, u32, u32)], expected: &[(String, u32, u32)]) -> String {
    use core::fmt::Write as _;

    let mut lines = format!("{name}: the walks differ\n");
    let mut shown = 0;
    let mut mine = 0;
    let mut theirs = 0;

    while shown < 24 && (mine < held.len() || theirs < expected.len()) {
        if theirs >= expected.len() || (mine < held.len() && held[mine] < expected[theirs]) {
            let row = &held[mine];
            let _ = writeln!(lines, "  extra   {} {} {}", row.0, row.1, row.2);

            mine += 1;
            shown += 1;

            continue;
        }

        if mine >= held.len() || expected[theirs] < held[mine] {
            let row = &expected[theirs];
            let _ = writeln!(lines, "  missing {} {} {}", row.0, row.1, row.2);

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
fn classify_is_total_over_the_fixtures() {
    let found = fixtures();

    assert!(!found.is_empty(), "tests/fixtures/go holds no source");

    let mut machine = Machine::reserve();

    for fixture in &found {
        assert!(machine.run(&fixture.source), "{} overran", fixture.name);

        let errors = machine
            .raw
            .iter()
            .filter(|kind| **kind == GoKind::ErrorToken)
            .count();

        assert_eq!(errors, 0, "{} classifies to an ErrorToken", fixture.name);
        assert_eq!(machine.raw.count() as usize, machine.tokens().len());
    }
}

#[test]
fn the_gaps_over_the_fixtures_hold_only_blank_bytes() {
    let found = fixtures();

    assert!(!found.is_empty(), "tests/fixtures/go holds no source");

    let mut machine = Machine::reserve();

    for fixture in &found {
        let _ = machine.run(&fixture.source);
        gaps_are_blank(&fixture.source, machine.tokens(), &fixture.name);
    }
}

#[test]
fn classify_is_total_on_byte_soup() {
    let mut random = Random::new(0x2545_F491_4F6C_DD1D);
    let mut machine = Machine::reserve();

    for round in 0..512_u32 {
        let length = random.below(512) + 1;
        let source = soup(&mut random, length);

        assert!(machine.run(&source), "round {round} overran");
        assert_eq!(machine.raw.count() as usize, machine.tokens().len());
        gaps_are_blank(&source, machine.tokens(), "byte soup");
    }
}

#[test]
fn the_parser_holds_its_invariants_on_byte_soup() {
    let mut random = Random::new(0x9E37_79B9_7F4A_7C15);
    let mut machine = Machine::reserve();

    for round in 0..512_u32 {
        let length = random.below(512) + 1;
        let source = soup(&mut random, length);

        let _ = machine.parse(&source);
        invariants_hold(&machine, "byte soup");

        let first: Vec<_> = machine.tree.as_slice().to_vec();

        let _ = machine.parse(&source);

        assert_eq!(
            machine.tree.as_slice(),
            first,
            "round {round} parses differently the second time"
        );
    }
}

#[test]
fn classify_runs_the_corpus_without_an_unclaimed_byte() {
    let found = corpus();

    if found.is_empty() {
        return;
    }

    let carried = oracle::residue_of("residue-go.json", &NOT_GO);
    let mut machine = Machine::reserve();
    let mut compared = 0;

    for fixture in &found {
        if carried.contains(&fixture.name) {
            continue;
        }

        assert!(machine.run(&fixture.source), "{} overran", fixture.name);

        for (position, kind) in machine.raw.iter().enumerate() {
            assert_ne!(
                *kind,
                GoKind::ErrorToken,
                "{} classifies token {position} to an ErrorToken",
                fixture.name
            );
        }

        gaps_are_blank(&fixture.source, machine.tokens(), &fixture.name);

        compared += 1;
    }

    assert!(compared >= 1000, "the corpus lost its Go files");
}

#[test]
fn the_tree_holds_its_invariants_over_the_corpus() {
    let found = corpus();

    if found.is_empty() {
        return;
    }

    let carried = oracle::residue_of("residue-go.json", &NOT_GO);
    let mut machine = Machine::reserve();

    for fixture in &found {
        if carried.contains(&fixture.name) {
            continue;
        }

        let _ = machine.parse(&fixture.source);
        invariants_hold(&machine, &fixture.name);
    }
}

#[test]
fn the_statement_census_matches_the_goldens() {
    let root = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/golden-go");
    let found = fixtures();

    assert!(!found.is_empty(), "tests/fixtures/go holds no source");

    let mut machine = Machine::reserve();
    let mut compared = 0;

    for fixture in &found {
        let golden = oracle::golden(&root, &fixture.name)
            .unwrap_or_else(|| panic!("{} has no golden", fixture.name));

        assert!(!golden.broken, "{} does not parse", fixture.name);

        let outcome = machine.parse(&fixture.source);

        assert_eq!(outcome, Structure::Complete, "{}", fixture.name);

        assert_eq!(
            machine.census(),
            census_of(&golden.ast),
            "{} counts its statements differently",
            fixture.name
        );

        compared += 1;
    }

    assert_eq!(compared, found.len(), "a fixture went uncompared");
}

#[test]
fn the_normalized_walk_matches_the_goldens() {
    let root = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/golden-go");
    let carried = oracle::residue_of("residue-go.json", &EVERY_CATEGORY);
    let found = fixtures();

    assert!(!found.is_empty(), "tests/fixtures/go holds no source");

    let mut machine = Machine::reserve();
    let mut compared = 0;

    for fixture in &found {
        if carried.contains(&fixture.name) {
            continue;
        }

        let golden = oracle::golden(&root, &fixture.name)
            .unwrap_or_else(|| panic!("{} has no golden", fixture.name));

        let _ = machine.parse(&fixture.source);

        let length = u32::try_from(fixture.source.len()).expect("a fixture fits in u32");
        let held = machine.walk(length);
        let expected = wanted(&fixture.source, &machine.comments(), &golden.ast);

        assert!(
            held == expected,
            "{}",
            report(&fixture.name, &held, &expected)
        );

        compared += 1;
    }

    assert!(compared > 0, "every fixture is residue");
}

#[test]
fn the_normalized_walk_matches_the_corpus_goldens() {
    let Ok(root) = std::env::var("SCYLLA_CORPUS_GOLDEN") else {
        return;
    };

    let held = PathBuf::from(root);
    let found = corpus();

    if found.is_empty() {
        return;
    }

    let carried = oracle::residue_of("residue-go.json", &EVERY_CATEGORY);
    let mut machine = Machine::reserve();
    let mut differing = Vec::new();
    let mut compared = 0;

    for fixture in &found {
        if carried.contains(&fixture.name) {
            continue;
        }

        let Some(golden) = oracle::golden(&held, &fixture.name) else {
            panic!("{} has no golden", fixture.name);
        };

        assert!(
            !golden.broken,
            "{} does not parse under the oracle",
            fixture.name
        );

        let _ = machine.parse(&fixture.source);

        let length = u32::try_from(fixture.source.len()).expect("a file fits in u32");
        let walk = machine.walk(length);
        let expected = wanted(&fixture.source, &machine.comments(), &golden.ast);

        if walk != expected {
            differing.push(report(&fixture.name, &walk, &expected));
        }

        compared += 1;
    }

    assert!(
        compared + carried.len() >= 1030,
        "the corpus lost its Go files"
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
