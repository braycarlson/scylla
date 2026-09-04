#[path = "common/corpus.rs"]
mod corpus;
#[path = "common/floor.rs"]
mod floor;

use std::fs;
use std::path::PathBuf;

use scylla::bounded::{BoundedVec, Buffer, Span};
use scylla::format::print::Options;
use scylla::format::python::{Formatter, Input, Outcome, QuotePreference};
use scylla::language::Lexer as _;
use scylla::lex::PYTHON;
use scylla::lines;
use scylla::suppress::Pragmas;
use scylla::syntax::python::classify::classify;
use scylla::syntax::python::kind::PythonKind;
use scylla::syntax::python::parse;
use scylla::syntax::python::style::LineEnding;
use scylla::token::{TokenKind, Tokens};
use scylla::tree::{Events, Structure, Tree};

const ARENA_BYTES_MAX: u32 = 1 << 22;
const ELEMENT_COUNT_MAX: u32 = 1 << 18;
const ERROR_COUNT_MAX: u32 = 1 << 12;
const EVENT_COUNT_MAX: u32 = 1 << 20;
const NODE_COUNT_MAX: u32 = 1 << 18;
const TOKEN_COUNT_MAX: u32 = 1 << 18;

struct Held {
    events: Events<PythonKind>,
    formatter: Formatter,
    index: lines::Index,
    lexed: Tokens,
    pragmas: Pragmas,
    raw: BoundedVec<PythonKind>,
    tokens: Tokens,
    tree: Tree<PythonKind>,
}

impl Held {
    fn reserve() -> Self {
        Self {
            events: Events::reserve(EVENT_COUNT_MAX),
            formatter: Formatter::reserve(ELEMENT_COUNT_MAX, ARENA_BYTES_MAX),
            index: lines::Index::reserve(1 << 14),
            lexed: Tokens::reserve(TOKEN_COUNT_MAX),
            pragmas: Pragmas::reserve(1 << 10),
            raw: BoundedVec::reserve(TOKEN_COUNT_MAX),
            tokens: Tokens::reserve(TOKEN_COUNT_MAX),
            tree: Tree::reserve(NODE_COUNT_MAX, ERROR_COUNT_MAX),
        }
    }

    fn format(&mut self, source: &[u8], out: &mut Buffer) -> Outcome {
        self.lexed.clear();
        self.raw.clear();
        self.tokens.clear();

        PYTHON.lex(source, &mut self.lexed);

        if !self.index.build(source) {
            return Outcome::Overflow;
        }

        let comments: Vec<Span> = self
            .lexed
            .as_slice()
            .iter()
            .filter(|token| token.kind == TokenKind::Comment)
            .map(scylla::token::Token::span)
            .collect();

        self.pragmas
            .scan(source, comments.iter().copied(), &self.index);

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
            line_ending: LineEnding::LineFeed,
            magic_trailing_comma: true,
            options: Options::DEFAULT,
            outcome,
            pragmas: self.pragmas.as_slice(),
            quote: QuotePreference::Double,
            raw: &self.raw,
            source,
            tokens: self.tokens.as_slice(),
            tree: &self.tree,
        };

        self.formatter.format(&input, out)
    }

    fn words(&mut self, source: &[u8]) -> Vec<String> {
        self.lexed.clear();
        PYTHON.lex(source, &mut self.lexed);

        let held: Vec<String> = self
            .lexed
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

                let text = String::from_utf8_lossy(token.text(source)).into_owned();

                if token.kind == TokenKind::Number {
                    return number(&text);
                }

                text
            })
            .collect::<Vec<String>>();

        let mut found: Vec<String> = Vec::with_capacity(held.len());

        for (index, word) in held.iter().enumerate() {
            let trailing = word == ","
                && held
                    .get(index + 1)
                    .is_some_and(|next| matches!(next.as_str(), ")" | "]" | "}"));

            if trailing || word == "(" || word == ")" || word == ";" {
                continue;
            }

            if word == "<string>" && found.last().is_some_and(|last| last == "<string>") {
                continue;
            }

            let leaning = found.last().is_some_and(|last| last == ".")
                && word.starts_with(|first: char| first.is_ascii_digit());

            if leaning {
                found.pop();
                found.push(number(&format!(".{word}")));

                continue;
            }

            found.push(word.clone());
        }

        found
    }

    fn kinds(&mut self, source: &[u8]) -> Vec<PythonKind> {
        self.lexed.clear();
        self.raw.clear();
        self.tokens.clear();

        PYTHON.lex(source, &mut self.lexed);

        assert!(classify(
            source,
            self.lexed.as_slice(),
            &mut self.tokens,
            &mut self.raw
        ));

        self.raw
            .iter()
            .copied()
            .filter(|kind| {
                !matches!(
                    kind,
                    PythonKind::Comment
                        | PythonKind::Dedent
                        | PythonKind::Indent
                        | PythonKind::Newline
                )
            })
            .collect()
    }

    fn comments(&mut self, source: &[u8]) -> Vec<Vec<u8>> {
        self.lexed.clear();
        self.raw.clear();
        self.tokens.clear();

        PYTHON.lex(source, &mut self.lexed);

        assert!(classify(
            source,
            self.lexed.as_slice(),
            &mut self.tokens,
            &mut self.raw
        ));

        self.raw
            .iter()
            .enumerate()
            .filter(|(_, kind)| **kind == PythonKind::Comment)
            .map(|(index, _)| {
                let text = source[self.tokens.as_slice()[index].span().range()].trim_ascii_end();

                remark(text)
            })
            .collect()
    }
}

fn number(text: &str) -> String {
    let held = text.to_lowercase();

    let Some(at) = held.find('.') else {
        return held;
    };

    let (before, rest) = held.split_at(at);
    let after = rest.strip_prefix('.').unwrap_or_default();
    let leading = if before.is_empty() { "0" } else { before };
    let trailing = if after.is_empty() { "0" } else { after };

    format!("{leading}.{trailing}")
}

fn remark(text: &[u8]) -> Vec<u8> {
    let mut held = text.to_vec();

    if held.starts_with(b"# ") {
        held.remove(1);
    }

    held
}

fn first_difference(left: &[u8], right: &[u8]) -> Option<(usize, String, String)> {
    let first: Vec<&[u8]> = left.split(|byte| *byte == b'\n').collect();
    let second: Vec<&[u8]> = right.split(|byte| *byte == b'\n').collect();

    for index in 0..first.len().max(second.len()) {
        let held = first.get(index).copied().unwrap_or_default();
        let other = second.get(index).copied().unwrap_or_default();

        if held != other {
            return Some((
                index + 1,
                String::from_utf8_lossy(held).into_owned(),
                String::from_utf8_lossy(other).into_owned(),
            ));
        }
    }

    None
}

fn strung(kind: PythonKind) -> bool {
    matches!(
        kind,
        PythonKind::FStringEnd
            | PythonKind::FStringMiddle
            | PythonKind::FStringStart
            | PythonKind::StringBytes
            | PythonKind::StringFormat
            | PythonKind::StringPlain
    )
}

fn collapsed(kinds: &[PythonKind]) -> Vec<PythonKind> {
    let mut found: Vec<PythonKind> = Vec::with_capacity(kinds.len());

    for kind in kinds {
        if !strung(*kind) {
            found.push(*kind);

            continue;
        }

        if found.last().copied().is_some_and(strung) {
            continue;
        }

        found.push(PythonKind::StringPlain);
    }

    found
}

fn preserved(source: &[PythonKind], printed: &[PythonKind]) -> bool {
    let before = collapsed(source);
    let after = collapsed(printed);
    let mut held = 0;

    for kind in &after {
        while held < before.len()
            && before[held] != *kind
            && matches!(
                before[held],
                PythonKind::ParenClose | PythonKind::ParenOpen | PythonKind::Semicolon
            )
        {
            held += 1;
        }

        if held < before.len() && before[held] == *kind {
            held += 1;

            continue;
        }

        if !matches!(
            *kind,
            PythonKind::Comma | PythonKind::ParenClose | PythonKind::ParenOpen
        ) {
            return false;
        }
    }

    while held < before.len()
        && matches!(
            before[held],
            PythonKind::ParenClose | PythonKind::ParenOpen | PythonKind::Semicolon
        )
    {
        held += 1;
    }

    held == before.len()
}

fn fixtures() -> Vec<(PathBuf, Vec<u8>)> {
    let root = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/python");
    let mut found = Vec::new();

    for entry in fs::read_dir(&root).expect("the fixture directory is readable") {
        let path = entry.expect("the entry is readable").path();

        if path.extension().is_none_or(|extension| extension != "py") {
            continue;
        }

        let source = fs::read(&path).expect("the fixture is readable");

        found.push((path, source));
    }

    found.sort_by(|left, right| left.0.cmp(&right.0));

    assert!(found.len() > 8);

    found
}

