use core::fmt;
use core::mem::MaybeUninit;

use crate::bounded::Span;

const HASH_OFFSET: u64 = 0xcbf2_9ce4_8422_2325;
const HASH_PRIME: u64 = 0x0000_0100_0000_01b3;

#[derive(Clone, Copy, Debug)]
struct Entry<V> {
    hash: u64,
    key: Span,
    value: V,
}

pub struct Table<V> {
    count: u32,
    count_max: u32,
    present: Vec<u64>,
    slots: Vec<MaybeUninit<Entry<V>>>,
}

impl<V> fmt::Debug for Table<V> {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("Table")
            .field("count", &self.count)
            .field("count_max", &self.count_max)
            .finish_non_exhaustive()
    }
}

impl<V: Copy> Table<V> {
    pub fn reserve(count_max: u32) -> Self {
        assert!(count_max > 0);

        assert!(!crate::allocation::is_frozen());

        let capacity = (count_max * 2).next_power_of_two();

        assert!(capacity >= count_max * 2);
        assert!(capacity.is_power_of_two());

        let mut slots = Vec::with_capacity(capacity as usize);

        unsafe {
            slots.set_len(capacity as usize);
        }

        Self {
            count: 0,
            count_max,
            present: vec![0_u64; (capacity as usize).div_ceil(64)],
            slots,
        }
    }

    fn entry_at(&self, index: usize) -> Entry<V> {
        assert!(self.is_present(index));

        unsafe { self.slots[index].assume_init() }
    }

    fn is_present(&self, index: usize) -> bool {
        assert!(index < self.slots.len());

        (self.present[index >> 6_u32] >> (index & 63)) & 1 == 1
    }

    fn mark_present(&mut self, index: usize) {
        assert!(index < self.slots.len());

        self.present[index >> 6_u32] |= 1_u64 << (index & 63);
    }

    pub const fn count_max(&self) -> u32 {
        self.count_max
    }

    pub fn count(&self) -> u32 {
        assert!(self.count <= self.count_max);

        self.count
    }

    pub fn is_empty(&self) -> bool {
        self.count == 0
    }

    pub fn get(&self, hash: u64, equal: impl Fn(Span) -> bool) -> Option<V> {
        let mut index = self.index_of(hash);

        for _ in 0..self.slots.len() {
            if !self.is_present(index) {
                return None;
            }

            let entry = self.entry_at(index);

            if entry.hash == hash && equal(entry.key) {
                return Some(entry.value);
            }

            index = self.index_next(index);
        }

        unreachable!()
    }

    #[must_use]
    pub fn insert(&mut self, hash: u64, key: Span, value: V, equal: impl Fn(Span) -> bool) -> bool {
        assert!(key.length > 0);

        if self.count == self.count_max {
            return false;
        }

        let mut index = self.index_of(hash);

        for _ in 0..self.slots.len() {
            if !self.is_present(index) {
                self.slots[index] = MaybeUninit::new(Entry { hash, key, value });
                self.mark_present(index);
                self.count += 1;

                assert!(self.count <= self.count_max);

                return true;
            }

            let entry = self.entry_at(index);

            if entry.hash == hash && equal(entry.key) {
                return false;
            }

            index = self.index_next(index);
        }

        unreachable!()
    }

    pub fn clear(&mut self) {
        self.present.fill(0);

        self.count = 0;

        assert!(self.is_empty());
    }

    pub fn iter(&self) -> impl Iterator<Item = (Span, V)> + '_ {
        (0..self.slots.len()).filter_map(|index| {
            if !self.is_present(index) {
                return None;
            }

            let entry = self.entry_at(index);

            Some((entry.key, entry.value))
        })
    }

    fn index_next(&self, index: usize) -> usize {
        assert!(index < self.slots.len());

        (index + 1) & (self.slots.len() - 1)
    }

    fn index_of(&self, hash: u64) -> usize {
        let mask = self.slots.len() as u64 - 1;
        let index = usize::try_from(hash & mask).expect("the masked hash fits in usize");

        assert!(index < self.slots.len());

        index
    }
}

