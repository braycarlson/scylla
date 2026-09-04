#[path = "common/corpus.rs"]
mod corpus;
#[path = "common/floor.rs"]
mod floor;

use std::fs;
use std::path::PathBuf;

use scylla::bounded::{BoundedVec, Buffer, Span};
use scylla::format::go::{Formatter, Input, Outcome};
use scylla::format::print::Options;
use scylla::language::Lexer as _;
use scylla::lex::GO;
use scylla::syntax::go::classify::classify;
use scylla::syntax::go::kind::GoKind;
use scylla::syntax::go::parse;
use scylla::token::{TokenKind, Tokens};
use scylla::tree::{Events, Tree};

const ELEMENT_COUNT_MAX: u32 = 1 << 18;
const ERROR_COUNT_MAX: u32 = 1 << 12;
const EVENT_COUNT_MAX: u32 = 1 << 20;
const NODE_COUNT_MAX: u32 = 1 << 18;
const OUT_BYTES_MAX: u32 = 1 << 22;
const TOKEN_COUNT_MAX: u32 = 1 << 18;

struct Held {
    events: Events<GoKind>,
    formatter: Formatter,
    lexed: Tokens,
    raw: BoundedVec<GoKind>,
    tokens: Tokens,
    tree: Tree<GoKind>,
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

        GO.lex(source, &mut self.lexed);

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
                indent_width: 8,
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

        GO.lex(source, &mut self.lexed);

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
                indent_width: 8,
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
        GO.lex(source, &mut self.lexed);

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

    fn kinds(&mut self, source: &[u8]) -> Vec<GoKind> {
        self.lexed.clear();
        self.raw.clear();
        self.tokens.clear();

        GO.lex(source, &mut self.lexed);

        assert!(classify(
            source,
            self.lexed.as_slice(),
            &mut self.tokens,
            &mut self.raw
        ));

        let mut held: Vec<GoKind> = Vec::new();

        let carried: Vec<GoKind> = self
            .raw
            .iter()
            .enumerate()
            .filter(|(index, kind)| {
                if matches!(kind.name(), "Dedent" | "Indent" | "Newline") {
                    return false;
                }

                **kind != GoKind::Comment
                    || !constraining(&source[self.tokens.as_slice()[*index].span().range()])
            })
            .map(|(_, kind)| *kind)
            .collect();

        for kind in carried {
            if kind == GoKind::Comment && held.last() == Some(&GoKind::Comment) {
                continue;
            }

            held.push(kind);
        }

        held
    }

    fn comments(&mut self, source: &[u8]) -> Vec<Vec<u8>> {
        self.lexed.clear();
        self.raw.clear();
        self.tokens.clear();

        GO.lex(source, &mut self.lexed);

        assert!(classify(
            source,
            self.lexed.as_slice(),
            &mut self.tokens,
            &mut self.raw
        ));

        self.raw
            .iter()
            .enumerate()
            .filter(|(index, kind)| {
                **kind == GoKind::Comment
                    && !constraining(&source[self.tokens.as_slice()[*index].span().range()])
            })
            .flat_map(|(index, _)| {
                bodied(&source[self.tokens.as_slice()[index].span().range()])
                    .split(|byte| byte.is_ascii_whitespace())
                    .filter(|word| !word.is_empty())
                    .map(<[u8]>::to_vec)
                    .collect::<Vec<Vec<u8>>>()
            })
            .collect()
    }
}

