use core::ops::{Deref, DerefMut};

use super::Bytes;

#[derive(Debug)]
pub struct BoundedVec<T> {
    capacity: u32,
    items: Vec<T>,
}

impl<T> BoundedVec<T> {
    pub fn reserve(capacity: u32) -> Self {
        assert!(capacity > 0);

        assert!(!crate::allocation::is_frozen());

        let items = Vec::with_capacity(capacity as usize);

        assert!(items.capacity() >= capacity as usize);
        assert!(items.is_empty());

        Self { capacity, items }
    }

    pub const fn empty() -> Self {
        Self {
            capacity: 0,
            items: Vec::new(),
        }
    }

    pub const fn capacity(&self) -> u32 {
        self.capacity
    }

    #[expect(
        clippy::cast_possible_truncation,
        reason = "the length is bounded by a u32 capacity, which the assert pins"
    )]
    pub fn count(&self) -> u32 {
        debug_assert!(self.items.len() <= self.capacity as usize);

        self.items.len() as u32
    }

    pub fn is_full(&self) -> bool {
        self.items.len() >= self.capacity as usize
    }

    #[must_use]
    pub fn push(&mut self, item: T) -> bool {
        if self.items.len() >= self.capacity as usize {
            return false;
        }

        assert!(self.items.len() < self.items.capacity());

        self.items.push(item);

        true
    }

    pub fn push_assert(&mut self, item: T) {
        let pushed = self.push(item);

        assert!(pushed);
        assert!(self.count() > 0);
    }
}

impl<T: Copy> BoundedVec<T> {
    pub fn clear(&mut self) {
        self.items.clear();

        assert_eq!(self.count(), 0);
    }

    pub fn truncate(&mut self, count: u32) {
        assert!(count <= self.count());

        self.items.truncate(count as usize);

        assert_eq!(self.count(), count);
    }

    pub fn shift_tail(&mut self, from: u32, to: u32) -> bool {
        assert!(from <= self.count());

        let tail = (self.count() - from) as usize;
        let length = to as usize + tail;

        if length > self.capacity as usize {
            return false;
        }

        if to > from {
            let Some(filler) = self.items.last().copied() else {
                return false;
            };

            self.items.resize(length, filler);
        }

        self.items
            .copy_within(from as usize..from as usize + tail, to as usize);

        if to < from {
            self.items.truncate(length);
        }

        assert_eq!(self.count() as usize, length);

        true
    }

    pub fn pop(&mut self) -> Option<T> {
        let count_before = self.count();
        let item = self.items.pop();

        assert!(item.is_none() || self.count() + 1 == count_before);

        item
    }
}

impl Bytes for BoundedVec<u8> {
    fn push_bytes(&mut self, bytes: &[u8]) -> bool {
        let length = self.items.len() + bytes.len();

        if length > self.capacity as usize {
            return false;
        }

        self.items.extend_from_slice(bytes);

        assert_eq!(self.items.len(), length);

        true
    }
}

impl<T> Deref for BoundedVec<T> {
    type Target = [T];

    fn deref(&self) -> &[T] {
        &self.items
    }
}

impl<T> DerefMut for BoundedVec<T> {
    fn deref_mut(&mut self) -> &mut [T] {
        &mut self.items
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::bounded::Random;

    #[test]
    fn push_stops_at_capacity() {
        let mut vector = BoundedVec::<u32>::reserve(4);

        for value in 0..4_u32 {
            vector.push_assert(value);
        }

        assert!(vector.is_full());
        let written = vector.push(4);

        assert!(!written);
        assert_eq!(vector.count(), 4);
        assert_eq!(&*vector, &[0_u32, 1, 2, 3][..]);
        assert_eq!(vector.count(), 4);
    }

    #[test]
    #[should_panic(expected = "pushed")]
    fn push_assert_rejects_overflow() {
        let mut vector = BoundedVec::<u32>::reserve(1);

        vector.push_assert(0);
        vector.push_assert(1);
    }

    #[test]
    fn push_bytes_writes_all_or_nothing() {
        let mut vector = BoundedVec::<u8>::reserve(8);

        assert!(vector.push_bytes(b"abcd"));
        assert!(!vector.push_bytes(b"efghi"));
        assert_eq!(&*vector, b"abcd");

        assert!(vector.push_bytes(b"efgh"));
        assert_eq!(&*vector, b"abcdefgh");
        assert!(vector.is_full());
    }

    #[test]
    fn capacity_holds_under_a_frozen_thread() {
        let mut vector = BoundedVec::<u32>::reserve(64);
        let mut random = Random::new(0x2545_F491_4F6C_DD1D);
        let _scope = crate::allocation::freeze_scope();

        for _ in 0..4_096 {
            let operation = random.below(3);

            match operation {
                0 => {
                    let pushed = vector.push(random.below(1_000));

                    assert!(pushed || vector.is_full());
                }
                1 => {
                    let popped = vector.pop();

                    assert!(popped.is_some() || vector.is_empty());
                }
                _ => vector.clear(),
            }

            assert!(vector.count() <= 64);
        }
    }
}
