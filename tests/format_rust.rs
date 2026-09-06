#[path = "common/corpus.rs"]
mod corpus;
#[path = "common/floor.rs"]
mod floor;

use std::fs;
use std::path::PathBuf;

use scylla::bounded::{BoundedVec, Buffer, Span};
use scylla::format::print::Options;
use scylla::format::rust::{Formatter, Input, Outcome};
use scylla::language::Lexer as _;
use scylla::lex::RUST;
use scylla::syntax::rust::classify::classify;
use scylla::syntax::rust::kind::RustKind;
use scylla::syntax::rust::parse;
use scylla::token::{TokenKind, Tokens};
use scylla::tree::{Events, Tree};

const ELEMENT_COUNT_MAX: u32 = 1 << 18;
const ERROR_COUNT_MAX: u32 = 1 << 12;
const EVENT_COUNT_MAX: u32 = 1 << 20;
const NODE_COUNT_MAX: u32 = 1 << 18;
const OUT_BYTES_MAX: u32 = 1 << 22;
const TOKEN_COUNT_MAX: u32 = 1 << 18;

struct Held {
    events: Events<RustKind>,
    formatter: Formatter,
    lexed: Tokens,
    raw: BoundedVec<RustKind>,
    tokens: Tokens,
    tree: Tree<RustKind>,
}

impl Held {
    fn reserve() -> Self {
        Self {
            events: Events::reserve(EVENT_COUNT_MAX),
            formatter: Formatter::reserve(ELEMENT_COUNT_MAX, OUT_BYTES_MAX),
            lexed: Tokens::reserve(TOKEN_COUNT_MAX),
            raw: BoundedVec::reserve(TOKEN_COUNT_MAX),
            tokens: Tokens::reserve(TOKEN_COUNT_MAX),
            tree: Tree::reserve(NODE_COUNT_MAX, ERROR_COUNT_MAX),
        }
    }

    fn format(&mut self, source: &[u8], out: &mut Buffer) -> Outcome {
        self.lexed.clear();
        self.raw.clear();
        self.tokens.clear();

        RUST.lex(source, &mut self.lexed);

        if !classify(
            source,
            self.lexed.as_slice(),
            &mut self.tokens,
            &mut self.raw,
        ) {
            return Outcome::Overflow;
        }

        let outcome = parse::build(
            source,
            self.tokens.as_slice(),
            &self.raw,
            &mut self.events,
            &mut self.tree,
        );

        let input = Input {
            options: Options::DEFAULT,
            outcome,
            raw: &self.raw,
            source,
            tokens: self.tokens.as_slice(),
            tree: &self.tree,
        };

        self.formatter.format(&input, out)
    }

    fn range(&mut self, source: &[u8], lines: (u32, u32), out: &mut Buffer) -> Option<Span> {
        self.lexed.clear();
        self.raw.clear();
        self.tokens.clear();

        RUST.lex(source, &mut self.lexed);

        if !classify(
            source,
            self.lexed.as_slice(),
            &mut self.tokens,
            &mut self.raw,
        ) {
            return None;
        }

        let outcome = parse::build(
            source,
            self.tokens.as_slice(),
            &self.raw,
            &mut self.events,
            &mut self.tree,
        );

        let input = Input {
            options: Options::DEFAULT,
            outcome,
            raw: &self.raw,
            source,
            tokens: self.tokens.as_slice(),
            tree: &self.tree,
        };

        self.formatter.range(&input, lines, out)
    }

    fn words(&mut self, source: &[u8]) -> Vec<String> {
        self.lexed.clear();
        RUST.lex(source, &mut self.lexed);

        self.lexed
            .as_slice()
            .iter()
            .filter(|token| {
                !matches!(
                    token.kind,
                    TokenKind::BlockEnd | TokenKind::BlockStart | TokenKind::Newline
                ) && token.length > 0
            })
            .map(|token| {
                if token.kind == TokenKind::String {
                    return "<string>".to_owned();
                }

                String::from_utf8_lossy(token.text(source)).into_owned()
            })
            .collect()
    }

    fn kinds(&mut self, source: &[u8]) -> Vec<RustKind> {
        self.lexed.clear();
        self.raw.clear();
        self.tokens.clear();

        RUST.lex(source, &mut self.lexed);

        assert!(classify(
            source,
            self.lexed.as_slice(),
            &mut self.tokens,
            &mut self.raw
        ));

        self.raw
            .iter()
            .copied()
            .filter(|kind| !matches!(kind.name(), "Dedent" | "Indent" | "Newline"))
            .collect()
    }

    fn comments(&mut self, source: &[u8]) -> Vec<Vec<u8>> {
        self.lexed.clear();
        self.raw.clear();
        self.tokens.clear();

        RUST.lex(source, &mut self.lexed);

        assert!(classify(
            source,
            self.lexed.as_slice(),
            &mut self.tokens,
            &mut self.raw
        ));

        self.raw
            .iter()
            .enumerate()
            .filter(|(_, kind)| **kind == RustKind::Comment)
            .map(|(index, _)| {
                source[self.tokens.as_slice()[index].span().range()]
                    .trim_ascii_end()
                    .to_vec()
            })
            .collect()
    }
}

fn fixtures() -> Vec<(String, Vec<u8>)> {
    let root = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/rust");
    let mut found = Vec::new();

    for entry in fs::read_dir(&root).expect("the fixture directory is readable") {
        let path = entry.expect("the entry is readable").path();

        if path.extension().is_none_or(|extension| extension != "rs") {
            continue;
        }

        let name = path
            .file_name()
            .expect("the fixture has a name")
            .to_string_lossy()
            .into_owned();

        let source = fs::read(&path).expect("the fixture is readable");

        found.push((name, source));
    }

    found.sort_by(|left, right| left.0.cmp(&right.0));

    assert!(found.len() > 4);

    found
}

#[test]
fn formatting_formatted_output_changes_nothing() {
    let mut first = Buffer::reserve(OUT_BYTES_MAX);
    let mut held = Held::reserve();
    let mut second = Buffer::reserve(OUT_BYTES_MAX);

    for (name, source) in fixtures() {
        assert_eq!(
            held.format(&source, &mut first),
            Outcome::Complete,
            "{name}"
        );

        let once = first.as_bytes().to_vec();

        assert_eq!(held.format(&once, &mut second), Outcome::Complete, "{name}");

        assert_eq!(
            String::from_utf8_lossy(second.as_bytes()),
            String::from_utf8_lossy(&once),
            "{name} is not idempotent"
        );
    }
}

fn listed(kinds: &[RustKind]) -> Vec<RustKind> {
    kinds
        .iter()
        .enumerate()
        .filter(|(index, held)| {
            **held != RustKind::Comma
                || !matches!(
                    kinds.get(index + 1),
                    Some(RustKind::BraceClose | RustKind::BracketClose | RustKind::ParenClose)
                )
        })
        .map(|(_, held)| *held)
        .collect()
}

fn ordered(kinds: &[RustKind]) -> Vec<RustKind> {
    let mut held = Vec::with_capacity(kinds.len());
    let mut index = 0;

    while index < kinds.len() {
        held.push(kinds[index]);
        index += 1;

        if kinds[index - 1] != RustKind::BraceOpen {
            continue;
        }

        let Some(close) = listed_at(kinds, index) else {
            continue;
        };

        let mut run = kinds[index..close].to_vec();

        run.sort_unstable_by_key(|kind| kind.name());
        held.extend(run);
        index = close;
    }

    held
}

fn listed_at(kinds: &[RustKind], open: usize) -> Option<usize> {
    let mut depth = 0;
    let mut index = open;

    while index < kinds.len() {
        let held = kinds[index];

        if held == RustKind::BraceClose {
            if depth == 0 {
                return Some(index);
            }

            depth -= 1;
            index += 1;

            continue;
        }

        if held == RustKind::BraceOpen {
            depth += 1;
            index += 1;

            continue;
        }

        if !matches!(
            held,
            RustKind::AsKeyword
                | RustKind::ColonColon
                | RustKind::Comma
                | RustKind::CrateKeyword
                | RustKind::Identifier
                | RustKind::SelfLower
                | RustKind::Star
                | RustKind::SuperKeyword
                | RustKind::Underscore
        ) {
            return None;
        }

        index += 1;
    }

    None
}

