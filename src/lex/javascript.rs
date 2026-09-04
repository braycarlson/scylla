use crate::language::Lexer;
use crate::scan::{
    BYTE_ORDER_MARK,
    CLASS_IDENTIFIER_PART,
    CLASSES,
    Numbers,
    identifier_scan,
    is_identifier_part,
    is_identifier_start_at,
    line_scan_trimmed,
    number_scan_bounded,
    punctuation_of,
    string_scan_continued,
    word_in,
};
use crate::token::{Keyword, Lex, Punctuation, TokenKind, Tokens};

pub static JAVASCRIPT: JavaScriptLexer = JavaScriptLexer;
pub static TYPESCRIPT: TypeScriptLexer = TypeScriptLexer;
const ASSERTION_PREFIXES: &[&[u8]] = &[b"assert", b"expect", b"invariant"];
const ESCAPE_BRACED_BYTES_MAX: usize = 8;

const CONTEXTUAL_WORDS: &[&[u8]] = &[
    b"abstract",
    b"async",
    b"declare",
    b"implements",
    b"infer",
    b"is",
    b"keyof",
    b"namespace",
    b"of",
    b"override",
    b"readonly",
    b"satisfies",
    b"static",
    b"type",
];

pub struct JavaScriptLexer;

pub struct TypeScriptLexer;

impl Lexer for JavaScriptLexer {
    fn extensions(&self) -> &'static [&'static [u8]] {
        &[b"cjs", b"js", b"jsx", b"mjs"]
    }

    fn identifier(&self) -> &'static str {
        "javascript"
    }

    fn lex(&self, source: &[u8], tokens: &mut Tokens) -> Lex {
        assert!(u32::try_from(source.len()).is_ok());

        run(source, tokens, false)
    }
}

impl Lexer for TypeScriptLexer {
    fn extensions(&self) -> &'static [&'static [u8]] {
        &[b"cts", b"mts", b"ts", b"tsx"]
    }

    fn identifier(&self) -> &'static str {
        "typescript"
    }

    fn lex(&self, source: &[u8], tokens: &mut Tokens) -> Lex {
        assert!(u32::try_from(source.len()).is_ok());

        run(source, tokens, true)
    }
}

fn run(source: &[u8], tokens: &mut Tokens, typed: bool) -> Lex {
    let mut offset = crate::scan::mark_width(source);
    let mut previous = TokenKind::Newline;

    while offset < source.len() {
        let blank = crate::scan::whitespace_scan(source, offset);

        if blank > offset {
            offset = blank;

            continue;
        }

        let (kind, end) = token_of(source, offset, previous, typed);

        assert!(end > offset);

        if !tokens.push(source, kind, offset, end - offset) {
            return Lex::Truncated;
        }

        let transparent =
            typed && kind == TokenKind::Punctuation(Punctuation::Bang) && divides(previous);

        if kind != TokenKind::Comment && !transparent {
            previous = kind;
        }

        offset = end;
    }

    Lex::Complete
}

pub(crate) fn word_of(text: &[u8], typed: bool) -> Option<TokenKind> {
    if typed {
        let keyword = match text {
            b"abstract" | b"declare" | b"implements" | b"infer" => Keyword::Other,
            b"is" | b"keyof" | b"namespace" | b"override" => Keyword::Other,
            b"readonly" | b"satisfies" | b"type" => Keyword::Other,
            b"enum" | b"interface" => Keyword::Struct,
            _ => return word_base_of(text),
        };

        return Some(TokenKind::Keyword(keyword));
    }

    word_base_of(text)
}

fn word_base_of(text: &[u8]) -> Option<TokenKind> {
    let keyword = match text {
        b"break" => Keyword::Break,
        b"case" | b"switch" => Keyword::Match,
        b"catch" => Keyword::Except,
        b"class" => Keyword::Struct,
        b"const" => Keyword::Constant,
        b"continue" => Keyword::Continue,
        b"do" | b"for" | b"while" => Keyword::Loop,
        b"else" => Keyword::BranchElse,
        b"export" | b"import" => Keyword::Import,
        b"if" => Keyword::Branch,
        b"let" | b"var" => Keyword::Mutable,
        b"return" => Keyword::Return,
        b"try" => Keyword::Try,
        b"async" | b"await" | b"debugger" | b"default" => Keyword::Other,
        b"delete" | b"extends" | b"finally" | b"in" => Keyword::Other,
        b"instanceof" | b"new" | b"of" | b"static" => Keyword::Other,
        b"super" | b"this" | b"throw" | b"typeof" => Keyword::Other,
        b"void" | b"with" | b"yield" => Keyword::Other,
        _ => return None,
    };

    Some(TokenKind::Keyword(keyword))
}

fn opens_an_escape(source: &[u8], offset: usize) -> bool {
    source[offset] == b'\\' && source.get(offset + 1) == Some(&b'u')
}

fn escape_end(source: &[u8], offset: usize) -> usize {
    assert!(opens_an_escape(source, offset));

    let mut cursor = offset + 2;

    if source.get(cursor) == Some(&b'{') {
        let ceiling = source.len().min(cursor + ESCAPE_BRACED_BYTES_MAX);

        while cursor < ceiling && source[cursor] != b'}' {
            cursor += 1;
        }

        return source.len().min(cursor + 1);
    }

    while cursor < source.len() && cursor < offset + 6 && source[cursor].is_ascii_hexdigit() {
        cursor += 1;
    }

    cursor
}

const fn is_identifier_part_dollar(byte: u8) -> bool {
    byte == b'$' || is_identifier_part(byte)
}

fn is_identifier_start_dollar_at(source: &[u8], offset: usize) -> bool {
    assert!(offset <= source.len());

    if source.get(offset) == Some(&b'$') {
        return true;
    }

    is_identifier_start_at(source, offset)
}

fn identifier_escaped_scan(source: &[u8], start: usize) -> usize {
    assert!(is_identifier_start_dollar_at(source, start) || opens_an_escape(source, start));

    let mut offset = start;

    while offset < source.len() {
        let byte = source[offset];

        if byte < 0x80 {
            if byte == b'\\' {
                if source.get(offset + 1) != Some(&b'u') {
                    break;
                }

                offset = escape_end(source, offset);

                continue;
            }

            if !is_identifier_part_dollar(byte) {
                break;
            }

            offset += 1;

            continue;
        }

        if crate::scan::whitespace_width(source, offset) > 0 {
            break;
        }

        offset += 1;
    }

    assert!(offset > start);

    offset
}

fn names_a_member(previous: TokenKind) -> bool {
    previous == TokenKind::Punctuation(Punctuation::Dot)
}

fn names_a_property(source: &[u8], end: usize, previous: TokenKind, text: &[u8]) -> bool {
    if !matches!(
        previous,
        TokenKind::BlockStart
            | TokenKind::BlockEnd
            | TokenKind::Punctuation(Punctuation::Comma | Punctuation::Semicolon)
    ) {
        return false;
    }

    let cursor = space_skip_forward(source, end);
    let optional = source.get(cursor) == Some(&b'?');
    let colon = source.get(cursor + usize::from(optional)) == Some(&b':');

    if !colon {
        return false;
    }

    text != b"default"
}

fn space_skip_forward(source: &[u8], start: usize) -> usize {
    let mut cursor = start;

    while cursor < source.len() && matches!(source[cursor], b' ' | b'\t') {
        cursor += 1;
    }

    cursor
}

