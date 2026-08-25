use scylla::bounded::{BoundedVec, Span};
use scylla::language::Lexer as _;
use scylla::lex::PYTHON;
use scylla::lines;
use scylla::syntax::python::classify::classify;
use scylla::syntax::python::edit::{self, Deletion};
use scylla::syntax::python::imports;
use scylla::syntax::python::kind::PythonKind;
use scylla::syntax::python::parse;
use scylla::syntax::python::style::{self, LineEnding, QuoteStyle};
use scylla::token::Tokens;
use scylla::tree::{Events, NONE, Structure, Tree};

struct Fixture {
    index: lines::Index,
    lexed: Tokens,
    raw: BoundedVec<PythonKind>,
    source: Vec<u8>,
    tokens: Tokens,
    tree: Tree<PythonKind>,
}

impl Fixture {
    fn of(source: &[u8]) -> Self {
        let mut lexed = Tokens::reserve(1 << 14);
        let mut tokens = Tokens::reserve(1 << 14);
        let mut raw = BoundedVec::reserve(1 << 14);
        let mut events = Events::reserve(1 << 16);
        let mut tree = Tree::<PythonKind>::reserve(1 << 14, 1 << 8);
        let mut index = lines::Index::reserve(1 << 12);

        PYTHON.lex(source, &mut lexed);

        assert!(classify(source, lexed.as_slice(), &mut tokens, &mut raw));

        assert_eq!(
            parse::build(source, tokens.as_slice(), &raw, &mut events, &mut tree),
            Structure::Complete
        );

        assert!(index.build(source));

        Self {
            index,
            lexed,
            raw,
            source: source.to_vec(),
            tokens,
            tree,
        }
    }

    fn first(&self, kind: PythonKind) -> u32 {
        for node in 0..self.tree.count() {
            if self.tree.at(node).kind == kind {
                return node;
            }
        }

        NONE
    }

    fn nth(&self, kind: PythonKind, position: u32) -> u32 {
        let mut seen = 0;

        for node in 0..self.tree.count() {
            if self.tree.at(node).kind != kind {
                continue;
            }

            if seen == position {
                return node;
            }

            seen += 1;
        }

        NONE
    }

    fn text(&self, span: Span) -> String {
        String::from_utf8_lossy(&self.source[span.range()]).into_owned()
    }

    fn deletion(&self, statement: u32) -> Deletion {
        edit::statement_deletion(
            &self.source,
            self.tokens.as_slice(),
            &self.tree,
            statement,
            &self.index,
        )
    }

    fn shown(&self, held: Deletion) -> (bool, String) {
        match held {
            Deletion::Remove(span) => (false, self.text(span)),
            Deletion::Replace(span) => (true, self.text(span)),
        }
    }
}

#[test]
fn the_only_statement_of_a_block_is_replaced_rather_than_removed() {
    let held = Fixture::of(b"def read():\n    value = 1\n");
    let statement = held.first(PythonKind::Assign);

    assert_eq!(
        held.shown(held.deletion(statement)),
        (true, "value = 1".to_owned())
    );
}

#[test]
fn a_statement_that_owns_its_line_takes_the_whole_line_with_it() {
    let held = Fixture::of(b"def read():\n    value = 1\n    return 2\n");
    let statement = held.first(PythonKind::Assign);

    assert_eq!(
        held.shown(held.deletion(statement)),
        (false, "    value = 1\n".to_owned())
    );
}

#[test]
fn a_statement_with_a_trailing_comment_still_takes_the_whole_line() {
    let held = Fixture::of(b"def read():\n    value = 1  # keep\n    return 2\n");
    let statement = held.first(PythonKind::Assign);

    assert_eq!(
        held.shown(held.deletion(statement)),
        (false, "    value = 1  # keep\n".to_owned())
    );
}

#[test]
fn a_statement_after_a_semicolon_leaves_the_semicolon_standing() {
    let held = Fixture::of(b"def read():\n    a = 1; b = 2\n    return a\n");
    let statement = held.nth(PythonKind::Assign, 1);

    assert_eq!(
        held.shown(held.deletion(statement)),
        (false, "b = 2".to_owned())
    );
}

#[test]
fn a_statement_between_two_semicolons_takes_the_one_after_it() {
    let held = Fixture::of(b"x = 1; import os; y = 2\n");
    let statement = held.first(PythonKind::Import);

    assert_eq!(
        held.shown(held.deletion(statement)),
        (false, "import os; ".to_owned())
    );
}

#[test]
fn the_only_statement_of_an_inline_block_is_replaced() {
    let held = Fixture::of(b"if x: value = 1\n");
    let statement = held.first(PythonKind::Assign);

    assert_eq!(
        held.shown(held.deletion(statement)),
        (true, "value = 1".to_owned())
    );
}

