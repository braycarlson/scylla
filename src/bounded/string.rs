use core::fmt;

use crate::bounded::{Bytes, count_of};

#[derive(Debug)]
pub struct BoundedString {
    bytes: Vec<u8>,
    capacity: u32,
}

impl BoundedString {
    pub fn reserve(capacity: u32) -> Self {
        assert!(capacity > 0);

        assert!(!crate::allocation::is_frozen());

        let bytes = Vec::with_capacity(capacity as usize);

        assert!(bytes.capacity() >= capacity as usize);

        Self { bytes, capacity }
    }

    pub fn as_bytes(&self) -> &[u8] {
        &self.bytes
    }

    pub fn as_str(&self) -> &str {
        core::str::from_utf8(&self.bytes).expect("a bounded string holds valid UTF-8")
    }

    pub fn capacity(&self) -> u32 {
        assert!(self.capacity > 0);

        self.capacity
    }

    pub fn clear(&mut self) {
        self.bytes.clear();

        assert_eq!(self.count(), 0);
    }

    pub fn count(&self) -> u32 {
        let count = count_of(self.bytes.len());

        assert!(count <= self.capacity);

        count
    }

    pub fn is_empty(&self) -> bool {
        self.count() == 0
    }

    #[must_use]
    fn bytes_push(&mut self, bytes: &[u8]) -> bool {
        let count_new = self.count() as usize + bytes.len();

        if count_new > self.capacity as usize {
            return false;
        }

        assert!(count_new <= self.bytes.capacity());

        self.bytes.extend_from_slice(bytes);

        assert_eq!(self.count() as usize, count_new);

        true
    }

    #[must_use]
    pub fn push_str(&mut self, text: &str) -> bool {
        self.bytes_push(text.as_bytes())
    }

    pub fn flatten(&mut self, start: u32) -> u32 {
        assert!(start <= self.count());

        let mut read = start as usize;
        let mut write = start as usize;
        let mut spaced = false;

        while read < self.bytes.len() {
            let byte = self.bytes[read];
            let blank = matches!(byte, b' ' | b'\t' | b'\n' | b'\r');

            read += 1;

            if blank {
                spaced = write > start as usize;

                continue;
            }

            if spaced {
                self.bytes[write] = b' ';
                write += 1;
                spaced = false;
            }

            self.bytes[write] = byte;
            write += 1;
        }

        self.bytes.truncate(write);

        count_of(write) - start
    }

    pub fn truncate(&mut self, count: u32) {
        assert!(count <= self.count());

        self.bytes.truncate(count as usize);

        assert_eq!(self.count(), count);
    }
}

impl Bytes for BoundedString {
    fn push_bytes(&mut self, bytes: &[u8]) -> bool {
        if core::str::from_utf8(bytes).is_err() {
            return false;
        }

        self.bytes_push(bytes)
    }
}

impl fmt::Write for BoundedString {
    fn write_str(&mut self, text: &str) -> fmt::Result {
        if self.push_str(text) {
            return Ok(());
        }

        Err(fmt::Error)
    }
}

#[cfg(test)]
mod tests {
    use core::fmt::Write as _;

    use super::*;

    #[test]
    fn flattening_collapses_every_blank_run() {
        let mut text = BoundedString::reserve(64);
        let written = text.push_str("head: one\n    two\t\tthree  ");

        assert!(written);
        assert_eq!(text.flatten(0), 19);
        assert_eq!(text.as_str(), "head: one two three");
    }

    #[test]
    fn flattening_leaves_the_prefix_alone() {
        let mut text = BoundedString::reserve(64);
        let written_2 = text.push_str("kept  ");

        assert!(written_2);

        let start = text.count();
        let written_3 = text.push_str("one\ntwo");

        assert!(written_3);
        let _ = text.flatten(start);

        assert_eq!(text.as_str(), "kept  one two");
    }

    #[test]
    fn writing_stops_at_capacity() {
        let mut text = BoundedString::reserve(8);
        let written_4 = text.push_str("linter");

        assert!(written_4);
        assert_eq!(text.count(), 6);
        let written_5 = text.push_str("xyz");

        assert!(!written_5);
        assert_eq!(text.as_str(), "linter");
    }

    #[test]
    fn formatting_reports_overflow() {
        let mut text = BoundedString::reserve(16);
        let _scope = crate::allocation::freeze_scope();
        let first = core::hint::black_box(4_096_u32);
        let second = core::hint::black_box(8_192_u32);
        let written = write!(text, "{first} of {second} bytes");

        assert!(written.is_err());
        assert_eq!(text.count(), 12);
    }

    #[test]
    fn clearing_restores_the_whole_capacity() {
        let mut text = BoundedString::reserve(16);
        let _scope = crate::allocation::freeze_scope();

        for _ in 0..64 {
            text.clear();

            assert!(text.is_empty());

            let written_6 = text.push_str("0123456789abcdef");

            assert!(written_6);
            assert_eq!(text.count(), text.capacity());
        }
    }

    #[test]
    fn truncation_keeps_the_prefix() {
        let mut text = BoundedString::reserve(32);
        let written_7 = text.push_str("linter lints");

        assert!(written_7);

        text.truncate(6);

        assert_eq!(text.as_str(), "linter");
    }
}
