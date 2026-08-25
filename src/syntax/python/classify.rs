use crate::bounded::BoundedVec;
use crate::lex::python_token_at;
use crate::syntax::python::fstring;
use crate::syntax::python::kind::PythonKind;
use crate::token::{Token, TokenKind, Tokens};

#[cfg(test)]
const KEYWORDS: [(&[u8], PythonKind); 35] = [
    (b"False", PythonKind::FalseKeyword),
    (b"None", PythonKind::NoneKeyword),
    (b"True", PythonKind::TrueKeyword),
    (b"and", PythonKind::AndKeyword),
    (b"as", PythonKind::AsKeyword),
    (b"assert", PythonKind::AssertKeyword),
    (b"async", PythonKind::AsyncKeyword),
    (b"await", PythonKind::AwaitKeyword),
    (b"break", PythonKind::BreakKeyword),
    (b"class", PythonKind::ClassKeyword),
    (b"continue", PythonKind::ContinueKeyword),
    (b"def", PythonKind::DefKeyword),
    (b"del", PythonKind::DelKeyword),
    (b"elif", PythonKind::ElifKeyword),
    (b"else", PythonKind::ElseKeyword),
    (b"except", PythonKind::ExceptKeyword),
    (b"finally", PythonKind::FinallyKeyword),
    (b"for", PythonKind::ForKeyword),
    (b"from", PythonKind::FromKeyword),
    (b"global", PythonKind::GlobalKeyword),
    (b"if", PythonKind::IfKeyword),
    (b"import", PythonKind::ImportKeyword),
    (b"in", PythonKind::InKeyword),
    (b"is", PythonKind::IsKeyword),
    (b"lambda", PythonKind::LambdaKeyword),
    (b"nonlocal", PythonKind::NonlocalKeyword),
    (b"not", PythonKind::NotKeyword),
    (b"or", PythonKind::OrKeyword),
    (b"pass", PythonKind::PassKeyword),
    (b"raise", PythonKind::RaiseKeyword),
    (b"return", PythonKind::ReturnKeyword),
    (b"try", PythonKind::TryKeyword),
    (b"while", PythonKind::WhileKeyword),
    (b"with", PythonKind::WithKeyword),
    (b"yield", PythonKind::YieldKeyword),
];

#[cfg(test)]
const OPERATORS: [(&[u8], PythonKind); 41] = [
    (b"!", PythonKind::Bang),
    (b"!=", PythonKind::NotEqual),
    (b"%", PythonKind::Percent),
    (b"%=", PythonKind::PercentEqual),
    (b"&", PythonKind::Ampersand),
    (b"&=", PythonKind::AmpersandEqual),
    (b"(", PythonKind::ParenOpen),
    (b")", PythonKind::ParenClose),
    (b"*", PythonKind::Star),
    (b"*=", PythonKind::StarEqual),
    (b"**=", PythonKind::StarStarEqual),
    (b"+", PythonKind::Plus),
    (b"+=", PythonKind::PlusEqual),
    (b",", PythonKind::Comma),
    (b"-", PythonKind::Minus),
    (b"-=", PythonKind::MinusEqual),
    (b"->", PythonKind::Arrow),
    (b".", PythonKind::Dot),
    (b"/", PythonKind::Slash),
    (b"/=", PythonKind::SlashEqual),
    (b"//=", PythonKind::SlashSlashEqual),
    (b":", PythonKind::Colon),
    (b";", PythonKind::Semicolon),
    (b"<", PythonKind::Less),
    (b"<<=", PythonKind::LessLessEqual),
    (b"<=", PythonKind::LessEqual),
    (b"=", PythonKind::Equal),
    (b"==", PythonKind::EqualEqual),
    (b">", PythonKind::Greater),
    (b">=", PythonKind::GreaterEqual),
    (b">>=", PythonKind::GreaterGreaterEqual),
    (b"@", PythonKind::At),
    (b"[", PythonKind::BracketOpen),
    (b"]", PythonKind::BracketClose),
    (b"^", PythonKind::Caret),
    (b"^=", PythonKind::CaretEqual),
    (b"{", PythonKind::BraceOpen),
    (b"|", PythonKind::Bar),
    (b"|=", PythonKind::BarEqual),
    (b"}", PythonKind::BraceClose),
    (b"~", PythonKind::Tilde),
];