#[test]
fn formatting_formatted_output_changes_nothing() {
    let mut first = Buffer::reserve(ARENA_BYTES_MAX);
    let mut held = Held::reserve();
    let mut second = Buffer::reserve(ARENA_BYTES_MAX);

    for (path, source) in fixtures() {
        assert_eq!(
            held.format(&source, &mut first),
            Outcome::Complete,
            "{}",
            path.display()
        );

        let once = first.as_bytes().to_vec();

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

#[test]
fn a_one_element_tuple_holding_a_broken_collection_gets_one_comma() {
    let source: &[u8] = b"a = (\n    (\n        None,\n        1,\n    ),\n)\n";
    let mut held = Held::reserve();
    let mut out = Buffer::reserve(ARENA_BYTES_MAX);

    assert_eq!(held.format(source, &mut out), Outcome::Complete);
    assert!(!String::from_utf8_lossy(out.as_bytes()).contains(",,"));
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(source)
    );
}

#[test]
fn an_empty_collection_ending_a_call_is_no_magic_trailing_comma() {
    let source: &[u8] = b"self.assertEqual(Child.check(), [])
";
    let mut held = Held::reserve();
    let mut out = Buffer::reserve(ARENA_BYTES_MAX);

    assert_eq!(held.format(source, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(source)
    );
}

#[test]
fn a_comment_after_the_trailing_comma_keeps_the_comma_before_it() {
    let source: &[u8] = b"from a import (\n    b,\n    c,  # note\n)\n";
    let mut held = Held::reserve();
    let mut out = Buffer::reserve(ARENA_BYTES_MAX);

    assert_eq!(held.format(source, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(source)
    );
}

#[test]
fn a_comment_on_a_line_of_its_own_keeps_that_line() {
    let source: &[u8] = b"x = [\n    1,\n    2,\n    # note\n]\n";
    let mut held = Held::reserve();
    let mut out = Buffer::reserve(ARENA_BYTES_MAX);

    assert_eq!(held.format(source, &mut out), Outcome::Complete);

    let once = String::from_utf8_lossy(out.as_bytes()).into_owned();

    assert!(once.contains("2,\n"), "{once}");
    assert!(once.contains("# note\n]"), "{once}");
}

#[test]
fn a_one_line_suite_holding_a_semicolon_stays_on_its_line() {
    let source: &[u8] = b"def f(t):\n    if t: a = 1; b = 2\n    else: a = 3; b = 4\n";
    let mut held = Held::reserve();
    let mut first = Buffer::reserve(ARENA_BYTES_MAX);
    let mut second = Buffer::reserve(ARENA_BYTES_MAX);

    assert_eq!(held.format(source, &mut first), Outcome::Complete);

    let once = first.as_bytes().to_vec();

    assert_eq!(held.format(&once, &mut second), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(second.as_bytes()),
        String::from_utf8_lossy(&once)
    );
}

#[test]
fn a_multiline_string_leaves_the_column_its_last_line_ends_at() {
    let source: &[u8] = b"def f():\n    try:\n        pass\n    except:\n        if d:\n            print(\"\"\"\nIf you would like to see debugging output,\ntry: %s -d5\n\"\"\" % sys.argv[0])\n";
    let mut held = Held::reserve();
    let mut first = Buffer::reserve(ARENA_BYTES_MAX);
    let mut second = Buffer::reserve(ARENA_BYTES_MAX);

    assert_eq!(held.format(source, &mut first), Outcome::Complete);

    let once = first.as_bytes().to_vec();

    assert!(
        String::from_utf8_lossy(&once).contains("sys.argv[0]"),
        "{}",
        String::from_utf8_lossy(&once)
    );

    assert_eq!(held.format(&once, &mut second), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(second.as_bytes()),
        String::from_utf8_lossy(&once)
    );
}

#[test]
fn a_format_off_region_leaves_the_indentation_it_found() {
    let source: &[u8] = b"def f(a):\n    if a:\n        # note\n        # fmt: off\n        x = (\n            1 or\n            2\n        )\n        # fmt: on\n        if x:\n            return x\n\n    return 0\n";
    let mut held = Held::reserve();
    let mut first = Buffer::reserve(ARENA_BYTES_MAX);
    let mut second = Buffer::reserve(ARENA_BYTES_MAX);

    assert_eq!(held.format(source, &mut first), Outcome::Complete);

    let once = first.as_bytes().to_vec();

    assert_eq!(
        String::from_utf8_lossy(&once),
        String::from_utf8_lossy(source)
    );

    assert_eq!(held.format(&once, &mut second), Outcome::Complete);
}

#[test]
fn formatting_keeps_every_token_it_was_given() {
    let mut held = Held::reserve();
    let mut out = Buffer::reserve(ARENA_BYTES_MAX);

    for (path, source) in fixtures() {
        assert_eq!(held.format(&source, &mut out), Outcome::Complete);

        let formatted = out.as_bytes().to_vec();
        let before = held.kinds(&source);
        let after = held.kinds(&formatted);

        assert!(
            preserved(&before, &after),
            "{} lost a token or gained one that is not a comma",
            path.display()
        );
    }
}

#[test]
fn formatting_keeps_every_comment_it_was_given() {
    let mut held = Held::reserve();
    let mut out = Buffer::reserve(ARENA_BYTES_MAX);

    for (path, source) in fixtures() {
        assert_eq!(held.format(&source, &mut out), Outcome::Complete);

        let formatted = out.as_bytes().to_vec();
        let before = held.comments(&source);
        let after = held.comments(&formatted);

        assert_eq!(before, after, "{} lost a comment", path.display());
    }
}

#[path = "common/oracle.rs"]
mod oracle;

const EVERY_CATEGORY: [&str; 4] = [
    "literal-normalisation",
    "redundant-parentheses",
    "statement-separator",
    "verbatim-format-string",
];

#[test]
fn the_formatted_output_matches_the_oracle_modulo_residue() {
    let carried = oracle::residue_of("residue-format-python.json", &EVERY_CATEGORY);
    let root = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/golden-ruff-format");
    let mut compared = 0;
    let mut held = Held::reserve();
    let mut out = Buffer::reserve(ARENA_BYTES_MAX);

    for (path, source) in fixtures() {
        let name = path
            .file_name()
            .expect("the fixture has a name")
            .to_string_lossy()
            .into_owned();

        if carried.contains(&name) {
            continue;
        }

        assert_eq!(held.format(&source, &mut out), Outcome::Complete);

        let golden = fs::read(root.join(&name)).expect("the golden is dumped");

        assert_eq!(
            String::from_utf8_lossy(out.as_bytes()),
            String::from_utf8_lossy(&golden),
            "{name} diverges from ruff and no residue row names it"
        );

        compared += 1;
    }

    assert!(
        compared >= floor::FIXTURE_FORMAT_PYTHON,
        "the Python fixtures lost a formatting: {compared} compared, floor {}",
        floor::FIXTURE_FORMAT_PYTHON
    );
}

#[test]
fn every_residue_row_names_a_fixture_that_diverges() {
    let carried = oracle::residue_of("residue-format-python.json", &EVERY_CATEGORY);
    let root = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/golden-ruff-format");
    let mut held = Held::reserve();
    let mut out = Buffer::reserve(ARENA_BYTES_MAX);

    for name in &carried {
        let source = fs::read(
            PathBuf::from(env!("CARGO_MANIFEST_DIR"))
                .join("tests/fixtures/python")
                .join(name),
        )
        .expect("the residue row names a fixture");

        assert_eq!(held.format(&source, &mut out), Outcome::Complete);

        let golden = fs::read(root.join(name)).expect("the golden is dumped");

        assert_ne!(
            out.as_bytes(),
            golden.as_slice(),
            "{name} matches ruff and needs no residue row"
        );
    }
}

#[test]
fn a_file_that_does_not_parse_is_refused() {
    let mut held = Held::reserve();
    let mut out = Buffer::reserve(ARENA_BYTES_MAX);

    assert_eq!(held.format(b"def f(:\n", &mut out), Outcome::Refusal);
    assert!(out.is_empty());
}

#[test]
fn a_range_reads_back_the_lines_it_names() {
    let source: &[u8] = b"x=1\ny=2\nz=3\n";
    let mut held = Held::reserve();
    let mut out = Buffer::reserve(ARENA_BYTES_MAX);

    held.lexed.clear();
    held.raw.clear();
    held.tokens.clear();

    PYTHON.lex(source, &mut held.lexed);

    assert!(classify(
        source,
        held.lexed.as_slice(),
        &mut held.tokens,
        &mut held.raw
    ));

    let outcome = parse::build(
        source,
        held.tokens.as_slice(),
        &held.raw,
        &mut held.events,
        &mut held.tree,
    );

    let input = Input {
        line_ending: LineEnding::LineFeed,
        magic_trailing_comma: true,
        options: Options::DEFAULT,
        pragmas: &[],
        quote: QuotePreference::Double,
        outcome,
        raw: &held.raw,
        source,
        tokens: held.tokens.as_slice(),
        tree: &held.tree,
    };

    let span = held
        .formatter
        .range(&input, (1, 1), &mut out)
        .expect("the range is formatted");

    assert_eq!(out.as_bytes(), b"x = 1\ny = 2\nz = 3\n");
    assert_eq!(&out.as_bytes()[span.range()], b"y = 2\n");
}

fn corpus() -> Vec<(PathBuf, Vec<u8>)> {
    let Some(root) = corpus::root() else {
        return Vec::new();
    };

    let mut found = Vec::new();
    let mut pending = vec![root];

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

            if path.extension().is_none_or(|extension| extension != "py") {
                continue;
            }

            let Ok(source) = fs::read(&path) else {
                continue;
            };

            found.push((path, source));
        }
    }

    found.sort_by(|left, right| left.0.cmp(&right.0));

    found
}

#[test]
fn the_three_relations_hold_over_the_corpus() {
    let mut first = Buffer::reserve(ARENA_BYTES_MAX);
    let mut held = Held::reserve();
    let mut formatted = 0;
    let mut refused = 0;
    let mut second = Buffer::reserve(ARENA_BYTES_MAX);

    for (path, source) in corpus() {
        let outcome = held.format(&source, &mut first);

        if outcome != Outcome::Complete {
            refused += 1;

            continue;
        }

        formatted += 1;

        let once = first.as_bytes().to_vec();
        let before = held.kinds(&source);
        let after = held.kinds(&once);

        assert!(
            preserved(&before, &after),
            "{} lost a token or gained one that is not a comma",
            path.display()
        );

        assert_eq!(
            held.comments(&source),
            held.comments(&once),
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
            first_difference(&once, second.as_bytes()),
            None,
            "{} is not idempotent",
            path.display()
        );
    }

    if let Ok(report) = std::env::var("SCYLLA_REPORT") {
        fs::write(
            report,
            format!("formatted {formatted}, refused {refused}\n"),
        )
        .expect("the report path is writable");
    }
}

struct Tuned {
    events: Events<PythonKind>,
    formatter: Formatter,
    index: lines::Index,
    lexed: Tokens,
    pragmas: Pragmas,
    raw: BoundedVec<PythonKind>,
    tokens: Tokens,
    tree: Tree<PythonKind>,
}

impl Tuned {
    fn reserve() -> Self {
        Self {
            events: Events::reserve(EVENT_COUNT_MAX),
            formatter: Formatter::reserve(ELEMENT_COUNT_MAX, ARENA_BYTES_MAX),
            index: lines::Index::reserve(1 << 14),
            lexed: Tokens::reserve(TOKEN_COUNT_MAX),
            pragmas: Pragmas::reserve(1 << 10),
            raw: BoundedVec::reserve(TOKEN_COUNT_MAX),
            tokens: Tokens::reserve(TOKEN_COUNT_MAX),
            tree: Tree::reserve(NODE_COUNT_MAX, ERROR_COUNT_MAX),
        }
    }

    fn prepare(&mut self, source: &[u8]) -> Structure {
        self.lexed.clear();
        self.raw.clear();
        self.tokens.clear();
        self.tree.clear();

        PYTHON.lex(source, &mut self.lexed);

        assert!(classify(
            source,
            self.lexed.as_slice(),
            &mut self.tokens,
            &mut self.raw
        ));

        assert!(self.index.build(source));

        let comments: Vec<Span> = self
            .lexed
            .as_slice()
            .iter()
            .filter(|token| token.kind == TokenKind::Comment)
            .map(scylla::token::Token::span)
            .collect();

        self.pragmas
            .scan(source, comments.iter().copied(), &self.index);

        parse::build(
            source,
            self.tokens.as_slice(),
            &self.raw,
            &mut self.events,
            &mut self.tree,
        )
    }

    fn formatted(
        &mut self,
        source: &[u8],
        line_ending: LineEnding,
        magic_trailing_comma: bool,
        quote: QuotePreference,
    ) -> String {
        let outcome = self.prepare(source);
        let mut out = Buffer::reserve(1 << 16);

        let input = Input {
            line_ending,
            magic_trailing_comma,
            options: Options::DEFAULT,
            outcome,
            pragmas: self.pragmas.as_slice(),
            quote,
            raw: &self.raw,
            source,
            tokens: self.tokens.as_slice(),
            tree: &self.tree,
        };

        assert_eq!(self.formatter.format(&input, &mut out), Outcome::Complete);

        String::from_utf8_lossy(out.as_bytes()).into_owned()
    }

    fn ranged(&mut self, source: &[u8], range: Span) -> Option<(String, Span)> {
        let outcome = self.prepare(source);
        let mut scratch = Buffer::reserve(1 << 16);
        let mut out = Buffer::reserve(1 << 16);
        let mut lexed = Tokens::reserve(TOKEN_COUNT_MAX);

        let input = Input {
            line_ending: LineEnding::LineFeed,
            magic_trailing_comma: true,
            options: Options::DEFAULT,
            outcome,
            pragmas: self.pragmas.as_slice(),
            quote: QuotePreference::Double,
            raw: &self.raw,
            source,
            tokens: self.tokens.as_slice(),
            tree: &self.tree,
        };

        let span =
            self.formatter
                .format_range(&input, range, &mut scratch, &mut lexed, &mut out)?;

        Some((String::from_utf8_lossy(out.as_bytes()).into_owned(), span))
    }
}

fn plain(source: &[u8], quote: QuotePreference) -> String {
    Tuned::reserve().formatted(source, LineEnding::LineFeed, true, quote)
}

#[test]
fn a_single_quoted_file_stays_single_quoted_under_that_preference() {
    let source = b"held = 'text'\nother = \"text\"\n";

    assert_eq!(
        plain(source, QuotePreference::Single),
        "held = 'text'\nother = 'text'\n"
    );

    assert_eq!(
        plain(source, QuotePreference::Double),
        "held = \"text\"\nother = \"text\"\n"
    );

    assert_eq!(
        plain(source, QuotePreference::Preserve),
        "held = 'text'\nother = \"text\"\n"
    );
}

#[test]
fn a_string_holding_the_wanted_quote_stays_as_the_author_wrote_it() {
    let source = b"held = \"it's\"\n";

    assert_eq!(plain(source, QuotePreference::Single), "held = \"it's\"\n");
}

#[test]
fn a_magic_trailing_comma_breaks_its_bracket_until_it_is_turned_off() {
    let source = b"held = [\n    1,\n]\n";

    assert_eq!(
        Tuned::reserve().formatted(source, LineEnding::LineFeed, true, QuotePreference::Double),
        "held = [\n    1,\n]\n"
    );

    assert_eq!(
        Tuned::reserve().formatted(source, LineEnding::LineFeed, false, QuotePreference::Double),
        "held = [1]\n"
    );
}

#[test]
fn a_carriage_return_line_feed_file_writes_every_line_that_way() {
    let held = Tuned::reserve().formatted(
        b"x = 1\ny   =   2\nz = 3\n",
        LineEnding::CarriageReturnLineFeed,
        true,
        QuotePreference::Double,
    );

    assert_eq!(held, "x = 1\r\ny = 2\r\nz = 3\r\n");
}

#[test]
fn a_line_break_inside_a_string_takes_the_ending_once() {
    let mut tuned = Tuned::reserve();
    let carriage = b"x = \"\"\"a\r\nb\"\"\"\r\n";
    let feed = b"x = \"\"\"a\nb\"\"\"\n";

    assert_eq!(
        tuned.formatted(
            carriage,
            LineEnding::CarriageReturnLineFeed,
            true,
            QuotePreference::Double
        ),
        "x = \"\"\"a\r\nb\"\"\"\r\n"
    );

    assert_eq!(
        tuned.formatted(
            feed,
            LineEnding::CarriageReturnLineFeed,
            true,
            QuotePreference::Double
        ),
        "x = \"\"\"a\r\nb\"\"\"\r\n"
    );

    assert_eq!(
        tuned.formatted(
            carriage,
            LineEnding::LineFeed,
            true,
            QuotePreference::Double
        ),
        "x = \"\"\"a\nb\"\"\"\n"
    );

    assert_eq!(
        tuned.formatted(feed, LineEnding::LineFeed, true, QuotePreference::Double),
        "x = \"\"\"a\nb\"\"\"\n"
    );
}

#[test]
fn a_stub_owes_no_blank_to_the_clause_that_continues_its_statement() {
    assert_eq!(
        plain(
            b"if X:\n    def f(a) -> int: ...\nelse:\n    pass\n",
            QuotePreference::Double
        ),
        "if X:\n\n    def f(a) -> int: ...\nelse:\n    pass\n"
    );

    assert_eq!(
        plain(
            b"try:\n    class C: ...\nexcept E:\n    pass\nfinally:\n    pass\n",
            QuotePreference::Double
        ),
        "try:\n\n    class C: ...\nexcept E:\n    pass\nfinally:\n    pass\n"
    );

    assert_eq!(
        plain(
            b"if X:\n    def f(a) -> int: ...\n\n\nelse:\n    pass\n",
            QuotePreference::Double
        ),
        "if X:\n\n    def f(a) -> int: ...\n\n\nelse:\n    pass\n"
    );

    assert_eq!(
        plain(
            b"if X:\n    def f(a) -> int: ...\ny = 1\n",
            QuotePreference::Double
        ),
        "if X:\n\n    def f(a) -> int: ...\n\n\ny = 1\n"
    );
}

#[test]
fn a_sole_multiline_string_takes_the_hug_a_call_gives_it_and_no_other_bracket() {
    assert_eq!(
        plain(
            b"g(\n    a,\n    html=dedent(\"\"\"\n    <p>x</p>\"\"\"),\n)\n",
            QuotePreference::Double
        ),
        "g(\n    a,\n    html=dedent(\"\"\"\n    <p>x</p>\"\"\"),\n)\n"
    );

    assert_eq!(
        plain(
            b"g(\n    a,\n    html=(\"\"\"\n    <p>x</p>\"\"\"),\n)\n",
            QuotePreference::Double
        ),
        "g(\n    a,\n    html=(\n        \"\"\"\n    <p>x</p>\"\"\"\n    ),\n)\n"
    );

    assert_eq!(
        plain(b"x = t[\"\"\"\n<p>x</p>\"\"\"]\n", QuotePreference::Double),
        "x = t[\n    \"\"\"\n<p>x</p>\"\"\"\n]\n"
    );

    assert_eq!(
        plain(b"x = [\"\"\"\n<p>x</p>\"\"\"]\n", QuotePreference::Double),
        "x = [\n    \"\"\"\n<p>x</p>\"\"\"\n]\n"
    );
}

#[test]
fn a_multiline_format_string_respaces_every_field_and_keeps_its_own_lines() {
    assert_eq!(
        plain(
            b"x = f\"\"\"\nhead {a+b} mid\n{'-'*40}\nend\"\"\"\n",
            QuotePreference::Double
        ),
        "x = f\"\"\"\nhead {a + b} mid\n{\"-\" * 40}\nend\"\"\"\n"
    );

    assert_eq!(
        plain(
            b"x = rf\"\"\"\n{'-'*40}\\d\nend\"\"\"\n",
            QuotePreference::Double
        ),
        "x = rf\"\"\"\n{\"-\" * 40}\\d\nend\"\"\"\n"
    );

    assert_eq!(
        plain(
            b"x = f\"\"\"\nhead {g('''\nz''')} mid\nend\"\"\"\n",
            QuotePreference::Double
        ),
        "x = f\"\"\"\nhead {g('''\nz''')} mid\nend\"\"\"\n"
    );
}

#[test]
fn a_value_that_is_one_bracket_pair_never_takes_the_optional_pair() {
    let remark = "  # added to allow handlers to be removed in reverse of order initialized\n";

    for value in ["[]", "()", "{}", "not []", "-[]", "([])"] {
        let source = format!("_handlerList = {value}{remark}");
        let wanted = source.replace("([])", "[]");

        assert_eq!(plain(source.as_bytes(), QuotePreference::Double), wanted);
    }

    assert_eq!(
        plain(
            format!("_handlerList = [] + x{remark}").as_bytes(),
            QuotePreference::Double
        ),
        format!("_handlerList = (\n    [] + x\n){remark}")
    );

    assert_eq!(
        plain(
            format!("_handlerList = call(){remark}").as_bytes(),
            QuotePreference::Double
        ),
        format!("_handlerList = (\n    call()\n){remark}")
    );
}

#[test]
fn a_bare_tuple_value_wider_than_the_line_takes_the_pair_one_element_to_a_line() {
    let wide = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa, bbbbbbbbbbbbbbbbbbbb";

    assert_eq!(
        plain(
            format!("self._connection = host, HTTPSConnection({wide})\n").as_bytes(),
            QuotePreference::Double
        ),
        format!("self._connection = (\n    host,\n    HTTPSConnection({wide}),\n)\n")
    );

    assert_eq!(
        plain(
            b"self._connection = host, HTTPSConnection(a)\n",
            QuotePreference::Double
        ),
        "self._connection = host, HTTPSConnection(a)\n"
    );

    assert_eq!(
        plain(
            format!("p = q = host, HTTPSConnection({wide})\n").as_bytes(),
            QuotePreference::Double
        ),
        format!("p = q = (\n    host,\n    HTTPSConnection({wide}),\n)\n")
    );
}

#[test]
fn a_remark_run_trailing_an_import_keeps_the_gap_the_source_gave_it() {
    assert_eq!(
        plain(
            b"from a import b\n# one\n# two\n\nx = 1\n",
            QuotePreference::Double
        ),
        "from a import b\n# one\n# two\n\nx = 1\n"
    );

    assert_eq!(
        plain(b"from a import b\n# remark\nx = 1\n", QuotePreference::Double),
        "from a import b\n\n# remark\nx = 1\n"
    );

    assert_eq!(
        plain(b"from a import b\n# one\n\n# two\nx = 1\n", QuotePreference::Double),
        "from a import b\n# one\n\n# two\nx = 1\n"
    );
}

#[test]
fn a_statement_a_redundant_semicolon_ends_owes_the_next_one_no_blank() {
    assert_eq!(
        plain(b"x = 1;\n\ny = 2\n", QuotePreference::Double),
        "x = 1\ny = 2\n"
    );

    assert_eq!(
        plain(b"x = 1; y = 2;\n\nz = 3\n", QuotePreference::Double),
        "x = 1\ny = 2\nz = 3\n"
    );

    assert_eq!(
        plain(b"def g():\n    x = 1;\n\n    y = 2\n", QuotePreference::Double),
        "def g():\n    x = 1\n    y = 2\n"
    );

    assert_eq!(
        plain(b"x = 1;\n\ndef f():\n    pass\n", QuotePreference::Double),
        "x = 1\n\n\ndef f():\n    pass\n"
    );

    assert_eq!(
        plain(b"from a import b;\n\nx = 1\n", QuotePreference::Double),
        "from a import b\n\nx = 1\n"
    );
}

#[test]
fn a_stub_body_reads_through_the_semicolon_that_ends_it() {
    assert_eq!(
        plain(b"def f(): ...;\nx = 1\n", QuotePreference::Double),
        "def f(): ...\n\n\nx = 1\n"
    );

    assert_eq!(
        plain(b"def f():\n    ...;\nx = 1\n", QuotePreference::Double),
        "def f(): ...\n\n\nx = 1\n"
    );

    assert_eq!(
        plain(b"def f(): ...;  # r\nx = 1\n", QuotePreference::Double),
        "def f(): ...  # r\n\n\nx = 1\n"
    );

    assert_eq!(
        plain(b"def f(): ...; x = 1\n", QuotePreference::Double),
        "def f():\n    ...\n    x = 1\n"
    );
}

#[test]
fn a_bare_tuple_statement_takes_the_pair_the_source_left_off() {
    let wide = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";

    assert_eq!(
        plain(b"call(a),\n", QuotePreference::Double),
        "(call(a),)\n"
    );

    assert_eq!(
        plain(b"call(a), other\n", QuotePreference::Double),
        "call(a), other\n"
    );

    assert_eq!(
        plain(
            format!("call({wide}), other_{wide}\n").as_bytes(),
            QuotePreference::Double
        ),
        format!("(\n    call({wide}),\n    other_{wide},\n)\n")
    );

    assert_eq!(
        plain(
            format!("del {wide}, bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb, ccccccccccccccccc\n").as_bytes(),
            QuotePreference::Double
        ),
        format!("del {wide}, bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb, ccccccccccccccccc\n")
    );
}

#[test]
fn a_multiline_string_an_operator_follows_takes_the_pair_around_it() {
    assert_eq!(
        plain(b"x = \"\"\"\nabc\"\"\"\n", QuotePreference::Double),
        "x = \"\"\"\nabc\"\"\"\n"
    );

    assert_eq!(
        plain(b"x = \"\"\"\nabc\"\"\" % name\n", QuotePreference::Double),
        "x = (\n    \"\"\"\nabc\"\"\"\n    % name\n)\n"
    );

    assert_eq!(
        plain(b"x = name + \"\"\"\nabc\"\"\"\n", QuotePreference::Double),
        "x = (\n    name\n    + \"\"\"\nabc\"\"\"\n)\n"
    );

    assert_eq!(
        plain(b"x = \"\"\"\nabc\"\"\" % (a, b)\n", QuotePreference::Double),
        "x = \"\"\"\nabc\"\"\" % (a, b)\n"
    );

    assert_eq!(
        plain(b"x = \"\"\"\nabc\"\"\".strip()\n", QuotePreference::Double),
        "x = \"\"\"\nabc\"\"\".strip()\n"
    );
}

#[test]
fn a_format_string_joined_onto_a_plain_one_measures_at_its_joined_width() {
    let source = concat!(
        "class C:\n    _make.__func__.__doc__ = (f'Make a new {typename} object from a",
        " sequence '\n                              'or iterable')\n"
    );

    let wanted = concat!(
        "class C:\n    _make.__func__.__doc__ = f\"Make a new {typename} object from a",
        " sequence or iterable\"\n"
    );

    assert_eq!(plain(source.as_bytes(), QuotePreference::Double), wanted);
}

#[test]
fn a_triple_quoted_format_string_keeps_a_quote_that_ends_one_of_its_parts() {
    assert_eq!(
        plain(
            b"script = f'''\n   tell application \"{name}\"\n   '''\n",
            QuotePreference::Double
        ),
        "script = f'''\n   tell application \"{name}\"\n   '''\n"
    );

    assert_eq!(
        plain(
            b"script = f'''\n   tell application\n   '''\n",
            QuotePreference::Double
        ),
        "script = f\"\"\"\n   tell application\n   \"\"\"\n"
    );

    assert_eq!(
        plain(
            b"script = f'''\n   tell \"x\" here {name}\n   '''\n",
            QuotePreference::Double
        ),
        "script = f\"\"\"\n   tell \"x\" here {name}\n   \"\"\"\n"
    );

    assert_eq!(
        plain(
            b"script = f'''\n   tell {d[\"k\"]} here\n   '''\n",
            QuotePreference::Double
        ),
        "script = f\"\"\"\n   tell {d[\"k\"]} here\n   \"\"\"\n"
    );

    assert_eq!(
        plain(
            b"script = '''\n   tell application \"x\"\n   '''\n",
            QuotePreference::Double
        ),
        "script = \"\"\"\n   tell application \"x\"\n   \"\"\"\n"
    );
}

#[test]
fn a_one_element_tuple_in_a_replacement_field_takes_the_pair() {
    assert_eq!(
        plain(b"x = f\"{a,}\"\n", QuotePreference::Double),
        "x = f\"{(a,)}\"\n"
    );

    assert_eq!(
        plain(b"x = f\"{a,:>10}\"\n", QuotePreference::Double),
        "x = f\"{(a,):>10}\"\n"
    );

    assert_eq!(
        plain(b"x = f\"{a,!r}\"\n", QuotePreference::Double),
        "x = f\"{(a,)!r}\"\n"
    );

    assert_eq!(
        plain(b"x = f\"{a, b}\"\n", QuotePreference::Double),
        "x = f\"{a, b}\"\n"
    );

    assert_eq!(
        plain(b"x = f\"{d[a, b]}\"\n", QuotePreference::Double),
        "x = f\"{d[a, b]}\"\n"
    );

    assert_eq!(
        plain(b"x = f\"{a,=}\"\n", QuotePreference::Double),
        "x = f\"{a,=}\"\n"
    );
}

#[test]
fn an_operator_ahead_of_a_concatenation_keeps_the_line_the_first_part_opens() {
    let source = concat!(
        "f(\n    g(\"Manual porting required\") + \"\\n\"\n",
        "    \"  Your migrations contained functions that must be manually \"\n",
        "    \"copied over.\"\n)\n"
    );

    assert_eq!(plain(source.as_bytes(), QuotePreference::Double), source);

    let tailed = concat!(
        "raise E(\n    \"  * At least one of the expected database tables is missing.\\n\"\n",
        "    \"Hint: Look at the output of 'django-admin sqlflush'. \"\n",
        "    \"That's the SQL this command wasn't able to run.\"\n",
        "    % (connection.settings_dict[\"NAME\"],)\n)\n"
    );

    assert_eq!(plain(tailed.as_bytes(), QuotePreference::Double), tailed);
}

#[test]
fn a_format_string_part_records_the_element_level_a_plain_one_records() {
    let source = concat!(
        "f(\n    f\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\\n\"\n",
        "    f\"  See the comment at the top of the squashed migration for details.\\n\"\n",
        "    + black_warning,\n)\n"
    );

    assert_eq!(plain(source.as_bytes(), QuotePreference::Double), source);

    assert_eq!(
        plain(b"f(\n    f\"aaa\"\n    f\"bbb\"\n    + w,\n)\n", QuotePreference::Double),
        "f(\n    f\"aaabbb\" + w,\n)\n"
    );
}

#[test]
fn a_wrap_head_inside_a_bracket_measures_from_the_element_it_stands_in() {
    let source = concat!(
        "d = {\n    \"__hash__\": default_hash,\n",
        "    \"__str__\": lambda self: f\"{type(self).__name__}\",\n",
        "    \"__fspath__\": lambda self: f\"{type(self).__name__}",
        "/{self._extract_mock_name()}/{id(self)}\",\n}\n"
    );

    let wanted = concat!(
        "d = {\n    \"__hash__\": default_hash,\n",
        "    \"__str__\": lambda self: f\"{type(self).__name__}\",\n",
        "    \"__fspath__\": lambda self: (\n        f\"{type(self).__name__}",
        "/{self._extract_mock_name()}/{id(self)}\"\n    ),\n}\n"
    );

    assert_eq!(plain(source.as_bytes(), QuotePreference::Double), wanted);

    let called = concat!(
        "item = make_objecttreeitem(\n    str(key) + \" =\",\n    value,\n",
        "    lambda value, key=key, object_=self.object: setattr(object_, key, value),\n)\n"
    );

    assert_eq!(plain(called.as_bytes(), QuotePreference::Double), called);
}

#[test]
fn a_lambda_body_ends_where_the_comprehension_clause_after_it_opens() {
    let source = concat!(
        "g = f(\n    (\n        lambda addrinfo=addrinfo: self._connect_sock(exceptions,",
        " addrinfo, laddr_infos)\n        for addrinfo in infos\n    ),\n    delay,\n)\n"
    );

    assert_eq!(plain(source.as_bytes(), QuotePreference::Double), source);

    let awaited = concat!(
        "async def q():\n    g = (\n        self._connect_sock(\n",
        "            exceptions, addrinfo, laddr_infos, aaaaaaaaaaaaaaaaaaaaaaaaaaaa\n",
        "        )\n        async for addrinfo in infos\n    )\n"
    );

    assert_eq!(plain(awaited.as_bytes(), QuotePreference::Double), awaited);
}

#[test]
fn a_doubled_pair_of_grouping_parentheses_collapses_to_one() {
    assert_eq!(
        plain(b"def f():\n    if (a) or ((b)):\n        return\n", QuotePreference::Double),
        "def f():\n    if (a) or (b):\n        return\n"
    );

    assert_eq!(
        plain(b"x = (((a)))\n", QuotePreference::Double),
        "x = a\n"
    );

    assert_eq!(plain(b"f((a))\n", QuotePreference::Double), "f((a))\n");

    assert_eq!(
        plain(
            b"def f():\n    return \"%s=%s\" % ((quote(k, safe), quote(v, safe)))\n",
            QuotePreference::Double
        ),
        "def f():\n    return \"%s=%s\" % ((quote(k, safe), quote(v, safe)))\n"
    );
}

#[test]
fn a_concatenation_the_head_cannot_hold_parts_from_its_operator() {
    let held = concat!(
        "def f():\n    self.assertTrue(\n        template_name in template_names,\n",
        "        msg_prefix + \"Template '%s' was not a template used to render\"\n",
        "        \" the response. Actual template(s) used: %s\"\n",
        "        % (template_name, \", \".join(template_names)),\n    )\n"
    );

    assert_eq!(plain(held.as_bytes(), QuotePreference::Double), held);

    let parted = concat!(
        "x = Label(\n    self.frame,\n",
        "    text=\"Key bindings are specified using Tkinter keysyms as\\n\"\n",
        "    + \"in these samples: <Control-f>, <Shift-F2>, <F12>,\\n\"\n",
        "    \"<Control-space>, <Meta-less>, <Control-Alt-Shift-X>.\\n\",\n)\n"
    );

    assert_eq!(plain(parted.as_bytes(), QuotePreference::Double), parted);
}

#[test]
fn a_return_annotation_drops_the_pair_the_source_wrapped_it_in() {
    let source = concat!(
        "def iter_attrs() -> (\n    Iterable[Tuple[str, Any, Optional[Callable[[Any], str]],",
        " Held, Moreeee]]\n):\n    pass\n"
    );

    let wanted = concat!(
        "def iter_attrs() -> Iterable[\n    Tuple[str, Any, Optional[Callable[[Any], str]],",
        " Held, Moreeee]\n]:\n    pass\n"
    );

    assert_eq!(plain(source.as_bytes(), QuotePreference::Double), wanted);

    assert_eq!(
        plain(b"def f() -> (int):\n    pass\n", QuotePreference::Double),
        "def f() -> int:\n    pass\n"
    );

    assert_eq!(
        plain(b"def f() -> (  # r\n    int\n):\n    pass\n", QuotePreference::Double),
        "def f() -> (  # r\n    int\n):\n    pass\n"
    );

    assert_eq!(
        plain(b"def f(\n    a,\n    b,\n):\n    pass\n", QuotePreference::Double),
        "def f(\n    a,\n    b,\n):\n    pass\n"
    );
}

#[test]
fn only_a_definition_head_owes_the_magic_comma_its_line_opens_with() {
    let chained = concat!(
        "async def q():\n    async for s in SimpleModel.objects.prefetch_related(\n",
        "        Prefetch(\"relatedmodel_set\", to_attr=\"prefetched_relatedmodel\")\n",
        "    ).aiterator(chunk_size=2000):\n        pass\n"
    );

    assert_eq!(plain(chained.as_bytes(), QuotePreference::Double), chained);

    assert_eq!(
        plain(b"async def q(\n    a,\n    b,\n):\n    pass\n", QuotePreference::Double),
        "async def q(\n    a,\n    b,\n):\n    pass\n"
    );
}

#[test]
fn a_parted_list_owes_its_separator_ahead_of_an_own_line_remark() {
    assert_eq!(
        plain(b"f(\n    a,\n    b\n    # remark\n)\n", QuotePreference::Double),
        "f(\n    a,\n    b,\n    # remark\n)\n"
    );

    assert_eq!(
        plain(b"f(\n    a,\n    b\n    # one\n    # two\n)\n", QuotePreference::Double),
        "f(\n    a,\n    b,\n    # one\n    # two\n)\n"
    );

    assert_eq!(
        plain(
            b"__all__ = [\n    \"walk\",\n    # Do not include _structure().\n]\n",
            QuotePreference::Double
        ),
        "__all__ = [\n    \"walk\",\n    # Do not include _structure().\n]\n"
    );

    assert_eq!(
        plain(b"x = [\n    a\n    # remark\n]\n", QuotePreference::Double),
        "x = [\n    a\n    # remark\n]\n"
    );
}

#[test]
fn an_operator_after_a_concatenation_keeps_the_remark_that_rides_it() {
    let held = concat!(
        "f(\n    r\"(^[ \\t]*)\"  # at beginning\n",
        "    r\"(?![ \\t]*(?:\" +  # not followed by\n    # pattern matching\n",
        "    r\"|\".join(k for k in kw) + r\")\\b))\",\n    other,\n)\n"
    );

    let wanted = concat!(
        "f(\n    r\"(^[ \\t]*)\"  # at beginning\n",
        "    r\"(?![ \\t]*(?:\" +  # not followed by\n    # pattern matching\n",
        "    r\"|\".join(k for k in kw) + r\")\\b))\",\n    other,\n)\n"
    );

    assert_eq!(plain(held.as_bytes(), QuotePreference::Double), wanted);

    let lone = concat!(
        "x = (\n    aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa +  # remark\n",
        "    bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n)\n"
    );

    let parted = concat!(
        "x = (\n    aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa  # remark\n",
        "    + bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n)\n"
    );

    assert_eq!(plain(lone.as_bytes(), QuotePreference::Double), parted);
}

#[test]
fn a_binary_value_leading_with_a_spanning_string_omits_the_pair_alone() {
    let paired = concat!(
        "def f():\n    if p:\n        result = result + \"\"\"\n<tr><td>%s</td>\"\"\"",
        " % (cls, marginalia, gap)\n"
    );

    let wanted = concat!(
        "def f():\n    if p:\n        result = (\n            result\n",
        "            + \"\"\"\n<tr><td>%s</td>\"\"\"\n            % (cls, marginalia, gap)\n",
        "        )\n"
    );

    assert_eq!(plain(paired.as_bytes(), QuotePreference::Double), wanted);

    let bare = concat!(
        "def f():\n    if p:\n        result = \"\"\"\n<tr><td>%s</td>\"\"\"",
        " % (cls, marginalia, gap)\n"
    );

    assert_eq!(plain(bare.as_bytes(), QuotePreference::Double), bare);

    let nested = concat!(
        "def f():\n    if p:\n        result = result + self.section(\n",
        "            \"MODULE REFERENCE\",\n            docloc\n            + \"\"\"\n\n",
        "The following documentation is generated.\n\"\"\",\n        )\n"
    );

    assert_eq!(plain(nested.as_bytes(), QuotePreference::Double), nested);
}

#[test]
fn a_docstring_holding_an_escaped_newline_keeps_every_line_it_was_given() {
    assert_eq!(
        plain(
            b"def f():\n    \"\"\"head \\\n        rest.\n        tail.\n    \"\"\"\n",
            QuotePreference::Double
        ),
        "def f():\n    \"\"\"head \\\n        rest.\n        tail.\n    \"\"\"\n"
    );

    assert_eq!(
        plain(
            b"def f():\n    '''head.\n        mid \\\\\n        rest.   \n    '''\n",
            QuotePreference::Double
        ),
        "def f():\n    \"\"\"head.\n        mid \\\\\n        rest.   \n    \"\"\"\n"
    );

    assert_eq!(
        plain(
            b"def f():\n    \"\"\"head.\n        mid \\t dle.\n        tail.\n    \"\"\"\n",
            QuotePreference::Double
        ),
        "def f():\n    \"\"\"head.\n    mid \\t dle.\n    tail.\n    \"\"\"\n"
    );
}

#[test]
fn a_single_quoted_docstring_is_requoted_and_reindented_together() {
    let source = b"def f():\n    '''doc\n        more\n      '''\n";

    assert_eq!(
        plain(source, QuotePreference::Double),
        "def f():\n    \"\"\"doc\n    more\n    \"\"\"\n"
    );

    assert_eq!(
        plain(source, QuotePreference::Single),
        "def f():\n    \"\"\"doc\n    more\n    \"\"\"\n"
    );

    assert_eq!(
        plain(source, QuotePreference::Preserve),
        "def f():\n    '''doc\n    more\n    '''\n"
    );

    assert_eq!(
        plain(b"def f():\n    'doc'\n", QuotePreference::Single),
        "def f():\n    \"doc\"\n"
    );

    assert_eq!(
        plain(
            b"def f():\n    '''say \"hi\"\n    x'''\n",
            QuotePreference::Double
        ),
        "def f():\n    \"\"\"say \"hi\"\n    x\"\"\"\n"
    );
}

#[test]
fn a_dot_after_an_integer_keeps_the_space_that_makes_it_an_attribute() {
    let source = b"x = 3 .real\ny = a . b\nz = (3).real\nw = 3.5.real\nv = 0x1 .real\n";

    let held =
        Tuned::reserve().formatted(source, LineEnding::LineFeed, true, QuotePreference::Double);

    assert_eq!(
        held,
        "x = 3 .real\ny = a.b\nz = (3).real\nw = 3.5.real\nv = 0x1.real\n"
    );
}

#[test]
fn a_format_off_region_is_reproduced_byte_for_byte() {
    let source = b"# fmt: off\nmatrix = [\n    1,  0,\n    0,  1,\n]\n# fmt: on\nheld   =   1\n";

    let held =
        Tuned::reserve().formatted(source, LineEnding::LineFeed, true, QuotePreference::Double);

    assert_eq!(
        held,
        "# fmt: off\nmatrix = [\n    1,  0,\n    0,  1,\n]\n# fmt: on\nheld = 1\n"
    );
}

#[test]
fn a_format_skip_statement_is_reproduced_and_the_next_one_is_not() {
    let source = b"held   =   1  # fmt: skip\nother   =   2\n";

    let held =
        Tuned::reserve().formatted(source, LineEnding::LineFeed, true, QuotePreference::Double);

    assert_eq!(held, "held   =   1  # fmt: skip\nother = 2\n");
}

#[test]
fn a_range_over_the_middle_statement_changes_only_that_statement() {
    let source = b"x = 1\ny   =   2\nz = 3\n";

    let (text, span) = Tuned::reserve()
        .ranged(
            source,
            Span {
                length: 1,
                offset: 8,
            },
        )
        .expect("the range is formatted");

    assert_eq!(&source[span.range()], b"y   =   2\n");
    assert_eq!(text, "y = 2\n");
}

fn applied(source: &[u8], range: Span) -> String {
    let (text, span) = Tuned::reserve()
        .ranged(source, range)
        .expect("the range is formatted");

    let mut held = source[..span.offset as usize].to_vec();

    held.extend_from_slice(text.as_bytes());
    held.extend_from_slice(&source[span.end() as usize..]);

    String::from_utf8_lossy(&held).into_owned()
}

#[test]
fn a_range_edit_applied_to_the_file_matches_ruff() {
    let bracketed = Span {
        length: 1,
        offset: 4,
    };

    assert_eq!(
        applied(b"x=1\nprint( y )\nz=3\n", bracketed),
        "x=1\nprint(y)\nz=3\n"
    );

    assert_eq!(
        applied(
            b"x=1\nresult = call(\n    a, b\n)\ny=2\n",
            Span {
                length: 1,
                offset: 20
            }
        ),
        "x=1\nresult = call(a, b)\ny=2\n"
    );

    assert_eq!(
        applied(
            b"x=1\n@dec\ndef f( a ):\n    pass\ny=2\n",
            Span {
                length: 1,
                offset: 10
            }
        ),
        "x=1\n@dec\ndef f(a):\n    pass\ny=2\n"
    );

    assert_eq!(
        applied(b"x=1\nprint( y )  # note\nz=3\n", bracketed),
        "x=1\nprint(y)  # note\nz=3\n"
    );
}

#[test]
fn a_range_over_two_statements_covers_both() {
    let source = b"x   =   1\ny   =   2\nz = 3\n";

    let (text, span) = Tuned::reserve()
        .ranged(
            source,
            Span {
                length: 12,
                offset: 0,
            },
        )
        .expect("the range is formatted");

    assert_eq!(&source[span.range()], b"x   =   1\ny   =   2\n");
    assert_eq!(text, "x = 1\ny = 2\n");
}

#[test]
fn a_range_that_meets_no_statement_reports_none() {
    let source = b"x = 1\n";

    assert!(
        Tuned::reserve()
            .ranged(
                source,
                Span {
                    length: 0,
                    offset: 6,
                }
            )
            .is_none()
    );
}

#[test]
fn formatting_keeps_every_word_it_was_given() {
    let mut held = Held::reserve();
    let mut out = Buffer::reserve(ARENA_BYTES_MAX);

    for (path, source) in fixtures() {
        let name = path.display().to_string();

        if held.format(&source, &mut out) != Outcome::Complete {
            continue;
        }

        let formatted = out.as_bytes().to_vec();
        let before = held.words(&source);
        let after = held.words(&formatted);

        assert_eq!(
            before, after,
            "{name} split, joined, lost, or gained a word"
        );
    }
}

#[test]
fn a_statement_drops_the_parentheses_that_only_group_its_operand() {
    const SOURCE: &[u8] = b"while (i > 0):\n    pass\nif (a and b):\n    pass\nelif (c):\n    pass\nassert (x), (y)\nfor (i, row) in (held):\n    pass\n";
    const WANTED: &[u8] = b"while i > 0:\n    pass\nif a and b:\n    pass\nelif c:\n    pass\nassert x, y\nfor i, row in held:\n    pass\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(ARENA_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(WANTED)
    );
}

