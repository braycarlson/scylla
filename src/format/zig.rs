use crate::bounded::{Buffer, Span};
use crate::format::brace::{self, Policy};
use crate::format::print::Options;
use crate::syntax::zig::kind::ZigKind as Kind;
use crate::token::Token;
use crate::tree::{Structure, Tree};

pub const POLICY: Policy = Policy {
    blank_max: 1,
    block_words: &[
        b"comptime",
        b"export",
        b"fn",
        b"inline",
        b"noinline",
        b"pub",
        b"test",
    ],
    brace_hugs: true,
    brace_spaces: true,
    brace_words: &[b"struct"],
    bracket_types: true,
    cast_words: &[],
    dedent_words: &[],
    hug_words: &[b"align", b"callconv", b"enum", b"error", b"union"],
    operand_words: &[],
    postfix_words: &[],
    prefix_words: &[b"@"],
    signature_words: &[],
    source_gaps: false,
    source_words: &[b"|"],
    tight_from_source: &[b"!", b"?"],
    ternary_colon: false,
    tight_words: &[],
    unary_words: &[b"!", b"&", b"*", b"-", b"?", b"~"],
    units: false,
};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Outcome {
    Complete,
    Overflow,
    Refusal,
}

pub struct Input<'held> {
    pub options: Options,
    pub outcome: Structure,
    pub raw: &'held [Kind],
    pub source: &'held [u8],
    pub tokens: &'held [Token],
    pub tree: &'held Tree<Kind>,
}

#[derive(Debug)]
pub struct Formatter {
    inner: brace::Formatter,
}

fn broken(input: &Input<'_>) -> bool {
    if input.outcome != Structure::Complete || !input.tree.errors().is_empty() {
        return true;
    }

    if input.raw.contains(&Kind::ErrorToken) {
        return true;
    }

    if input
        .tree
        .as_slice()
        .iter()
        .any(|node| node.kind == Kind::ErrorNode)
    {
        return true;
    }

    !brace::balanced(input.tokens)
}

impl Formatter {
    pub fn reserve(element_count_max: u32) -> Self {
        Self {
            inner: brace::Formatter::reserve(element_count_max),
        }
    }

    #[must_use]
    pub fn format(&mut self, input: &Input<'_>, out: &mut Buffer) -> Outcome {
        assert_eq!(input.tokens.len(), input.raw.len());

        if broken(input) {
            return Outcome::Refusal;
        }

        let held = brace::Input {
            options: input.options,
            policy: POLICY,
            source: input.source,
            tokens: input.tokens,
        };

        if !self.inner.format(&held, out) {
            return Outcome::Overflow;
        }

        Outcome::Complete
    }

    #[must_use]
    pub fn range(
        &mut self,
        input: &Input<'_>,
        lines: (u32, u32),
        out: &mut Buffer,
    ) -> Option<Span> {
        if self.format(input, out) != Outcome::Complete {
            return None;
        }

        brace::span_of(out.as_bytes(), lines)
    }
}
