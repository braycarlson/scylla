mod css;
mod go;
mod javascript;
mod odin;
mod python;
mod rust;
mod zig;

pub use css::{CSS, CSSLexer, NESTING_DEPTH_MAX as CSS_NESTING_DEPTH_MAX};
pub use go::{GO, GoLexer};
pub use javascript::{JAVASCRIPT, JavaScriptLexer, TYPESCRIPT, TypeScriptLexer};
pub use odin::{ODIN, OdinLexer};
pub use python::{PYTHON, PythonLexer};

pub(crate) use javascript::token_at as javascript_token_at;
pub(crate) use python::token_at as python_token_at;
pub use rust::{RUST, RustLexer};
pub use zig::{EXPECTATIONS as ZIG_EXPECTATIONS, ZIG, ZigLexer};

#[cfg(any(test, feature = "tests"))]
pub mod tests_support {
    use crate::language::Lexer;
    use crate::token::{Lex, Token, TokenKind, Tokens};

    pub fn lex(lexer: &dyn Lexer, source: &[u8]) -> Vec<Token> {
        let mut tokens = Tokens::reserve(4_096);
        let outcome = lexer.lex(source, &mut tokens);

        assert_eq!(outcome, Lex::Complete);

        tokens.as_slice().to_vec()
    }

    pub fn lex_bounded(lexer: &dyn Lexer, source: &[u8], budget: u32) -> Lex {
        let mut tokens = Tokens::reserve(budget);

        lexer.lex(source, &mut tokens)
    }