#[test]
fn a_pair_the_grammar_wants_is_kept() {
    const SOURCE: &[u8] = b"u = (v := 10)\n\n\ndef f():\n    return (a, b)\n    return (a,)\n    return ()\n    return (x for x in y)\n    return (a)[0]\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(ARENA_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(SOURCE)
    );
}

#[test]
fn a_pair_the_line_needs_back_is_kept() {
    const SOURCE: &[u8] = b"def f():\n    if (aaaaaaaaaaaaaaaaaaaaaaaaa and bbbbbbbbbbbbbbbbbbbbbbbbbbbb and cccccccccccccccccccccc):\n        pass\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(ARENA_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert!(
        out.as_bytes()
            .split(|byte| *byte == b'\n')
            .all(|line| line.len() <= 88),
        "{}",
        String::from_utf8_lossy(out.as_bytes())
    );
}

#[test]
fn a_format_field_leaves_the_literal_a_value_the_parentheses_may_hold() {
    const SOURCE: &[u8] = b"def f(context, name):\n    context[\"widget\"][\"attrs\"][\"aria-describedby\"] = f\"plain_{name}_value_that_is_long12\"\n";
    const WANTED: &[u8] = b"def f(context, name):\n    context[\"widget\"][\"attrs\"][\"aria-describedby\"] = (\n        f\"plain_{name}_value_that_is_long12\"\n    )\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(ARENA_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(WANTED)
    );
}

