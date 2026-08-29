use crate::bounded::{BoundedVec, count_of};
use crate::syntax::zig::kind::ZigKind;
use crate::token::{Token, TokenKind, Tokens, operator_limit_of};

#[cfg(test)]
const KEYWORDS: [(&[u8], ZigKind); 46] = [
    (b"addrspace", ZigKind::AddrspaceKeyword),
    (b"align", ZigKind::AlignKeyword),
    (b"allowzero", ZigKind::AllowzeroKeyword),
    (b"and", ZigKind::AndKeyword),
    (b"anyframe", ZigKind::AnyframeKeyword),
    (b"anytype", ZigKind::AnytypeKeyword),
    (b"asm", ZigKind::AsmKeyword),
    (b"break", ZigKind::BreakKeyword),
    (b"callconv", ZigKind::CallconvKeyword),
    (b"catch", ZigKind::CatchKeyword),
    (b"comptime", ZigKind::ComptimeKeyword),
    (b"const", ZigKind::ConstKeyword),
    (b"continue", ZigKind::ContinueKeyword),
    (b"defer", ZigKind::DeferKeyword),
    (b"else", ZigKind::ElseKeyword),
    (b"enum", ZigKind::EnumKeyword),
    (b"errdefer", ZigKind::ErrdeferKeyword),
    (b"error", ZigKind::ErrorKeyword),
    (b"export", ZigKind::ExportKeyword),
    (b"extern", ZigKind::ExternKeyword),
    (b"fn", ZigKind::FnKeyword),
    (b"for", ZigKind::ForKeyword),
    (b"if", ZigKind::IfKeyword),
    (b"inline", ZigKind::InlineKeyword),
    (b"linksection", ZigKind::LinksectionKeyword),
    (b"noalias", ZigKind::NoaliasKeyword),
    (b"noinline", ZigKind::NoinlineKeyword),
    (b"nosuspend", ZigKind::NosuspendKeyword),
    (b"opaque", ZigKind::OpaqueKeyword),
    (b"or", ZigKind::OrKeyword),
    (b"orelse", ZigKind::OrelseKeyword),
    (b"packed", ZigKind::PackedKeyword),
    (b"pub", ZigKind::PubKeyword),
    (b"resume", ZigKind::ResumeKeyword),
    (b"return", ZigKind::ReturnKeyword),
    (b"struct", ZigKind::StructKeyword),
    (b"suspend", ZigKind::SuspendKeyword),
    (b"switch", ZigKind::SwitchKeyword),
    (b"test", ZigKind::TestKeyword),
    (b"threadlocal", ZigKind::ThreadlocalKeyword),
    (b"try", ZigKind::TryKeyword),
    (b"union", ZigKind::UnionKeyword),
    (b"unreachable", ZigKind::UnreachableKeyword),
    (b"var", ZigKind::VarKeyword),
    (b"volatile", ZigKind::VolatileKeyword),
    (b"while", ZigKind::WhileKeyword),
];

