use crate::bounded::{BoundedVec, Span, count_of};
use crate::brackets::{self, Bracket, Pairs};
use crate::token::{Punctuation, Token, TokenKind};

pub const DOTTED_PATH_DEPTH_MAX: u32 = 32;

pub const LITERAL_WORDS: [&[u8]; 7] = [
    b"False",
    b"None",
    b"True",
    b"false",
    b"null",
    b"true",
    b"undefined",
];

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Summary {
    Call {
        callee_count: u32,
        callee_first: u32,
        paren_open: u32,
    },
    DottedName {
        segment_count: u32,
        segment_first: u32,
    },
    Dynamic,
    Literal {
        content: Span,
    },
    Sequence {
        item_count: u32,
        item_first: u32,
    },
}

struct Reader<'run> {
    end: u32,
    items: &'run mut BoundedVec<Summary>,
    pairs: &'run Pairs,
    segments: &'run mut BoundedVec<Span>,
    source: &'run [u8],
    start: u32,
    tokens: &'run [Token],
}

impl Reader<'_> {
    fn chain_end(&self, first: u32) -> u32 {
        let mut last = first;
        let mut segments = 1;

        while segments < DOTTED_PATH_DEPTH_MAX {
            let Some(dot) = self.significant_next(last + 1) else {
                return last;
            };

            if !self.tokens[dot as usize].is_punctuation(Punctuation::Dot) {
                return last;
            }

            let Some(name) = self.significant_next(dot + 1) else {
                return last;
            };

            if !self.is_name(name) {
                return last;
            }

            last = name;
            segments += 1;
        }

        last
    }

    fn is_name(&self, index: u32) -> bool {
        matches!(
            self.tokens[index as usize].kind,
            TokenKind::Identifier | TokenKind::Keyword(_)
        )
    }

    fn is_significant(&self, index: u32) -> bool {
        !matches!(
            self.tokens[index as usize].kind,
            TokenKind::Comment | TokenKind::Newline
        )
    }

    fn last_significant(&self) -> Option<u32> {
        let mut index = self.end;

        while index > self.start {
            index -= 1;

            if self.is_significant(index) {
                return Some(index);
            }
        }

        None
    }

    fn significant_next(&self, from: u32) -> Option<u32> {
        let mut index = from;

        while index < self.end {
            if self.is_significant(index) {
                return Some(index);
            }

            index += 1;
        }

        None
    }

    fn opener_of(&self, index: u32) -> Option<Bracket> {
        let (kind, opens) = brackets::classify(self.source, &self.tokens[index as usize])?;

        opens.then_some(kind)
    }

    fn push_segments(&mut self, first: u32, last: u32) -> (u32, u32) {
        let start = self.segments.count();
        let mut count = 0;
        let mut index = first;

        while index <= last {
            if self.is_name(index) && self.segments.push(self.tokens[index as usize].span()) {
                count += 1;
            }

            index += 1;
        }

        (start, count)
    }

    fn read(&mut self, nested: bool) -> Summary {
        let Some(first) = self.significant_next(self.start) else {
            return Summary::Dynamic;
        };

        let Some(last) = self.last_significant() else {
            return Summary::Dynamic;
        };

        if first == last {
            return self.read_single(first);
        }

        if let Some(kind) = self.opener_of(first)
            && self.pairs.partner_of(first) == last
        {
            if nested {
                return Summary::Dynamic;
            }

            return self.read_sequence(kind, first, last);
        }

        if !self.is_name(first) {
            return Summary::Dynamic;
        }

        let chain = self.chain_end(first);

        if chain == last {
            let (segment_first, segment_count) = self.push_segments(first, last);

            return Summary::DottedName {
                segment_count,
                segment_first,
            };
        }

        let Some(paren) = self.significant_next(chain + 1) else {
            return Summary::Dynamic;
        };

        if !self.tokens[paren as usize].is_punctuation(Punctuation::ParenOpen)
            || self.pairs.partner_of(paren) != last
        {
            return Summary::Dynamic;
        }

        let (callee_first, callee_count) = self.push_segments(first, chain);

        Summary::Call {
            callee_count,
            callee_first,
            paren_open: paren,
        }
    }

    fn read_sequence(&mut self, kind: Bracket, first: u32, last: u32) -> Summary {
        assert!(first < last);

        let depth = self.pairs.depth_of(first) + 1;
        let item_first = self.items.count();
        let mut count = 0;
        let mut element = first + 1;
        let mut index = first + 1;

        while index <= last {
            let closes = index == last;

            let splits = closes
                || (self.tokens[index as usize].is_punctuation(Punctuation::Comma)
                    && self.pairs.depth_of(index) == depth);

            if !splits {
                index += 1;

                continue;
            }

            if self.next_significant_within(element, index).is_some() {
                let summary = self.read_element(element, index);

                if self.items.push(summary) {
                    count += 1;
                }
            }

            element = index + 1;
            index += 1;
        }

        assert!(matches!(
            kind,
            Bracket::Brace | Bracket::Paren | Bracket::Square
        ));

        Summary::Sequence {
            item_count: count,
            item_first,
        }
    }

    fn read_element(&mut self, start: u32, end: u32) -> Summary {
        let held_end = self.end;
        let held_start = self.start;

        self.end = end;
        self.start = start;

        let summary = self.read(true);

        self.end = held_end;
        self.start = held_start;

        summary
    }

    fn read_single(&mut self, index: u32) -> Summary {
        let token = self.tokens[index as usize];

        match token.kind {
            TokenKind::String => literal_of_string(token, self.source),
            TokenKind::Number => Summary::Literal {
                content: token.span(),
            },
            TokenKind::Identifier | TokenKind::Keyword(_) => {
                if LITERAL_WORDS.contains(&token.text(self.source)) {
                    return Summary::Literal {
                        content: token.span(),
                    };
                }

                let (segment_first, segment_count) = self.push_segments(index, index);

                Summary::DottedName {
                    segment_count,
                    segment_first,
                }
            }
            TokenKind::BlockEnd
            | TokenKind::BlockStart
            | TokenKind::Comment
            | TokenKind::Newline
            | TokenKind::Punctuation(_) => Summary::Dynamic,
        }
    }

    fn next_significant_within(&self, from: u32, end: u32) -> Option<u32> {
        let mut index = from;

        while index < end {
            if self.is_significant(index) {
                return Some(index);
            }

            index += 1;
        }

        None
    }
}