const PAIRS: [(&[u8], u8, PythonKind); 6] = [
    (b"*", b'*', PythonKind::StarStar),
    (b"/", b'/', PythonKind::SlashSlash),
    (b":", b'=', PythonKind::ColonEqual),
    (b"<", b'<', PythonKind::LessLess),
    (b"@", b'=', PythonKind::AtEqual),
    (b">", b'>', PythonKind::GreaterGreater),
];

#[must_use]
pub fn classify(
    source: &[u8],
    tokens: &[Token],
    out: &mut Tokens,
    raw: &mut BoundedVec<PythonKind>,
) -> bool {
    assert!(u32::try_from(tokens.len()).is_ok());

    out.clear();
    raw.clear();

    let mut position = 0;

    while position < tokens.len() {
        let token = tokens[position];
        let offset = token.offset as usize;
        let end = token.end() as usize;

        if let Some(kind) = structural_of(token.kind) {
            if !push(source, out, raw, token.kind, kind, offset, end) {
                return false;
            }

            position += 1;

            continue;
        }

        if token.kind == TokenKind::String && fstring::is_format(token.text(source)) {
            if !fstring::expand(source, token.span(), out, raw) {
                return false;
            }

            position += 1;

            continue;
        }

        let (kind, stop) = kind_of(source, token.kind, offset, end);

        if !push(source, out, raw, token.kind, kind, offset, stop) {
            return false;
        }

        position += 1;

        while position < tokens.len()
            && structural_of(tokens[position].kind).is_none()
            && tokens[position].end() as usize <= stop
        {
            position += 1;
        }
    }

    true
}

const fn structural_of(kind: TokenKind) -> Option<PythonKind> {
    match kind {
        TokenKind::BlockEnd => Some(PythonKind::Dedent),
        TokenKind::BlockStart => Some(PythonKind::Indent),
        TokenKind::Comment => Some(PythonKind::Comment),
        TokenKind::Newline => Some(PythonKind::Newline),
        TokenKind::Identifier
        | TokenKind::Keyword(_)
        | TokenKind::Number
        | TokenKind::Punctuation(_)
        | TokenKind::String => None,
    }
}

fn push(
    source: &[u8],
    out: &mut Tokens,
    raw: &mut BoundedVec<PythonKind>,
    coarse: TokenKind,
    kind: PythonKind,
    offset: usize,
    end: usize,
) -> bool {
    let start = offset.max(out.end_previous() as usize);
    let stop = end.min(source.len());

    if stop <= start
        && !matches!(
            coarse,
            TokenKind::BlockEnd | TokenKind::BlockStart | TokenKind::Newline
        )
    {
        return true;
    }

    if raw.is_full() {
        return false;
    }

    if !out.push(source, coarse, start, stop.saturating_sub(start)) {
        return false;
    }

    raw.push(kind)
}

pub(crate) fn kind_of(
    source: &[u8],
    coarse: TokenKind,
    offset: usize,
    end: usize,
) -> (PythonKind, usize) {
    let bytes = &source[offset..end];

    match coarse {
        TokenKind::BlockEnd => (PythonKind::Dedent, end),
        TokenKind::BlockStart => (PythonKind::Indent, end),
        TokenKind::Comment => (PythonKind::Comment, end),
        TokenKind::Newline => (PythonKind::Newline, end),
        TokenKind::Number => number_join(source, end, number_of(bytes)),
        TokenKind::String => (string_of(bytes), end),
        TokenKind::Identifier | TokenKind::Keyword(_) | TokenKind::Punctuation(_) => {
            if is_word(bytes) {
                return (word_of(bytes), end);
            }

            operator_join(source, bytes, end)
        }
    }
}

