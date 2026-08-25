use crate::language::Lexer;
use crate::scan::{
    identifier_scan,
    is_identifier_start_at,
    line_scan_trimmed,
    number_scan,
    punctuation_of,
    string_scan_multiline,
};
use crate::token::{Keyword, Lex, Punctuation, TokenKind, Tokens};

pub static RUST: RustLexer = RustLexer;
const ASSERTION_PREFIXES: &[&[u8]] = &[b"assert", b"debug_assert", b"prop_assert"];
const CHARACTER_BYTES_MAX: usize = 24;
const HASH_COUNT_MAX: usize = 255;

pub struct RustLexer;

impl Lexer for RustLexer {
    fn extensions(&self) -> &'static [&'static [u8]] {
        &[b"rs"]
    }

    fn identifier(&self) -> &'static str {
        "rust"
    }

    fn lex(&self, source: &[u8], tokens: &mut Tokens) -> Lex {
        assert!(u32::try_from(source.len()).is_ok());

        let mut offset = crate::scan::mark_width(source);
        let mut previous = None;

        while offset < source.len() {
            let byte = source[offset];
            let blank = crate::scan::whitespace_scan(source, offset);

            if blank > offset {
                offset = blank;

                continue;
            }

            let (mut kind, end) = token_of(source, offset);

            if byte == b'|' && opens_a_closure(previous) {
                kind = TokenKind::Keyword(Keyword::Lambda);
            }

            if kind != TokenKind::Comment {
                previous = Some(kind);
            }

            assert!(end > offset);

            if !tokens.push(source, kind, offset, end - offset) {
                return Lex::Truncated;
            }

            offset = end;
        }

        Lex::Complete
    }
}

const fn opens_a_closure(previous: Option<TokenKind>) -> bool {
    let Some(kind) = previous else {
        return true;
    };

    !matches!(
        kind,
        TokenKind::BlockEnd
            | TokenKind::Identifier
            | TokenKind::Number
            | TokenKind::Punctuation(Punctuation::BracketClose | Punctuation::ParenClose)
            | TokenKind::String
    )
}

fn is_assertion(text: &[u8], source: &[u8], end: usize) -> bool {
    if source.get(end) != Some(&b'!') {
        return false;
    }

    ASSERTION_PREFIXES
        .iter()
        .any(|prefix| text.starts_with(prefix))
}

pub(crate) fn word_of(text: &[u8]) -> Option<TokenKind> {
    let keyword = match text {
        b"break" => Keyword::Break,
        b"const" | b"static" => Keyword::Constant,
        b"continue" => Keyword::Continue,
        b"use" => Keyword::Import,
        b"else" => Keyword::BranchElse,
        b"enum" | b"impl" | b"struct" | b"trait" => Keyword::Struct,
        b"fn" => Keyword::Function,
        b"for" | b"while" => Keyword::Loop,
        b"if" => Keyword::Branch,
        b"loop" => Keyword::LoopUnbounded,
        b"match" => Keyword::Match,
        b"mut" => Keyword::Mutable,
        b"return" => Keyword::Return,
        b"let" => Keyword::Declare,
        b"as" | b"async" | b"await" | b"crate" | b"dyn" | b"extern" => Keyword::Other,
        b"in" | b"mod" | b"move" => Keyword::Other,
        b"pub" | b"ref" | b"self" | b"super" | b"type" | b"unsafe" | b"where" => Keyword::Other,
        _ => return None,
    };

    Some(TokenKind::Keyword(keyword))
}

fn character_scan(source: &[u8], start: usize) -> (TokenKind, usize) {
    assert_eq!(source[start], b'\'');

    let escaped = source.get(start + 1) == Some(&b'\\');
    let limit = source.len().min(start + CHARACTER_BYTES_MAX);
    let mut offset = if escaped { start + 2 } else { start + 1 };

    if offset < limit {
        offset += 1;
    }

    if escaped {
        while offset < limit {
            if source[offset] == b'\n' {
                break;
            }

            if source[offset] == b'\'' {
                return (TokenKind::String, offset + 1);
            }

            offset += 1;
        }
    } else {
        while offset < limit && (source[offset] & 0xC0) == 0x80 {
            offset += 1;
        }

        assert!(offset <= source.len());

        if source.get(offset) == Some(&b'\'') {
            return (TokenKind::String, offset + 1);
        }
    }

    if is_identifier_start_at(source, start + 1) {
        return (TokenKind::Identifier, identifier_scan(source, start + 1));
    }

    (TokenKind::Punctuation(Punctuation::Other), start + 1)
}

