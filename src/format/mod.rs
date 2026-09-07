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
use crate::language::{Language, Lexer};
use crate::lines::{self, LineEnding};
use crate::suppress::Pragmas;
use crate::syntax::front::{self, Front, Fronts, Options, Syntax, Tables};
use crate::syntax::python::kind::PythonKind;
use crate::syntax::python::style;
use crate::token::{Lex, Token, TokenKind, Tokens};
use crate::tree::Structure;

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

#[derive(Clone, Copy)]
pub struct Request<'run> {
    pub input: &'run Input,
    pub lexer: &'run dyn Lexer,
    pub options: &'run Options<'run>,
    pub path: &'run [u8],
    pub source: &'run [u8],
}

pub struct Formatters {
    css: Option<css::Formatter>,
    go: Option<go::Formatter>,
    javascript: Option<javascript::Formatter>,
    markup: Option<MarkupFormatter>,
    odin: Option<odin::Formatter>,
    python: Option<PythonFormatter>,
    rust: Option<rust::Formatter>,
    typescript: Option<typescript::Formatter>,
    zig: Option<zig::Formatter>,
}

struct MarkupFormatter {
    formatter: markup::Formatter,
    lines: lines::Index,
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
            markup: wanted[Language::Markup.index()].then(|| MarkupFormatter {
                formatter: markup::Formatter::reserve(
                    count,
                    limits.line_count_max,
                    limits.scratch_bytes_max,
                ),
                lines: lines::Index::reserve(limits.line_count_max),
            }),
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
            Tables::Markup { .. } => self.markup.as_mut().map_or(Outcome::Unsupported, |held| {
                held.format(front.tables(), source, input, outcome, out)
            }),
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

    #[must_use]
    pub fn format_source(
        &mut self,
        fronts: &mut Fronts,
        lexed: &mut Tokens,
        request: &Request<'_>,
        out: &mut Buffer,
    ) -> Outcome {
        assert!(u32::try_from(request.source.len()).is_ok());

        let Some(language) = Language::of_name(request.lexer.identifier()) else {
            return Outcome::Unsupported;
        };

        let index = fronts.of_path(language, request.path);

        if index == front::NONE {
            return Outcome::Unsupported;
        }

        lexed.clear();

        if language != Language::Markup && request.lexer.lex(request.source, lexed) != Lex::Complete
        {
            return Outcome::Refusal;
        }

        let _ = fronts.build(index, request.source, lexed.as_slice(), request.options);

        self.format(
            fronts.at(index),
            lexed.as_slice(),
            request.source,
            request.input,
            out,
        )
    }
}

impl MarkupFormatter {
    fn format(
        &mut self,
        tables: &Tables,
        source: &[u8],
        input: &Input,
        outcome: Structure,
        out: &mut Buffer,
    ) -> Outcome {
        let Tables::Markup {
            blocks: map,
            tokens,
            tree,
            ..
        } = tables
        else {
            return Outcome::Unsupported;
        };

        if outcome != Structure::Complete {
            return Outcome::Refusal;
        }

        if !self.lines.build(source) {
            return Outcome::Overflow;
        }

        let held = markup::Input {
            index: &self.lines,
            map,
            options: input.options,
            source,
            tokens: tokens.as_slice(),
            tree,
        };

        match self.formatter.format(&held, out) {
            markup::Outcome::Complete => Outcome::Complete,
            markup::Outcome::Overflow => Outcome::Overflow,
            markup::Outcome::Refusal => Outcome::Refusal,
        }
    }
}