#[test]
fn a_bare_tuple_takes_the_parentheses_the_reference_writes_around_it() {
    const SOURCE: &[u8] = b"__all__ = \"BaseProactorEventLoop\",\na = 1, 2\nb = 1,\nd = \"x\", \"y\",\n\n\ndef g():\n    return 1,\n\n\ndef h():\n    return bytes([1, 2, 3, 4]),\n";
    const WANTED: &[u8] = b"__all__ = (\"BaseProactorEventLoop\",)\na = 1, 2\nb = (1,)\nd = (\n    \"x\",\n    \"y\",\n)\n\n\ndef g():\n    return (1,)\n\n\ndef h():\n    return (bytes([1, 2, 3, 4]),)\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(ARENA_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(WANTED)
    );
}

#[test]
fn a_value_takes_the_parentheses_the_reference_writes_where_no_bracket_parts_it() {
    const SOURCE: &[u8] = b"def f():\n    aaaaaaaaaaaaaaaaaaa = salted_hmac(key_salt, self.password, secret=secret, alg=\"x\").hex()\n    ccccccccccccccccccc = salted_hmac(key_salt, self.password, sec=secret).hexdigest().upper()\n    ddddddddddddddddddd = alpha.beta.gamma.delta.epsilon.zeta.eta.theta.iota.kappa.lambdaa.mu\n    ggggggggggggggggggg = await cls.get_model_class().objects.filter(expire=now()).adelete_now()\n    frame_no_here = ((time - self.start_time) * self.speed) / (self.interval / 1000.0) + off\n    response_ab_c = await sync_to_async(response.render, thread_sensitive=True_value_xyz)()\n    hhhhhhhhhhhhhhhhhhh = some_dictionary_name[\"a key that is long\"][\"another key here\"][\"m\"]\n";
    const WANTED: &[u8] = b"def f():\n    aaaaaaaaaaaaaaaaaaa = salted_hmac(\n        key_salt, self.password, secret=secret, alg=\"x\"\n    ).hex()\n    ccccccccccccccccccc = (\n        salted_hmac(key_salt, self.password, sec=secret).hexdigest().upper()\n    )\n    ddddddddddddddddddd = (\n        alpha.beta.gamma.delta.epsilon.zeta.eta.theta.iota.kappa.lambdaa.mu\n    )\n    ggggggggggggggggggg = (\n        await cls.get_model_class().objects.filter(expire=now()).adelete_now()\n    )\n    frame_no_here = ((time - self.start_time) * self.speed) / (\n        self.interval / 1000.0\n    ) + off\n    response_ab_c = await sync_to_async(\n        response.render, thread_sensitive=True_value_xyz\n    )()\n    hhhhhhhhhhhhhhhhhhh = some_dictionary_name[\"a key that is long\"][\n        \"another key here\"\n    ][\"m\"]\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(ARENA_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(WANTED)
    );
}

