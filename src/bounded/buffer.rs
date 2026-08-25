use std::io::Read;

use crate::bounded::{Bytes, count_of};

#[derive(Debug)]
pub struct Buffer {
    bytes: Vec<u8>,
    length: u32,
}

impl Buffer {
    pub fn reserve(capacity: u32) -> Self {
        assert!(capacity > 0);

        assert!(!crate::allocation::is_frozen());

        let bytes = vec![0_u8; capacity as usize];

        assert_eq!(count_of(bytes.len()), capacity);

        Self { bytes, length: 0 }
    }

    pub fn as_bytes(&self) -> &[u8] {
        assert!(self.length <= self.capacity());

        &self.bytes[..self.length as usize]
    }

    pub fn capacity(&self) -> u32 {
        count_of(self.bytes.len())
    }

    pub fn clear(&mut self) {
        self.length = 0;

        assert!(self.is_empty());
    }

    pub fn count(&self) -> u32 {
        assert!(self.length <= self.capacity());

        self.length
    }

    pub const fn is_empty(&self) -> bool {
        self.length == 0
    }

    pub fn patch(&mut self, offset: u32, bytes: &[u8]) -> bool {
        let end = offset as usize + bytes.len();

        if end > self.length as usize {
            return false;
        }

        self.bytes[offset as usize..end].copy_from_slice(bytes);

        true
    }

    pub fn splice(&mut self, start: u32, end: u32, inserted: &[u8]) -> bool {
        assert!(start <= end);
        assert!(end <= self.length);

        let removed = (end - start) as usize;
        let length = self.length as usize - removed + inserted.len();

        if length > self.bytes.len() {
            return false;
        }

        self.bytes.copy_within(
            end as usize..self.length as usize,
            start as usize + inserted.len(),
        );

        self.bytes[start as usize..start as usize + inserted.len()].copy_from_slice(inserted);
        self.length = count_of(length);

        true
    }

    pub fn truncate(&mut self, count: u32) {
        assert!(count <= self.length);

        self.length = count;

        assert_eq!(self.count(), count);
    }

    #[must_use]
    fn bytes_push(&mut self, bytes: &[u8]) -> bool {
        let length = self.length as usize + bytes.len();

        if length > self.bytes.len() {
            return false;
        }

        self.bytes[self.length as usize..length].copy_from_slice(bytes);
        self.length = count_of(length);

        true
    }

    pub fn read_from(&mut self, source: &mut impl Read) -> std::io::Result<bool> {
        self.length = 0;

        for _ in 0..=self.capacity() {
            if self.length == self.capacity() {
                let mut probe = [0_u8; 1];
                let extra = source.read(&mut probe)?;

                return Ok(extra == 0);
            }

            let read = source.read(&mut self.bytes[self.length as usize..])?;

            if read == 0 {
                return Ok(true);
            }

            self.length += count_of(read);
        }

        Ok(false)
    }

    pub fn read_exact_from(
        &mut self,
        source: &mut impl Read,
        length: u32,
    ) -> std::io::Result<bool> {
        if length > self.capacity() {
            return Ok(false);
        }

        self.length = 0;

        source.read_exact(&mut self.bytes[..length as usize])?;

        self.length = length;

        assert_eq!(self.count(), length);

        Ok(true)
    }
}

impl Bytes for Buffer {
    fn push_bytes(&mut self, bytes: &[u8]) -> bool {
        self.bytes_push(bytes)
    }
}

#[cfg(test)]
mod tests {
    use std::io::ErrorKind;

    use super::*;

