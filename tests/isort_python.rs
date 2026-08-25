use scylla::bounded::{BoundedVec, Buffer};
use scylla::language::Lexer as _;
use scylla::lex::PYTHON;
use scylla::lines;
use scylla::syntax::python::classify::classify;
use scylla::syntax::python::imports::{self, Block, Parsed};
use scylla::syntax::python::kind::PythonKind;
use scylla::syntax::python::parse;
use scylla::syntax::python::style::{self, Style};
use scylla::token::Tokens;
use scylla::tree::{Events, Structure, Tree};

const LINE_WIDTH: u32 = 88;

struct Fixture {
    blocks: BoundedVec<Block>,
    index: lines::Index,
    source: Vec<u8>,
    style: Style,
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
        let mut blocks = BoundedVec::reserve(1 << 8);

        PYTHON.lex(source, &mut lexed);

        assert!(classify(source, lexed.as_slice(), &mut tokens, &mut raw));

        assert_eq!(
            parse::build(source, tokens.as_slice(), &raw, &mut events, &mut tree),
            Structure::Complete
        );

        assert!(index.build(source));

        assert!(imports::blocks(
            tokens.as_slice(),
            &tree,
            &index,
            &mut blocks
        ));

        let style = style::detect(source, lexed.as_slice());

        Self {
            blocks,
            index,
            source: source.to_vec(),
            style,
            tokens,
            tree,
        }
    }

    fn parsed(&self) -> Parsed<'_> {
        Parsed {
            index: &self.index,
            source: &self.source,
            tokens: self.tokens.as_slice(),
            tree: &self.tree,
        }
    }

    fn sorted_into(
        &self,
        position: u32,
        first_party: &[&[u8]],
        out: &mut Buffer,
    ) -> Option<String> {
        assert!(position < self.blocks.count());

        if !imports::sort(
            &self.parsed(),
            &self.blocks[position as usize],
            first_party,
            self.style,
            LINE_WIDTH,
            out,
        ) {
            return None;
        }

        Some(String::from_utf8_lossy(out.as_bytes()).into_owned())
    }

    fn sorted(&self) -> Option<String> {
        let mut out = Buffer::reserve(1 << 14);

        assert_eq!(self.blocks.count(), 1);

        self.sorted_into(0, &[], &mut out)
    }
}

fn sorted_of(source: &[u8]) -> String {
    Fixture::of(source).sorted().expect("the sorter renders")
}

#[test]
fn a_mixed_block_sorts_into_sections_with_a_blank_line_between_them() {
    let held = sorted_of(
        b"import requests\nimport os\nfrom collections import OrderedDict\nimport sys\
            \nfrom mypkg import thing\n",
    );

    assert_eq!(
        held,
        "import os\nimport sys\nfrom collections import OrderedDict\n\
         \nimport requests\nfrom mypkg import thing\n"
    );
}

#[test]
fn a_plain_import_of_several_modules_splits_into_one_statement_each() {
    let held = sorted_of(b"import os, sys, collections\n");

    assert_eq!(held, "import collections\nimport os\nimport sys\n");
}

#[test]
fn a_from_statement_past_the_line_width_wraps_one_name_a_line() {
    let held = sorted_of(
        b"from collections import OrderedDict, defaultdict, namedtuple, Counter, deque, \
          ChainMap, UserDict\n",
    );

    assert_eq!(
        held,
        concat!(
            "from collections import (\n",
            "    ChainMap,\n",
            "    Counter,\n",
            "    OrderedDict,\n",
            "    UserDict,\n",
            "    defaultdict,\n",
            "    deque,\n",
            "    namedtuple,\n",
            ")\n",
        )
    );
}

#[test]
fn a_magic_trailing_comma_keeps_a_short_statement_exploded() {
    let held = sorted_of(b"from a import (\n    b,\n)\n");

    assert_eq!(held, "from a import (\n    b,\n)\n");
}

#[test]
fn a_parenthesis_closed_without_a_comma_collapses_onto_one_line() {
    let held = sorted_of(b"from a import (\n    c,\n    b\n)\n");

    assert_eq!(held, "from a import b, c\n");
}

