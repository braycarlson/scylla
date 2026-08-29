use crate::bounded::BoundedVec;
use crate::lex::javascript_token_at as typescript_token_at;
use crate::syntax::typescript::dialect::Dialect;
use crate::syntax::typescript::jsx;
use crate::syntax::typescript::kind::TypeScriptKind;
use crate::syntax::typescript::template;
use crate::token::{Punctuation, Token, TokenKind, Tokens, operator_limit_of};

#[cfg(test)]
const KEYWORDS: [(&[u8], TypeScriptKind); 42] = [
    (b"async", TypeScriptKind::AsyncKeyword),
    (b"await", TypeScriptKind::AwaitKeyword),
    (b"break", TypeScriptKind::BreakKeyword),
    (b"case", TypeScriptKind::CaseKeyword),
    (b"catch", TypeScriptKind::CatchKeyword),
    (b"class", TypeScriptKind::ClassKeyword),
    (b"const", TypeScriptKind::ConstKeyword),
    (b"continue", TypeScriptKind::ContinueKeyword),
    (b"debugger", TypeScriptKind::DebuggerKeyword),
    (b"default", TypeScriptKind::DefaultKeyword),
    (b"delete", TypeScriptKind::DeleteKeyword),
    (b"do", TypeScriptKind::DoKeyword),
    (b"else", TypeScriptKind::ElseKeyword),
    (b"export", TypeScriptKind::ExportKeyword),
    (b"extends", TypeScriptKind::ExtendsKeyword),
    (b"false", TypeScriptKind::FalseKeyword),
    (b"finally", TypeScriptKind::FinallyKeyword),
    (b"for", TypeScriptKind::ForKeyword),
    (b"function", TypeScriptKind::FunctionKeyword),
    (b"if", TypeScriptKind::IfKeyword),
    (b"import", TypeScriptKind::ImportKeyword),
    (b"in", TypeScriptKind::InKeyword),
    (b"instanceof", TypeScriptKind::InstanceofKeyword),
    (b"let", TypeScriptKind::LetKeyword),
    (b"new", TypeScriptKind::NewKeyword),
    (b"null", TypeScriptKind::NullKeyword),
    (b"of", TypeScriptKind::OfKeyword),
    (b"return", TypeScriptKind::ReturnKeyword),
    (b"static", TypeScriptKind::StaticKeyword),
    (b"super", TypeScriptKind::SuperKeyword),
    (b"switch", TypeScriptKind::SwitchKeyword),
    (b"this", TypeScriptKind::ThisKeyword),
    (b"throw", TypeScriptKind::ThrowKeyword),
    (b"true", TypeScriptKind::TrueKeyword),
    (b"try", TypeScriptKind::TryKeyword),
    (b"typeof", TypeScriptKind::TypeofKeyword),
    (b"undefined", TypeScriptKind::UndefinedKeyword),
    (b"var", TypeScriptKind::VarKeyword),
    (b"void", TypeScriptKind::VoidKeyword),
    (b"while", TypeScriptKind::WhileKeyword),
    (b"with", TypeScriptKind::WithKeyword),
    (b"yield", TypeScriptKind::YieldKeyword),
];

