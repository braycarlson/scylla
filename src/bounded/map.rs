use crate::bounded::hash_of;

const KEY_BYTES_MAX: usize = 256;

#[derive(Clone, Copy, Debug)]
struct Entry<V> {
    key: &'static [u8],
    value: V,
}

#[derive(Debug)]
pub struct FixedMap<V> {
    count: u32,
    count_max: u32,
    slots: Vec<Option<Entry<V>>>,
}

impl<V: Copy> FixedMap<V> {
    pub fn reserve(count_max: u32) -> Self {
        assert!(count_max > 0);

        assert!(!crate::allocation::is_frozen());

        let capacity = (count_max * 2).next_power_of_two();

        assert!(capacity >= count_max * 2);
        assert!(capacity.is_power_of_two());

        Self {
            count: 0,
            count_max,
            slots: vec![None; capacity as usize],
        }
    }

    pub const fn count_max(&self) -> u32 {
        self.count_max
    }

    pub fn count(&self) -> u32 {
        assert!(self.count <= self.count_max);

        self.count
    }

    pub fn get(&self, key: &[u8]) -> Option<V> {
        assert!(!key.is_empty());
        assert!(key.len() <= KEY_BYTES_MAX);

        let mut index = self.index_of(key);

        for _ in 0..self.slots.len() {
            let entry = self.slots[index]?;

            if entry.key == key {
                return Some(entry.value);
            }

            index = self.index_next(index);
        }

        unreachable!()
    }

    #[must_use]
    pub fn insert(&mut self, key: &'static [u8], value: V) -> bool {
        assert!(!key.is_empty());
        assert!(key.len() <= KEY_BYTES_MAX);

        if self.count == self.count_max {
            return false;
        }

        let mut index = self.index_of(key);

        for _ in 0..self.slots.len() {
            match self.slots[index] {
                None => {
                    self.slots[index] = Some(Entry { key, value });
                    self.count += 1;

                    assert!(self.count <= self.count_max);

                    return true;
                }
                Some(entry) => {
                    if entry.key == key {
                        return false;
                    }
                }
            }

            index = self.index_next(index);
        }

        unreachable!()
    }

    pub fn insert_assert(&mut self, key: &'static [u8], value: V) {
        let count_before = self.count();
        let inserted = self.insert(key, value);

        assert!(inserted);
        assert_eq!(self.count(), count_before + 1);
    }

    fn index_next(&self, index: usize) -> usize {
        assert!(index < self.slots.len());

        (index + 1) & (self.slots.len() - 1)
    }

    fn index_of(&self, key: &[u8]) -> usize {
        assert!(!key.is_empty());
        assert!(key.len() <= KEY_BYTES_MAX);

        let mask = self.slots.len() as u64 - 1;
        let index = usize::try_from(hash_of(key) & mask).expect("the masked hash fits in usize");

        assert!(index < self.slots.len());

        index
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::bounded::Random;

    #[test]
    fn lookup_finds_each_registered_key() {
        let mut map = FixedMap::<u32>::reserve(4);

        map.insert_assert(b"rs", 0);
        map.insert_assert(b"zig", 1);
        map.insert_assert(b"py", 2);

        let _scope = crate::allocation::freeze_scope();

        assert_eq!(map.get(b"rs"), Some(0));
        assert_eq!(map.get(b"zig"), Some(1));
        assert_eq!(map.get(b"py"), Some(2));
        assert_eq!(map.get(b"go"), None);
        assert_eq!(map.count(), 3);
    }

    #[test]
    fn insert_refuses_a_duplicate_key() {
        let mut map = FixedMap::<u32>::reserve(4);

        map.insert_assert(b"rs", 0);

        let inserted = map.insert(b"rs", 1);

        assert!(!inserted);
        assert_eq!(map.get(b"rs"), Some(0));
        assert_eq!(map.count(), 1);
    }

    #[test]
    fn insert_refuses_past_the_registered_count() {
        let mut map = FixedMap::<u32>::reserve(2);

        map.insert_assert(b"rs", 0);
        map.insert_assert(b"zig", 1);

        let written = map.insert(b"py", 2);

        assert!(!written);
        assert_eq!(map.count(), 2);
    }

    #[test]
    fn collisions_resolve_by_probing() {
        const KEYS: [&[u8]; 8] = [
            b"alpha",
            b"beta",
            b"gamma",
            b"delta",
            b"epsilon",
            b"zeta",
            b"eta",
            b"theta",
        ];

        let mut map = FixedMap::<u32>::reserve(8);

        for (value, key) in KEYS.iter().enumerate() {
            map.insert_assert(key, u32::try_from(value).expect("the index fits"));
        }

        let mut random = Random::new(0x9E37_79B9_7F4A_7C15);
        let _scope = crate::allocation::freeze_scope();

        for _ in 0..1_024 {
            let index = random.below(8) as usize;

            assert_eq!(
                map.get(KEYS[index]),
                Some(u32::try_from(index).expect("the index fits"))
            );
        }
    }
}
