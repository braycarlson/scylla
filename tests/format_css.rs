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
                remarked(source[self.tokens.as_slice()[index].span().range()].trim_ascii_end())
            })
            .collect()
    }
}

fn remarked(text: &[u8]) -> Vec<u8> {
    let mut lines = text.split(|byte| *byte == b'\n');
    let held = lines.next();

    let starred = text.starts_with(b"/**")
        && held.is_some()
        && lines.clone().count() > 0
        && lines.all(|line| line.trim_ascii_start().starts_with(b"*"));

    if !starred {
        return text.to_vec();
    }

    let mut found = Vec::new();

    for (index, line) in text.split(|byte| *byte == b'\n').enumerate() {
        if index > 0 {
            found.push(b'\n');
        }

        found.extend_from_slice(if index == 0 { line } else { line.trim_ascii() });
    }

    found
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

fn swapped(before: &[CSSKind], held: usize, after: &[CSSKind], index: usize) -> bool {
    before.get(held) == Some(&CSSKind::Comma)
        && before.get(held + 1) == Some(&CSSKind::Comment)
        && after.get(index) == Some(&CSSKind::Comment)
        && after.get(index + 1) == Some(&CSSKind::Comma)
}

fn preserved(before: &[CSSKind], after: &[CSSKind]) -> bool {
    let mut held = 0;
    let mut index = 0;

    while index < after.len() {
        if held < before.len() {
            if let Some(taken) = counted(before, held, after, index) {
                held += 1;
                index += taken;

                continue;
            }
        }

        if swapped(before, held, after, index) {
            held += 2;
            index += 2;

            continue;
        }

        if held < before.len() && kept(before[held], after[index], after, index) {
            held += 1;
            index += 1;

            continue;
        }

        if after[index] != CSSKind::Semicolon {
            return false;
        }

        index += 1;
    }

    held == before.len()
}

fn counted(before: &[CSSKind], held: usize, after: &[CSSKind], index: usize) -> Option<usize> {
    let signed = matches!(after.get(index), Some(CSSKind::Minus | CSSKind::Plus))
        && after.get(index + 1) == Some(&CSSKind::Number)
        && index > 0
        && matches!(after[index - 1], CSSKind::Identifier | CSSKind::Unit);

    if signed && before[held] == CSSKind::Number {
        return Some(2);
    }

    let stepped = matches!(after.get(index), Some(CSSKind::Identifier | CSSKind::Unit))
        && matches!(after.get(index + 1), Some(CSSKind::Minus | CSSKind::Plus))
        && after.get(index + 2) == Some(&CSSKind::Number)
        && before.get(held + 1) != Some(&CSSKind::Number);

    (stepped && before[held] == CSSKind::Identifier).then_some(3)
}

fn collapsed(kind: CSSKind) -> CSSKind {
    if kind == CSSKind::Float {
        CSSKind::Number
    } else {
        kind
    }
}

fn kept(source: CSSKind, printed: CSSKind, after: &[CSSKind], index: usize) -> bool {
    if collapsed(source) == collapsed(printed) {
        return true;
    }

    if matches!(source, CSSKind::Identifier | CSSKind::Unit)
        && matches!(printed, CSSKind::Identifier | CSSKind::Unit)
    {
        return true;
    }

    source == CSSKind::Identifier
        && printed == CSSKind::Text
        && index > 0
        && matches!(
            after[index - 1],
            CSSKind::BarEqual
                | CSSKind::CaretEqual
                | CSSKind::DollarEqual
                | CSSKind::Equal
                | CSSKind::StarEqual
                | CSSKind::TildeEqual
        )
}

fn worded(before: &[String], after: &[String]) -> bool {
    let mut held = 0;

    for (index, word) in after.iter().enumerate() {
        let quoted = word == "<string>"
            && index > 0
            && matches!(
                after[index - 1].as_str(),
                "*=" | "=" | "^=" | "|=" | "~=" | "$="
            );

        if held < before.len() && (before[held] == *word || quoted) {
            held += 1;

            continue;
        }

        if word != ";" {
            return false;
        }
    }

    held == before.len()
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

        assert!(
            preserved(&before, &after),
            "{name} lost or gained a token: {before:?} against {after:?}"
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
fn a_descendant_combinator_before_a_pseudo_class_survives() {
    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(
        held.format(b"div :hover { color: red; }\n", &mut out),
        Outcome::Complete
    );

    assert!(
        String::from_utf8_lossy(out.as_bytes()).starts_with("div :hover"),
        "{}",
        String::from_utf8_lossy(out.as_bytes())
    );

    assert_eq!(
        held.format(b"div:hover { color: red; }\n", &mut out),
        Outcome::Complete
    );

    assert!(
        String::from_utf8_lossy(out.as_bytes()).starts_with("div:hover"),
        "{}",
        String::from_utf8_lossy(out.as_bytes())
    );
}

#[test]
fn a_declaration_loses_the_space_before_its_colon() {
    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(
        held.format(b"a { color : red; --held : blue; }\n", &mut out),
        Outcome::Complete
    );

    let formatted = String::from_utf8_lossy(out.as_bytes()).into_owned();

    assert!(formatted.contains("color: red"), "{formatted}");
    assert!(formatted.contains("--held: blue"), "{formatted}");
}

#[test]
fn a_dropped_byte_between_two_tokens_writes_no_space_before_a_comma() {
    let source: &[u8] = b"E:2E%\xef\xbb\xbf,";
    let mut held = Held::reserve();
    let mut first = Buffer::reserve(OUT_BYTES_MAX);
    let mut second = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(source, &mut first), Outcome::Complete);

    let once = first.as_bytes().to_vec();

    assert_eq!(String::from_utf8_lossy(&once), "E:2E%,\n");
    assert_eq!(held.format(&once, &mut second), Outcome::Complete);
    assert_eq!(second.as_bytes(), once);
}

#[test]
fn a_dot_run_a_selector_wrote_tight_stays_tight() {
    let source: &[u8] = b"a:b...";
    let mut held = Held::reserve();
    let mut first = Buffer::reserve(OUT_BYTES_MAX);
    let mut second = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(source, &mut first), Outcome::Complete);

    let once = first.as_bytes().to_vec();

    assert_eq!(String::from_utf8_lossy(&once), "a:b...\n");
    assert_eq!(held.format(&once, &mut second), Outcome::Complete);
    assert_eq!(second.as_bytes(), once);
}

#[test]
fn an_at_rule_above_a_pseudo_class_selector_formats_twice() {
    let source: &[u8] = b"@charset\nh :(\"\")";
    let mut held = Held::reserve();
    let mut first = Buffer::reserve(OUT_BYTES_MAX);
    let mut second = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(source, &mut first), Outcome::Complete);

    let once = first.as_bytes().to_vec();

    assert_eq!(held.format(&once, &mut second), Outcome::Complete);
    assert_eq!(second.as_bytes(), once);
}