fn imported<T>(
    held: &[T],
    ends: fn(&T) -> bool,
    heads: fn(&T) -> bool,
    opens: fn(&T) -> bool,
    nests: fn(&T) -> i32,
) -> Vec<T>
where
    T: Clone + Ord,
{
    let mut found = Vec::with_capacity(held.len());
    let mut index = 0;

    while index < held.len() {
        let mut run: Vec<Vec<T>> = Vec::new();
        let mut scan = index;

        while let Some(stop) = statement_end(held, scan, ends, nests) {
            if !heads(&held[scan]) || !opened_at(&held[scan..stop], opens, nests) {
                break;
            }

            run.push(held[scan..stop].to_vec());
            scan = stop;
        }

        if run.len() < 2 {
            found.push(held[index].clone());
            index += 1;

            continue;
        }

        run.sort();

        for statement in run {
            found.extend(statement);
        }

        index = scan;
    }

    found
}

fn opened_at<T>(held: &[T], opens: fn(&T) -> bool, nests: fn(&T) -> i32) -> bool {
    let mut depth = 0;

    for element in held {
        if depth == 0 && opens(element) {
            return true;
        }

        depth += nests(element);
    }

    false
}

fn statement_end<T>(
    held: &[T],
    from: usize,
    ends: fn(&T) -> bool,
    nests: fn(&T) -> i32,
) -> Option<usize> {
    let mut depth = 0;
    let mut index = from;

    while index < held.len() {
        depth += nests(&held[index]);

        if depth < 0 {
            return None;
        }

        if depth == 0 && ends(&held[index]) {
            return Some(index + 1);
        }

        index += 1;
    }

    None
}

fn nested_kind(kind: RustKind) -> i32 {
    match kind {
        RustKind::BraceOpen | RustKind::BracketOpen | RustKind::ParenOpen => 1,
        RustKind::BraceClose | RustKind::BracketClose | RustKind::ParenClose => -1,
        _ => 0,
    }
}

fn nested_word(word: &str) -> i32 {
    match word {
        "{" | "[" | "(" => 1,
        "}" | "]" | ")" => -1,
        _ => 0,
    }
}

fn unwrapped(kinds: &[RustKind]) -> Vec<RustKind> {
    let mut bare = vec![false; kinds.len()];
    let mut cut = vec![false; kinds.len()];
    let mut open: Vec<usize> = Vec::new();

    for (index, kind) in kinds.iter().enumerate() {
        match nested_kind(*kind) {
            1 => open.push(index),
            -1 => {
                if let Some(held) = open.pop() {
                    if cut[held] {
                        cut[index] = true;
                        bare[index] = bare[held];
                    }
                }
            }
            _ => continue,
        }

        if *kind != RustKind::BraceOpen || index == 0 {
            continue;
        }

        if kinds[index - 1] == RustKind::FatArrow {
            cut[index] = true;
        }

        if matches!(kinds[index - 1], RustKind::Or | RustKind::OrOr) {
            cut[index] = true;
            bare[index] = true;
        }
    }

    let mut held = Vec::with_capacity(kinds.len());

    for (index, kind) in kinds.iter().enumerate() {
        if !cut[index] {
            held.push(*kind);

            continue;
        }

        if *kind == RustKind::BraceClose
            && !bare[index]
            && kinds.get(index + 1) != Some(&RustKind::Comma)
        {
            held.push(RustKind::Comma);
        }
    }

    held
}

fn related(kinds: &[RustKind]) -> Vec<RustKind> {
    imported(
        &ordered(&listed(&unwrapped(kinds))),
        |kind| *kind == RustKind::Semicolon,
        |kind| {
            matches!(
                kind,
                RustKind::Pound | RustKind::PubKeyword | RustKind::UseKeyword
            )
        },
        |kind| *kind == RustKind::UseKeyword,
        |kind| nested_kind(*kind),
    )
}

fn terminated(source: &[RustKind], printed: &[RustKind]) -> bool {
    let mut held = 0;

    for kind in printed {
        if source.get(held) == Some(kind) {
            held += 1;

            continue;
        }

        if *kind == RustKind::Semicolon {
            continue;
        }

        return false;
    }

    held == source.len()
}

fn ended(source: &[String], printed: &[String]) -> bool {
    let mut held = 0;

    for word in printed {
        if source.get(held) == Some(word) {
            held += 1;

            continue;
        }

        if word.as_str() == ";" {
            continue;
        }

        return false;
    }

    held == source.len()
}

#[test]
fn formatting_keeps_every_token_it_was_given() {
    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    for (name, source) in fixtures() {
        assert_eq!(held.format(&source, &mut out), Outcome::Complete);

        let formatted = out.as_bytes().to_vec();
        let before = related(&held.kinds(&source));
        let after = related(&held.kinds(&formatted));

        assert!(terminated(&before, &after), "{name} lost or gained a token");
    }
}

#[test]
fn formatting_keeps_every_comment_it_was_given() {
    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    for (name, source) in fixtures() {
        assert_eq!(held.format(&source, &mut out), Outcome::Complete);

        let formatted = out.as_bytes().to_vec();

        assert_eq!(
            held.comments(&source),
            held.comments(&formatted),
            "{name} lost a comment"
        );
    }
}

#[test]
fn a_dump_writes_the_formatted_fixtures() {
    let Ok(root) = std::env::var("SCYLLA_FORMAT_DUMP") else {
        return;
    };

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    for (name, source) in fixtures() {
        assert_eq!(held.format(&source, &mut out), Outcome::Complete);

        fs::write(PathBuf::from(&root).join(name), out.as_bytes())
            .expect("the dump directory is writable");
    }
}

#[path = "common/oracle.rs"]
mod oracle;

const EVERY_CATEGORY: [&str; 3] = [
    "rustfmt-item-ordering",
    "rustfmt-line-breaking",
    "rustfmt-macro-spacing",
];

#[test]
fn the_formatted_output_matches_the_oracle_modulo_residue() {
    let carried = oracle::residue_of("residue-format-rust.json", &EVERY_CATEGORY);
    let root = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/golden-rustfmt");
    let mut compared = 0;
    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    for (name, source) in fixtures() {
        if carried.contains(&name) {
            continue;
        }

        assert_eq!(held.format(&source, &mut out), Outcome::Complete);

        let golden = fs::read(root.join(&name)).expect("the golden is dumped");

        assert_eq!(
            String::from_utf8_lossy(out.as_bytes()),
            String::from_utf8_lossy(&golden),
            "{name} diverges from rustfmt and no residue row names it"
        );

        compared += 1;
    }

    assert!(
        compared >= floor::FIXTURE_FORMAT_RUST,
        "the Rust fixtures lost a formatting: {compared} compared, floor {}",
        floor::FIXTURE_FORMAT_RUST
    );
}

#[test]
fn every_residue_row_names_a_fixture_that_diverges() {
    let carried = oracle::residue_of("residue-format-rust.json", &EVERY_CATEGORY);
    let root = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/golden-rustfmt");
    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    for name in &carried {
        let source = fs::read(
            PathBuf::from(env!("CARGO_MANIFEST_DIR"))
                .join("tests/fixtures/rust")
                .join(name),
        )
        .expect("the residue row names a fixture");

        assert_eq!(held.format(&source, &mut out), Outcome::Complete);

        let golden = fs::read(root.join(name)).expect("the golden is dumped");

        assert_ne!(
            out.as_bytes(),
            golden.as_slice(),
            "{name} matches rustfmt and needs no residue row"
        );
    }
}

#[test]
fn a_file_that_does_not_parse_is_refused() {
    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(b"fn f( {\n", &mut out), Outcome::Refusal);
    assert!(out.is_empty());
}

#[test]
fn a_block_comment_that_never_closes_its_nesting_is_refused() {
    const SOURCES: [&[u8]; 3] = [b"/*/*/", b"x/*/*/", b"/* /*"];
    const CLOSED: [&[u8]; 2] = [b"/* a */\n", b"/* /* b */ */\n"];

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    for source in SOURCES {
        assert_eq!(
            held.format(source, &mut out),
            Outcome::Refusal,
            "{:?}",
            String::from_utf8_lossy(source)
        );
    }

    for source in CLOSED {
        assert_eq!(
            held.format(source, &mut out),
            Outcome::Complete,
            "{:?}",
            String::from_utf8_lossy(source)
        );
    }
}

