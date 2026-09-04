use crate::bounded::{BoundedVec, count_of};
use crate::syntax::rust::kind::RustKind;
use crate::token::{Punctuation, Token, TokenKind, Tokens, operator_limit_of};

#[cfg(test)]
const KEYWORDS: [(&[u8], RustKind); 42] = [
    (b"Self", RustKind::SelfUpper),
    (b"as", RustKind::AsKeyword),
    (b"async", RustKind::AsyncKeyword),
    (b"await", RustKind::AwaitKeyword),
    (b"break", RustKind::BreakKeyword),
    (b"const", RustKind::ConstKeyword),
    (b"continue", RustKind::ContinueKeyword),
    (b"crate", RustKind::CrateKeyword),
    (b"dyn", RustKind::DynKeyword),
    (b"else", RustKind::ElseKeyword),
    (b"enum", RustKind::EnumKeyword),
    (b"extern", RustKind::ExternKeyword),
    (b"false", RustKind::FalseKeyword),
    (b"fn", RustKind::FnKeyword),
    (b"for", RustKind::ForKeyword),
    (b"if", RustKind::IfKeyword),
    (b"impl", RustKind::ImplKeyword),
    (b"in", RustKind::InKeyword),
    (b"let", RustKind::LetKeyword),
    (b"loop", RustKind::LoopKeyword),
    (b"macro", RustKind::MacroKeyword),
    (b"match", RustKind::MatchKeyword),
    (b"mod", RustKind::ModKeyword),
    (b"move", RustKind::MoveKeyword),
    (b"mut", RustKind::MutKeyword),
    (b"pub", RustKind::PubKeyword),
    (b"ref", RustKind::RefKeyword),
    (b"return", RustKind::ReturnKeyword),
    (b"self", RustKind::SelfLower),
    (b"static", RustKind::StaticKeyword),
    (b"struct", RustKind::StructKeyword),
    (b"super", RustKind::SuperKeyword),
    (b"trait", RustKind::TraitKeyword),
    (b"true", RustKind::TrueKeyword),
    (b"try", RustKind::TryKeyword),
    (b"type", RustKind::TypeKeyword),
    (b"union", RustKind::UnionKeyword),
    (b"unsafe", RustKind::UnsafeKeyword),
    (b"use", RustKind::UseKeyword),
    (b"where", RustKind::WhereKeyword),
    (b"while", RustKind::WhileKeyword),
    (b"yield", RustKind::YieldKeyword),
];

#[cfg(test)]
const OPERATORS: [(&[u8], RustKind); 42] = [
    (b"<<=", RustKind::LessLessEqual),
    (b">>=", RustKind::GreaterGreaterEqual),
    (b"..=", RustKind::DotDotEqual),
    (b"...", RustKind::DotDotDot),
    (b"!=", RustKind::BangEqual),
    (b"%=", RustKind::PercentEqual),
    (b"&=", RustKind::AmpersandEqual),
    (b"*=", RustKind::StarEqual),
    (b"+=", RustKind::PlusEqual),
    (b"-=", RustKind::MinusEqual),
    (b"->", RustKind::RArrow),
    (b"..", RustKind::DotDot),
    (b"/=", RustKind::SlashEqual),
    (b"::", RustKind::ColonColon),
    (b"<=", RustKind::LessEqual),
    (b"==", RustKind::EqualEqual),
    (b"=>", RustKind::FatArrow),
    (b">=", RustKind::GreaterEqual),
    (b"^=", RustKind::CaretEqual),
    (b"|=", RustKind::OrEqual),
    (b"||", RustKind::OrOr),
    (b"!", RustKind::Bang),
    (b"#", RustKind::Pound),
    (b"$", RustKind::Dollar),
    (b"%", RustKind::Percent),
    (b"&", RustKind::Ampersand),
    (b"(", RustKind::ParenOpen),
    (b")", RustKind::ParenClose),
    (b"*", RustKind::Star),
    (b"+", RustKind::Plus),
    (b",", RustKind::Comma),
    (b"-", RustKind::Minus),
    (b".", RustKind::Dot),
    (b"/", RustKind::Slash),
    (b":", RustKind::Colon),
    (b";", RustKind::Semicolon),
    (b"<", RustKind::Less),
    (b"=", RustKind::Equal),
    (b">", RustKind::Greater),
    (b"?", RustKind::Question),
    (b"@", RustKind::At),
    (b"^", RustKind::Caret),
];

