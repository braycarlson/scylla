mod arena;
mod buffer;
mod list;
mod map;
mod pool;
mod string;
mod table;
mod vector;

pub use arena::Arena;
pub use buffer::Buffer;
pub use list::InternedList;
pub use map::FixedMap;
pub use pool::{Handle, Pool};
pub use string::BoundedString;
pub use table::{HASH_OFFSET, HASH_PRIME, Table, hash_of, hash_seeded};
pub use vector::BoundedVec;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Span {
    pub length: u32,
    pub offset: u32,
}

pub trait Bytes {
    fn push_bytes(&mut self, bytes: &[u8]) -> bool;
}

pub trait Reset {
    fn reset(&mut self);
}

impl Span {
    pub const EMPTY: Self = Self {
        length: 0,
        offset: 0,
    };

    pub const fn new(offset: u32, length: u32) -> Self {
        assert!(u32::MAX - offset >= length);

        Self { length, offset }
    }

    pub const fn between(start: u32, end: u32) -> Self {
        assert!(end >= start);

        Self {
            length: end - start,
            offset: start,
        }
    }

    pub const fn contains(self, offset: u32) -> bool {
        self.offset <= offset && offset < self.end()
    }

    pub const fn end(self) -> u32 {
        assert!(u32::MAX - self.offset >= self.length);

        self.offset + self.length
    }

    pub const fn range(self) -> core::ops::Range<usize> {
        self.offset as usize..self.end() as usize
    }

    #[must_use]
    pub const fn shifted(self, base: u32) -> Self {
        Self {
            length: self.length,
            offset: base.saturating_add(self.offset),
        }
    }
}

pub fn count_of(length: usize) -> u32 {
    u32::try_from(length).expect("a bounded length fits in u32")
}

pub fn written(target: &mut [u8], parts: &[&[u8]]) -> Option<usize> {
    let mut length = 0_usize;

    for part in parts {
        let end = length.checked_add(part.len())?;

        target.get_mut(length..end)?.copy_from_slice(part);
        length = end;
    }

    assert!(length <= target.len());

    Some(length)
}

pub struct Random {
    state: u64,
}

impl Random {
    pub fn new(seed: u64) -> Self {
        assert!(seed > 0);

        let random = Self { state: seed };

        assert!(random.state > 0);

        random
    }

    pub fn below(&mut self, bound: u32) -> u32 {
        assert!(bound > 0);

        let value = self.next() % u64::from(bound);

        u32::try_from(value).expect("the remainder fits in u32")
    }

    pub fn next(&mut self) -> u64 {
        let mut state = self.state;

        state ^= state << 13;
        state ^= state >> 7;
        state ^= state << 17;

        assert!(state > 0);

        self.state = state;

        state
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_span_opens_where_it_is_told_and_carries_its_length() {
        let span = Span::new(4, 6);

        assert_eq!(span.offset, 4);
        assert_eq!(span.length, 6);
        assert_eq!(span.end(), 10);
    }

    #[test]
    fn a_span_between_two_offsets_reaches_the_second() {
        let span = Span::between(4, 10);

        assert_eq!(span, Span::new(4, 6));
        assert_eq!(Span::between(7, 7), Span::new(7, 0));
    }

    #[test]
    fn a_shifted_span_keeps_its_length() {
        assert_eq!(Span::new(4, 6).shifted(10), Span::new(14, 6));
        assert_eq!(Span::new(4, 6).shifted(0), Span::new(4, 6));
        assert_eq!(Span::new(4, 6).shifted(u32::MAX).offset, u32::MAX);
    }

    #[test]
    #[should_panic(expected = "end >= start")]
    fn a_span_between_a_reversed_pair_is_refused() {
        let _span = Span::between(10, 4);
    }

    #[test]
    fn a_span_contains_its_offsets_and_not_its_end() {
        let span = Span::new(4, 6);

        assert!(span.contains(4));
        assert!(span.contains(9));
        assert!(!span.contains(3));
        assert!(!span.contains(10));
        assert!(!Span::new(4, 0).contains(4));
        assert!(!Span::EMPTY.contains(0));
    }

    #[test]
    fn written_parts_land_end_to_end_or_not_at_all() {
        let mut target = [0_u8; 8];

        assert_eq!(written(&mut target, &[b"ab", b"", b"cd"]), Some(4));
        assert_eq!(&target[..4], b"abcd");
        assert_eq!(written(&mut target, &[]), Some(0));
        assert_eq!(written(&mut target, &[b"12345678"]), Some(8));
        assert_eq!(written(&mut target, &[b"12345678", b"9"]), None);
        assert_eq!(written(&mut [], &[b"a"]), None);
        assert_eq!(written(&mut [], &[b""]), Some(0));
    }
}