#[test]
fn a_range_reads_back_the_lines_it_names() {
    let source: &[u8] = b"fn f() {\nlet x=1;\nlet _=x;\n}\n";
    let mut held = Held::reserve();
    let mut whole = Buffer::reserve(OUT_BYTES_MAX);
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(source, &mut whole), Outcome::Complete);

    let formatted = whole.as_bytes().to_vec();

    let span = held
        .range(source, (1, 2), &mut out)
        .expect("the range is formatted");

    assert_eq!(out.as_bytes(), formatted);
    assert_eq!(&out.as_bytes()[span.range()], lines_of(&formatted, 1, 2));
}

#[test]
fn the_three_relations_hold_over_the_corpus() {
    let Some(root) = corpus::root() else {
        return;
    };

    let mut first = Buffer::reserve(OUT_BYTES_MAX);
    let mut held = Held::reserve();
    let mut pending = vec![root];
    let mut second = Buffer::reserve(OUT_BYTES_MAX);
    let mut seen = 0;
    let stride = corpus::stride();

    while let Some(directory) = pending.pop() {
        let Ok(entries) = fs::read_dir(&directory) else {
            continue;
        };

        for entry in entries {
            let path = entry.expect("the entry is readable").path();

            if path.is_dir() {
                pending.push(path);

                continue;
            }

            if path.extension().is_none_or(|extension| extension != "rs") {
                continue;
            }

            seen += 1;

            if seen % stride != 0 {
                continue;
            }

            let Ok(source) = fs::read(&path) else {
                continue;
            };

            if held.format(&source, &mut first) != Outcome::Complete {
                continue;
            }

            let once = first.as_bytes().to_vec();
            let before = related(&held.kinds(&source));
            let after = related(&held.kinds(&once));

            assert!(
                terminated(&before, &after),
                "{} lost a token",
                path.display()
            );

            assert_eq!(
                String::from_utf8_lossy(&held.comments(&source).concat()),
                String::from_utf8_lossy(&held.comments(&once).concat()),
                "{} lost a comment",
                path.display()
            );

            assert_eq!(
                held.format(&once, &mut second),
                Outcome::Complete,
                "{}",
                path.display()
            );

            assert_eq!(
                String::from_utf8_lossy(second.as_bytes()),
                String::from_utf8_lossy(&once),
                "{} is not idempotent",
                path.display()
            );
        }
    }
}

fn lines_of(bytes: &[u8], first: u32, last: u32) -> &[u8] {
    let mut line = 0;
    let mut start = 0;
    let mut end = bytes.len();

    for (offset, byte) in bytes.iter().enumerate() {
        if *byte != b'\n' {
            continue;
        }

        line += 1;

        if line == first {
            start = offset + 1;
        }

        if line == last + 1 {
            end = offset + 1;

            break;
        }
    }

    &bytes[start..end]
}

#[test]
fn formatting_keeps_every_word_it_was_given() {
    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    for (name, source) in fixtures() {
        if held.format(&source, &mut out) != Outcome::Complete {
            continue;
        }

        let formatted = out.as_bytes().to_vec();

        let before = imported(
            &held.words(&source),
            |word| word == ";",
            |word| matches!(word.as_str(), "#" | "pub" | "use"),
            |word| word == "use",
            |word| nested_word(word),
        );

        let after = imported(
            &held.words(&formatted),
            |word| word == ";",
            |word| matches!(word.as_str(), "#" | "pub" | "use"),
            |word| word == "use",
            |word| nested_word(word),
        );

        assert!(
            ended(&before, &after),
            "{name} split, joined, lost, or gained a word"
        );
    }
}

#[test]
fn a_macro_definitions_matcher_is_written_from_the_source_and_its_body_is_laid_out() {
    const SOURCE: &[u8] = b"macro_rules! held {\n    ($a : ty, $b:expr) => {\n        #[doc=$b]\n        struct  S ( $a ) ;\n    };\n}\n";
    const WANTED: &[u8] = b"macro_rules! held {\n    ($a : ty, $b:expr) => {\n        #[doc=$b]\n        struct S($a);\n    };\n}\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(WANTED)
    );
}

#[test]
fn a_sole_argument_that_is_a_call_parts_inside_that_call() {
    const SOURCE: &[u8] = b"fn a() -> io::Result<()> {\n    if held.status.is_error() {\n        Err(io::Error::from_raw_os_error(completion_token.status.as_usize()))\n    } else {\n        Ok(())\n    }\n}\n";
    const WANTED: &[u8] = b"fn a() -> io::Result<()> {\n    if held.status.is_error() {\n        Err(io::Error::from_raw_os_error(\n            completion_token.status.as_usize(),\n        ))\n    } else {\n        Ok(())\n    }\n}\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(WANTED)
    );
}

#[test]
fn an_overflow_stops_at_the_callee_that_no_longer_fits_the_budget_above_it() {
    const SOURCE: &[u8] = b"fn b() -> UnixDatagram {\n    UnixDatagram(Socket::from_inner(FromInner::from_inner(OwnedFd::from_raw_fd(fd))))\n}\n";
    const WANTED: &[u8] = b"fn b() -> UnixDatagram {\n    UnixDatagram(Socket::from_inner(FromInner::from_inner(\n        OwnedFd::from_raw_fd(fd),\n    )))\n}\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(WANTED)
    );
}

#[test]
fn a_separator_the_source_wrote_past_the_last_argument_spells_no_column() {
    const SOURCE: &[u8] =
        b"fn c() {\n    let kind = E(format!(\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",));\n}\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(SOURCE)
    );
}

#[test]
fn a_macro_definitions_branch_body_is_laid_over_lines_however_short_it_runs() {
    const SOURCE: &[u8] = b"macro_rules! held {\n    ($a:expr) => { f($a) };\n}\n";
    const WANTED: &[u8] = b"macro_rules! held {\n    ($a:expr) => {\n        f($a)\n    };\n}\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(WANTED)
    );
}

#[test]
fn a_macro_branch_body_that_is_a_block_keeps_the_two_braces_welded() {
    const SOURCE: &[u8] = b"macro_rules! held {\n    ($a:expr) => {{\n        f($a)\n    }};\n}\n";
    const WANTED: &[u8] = b"macro_rules! held {\n    ($a:expr) => {{ f($a) }};\n}\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(WANTED)
    );
}

#[test]
fn a_macro_definition_holding_a_metavariable_expression_is_written_from_the_source() {
    const SOURCE: &[u8] =
        b"macro_rules! held {\n    ($name:ident) => {\n        f!(one, ${ concat($name, _tail) } );\n    };\n}\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(SOURCE)
    );
}

#[test]
fn a_macro_definition_holding_a_remark_past_the_width_is_written_from_the_source() {
    const SOURCE: &[u8] =
        b"macro_rules! held {\n    ($a:expr) => {\n        // REMARK\n        f( $a )\n    };\n}\n";

    let source = String::from_utf8_lossy(SOURCE).replace("REMARK", &"x".repeat(96));
    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(source.as_bytes(), &mut out), Outcome::Complete);
    assert_eq!(String::from_utf8_lossy(out.as_bytes()), source);
}

#[test]
fn an_attribute_holding_what_no_meta_item_holds_is_written_from_the_source() {
    const SOURCE: &[u8] = b"#[doc = concat!(\n    \"one\",\n    \"two\"\n)]\npub fn held() {}\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(SOURCE)
    );
}

#[test]
fn a_macro_invocation_the_braces_delimit_is_written_from_the_source() {
    const SOURCE: &[u8] = b"fn f() {\n    held! { a : b,  c }\n}\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(out.as_bytes(), SOURCE);
}

#[test]
fn an_item_the_attribute_holds_out_is_written_from_the_source() {
    const SOURCE: &[u8] = b"fn f() {\n    #[rustfmt::skip]\n    let held = named(0,  1,  2,   3,  4,  5,   6,  7,  8,   9,  10, 11, 12, 13, 14, 15,\n                     16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31);\n}\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(out.as_bytes(), SOURCE);
}

#[test]
fn an_item_no_attribute_holds_out_is_written_by_the_layout() {
    const SOURCE: &[u8] = b"fn f() {\n    #[inline]\n    let held = named(0,  1);\n}\n";
    const WANTED: &[u8] = b"fn f() {\n    #[inline]\n    let held = named(0, 1);\n}\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(out.as_bytes(), WANTED);
}

