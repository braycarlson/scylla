use crate::bounded::{BoundedVec, Reset, count_of};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Handle {
    generation: u32,
    index: u32,
}

#[derive(Debug)]
struct Slot<T> {
    generation: u32,
    occupied: bool,
    value: T,
}

#[derive(Debug)]
pub struct Pool<T> {
    free: BoundedVec<u32>,
    slots: Vec<Slot<T>>,
}

impl<T: Reset> Pool<T> {
    pub fn reserve(count: u32, mut make: impl FnMut(u32) -> T) -> Self {
        assert!(count > 0);

        assert!(!crate::allocation::is_frozen());

        let mut free = BoundedVec::<u32>::reserve(count);
        let mut slots = Vec::with_capacity(count as usize);

        for index in 0..count {
            slots.push(Slot {
                generation: 0,
                occupied: false,
                value: make(index),
            });

            free.push_assert(count - index - 1);
        }

        assert_eq!(count_of(slots.len()), count);
        assert_eq!(free.count(), count);

        Self { free, slots }
    }

    pub fn acquire(&mut self) -> Option<Handle> {
        let index = self.free.pop()?;
        let slot = &mut self.slots[index as usize];

        assert!(!slot.occupied);

        slot.occupied = true;

        Some(Handle {
            generation: slot.generation,
            index,
        })
    }

    pub fn capacity(&self) -> u32 {
        count_of(self.slots.len())
    }

    pub fn contains(&self, handle: Handle) -> bool {
        if handle.index >= self.capacity() {
            return false;
        }

        let slot = &self.slots[handle.index as usize];

        slot.occupied && slot.generation == handle.generation
    }

    pub fn count(&self) -> u32 {
        let count = self.capacity() - self.free.count();

        assert!(count <= self.capacity());

        count
    }

    pub fn get(&self, handle: Handle) -> &T {
        assert!(self.contains(handle));

        &self.slots[handle.index as usize].value
    }

    pub fn get_mut(&mut self, handle: Handle) -> &mut T {
        assert!(self.contains(handle));

        &mut self.slots[handle.index as usize].value
    }

    pub fn iter(&self) -> impl Iterator<Item = (Handle, &T)> {
        self.slots
            .iter()
            .enumerate()
            .filter(|(_, slot)| slot.occupied)
            .map(|(index, slot)| {
                let handle = Handle {
                    generation: slot.generation,
                    index: count_of(index),
                };

                (handle, &slot.value)
            })
    }

    pub fn release(&mut self, handle: Handle) {
        assert!(self.contains(handle));

        let slot = &mut self.slots[handle.index as usize];

        slot.occupied = false;
        slot.generation = slot.generation.wrapping_add(1);
        slot.value.reset();

        self.free.push_assert(handle.index);

        assert!(!self.contains(handle));
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::bounded::Random;

    #[derive(Debug)]
    struct Counter {
        resets: u32,
        value: u32,
    }

    impl Reset for Counter {
        fn reset(&mut self) {
            self.resets += 1;
            self.value = 0;
        }
    }

    fn pool_of(count: u32) -> Pool<Counter> {
        Pool::reserve(count, |_| Counter {
            resets: 0,
            value: 0,
        })
    }

    #[test]
    fn acquire_stops_at_capacity() {
        let mut pool = pool_of(2);
        let _scope = crate::allocation::freeze_scope();
        let first = pool.acquire().expect("the pool has room");
        let second = pool.acquire().expect("the pool has room");

        assert_eq!(pool.count(), pool.capacity());
        assert_eq!(pool.acquire(), None);
        assert_ne!(first, second);
        assert_eq!(pool.count(), 2);
    }

    #[test]
    fn release_resets_the_slot_and_invalidates_the_handle() {
        let mut pool = pool_of(1);
        let _scope = crate::allocation::freeze_scope();
        let handle = pool.acquire().expect("the pool has room");

        pool.get_mut(handle).value = 7;

        assert_eq!(pool.get(handle).value, 7);

        pool.release(handle);

        assert!(!pool.contains(handle));
        assert_eq!(pool.count(), 0);

        let reused = pool.acquire().expect("the slot returns to the pool");

        assert_ne!(reused, handle);
        assert_eq!(pool.count(), 1);
        assert_eq!(pool.get(reused).value, 0);
        assert_eq!(pool.get(reused).resets, 1);
    }

    #[test]
    #[should_panic(expected = "self.contains(handle)")]
    fn a_stale_handle_is_rejected() {
        let mut pool = pool_of(1);
        let handle = pool.acquire().expect("the pool has room");

        pool.release(handle);

        let _ = pool.get(handle);
    }

    #[test]
    fn churn_holds_the_invariants() {
        let mut pool = pool_of(8);
        let mut live = BoundedVec::<Handle>::reserve(8);
        let mut random = Random::new(0xDEAD_BEEF_CAFE_F00D);
        let _scope = crate::allocation::freeze_scope();

        for _ in 0..4_096 {
            let acquiring = random.below(2) == 0;

            if acquiring {
                if let Some(handle) = pool.acquire() {
                    live.push_assert(handle);
                }
            }

            if !acquiring {
                if let Some(handle) = live.pop() {
                    pool.release(handle);
                }
            }

            assert_eq!(pool.count(), live.count());

            for handle in live.iter() {
                assert!(pool.contains(*handle));
            }
        }
    }
}
