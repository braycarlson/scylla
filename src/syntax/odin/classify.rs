use crate::bounded::{BoundedVec, count_of};
use crate::syntax::odin::kind::OdinKind;
use crate::token::{Token, TokenKind, Tokens, operator_limit_of};

#[cfg(test)]
const KEYWORDS: [(&[u8], OdinKind); 42] = [
    (b"asm", OdinKind::AsmKeyword),
    (b"auto_cast", OdinKind::AutoCastKeyword),
    (b"bit_field", OdinKind::BitFieldKeyword),
    (b"bit_set", OdinKind::BitSetKeyword),
    (b"break", OdinKind::BreakKeyword),
    (b"case", OdinKind::CaseKeyword),
    (b"cast", OdinKind::CastKeyword),
    (b"context", OdinKind::ContextKeyword),
    (b"continue", OdinKind::ContinueKeyword),
    (b"defer", OdinKind::DeferKeyword),
    (b"distinct", OdinKind::DistinctKeyword),
    (b"do", OdinKind::DoKeyword),
    (b"dynamic", OdinKind::DynamicKeyword),
    (b"else", OdinKind::ElseKeyword),
    (b"enum", OdinKind::EnumKeyword),
    (b"fallthrough", OdinKind::FallthroughKeyword),
    (b"false", OdinKind::FalseKeyword),
    (b"for", OdinKind::ForKeyword),
    (b"foreign", OdinKind::ForeignKeyword),
    (b"if", OdinKind::IfKeyword),
    (b"import", OdinKind::ImportKeyword),
    (b"in", OdinKind::InKeyword),
    (b"map", OdinKind::MapKeyword),
    (b"matrix", OdinKind::MatrixKeyword),
    (b"nil", OdinKind::NilKeyword),
    (b"not_in", OdinKind::NotInKeyword),
    (b"or_break", OdinKind::OrBreakKeyword),
    (b"or_continue", OdinKind::OrContinueKeyword),
    (b"or_else", OdinKind::OrElseKeyword),
    (b"or_return", OdinKind::OrReturnKeyword),
    (b"package", OdinKind::PackageKeyword),
    (b"proc", OdinKind::ProcKeyword),
    (b"return", OdinKind::ReturnKeyword),
    (b"struct", OdinKind::StructKeyword),
    (b"switch", OdinKind::SwitchKeyword),
    (b"transmute", OdinKind::TransmuteKeyword),
    (b"true", OdinKind::TrueKeyword),
    (b"typeid", OdinKind::TypeidKeyword),
    (b"union", OdinKind::UnionKeyword),
    (b"using", OdinKind::UsingKeyword),
    (b"when", OdinKind::WhenKeyword),
    (b"where", OdinKind::WhereKeyword),
];