#[test]
fn a_definition_the_attribute_holds_out_ends_on_its_own_brace() {
    const SOURCE: &[u8] =
        b"#[rustfmt::skip]\nfn held(a:  u32) -> u32 {\n    1  +  2\n}\n\nfn after(b:  u32) {}\n";

    const WANTED: &[u8] =
        b"#[rustfmt::skip]\nfn held(a:  u32) -> u32 {\n    1  +  2\n}\n\nfn after(b: u32) {}\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(out.as_bytes(), WANTED);
}

#[test]
fn a_pattern_writes_its_alternatives_at_the_arm_it_belongs_to() {
    const SOURCE: &[u8] = b"fn held(value: Kind) -> Option<u32> {\n    match value {\n        Kind::ArithmeticShiftLeft\n        | Kind::ArithmeticShiftRight\n        | Kind::LogicalShiftRight\n        | Kind::CountLeadingZeros\n        | Kind::CountTrailingZeros => None,\n        _ => Some(0),\n    }\n}\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(out.as_bytes(), SOURCE);
}

#[test]
fn a_clause_opens_past_the_word_ending_a_line_and_closes_on_the_items_separator() {
    const SOURCE: &[u8] = b"pub trait Held {\n    /// The arguments the call takes.\n    type Args<'a>\n    where\n        Self: 'a;\n\n    /// The value the call answers with.\n    type Ret;\n}\n\npub fn held<Scalar, Vector>(one: &dyn Fn(Vector) -> Scalar, two: &dyn Fn(Scalar) -> bool)\nwhere\n    Scalar: Copy + core::fmt::Debug + DefaultStrategy,\n    Vector: Into<[Scalar; 4]> + From<[Scalar; 4]> + Copy,\n{\n}\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(out.as_bytes(), SOURCE);
}

#[test]
fn a_branched_expression_wider_than_its_own_width_parts_at_both_braces() {
    const SOURCE: &[u8] = b"fn held(c: bool) -> u32 {\n    let one = if c { 111111111111111111111111111111 } else { 2 };\n    let two = if c { 1111111111111111111111111111111 } else { 2 };\n    one + two\n}\n";
    const WANTED: &[u8] = b"fn held(c: bool) -> u32 {\n    let one = if c { 111111111111111111111111111111 } else { 2 };\n    let two = if c {\n        1111111111111111111111111111111\n    } else {\n        2\n    };\n    one + two\n}\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(WANTED)
    );
}

#[test]
fn an_attribute_wider_than_its_own_width_parts_at_the_separators_it_holds() {
    const SOURCE: &[u8] = b"#[unstable(feature = \"iter_macro\", issue = \"142269\", reason = \"generators unstab\")]\nfn a() {}\n#[unstable(feature = \"iter_macro\", issue = \"142269\", reason = \"generators unstabl\")]\nfn b() {}\n#[derive(Clone, Copy, Debug, Eq, PartialEq, Ord, PartialOrd, Hash, Default, Serialize)]\nstruct C;\n";
    const WANTED: &[u8] = b"#[unstable(feature = \"iter_macro\", issue = \"142269\", reason = \"generators unstab\")]\nfn a() {}\n#[unstable(\n    feature = \"iter_macro\",\n    issue = \"142269\",\n    reason = \"generators unstabl\"\n)]\nfn b() {}\n#[derive(Clone, Copy, Debug, Eq, PartialEq, Ord, PartialOrd, Hash, Default, Serialize)]\nstruct C;\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(WANTED)
    );
}

#[test]
fn an_attribute_the_reference_does_not_read_stands_however_wide_it_runs() {
    const SOURCE: &[u8] = b"#[foo(alpha = Xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx, beta = \"yyyyyyyyyyyyyyyyyyyyyyyyyyyyy\")]\nfn c() {}\n#[foo(\"Use of bat as a pager is disallowed in order to avoid infinite recursion prob1\")]\nfn d() {}\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(SOURCE)
    );
}

#[test]
fn a_call_wider_than_its_own_width_parts_at_the_separators_it_holds() {
    const SOURCE: &[u8] = b"fn t() {\n    held60(aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa, bbbbbbbbbbbbbbbbbb);\n    held61(aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa, bbbbbbbbbbbbbbbbbb);\n}\n";
    const WANTED: &[u8] = b"fn t() {\n    held60(aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa, bbbbbbbbbbbbbbbbbb);\n    held61(\n        aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa,\n        bbbbbbbbbbbbbbbbbb,\n    );\n}\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(WANTED)
    );
}

#[test]
fn a_definition_lays_its_own_parameters_out_against_the_line() {
    const SOURCE: &[u8] =
        b"fn t(ptr: *mut (), flags: u64, name_buf: *mut u8, filename: u8, held: u16) {}\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(SOURCE)
    );
}

#[test]
fn a_run_of_imports_is_written_in_the_order_the_language_sorts_them() {
    const SOURCE: &[u8] = b"use zed::Zed;\nuse crate::Alpha;\nuse crate::alpha;\nuse super::Beta;\nuse self::Gamma;\nuse std::fmt;\n\nuse held::A;\n// a remark\nuse later::B;\nuse early::C;\nfn f() {}\n";
    const WANTED: &[u8] = b"use self::Gamma;\nuse super::Beta;\nuse crate::Alpha;\nuse crate::alpha;\nuse std::fmt;\nuse zed::Zed;\n\nuse held::A;\n// a remark\nuse early::C;\nuse later::B;\nfn f() {}\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(WANTED)
    );
}

#[test]
fn a_macro_body_and_an_item_held_out_keep_the_order_the_source_gave_them() {
    const SOURCE: &[u8] = b"cfg_if! {\n    if #[cfg(unix)] {\n        use zed::Zed;\n        use alpha::Alpha;\n    }\n}\n\n#[rustfmt::skip]\nmod held {\n    use zed::Zed;\n    use alpha::Alpha;\n}\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(SOURCE)
    );
}

#[test]
fn a_chain_wider_than_its_own_width_parts_at_every_link_it_holds() {
    const SOURCE: &[u8] = b"fn t() {\n    ab.inner.borrow_mut().entry(key).or_insert_with(Vec::newxxxxxxxxxxxxx);\n    abcde.inner.borrow_mut().entry(key).or_insert_with(Vec::newxxxxxxxxxx);\n    self.slice[self.position..self.position + len].copy_from_slice(datax);\n}\n";
    const WANTED: &[u8] = b"fn t() {\n    ab.inner\n        .borrow_mut()\n        .entry(key)\n        .or_insert_with(Vec::newxxxxxxxxxxxxx);\n    abcde\n        .inner\n        .borrow_mut()\n        .entry(key)\n        .or_insert_with(Vec::newxxxxxxxxxx);\n    self.slice[self.position..self.position + len].copy_from_slice(datax);\n}\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(WANTED)
    );
}

#[test]
fn a_literal_wider_than_its_own_width_parts_at_the_separators_it_holds() {
    const SOURCE: &[u8] = b"fn t() -> Held {\n    let a = Held { one: 111111, two: 222222 };\n    let b = Held { one: 1, ..Default::default() };\n    let c = Held { a: xxxxxxxxxxxxxxx };\n    Held { inner: sys::Condvar::new() }\n}\n";
    const WANTED: &[u8] = b"fn t() -> Held {\n    let a = Held {\n        one: 111111,\n        two: 222222,\n    };\n    let b = Held {\n        one: 1,\n        ..Default::default()\n    };\n    let c = Held { a: xxxxxxxxxxxxxxx };\n    Held {\n        inner: sys::Condvar::new(),\n    }\n}\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(WANTED)
    );
}

#[test]
fn a_brace_a_word_heads_holds_statements_however_wide_they_run() {
    const SOURCE: &[u8] = b"fn t(held: Kind) -> bool {\n    if held.one && held.two && held.three && held.four && held.five {\n        return true;\n    }\n    let get = |size, lit| -> Vec<BString> { ngrams(size, lit).collect() };\n    get(1, \"x\").is_empty()\n}\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(SOURCE)
    );
}

#[test]
fn a_macro_wider_than_a_calls_width_parts_at_the_separators_it_holds() {
    const SOURCE: &[u8] = b"fn t() {\n    t!(first_argument_value_here, second_argument_value_here, third_argument_value_goes_here);\n    t!(first_argument_value_here, second_argument_value_her);\n}\n";
    const WANTED: &[u8] = b"fn t() {\n    t!(\n        first_argument_value_here,\n        second_argument_value_here,\n        third_argument_value_goes_here\n    );\n    t!(first_argument_value_here, second_argument_value_her);\n}\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(WANTED)
    );
}

