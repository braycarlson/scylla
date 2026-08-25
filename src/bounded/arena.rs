use crate::bounded::{Bytes, Reset, Span, count_of};

#[derive(Debug)]
pub struct Arena {
    bytes: Vec<u8>,
    capacity: u32,
}

impl Arena {
    pub fn reserve(capacity: u32) -> Self {
        assert!(capacity > 0);

        assert!(!crate::allocation::is_frozen());

        let bytes = Vec::with_capacity(capacity as usize);

        assert!(bytes.capacity() >= capacity as usize);
        assert!(bytes.is_empty());

        Self { bytes, capacity }
    }

    pub const fn capacity(&self) -> u32 {
        self.capacity
    }

    pub fn count(&self) -> u32 {
        let count = count_of(self.bytes.len());

        assert!(count <= self.capacity);

        count
    }

    pub fn is_empty(&self) -> bool {
        self.bytes.is_empty()
    }

    #[must_use]
    pub fn intern(&mut self, bytes: &[u8]) -> Option<Span> {
        assert!(!bytes.is_empty());

        let offset = self.count();
        let length = count_of(bytes.len());

        if self.capacity - offset < length {
            return None;
        }

        self.bytes.extend_from_slice(bytes);

        assert!(self.bytes.len() <= self.capacity as usize);

        let span = Span { length, offset };

        assert_eq!(self.bytes_of(span), bytes);

        Some(span)
    }

    #[must_use]
    pub fn copy_of(&mut self, span: Span) -> Option<Span> {
        assert!(span.end() <= self.count());

        let offset = self.count();

        if self.capacity - offset < span.length {
            return None;
        }

        self.bytes.extend_from_within(span.range());

        assert!(self.bytes.len() <= self.capacity as usize);

        Some(Span {
            length: span.length,
            offset,
        })
    }

    pub fn reset(&mut self) {
        self.bytes.clear();

        assert!(self.bytes.is_empty());
        assert!(self.bytes.capacity() >= self.capacity as usize);
    }

    pub fn truncate(&mut self, count: u32) {
        assert!(count <= self.count());

        self.bytes.truncate(count as usize);

        assert_eq!(self.count(), count);
    }

    pub fn bytes_of(&self, span: Span) -> &[u8] {
        assert!(span.end() <= self.count());

        &self.bytes[span.range()]
    }
}

impl Bytes for Arena {
    fn push_bytes(&mut self, bytes: &[u8]) -> bool {
        self.intern(bytes).is_some()
    }
}

impl Reset for Arena {
    fn reset(&mut self) {
        Self::reset(self);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_interned_name_reads_back() {
        let mut arena = Arena::reserve(64);
        let first = arena.intern(b"base.html").expect("the arena holds it");

        let second = arena
            .intern(b"partials/row.html")
            .expect("the arena holds it");

        let _scope = crate::allocation::freeze_scope();

        assert_eq!(arena.bytes_of(first), b"base.html");
        assert_eq!(arena.bytes_of(second), b"partials/row.html");
        assert_eq!(arena.count(), 26);
    }

    #[test]
    fn the_same_name_twice_takes_two_spans() {
        let mut arena = Arena::reserve(64);
        let first = arena.intern(b"base.html").expect("the arena holds it");
        let second = arena.intern(b"base.html").expect("the arena holds it");

        assert_ne!(first.offset, second.offset);
        assert_eq!(arena.bytes_of(first), arena.bytes_of(second));
    }

    #[test]
    fn intern_refuses_past_the_reserved_bytes() {
        let mut arena = Arena::reserve(8);

        assert!(arena.intern(b"abcdefgh").is_some());
        assert!(arena.intern(b"i").is_none());
        assert_eq!(arena.count(), 8);
    }

    #[test]
    fn reset_empties_the_arena_without_allocating() {
        let mut arena = Arena::reserve(16);

        assert!(arena.intern(b"first").is_some());

        let _scope = crate::allocation::freeze_scope();

        arena.reset();

        assert!(arena.is_empty());

        let span = arena.intern(b"second").expect("the arena holds it");

        assert_eq!(span.offset, 0);
        assert_eq!(arena.bytes_of(span), b"second");
    }
}
