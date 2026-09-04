#[path = "common/corpus.rs"]
mod corpus;
#[path = "common/floor.rs"]
mod floor;

use std::fs;
use std::path::PathBuf;

use scylla::bounded::{BoundedVec, Buffer, Span};
use scylla::format::print::Options;
use scylla::format::zig::{Formatter, Input, Outcome};
use scylla::language::Lexer as _;
use scylla::lex::ZIG;
use scylla::syntax::zig::classify::classify;
use scylla::syntax::zig::kind::ZigKind;
use scylla::syntax::zig::parse;
use scylla::token::{TokenKind, Tokens};
use scylla::tree::{Events, Tree};

const CASTS: [&str; 4] = ["alignCast", "constCast", "ptrCast", "volatileCast"];
const ELEMENT_COUNT_MAX: u32 = 1 << 18;
const ERROR_COUNT_MAX: u32 = 1 << 12;
const EVENT_COUNT_MAX: u32 = 1 << 20;
const NODE_COUNT_MAX: u32 = 1 << 18;
const OUT_BYTES_MAX: u32 = 1 << 22;
const TOKEN_COUNT_MAX: u32 = 1 << 18;

struct Held {
    events: Events<ZigKind>,
    formatter: Formatter,
    lexed: Tokens,
    raw: BoundedVec<ZigKind>,
    tokens: Tokens,
    tree: Tree<ZigKind>,
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

        ZIG.lex(source, &mut self.lexed);

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

        ZIG.lex(source, &mut self.lexed);

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
        ZIG.lex(source, &mut self.lexed);

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

                let text = String::from_utf8_lossy(token.text(source)).into_owned();

                if CASTS.contains(&text.trim_start_matches('@')) {
                    return "<cast>".to_owned();
                }

                text
            })
            .collect()
    }

    fn kinds(&mut self, source: &[u8]) -> Vec<ZigKind> {
        self.lexed.clear();
        self.raw.clear();
        self.tokens.clear();

        ZIG.lex(source, &mut self.lexed);

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

        ZIG.lex(source, &mut self.lexed);

        assert!(classify(
            source,
            self.lexed.as_slice(),
            &mut self.tokens,
            &mut self.raw
        ));

        self.raw
            .iter()
            .enumerate()
            .filter(|(_, kind)| **kind == ZigKind::Comment)
            .map(|(index, _)| {
                source[self.tokens.as_slice()[index].span().range()]
                    .trim_ascii_end()
                    .to_vec()
            })
            .collect()
    }
}