fn fixtures() -> Vec<(String, Vec<u8>)> {
    let root = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/go");
    let mut found = Vec::new();

    for entry in fs::read_dir(&root).expect("the fixture directory is readable") {
        let path = entry.expect("the entry is readable").path();

        if path.extension().is_none_or(|extension| extension != "go") {
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

#[test]
fn formatting_keeps_every_token_it_was_given() {
    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    for (name, source) in fixtures() {
        assert_eq!(held.format(&source, &mut out), Outcome::Complete);

        let formatted = out.as_bytes().to_vec();
        let before = held.kinds(&source);
        let after = held.kinds(&formatted);

        assert_eq!(
            sequenced(&before),
            sequenced(&after),
            "{name} lost or gained a token"
        );

        assert_eq!(
            before.iter().filter(|kind| **kind == GoKind::Comment).count(),
            after.iter().filter(|kind| **kind == GoKind::Comment).count(),
            "{name} lost or gained a remark"
        );
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
    "gofmt-declaration-context",
    "gofmt-import-grouping",
    "gofmt-operator-precedence-spacing",
];

#[test]
fn the_formatted_output_matches_the_oracle_modulo_residue() {
    let carried = oracle::residue_of("residue-format-go.json", &EVERY_CATEGORY);
    let root = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/golden-gofmt");
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
            "{name} diverges from gofmt and no residue row names it"
        );

        compared += 1;
    }

    assert!(
        compared >= floor::FIXTURE_FORMAT_GO,
        "the Go fixtures lost a formatting: {compared} compared, floor {}",
        floor::FIXTURE_FORMAT_GO
    );
}

#[test]
fn every_residue_row_names_a_fixture_that_diverges() {
    let carried = oracle::residue_of("residue-format-go.json", &EVERY_CATEGORY);
    let root = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/golden-gofmt");
    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    for name in &carried {
        let source = fs::read(
            PathBuf::from(env!("CARGO_MANIFEST_DIR"))
                .join("tests/fixtures/go")
                .join(name),
        )
        .expect("the residue row names a fixture");

        assert_eq!(held.format(&source, &mut out), Outcome::Complete);

        let golden = fs::read(root.join(name)).expect("the golden is dumped");

        assert_ne!(
            out.as_bytes(),
            golden.as_slice(),
            "{name} matches gofmt and needs no residue row"
        );
    }
}

#[test]
fn a_file_that_does_not_parse_is_refused() {
    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(b"func f( {\n", &mut out), Outcome::Refusal);
    assert!(out.is_empty());
}

#[test]
fn a_source_that_never_closes_a_string_or_a_comment_is_refused() {
    const SOURCES: [&[u8]; 3] = [
        b"package packa/*iex",
        b"package fixtUre/* ",
        b"package p\n\nfunc f() {\n\ts := \"open\n}\n",
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
fn alignment_leaves_a_block_comment_the_text_it_was_given() {
    let source: &[u8] =
        b"package p\n\nfunc f() {\n\t/* 0 = block */\n\t/* 8 = stream */\n\ta := 1\n\tbb := 2\n}\n";
    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(source, &mut out), Outcome::Complete);

    let once = out.as_bytes().to_vec();

    assert_eq!(held.comments(source), held.comments(&once));
}

#[test]
fn alignment_leaves_the_bytes_of_a_raw_string_alone() {
    let source: &[u8] = b"package i\n\nfunc run() {\n\ttext := `n*/\n\t_ =\n\t=  =_ =`\n}\n";
    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(source, &mut out), Outcome::Complete);

    let formatted = String::from_utf8_lossy(out.as_bytes()).into_owned();

    assert!(formatted.contains("`n*/\n\t_ =\n\t=  =_ =`"), "{formatted}");
}

#[test]
fn a_quoted_backtick_does_not_open_a_raw_string_for_alignment() {
    let source: &[u8] = b"package i\n\nvar (\n\ttick = \"`\"\n\tone = 1\n\tlonger = 2\n)\n";
    let mut held = Held::reserve();
    let mut first = Buffer::reserve(OUT_BYTES_MAX);
    let mut second = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(source, &mut first), Outcome::Complete);

    let once = first.as_bytes().to_vec();
    let formatted = String::from_utf8_lossy(&once).into_owned();

    assert!(formatted.contains("one    = 1"), "{formatted}");
    assert_eq!(held.format(&once, &mut second), Outcome::Complete);
    assert_eq!(second.as_bytes(), once);
}

#[test]
fn a_channel_arrow_beside_a_unary_minus_formats_twice() {
    const SOURCES: [&[u8]; 2] = [b"package i\nfunc {m<--l:}", b"package i\nfunc {m<--\nn:}"];

    let mut held = Held::reserve();
    let mut first = Buffer::reserve(OUT_BYTES_MAX);
    let mut second = Buffer::reserve(OUT_BYTES_MAX);

    for source in SOURCES {
        if held.format(source, &mut first) != Outcome::Complete {
            continue;
        }

        let once = first.as_bytes().to_vec();

        assert_eq!(
            held.format(&once, &mut second),
            Outcome::Complete,
            "{}",
            String::from_utf8_lossy(&once)
        );

        assert_eq!(second.as_bytes(), once);
    }
}

#[test]
fn a_channel_send_keeps_its_unary_minus_apart() {
    let source: &[u8] = b"package i\n\nfunc run(c chan int, x int) {\n\tc <--x\n}\n";
    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(source, &mut out), Outcome::Complete);

    let formatted = String::from_utf8_lossy(out.as_bytes()).into_owned();

    assert!(formatted.contains("c <- -x"), "{formatted}");
}