    pub fn kind_of(lexer: &dyn Lexer, source: &str, word: &str) -> TokenKind {
        assert!(!word.is_empty());
        assert!(source.contains(word));

        let bytes = source.as_bytes();
        let tokens = lex(lexer, bytes);

        let found = tokens
            .iter()
            .find(|token| token.text(bytes) == word.as_bytes());

        found
            .unwrap_or_else(|| panic!("{word} is lexed as a token of its own"))
            .kind
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::language::{Languages, Lexer};
    use crate::scan::COMMENT_DEPTH_MAX;
    use crate::structure::DEPTH_MAX;
    use crate::token::{Keyword, Lex, TokenKind};

    const EVERY_LEXER: &[&dyn Lexer] =
        &[&GO, &JAVASCRIPT, &ODIN, &PYTHON, &RUST, &TYPESCRIPT, &ZIG];

    #[test]
    fn every_lexer_the_library_ships_registers_under_its_own_identifier() {
        let mut languages = Languages::reserve(16);

        for lexer in EVERY_LEXER {
            languages.register(*lexer);
        }

        assert_eq!(
            languages.count(),
            u32::try_from(EVERY_LEXER.len()).expect("the list is small")
        );

        for lexer in EVERY_LEXER {
            let index = languages
                .of_identifier(lexer.identifier().as_bytes())
                .expect("the lexer was just registered");

            assert_eq!(languages.lexer(index).identifier(), lexer.identifier());
        }
    }

    #[test]
    fn a_byte_order_mark_is_skipped_rather_than_lexed() {
        for lexer in EVERY_LEXER {
            let plain = b"fn helper() {}\n";
            let marked = b"\xef\xbb\xbffn helper() {}\n";
            let without = tests_support::lex(*lexer, plain);
            let with = tests_support::lex(*lexer, marked);

            assert_eq!(
                without.len(),
                with.len(),
                "{}: the mark changed the token count",
                lexer.identifier()
            );

            for (index, (bare, token)) in without.iter().zip(with.iter()).enumerate() {
                assert_eq!(
                    bare.kind,
                    token.kind,
                    "{}: token {index} changed kind behind the mark",
                    lexer.identifier()
                );

                assert_eq!(
                    bare.length,
                    token.length,
                    "{}: token {index} changed length behind the mark",
                    lexer.identifier()
                );

                assert_eq!(
                    bare.offset + 3,
                    token.offset,
                    "{}: token {index} is not three bytes further along",
                    lexer.identifier()
                );
            }
        }
    }

    #[test]
    fn a_mark_on_its_own_lexes_to_nothing_that_is_not_a_line() {
        for lexer in EVERY_LEXER {
            let tokens = tests_support::lex(*lexer, b"\xef\xbb\xbf");

            assert!(
                tokens.iter().all(|token| token.kind == TokenKind::Newline),
                "{}: a lone mark produced {tokens:?}",
                lexer.identifier()
            );
        }
    }

    #[test]
    fn a_mark_in_the_middle_of_a_file_is_not_a_mark() {
        for lexer in EVERY_LEXER {
            let plain = tests_support::lex(*lexer, b"a\nb\n");
            let inner = tests_support::lex(*lexer, b"a\n\xef\xbb\xbfb\n");

            assert!(
                inner.len() >= plain.len(),
                "{}: a mark in the middle removed a token",
                lexer.identifier()
            );
        }
    }

    #[test]
    fn every_lexer_truncates_rather_than_overrunning_its_token_buffer() {
        let source = b"a b c d e f g h i j k l m n o p q r s t u v w x y z\n";

        for lexer in EVERY_LEXER {
            assert_eq!(
                tests_support::lex_bounded(*lexer, source, 4),
                Lex::Truncated,
                "{}: a four-token budget was not enough to truncate",
                lexer.identifier()
            );

            assert_eq!(
                tests_support::lex_bounded(*lexer, source, 4_096),
                Lex::Complete,
                "{}: the same source does not fit a generous budget",
                lexer.identifier()
            );
        }
    }

    #[test]
    fn an_empty_source_is_complete_under_any_budget() {
        for lexer in EVERY_LEXER {
            assert_eq!(
                tests_support::lex_bounded(*lexer, b"", 1),
                Lex::Complete,
                "{}",
                lexer.identifier()
            );
        }
    }

    #[test]
    fn nesting_past_the_indent_bound_stops_opening_blocks() {
        let mut source = String::new();

        for depth in 0..(DEPTH_MAX as usize + 8) {
            source.push_str(&" ".repeat(depth * 2));
            source.push_str("if x:\n");
        }

        source.push_str(&" ".repeat((DEPTH_MAX as usize + 8) * 2));
        source.push_str("pass\n");

        let tokens = tests_support::lex(&PYTHON, source.as_bytes());

        let opened = tokens
            .iter()
            .filter(|token| token.kind == TokenKind::BlockStart)
            .count();

        assert!(
            opened < DEPTH_MAX as usize,
            "{opened} blocks opened, past the {DEPTH_MAX} bound"
        );

        assert!(opened > 8, "the source should nest deeply: {opened}");
    }

    fn invariants_hold(lexer: &dyn Lexer, source: &[u8]) {
        let tokens = tests_support::lex(lexer, source);
        let name = lexer.identifier();
        let mut end_previous = 0;

        for (index, token) in tokens.iter().enumerate() {
            let start = token.offset as usize;
            let end = start + token.length as usize;

            assert!(
                end <= source.len(),
                "{name}: token {index} ends at {end} past the {} byte source",
                source.len()
            );

            assert!(
                start >= end_previous,
                "{name}: token {index} starts at {start} inside the one before it"
            );

            end_previous = end;
        }

        let again = tests_support::lex(lexer, source);

        assert_eq!(tokens.len(), again.len(), "{name}: the lex is not stable");

        for (first, second) in tokens.iter().zip(again.iter()) {
            assert_eq!(first.kind, second.kind, "{name}: the lex is not stable");
            assert_eq!(first.offset, second.offset, "{name}: the lex is not stable");
            assert_eq!(first.length, second.length, "{name}: the lex is not stable");
        }
    }

    #[test]
    fn every_lexer_holds_its_invariants_on_awkward_sources() {
        const SOURCES: &[&[u8]] = &[
            b"",
            b"\n",
            b"\r\n",
            b"\xef\xbb\xbf",
            b"\xef\xbb\xbffn helper() {}\n",
            b"fn helper() {\r\n    let value = 1;\r\n}\r\n",
            b"\"unterminated",
            b"'unterminated",
            b"/* unterminated",
            b"// trailing comment without a newline",
            b"#",
            b"\0",
            b"a\0b\n",
            b"let s = \"\xf0\x9f\x98\x80\";\n",
            b"\xff\xfe not utf eight at all\n",
            b"((((((((((((((((((((\n",
            b"))))))))))))))))))))\n",
            b"r#\"raw \"quoted\" text\"#\n",
            b"/* /* nested */ */\n",
            b"\\",
            b"0x",
            b"1.",
            b".1",
            b"1e",
            b"a\tb\x0bc\x0cd\n",
        ];

        for lexer in EVERY_LEXER {
            for source in SOURCES {
                invariants_hold(*lexer, source);
            }
        }
    }

    #[test]
    fn a_comment_nested_past_the_bound_degrades_rather_than_panicking() {
        let deep = b"/*".repeat(COMMENT_DEPTH_MAX as usize + 8);

        for lexer in EVERY_LEXER {
            let tokens = tests_support::lex(*lexer, &deep);

            invariants_hold(*lexer, &deep);

            assert!(
                !tokens.is_empty(),
                "{}: a file of openers lexed to nothing",
                lexer.identifier()
            );
        }
    }

    #[test]
    fn a_comment_nested_inside_the_bound_still_closes_where_it_should() {
        const NESTING: &[&(dyn Lexer + Sync)] = &[&RUST, &ODIN];
        let mut source = "/*".repeat(COMMENT_DEPTH_MAX as usize - 1);

        source.push_str(&"*/".repeat(COMMENT_DEPTH_MAX as usize - 1));
        source.push_str("\nx\n");

        for lexer in NESTING {
            let tokens = tests_support::lex(*lexer, source.as_bytes());
            let comments = tokens
                .iter()
                .filter(|token| token.kind == TokenKind::Comment)
                .count();

            assert_eq!(
                comments,
                1,
                "{}: the nesting should close as one comment",
                lexer.identifier()
            );

            assert!(
                tokens
                    .iter()
                    .any(|token| token.kind == TokenKind::Identifier),
                "{}: the code after the comment was swallowed",
                lexer.identifier()
            );
        }
    }

    #[test]
    fn an_extern_block_is_not_an_import() {
        let tokens = tests_support::lex(&RUST, b"extern \"C\" fn on_done(packet: *mut T) {}\n");

        assert!(
            !tokens[0].is_keyword(Keyword::Import),
            "{:?}",
            tokens[0].kind
        );
    }

    #[test]
    fn a_no_break_space_separates_two_words_rather_than_gluing_them() {
        for lexer in EVERY_LEXER {
            let source = "const\u{00a0}value = 1\n";
            let tokens = tests_support::lex(*lexer, source.as_bytes());
            let first = tokens.first().expect("the source is not empty");

            assert_eq!(
                first.text(source.as_bytes()),
                b"const",
                "{}: the no-break space did not separate the words",
                lexer.identifier()
            );
        }
    }

    #[test]
    fn a_legitimate_unicode_identifier_still_lexes_whole() {
        for lexer in EVERY_LEXER {
            let source = "wert\u{00e4}hnlich = 1\n";
            let tokens = tests_support::lex(*lexer, source.as_bytes());
            let first = tokens.first().expect("the source is not empty");

            assert_eq!(
                first.text(source.as_bytes()),
                "wert\u{00e4}hnlich".as_bytes(),
                "{}: a Unicode identifier was split",
                lexer.identifier()
            );
        }
    }

    #[test]
    fn a_line_separator_is_whitespace_rather_than_an_identifier_byte() {
        for separator in ["\u{2028}", "\u{2029}", "\u{3000}", "\u{202f}", "\u{feff}"] {
            let source = format!("const{separator}value = 1\n");
            let tokens = tests_support::lex(&JAVASCRIPT, source.as_bytes());

            assert_eq!(
                tokens[0].kind,
                TokenKind::Keyword(Keyword::Constant),
                "{separator:?} glued itself to the keyword"
            );
        }
    }
}
