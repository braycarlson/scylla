use crate::bounded::BoundedVec;
use crate::syntax::javascript::jsx;
use crate::syntax::javascript::kind::JavaScriptKind;
use crate::syntax::javascript::template;
use crate::token::{Token, TokenKind, Tokens};

#[cfg(test)]
const KEYWORDS: [(&[u8], JavaScriptKind); 42] = [
    (b"async", JavaScriptKind::AsyncKeyword),
    (b"await", JavaScriptKind::AwaitKeyword),
    (b"break", JavaScriptKind::BreakKeyword),
    (b"case", JavaScriptKind::CaseKeyword),
    (b"catch", JavaScriptKind::CatchKeyword),
    (b"class", JavaScriptKind::ClassKeyword),
    (b"const", JavaScriptKind::ConstKeyword),
    (b"continue", JavaScriptKind::ContinueKeyword),
    (b"debugger", JavaScriptKind::DebuggerKeyword),
    (b"default", JavaScriptKind::DefaultKeyword),
    (b"delete", JavaScriptKind::DeleteKeyword),
    (b"do", JavaScriptKind::DoKeyword),
    (b"else", JavaScriptKind::ElseKeyword),
    (b"export", JavaScriptKind::ExportKeyword),
    (b"extends", JavaScriptKind::ExtendsKeyword),
    (b"false", JavaScriptKind::FalseKeyword),
    (b"finally", JavaScriptKind::FinallyKeyword),
    (b"for", JavaScriptKind::ForKeyword),
    (b"function", JavaScriptKind::FunctionKeyword),
    (b"if", JavaScriptKind::IfKeyword),
    (b"import", JavaScriptKind::ImportKeyword),
    (b"in", JavaScriptKind::InKeyword),
    (b"instanceof", JavaScriptKind::InstanceofKeyword),
    (b"let", JavaScriptKind::LetKeyword),
    (b"new", JavaScriptKind::NewKeyword),
    (b"null", JavaScriptKind::NullKeyword),
    (b"of", JavaScriptKind::OfKeyword),
    (b"return", JavaScriptKind::ReturnKeyword),
    (b"static", JavaScriptKind::StaticKeyword),
    (b"super", JavaScriptKind::SuperKeyword),
    (b"switch", JavaScriptKind::SwitchKeyword),
    (b"this", JavaScriptKind::ThisKeyword),
    (b"throw", JavaScriptKind::ThrowKeyword),
    (b"true", JavaScriptKind::TrueKeyword),
    (b"try", JavaScriptKind::TryKeyword),
    (b"typeof", JavaScriptKind::TypeofKeyword),
    (b"undefined", JavaScriptKind::UndefinedKeyword),
    (b"var", JavaScriptKind::VarKeyword),
    (b"void", JavaScriptKind::VoidKeyword),
    (b"while", JavaScriptKind::WhileKeyword),
    (b"with", JavaScriptKind::WithKeyword),
    (b"yield", JavaScriptKind::YieldKeyword),
];