pub fn hash_of(bytes: &[u8]) -> u64 {
    assert!(!bytes.is_empty());

    let mut hash = HASH_OFFSET;

    for byte in bytes {
        hash ^= u64::from(*byte);
        hash = hash.wrapping_mul(HASH_PRIME);
    }

    hash
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::bounded::{Arena, Random};

    fn interned(arena: &mut Arena, name: &[u8]) -> (u64, Span) {
        (
            hash_of(name),
            arena.intern(name).expect("the arena holds it"),
        )
    }

    #[test]
    fn lookup_finds_a_key_read_out_of_a_file() {
        let mut arena = Arena::reserve(256);
        let mut table = Table::<u32>::reserve(4);
        let (base, base_key) = interned(&mut arena, b"base.html");
        let (row, row_key) = interned(&mut arena, b"partials/row.html");

        assert!(table.insert(base, base_key, 7, |span| arena.bytes_of(span)
            == b"base.html"));

        assert!(table.insert(row, row_key, 9, |span| {
            arena.bytes_of(span) == b"partials/row.html"
        }));

        let _scope = crate::allocation::freeze_scope();

        assert_eq!(
            table.get(base, |span| arena.bytes_of(span) == b"base.html"),
            Some(7)
        );

        assert_eq!(
            table.get(row, |span| arena.bytes_of(span) == b"partials/row.html"),
            Some(9)
        );

        assert_eq!(
            table.get(hash_of(b"missing.html"), |span| {
                arena.bytes_of(span) == b"missing.html"
            }),
            None
        );

        assert_eq!(table.count(), 2);
    }

    #[test]
    fn insert_refuses_a_duplicate_key() {
        let mut arena = Arena::reserve(64);
        let mut table = Table::<u32>::reserve(4);
        let (hash, key) = interned(&mut arena, b"base.html");

        assert!(table.insert(hash, key, 1, |span| arena.bytes_of(span) == b"base.html"));

        let second = arena.intern(b"base.html").expect("the arena holds it");

        assert!(!table.insert(hash, second, 2, |span| {
            arena.bytes_of(span) == b"base.html"
        }));

        assert_eq!(
            table.get(hash, |span| arena.bytes_of(span) == b"base.html"),
            Some(1)
        );

        assert_eq!(table.count(), 1);
    }

    #[test]
    fn insert_refuses_past_the_reserved_count() {
        let mut arena = Arena::reserve(64);
        let mut table = Table::<u32>::reserve(2);

        for name in [b"one".as_slice(), b"two".as_slice()] {
            let (hash, key) = interned(&mut arena, name);

            assert!(table.insert(hash, key, 0, |span| arena.bytes_of(span) == name));
        }

        let (hash, key) = interned(&mut arena, b"three");

        assert!(!table.insert(hash, key, 0, |span| arena.bytes_of(span) == b"three"));
        assert_eq!(table.count(), 2);
    }

    #[test]
    fn two_keys_sharing_a_hash_resolve_by_probing() {
        const NAMES: [&[u8]; 8] = [
            b"alpha",
            b"beta",
            b"gamma",
            b"delta",
            b"epsilon",
            b"zeta",
            b"eta",
            b"theta",
        ];

        let mut arena = Arena::reserve(256);
        let mut table = Table::<u32>::reserve(8);

        for (value, name) in NAMES.iter().enumerate() {
            let (hash, key) = interned(&mut arena, name);

            let written = table.insert(
                hash,
                key,
                u32::try_from(value).expect("the index fits"),
                |span| arena.bytes_of(span) == *name,
            );

            assert!(written);
        }

        let mut random = Random::new(0x9E37_79B9_7F4A_7C15);
        let _scope = crate::allocation::freeze_scope();

        for _ in 0..1_024 {
            let index = random.below(8) as usize;
            let name = NAMES[index];

            assert_eq!(
                table.get(hash_of(name), |span| arena.bytes_of(span) == name),
                Some(u32::try_from(index).expect("the index fits"))
            );
        }
    }

    #[test]
    fn clear_empties_the_table_without_allocating() {
        let mut arena = Arena::reserve(64);
        let mut table = Table::<u32>::reserve(4);
        let (hash, key) = interned(&mut arena, b"base.html");

        assert!(table.insert(hash, key, 1, |span| arena.bytes_of(span) == b"base.html"));

        let _scope = crate::allocation::freeze_scope();

        table.clear();

        assert!(table.is_empty());

        assert_eq!(
            table.get(hash, |span| arena.bytes_of(span) == b"base.html"),
            None
        );
    }

    #[test]
    fn iter_yields_every_row() {
        let mut arena = Arena::reserve(64);
        let mut table = Table::<u32>::reserve(4);

        for (value, name) in [b"one".as_slice(), b"two".as_slice()].iter().enumerate() {
            let (hash, key) = interned(&mut arena, name);

            let written = table.insert(
                hash,
                key,
                u32::try_from(value).expect("the index fits"),
                |span| arena.bytes_of(span) == *name,
            );

            assert!(written);
        }

        let mut values = table.iter().map(|(_, value)| value).collect::<Vec<_>>();

        values.sort_unstable();

        assert_eq!(values, [0, 1]);
    }
}
