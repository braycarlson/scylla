use crate::bounded::{Span, count_of};
use crate::lines::LineEnding;
use crate::syntax::python::literal;
use crate::token::{Token, TokenKind};

const INDENT_WIDTH_DEFAULT: u32 = 4;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum QuoteStyle {
    Double,
    Single,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Style {
    pub indent: Span,
    pub indent_tabs: bool,
    pub indent_width: u32,
    pub line_ending: LineEnding,
    pub quote: QuoteStyle,
}

impl QuoteStyle {
    pub const fn byte(self) -> u8 {
        match self {
            Self::Double => b'"',
            Self::Single => b'\'',
        }
    }
}

pub fn detect(source: &[u8], tokens: &[Token]) -> Style {
    let indent = indent_of(source, tokens);

    Style {
        indent,
        indent_tabs: source.get(indent.offset as usize) == Some(&b'\t'),
        indent_width: if indent.length > 0 {
            indent.length
        } else {
            INDENT_WIDTH_DEFAULT
        },
        line_ending: LineEnding::of_source(source),
        quote: quote_of(source, tokens),
    }
}

fn indent_of(source: &[u8], tokens: &[Token]) -> Span {
    let Some(token) = tokens
        .iter()
        .find(|held| held.kind == TokenKind::BlockStart)
    else {
        return Span::EMPTY;
    };

    let start = crate::scan::line_start_of(source, token.offset as usize);
    let mut end = start;

    while end < source.len() && matches!(source[end], b'\t' | b' ') {
        end += 1;
    }

    assert!(end >= start);

    Span {
        length: count_of(end - start),
        offset: count_of(start),
    }
}

fn quote_of(source: &[u8], tokens: &[Token]) -> QuoteStyle {
    let Some(token) = tokens.iter().find(|held| held.kind == TokenKind::String) else {
        return QuoteStyle::Double;
    };

    let text = &source[token.offset as usize..token.end() as usize];

    let Some(shape) = literal::shape_of(text, token.offset) else {
        return QuoteStyle::Double;
    };

    if shape.quote.byte == b'\'' {
        return QuoteStyle::Single;
    }

    QuoteStyle::Double
}