#[cfg(test)]
const OPERATORS: [(&[u8], ZigKind); 60] = [
    (b"<<|=", ZigKind::LessLessPipeEqual),
    (b"...", ZigKind::DotDotDot),
    (b"*%=", ZigKind::StarPercentEqual),
    (b"*|=", ZigKind::StarPipeEqual),
    (b"+%=", ZigKind::PlusPercentEqual),
    (b"+|=", ZigKind::PlusPipeEqual),
    (b"-%=", ZigKind::MinusPercentEqual),
    (b"-|=", ZigKind::MinusPipeEqual),
    (b"<<=", ZigKind::LessLessEqual),
    (b"<<|", ZigKind::LessLessPipe),
    (b">>=", ZigKind::GreaterGreaterEqual),
    (b"!=", ZigKind::BangEqual),
    (b"%=", ZigKind::PercentEqual),
    (b"&=", ZigKind::AmpersandEqual),
    (b"*%", ZigKind::StarPercent),
    (b"**", ZigKind::StarStar),
    (b"*=", ZigKind::StarEqual),
    (b"*|", ZigKind::StarPipe),
    (b"+%", ZigKind::PlusPercent),
    (b"++", ZigKind::PlusPlus),
    (b"+=", ZigKind::PlusEqual),
    (b"+|", ZigKind::PlusPipe),
    (b"-%", ZigKind::MinusPercent),
    (b"-=", ZigKind::MinusEqual),
    (b"-|", ZigKind::MinusPipe),
    (b".*", ZigKind::DotAsterisk),
    (b"..", ZigKind::DotDot),
    (b".?", ZigKind::DotQuestion),
    (b"/=", ZigKind::SlashEqual),
    (b"<<", ZigKind::LessLess),
    (b"<=", ZigKind::LessEqual),
    (b"==", ZigKind::EqualEqual),
    (b"=>", ZigKind::Arrow),
    (b">=", ZigKind::GreaterEqual),
    (b">>", ZigKind::GreaterGreater),
    (b"^=", ZigKind::CaretEqual),
    (b"|=", ZigKind::PipeEqual),
    (b"||", ZigKind::PipePipe),
    (b"!", ZigKind::Bang),
    (b"%", ZigKind::Percent),
    (b"&", ZigKind::Ampersand),
    (b"(", ZigKind::ParenOpen),
    (b")", ZigKind::ParenClose),
    (b"*", ZigKind::Star),
    (b"+", ZigKind::Plus),
    (b",", ZigKind::Comma),
    (b"-", ZigKind::Minus),
    (b".", ZigKind::Dot),
    (b"/", ZigKind::Slash),
    (b":", ZigKind::Colon),
    (b";", ZigKind::Semicolon),
    (b"<", ZigKind::Less),
    (b"=", ZigKind::Equal),
    (b">", ZigKind::Greater),
    (b"?", ZigKind::Question),
    (b"[", ZigKind::BracketOpen),
    (b"]", ZigKind::BracketClose),
    (b"^", ZigKind::Caret),
    (b"|", ZigKind::Pipe),
    (b"~", ZigKind::Tilde),
];