#[test]
fn a_range_reads_back_the_lines_it_names() {
    let source: &[u8] = b"package main\n\nfunc f() {\nx := 1\n_ = x\n}\n";
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

            if path.extension().is_none_or(|extension| extension != "go") {
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
                kept(&before, &after),
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

fn sequenced(kinds: &[GoKind]) -> Vec<GoKind> {
    kinds
        .iter()
        .copied()
        .filter(|kind| *kind != GoKind::Comment)
        .collect()
}

fn kept(before: &[GoKind], after: &[GoKind]) -> bool {
    let held = sequenced(before);
    let printing = sequenced(after);
    let mut printed = 0;
    let mut source = 0;

    while source < held.len() && printed < printing.len() {
        if held[source] == printing[printed] {
            printed += 1;
            source += 1;

            continue;
        }

        if held[source] != GoKind::Semicolon {
            return false;
        }

        source += 1;
    }

    while source < held.len() && held[source] == GoKind::Semicolon {
        source += 1;
    }

    source == held.len() && printed == printing.len()
}

fn constraining(text: &[u8]) -> bool {
    let held = text.trim_ascii_start();

    held.starts_with(b"//go:build")
        || held
            .strip_prefix(b"//")
            .is_some_and(|rest| rest.trim_ascii_start().starts_with(b"+build"))
}

fn bodied(text: &[u8]) -> &[u8] {
    let held = text
        .strip_prefix(b"//")
        .or_else(|| text.strip_prefix(b"/*"))
        .unwrap_or(text);

    held.strip_suffix(b"*/").unwrap_or(held)
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

#[test]
fn a_field_remark_takes_no_column_of_its_own() {
    const SOURCE: &[u8] = b"package p\n\ntype T struct {\n\tA int `x` // a\n\tBcd string // b\n\tEf bool `yy` // e\n}\n";

    const WANTED: &[u8] =
        b"package p\n\ntype T struct {\n\tA   int    `x` // a\n\tBcd string // b\n\tEf  bool   `yy` // e\n}\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(WANTED)
    );
}

#[test]
fn a_field_type_takes_a_column_only_where_a_cell_stands_past_it() {
    const SOURCE: &[u8] = b"package p\n\ntype A struct {\n\tA int\n\tBcd string\n}\n\ntype B struct {\n\tA int // a\n\tBcd string // b\n}\n";
    const WANTED: &[u8] = b"package p\n\ntype A struct {\n\tA   int\n\tBcd string\n}\n\ntype B struct {\n\tA   int    // a\n\tBcd string // b\n}\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(WANTED)
    );
}

#[test]
fn a_statement_that_reads_like_a_field_takes_no_type_column() {
    const SOURCE: &[u8] = b"package p\n\nfunc f() {\n\tline1 := \"one\"\n\trestData := \"two\"\n\tuse(line1 + \"lib\" + restData)\n}\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(SOURCE)
    );
}

#[test]
fn an_operator_that_would_glue_into_a_longer_one_keeps_its_blanks() {
    const SOURCE: &[u8] =
        b"package p\n\nfunc f(x, y, z int) {\n\tif x & ^(y|z) != 0 {\n\t}\n\t_ = x&y + z\n}\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(SOURCE)
    );
}

#[test]
fn a_remark_under_a_continuation_stands_where_the_source_put_it() {
    const SOURCE: &[u8] = b"package p\n\nconst q = \"\" +\n\t\"a\" +\n\t\"\"\n\t// the run's own remark\n\nfunc f() {\n\tskip := 1 +\n\t\t2 +\n\t\t3\n\t// the statement's remark\n\tskip += 4\n\theld := 1 +\n\t\t2\n\t\t// the run's own remark\n\theld += 3\n\t_ = held\n}\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(SOURCE)
    );
}

#[test]
fn a_spec_group_gives_its_type_a_column_of_its_own() {
    const SOURCE: &[u8] = b"package p\n\nconst (\nRecvDir ChanDir = 1 << iota // one\nSendDir // two\nBothDir = RecvDir | SendDir // three\n)\n";
    const WANTED: &[u8] = b"package p\n\nconst (\n\tRecvDir ChanDir             = 1 << iota // one\n\tSendDir                                 // two\n\tBothDir = RecvDir | SendDir             // three\n)\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(WANTED)
    );
}

