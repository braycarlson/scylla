use scylla::bounded::{BoundedVec, Buffer, Span, count_of};
use scylla::diagnostic::{Diagnostic, Diagnostics, Message, Severity};
use scylla::fix::{self, Applicability, Edit, Fixes, Piece};
use scylla::language::Lexer as _;
use scylla::lex::PYTHON;
use scylla::token::{Token, TokenKind, Tokens};

const ARENA_BYTES_MAX: u32 = 1 << 10;
const CLAIM_COUNT_MAX: u32 = 1 << 6;
const DIAGNOSTIC_COUNT_MAX: u32 = 1 << 6;
const EDIT_COUNT_MAX: u32 = 1 << 6;
const FIX_COUNT_MAX: u32 = 1 << 6;
const ROUND_MAX: u32 = 4;
const IMPORT: &[u8] = b"import os, sys\n";
const SOURCE: &[u8] = b"def f(l):\n    return l\n";
const SOURCE_BYTES_MAX: u32 = 1 << 12;
const TOKEN_COUNT_MAX: u32 = 1 << 10;

struct Round {
    claimed: BoundedVec<Span>,
    diagnostics: Diagnostics,
    fixes: Fixes,
    held: BoundedVec<Edit>,
    selected: BoundedVec<u32>,
    tokens: Tokens,
}

impl Round {
    fn reserve() -> Self {
        Self {
            claimed: BoundedVec::reserve(CLAIM_COUNT_MAX),
            diagnostics: Diagnostics::reserve(DIAGNOSTIC_COUNT_MAX, ARENA_BYTES_MAX),
            fixes: Fixes::reserve(FIX_COUNT_MAX, EDIT_COUNT_MAX, ARENA_BYTES_MAX),
            held: BoundedVec::reserve(EDIT_COUNT_MAX),
            selected: BoundedVec::reserve(FIX_COUNT_MAX),
            tokens: Tokens::reserve(TOKEN_COUNT_MAX),
        }
    }

    fn record(&mut self, source: &[u8]) -> u32 {
        self.claimed.clear();
        self.diagnostics.clear();
        self.fixes.clear();
        self.held.clear();
        self.selected.clear();
        self.tokens.clear();

        PYTHON.lex(source, &mut self.tokens);

        for token in self.tokens.as_slice() {
            if !renamed(source, token) {
                continue;
            }

            self.fixes.open("Rename", Applicability::Safe, 0);

            assert!(self.fixes.edit(token.span(), b"value"));

            let index = self.fixes.close();

            assert!(self.diagnostics.push(Diagnostic {
                code: "PR001",
                fix: index,
                message: Message::Static("the name is renamed"),
                related_count: 0,
                related_start: 0,
                rule: scylla::rule::NONE,
                severity: Severity::Warning,
                span: token.span(),
            }));
        }

        self.diagnostics.sort();

        self.diagnostics.count()
    }

    fn apply(&mut self, source: &[u8], out: &mut Buffer) -> bool {
        fix::plan(
            &self.fixes,
            Applicability::Safe,
            &mut self.claimed,
            &mut self.selected,
        );

        for index in &*self.selected {
            let held = *self.fixes.get(*index).expect("a selected fix is recorded");

            for edit in self.fixes.edits_of(&held) {
                self.held.push_assert(*edit);
            }
        }

        fix::apply(source, &self.fixes, &self.held, out)
    }
}

fn renamed(source: &[u8], token: &Token) -> bool {
    token.kind == TokenKind::Identifier && token.text(source) == b"l"
}

#[test]
fn a_recorded_rename_applies_and_then_converges() {
    let mut out = Buffer::reserve(SOURCE_BYTES_MAX);
    let mut round = Round::reserve();
    let mut rounds = 0;
    let mut source = SOURCE.to_vec();

    for _ in 0..ROUND_MAX {
        let count = round.record(&source);

        if count == 0 {
            break;
        }

        assert!(round.apply(&source, &mut out));

        source = out.as_bytes().to_vec();
        rounds += 1;
    }

    assert_eq!(rounds, 1);
    assert_eq!(source, b"def f(value):\n    return value\n");
    assert_eq!(round.record(&source), 0);
}