pub fn read(
    source: &[u8],
    tokens: &[Token],
    pairs: &Pairs,
    token_start: u32,
    token_end: u32,
    segments: &mut BoundedVec<Span>,
    items: &mut BoundedVec<Summary>,
) -> Summary {
    assert!(u32::try_from(source.len()).is_ok());
    assert!(token_start <= token_end);
    assert!(token_end as usize <= tokens.len());

    if token_start == token_end {
        return Summary::Dynamic;
    }

    let mut reader = Reader {
        end: token_end,
        items,
        pairs,
        segments,
        source,
        start: token_start,
        tokens,
    };

    reader.read(false)
}

fn literal_of_string(token: Token, source: &[u8]) -> Summary {
    let text = token.text(source);
    let mut prefix = 0;

    while prefix < text.len() && text[prefix].is_ascii_alphabetic() {
        prefix += 1;
    }

    if text.get(..prefix).is_some_and(|letters| {
        letters
            .iter()
            .any(|byte| matches!(byte.to_ascii_lowercase(), b'f' | b't'))
    }) {
        return Summary::Dynamic;
    }

    let Some(&quote) = text.get(prefix) else {
        return Summary::Dynamic;
    };

    if quote == b'`' {
        return Summary::Dynamic;
    }

    if quote != b'"' && quote != b'\'' {
        return Summary::Dynamic;
    }

    let opening = if text[prefix..].starts_with(&[quote, quote, quote]) {
        3
    } else {
        1
    };

    let start = prefix + opening;

    let closes = text.len() >= start + opening
        && text[text.len() - opening..]
            .iter()
            .all(|byte| *byte == quote);

    let end = if closes {
        text.len() - opening
    } else {
        text.len()
    };

    if end < start {
        return Summary::Dynamic;
    }

    Summary::Literal {
        content: Span {
            length: count_of(end - start),
            offset: token.offset + count_of(start),
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::brackets::NONE;
    use crate::language::Lexer;
    use crate::lex::{JAVASCRIPT, PYTHON};
    use crate::token::Tokens;

    struct Built {
        items: BoundedVec<Summary>,
        pairs: Pairs,
        segments: BoundedVec<Span>,
        source: Vec<u8>,
        tokens: Vec<Token>,
    }

    fn built(lexer: &dyn Lexer, source: &str) -> (Built, Summary) {
        let bytes = source.as_bytes().to_vec();
        let mut tokens = Tokens::reserve(4_096);
        let mut pairs = Pairs::reserve(4_096);

        lexer.lex(&bytes, &mut tokens);
        pairs.build(&bytes, tokens.as_slice());

        let held = tokens.as_slice().to_vec();
        let mut segments = BoundedVec::reserve(256);
        let mut items = BoundedVec::reserve(256);
        let count = count_of(held.len());
        let summary = read(&bytes, &held, &pairs, 0, count, &mut segments, &mut items);

        (
            Built {
                items,
                pairs,
                segments,
                source: bytes,
                tokens: held,
            },
            summary,
        )
    }

    fn text_of(built: &Built, span: Span) -> String {
        String::from_utf8_lossy(&built.source[span.range()]).into_owned()
    }

    fn segments_of(built: &Built, first: u32, count: u32) -> Vec<String> {
        (first..first + count)
            .map(|index| text_of(built, built.segments[index as usize]))
            .collect()
    }

    #[test]
    fn a_lone_string_is_a_literal_without_its_quotes() {
        let (built, summary) = built(&PYTHON, "\"hello\"");

        let Summary::Literal { content } = summary else {
            panic!("{summary:?}");
        };

        assert_eq!(text_of(&built, content), "hello");
    }

    #[test]
    fn a_raw_string_keeps_its_content_and_a_format_string_is_dynamic() {
        let (held, raw) = built(&PYTHON, "r\"a\\b\"");

        let Summary::Literal { content } = raw else {
            panic!("{raw:?}");
        };

        assert_eq!(text_of(&held, content), "a\\b");

        let (_, formatted) = built(&PYTHON, "f\"{name}\"");

        assert_eq!(formatted, Summary::Dynamic);
    }

    #[test]
    fn a_triple_quoted_string_drops_all_six_quotes() {
        let (built, summary) = built(&PYTHON, "\"\"\"body\"\"\"");

        let Summary::Literal { content } = summary else {
            panic!("{summary:?}");
        };

        assert_eq!(text_of(&built, content), "body");
    }

    #[test]
    fn a_number_and_a_literal_word_are_literals() {
        for source in ["42", "3.5", "True", "None", "False"] {
            let (_, summary) = built(&PYTHON, source);

            assert!(matches!(summary, Summary::Literal { .. }), "{source}");
        }

        for source in ["null", "undefined", "true"] {
            let (_, summary) = built(&JAVASCRIPT, source);

            assert!(matches!(summary, Summary::Literal { .. }), "{source}");
        }
    }

    #[test]
    fn a_dotted_chain_records_each_segment() {
        let (built, summary) = built(&PYTHON, "django.db.models.CharField");

        let Summary::DottedName {
            segment_count,
            segment_first,
        } = summary
        else {
            panic!("{summary:?}");
        };

        assert_eq!(
            segments_of(&built, segment_first, segment_count),
            ["django", "db", "models", "CharField"]
        );
    }

    #[test]
    fn a_chain_that_ends_in_a_call_is_a_call() {
        let (built, summary) = built(&PYTHON, "models.CharField(max_length=10)");

        let Summary::Call {
            callee_count,
            callee_first,
            paren_open,
        } = summary
        else {
            panic!("{summary:?}");
        };

        assert_eq!(
            segments_of(&built, callee_first, callee_count),
            ["models", "CharField"]
        );

        assert!(built.tokens[paren_open as usize].is_punctuation(Punctuation::ParenOpen));
        assert_ne!(built.pairs.partner_of(paren_open), NONE);
    }

    #[test]
    fn a_bracketed_run_is_a_sequence_of_its_elements() {
        let (built, summary) = built(&PYTHON, "[\"a\", \"b\", 3]");

        let Summary::Sequence {
            item_count,
            item_first,
        } = summary
        else {
            panic!("{summary:?}");
        };

        assert_eq!(item_count, 3);

        let texts: Vec<String> = (item_first..item_first + item_count)
            .map(|index| match built.items[index as usize] {
                Summary::Literal { content } => text_of(&built, content),

                other @ (Summary::Call { .. }
                | Summary::DottedName { .. }
                | Summary::Dynamic
                | Summary::Sequence { .. }) => format!("{other:?}"),
            })
            .collect();

        assert_eq!(texts, ["a", "b", "3"]);
    }

    #[test]
    fn a_nested_sequence_inside_an_item_is_dynamic() {
        let (built, summary) = built(&PYTHON, "[[\"a\"], \"b\"]");

        let Summary::Sequence {
            item_count,
            item_first,
        } = summary
        else {
            panic!("{summary:?}");
        };

        assert_eq!(item_count, 2);
        assert_eq!(built.items[item_first as usize], Summary::Dynamic);
    }

    #[test]
    fn a_trailing_comma_does_not_add_an_element() {
        let (_, summary) = built(&PYTHON, "(\"a\", \"b\",)");

        let Summary::Sequence { item_count, .. } = summary else {
            panic!("{summary:?}");
        };

        assert_eq!(item_count, 2);
    }

    #[test]
    fn an_expression_the_reader_cannot_classify_is_dynamic() {
        for source in ["a + b", "a[0]", "-1", "lambda: 1"] {
            let (_, summary) = built(&PYTHON, source);

            assert_eq!(summary, Summary::Dynamic, "{source}");
        }
    }

    #[test]
    fn byte_soup_classifies_without_panicking() {
        let mut random = crate::bounded::Random::new(0x1234_5678_9ABC_DEF1);
        let alphabet = b"()[]{}\"'.,abc123 \nTrueNonef";

        for _ in 0..256 {
            let length = random.below(64) as usize;
            let mut source = Vec::with_capacity(length);

            for _ in 0..length {
                let index = random.below(count_of(alphabet.len())) as usize;

                source.push(alphabet[index]);
            }

            let (built, summary) = built(&PYTHON, &String::from_utf8_lossy(&source));

            let bounded = match summary {
                Summary::Literal { content } => content.end() as usize <= built.source.len(),
                Summary::Call { .. }
                | Summary::DottedName { .. }
                | Summary::Dynamic
                | Summary::Sequence { .. } => true,
            };

            assert!(bounded, "a literal summary stays inside its source");

            for item in built.items.iter() {
                assert!(!matches!(item, Summary::Sequence { .. }));
            }
        }
    }

    #[test]
    fn a_javascript_template_literal_is_dynamic() {
        let (_, summary) = built(&JAVASCRIPT, "`a${b}c`");

        assert_eq!(summary, Summary::Dynamic);
    }
}