#[test]
fn a_spec_whose_remark_is_a_block_comment_holds_the_name_column_open() {
    const SOURCE: &[u8] =
        b"package p\n\nconst (\nC_NONE = iota\nC_REGP /* even gpr pair */\nC_LONGNAME /* long */\n)\n";

    const WANTED: &[u8] = b"package p\n\nconst (\n\tC_NONE     = iota\n\tC_REGP     /* even gpr pair */\n\tC_LONGNAME /* long */\n)\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(WANTED)
    );
}

#[test]
fn a_line_of_two_elements_takes_the_key_column_and_ends_the_run() {
    const SOURCE: &[u8] =
        b"package p\n\nvar x = T{\nName: \"a\",\nMode: 0644,\nUid: 1000, Gid: 1000,\nUname: \"b\",\n}\n";

    const WANTED: &[u8] = b"package p\n\nvar x = T{\n\tName: \"a\",\n\tMode: 0644,\n\tUid:  1000, Gid: 1000,\n\tUname: \"b\",\n}\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(WANTED)
    );
}

#[test]
fn a_line_that_closes_the_literal_it_stands_in_still_holds_a_key() {
    const SOURCE: &[u8] = b"package p\n\nvar z = Dialer{\nKeepAlive: def,\nKeepAliveConfig: cfg}\n";

    const WANTED: &[u8] =
        b"package p\n\nvar z = Dialer{\n\tKeepAlive:       def,\n\tKeepAliveConfig: cfg}\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(WANTED)
    );
}

#[test]
fn a_remark_column_ends_at_the_element_that_spells_its_own_lines() {
    const SOURCE: &[u8] = b"package p\n\nvar decoders = []decoder{\nfunc(b *buffer) error { return decodeA(b) }, // one\nfunc(b *buffer) error { return decodeBB(b) }, // two\nfunc(b *buffer) error { // three spans lines\nreturn nil\n},\n}\n\nfunc f(edit E, src string) {\nif edit.Start > 0 && src[edit.Start-1] != 'x' || // not at line start\nedit.End > 0 && src[edit.End-1] != 'y' { // partial insert\ngoto expand // slow path\n}\n}\n";
    const WANTED: &[u8] = b"package p\n\nvar decoders = []decoder{\n\tfunc(b *buffer) error { return decodeA(b) },  // one\n\tfunc(b *buffer) error { return decodeBB(b) }, // two\n\tfunc(b *buffer) error { // three spans lines\n\t\treturn nil\n\t},\n}\n\nfunc f(edit E, src string) {\n\tif edit.Start > 0 && src[edit.Start-1] != 'x' || // not at line start\n\t\tedit.End > 0 && src[edit.End-1] != 'y' { // partial insert\n\t\tgoto expand // slow path\n\t}\n}\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(WANTED)
    );
}

#[test]
fn a_spec_group_reads_its_binary_operators_at_the_declarations_own_depth() {
    const SOURCE: &[u8] = b"package p\n\nconst (\nlineBits, lineMax = 20, 1<<lineBits - 2\n_, _ uint64 = 2 * iota, 1 << iota\n)\n";
    const WANTED: &[u8] = b"package p\n\nconst (\n\tlineBits, lineMax        = 20, 1<<lineBits - 2\n\t_, _              uint64 = 2 * iota, 1 << iota\n)\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(WANTED)
    );
}

#[test]
fn a_doc_comment_writes_its_indented_run_as_a_block_of_its_own() {
    const SOURCE: &[u8] = b"package p\n\n//Doc says what f does.\n//\n// ParamFlags\n//   0 ParamFeedsIfOrSwitch\n// <endpropsdump>\nfunc f() {}\n\n// Held is a value.\n//   - a list item the printer lays out itself\n//   - a second item\nvar Held = 1\n\n//go:noinline\nfunc g() {}\n";
    const WANTED: &[u8] = b"package p\n\n// Doc says what f does.\n//\n// ParamFlags\n//\n//\t0 ParamFeedsIfOrSwitch\n//\n// <endpropsdump>\nfunc f() {}\n\n// Held is a value.\n//   - a list item the printer lays out itself\n//   - a second item\nvar Held = 1\n\n//go:noinline\nfunc g() {}\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(WANTED)
    );
}

#[test]
fn a_field_name_spelled_outside_ascii_still_opens_a_column() {
    const SOURCE: &[u8] = b"package p\n\ntype parameters struct {\nk, l int // dimensions of A\n\xCE\xB7 int // bound for secret coefficients\n\xCE\xB31 int // log of gamma\n}\n";
    const WANTED: &[u8] = b"package p\n\ntype parameters struct {\n\tk, l int // dimensions of A\n\t\xCE\xB7    int // bound for secret coefficients\n\t\xCE\xB31   int // log of gamma\n}\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(WANTED)
    );
}