#[test]
fn a_first_round_records_two_fixed_diagnostics() {
    let mut round = Round::reserve();

    assert_eq!(round.record(SOURCE), 2);
    assert_eq!(round.fixes.count(), 2);

    let mut offset_previous = 0;

    for diagnostic in &round.diagnostics {
        assert_eq!(diagnostic.code, "PR001");
        assert!(diagnostic.is_fixed());
        assert!(diagnostic.span.offset >= offset_previous);

        offset_previous = diagnostic.span.offset;
    }
}

#[test]
fn a_plan_selects_every_disjoint_fix_in_one_pass() {
    let mut out = Buffer::reserve(SOURCE_BYTES_MAX);
    let mut round = Round::reserve();

    assert_eq!(round.record(SOURCE), 2);
    assert!(round.apply(SOURCE, &mut out));
    assert_eq!(round.selected.count(), 2);
    assert_eq!(&*round.selected, &[0_u32, 1][..]);
    assert_eq!(out.as_bytes(), b"def f(value):\n    return value\n");
}

#[test]
fn an_empty_edit_set_copies_the_source() {
    let mut out = Buffer::reserve(SOURCE_BYTES_MAX);
    let round = Round::reserve();

    assert!(fix::apply(SOURCE, &round.fixes, &[], &mut out));
    assert_eq!(out.as_bytes(), SOURCE);
}

#[test]
fn a_rendered_import_splits_into_two_statements() {
    let mut fixes = Fixes::reserve(FIX_COUNT_MAX, EDIT_COUNT_MAX, ARENA_BYTES_MAX);
    let mut held: BoundedVec<Edit> = BoundedVec::reserve(EDIT_COUNT_MAX);
    let mut out = Buffer::reserve(SOURCE_BYTES_MAX);
    let mut tokens = Tokens::reserve(TOKEN_COUNT_MAX);

    PYTHON.lex(IMPORT, &mut tokens);

    let names: Vec<Span> = tokens
        .as_slice()
        .iter()
        .filter(|token| token.kind == TokenKind::Identifier)
        .map(Token::span)
        .collect();

    assert_eq!(names.len(), 2);

    let first = names[0];
    let second = names[1];

    let statement = Span {
        length: second.end(),
        offset: 0,
    };

    fixes.open("Split the import", Applicability::Safe, 0);

    assert!(fixes.render(
        statement,
        IMPORT,
        &[],
        &[
            Piece::Source(Span {
                length: first.end(),
                offset: 0,
            }),
            Piece::Literal(b"\nimport "),
            Piece::Source(second),
        ]
    ));

    let index = fixes.close();
    let fix = *fixes.get(index).expect("the fix is recorded");

    for edit in fixes.edits_of(&fix) {
        held.push_assert(*edit);
    }

    assert!(fix::apply(IMPORT, &fixes, &held, &mut out));
    assert_eq!(out.as_bytes(), b"import os\nimport sys\n");
}

fn mapped(source: &[u8], span: Span, replacement: &'static [u8]) -> (String, Vec<fix::Marker>) {
    mapped_many(source, &[(span, replacement)], EDIT_COUNT_MAX * 2)
}

