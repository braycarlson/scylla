use crate::bounded::{Buffer, Span};
use crate::format::brace::{self, Policy};
use crate::format::print::Options;
use crate::syntax::javascript::kind::JavaScriptKind as Kind;
use crate::token::Token;
use crate::tree::{Structure, Tree};

pub const POLICY: Policy = Policy {
    arrow_after: &[],
    blank_max: 1,
    block_words: &[],
    brace_hugs: false,
    brace_spaces: true,
    brace_words: &[],
    bracket_types: false,
    cast_words: &[],
    dedent_words: &[],
    hug_words: &[],
    operand_words: &[b"import", b"super", b"this"],
    postfix_words: &[],
    prefix_words: &[b"...", b"@"],
    signature_words: &[],
    source_gaps: false,
    source_words: &[],
    tight_from_source: &[b"!", b"*", b"+", b"++", b"-", b"--", b"<", b">", b"?"],
    ternary_colon: true,
    tight_words: &[],
    unary_words: &[b"!", b"-", b"+", b"~", b"..."],
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
        .raw
        .iter()
        .any(|kind| kind.name().starts_with("Jsx") || kind.name().starts_with("Template"))
    {
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