#[test]
fn a_line_of_two_elements_takes_the_remark_column_and_ends_the_run() {
    const SOURCE: &[u8] = b"package p\n\nvar der = []byte{\n0x30, 6, // SEQUENCE\n0x02, 1, // INTEGER, 1 byte\n0xff, // -1\n0x02, 1, // INTEGER, 1 byte\n3,\n}\n";
    const WANTED: &[u8] = b"package p\n\nvar der = []byte{\n\t0x30, 6, // SEQUENCE\n\t0x02, 1, // INTEGER, 1 byte\n\t0xff,    // -1\n\t0x02, 1, // INTEGER, 1 byte\n\t3,\n}\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(WANTED)
    );
}

#[test]
fn a_key_run_is_ranked_by_the_width_of_the_key_rather_than_its_column() {
    const SOURCE: &[u8] = b"package p\n\nfunc f() {\nwant := map[string]int{\n\"Package path: \" + mainPkgPath + \"/dep\": 0,\n\"Func: Dep1\": 0,\n\"Func: PDep\": 0,\n}\n_ = want\n}\n";
    const WANTED: &[u8] = b"package p\n\nfunc f() {\n\twant := map[string]int{\n\t\t\"Package path: \" + mainPkgPath + \"/dep\": 0,\n\t\t\"Func: Dep1\":                            0,\n\t\t\"Func: PDep\":                            0,\n\t}\n\t_ = want\n}\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(WANTED)
    );
}

#[test]
fn a_body_brace_column_reads_through_a_signatures_block_comment() {
    const SOURCE: &[u8] =
        b"package p\n\nfunc (T1) m /* ERROR \"already declared\" */ () {}\nfunc (T2) m(io.Writer) {}\n";

    const WANTED: &[u8] = b"package p\n\nfunc (T1) m /* ERROR \"already declared\" */ () {}\nfunc (T2) m(io.Writer)                        {}\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(WANTED)
    );
}

#[test]
fn an_embedded_field_holds_its_tag_in_a_column_of_its_own() {
    const SOURCE: &[u8] = b"package p\n\ntype LayerOne struct {\nValue *float64 `xml:\"value,omitempty\"`\n*LayerTwo `xml:\",omitempty\"`\n}\n";
    const WANTED: &[u8] = b"package p\n\ntype LayerOne struct {\n\tValue     *float64 `xml:\"value,omitempty\"`\n\t*LayerTwo `xml:\",omitempty\"`\n}\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(WANTED)
    );
}

#[test]
fn a_body_of_one_member_stays_on_the_line_the_source_wrote_it_on() {
    const SOURCE: &[u8] = b"package p\n\ntype A interface{ M() }\ntype B interface{ M(); N() }\ntype C struct{ x int }\ntype D struct{}\ntype E struct{ x int /* c */ }\ntype F interface{ *P | []P | chan P | map[string]P }\ntype G interface{ *P | []P | chan P }\ntype H struct{ abcdefghij int; }\ntype I struct{ aaaaaaaaaaaaaaaaaaaaaaaaaaaa int }\n";
    const WANTED: &[u8] = b"package p\n\ntype A interface{ M() }\ntype B interface {\n\tM()\n\tN()\n}\ntype C struct{ x int }\ntype D struct{}\ntype E struct {\n\tx int /* c */\n}\ntype F interface {\n\t*P | []P | chan P | map[string]P\n}\ntype G interface{ *P | []P | chan P }\ntype H struct{ abcdefghij int }\ntype I struct{ aaaaaaaaaaaaaaaaaaaaaaaaaaaa int }\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(WANTED)
    );
}

#[test]
fn a_block_remark_closes_up_against_the_separator_and_the_close_past_it() {
    const SOURCE: &[u8] = b"package p\n\nfunc f() {\n_ = append(nil /* one */ , s)\n_ = T{ /* two */ }\n_ = T{a, b /* three */ }\n_ = g(a /* four */ )\n_ = h( /* five */ )\nx = y /* six */ * 10\n}\n";
    const WANTED: &[u8] = b"package p\n\nfunc f() {\n\t_ = append(nil /* one */, s)\n\t_ = T{ /* two */ }\n\t_ = T{a, b /* three */}\n\t_ = g(a /* four */)\n\t_ = h( /* five */ )\n\tx = y /* six */ * 10\n}\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(WANTED)
    );
}

