use crate::language::Lexer;
use crate::scan::{
    is_identifier_part,
    line_break_width,
    mark_width,
    number_scan,
    punctuation_of,
    string_scan_multiline,
    whitespace_scan,
};
use crate::token::{Lex, TokenKind, Tokens};

pub const NESTING_DEPTH_MAX: u32 = 64;
pub static CSS: CSSLexer = CSSLexer;

pub struct CSSLexer;

impl Lexer for CSSLexer {
    fn extensions(&self) -> &'static [&'static [u8]] {
        &[b"css"]
    }

    fn identifier(&self) -> &'static str {
        "css"
    }

    fn lex(&self, source: &[u8], tokens: &mut Tokens) -> Lex {
        assert!(u32::try_from(source.len()).is_ok());

        assert!(u32::try_from(source.len()).is_ok());

        let mut depth = 0;
        let mut offset = mark_width(source);

        while offset < source.len() {
            let blank = whitespace_scan(source, offset);

            if blank > offset {
                offset = blank;

                continue;
            }

            let (kind, end) = token_of(source, offset, depth);

            assert!(end > offset);

            if kind == TokenKind::BlockStart {
                depth += 1;
            }

            if kind == TokenKind::BlockEnd {
                depth = depth.saturating_sub(1);
            }

            if !tokens.push(source, kind, offset, end - offset) {
                return Lex::Truncated;
            }

            offset = end;
        }

        Lex::Complete
    }
}

fn token_of(source: &[u8], start: usize, depth: u32) -> (TokenKind, usize) {
    assert!(start < source.len());

    let byte = source[start];
    let breaks = line_break_width(source, start);

    if breaks > 0 {
        return (TokenKind::Newline, start + breaks);
    }

    if byte == b'/' && source.get(start + 1) == Some(&b'*') {
        return (TokenKind::Comment, comment_end(source, start));
    }

    if byte == b'"' || byte == b'\'' {
        return (
            TokenKind::String,
            string_scan_multiline(source, start, byte),
        );
    }

    if byte == b'{' {
        if depth >= NESTING_DEPTH_MAX {
            return (
                TokenKind::Punctuation(punctuation_of(source, start).0),
                start + 1,
            );
        }

        return (TokenKind::BlockStart, start + 1);
    }

    if byte == b'}' {
        if depth == 0 || depth > NESTING_DEPTH_MAX {
            return (
                TokenKind::Punctuation(punctuation_of(source, start).0),
                start + 1,
            );
        }

        return (TokenKind::BlockEnd, start + 1);
    }

    if byte.is_ascii_digit() {
        return (TokenKind::Number, number_scan(source, start));
    }

    if byte == b'@'
        && source
            .get(start + 1)
            .is_some_and(|next| is_name_byte(*next))
    {
        return (TokenKind::Identifier, name_end(source, start + 1));
    }

    if is_name_start(byte) {
        return (TokenKind::Identifier, name_end(source, start));
    }

    let (punctuation, width) = punctuation_of(source, start);

    (TokenKind::Punctuation(punctuation), start + width)
}

fn comment_end(source: &[u8], start: usize) -> usize {
    let mut offset = start + 2;

    while offset < source.len() {
        if source[offset] == b'*' && source.get(offset + 1) == Some(&b'/') {
            return offset + 2;
        }

        offset += 1;
    }

    source.len()
}

const fn is_name_byte(byte: u8) -> bool {
    is_identifier_part(byte) || byte == b'-'
}

const fn is_name_start(byte: u8) -> bool {
    byte.is_ascii_alphabetic() || byte == b'_' || byte == b'-' || byte >= 0x80
}