#[cfg(test)]
const OPERATORS: [(&[u8], JavaScriptKind); 56] = [
    (b">>>=", JavaScriptKind::GreaterGreaterGreaterEqual),
    (b"!==", JavaScriptKind::BangEqualEqual),
    (b"&&=", JavaScriptKind::AmpersandAmpersandEqual),
    (b"**=", JavaScriptKind::StarStarEqual),
    (b"...", JavaScriptKind::DotDotDot),
    (b"<<=", JavaScriptKind::LessLessEqual),
    (b"===", JavaScriptKind::EqualEqualEqual),
    (b">>=", JavaScriptKind::GreaterGreaterEqual),
    (b">>>", JavaScriptKind::GreaterGreaterGreater),
    (b"??=", JavaScriptKind::QuestionQuestionEqual),
    (b"||=", JavaScriptKind::BarBarEqual),
    (b"!=", JavaScriptKind::BangEqual),
    (b"%=", JavaScriptKind::PercentEqual),
    (b"&&", JavaScriptKind::AmpersandAmpersand),
    (b"&=", JavaScriptKind::AmpersandEqual),
    (b"**", JavaScriptKind::StarStar),
    (b"*=", JavaScriptKind::StarEqual),
    (b"++", JavaScriptKind::PlusPlus),
    (b"+=", JavaScriptKind::PlusEqual),
    (b"--", JavaScriptKind::MinusMinus),
    (b"-=", JavaScriptKind::MinusEqual),
    (b"/=", JavaScriptKind::SlashEqual),
    (b"<<", JavaScriptKind::LessLess),
    (b"<=", JavaScriptKind::LessEqual),
    (b"==", JavaScriptKind::EqualEqual),
    (b"=>", JavaScriptKind::Arrow),
    (b">=", JavaScriptKind::GreaterEqual),
    (b">>", JavaScriptKind::GreaterGreater),
    (b"?.", JavaScriptKind::QuestionDot),
    (b"??", JavaScriptKind::QuestionQuestion),
    (b"^=", JavaScriptKind::CaretEqual),
    (b"|=", JavaScriptKind::BarEqual),
    (b"||", JavaScriptKind::BarBar),
    (b"!", JavaScriptKind::Bang),
    (b"%", JavaScriptKind::Percent),
    (b"&", JavaScriptKind::Ampersand),
    (b"(", JavaScriptKind::ParenOpen),
    (b")", JavaScriptKind::ParenClose),
    (b"*", JavaScriptKind::Star),
    (b"+", JavaScriptKind::Plus),
    (b",", JavaScriptKind::Comma),
    (b"-", JavaScriptKind::Minus),
    (b".", JavaScriptKind::Dot),
    (b"/", JavaScriptKind::Slash),
    (b":", JavaScriptKind::Colon),
    (b";", JavaScriptKind::Semicolon),
    (b"<", JavaScriptKind::Less),
    (b"=", JavaScriptKind::Equal),
    (b">", JavaScriptKind::Greater),
    (b"?", JavaScriptKind::Question),
    (b"@", JavaScriptKind::At),
    (b"[", JavaScriptKind::BracketOpen),
    (b"]", JavaScriptKind::BracketClose),
    (b"^", JavaScriptKind::Caret),
    (b"|", JavaScriptKind::Bar),
    (b"~", JavaScriptKind::Tilde),
];