#[test]
fn a_files_build_constraints_are_written_from_the_expression_they_spell() {
    const SOURCE: &[u8] = b"// Package doc.\n\n//go:build linux && go1.2 || windows\n// +build !bad\n// +build !worse\n\npackage p\n";
    const WANTED: &[u8] = b"// Package doc.\n\n//go:build (linux && go1.2) || windows\n// +build linux,go1.2 windows\n\npackage p\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(WANTED)
    );
}

#[test]
fn a_key_run_ends_above_a_value_that_spells_its_own_lines() {
    const SOURCE: &[u8] = b"package p\n\nvar held = &command{\nUsageLine: \"one two\",\nShort: \"short text\",\nLong: `first line\nsecond line\n`,\nName: \"n\",\n}\n";
    const WANTED: &[u8] = b"package p\n\nvar held = &command{\n\tUsageLine: \"one two\",\n\tShort:     \"short text\",\n\tLong: `first line\nsecond line\n`,\n\tName: \"n\",\n}\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(WANTED)
    );
}

#[test]
fn a_line_directive_the_source_began_at_column_zero_keeps_that_column() {
    const SOURCE: &[u8] = b"package p\n\nfunc main() {\nif flag {\n//line fmthello.go:999\nx()\n//go:noinline\ny()\n}\n}\n";
    const WANTED: &[u8] = b"package p\n\nfunc main() {\n\tif flag {\n//line fmthello.go:999\n\t\tx()\n\t\t//go:noinline\n\t\ty()\n\t}\n}\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(WANTED)
    );
}

#[test]
fn a_line_directive_the_source_indented_takes_the_blocks_own_column() {
    const SOURCE: &[u8] = b"package p\n\nfunc main() {\nif flag {\n\t\t//line a.go:9\nx()\n}\n}\n";

    const WANTED: &[u8] =
        b"package p\n\nfunc main() {\n\tif flag {\n\t\t//line a.go:9\n\t\tx()\n\t}\n}\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(WANTED)
    );
}

#[test]
fn a_keyword_takes_the_blank_a_parenthesis_past_it_owes() {
    const SOURCE: &[u8] = b"package p\n\nconst(\n\tA = 1\n)\n\nfunc f() int { return(1) }\n\ntype _ interface {\n\tfunc(int) int\n}\n";
    const WANTED: &[u8] = b"package p\n\nconst (\n\tA = 1\n)\n\nfunc f() int { return (1) }\n\ntype _ interface {\n\tfunc(int) int\n}\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(WANTED)
    );
}

#[test]
fn a_body_brace_takes_the_blank_a_remark_ahead_of_it_leaves() {
    const SOURCE: &[u8] =
        b"package p\n\nfunc a() int { return 0 /* c */}\n\nfunc b() { g(1 /* c */) }\n";

    const WANTED: &[u8] =
        b"package p\n\nfunc a() int { return 0 /* c */ }\n\nfunc b() { g(1 /* c */) }\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(WANTED)
    );
}

#[test]
fn a_signature_word_inside_a_bracket_hugs_its_own_parenthesis() {
    const SOURCE: &[u8] =
        b"package p\n\ntype _ interface {\n\tfunc()\n}\n\nfunc (t T) m() int { return 0 }\n";

    const WANTED: &[u8] =
        b"package p\n\ntype _ interface {\n\tfunc()\n}\n\nfunc (t T) m() int { return 0 }\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(WANTED)
    );
}

#[test]
fn a_close_standing_ahead_of_an_open_takes_no_blank_from_it() {
    const SOURCE: &[u8] =
        b"package p\n\nfunc a[P any] (x P) P { return x }\n\nvar u = struct{ a int } {a: 1}\n";

    const WANTED: &[u8] =
        b"package p\n\nfunc a[P any](x P) P { return x }\n\nvar u = struct{ a int }{a: 1}\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(WANTED)
    );
}

#[test]
fn a_remark_reached_across_a_specs_own_column_stands_against_the_name() {
    const SOURCE: &[u8] =
        b"package p\n\ntype (\n\tT0 int\n\tT1 /* note */ T1\n)\n\nconst (\n\tC1 /* note */\n)\n";

    const WANTED: &[u8] =
        b"package p\n\ntype (\n\tT0 int\n\tT1/* note */ T1\n)\n\nconst (\n\tC1 /* note */\n)\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(WANTED)
    );
}