#[cfg(test)]
const OPERATORS: [(&[u8], TypeScriptKind); 54] = [
    (b">>>=", TypeScriptKind::GreaterGreaterGreaterEqual),
    (b"!==", TypeScriptKind::BangEqualEqual),
    (b"&&=", TypeScriptKind::AmpersandAmpersandEqual),
    (b"**=", TypeScriptKind::StarStarEqual),
    (b"...", TypeScriptKind::DotDotDot),
    (b"<<=", TypeScriptKind::LessLessEqual),
    (b"===", TypeScriptKind::EqualEqualEqual),
    (b">>=", TypeScriptKind::GreaterGreaterEqual),
    (b"??=", TypeScriptKind::QuestionQuestionEqual),
    (b"||=", TypeScriptKind::BarBarEqual),
    (b"!=", TypeScriptKind::BangEqual),
    (b"%=", TypeScriptKind::PercentEqual),
    (b"&&", TypeScriptKind::AmpersandAmpersand),
    (b"&=", TypeScriptKind::AmpersandEqual),
    (b"**", TypeScriptKind::StarStar),
    (b"*=", TypeScriptKind::StarEqual),
    (b"++", TypeScriptKind::PlusPlus),
    (b"+=", TypeScriptKind::PlusEqual),
    (b"--", TypeScriptKind::MinusMinus),
    (b"-=", TypeScriptKind::MinusEqual),
    (b"/=", TypeScriptKind::SlashEqual),
    (b"<<", TypeScriptKind::LessLess),
    (b"<=", TypeScriptKind::LessEqual),
    (b"==", TypeScriptKind::EqualEqual),
    (b"=>", TypeScriptKind::Arrow),
    (b">=", TypeScriptKind::GreaterEqual),
    (b"?.", TypeScriptKind::QuestionDot),
    (b"??", TypeScriptKind::QuestionQuestion),
    (b"^=", TypeScriptKind::CaretEqual),
    (b"|=", TypeScriptKind::BarEqual),
    (b"||", TypeScriptKind::BarBar),
    (b"!", TypeScriptKind::Bang),
    (b"%", TypeScriptKind::Percent),
    (b"&", TypeScriptKind::Ampersand),
    (b"(", TypeScriptKind::ParenOpen),
    (b")", TypeScriptKind::ParenClose),
    (b"*", TypeScriptKind::Star),
    (b"+", TypeScriptKind::Plus),
    (b",", TypeScriptKind::Comma),
    (b"-", TypeScriptKind::Minus),
    (b".", TypeScriptKind::Dot),
    (b"/", TypeScriptKind::Slash),
    (b":", TypeScriptKind::Colon),
    (b";", TypeScriptKind::Semicolon),
    (b"<", TypeScriptKind::Less),
    (b"=", TypeScriptKind::Equal),
    (b">", TypeScriptKind::Greater),
    (b"?", TypeScriptKind::Question),
    (b"@", TypeScriptKind::At),
    (b"[", TypeScriptKind::BracketOpen),
    (b"]", TypeScriptKind::BracketClose),
    (b"^", TypeScriptKind::Caret),
    (b"|", TypeScriptKind::Bar),
    (b"~", TypeScriptKind::Tilde),
];

#[must_use]
pub fn classify(
    source: &[u8],
    tokens: &[Token],
    out: &mut Tokens,
    raw: &mut BoundedVec<TypeScriptKind>,
    dialect: Dialect,
) -> bool {
    assert!(u32::try_from(tokens.len()).is_ok());

    out.clear();
    raw.clear();

    let mut position = 0;
    let mut previous: Option<TypeScriptKind> = None;

    while position < tokens.len() {
        let token = tokens[position];
        let offset = token.offset as usize;

        if token.kind == TokenKind::String && source.get(offset) == Some(&b'`') {
            if !template::expand(source, token.span(), out, raw) {
                return false;
            }

            previous = Some(TypeScriptKind::TemplateEnd);
            position += 1;

            continue;
        }

        if dialect.is_tsx() && jsx::opens_at(previous, source, offset) {
            let Some(stop) = jsx::expand(source, offset, out, raw) else {
                return false;
            };

            previous = Some(TypeScriptKind::JsxTagEnd);
            position = past(tokens, position + 1, stop);

            if position < tokens.len() && (tokens[position].offset as usize) < stop {
                let Some(held) = resume(source, tokens, position, stop, out, raw, &mut previous)
                else {
                    return false;
                };

                position = held;
            }

            continue;
        }

        let limit = operator_limit_of(tokens, position, token.end());

        let Some(stop) = split(source, token, limit, out, raw, &mut previous) else {
            return false;
        };

        position = past(tokens, position + 1, stop);
    }

    true
}