    struct Chunked<'source> {
        bytes: &'source [u8],
        offset: usize,
        step: usize,
        widths: &'source [usize],
    }

    struct Failing<'source> {
        bytes: &'source [u8],
        kind: ErrorKind,
        limit: usize,
        offset: usize,
        raised: bool,
    }

    impl Read for Chunked<'_> {
        fn read(&mut self, target: &mut [u8]) -> std::io::Result<usize> {
            assert!(!target.is_empty());
            assert!(self.offset <= self.bytes.len());

            let remaining = self.bytes.len() - self.offset;

            if remaining == 0 {
                return Ok(0);
            }

            let width = self.widths[self.step % self.widths.len()]
                .min(remaining)
                .min(target.len());

            self.step += 1;
            target[..width].copy_from_slice(&self.bytes[self.offset..self.offset + width]);
            self.offset += width;

            Ok(width)
        }
    }

    impl Read for Failing<'_> {
        fn read(&mut self, target: &mut [u8]) -> std::io::Result<usize> {
            assert!(self.offset <= self.limit);
            assert!(self.limit <= self.bytes.len());

            if self.offset == self.limit && !self.raised {
                self.raised = true;

                return Err(std::io::Error::from(self.kind));
            }

            let width = (self.limit - self.offset).min(target.len());

            target[..width].copy_from_slice(&self.bytes[self.offset..self.offset + width]);
            self.offset += width;

            Ok(width)
        }
    }

    #[test]
    fn a_push_appends_to_the_contents() {
        let mut buffer = Buffer::reserve(16);
        let _scope = crate::allocation::freeze_scope();

        assert!(buffer.push_bytes(b"linter"));
        assert_eq!(buffer.count(), 6);
        assert!(buffer.push_bytes(b" lints"));
        assert_eq!(buffer.as_bytes(), b"linter lints");

        buffer.clear();

        assert!(buffer.is_empty());
    }

    #[test]
    fn a_truncation_keeps_the_prefix() {
        let mut buffer = Buffer::reserve(16);
        let _scope = crate::allocation::freeze_scope();

        assert!(buffer.push_bytes(b"linter lints"));

        buffer.truncate(6);

        assert_eq!(buffer.as_bytes(), b"linter");
        assert!(buffer.push_bytes(b"s"));
        assert_eq!(buffer.as_bytes(), b"linters");
    }

    #[test]
    fn a_push_past_capacity_is_refused() {
        let mut buffer = Buffer::reserve(4);
        let _scope = crate::allocation::freeze_scope();

        assert!(!buffer.push_bytes(b"linter"));
        assert!(buffer.is_empty());
    }

    #[test]
    fn a_read_fills_the_requested_length() {
        let mut buffer = Buffer::reserve(16);
        let mut source = &b"linter lints"[..];
        let _scope = crate::allocation::freeze_scope();

        assert!(
            buffer
                .read_exact_from(&mut source, 6)
                .expect("the source holds the bytes")
        );

        assert_eq!(buffer.as_bytes(), b"linter");
    }

    #[test]
    fn a_read_past_capacity_is_refused() {
        let mut buffer = Buffer::reserve(4);
        let mut source = &b"linter"[..];
        let _scope = crate::allocation::freeze_scope();

        assert!(
            !buffer
                .read_exact_from(&mut source, 6)
                .expect("the length is checked before the read")
        );

        assert!(buffer.is_empty());
    }

    #[test]
    fn a_reader_that_answers_one_byte_at_a_time_still_fills_the_buffer() {
        let mut buffer = Buffer::reserve(32);

        let mut source = Chunked {
            bytes: b"linter lints",
            offset: 0,
            step: 0,
            widths: &[1],
        };

        let _scope = crate::allocation::freeze_scope();

        assert!(
            buffer
                .read_from(&mut source)
                .expect("the reader never errors")
        );

        assert_eq!(buffer.as_bytes(), b"linter lints");
    }

    #[test]
    fn a_reader_that_answers_in_irregular_chunks_still_fills_the_buffer() {
        let mut buffer = Buffer::reserve(32);

        let mut source = Chunked {
            bytes: b"linter lints tigerstyle",
            offset: 0,
            step: 0,
            widths: &[3, 1, 7, 2],
        };

        let _scope = crate::allocation::freeze_scope();

        assert!(
            buffer
                .read_from(&mut source)
                .expect("the reader never errors")
        );

        assert_eq!(buffer.as_bytes(), b"linter lints tigerstyle");
    }

    #[test]
    fn an_interrupted_read_is_reported_rather_than_retried() {
        let mut buffer = Buffer::reserve(32);

        let mut source = Failing {
            bytes: b"linter lints",
            kind: ErrorKind::Interrupted,
            limit: 6,
            offset: 0,
            raised: false,
        };

        let _scope = crate::allocation::freeze_scope();
        let outcome = buffer.read_from(&mut source);
        let error = outcome.expect_err("the interruption reaches the caller");

        assert_eq!(error.kind(), ErrorKind::Interrupted);
        assert_eq!(buffer.as_bytes(), b"linter");
    }

    #[test]
    fn an_error_partway_through_reaches_the_caller_with_no_invented_bytes() {
        let mut buffer = Buffer::reserve(32);

        let mut source = Failing {
            bytes: b"linter lints",
            kind: ErrorKind::BrokenPipe,
            limit: 4,
            offset: 0,
            raised: false,
        };

        let _scope = crate::allocation::freeze_scope();
        let outcome = buffer.read_from(&mut source);
        let error = outcome.expect_err("the failure reaches the caller");

        assert_eq!(error.kind(), ErrorKind::BrokenPipe);
        assert_eq!(buffer.as_bytes(), b"lint");
    }

    #[test]
    fn a_stream_longer_than_the_buffer_is_refused() {
        let mut buffer = Buffer::reserve(8);

        let mut source = Chunked {
            bytes: b"linter lints tigerstyle",
            offset: 0,
            step: 0,
            widths: &[5],
        };

        let _scope = crate::allocation::freeze_scope();

        assert!(
            !buffer
                .read_from(&mut source)
                .expect("the reader never errors")
        );

        assert_eq!(buffer.count(), 8);
    }

    #[test]
    fn a_stream_that_exactly_fills_the_buffer_is_complete() {
        let mut buffer = Buffer::reserve(12);

        let mut source = Chunked {
            bytes: b"linter lints",
            offset: 0,
            step: 0,
            widths: &[5],
        };

        let _scope = crate::allocation::freeze_scope();

        assert!(
            buffer
                .read_from(&mut source)
                .expect("the reader never errors")
        );

        assert_eq!(buffer.as_bytes(), b"linter lints");
    }
}
