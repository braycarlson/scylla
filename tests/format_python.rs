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

                String::from_utf8_lossy(token.text(source)).into_owned()
            })
            .collect::<Vec<String>>();

        let mut found = Vec::with_capacity(held.len());

        for (index, word) in held.iter().enumerate() {
            let trailing = word == ","
                && held
                    .get(index + 1)
                    .is_some_and(|next| matches!(next.as_str(), ")" | "]" | "}"));

            if trailing || word == "(" || word == ")" {
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
                    PythonKind::Dedent | PythonKind::Indent | PythonKind::Newline
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
                source[self.tokens.as_slice()[index].span().range()]
                    .trim_ascii_end()
                    .to_vec()
            })
            .collect()
    }
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

fn preserved(before: &[PythonKind], after: &[PythonKind]) -> bool {
    let mut held = 0;

    for kind in after {
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

        assert_eq!(before, after, "{name} split, joined, lost, or gained a word");
    }
}
