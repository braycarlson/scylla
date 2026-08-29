#[path = "common/corpus.rs"]
mod corpus;
#[path = "common/floor.rs"]
mod floor;

use std::fs;
use std::path::PathBuf;

use scylla::bounded::{BoundedVec, Buffer, Span};
use scylla::format::css::{Formatter, Input, Outcome};
use scylla::format::print::Options;
use scylla::language::Lexer as _;
use scylla::lex::CSS;
use scylla::syntax::css::classify::classify;
use scylla::syntax::css::kind::CSSKind;
use scylla::syntax::css::parse;
use scylla::token::{TokenKind, Tokens};
use scylla::tree::{Events, Tree};

const ELEMENT_COUNT_MAX: u32 = 1 << 18;
const ERROR_COUNT_MAX: u32 = 1 << 12;
const EVENT_COUNT_MAX: u32 = 1 << 20;
const NODE_COUNT_MAX: u32 = 1 << 18;
const OUT_BYTES_MAX: u32 = 1 << 22;
const TOKEN_COUNT_MAX: u32 = 1 << 18;

struct Held {
    events: Events<CSSKind>,
    formatter: Formatter,
    lexed: Tokens,
    raw: BoundedVec<CSSKind>,
    tokens: Tokens,
    tree: Tree<CSSKind>,
}

impl Held {
    fn reserve() -> Self {
        Self {
            events: Events::reserve(EVENT_COUNT_MAX),
            formatter: Formatter::reserve(ELEMENT_COUNT_MAX),
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

        CSS.lex(source, &mut self.lexed);

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

        CSS.lex(source, &mut self.lexed);

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
        CSS.lex(source, &mut self.lexed);

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

    fn kinds(&mut self, source: &[u8]) -> Vec<CSSKind> {
        self.lexed.clear();
        self.raw.clear();
        self.tokens.clear();

        CSS.lex(source, &mut self.lexed);

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

        CSS.lex(source, &mut self.lexed);

        assert!(classify(
            source,
            self.lexed.as_slice(),
            &mut self.tokens,
            &mut self.raw
        ));

        self.raw
            .iter()
            .enumerate()
            .filter(|(_, kind)| **kind == CSSKind::Comment)
            .map(|(index, _)| {
                source[self.tokens.as_slice()[index].span().range()]
                    .trim_ascii_end()
                    .to_vec()
            })
            .collect()
    }
}

fn fixtures() -> Vec<(String, Vec<u8>)> {
    let root = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/css");
    let mut found = Vec::new();

    for entry in fs::read_dir(&root).expect("the fixture directory is readable") {
        let path = entry.expect("the entry is readable").path();

        if path.extension().is_none_or(|extension| extension != "css") {
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

        let differed = before
            .iter()
            .zip(after.iter())
            .position(|(left, right)| left != right);

        assert_eq!(
            differed.map(|at| (
                format!(
                    "{:?}",
                    &before[at.saturating_sub(4)..(at + 4).min(before.len())]
                ),
                format!(
                    "{:?}",
                    &after[at.saturating_sub(4)..(at + 4).min(after.len())]
                )
            )),
            None,
            "{name} lost or gained a token"
        );
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

const EVERY_CATEGORY: [&str; 2] = ["biome-line-breaking", "biome-value-syntax"];

#[test]
fn the_formatted_output_matches_the_oracle_modulo_residue() {
    let carried = oracle::residue_of("residue-format-css.json", &EVERY_CATEGORY);
    let root = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/golden-biome-css");
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
            "{name} diverges from biome and no residue row names it"
        );

        compared += 1;
    }

    assert!(
        compared >= floor::FIXTURE_FORMAT_CSS,
        "the CSS fixtures lost a formatting: {compared} compared, floor {}",
        floor::FIXTURE_FORMAT_CSS
    );
}

#[test]
fn every_residue_row_names_a_fixture_that_diverges() {
    let carried = oracle::residue_of("residue-format-css.json", &EVERY_CATEGORY);
    let root = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/golden-biome-css");
    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    for name in &carried {
        let source = fs::read(
            PathBuf::from(env!("CARGO_MANIFEST_DIR"))
                .join("tests/fixtures/css")
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
            "{name} matches biome and needs no residue row"
        );
    }
}

#[test]
fn a_file_that_does_not_parse_is_refused() {
    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(b"a {\n", &mut out), Outcome::Refusal);
    assert!(out.is_empty());
}

#[test]
fn a_source_that_never_closes_a_string_or_a_comment_is_refused() {
    const SOURCES: [&[u8]; 5] = [
        b"\"",
        b"' ",
        b"/* ",
        b"a { content: \"x; }\n",
        b"a { content: 'x }\n",
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
fn an_escaped_quote_in_a_selector_opens_no_string() {
    let source: &[u8] = b".tw\\:bg-\\[url\\(\\'x.png\\'\\)\\] { background: url(a.png); }\n";
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

    assert!(String::from_utf8_lossy(&once).contains("background: url(a.png)"));
}

#[test]
fn a_trailing_escape_reads_the_same_with_or_without_a_final_newline() {
    let mut held = Held::reserve();
    let mut bare = Buffer::reserve(OUT_BYTES_MAX);
    let mut ended = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(b"gin: ol\\", &mut bare), Outcome::Complete);
    assert_eq!(held.format(b"gin: ol\\\n", &mut ended), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(bare.as_bytes()),
        String::from_utf8_lossy(ended.as_bytes())
    );
}

#[test]
fn a_range_reads_back_the_lines_it_names() {
    let source: &[u8] = b".a{\ncolor:red;\n}\n";
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

            if path.extension().is_none_or(|extension| extension != "css") {
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

        assert_eq!(before, after, "{name} split, joined, lost, or gained a word");
    }
}