fn resume(
    source: &[u8],
    tokens: &[Token],
    from: usize,
    stop: usize,
    out: &mut Tokens,
    raw: &mut BoundedVec<TypeScriptKind>,
    previous: &mut Option<TypeScriptKind>,
) -> Option<usize> {
    let mut coarse = TokenKind::Punctuation(Punctuation::Greater);
    let mut cursor = stop;
    let mut position = from;

    for _ in 0..source.len() {
        while cursor < source.len() && source[cursor].is_ascii_whitespace() {
            cursor += 1;
        }

        if cursor >= source.len() {
            return Some(tokens.len());
        }

        while position < tokens.len() && (tokens[position].offset as usize) < cursor {
            position += 1;
        }

        if position < tokens.len() && tokens[position].offset as usize == cursor {
            return Some(position);
        }

        if jsx::opens_at(*previous, source, cursor) {
            let held = jsx::expand(source, cursor, out, raw)?;

            *previous = Some(TypeScriptKind::JsxTagEnd);
            coarse = TokenKind::Punctuation(Punctuation::Greater);
            cursor = held;

            continue;
        }

        let (kind, reach) = typescript_token_at(source, cursor, coarse);

        let token = Token {
            kind,
            length: u32::try_from(reach - cursor).ok()?,
            offset: u32::try_from(cursor).ok()?,
        };

        if kind == TokenKind::String && source.get(cursor) == Some(&b'`') {
            if !template::expand(source, token.span(), out, raw) {
                return None;
            }

            *previous = Some(TypeScriptKind::TemplateEnd);
            coarse = kind;
            cursor = reach;

            continue;
        }

        let limit = operator_reach(source, reach, kind);
        let held = split(source, token, u32::try_from(limit).ok()?, out, raw, previous)?;

        coarse = kind;
        cursor = held.max(reach);
    }

    Some(tokens.len())
}

fn operator_reach(source: &[u8], from: usize, coarse: TokenKind) -> usize {
    let mut previous = coarse;
    let mut reach = from;

    for _ in 0..source.len() {
        if reach >= source.len() || source[reach].is_ascii_whitespace() {
            break;
        }

        let (kind, stop) = typescript_token_at(source, reach, previous);

        if stop <= reach || !matches!(kind, TokenKind::Number | TokenKind::Punctuation(_)) {
            break;
        }

        previous = kind;
        reach = stop;
    }

    reach
}

fn past(tokens: &[Token], from: usize, stop: usize) -> usize {
    let mut position = from;

    while position < tokens.len() && tokens[position].end() as usize <= stop {
        position += 1;
    }

    position
}

fn split(
    source: &[u8],
    token: Token,
    limit: u32,
    out: &mut Tokens,
    raw: &mut BoundedVec<TypeScriptKind>,
    previous: &mut Option<TypeScriptKind>,
) -> Option<usize> {
    let offset = token.offset as usize;
    let end = token.end() as usize;
    let mut cursor = offset;
    let mut stop = offset;

    for _ in 0..=(end - offset) {
        let (kind, reach) = kind_of(&source[..limit as usize], token.kind, cursor, end);

        if !push(source, out, raw, token.kind, kind, cursor, reach) {
            return None;
        }

        if kind != TypeScriptKind::Comment {
            *previous = Some(kind);
        }

        stop = reach;

        if reach >= end {
            break;
        }

        cursor = reach;
    }

    Some(stop)
}

pub(crate) fn push(
    source: &[u8],
    out: &mut Tokens,
    raw: &mut BoundedVec<TypeScriptKind>,
    coarse: TokenKind,
    kind: TypeScriptKind,
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

pub(crate) fn kind_of(
    source: &[u8],
    coarse: TokenKind,
    offset: usize,
    end: usize,
) -> (TypeScriptKind, usize) {
    let bytes = &source[offset..end];

    match coarse {
        TokenKind::BlockEnd => (TypeScriptKind::BraceClose, end),
        TokenKind::BlockStart => (TypeScriptKind::BraceOpen, end),
        TokenKind::Comment => (TypeScriptKind::Comment, end),
        TokenKind::Newline => (TypeScriptKind::ErrorToken, end),
        TokenKind::Number => (TypeScriptKind::Number, end),
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
        byte.is_ascii_alphabetic() || matches!(*byte, b'#' | b'$' | b'\\' | b'_') || *byte >= 0x80
    })
}