fn fixtures() -> Vec<(String, Vec<u8>)> {
    let root = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/zig");
    let mut found = Vec::new();

    for entry in fs::read_dir(&root).expect("the fixture directory is readable") {
        let path = entry.expect("the entry is readable").path();

        if path.extension().is_none_or(|extension| extension != "zig") {
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

        assert_eq!(before, after, "{name} lost or gained a token");
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

const EVERY_CATEGORY: [&str; 2] = ["zigfmt-declaration-context", "zigfmt-line-breaking"];

#[test]
fn the_formatted_output_matches_the_oracle_modulo_residue() {
    let carried = oracle::residue_of("residue-format-zig.json", &EVERY_CATEGORY);
    let root = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/golden-zigfmt");
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
            "{name} diverges from zig fmt and no residue row names it"
        );

        compared += 1;
    }

    assert!(
        compared >= floor::FIXTURE_FORMAT_ZIG,
        "the Zig fixtures lost a formatting: {compared} compared, floor {}",
        floor::FIXTURE_FORMAT_ZIG
    );
}

#[test]
fn every_residue_row_names_a_fixture_that_diverges() {
    let carried = oracle::residue_of("residue-format-zig.json", &EVERY_CATEGORY);
    let root = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/golden-zigfmt");
    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    for name in &carried {
        let source = fs::read(
            PathBuf::from(env!("CARGO_MANIFEST_DIR"))
                .join("tests/fixtures/zig")
                .join(name),
        )
        .expect("the residue row names a fixture");

        assert_eq!(held.format(&source, &mut out), Outcome::Complete);

        let golden = fs::read(root.join(name)).expect("the golden is dumped");

        assert_ne!(
            out.as_bytes(),
            golden.as_slice(),
            "{name} matches zig fmt and needs no residue row"
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
fn a_range_reads_back_the_lines_it_names() {
    let source: &[u8] = b"fn f() void {\nconst x=1;\n_=x;\n}\n";
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

            if path.extension().is_none_or(|extension| extension != "zig") {
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

        assert_eq!(
            before, after,
            "{name} split, joined, lost, or gained a word"
        );
    }
}

#[test]
fn a_switch_prong_lists_its_cases_without_the_columns_a_row_takes() {
    const SOURCE: &[u8] = b"const E = enum { aaa, b, cccccccccc, d };\nfn f(e: E) u8 {\n    return switch (e) {\n        .aaa, .b => 1,\n        .cccccccccc, .d => 2,\n    };\n}\nconst t = [_]u32{\n    1, 2,\n    400, 5,\n};\n";
    const WANTED: &[u8] = b"const E = enum { aaa, b, cccccccccc, d };\nfn f(e: E) u8 {\n    return switch (e) {\n        .aaa, .b => 1,\n        .cccccccccc, .d => 2,\n    };\n}\nconst t = [_]u32{\n    1,   2,\n    400, 5,\n};\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(WANTED)
    );
}

#[test]
fn a_body_whose_head_stands_on_a_continuation_indents_from_that_line() {
    const SOURCE: &[u8] = b"fn f() u8 {\n    const held =\n        for ([_]u8{ 1, 2, 3 }) |value| {\n            if (value == 2) break value;\n        } else 0;\n    return held;\n}\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(SOURCE)
    );
}

#[test]
fn an_operator_chain_steps_a_level_where_the_operators_bind_harder() {
    const SOURCE: &[u8] = b"const a: u64 = 1;\nconst b: u64 = 2;\nconst c: u64 = 3;\nconst d: u64 = 4;\nfn f() u64 {\n    const p =\n        a +\n        b *\n        c +\n        d;\n    const q =\n        a *\n        b +\n        c;\n    return p + q;\n}\n";
    const WANTED: &[u8] = b"const a: u64 = 1;\nconst b: u64 = 2;\nconst c: u64 = 3;\nconst d: u64 = 4;\nfn f() u64 {\n    const p =\n        a +\n        b *\n            c +\n        d;\n    const q =\n        a *\n        b +\n        c;\n    return p + q;\n}\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(WANTED)
    );
}

#[test]
fn a_bracket_inside_a_headers_condition_indents_from_the_line_it_opened_on() {
    const SOURCE: &[u8] = b"fn f() void {\n    if (aaa and\n        other(\n        one,\n        two,\n    )) {\n        stage();\n    }\n}\n";
    const WANTED: &[u8] = b"fn f() void {\n    if (aaa and\n        other(\n            one,\n            two,\n        ))\n    {\n        stage();\n    }\n}\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(WANTED)
    );
}

#[test]
fn a_body_whose_header_ends_over_indented_takes_a_line_of_its_own() {
    const SOURCE: &[u8] = b"fn f() void {\n    if (aaa and\n        bbb) {\n        one();\n    }\n    if (call(\n        aaa,\n    ) == 0) {\n        two();\n    }\n}\n";
    const WANTED: &[u8] = b"fn f() void {\n    if (aaa and\n        bbb)\n    {\n        one();\n    }\n    if (call(\n        aaa,\n    ) == 0) {\n        two();\n    }\n}\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(WANTED)
    );
}

#[test]
fn a_headers_body_steps_in_from_the_header_and_its_else_steps_back() {
    const SOURCE: &[u8] = b"fn f() void {\n    const held =\n        if (a)\n        if (b)\n        one\n        else\n        two\n        else\n        three;\n    _ = held;\n}\n";
    const WANTED: &[u8] = b"fn f() void {\n    const held =\n        if (a)\n            if (b)\n                one\n            else\n                two\n        else\n            three;\n    _ = held;\n}\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(WANTED)
    );
}

