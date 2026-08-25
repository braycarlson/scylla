use crate::language::Lexer;
use crate::scan::{
    identifier_scan,
    is_identifier_start_at,
    line_scan,
    line_scan_trimmed,
    number_scan,
    punctuation_of,
    string_scan,
    word_in,
};
use crate::token::{Keyword, Lex, Punctuation, TokenKind, Tokens};

pub static GO: GoLexer = GoLexer;

const ASSERT_METHODS: &[&[u8]] = &[
    b"Contains",
    b"Empty",
    b"Equal",
    b"EqualError",
    b"EqualValues",
    b"Error",
    b"ErrorAs",
    b"ErrorIs",
    b"False",
    b"Greater",
    b"GreaterOrEqual",
    b"Len",
    b"Less",
    b"LessOrEqual",
    b"Nil",
    b"NoError",
    b"NotContains",
    b"NotEmpty",
    b"NotEqual",
    b"NotNil",
    b"NotZero",
    b"Panics",
    b"Positive",
    b"Same",
    b"True",
    b"Zero",
];

const RECEIVER_BYTES_MAX: usize = 256;
const DECLARE_WORD: &[u8] = b"func";

pub struct GoLexer;

impl Lexer for GoLexer {
    fn extensions(&self) -> &'static [&'static [u8]] {
        &[b"go"]
    }

    fn identifier(&self) -> &'static str {
        "go"
    }

    fn lex(&self, source: &[u8], tokens: &mut Tokens) -> Lex {
        assert!(u32::try_from(source.len()).is_ok());

        let mut offset = crate::scan::mark_width(source);
        let mut ends = false;

        while offset < source.len() {
            let byte = source[offset];

            if byte == b'\n' {
                if ends {
                    if !tokens.push(source, TokenKind::Newline, offset, 1) {
                        return Lex::Truncated;
                    }

                    ends = false;
                }

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

            if ends && comment_spans_lines(kind, &source[offset..end]) {
                if !tokens.push(source, TokenKind::Newline, end, 0) {
                    return Lex::Truncated;
                }

                ends = false;
            }

            offset = end;
        }

        if ends && !tokens.push(source, TokenKind::Newline, source.len(), 0) {
            return Lex::Truncated;
        }

        Lex::Complete
    }
}