fn operator_join(source: &[u8], offset: usize) -> (TypeScriptKind, usize) {
    if source.get(offset..offset + 4) == Some(b">>>=".as_slice()) {
        return (TypeScriptKind::GreaterGreaterGreaterEqual, offset + 4);
    }

    if let Some(kind) = operator_three(source, offset) {
        return (kind, offset + 3);
    }

    if let Some(kind) = operator_two(source, offset) {
        return (kind, offset + 2);
    }

    (operator_one(source, offset), offset + 1)
}

fn operator_three(source: &[u8], offset: usize) -> Option<TypeScriptKind> {
    let kind = match source.get(offset..offset + 3).unwrap_or_default() {
        b"!==" => TypeScriptKind::BangEqualEqual,
        b"&&=" => TypeScriptKind::AmpersandAmpersandEqual,
        b"**=" => TypeScriptKind::StarStarEqual,
        b"..." => TypeScriptKind::DotDotDot,
        b"<<=" => TypeScriptKind::LessLessEqual,
        b"===" => TypeScriptKind::EqualEqualEqual,
        b">>=" => TypeScriptKind::GreaterGreaterEqual,
        b"??=" => TypeScriptKind::QuestionQuestionEqual,
        b"||=" => TypeScriptKind::BarBarEqual,
        _ => return None,
    };

    Some(kind)
}

fn operator_two(source: &[u8], offset: usize) -> Option<TypeScriptKind> {
    let kind = match source.get(offset..offset + 2).unwrap_or_default() {
        b"!=" => TypeScriptKind::BangEqual,
        b"%=" => TypeScriptKind::PercentEqual,
        b"&&" => TypeScriptKind::AmpersandAmpersand,
        b"&=" => TypeScriptKind::AmpersandEqual,
        b"**" => TypeScriptKind::StarStar,
        b"*=" => TypeScriptKind::StarEqual,
        b"++" => TypeScriptKind::PlusPlus,
        b"+=" => TypeScriptKind::PlusEqual,
        b"--" => TypeScriptKind::MinusMinus,
        b"-=" => TypeScriptKind::MinusEqual,
        b"/=" => TypeScriptKind::SlashEqual,
        b"<<" => TypeScriptKind::LessLess,
        b"<=" => TypeScriptKind::LessEqual,
        b"==" => TypeScriptKind::EqualEqual,
        b"=>" => TypeScriptKind::Arrow,
        b">=" => TypeScriptKind::GreaterEqual,
        b"?." if !source.get(offset + 2).is_some_and(u8::is_ascii_digit) => {
            TypeScriptKind::QuestionDot
        }
        b"??" => TypeScriptKind::QuestionQuestion,
        b"^=" => TypeScriptKind::CaretEqual,
        b"|=" => TypeScriptKind::BarEqual,
        b"||" => TypeScriptKind::BarBar,
        _ => return None,
    };

    Some(kind)
}

