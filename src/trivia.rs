use crate::bounded::{Span, count_of};
use crate::scan::BYTE_ORDER_MARK;
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