fn names_a_binding(previous: TokenKind, text: &[u8]) -> bool {
    matches!(
        previous,
        TokenKind::Keyword(Keyword::Constant | Keyword::Mutable)
    ) && word_in(CONTEXTUAL_WORDS, text)
}

fn function_keyword(source: &[u8], end: usize) -> Keyword {
    let mut offset = end;

    while offset < source.len() && source[offset].is_ascii_whitespace() {
        offset += 1;
    }

    if offset < source.len() && source[offset] == b'*' {
        offset += 1;

        while offset < source.len() && source[offset].is_ascii_whitespace() {
            offset += 1;
        }
    }

    if is_identifier_start_dollar_at(source, offset) {
        return Keyword::Function;
    }

    Keyword::Lambda
}

const fn divides(previous: TokenKind) -> bool {
    matches!(
        previous,
        TokenKind::Identifier
            | TokenKind::Number
            | TokenKind::String
            | TokenKind::Punctuation(Punctuation::ParenClose | Punctuation::BracketClose)
    )
}

const HEAD_BYTES_MAX: usize = 512;
const HEAD_WORDS: &[&[u8]] = &[b"catch", b"for", b"if", b"while", b"with"];

fn divides_at(source: &[u8], start: usize, previous: TokenKind) -> bool {
    assert_eq!(source[start], b'/');

    if follows_increment(source, start) {
        return true;
    }

    if previous != TokenKind::Punctuation(Punctuation::ParenClose) {
        return divides(previous);
    }

    !heads_a_statement(source, start)
}

fn follows_increment(source: &[u8], start: usize) -> bool {
    let cursor = space_skip_back(source, start);

    if cursor < 2 {
        return false;
    }

    matches!(&source[cursor - 2..cursor], b"++" | b"--")
}

fn heads_a_statement(source: &[u8], start: usize) -> bool {
    let close = space_skip_back(source, start);

    if close == 0 || source[close - 1] != b')' {
        return false;
    }

    let floor = close.saturating_sub(HEAD_BYTES_MAX);
    let mut depth = 0_u32;
    let mut offset = close;

    while offset > floor {
        offset -= 1;

        if source[offset] == b')' {
            depth += 1;
        }

        if source[offset] == b'(' {
            depth -= 1;

            if depth == 0 {
                return word_before(source, space_skip_back(source, offset));
            }
        }
    }

    false
}

fn word_before(source: &[u8], end: usize) -> bool {
    if end == 0 || !is_identifier_part_dollar(source[end - 1]) {
        return false;
    }

    let mut start = end;

    while start > 0 && is_identifier_part_dollar(source[start - 1]) {
        start -= 1;
    }

    word_in(HEAD_WORDS, &source[start..end])
}

fn space_skip_back(source: &[u8], start: usize) -> usize {
    let mut cursor = start;

    while cursor > 0 {
        if matches!(source[cursor - 1], b' ' | b'\t') {
            cursor -= 1;

            continue;
        }

        if cursor >= BYTE_ORDER_MARK.len()
            && &source[cursor - BYTE_ORDER_MARK.len()..cursor] == BYTE_ORDER_MARK
        {
            cursor -= BYTE_ORDER_MARK.len();

            continue;
        }

        break;
    }

    cursor
}

fn regex_scan(source: &[u8], start: usize) -> Option<usize> {
    assert_eq!(source[start], b'/');

    let mut offset = start + 1;
    let mut class = false;

    while offset < source.len() {
        let byte = source[offset];

        if matches!(byte, b'\n' | b'\r') {
            return None;
        }

        if byte == b'\\' {
            offset += 2;

            continue;
        }

        if byte == b'[' {
            class = true;
        }

        if byte == b']' {
            class = false;
        }

        if byte == b'/' && !class {
            let flags = offset + 1;

            let lettered = source.get(flags).copied().is_some_and(is_identifier_part)
                && crate::scan::whitespace_width(source, flags) == 0;

            if lettered {
                return Some(identifier_scan(source, flags));
            }

            return Some(flags);
        }

        offset += 1;
    }

    None
}

const REGEX_HEAD_WORDS: &[&[u8]] = &[
    b"await",
    b"case",
    b"delete",
    b"do",
    b"else",
    b"in",
    b"instanceof",
    b"new",
    b"of",
    b"return",
    b"throw",
    b"typeof",
    b"void",
    b"yield",
];

fn divides_before(source: &[u8], offset: usize) -> bool {
    assert_eq!(source[offset], b'/');

    let mut end = offset;

    while end > 0 && source[end - 1].is_ascii_whitespace() {
        end -= 1;
    }

    if end == 0 {
        return false;
    }

    let byte = source[end - 1];

    if matches!(byte, b')' | b']' | b'"' | b'\'' | b'`') {
        return true;
    }

    if !is_identifier_part_dollar(byte) {
        return false;
    }

    let mut start = end;

    while start > 0 && is_identifier_part_dollar(source[start - 1]) {
        start -= 1;
    }

    !word_in(REGEX_HEAD_WORDS, &source[start..end])
}

const TEMPLATE_DEPTH_MAX: usize = 32;
const FRAME_BRACE: u8 = 0;
const FRAME_SUBSTITUTION: u8 = 1;
const FRAME_TEMPLATE: u8 = 2;

fn template_scan(source: &[u8], start: usize) -> usize {
    assert_eq!(source[start], b'`');
    assert!(start < source.len());

    let mut frames = [FRAME_TEMPLATE; TEMPLATE_DEPTH_MAX];
    let mut depth = 1;
    let mut offset = start + 1;

    while offset < source.len() {
        let byte = source[offset];
        let next = source.get(offset + 1).copied();
        let frame = frames[depth - 1];

        if byte == b'\\' {
            offset += 2;

            continue;
        }

        if frame == FRAME_TEMPLATE && byte == b'`' {
            depth -= 1;
            offset += 1;

            if depth == 0 {
                return offset;
            }

            continue;
        }

        if let Some(opened) = frame_opened(frame, byte, next) {
            if depth == TEMPLATE_DEPTH_MAX {
                return source.len();
            }

            frames[depth] = opened;
            depth += 1;
            offset += 1 + usize::from(opened == FRAME_SUBSTITUTION);

            continue;
        }

        if frame == FRAME_TEMPLATE {
            offset += 1;

            continue;
        }

        if byte == b'}' {
            depth -= 1;
            offset += 1;

            assert!(depth > 0);

            continue;
        }

        offset = frame_code_scan(source, offset, next).unwrap_or(offset + 1);
    }

    source.len()
}

const fn frame_opened(frame: u8, byte: u8, next: Option<u8>) -> Option<u8> {
    match (frame, byte, next) {
        (FRAME_TEMPLATE, b'$', Some(b'{')) => Some(FRAME_SUBSTITUTION),
        (FRAME_BRACE | FRAME_SUBSTITUTION, b'{', _) => Some(FRAME_BRACE),
        (FRAME_BRACE | FRAME_SUBSTITUTION, b'`', _) => Some(FRAME_TEMPLATE),
        _ => None,
    }
}

fn frame_code_scan(source: &[u8], offset: usize, next: Option<u8>) -> Option<usize> {
    assert!(offset < source.len());

    let byte = source[offset];

    if matches!(byte, b'"' | b'\'') {
        return Some(string_scan_continued(source, offset, byte));
    }

    if byte != b'/' {
        return None;
    }

    if next == Some(b'/') {
        return Some(line_scan_trimmed(source, offset));
    }

    if next == Some(b'*') {
        return Some(comment_block_scan(source, offset));
    }

    if divides_before(source, offset) {
        return None;
    }

    regex_scan(source, offset)
}