#[test]
fn a_header_takes_the_parentheses_its_condition_needs_and_closes_them_on_the_colon() {
    const SOURCE: &[u8] = b"def f():\n    if caller_frame and not caller_frame.f_trace and caller_frame is not self.botframe_x:\n        pass\n    if some_object.attribute_one.attribute_two.attribute_three.attribute_four.attr_fivex:\n        pass\n    while some_dictionary[\"a key that is long\"][\"another key here\"][\"and one more key!!\"]:\n        pass\n    return long_call_name(argument_one, argument_two, argument_three_here), False_value_x\n";
    const WANTED: &[u8] = b"def f():\n    if (\n        caller_frame\n        and not caller_frame.f_trace\n        and caller_frame is not self.botframe_x\n    ):\n        pass\n    if some_object.attribute_one.attribute_two.attribute_three.attribute_four.attr_fivex:\n        pass\n    while some_dictionary[\"a key that is long\"][\"another key here\"][\n        \"and one more key!!\"\n    ]:\n        pass\n    return long_call_name(\n        argument_one, argument_two, argument_three_here\n    ), False_value_x\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(ARENA_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(WANTED)
    );
}

#[test]
fn a_word_that_opens_a_statement_takes_the_pair_its_own_operand_needs() {
    const SOURCE: &[u8] = b"async def f():\n    assert some_object.attribute_one.attribute_two.attribute_three.attribute_four.attrxyz\n    assert some_object.attribute_one.attribute_two.attribute_three.attrxy, \"a message ok!\"\n    await some_object.attribute_one.attribute_two.attribute_three.attribute_four.attribxyz\n    with some_object.attribute_one.attribute_two.attribute_three.attribute_four.attribxyz:\n        pass\n    with GzipFile(filename=filename, mode=\"wb\", compresslevel=6, fileobj=buf) as zfile_ab:\n        pass\n";
    const WANTED: &[u8] = b"async def f():\n    assert (\n        some_object.attribute_one.attribute_two.attribute_three.attribute_four.attrxyz\n    )\n    assert some_object.attribute_one.attribute_two.attribute_three.attrxy, (\n        \"a message ok!\"\n    )\n    await (\n        some_object.attribute_one.attribute_two.attribute_three.attribute_four.attribxyz\n    )\n    with (\n        some_object.attribute_one.attribute_two.attribute_three.attribute_four.attribxyz\n    ):\n        pass\n    with GzipFile(\n        filename=filename, mode=\"wb\", compresslevel=6, fileobj=buf\n    ) as zfile_ab:\n        pass\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(ARENA_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(WANTED)
    );
}