fn comment_block_scan(source: &[u8], start: usize) -> usize {
    assert_eq!(source[start], b'/');

    let mut depth = 0_u32;
    let mut offset = start;

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

fn string_raw_scan(source: &[u8], start: usize) -> Option<usize> {
    assert_eq!(source[start], b'r');

    let mut hashes = 0;
    let mut offset = start + 1;

    while offset < source.len() && source[offset] == b'#' && hashes < HASH_COUNT_MAX {
        hashes += 1;
        offset += 1;
    }

    if offset >= source.len() || source[offset] != b'"' {
        return None;
    }

    offset += 1;

    while offset < source.len() {
        if source[offset] != b'"' {
            offset += 1;

            continue;
        }

        let end = offset + 1 + hashes;

        if end <= source.len() && source[offset + 1..end].iter().all(|byte| *byte == b'#') {
            return Some(end);
        }

        offset += 1;
    }

    Some(source.len())
}

fn escapes_a_keyword(source: &[u8], offset: usize) -> bool {
    if offset < 2 || source[offset - 1] != b'#' || source[offset - 2] != b'r' {
        return false;
    }

    offset == 2 || !crate::scan::is_identifier_part(source[offset - 3])
}

fn suffix_end(source: &[u8], end: usize) -> usize {
    if !is_identifier_start_at(source, end) {
        return end;
    }

    identifier_scan(source, end)
}

fn token_of(source: &[u8], offset: usize) -> (TokenKind, usize) {
    let (kind, end) = token_scan(source, offset);

    if kind == TokenKind::String {
        return (kind, suffix_end(source, end));
    }

    (kind, end)
}

fn identifier_token_of(source: &[u8], offset: usize) -> (TokenKind, usize) {
    assert!(offset < source.len());

    let end = identifier_scan(source, offset);
    let text = &source[offset..end];

    assert!(end > offset);

    if escapes_a_keyword(source, offset) {
        return (TokenKind::Identifier, end);
    }

    if is_assertion(text, source, end) {
        return (TokenKind::Keyword(Keyword::Assert), end);
    }

    match word_of(text) {
        Some(kind) => (kind, end),
        None => (TokenKind::Identifier, end),
    }
}

fn token_scan(source: &[u8], offset: usize) -> (TokenKind, usize) {
    let byte = source[offset];
    let next = source.get(offset + 1).copied();

    if byte == b'/' && next == Some(b'/') {
        return (TokenKind::Comment, line_scan_trimmed(source, offset));
    }

    if byte == b'/' && next == Some(b'*') {
        return (TokenKind::Comment, comment_block_scan(source, offset));
    }

    if offset == 0 && byte == b'#' && next == Some(b'!') && source.get(2) != Some(&b'[') {
        return (TokenKind::Comment, line_scan_trimmed(source, offset));
    }

    if byte == b'{' {
        return (TokenKind::BlockStart, offset + 1);
    }

    if byte == b'}' {
        return (TokenKind::BlockEnd, offset + 1);
    }

    if let Some(found) = literal_token_of(source, offset, next) {
        return found;
    }

    if is_identifier_start_at(source, offset) {
        return identifier_token_of(source, offset);
    }

    if byte.is_ascii_digit() {
        return (TokenKind::Number, number_scan(source, offset));
    }

    let (punctuation, length) = punctuation_of(source, offset);

    (TokenKind::Punctuation(punctuation), offset + length)
}

fn literal_token_of(source: &[u8], offset: usize, next: Option<u8>) -> Option<(TokenKind, usize)> {
    assert!(offset < source.len());

    let byte = source[offset];

    if byte == b'"' {
        return Some((
            TokenKind::String,
            string_scan_multiline(source, offset, b'"'),
        ));
    }

    if byte == b'\'' {
        return Some(character_scan(source, offset));
    }

    if byte == b'r' {
        return string_raw_scan(source, offset).map(|end| (TokenKind::String, end));
    }

    if byte != b'b' && byte != b'c' {
        return None;
    }

    if next == Some(b'"') {
        return Some((
            TokenKind::String,
            string_scan_multiline(source, offset + 1, b'"'),
        ));
    }

    if next != Some(b'r') {
        return None;
    }

    string_raw_scan(source, offset + 1).map(|end| (TokenKind::String, end))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::lex::tests_support;

    #[test]
    fn a_raw_identifier_escapes_the_word_behind_its_own_prefix() {
        assert!(escapes_a_keyword(b"r#fn", 2));
        assert!(escapes_a_keyword(b" r#fn", 3));
        assert!(escapes_a_keyword(b"(r#fn", 3));
        assert!(!escapes_a_keyword(b"ar#fn", 3));
        assert!(!escapes_a_keyword(b"r_#fn", 3));
        assert!(!escapes_a_keyword(b"#fn", 1));
        assert!(!escapes_a_keyword(b"rfn", 2));
        assert!(!escapes_a_keyword(b"fn", 0));
    }

    const KEYWORDS_STRICT: &[(&str, &str, TokenKind)] = &[
        (
            "as",
            "use std::io as system;\n",
            TokenKind::Keyword(Keyword::Other),
        ),
        (
            "async",
            "async fn f() {}\n",
            TokenKind::Keyword(Keyword::Other),
        ),
        (
            "await",
            "async fn f(task: Task) {\n    task.await;\n}\n",
            TokenKind::Keyword(Keyword::Other),
        ),
        (
            "break",
            "fn f() {\n    loop {\n        break;\n    }\n}\n",
            TokenKind::Keyword(Keyword::Break),
        ),
        (
            "const",
            "const LIMIT: u32 = 4;\n",
            TokenKind::Keyword(Keyword::Constant),
        ),
        (
            "continue",
            "fn f() {\n    for index in 0..4 {\n        continue;\n    }\n}\n",
            TokenKind::Keyword(Keyword::Continue),
        ),
        (
            "crate",
            "use crate::lex;\n",
            TokenKind::Keyword(Keyword::Other),
        ),
        (
            "dyn",
            "fn f(handler: &dyn Fn(u32)) {}\n",
            TokenKind::Keyword(Keyword::Other),
        ),
        (
            "else",
            "fn f(flag: bool) {\n    if flag {\n    } else {\n    }\n}\n",
            TokenKind::Keyword(Keyword::BranchElse),
        ),
        (
            "enum",
            "enum Kind {\n    Null,\n}\n",
            TokenKind::Keyword(Keyword::Struct),
        ),
        (
            "extern",
            "extern \"C\" fn f() {}\n",
            TokenKind::Keyword(Keyword::Other),
        ),
        (
            "false",
            "const FLAG: bool = false;\n",
            TokenKind::Identifier,
        ),
        ("fn", "fn f() {}\n", TokenKind::Keyword(Keyword::Function)),
        (
            "for",
            "fn f() {\n    for index in 0..4 {\n    }\n}\n",
            TokenKind::Keyword(Keyword::Loop),
        ),
        (
            "if",
            "fn f(flag: bool) {\n    if flag {\n    }\n}\n",
            TokenKind::Keyword(Keyword::Branch),
        ),
        (
            "impl",
            "impl Store {\n}\n",
            TokenKind::Keyword(Keyword::Struct),
        ),
        (
            "in",
            "fn f() {\n    for index in 0..4 {\n    }\n}\n",
            TokenKind::Keyword(Keyword::Other),
        ),
        (
            "let",
            "fn f() {\n    let value = 1;\n}\n",
            TokenKind::Keyword(Keyword::Declare),
        ),
        (
            "loop",
            "fn f() {\n    loop {\n        break;\n    }\n}\n",
            TokenKind::Keyword(Keyword::LoopUnbounded),
        ),
        (
            "match",
            "fn f(value: u32) {\n    match value {\n        _ => {}\n    }\n}\n",
            TokenKind::Keyword(Keyword::Match),
        ),
        (
            "mod",
            "mod inner {\n}\n",
            TokenKind::Keyword(Keyword::Other),
        ),
        (
            "move",
            "fn f() {\n    let closure = move || 1;\n}\n",
            TokenKind::Keyword(Keyword::Other),
        ),
        (
            "mut",
            "fn f() {\n    let mut value = 1;\n}\n",
            TokenKind::Keyword(Keyword::Mutable),
        ),
        ("pub", "pub fn f() {}\n", TokenKind::Keyword(Keyword::Other)),
        (
            "ref",
            "fn f(value: u32) {\n    let ref held = value;\n}\n",
            TokenKind::Keyword(Keyword::Other),
        ),
        (
            "return",
            "fn f() -> u32 {\n    return 0;\n}\n",
            TokenKind::Keyword(Keyword::Return),
        ),
        (
            "self",
            "impl Store {\n    fn read(self) {}\n}\n",
            TokenKind::Keyword(Keyword::Other),
        ),
        (
            "Self",
            "impl Store {\n    fn read() -> Self {\n        Store\n    }\n}\n",
            TokenKind::Identifier,
        ),
        (
            "static",
            "static LIMIT: u32 = 4;\n",
            TokenKind::Keyword(Keyword::Constant),
        ),
        (
            "struct",
            "struct Store {\n}\n",
            TokenKind::Keyword(Keyword::Struct),
        ),
        (
            "super",
            "use super::lex;\n",
            TokenKind::Keyword(Keyword::Other),
        ),
        (
            "trait",
            "trait Read {\n}\n",
            TokenKind::Keyword(Keyword::Struct),
        ),
        ("true", "const FLAG: bool = true;\n", TokenKind::Identifier),
        (
            "type",
            "type Count = u32;\n",
            TokenKind::Keyword(Keyword::Other),
        ),
        (
            "unsafe",
            "unsafe fn f() {}\n",
            TokenKind::Keyword(Keyword::Other),
        ),
        ("use", "use std::io;\n", TokenKind::Keyword(Keyword::Import)),
        (
            "where",
            "fn f<T>(value: T)\nwhere\n    T: Copy,\n{\n}\n",
            TokenKind::Keyword(Keyword::Other),
        ),
        (
            "while",
            "fn f(flag: bool) {\n    while flag {\n    }\n}\n",
            TokenKind::Keyword(Keyword::Loop),
        ),
    ];

    const KEYWORDS_RESERVED: &[(&str, &str, TokenKind)] = &[
        (
            "abstract",
            "fn f() {\n    abstract;\n}\n",
            TokenKind::Identifier,
        ),
        (
            "become",
            "fn f() {\n    become;\n}\n",
            TokenKind::Identifier,
        ),
        ("box", "fn f() {\n    box;\n}\n", TokenKind::Identifier),
        ("do", "fn f() {\n    do;\n}\n", TokenKind::Identifier),
        ("final", "fn f() {\n    final;\n}\n", TokenKind::Identifier),
        ("gen", "fn f() {\n    gen;\n}\n", TokenKind::Identifier),
        ("macro", "fn f() {\n    macro;\n}\n", TokenKind::Identifier),
        (
            "override",
            "fn f() {\n    override;\n}\n",
            TokenKind::Identifier,
        ),
        ("priv", "fn f() {\n    priv;\n}\n", TokenKind::Identifier),
        ("try", "fn f() {\n    try;\n}\n", TokenKind::Identifier),
        (
            "typeof",
            "fn f() {\n    typeof;\n}\n",
            TokenKind::Identifier,
        ),
        (
            "unsized",
            "fn f() {\n    unsized;\n}\n",
            TokenKind::Identifier,
        ),
        (
            "virtual",
            "fn f() {\n    virtual;\n}\n",
            TokenKind::Identifier,
        ),
        ("yield", "fn f() {\n    yield;\n}\n", TokenKind::Identifier),
    ];

    const PUNCTUATION: &[(&str, &str, TokenKind)] = &[
        (
            "!",
            "fn f(flag: bool) -> bool {\n    !flag\n}\n",
            TokenKind::Punctuation(Punctuation::Bang),
        ),
        (
            "!=",
            "fn f(a: u32, b: u32) -> bool {\n    a != b\n}\n",
            TokenKind::Punctuation(Punctuation::NotEqual),
        ),
        (
            "&",
            "fn f(value: &u32) {}\n",
            TokenKind::Punctuation(Punctuation::Ampersand),
        ),
        (
            "&&",
            "fn f(a: bool, b: bool) -> bool {\n    a && b\n}\n",
            TokenKind::Punctuation(Punctuation::AmpersandDouble),
        ),
        (
            "(",
            "fn f() {}\n",
            TokenKind::Punctuation(Punctuation::ParenOpen),
        ),
        (
            ")",
            "fn f() {}\n",
            TokenKind::Punctuation(Punctuation::ParenClose),
        ),
        (
            "*",
            "fn f(a: u32, b: u32) -> u32 {\n    a * b\n}\n",
            TokenKind::Punctuation(Punctuation::Star),
        ),
        (
            "+",
            "fn f(a: u32, b: u32) -> u32 {\n    a + b\n}\n",
            TokenKind::Punctuation(Punctuation::Other),
        ),
        (
            ",",
            "fn f(a: u32, b: u32) {}\n",
            TokenKind::Punctuation(Punctuation::Comma),
        ),
        (
            "-",
            "fn f(a: u32, b: u32) -> u32 {\n    a - b\n}\n",
            TokenKind::Punctuation(Punctuation::Other),
        ),
        (
            "->",
            "fn f() -> u32 {\n    0\n}\n",
            TokenKind::Punctuation(Punctuation::Arrow),
        ),
        (
            ".",
            "fn f(value: Store) {\n    value.read();\n}\n",
            TokenKind::Punctuation(Punctuation::Dot),
        ),
        (
            "/",
            "fn f(a: u32, b: u32) -> u32 {\n    a / b\n}\n",
            TokenKind::Punctuation(Punctuation::Slash),
        ),
        (
            ":",
            "fn f(value: u32) {}\n",
            TokenKind::Punctuation(Punctuation::Colon),
        ),
        (
            ";",
            "fn f() {\n    let value = 1;\n}\n",
            TokenKind::Punctuation(Punctuation::Semicolon),
        ),
        (
            "<",
            "fn f(a: u32, b: u32) -> bool {\n    a < b\n}\n",
            TokenKind::Punctuation(Punctuation::Less),
        ),
        (
            "<=",
            "fn f(a: u32, b: u32) -> bool {\n    a <= b\n}\n",
            TokenKind::Punctuation(Punctuation::LessEqual),
        ),
        (
            "=",
            "fn f() {\n    let value = 1;\n}\n",
            TokenKind::Punctuation(Punctuation::Assign),
        ),
        (
            "==",
            "fn f(a: u32, b: u32) -> bool {\n    a == b\n}\n",
            TokenKind::Punctuation(Punctuation::Equal),
        ),
        (
            ">",
            "fn f(a: u32, b: u32) -> bool {\n    a > b\n}\n",
            TokenKind::Punctuation(Punctuation::Greater),
        ),
        (
            ">=",
            "fn f(a: u32, b: u32) -> bool {\n    a >= b\n}\n",
            TokenKind::Punctuation(Punctuation::GreaterEqual),
        ),
        (
            "[",
            "fn f(values: [u32; 4]) {}\n",
            TokenKind::Punctuation(Punctuation::BracketOpen),
        ),
        (
            "]",
            "fn f(values: [u32; 4]) {}\n",
            TokenKind::Punctuation(Punctuation::BracketClose),
        ),
        (
            "^",
            "fn f(a: u32, b: u32) -> u32 {\n    a ^ b\n}\n",
            TokenKind::Punctuation(Punctuation::Other),
        ),
        ("{", "fn f() {}\n", TokenKind::BlockStart),
        (
            "|",
            "fn f(a: u32, b: u32) -> u32 {\n    a | b\n}\n",
            TokenKind::Punctuation(Punctuation::Other),
        ),
        (
            "||",
            "fn f(a: bool, b: bool) -> bool {\n    a || b\n}\n",
            TokenKind::Punctuation(Punctuation::BarDouble),
        ),
        ("}", "fn f() {}\n", TokenKind::BlockEnd),
    ];

    #[test]
    fn an_escaped_quote_closes_its_character_literal() {
        let source = b"fn f(text: &str) -> bool {\n    text.contains('\\'')\n}\n";
        let tokens = tests_support::lex(&RUST, source);

        let literal = tokens
            .iter()
            .find(|token| token.kind == TokenKind::String)
            .expect("the literal is lexed");

        assert_eq!(literal.text(source), b"'\\''");
    }

    #[test]
    fn every_strict_keyword_of_the_reference_lexes_to_its_kind() {
        assert_eq!(KEYWORDS_STRICT.len(), 38);

        for (word, source, expected) in KEYWORDS_STRICT {
            assert_eq!(
                tests_support::kind_of(&RUST, source, word),
                *expected,
                "{word}"
            );
        }
    }

    #[test]
    fn every_reserved_keyword_of_the_reference_lexes_as_an_identifier() {
        assert_eq!(KEYWORDS_RESERVED.len(), 14);

        for (word, source, expected) in KEYWORDS_RESERVED {
            assert_eq!(
                tests_support::kind_of(&RUST, source, word),
                *expected,
                "{word}"
            );
        }
    }

    #[test]
    fn every_punctuation_of_the_reference_lexes_to_its_kind() {
        for (word, source, expected) in PUNCTUATION {
            assert_eq!(
                tests_support::kind_of(&RUST, source, word),
                *expected,
                "{word}"
            );
        }
    }

    #[test]
    fn a_function_lexes_to_its_parts() {
        let source = b"pub fn main() {\n    let value = 1;\n}\n";
        let tokens = tests_support::lex(&RUST, source);

        assert_eq!(tokens[0].kind, TokenKind::Keyword(Keyword::Other));
        assert_eq!(tokens[1].kind, TokenKind::Keyword(Keyword::Function));
        assert_eq!(tokens[2].kind, TokenKind::Identifier);
        assert_eq!(tokens[2].text(source), b"main");

        assert_eq!(
            tokens[3].kind,
            TokenKind::Punctuation(Punctuation::ParenOpen)
        );

        assert_eq!(tokens[5].kind, TokenKind::BlockStart);

        assert_eq!(
            tokens.last().expect("the block closes").kind,
            TokenKind::BlockEnd
        );
    }

    #[test]
    fn a_comment_covers_its_line() {
        let source = b"// a note\nfn f() {}\n";
        let tokens = tests_support::lex(&RUST, source);

        assert_eq!(tokens[0].kind, TokenKind::Comment);
        assert_eq!(tokens[0].text(source), b"// a note");
    }

    #[test]
    fn a_nested_block_comment_closes_once() {
        let source = b"/* outer /* inner */ still */ fn f() {}";
        let tokens = tests_support::lex(&RUST, source);

        assert_eq!(tokens[0].kind, TokenKind::Comment);
        assert_eq!(tokens[0].text(source), b"/* outer /* inner */ still */");
        assert_eq!(tokens[1].kind, TokenKind::Keyword(Keyword::Function));
    }

    #[test]
    fn a_raw_string_holds_its_hashes() {
        let source = br##"let text = r#"a "quoted" value"#;"##;
        let tokens = tests_support::lex(&RUST, source);

        assert_eq!(tokens[3].kind, TokenKind::String);
        assert_eq!(tokens[3].text(source), br##"r#"a "quoted" value"#"##);
    }

    #[test]
    fn a_lifetime_is_not_a_character() {
        let source = b"fn f<'a>(value: &'a str) -> char { 'x' }";
        let tokens = tests_support::lex(&RUST, source);

        let strings = tokens
            .iter()
            .filter(|token| token.kind == TokenKind::String)
            .count();

        assert_eq!(strings, 1);
    }

    #[test]
    #[expect(
        clippy::non_ascii_literal,
        reason = "the probe exists to be non-ASCII: one two-byte character and one non-BMP one"
    )]
    fn a_multi_byte_character_is_a_string() {
        let source = "let accent = 'é'; let face = '\u{1F600}';".as_bytes();
        let tokens = tests_support::lex(&RUST, source);

        let strings = tokens
            .iter()
            .filter(|token| token.kind == TokenKind::String)
            .collect::<Vec<_>>();

        assert_eq!(strings.len(), 2);
        assert_eq!(strings[0].text(source), "'é'".as_bytes());
        assert_eq!(strings[1].text(source), "'\u{1F600}'".as_bytes());
    }

    #[test]
    fn an_escaped_character_is_a_string() {
        let source = br"let line = '\n'; let face = '\u{1F600}';";
        let tokens = tests_support::lex(&RUST, source);

        let strings = tokens
            .iter()
            .filter(|token| token.kind == TokenKind::String)
            .collect::<Vec<_>>();

        assert_eq!(strings.len(), 2);
        assert_eq!(strings[0].text(source), br"'\n'");
        assert_eq!(strings[1].text(source), br"'\u{1F600}'");
    }

    #[test]
    fn a_character_past_the_byte_limit_is_not_a_string() {
        let source = b"let value = \'aaaaaaaaaaaaaaaa\';";
        let tokens = tests_support::lex(&RUST, source);

        let strings = tokens
            .iter()
            .filter(|token| token.kind == TokenKind::String)
            .count();

        assert_eq!(strings, 0);
    }

    #[test]
    fn an_escaped_character_stops_at_its_newline() {
        let source = b"let value = \'\\\nlet next = 1;";
        let tokens = tests_support::lex(&RUST, source);

        let strings = tokens
            .iter()
            .filter(|token| token.kind == TokenKind::String)
            .count();

        assert_eq!(strings, 0);
    }

    #[test]
    fn a_lifetime_after_a_quote_is_an_identifier() {
        let source = b"fn f<\'lifetime>() {}";
        let tokens = tests_support::lex(&RUST, source);

        let name = tokens
            .iter()
            .find(|token| token.text(source) == b"'lifetime")
            .expect("the lifetime name is a token");

        assert_eq!(name.kind, TokenKind::Identifier);
    }

    #[test]
    fn a_character_at_the_source_start_closes() {
        let source = b"\'x\'";
        let tokens = tests_support::lex(&RUST, source);

        assert_eq!(tokens.len(), 1);
        assert_eq!(tokens[0].kind, TokenKind::String);
        assert_eq!(tokens[0].length, 3);
    }

    #[test]
    fn a_block_comment_ending_in_a_star_runs_to_the_source_end() {
        let source = b"/* ending in a star *";
        let tokens = tests_support::lex(&RUST, source);

        assert_eq!(tokens.len(), 1);
        assert_eq!(tokens[0].kind, TokenKind::Comment);
        assert_eq!(tokens[0].length, 21);
    }

    #[test]
    fn a_raw_prefix_at_the_source_end_is_a_name() {
        let source = b"let value = r";
        let tokens = tests_support::lex(&RUST, source);
        let last = tokens.last().expect("the letter is a token");

        assert_eq!(last.kind, TokenKind::Identifier);
        assert_eq!(last.length, 1);
    }

    #[test]
    fn a_raw_prefix_with_hashes_at_the_source_end_is_a_name() {
        let source = b"let value = r##";
        let tokens = tests_support::lex(&RUST, source);

        let strings = tokens
            .iter()
            .filter(|token| token.kind == TokenKind::String)
            .count();

        assert_eq!(strings, 0);
    }

    #[test]
    fn a_character_at_the_source_end_closes() {
        let source = b"let value = 'x'";
        let tokens = tests_support::lex(&RUST, source);
        let last = tokens.last().expect("the character is a token");

        assert_eq!(last.kind, TokenKind::String);
        assert_eq!(last.offset, 12);
        assert_eq!(last.length, 3);
    }

    #[test]
    fn an_unclosed_character_at_the_source_end_is_not_a_string() {
        let source = b"let value = 'x";
        let tokens = tests_support::lex(&RUST, source);

        let strings = tokens
            .iter()
            .filter(|token| token.kind == TokenKind::String)
            .count();

        assert_eq!(strings, 0);
    }

    #[test]
    fn a_bare_quote_at_the_source_end_is_punctuation() {
        let source = b"let value = '";
        let tokens = tests_support::lex(&RUST, source);
        let last = tokens.last().expect("the quote is a token");

        assert_eq!(last.kind, TokenKind::Punctuation(Punctuation::Other));
        assert_eq!(last.length, 1);
    }

    #[test]
    fn an_escaped_character_at_the_source_end_closes() {
        let source = br"let line = '\n'";
        let tokens = tests_support::lex(&RUST, source);
        let last = tokens.last().expect("the character is a token");

        assert_eq!(last.kind, TokenKind::String);
        assert_eq!(last.text(source), br"'\n'");
    }

    #[test]
    fn a_nested_block_comment_closes_at_its_outer_end() {
        let source = b"/* outer /* inner */ still */ let value = 1;";
        let tokens = tests_support::lex(&RUST, source);

        assert_eq!(tokens[0].kind, TokenKind::Comment);
        assert_eq!(tokens[0].length, 29);
        assert_eq!(tokens[1].text(source), b"let");
    }

    #[test]
    fn an_unclosed_block_comment_runs_to_the_source_end() {
        let source = b"/* outer";
        let tokens = tests_support::lex(&RUST, source);

        assert_eq!(tokens.len(), 1);
        assert_eq!(tokens[0].kind, TokenKind::Comment);
        assert_eq!(tokens[0].length, 8);
    }

    #[test]
    fn a_two_character_quote_is_not_a_string() {
        let source = b"let value = 'ab';";
        let tokens = tests_support::lex(&RUST, source);

        let strings = tokens
            .iter()
            .filter(|token| token.kind == TokenKind::String)
            .count();

        assert_eq!(strings, 0);
    }

    #[test]
    fn an_assert_is_a_keyword() {
        let source = b"assert!(value > 0);";
        let tokens = tests_support::lex(&RUST, source);

        assert_eq!(tokens[0].kind, TokenKind::Keyword(Keyword::Assert));
        assert_eq!(tokens[1].kind, TokenKind::Punctuation(Punctuation::Bang));
    }

    #[test]
    fn a_prefixed_assertion_is_a_keyword() {
        let source = b"debug_assert!(value > 0);\nprop_assert_eq!(a, b);\n";
        let tokens = tests_support::lex(&RUST, source);

        let asserts = tokens
            .iter()
            .filter(|token| token.is_keyword(Keyword::Assert))
            .count();

        assert_eq!(asserts, 2);
    }

    #[test]
    fn an_assertion_word_without_a_bang_is_an_identifier() {
        for word in [
            &b"assert"[..],
            b"assert_eq",
            b"assert_ne",
            b"debug_assert",
            b"debug_assert_eq",
            b"debug_assert_ne",
        ] {
            let mut source = b"let ".to_vec();

            source.extend_from_slice(word);
            source.extend_from_slice(b" = 1;");

            let tokens = tests_support::lex(&RUST, &source);

            assert_eq!(
                tokens[1].kind,
                TokenKind::Identifier,
                "{}",
                String::from_utf8_lossy(word)
            );
        }
    }

    #[test]
    fn an_assertion_word_with_a_bang_is_a_keyword() {
        for word in [
            &b"assert"[..],
            b"assert_eq",
            b"assert_ne",
            b"debug_assert",
            b"debug_assert_eq",
            b"debug_assert_ne",
        ] {
            let mut source = word.to_vec();

            source.extend_from_slice(b"!(value);");

            let tokens = tests_support::lex(&RUST, &source);

            assert_eq!(
                tokens[0].kind,
                TokenKind::Keyword(Keyword::Assert),
                "{}",
                String::from_utf8_lossy(word)
            );
        }
    }

    #[test]
    fn a_raw_string_without_hashes_closes_at_its_quote() {
        let source = br#"let text = r"a value";"#;
        let tokens = tests_support::lex(&RUST, source);

        assert_eq!(tokens[3].kind, TokenKind::String);
        assert_eq!(tokens[3].text(source), br#"r"a value""#);
    }

    #[test]
    fn a_c_string_closes_where_a_string_closes() {
        let source = br#"let text = cr#"say "hi""#;
        let tokens = tests_support::lex(&RUST, source);

        assert_eq!(tokens[3].kind, TokenKind::String);
        assert_eq!(tokens[3].text(source), br#"cr#"say "hi""#);

        let plain = b"let text = c\"say\";\nfn later() {}\n";
        let plained = tests_support::lex(&RUST, plain);

        assert_eq!(plained[3].kind, TokenKind::String);
        assert_eq!(plained[3].text(plain), b"c\"say\"");

        assert_eq!(
            plained
                .iter()
                .find(|token| token.text(plain) == b"fn")
                .expect("the function survives the literal")
                .kind,
            TokenKind::Keyword(Keyword::Function)
        );
    }

    #[test]
    fn a_nine_hash_raw_string_is_still_a_string() {
        let source = br##########"let text = r#########"a value"#########;"##########;
        let tokens = tests_support::lex(&RUST, source);

        assert_eq!(tokens[3].kind, TokenKind::String);
    }

    #[test]
    fn a_union_call_is_not_a_struct() {
        assert_eq!(
            tests_support::kind_of(&RUST, "let both = left.union(&right);\n", "union"),
            TokenKind::Identifier
        );
    }

    #[test]
    fn a_raw_identifier_does_not_promote_to_a_keyword() {
        for (source, word) in [("let r#fn = 1;\n", "fn"), ("let r#struct = 1;\n", "struct")] {
            assert_eq!(
                tests_support::kind_of(&RUST, source, word),
                TokenKind::Identifier,
                "{source:?}"
            );
        }

        assert_eq!(
            tests_support::kind_of(&RUST, "fn helper() {}\n", "fn"),
            TokenKind::Keyword(Keyword::Function)
        );
    }

    #[test]
    fn a_shebang_is_a_comment_and_an_inner_attribute_is_not() {
        let source = b"#!/usr/bin/env cargo\nfn main() {}\n";
        let tokens = tests_support::lex(&RUST, source);

        assert_eq!(tokens[0].kind, TokenKind::Comment);
        assert_eq!(tokens[0].text(source), b"#!/usr/bin/env cargo");

        let attribute = b"#![allow(dead_code)]\nfn main() {}\n";
        let attributed = tests_support::lex(&RUST, attribute);

        assert_ne!(attributed[0].kind, TokenKind::Comment);
    }

    #[test]
    fn a_long_unicode_escape_stays_inside_its_character_literal() {
        let source = b"let face = '\\u{01_F600}';\n";
        let tokens = tests_support::lex(&RUST, source);

        assert_eq!(tokens[3].kind, TokenKind::String);
        assert_eq!(tokens[3].text(source), b"'\\u{01_F600}'");

        assert!(
            tokens
                .iter()
                .all(|token| token.kind != TokenKind::BlockStart)
        );
    }

    #[test]
    fn a_raw_string_stops_taking_hashes_at_the_limit() {
        let inside = "#".repeat(HASH_COUNT_MAX);
        let outside = "#".repeat(HASH_COUNT_MAX + 1);
        let held = format!("let text = r{inside}\"a value\"{inside};\n");
        let over = format!("let text = r{outside}\"a value\"{outside};\n");
        let bytes = held.as_bytes();
        let tokens = tests_support::lex(&RUST, bytes);

        assert_eq!(tokens[3].kind, TokenKind::String);

        assert_eq!(
            tokens[3].text(bytes),
            format!("r{inside}\"a value\"{inside}").as_bytes()
        );

        let bytes_over = over.as_bytes();
        let overrun = tests_support::lex(&RUST, bytes_over);

        assert_eq!(
            overrun[3].kind,
            TokenKind::Identifier,
            "{:?}",
            overrun[3].kind
        );

        assert_eq!(overrun[3].text(bytes_over), b"r");
    }

    #[test]
    fn an_escaped_character_that_never_closes_stops_at_the_source_end() {
        let source = b"let value = \'\\n";
        let tokens = tests_support::lex(&RUST, source);

        assert!(!tokens.is_empty());

        let bare = b"let value = \'\\";
        let stopped = tests_support::lex(&RUST, bare);

        assert!(!stopped.is_empty());
    }

    #[test]
    fn a_raw_string_needs_as_many_hashes_to_close() {
        let source = br##"let text = r#"a "quoted" value"#; let next = 1;"##;
        let tokens = tests_support::lex(&RUST, source);

        assert_eq!(tokens[3].text(source), br##"r#"a "quoted" value"#"##);
        assert_eq!(tokens[5].text(source), b"let");
    }

    #[test]
    fn an_unclosed_raw_string_runs_to_the_source_end() {
        let source = br#"let text = r#"unterminated"#;
        let tokens = tests_support::lex(&RUST, source);
        let last = tokens.last().expect("the raw string is a token");

        assert_eq!(last.kind, TokenKind::String);
        assert_eq!(last.offset, 11);
    }

    #[test]
    fn a_raw_letter_without_a_quote_is_a_name() {
        let source = b"let round = 1;";
        let tokens = tests_support::lex(&RUST, source);

        assert_eq!(tokens[1].kind, TokenKind::Identifier);
        assert_eq!(tokens[1].text(source), b"round");
    }

    #[test]
    fn a_raw_letter_with_hashes_but_no_quote_is_a_name() {
        let source = b"let value = r#type;";
        let tokens = tests_support::lex(&RUST, source);

        let strings = tokens
            .iter()
            .filter(|token| token.kind == TokenKind::String)
            .count();

        assert_eq!(strings, 0);
    }

    #[test]
    fn a_byte_raw_string_carries_its_prefix() {
        let source = br##"let text = br#"a "quoted" value"#;"##;
        let tokens = tests_support::lex(&RUST, source);

        assert_eq!(tokens[3].kind, TokenKind::String);
        assert_eq!(tokens[3].text(source), br##"br#"a "quoted" value"#"##);
    }

    #[test]
    fn a_byte_letter_before_a_name_is_not_a_raw_string() {
        let source = b"let brush = 1;";
        let tokens = tests_support::lex(&RUST, source);

        assert_eq!(tokens[1].kind, TokenKind::Identifier);
        assert_eq!(tokens[1].text(source), b"brush");
    }

    #[test]
    fn a_prefixed_assertion_without_a_bang_is_an_identifier() {
        let source = b"let prop_assert_eq = value;";
        let tokens = tests_support::lex(&RUST, source);

        let asserts = tokens
            .iter()
            .filter(|token| token.is_keyword(Keyword::Assert))
            .count();

        assert_eq!(asserts, 0);
    }
}
