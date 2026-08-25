mod arena;
mod buffer;
mod map;
mod pool;
mod string;
mod table;
mod vector;

pub use arena::Arena;
pub use buffer::Buffer;
pub use map::FixedMap;
pub use pool::{Handle, Pool};
pub use string::BoundedString;
pub use table::{Table, hash_of};
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

    pub const fn end(self) -> u32 {
        assert!(u32::MAX - self.offset >= self.length);

        self.offset + self.length
    }

    pub const fn range(self) -> core::ops::Range<usize> {
        self.offset as usize..self.end() as usize
    }
}

pub fn count_of(length: usize) -> u32 {
    u32::try_from(length).expect("a bounded length fits in u32")
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
    #[should_panic(expected = "end >= start")]
    fn a_span_between_a_reversed_pair_is_refused() {
        let _span = Span::between(10, 4);
    }
}
