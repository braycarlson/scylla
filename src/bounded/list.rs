use crate::bounded::{Arena, BoundedVec, Span, Table, hash_of};

#[derive(Debug)]
pub struct InternedList {
    arena: Arena,
    index: Table<u32>,
    spans: BoundedVec<Span>,
}

impl InternedList {
    pub fn at(&self, index: u32) -> &[u8] {
        assert!(index < self.count());

        self.arena.bytes_of(self.spans[index as usize])
    }

    pub fn clear(&mut self) {
        self.arena.reset();
        self.index.clear();
        self.spans.clear();

        assert!(self.is_empty());
    }

    pub fn count(&self) -> u32 {
        self.spans.count()
    }

    pub fn index_of(&self, bytes: &[u8]) -> Option<u32> {
        if bytes.is_empty() {
            return None;
        }

        self.index
            .get(hash_of(bytes), |key| self.arena.bytes_of(key) == bytes)
    }

    pub fn is_empty(&self) -> bool {
        self.spans.count() == 0
    }

    pub fn is_full(&self) -> bool {
        self.spans.is_full()
    }

    pub fn iter(&self) -> impl Iterator<Item = &[u8]> {
        self.spans.iter().map(|span| self.arena.bytes_of(*span))
    }

    pub fn record(&mut self, bytes: &[u8]) -> Option<u32> {
        if bytes.is_empty() {
            return None;
        }

        if let Some(index) = self.index_of(bytes) {
            return Some(index);
        }

        if self.spans.is_full() {
            return None;
        }

        let Self {
            arena,
            index,
            spans,
        } = self;

        let span = arena.intern(bytes)?;
        let position = spans.count();

        let inserted = index.insert(hash_of(bytes), span, position, |key| {
            arena.bytes_of(key) == bytes
        });

        assert!(inserted);

        spans.push_assert(span);

        Some(position)
    }

    pub fn reserve(count_max: u32, bytes_max: u32) -> Self {
        assert!(count_max > 0);
        assert!(bytes_max > 0);
        assert!(!crate::allocation::is_frozen());

        Self {
            arena: Arena::reserve(bytes_max),
            index: Table::reserve(count_max),
            spans: BoundedVec::reserve(count_max),
        }
    }

    pub fn span_at(&self, index: u32) -> Span {
        assert!(index < self.count());

        self.spans[index as usize]
    }

    pub fn text_of(&self, span: Span) -> &[u8] {
        assert!(span.length > 0);
        assert!(span.end() <= self.arena.count());

        self.arena.bytes_of(span)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_recorded_entry_reads_back_by_index_and_by_bytes() {
        let mut list = InternedList::reserve(4, 64);

        assert_eq!(list.record(b"/tmp/main.rs"), Some(0));
        assert_eq!(list.record(b"/tmp/other.py"), Some(1));
        assert_eq!(list.count(), 2);
        assert_eq!(list.at(0), b"/tmp/main.rs");
        assert_eq!(list.at(1), b"/tmp/other.py");
        assert_eq!(list.index_of(b"/tmp/other.py"), Some(1));
        assert_eq!(list.index_of(b"/tmp/missing"), None);
        assert_eq!(list.iter().collect::<Vec<_>>(), [b"/tmp/main.rs".as_slice(), b"/tmp/other.py"]);
    }

    #[test]
    fn a_span_handed_out_reads_the_same_bytes_as_its_index() {
        let mut list = InternedList::reserve(4, 64);

        assert_eq!(list.record(b"first"), Some(0));
        assert_eq!(list.record(b"second"), Some(1));

        let span = list.span_at(1);

        assert_eq!(span, Span::new(5, 6));
        assert_eq!(list.text_of(span), b"second");
        assert_eq!(list.text_of(list.span_at(0)), list.at(0));
        assert_eq!(list.text_of(Span::new(2, 5)), b"rstse");
    }

    #[test]
    #[should_panic(expected = "span.end() <= self.arena.count()")]
    fn a_span_past_the_arena_is_refused() {
        let mut list = InternedList::reserve(4, 64);

        assert_eq!(list.record(b"abc"), Some(0));

        let _ = list.text_of(Span::new(1, 3));
    }

    #[test]
    fn a_repeated_entry_keeps_its_first_index() {
        let mut list = InternedList::reserve(4, 64);

        assert_eq!(list.record(b"a"), Some(0));
        assert_eq!(list.record(b"b"), Some(1));
        assert_eq!(list.record(b"a"), Some(0));
        assert_eq!(list.count(), 2);
    }

    #[test]
    fn an_empty_entry_is_refused() {
        let mut list = InternedList::reserve(4, 64);

        assert_eq!(list.record(b""), None);
        assert_eq!(list.index_of(b""), None);
        assert!(list.is_empty());
    }

    #[test]
    fn a_full_list_refuses_a_new_entry_and_still_finds_an_old_one() {
        let mut list = InternedList::reserve(2, 64);

        assert_eq!(list.record(b"a"), Some(0));
        assert_eq!(list.record(b"b"), Some(1));
        assert!(list.is_full());
        assert_eq!(list.record(b"c"), None);
        assert_eq!(list.record(b"b"), Some(1));
    }

    #[test]
    fn a_list_with_no_room_for_the_bytes_refuses_the_entry() {
        let mut list = InternedList::reserve(4, 4);

        assert_eq!(list.record(b"abc"), Some(0));
        assert_eq!(list.record(b"de"), None);
        assert_eq!(list.record(b"d"), Some(1));
        assert_eq!(list.count(), 2);
    }

    #[test]
    fn a_cleared_list_forgets_every_entry() {
        let mut list = InternedList::reserve(4, 64);

        assert_eq!(list.record(b"a"), Some(0));

        list.clear();

        assert!(list.is_empty());
        assert_eq!(list.index_of(b"a"), None);
        assert_eq!(list.record(b"b"), Some(0));
    }
}
