use crate::language::Lexer;
use crate::scan::{
    Numbers,
    identifier_scan,
    is_identifier_part,
    is_identifier_start_at,
    line_scan_trimmed,
    number_scan_bounded,
    punctuation_of,
    string_scan,
    word_in,
};
use crate::token::{Keyword, Lex, Punctuation, TokenKind, Tokens};

pub static ODIN: OdinLexer = OdinLexer;
const MODIFIER_COUNT_MAX: usize = 4;
const BODY_WORD: &[u8] = b"do";
const BODY_COUNT_MAX: u32 = 8;
const COMMENT_BYTES_MAX: usize = 4_096;
const TRIVIA_COUNT_MAX: usize = 8;
const ASSERT_NAMES: &[&[u8]] = &[b"assert", b"ensure", b"panic", b"unimplemented"];

pub struct OdinLexer;

impl Lexer for OdinLexer {
    fn extensions(&self) -> &'static [&'static [u8]] {
        &[b"odin"]
    }

    fn identifier(&self) -> &'static str {
        "odin"
    }

    fn lex(&self, source: &[u8], tokens: &mut Tokens) -> Lex {
        assert!(u32::try_from(source.len()).is_ok());

        let mut offset = crate::scan::mark_width(source);
        let mut ends = false;
        let mut bodies = 0_u32;

        while offset < source.len() {
            let byte = source[offset];
            let joined = continuation_width(source, offset);

            if joined > 0 {
                offset += joined;

                continue;
            }

            if byte == b'\n' {
                if ends && !newline_close(source, tokens, &mut bodies, offset) {
                    return Lex::Truncated;
                }

                ends = false;
                offset += 1;

                continue;
            }

            let blank = crate::scan::whitespace_scan(source, offset);

            if blank > offset {
                offset = blank;

                continue;
            }

            let (kind, end) = token_of(source, offset);

            assert!(end > offset);

            if !tokens.push(source, kind, offset, end - offset) {
                return Lex::Truncated;
            }

            if kind != TokenKind::Comment {
                ends = ends_statement(kind, &source[offset..end]);
            }

            if &source[offset..end] == BODY_WORD && bodies < BODY_COUNT_MAX {
                bodies += 1;

                if !tokens.push(source, TokenKind::BlockStart, end, 0) {
                    return Lex::Truncated;
                }
            }

            offset = end;
        }

        if !bodies_close(source, tokens, &mut bodies, source.len()) {
            return Lex::Truncated;
        }

        Lex::Complete
    }
}

fn newline_close(source: &[u8], tokens: &mut Tokens, bodies: &mut u32, offset: usize) -> bool {
    if !bodies_close(source, tokens, bodies, offset) {
        return false;
    }

    tokens.push(source, TokenKind::Newline, offset, 1)
}

fn bodies_close(source: &[u8], tokens: &mut Tokens, bodies: &mut u32, offset: usize) -> bool {
    assert!(offset <= source.len());
    assert!(*bodies <= BODY_COUNT_MAX);

    while *bodies > 0 {
        *bodies -= 1;

        if !tokens.push(source, TokenKind::BlockEnd, offset, 0) {
            return false;
        }
    }

    true
}

pub(crate) fn word_of(text: &[u8]) -> Option<TokenKind> {
    let keyword = match text {
        b"break" => Keyword::Break,
        b"continue" => Keyword::Continue,
        b"else" => Keyword::BranchElse,
        b"bit_field" | b"bit_set" | b"enum" | b"struct" | b"union" => Keyword::Struct,
        b"if" | b"when" => Keyword::Branch,
        b"import" => Keyword::Import,
        b"return" => Keyword::Return,
        b"switch" => Keyword::Match,
        b"asm" | b"auto_cast" | b"case" | b"cast" | b"context" => Keyword::Other,
        b"defer" | b"distinct" | b"do" | b"dynamic" | b"fallthrough" => Keyword::Other,
        b"foreign" | b"in" | b"inline" | b"map" | b"matrix" => Keyword::Other,
        b"no_inline" | b"not_in" | b"or_break" | b"or_continue" => Keyword::Other,
        b"or_else" | b"or_return" | b"package" | b"transmute" => Keyword::Other,
        b"typeid" | b"using" | b"where" => Keyword::Other,
        _ => return None,
    };

    Some(TokenKind::Keyword(keyword))
}

fn trivia_skip_back(source: &[u8], start: usize) -> usize {
    let mut offset = start;

    for _ in 0..TRIVIA_COUNT_MAX {
        while offset > 0 && source[offset - 1].is_ascii_whitespace() {
            offset -= 1;
        }

        if offset >= 2 && source[offset - 1] == b'/' && source[offset - 2] == b'*' {
            let Some(opened) = comment_open_before(source, offset) else {
                return offset;
            };

            offset = opened;

            continue;
        }

        let Some(marked) = line_comment_before(source, offset) else {
            return offset;
        };

        offset = marked;
    }

    offset
}