#[test]
fn a_macro_holding_a_token_stream_stands_however_wide_it_runs() {
    const SOURCE: &[u8] = b"fn t() {\n    thread_local!(static HELD: RefCell<u32> = RefCell::new(0); static O: Cell<u8> = Cell::new(1));\n    asm!(\"sfence.vma {}, {}\", in(reg) vaddr, in(reg) asid, options(nostack, preserves_flags));\n    check_it!(val: || {}, \"a name that carries on for a while so the whole runs past sixty\");\n}\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(SOURCE)
    );
}

#[test]
fn a_definitions_parameters_take_the_lines_the_width_settles_for_them() {
    const SOURCE: &[u8] = b"fn joined(\n    aaa: u8,\n    bbb: u8,\n) {}\nfn parted(aaaaaaaaaaaaaaaa: u8, bbbbbbbbbbbbbbbb: u8, cccccccccccccccc: u8, dddddddddddddddd: u8, eeeeeeeeeeeeeeee: u8) {}\n";
    const WANTED: &[u8] = b"fn joined(aaa: u8, bbb: u8) {}\nfn parted(\n    aaaaaaaaaaaaaaaa: u8,\n    bbbbbbbbbbbbbbbb: u8,\n    cccccccccccccccc: u8,\n    dddddddddddddddd: u8,\n    eeeeeeeeeeeeeeee: u8,\n) {}\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(WANTED)
    );
}

#[test]
fn a_value_the_source_wrote_under_its_assignment_takes_the_line_that_holds_it() {
    const SOURCE: &[u8] = b"fn t() {\n    let held =\n        gathered(first_value);\n    let other =\n        gathered(first_value_here_long, second_value_here_long, third_value, fourth_value, fifth);\n}\n";
    const WANTED: &[u8] = b"fn t() {\n    let held = gathered(first_value);\n    let other = gathered(\n        first_value_here_long,\n        second_value_here_long,\n        third_value,\n        fourth_value,\n        fifth,\n    );\n}\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(WANTED)
    );
}

#[test]
fn a_use_tree_is_written_tight_and_sorted_at_every_brace_it_holds() {
    const SOURCE: &[u8] = b"use { bstr::ByteVec, ignore::WalkBuilder };\nuse crate::iter::{filter_map::FilterMap, filter::Filter, chain::Chain};\npub use crate::{\n    color::{ColorSpecs, ColorError},\n    hyperlink::{\n        HyperlinkAlias, HyperlinkConfig, HyperlinkEnvironment,\n        HyperlinkFormat, HyperlinkFormatError, hyperlink_aliases,\n    },\n};\nfn t() {}\n";
    const WANTED: &[u8] = b"use crate::iter::{chain::Chain, filter::Filter, filter_map::FilterMap};\npub use crate::{\n    color::{ColorError, ColorSpecs},\n    hyperlink::{\n        HyperlinkAlias, HyperlinkConfig, HyperlinkEnvironment, HyperlinkFormat,\n        HyperlinkFormatError, hyperlink_aliases,\n    },\n};\nuse {bstr::ByteVec, ignore::WalkBuilder};\nfn t() {}\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(WANTED)
    );
}

#[test]
fn a_remark_inside_a_chain_keeps_the_level_its_links_stand_at() {
    const SOURCE: &[u8] = b"fn main() {\n    PrettyPrinter::new()\n        .grid(true)\n        // The following line will be highlighted in the output:\n        .theme(\"1337\")\n        .print()\n        .unwrap();\n}\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(SOURCE)
    );
}

#[test]
fn a_macro_the_reference_cannot_read_keeps_the_blanks_the_source_gave_it() {
    const SOURCE: &[u8] = b"fn f() {\n    bar!(q : 1,  r : 2);\n    foo!(a,  b);\n}\n";
    const WANTED: &[u8] = b"fn f() {\n    bar!(q : 1,  r : 2);\n    foo!(a, b);\n}\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(WANTED)
    );
}

#[test]
fn a_macro_stream_written_under_tabs_lands_at_the_columns_they_spell() {
    const SOURCE: &[u8] =
        b"fn f() {\n    assert!(matches!(\n\t\terr,\n\t\tE::C(ref id) if id == \"n\"\n\t));\n}\n";

    const WANTED: &[u8] = b"fn f() {\n    assert!(matches!(\n        err,\n        E::C(ref id) if id == \"n\"\n    ));\n}\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(WANTED)
    );
}

#[test]
fn an_operator_of_two_characters_opens_a_continuation_the_way_one_of_one_does() {
    const SOURCE: &[u8] = b"fn g(current_version: V, stored_version: V) -> bool {\n    current_version.major_number_value == stored_version.major_number_value\n        && current_version.minor_number_value == stored_version.minor_number_value\n}\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(SOURCE)
    );
}

#[test]
fn an_await_ends_the_operand_the_dot_past_it_reads_from() {
    const SOURCE: &[u8] = b"async fn f(response: R) -> Result<(), E> {\n    Err(response.into_err().await.into())\n}\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(SOURCE)
    );
}

#[test]
fn a_sign_opening_a_line_carries_on_the_value_the_line_above_left() {
    const SOURCE: &[u8] = b"fn g() -> i32 {\n    let shift = a_significand_value_named_at_length.leading_zeros() as i32\n        - (implicit_bit_value_named_at_length << 3u32).leading_zeros() as i32;\n    shift\n}\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(SOURCE)
    );
}

#[test]
fn a_supertrait_list_stands_one_level_under_the_colon_that_opens_it() {
    const SOURCE: &[u8] = b"pub trait Float:\n    Copy + PartialEq + PartialOrd + core::fmt::Debug + core::marker::Send + core::marker::Sync\n{\n}\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(SOURCE)
    );
}

#[test]
fn a_macro_bracket_answers_to_the_width_a_call_answers_to() {
    const SOURCE: &[u8] = b"fn v() {\n    let vec = vec![\n        Some(Box::new(42)),\n        Some(Box::new(24)),\n        None,\n        Some(Box::new(12)),\n    ];\n}\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(SOURCE)
    );
}

#[test]
fn a_generic_list_the_source_parted_writes_its_elements_one_level_in() {
    const SOURCE: &[u8] = b"pub struct PeekMutHolder<\n    'a,\n    T,\n    #[unstable(feature = \"allocator_api\", issue = \"32838\")] A: Allocator + Clone = Global,\n> {\n    vec: &'a mut Vec<T, A>,\n}\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(SOURCE)
    );
}

#[test]
fn a_declarative_macro_definition_writes_its_arms_from_the_source() {
    const SOURCE: &[u8] = b"pub macro wrap {\n    ($expr:expr) => {\n        builtin # wrap ( $expr )\n    },\n    ($expr:expr ; $ty:ty) => {\n        builtin # wrap ( $expr, $ty )\n    },\n}\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(SOURCE)
    );
}

#[test]
fn a_brace_holding_a_block_remark_alone_takes_the_blank_the_body_owes() {
    const SOURCE: &[u8] = b"fn h() {\n    match v {\n        Ok(_) => { /* fine */ }\n        Err(_) => { /* held */ }\n    }\n}\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(SOURCE)
    );
}

#[test]
fn a_filled_list_leaves_the_line_the_separator_its_last_element_owes() {
    const SOURCE: &[u8] = b"use crate::held::{\n    aaaaaaaaaaaa, bbbbbbbbbbbb, cccccccccccc, dddddddddddd, eeeeeeeeeeee,\n    fffffffffffff, gggggggggggg,\n};\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(SOURCE)
    );
}

#[test]
fn a_match_arm_guard_on_a_line_of_its_own_stands_under_the_pattern() {
    const SOURCE: &[u8] = b"fn h() {\n    match v {\n        Aaa(b)\n            if c(b) =>\n        {\n            d(b);\n        }\n        _ => {}\n    }\n}\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(SOURCE)
    );
}

#[test]
fn a_declarative_macro_matcher_and_its_repeated_body_come_from_the_source() {
    const SOURCE: &[u8] = b"macro cfg_held(\n    $(#[cfg($c:meta)] $o:item)*\n    #[else] $f:item\n) {\n    $(#[cfg($c)] $o)*\n    #[cfg(not(any($($c),*)))] $f\n}\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(SOURCE)
    );
}

