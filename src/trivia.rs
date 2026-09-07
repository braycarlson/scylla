use crate::bounded::{Span, count_of};
use crate::language::Grammar;
use crate::lines::Index;
use crate::scan::{BYTE_ORDER_MARK, indent_width};
use crate::tree::Positioned;

pub const CONTINUATION_NONE: u8 = 0;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Gap {
    pub span: Span,
    pub token: u32,
}

pub struct Gaps<'tokens, T> {
    end_previous: u32,
    length: u32,
    position: u32,
    tokens: &'tokens [T],
}

impl<T> Iterator for Gaps<'_, T>
where
    T: Positioned,
{
    type Item = Gap;

    fn next(&mut self) -> Option<Gap> {
        let count = count_of(self.tokens.len());

        if self.position > count {
            return None;
        }

        let offset = self.end_previous;

        let end = if self.position == count {
            self.length
        } else {
            self.tokens[self.position as usize].offset()
        };

        assert!(end >= offset);

        if self.position < count {
            self.end_previous = self.tokens[self.position as usize].end();
        }

        let gap = Gap {
            span: Span {
                length: end - offset,
                offset,
            },
            token: self.position,
        };

        self.position += 1;

        Some(gap)
    }
}

pub fn comment_precedes(source: &[u8], index: &Index, line: u32, grammar: &Grammar) -> bool {
    assert!(line < index.count());

    let mut cursor = line;

    while cursor > 0 {
        cursor -= 1;

        let text = source[index.line_span(cursor, source).range()].trim_ascii();

        if text.is_empty() {
            continue;
        }

        return opens_a_comment(text, grammar);
    }

    false
}

fn opens_a_comment(text: &[u8], grammar: &Grammar) -> bool {
    let prefix = grammar.comment_prefix;
    let opener = grammar.comment_block_open;

    (!prefix.is_empty() && text.starts_with(prefix))
        || (!opener.is_empty() && text.starts_with(opener))
}

pub fn trails_the_block(
    source: &[u8],
    index: &Index,
    first: u32,
    last: u32,
    grammar: &Grammar,
) -> bool {
    assert!(first <= last);
    assert!(last < index.count());

    let line = &source[index.line_span(last, source).range()];
    let text = line.trim_ascii();

    if text.is_empty() {
        return true;
    }

    let prefix = grammar.comment_prefix;

    if prefix.is_empty() || !text.starts_with(prefix) {
        return false;
    }

    let opening = &source[index.line_span(first, source).range()];

    indent_width(line) <= indent_width(opening)
}

pub fn gaps<T>(length: u32, tokens: &[T]) -> Gaps<'_, T>
where
    T: Positioned,
{
    assert!(u32::try_from(tokens.len()).is_ok());

    Gaps {
        end_previous: 0,
        length,
        position: 0,
        tokens,
    }
}

pub fn gap_is_blank(source: &[u8], gap: Span, continuation: u8) -> bool {
    assert!(gap.end() as usize <= source.len());

    let mut offset = gap.offset;

    if offset == 0 && source.starts_with(BYTE_ORDER_MARK) {
        offset += count_of(BYTE_ORDER_MARK.len()).min(gap.length);
    }

    while offset < gap.end() {
        let byte = source[offset as usize];

        let blank = matches!(byte, b'\t' | b'\n' | b'\x0b' | b'\x0c' | b'\r' | b' ')
            || (continuation != CONTINUATION_NONE && byte == continuation);

        if blank {
            offset += 1;

            continue;
        }

        let width = crate::scan::whitespace_width(source, offset as usize);

        if width == 0 {
            return false;
        }

        offset += count_of(width);
    }

    true
}

#[cfg(test)]
mod tests {
    use super::*;

    const SOURCE: &[u8] = b"fn held() {\n    // why\n\n    let x = 1;\n    /* block */\n    let y = 2;\n        // deeper\n    // level\n\n}\n";

    fn indexed() -> Index {
        let mut index = Index::reserve(64);

        assert!(index.build(SOURCE));

        index
    }

    #[test]
    fn a_comment_precedes_a_line_across_blank_lines() {
        let index = indexed();
        let grammar = Grammar {
            comment_block_open: b"/*",
            ..Grammar::DEFAULT
        };

        assert!(comment_precedes(SOURCE, &index, 3, &grammar));
        assert!(comment_precedes(SOURCE, &index, 5, &grammar));
        assert!(!comment_precedes(SOURCE, &index, 5, &Grammar::DEFAULT));
        assert!(!comment_precedes(SOURCE, &index, 1, &grammar));
        assert!(!comment_precedes(SOURCE, &index, 0, &grammar));
        assert!(!comment_precedes(SOURCE, &index, 4, &Grammar {
            comment_prefix: b"",
            ..Grammar::DEFAULT
        }));
    }

    #[test]
    fn a_line_trails_the_block_when_blank_or_a_comment_no_deeper_than_the_opener() {
        let index = indexed();

        assert!(trails_the_block(SOURCE, &index, 0, 2, &Grammar::DEFAULT));
        assert!(trails_the_block(SOURCE, &index, 0, 8, &Grammar::DEFAULT));
        assert!(trails_the_block(SOURCE, &index, 3, 7, &Grammar::DEFAULT));
        assert!(!trails_the_block(SOURCE, &index, 3, 6, &Grammar::DEFAULT));
        assert!(!trails_the_block(SOURCE, &index, 0, 5, &Grammar::DEFAULT));
        assert!(!trails_the_block(SOURCE, &index, 0, 4, &Grammar::DEFAULT));
        assert!(!trails_the_block(SOURCE, &index, 0, 1, &Grammar {
            comment_prefix: b"",
            ..Grammar::DEFAULT
        }));
        assert!(trails_the_block(SOURCE, &index, 8, 8, &Grammar::DEFAULT));
        assert!(!trails_the_block(SOURCE, &index, 9, 9, &Grammar::DEFAULT));
    }
}