#[test]
fn a_statement_on_a_carriage_return_line_feed_line_takes_both_bytes() {
    let held = Fixture::of(b"import os\r\nvalue = 1\r\n");
    let statement = held.first(PythonKind::Import);

    assert_eq!(
        held.shown(held.deletion(statement)),
        (false, "import os\r\n".to_owned())
    );
}

#[test]
fn a_statement_before_a_semicolon_takes_the_semicolon_after_it() {
    let held = Fixture::of(b"def read():\n    a = 1; b = 2\n    return b\n");
    let statement = held.nth(PythonKind::Assign, 0);

    assert_eq!(
        held.shown(held.deletion(statement)),
        (false, "a = 1; ".to_owned())
    );
}

#[test]
fn a_statement_spanning_several_lines_takes_every_one_of_them() {
    let held = Fixture::of(b"def read():\n    value = [\n        1,\n    ]\n    return 2\n");
    let statement = held.first(PythonKind::Assign);
    let (replaced, text) = held.shown(held.deletion(statement));

    assert!(!replaced);
    assert_eq!(text, "    value = [\n        1,\n    ]\n");
}

#[test]
fn removing_a_leading_alias_takes_the_comma_after_it() {
    let held = Fixture::of(b"import os, sys\n");
    let statement = held.first(PythonKind::Import);

    let removal = edit::alias_removal(
        &held.source,
        held.tokens.as_slice(),
        &held.tree,
        statement,
        0,
        &held.index,
    );

    assert_eq!(held.shown(removal), (false, "os, ".to_owned()));
}

#[test]
fn removing_a_trailing_alias_takes_the_comma_before_it() {
    let held = Fixture::of(b"import os, sys\n");
    let statement = held.first(PythonKind::Import);

    let removal = edit::alias_removal(
        &held.source,
        held.tokens.as_slice(),
        &held.tree,
        statement,
        1,
        &held.index,
    );

    assert_eq!(held.shown(removal), (false, ", sys".to_owned()));
}

#[test]
fn removing_the_only_alias_removes_the_statement() {
    let held = Fixture::of(b"import os\nvalue = 1\n");
    let statement = held.first(PythonKind::Import);

    let removal = edit::alias_removal(
        &held.source,
        held.tokens.as_slice(),
        &held.tree,
        statement,
        0,
        &held.index,
    );

    assert_eq!(held.shown(removal), (false, "import os\n".to_owned()));
}

#[test]
fn removing_an_argument_takes_the_comma_on_the_side_it_has_one() {
    let held = Fixture::of(b"read(first, second, third)\n");
    let call = held.first(PythonKind::Call);

    assert_eq!(
        held.text(edit::argument_removal(
            held.tokens.as_slice(),
            &held.tree,
            call,
            0
        )),
        "first, "
    );

    assert_eq!(
        held.text(edit::argument_removal(
            held.tokens.as_slice(),
            &held.tree,
            call,
            1
        )),
        "second, "
    );

    assert_eq!(
        held.text(edit::argument_removal(
            held.tokens.as_slice(),
            &held.tree,
            call,
            2
        )),
        ", third"
    );
}

#[test]
fn removing_the_only_argument_takes_the_argument_alone() {
    let held = Fixture::of(b"read(first)\n");
    let call = held.first(PythonKind::Call);

    assert_eq!(
        held.text(edit::argument_removal(
            held.tokens.as_slice(),
            &held.tree,
            call,
            0
        )),
        "first"
    );
}

#[test]
fn a_replacement_fits_up_to_the_width_and_not_past_it() {
    let held = Fixture::of(b"value = read()\n");

    let span = Span {
        length: 6,
        offset: 8,
    };

    assert!(edit::fits(&held.source, &held.index, span, 6, 14, 4));
    assert!(!edit::fits(&held.source, &held.index, span, 7, 14, 4));
}

#[test]
fn a_tab_counts_the_width_a_caller_gives_it() {
    let held = Fixture::of(b"def read():\n\tvalue = 1\n");

    let span = Span {
        length: 1,
        offset: 21,
    };

    assert_eq!(held.text(span), "1");
    assert!(edit::fits(&held.source, &held.index, span, 1, 13, 4));
    assert!(!edit::fits(&held.source, &held.index, span, 1, 12, 4));
}

#[test]
fn a_replacement_that_would_fuse_with_a_keyword_asks_for_a_space() {
    let held = Fixture::of(b"def read():\n    return(1)\n");

    let span = Span {
        length: 3,
        offset: 22,
    };

    assert_eq!(held.text(span), "(1)");
    assert_eq!(edit::padding(&held.source, span, b"1"), (true, false));
}