#[test]
fn a_body_brace_opening_a_line_stands_at_the_statements_own_level() {
    const SOURCE: &[u8] = b"fn f() {\n    if a {\n        b();\n    } else\n    /* c */\n    {\n        d();\n    }\n}\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(SOURCE)
    );
}

#[test]
fn a_self_import_carrying_an_alias_still_sorts_ahead_of_a_name() {
    const SOURCE: &[u8] = b"use p::{self as pm2, Span};\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(SOURCE)
    );
}

#[test]
fn a_reference_closes_up_against_the_lifetime_it_carries() {
    const SOURCE: &[u8] = b"struct Bar<'a>(#[allow(unused)] &'a Foo);\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(SOURCE)
    );
}

#[test]
fn a_continuation_inside_a_bracket_the_run_opened_takes_that_brackets_level() {
    const SOURCE: &[u8] = b"fn f() {\n    let held = one\n        + two * (three_value_name_here\n            + four * (five_value_name_here + six_value_name_here + seven_value_name));\n}\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(SOURCE)
    );
}

#[test]
fn a_remark_standing_at_a_closing_braces_column_takes_that_braces_level() {
    const SOURCE: &[u8] = b"fn f(a: u32) -> u32 {\n    if a > 2 {\n        one();\n        two();\n    // a remark\n    } else {\n        three();\n    }\n    a\n}\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(SOURCE)
    );
}

#[test]
fn a_chain_link_past_a_receiver_closing_on_its_own_quote_stands_level_with_it() {
    const SOURCE: &[u8] = b"fn f() -> String {\n    let held = \"\none\ntwo\n    \"\n        .trim()\n        .to_string();\n    held\n}\n";
    const WANTED: &[u8] = b"fn f() -> String {\n    let held = \"\none\ntwo\n    \"\n    .trim()\n    .to_string();\n    held\n}\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(WANTED)
    );
}

#[test]
fn an_arm_guard_is_the_base_the_operators_under_it_step_from() {
    const SOURCE: &[u8] = b"fn f(held: Held) -> bool {\n    match held {\n        Held::Metadata(meta)\n            if meta.first_named_reading().is_file() && meta.second_named_reading() > 0\n                || meta.first_named_reading().is_block_device() =>\n        {\n            true\n        }\n        _ => false,\n    }\n}\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(SOURCE)
    );
}

#[test]
fn a_chain_link_past_a_receiver_closing_past_its_own_text_steps_from_it() {
    const SOURCE: &[u8] = b"fn f() -> String {\n    let held = \"\none\ntwo held\"\n        .trim()\n        .to_string();\n    held\n}\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(SOURCE)
    );
}

#[test]
fn a_macro_matchers_remark_keeps_the_column_the_source_gave_it() {
    const SOURCE: &[u8] = b"macro_rules! held {\n    (\n        $one:ident, // first\n        $two:ident,   // second\n        $three:ident, // third\n    ) => {};\n}\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(SOURCE)
    );
}

#[test]
fn an_arrow_inside_a_bracket_that_is_no_brace_carries_no_continuation() {
    const SOURCE: &[u8] = b"fn f() {\n    held!(\n        check,\n        (\n            one: u8 = a,\n        ) =>\n        wanted(one)\n    );\n}\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(SOURCE)
    );
}

#[test]
fn a_bracket_the_layout_parts_takes_a_level_inside_one_that_hugs() {
    const SOURCE: &[u8] = b"fn f() {\n    if (a > 0\n        && held(\n            one_argument_value_here,\n            two_argument_value_here,\n            three_argument_value,\n        ) == b)\n        || c\n    {\n        run();\n    }\n}\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(SOURCE)
    );
}

#[test]
fn a_macro_body_holding_a_builtin_prefix_is_written_from_the_source() {
    const SOURCE: &[u8] = b"pub macro deref($pat:pat) {\n    builtin # deref($pat)\n}\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(SOURCE)
    );
}

#[test]
fn a_tighter_operator_opening_a_line_steps_in_from_the_looser_one_above() {
    const SOURCE: &[u8] =
        b"fn f() -> bool {\n    alpha_one_two_three_four(one)\n        && beta_four_five_six_seven(two)\n            != gamma_seven_eight_nine(three)\n}\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(SOURCE)
    );
}

#[test]
fn a_brace_standing_against_a_body_brace_takes_no_blank() {
    const SOURCE: &[u8] = b"pub macro held() {{ core::held::run() }}\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(SOURCE)
    );
}

#[test]
fn an_attributes_own_close_ends_no_operand() {
    const SOURCE: &[u8] = b"fn f() {\n    held(\n        #[cold]\n        || {\n            run();\n        },\n    );\n}\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(SOURCE)
    );
}

#[test]
fn a_pattern_alternative_inside_a_bracket_keeps_the_arms_own_level() {
    const SOURCE: &[u8] = b"fn f(v: E) -> u32 {\n    match v {\n        E::Let(\n            One(_, extracted_value)\n            | Two(_, _, extracted_value)\n            | Three(_, _, extracted_value),\n        ) => extracted_value,\n        _ => 0,\n    }\n}\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(SOURCE)
    );
}

#[test]
fn a_macro_definitions_body_brace_takes_the_blank_the_source_wrote() {
    const SOURCE: &[u8] =
        b"macro_rules! held{\n    ($t:ident) => {\n        struct $t;\n    };\n}\n";

    const WANTED: &[u8] =
        b"macro_rules! held {\n    ($t:ident) => {\n        struct $t;\n    };\n}\n";

    let mut first = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(first.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(WANTED)
    );
}

#[test]
fn a_type_parameter_list_nested_inside_another_steps_again() {
    const SOURCE: &[u8] = b"fn f() {\n    let _x: HeldOuterTypeNameThatIsVeryLongIndeed<\n        AlphaTypeNameThatIsAlsoQuiteLong,\n        InnerHeldTypeNameThatIsLong<\n        BetaTypeNameThatIsAlsoQuiteLong,\n        GammaTypeNameThatIsAlsoQuiteLong,\n    >,\n    > = held();\n}\n";
    const WANTED: &[u8] = b"fn f() {\n    let _x: HeldOuterTypeNameThatIsVeryLongIndeed<\n        AlphaTypeNameThatIsAlsoQuiteLong,\n        InnerHeldTypeNameThatIsLong<\n            BetaTypeNameThatIsAlsoQuiteLong,\n            GammaTypeNameThatIsAlsoQuiteLong,\n        >,\n    > = held();\n}\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(WANTED)
    );
}

#[test]
fn a_chain_a_closure_opens_steps_from_the_link_that_opened_it() {
    const SOURCE: &[u8] = b"fn f() {\n    let held = Some(format!(\n        \"{} \",\n        self.decorations_and_more_of_them\n            .iter()\n            .map(|d| d\n            .generate_the_decoration_for_this_line(line_number, true, self)\n            .text_of_the_generated_thing)\n            .collect::<Vec<String>>()\n            .join(\" \")\n    ));\n}\n";
    const WANTED: &[u8] = b"fn f() {\n    let held = Some(format!(\n        \"{} \",\n        self.decorations_and_more_of_them\n            .iter()\n            .map(|d| d\n                .generate_the_decoration_for_this_line(line_number, true, self)\n                .text_of_the_generated_thing)\n            .collect::<Vec<String>>()\n            .join(\" \")\n    ));\n}\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(WANTED)
    );
}

#[test]
fn a_chain_past_a_literal_spelling_its_own_lines_stands_level_with_it() {
    const SOURCE: &[u8] = b"fn f() -> Result<u8, String> {\n    if a {\n        Ok(1)\n    } else {\n        Err(\"\\n\\n\\\n             couldn't determine visual studio generator\\n\\\n             if VisualStudio is installed, however, consider \\\n             running the appropriate vcvars script before building \\\n             this crate\\n\\\n             \"\n            .to_string())\n    }\n}\n";
    const WANTED: &[u8] = b"fn f() -> Result<u8, String> {\n    if a {\n        Ok(1)\n    } else {\n        Err(\"\\n\\n\\\n             couldn't determine visual studio generator\\n\\\n             if VisualStudio is installed, however, consider \\\n             running the appropriate vcvars script before building \\\n             this crate\\n\\\n             \"\n        .to_string())\n    }\n}\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(WANTED)
    );
}