#[test]
fn a_magic_trailing_comma_carries_through_a_merge_and_stays_off_the_alias() {
    let held = sorted_of(b"from a import x as y, b\nfrom a import (\n    z,\n)\n");

    assert_eq!(
        held,
        "from a import (\n    b,\n    z,\n)\nfrom a import x as y\n"
    );
}

#[test]
fn a_magic_trailing_comma_on_a_statement_with_an_alias_explodes_both_statements() {
    let held = sorted_of(b"from a import (B, a, c as d,)\n");

    assert_eq!(
        held,
        "from a import (\n    B,\n    a,\n)\nfrom a import (\n    c as d,\n)\n"
    );
}

#[test]
fn a_wrapped_statement_indents_with_the_file_s_own_bytes() {
    let held = sorted_of(b"from a import (\n    c,\n    b,\n)\n\n\ndef f():\n  \treturn 1\n");

    assert_eq!(held, "from a import (\n  \tb,\n  \tc,\n)\n");
}

#[test]
fn an_aliased_name_keeps_its_own_statement_below_the_plain_ones() {
    let held = sorted_of(b"from collections import OrderedDict as OD, defaultdict, Counter\n");

    assert_eq!(
        held,
        "from collections import Counter, defaultdict\nfrom collections import OrderedDict as OD\n"
    );
}

#[test]
fn an_aliased_module_keeps_its_alias() {
    let held =
        sorted_of(b"import numpy as np\nimport os\nfrom collections import OrderedDict as OD\n");

    assert_eq!(
        held,
        "import os\nfrom collections import OrderedDict as OD\n\nimport numpy as np\n"
    );
}

#[test]
fn a_deeper_relative_import_stands_above_a_shallower_one() {
    let held =
        sorted_of(b"from . import a\nfrom .. import b\nfrom ...pkg import c\nfrom .mod import d\n");

    assert_eq!(
        held,
        "from ...pkg import c\nfrom .. import b\nfrom . import a\nfrom .mod import d\n"
    );
}

#[test]
fn a_relative_import_sorts_below_every_absolute_one() {
    let held = sorted_of(b"from . import sibling\nfrom ..pkg import thing\nimport os\n");

    assert_eq!(
        held,
        "import os\n\nfrom ..pkg import thing\nfrom . import sibling\n"
    );
}

#[test]
fn a_module_name_sorts_without_regard_to_case() {
    let held = sorted_of(b"import Zebra\nimport apple\nimport Beta\n");

    assert_eq!(held, "import apple\nimport Beta\nimport Zebra\n");
}

#[test]
fn a_module_name_differing_only_in_case_sorts_uppercase_first() {
    let held = sorted_of(b"import ab\nimport AB\n");

    assert_eq!(held, "import AB\nimport ab\n");
}

#[test]
fn a_module_name_holding_a_number_sorts_in_natural_order() {
    let held = sorted_of(b"import a10\nimport a9\n");

    assert_eq!(held, "import a9\nimport a10\n");
}

#[test]
fn a_digit_run_opening_on_a_zero_sorts_digit_by_digit() {
    let held = sorted_of(
        b"import a10\nimport a9\nimport a1\nimport a010\nimport a01\nimport a001\nimport a0\
            \nimport a00\n",
    );

    assert_eq!(
        held,
        concat!(
            "import a0\n",
            "import a00\n",
            "import a001\n",
            "import a01\n",
            "import a010\n",
            "import a1\n",
            "import a9\n",
            "import a10\n",
        )
    );
}

#[test]
fn an_imported_name_sorts_constants_then_classes_then_the_rest() {
    let held = sorted_of(b"from m import A, A_B, CONST1, _X, X1, Ab1, a, _, __\n");

    assert_eq!(
        held,
        "from m import _X, A_B, CONST1, X1, A, Ab1, _, __, a\n"
    );
}

