use core::ops::{Deref, DerefMut};

use crate::bounded::{BoundedVec, Span, count_of};
use crate::scan::mark_width;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Encoding {
    Utf16,
    Utf8,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Position {
    pub character: u32,
    pub line: u32,
}

#[derive(Debug)]
pub struct Index {
    starts: BoundedVec<u32>,
}

#[derive(Clone, Copy, Debug)]
pub struct Plan {
    pub added: u32,
    pub first: u32,
    pub last: u32,
}

impl Encoding {
    pub fn count(self, text: &str) -> u32 {
        let mut units = 0;

        for character in text.chars() {
            units += self.width(character);
        }

        units
    }

    pub const fn name(self) -> &'static str {
        match self {
            Self::Utf8 => "utf-8",
            Self::Utf16 => "utf-16",
        }
    }

    pub fn width(self, character: char) -> u32 {
        match self {
            Self::Utf8 => count_of(character.len_utf8()),
            Self::Utf16 => count_of(character.len_utf16()),
        }
    }
}

impl Deref for Index {
    type Target = [u32];

    fn deref(&self) -> &Self::Target {
        &self.starts
    }
}

impl DerefMut for Index {
    fn deref_mut(&mut self) -> &mut Self::Target {
        &mut self.starts
    }
}

impl Index {
    pub fn reserve(line_count_max: u32) -> Self {
        assert!(line_count_max > 0);

        assert!(!crate::allocation::is_frozen());

        let mut index = Self {
            starts: BoundedVec::reserve(line_count_max),
        };

        index.clear();

        index
    }

    #[must_use]
    pub fn build(&mut self, source: &[u8]) -> bool {
        assert!(u32::try_from(source.len()).is_ok());

        self.clear();

        for (offset, byte) in source.iter().enumerate() {
            if *byte != b'\n' {
                continue;
            }

            if !self.starts.push(count_of(offset) + 1) {
                self.clear();

                return false;
            }
        }

        assert!(self.count() > 0);

        true
    }

    pub fn capacity(&self) -> u32 {
        self.starts.capacity()
    }

    pub fn clear(&mut self) {
        self.starts.clear();
        self.starts.push_assert(0);

        assert_eq!(self.count(), 1);
    }

    pub fn count(&self) -> u32 {
        let count = self.starts.count();

        assert!(count > 0);

        count
    }

    pub fn line_end(&self, line: u32, length: u32) -> u32 {
        assert!(line < self.count());

        if line + 1 < self.count() {
            return self.starts[line as usize + 1];
        }

        length
    }

    pub fn line_of(&self, offset: u32) -> u32 {
        let index = self.starts.partition_point(|start| *start <= offset);

        assert!(index > 0);

        count_of(index - 1)
    }

    pub fn line_start(&self, line: u32) -> u32 {
        self.starts.get(line as usize).copied().unwrap_or(0)
    }

    pub fn line_start_after_mark(&self, line: u32, source: &[u8]) -> u32 {
        assert!(line < self.count());

        let start = self.starts[line as usize];

        if line > 0 {
            return start;
        }

        start + count_of(mark_width(source))
    }

    pub fn line_span(&self, line: u32, source: &[u8]) -> Span {
        assert!(line < self.count());

        let start = self.line_start_after_mark(line, source);

        let end = if line + 1 < self.count() {
            terminator_start(source, self.starts[line as usize + 1] - 1, start)
        } else {
            count_of(source.len())
        };

        Span::between(start, end)
    }

    pub fn line_span_terminated(&self, line: u32, source: &[u8]) -> Span {
        assert!(line < self.count());

        let start = self.line_start_after_mark(line, source);

        let end = if line + 1 < self.count() {
            self.starts[line as usize + 1]
        } else {
            count_of(source.len())
        };

        Span::between(start, end)
    }