fn mapped_many(
    source: &[u8],
    edits: &[(Span, &'static [u8])],
    marker_count_max: u32,
) -> (String, Vec<fix::Marker>) {
    let mut fixes = Fixes::reserve(FIX_COUNT_MAX, EDIT_COUNT_MAX, ARENA_BYTES_MAX);
    let mut out = Buffer::reserve(SOURCE_BYTES_MAX);
    let mut markers = BoundedVec::reserve(marker_count_max);

    fixes.open("rewrite", Applicability::Safe, fix::NONE);

    for (span, replacement) in edits {
        assert!(fixes.edit(*span, replacement));
    }

    let index = fixes.close();
    let held = fixes.get(index).expect("the fix closed");
    let held_edits: Vec<Edit> = fixes.edits_of(held).to_vec();
    let applied = fix::apply_mapped(source, &fixes, &held_edits, &mut out, &mut markers);

    assert_eq!(applied, markers.count() == count_of(held_edits.len() * 2));

    (
        String::from_utf8_lossy(out.as_bytes()).into_owned(),
        markers.iter().copied().collect(),
    )
}

#[test]
fn an_insertion_before_an_offset_shifts_it() {
    let source = b"value = read()\n";

    let (text, markers) = mapped(
        source,
        Span {
            length: 0,
            offset: 0,
        },
        b"import os\n",
    );

    assert_eq!(text, "import os\nvalue = read()\n");
    assert_eq!(fix::offset_after(&markers, 0), 10);
    assert_eq!(fix::offset_after(&markers, 8), 18);
}

#[test]
fn a_deletion_after_an_offset_leaves_it_alone() {
    let source = b"value = read()\n";

    let (text, markers) = mapped(
        source,
        Span {
            length: 6,
            offset: 8,
        },
        b"",
    );

    assert_eq!(text, "value = \n");
    assert_eq!(fix::offset_after(&markers, 0), 0);
    assert_eq!(fix::offset_after(&markers, 5), 5);
}

#[test]
fn an_offset_inside_a_replaced_span_maps_to_the_replacement_end() {
    let source = b"value = read()\n";

    let (text, markers) = mapped(
        source,
        Span {
            length: 6,
            offset: 8,
        },
        b"x",
    );

    assert_eq!(text, "value = x\n");
    assert_eq!(fix::offset_after(&markers, 8), 9);
    assert_eq!(fix::offset_after(&markers, 11), 9);
    assert_eq!(fix::offset_after(&markers, 13), 9);
    assert_eq!(fix::offset_after(&markers, 14), 9);
}

#[test]
fn an_offset_past_a_shortened_span_shifts_back_by_what_it_lost() {
    let source = b"value = read()\nother = 2\n";

    let (text, markers) = mapped(
        source,
        Span {
            length: 6,
            offset: 8,
        },
        b"x",
    );

    assert_eq!(text, "value = x\nother = 2\n");
    assert_eq!(fix::offset_after(&markers, 15), 10);
    assert_eq!(fix::offset_after(&markers, 24), 19);
}

#[test]
fn two_edits_shift_an_offset_by_what_both_of_them_moved() {
    let source = b"a = read()\nb = read()\nc = 3\n";

    let (text, markers) = mapped_many(
        source,
        &[
            (
                Span {
                    length: 6,
                    offset: 4,
                },
                b"x",
            ),
            (
                Span {
                    length: 6,
                    offset: 15,
                },
                b"yy",
            ),
        ],
        EDIT_COUNT_MAX * 2,
    );

    assert_eq!(text, "a = x\nb = yy\nc = 3\n");
    assert_eq!(fix::offset_after(&markers, 0), 0);
    assert_eq!(fix::offset_after(&markers, 11), 6);
    assert_eq!(fix::offset_after(&markers, 18), 12);
    assert_eq!(fix::offset_after(&markers, 22), 13);
    assert_eq!(fix::offset_after(&markers, 27), 18);
}

#[test]
fn two_adjacent_edits_map_the_seam_to_the_second_replacement_end() {
    let source = b"ab\n";

    let (text, markers) = mapped_many(
        source,
        &[
            (
                Span {
                    length: 1,
                    offset: 0,
                },
                b"xx",
            ),
            (
                Span {
                    length: 1,
                    offset: 1,
                },
                b"",
            ),
        ],
        EDIT_COUNT_MAX * 2,
    );

    assert_eq!(text, "xx\n");
    assert_eq!(fix::offset_after(&markers, 0), 2);
    assert_eq!(fix::offset_after(&markers, 1), 2);
    assert_eq!(fix::offset_after(&markers, 2), 2);
    assert_eq!(fix::offset_after(&markers, 3), 3);
}

#[test]
fn a_marker_table_that_fills_rolls_the_whole_application_back() {
    let source = b"ab\n";

    let (text, markers) = mapped_many(
        source,
        &[
            (
                Span {
                    length: 1,
                    offset: 0,
                },
                b"x",
            ),
            (
                Span {
                    length: 1,
                    offset: 1,
                },
                b"y",
            ),
        ],
        3,
    );

    assert_eq!(text, "");
    assert!(markers.is_empty());
}

#[test]
fn an_empty_map_answers_every_offset_with_itself() {
    assert_eq!(fix::offset_after(&[], 0), 0);
    assert_eq!(fix::offset_after(&[], 41), 41);
}