#[test]
fn a_continuation_opened_inside_another_steps_in_from_it() {
    const SOURCE: &[u8] = b"fn f() void {\n    const held =\n        if (a)\n        one\n    else\n        two;\n    _ = held;\n}\n";
    const WANTED: &[u8] = b"fn f() void {\n    const held =\n        if (a)\n            one\n        else\n            two;\n    _ = held;\n}\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(WANTED)
    );
}

#[test]
fn a_remark_takes_the_level_of_the_code_below_it() {
    const SOURCE: &[u8] = b"fn f() void {\n    const held = value.first()\n    // A remark standing inside a continuation.\n        .second();\n    _ = held;\n}\n";
    const WANTED: &[u8] = b"fn f() void {\n    const held = value.first()\n        // A remark standing inside a continuation.\n        .second();\n    _ = held;\n}\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(WANTED)
    );
}

#[test]
fn a_continue_clause_stands_at_the_level_its_header_took() {
    const SOURCE: &[u8] = b"fn f() void {\n    var i: u8 = 0;\n    while (i < ten and\n        i < twenty) //\n        : (i += 1) {\n        one();\n    }\n}\n";
    const WANTED: &[u8] = b"fn f() void {\n    var i: u8 = 0;\n    while (i < ten and\n        i < twenty) //\n    : (i += 1) {\n        one();\n    }\n}\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(WANTED)
    );
}

#[test]
fn a_run_of_nested_casts_is_written_in_one_order() {
    const SOURCE: &[u8] = b"fn f(ctx: *anyopaque) void {\n    const held = @constCast(@alignCast(@ptrCast(ctx)));\n    _ = held;\n}\n";
    const WANTED: &[u8] = b"fn f(ctx: *anyopaque) void {\n    const held = @ptrCast(@alignCast(@constCast(ctx)));\n    _ = held;\n}\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(WANTED)
    );
}

#[test]
fn a_slices_own_sentinel_takes_the_blank_a_types_sentinel_does_not() {
    const SOURCE: &[u8] = b"fn f(buffer: []u8, read: usize) void {\n    var one: [614:0]u8 = undefined;\n    const two = buffer[0..read :0];\n    _ = one;\n    _ = two;\n}\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(SOURCE)
    );
}

#[test]
fn a_line_past_a_multiline_string_steps_back_out_of_it() {
    const SOURCE: &[u8] = b"fn f(buf: []u8) void {\n    const held = call(\n        \\\\one\n    ++\n        \\\\two\n        , buf);\n    const kept = .{\n        \\\\three\n        ,\n        4,\n    };\n    _ = held;\n    _ = kept;\n}\n";
    const WANTED: &[u8] = b"fn f(buf: []u8) void {\n    const held = call(\n        \\\\one\n    ++\n        \\\\two\n    , buf);\n    const kept = .{\n        \\\\three\n        ,\n        4,\n    };\n    _ = held;\n    _ = kept;\n}\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(WANTED)
    );
}

#[test]
fn a_sole_element_hugs_the_brace_holding_it_however_it_parts() {
    const SOURCE: &[u8] = b"fn f() void {\n    try p(\"a\", .{ sized(\n        one,\n    ) });\n    try p(\"a\", .{ one, sized(\n        two,\n    ) });\n}\n";
    const WANTED: &[u8] = b"fn f() void {\n    try p(\"a\", .{sized(\n        one,\n    )});\n    try p(\"a\", .{ one, sized(\n        two,\n    ) });\n}\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(WANTED)
    );
}

#[test]
fn an_element_spelling_lines_of_its_own_takes_a_row_of_its_own() {
    const SOURCE: &[u8] = b"const held = .{\n    .{\n        one, Mapping{\n            .name = \"two\",\n        },\n    },\n    .{ three, Mapping{\n        .name = \"four\",\n    } },\n};\n";
    const WANTED: &[u8] = b"const held = .{\n    .{\n        one,\n        Mapping{\n            .name = \"two\",\n        },\n    },\n    .{ three, Mapping{\n        .name = \"four\",\n    } },\n};\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(WANTED)
    );
}

