pub mod align;
pub mod brace;
pub mod css;
pub mod go;
pub mod ir;
pub mod javascript;
pub mod markup;
pub mod mask;
pub mod odin;
pub mod policy;
pub mod print;
pub mod python;
pub mod reach;
pub mod rust;
pub mod stream;
pub mod text;
pub mod typescript;
pub mod walk;
pub mod zig;

use crate::bounded::{Buffer, Span};
use crate::language::Language;
use crate::lines;
use crate::suppress::Pragmas;
use crate::syntax::front::{Front, Tables};
use crate::syntax::python::style::{self, LineEnding};
use crate::token::{Token, TokenKind};

pub use python::QuotePreference;

#[expect(
    clippy::struct_field_names,
    reason = "the `_max` postfix is the big-endian convention naming the bound each field carries"
)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Limits {
    pub arena_bytes_max: u32,
    pub element_count_max: u32,
    pub line_count_max: u32,
    pub pragma_count_max: u32,
    pub scratch_bytes_max: u32,
}

#[derive(Clone, Copy, Debug)]
pub struct Input {
    pub line_ending: Option<LineEnding>,
    pub magic_trailing_comma: bool,
    pub options: print::Options,
    pub quote: QuotePreference,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Outcome {
    Complete,
    Overflow,
    Refusal,
    Unsupported,
}

pub struct Formatters {
    css: Option<css::Formatter>,
    go: Option<go::Formatter>,
    javascript: Option<javascript::Formatter>,
    odin: Option<odin::Formatter>,
    python: Option<PythonFormatter>,
    rust: Option<rust::Formatter>,
    typescript: Option<typescript::Formatter>,
    zig: Option<zig::Formatter>,
}

struct PythonFormatter {
    formatter: python::Formatter,
    lines: lines::Index,
    pragmas: Pragmas,
}

macro_rules! brace_format {
    (
        $held:expr,
        $module:ident,
        $syntax:expr,
        $source:expr,
        $input:expr,
        $outcome:expr,
        $out:expr
    ) => {
        $held.as_mut().map_or(Outcome::Unsupported, |held| {
            let formatted = held.format(
                &$module::Input {
                    options: $input.options,
                    outcome: $outcome,
                    raw: &$syntax.raw,
                    source: $source,
                    tokens: $syntax.tokens.as_slice(),
                    tree: &$syntax.tree,
                },
                $out,
            );

            match formatted {
                $module::Outcome::Complete => Outcome::Complete,
                $module::Outcome::Overflow => Outcome::Overflow,
                $module::Outcome::Refusal => Outcome::Refusal,
            }
        })
    };
}

impl Formatters {
    pub fn reserve(limits: &Limits, wanted: [bool; Language::COUNT]) -> Self {
        assert!(limits.element_count_max > 0);
        assert!(limits.arena_bytes_max > 0);

        assert!(!crate::allocation::is_frozen());

        let count = limits.element_count_max;

        Self {
            css: wanted[Language::Css.index()]
                .then(|| css::Formatter::reserve(count, limits.scratch_bytes_max)),
            go: wanted[Language::Go.index()]
                .then(|| go::Formatter::reserve(count, limits.scratch_bytes_max)),
            javascript: wanted[Language::JavaScript.index()]
                .then(|| javascript::Formatter::reserve(count, limits.scratch_bytes_max)),
            odin: wanted[Language::Odin.index()]
                .then(|| odin::Formatter::reserve(count, limits.scratch_bytes_max)),
            python: wanted[Language::Python.index()].then(|| PythonFormatter {
                formatter: python::Formatter::reserve(count, limits.arena_bytes_max),
                lines: lines::Index::reserve(limits.line_count_max),
                pragmas: Pragmas::reserve(limits.pragma_count_max),
            }),
            rust: wanted[Language::Rust.index()]
                .then(|| rust::Formatter::reserve(count, limits.scratch_bytes_max)),
            typescript: (wanted[Language::TypeScript.index()] || wanted[Language::Tsx.index()])
                .then(|| typescript::Formatter::reserve(count, limits.scratch_bytes_max)),
            zig: wanted[Language::Zig.index()]
                .then(|| zig::Formatter::reserve(count, limits.scratch_bytes_max)),
        }
    }

    #[must_use]
    pub fn format(
        &mut self,
        front: &Front,
        lexed: &[Token],
        source: &[u8],
        input: &Input,
        out: &mut Buffer,
    ) -> Outcome {
        assert!(u32::try_from(source.len()).is_ok());

        let outcome = front.outcome();

        match front.tables() {
            Tables::Css { syntax, .. } => {
                brace_format!(self.css, css, syntax, source, input, outcome, out)
            }
            Tables::Go { syntax, .. } => {
                brace_format!(self.go, go, syntax, source, input, outcome, out)
            }
            Tables::JavaScript { syntax, .. } => {
                brace_format!(
                    self.javascript,
                    javascript,
                    syntax,
                    source,
                    input,
                    outcome,
                    out
                )
            }
            Tables::Markup { .. } => Outcome::Unsupported,
            Tables::Odin { syntax, .. } => {
                brace_format!(self.odin, odin, syntax, source, input, outcome, out)
            }
            Tables::Python { syntax, .. } => {
                self.python.as_mut().map_or(Outcome::Unsupported, |held| {
                    held.format(syntax, lexed, source, input, outcome, out)
                })
            }
            Tables::Rust { syntax, .. } => {
                brace_format!(self.rust, rust, syntax, source, input, outcome, out)
            }
            Tables::TypeScript { syntax, .. } => {
                brace_format!(
                    self.typescript,
                    typescript,
                    syntax,
                    source,
                    input,
                    outcome,
                    out
                )
            }
            Tables::Zig { syntax, .. } => {
                brace_format!(self.zig, zig, syntax, source, input, outcome, out)
            }
        }
    }
}

impl PythonFormatter {
    fn format(
        &mut self,
        syntax: &crate::syntax::front::Syntax<crate::syntax::python::kind::PythonKind>,
        lexed: &[Token],
        source: &[u8],
        input: &Input,
        outcome: crate::tree::Structure,
        out: &mut Buffer,
    ) -> Outcome {
        if !self.lines.build(source) {
            return Outcome::Overflow;
        }

        let comments = lexed
            .iter()
            .filter(|token| token.kind == TokenKind::Comment)
            .map(|token| Span {
                length: token.length,
                offset: token.offset,
            });

        self.pragmas.scan(source, comments, &self.lines);

        let detected = style::detect(source, lexed);

        let held = python::Input {
            line_ending: input.line_ending.unwrap_or(detected.line_ending),
            magic_trailing_comma: input.magic_trailing_comma,
            options: input.options,
            outcome,
            pragmas: self.pragmas.as_slice(),
            quote: input.quote,
            raw: &syntax.raw,
            source,
            tokens: syntax.tokens.as_slice(),
            tree: &syntax.tree,
        };

        match self.formatter.format(&held, out) {
            python::Outcome::Complete => Outcome::Complete,
            python::Outcome::Overflow => Outcome::Overflow,
            python::Outcome::Refusal => Outcome::Refusal,
        }
    }
}