#[test]
fn an_imported_name_list_already_in_type_order_is_left_as_it_stands() {
    let held = sorted_of(b"from collections import ZEBRA, Apple, beta\n");

    assert_eq!(held, "from collections import ZEBRA, Apple, beta\n");
}

#[test]
fn a_repeated_import_is_written_once() {
    let held = sorted_of(b"import os\nimport os\n");

    assert_eq!(held, "import os\n");
}

#[test]
fn two_statements_over_one_module_merge_into_one() {
    let held = sorted_of(b"from collections import b\nfrom collections import a\n");

    assert_eq!(held, "from collections import a, b\n");
}

#[test]
fn a_plain_import_stands_above_a_from_over_the_same_module() {
    let held = sorted_of(b"from a import x\nimport a\n");

    assert_eq!(held, "import a\nfrom a import x\n");
}

#[test]
fn a_first_party_module_sorts_below_every_third_party_one() {
    let held = Fixture::of(b"import requests\nimport mypkg\n");
    let mut out = Buffer::reserve(1 << 12);

    assert_eq!(
        held.sorted_into(0, &[b"mypkg"], &mut out),
        Some("import requests\n\nimport mypkg\n".to_owned())
    );
}

#[test]
fn a_future_import_sorts_above_every_other_section() {
    let held = sorted_of(b"import os\nfrom __future__ import annotations\n");

    assert_eq!(held, "from __future__ import annotations\n\nimport os\n");
}

#[test]
fn a_carriage_return_line_feed_file_sorts_with_its_own_ending() {
    let held = sorted_of(b"import sys\r\nimport os\r\n");

    assert_eq!(held, "import os\r\nimport sys\r\n");
}

#[test]
fn a_block_holding_a_comment_is_refused_rather_than_guessed_at() {
    assert_eq!(
        Fixture::of(b"import os\n# a comment\nimport sys\n").sorted(),
        None
    );
}

#[test]
fn a_block_holding_a_star_import_is_refused() {
    assert_eq!(
        Fixture::of(b"from os import *\nimport sys\n").sorted(),
        None
    );
}

#[test]
fn a_block_whose_first_import_follows_a_statement_on_its_line_is_refused() {
    let held = Fixture::of(b"x = 1; import sys\nimport os\n");

    assert_eq!(held.blocks.count(), 1);
    assert_eq!(held.sorted(), None);
}

#[test]
fn a_block_whose_last_import_precedes_a_statement_on_its_line_is_refused() {
    let held = Fixture::of(b"import sys\nimport os; x = 1\n");

    assert_eq!(held.blocks.count(), 1);
    assert_eq!(held.sorted(), None);
}

#[test]
fn a_block_past_the_import_count_is_refused() {
    let mut source = b"from m import ".to_vec();

    for position in 0..=imports::IMPORT_COUNT_MAX {
        if position > 0 {
            source.extend_from_slice(b", ");
        }

        source.extend_from_slice(format!("n{position}").as_bytes());
    }

    source.push(b'\n');

    assert_eq!(Fixture::of(&source).sorted(), None);
}

#[test]
fn a_buffer_too_small_for_the_block_is_reported_rather_than_cut() {
    let held = Fixture::of(b"import sys\nimport os\n");
    let mut out = Buffer::reserve(4);

    assert_eq!(held.sorted_into(0, &[], &mut out), None);
    assert_eq!(out.count(), 0);
}

#[test]
fn a_file_with_no_import_at_all_reports_no_block() {
    let held = Fixture::of(b"value = 1\n");

    assert_eq!(held.blocks.count(), 0);
}

#[test]
fn two_runs_separated_by_a_statement_are_two_blocks_each_sorted_alone() {
    let held = Fixture::of(b"import sys\nimport os\n\nvalue = 1\n\nimport b\nimport a\n");
    let mut out = Buffer::reserve(1 << 12);

    assert_eq!(held.blocks.count(), 2);

    assert_eq!(
        held.sorted_into(0, &[], &mut out),
        Some("import os\nimport sys\n".to_owned())
    );

    assert_eq!(
        held.sorted_into(1, &[], &mut out),
        Some("import a\nimport b\n".to_owned())
    );
}