fn is_word(bytes: &[u8]) -> bool {
    bytes
        .first()
        .is_some_and(|byte| byte.is_ascii_alphabetic() || *byte == b'_')
}

fn number_join(source: &[u8], end: usize, kind: PythonKind) -> (PythonKind, usize) {
    if source.get(end) != Some(&b'.') {
        return (kind, end);
    }

    let after = end + 1;

    let Some(byte) = source.get(after) else {
        return (PythonKind::NumberFloat, after);
    };

    if !byte.is_ascii_alphabetic() {
        return (PythonKind::NumberFloat, after);
    }

    let (_, stop) = python_token_at(source, after);

    match byte {
        b'j' | b'J' => (PythonKind::NumberComplex, stop),
        b'e' | b'E' => (PythonKind::NumberFloat, stop),
        _ => (PythonKind::NumberFloat, after),
    }
}

fn operator_join(source: &[u8], bytes: &[u8], end: usize) -> (PythonKind, usize) {
    if bytes == b"." {
        if source.get(end) == Some(&b'.') && source.get(end + 1) == Some(&b'.') {
            return (PythonKind::Ellipsis, end + 2);
        }

        if source.get(end).is_some_and(u8::is_ascii_digit) {
            let (_, stop) = python_token_at(source, end);

            return (PythonKind::NumberFloat, stop);
        }

        return (PythonKind::Dot, end);
    }

    let found = PAIRS
        .iter()
        .find(|pair| pair.0 == bytes && source.get(end) == Some(&pair.1));

    if let Some(pair) = found {
        return (pair.2, end + 1);
    }

    (operator_of(bytes), end)
}

fn number_of(bytes: &[u8]) -> PythonKind {
    let radix = bytes.get(..2).unwrap_or_default();

    if radix.eq_ignore_ascii_case(b"0x") {
        return PythonKind::NumberHexadecimal;
    }

    if radix.eq_ignore_ascii_case(b"0o") {
        return PythonKind::NumberOctal;
    }

    if radix.eq_ignore_ascii_case(b"0b") {
        return PythonKind::NumberBinary;
    }

    if bytes
        .last()
        .is_some_and(|byte| byte.eq_ignore_ascii_case(&b'j'))
    {
        return PythonKind::NumberComplex;
    }

    if bytes
        .iter()
        .any(|byte| *byte == b'.' || byte.eq_ignore_ascii_case(&b'e'))
    {
        return PythonKind::NumberFloat;
    }

    PythonKind::NumberInteger
}

fn operator_of(bytes: &[u8]) -> PythonKind {
    match bytes {
        b"!" => PythonKind::Bang,
        b"!=" => PythonKind::NotEqual,
        b"%" => PythonKind::Percent,
        b"%=" => PythonKind::PercentEqual,
        b"&" => PythonKind::Ampersand,
        b"&=" => PythonKind::AmpersandEqual,
        b"(" => PythonKind::ParenOpen,
        b")" => PythonKind::ParenClose,
        b"*" => PythonKind::Star,
        b"*=" => PythonKind::StarEqual,
        b"**=" => PythonKind::StarStarEqual,
        b"+" => PythonKind::Plus,
        b"+=" => PythonKind::PlusEqual,
        b"," => PythonKind::Comma,
        b"-" => PythonKind::Minus,
        b"-=" => PythonKind::MinusEqual,
        b"->" => PythonKind::Arrow,
        b"." => PythonKind::Dot,
        b"/" => PythonKind::Slash,
        b"/=" => PythonKind::SlashEqual,
        b"//=" => PythonKind::SlashSlashEqual,
        b":" => PythonKind::Colon,
        b";" => PythonKind::Semicolon,
        b"<" => PythonKind::Less,
        b"<<=" => PythonKind::LessLessEqual,
        b"<=" => PythonKind::LessEqual,
        b"=" => PythonKind::Equal,
        b"==" => PythonKind::EqualEqual,
        b">" => PythonKind::Greater,
        b">=" => PythonKind::GreaterEqual,
        b">>=" => PythonKind::GreaterGreaterEqual,
        b"@" => PythonKind::At,
        b"[" => PythonKind::BracketOpen,
        b"]" => PythonKind::BracketClose,
        b"^" => PythonKind::Caret,
        b"^=" => PythonKind::CaretEqual,
        b"{" => PythonKind::BraceOpen,
        b"|" => PythonKind::Bar,
        b"|=" => PythonKind::BarEqual,
        b"}" => PythonKind::BraceClose,
        b"~" => PythonKind::Tilde,
        _ => PythonKind::ErrorToken,
    }
}

