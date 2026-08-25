use crate::bounded::BoundedVec;
use crate::syntax::css::expression::{
    escape_end,
    identifier_end,
    is_name_start,
    number_end,
    unit_end,
};
use crate::syntax::css::kind::CSSKind;
use crate::token::{Token, TokenKind, Tokens};

#[cfg(test)]
const OPERATORS: [(&[u8], CSSKind); 34] = [
    (b"::", CSSKind::ColonColon),
    (b"$=", CSSKind::DollarEqual),
    (b"*=", CSSKind::StarEqual),
    (b"^=", CSSKind::CaretEqual),
    (b"|=", CSSKind::BarEqual),
    (b"~=", CSSKind::TildeEqual),
    (b"!", CSSKind::Bang),
    (b"#", CSSKind::Hash),
    (b"$", CSSKind::Dollar),
    (b"%", CSSKind::Percent),
    (b"&", CSSKind::Ampersand),
    (b"(", CSSKind::ParenOpen),
    (b")", CSSKind::ParenClose),
    (b"*", CSSKind::Star),
    (b"+", CSSKind::Plus),
    (b",", CSSKind::Comma),
    (b"-", CSSKind::Minus),
    (b".", CSSKind::Dot),
    (b"/", CSSKind::Slash),
    (b":", CSSKind::Colon),
    (b";", CSSKind::Semicolon),
    (b"<", CSSKind::Less),
    (b"=", CSSKind::Equal),
    (b">", CSSKind::Greater),
    (b"?", CSSKind::Question),
    (b"@", CSSKind::At),
    (b"[", CSSKind::BracketOpen),
    (b"]", CSSKind::BracketClose),
    (b"^", CSSKind::Caret),
    (b"{", CSSKind::BraceOpen),
    (b"|", CSSKind::Pipe),
    (b"}", CSSKind::BraceClose),
    (b"~", CSSKind::Tilde),
    (b"\\", CSSKind::Escape),
];

#[derive(Clone, Copy, Debug)]
struct Step {
    kind: CSSKind,
    reach: usize,
    unit: Option<usize>,
}

#[must_use]
pub fn classify(
    source: &[u8],
    tokens: &[Token],
    out: &mut Tokens,
    raw: &mut BoundedVec<CSSKind>,
) -> bool {
    assert!(u32::try_from(tokens.len()).is_ok());

    out.clear();
    raw.clear();

    let mut position = 0;

    while position < tokens.len() {
        let token = tokens[position];
        let end = token.end() as usize;
        let mut cursor = token.offset as usize;
        let mut limit = end;

        for _ in 0..=source.len() {
            if cursor >= limit {
                break;
            }

            let step = step_of(source, token.kind, cursor, end);

            if !push(source, out, raw, token.kind, step.kind, cursor, step.reach) {
                return false;
            }

            cursor = step.reach;

            if let Some(unit) = step.unit {
                if !push(source, out, raw, token.kind, CSSKind::Unit, cursor, unit) {
                    return false;
                }

                cursor = unit;
            }

            limit = limit.max(cursor);
        }

        position += 1;

        while position < tokens.len() && tokens[position].end() as usize <= cursor {
            position += 1;
        }
    }

    true
}

fn push(
    source: &[u8],
    out: &mut Tokens,
    raw: &mut BoundedVec<CSSKind>,
    coarse: TokenKind,
    kind: CSSKind,
    offset: usize,
    end: usize,
) -> bool {
    let start = offset.max(out.end_previous() as usize);
    let stop = end.min(source.len());

    if stop <= start {
        return true;
    }

    if raw.is_full() {
        return false;
    }

    if !out.push(source, coarse, start, stop - start) {
        return false;
    }

    raw.push(kind)
}

fn step_of(source: &[u8], coarse: TokenKind, offset: usize, end: usize) -> Step {
    assert!(offset < source.len());
    assert!(end <= source.len());

    match coarse {
        TokenKind::BlockEnd => plain(CSSKind::BraceClose, end),
        TokenKind::BlockStart => plain(CSSKind::BraceOpen, end),
        TokenKind::Comment => plain(CSSKind::Comment, end),
        TokenKind::Newline => plain(CSSKind::Newline, end),
        TokenKind::String => plain(CSSKind::Text, end),
        TokenKind::Identifier
        | TokenKind::Keyword(_)
        | TokenKind::Number
        | TokenKind::Punctuation(_) => byte_step(source, offset),
    }
}