#[test]
fn a_jump_ending_a_block_laid_over_lines_takes_the_separator_the_reference_writes() {
    const SOURCE: &[u8] = b"fn f() -> bool {\n    if a {\n        return false\n    }\n    loop {\n        break\n    }\n    true\n}\n";
    const WANTED: &[u8] = b"fn f() -> bool {\n    if a {\n        return false;\n    }\n    loop {\n        break;\n    }\n    true\n}\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(WANTED)
    );
}

#[test]
fn a_jump_ending_a_block_standing_on_one_line_takes_no_separator() {
    const SOURCE: &[u8] = b"fn f(a: bool) -> u32 {\n    if a { return 1 } else { return 2 }\n}\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(SOURCE)
    );
}

#[test]
fn a_braced_macro_body_moves_to_the_column_the_emitter_stands_at() {
    const SOURCE: &[u8] = b"fn f() {\n    held! {\n\t\t\tlet a = 1;\n\t\t}\n}\n";
    const WANTED: &[u8] = b"fn f() {\n    held! {\n        let a = 1;\n    }\n}\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(WANTED)
    );
}

#[test]
fn a_macro_definition_holding_a_repetition_keeps_the_lines_the_source_wrote() {
    const SOURCE: &[u8] = b"macro_rules! held {\n  ($($a:expr),+) => {\n     f($($a),+)\n  };\n}\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(SOURCE)
    );
}

#[test]
fn a_header_the_source_parted_comes_back_whole_where_it_fits() {
    const SOURCE: &[u8] =
        b"fn f() {\n    if aaa(x)\n        && bbb(y)\n    {\n        g();\n    }\n}\n";

    const WANTED: &[u8] = b"fn f() {\n    if aaa(x) && bbb(y) {\n        g();\n    }\n}\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(WANTED)
    );
}

#[test]
fn a_let_chain_keeps_the_lines_the_source_parted_it_on() {
    const SOURCE: &[u8] = b"fn f() {\n    if let Some(c) = d()\n        && c.is_ok()\n    {\n        g();\n    }\n}\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(SOURCE)
    );
}

#[test]
fn a_let_binding_past_the_single_line_else_width_lays_its_else_block_over_lines() {
    const SOURCE: &[u8] = b"fn f() {\n    let Some(aaaaaaaaaaaaaaaaa) = q() else { return };\n    let Some(aaaaaaaaaaaaaaaaaa) = q() else { return };\n}\n";
    const WANTED: &[u8] = b"fn f() {\n    let Some(aaaaaaaaaaaaaaaaa) = q() else { return };\n    let Some(aaaaaaaaaaaaaaaaaa) = q() else {\n        return;\n    };\n}\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(WANTED)
    );
}

#[test]
fn an_else_a_branch_opens_is_no_let_binding_however_wide_the_statement_runs() {
    const SOURCE: &[u8] =
        b"fn f() {\n    let prefix = if self.has_fields { \", \" } else { \" { \" };\n}\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(SOURCE)
    );
}

#[test]
fn a_match_arm_body_of_one_expression_loses_the_braces_around_it() {
    const SOURCE: &[u8] = b"fn f() {\n    match x {\n        X => {\n            g(a)\n        }\n        Y => {}\n    }\n}\n";

    const WANTED: &[u8] =
        b"fn f() {\n    match x {\n        X => g(a),\n        Y => {}\n    }\n}\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(WANTED)
    );
}

#[test]
fn a_match_arm_body_that_carries_a_statement_keeps_its_braces() {
    const SOURCE: &[u8] = b"fn f() {\n    match x {\n        X => {\n            g(a);\n        }\n        Y => {}\n    }\n}\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(SOURCE)
    );
}

#[test]
fn a_chain_past_its_width_parts_the_block_brace_it_stands_under() {
    const SOURCE: &[u8] = b"impl A {\n    fn f(&mut self, index: usize) -> &mut K {\n        unsafe { holder.as_leaf_mut().keys.as_mut_slice().get_unchecked_mut(index) }\n    }\n}\n";
    const WANTED: &[u8] = b"impl A {\n    fn f(&mut self, index: usize) -> &mut K {\n        unsafe {\n            holder\n                .as_leaf_mut()\n                .keys\n                .as_mut_slice()\n                .get_unchecked_mut(index)\n        }\n    }\n}\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(WANTED)
    );
}

#[test]
fn a_value_a_remark_stands_ahead_of_is_written_from_the_source() {
    const SOURCE: &[u8] = b"fn f() {\n    let held =\n        // a remark the reference keeps where the source put it\n        one.two().three().four().five().six().seven().eight().nine().ten();\n}\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(SOURCE)
    );
}

#[test]
fn a_call_past_its_width_parts_at_the_innermost_bracket_its_sole_argument_opens() {
    const SOURCE: &[u8] = b"impl A {\n    fn f() -> Res {\n        Err(io::const_error!(io::ErrorKind::Unsupported, \"unavailable on the platform\"))\n    }\n}\n";
    const WANTED: &[u8] = b"impl A {\n    fn f() -> Res {\n        Err(io::const_error!(\n            io::ErrorKind::Unsupported,\n            \"unavailable on the platform\"\n        ))\n    }\n}\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(WANTED)
    );
}

#[test]
fn a_closure_standing_as_a_calls_sole_argument_opens_no_bracket_the_width_parts() {
    const SOURCE: &[u8] =
        b"fn f(b: &mut B) {\n    b.iter(|| assert_eq!(2, set.matches(SEARCHED_FOR_TEXT).iter().count()));\n}\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(SOURCE)
    );
}

#[test]
fn a_closure_body_of_one_expression_loses_the_block_around_it() {
    const SOURCE: &[u8] = b"fn f() {\n    let h = q.map(|v| {\n        g(v)\n    });\n}\n";
    const WANTED: &[u8] = b"fn f() {\n    let h = q.map(|v| g(v));\n}\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(WANTED)
    );
}

#[test]
fn a_closure_written_inside_a_macro_keeps_the_block_the_source_gave_it() {
    const SOURCE: &[u8] = b"fn f() {\n    assert!(e.any(|v| {\n        g(v)\n    }));\n}\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(SOURCE)
    );
}

#[test]
fn a_bracket_holding_one_chain_parts_where_its_callee_is_no_shorter_than_the_indent() {
    const SOURCE: &[u8] = b"fn f() {\n    assert!(result.err().unwrap().to_string().contains(\"aaaaaaaaaaaaaaa\"));\n    qqq(result.err().unwrap().to_string().contains(\"aaaaaaaaaaaaaaa\"));\n}\n";
    const WANTED: &[u8] = b"fn f() {\n    assert!(\n        result\n            .err()\n            .unwrap()\n            .to_string()\n            .contains(\"aaaaaaaaaaaaaaa\")\n    );\n    qqq(result\n        .err()\n        .unwrap()\n        .to_string()\n        .contains(\"aaaaaaaaaaaaaaa\"));\n}\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(WANTED)
    );
}

#[test]
fn a_value_the_equals_line_cannot_hold_moves_whole_to_the_line_under_it() {
    const SOURCE: &[u8] = b"fn f() {\n    let held = aaaaaaaaaaaaa + aaaaaaaaaaaaa + aaaaaaaaaaaaa + aaaaaaaaaaaaa + aaaaaaaaaaaaa;\n}\n";
    const WANTED: &[u8] = b"fn f() {\n    let held =\n        aaaaaaaaaaaaa + aaaaaaaaaaaaa + aaaaaaaaaaaaa + aaaaaaaaaaaaa + aaaaaaaaaaaaa;\n}\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(WANTED)
    );
}

#[test]
fn a_branch_the_source_parted_comes_back_whole_where_it_spells_fifty_columns() {
    const SOURCE: &[u8] = b"fn f() -> u8 {\n    let held = if wide {\n        a\n    } else {\n        b\n    };\n}\n";
    const WANTED: &[u8] = b"fn f() -> u8 {\n    let held = if wide { a } else { b };\n}\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(WANTED)
    );
}

#[test]
fn a_branch_standing_alone_in_a_match_arm_block_keeps_its_lines() {
    const SOURCE: &[u8] = b"fn f() -> u8 {\n    match x {\n        Err(root) => {\n            if len > 0 {\n                Ok(None)\n            } else {\n                Err(root)\n            }\n        }\n    }\n}\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(SOURCE)
    );
}