fn comment_block_scan(source: &[u8], start: usize) -> usize {
    assert_eq!(source[start], b'/');

    let mut offset = start + 2;

    while offset + 1 < source.len() {
        if source[offset] == b'*' && source[offset + 1] == b'/' {
            return offset + 2;
        }

        offset += 1;
    }

    source.len()
}

fn is_assertion(text: &[u8], source: &[u8], end: usize) -> bool {
    if !ASSERTION_PREFIXES
        .iter()
        .any(|prefix| names_an_assertion(text, prefix))
    {
        return false;
    }

    let mut offset = end;

    while offset < source.len() && source[offset] == b' ' {
        offset += 1;
    }

    source.get(offset) == Some(&b'(')
}

fn names_an_assertion(text: &[u8], prefix: &[u8]) -> bool {
    assert!(!prefix.is_empty());

    text.starts_with(prefix)
        && !text[prefix.len()..]
            .first()
            .is_some_and(u8::is_ascii_lowercase)
}

fn opens_a_line(source: &[u8], start: usize) -> bool {
    let mark = crate::scan::mark_width(source);
    let mut cursor = start;

    while cursor > mark {
        let byte = source[cursor - 1];

        if matches!(byte, b'\n' | b'\r') {
            return true;
        }

        if !byte.is_ascii_whitespace() {
            return false;
        }

        cursor -= 1;
    }

    true
}

fn identifier_token_of(
    source: &[u8],
    offset: usize,
    previous: TokenKind,
    typed: bool,
) -> (TokenKind, usize) {
    assert!(offset < source.len());

    let end = identifier_escaped_scan(source, offset);
    let text = &source[offset..end];

    assert!(end > offset);

    if is_assertion(text, source, end) {
        return (TokenKind::Keyword(Keyword::Assert), end);
    }

    if names_a_member(previous)
        || names_a_binding(previous, text)
        || names_a_property(source, end, previous, text)
    {
        return (TokenKind::Identifier, end);
    }

    if text == b"function" {
        return (TokenKind::Keyword(function_keyword(source, end)), end);
    }

    match word_of(text, typed) {
        Some(kind) => (kind, end),
        None => (TokenKind::Identifier, end),
    }
}

pub(crate) fn token_at(source: &[u8], offset: usize, previous: TokenKind) -> (TokenKind, usize) {
    token_of(source, offset, previous, false)
}

fn token_of(source: &[u8], offset: usize, previous: TokenKind, typed: bool) -> (TokenKind, usize) {
    assert!(offset < source.len());

    let byte = source[offset];

    if byte < 0x80 && CLASSES[byte as usize] & CLASS_IDENTIFIER_PART != 0 {
        if byte.is_ascii_digit() {
            return (
                TokenKind::Number,
                number_scan_bounded(source, offset, Numbers::ONE_SIDED),
            );
        }

        return identifier_token_of(source, offset, previous, typed);
    }

    let next = source.get(offset + 1).copied();

    if let Some(found) = comment_token_of(source, offset, previous, next) {
        return found;
    }

    if let Some(found) = quote_token_of(source, offset) {
        return found;
    }

    if byte == b'{' {
        return (TokenKind::BlockStart, offset + 1);
    }

    if byte == b'}' {
        return (TokenKind::BlockEnd, offset + 1);
    }

    if byte == b'#' && next == Some(b'!') && offset == 0 {
        return (TokenKind::Comment, line_scan_trimmed(source, offset));
    }

    if byte == b'#' && is_identifier_start_dollar_at(source, offset + 1) {
        return (
            TokenKind::Identifier,
            identifier_escaped_scan(source, offset + 1),
        );
    }

    if is_identifier_start_dollar_at(source, offset) || opens_an_escape(source, offset) {
        return identifier_token_of(source, offset, previous, typed);
    }

    if byte == b'.' && source[offset..].starts_with(b"...") {
        return (TokenKind::Punctuation(Punctuation::Other), offset + 3);
    }

    let leads = byte == b'.' && source.get(offset + 1).is_some_and(u8::is_ascii_digit);

    if byte.is_ascii_digit() || leads {
        return (
            TokenKind::Number,
            number_scan_bounded(source, offset, Numbers::ONE_SIDED),
        );
    }

    let (punctuation, length) = punctuation_of(source, offset);

    (TokenKind::Punctuation(punctuation), offset + length)
}

fn comment_token_of(
    source: &[u8],
    offset: usize,
    previous: TokenKind,
    next: Option<u8>,
) -> Option<(TokenKind, usize)> {
    assert!(offset < source.len());

    let byte = source[offset];

    if byte == b'<' && source[offset..].starts_with(b"<!--") {
        return Some((TokenKind::Comment, line_scan_trimmed(source, offset)));
    }

    if byte == b'-' && source[offset..].starts_with(b"-->") && opens_a_line(source, offset) {
        return Some((TokenKind::Comment, line_scan_trimmed(source, offset)));
    }

    if byte != b'/' {
        return None;
    }

    if next == Some(b'/') {
        return Some((TokenKind::Comment, line_scan_trimmed(source, offset)));
    }

    if next == Some(b'*') {
        return Some((TokenKind::Comment, comment_block_scan(source, offset)));
    }

    if offset > 0 && source[offset - 1] == b'<' {
        let (punctuation, length) = punctuation_of(source, offset);

        return Some((TokenKind::Punctuation(punctuation), offset + length));
    }

    if divides_at(source, offset, previous) {
        return None;
    }

    let end = regex_scan(source, offset)?;

    assert!(end > offset + 1);

    Some((TokenKind::String, end))
}