fn name_end(source: &[u8], start: usize) -> usize {
    let mut offset = start;

    while offset < source.len() && is_name_byte(source[offset]) {
        offset += 1;
    }

    offset.max(start + 1)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::lex::tests_support;
    use crate::token::{Punctuation, Token};

    fn spans(source: &str) -> Vec<(TokenKind, String)> {
        let bytes = source.as_bytes();

        tests_support::lex(&CSS, bytes)
            .iter()
            .map(|token| {
                (
                    token.kind,
                    String::from_utf8_lossy(token.text(bytes)).into_owned(),
                )
            })
            .filter(|(kind, _)| *kind != TokenKind::Newline)
            .collect()
    }

    fn kinds(source: &str) -> Vec<TokenKind> {
        spans(source).into_iter().map(|(kind, _)| kind).collect()
    }

    #[test]
    fn a_declaration_lexes_to_a_name_a_colon_a_value_and_a_semicolon() {
        assert_eq!(
            spans("color: red;"),
            vec![
                (TokenKind::Identifier, "color".to_owned()),
                (TokenKind::Punctuation(Punctuation::Colon), ":".to_owned()),
                (TokenKind::Identifier, "red".to_owned()),
                (
                    TokenKind::Punctuation(Punctuation::Semicolon),
                    ";".to_owned()
                ),
            ]
        );
    }

    #[test]
    fn a_hyphenated_property_stays_one_name() {
        assert_eq!(
            spans("background-color: blue;")[0],
            (TokenKind::Identifier, "background-color".to_owned())
        );
    }

    #[test]
    fn an_at_rule_carries_its_prefix() {
        assert_eq!(
            spans("@media print { a { b: c } }")[0],
            (TokenKind::Identifier, "@media".to_owned())
        );
    }

    #[test]
    fn a_rule_body_opens_and_closes_a_block() {
        assert_eq!(
            kinds("a { b: c }"),
            vec![
                TokenKind::Identifier,
                TokenKind::BlockStart,
                TokenKind::Identifier,
                TokenKind::Punctuation(Punctuation::Colon),
                TokenKind::Identifier,
                TokenKind::BlockEnd,
            ]
        );
    }

    #[test]
    fn a_comment_is_one_token_and_an_unterminated_one_runs_to_the_end() {
        assert_eq!(
            spans("/* note */ a {}")[0],
            (TokenKind::Comment, "/* note */".to_owned())
        );

        assert_eq!(
            spans("/* open")[0],
            (TokenKind::Comment, "/* open".to_owned())
        );
    }

    #[test]
    fn a_string_keeps_its_quotes_and_spans_its_lines() {
        assert_eq!(
            spans("content: \"a b\";")[2],
            (TokenKind::String, "\"a b\"".to_owned())
        );

        assert_eq!(
            spans("content: 'a b';")[2],
            (TokenKind::String, "'a b'".to_owned())
        );
    }

    #[test]
    fn a_dimension_carries_its_unit() {
        assert_eq!(
            spans("width: 10px;")[2],
            (TokenKind::Number, "10px".to_owned())
        );
    }

    #[test]
    fn a_selector_keeps_its_marks_apart_from_its_name() {
        assert_eq!(
            spans(".card > #main a:hover {}")
                .into_iter()
                .map(|(_, text)| text)
                .collect::<Vec<String>>(),
            [".", "card", ">", "#", "main", "a", ":", "hover", "{", "}"]
        );
    }

    #[test]
    fn nesting_past_the_bound_stops_opening_blocks() {
        let mut source = String::new();

        for _ in 0..(NESTING_DEPTH_MAX + 8) {
            source.push_str("a {");
        }

        let tokens = tests_support::lex(&CSS, source.as_bytes());

        let opened = tokens
            .iter()
            .filter(|token| token.kind == TokenKind::BlockStart)
            .count();

        assert_eq!(opened, NESTING_DEPTH_MAX as usize);
    }

    #[test]
    fn a_stray_closer_is_punctuation_rather_than_a_block_end() {
        assert_eq!(
            spans("}")[0],
            (TokenKind::Punctuation(Punctuation::Other), "}".to_owned())
        );
    }

    #[test]
    fn byte_soup_lexes_in_bounds_and_stably() {
        let mut random = crate::bounded::Random::new(0x7F4A_7C15_9E37_79B9);
        let alphabet = b"{}:;/*\"'@.#-abc123 \n";

        for _ in 0..256 {
            let length = random.below(128) as usize;
            let mut source = Vec::with_capacity(length);

            for _ in 0..length {
                source.push(
                    alphabet[random.below(crate::bounded::count_of(alphabet.len())) as usize],
                );
            }

            let first = tests_support::lex(&CSS, &source);
            let again = tests_support::lex(&CSS, &source);

            assert_eq!(first, again);

            let mut end_previous = 0;

            for token in &first {
                assert!(token.offset >= end_previous);
                assert!(token.end() as usize <= source.len());

                end_previous = token.end();
            }
        }
    }

    #[test]
    fn the_lexer_holds_its_invariants_on_awkward_sources() {
        const SOURCES: &[&[u8]] = &[
            b"",
            b"\n",
            b"{",
            b"}",
            b"@",
            b"@media",
            b"/*",
            b"\"open",
            b"a{b:c}",
            b"\xef\xbb\xbfa {}",
            b"\xff\xfe not utf eight",
            b"-",
            b"--custom-property: 1;",
        ];

        for source in SOURCES {
            let tokens: Vec<Token> = tests_support::lex(&CSS, source);
            let mut end_previous = 0;

            for token in &tokens {
                let start = token.offset as usize;
                let end = start + token.length as usize;

                assert!(end <= source.len());
                assert!(start >= end_previous);

                end_previous = end;
            }
        }
    }
}