#[cfg(test)]
const OPERATORS: [(&[u8], OdinKind); 59] = [
    (b"%%=", OdinKind::PercentPercentEqual),
    (b"&&=", OdinKind::AmpersandAmpersandEqual),
    (b"&~=", OdinKind::AmpersandTildeEqual),
    (b"---", OdinKind::MinusMinusMinus),
    (b"...", OdinKind::DotDotDot),
    (b"..<", OdinKind::DotDotLess),
    (b"..=", OdinKind::DotDotEqual),
    (b"<<=", OdinKind::LessLessEqual),
    (b">>=", OdinKind::GreaterGreaterEqual),
    (b"||=", OdinKind::BarBarEqual),
    (b"!=", OdinKind::BangEqual),
    (b"%%", OdinKind::PercentPercent),
    (b"%=", OdinKind::PercentEqual),
    (b"&&", OdinKind::AmpersandAmpersand),
    (b"&=", OdinKind::AmpersandEqual),
    (b"&~", OdinKind::AmpersandTilde),
    (b"*=", OdinKind::StarEqual),
    (b"+=", OdinKind::PlusEqual),
    (b"->", OdinKind::Arrow),
    (b"-=", OdinKind::MinusEqual),
    (b"..", OdinKind::DotDot),
    (b"/=", OdinKind::SlashEqual),
    (b"::", OdinKind::ColonColon),
    (b":=", OdinKind::ColonEqual),
    (b"<<", OdinKind::LessLess),
    (b"<=", OdinKind::LessEqual),
    (b"==", OdinKind::EqualEqual),
    (b"=>", OdinKind::FatArrow),
    (b">=", OdinKind::GreaterEqual),
    (b">>", OdinKind::GreaterGreater),
    (b"|=", OdinKind::BarEqual),
    (b"||", OdinKind::BarBar),
    (b"~=", OdinKind::TildeEqual),
    (b"!", OdinKind::Bang),
    (b"%", OdinKind::Percent),
    (b"&", OdinKind::Ampersand),
    (b"(", OdinKind::ParenOpen),
    (b")", OdinKind::ParenClose),
    (b"*", OdinKind::Star),
    (b"+", OdinKind::Plus),
    (b",", OdinKind::Comma),
    (b"-", OdinKind::Minus),
    (b".", OdinKind::Dot),
    (b"/", OdinKind::Slash),
    (b":", OdinKind::Colon),
    (b";", OdinKind::Semicolon),
    (b"<", OdinKind::Less),
    (b"=", OdinKind::Equal),
    (b">", OdinKind::Greater),
    (b"?", OdinKind::Question),
    (b"@", OdinKind::At),
    (b"[", OdinKind::BracketOpen),
    (b"]", OdinKind::BracketClose),
    (b"^", OdinKind::Caret),
    (b"{", OdinKind::BraceOpen),
    (b"|", OdinKind::Bar),
    (b"}", OdinKind::BraceClose),
    (b"~", OdinKind::Tilde),
    (b"$", OdinKind::Dollar),
];