#[must_use]
pub fn classify(
    source: &[u8],
    tokens: &[Token],
    out: &mut Tokens,
    raw: &mut BoundedVec<RustKind>,
) -> bool {
    assert!(u32::try_from(tokens.len()).is_ok());

    out.clear();
    raw.clear();

    let mut position = 0;
    let mut previous = RustKind::ErrorToken;

    while position < tokens.len() {
        let token = tokens[position];
        let offset = token.offset as usize;
        let mut end = token.end() as usize;
        let mut coarse = token.kind;

        if prefixes(source, token, tokens.get(position + 1)) {
            end = tokens[position + 1].end() as usize;
            coarse = TokenKind::String;
            position += 1;
        }

        if raw_identifier(source, token, &tokens[position..]) {
            end = tokens[position + 2].end() as usize;
            coarse = TokenKind::Identifier;
            position += 2;
        }

        let limit = operator_limit_of(tokens, position, count_of(end));
        let mut cursor = offset.max(out.end_previous() as usize);
        let mut stop = cursor;

        let split = if coarse == TokenKind::Number && previous == RustKind::Dot {
            source[offset..end].iter().position(|byte| *byte == b'.')
        } else {
            None
        };

        if let Some(index) = split {
            let middle = offset + index;

            if !push(source, out, raw, coarse, RustKind::Number, offset, middle) {
                return false;
            }

            let dot = TokenKind::Punctuation(Punctuation::Dot);

            if !push(source, out, raw, dot, RustKind::Dot, middle, middle + 1) {
                return false;
            }

            if !push(source, out, raw, coarse, RustKind::Number, middle + 1, end) {
                return false;
            }

            previous = RustKind::Number;
            position += 1;

            continue;
        }

        for _ in 0..=(end - offset) {
            let (kind, reach) = kind_of(source, limit as usize, coarse, cursor, end);

            if !push(source, out, raw, coarse, kind, cursor, reach) {
                return false;
            }

            previous = kind;
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

fn prefixes(source: &[u8], token: Token, next: Option<&Token>) -> bool {
    if token.kind != TokenKind::Identifier {
        return false;
    }

    let Some(held) = next else {
        return false;
    };

    if held.kind != TokenKind::String || held.offset != token.end() {
        return false;
    }

    matches!(token.text(source), b"b" | b"br" | b"c" | b"cr" | b"rb")
}

fn raw_identifier(source: &[u8], token: Token, rest: &[Token]) -> bool {
    if token.kind != TokenKind::Identifier || token.text(source) != b"r" {
        return false;
    }

    if rest.len() < 3 {
        return false;
    }

    let Some(pound) = rest.get(1) else {
        return false;
    };

    let Some(held) = rest.get(2) else {
        return false;
    };

    pound.offset == token.end()
        && pound.length == 1
        && source.get(pound.offset as usize) == Some(&b'#')
        && held.kind == TokenKind::Identifier
        && held.offset == pound.end()
}

fn push(
    source: &[u8],
    out: &mut Tokens,
    raw: &mut BoundedVec<RustKind>,
    coarse: TokenKind,
    kind: RustKind,
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

fn kind_of(
    source: &[u8],
    limit: usize,
    coarse: TokenKind,
    offset: usize,
    end: usize,
) -> (RustKind, usize) {
    let bytes = &source[offset..end];

    match coarse {
        TokenKind::BlockEnd => (RustKind::BraceClose, end),
        TokenKind::BlockStart => (RustKind::BraceOpen, end),
        TokenKind::Comment => (comment_of(bytes), end),
        TokenKind::Newline => (RustKind::ErrorToken, end),
        TokenKind::Number => (RustKind::Number, number_end(source, end)),
        TokenKind::String => (string_of(bytes), end),
        TokenKind::Identifier | TokenKind::Keyword(_) | TokenKind::Punctuation(_) => {
            if bytes.len() > 1 && bytes.first() == Some(&b'\'') {
                return (RustKind::Apostrophe, offset + 1);
            }

            if is_word(bytes) {
                return (word_of(bytes), end);
            }

            operator_join(&source[..limit], offset)
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
    bytes.first().is_some_and(|byte| {
        byte.is_ascii_alphabetic() || matches!(*byte, b'\'' | b'_') || *byte >= 0x80
    })
}

fn operator_join(source: &[u8], offset: usize) -> (RustKind, usize) {
    if let Some(kind) = operator_three(source, offset) {
        return (kind, offset + 3);
    }

    if let Some(kind) = operator_two(source, offset) {
        return (kind, offset + 2);
    }

    (operator_one(source, offset), offset + 1)
}

fn operator_three(source: &[u8], offset: usize) -> Option<RustKind> {
    let kind = match source.get(offset..offset + 3).unwrap_or_default() {
        b"<<=" => RustKind::LessLessEqual,
        b">>=" => RustKind::GreaterGreaterEqual,
        b"..=" => RustKind::DotDotEqual,
        b"..." => RustKind::DotDotDot,
        _ => return None,
    };

    Some(kind)
}

fn operator_two(source: &[u8], offset: usize) -> Option<RustKind> {
    let kind = match source.get(offset..offset + 2).unwrap_or_default() {
        b"!=" => RustKind::BangEqual,
        b"%=" => RustKind::PercentEqual,
        b"&=" => RustKind::AmpersandEqual,
        b"*=" => RustKind::StarEqual,
        b"+=" => RustKind::PlusEqual,
        b"-=" => RustKind::MinusEqual,
        b"->" => RustKind::RArrow,
        b".." => RustKind::DotDot,
        b"/=" => RustKind::SlashEqual,
        b"::" => RustKind::ColonColon,
        b"<=" => RustKind::LessEqual,
        b"==" => RustKind::EqualEqual,
        b"=>" => RustKind::FatArrow,
        b">=" => RustKind::GreaterEqual,
        b"^=" => RustKind::CaretEqual,
        b"|=" => RustKind::OrEqual,
        b"||" => RustKind::OrOr,
        _ => return None,
    };

    Some(kind)
}

fn operator_one(source: &[u8], offset: usize) -> RustKind {
    match source.get(offset).copied().unwrap_or(0) {
        b'!' => RustKind::Bang,
        b'#' => RustKind::Pound,
        b'$' => RustKind::Dollar,
        b'%' => RustKind::Percent,
        b'&' => RustKind::Ampersand,
        b'(' => RustKind::ParenOpen,
        b')' => RustKind::ParenClose,
        b'*' => RustKind::Star,
        b'+' => RustKind::Plus,
        b',' => RustKind::Comma,
        b'-' => RustKind::Minus,
        b'.' => RustKind::Dot,
        b'/' => RustKind::Slash,
        b':' => RustKind::Colon,
        b';' => RustKind::Semicolon,
        b'<' => RustKind::Less,
        b'=' => RustKind::Equal,
        b'>' => RustKind::Greater,
        b'?' => RustKind::Question,
        b'@' => RustKind::At,
        b'[' => RustKind::BracketOpen,
        b']' => RustKind::BracketClose,
        b'^' => RustKind::Caret,
        b'{' => RustKind::BraceOpen,
        b'|' => RustKind::Or,
        b'}' => RustKind::BraceClose,
        b'~' => RustKind::Tilde,
        _ => RustKind::ErrorToken,
    }
}

fn comment_of(bytes: &[u8]) -> RustKind {
    let documented = bytes.starts_with(b"///")
        || bytes.starts_with(b"//!")
        || (bytes.starts_with(b"/**") && !bytes.starts_with(b"/**/"))
        || bytes.starts_with(b"/*!");

    if documented {
        return RustKind::DocComment;
    }

    RustKind::Comment
}

fn prefix_end(bytes: &[u8]) -> usize {
    bytes
        .iter()
        .position(|byte| matches!(*byte, b'"' | b'\'' | b'#'))
        .unwrap_or(bytes.len())
}

fn string_of(bytes: &[u8]) -> RustKind {
    let prefix = &bytes[..prefix_end(bytes)];
    let quote = bytes.get(prefix_end(bytes)).copied().unwrap_or(b'"');
    let character = quote == b'\'';

    if prefix == b"b" {
        if character {
            return RustKind::ByteLiteral;
        }

        return RustKind::ByteStringLiteral;
    }

    if prefix == b"br" || prefix == b"rb" {
        return RustKind::ByteStringLiteral;
    }

    if prefix == b"c" || prefix == b"cr" {
        return RustKind::CStringLiteral;
    }

    if character {
        return RustKind::CharLiteral;
    }

    RustKind::StringLiteral
}

fn word_of(bytes: &[u8]) -> RustKind {
    if bytes == b"_" {
        return RustKind::Underscore;
    }

    if bytes.starts_with(b"r#") {
        return RustKind::Identifier;
    }

    match bytes {
        b"Self" => RustKind::SelfUpper,
        b"as" => RustKind::AsKeyword,
        b"async" => RustKind::AsyncKeyword,
        b"await" => RustKind::AwaitKeyword,
        b"break" => RustKind::BreakKeyword,
        b"const" => RustKind::ConstKeyword,
        b"continue" => RustKind::ContinueKeyword,
        b"crate" => RustKind::CrateKeyword,
        b"dyn" => RustKind::DynKeyword,
        b"else" => RustKind::ElseKeyword,
        b"enum" => RustKind::EnumKeyword,
        b"extern" => RustKind::ExternKeyword,
        b"false" => RustKind::FalseKeyword,
        b"fn" => RustKind::FnKeyword,
        b"for" => RustKind::ForKeyword,
        b"if" => RustKind::IfKeyword,
        b"impl" => RustKind::ImplKeyword,
        b"in" => RustKind::InKeyword,
        b"let" => RustKind::LetKeyword,
        b"loop" => RustKind::LoopKeyword,
        b"macro" => RustKind::MacroKeyword,
        b"match" => RustKind::MatchKeyword,
        b"mod" => RustKind::ModKeyword,
        b"move" => RustKind::MoveKeyword,
        b"mut" => RustKind::MutKeyword,
        b"pub" => RustKind::PubKeyword,
        b"ref" => RustKind::RefKeyword,
        b"return" => RustKind::ReturnKeyword,
        b"self" => RustKind::SelfLower,
        b"static" => RustKind::StaticKeyword,
        b"struct" => RustKind::StructKeyword,
        b"super" => RustKind::SuperKeyword,
        b"trait" => RustKind::TraitKeyword,
        b"true" => RustKind::TrueKeyword,
        b"try" => RustKind::TryKeyword,
        b"type" => RustKind::TypeKeyword,
        b"union" => RustKind::UnionKeyword,
        b"unsafe" => RustKind::UnsafeKeyword,
        b"use" => RustKind::UseKeyword,
        b"where" => RustKind::WhereKeyword,
        b"while" => RustKind::WhileKeyword,
        b"yield" => RustKind::YieldKeyword,
        _ => RustKind::Identifier,
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