#[test]
fn a_hash_with_no_name_does_not_swallow_the_brace_that_closes_its_block() {
    const SOURCES: [&[u8]; 3] = [b"{#}h:;", b"{#} h:;\n", b"{}{#}h:;"];

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

        assert_eq!(
            held.format(&once, &mut second),
            Outcome::Complete,
            "{:?}",
            String::from_utf8_lossy(&once)
        );

        assert_eq!(second.as_bytes(), once);
    }
}

#[test]
fn an_id_selector_still_takes_the_name_written_against_it() {
    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(
        held.format(b"#main { color: #fff; }\n", &mut out),
        Outcome::Complete
    );

    let formatted = String::from_utf8_lossy(out.as_bytes()).into_owned();

    assert!(formatted.contains("#main"), "{formatted}");
    assert!(formatted.contains("#fff"), "{formatted}");
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

            assert!(
                preserved(&before, &after),
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
        let before = held.words(&source);
        let after = held.words(&formatted);

        assert!(
            worded(&before, &after),
            "{name} split, joined, lost, or gained a word"
        );
    }
}

#[test]
fn a_slash_in_a_value_parts_from_what_it_stands_between() {
    const SOURCE: &[u8] =
        b"a {\n    font: normal 16px/1 codicon;\n    grid-area: 1/2/3/4;\n    background: url(a/b.png);\n}\n";

    const WANTED: &[u8] =
        b"a {\n    font: normal 16px / 1 codicon;\n    grid-area: 1 / 2 / 3 / 4;\n    background: url(a/b.png);\n}\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(WANTED)
    );
}

