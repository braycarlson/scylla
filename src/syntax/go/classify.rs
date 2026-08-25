use crate::bounded::BoundedVec;
use crate::syntax::go::kind::GoKind;
use crate::token::{Token, TokenKind, Tokens};

#[cfg(test)]
const KEYWORDS: [(&[u8], GoKind); 25] = [
    (b"break", GoKind::BreakKeyword),
    (b"case", GoKind::CaseKeyword),
    (b"chan", GoKind::ChanKeyword),
    (b"const", GoKind::ConstKeyword),
    (b"continue", GoKind::ContinueKeyword),
    (b"default", GoKind::DefaultKeyword),
    (b"defer", GoKind::DeferKeyword),
    (b"else", GoKind::ElseKeyword),
    (b"fallthrough", GoKind::FallthroughKeyword),
    (b"for", GoKind::ForKeyword),
    (b"func", GoKind::FuncKeyword),
    (b"go", GoKind::GoKeyword),
    (b"goto", GoKind::GotoKeyword),
    (b"if", GoKind::IfKeyword),
    (b"import", GoKind::ImportKeyword),
    (b"interface", GoKind::InterfaceKeyword),
    (b"map", GoKind::MapKeyword),
    (b"package", GoKind::PackageKeyword),
    (b"range", GoKind::RangeKeyword),
    (b"return", GoKind::ReturnKeyword),
    (b"select", GoKind::SelectKeyword),
    (b"struct", GoKind::StructKeyword),
    (b"switch", GoKind::SwitchKeyword),
    (b"type", GoKind::TypeKeyword),
    (b"var", GoKind::VarKeyword),
];

#[cfg(test)]
const OPERATORS: [(&[u8], GoKind); 47] = [
    (b"&^=", GoKind::AmpersandCaretEqual),
    (b"<<=", GoKind::LessLessEqual),
    (b">>=", GoKind::GreaterGreaterEqual),
    (b"...", GoKind::DotDotDot),
    (b"!=", GoKind::BangEqual),
    (b"%=", GoKind::PercentEqual),
    (b"&&", GoKind::AmpersandAmpersand),
    (b"&=", GoKind::AmpersandEqual),
    (b"&^", GoKind::AmpersandCaret),
    (b"*=", GoKind::StarEqual),
    (b"++", GoKind::PlusPlus),
    (b"+=", GoKind::PlusEqual),
    (b"--", GoKind::MinusMinus),
    (b"-=", GoKind::MinusEqual),
    (b"/=", GoKind::SlashEqual),
    (b":=", GoKind::ColonEqual),
    (b"<-", GoKind::Arrow),
    (b"<<", GoKind::LessLess),
    (b"<=", GoKind::LessEqual),
    (b"==", GoKind::EqualEqual),
    (b">=", GoKind::GreaterEqual),
    (b">>", GoKind::GreaterGreater),
    (b"^=", GoKind::CaretEqual),
    (b"|=", GoKind::BarEqual),
    (b"||", GoKind::BarBar),
    (b"!", GoKind::Bang),
    (b"%", GoKind::Percent),
    (b"&", GoKind::Ampersand),
    (b"(", GoKind::ParenOpen),
    (b")", GoKind::ParenClose),
    (b"*", GoKind::Star),
    (b"+", GoKind::Plus),
    (b",", GoKind::Comma),
    (b"-", GoKind::Minus),
    (b".", GoKind::Dot),
    (b"/", GoKind::Slash),
    (b":", GoKind::Colon),
    (b";", GoKind::Semicolon),
    (b"<", GoKind::Less),
    (b"=", GoKind::Equal),
    (b">", GoKind::Greater),
    (b"[", GoKind::BracketOpen),
    (b"]", GoKind::BracketClose),
    (b"^", GoKind::Caret),
    (b"{", GoKind::BraceOpen),
    (b"|", GoKind::Bar),
    (b"~", GoKind::Tilde),
];