impl PythonFormatter {
    fn format(
        &mut self,
        syntax: &Syntax<PythonKind>,
        lexed: &[Token],
        source: &[u8],
        input: &Input,
        outcome: Structure,
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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::language::Grammar;
    use crate::lex::PYTHON;
    use crate::markup::Vocabulary;
    use crate::markup::blocks::TagSpecification;
    use crate::syntax::python::stdlib::PythonVersion;

    struct MarkupLexer;

    const FRONT_LIMITS: front::Limits = front::Limits {
        binding_count_max: 1 << 8,
        error_count_max: 1 << 6,
        event_count_max: 1 << 12,
        export_count_max: 1 << 6,
        fact_count_max: 1 << 6,
        node_count_max: 1 << 10,
        reference_count_max: 1 << 8,
        scope_count_max: 1 << 6,
        segment_count_max: 1 << 6,
        tag_count_max: 1 << 6,
        token_count_max: 1 << 10,
    };

    const INPUT: Input = Input {
        line_ending: None,
        magic_trailing_comma: true,
        options: print::Options::DEFAULT,
        quote: QuotePreference::Double,
    };

    const LIMITS: Limits = Limits {
        arena_bytes_max: 1 << 14,
        element_count_max: 1 << 12,
        line_count_max: 1 << 8,
        pragma_count_max: 1 << 4,
        scratch_bytes_max: 1 << 14,
    };

    const OPTIONS: Options<'static> = Options {
        globals: &[],
        python_version: PythonVersion::Py310,
        template_imports: &[],
    };

    const VOCABULARY: Vocabulary<'static> = Vocabulary {
        end_prefix: b"end",
        extends_tags: &[],
        intermediate_words: &[b"else"],
        only_word: b"",
        raw_text_tags: &[],
        specifications: &[TagSpecification {
            intermediates: &[b"else"],
            name: b"if",
        }],
    };

    impl Lexer for MarkupLexer {
        fn extensions(&self) -> &'static [&'static [u8]] {
            &[b"html"]
        }

        fn grammar(&self) -> &'static Grammar {
            &Grammar::DEFAULT
        }

        fn identifier(&self) -> &'static str {
            "markup"
        }

        fn lex(&self, _source: &[u8], _tokens: &mut Tokens) -> Lex {
            Lex::Complete
        }
    }

    fn formatted(lexer: &dyn Lexer, path: &[u8], source: &[u8]) -> (Outcome, String) {
        let languages = [Language::Markup, Language::Python];
        let mut fronts = Fronts::reserve(&FRONT_LIMITS, &languages);
        let mut formatters = Formatters::reserve(&LIMITS, fronts.wanted());
        let mut tokens = Tokens::reserve(FRONT_LIMITS.token_count_max);
        let mut out = Buffer::reserve(1 << 12);

        fronts.vocabulary_set(VOCABULARY);

        let request = Request {
            input: &INPUT,
            lexer,
            options: &OPTIONS,
            path,
            source,
        };

        let outcome = formatters.format_source(&mut fronts, &mut tokens, &request, &mut out);

        (
            outcome,
            String::from_utf8_lossy(out.as_bytes()).into_owned(),
        )
    }

    #[test]
    fn a_markup_front_formats_through_the_table() {
        let (outcome, text) = formatted(
            &MarkupLexer,
            b"a.html",
            b"{% if a %}\n<p>b</p>\n{% endif %}\n",
        );

        assert_eq!(outcome, Outcome::Complete);
        assert_eq!(text, "{% if a %}\n    <p>b</p>\n{% endif %}\n");
    }

    #[test]
    fn a_source_formats_in_one_call() {
        let (outcome, text) = formatted(&PYTHON, b"a.py", b"x  =  1\n");

        assert_eq!(outcome, Outcome::Complete);
        assert_eq!(text, "x = 1\n");
    }

    #[test]
    fn a_language_without_a_front_is_unsupported() {
        let mut fronts = Fronts::reserve(&FRONT_LIMITS, &[Language::Python]);
        let mut formatters = Formatters::reserve(&LIMITS, fronts.wanted());
        let mut tokens = Tokens::reserve(FRONT_LIMITS.token_count_max);
        let mut out = Buffer::reserve(1 << 12);

        let request = Request {
            input: &INPUT,
            lexer: &MarkupLexer,
            options: &OPTIONS,
            path: b"a.html",
            source: b"<p>a</p>\n",
        };

        assert_eq!(
            formatters.format_source(&mut fronts, &mut tokens, &request, &mut out),
            Outcome::Unsupported
        );
    }

    #[test]
    fn a_markup_front_with_errors_is_refused() {
        let (outcome, _) = formatted(&MarkupLexer, b"a.html", b"<p><span>a</p>\n");

        assert_eq!(outcome, Outcome::Refusal);
    }
}