#[test]
fn a_payload_the_source_parted_steps_in_from_the_header_opening_it() {
    const SOURCE: &[u8] = b"fn f() void {\n    for (one, two) |\n    first,\n    second,\n    | {\n        _ = .{ first, second };\n    }\n}\n";
    const WANTED: &[u8] = b"fn f() void {\n    for (one, two) |\n        first,\n        second,\n    | {\n        _ = .{ first, second };\n    }\n}\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(WANTED)
    );
}

#[test]
fn a_conditions_operator_under_a_trailing_remark_keeps_the_headers_level() {
    const SOURCE: &[u8] = b"fn f(link: []const u8) void {\n    if (one(link) // external.\n        or two(link) // email.\n    ) {\n        return;\n    }\n}\n";
    const WANTED: &[u8] = b"fn f(link: []const u8) void {\n    if (one(link) // external.\n    or two(link) // email.\n    ) {\n        return;\n    }\n}\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(WANTED)
    );
}

#[test]
fn a_remark_between_two_operands_keeps_the_precedence_the_chain_stands_at() {
    const SOURCE: &[u8] = b"const a = if (element_count >=\n    // one\n    capacity +\n    // two\n    1 +\n    // three\n    2)\n    naive\nelse\n    naive - 1;\n";
    const WANTED: &[u8] = b"const a = if (element_count >=\n    // one\n    capacity +\n        // two\n        1 +\n        // three\n        2)\n    naive\nelse\n    naive - 1;\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(WANTED)
    );
}

#[test]
fn an_arm_body_under_a_remark_run_keeps_the_arms_own_level() {
    const SOURCE: &[u8] = b"fn f(n: u8) ?u8 {\n    return switch (n) {\n        0 =>\n            // one\n            // two\n            call(\n                a,\n            ),\n        else => null,\n    };\n}\n";
    const WANTED: &[u8] = b"fn f(n: u8) ?u8 {\n    return switch (n) {\n        0 =>\n        // one\n        // two\n        call(\n            a,\n        ),\n        else => null,\n    };\n}\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(WANTED)
    );
}

#[test]
fn a_struct_initialiser_field_under_a_trailing_remark_keeps_its_own_level() {
    const SOURCE: &[u8] = b"const g = init(gpa, .{\n    .alpha = one,\n    .beta = //\n        two,\n});\nconst v = struct {\n    alpha: u8 = //\n        one,\n};\n";
    const WANTED: &[u8] = b"const g = init(gpa, .{\n    .alpha = one,\n    .beta = //\n    two,\n});\nconst v = struct {\n    alpha: u8 = //\n        one,\n};\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(WANTED)
    );
}

#[test]
fn a_body_an_orelse_opens_indents_from_the_line_it_opened_on() {
    const SOURCE: &[u8] = b"fn f() void {\n    const held: i64 = if (client == 0)\n        @intCast(stamp)\n    else\n        clock.sync() orelse {\n        one();\n        return;\n    };\n    _ = held;\n}\n";
    const WANTED: &[u8] = b"fn f() void {\n    const held: i64 = if (client == 0)\n        @intCast(stamp)\n    else\n        clock.sync() orelse {\n            one();\n            return;\n        };\n    _ = held;\n}\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(WANTED)
    );
}

#[test]
fn a_wrapping_negation_closes_up_against_its_operand() {
    const SOURCE: &[u8] = b"fn f(less_than: u64, x: u64) void {\n    const t = -%less_than;\n    const u = x -% less_than;\n    _ = .{ t, u };\n}\n";

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(SOURCE, &mut out), Outcome::Complete);
    assert_eq!(
        String::from_utf8_lossy(out.as_bytes()),
        String::from_utf8_lossy(SOURCE)
    );
}