#[test]
fn a_docstring_a_remark_stands_above_owes_the_remark_below_it_a_cap() {
    const SOURCE: &[u8] = b"#!/bin/sh\n\"\"\"Doc.\"\"\"\n# a remark\n\n\nimport os\n";
    const WANTED: &[u8] = b"#!/bin/sh\n\"\"\"Doc.\"\"\"\n# a remark\n\nimport os\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(ARENA_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(WANTED)
    );
}

#[test]
fn a_join_takes_the_quote_that_spells_its_parts_with_the_fewest_backslashes() {
    const SOURCE: &[u8] = b"def f(self, bits):\n    a = '\"count\" in %r tag expected exactly ' \"one keyword argument.\"\n    b = \"No handlers could be found for logger\" \" \\\"%s\\\"\\n\" % self.name\n    c = \"plain part one \" \"and plain part two\"\n";
    const WANTED: &[u8] = b"def f(self, bits):\n    a = '\"count\" in %r tag expected exactly one keyword argument.'\n    b = 'No handlers could be found for logger \"%s\"\\n' % self.name\n    c = \"plain part one and plain part two\"\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(ARENA_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(WANTED)
    );
}

#[test]
fn a_format_field_is_written_with_the_spacing_the_expression_it_holds_takes() {
    const SOURCE: &[u8] = b"def f(a, b, ip_str, x, width, items):\n    p = f\"{a+1}\"\n    q = f\"{f(a,b)}\"\n    r = f\"{ip_str[:45]}({len(ip_str)-90} chars elided){ip_str[-45:]}\"\n    s = f\"{-a}\"\n    t = f\"{not a}\"\n    v = f\"{f(a=1,b=2)}\"\n    w = f\"{x=}\"\n    y = f\"{x!r}\"\n    z = f\"{x:{width}}\"\n    aa = f\"{a.b.c(d)[e]}\"\n    ac = f\"{ {'k': 1} }\"\n    ad = f\"{a**2}\"\n    ah = f\"{(lambda q: q+1)}\"\n    ai = f'{a<b and c>=d}'\n";
    const WANTED: &[u8] = b"def f(a, b, ip_str, x, width, items):\n    p = f\"{a + 1}\"\n    q = f\"{f(a, b)}\"\n    r = f\"{ip_str[:45]}({len(ip_str) - 90} chars elided){ip_str[-45:]}\"\n    s = f\"{-a}\"\n    t = f\"{not a}\"\n    v = f\"{f(a=1, b=2)}\"\n    w = f\"{x=}\"\n    y = f\"{x!r}\"\n    z = f\"{x:{width}}\"\n    aa = f\"{a.b.c(d)[e]}\"\n    ac = f\"{ {'k': 1} }\"\n    ad = f\"{a**2}\"\n    ah = f\"{(lambda q: q + 1)}\"\n    ai = f\"{a < b and c >= d}\"\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(ARENA_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(WANTED)
    );
}