    pub fn terminator_of<'source>(&self, line: u32, source: &'source [u8]) -> &'source [u8] {
        assert!(line < self.count());

        let span = self.line_span(line, source);
        let terminated = self.line_span_terminated(line, source);

        &source[span.end() as usize..terminated.end() as usize]
    }

    pub fn splice_plan(&self, start: u32, end: u32, inserted: &[u8]) -> Option<Plan> {
        assert!(start <= end);

        let first = count_of(self.starts.partition_point(|offset| *offset <= start));
        let last = count_of(self.starts.partition_point(|offset| *offset <= end));

        assert!(first <= last);

        let mut added = 0;

        for byte in inserted {
            if *byte == b'\n' {
                added += 1;
            }
        }

        let count = first + added + (self.count() - last);

        if count > self.capacity() {
            return None;
        }

        Some(Plan { added, first, last })
    }

    pub fn splice_apply(&mut self, start: u32, end: u32, inserted: &[u8], plan: &Plan) {
        assert!(start <= end);

        let delta = i64::from(count_of(inserted.len())) - i64::from(end - start);
        let shifted = self.shift_tail(plan.last, plan.first + plan.added);

        assert!(shifted);

        let mut cursor = plan.first as usize;

        for (position, byte) in inserted.iter().enumerate() {
            if *byte != b'\n' {
                continue;
            }

            self.starts[cursor] = start + count_of(position) + 1;
            cursor += 1;
        }

        assert_eq!(count_of(cursor), plan.first + plan.added);

        for offset in &mut self.starts[cursor..] {
            *offset =
                u32::try_from(i64::from(*offset) + delta).expect("the line offset stays in range");
        }
    }

    pub fn offset_of(&self, source: &str, position: Position, encoding: Encoding) -> Option<u32> {
        if position.line >= self.count() {
            return None;
        }

        let length = count_of(source.len());
        let start = self.starts[position.line as usize];
        let end = self.line_end(position.line, length);
        let text = slice_of(source, start, end);
        let mut units = 0;

        for (index, character) in text.char_indices() {
            if units == position.character {
                return Some(start + count_of(index));
            }

            units += encoding.width(character);
        }

        if units == position.character {
            return Some(end);
        }

        None
    }

    pub fn position_of(&self, source: &str, offset: u32, encoding: Encoding) -> Position {
        assert!(offset as usize <= source.len());

        let line = self.line_of(offset);
        let start = self.starts[line as usize];

        assert!(start <= offset);

        Position {
            character: encoding.count(slice_of(source, start, offset)),
            line,
        }
    }

    pub fn push(&mut self, start: u32) -> bool {
        self.starts.push(start)
    }

    pub fn shift_tail(&mut self, from: u32, to: u32) -> bool {
        self.starts.shift_tail(from, to)
    }

    pub fn validate(&self, length: u32) {
        assert!(self.count() > 0);
        assert_eq!(self.starts[0], 0);
        assert!(self.starts[self.count() as usize - 1] <= length);
    }
}

fn terminator_start(source: &[u8], newline: u32, start: u32) -> u32 {
    assert!(newline >= start);

    if newline > start && source[newline as usize - 1] == b'\r' {
        return newline - 1;
    }

    newline
}

fn slice_of(source: &str, start: u32, end: u32) -> &str {
    assert!(start <= end);
    assert!(end as usize <= source.len());

    source
        .get(start as usize..end as usize)
        .expect("a line boundary sits on a character boundary")
}

#[cfg(test)]
mod tests {
    use super::*;

    fn built(source: &str) -> Index {
        let mut index = Index::reserve(64);

        assert!(index.build(source.as_bytes()));

        index
    }

    #[test]
    fn an_empty_source_carries_one_line() {
        let index = built("");

        assert_eq!(index.count(), 1);
        assert_eq!(index.line_start(0), 0);
        assert_eq!(index.line_end(0, 0), 0);
    }

    #[test]
    fn a_line_break_opens_the_next_line() {
        let index = built("one\ntwo\nthree");

        assert_eq!(index.count(), 3);
        assert_eq!(index.line_start(0), 0);
        assert_eq!(index.line_start(1), 4);
        assert_eq!(index.line_start(2), 8);
        assert_eq!(index.line_end(1, 13), 8);
        assert_eq!(index.line_end(2, 13), 13);
    }

    #[test]
    fn a_trailing_break_opens_an_empty_last_line() {
        let index = built("one\n");

        assert_eq!(index.count(), 2);
        assert_eq!(index.line_start(1), 4);
        assert_eq!(index.line_end(1, 4), 4);
    }

    #[test]
    fn an_offset_maps_to_its_line_and_column() {
        let source = "one\ntwo\n";
        let index = built(source);

        assert_eq!(
            index.position_of(source, 0, Encoding::Utf8),
            Position {
                character: 0,
                line: 0
            }
        );

        assert_eq!(
            index.position_of(source, 4, Encoding::Utf8),
            Position {
                character: 0,
                line: 1
            }
        );

        assert_eq!(
            index.position_of(source, 6, Encoding::Utf8),
            Position {
                character: 2,
                line: 1
            }
        );
    }

    #[test]
    fn a_surrogate_pair_counts_as_two_utf_sixteen_units() {
        let source = "a\u{1F600}b\n";
        let index = built(source);
        let after = count_of("a\u{1F600}".len());

        assert_eq!(
            index.position_of(source, after, Encoding::Utf16),
            Position {
                character: 3,
                line: 0
            }
        );

        assert_eq!(
            index.position_of(source, after, Encoding::Utf8),
            Position {
                character: 5,
                line: 0
            }
        );
    }

    #[test]
    fn a_position_maps_back_to_its_offset() {
        let source = "one\na\u{1F600}b\nthree";
        let index = built(source);

        for offset in 0..count_of(source.len()) {
            if !source.is_char_boundary(offset as usize) {
                continue;
            }

            let position = index.position_of(source, offset, Encoding::Utf16);

            assert_eq!(
                index.offset_of(source, position, Encoding::Utf16),
                Some(offset)
            );
        }
    }