#[test]
fn a_star_led_comment_is_written_under_the_column_it_opens_on() {
    const SOURCE: &[u8] =
        b"a {\n\t/**\n\t * held\n\t */\n\tcolor: red;\n\t/*\n\t * held\n\t */\n\tmargin: 0;\n}\n";

    const WANTED: &[u8] = b"a {\n    /**\n     * held\n     */\n    color: red;\n    /*\n\t * held\n\t */\n    margin: 0;\n}\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(WANTED)
    );
}

#[test]
fn a_child_count_takes_the_one_form_the_reference_writes() {
    const SOURCE: &[u8] =
        b"a:nth-last-child(n+3),\nb:nth-child(2N-1),\nc:nth-of-type(odd) {\n    color: red;\n}\n";

    const WANTED: &[u8] =
        b"a:nth-last-child(n + 3),\nb:nth-child(2n - 1),\nc:nth-of-type(odd) {\n    color: red;\n}\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(WANTED)
    );
}

#[test]
fn a_custom_property_fills_its_value_where_a_named_one_parts_it() {
    const SOURCE: &[u8] = b"a {\n    --held-shadow-value: inset 0 1px 0 rgba(255, 255, 255, 0.15), 0 1px 1px rgba(0, 0, 0, 0.075);\n    box-shadow: inset 0 1px 0 rgba(255, 255, 255, 0.15), 0 1px 1px rgba(0, 0, 0, 0.075);\n}\n";
    const WANTED: &[u8] = b"a {\n    --held-shadow-value:\n        inset 0 1px 0 rgba(255, 255, 255, 0.15), 0 1px 1px rgba(0, 0, 0, 0.075);\n    box-shadow:\n        inset 0 1px 0 rgba(255, 255, 255, 0.15),\n        0 1px 1px rgba(0, 0, 0, 0.075);\n}\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(WANTED)
    );
}

#[test]
fn a_remarked_rule_of_two_compounds_parts_them_at_its_own_level() {
    const SOURCE: &[u8] = b"/* held */\n.aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa .bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb {\n    color: red;\n}\n";
    const WANTED: &[u8] = b"/* held */\n.aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n.bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb {\n    color: red;\n}\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(WANTED)
    );
}

#[test]
fn a_remark_past_a_declaration_counts_toward_the_width_its_value_parts_at() {
    const SOURCE: &[u8] = b"a {\n    zoom: var(--zoom-factor); /* helps to position the menu properly when counter zooming */\n}\n";
    const WANTED: &[u8] = b"a {\n    zoom: var(\n        --zoom-factor\n    ); /* helps to position the menu properly when counter zooming */\n}\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(WANTED)
    );
}

#[test]
fn a_star_in_a_value_parts_and_a_known_at_rule_is_lowercased() {
    const SOURCE: &[u8] =
        b"@IMporT url(\"held.css\");\na {\n    padding-right: calc(var(--held-font-size)*0.5);\n}\n";

    const WANTED: &[u8] =
        b"@import url(\"held.css\");\na {\n    padding-right: calc(var(--held-font-size) * 0.5);\n}\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(WANTED)
    );
}