fn comment_open_before(source: &[u8], end: usize) -> Option<usize> {
    assert!(end >= 2);

    let floor = end.saturating_sub(COMMENT_BYTES_MAX);
    let mut offset = end - 2;

    while offset > floor {
        offset -= 1;

        if source[offset] == b'/' && source.get(offset + 1) == Some(&b'*') {
            return Some(offset);
        }
    }

    None
}

fn line_comment_before(source: &[u8], end: usize) -> Option<usize> {
    let floor = end.saturating_sub(COMMENT_BYTES_MAX);
    let mut start = end;

    while start > floor && source[start - 1] != b'\n' {
        start -= 1;
    }

    let mut offset = start;

    while offset + 1 < end {
        if source[offset] == b'/' && source[offset + 1] == b'/' {
            return Some(offset);
        }

        offset += 1;
    }

    None
}

fn continuation_width(source: &[u8], offset: usize) -> usize {
    assert!(offset < source.len());

    if source[offset] != b'\\' {
        return 0;
    }

    let mut cursor = offset + 1;

    while cursor < source.len() && matches!(source[cursor], b' ' | b'\t') {
        cursor += 1;
    }

    let terminator = crate::scan::line_break_width(source, cursor);

    if terminator == 0 {
        return 0;
    }

    cursor + terminator - offset
}

fn procedure_keyword(source: &[u8], start: usize) -> Keyword {
    let mut offset = start;

    for _ in 0..MODIFIER_COUNT_MAX {
        offset = trivia_skip_back(source, offset);

        let mut word = offset;

        while word > 0 && is_identifier_part(source[word - 1]) {
            word -= 1;
        }

        if word == offset || word == 0 || source[word - 1] != b'#' {
            break;
        }

        offset = word - 1;
    }

    if offset < 2 {
        return Keyword::Lambda;
    }

    let bound = source[offset - 2] == b':' && matches!(source[offset - 1], b':' | b'=');

    if bound {
        return Keyword::Function;
    }

    Keyword::Lambda
}

fn loop_keyword(source: &[u8], end: usize) -> Keyword {
    let mut offset = end;

    while offset < source.len() && source[offset].is_ascii_whitespace() {
        offset += 1;
    }

    if offset < source.len() && source[offset] == b'{' {
        return Keyword::LoopUnbounded;
    }

    Keyword::Loop
}

fn ends_statement(kind: TokenKind, text: &[u8]) -> bool {
    match kind {
        TokenKind::BlockEnd | TokenKind::Identifier | TokenKind::Number | TokenKind::String => true,
        TokenKind::Keyword(keyword) => {
            matches!(
                keyword,
                Keyword::Assert | Keyword::Break | Keyword::Continue | Keyword::Return
            ) || matches!(
                text,
                b"context"
                    | b"fallthrough"
                    | b"or_break"
                    | b"or_continue"
                    | b"or_return"
                    | b"typeid"
            )
        }
        TokenKind::Punctuation(_) => matches!(text, b")" | b"]" | b"^" | b"?" | b"---"),
        TokenKind::Comment | TokenKind::BlockStart | TokenKind::Newline => false,
    }
}

fn comment_block_scan(source: &[u8], start: usize) -> usize {
    assert_eq!(source[start], b'/');

    let mut offset = start + 2;
    let mut depth = 1_u32;

    while offset + 1 < source.len() {
        if source[offset] == b'/' && source[offset + 1] == b'*' {
            if depth == crate::scan::COMMENT_DEPTH_MAX {
                return source.len();
            }

            depth += 1;
            offset += 2;

            continue;
        }

        if source[offset] == b'*' && source[offset + 1] == b'/' {
            depth -= 1;
            offset += 2;

            if depth == 0 {
                return offset;
            }

            continue;
        }

        offset += 1;
    }

    source.len()
}

fn string_raw_scan(source: &[u8], start: usize) -> usize {
    assert_eq!(source[start], b'`');

    let mut offset = start + 1;

    while offset < source.len() {
        if source[offset] == b'`' {
            return offset + 1;
        }

        offset += 1;
    }

    source.len()
}

fn string_triple_scan(source: &[u8], start: usize, quote: u8) -> usize {
    assert!(quote == b'"' || quote == b'`');
    assert!(source[start..].starts_with(&[quote, quote, quote]));

    let escapes = quote == b'"';
    let mut offset = start + 3;

    while offset < source.len() {
        let byte = source[offset];

        if escapes && byte == b'\\' {
            offset += 2;

            continue;
        }

        if byte == quote && source[offset + 1..].starts_with(&[quote, quote]) {
            return offset + 3;
        }

        offset += 1;
    }

    source.len()
}

fn marked_scan(source: &[u8], start: usize) -> (TokenKind, usize) {
    assert!(source[start] == b'#' || source[start] == b'@');

    let shebang = start == crate::scan::mark_width(source) && source.get(start + 1) == Some(&b'!');
    let tagged = source.get(start + 1) == Some(&b'+') || shebang;

    if source[start] == b'#' && tagged {
        return (TokenKind::Comment, tag_scan(source, start));
    }

    if is_identifier_start_at(source, start + 1) {
        return (TokenKind::Identifier, identifier_scan(source, start + 1));
    }

    (TokenKind::Punctuation(Punctuation::Other), start + 1)
}