fn string_of(bytes: &[u8]) -> PythonKind {
    let prefix_end = bytes
        .iter()
        .position(|byte| matches!(*byte, b'"' | b'\''))
        .unwrap_or(bytes.len());

    let prefix = &bytes[..prefix_end];

    if prefix.iter().any(|byte| byte.eq_ignore_ascii_case(&b'b')) {
        return PythonKind::StringBytes;
    }

    if prefix.iter().any(|byte| byte.eq_ignore_ascii_case(&b'f')) {
        return PythonKind::StringFormat;
    }

    PythonKind::StringPlain
}

fn word_of(bytes: &[u8]) -> PythonKind {
    match bytes {
        b"False" => PythonKind::FalseKeyword,
        b"None" => PythonKind::NoneKeyword,
        b"True" => PythonKind::TrueKeyword,
        b"and" => PythonKind::AndKeyword,
        b"as" => PythonKind::AsKeyword,
        b"assert" => PythonKind::AssertKeyword,
        b"async" => PythonKind::AsyncKeyword,
        b"await" => PythonKind::AwaitKeyword,
        b"break" => PythonKind::BreakKeyword,
        b"class" => PythonKind::ClassKeyword,
        b"continue" => PythonKind::ContinueKeyword,
        b"def" => PythonKind::DefKeyword,
        b"del" => PythonKind::DelKeyword,
        b"elif" => PythonKind::ElifKeyword,
        b"else" => PythonKind::ElseKeyword,
        b"except" => PythonKind::ExceptKeyword,
        b"finally" => PythonKind::FinallyKeyword,
        b"for" => PythonKind::ForKeyword,
        b"from" => PythonKind::FromKeyword,
        b"global" => PythonKind::GlobalKeyword,
        b"if" => PythonKind::IfKeyword,
        b"import" => PythonKind::ImportKeyword,
        b"in" => PythonKind::InKeyword,
        b"is" => PythonKind::IsKeyword,
        b"lambda" => PythonKind::LambdaKeyword,
        b"nonlocal" => PythonKind::NonlocalKeyword,
        b"not" => PythonKind::NotKeyword,
        b"or" => PythonKind::OrKeyword,
        b"pass" => PythonKind::PassKeyword,
        b"raise" => PythonKind::RaiseKeyword,
        b"return" => PythonKind::ReturnKeyword,
        b"try" => PythonKind::TryKeyword,
        b"while" => PythonKind::WhileKeyword,
        b"with" => PythonKind::WithKeyword,
        b"yield" => PythonKind::YieldKeyword,
        _ => PythonKind::Identifier,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_keyword_reaches_its_kind_through_the_match() {
        for entry in &KEYWORDS {
            assert_eq!(word_of(entry.0), entry.1);
        }
    }

    #[test]
    fn every_operator_reaches_its_kind_through_the_match() {
        for entry in &OPERATORS {
            assert_eq!(operator_of(entry.0), entry.1);
        }
    }
}
