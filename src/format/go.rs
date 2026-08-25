use crate::bounded::{Buffer, Bytes as _, Span};
use crate::format::align::{self, Target};
use crate::format::brace::{self, Policy};
use crate::format::print::Options;
use crate::syntax::go::kind::GoKind as Kind;
use crate::token::Token;
use crate::tree::{Structure, Tree};

pub const POLICY: Policy = Policy {
    blank_max: 1,
    block_words: &[],
    brace_hugs: true,
    brace_spaces: false,
    brace_words: &[b"interface", b"struct"],
    bracket_types: true,
    cast_words: &[],
    dedent_words: &[b"case", b"default"],
    hug_words: &[b"chan", b"func", b"interface", b"map", b"struct"],
    operand_words: &[],
    postfix_words: &[b"++", b"--"],
    prefix_words: &[],
    signature_words: &[b"func"],
    source_gaps: false,
    source_words: &[],
    tight_from_source: &[],
    ternary_colon: false,
    tight_words: &[],
    unary_words: &[b"!", b"&", b"&^", b"*", b"-", b"...", b"<-", b"^", b"~"],
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
    scratch: Buffer,
    staged: Buffer,
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
    pub fn reserve(element_count_max: u32, scratch_bytes_max: u32) -> Self {
        assert!(scratch_bytes_max > 0);

        assert!(!crate::allocation::is_frozen());

        Self {
            inner: brace::Formatter::reserve(element_count_max),
            scratch: Buffer::reserve(scratch_bytes_max),
            staged: Buffer::reserve(scratch_bytes_max),
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

        if !self.inner.format(&held, &mut self.scratch) {
            return Outcome::Overflow;
        }

        if !align::align(self.scratch.as_bytes(), Target::Assign, &mut self.staged) {
            return Outcome::Overflow;
        }

        if !align::align(self.staged.as_bytes(), Target::Comment, &mut self.scratch) {
            return Outcome::Overflow;
        }

        out.clear();

        if !out.push_bytes(self.scratch.as_bytes()) {
            out.clear();

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