#[must_use]
pub fn classify(
    source: &[u8],
    tokens: &[Token],
    out: &mut Tokens,
    raw: &mut BoundedVec<ZigKind>,
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
        let mut cursor = offset;
        let mut stop = offset;

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
    raw: &mut BoundedVec<ZigKind>,
    coarse: TokenKind,
    kind: ZigKind,
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

fn kind_of(source: &[u8], coarse: TokenKind, offset: usize, end: usize) -> (ZigKind, usize) {
    let bytes = &source[offset..end];

    match coarse {
        TokenKind::BlockEnd => (ZigKind::BraceClose, end),
        TokenKind::BlockStart => (ZigKind::BraceOpen, end),
        TokenKind::Comment => (comment_of(bytes), end),
        TokenKind::Newline => (ZigKind::ErrorToken, end),
        TokenKind::Number => (ZigKind::Number, end),
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
    bytes.first().is_some_and(|byte| {
        byte.is_ascii_alphabetic() || matches!(*byte, b'@' | b'_') || *byte >= 0x80
    })
}

fn operator_wide(source: &[u8], offset: usize) -> Option<(ZigKind, usize)> {
    if source.get(offset..offset + 4) == Some(b"<<|=".as_slice()) {
        return Some((ZigKind::LessLessPipeEqual, offset + 4));
    }

    match source.get(offset..offset + 3).unwrap_or_default() {
        b"..." => return Some((ZigKind::DotDotDot, offset + 3)),
        b"*%=" => return Some((ZigKind::StarPercentEqual, offset + 3)),
        b"*|=" => return Some((ZigKind::StarPipeEqual, offset + 3)),
        b"+%=" => return Some((ZigKind::PlusPercentEqual, offset + 3)),
        b"+|=" => return Some((ZigKind::PlusPipeEqual, offset + 3)),
        b"-%=" => return Some((ZigKind::MinusPercentEqual, offset + 3)),
        b"-|=" => return Some((ZigKind::MinusPipeEqual, offset + 3)),
        b"<<=" => return Some((ZigKind::LessLessEqual, offset + 3)),
        b"<<|" => return Some((ZigKind::LessLessPipe, offset + 3)),
        b">>=" => return Some((ZigKind::GreaterGreaterEqual, offset + 3)),
        _ => {}
    }

    match source.get(offset..offset + 2).unwrap_or_default() {
        b"!=" => return Some((ZigKind::BangEqual, offset + 2)),
        b"%=" => return Some((ZigKind::PercentEqual, offset + 2)),
        b"&=" => return Some((ZigKind::AmpersandEqual, offset + 2)),
        b"*%" => return Some((ZigKind::StarPercent, offset + 2)),
        b"**" => return Some((ZigKind::StarStar, offset + 2)),
        b"*=" => return Some((ZigKind::StarEqual, offset + 2)),
        b"*|" => return Some((ZigKind::StarPipe, offset + 2)),
        b"+%" => return Some((ZigKind::PlusPercent, offset + 2)),
        b"++" => return Some((ZigKind::PlusPlus, offset + 2)),
        b"+=" => return Some((ZigKind::PlusEqual, offset + 2)),
        b"+|" => return Some((ZigKind::PlusPipe, offset + 2)),
        b"-%" => return Some((ZigKind::MinusPercent, offset + 2)),
        b"-=" => return Some((ZigKind::MinusEqual, offset + 2)),
        b"-|" => return Some((ZigKind::MinusPipe, offset + 2)),
        b".*" => return Some((ZigKind::DotAsterisk, offset + 2)),
        b".." => return Some((ZigKind::DotDot, offset + 2)),
        b".?" => return Some((ZigKind::DotQuestion, offset + 2)),
        b"/=" => return Some((ZigKind::SlashEqual, offset + 2)),
        b"<<" => return Some((ZigKind::LessLess, offset + 2)),
        b"<=" => return Some((ZigKind::LessEqual, offset + 2)),
        b"==" => return Some((ZigKind::EqualEqual, offset + 2)),
        b"=>" => return Some((ZigKind::Arrow, offset + 2)),
        b">=" => return Some((ZigKind::GreaterEqual, offset + 2)),
        b">>" => return Some((ZigKind::GreaterGreater, offset + 2)),
        b"^=" => return Some((ZigKind::CaretEqual, offset + 2)),
        b"|=" => return Some((ZigKind::PipeEqual, offset + 2)),
        b"||" => return Some((ZigKind::PipePipe, offset + 2)),
        _ => {}
    }

    None
}

fn operator_join(source: &[u8], offset: usize) -> (ZigKind, usize) {
    if let Some(found) = operator_wide(source, offset) {
        return found;
    }

    match source.get(offset..offset + 1).unwrap_or_default() {
        b"!" => return (ZigKind::Bang, offset + 1),
        b"%" => return (ZigKind::Percent, offset + 1),
        b"&" => return (ZigKind::Ampersand, offset + 1),
        b"(" => return (ZigKind::ParenOpen, offset + 1),
        b")" => return (ZigKind::ParenClose, offset + 1),
        b"*" => return (ZigKind::Star, offset + 1),
        b"+" => return (ZigKind::Plus, offset + 1),
        b"," => return (ZigKind::Comma, offset + 1),
        b"-" => return (ZigKind::Minus, offset + 1),
        b"." => return (ZigKind::Dot, offset + 1),
        b"/" => return (ZigKind::Slash, offset + 1),
        b":" => return (ZigKind::Colon, offset + 1),
        b";" => return (ZigKind::Semicolon, offset + 1),
        b"<" => return (ZigKind::Less, offset + 1),
        b"=" => return (ZigKind::Equal, offset + 1),
        b">" => return (ZigKind::Greater, offset + 1),
        b"?" => return (ZigKind::Question, offset + 1),
        b"[" => return (ZigKind::BracketOpen, offset + 1),
        b"]" => return (ZigKind::BracketClose, offset + 1),
        b"^" => return (ZigKind::Caret, offset + 1),
        b"|" => return (ZigKind::Pipe, offset + 1),
        b"~" => return (ZigKind::Tilde, offset + 1),
        _ => {}
    }

    if source.get(offset) == Some(&b'{') {
        return (ZigKind::BraceOpen, offset + 1);
    }

    if source.get(offset) == Some(&b'}') {
        return (ZigKind::BraceClose, offset + 1);
    }

    (ZigKind::ErrorToken, offset + 1)
}

fn comment_of(bytes: &[u8]) -> ZigKind {
    if bytes.starts_with(b"///") || bytes.starts_with(b"//!") {
        return ZigKind::DocComment;
    }

    ZigKind::Comment
}

fn string_of(bytes: &[u8]) -> ZigKind {
    match bytes.first() {
        Some(b'\'') => ZigKind::Character,
        Some(b'\\') => ZigKind::TextLine,
        _ => ZigKind::Text,
    }
}

fn word_of(bytes: &[u8]) -> ZigKind {
    if bytes.first() == Some(&b'@') {
        if bytes.get(1) == Some(&b'"') {
            return ZigKind::Identifier;
        }

        return ZigKind::Builtin;
    }

    match bytes {
        b"addrspace" => ZigKind::AddrspaceKeyword,
        b"align" => ZigKind::AlignKeyword,
        b"allowzero" => ZigKind::AllowzeroKeyword,
        b"and" => ZigKind::AndKeyword,
        b"anyframe" => ZigKind::AnyframeKeyword,
        b"anytype" => ZigKind::AnytypeKeyword,
        b"asm" => ZigKind::AsmKeyword,
        b"break" => ZigKind::BreakKeyword,
        b"callconv" => ZigKind::CallconvKeyword,
        b"catch" => ZigKind::CatchKeyword,
        b"comptime" => ZigKind::ComptimeKeyword,
        b"const" => ZigKind::ConstKeyword,
        b"continue" => ZigKind::ContinueKeyword,
        b"defer" => ZigKind::DeferKeyword,
        b"else" => ZigKind::ElseKeyword,
        b"enum" => ZigKind::EnumKeyword,
        b"errdefer" => ZigKind::ErrdeferKeyword,
        b"error" => ZigKind::ErrorKeyword,
        b"export" => ZigKind::ExportKeyword,
        b"extern" => ZigKind::ExternKeyword,
        b"fn" => ZigKind::FnKeyword,
        b"for" => ZigKind::ForKeyword,
        b"if" => ZigKind::IfKeyword,
        b"inline" => ZigKind::InlineKeyword,
        b"linksection" => ZigKind::LinksectionKeyword,
        b"noalias" => ZigKind::NoaliasKeyword,
        b"noinline" => ZigKind::NoinlineKeyword,
        b"nosuspend" => ZigKind::NosuspendKeyword,
        b"opaque" => ZigKind::OpaqueKeyword,
        b"or" => ZigKind::OrKeyword,
        b"orelse" => ZigKind::OrelseKeyword,
        b"packed" => ZigKind::PackedKeyword,
        b"pub" => ZigKind::PubKeyword,
        b"resume" => ZigKind::ResumeKeyword,
        b"return" => ZigKind::ReturnKeyword,
        b"struct" => ZigKind::StructKeyword,
        b"suspend" => ZigKind::SuspendKeyword,
        b"switch" => ZigKind::SwitchKeyword,
        b"test" => ZigKind::TestKeyword,
        b"threadlocal" => ZigKind::ThreadlocalKeyword,
        b"try" => ZigKind::TryKeyword,
        b"union" => ZigKind::UnionKeyword,
        b"unreachable" => ZigKind::UnreachableKeyword,
        b"var" => ZigKind::VarKeyword,
        b"volatile" => ZigKind::VolatileKeyword,
        b"while" => ZigKind::WhileKeyword,
        _ => ZigKind::Identifier,
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