#[test]
fn a_value_of_several_components_indents_the_call_it_holds_one_level_in() {
    const SOURCE: &[u8] = b".a {\n    border-image: linear-gradient(90deg, var(--aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa), var(--bbbbbbbbbbbbbbbbbb)) 1;\n}\n";
    const WANTED: &[u8] = b".a {\n    border-image: linear-gradient(\n            90deg,\n            var(--aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa),\n            var(--bbbbbbbbbbbbbbbbbb)\n        )\n        1;\n}\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(WANTED)
    );
}

#[test]
fn a_layer_parts_at_its_own_call_and_the_layer_past_it_opens_a_line() {
    const SOURCE: &[u8] = b".a {\n    background:\n        radial-gradient(ellipse 128% 102% at 100% 100%, color-mix(in srgb, var(--vscode-agentsGradient-tintColor) 9%, transparent) 0%, transparent 60%),\n        var(--vscode-agents-background);\n}\n";
    const WANTED: &[u8] = b".a {\n    background:\n        radial-gradient(\n            ellipse 128% 102% at 100% 100%,\n            color-mix(in srgb, var(--vscode-agentsGradient-tintColor) 9%, transparent)\n                0%,\n            transparent 60%\n        ),\n        var(--vscode-agents-background);\n}\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(WANTED)
    );
}

#[test]
fn an_argument_is_measured_without_the_comma_it_ends_on() {
    const SOURCE: &[u8] = b".a {\n    border-image: linear-gradient(90deg, var(--vscode-editorGutter-addedBackground) var(--inline-chat-frame-progress), var(--vscode-button-background)) 1;\n}\n";
    const WANTED: &[u8] = b".a {\n    border-image: linear-gradient(\n            90deg,\n            var(--vscode-editorGutter-addedBackground) var(--inline-chat-frame-progress),\n            var(--vscode-button-background)\n        )\n        1;\n}\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(WANTED)
    );
}

#[test]
fn a_compound_parts_at_the_pseudo_that_runs_past_the_next_break() {
    const SOURCE: &[u8] = b".input-group > :not(:first-child):not(.dropdown-menu):not(.valid-tooltip):not(.valid-feedback):not(.invalid-tooltip):not(.invalid-feedback) {\n    margin-left: 0;\n}\n";
    const WANTED: &[u8] = b".input-group\n    > :not(:first-child):not(.dropdown-menu):not(.valid-tooltip):not(\n        .valid-feedback\n    ):not(.invalid-tooltip):not(.invalid-feedback) {\n    margin-left: 0;\n}\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(WANTED)
    );
}

#[test]
fn a_rules_own_brace_takes_a_blank_whatever_the_source_wrote() {
    const SOURCE: &[u8] = b"@keyframes held {\n    0%{\n        opacity: 0;\n    }\n}\n";
    const WANTED: &[u8] = b"@keyframes held {\n    0% {\n        opacity: 0;\n    }\n}\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(WANTED)
    );
}

#[test]
fn a_calc_parts_a_parenthesised_operand_and_the_operator_rides_the_line_it_closes() {
    const SOURCE: &[u8] = b".d {\n    width: calc(var(--aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa) - 1px);\n}\n.e {\n    width: calc((var(--aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa) - var(--bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb)) / 2);\n}\n";
    const WANTED: &[u8] = b".d {\n    width: calc(\n        var(\n            --aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n        ) -\n        1px\n    );\n}\n.e {\n    width: calc(\n        (\n            var(--aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa) -\n            var(--bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb)\n        ) /\n        2\n    );\n}\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(WANTED)
    );
}

