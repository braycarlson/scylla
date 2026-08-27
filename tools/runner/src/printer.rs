use scylla::bounded::{Buffer, Span};
use scylla::format::print::Options;
use scylla::lines;
use scylla::suppress::Pragmas;
use scylla::token::{Token, TokenKind, Tokens};

use scylla::format::css as css_format;
use scylla::format::go as go_format;
use scylla::format::javascript as javascript_format;
use scylla::format::odin as odin_format;
use scylla::format::rust as rust_format;
use scylla::format::typescript as typescript_format;
use scylla::format::zig as zig_format;
use scylla::syntax::css::kind::CSSKind;
use scylla::syntax::go::kind::GoKind;
use scylla::syntax::javascript::kind::JavaScriptKind;
use scylla::syntax::odin::kind::OdinKind;
use scylla::syntax::python::kind::PythonKind;
use scylla::syntax::rust::kind::RustKind;
use scylla::syntax::typescript::kind::TypeScriptKind;
use scylla::syntax::zig::kind::ZigKind;

use crate::format::{options_of, Print, Printer};

const ELEMENT_COUNT_MAX: u32 = 1 << 18;
const LINE_COUNT_MAX: u32 = 1 << 18;
const OUT_BYTES_MAX: u32 = 1 << 24;
const PRAGMA_COUNT_MAX: u32 = 1 << 14;
const TOKEN_COUNT_MAX: u32 = 1 << 21;

macro_rules! printer {
    ($name:ident, $module:ident, $kind:ty, $options:expr, $reserve:expr) => {
        pub struct $name {
            formatter: $module::Formatter,
            options: Options,
        }

        impl $name {
            pub fn reserve() -> Self {
                Self {
                    formatter: $reserve,
                    options: $options,
                }
            }
        }

        impl Printer<$kind> for $name {
            fn print(&mut self, held: &Print<'_, $kind>, out: &mut Buffer) -> bool {
                let input = $module::Input {
                    options: self.options,
                    outcome: held.outcome,
                    raw: held.raw,
                    source: held.source,
                    tokens: held.tokens,
                    tree: held.tree,
                };

                self.formatter.format(&input, out) == $module::Outcome::Complete
            }
        }
    };
}

printer!(
    Css,
    css_format,
    CSSKind,
    Options::DEFAULT,
    css_format::Formatter::reserve(ELEMENT_COUNT_MAX)
);

printer!(
    Go,
    go_format,
    GoKind,
    options_of(true, 8),
    go_format::Formatter::reserve(ELEMENT_COUNT_MAX, OUT_BYTES_MAX)
);

printer!(
    JavaScript,
    javascript_format,
    JavaScriptKind,
    Options::DEFAULT,
    javascript_format::Formatter::reserve(ELEMENT_COUNT_MAX)
);

printer!(
    Odin,
    odin_format,
    OdinKind,
    options_of(true, 4),
    odin_format::Formatter::reserve(ELEMENT_COUNT_MAX)
);

printer!(
    Rust,
    rust_format,
    RustKind,
    Options::DEFAULT,
    rust_format::Formatter::reserve(ELEMENT_COUNT_MAX)
);

printer!(
    TypeScript,
    typescript_format,
    TypeScriptKind,
    Options::DEFAULT,
    typescript_format::Formatter::reserve(ELEMENT_COUNT_MAX)
);

printer!(
    Zig,
    zig_format,
    ZigKind,
    Options::DEFAULT,
    zig_format::Formatter::reserve(ELEMENT_COUNT_MAX)
);

pub struct Python {
    formatter: scylla::format::python::Formatter,
    index: lines::Index,
    lexed: Tokens,
    pragmas: Pragmas,
}

impl Python {
    pub fn reserve() -> Self {
        Self {
            formatter: scylla::format::python::Formatter::reserve(ELEMENT_COUNT_MAX, OUT_BYTES_MAX),
            index: lines::Index::reserve(LINE_COUNT_MAX),
            lexed: Tokens::reserve(TOKEN_COUNT_MAX),
            pragmas: Pragmas::reserve(PRAGMA_COUNT_MAX),
        }
    }
}

impl Printer<PythonKind> for Python {
    fn print(&mut self, held: &Print<'_, PythonKind>, out: &mut Buffer) -> bool {
        use scylla::format::python::{Input, Outcome, QuotePreference};
        use scylla::language::Lexer as _;
        use scylla::syntax::python::style::LineEnding;

        self.lexed.clear();
        scylla::lex::PYTHON.lex(held.source, &mut self.lexed);

        if !self.index.build(held.source) {
            return false;
        }

        let comments: Vec<Span> = self
            .lexed
            .as_slice()
            .iter()
            .filter(|token| token.kind == TokenKind::Comment)
            .map(Token::span)
            .collect();

        self.pragmas
            .scan(held.source, comments.iter().copied(), &self.index);

        let input = Input {
            line_ending: LineEnding::LineFeed,
            magic_trailing_comma: true,
            options: Options::DEFAULT,
            outcome: held.outcome,
            pragmas: self.pragmas.as_slice(),
            quote: QuotePreference::Double,
            raw: held.raw,
            source: held.source,
            tokens: held.tokens,
            tree: held.tree,
        };

        self.formatter.format(&input, out) == Outcome::Complete
    }
}