#[test]
fn a_join_is_measured_with_the_separator_the_group_holding_it_owes() {
    const SOURCE: &[u8] = b"held = {\n    \"key\": {\n        \"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"\n        \"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\",\n    },\n}\n";
    const WANTED: &[u8] = b"held = {\n    \"key\": {\n        \"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaabbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\",\n    },\n}\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(ARENA_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(WANTED)
    );
}

#[test]
fn a_join_the_separator_takes_past_the_width_parts_where_it_stands() {
    const SOURCE: &[u8] = b"held = {\n    \"key\": {\n        \"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"\n        \"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\",\n    },\n}\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(ARENA_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(SOURCE)
    );
}

#[test]
fn a_remark_under_a_module_docstring_keeps_the_one_line_it_owes() {
    const SOURCE: &[u8] = b"\"\"\"Doc.\"\"\"\n\n# note\n\n\nimport sys\n";
    const WANTED: &[u8] = b"\"\"\"Doc.\"\"\"\n\n# note\n\nimport sys\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(ARENA_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(WANTED)
    );
}

#[test]
fn a_pair_holding_a_product_is_no_unpacking_and_goes() {
    const SOURCE: &[u8] = b"def f():\n    return (a * b)\n";
    const WANTED: &[u8] = b"def f():\n    return a * b\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(ARENA_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(WANTED)
    );
}