fn quote_token_of(source: &[u8], offset: usize) -> Option<(TokenKind, usize)> {
    assert!(offset < source.len());

    let byte = source[offset];

    if byte == b'"' || byte == b'\'' {
        return Some((
            TokenKind::String,
            string_scan_continued(source, offset, byte),
        ));
    }

    if byte == b'`' {
        return Some((TokenKind::String, template_scan(source, offset)));
    }

    None
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::lex::tests_support;

    #[test]
    fn an_escape_opens_only_on_a_backslash_and_a_u() {
        assert!(opens_an_escape(b"\\u0041", 0));
        assert!(!opens_an_escape(b"\\n", 0));
        assert!(!opens_an_escape(b"u0041", 0));
        assert!(!opens_an_escape(b"\\", 0));
        assert!(opens_an_escape(b"a\\u0041", 1));
    }

    #[test]
    fn an_escape_ends_where_its_form_says() {
        assert_eq!(escape_end(b"\\u0041x", 0), 6);
        assert_eq!(escape_end(b"\\u0041", 0), 6);
        assert_eq!(escape_end(b"\\u00", 0), 4);
        assert_eq!(escape_end(b"\\uZZZZ", 0), 2);
        assert_eq!(escape_end(b"\\u00412", 0), 6);
        assert_eq!(escape_end(b"\\u{41}x", 0), 6);
        assert_eq!(escape_end(b"\\u{1F600}", 0), 9);
        assert_eq!(escape_end(b"\\u{41", 0), 5);
        assert_eq!(escape_end(b"a\\u0041", 1), 7);
    }

    #[test]
    fn a_braced_escape_stops_at_the_cap_rather_than_scanning_the_file() {
        assert_eq!(escape_end(b"\\u{0000000000}", 0), 11);
        assert_eq!(escape_end(b"\\u{000000}", 0), 10);
        assert_eq!(escape_end(b"\\u{00000000", 0), 11);
    }

    #[test]
    fn a_blank_run_forward_stops_at_the_first_byte_that_is_not_a_space() {
        assert_eq!(space_skip_forward(b"   x", 0), 3);
        assert_eq!(space_skip_forward(b"\t \tx", 0), 3);
        assert_eq!(space_skip_forward(b"x  ", 0), 0);
        assert_eq!(space_skip_forward(b"   ", 0), 3);
        assert_eq!(space_skip_forward(b"", 0), 0);
        assert_eq!(space_skip_forward(b"a  b", 1), 3);
        assert_eq!(space_skip_forward(b" \n ", 0), 1);
    }

    #[test]
    fn an_increment_is_read_only_where_two_bytes_stand_for_it() {
        assert!(follows_increment(b"a++", 3));
        assert!(follows_increment(b"a-- ", 4));
        assert!(!follows_increment(b"++", 1));
        assert!(!follows_increment(b"a+", 2));
        assert!(!follows_increment(b"", 0));
        assert!(!follows_increment(b"a+-", 3));
        assert!(follows_increment(b"++", 2));
        assert!(follows_increment(b"--", 2));
    }

    #[test]
    fn a_head_word_is_the_one_directly_before_the_parentheses() {
        assert!(word_before(b"if", 2));
        assert!(word_before(b"while", 5));
        assert!(word_before(b"catch", 5));
        assert!(!word_before(b"", 0));
        assert!(!word_before(b"if(", 3));
        assert!(!word_before(b"xif", 3));
        assert!(!word_before(b"function", 8));
        assert!(word_before(b"} if", 4));
    }

    #[test]
    fn a_statement_head_needs_its_own_word_before_its_own_parentheses() {
        assert!(heads_a_statement(b"if (a) ", 7));
        assert!(heads_a_statement(b"while (a(b)) ", 13));
        assert!(!heads_a_statement(b"foo(a) ", 7));
        assert!(!heads_a_statement(b"", 0));
        assert!(!heads_a_statement(b"if a ", 5));
        assert!(!heads_a_statement(b"(a) ", 4));
        assert!(!heads_a_statement(b") ", 2));
        assert!(!heads_a_statement(b"a) ", 3));
    }

    fn kinds(source: &'static [u8]) -> Vec<TokenKind> {
        tests_support::lex(&JAVASCRIPT, source)
            .iter()
            .map(|token| token.kind)
            .collect()
    }

    #[test]
    fn a_slash_behind_a_tag_and_a_comment_close_are_read_as_themselves() {
        assert!(
            !kinds(b"const a = <b></b>;\n").contains(&TokenKind::String),
            "the closing tag opened a regex"
        );

        assert!(
            kinds(b"<!-- a -->\nconst b = 1;\n").starts_with(&[TokenKind::Comment]),
            "the opening comment was not a comment"
        );

        assert!(
            kinds(b"--> a\n").starts_with(&[TokenKind::Comment]),
            "the closing comment at the line start was not a comment"
        );

        assert!(
            !kinds(b"const a = b - c;\n").contains(&TokenKind::Comment),
            "a subtraction became a comment"
        );

        assert!(
            !kinds(b"const a = b --> c;\n").contains(&TokenKind::Comment),
            "a decrement mid-line became a comment"
        );
    }

    #[test]
    fn a_template_closes_past_its_nested_frames() {
        assert_eq!(template_scan(b"`a`x", 0), 3);
        assert_eq!(template_scan(b"`a${b}c`x", 0), 8);
        assert_eq!(template_scan(b"`a${`b`}c`x", 0), 10);
        assert_eq!(template_scan(b"`a${{b: 1}}c`x", 0), 13);
        assert_eq!(template_scan(b"`a${\"`\"}c`x", 0), 10);
        assert_eq!(template_scan(b"`a${'`'}c`x", 0), 10);
        assert_eq!(template_scan(b"`a\\`b`x", 0), 6);
        assert_eq!(template_scan(b"`a", 0), 2);
    }

    #[test]
    fn a_line_is_open_only_when_nothing_but_blanks_stands_before_it() {
        assert!(opens_a_line(b"", 0));
        assert!(opens_a_line(b"  x", 2));
        assert!(opens_a_line(b"a\n  x", 4));
        assert!(opens_a_line(b"\nx", 1));
        assert!(!opens_a_line(b"a x", 2));
        assert!(!opens_a_line(b"ax", 2));
    }

    const KEYWORDS: &[(&str, &str, TokenKind)] = &[
        (
            "async",
            "async function run() {}\n",
            TokenKind::Keyword(Keyword::Other),
        ),
        (
            "await",
            "async function run() {\n    await ready();\n}\n",
            TokenKind::Keyword(Keyword::Other),
        ),
        (
            "break",
            "function run() {\n    while (true) {\n        break;\n    }\n}\n",
            TokenKind::Keyword(Keyword::Break),
        ),
        (
            "case",
            "function run(value) {\n    switch (value) {\n    case 1:\n        break;\n    }\n}\n",
            TokenKind::Keyword(Keyword::Match),
        ),
        (
            "catch",
            "function run() {\n    try {\n    } catch (failure) {\n    }\n}\n",
            TokenKind::Keyword(Keyword::Except),
        ),
        (
            "class",
            "class Store {}\n",
            TokenKind::Keyword(Keyword::Struct),
        ),
        (
            "const",
            "const value = 1;\n",
            TokenKind::Keyword(Keyword::Constant),
        ),
        (
            "continue",
            "function run() {\n    while (true) {\n        continue;\n    }\n}\n",
            TokenKind::Keyword(Keyword::Continue),
        ),
        (
            "debugger",
            "function run() {\n    debugger;\n}\n",
            TokenKind::Keyword(Keyword::Other),
        ),
        (
            "default",
            "export default run;\n",
            TokenKind::Keyword(Keyword::Other),
        ),
        (
            "delete",
            "function run(store) {\n    delete store.value;\n}\n",
            TokenKind::Keyword(Keyword::Other),
        ),
        (
            "do",
            "function run() {\n    do {\n    } while (false);\n}\n",
            TokenKind::Keyword(Keyword::Loop),
        ),
        (
            "else",
            "function run(value) {\n    if (value) {\n    } else {\n    }\n}\n",
            TokenKind::Keyword(Keyword::BranchElse),
        ),
        (
            "export",
            "export const value = 1;\n",
            TokenKind::Keyword(Keyword::Import),
        ),
        (
            "extends",
            "class Store extends Base {}\n",
            TokenKind::Keyword(Keyword::Other),
        ),
        (
            "finally",
            "function run() {\n    try {\n    } finally {\n    }\n}\n",
            TokenKind::Keyword(Keyword::Other),
        ),
        (
            "for",
            "function run() {\n    for (;;) {\n    }\n}\n",
            TokenKind::Keyword(Keyword::Loop),
        ),
        (
            "function",
            "function run() {}\n",
            TokenKind::Keyword(Keyword::Function),
        ),
        (
            "if",
            "function run(value) {\n    if (value) {\n    }\n}\n",
            TokenKind::Keyword(Keyword::Branch),
        ),
        (
            "import",
            "import store from \"./store.js\";\n",
            TokenKind::Keyword(Keyword::Import),
        ),
        (
            "in",
            "function run(store) {\n    for (const key in store) {\n    }\n}\n",
            TokenKind::Keyword(Keyword::Other),
        ),
        (
            "instanceof",
            "function run(value) {\n    return value instanceof Store;\n}\n",
            TokenKind::Keyword(Keyword::Other),
        ),
        (
            "let",
            "function run() {\n    let value = 1;\n}\n",
            TokenKind::Keyword(Keyword::Mutable),
        ),
        (
            "new",
            "function run() {\n    return new Store();\n}\n",
            TokenKind::Keyword(Keyword::Other),
        ),
        (
            "of",
            "function run(values) {\n    for (const value of values) {\n    }\n}\n",
            TokenKind::Keyword(Keyword::Other),
        ),
        (
            "return",
            "function run() {\n    return 1;\n}\n",
            TokenKind::Keyword(Keyword::Return),
        ),
        (
            "static",
            "class Store {\n    static value = 1;\n}\n",
            TokenKind::Keyword(Keyword::Other),
        ),
        (
            "super",
            "class Store extends Base {\n    constructor() {\n        super();\n    }\n}\n",
            TokenKind::Keyword(Keyword::Other),
        ),
        (
            "switch",
            "function run(value) {\n    switch (value) {\n    }\n}\n",
            TokenKind::Keyword(Keyword::Match),
        ),
        (
            "this",
            "class Store {\n    read() {\n        return this.value;\n    }\n}\n",
            TokenKind::Keyword(Keyword::Other),
        ),
        (
            "throw",
            "function run() {\n    throw new Error(\"no\");\n}\n",
            TokenKind::Keyword(Keyword::Other),
        ),
        (
            "try",
            "function run() {\n    try {\n    } catch (failure) {\n    }\n}\n",
            TokenKind::Keyword(Keyword::Try),
        ),
        (
            "typeof",
            "function run(value) {\n    return typeof value;\n}\n",
            TokenKind::Keyword(Keyword::Other),
        ),
        (
            "var",
            "function run() {\n    var value = 1;\n}\n",
            TokenKind::Keyword(Keyword::Mutable),
        ),
        (
            "void",
            "function run() {\n    void 0;\n}\n",
            TokenKind::Keyword(Keyword::Other),
        ),
        (
            "while",
            "function run() {\n    while (false) {\n    }\n}\n",
            TokenKind::Keyword(Keyword::Loop),
        ),
        (
            "with",
            "function run(store) {\n    with (store) {\n    }\n}\n",
            TokenKind::Keyword(Keyword::Other),
        ),
        (
            "yield",
            "function* run() {\n    yield 1;\n}\n",
            TokenKind::Keyword(Keyword::Other),
        ),
    ];

    const TYPED_KEYWORDS: &[(&str, &str, TokenKind)] = &[
        (
            "abstract",
            "abstract class Store {}\n",
            TokenKind::Keyword(Keyword::Other),
        ),
        (
            "declare",
            "declare const value: number;\n",
            TokenKind::Keyword(Keyword::Other),
        ),
        (
            "enum",
            "enum Colour {\n    Red,\n}\n",
            TokenKind::Keyword(Keyword::Struct),
        ),
        (
            "implements",
            "class Store implements Reader {}\n",
            TokenKind::Keyword(Keyword::Other),
        ),
        (
            "infer",
            "type Held<T> = T extends Box<infer U> ? U : never;\n",
            TokenKind::Keyword(Keyword::Other),
        ),
        (
            "interface",
            "interface Reader {\n    read(): number;\n}\n",
            TokenKind::Keyword(Keyword::Struct),
        ),
        (
            "is",
            "function isStore(value: unknown): value is Store {\n    return true;\n}\n",
            TokenKind::Keyword(Keyword::Other),
        ),
        (
            "keyof",
            "type Keys = keyof Store;\n",
            TokenKind::Keyword(Keyword::Other),
        ),
        (
            "namespace",
            "namespace store {\n}\n",
            TokenKind::Keyword(Keyword::Other),
        ),
        (
            "override",
            "class Store extends Base {\n    override read(): number {\n        return 1;\n    \
             }\n}\n",
            TokenKind::Keyword(Keyword::Other),
        ),
        (
            "readonly",
            "interface Reader {\n    readonly value: number;\n}\n",
            TokenKind::Keyword(Keyword::Other),
        ),
        (
            "satisfies",
            "const value = 1 satisfies number;\n",
            TokenKind::Keyword(Keyword::Other),
        ),
        (
            "type",
            "type Value = number;\n",
            TokenKind::Keyword(Keyword::Other),
        ),
    ];

    fn spans(source: &str) -> Vec<(TokenKind, String)> {
        let bytes = source.as_bytes();

        tests_support::lex(&JAVASCRIPT, bytes)
            .iter()
            .map(|token| {
                (
                    token.kind,
                    String::from_utf8_lossy(token.text(bytes)).into_owned(),
                )
            })
            .collect()
    }

    fn first_of(source: &str, kind: TokenKind) -> String {
        spans(source)
            .into_iter()
            .find(|(found, _)| *found == kind)
            .unwrap_or_else(|| panic!("{source:?} carries a {kind:?} token"))
            .1
    }

    #[test]
    fn every_keyword_of_the_specification_lexes_to_its_kind() {
        for (word, source, expected) in KEYWORDS {
            assert_eq!(
                tests_support::kind_of(&JAVASCRIPT, source, word),
                *expected,
                "{word}"
            );
        }
    }

    #[test]
    fn every_typed_keyword_of_the_specification_lexes_to_its_kind() {
        for (word, source, expected) in TYPED_KEYWORDS {
            assert_eq!(
                tests_support::kind_of(&TYPESCRIPT, source, word),
                *expected,
                "{word}"
            );
        }
    }

    #[test]
    fn a_typed_keyword_is_an_identifier_in_javascript() {
        for (word, source, _) in TYPED_KEYWORDS {
            if *word == "enum" || *word == "interface" {
                continue;
            }

            assert_eq!(
                tests_support::kind_of(&JAVASCRIPT, source, word),
                TokenKind::Identifier,
                "{word}"
            );
        }
    }

    const TEMPLATES: &[(&str, &str)] = &[
        ("const value = `plain`;\n", "`plain`"),
        ("const value = `a${b}c`;\n", "`a${b}c`"),
        ("const value = `a${`inner`}c`;\n", "`a${`inner`}c`"),
        ("const value = `a${ { b: 1 } }c`;\n", "`a${ { b: 1 } }c`"),
        ("const value = `a\\`b`;\n", "`a\\`b`"),
        ("const value = `line\nbreak`;\n", "`line\nbreak`"),
        ("const value = `${a}${b}`;\n", "`${a}${b}`"),
        ("const value = `a$b`;\n", "`a$b`"),
        ("const value = `a{b}c`;\n", "`a{b}c`"),
        ("const value = `a}b`;\n", "`a}b`"),
        ("const value = `${`${a}`}`;\n", "`${`${a}`}`"),
        ("const value = `${ { a: 1 } }`;\n", "`${ { a: 1 } }`"),
    ];

    #[test]
    fn every_template_shape_lexes_to_one_string() {
        for (source, expected) in TEMPLATES {
            assert_eq!(first_of(source, TokenKind::String), *expected, "{source:?}");
        }
    }

    #[test]
    fn an_unterminated_template_runs_to_the_end() {
        assert_eq!(
            first_of("const value = `open;\n", TokenKind::String),
            "`open;\n"
        );
    }

    const REGEXES: &[(&str, &str)] = &[
        ("const found = /ab+c/;\n", "/ab+c/"),
        ("const found = /ab+c/gi;\n", "/ab+c/gi"),
        ("const found = /a\\/b/;\n", "/a\\/b/"),
        ("const found = /[/]/;\n", "/[/]/"),
        ("const found = /[a-z]+/u;\n", "/[a-z]+/u"),
        ("const found = value.replace(/a/, \"b\");\n", "/a/"),
    ];

    #[test]
    fn every_regular_expression_shape_lexes_to_one_string() {
        for (source, expected) in REGEXES {
            assert_eq!(first_of(source, TokenKind::String), *expected, "{source:?}");
        }
    }

    #[test]
    fn a_division_is_not_a_regular_expression() {
        let source = "const share = total / count;\n";

        let found = spans(source)
            .into_iter()
            .find(|(kind, _)| *kind == TokenKind::String);

        assert!(found.is_none(), "{found:?}");

        assert_eq!(
            tests_support::kind_of(&JAVASCRIPT, source, "/"),
            TokenKind::Punctuation(Punctuation::Slash)
        );
    }

    #[test]
    fn a_second_division_on_the_line_is_still_a_division() {
        let source = "const share = total / count / 2;\n";

        let found = spans(source)
            .into_iter()
            .find(|(kind, _)| *kind == TokenKind::String);

        assert!(found.is_none(), "{found:?}");
    }

    #[test]
    fn a_slash_that_never_closes_is_a_division() {
        assert_eq!(
            tests_support::kind_of(&JAVASCRIPT, "const found = /open;\n", "/"),
            TokenKind::Punctuation(Punctuation::Slash)
        );
    }

    #[test]
    fn a_slash_that_opens_the_source_is_a_regular_expression_that_never_closes() {
        for source in ["/", "/\n", "/a"] {
            let bytes = source.as_bytes();
            let tokens = tests_support::lex(&JAVASCRIPT, bytes);

            assert_eq!(tokens[0].kind, TokenKind::Punctuation(Punctuation::Slash));
        }
    }

    #[test]
    fn a_slash_at_the_end_of_the_source_is_a_division() {
        assert_eq!(
            tests_support::kind_of(&JAVASCRIPT, "const found = /", "/"),
            TokenKind::Punctuation(Punctuation::Slash)
        );
    }

    const COMMENTS: &[(&str, &str)] = &[
        ("/* note */\nconst value = 1;\n", "/* note */"),
        ("/**/\nconst value = 1;\n", "/**/"),
        ("/* a\n   b */\nconst value = 1;\n", "/* a\n   b */"),
        ("/* a * b */\nconst value = 1;\n", "/* a * b */"),
        ("// note\nconst value = 1;\n", "// note"),
        ("const value = 1; /* note */\n", "/* note */"),
        ("const value = 1; /* a */ const other = 2;\n", "/* a */"),
    ];

    #[test]
    fn every_comment_shape_lexes_to_one_comment() {
        for (source, expected) in COMMENTS {
            assert_eq!(
                first_of(source, TokenKind::Comment),
                *expected,
                "{source:?}"
            );
        }
    }

    #[test]
    fn an_unterminated_block_comment_runs_to_the_end() {
        for source in ["/* open\n", "/* open*", "/* open", "/*", "/*/"] {
            assert_eq!(first_of(source, TokenKind::Comment), *source, "{source:?}");
        }
    }

    #[test]
    fn an_unterminated_string_runs_to_the_end_of_the_line() {
        assert_eq!(
            first_of(
                "const value = \"open\nconst other = 1;\n",
                TokenKind::String
            ),
            "\"open"
        );

        assert_eq!(
            first_of("const value = 'open\nconst other = 1;\n", TokenKind::String),
            "'open"
        );
    }

    #[test]
    fn an_unterminated_string_at_the_end_of_the_source_stops_there() {
        assert_eq!(
            first_of("const value = \"open", TokenKind::String),
            "\"open"
        );
    }

    const FUNCTION_WORDS: &[(&str, Keyword)] = &[
        ("function run() {}\n", Keyword::Function),
        ("const run = function () {};\n", Keyword::Lambda),
        ("function* run() {}\n", Keyword::Function),
        ("const run = function* () {};\n", Keyword::Lambda),
        ("function  run() {}\n", Keyword::Function),
        ("function *run() {}\n", Keyword::Function),
        ("const run = function*() {};\n", Keyword::Lambda),
    ];

    #[test]
    fn a_named_function_is_a_function_and_an_anonymous_one_is_a_lambda() {
        for (source, expected) in FUNCTION_WORDS {
            assert_eq!(
                tests_support::kind_of(&JAVASCRIPT, source, "function"),
                TokenKind::Keyword(*expected),
                "{source:?}"
            );
        }
    }

    #[test]
    fn the_function_word_at_the_end_of_the_source_is_a_lambda() {
        for source in [
            "const run = function",
            "const run = function ",
            "const run = function*",
            "const run = function* ",
        ] {
            assert_eq!(
                tests_support::kind_of(&JAVASCRIPT, source, "function"),
                TokenKind::Keyword(Keyword::Lambda),
                "{source:?}"
            );
        }
    }

    const ASSERTIONS: &[(&str, &str, TokenKind)] = &[
        (
            "assert",
            "function f(v) {\n    assert(v);\n}\n",
            TokenKind::Keyword(Keyword::Assert),
        ),
        (
            "assert",
            "function f(v) {\n    assert (v);\n}\n",
            TokenKind::Keyword(Keyword::Assert),
        ),
        (
            "assertEqual",
            "function f(v) {\n    assertEqual(v, 1);\n}\n",
            TokenKind::Keyword(Keyword::Assert),
        ),
        (
            "expect",
            "function f(v) {\n    expect(v).toBe(1);\n}\n",
            TokenKind::Keyword(Keyword::Assert),
        ),
        (
            "invariant",
            "function f(v) {\n    invariant(v);\n}\n",
            TokenKind::Keyword(Keyword::Assert),
        ),
        (
            "assert",
            "function f(v) {\n    const assert = v;\n}\n",
            TokenKind::Identifier,
        ),
        (
            "assured",
            "function f(v) {\n    assured(v);\n}\n",
            TokenKind::Identifier,
        ),
        (
            "expect",
            "function f(v) {\n    expect\n        .anything();\n}\n",
            TokenKind::Identifier,
        ),
    ];

    #[test]
    fn an_assertion_word_needs_a_call_to_be_a_keyword() {
        for (word, source, expected) in ASSERTIONS {
            assert_eq!(
                tests_support::kind_of(&JAVASCRIPT, source, word),
                *expected,
                "{source:?}"
            );
        }
    }

    #[test]
    fn an_assertion_word_at_the_end_of_the_source_is_an_identifier() {
        assert_eq!(
            tests_support::kind_of(&JAVASCRIPT, "assert", "assert"),
            TokenKind::Identifier
        );
    }

    #[test]
    fn a_backslash_carries_a_string_over_the_newline() {
        assert_eq!(
            first_of("const plain = 'a\\\nb';\n", TokenKind::String),
            "'a\\\nb'"
        );

        assert_eq!(
            first_of("const plain = 'a\nconst other = 1;\n", TokenKind::String),
            "'a"
        );
    }

    #[test]
    fn a_substitution_holding_an_object_does_not_close_its_template() {
        assert_eq!(
            first_of("const t = `${f({ a: 1 }, `b`)}`;\n", TokenKind::String),
            "`${f({ a: 1 }, `b`)}`"
        );

        assert_eq!(
            first_of(
                "const t = `${items.map((i) => { return i; })}`;\n",
                TokenKind::String
            ),
            "`${items.map((i) => { return i; })}`"
        );
    }

    #[test]
    fn a_quote_inside_a_substitution_does_not_leak() {
        assert_eq!(
            first_of("const t = `${x[\"a\"]}` + 1;\n", TokenKind::String),
            "`${x[\"a\"]}`"
        );
    }

    #[test]
    fn an_increment_leaves_the_slash_after_it_a_division() {
        let source = "const share = sent++ / total * 100 / 2;\n";
        let tokens = spans(source);

        assert!(
            tokens.iter().all(|(kind, _)| *kind != TokenKind::String),
            "{tokens:?}"
        );
    }

    #[test]
    fn a_regular_expression_after_a_statement_head_is_not_a_division() {
        assert_eq!(
            first_of(
                "function f(ok, s) { if (ok) /['\"]/.test(s); }\n",
                TokenKind::String
            ),
            "/['\"]/"
        );
    }

    #[test]
    fn a_call_result_divided_is_still_a_division() {
        let source = "const half = size(a) / 2;\n";
        let tokens = spans(source);

        assert!(
            tokens.iter().all(|(kind, _)| *kind != TokenKind::String),
            "{tokens:?}"
        );
    }

    #[test]
    fn a_member_name_is_not_a_keyword() {
        assert_eq!(
            tests_support::kind_of(&JAVASCRIPT, "cache.delete(key);\n", "delete"),
            TokenKind::Identifier
        );

        assert_eq!(
            tests_support::kind_of(&JAVASCRIPT, "task.catch(onFailure);\n", "catch"),
            TokenKind::Identifier
        );
    }

    #[test]
    fn a_contextual_keyword_bound_to_a_name_is_a_name() {
        assert_eq!(
            tests_support::kind_of(&TYPESCRIPT, "const type = \"click\";\n", "type"),
            TokenKind::Identifier
        );

        assert_eq!(
            tests_support::kind_of(&TYPESCRIPT, "type Handler = () => void;\n", "type"),
            TokenKind::Keyword(Keyword::Other)
        );

        assert_eq!(
            tests_support::kind_of(&TYPESCRIPT, "const enum Mode {}\n", "enum"),
            TokenKind::Keyword(Keyword::Struct)
        );
    }

    #[test]
    fn an_assertion_prefix_does_not_swallow_a_longer_word() {
        assert_eq!(
            tests_support::kind_of(&JAVASCRIPT, "expectations(rows);\n", "expectations"),
            TokenKind::Identifier
        );

        assert_eq!(
            tests_support::kind_of(&JAVASCRIPT, "expectThat(rows);\n", "expectThat"),
            TokenKind::Keyword(Keyword::Assert)
        );

        assert_eq!(
            tests_support::kind_of(&JAVASCRIPT, "assert_eq(a, b);\n", "assert_eq"),
            TokenKind::Keyword(Keyword::Assert)
        );
    }

    #[test]
    fn a_reserved_word_is_a_key_where_a_key_belongs() {
        for source in [
            "const options = { continue: false };\n",
            "const options = { code: 1, continue: false };\n",
            "interface Options {\n    if?: string;\n}\n",
            "const options = { case: \"sensitive\" };\n",
        ] {
            let word = source
                .split_whitespace()
                .find(|word| word.ends_with(':') || word.ends_with("?:"))
                .expect("the key is a word")
                .trim_end_matches(&[':', '?'][..]);

            assert_eq!(
                tests_support::kind_of(&TYPESCRIPT, source, word),
                TokenKind::Identifier,
                "{source:?}"
            );
        }
    }

    #[test]
    fn a_switch_keeps_its_clause_words() {
        let source = "function f(v) {\n    switch (v) {\n    case 1:\n        break;\n    \
                      default:\n        break;\n    }\n}\n";

        assert_eq!(
            tests_support::kind_of(&JAVASCRIPT, source, "case"),
            TokenKind::Keyword(Keyword::Match)
        );

        assert_eq!(
            tests_support::kind_of(&JAVASCRIPT, source, "default"),
            TokenKind::Keyword(Keyword::Other)
        );
    }

    #[test]
    fn a_spread_is_one_token_rather_than_three_dots() {
        assert_eq!(
            tests_support::kind_of(&JAVASCRIPT, "const all = [...new Set(paths)];\n", "new"),
            TokenKind::Keyword(Keyword::Other)
        );

        assert_eq!(
            first_of(
                "const all = [...rest];\n",
                TokenKind::Punctuation(Punctuation::Other)
            ),
            "..."
        );
    }

    #[test]
    fn an_html_like_comment_is_a_comment() {
        assert_eq!(
            first_of("<!-- a comment\nconst value = 1;\n", TokenKind::Comment),
            "<!-- a comment"
        );

        assert_eq!(
            first_of("--> a comment\nconst value = 1;\n", TokenKind::Comment),
            "--> a comment"
        );
    }

    #[test]
    fn a_byte_order_mark_is_whitespace_to_the_scans_that_walk_back_over_it() {
        assert_eq!(
            first_of(
                "\u{feff}--> a comment\nconst value = 1;\n",
                TokenKind::Comment
            ),
            "--> a comment"
        );

        assert!(
            !kinds(b"--\xef\xbb\xbf/a/").contains(&TokenKind::String),
            "a mark between the decrement and the slash opened a regex"
        );

        assert!(
            !kinds(b"--/a/").contains(&TokenKind::String),
            "the decrement before the slash opened a regex"
        );
    }

    #[test]
    fn a_line_comment_carries_no_carriage_return_of_the_break_that_ends_it() {
        assert_eq!(first_of("// note\r\r\n", TokenKind::Comment), "// note");
        assert_eq!(first_of("<!--\r\r\n", TokenKind::Comment), "<!--");
        assert_eq!(first_of("// note\r\n", TokenKind::Comment), "// note");
        assert_eq!(first_of("// note\n", TokenKind::Comment), "// note");
    }

    #[test]
    fn every_javascript_and_typescript_extension_is_registered() {
        assert_eq!(
            JAVASCRIPT.extensions(),
            &[&b"cjs"[..], b"js", b"jsx", b"mjs"]
        );

        assert_eq!(
            TYPESCRIPT.extensions(),
            &[&b"cts"[..], b"mts", b"ts", b"tsx"]
        );
    }

    #[test]
    fn a_private_field_lexes_as_one_identifier() {
        assert_eq!(
            tests_support::kind_of(&JAVASCRIPT, "class Store {\n    #value = 1;\n}\n", "#value"),
            TokenKind::Identifier
        );
    }

    #[test]
    fn a_one_sided_dot_float_is_one_number() {
        assert_eq!(first_of("const half = .5;\n", TokenKind::Number), ".5");
        assert_eq!(first_of("const one = 1.;\n", TokenKind::Number), "1.");
    }

    #[test]
    fn a_hexadecimal_literal_keeps_its_subtraction() {
        assert_eq!(
            first_of("const left = 0xCAFE-1;\n", TokenKind::Number),
            "0xCAFE"
        );
    }

    #[test]
    fn a_shebang_is_a_comment_only_at_the_head_of_the_file() {
        assert_eq!(
            first_of("#!/usr/bin/env node\n", TokenKind::Comment),
            "#!/usr/bin/env node"
        );
    }

    fn typed_spans(source: &str) -> Vec<(TokenKind, String)> {
        let bytes = source.as_bytes();

        tests_support::lex(&TYPESCRIPT, bytes)
            .iter()
            .map(|token| {
                (
                    token.kind,
                    String::from_utf8_lossy(token.text(bytes)).into_owned(),
                )
            })
            .collect()
    }

    fn typed_first_of(source: &str, kind: TokenKind) -> String {
        typed_spans(source)
            .into_iter()
            .find(|(found, _)| *found == kind)
            .unwrap_or_else(|| panic!("{source:?} carries a {kind:?} token"))
            .1
    }

    #[test]
    fn a_typescript_bang_is_transparent_to_the_division_that_follows() {
        let source = "const share = total! / count / 2;\n";

        let found = typed_spans(source)
            .into_iter()
            .find(|(kind, _)| *kind == TokenKind::String);

        assert!(found.is_none(), "{found:?}");
    }

    #[test]
    fn a_javascript_bang_is_not_transparent_to_the_division_that_follows() {
        assert_eq!(
            first_of("const share = total! / count / 2;\n", TokenKind::String),
            "/ count /"
        );
    }

    #[test]
    fn a_comment_between_a_value_and_a_slash_keeps_the_division() {
        let source = "const share = total /* note */ / count / 2;\n";

        let found = spans(source)
            .into_iter()
            .find(|(kind, _)| *kind == TokenKind::String);

        assert!(found.is_none(), "{found:?}");
    }

    #[test]
    fn a_slash_after_a_keyword_opens_a_regular_expression() {
        assert_eq!(
            first_of("function run() {\n    return /a/;\n}\n", TokenKind::String),
            "/a/"
        );
    }

    #[test]
    fn a_typescript_bang_is_transparent_to_the_regular_expression_scan() {
        assert_eq!(
            typed_first_of(
                "const found = value!.replace(/a/, \"b\");\n",
                TokenKind::String
            ),
            "/a/"
        );
    }

    #[test]
    fn a_substitution_reads_through_a_block_comment_holding_a_brace() {
        let source = b"`${ /* ` } */ x }`X";

        assert_eq!(template_scan(source, 0), source.len() - 1);
    }

    #[test]
    fn a_substitution_reads_through_a_line_comment_holding_a_brace() {
        let source = b"`${ a // ` }\n }`X";

        assert_eq!(template_scan(source, 0), source.len() - 1);
    }

    #[test]
    fn a_substitution_reads_through_a_string_holding_a_brace() {
        let source = b"`${ \"}\" }`X";

        assert_eq!(template_scan(source, 0), source.len() - 1);
    }

    #[test]
    fn a_substitution_reads_through_a_regex_holding_a_brace() {
        let source = b"`${ /[}`]/.test(a) }`X";

        assert_eq!(template_scan(source, 0), source.len() - 1);
    }

    #[test]
    fn a_division_inside_a_substitution_is_not_read_as_a_regex() {
        let source = b"`${ a / b }` c";

        assert_eq!(template_scan(source, 0), source.len() - 2);
        assert!(!divides_before(b"return /x/", 7));
        assert!(divides_before(b"a / b", 2));
        assert!(divides_before(b") / b", 2));
    }

    #[test]
    fn a_template_ends_where_the_scan_says_it_does() {
        let source = b"`${ /* ` } */ x }` after";
        let tokens = tests_support::lex(&JAVASCRIPT, source);

        let strings: Vec<Vec<u8>> = tokens
            .iter()
            .filter(|token| token.kind == TokenKind::String)
            .map(|token| token.text(source).to_vec())
            .collect();

        assert_eq!(strings, vec![b"`${ /* ` } */ x }`".to_vec()]);
        assert!(identifiers_of(&JAVASCRIPT, source).contains(&b"after".to_vec()));
    }

    #[test]
    fn a_regex_ahead_of_a_wide_space_carries_no_flags() {
        for space in ["\u{feff}", "\u{00a0}", "\u{2028}"] {
            let text = format!("const a = /x/{space};");
            let source = text.as_bytes();
            let tokens = tests_support::lex(&JAVASCRIPT, source);

            let strings: Vec<&[u8]> = tokens
                .iter()
                .filter(|token| token.kind == TokenKind::String)
                .map(|token| token.text(source))
                .collect();

            assert_eq!(strings, vec![&b"/x/"[..]]);
        }
    }

    #[test]
    fn a_jsx_expression_container_opens_a_block() {
        let source = b"const view = <div title={name}>Hello {name} world</div>;";
        let tokens = tests_support::lex(&TYPESCRIPT, source);

        let blocks = tokens
            .iter()
            .filter(|token| matches!(token.kind, TokenKind::BlockStart | TokenKind::BlockEnd))
            .count();

        assert_eq!(blocks, 4);
    }

    fn identifiers_of(lexer: &dyn Lexer, source: &[u8]) -> Vec<Vec<u8>> {
        let tokens = tests_support::lex(lexer, source);

        tokens
            .iter()
            .filter(|token| token.kind == TokenKind::Identifier)
            .map(|token| token.text(source).to_vec())
            .collect()
    }

    #[test]
    fn a_dollar_sign_belongs_to_the_identifier_it_touches() {
        let sources: [&[u8]; 4] = [b"$x", b"x$", b"$", b"$$"];

        for source in sources {
            let lexers: [&dyn Lexer; 2] = [&JAVASCRIPT, &TYPESCRIPT];

            for lexer in lexers {
                assert_eq!(identifiers_of(lexer, source), vec![source.to_vec()]);
            }
        }
    }

    #[test]
    fn a_dollar_sign_carries_through_a_declaration_and_a_call() {
        let source = b"const $x = $(1)";
        let lexers: [&dyn Lexer; 2] = [&JAVASCRIPT, &TYPESCRIPT];

        for lexer in lexers {
            assert_eq!(
                identifiers_of(lexer, source),
                vec![b"$x".to_vec(), b"$".to_vec()]
            );
        }
    }

    #[test]
    fn a_dollar_sign_joins_a_private_name_and_a_member() {
        let source = b"class C { #$a; b() { return this.$c; } }";
        let lexers: [&dyn Lexer; 2] = [&JAVASCRIPT, &TYPESCRIPT];

        for lexer in lexers {
            let identifiers = identifiers_of(lexer, source);

            assert!(identifiers.contains(&b"#$a".to_vec()));
            assert!(identifiers.contains(&b"$c".to_vec()));
        }
    }

    #[test]
    fn a_dollar_sign_stays_outside_the_identifier_in_the_other_five_languages() {
        let source = b"$x";

        let lexers: [&dyn Lexer; 5] = [
            &crate::lex::GO,
            &crate::lex::ODIN,
            &crate::lex::PYTHON,
            &crate::lex::RUST,
            &crate::lex::ZIG,
        ];

        for lexer in lexers {
            assert_eq!(identifiers_of(lexer, source), vec![b"x".to_vec()]);
        }
    }
}
