#[path = "common/corpus.rs"]
mod corpus;
#[path = "common/floor.rs"]
mod floor;

use std::fs;
use std::path::PathBuf;

use scylla::bounded::{BoundedVec, Buffer, Span};
use scylla::format::odin::{Formatter, Input, Outcome};
use scylla::format::print::Options;
use scylla::language::Lexer as _;
use scylla::lex::ODIN;
use scylla::syntax::odin::classify::classify;
use scylla::syntax::odin::kind::OdinKind;
use scylla::syntax::odin::parse;
use scylla::token::{TokenKind, Tokens};
use scylla::tree::{Events, Tree};

const ELEMENT_COUNT_MAX: u32 = 1 << 18;
const ERROR_COUNT_MAX: u32 = 1 << 12;
const EVENT_COUNT_MAX: u32 = 1 << 20;
const NODE_COUNT_MAX: u32 = 1 << 18;
const OUT_BYTES_MAX: u32 = 1 << 22;
const TOKEN_COUNT_MAX: u32 = 1 << 18;

struct Held {
    events: Events<OdinKind>,
    formatter: Formatter,
    lexed: Tokens,
    raw: BoundedVec<OdinKind>,
    tokens: Tokens,
    tree: Tree<OdinKind>,
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

        ODIN.lex(source, &mut self.lexed);

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
            options: Options {
                tabs: true,
                ..Options::DEFAULT
            },
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

        ODIN.lex(source, &mut self.lexed);

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
            options: Options {
                tabs: true,
                ..Options::DEFAULT
            },
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
        ODIN.lex(source, &mut self.lexed);

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

    fn kinds(&mut self, source: &[u8]) -> Vec<OdinKind> {
        self.lexed.clear();
        self.raw.clear();
        self.tokens.clear();

        ODIN.lex(source, &mut self.lexed);

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

        ODIN.lex(source, &mut self.lexed);

        assert!(classify(
            source,
            self.lexed.as_slice(),
            &mut self.tokens,
            &mut self.raw
        ));

        self.raw
            .iter()
            .enumerate()
            .filter(|(_, kind)| **kind == OdinKind::Comment)
            .map(|(index, _)| {
                source[self.tokens.as_slice()[index].span().range()]
                    .trim_ascii_end()
                    .to_vec()
            })
            .collect()
    }
}

fn dumped(root: &PathBuf) -> bool {
    fs::read_dir(root).is_ok_and(|mut entries| entries.next().is_some())
}