#[test]
fn a_remark_past_the_statement_keeps_the_pair_it_owes() {
    const SOURCE: &[u8] = b"def g(new_args, field):\n    new_args[field] = (\n        \"X\" * 250\n    )  # a value that runs the line it stands on well past the width it answers to.\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(ARENA_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(SOURCE)
    );
}

#[test]
fn a_pair_whose_head_fits_goes_and_the_bracket_it_holds_parts() {
    const SOURCE: &[u8] = b"def h():\n    cfile = (importlib.util.cache_from_source(fullname_value, optimization=option_value))\n";
    const WANTED: &[u8] = b"def h():\n    cfile = importlib.util.cache_from_source(fullname_value, optimization=option_value)\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(ARENA_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(WANTED)
    );
}

#[test]
fn a_pair_whose_head_runs_past_the_width_stays() {
    const SOURCE: &[u8] = b"def i(task_backends):\n    if True:\n        task_backends._settings = task_backends.settings = (\n            task_backends.configure_settings(None)\n        )\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(ARENA_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(SOURCE)
    );
}

#[test]
fn an_import_list_takes_the_parentheses_the_width_needs_and_no_others() {
    const SOURCE: &[u8] = b"from _csv import Error, writer, reader, register_dialect, unregister_dialect, get_dialect\nfrom x import (a, b)\n";
    const WANTED: &[u8] = b"from _csv import (\n    Error,\n    writer,\n    reader,\n    register_dialect,\n    unregister_dialect,\n    get_dialect,\n)\nfrom x import a, b\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(ARENA_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(WANTED)
    );
}

#[test]
fn an_import_list_of_one_name_takes_the_separator_it_parts_with() {
    const SOURCE: &[u8] = b"def f():\n    if True:\n        if True:\n            if True:\n                if True:\n                    if True:\n                        if True:\n                            if True:\n                                from pip._vendor.rich._win32_console import LegacyWindowsTerm\n";
    const WANTED: &[u8] = b"def f():\n    if True:\n        if True:\n            if True:\n                if True:\n                    if True:\n                        if True:\n                            if True:\n                                from pip._vendor.rich._win32_console import (\n                                    LegacyWindowsTerm,\n                                )\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(ARENA_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(WANTED)
    );
}

#[test]
fn a_dict_entrys_break_goes_into_the_value_the_key_leaves_room_for() {
    const SOURCE: &[u8] = b"d = {\n    \"%s__pkXXX\" % self.content_type_field_name: ContentType.objects.db_manager(usingxxxx),\n    \"%s__inXX\" % GeoColumn.table_name_col(): [\"gis_neighborhoodxxx\", \"gis_householdxxxx\"],\n    \"_prefetch_related_val_%sXX\" % f.attnamex: \"%s.%s\" % (qn(join_table), qn(source_col)),\n    \"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaXX\" % bbbbbbbbbbbbbbbbbbbbbbbbb: cc,\n    \"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaXXX\" % bbbbbbbbbbbbbbbbbbbbbbbbb: ccccccccccccccccccccc,\n}\n";
    const WANTED: &[u8] = b"d = {\n    \"%s__pkXXX\" % self.content_type_field_name: ContentType.objects.db_manager(\n        usingxxxx\n    ),\n    \"%s__inXX\" % GeoColumn.table_name_col(): [\n        \"gis_neighborhoodxxx\",\n        \"gis_householdxxxx\",\n    ],\n    \"_prefetch_related_val_%sXX\" % f.attnamex: \"%s.%s\"\n    % (qn(join_table), qn(source_col)),\n    \"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaXX\"\n    % bbbbbbbbbbbbbbbbbbbbbbbbb: cc,\n    \"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaXXX\"\n    % bbbbbbbbbbbbbbbbbbbbbbbbb: ccccccccccccccccccccc,\n}\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(ARENA_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(WANTED)
    );
}

#[test]
fn a_trailing_remark_run_past_a_closed_block_takes_the_gap_the_source_wrote() {
    const SOURCE: &[u8] = b"if x:\n\n    def held():\n        return 1\n\nelse:\n\n    def held():\n        return 2\n\n#\n# a run the blank below detaches\n#\n\nclass S:\n    pass\n\n\ndef other():\n    return 3\n\n# a run that leads the statement below\ny = 2\n";
    const WANTED: &[u8] = b"if x:\n\n    def held():\n        return 1\n\nelse:\n\n    def held():\n        return 2\n\n#\n# a run the blank below detaches\n#\n\n\nclass S:\n    pass\n\n\ndef other():\n    return 3\n\n\n# a run that leads the statement below\ny = 2\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(ARENA_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(WANTED)
    );
}

#[test]
fn an_element_a_remark_defers_opens_its_groups_at_an_f_string_too() {
    const SOURCE: &[u8] =
        b"a = [\n    (x, y),\n    # a remark\n    f\"aaa\" if PYPY else \"0-0-0\",\n]\n";

    const WANTED: &[u8] =
        b"a = [\n    (x, y),\n    # a remark\n    f\"aaa\" if PYPY else \"0-0-0\",\n]\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(ARENA_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(WANTED)
    );
}

#[test]
fn a_target_list_takes_the_pair_the_values_own_wrap_leaves_no_room_for() {
    const SOURCE: &[u8] = b"class C:\n    def f(self, chunk):\n        try:\n            wFormatTag, self._nchannels, self._framerate, dwAvgBytesPerSec, wBlockAlign = struct.unpack_from(\"<HHLLH\", chunk.read(14))\n        except struct.error:\n            raise EOFError from None\n        wFormatTag, self._nchannels, wBlockAlign = struct.unpack_from(\"<HHLLH\", chunk)\n";
    const WANTED: &[u8] = b"class C:\n    def f(self, chunk):\n        try:\n            (\n                wFormatTag,\n                self._nchannels,\n                self._framerate,\n                dwAvgBytesPerSec,\n                wBlockAlign,\n            ) = struct.unpack_from(\"<HHLLH\", chunk.read(14))\n        except struct.error:\n            raise EOFError from None\n        wFormatTag, self._nchannels, wBlockAlign = struct.unpack_from(\"<HHLLH\", chunk)\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(ARENA_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(WANTED)
    );
}

#[test]
fn a_unary_prefixs_power_operand_takes_the_parentheses() {
    const SOURCE: &[u8] = b"a = -2**31\nb = ~a ** 2\nc = -256 ** (digits - 1)\nd = -(-1) ** self._sign\ne = 2**31\nf = a**-b\ng = -2**31 + 1\nh = not a**2\n";
    const WANTED: &[u8] = b"a = -(2**31)\nb = ~(a**2)\nc = -(256 ** (digits - 1))\nd = -((-1) ** self._sign)\ne = 2**31\nf = a**-b\ng = -(2**31) + 1\nh = not (a**2)\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(ARENA_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(WANTED)
    );
}

#[test]
fn a_targets_last_bracket_parts_where_the_values_own_head_runs_past_the_width() {
    const SOURCE: &[u8] = b"obj.fields[\"groups\"].help_text = \"These groups give the users the different rights they hold\"\nobj.fieldsandmore[\"groups\"] = \"These groups give the users the different rights they hold\"\nobj.fields[\"action\"].choices = self.get_the_action_choices_for_this_given_location(request)\nobj.fields[\"action\"].choices = self.get_the_action_choices_for_this_given_location_and_more(request)\n";
    const WANTED: &[u8] = b"obj.fields[\n    \"groups\"\n].help_text = \"These groups give the users the different rights they hold\"\nobj.fieldsandmore[\"groups\"] = (\n    \"These groups give the users the different rights they hold\"\n)\nobj.fields[\"action\"].choices = self.get_the_action_choices_for_this_given_location(\n    request\n)\nobj.fields[\n    \"action\"\n].choices = self.get_the_action_choices_for_this_given_location_and_more(request)\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(ARENA_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(WANTED)
    );
}

#[test]
fn a_chains_pair_stands_at_the_last_target_whose_own_head_fits() {
    const SOURCE: &[u8] = b"self.hideid = self.keypressid = self.listupdateid = self.winconfigid = self.keyreleaseid = self.doubleclickid = None\nreal_test_settings[\"USER\"] = real_settings[\"USER\"] = test_settings[\"USER\"] = (\n    self.connection.settings_dict[\"USER\"]\n) = parameters[\"user\"]\n";
    const WANTED: &[u8] = b"self.hideid = self.keypressid = self.listupdateid = self.winconfigid = (\n    self.keyreleaseid\n) = self.doubleclickid = None\nreal_test_settings[\"USER\"] = real_settings[\"USER\"] = test_settings[\n    \"USER\"\n] = self.connection.settings_dict[\"USER\"] = parameters[\"user\"]\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(ARENA_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(WANTED)
    );
}