fn operator_one(source: &[u8], offset: usize) -> TypeScriptKind {
    match source.get(offset).copied().unwrap_or(0) {
        b'!' => TypeScriptKind::Bang,
        b'%' => TypeScriptKind::Percent,
        b'&' => TypeScriptKind::Ampersand,
        b'(' => TypeScriptKind::ParenOpen,
        b')' => TypeScriptKind::ParenClose,
        b'*' => TypeScriptKind::Star,
        b'+' => TypeScriptKind::Plus,
        b',' => TypeScriptKind::Comma,
        b'-' => TypeScriptKind::Minus,
        b'.' => TypeScriptKind::Dot,
        b'/' => TypeScriptKind::Slash,
        b':' => TypeScriptKind::Colon,
        b';' => TypeScriptKind::Semicolon,
        b'<' => TypeScriptKind::Less,
        b'=' => TypeScriptKind::Equal,
        b'>' => TypeScriptKind::Greater,
        b'?' => TypeScriptKind::Question,
        b'@' => TypeScriptKind::At,
        b'[' => TypeScriptKind::BracketOpen,
        b']' => TypeScriptKind::BracketClose,
        b'^' => TypeScriptKind::Caret,
        b'|' => TypeScriptKind::Bar,
        b'~' => TypeScriptKind::Tilde,
        _ => TypeScriptKind::ErrorToken,
    }
}

fn string_of(bytes: &[u8]) -> TypeScriptKind {
    match bytes.first() {
        Some(b'/') => TypeScriptKind::Regex,
        Some(b'`') => TypeScriptKind::TemplateChars,
        _ => TypeScriptKind::String,
    }
}

pub(crate) fn word_of(bytes: &[u8]) -> TypeScriptKind {
    if bytes.first() == Some(&b'#') {
        return TypeScriptKind::PrivateIdentifier;
    }

    match bytes {
        b"async" => TypeScriptKind::AsyncKeyword,
        b"await" => TypeScriptKind::AwaitKeyword,
        b"break" => TypeScriptKind::BreakKeyword,
        b"case" => TypeScriptKind::CaseKeyword,
        b"catch" => TypeScriptKind::CatchKeyword,
        b"class" => TypeScriptKind::ClassKeyword,
        b"const" => TypeScriptKind::ConstKeyword,
        b"continue" => TypeScriptKind::ContinueKeyword,
        b"debugger" => TypeScriptKind::DebuggerKeyword,
        b"default" => TypeScriptKind::DefaultKeyword,
        b"delete" => TypeScriptKind::DeleteKeyword,
        b"do" => TypeScriptKind::DoKeyword,
        b"else" => TypeScriptKind::ElseKeyword,
        b"export" => TypeScriptKind::ExportKeyword,
        b"extends" => TypeScriptKind::ExtendsKeyword,
        b"false" => TypeScriptKind::FalseKeyword,
        b"finally" => TypeScriptKind::FinallyKeyword,
        b"for" => TypeScriptKind::ForKeyword,
        b"function" => TypeScriptKind::FunctionKeyword,
        b"if" => TypeScriptKind::IfKeyword,
        b"import" => TypeScriptKind::ImportKeyword,
        b"in" => TypeScriptKind::InKeyword,
        b"instanceof" => TypeScriptKind::InstanceofKeyword,
        b"let" => TypeScriptKind::LetKeyword,
        b"new" => TypeScriptKind::NewKeyword,
        b"null" => TypeScriptKind::NullKeyword,
        b"of" => TypeScriptKind::OfKeyword,
        b"return" => TypeScriptKind::ReturnKeyword,
        b"static" => TypeScriptKind::StaticKeyword,
        b"super" => TypeScriptKind::SuperKeyword,
        b"switch" => TypeScriptKind::SwitchKeyword,
        b"this" => TypeScriptKind::ThisKeyword,
        b"throw" => TypeScriptKind::ThrowKeyword,
        b"true" => TypeScriptKind::TrueKeyword,
        b"try" => TypeScriptKind::TryKeyword,
        b"typeof" => TypeScriptKind::TypeofKeyword,
        b"undefined" => TypeScriptKind::UndefinedKeyword,
        b"var" => TypeScriptKind::VarKeyword,
        b"void" => TypeScriptKind::VoidKeyword,
        b"while" => TypeScriptKind::WhileKeyword,
        b"with" => TypeScriptKind::WithKeyword,
        b"yield" => TypeScriptKind::YieldKeyword,
        _ => TypeScriptKind::Identifier,
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