    #[test]
    fn a_position_past_the_last_line_maps_to_nothing() {
        let source = "one\n";
        let index = built(source);

        assert_eq!(
            index.offset_of(
                source,
                Position {
                    character: 0,
                    line: 9
                },
                Encoding::Utf8
            ),
            None
        );

        assert_eq!(
            index.offset_of(
                source,
                Position {
                    character: 9,
                    line: 0
                },
                Encoding::Utf8
            ),
            None
        );
    }

    #[test]
    fn a_column_at_the_line_end_maps_to_the_break() {
        let source = "one\ntwo";
        let index = built(source);

        assert_eq!(
            index.offset_of(
                source,
                Position {
                    character: 3,
                    line: 0
                },
                Encoding::Utf8
            ),
            Some(3)
        );
    }

    #[test]
    fn a_source_with_more_lines_than_the_budget_is_refused() {
        let mut index = Index::reserve(4);
        let source = "a\nb\nc\nd\ne\nf\n";

        assert!(!index.build(source.as_bytes()));
        assert_eq!(index.count(), 1);
    }

    #[test]
    fn byte_soup_maps_every_offset_back_to_itself() {
        let mut random = crate::bounded::Random::new(0x2B99_2DDF_A232_49D6);
        let mut index = Index::reserve(1_024);

        for _ in 0..256 {
            let length = random.below(128) as usize;
            let mut source = String::with_capacity(length);

            for _ in 0..length {
                source
                    .push_str(["a", "\n", "\u{1F600}", "\u{00e4}", " "][random.below(5) as usize]);
            }

            assert!(index.build(source.as_bytes()));

            for offset in 0..count_of(source.len()) {
                if !source.is_char_boundary(offset as usize) {
                    continue;
                }

                let position = index.position_of(&source, offset, Encoding::Utf16);

                assert_eq!(
                    index.offset_of(&source, position, Encoding::Utf16),
                    Some(offset)
                );
            }
        }
    }

    #[test]
    fn an_offset_inside_the_last_line_still_names_it() {
        let source = "one\ntwo";
        let index = built(source);

        assert_eq!(index.line_of(6), 1);
        assert_eq!(index.line_of(0), 0);
        assert_eq!(index.line_of(3), 0);
        assert_eq!(index.line_of(4), 1);
    }

    #[test]
    fn a_line_span_leaves_its_terminator_outside() {
        const SOURCE: &[u8] = b"one\r\ntwo\nthree";

        let mut index = Index::reserve(8);

        assert!(index.build(SOURCE));
        assert_eq!(index.count(), 3);
        assert_eq!(&SOURCE[index.line_span(0, SOURCE).range()], b"one");
        assert_eq!(&SOURCE[index.line_span(1, SOURCE).range()], b"two");
        assert_eq!(&SOURCE[index.line_span(2, SOURCE).range()], b"three");
        assert_eq!(index.terminator_of(0, SOURCE), b"\r\n");
        assert_eq!(index.terminator_of(1, SOURCE), b"\n");
        assert_eq!(index.terminator_of(2, SOURCE), b"");

        assert_eq!(
            &SOURCE[index.line_span_terminated(0, SOURCE).range()],
            b"one\r\n"
        );
    }

    #[test]
    fn a_first_line_starts_after_a_byte_order_mark() {
        const SOURCE: &[u8] = b"\xef\xbb\xbfone\ntwo";

        let mut index = Index::reserve(8);

        assert!(index.build(SOURCE));
        assert_eq!(index.line_start_after_mark(0, SOURCE), 3);
        assert_eq!(index.line_start_after_mark(1, SOURCE), 7);
        assert_eq!(&SOURCE[index.line_span(0, SOURCE).range()], b"one");
    }

    #[test]
    fn a_splice_patches_the_index_the_way_a_rebuild_would() {
        const SOURCE: &[u8] = b"one\ntwo\nthree\n";
        const INSERTED: &[u8] = b"a\nb\n";

        let mut index = Index::reserve(16);

        assert!(index.build(SOURCE));

        let plan = index.splice_plan(4, 8, INSERTED).expect("the index fits");

        index.splice_apply(4, 8, INSERTED, &plan);

        let mut spliced = Vec::from(&SOURCE[..4]);

        spliced.extend_from_slice(INSERTED);
        spliced.extend_from_slice(&SOURCE[8..]);

        let mut rebuilt = Index::reserve(16);

        assert!(rebuilt.build(&spliced));
        assert_eq!(index.count(), rebuilt.count());

        for line in 0..index.count() {
            assert_eq!(index.line_start(line), rebuilt.line_start(line));
        }
    }

    #[test]
    fn a_splice_past_the_reserved_lines_answers_no_plan() {
        const SOURCE: &[u8] = b"one\n";

        let mut index = Index::reserve(3);

        assert!(index.build(SOURCE));
        assert!(index.splice_plan(0, 0, b"a\nb\nc\nd\n").is_none());
    }
}