#[test]
fn a_match_arm_body_the_layout_parts_still_writes_its_head_on_the_arrow_line() {
    const SOURCE: &[u8] = b"fn f() {\n    match x {\n        Some(v) => {\n            Ok(Held {\n                value_of_the_thing: v,\n                mark: 1,\n            })\n        }\n        Y => {}\n    }\n}\n";
    const WANTED: &[u8] = b"fn f() {\n    match x {\n        Some(v) => Ok(Held {\n            value_of_the_thing: v,\n            mark: 1,\n        }),\n        Y => {}\n    }\n}\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(WANTED)
    );
}

#[test]
fn a_line_opening_on_a_body_brace_stands_at_the_headers_own_level() {
    const SOURCE: &[u8] = b"pub trait Int:\n    Sized\n    + Clone\n    + CastInto<i16>\n{\n    const ZERO: Self;\n}\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(SOURCE)
    );
}

#[test]
fn a_definition_header_carries_on_past_the_word_its_own_trait_stands_before() {
    const SOURCE: &[u8] = b"impl<'a, P: Pattern<Searcher<'a>: DoubleEndedSearcher<'a>>> DoubleEndedIterator\n    for SplitInclusive<'a, P>\n{\n    fn f() {}\n}\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(SOURCE)
    );
}

#[test]
fn a_use_tree_wider_than_the_line_it_answers_to_is_laid_over_lines() {
    const SOURCE: &[u8] = b"use crate::io::{self, Write, aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa};\n";
    const WANTED: &[u8] = b"use crate::io::{\n    self, Write,\n    aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa,\n};\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(WANTED)
    );
}

#[test]
fn a_closure_body_laid_over_lines_takes_the_block_the_reference_writes() {
    const SOURCE: &[u8] = b"fn f(b: &mut B) {\n    b.iter(|| CHARS.iter().cycle().take(10_000).map(|c| black_box(c).to_digit(2)).min())\n}\n";
    const WANTED: &[u8] = b"fn f(b: &mut B) {\n    b.iter(|| {\n        CHARS\n            .iter()\n            .cycle()\n            .take(10_000)\n            .map(|c| black_box(c).to_digit(2))\n            .min()\n    })\n}\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(WANTED)
    );
}

#[test]
fn a_closure_body_of_one_link_answers_to_the_line_and_takes_no_block() {
    const SOURCE: &[u8] =
        b"fn f() {\n    held(|mem| mem.with_metadata_of(ptr::from_ref(for_value) as *const Inner<T>));\n}\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(SOURCE)
    );
}

#[test]
fn a_chain_of_one_link_the_source_parted_comes_back_whole() {
    const SOURCE: &[u8] =
        b"fn f() {\n    writeln!(out, \"a line of prose\")\n        .unwrap();\n}\n";

    const WANTED: &[u8] = b"fn f() {\n    writeln!(out, \"a line of prose\").unwrap();\n}\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(WANTED)
    );
}

#[test]
fn a_chain_of_two_links_past_the_chain_width_keeps_the_lines_it_was_given() {
    const SOURCE: &[u8] = b"fn f() {\n    held\n        .with_a_name_of_its_own(alpha)\n        .and_another_name_here(bravo);\n}\n";
    const WANTED: &[u8] = b"fn f() {\n    held.with_a_name_of_its_own(alpha)\n        .and_another_name_here(bravo);\n}\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(WANTED)
    );
}

#[test]
fn a_header_that_fits_without_its_brace_joins_and_leaves_the_brace_alone() {
    const SOURCE: &[u8] = b"fn f() {\n    if aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa(x)\n        && bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb(y)\n    {\n        g();\n    }\n}\n";
    const WANTED: &[u8] = b"fn f() {\n    if aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa(x) && bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb(y)\n    {\n        g();\n    }\n}\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(WANTED)
    );
}

#[test]
fn an_enum_variants_own_brace_answers_to_a_wider_bound_than_a_literal_does() {
    const SOURCE: &[u8] = b"pub enum E {\n    Unknown { cmsg_level: i32, cmsg_type: i32 },\n}\n\nfn f() {\n    let held = Held { cmsg_level: 1, cmsg_type: 2 };\n}\n";
    const WANTED: &[u8] = b"pub enum E {\n    Unknown { cmsg_level: i32, cmsg_type: i32 },\n}\n\nfn f() {\n    let held = Held {\n        cmsg_level: 1,\n        cmsg_type: 2,\n    };\n}\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(WANTED)
    );
}

#[test]
fn a_parameter_list_the_source_parted_joins_where_the_signature_fits() {
    const SOURCE: &[u8] = b"trait T {\n    fn held<F>(\n        &self,\n        alpha: &[u8],\n        beta: usize,\n    ) -> Result<(), Self::Error>\n    where\n        F: FnMut(u8) -> bool,\n    {\n        g();\n    }\n}\n";
    const WANTED: &[u8] = b"trait T {\n    fn held<F>(&self, alpha: &[u8], beta: usize) -> Result<(), Self::Error>\n    where\n        F: FnMut(u8) -> bool,\n    {\n        g();\n    }\n}\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(WANTED)
    );
}

#[test]
fn a_list_holding_a_block_remark_is_still_a_list_the_layout_parts() {
    const SOURCE: &[u8] = b"fn f() {\n    panic_nounwind_fmt(fmt::Arguments::from_str(expr), /* force_no_backtrace */ false);\n}\n";
    const WANTED: &[u8] = b"fn f() {\n    panic_nounwind_fmt(\n        fmt::Arguments::from_str(expr),\n        /* force_no_backtrace */ false,\n    );\n}\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(WANTED)
    );
}

#[test]
fn a_definition_whose_generics_stand_over_lines_parts_its_parameters_too() {
    const SOURCE: &[u8] = b"pub unsafe fn held<\n    T: CopyAndCloneAndSendAndSync,\n    const ORDERING: AtomicOrderingKindHeld,\n>(dst: *mut T, old: T, src: T) -> (T, bool);\n";
    const WANTED: &[u8] = b"pub unsafe fn held<\n    T: CopyAndCloneAndSendAndSync,\n    const ORDERING: AtomicOrderingKindHeld,\n>(\n    dst: *mut T,\n    old: T,\n    src: T,\n) -> (T, bool);\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(WANTED)
    );
}

#[test]
fn a_block_value_the_source_parted_comes_back_on_one_line() {
    const SOURCE: &[u8] =
        b"fn f() {\n    let held = unsafe {\n        gethostname(buf, maxlen)\n    };\n}\n";

    const WANTED: &[u8] = b"fn f() {\n    let held = unsafe { gethostname(buf, maxlen) };\n}\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(WANTED)
    );
}

#[test]
fn a_block_value_carrying_an_attribute_keeps_its_braces() {
    const SOURCE: &[u8] =
        b"fn f() {\n    #[cfg(unix)]\n    unsafe {\n        gethostname(buf, maxlen)\n    }\n}\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(SOURCE)
    );
}

#[test]
fn a_struct_field_holding_a_lifetime_still_carries_its_own_remark_column() {
    const SOURCE: &[u8] = b"pub struct C<'a> {\n    pub ip: *const u8, // one\n    pub start: &'a dyn Fn(u8), // two\n}\n";
    const WANTED: &[u8] = b"pub struct C<'a> {\n    pub ip: *const u8,         // one\n    pub start: &'a dyn Fn(u8), // two\n}\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(WANTED)
    );
}

#[test]
fn a_match_arm_ending_on_its_own_body_brace_takes_the_remark_column_too() {
    const SOURCE: &[u8] = b"fn f() {\n    match a {\n        Ok(_) => {} // one\n        Err(n) if n == addr => {} // two\n        _ => panic!(\"held\"),\n    }\n}\n";
    const WANTED: &[u8] = b"fn f() {\n    match a {\n        Ok(_) => {}               // one\n        Err(n) if n == addr => {} // two\n        _ => panic!(\"held\"),\n    }\n}\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(WANTED)
    );
}

#[test]
fn a_tuple_of_one_element_keeps_the_comma_that_makes_it_one() {
    const SOURCE: &[u8] = b"trait X {\n    fn held<I: IntoIterator<Item = (T,)>>(&mut self, iter: I) {\n        g();\n    }\n}\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(SOURCE)
    );
}