#[test]
fn a_replacement_that_would_fuse_with_a_number_asks_for_a_space_after() {
    let held = Fixture::of(b"value = 1 if read else 2\n");

    let span = Span {
        length: 1,
        offset: 8,
    };

    assert_eq!(held.text(span), "1");
    assert_eq!(edit::padding(&held.source, span, b"1"), (false, false));

    let seam = Span {
        length: 1,
        offset: 9,
    };

    assert_eq!(edit::padding(&held.source, seam, b"x"), (true, true));
}

#[test]
fn a_byte_of_a_multi_byte_character_counts_as_a_word_byte() {
    let source = "caf\u{e9}".as_bytes();

    let span = Span {
        length: 0,
        offset: 5,
    };

    assert_eq!(edit::padding(source, span, b"x"), (true, false));
}

#[test]
fn a_replacement_between_punctuation_asks_for_nothing() {
    let held = Fixture::of(b"value = (1)\n");

    let span = Span {
        length: 1,
        offset: 9,
    };

    assert_eq!(edit::padding(&held.source, span, b"2"), (false, false));
}

#[test]
fn a_tab_indented_file_reads_as_tab_indented() {
    let held = Fixture::of(b"def read():\n\tvalue = 1\n\treturn value\n");
    let found = style::detect(&held.source, held.lexed.as_slice());

    assert!(found.indent_tabs);
    assert_eq!(found.indent_width, 1);
    assert_eq!(found.line_ending, LineEnding::LineFeed);
    assert_eq!(found.quote, QuoteStyle::Double);
}

#[test]
fn a_two_space_file_with_single_quotes_reads_as_both() {
    let held = Fixture::of(b"def read():\r\n  return 'text'\r\n");
    let found = style::detect(&held.source, held.lexed.as_slice());

    assert!(!found.indent_tabs);
    assert_eq!(found.indent_width, 2);
    assert_eq!(found.line_ending, LineEnding::CarriageReturnLineFeed);
    assert_eq!(found.quote, QuoteStyle::Single);
}

#[test]
fn a_file_with_no_block_at_all_reads_as_four_spaces() {
    let held = Fixture::of(b"value = 1\n");
    let found = style::detect(&held.source, held.lexed.as_slice());

    assert!(!found.indent_tabs);
    assert_eq!(found.indent_width, 4);
    assert_eq!(found.indent.length, 0);
}

#[test]
fn a_mixed_indent_is_kept_byte_for_byte() {
    let held = Fixture::of(b"def read():\n  \tvalue = 1\n");
    let found = style::detect(&held.source, held.lexed.as_slice());

    assert!(!found.indent_tabs);
    assert_eq!(found.indent_width, 3);
    assert_eq!(held.text(found.indent), "  \t");
}

#[test]
fn an_empty_file_reads_as_the_defaults() {
    let found = style::detect(b"", &[]);

    assert!(!found.indent_tabs);
    assert_eq!(found.indent_width, 4);
    assert_eq!(found.line_ending, LineEnding::LineFeed);
    assert_eq!(found.quote, QuoteStyle::Double);
}

#[test]
fn a_comment_only_file_reads_as_the_defaults_with_its_own_ending() {
    let held = Fixture::of(b"# only a comment\r\n");
    let found = style::detect(&held.source, held.lexed.as_slice());

    assert!(!found.indent_tabs);
    assert_eq!(found.indent_width, 4);
    assert_eq!(found.line_ending, LineEnding::CarriageReturnLineFeed);
    assert_eq!(found.quote, QuoteStyle::Double);
}

#[test]
fn an_import_goes_under_the_last_import_of_the_first_block() {
    let held = Fixture::of(b"\"doc\"\n\nimport os\nimport sys\n\nvalue = 1\n");

    let (leading, offset) =
        imports::insertion_point(held.tokens.as_slice(), &held.tree, &held.index);

    assert_eq!(leading, 0);
    assert_eq!(offset, 28);
}

#[test]
fn an_import_goes_under_the_docstring_when_the_file_has_no_import() {
    let held = Fixture::of(b"\"doc\"\n\nvalue = 1\n");

    let (leading, offset) =
        imports::insertion_point(held.tokens.as_slice(), &held.tree, &held.index);

    assert_eq!(leading, 1);
    assert_eq!(offset, 6);
}

#[test]
fn an_import_goes_to_the_head_of_a_file_with_neither() {
    let held = Fixture::of(b"value = 1\n");

    let (leading, offset) =
        imports::insertion_point(held.tokens.as_slice(), &held.tree, &held.index);

    assert_eq!(leading, 0);
    assert_eq!(offset, 0);
}

#[test]
fn the_raw_kinds_stay_beside_the_tokens_the_tree_indexes() {
    let held = Fixture::of(b"value = 1\n");

    assert_eq!(
        held.raw.count(),
        u32::try_from(held.tokens.as_slice().len()).expect("a bounded count fits in u32")
    );
}