#[must_use]
pub fn classify(
    source: &[u8],
    tokens: &[Token],
    out: &mut Tokens,
    raw: &mut BoundedVec<OdinKind>,
) -> bool {
    assert!(u32::try_from(tokens.len()).is_ok());

    out.clear();
    raw.clear();

    let mut position = 0;

    while position < tokens.len() {
        let token = tokens[position];
        let offset = token.offset as usize;
        let end = token.end() as usize;
        let limit = operator_limit_of(tokens, position, count_of(end));
        let mut cursor = offset.max(out.end_previous() as usize);
        let mut stop = cursor;

        for _ in 0..=(end - offset) {
            let (kind, reach) = kind_of(&source[..limit as usize], token.kind, cursor, end);

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

fn push(
    source: &[u8],
    out: &mut Tokens,
    raw: &mut BoundedVec<OdinKind>,
    coarse: TokenKind,
    kind: OdinKind,
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

fn kind_of(source: &[u8], coarse: TokenKind, offset: usize, end: usize) -> (OdinKind, usize) {
    let bytes = &source[offset..end];

    if bytes.first() == Some(&b'@') && bytes.len() > 1 {
        return (OdinKind::At, offset + 1);
    }

    match coarse {
        TokenKind::BlockEnd => (OdinKind::BraceClose, end),
        TokenKind::BlockStart => (OdinKind::BraceOpen, end),
        TokenKind::Comment => (comment_of(bytes), end),
        TokenKind::Newline => (OdinKind::Newline, end),
        TokenKind::Number => (number_of(bytes), end),
        TokenKind::String => (string_of(bytes), end),
        TokenKind::Identifier | TokenKind::Keyword(_) | TokenKind::Punctuation(_) => {
            if is_word(bytes) {
                return (word_of(bytes), end);
            }

            operator_join(source, offset)
        }
    }
}

fn is_word(bytes: &[u8]) -> bool {
    let Some(byte) = bytes.first() else {
        return false;
    };

    if matches!(*byte, b'#' | b'@') {
        return bytes.len() > 1;
    }

    byte.is_ascii_alphabetic() || *byte == b'_' || *byte >= 0x80
}

fn operator_join(source: &[u8], offset: usize) -> (OdinKind, usize) {
    if let Some(kind) = operator_three(source, offset) {
        return (kind, offset + 3);
    }

    if let Some(kind) = operator_two(source, offset) {
        return (kind, offset + 2);
    }

    (operator_one(source, offset), offset + 1)
}

fn operator_three(source: &[u8], offset: usize) -> Option<OdinKind> {
    let kind = match source.get(offset..offset + 3).unwrap_or_default() {
        b"%%=" => OdinKind::PercentPercentEqual,
        b"&&=" => OdinKind::AmpersandAmpersandEqual,
        b"&~=" => OdinKind::AmpersandTildeEqual,
        b"---" => OdinKind::MinusMinusMinus,
        b"..." => OdinKind::DotDotDot,
        b"..<" => OdinKind::DotDotLess,
        b"..=" => OdinKind::DotDotEqual,
        b"<<=" => OdinKind::LessLessEqual,
        b">>=" => OdinKind::GreaterGreaterEqual,
        b"||=" => OdinKind::BarBarEqual,
        _ => return None,
    };

    Some(kind)
}

fn operator_two(source: &[u8], offset: usize) -> Option<OdinKind> {
    let kind = match source.get(offset..offset + 2).unwrap_or_default() {
        b"!=" => OdinKind::BangEqual,
        b"%%" => OdinKind::PercentPercent,
        b"%=" => OdinKind::PercentEqual,
        b"&&" => OdinKind::AmpersandAmpersand,
        b"&=" => OdinKind::AmpersandEqual,
        b"&~" => OdinKind::AmpersandTilde,
        b"*=" => OdinKind::StarEqual,
        b"+=" => OdinKind::PlusEqual,
        b"->" => OdinKind::Arrow,
        b"-=" => OdinKind::MinusEqual,
        b".." => OdinKind::DotDot,
        b"/=" => OdinKind::SlashEqual,
        b"::" => OdinKind::ColonColon,
        b":=" => OdinKind::ColonEqual,
        b"<<" => OdinKind::LessLess,
        b"<=" => OdinKind::LessEqual,
        b"==" => OdinKind::EqualEqual,
        b"=>" => OdinKind::FatArrow,
        b">=" => OdinKind::GreaterEqual,
        b">>" => OdinKind::GreaterGreater,
        b"|=" => OdinKind::BarEqual,
        b"||" => OdinKind::BarBar,
        b"~=" => OdinKind::TildeEqual,
        _ => return None,
    };

    Some(kind)
}

fn operator_one(source: &[u8], offset: usize) -> OdinKind {
    match source.get(offset).copied().unwrap_or(0) {
        b'!' => OdinKind::Bang,
        b'$' => OdinKind::Dollar,
        b'%' => OdinKind::Percent,
        b'&' => OdinKind::Ampersand,
        b'(' => OdinKind::ParenOpen,
        b')' => OdinKind::ParenClose,
        b'*' => OdinKind::Star,
        b'+' => OdinKind::Plus,
        b',' => OdinKind::Comma,
        b'-' => OdinKind::Minus,
        b'.' => OdinKind::Dot,
        b'/' => OdinKind::Slash,
        b':' => OdinKind::Colon,
        b';' => OdinKind::Semicolon,
        b'<' => OdinKind::Less,
        b'=' => OdinKind::Equal,
        b'>' => OdinKind::Greater,
        b'?' => OdinKind::Question,
        b'@' => OdinKind::At,
        b'[' => OdinKind::BracketOpen,
        b']' => OdinKind::BracketClose,
        b'^' => OdinKind::Caret,
        b'{' => OdinKind::BraceOpen,
        b'|' => OdinKind::Bar,
        b'}' => OdinKind::BraceClose,
        b'~' => OdinKind::Tilde,
        _ => OdinKind::ErrorToken,
    }
}

fn comment_of(bytes: &[u8]) -> OdinKind {
    if bytes.starts_with(b"/*") {
        return OdinKind::CommentBlock;
    }

    if bytes.starts_with(b"//") {
        return OdinKind::Comment;
    }

    OdinKind::CommentTag
}

fn number_of(bytes: &[u8]) -> OdinKind {
    if bytes.starts_with(b"0h") || bytes.starts_with(b"0H") {
        return OdinKind::Float;
    }

    if bytes.starts_with(b"0x") || bytes.starts_with(b"0X") || bytes.starts_with(b"0b") {
        return OdinKind::Number;
    }

    if bytes.starts_with(b"0o") || bytes.starts_with(b"0d") || bytes.starts_with(b"0z") {
        return OdinKind::Number;
    }

    if bytes.iter().any(|byte| matches!(*byte, b'.' | b'e' | b'E')) {
        return OdinKind::Float;
    }

    OdinKind::Number
}

fn string_of(bytes: &[u8]) -> OdinKind {
    match bytes.first() {
        Some(b'\'') => OdinKind::Character,
        _ => OdinKind::Text,
    }
}

fn word_of(bytes: &[u8]) -> OdinKind {
    if bytes.first() == Some(&b'#') {
        return OdinKind::Directive;
    }

    match bytes {
        b"asm" => OdinKind::AsmKeyword,
        b"auto_cast" => OdinKind::AutoCastKeyword,
        b"bit_field" => OdinKind::BitFieldKeyword,
        b"bit_set" => OdinKind::BitSetKeyword,
        b"break" => OdinKind::BreakKeyword,
        b"case" => OdinKind::CaseKeyword,
        b"cast" => OdinKind::CastKeyword,
        b"context" => OdinKind::ContextKeyword,
        b"continue" => OdinKind::ContinueKeyword,
        b"defer" => OdinKind::DeferKeyword,
        b"distinct" => OdinKind::DistinctKeyword,
        b"do" => OdinKind::DoKeyword,
        b"dynamic" => OdinKind::DynamicKeyword,
        b"else" => OdinKind::ElseKeyword,
        b"enum" => OdinKind::EnumKeyword,
        b"fallthrough" => OdinKind::FallthroughKeyword,
        b"false" => OdinKind::FalseKeyword,
        b"for" => OdinKind::ForKeyword,
        b"foreign" => OdinKind::ForeignKeyword,
        b"if" => OdinKind::IfKeyword,
        b"import" => OdinKind::ImportKeyword,
        b"in" => OdinKind::InKeyword,
        b"map" => OdinKind::MapKeyword,
        b"matrix" => OdinKind::MatrixKeyword,
        b"nil" => OdinKind::NilKeyword,
        b"not_in" => OdinKind::NotInKeyword,
        b"or_break" => OdinKind::OrBreakKeyword,
        b"or_continue" => OdinKind::OrContinueKeyword,
        b"or_else" => OdinKind::OrElseKeyword,
        b"or_return" => OdinKind::OrReturnKeyword,
        b"package" => OdinKind::PackageKeyword,
        b"proc" => OdinKind::ProcKeyword,
        b"return" => OdinKind::ReturnKeyword,
        b"struct" => OdinKind::StructKeyword,
        b"switch" => OdinKind::SwitchKeyword,
        b"transmute" => OdinKind::TransmuteKeyword,
        b"true" => OdinKind::TrueKeyword,
        b"typeid" => OdinKind::TypeidKeyword,
        b"union" => OdinKind::UnionKeyword,
        b"using" => OdinKind::UsingKeyword,
        b"when" => OdinKind::WhenKeyword,
        b"where" => OdinKind::WhereKeyword,
        _ => OdinKind::Identifier,
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