fn fixtures() -> Vec<(String, Vec<u8>)> {
    let root = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/odin");
    let mut found = Vec::new();

    for entry in fs::read_dir(&root).expect("the fixture directory is readable") {
        let path = entry.expect("the entry is readable").path();

        if path.extension().is_none_or(|extension| extension != "odin") {
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
        if held.format(&source, &mut first) != Outcome::Complete {
            continue;
        }

        let once = first.as_bytes().to_vec();

        assert_eq!(held.format(&once, &mut second), Outcome::Complete, "{name}");

        assert_eq!(
            String::from_utf8_lossy(second.as_bytes()),
            String::from_utf8_lossy(&once),
            "{name} is not idempotent"
        );
    }
}

#[test]
fn formatting_keeps_every_token_it_was_given() {
    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    for (name, source) in fixtures() {
        if held.format(&source, &mut out) != Outcome::Complete {
            continue;
        }

        let formatted = out.as_bytes().to_vec();
        let before = held.kinds(&source);
        let after = held.kinds(&formatted);

        assert_eq!(before, after, "{name} lost or gained a token");
    }
}

#[test]
fn formatting_keeps_every_comment_it_was_given() {
    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    for (name, source) in fixtures() {
        if held.format(&source, &mut out) != Outcome::Complete {
            continue;
        }

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
        if held.format(&source, &mut out) != Outcome::Complete {
            continue;
        }

        fs::write(PathBuf::from(&root).join(name), out.as_bytes())
            .expect("the dump directory is writable");
    }
}

#[path = "common/oracle.rs"]
mod oracle;

const EVERY_CATEGORY: [&str; 1] = ["odinfmt-absent"];

#[test]
fn the_formatted_output_matches_the_oracle_modulo_residue() {
    let carried = oracle::residue_of("residue-format-odin.json", &EVERY_CATEGORY);
    let root = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/golden-odinfmt");

    if !dumped(&root) {
        return;
    }

    let mut compared = 0;
    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    for (name, source) in fixtures() {
        if carried.contains(&name) {
            continue;
        }

        assert_eq!(
            held.format(&source, &mut out),
            Outcome::Complete,
            "{name} is refused and no residue row names it"
        );

        let golden = fs::read(root.join(&name)).expect("the golden is dumped");

        assert_eq!(
            String::from_utf8_lossy(out.as_bytes()),
            String::from_utf8_lossy(&golden),
            "{name} diverges from odinfmt and no residue row names it"
        );

        compared += 1;
    }

    assert!(
        compared >= floor::FIXTURE_FORMAT_ODIN,
        "the Odin fixtures lost a formatting: {compared} compared, floor {}",
        floor::FIXTURE_FORMAT_ODIN
    );
}

#[test]
fn every_residue_row_names_a_fixture_that_diverges() {
    let carried = oracle::residue_of("residue-format-odin.json", &EVERY_CATEGORY);
    let root = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/golden-odinfmt");

    if !dumped(&root) {
        return;
    }

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    for name in &carried {
        let source = fs::read(
            PathBuf::from(env!("CARGO_MANIFEST_DIR"))
                .join("tests/fixtures/odin")
                .join(name),
        )
        .expect("the residue row names a fixture");

        if held.format(&source, &mut out) != Outcome::Complete {
            continue;
        }

        let golden = fs::read(root.join(name)).expect("the golden is dumped");

        assert_ne!(
            out.as_bytes(),
            golden.as_slice(),
            "{name} matches odinfmt and needs no residue row"
        );
    }
}

#[test]
fn a_file_that_does_not_parse_is_refused() {
    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(
        held.format(b"main :: proc( {\n", &mut out),
        Outcome::Refusal
    );

    assert!(out.is_empty());
}

#[test]
fn a_line_continuation_does_not_break_the_statement_it_joins() {
    let source: &[u8] =
        b"package p\n\nf :: proc() {\n\tif a == 1 \\\n\t|| b == 2 {\n\t\tc := 3\n\t}\n}\n";
    let mut held = Held::reserve();
    let mut first = Buffer::reserve(OUT_BYTES_MAX);
    let mut second = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(source, &mut first), Outcome::Complete);

    let once = first.as_bytes().to_vec();

    assert_eq!(held.format(&once, &mut second), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(second.as_bytes()),
        String::from_utf8_lossy(&once)
    );
}

#[test]
fn an_unclosed_triple_quoted_string_is_refused() {
    const SOURCES: [&[u8]; 4] = [
        b"\"\"\"",
        b"\"\"\"\n",
        b"```",
        b"\"\"\"\"\"\"\"\"\"\"\"\"\"\"\"",
    ];

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
}

#[test]
fn a_closed_triple_quoted_string_still_formats() {
    let source: &[u8] = b"main :: proc() {\n\ttext := \"\"\"a\nb\"\"\"\n}\n";
    let mut held = Held::reserve();
    let mut first = Buffer::reserve(OUT_BYTES_MAX);
    let mut second = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(source, &mut first), Outcome::Complete);

    let once = first.as_bytes().to_vec();

    assert_eq!(held.format(&once, &mut second), Outcome::Complete);
    assert_eq!(second.as_bytes(), once);
}