pub(crate) fn word_of(text: &[u8]) -> Option<TokenKind> {
    let keyword = match text {
        b"break" => Keyword::Break,
        b"const" => Keyword::Constant,
        b"continue" => Keyword::Continue,
        b"else" => Keyword::BranchElse,
        b"goto" => Keyword::Goto,
        b"if" => Keyword::Branch,
        b"import" => Keyword::Import,
        b"return" => Keyword::Return,
        b"select" | b"switch" => Keyword::Match,
        b"struct" | b"type" => Keyword::Struct,
        b"var" => Keyword::Mutable,
        b"case" | b"chan" | b"default" | b"defer" => Keyword::Other,
        b"fallthrough" | b"go" | b"interface" | b"map" => Keyword::Other,
        b"package" | b"range" => Keyword::Other,
        _ => return None,
    };

    Some(TokenKind::Keyword(keyword))
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

fn comment_spans_lines(kind: TokenKind, text: &[u8]) -> bool {
    kind == TokenKind::Comment && text.contains(&b'\n')
}

fn ends_statement(kind: TokenKind, text: &[u8]) -> bool {
    match kind {
        TokenKind::BlockEnd | TokenKind::Identifier | TokenKind::Number | TokenKind::String => true,
        TokenKind::Keyword(keyword) => {
            matches!(
                keyword,
                Keyword::Assert | Keyword::Break | Keyword::Continue | Keyword::Return
            ) || text == b"fallthrough"
        }
        TokenKind::Punctuation(_) => matches!(text, b")" | b"]" | b"++" | b"--" | b":"),
        TokenKind::Comment | TokenKind::BlockStart | TokenKind::Newline => false,
    }
}

fn function_keyword(source: &[u8], end: usize) -> Keyword {
    let start = space_skip(source, end);

    if start >= source.len() {
        return Keyword::Lambda;
    }

    if is_identifier_start_at(source, start) {
        return Keyword::Function;
    }

    if source[start] != b'(' {
        return Keyword::Lambda;
    }

    let Some(close) = paren_close(source, start) else {
        return Keyword::Lambda;
    };

    let name = space_skip(source, close + 1);

    if !is_identifier_start_at(source, name) {
        return Keyword::Lambda;
    }

    let stop = identifier_scan(source, name);

    if names_a_type(&source[name..stop]) {
        return Keyword::Lambda;
    }

    let after = space_skip(source, stop);

    if after < source.len() && source[after] == b'(' {
        return Keyword::Function;
    }

    Keyword::Lambda
}

fn names_a_type(word: &[u8]) -> bool {
    word == DECLARE_WORD || word_of(word).is_some()
}

fn declares_a_name(source: &[u8], start: usize) -> bool {
    let cursor = space_skip_back(source, start);

    if follows_word(source, cursor, DECLARE_WORD) {
        return true;
    }

    if cursor == 0 || source[cursor - 1] != b')' {
        return false;
    }

    let Some(open) = paren_open(source, cursor - 1) else {
        return false;
    };

    follows_word(source, space_skip_back(source, open), DECLARE_WORD)
}

fn binds_a_name(source: &[u8], end: usize) -> bool {
    let cursor = space_skip_forward(source, end);

    source.get(cursor) == Some(&b':') && source.get(cursor + 1) == Some(&b'=')
}

fn follows_word(source: &[u8], cursor: usize, word: &[u8]) -> bool {
    assert!(cursor <= source.len());
    assert!(!word.is_empty());

    cursor >= word.len()
        && &source[cursor - word.len()..cursor] == word
        && !source[..cursor - word.len()]
            .last()
            .copied()
            .is_some_and(crate::scan::is_identifier_part)
}

fn paren_open(source: &[u8], close: usize) -> Option<usize> {
    assert_eq!(source[close], b')');

    let floor = close.saturating_sub(RECEIVER_BYTES_MAX);
    let mut depth = 0_u32;
    let mut offset = close + 1;

    while offset > floor {
        offset -= 1;

        if source[offset] == b')' {
            depth += 1;
        }

        if source[offset] == b'(' {
            depth -= 1;

            if depth == 0 {
                return Some(offset);
            }
        }
    }

    None
}

fn space_skip_back(source: &[u8], start: usize) -> usize {
    let mut cursor = start;

    while cursor > 0 && source[cursor - 1] == b' ' {
        cursor -= 1;
    }

    cursor
}

fn space_skip_forward(source: &[u8], start: usize) -> usize {
    let mut cursor = start;

    while cursor < source.len() && source[cursor] == b' ' {
        cursor += 1;
    }

    cursor
}

fn is_assert_name(text: &[u8], source: &[u8], end: usize) -> bool {
    if text == b"assert" {
        return true;
    }

    if text != b"require" {
        return false;
    }

    if source.get(end) != Some(&b'.') {
        return false;
    }

    let start = end + 1;

    if !is_identifier_start_at(source, start) {
        return false;
    }

    let stop = identifier_scan(source, start);

    word_in(ASSERT_METHODS, &source[start..stop])
}

fn loop_keyword(source: &[u8], end: usize) -> Keyword {
    let start = space_skip(source, end);

    if start < source.len() && source[start] == b'{' {
        return Keyword::LoopUnbounded;
    }

    Keyword::Loop
}

fn paren_close(source: &[u8], open: usize) -> Option<usize> {
    assert_eq!(source[open], b'(');

    let limit = source.len().min(open + RECEIVER_BYTES_MAX);
    let mut depth = 0_u32;
    let mut offset = open;

    while offset < limit {
        if source[offset] == b'(' {
            depth += 1;
        }

        if source[offset] == b')' {
            depth -= 1;

            if depth == 0 {
                return Some(offset);
            }
        }

        offset += 1;
    }

    None
}

fn space_skip(source: &[u8], start: usize) -> usize {
    let mut offset = start;

    while offset < source.len() {
        let byte = source[offset];

        if byte.is_ascii_whitespace() {
            offset += 1;

            continue;
        }

        if byte == b'/' && source.get(offset + 1) == Some(&b'/') {
            offset = line_scan(source, offset);

            continue;
        }

        if byte == b'/' && source.get(offset + 1) == Some(&b'*') {
            offset = comment_block_scan(source, offset);

            continue;
        }

        break;
    }

    offset
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
        return (TokenKind::String, string_scan(source, offset, b'"'));
    }

    if byte == b'\'' {
        return (TokenKind::String, string_scan(source, offset, b'\''));
    }

    if byte == b'`' {
        return (TokenKind::String, string_raw_scan(source, offset));
    }

    if byte == b':' && next == Some(b'=') {
        return (
            TokenKind::Punctuation(Punctuation::AssignDeclare),
            offset + 2,
        );
    }

    if (byte == b'+' && next == Some(b'+')) || (byte == b'-' && next == Some(b'-')) {
        return (TokenKind::Punctuation(Punctuation::Other), offset + 2);
    }

    if is_identifier_start_at(source, offset) {
        let end = identifier_scan(source, offset);
        let text = &source[offset..end];

        if text == b"func" {
            return (TokenKind::Keyword(function_keyword(source, end)), end);
        }

        if text == b"for" {
            return (TokenKind::Keyword(loop_keyword(source, end)), end);
        }

        if is_assert_name(text, source, end)
            && !declares_a_name(source, offset)
            && !binds_a_name(source, end)
        {
            return (TokenKind::Keyword(Keyword::Assert), end);
        }

        return match word_of(text) {
            Some(kind) => (kind, end),
            None => (TokenKind::Identifier, end),
        };
    }

    if byte.is_ascii_digit() {
        return (TokenKind::Number, number_scan(source, offset));
    }

    let (punctuation, length) = punctuation_of(source, offset);

    (TokenKind::Punctuation(punctuation), offset + length)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::lex::tests_support;

    fn strings_of(source: &[u8]) -> Vec<Vec<u8>> {
        let tokens = tests_support::lex(&GO, source);

        tokens
            .iter()
            .filter(|token| token.kind == TokenKind::String)
            .map(|token| token.text(source).to_vec())
            .collect()
    }

    #[test]
    fn a_rune_literal_ends_where_go_scanner_ends_it() {
        let source = b"func f() {\n\tr := 'a'\n\tq := '\\''\n\tw := '\\U0001F600'\n}\n";

        assert_eq!(
            strings_of(source),
            vec![
                b"'a'".to_vec(),
                b"'\\''".to_vec(),
                b"'\\U0001F600'".to_vec()
            ]
        );
    }

    #[test]
    fn a_stray_apostrophe_closes_at_the_next_one_and_stops_at_the_line() {
        let paired = b"func f() {\n\ts := 'don't\n}\n";

        assert_eq!(strings_of(paired), vec![b"'don'".to_vec()]);

        let alone = b"func f() {\n\ts := 'a\n}\n";

        assert_eq!(strings_of(alone), vec![b"'a".to_vec()]);

        let ended = b"func f() {\n\ts := 'a";

        assert_eq!(strings_of(ended), vec![b"'a".to_vec()]);
    }

    #[test]
    fn a_short_declaration_binds_only_where_both_bytes_stand() {
        assert!(binds_a_name(b"assert := f", 6));
        assert!(binds_a_name(b"assert:= f", 6));
        assert!(!binds_a_name(b"assert = f", 6));
        assert!(!binds_a_name(b"assert : f", 6));
        assert!(!binds_a_name(b"assert", 6));
        assert!(!binds_a_name(b"assert :", 6));
    }

    #[test]
    fn a_blank_run_forward_stops_at_the_first_byte_that_is_not_a_space() {
        assert_eq!(space_skip_forward(b"   x", 0), 3);
        assert_eq!(space_skip_forward(b"x  ", 0), 0);
        assert_eq!(space_skip_forward(b"   ", 0), 3);
        assert_eq!(space_skip_forward(b"", 0), 0);
        assert_eq!(space_skip_forward(b" \t ", 0), 1);
        assert_eq!(space_skip_forward(b"a  b", 1), 3);
    }

    #[test]
    fn a_receiver_list_opens_where_its_own_parenthesis_does() {
        assert_eq!(paren_open(b"(a)", 2), Some(0));
        assert_eq!(paren_open(b"(a (b))", 6), Some(0));
        assert_eq!(paren_open(b"x (a)", 4), Some(2));
        assert_eq!(paren_open(b")", 0), None);
    }

    const KEYWORDS: &[(&str, &str, Keyword)] = &[
        (
            "break",
            "func f() {\n\tfor {\n\t\tbreak\n\t}\n}\n",
            Keyword::Break,
        ),
        (
            "case",
            "func f(v int) {\n\tswitch v {\n\tcase 1:\n\t}\n}\n",
            Keyword::Other,
        ),
        ("chan", "func f(c chan int) {\n}\n", Keyword::Other),
        ("const", "const limit = 4\n", Keyword::Constant),
        (
            "continue",
            "func f() {\n\tfor i := 0; i < 4; i++ {\n\t\tcontinue\n\t}\n}\n",
            Keyword::Continue,
        ),
        (
            "default",
            "func f(v int) {\n\tswitch v {\n\tdefault:\n\t}\n}\n",
            Keyword::Other,
        ),
        (
            "defer",
            "func f(c chan int) {\n\tdefer close(c)\n}\n",
            Keyword::Other,
        ),
        (
            "else",
            "func f(v int) {\n\tif v > 0 {\n\t} else {\n\t}\n}\n",
            Keyword::BranchElse,
        ),
        (
            "fallthrough",
            "func f(v int) {\n\tswitch v {\n\tcase 1:\n\t\tfallthrough\n\t}\n}\n",
            Keyword::Other,
        ),
        (
            "for",
            "func f() {\n\tfor i := 0; i < 4; i++ {\n\t}\n}\n",
            Keyword::Loop,
        ),
        ("func", "func f() {\n}\n", Keyword::Function),
        (
            "go",
            "func f(c chan int) {\n\tgo close(c)\n}\n",
            Keyword::Other,
        ),
        ("goto", "func f() {\n\tgoto done\ndone:\n}\n", Keyword::Goto),
        (
            "if",
            "func f(v int) {\n\tif v > 0 {\n\t}\n}\n",
            Keyword::Branch,
        ),
        ("import", "import \"fmt\"\n", Keyword::Import),
        ("interface", "type Reader interface {\n}\n", Keyword::Other),
        ("map", "func f(m map[string]int) {\n}\n", Keyword::Other),
        ("package", "package fixture\n", Keyword::Other),
        (
            "range",
            "func f(v []int) {\n\tfor _, x := range v {\n\t}\n}\n",
            Keyword::Other,
        ),
        ("return", "func f() int {\n\treturn 0\n}\n", Keyword::Return),
        ("select", "func f() {\n\tselect {\n\t}\n}\n", Keyword::Match),
        ("struct", "type Point struct {\n}\n", Keyword::Struct),
        (
            "switch",
            "func f(v int) {\n\tswitch v {\n\t}\n}\n",
            Keyword::Match,
        ),
        ("type", "type Count int\n", Keyword::Struct),
        ("var", "var count = 0\n", Keyword::Mutable),
    ];

    const PUNCTUATION: &[(&str, &str, TokenKind)] = &[
        (
            "!",
            "func f(v bool) bool {\n\treturn !v\n}\n",
            TokenKind::Punctuation(Punctuation::Bang),
        ),
        (
            "!=",
            "func f(a int, b int) bool {\n\treturn a != b\n}\n",
            TokenKind::Punctuation(Punctuation::NotEqual),
        ),
        (
            "&",
            "func f(a int, b int) int {\n\treturn a & b\n}\n",
            TokenKind::Punctuation(Punctuation::Ampersand),
        ),
        (
            "&&",
            "func f(a bool, b bool) bool {\n\treturn a && b\n}\n",
            TokenKind::Punctuation(Punctuation::AmpersandDouble),
        ),
        (
            "(",
            "func f() {\n}\n",
            TokenKind::Punctuation(Punctuation::ParenOpen),
        ),
        (
            ")",
            "func f() {\n}\n",
            TokenKind::Punctuation(Punctuation::ParenClose),
        ),
        (
            "*",
            "func f(a int, b int) int {\n\treturn a * b\n}\n",
            TokenKind::Punctuation(Punctuation::Star),
        ),
        (
            "+",
            "func f(a int, b int) int {\n\treturn a + b\n}\n",
            TokenKind::Punctuation(Punctuation::Other),
        ),
        (
            "++",
            "func f() {\n\tfor i := 0; i < 4; i++ {\n\t}\n}\n",
            TokenKind::Punctuation(Punctuation::Other),
        ),
        (
            ",",
            "func f(a int, b int) {\n}\n",
            TokenKind::Punctuation(Punctuation::Comma),
        ),
        (
            "-",
            "func f(a int, b int) int {\n\treturn a - b\n}\n",
            TokenKind::Punctuation(Punctuation::Other),
        ),
        (
            "--",
            "func f() {\n\tfor i := 4; i > 0; i-- {\n\t}\n}\n",
            TokenKind::Punctuation(Punctuation::Other),
        ),
        (
            ".",
            "func f() {\n\tfmt.Println()\n}\n",
            TokenKind::Punctuation(Punctuation::Dot),
        ),
        (
            "/",
            "func f(a int, b int) int {\n\treturn a / b\n}\n",
            TokenKind::Punctuation(Punctuation::Slash),
        ),
        (
            ":",
            "func f(v int) {\n\tswitch v {\n\tcase 1:\n\t}\n}\n",
            TokenKind::Punctuation(Punctuation::Colon),
        ),
        (
            ":=",
            "func f() {\n\tcount := 0\n}\n",
            TokenKind::Punctuation(Punctuation::AssignDeclare),
        ),
        (
            ";",
            "func f() {\n\tfor i := 0; i < 4; i++ {\n\t}\n}\n",
            TokenKind::Punctuation(Punctuation::Semicolon),
        ),
        (
            "<",
            "func f(a int, b int) bool {\n\treturn a < b\n}\n",
            TokenKind::Punctuation(Punctuation::Less),
        ),
        (
            "<=",
            "func f(a int, b int) bool {\n\treturn a <= b\n}\n",
            TokenKind::Punctuation(Punctuation::LessEqual),
        ),
        (
            "=",
            "func f() {\n\tvar count int\n\tcount = 1\n}\n",
            TokenKind::Punctuation(Punctuation::Assign),
        ),
        (
            "==",
            "func f(a int, b int) bool {\n\treturn a == b\n}\n",
            TokenKind::Punctuation(Punctuation::Equal),
        ),
        (
            ">",
            "func f(a int, b int) bool {\n\treturn a > b\n}\n",
            TokenKind::Punctuation(Punctuation::Greater),
        ),
        (
            ">=",
            "func f(a int, b int) bool {\n\treturn a >= b\n}\n",
            TokenKind::Punctuation(Punctuation::GreaterEqual),
        ),
        (
            "[",
            "func f(v []int) {\n}\n",
            TokenKind::Punctuation(Punctuation::BracketOpen),
        ),
        (
            "]",
            "func f(v []int) {\n}\n",
            TokenKind::Punctuation(Punctuation::BracketClose),
        ),
        (
            "^",
            "func f(a int, b int) int {\n\treturn a ^ b\n}\n",
            TokenKind::Punctuation(Punctuation::Other),
        ),
        ("{", "func f() {\n}\n", TokenKind::BlockStart),
        (
            "|",
            "func f(a int, b int) int {\n\treturn a | b\n}\n",
            TokenKind::Punctuation(Punctuation::Other),
        ),
        (
            "||",
            "func f(a bool, b bool) bool {\n\treturn a || b\n}\n",
            TokenKind::Punctuation(Punctuation::BarDouble),
        ),
        ("}", "func f() {\n}\n", TokenKind::BlockEnd),
    ];

    #[test]
    fn every_keyword_of_the_specification_lexes_to_its_kind() {
        assert_eq!(KEYWORDS.len(), 25);

        for (word, source, expected) in KEYWORDS {
            assert_eq!(
                tests_support::kind_of(&GO, source, word),
                TokenKind::Keyword(*expected),
                "{word}"
            );
        }
    }

    #[test]
    fn the_channel_arrow_lexes_as_two_tokens() {
        let source = b"func f(c chan int) {\n\tc <- 1\n}\n";
        let tokens = tests_support::lex(&GO, source);

        let arrow = tokens
            .iter()
            .position(|token| token.text(source) == b"<")
            .expect("the arrow opens with a less-than");

        assert_eq!(
            tokens[arrow].kind,
            TokenKind::Punctuation(Punctuation::Less)
        );

        assert_eq!(
            tokens[arrow + 1].kind,
            TokenKind::Punctuation(Punctuation::Other)
        );
    }

    #[test]
    fn a_statement_ending_word_takes_a_newline() {
        for word in [&b"break"[..], b"continue", b"return", b"fallthrough"] {
            let mut source = b"func f() {\n\t".to_vec();

            source.extend_from_slice(word);
            source.extend_from_slice(b"\n}\n");

            let tokens = tests_support::lex(&GO, &source);

            let index = tokens
                .iter()
                .position(|token| token.text(&source) == word)
                .expect("the word is a token");

            assert_eq!(
                tokens[index + 1].kind,
                TokenKind::Newline,
                "{}",
                String::from_utf8_lossy(word)
            );
        }
    }

    #[test]
    fn a_statement_ending_punctuation_takes_a_newline() {
        for tail in [&b")"[..], b"]", b"++", b"--"] {
            let mut source = b"func f() {\n\tvalues".to_vec();

            source.extend_from_slice(tail);
            source.extend_from_slice(b"\n}\n");

            let tokens = tests_support::lex(&GO, &source);

            let index = tokens
                .iter()
                .rposition(|token| token.text(&source) == tail)
                .expect("the punctuation is a token");

            assert_eq!(
                tokens[index + 1].kind,
                TokenKind::Newline,
                "{}",
                String::from_utf8_lossy(tail)
            );
        }
    }

    #[test]
    fn an_opening_word_takes_no_newline() {
        let source = b"func f() {\n\tvar\n\tvalue = 1\n}\n";
        let tokens = tests_support::lex(&GO, source);

        let index = tokens
            .iter()
            .position(|token| token.text(source) == b"var")
            .expect("the word is a token");

        assert_ne!(tokens[index + 1].kind, TokenKind::Newline);
    }

    #[test]
    fn a_function_literal_returning_a_function_is_not_a_declaration() {
        let source = b"var build = func() func(int) int {\n\treturn nil\n}\n";
        let tokens = tests_support::lex(&GO, source);

        let kinds = tokens
            .iter()
            .filter(|token| token.text(source) == b"func")
            .map(|token| token.kind)
            .collect::<Vec<_>>();

        assert_eq!(
            kinds,
            vec![
                TokenKind::Keyword(Keyword::Lambda),
                TokenKind::Keyword(Keyword::Lambda)
            ]
        );
    }

    #[test]
    fn a_general_comment_that_spans_lines_acts_as_a_newline() {
        let spanning = b"func f() {\n\ta := 1 /* note\n\t*/ b := a\n}\n";
        let inline = b"func f() {\n\ta := 1 /* note */ b := a\n}\n";

        assert_eq!(newlines(spanning), newlines(inline) + 1);
    }

    #[test]
    fn a_last_statement_without_a_trailing_newline_still_ends() {
        assert_eq!(newlines(b"func f() {\n\ta := 1\n}"), 2);
        assert_eq!(newlines(b"func f() {\n\ta := 1\n}\n"), 2);
    }

    #[test]
    fn a_colon_ends_a_statement_though_the_specification_does_not() {
        let source =
            b"func f(v int) int {\n\tswitch v {\n\tcase 1:\n\t\treturn 2\n\t}\n\treturn 0\n}\n";

        let tokens = tests_support::lex(&GO, source);

        let index = tokens
            .iter()
            .position(|token| token.text(source) == b":")
            .expect("the colon is a token");

        assert_eq!(tokens[index + 1].kind, TokenKind::Newline);
    }

    #[test]
    fn a_method_named_assert_keeps_its_name() {
        let source = b"func (t *T) assert(ok bool) {\n}\n";
        let tokens = tests_support::lex(&GO, source);

        let index = tokens
            .iter()
            .position(|token| token.text(source) == b"assert")
            .expect("the name is a token");

        assert_eq!(tokens[index].kind, TokenKind::Identifier);
        assert_eq!(tokens[0].kind, TokenKind::Keyword(Keyword::Function));
    }

    #[test]
    fn a_bound_assert_name_keeps_its_name() {
        let source = b"func f() {\n\tassert := func(ok bool) {}\n\tassert(true)\n}\n";
        let tokens = tests_support::lex(&GO, source);

        assert_eq!(
            tokens
                .iter()
                .filter(|token| token.kind == TokenKind::Keyword(Keyword::Assert))
                .count(),
            1
        );
    }

    #[test]
    fn a_nested_receiver_group_closes_at_its_outer_paren() {
        let source = b"func (s *Store[map[string]int]) Read() int {\n\treturn 0\n}\n";
        let tokens = tests_support::lex(&GO, source);

        assert_eq!(tokens[0].kind, TokenKind::Keyword(Keyword::Function));
    }

    #[test]
    fn an_unclosed_receiver_group_is_a_lambda() {
        let source = b"func (s *Store\n";
        let tokens = tests_support::lex(&GO, source);

        assert_eq!(tokens[0].kind, TokenKind::Keyword(Keyword::Lambda));
    }

    #[test]
    fn a_receiver_group_past_the_byte_limit_is_a_lambda() {
        let mut source = b"func (s *Store".to_vec();

        source.extend_from_slice(&b" "[..].repeat(300));
        source.extend_from_slice(b") Read() int {\n\treturn 0\n}\n");

        let tokens = tests_support::lex(&GO, &source);

        assert_eq!(tokens[0].kind, TokenKind::Keyword(Keyword::Lambda));
    }

    #[test]
    fn a_method_receiver_names_a_function() {
        let source = b"func (s *Store) Read() int {\n\treturn 0\n}\n";

        assert_eq!(
            tests_support::kind_of(&GO, "func", "func"),
            TokenKind::Keyword(Keyword::Lambda)
        );

        assert_eq!(
            tests_support::lex(&GO, source)[0].kind,
            TokenKind::Keyword(Keyword::Function)
        );
    }

    #[test]
    fn a_function_literal_is_a_lambda() {
        let source = b"var f = func() int {\n\treturn 0\n}\n";
        let tokens = tests_support::lex(&GO, source);

        let word = tokens
            .iter()
            .find(|token| token.text(source) == b"func")
            .expect("the word is a token");

        assert_eq!(word.kind, TokenKind::Keyword(Keyword::Lambda));
    }

    fn loop_word(tokens: &[crate::token::Token], source: &[u8]) -> TokenKind {
        tokens
            .iter()
            .find(|token| token.text(source) == b"for")
            .expect("the word is a token")
            .kind
    }

    #[test]
    fn a_bare_for_is_an_unbounded_loop() {
        let bounded = tests_support::lex(&GO, b"func f() {\n\tfor i := 0; i < 2; i++ {\n\t}\n}\n");
        let unbounded = tests_support::lex(&GO, b"func f() {\n\tfor {\n\t}\n}\n");

        assert_eq!(
            loop_word(
                &bounded,
                b"func f() {\n\tfor i := 0; i < 2; i++ {\n\t}\n}\n"
            ),
            TokenKind::Keyword(Keyword::Loop)
        );

        assert_eq!(
            loop_word(&unbounded, b"func f() {\n\tfor {\n\t}\n}\n"),
            TokenKind::Keyword(Keyword::LoopUnbounded)
        );
    }

    #[test]
    fn a_declared_assert_name_is_not_an_assertion() {
        let source = b"func assert(value int) {\n}\n";
        let tokens = tests_support::lex(&GO, source);

        let asserts = tokens
            .iter()
            .filter(|token| token.is_keyword(Keyword::Assert))
            .count();

        assert_eq!(asserts, 0);
    }

    #[test]
    fn a_require_method_is_an_assertion() {
        let source = b"func f() {\n\trequire.Equal(t, 1, 2)\n}\n";
        let tokens = tests_support::lex(&GO, source);

        let asserts = tokens
            .iter()
            .filter(|token| token.is_keyword(Keyword::Assert))
            .count();

        assert_eq!(asserts, 1);
    }

    #[test]
    fn a_require_without_a_method_is_not_an_assertion() {
        let source = b"func f() {\n\trequire(1)\n}\n";
        let tokens = tests_support::lex(&GO, source);

        let asserts = tokens
            .iter()
            .filter(|token| token.is_keyword(Keyword::Assert))
            .count();

        assert_eq!(asserts, 0);
    }

    #[test]
    fn a_comment_between_func_and_its_name_still_names_a_function() {
        let source = b"func /* here */ read() int {\n\treturn 0\n}\n";
        let tokens = tests_support::lex(&GO, source);

        assert_eq!(tokens[0].kind, TokenKind::Keyword(Keyword::Function));
    }

    #[test]
    fn a_line_comment_between_func_and_its_name_still_names_a_function() {
        let source = b"func // here\nread() int {\n\treturn 0\n}\n";
        let tokens = tests_support::lex(&GO, source);

        assert_eq!(tokens[0].kind, TokenKind::Keyword(Keyword::Function));
    }

    #[test]
    fn a_comment_before_a_loop_brace_still_names_an_unbounded_loop() {
        let source = b"func f() {\n\tfor /* here */ {\n\t}\n}\n";
        let tokens = tests_support::lex(&GO, source);

        let word = tokens
            .iter()
            .find(|token| token.text(source) == b"for")
            .expect("the word is a token");

        assert_eq!(word.kind, TokenKind::Keyword(Keyword::LoopUnbounded));
    }

    #[test]
    fn a_raw_string_runs_to_its_backtick() {
        let source = b"var text = `a \"quoted\" value`\n";
        let tokens = tests_support::lex(&GO, source);

        let raw = tokens
            .iter()
            .find(|token| token.kind == TokenKind::String)
            .expect("the raw string is a token");

        assert_eq!(raw.text(source), b"`a \"quoted\" value`");
    }

    #[test]
    fn an_unclosed_raw_string_runs_to_the_source_end() {
        let source = b"var text = `unterminated";
        let tokens = tests_support::lex(&GO, source);

        let raw = tokens
            .iter()
            .find(|token| token.kind == TokenKind::String)
            .expect("the raw string is a token");

        assert_eq!(raw.length, 13);
    }

    #[test]
    fn a_raw_string_closing_at_the_source_end_closes() {
        let source = b"var text = `done`";
        let tokens = tests_support::lex(&GO, source);

        let raw = tokens
            .iter()
            .find(|token| token.kind == TokenKind::String)
            .expect("the raw string is a token");

        assert_eq!(raw.text(source), b"`done`");
    }

    #[test]
    fn a_block_comment_ending_in_a_star_runs_to_the_source_end() {
        let source = b"/* ending in a star *";
        let tokens = tests_support::lex(&GO, source);

        assert_eq!(tokens.len(), 1);
        assert_eq!(tokens[0].kind, TokenKind::Comment);
        assert_eq!(tokens[0].length, 21);
    }

    #[test]
    fn a_receiver_method_without_a_signature_is_a_lambda() {
        let source = b"func (s *Store) Read";
        let tokens = tests_support::lex(&GO, source);

        assert_eq!(tokens[0].kind, TokenKind::Keyword(Keyword::Lambda));
    }

    #[test]
    fn a_receiver_without_a_method_name_is_a_lambda() {
        let source = b"func (s *Store) ";
        let tokens = tests_support::lex(&GO, source);

        assert_eq!(tokens[0].kind, TokenKind::Keyword(Keyword::Lambda));
    }

    #[test]
    fn a_for_at_the_source_end_is_a_bounded_loop() {
        let source = b"func f() {\n\tfor";
        let tokens = tests_support::lex(&GO, source);

        let word = tokens
            .iter()
            .find(|token| token.text(source) == b"for")
            .expect("the word is a token");

        assert_eq!(word.kind, TokenKind::Keyword(Keyword::Loop));
    }

    #[test]
    fn an_assert_at_the_source_start_is_an_assertion() {
        let source = b"assert(value)";
        let tokens = tests_support::lex(&GO, source);

        assert_eq!(tokens[0].kind, TokenKind::Keyword(Keyword::Assert));
    }

    #[test]
    fn a_require_dot_at_the_source_end_is_not_an_assertion() {
        let source = b"func f() {\n\trequire.";
        let tokens = tests_support::lex(&GO, source);

        let asserts = tokens
            .iter()
            .filter(|token| token.is_keyword(Keyword::Assert))
            .count();

        assert_eq!(asserts, 0);
    }

    #[test]
    fn a_lone_slash_before_a_name_does_not_open_a_comment() {
        let source = b"func f() {\n\tvalue := a / b\n}\n";
        let tokens = tests_support::lex(&GO, source);

        let comments = tokens
            .iter()
            .filter(|token| token.kind == TokenKind::Comment)
            .count();

        assert_eq!(comments, 0);
    }

    #[test]
    fn a_block_comment_closes_at_its_first_end() {
        let source = b"/* outer /* inner */ func f() {}\n";
        let tokens = tests_support::lex(&GO, source);

        assert_eq!(tokens[0].kind, TokenKind::Comment);
        assert_eq!(tokens[0].length, 20);
        assert_eq!(tokens[1].text(source), b"func");
    }

    #[test]
    fn an_unclosed_block_comment_runs_to_the_source_end() {
        let source = b"/* outer";
        let tokens = tests_support::lex(&GO, source);

        assert_eq!(tokens.len(), 1);
        assert_eq!(tokens[0].kind, TokenKind::Comment);
        assert_eq!(tokens[0].length, 8);
    }

    #[test]
    fn a_block_comment_ending_at_the_source_end_closes() {
        let source = b"/* outer */";
        let tokens = tests_support::lex(&GO, source);

        assert_eq!(tokens.len(), 1);
        assert_eq!(tokens[0].kind, TokenKind::Comment);
        assert_eq!(tokens[0].length, 11);
    }

    #[test]
    fn every_punctuation_of_the_specification_lexes_to_its_kind() {
        for (word, source, expected) in PUNCTUATION {
            assert_eq!(
                tests_support::kind_of(&GO, source, word),
                *expected,
                "{word}"
            );
        }
    }

    #[test]
    fn a_function_lexes_to_its_parts() {
        let source = b"func main() {\n\tcount := 0\n}\n";
        let tokens = tests_support::lex(&GO, source);

        assert_eq!(tokens[0].kind, TokenKind::Keyword(Keyword::Function));
        assert_eq!(tokens[1].text(source), b"main");
        assert_eq!(tokens[4].kind, TokenKind::BlockStart);
        assert_eq!(tokens[5].text(source), b"count");

        assert_eq!(
            tokens[6].kind,
            TokenKind::Punctuation(Punctuation::AssignDeclare)
        );

        assert_eq!(tokens[8].kind, TokenKind::Newline);
    }

    #[test]
    fn a_method_declares_a_function() {
        let source = b"func (r *Reader) Read(buffer []byte) int {\n}\n";
        let tokens = tests_support::lex(&GO, source);

        assert_eq!(tokens[0].kind, TokenKind::Keyword(Keyword::Function));
    }

    #[test]
    fn a_func_literal_is_a_lambda() {
        let source = b"var double = func(value int) int {\n\treturn value\n}\n";
        let tokens = tests_support::lex(&GO, source);

        assert_eq!(tokens[3].kind, TokenKind::Keyword(Keyword::Lambda));
    }

    #[test]
    fn a_bare_for_is_unbounded() {
        let source = b"func main() {\n\tfor {\n\t}\n\tfor i := 0; i < 4; i++ {\n\t}\n}\n";
        let tokens = tests_support::lex(&GO, source);

        let unbounded = tokens
            .iter()
            .filter(|token| token.is_keyword(Keyword::LoopUnbounded))
            .count();

        let bounded = tokens
            .iter()
            .filter(|token| token.is_keyword(Keyword::Loop))
            .count();

        assert_eq!(unbounded, 1);
        assert_eq!(bounded, 1);
    }

    #[test]
    fn a_raw_string_spans_its_lines() {
        let source = b"var text = `one\ntwo`\n";
        let tokens = tests_support::lex(&GO, source);

        assert_eq!(tokens[3].kind, TokenKind::String);
        assert_eq!(tokens[3].text(source), b"`one\ntwo`");
    }

    #[test]
    fn a_rune_is_a_string() {
        let source = b"var byte = 'a'\n";
        let tokens = tests_support::lex(&GO, source);

        assert_eq!(tokens[3].kind, TokenKind::String);
        assert_eq!(tokens[3].text(source), b"'a'");
    }

    #[test]
    fn a_line_ending_in_an_operator_carries_on() {
        let source = b"var total = one +\n\ttwo\n";
        let tokens = tests_support::lex(&GO, source);

        let newlines = tokens
            .iter()
            .filter(|token| token.kind == TokenKind::Newline)
            .count();

        assert_eq!(newlines, 1);
    }

    #[test]
    fn a_trailing_comment_does_not_hide_the_line_break() {
        let source = b"count := 0 // A note.\ntotal := 1\n";
        let tokens = tests_support::lex(&GO, source);

        let newlines = tokens
            .iter()
            .filter(|token| token.kind == TokenKind::Newline)
            .count();

        assert_eq!(newlines, 2);
    }

    #[test]
    fn a_star_behind_a_name_does_not_open_a_comment() {
        let source = b"package main\n\nfunc a*b() {}\n";
        let tokens = tests_support::lex(&GO, source);

        assert!(!tokens.is_empty());

        assert_eq!(
            tests_support::kind_of(&GO, "package main\n\nfunc a*b() {}\n", "func"),
            TokenKind::Keyword(Keyword::Function)
        );
    }

    #[test]
    fn a_comment_between_func_and_its_name_is_skipped() {
        assert_eq!(
            tests_support::kind_of(&GO, "package main\n\nfunc /* note */ run() {}\n", "func"),
            TokenKind::Keyword(Keyword::Function)
        );

        assert_eq!(
            tests_support::kind_of(&GO, "package main\n\nfunc // note\nrun() {}\n", "func"),
            TokenKind::Keyword(Keyword::Function)
        );
    }

    #[test]
    fn a_block_comment_closes_once() {
        let source = b"/* A note. */ func main() {}";
        let tokens = tests_support::lex(&GO, source);

        assert_eq!(tokens[0].kind, TokenKind::Comment);
        assert_eq!(tokens[0].text(source), b"/* A note. */");
        assert_eq!(tokens[1].kind, TokenKind::Keyword(Keyword::Function));
    }

    #[test]
    fn a_type_declaration_names_its_struct() {
        let source = b"type Point struct {\n\tX int\n}\n";
        let tokens = tests_support::lex(&GO, source);

        assert_eq!(tokens[0].kind, TokenKind::Keyword(Keyword::Struct));
        assert_eq!(tokens[1].text(source), b"Point");
        assert_eq!(tokens[2].kind, TokenKind::Keyword(Keyword::Struct));
    }

    #[test]
    fn an_assertion_package_is_an_assertion() {
        let source = b"func f(t *T) {\n\trequire.NoError(t, err)\n\tassert.True(t, ok)\n}\n";
        let tokens = tests_support::lex(&GO, source);

        let asserts = tokens
            .iter()
            .filter(|token| token.is_keyword(Keyword::Assert))
            .count();

        assert_eq!(asserts, 2);
    }

    #[test]
    fn an_ordinary_package_is_an_identifier() {
        let source = b"func f() {\n\tfmt.Println(value)\n}\n";
        let tokens = tests_support::lex(&GO, source);

        let asserts = tokens
            .iter()
            .filter(|token| token.is_keyword(Keyword::Assert))
            .count();

        assert_eq!(asserts, 0);
    }

    #[test]
    fn a_declared_assert_is_not_a_keyword() {
        let source = b"func assert(condition bool) {\n}\n";
        let tokens = tests_support::lex(&GO, source);

        let asserts = tokens
            .iter()
            .filter(|token| token.is_keyword(Keyword::Assert))
            .count();

        assert_eq!(asserts, 0);
        assert_eq!(tokens[1].kind, TokenKind::Identifier);
    }

    fn newlines(source: &[u8]) -> usize {
        tests_support::lex(&GO, source)
            .iter()
            .filter(|token| token.kind == TokenKind::Newline)
            .count()
    }
}
