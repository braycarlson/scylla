use core::time::Duration;

use crate::bounded::BoundedVec;
use crate::path::{Facts, PATH_BYTES_MAX, facts_of, join};

pub const POLL_MILLISECONDS: u64 = 200;

#[derive(Debug)]
pub struct Stamps {
    held: BoundedVec<Facts>,
}

impl Stamps {
    pub fn reserve(count_max: u32) -> Self {
        assert!(count_max > 0);
        assert!(!crate::allocation::is_frozen());

        Self {
            held: BoundedVec::reserve(count_max),
        }
    }

    pub fn capacity(&self) -> u32 {
        self.held.capacity()
    }

    pub fn clear(&mut self) {
        self.held.clear();
    }

    pub fn count(&self) -> u32 {
        self.held.count()
    }

    pub fn record(&mut self, index: u32, stamp: Facts) -> bool {
        if index >= self.held.capacity() {
            return false;
        }

        while self.held.count() <= index {
            self.held.push_assert(Facts::default());
        }

        let previous = self.held[index as usize];

        self.held[index as usize] = stamp;

        previous != stamp
    }

    pub fn record_path(&mut self, index: u32, path: &[u8]) -> bool {
        self.record(index, stamp_of(path))
    }
}

pub fn rest() {
    std::thread::sleep(Duration::from_millis(POLL_MILLISECONDS));
}

pub fn stamp_of(path: &[u8]) -> Facts {
    facts_of(path).unwrap_or_default()
}

pub fn stamp_in(root: &[u8], name: &[u8]) -> Facts {
    if root.is_empty() {
        return Facts::default();
    }

    let mut path = [0_u8; PATH_BYTES_MAX];

    let Some(length) = join(&mut path, root, name) else {
        return Facts::default();
    };

    stamp_of(&path[..length])
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_first_look_is_a_change() {
        let mut stamps = Stamps::reserve(4);

        crate::allocation::frozen(|| {
            let stamp = stamp_of(b"Cargo.toml");

            assert_ne!(stamp, Facts::default());
            assert!(stamps.record(2, stamp));
            assert_eq!(stamps.count(), 3);
            assert!(!stamps.record(2, stamp));
            assert!(stamps.record(0, stamp));
            assert!(!stamps.record_path(2, b"Cargo.toml"));
        });
    }

    #[test]
    fn a_slot_past_the_reservation_records_nothing() {
        let mut stamps = Stamps::reserve(2);

        crate::allocation::frozen(|| {
            assert!(!stamps.record(2, stamp_of(b"Cargo.toml")));
            assert_eq!(stamps.count(), 0);
        });
    }

    #[test]
    fn a_missing_path_stamps_empty() {
        crate::allocation::frozen(|| {
            assert_eq!(stamp_of(b"/nonexistent/scylla"), Facts::default());
            assert_eq!(stamp_in(b"", b"Cargo.toml"), Facts::default());
            assert_eq!(stamp_in(b"/nonexistent", b"Cargo.toml"), Facts::default());
            assert_ne!(stamp_in(b".", b"Cargo.toml"), Facts::default());
        });
    }

    #[test]
    fn a_cleared_table_forgets_every_stamp() {
        let mut stamps = Stamps::reserve(2);

        crate::allocation::frozen(|| {
            let stamp = stamp_of(b"Cargo.toml");

            assert!(stamps.record(0, stamp));

            stamps.clear();

            assert_eq!(stamps.count(), 0);
            assert!(stamps.record(0, stamp));
        });
    }
}