const fn plain(kind: CSSKind, reach: usize) -> Step {
    Step {
        kind,
        reach,
        unit: None,
    }
}

fn byte_step(source: &[u8], offset: usize) -> Step {
    let byte = source[offset];

    if byte == b'\\' {
        return plain(CSSKind::Escape, escape_end(source, offset));
    }

    if byte == b'@'
        && source
            .get(offset + 1)
            .is_some_and(|next| is_name_start(*next))
    {
        return plain(CSSKind::At, offset + 1);
    }

    if byte.is_ascii_digit() || matches!(byte, b'+' | b'-' | b'.') {
        if let Some((kind, reach)) = number_end(source, offset) {
            return Step {
                kind,
                reach,
                unit: unit_end(source, reach),
            };
        }
    }

    if is_name_start(byte) {
        if let Some(reach) = identifier_end(source, offset) {
            return plain(CSSKind::Identifier, reach);
        }
    }

    operator_step(source, offset)
}

fn operator_step(source: &[u8], offset: usize) -> Step {
    match source.get(offset..offset + 2).unwrap_or_default() {
        b"::" => return plain(CSSKind::ColonColon, offset + 2),
        b"$=" => return plain(CSSKind::DollarEqual, offset + 2),
        b"*=" => return plain(CSSKind::StarEqual, offset + 2),
        b"^=" => return plain(CSSKind::CaretEqual, offset + 2),
        b"|=" => return plain(CSSKind::BarEqual, offset + 2),
        b"~=" => return plain(CSSKind::TildeEqual, offset + 2),
        _ => {}
    }

    match source.get(offset..offset + 1).unwrap_or_default() {
        b"!" => return plain(CSSKind::Bang, offset + 1),
        b"#" => return plain(CSSKind::Hash, offset + 1),
        b"$" => return plain(CSSKind::Dollar, offset + 1),
        b"%" => return plain(CSSKind::Percent, offset + 1),
        b"&" => return plain(CSSKind::Ampersand, offset + 1),
        b"(" => return plain(CSSKind::ParenOpen, offset + 1),
        b")" => return plain(CSSKind::ParenClose, offset + 1),
        b"*" => return plain(CSSKind::Star, offset + 1),
        b"+" => return plain(CSSKind::Plus, offset + 1),
        b"," => return plain(CSSKind::Comma, offset + 1),
        b"-" => return plain(CSSKind::Minus, offset + 1),
        b"." => return plain(CSSKind::Dot, offset + 1),
        b"/" => return plain(CSSKind::Slash, offset + 1),
        b":" => return plain(CSSKind::Colon, offset + 1),
        b";" => return plain(CSSKind::Semicolon, offset + 1),
        b"<" => return plain(CSSKind::Less, offset + 1),
        b"=" => return plain(CSSKind::Equal, offset + 1),
        b">" => return plain(CSSKind::Greater, offset + 1),
        b"?" => return plain(CSSKind::Question, offset + 1),
        b"@" => return plain(CSSKind::At, offset + 1),
        b"[" => return plain(CSSKind::BracketOpen, offset + 1),
        b"]" => return plain(CSSKind::BracketClose, offset + 1),
        b"^" => return plain(CSSKind::Caret, offset + 1),
        b"{" => return plain(CSSKind::BraceOpen, offset + 1),
        b"|" => return plain(CSSKind::Pipe, offset + 1),
        b"}" => return plain(CSSKind::BraceClose, offset + 1),
        b"~" => return plain(CSSKind::Tilde, offset + 1),
        b"\\" => return plain(CSSKind::Escape, offset + 1),
        _ => {}
    }

    plain(CSSKind::ErrorToken, offset + 1)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::language::Lexer as _;
    use crate::lex::CSS;

    #[test]
    fn every_operator_reaches_its_kind_through_the_match() {
        for entry in &OPERATORS {
            let step = operator_step(entry.0, 0);

            assert_eq!(step.kind, entry.1);
            assert_eq!(step.reach, entry.0.len());
        }
    }

    fn run(source: &[u8]) -> Vec<(CSSKind, String)> {
        let mut lexed = Tokens::reserve(4_096);
        let mut out = Tokens::reserve(4_096);
        let mut raw = BoundedVec::reserve(4_096);

        CSS.lex(source, &mut lexed);

        assert!(classify(source, lexed.as_slice(), &mut out, &mut raw));
        assert_eq!(raw.count() as usize, out.as_slice().len());

        out.as_slice()
            .iter()
            .zip(raw.iter())
            .map(|(token, kind)| {
                (
                    *kind,
                    String::from_utf8_lossy(token.text(source)).into_owned(),
                )
            })
            .filter(|(kind, _)| *kind != CSSKind::Newline)
            .collect()
    }

    #[test]
    fn an_at_rule_splits_its_mark_from_its_name() {
        assert_eq!(
            run(b"@media print {}"),
            vec![
                (CSSKind::At, "@".to_owned()),
                (CSSKind::Identifier, "media".to_owned()),
                (CSSKind::Identifier, "print".to_owned()),
                (CSSKind::BraceOpen, "{".to_owned()),
                (CSSKind::BraceClose, "}".to_owned()),
            ]
        );
    }

    #[test]
    fn a_dimension_splits_its_number_from_its_unit() {
        assert_eq!(
            run(b"a{b:10px}"),
            vec![
                (CSSKind::Identifier, "a".to_owned()),
                (CSSKind::BraceOpen, "{".to_owned()),
                (CSSKind::Identifier, "b".to_owned()),
                (CSSKind::Colon, ":".to_owned()),
                (CSSKind::Number, "10".to_owned()),
                (CSSKind::Unit, "px".to_owned()),
                (CSSKind::BraceClose, "}".to_owned()),
            ]
        );

        assert_eq!(
            run(b"a{b:100%}")[4..6],
            [
                (CSSKind::Number, "100".to_owned()),
                (CSSKind::Unit, "%".to_owned()),
            ]
        );

        assert_eq!(
            run(b"a{b:1.5em}")[4..6],
            [
                (CSSKind::Float, "1.5".to_owned()),
                (CSSKind::Unit, "em".to_owned()),
            ]
        );
    }

    #[test]
    fn a_signed_number_joins_its_sign_and_a_spaced_sign_does_not() {
        assert_eq!(
            run(b"a{b:-50%}")[4..6],
            [
                (CSSKind::Number, "-50".to_owned()),
                (CSSKind::Unit, "%".to_owned()),
            ]
        );

        assert_eq!(
            run(b"a{b:+1em}")[4..6],
            [
                (CSSKind::Number, "+1".to_owned()),
                (CSSKind::Unit, "em".to_owned()),
            ]
        );

        assert_eq!(
            run(b"a{b:1 - 2}")[4..7],
            [
                (CSSKind::Number, "1".to_owned()),
                (CSSKind::Minus, "-".to_owned()),
                (CSSKind::Number, "2".to_owned()),
            ]
        );
    }

    #[test]
    fn a_unit_a_plain_value_outruns_stays_an_identifier() {
        assert_eq!(
            run(b"a{b:12px/1.5}")[4..],
            [
                (CSSKind::Number, "12".to_owned()),
                (CSSKind::Identifier, "px".to_owned()),
                (CSSKind::Slash, "/".to_owned()),
                (CSSKind::Float, "1.5".to_owned()),
                (CSSKind::BraceClose, "}".to_owned()),
            ]
        );
    }

    #[test]
    fn the_selector_marks_carry_their_own_kinds() {
        assert_eq!(
            run(b"a::b .c#d[e~=f]{}")
                .into_iter()
                .map(|(kind, _)| kind)
                .collect::<Vec<CSSKind>>(),
            vec![
                CSSKind::Identifier,
                CSSKind::ColonColon,
                CSSKind::Identifier,
                CSSKind::Dot,
                CSSKind::Identifier,
                CSSKind::Hash,
                CSSKind::Identifier,
                CSSKind::BracketOpen,
                CSSKind::Identifier,
                CSSKind::TildeEqual,
                CSSKind::Identifier,
                CSSKind::BracketClose,
                CSSKind::BraceOpen,
                CSSKind::BraceClose,
            ]
        );
    }

    #[test]
    fn an_escape_outside_a_string_is_its_own_token() {
        assert_eq!(
            run(b".d\\:e{}")[0..4],
            [
                (CSSKind::Dot, ".".to_owned()),
                (CSSKind::Identifier, "d".to_owned()),
                (CSSKind::Escape, "\\:".to_owned()),
                (CSSKind::Identifier, "e".to_owned()),
            ]
        );
    }
}