#[test]
fn a_compound_parts_every_pseudo_argument_the_line_does_not_hold() {
    const SOURCE: &[u8] = b".chat-rich-link:is([data-chat-rich-link-kind=\"session\"], [data-chat-rich-link-kind=\"chat\"]):is([data-chat-rich-link-status=\"pending\"], [data-chat-rich-link-status=\"warning\"], [data-chat-rich-link-status=\"error\"]) .chat-rich-link-primary-status {\n    display: inline-flex;\n}\n.a {\n    .b {\n        > .monaco-scrollable-element:has(.chat-used-context-list.chat-thinking-collapsible:not(.chat-thinking-streaming)) {\n            overflow: hidden;\n        }\n    }\n}\n";
    const WANTED: &[u8] = b".chat-rich-link:is(\n        [data-chat-rich-link-kind=\"session\"],\n        [data-chat-rich-link-kind=\"chat\"]\n    ):is(\n        [data-chat-rich-link-status=\"pending\"],\n        [data-chat-rich-link-status=\"warning\"],\n        [data-chat-rich-link-status=\"error\"]\n    )\n    .chat-rich-link-primary-status {\n    display: inline-flex;\n}\n.a {\n    .b {\n        > .monaco-scrollable-element:has(\n                .chat-used-context-list.chat-thinking-collapsible:not(\n                        .chat-thinking-streaming\n                    )\n            ) {\n            overflow: hidden;\n        }\n    }\n}\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(WANTED)
    );
}

#[test]
fn a_brace_past_a_trailing_remark_keeps_the_line_the_remark_ends() {
    const SOURCE: &[u8] = b"#monaco-workbench-editor-drop-overlay .editor-group-overlay-drop-into-prompt i /* Style keybinding */ {\n    padding: 0 8px;\n}\n";
    const WANTED: &[u8] = b"#monaco-workbench-editor-drop-overlay\n    .editor-group-overlay-drop-into-prompt\n    i /* Style keybinding */ {\n    padding: 0 8px;\n}\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(WANTED)
    );
}

#[test]
fn a_remarked_rule_joins_its_first_two_compounds_only_under_a_named_head() {
    const SOURCE: &[u8] = b"/* The stroke lives on the fill. */\n:is(.hc-black, .hc-light).modern-ui-tabs.monaco-workbench .part.editor > .content .editor-group-container > .title {\n    outline: none;\n}\n/* The stroke lives on the fill. */\n.aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa .bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb .ccccccccccccccccccccccc {\n    outline: none;\n}\n";
    const WANTED: &[u8] = b"/* The stroke lives on the fill. */\n:is(.hc-black, .hc-light).modern-ui-tabs.monaco-workbench\n    .part.editor\n    > .content\n    .editor-group-container\n    > .title {\n    outline: none;\n}\n/* The stroke lives on the fill. */\n.aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa .bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n    .ccccccccccccccccccccccc {\n    outline: none;\n}\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(WANTED)
    );
}

#[test]
fn a_value_holding_a_slash_opens_the_line_under_the_property_it_names() {
    const SOURCE: &[u8] = b".a {\n    background: url(\"../../../../browser/media/code-icon.svg\") center / contain no-repeat;\n}\n.b {\n    .c {\n        font: normal normal normal calc(var(--vscode-testing-coverage-lineHeight) / 2) / 1 codicon;\n    }\n}\n";
    const WANTED: &[u8] = b".a {\n    background:\n        url(\"../../../../browser/media/code-icon.svg\") center / contain no-repeat;\n}\n.b {\n    .c {\n        font:\n            normal normal normal calc(var(--vscode-testing-coverage-lineHeight) / 2) / 1\n            codicon;\n    }\n}\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(WANTED)
    );
}

#[test]
fn a_paired_compounds_pseudo_argument_steps_one_level_from_the_rule() {
    const SOURCE: &[u8] = b"/* remark */\n.aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa:not(.bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb) .ccc {\n    a: 1;\n}\n.aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa:not(.bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb) .ccc {\n    a: 1;\n}\n";
    const WANTED: &[u8] = b"/* remark */\n.aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa:not(\n    .bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n)\n.ccc {\n    a: 1;\n}\n.aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa:not(\n        .bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n    )\n    .ccc {\n    a: 1;\n}\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(WANTED)
    );
}

#[test]
fn a_blank_line_inside_a_selector_list_is_dropped() {
    const SOURCE: &[u8] = b".a,\n\n.b {\n    color: red;\n}\n";
    const WANTED: &[u8] = b".a,\n.b {\n    color: red;\n}\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(WANTED)
    );
}