#[must_use]
pub fn classify(
    source: &[u8],
    tokens: &[Token],
    out: &mut Tokens,
    raw: &mut BoundedVec<JavaScriptKind>,
) -> bool {
    assert!(u32::try_from(tokens.len()).is_ok());

    out.clear();
    raw.clear();

    let mut position = 0;
    let mut previous: Option<JavaScriptKind> = None;

    while position < tokens.len() {
        let token = tokens[position];
        let offset = token.offset as usize;

        if token.kind == TokenKind::String && source.get(offset) == Some(&b'`') {
            if !template::expand(source, token.span(), out, raw) {
                return false;
            }

            previous = Some(JavaScriptKind::TemplateEnd);
            position += 1;

            continue;
        }

        if jsx::opens_at(previous, source, offset) {
            let Some(stop) = jsx::expand(source, offset, out, raw) else {
                return false;
            };

            previous = Some(JavaScriptKind::JsxTagEnd);
            position = past(tokens, position + 1, stop);

            continue;
        }

        let Some(stop) = split(source, token, out, raw, &mut previous) else {
            return false;
        };

        position = past(tokens, position + 1, stop);
    }

    true
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
    out: &mut Tokens,
    raw: &mut BoundedVec<JavaScriptKind>,
    previous: &mut Option<JavaScriptKind>,
) -> Option<usize> {
    let offset = token.offset as usize;
    let end = token.end() as usize;
    let mut cursor = offset;
    let mut stop = offset;

    for _ in 0..=(end - offset) {
        let (kind, reach) = kind_of(source, token.kind, cursor, end);

        if !push(source, out, raw, token.kind, kind, cursor, reach) {
            return None;
        }

        if kind != JavaScriptKind::Comment {
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
    raw: &mut BoundedVec<JavaScriptKind>,
    coarse: TokenKind,
    kind: JavaScriptKind,
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
) -> (JavaScriptKind, usize) {
    let bytes = &source[offset..end];

    match coarse {
        TokenKind::BlockEnd => (JavaScriptKind::BraceClose, end),
        TokenKind::BlockStart => (JavaScriptKind::BraceOpen, end),
        TokenKind::Comment => (JavaScriptKind::Comment, end),
        TokenKind::Newline => (JavaScriptKind::ErrorToken, end),
        TokenKind::Number => (JavaScriptKind::Number, end),
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

fn operator_join(source: &[u8], offset: usize) -> (JavaScriptKind, usize) {
    if source.get(offset..offset + 4) == Some(b">>>=".as_slice()) {
        return (JavaScriptKind::GreaterGreaterGreaterEqual, offset + 4);
    }

    if let Some(kind) = operator_three(source, offset) {
        return (kind, offset + 3);
    }

    if let Some(kind) = operator_two(source, offset) {
        return (kind, offset + 2);
    }

    (operator_one(source, offset), offset + 1)
}

fn operator_three(source: &[u8], offset: usize) -> Option<JavaScriptKind> {
    let kind = match source.get(offset..offset + 3).unwrap_or_default() {
        b"!==" => JavaScriptKind::BangEqualEqual,
        b"&&=" => JavaScriptKind::AmpersandAmpersandEqual,
        b"**=" => JavaScriptKind::StarStarEqual,
        b"..." => JavaScriptKind::DotDotDot,
        b"<<=" => JavaScriptKind::LessLessEqual,
        b"===" => JavaScriptKind::EqualEqualEqual,
        b">>=" => JavaScriptKind::GreaterGreaterEqual,
        b">>>" => JavaScriptKind::GreaterGreaterGreater,
        b"??=" => JavaScriptKind::QuestionQuestionEqual,
        b"||=" => JavaScriptKind::BarBarEqual,
        _ => return None,
    };

    Some(kind)
}

fn operator_two(source: &[u8], offset: usize) -> Option<JavaScriptKind> {
    let kind = match source.get(offset..offset + 2).unwrap_or_default() {
        b"!=" => JavaScriptKind::BangEqual,
        b"%=" => JavaScriptKind::PercentEqual,
        b"&&" => JavaScriptKind::AmpersandAmpersand,
        b"&=" => JavaScriptKind::AmpersandEqual,
        b"**" => JavaScriptKind::StarStar,
        b"*=" => JavaScriptKind::StarEqual,
        b"++" => JavaScriptKind::PlusPlus,
        b"+=" => JavaScriptKind::PlusEqual,
        b"--" => JavaScriptKind::MinusMinus,
        b"-=" => JavaScriptKind::MinusEqual,
        b"/=" => JavaScriptKind::SlashEqual,
        b"<<" => JavaScriptKind::LessLess,
        b"<=" => JavaScriptKind::LessEqual,
        b"==" => JavaScriptKind::EqualEqual,
        b"=>" => JavaScriptKind::Arrow,
        b">=" => JavaScriptKind::GreaterEqual,
        b">>" => JavaScriptKind::GreaterGreater,
        b"?." if !source.get(offset + 2).is_some_and(u8::is_ascii_digit) => {
            JavaScriptKind::QuestionDot
        }
        b"??" => JavaScriptKind::QuestionQuestion,
        b"^=" => JavaScriptKind::CaretEqual,
        b"|=" => JavaScriptKind::BarEqual,
        b"||" => JavaScriptKind::BarBar,
        _ => return None,
    };

    Some(kind)
}

fn operator_one(source: &[u8], offset: usize) -> JavaScriptKind {
    match source.get(offset).copied().unwrap_or(0) {
        b'!' => JavaScriptKind::Bang,
        b'%' => JavaScriptKind::Percent,
        b'&' => JavaScriptKind::Ampersand,
        b'(' => JavaScriptKind::ParenOpen,
        b')' => JavaScriptKind::ParenClose,
        b'*' => JavaScriptKind::Star,
        b'+' => JavaScriptKind::Plus,
        b',' => JavaScriptKind::Comma,
        b'-' => JavaScriptKind::Minus,
        b'.' => JavaScriptKind::Dot,
        b'/' => JavaScriptKind::Slash,
        b':' => JavaScriptKind::Colon,
        b';' => JavaScriptKind::Semicolon,
        b'<' => JavaScriptKind::Less,
        b'=' => JavaScriptKind::Equal,
        b'>' => JavaScriptKind::Greater,
        b'?' => JavaScriptKind::Question,
        b'@' => JavaScriptKind::At,
        b'[' => JavaScriptKind::BracketOpen,
        b']' => JavaScriptKind::BracketClose,
        b'^' => JavaScriptKind::Caret,
        b'|' => JavaScriptKind::Bar,
        b'~' => JavaScriptKind::Tilde,
        _ => JavaScriptKind::ErrorToken,
    }
}

fn string_of(bytes: &[u8]) -> JavaScriptKind {
    match bytes.first() {
        Some(b'/') => JavaScriptKind::Regex,
        Some(b'`') => JavaScriptKind::TemplateChars,
        _ => JavaScriptKind::String,
    }
}

pub(crate) fn word_of(bytes: &[u8]) -> JavaScriptKind {
    if bytes.first() == Some(&b'#') {
        return JavaScriptKind::PrivateIdentifier;
    }

    match bytes {
        b"async" => JavaScriptKind::AsyncKeyword,
        b"await" => JavaScriptKind::AwaitKeyword,
        b"break" => JavaScriptKind::BreakKeyword,
        b"case" => JavaScriptKind::CaseKeyword,
        b"catch" => JavaScriptKind::CatchKeyword,
        b"class" => JavaScriptKind::ClassKeyword,
        b"const" => JavaScriptKind::ConstKeyword,
        b"continue" => JavaScriptKind::ContinueKeyword,
        b"debugger" => JavaScriptKind::DebuggerKeyword,
        b"default" => JavaScriptKind::DefaultKeyword,
        b"delete" => JavaScriptKind::DeleteKeyword,
        b"do" => JavaScriptKind::DoKeyword,
        b"else" => JavaScriptKind::ElseKeyword,
        b"export" => JavaScriptKind::ExportKeyword,
        b"extends" => JavaScriptKind::ExtendsKeyword,
        b"false" => JavaScriptKind::FalseKeyword,
        b"finally" => JavaScriptKind::FinallyKeyword,
        b"for" => JavaScriptKind::ForKeyword,
        b"function" => JavaScriptKind::FunctionKeyword,
        b"if" => JavaScriptKind::IfKeyword,
        b"import" => JavaScriptKind::ImportKeyword,
        b"in" => JavaScriptKind::InKeyword,
        b"instanceof" => JavaScriptKind::InstanceofKeyword,
        b"let" => JavaScriptKind::LetKeyword,
        b"new" => JavaScriptKind::NewKeyword,
        b"null" => JavaScriptKind::NullKeyword,
        b"of" => JavaScriptKind::OfKeyword,
        b"return" => JavaScriptKind::ReturnKeyword,
        b"static" => JavaScriptKind::StaticKeyword,
        b"super" => JavaScriptKind::SuperKeyword,
        b"switch" => JavaScriptKind::SwitchKeyword,
        b"this" => JavaScriptKind::ThisKeyword,
        b"throw" => JavaScriptKind::ThrowKeyword,
        b"true" => JavaScriptKind::TrueKeyword,
        b"try" => JavaScriptKind::TryKeyword,
        b"typeof" => JavaScriptKind::TypeofKeyword,
        b"undefined" => JavaScriptKind::UndefinedKeyword,
        b"var" => JavaScriptKind::VarKeyword,
        b"void" => JavaScriptKind::VoidKeyword,
        b"while" => JavaScriptKind::WhileKeyword,
        b"with" => JavaScriptKind::WithKeyword,
        b"yield" => JavaScriptKind::YieldKeyword,
        _ => JavaScriptKind::Identifier,
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