#[test]
fn a_mark_that_was_apart_from_its_name_is_not_glued_to_it() {
    let source: &[u8] = b"@\x0c@\x0c\xc0";
    let mut held = Held::reserve();
    let mut first = Buffer::reserve(OUT_BYTES_MAX);
    let mut second = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(source, &mut first), Outcome::Complete);

    let once = first.as_bytes().to_vec();

    assert_eq!(held.format(&once, &mut second), Outcome::Complete);
    assert_eq!(second.as_bytes(), once);
}

#[test]
fn a_mark_written_against_its_name_stays_against_it() {
    let source: &[u8] = b"@(private)\nmain :: proc() {\n\t#partial switch x {\n\t}\n}\n";
    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(source, &mut out), Outcome::Complete);

    let formatted = String::from_utf8_lossy(out.as_bytes()).into_owned();

    assert!(formatted.contains("@(private)"), "{formatted}");
    assert!(formatted.contains("#partial switch"), "{formatted}");
}

#[test]
fn a_build_tag_keeps_no_blank_between_itself_and_the_comment_it_trails() {
    const SOURCES: [&[u8]; 3] = [
        b"#+build linux // only there\npackage main\n",
        b"#+private //x\n",
        b"#+//&",
    ];

    let mut held = Held::reserve();
    let mut first = Buffer::reserve(OUT_BYTES_MAX);
    let mut second = Buffer::reserve(OUT_BYTES_MAX);

    for source in SOURCES {
        assert_eq!(
            held.format(source, &mut first),
            Outcome::Complete,
            "{:?}",
            String::from_utf8_lossy(source)
        );

        let once = first.as_bytes().to_vec();

        assert_eq!(held.format(&once, &mut second), Outcome::Complete);

        assert_eq!(
            second.as_bytes(),
            once,
            "{:?} grows a blank each pass",
            String::from_utf8_lossy(source)
        );
    }
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
fn a_dot_apart_from_a_digit_is_not_glued_into_a_number() {
    let source: &[u8] = b"d.\x0c0";
    let mut held = Held::reserve();
    let mut first = Buffer::reserve(OUT_BYTES_MAX);
    let mut second = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(source, &mut first), Outcome::Complete);

    let once = first.as_bytes().to_vec();

    assert_eq!(held.format(&once, &mut second), Outcome::Complete);
    assert_eq!(second.as_bytes(), once);
}

#[test]
fn a_dot_written_against_its_field_stays_against_it() {
    let source: &[u8] = b"main :: proc() {\n\tx := held . field\n\ty := held.other\n}\n";
    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(source, &mut out), Outcome::Complete);

    let formatted = String::from_utf8_lossy(out.as_bytes()).into_owned();

    assert!(formatted.contains("held.field"), "{formatted}");
    assert!(formatted.contains("held.other"), "{formatted}");
}

#[test]
fn a_range_reads_back_the_lines_it_names() {
    let source: &[u8] = b"main :: proc() {\nx:=1\n}\n";
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

            if path.extension().is_none_or(|extension| extension != "odin") {
                continue;
            }

            let Ok(source) = fs::read(&path) else {
                continue;
            };

            if held.format(&source, &mut first) != Outcome::Complete {
                continue;
            }

            let once = first.as_bytes().to_vec();
            let before = held.kinds(&source);
            let after = held.kinds(&once);

            assert_eq!(before.len(), after.len(), "{} lost a token", path.display());
            assert_eq!(before, after, "{} lost a token", path.display());

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

#[test]
fn the_fixtures_are_already_formatted() {
    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    for (name, source) in fixtures() {
        assert_eq!(held.format(&source, &mut out), Outcome::Complete, "{name}");

        assert_eq!(
            String::from_utf8_lossy(out.as_bytes()),
            String::from_utf8_lossy(&source),
            "{name} is not what the formatter writes"
        );
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
        let before = held.words(&source);
        let after = held.words(&formatted);

        assert_eq!(
            before, after,
            "{name} split, joined, lost, or gained a word"
        );
    }
}