#[test]
fn a_selector_past_a_remark_inside_a_list_opens_one_level_in() {
    const SOURCE: &[u8] =
        b".head,\n/* one */\n.a .b .c,\n/* two */\n.d,\n/* three */\n.e .f {\n    color: red;\n}\n";

    const WANTED: &[u8] = b".head,\n/* one */\n    .a .b\n    .c,\n/* two */\n    .d,\n/* three */\n.e .f {\n    color: red;\n}\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(WANTED)
    );
}

#[test]
fn a_remark_standing_inside_a_value_writes_no_break_and_counts_toward_the_width() {
    const SOURCE: &[u8] = b"body {\n    background: #d3d6d8 /*url(\"does.not.exist.png\")*/ url(/static/cached/img/relative.png);\n}\nbody {\n    background: #d3d6d8 /*u*/ url(/static/img/rel.png);\n}\n";
    const WANTED: &[u8] = b"body {\n    background: #d3d6d8 /*url(\"does.not.exist.png\")*/\n        url(/static/cached/img/relative.png);\n}\nbody {\n    background: #d3d6d8 /*u*/ url(/static/img/rel.png);\n}\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(WANTED)
    );
}

#[test]
fn a_selectors_own_separator_stands_past_the_remark_that_trails_it() {
    const SOURCE: &[u8] = b".monaco-list:focus .selected .monaco-icon-label, /* list */\n.monaco-list:focus .selected .monaco-icon-label::after {\n    color: inherit;\n}\n";
    const WANTED: &[u8] = b".monaco-list:focus .selected .monaco-icon-label /* list */,\n.monaco-list:focus .selected .monaco-icon-label::after {\n    color: inherit;\n}\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(WANTED)
    );
}

#[test]
fn a_layers_own_call_stands_at_the_level_the_layer_opens_on() {
    const SOURCE: &[u8] = b".a {\n    cursor: image-set(url(\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\") 1x, url(\"bbbbbbbbbbbb\") 2x) 5 8, text;\n}\n";
    const WANTED: &[u8] = b".a {\n    cursor:\n        image-set(\n            url(\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\")\n                1x,\n            url(\"bbbbbbbbbbbb\") 2x\n        )\n        5 8,\n        text;\n}\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(WANTED)
    );
}

#[test]
fn a_grid_shorthand_keeps_the_lines_the_source_gave_its_value() {
    const SOURCE: &[u8] =
        b".b {\n    grid-template-areas:\n    \"x y\"\n    \"z w\";\n    grid-area:\n        one\n        two;\n}\n";

    const WANTED: &[u8] =
        b".b {\n    grid-template-areas:\n        \"x y\"\n        \"z w\";\n    grid-area: one two;\n}\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(WANTED)
    );
}

#[test]
fn a_custom_property_past_the_fill_cap_keeps_the_lines_the_source_gave_it() {
    const SOURCE: &[u8] = b":root {\n    --wide:\n        aaaaaaaaaa,\n        bbbbbbbbbb,\n        cccccccccc,\n        dddddddddd,\n        eeeeeeeeee,\n        ffffffffff,\n        gggggggggg,\n        hhhhhhhhhh,\n        iiiiiiiiii,\n        jjjjjjjjjj,\n        kkkkkkkkkk,\n        llllllllll,\n        mmmmmmmmmm;\n    --slim:\n        aa,\n        bb,\n        cc;\n}\n";
    const WANTED: &[u8] = b":root {\n    --wide:\n        aaaaaaaaaa,\n        bbbbbbbbbb,\n        cccccccccc,\n        dddddddddd,\n        eeeeeeeeee,\n        ffffffffff,\n        gggggggggg,\n        hhhhhhhhhh,\n        iiiiiiiiii,\n        jjjjjjjjjj,\n        kkkkkkkkkk,\n        llllllllll,\n        mmmmmmmmmm;\n    --slim: aa, bb, cc;\n}\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(WANTED)
    );
}