fn tag_scan(source: &[u8], start: usize) -> usize {
    let line = line_scan_trimmed(source, start);
    let mut offset = start;

    while offset + 1 < line {
        if source[offset] == b'/' && source[offset + 1] == b'/' {
            return offset;
        }

        offset += 1;
    }

    line
}

fn is_assert_name(text: &[u8], source: &[u8], end: usize) -> bool {
    if !word_in(ASSERT_NAMES, text) {
        return false;
    }

    let mut offset = end;

    while offset < source.len() && source[offset] == b' ' {
        offset += 1;
    }

    source.get(offset) == Some(&b'(')
}

fn token_of(source: &[u8], offset: usize) -> (TokenKind, usize) {
    let byte = source[offset];
    let next = source.get(offset + 1).copied();

    if byte == b'/' && next == Some(b'/') {
        return (TokenKind::Comment, line_scan_trimmed(source, offset));
    }

    if byte == b'/' && next == Some(b'*') {
        return (TokenKind::Comment, comment_block_scan(source, offset));
    }

    if byte == b'{' {
        return (TokenKind::BlockStart, offset + 1);
    }

    if byte == b'}' {
        return (TokenKind::BlockEnd, offset + 1);
    }

    if byte == b'"' {
        if source[offset + 1..].starts_with(b"\"\"") {
            return (TokenKind::String, string_triple_scan(source, offset, b'"'));
        }

        return (TokenKind::String, string_scan(source, offset, b'"'));
    }

    if byte == b'\'' {
        return (TokenKind::String, string_scan(source, offset, b'\''));
    }

    if byte == b'`' {
        if source[offset + 1..].starts_with(b"``") {
            return (TokenKind::String, string_triple_scan(source, offset, b'`'));
        }

        return (TokenKind::String, string_raw_scan(source, offset));
    }

    if byte == b'#' || byte == b'@' {
        return marked_scan(source, offset);
    }

    if byte == b'-' && next == Some(b'-') && source.get(offset + 2) == Some(&b'-') {
        return (TokenKind::Punctuation(Punctuation::Other), offset + 3);
    }

    if byte == b':' && (next == Some(b'=') || next == Some(b':')) {
        return (
            TokenKind::Punctuation(Punctuation::AssignDeclare),
            offset + 2,
        );
    }

    if is_identifier_start_at(source, offset) {
        return word_token_of(source, offset);
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

fn word_token_of(source: &[u8], offset: usize) -> (TokenKind, usize) {
    assert!(is_identifier_start_at(source, offset));

    let end = identifier_scan(source, offset);
    let text = &source[offset..end];

    if text == b"for" {
        return (TokenKind::Keyword(loop_keyword(source, end)), end);
    }

    if text == b"proc" {
        return (TokenKind::Keyword(procedure_keyword(source, offset)), end);
    }

    if is_assert_name(text, source, end) {
        return (TokenKind::Keyword(Keyword::Assert), end);
    }

    match word_of(text) {
        Some(kind) => (kind, end),
        None => (TokenKind::Identifier, end),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::lex::tests_support;

    #[test]
    fn a_block_comment_opener_is_found_behind_its_closer() {
        assert_eq!(comment_open_before(b"/* a */", 7), Some(0));
        assert_eq!(comment_open_before(b"x /* a */", 9), Some(2));
        assert_eq!(comment_open_before(b"/**/", 4), Some(0));
        assert_eq!(comment_open_before(b"a */", 4), None);
        assert_eq!(comment_open_before(b"*/", 2), None);
        assert_eq!(comment_open_before(b"aaaaaa/*z\n", 10), Some(6));
    }

    #[test]
    fn a_line_comment_is_found_from_the_start_of_its_own_line() {
        assert_eq!(line_comment_before(b"// a", 4), Some(0));
        assert_eq!(line_comment_before(b"x // a", 6), Some(2));
        assert_eq!(line_comment_before(b"a\n// b", 6), Some(2));
        assert_eq!(line_comment_before(b"// a\nb", 6), None);
        assert_eq!(line_comment_before(b"a / b", 5), None);
        assert_eq!(line_comment_before(b"", 0), None);
        assert_eq!(line_comment_before(b"//", 2), Some(0));
        assert_eq!(line_comment_before(b"//", 1), None);
    }

    fn counted(source: &'static [u8], wanted: TokenKind) -> usize {
        tests_support::lex(&ODIN, source)
            .iter()
            .filter(|token| token.kind == wanted)
            .count()
    }

    #[test]
    fn a_do_body_opens_and_closes_its_block() {
        assert_eq!(counted(b"if x do y\n", TokenKind::BlockStart), 1);
        assert_eq!(counted(b"if x do y\n", TokenKind::BlockEnd), 1);
        assert_eq!(counted(b"if x do y", TokenKind::BlockStart), 1);
        assert_eq!(counted(b"if x do y", TokenKind::BlockEnd), 1);
        assert_eq!(counted(b"x := 1\n", TokenKind::BlockStart), 0);
        assert_eq!(counted(b"x := 1\n", TokenKind::BlockEnd), 0);
    }

    #[test]
    fn a_do_body_closes_at_its_own_line_and_not_at_the_end_of_the_source() {
        let source = b"if x do y\nz := 1\n";
        let tokens = tests_support::lex(&ODIN, source);

        let ends: Vec<_> = tokens
            .iter()
            .filter(|token| token.kind == TokenKind::BlockEnd)
            .map(|token| token.offset)
            .collect();

        assert_eq!(ends, vec![9], "{tokens:?}");
    }

    #[test]
    fn a_triple_quoted_string_runs_to_its_closing_triple() {
        assert_eq!(string_triple_scan(b"\"\"\"a\nb\"\"\"", 0, b'"'), 9);
        assert_eq!(string_triple_scan(b"\"\"\"\"\"\"", 0, b'"'), 6);
        assert_eq!(string_triple_scan(b"```a\\`b```", 0, b'`'), 10);
    }

    #[test]
    fn an_escaped_quote_does_not_close_a_triple_quoted_string() {
        assert_eq!(string_triple_scan(b"\"\"\"\\\"\"\"\"", 0, b'"'), 8);
        assert_eq!(string_triple_scan(b"\"\"\"a\\\"\"\"", 0, b'"'), 8);
    }

    #[test]
    fn an_unclosed_triple_quoted_string_runs_to_the_source_end() {
        assert_eq!(string_triple_scan(b"\"\"\"a\"\"", 0, b'"'), 6);
        assert_eq!(string_triple_scan(b"\"\"\"", 0, b'"'), 3);
        assert_eq!(string_triple_scan(b"```a", 0, b'`'), 4);
    }

    #[test]
    fn a_triple_quoted_string_lexes_as_one_token_across_lines() {
        assert_eq!(counted(b"s := \"\"\"\na \" b\n\"\"\"\n", TokenKind::String), 1);
        assert_eq!(counted(b"s := ```\na ` b\n```\n", TokenKind::String), 1);
        assert_eq!(counted(b"s := \"\" + \"a\"\n", TokenKind::String), 2);
    }

    #[test]
    fn a_tag_stops_where_a_trailing_comment_starts() {
        assert_eq!(tag_scan(b"#+build linux // only there\n", 0), 14);
        assert_eq!(tag_scan(b"#+build linux\n", 0), 13);
        assert_eq!(tag_scan(b"#+build linux", 0), 13);
        assert_eq!(tag_scan(b"//x\n", 0), 0);
        assert_eq!(tag_scan(b"#a/b\n", 0), 4);
        assert_eq!(tag_scan(b"", 0), 0);
    }

    #[test]
    fn a_continuation_covers_the_backslash_and_what_follows_it() {
        assert_eq!(continuation_width(b"\\\n", 0), 2);
        assert_eq!(continuation_width(b"\\  \n", 0), 4);
        assert_eq!(continuation_width(b"\\\t\n", 0), 3);
        assert_eq!(continuation_width(b"\\ x\n", 0), 0);
        assert_eq!(continuation_width(b"\\", 0), 0);
        assert_eq!(continuation_width(b"x\n", 0), 0);
    }

    const KEYWORDS: &[(&str, &str, TokenKind)] = &[
        (
            "asm",
            "f :: proc() {\n    asm() {}\n}\n",
            TokenKind::Keyword(Keyword::Other),
        ),
        (
            "auto_cast",
            "f :: proc(value: int) {\n    other := auto_cast value\n}\n",
            TokenKind::Keyword(Keyword::Other),
        ),
        (
            "bit_field",
            "Flags :: bit_field u8 {\n    a: bool | 1,\n}\n",
            TokenKind::Keyword(Keyword::Struct),
        ),
        (
            "bit_set",
            "Modes :: bit_set[Mode]\n",
            TokenKind::Keyword(Keyword::Struct),
        ),
        (
            "break",
            "f :: proc() {\n    for {\n        break\n    }\n}\n",
            TokenKind::Keyword(Keyword::Break),
        ),
        (
            "case",
            "f :: proc(value: int) {\n    switch value {\n    case 1:\n    }\n}\n",
            TokenKind::Keyword(Keyword::Other),
        ),
        (
            "cast",
            "f :: proc(value: int) {\n    other := cast(f32)value\n}\n",
            TokenKind::Keyword(Keyword::Other),
        ),
        (
            "context",
            "f :: proc() {\n    other := context.allocator\n}\n",
            TokenKind::Keyword(Keyword::Other),
        ),
        (
            "continue",
            "f :: proc() {\n    for {\n        continue\n    }\n}\n",
            TokenKind::Keyword(Keyword::Continue),
        ),
        (
            "defer",
            "f :: proc() {\n    defer cleanup()\n}\n",
            TokenKind::Keyword(Keyword::Other),
        ),
        (
            "distinct",
            "Id :: distinct int\n",
            TokenKind::Keyword(Keyword::Other),
        ),
        (
            "do",
            "f :: proc(ready: bool) {\n    if ready do cleanup()\n}\n",
            TokenKind::Keyword(Keyword::Other),
        ),
        (
            "dynamic",
            "f :: proc() {\n    values: [dynamic]int\n}\n",
            TokenKind::Keyword(Keyword::Other),
        ),
        (
            "else",
            "f :: proc(ready: bool) {\n    if ready {\n    } else {\n    }\n}\n",
            TokenKind::Keyword(Keyword::BranchElse),
        ),
        (
            "enum",
            "Mode :: enum {\n    Read,\n}\n",
            TokenKind::Keyword(Keyword::Struct),
        ),
        (
            "fallthrough",
            "f :: proc(value: int) {\n    switch value {\n    case 1:\n        fallthrough\n    \
             }\n}\n",
            TokenKind::Keyword(Keyword::Other),
        ),
        (
            "for",
            "f :: proc() {\n    for index in 0 ..< 2 {\n    }\n}\n",
            TokenKind::Keyword(Keyword::Loop),
        ),
        (
            "foreign",
            "foreign import lib \"system:c\"\n",
            TokenKind::Keyword(Keyword::Other),
        ),
        (
            "if",
            "f :: proc(ready: bool) {\n    if ready {\n    }\n}\n",
            TokenKind::Keyword(Keyword::Branch),
        ),
        (
            "import",
            "package main\n\nimport \"core:fmt\"\n",
            TokenKind::Keyword(Keyword::Import),
        ),
        (
            "in",
            "f :: proc() {\n    for index in 0 ..< 2 {\n    }\n}\n",
            TokenKind::Keyword(Keyword::Other),
        ),
        (
            "inline",
            "f :: proc() {\n    other := inline g()\n}\n",
            TokenKind::Keyword(Keyword::Other),
        ),
        (
            "map",
            "f :: proc() {\n    values: map[string]int\n}\n",
            TokenKind::Keyword(Keyword::Other),
        ),
        (
            "matrix",
            "f :: proc() {\n    values: matrix[2, 2]f32\n}\n",
            TokenKind::Keyword(Keyword::Other),
        ),
        (
            "no_inline",
            "f :: proc() {\n    other := no_inline g()\n}\n",
            TokenKind::Keyword(Keyword::Other),
        ),
        (
            "not_in",
            "f :: proc(values: map[string]int) -> bool {\n    return \"a\" not_in values\n}\n",
            TokenKind::Keyword(Keyword::Other),
        ),
        (
            "or_break",
            "f :: proc() {\n    for {\n        value := g() or_break\n    }\n}\n",
            TokenKind::Keyword(Keyword::Other),
        ),
        (
            "or_continue",
            "f :: proc() {\n    for {\n        value := g() or_continue\n    }\n}\n",
            TokenKind::Keyword(Keyword::Other),
        ),
        (
            "or_else",
            "f :: proc() {\n    value := g() or_else 0\n}\n",
            TokenKind::Keyword(Keyword::Other),
        ),
        (
            "or_return",
            "f :: proc() -> bool {\n    value := g() or_return\n    return true\n}\n",
            TokenKind::Keyword(Keyword::Other),
        ),
        (
            "package",
            "package main\n",
            TokenKind::Keyword(Keyword::Other),
        ),
        (
            "proc",
            "f :: proc() {\n}\n",
            TokenKind::Keyword(Keyword::Function),
        ),
        (
            "return",
            "f :: proc() -> int {\n    return 0\n}\n",
            TokenKind::Keyword(Keyword::Return),
        ),
        (
            "struct",
            "Point :: struct {\n    x: int,\n}\n",
            TokenKind::Keyword(Keyword::Struct),
        ),
        (
            "switch",
            "f :: proc(value: int) {\n    switch value {\n    }\n}\n",
            TokenKind::Keyword(Keyword::Match),
        ),
        (
            "transmute",
            "f :: proc(value: int) {\n    other := transmute(f32)value\n}\n",
            TokenKind::Keyword(Keyword::Other),
        ),
        (
            "typeid",
            "f :: proc(kind: typeid) {\n}\n",
            TokenKind::Keyword(Keyword::Other),
        ),
        (
            "union",
            "Value :: union {\n    int,\n}\n",
            TokenKind::Keyword(Keyword::Struct),
        ),
        (
            "using",
            "f :: proc() {\n    using fmt\n}\n",
            TokenKind::Keyword(Keyword::Other),
        ),
        (
            "when",
            "f :: proc() {\n    when ODIN_DEBUG {\n    }\n}\n",
            TokenKind::Keyword(Keyword::Branch),
        ),
        (
            "where",
            "f :: proc($T: typeid) where size_of(T) > 0 {\n}\n",
            TokenKind::Keyword(Keyword::Other),
        ),
    ];

    fn spans(source: &str) -> Vec<(TokenKind, String)> {
        let bytes = source.as_bytes();

        tests_support::lex(&ODIN, bytes)
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

    const COMMENTS: &[(&str, &str)] = &[
        ("/* note */\nvalue := 1\n", "/* note */"),
        ("/**/\nvalue := 1\n", "/**/"),
        ("/* a\n   b */\nvalue := 1\n", "/* a\n   b */"),
        (
            "/* outer /* inner */ still */\nvalue := 1\n",
            "/* outer /* inner */ still */",
        ),
        ("// note\nvalue := 1\n", "// note"),
        ("value := 1 /* note */\n", "/* note */"),
        ("value := 1 /* a */ + 2\n", "/* a */"),
        (
            "value := 1 /* outer /* inner */ still */ + 2\n",
            "/* outer /* inner */ still */",
        ),
        (
            "value := 1234567890 /* outer /* inner */ still */\n",
            "/* outer /* inner */ still */",
        ),
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
        assert_eq!(first_of("/* open\n", TokenKind::Comment), "/* open\n");
    }

    #[test]
    fn an_unterminated_nested_block_comment_runs_to_the_end() {
        for source in [
            "/* outer /* inner */\n",
            "/* open",
            "/* open*",
            "/* open/",
            "/*",
            "/*/",
            "/* outer /* inner *",
        ] {
            assert_eq!(first_of(source, TokenKind::Comment), *source, "{source:?}");
        }
    }

    const RAW_STRINGS: &[(&str, &str)] = &[
        ("value := `raw`\n", "`raw`"),
        ("value := `a\nb`\n", "`a\nb`"),
        ("value := ``\n", "``"),
        ("value := `a\\b`\n", "`a\\b`"),
    ];

    #[test]
    fn every_raw_string_shape_lexes_to_one_string() {
        for (source, expected) in RAW_STRINGS {
            assert_eq!(first_of(source, TokenKind::String), *expected, "{source:?}");
        }
    }

    #[test]
    fn an_unterminated_raw_string_runs_to_the_end() {
        assert_eq!(first_of("value := `open\n", TokenKind::String), "`open\n");
    }

    const PROCEDURES: &[(&str, Keyword)] = &[
        ("run :: proc() {}\n", Keyword::Function),
        ("run := proc() {}\n", Keyword::Function),
        ("run :: #force_inline proc() {}\n", Keyword::Function),
        (
            "run :: #force_inline #no_bounds_check proc() {}\n",
            Keyword::Function,
        ),
        ("callback := map[string]proc()\n", Keyword::Lambda),
        ("value := call(proc() {})\n", Keyword::Lambda),
    ];

    #[test]
    fn a_bound_procedure_is_a_function_and_a_free_one_is_a_lambda() {
        for (source, expected) in PROCEDURES {
            assert_eq!(
                tests_support::kind_of(&ODIN, source, "proc"),
                TokenKind::Keyword(*expected),
                "{source:?}"
            );
        }
    }

    const PROCEDURE_EDGES: &[(&str, Keyword)] = &[
        ("x :: proc() {}\n", Keyword::Function),
        ("x := proc() {}\n", Keyword::Function),
        ("x = proc() {}\n", Keyword::Lambda),
        ("x:: proc() {}\n", Keyword::Function),
        ("x :: # proc() {}\n", Keyword::Lambda),
        ("x :: #a #b #c #d proc() {}\n", Keyword::Lambda),
        ("x :: #a #b #c proc() {}\n", Keyword::Function),
        ("a proc() {}\n", Keyword::Lambda),
        ("::proc() {}\n", Keyword::Function),
        (":proc() {}\n", Keyword::Lambda),
    ];

    #[test]
    fn a_comment_between_the_binding_and_the_procedure_keeps_the_declaration() {
        for source in [
            "add :: // note\n    proc(a: int) -> int {\n\treturn a\n}\n",
            "add :: /* note */ proc(a: int) -> int {\n\treturn a\n}\n",
            "add :: /* a */ /* b */ proc(a: int) -> int {\n\treturn a\n}\n",
        ] {
            assert_eq!(
                tests_support::kind_of(&ODIN, source, "proc"),
                TokenKind::Keyword(Keyword::Function),
                "{source:?}"
            );
        }
    }

    #[test]
    fn a_do_body_opens_a_block_that_closes_at_the_statement() {
        let source = b"f :: proc(v: bool) {\n\tif v do g()\n\th()\n}\n";
        let tokens = tests_support::lex(&ODIN, source);

        let opened = tokens
            .iter()
            .filter(|token| token.kind == TokenKind::BlockStart)
            .count();

        let closed = tokens
            .iter()
            .filter(|token| token.kind == TokenKind::BlockEnd)
            .count();

        assert_eq!(opened, 2);
        assert_eq!(closed, 2);
    }

    #[test]
    fn a_file_tag_leaves_the_comment_after_it_alone() {
        let source = b"#+build linux // only there\npackage main\n";
        let tokens = tests_support::lex(&ODIN, source);

        assert_eq!(tokens[0].text(source), b"#+build linux ");
        assert_eq!(tokens[1].kind, TokenKind::Comment);
        assert_eq!(tokens[1].text(source), b"// only there");
    }

    #[test]
    fn a_shebang_behind_a_byte_order_mark_is_still_a_shebang() {
        let source = b"\xef\xbb\xbf#!/usr/bin/env odin\npackage main\n";
        let tokens = tests_support::lex(&ODIN, source);

        assert_eq!(tokens[0].kind, TokenKind::Comment);
        assert_eq!(tokens[0].text(source), b"#!/usr/bin/env odin");
    }

    #[test]
    fn a_continuation_tolerates_a_space_before_its_newline() {
        assert_eq!(newlines("value := 1 \\ \nother := 2\n"), 1);
        assert_eq!(newlines("value := 1 \\\r\nother := 2\n"), 1);
    }

    #[test]
    fn a_modifier_run_stops_at_the_limit() {
        for (source, expected) in PROCEDURE_EDGES {
            assert_eq!(
                tests_support::kind_of(&ODIN, source, "proc"),
                TokenKind::Keyword(*expected),
                "{source:?}"
            );
        }
    }

    #[test]
    fn a_procedure_at_the_head_of_the_source_is_a_lambda() {
        assert_eq!(
            tests_support::kind_of(&ODIN, "proc() {}\n", "proc"),
            TokenKind::Keyword(Keyword::Lambda)
        );
    }

    const LOOPS: &[(&str, Keyword)] = &[
        ("run :: proc() {\n\tfor {\n\t}\n}\n", Keyword::LoopUnbounded),
        (
            "run :: proc() {\n\tfor index in 0..<4 {\n\t}\n}\n",
            Keyword::Loop,
        ),
        (
            "run :: proc() {\n\tfor  {\n\t}\n}\n",
            Keyword::LoopUnbounded,
        ),
    ];

    #[test]
    fn a_bare_for_is_an_unbounded_loop() {
        for (source, expected) in LOOPS {
            assert_eq!(
                tests_support::kind_of(&ODIN, source, "for"),
                TokenKind::Keyword(*expected),
                "{source:?}"
            );
        }
    }

    #[test]
    fn a_for_at_the_end_of_the_source_is_a_bounded_loop() {
        assert_eq!(
            tests_support::kind_of(&ODIN, "run :: proc() {\n\tfor", "for"),
            TokenKind::Keyword(Keyword::Loop)
        );
    }

    const MARKED: &[(&str, &str, TokenKind)] = &[
        (
            "#+build linux\npackage main\n",
            "#+build linux",
            TokenKind::Comment,
        ),
        (
            "value := #config(NAME, 1)\n",
            "#config",
            TokenKind::Identifier,
        ),
        ("@(private)\nvalue := 1\n", "private", TokenKind::Identifier),
        (
            "value := a #  b\n",
            "#",
            TokenKind::Punctuation(Punctuation::Other),
        ),
        ("#config(NAME, 1)\n", "#config", TokenKind::Identifier),
        (
            "@(private)\npackage main\n",
            "@",
            TokenKind::Punctuation(Punctuation::Other),
        ),
    ];

    #[test]
    fn every_marked_shape_lexes_to_its_kind() {
        for (source, word, expected) in MARKED {
            assert_eq!(
                tests_support::kind_of(&ODIN, source, word),
                *expected,
                "{source:?}"
            );
        }
    }

    #[test]
    fn a_star_behind_a_name_does_not_open_a_comment() {
        let source = b"value := a*b\n";
        let tokens = tests_support::lex(&ODIN, source);

        assert!(!tokens.is_empty());

        assert_eq!(
            tests_support::kind_of(&ODIN, "value := a*b\n", "*"),
            TokenKind::Punctuation(Punctuation::Star)
        );
    }

    const PUNCTUATION_RUNS: &[(&str, &str, TokenKind)] = &[
        (
            "value: int = ---\n",
            "---",
            TokenKind::Punctuation(Punctuation::Other),
        ),
        (
            "value := 1\n",
            ":=",
            TokenKind::Punctuation(Punctuation::AssignDeclare),
        ),
        (
            "Value :: 1\n",
            "::",
            TokenKind::Punctuation(Punctuation::AssignDeclare),
        ),
        (
            "value: int\n",
            ":",
            TokenKind::Punctuation(Punctuation::Colon),
        ),
    ];

    #[test]
    fn every_punctuation_run_lexes_to_its_kind() {
        for (source, word, expected) in PUNCTUATION_RUNS {
            assert_eq!(
                tests_support::kind_of(&ODIN, source, word),
                *expected,
                "{source:?}"
            );
        }
    }

    #[test]
    fn a_shebang_at_the_head_of_the_file_is_a_comment() {
        assert_eq!(
            first_of("#!/usr/bin/env odin\n", TokenKind::Comment),
            "#!/usr/bin/env odin"
        );
    }

    #[test]
    fn a_mark_at_the_end_of_the_source_is_a_punctuation() {
        assert_eq!(
            tests_support::kind_of(&ODIN, "value := a #", "#"),
            TokenKind::Punctuation(Punctuation::Other)
        );
    }

    const ASSERTS: &[(&str, TokenKind)] = &[
        (
            "run :: proc(v: bool) {\n\tassert(v)\n}\n",
            TokenKind::Keyword(Keyword::Assert),
        ),
        (
            "run :: proc(v: bool) {\n\tassert (v)\n}\n",
            TokenKind::Keyword(Keyword::Assert),
        ),
        (
            "run :: proc(v: bool) {\n\tensure(v)\n}\n",
            TokenKind::Keyword(Keyword::Assert),
        ),
        (
            "run :: proc() {\n\tpanic(\"no\")\n}\n",
            TokenKind::Keyword(Keyword::Assert),
        ),
        (
            "run :: proc() {\n\tunimplemented(\"no\")\n}\n",
            TokenKind::Keyword(Keyword::Assert),
        ),
        (
            "run :: proc(v: bool) {\n\tassert := v\n}\n",
            TokenKind::Identifier,
        ),
        (
            "run :: proc(v: bool) {\n\tasserted(v)\n}\n",
            TokenKind::Identifier,
        ),
    ];

    #[test]
    fn an_assert_name_needs_a_call_to_be_a_keyword() {
        for (source, expected) in ASSERTS {
            let word = if source.contains("asserted") {
                "asserted"
            } else if source.contains("assert") {
                "assert"
            } else if source.contains("ensure") {
                "ensure"
            } else if source.contains("panic") {
                "panic"
            } else {
                "unimplemented"
            };

            assert_eq!(
                tests_support::kind_of(&ODIN, source, word),
                *expected,
                "{source:?}"
            );
        }
    }

    #[test]
    fn an_assert_name_at_the_end_of_the_source_is_an_identifier() {
        assert_eq!(
            tests_support::kind_of(&ODIN, "assert", "assert"),
            TokenKind::Identifier
        );
    }

    #[test]
    fn a_one_sided_dot_float_is_one_number() {
        assert_eq!(
            tests_support::kind_of(&ODIN, "half := .5\n", ".5"),
            TokenKind::Number
        );

        assert_eq!(
            tests_support::kind_of(&ODIN, "one := 1.\n", "1."),
            TokenKind::Number
        );
    }

    #[test]
    fn a_range_is_not_a_trailing_dot_float() {
        assert_eq!(
            tests_support::kind_of(&ODIN, "for i in 1..<5 {\n}\n", "1"),
            TokenKind::Number
        );
    }

    fn newlines(source: &str) -> usize {
        tests_support::lex(&ODIN, source.as_bytes())
            .iter()
            .filter(|token| token.kind == TokenKind::Newline)
            .count()
    }

    #[test]
    fn a_backslash_before_a_newline_joins_the_line() {
        assert_eq!(newlines("value := 1\nother := 2\n"), 2);
        assert_eq!(newlines("value := \\\n1\nother := 2\n"), 2);
        assert_eq!(newlines("value := 1 \\\n\nother := 2\n"), 2);
    }

    const STATEMENT_ENDS: &[(&str, usize)] = &[
        ("value := 1\n", 1),
        ("run :: proc() {\n}\n", 1),
        ("value := call(1)\n", 1),
        ("value := items[0]\n", 1),
        ("value := pointer^\n", 1),
        ("value := \"text\"\n", 1),
        ("run :: proc() {\n\treturn\n}\n", 2),
        ("run :: proc() {\n\tfor {\n\t\tbreak\n\t}\n}\n", 3),
        ("run :: proc() {\n\tfor {\n\t\tcontinue\n\t}\n}\n", 3),
        ("run :: proc(v: bool) {\n\tassert(v)\n}\n", 2),
        ("run :: proc() {\n\tor_return\n}\n", 2),
        ("run :: proc() {\n\tfallthrough\n}\n", 2),
        ("value: i64 = ---\n", 1),
        ("value := call() or_else 0 if ok else 1\n", 1),
        ("value := maybe.?\n", 1),
        ("kind: typeid\n", 1),
        ("allocator := context\n", 1),
        ("value := 1 +\n", 0),
        ("// note\n", 0),
        ("value :=\n", 0),
    ];

    #[test]
    fn an_undefined_value_ends_its_statement() {
        let source = "a: i64 = ---\nb: i64 = ---\nc: i64 = ---\n";

        assert_eq!(newlines(source), 3);
    }

    #[test]
    fn a_line_ends_a_statement_only_after_a_token_that_can_end_one() {
        for (source, expected) in STATEMENT_ENDS {
            assert_eq!(newlines(source), *expected, "{source:?}");
        }
    }

    #[test]
    fn every_keyword_of_the_specification_lexes_to_its_kind() {
        assert_eq!(KEYWORDS.len(), 41);

        for (word, source, expected) in KEYWORDS {
            assert_eq!(
                tests_support::kind_of(&ODIN, source, word),
                *expected,
                "{word}"
            );
        }
    }
}