#[must_use]
pub fn classify(
    source: &[u8],
    tokens: &[Token],
    out: &mut Tokens,
    raw: &mut BoundedVec<GoKind>,
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
            if !push(source, out, raw, token.kind, kind, offset, end.max(offset)) {
                return false;
            }

            position += 1;

            continue;
        }

        let mut cursor = offset;
        let mut stop = offset;

        for _ in 0..=(end - offset) {
            let (kind, reach) = kind_of(source, token.kind, cursor, end);

            if !push(source, out, raw, token.kind, kind, cursor, reach) {
                return false;
            }

            stop = reach;

            if reach >= end {
                break;
            }

            cursor = reach;
        }

        position += 1;

        while position < tokens.len() && tokens[position].end() as usize <= stop {
            position += 1;
        }
    }

    true
}

const fn structural_of(kind: TokenKind) -> Option<GoKind> {
    match kind {
        TokenKind::BlockEnd => Some(GoKind::BraceClose),
        TokenKind::BlockStart => Some(GoKind::BraceOpen),
        TokenKind::Comment => Some(GoKind::Comment),
        TokenKind::Newline => Some(GoKind::Newline),
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
    raw: &mut BoundedVec<GoKind>,
    coarse: TokenKind,
    kind: GoKind,
    offset: usize,
    end: usize,
) -> bool {
    let start = offset.max(out.end_previous() as usize);
    let stop = end.min(source.len());

    if stop <= start && coarse != TokenKind::Newline {
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

fn kind_of(source: &[u8], coarse: TokenKind, offset: usize, end: usize) -> (GoKind, usize) {
    let bytes = &source[offset..end];

    match coarse {
        TokenKind::BlockEnd => (GoKind::BraceClose, end),
        TokenKind::BlockStart => (GoKind::BraceOpen, end),
        TokenKind::Comment => (GoKind::Comment, end),
        TokenKind::Newline => (GoKind::Newline, end),
        TokenKind::Number => (GoKind::Number, number_end(source, end)),
        TokenKind::String => (string_of(bytes), end),
        TokenKind::Identifier | TokenKind::Keyword(_) | TokenKind::Punctuation(_) => {
            if is_word(bytes) {
                return (word_of(bytes), end);
            }

            operator_join(source, offset)
        }
    }
}

fn number_end(source: &[u8], end: usize) -> usize {
    if source.get(end) != Some(&b'.') {
        return end;
    }

    let after = source.get(end + 1).copied();

    if after.is_some_and(|byte| byte.is_ascii_alphabetic() || byte == b'.' || byte == b'_') {
        return end;
    }

    end + 1
}

fn is_word(bytes: &[u8]) -> bool {
    bytes
        .first()
        .is_some_and(|byte| byte.is_ascii_alphabetic() || *byte == b'_' || *byte >= 0x80)
}

fn operator_join(source: &[u8], offset: usize) -> (GoKind, usize) {
    if source.get(offset) == Some(&b'.') && source.get(offset + 1).is_some_and(u8::is_ascii_digit) {
        let mut end = offset + 1;

        while source
            .get(end)
            .is_some_and(|byte| byte.is_ascii_alphanumeric() || *byte == b'_' || *byte == b'.')
        {
            end += 1;
        }

        return (GoKind::Number, end);
    }

    if let Some(kind) = operator_three(source, offset) {
        return (kind, offset + 3);
    }

    if let Some(kind) = operator_two(source, offset) {
        return (kind, offset + 2);
    }

    (operator_one(source, offset), offset + 1)
}

fn operator_three(source: &[u8], offset: usize) -> Option<GoKind> {
    let kind = match source.get(offset..offset + 3).unwrap_or_default() {
        b"&^=" => GoKind::AmpersandCaretEqual,
        b"<<=" => GoKind::LessLessEqual,
        b">>=" => GoKind::GreaterGreaterEqual,
        b"..." => GoKind::DotDotDot,
        _ => return None,
    };

    Some(kind)
}

fn operator_two(source: &[u8], offset: usize) -> Option<GoKind> {
    let kind = match source.get(offset..offset + 2).unwrap_or_default() {
        b"!=" => GoKind::BangEqual,
        b"%=" => GoKind::PercentEqual,
        b"&&" => GoKind::AmpersandAmpersand,
        b"&=" => GoKind::AmpersandEqual,
        b"&^" => GoKind::AmpersandCaret,
        b"*=" => GoKind::StarEqual,
        b"++" => GoKind::PlusPlus,
        b"+=" => GoKind::PlusEqual,
        b"--" => GoKind::MinusMinus,
        b"-=" => GoKind::MinusEqual,
        b"/=" => GoKind::SlashEqual,
        b":=" => GoKind::ColonEqual,
        b"<-" => GoKind::Arrow,
        b"<<" => GoKind::LessLess,
        b"<=" => GoKind::LessEqual,
        b"==" => GoKind::EqualEqual,
        b">=" => GoKind::GreaterEqual,
        b">>" => GoKind::GreaterGreater,
        b"^=" => GoKind::CaretEqual,
        b"|=" => GoKind::BarEqual,
        b"||" => GoKind::BarBar,
        _ => return None,
    };

    Some(kind)
}

fn operator_one(source: &[u8], offset: usize) -> GoKind {
    match source.get(offset).copied().unwrap_or(0) {
        b'!' => GoKind::Bang,
        b'%' => GoKind::Percent,
        b'&' => GoKind::Ampersand,
        b'(' => GoKind::ParenOpen,
        b')' => GoKind::ParenClose,
        b'*' => GoKind::Star,
        b'+' => GoKind::Plus,
        b',' => GoKind::Comma,
        b'-' => GoKind::Minus,
        b'.' => GoKind::Dot,
        b'/' => GoKind::Slash,
        b':' => GoKind::Colon,
        b';' => GoKind::Semicolon,
        b'<' => GoKind::Less,
        b'=' => GoKind::Equal,
        b'>' => GoKind::Greater,
        b'[' => GoKind::BracketOpen,
        b']' => GoKind::BracketClose,
        b'^' => GoKind::Caret,
        b'{' => GoKind::BraceOpen,
        b'|' => GoKind::Bar,
        b'}' => GoKind::BraceClose,
        b'~' => GoKind::Tilde,
        _ => GoKind::ErrorToken,
    }
}

fn string_of(bytes: &[u8]) -> GoKind {
    if bytes.first() == Some(&b'\'') {
        return GoKind::RuneLiteral;
    }

    GoKind::StringLiteral
}

fn word_of(bytes: &[u8]) -> GoKind {
    match bytes {
        b"break" => GoKind::BreakKeyword,
        b"case" => GoKind::CaseKeyword,
        b"chan" => GoKind::ChanKeyword,
        b"const" => GoKind::ConstKeyword,
        b"continue" => GoKind::ContinueKeyword,
        b"default" => GoKind::DefaultKeyword,
        b"defer" => GoKind::DeferKeyword,
        b"else" => GoKind::ElseKeyword,
        b"fallthrough" => GoKind::FallthroughKeyword,
        b"for" => GoKind::ForKeyword,
        b"func" => GoKind::FuncKeyword,
        b"go" => GoKind::GoKeyword,
        b"goto" => GoKind::GotoKeyword,
        b"if" => GoKind::IfKeyword,
        b"import" => GoKind::ImportKeyword,
        b"interface" => GoKind::InterfaceKeyword,
        b"map" => GoKind::MapKeyword,
        b"package" => GoKind::PackageKeyword,
        b"range" => GoKind::RangeKeyword,
        b"return" => GoKind::ReturnKeyword,
        b"select" => GoKind::SelectKeyword,
        b"struct" => GoKind::StructKeyword,
        b"switch" => GoKind::SwitchKeyword,
        b"type" => GoKind::TypeKeyword,
        b"var" => GoKind::VarKeyword,
        _ => GoKind::Identifier,
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
            assert_eq!(operator_join(entry.0, 0), (entry.1, entry.0.len()));
        }
    }
}
