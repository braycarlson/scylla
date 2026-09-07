use std::io::{Read, Result};

use crate::bounded::{
    Arena,
    BoundedString,
    BoundedVec,
    Buffer,
    Bytes as _,
    Handle,
    Pool,
    Reset,
    Span,
    Table,
    count_of,
    hash_of,
};
use crate::json::Cursor;
use crate::lines::{Encoding, Index, Position, Range};
use crate::scan::is_char_boundary;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Open {
    Full,
    Invalid,
    Opened(Handle),
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Rejection {
    Lines,
    Size,
    Utf8,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Update {
    Accepted,
    Rejected(Rejection),
}

#[derive(Debug)]
pub struct Documents {
    arena: Arena,
    encoding: Encoding,
    handles: BoundedVec<Option<Handle>>,
    scratch: BoundedString,
    slots: Pool<TextDocument>,
    table: Table<Handle>,
}

#[derive(Debug)]
pub struct TextDocument {
    encoding: Encoding,
    lines: Index,
    scratch: Buffer,
    slot: u32,
    text: Buffer,
    uri: BoundedString,
    version: i64,
}

impl Reset for TextDocument {
    fn reset(&mut self) {
        self.text.clear();
        self.uri.clear();
        self.version = 0;
        self.lines.clear();

        assert!(self.uri.is_empty());
        assert_eq!(self.line_count(), 1);
    }
}

impl Documents {
    pub fn close(&mut self, handle: Handle) {
        let index = self.index_of(handle) as usize;

        self.handles[index] = None;
        self.slots.release(handle);
        self.table.clear();
        self.arena.reset();

        for (held, document) in self.slots.iter() {
            let uri = document.uri();
            let key = self
                .arena
                .intern(uri)
                .expect("every live uri fits the arena");

            let inserted = self.table.insert(hash_of(uri), key, held, |span| {
                self.arena.bytes_of(span) == uri
            });

            assert!(inserted);
        }

        assert!(!self.slots.contains(handle));
        assert_eq!(self.table.count(), self.slots.count());
    }

    pub fn count(&self) -> u32 {
        let count = self.slots.count();

        assert!(count <= self.slots.capacity());

        count
    }

    pub const fn encoding(&self) -> Encoding {
        self.encoding
    }

    pub const fn encoding_set(&mut self, encoding: Encoding) {
        self.encoding = encoding;
    }

    pub fn find(&self, uri: &[u8]) -> Option<Handle> {
        found(&self.arena, &self.table, uri)
    }

    pub fn find_text(&mut self, uri: Cursor<'_>) -> Option<Handle> {
        if !self.scratch_set(uri) {
            return None;
        }

        found(&self.arena, &self.table, self.scratch.as_bytes())
    }

    pub fn get(&self, handle: Handle) -> &TextDocument {
        self.slots.get(handle)
    }

    pub fn get_mut(&mut self, handle: Handle) -> &mut TextDocument {
        self.slots.get_mut(handle)
    }

    pub fn handle_at(&self, index: u32) -> Option<Handle> {
        assert!(index < self.slots.capacity());

        self.handles[index as usize]
    }

    pub fn handles(&self) -> impl Iterator<Item = Handle> + '_ {
        self.slots.iter().map(|(handle, _)| handle)
    }

    pub fn index_of(&self, handle: Handle) -> u32 {
        let index = self.slots.get(handle).slot;

        assert!(index < self.slots.capacity());
        assert_eq!(self.handles[index as usize], Some(handle));

        index
    }

    pub fn open(&mut self, uri: &[u8]) -> Open {
        opened(
            &mut self.arena,
            self.encoding,
            &mut self.handles,
            &mut self.slots,
            &mut self.table,
            uri,
        )
    }

    pub fn open_text(&mut self, uri: Cursor<'_>) -> Open {
        if !self.scratch_set(uri) {
            return Open::Invalid;
        }

        opened(
            &mut self.arena,
            self.encoding,
            &mut self.handles,
            &mut self.slots,
            &mut self.table,
            self.scratch.as_bytes(),
        )
    }

    pub fn reserve(
        document_count_max: u32,
        line_count_max: u32,
        text_bytes_max: u32,
        uri_bytes_max: u32,
    ) -> Self {
        assert!(document_count_max > 0);
        assert!(uri_bytes_max > 0);
        assert!(!crate::allocation::is_frozen());

        let mut handles = BoundedVec::reserve(document_count_max);

        for _ in 0..document_count_max {
            handles.push_assert(None);
        }

        assert_eq!(handles.count(), document_count_max);

        Self {
            arena: Arena::reserve(document_count_max * uri_bytes_max),
            encoding: Encoding::default(),
            handles,
            scratch: BoundedString::reserve(uri_bytes_max),
            slots: Pool::reserve(document_count_max, |slot| {
                let mut document =
                    TextDocument::reserve(line_count_max, text_bytes_max, uri_bytes_max);

                document.slot = slot;

                document
            }),
            table: Table::reserve(document_count_max),
        }
    }

    fn scratch_set(&mut self, uri: Cursor<'_>) -> bool {
        self.scratch.clear();

        if !uri.text(&mut self.scratch) {
            self.scratch.clear();

            return false;
        }

        !self.scratch.is_empty()
    }
}

impl TextDocument {
    pub fn apply(&mut self, range: Option<Range>, text: &[u8]) -> Update {
        let Some(asked) = range else {
            return self.text_replace(text);
        };

        let span = self.span_of(asked);

        self.splice(span.offset, span.end(), text)
    }

    pub const fn encoding(&self) -> Encoding {
        self.encoding
    }

    pub const fn encoding_set(&mut self, encoding: Encoding) {
        self.encoding = encoding;
    }

    pub fn line(&self, line: u32) -> &[u8] {
        if line >= self.line_count() {
            return &[];
        }

        let start = self.lines.line_start(line);
        let end = self.lines.line_end(line, self.text.count());

        &self.text.as_bytes()[start as usize..end as usize]
    }

    pub fn line_count(&self) -> u32 {
        let count = self.lines.count();

        assert!(count > 0);

        count
    }

    pub fn line_end_offset(&self, line: u32) -> u32 {
        if line >= self.line_count() {
            return self.text.count();
        }

        self.lines.line_end(line, self.text.count())
    }

    pub fn line_start_offset(&self, line: u32) -> u32 {
        self.lines.line_start(line)
    }

    pub const fn lines(&self) -> &Index {
        &self.lines
    }

    pub fn offset_in(&self, position: Position, encoding: Encoding) -> Option<u32> {
        self.lines.offset_of(self.text_str(), position, encoding)
    }

    pub fn offset_of(&self, position: Position) -> Option<u32> {
        self.offset_in(position, self.encoding)
    }

    pub fn position_in(&self, offset: u32, encoding: Encoding) -> Position {
        assert!(offset <= self.text_count());

        self.lines.position_of(self.text_str(), offset, encoding)
    }

    pub fn position_of(&self, offset: u32) -> Position {
        self.position_in(offset, self.encoding)
    }

    pub fn range_of(&self, span: Span) -> Range {
        self.lines
            .range_of(self.text.as_bytes(), span, self.encoding)
    }

    pub fn reserve(line_count_max: u32, text_bytes_max: u32, uri_bytes_max: u32) -> Self {
        assert!(line_count_max > 0);
        assert!(text_bytes_max > 0);
        assert!(uri_bytes_max > 0);
        assert!(!crate::allocation::is_frozen());

        let document = Self {
            encoding: Encoding::default(),
            lines: Index::reserve(line_count_max),
            scratch: Buffer::reserve(text_bytes_max),
            slot: 0,
            text: Buffer::reserve(text_bytes_max),
            uri: BoundedString::reserve(uri_bytes_max),
            version: 0,
        };

        assert_eq!(document.line_count(), 1);

        document
    }

    pub fn span_of(&self, range: Range) -> Span {
        self.lines
            .span_of(self.text.as_bytes(), range, self.encoding)
    }

    pub fn splice(&mut self, start: u32, end: u32, inserted: &[u8]) -> Update {
        spliced(&mut self.lines, &mut self.text, start, end, inserted)
    }

    pub fn splice_text(&mut self, start: u32, end: u32, text: Cursor<'_>) -> Update {
        self.scratch.clear();

        if let Some(reason) = decoded(text, &mut self.scratch) {
            return Update::Rejected(reason);
        }

        spliced(
            &mut self.lines,
            &mut self.text,
            start,
            end,
            self.scratch.as_bytes(),
        )
    }

    pub fn text(&self) -> &[u8] {
        self.text.as_bytes()
    }

    pub fn text_count(&self) -> u32 {
        self.text.count()
    }

    pub fn text_read(&mut self, source: &mut impl Read) -> Result<Update> {
        self.text.clear();

        let complete = match self.text.read_from(source) {
            Ok(complete) => complete,
            Err(error) => {
                self.clear();

                return Err(error);
            }
        };

        if !complete {
            self.clear();

            return Ok(Update::Rejected(Rejection::Size));
        }

        if core::str::from_utf8(self.text.as_bytes()).is_err() {
            self.clear();

            return Ok(Update::Rejected(Rejection::Utf8));
        }

        Ok(self.index_rebuild())
    }

    pub fn text_replace(&mut self, bytes: &[u8]) -> Update {
        self.text.clear();

        if core::str::from_utf8(bytes).is_err() {
            self.clear();

            return Update::Rejected(Rejection::Utf8);
        }

        if !self.text.push_bytes(bytes) {
            self.clear();

            return Update::Rejected(Rejection::Size);
        }

        self.index_rebuild()
    }

    pub fn text_set(&mut self, text: Cursor<'_>) -> Update {
        self.text.clear();

        if let Some(reason) = decoded(text, &mut self.text) {
            self.clear();

            return Update::Rejected(reason);
        }

        self.index_rebuild()
    }

    pub fn uri(&self) -> &[u8] {
        self.uri.as_bytes()
    }

    pub fn uri_set(&mut self, uri: &[u8]) -> bool {
        self.uri.clear();

        self.uri.push_bytes(uri)
    }

    pub const fn version(&self) -> i64 {
        self.version
    }

    pub const fn version_set(&mut self, version: i64) {
        self.version = version;
    }

    fn clear(&mut self) {
        self.text.clear();
        self.lines.clear();

        assert_eq!(self.text_count(), 0);
        assert_eq!(self.line_count(), 1);
    }

    fn index_rebuild(&mut self) -> Update {
        if !self.lines.build(self.text.as_bytes()) {
            self.clear();

            return Update::Rejected(Rejection::Lines);
        }

        self.lines.validate(self.text.count());

        Update::Accepted
    }

    fn text_str(&self) -> &str {
        core::str::from_utf8(self.text.as_bytes()).expect("a document holds valid UTF-8")
    }
}

fn decoded(text: Cursor<'_>, out: &mut Buffer) -> Option<Rejection> {
    let room = out.capacity() - out.count();
    let raw = text.raw().unwrap_or_default();

    if !text.text(out) {
        if raw.len() > room as usize {
            return Some(Rejection::Size);
        }

        return Some(Rejection::Utf8);
    }

    if core::str::from_utf8(out.as_bytes()).is_err() {
        return Some(Rejection::Utf8);
    }

    None
}

fn found(arena: &Arena, table: &Table<Handle>, uri: &[u8]) -> Option<Handle> {
    if uri.is_empty() {
        return None;
    }

    table.get(hash_of(uri), |span| arena.bytes_of(span) == uri)
}

fn opened(
    arena: &mut Arena,
    encoding: Encoding,
    handles: &mut BoundedVec<Option<Handle>>,
    slots: &mut Pool<TextDocument>,
    table: &mut Table<Handle>,
    uri: &[u8],
) -> Open {
    if uri.is_empty() {
        return Open::Invalid;
    }

    if let Some(handle) = found(arena, table, uri) {
        return Open::Opened(handle);
    }

    let Some(handle) = slots.acquire() else {
        return Open::Full;
    };

    let document = slots.get_mut(handle);

    if !document.uri_set(uri) {
        slots.release(handle);

        return Open::Invalid;
    }

    document.encoding_set(encoding);

    let slot = document.slot as usize;

    assert!(handles[slot].is_none());

    handles[slot] = Some(handle);

    let key = arena.intern(uri).expect("every live uri fits the arena");
    let inserted = table.insert(hash_of(uri), key, handle, |span| {
        arena.bytes_of(span) == uri
    });

    assert!(inserted);
    assert!(slots.contains(handle));

    Open::Opened(handle)
}

fn spliced(lines: &mut Index, text: &mut Buffer, start: u32, end: u32, inserted: &[u8]) -> Update {
    assert!(start <= end);

    if end > text.count() {
        return Update::Rejected(Rejection::Size);
    }

    if !is_char_boundary(text.as_bytes(), start)
        || !is_char_boundary(text.as_bytes(), end)
        || core::str::from_utf8(inserted).is_err()
    {
        return Update::Rejected(Rejection::Utf8);
    }

    if text.count() - (end - start) + count_of(inserted.len()) > text.capacity() {
        return Update::Rejected(Rejection::Size);
    }

    let Some(plan) = lines.splice_plan(start, end, inserted) else {
        text.clear();
        lines.clear();

        return Update::Rejected(Rejection::Lines);
    };

    let written = text.splice(start, end, inserted);

    assert!(written);

    lines.splice_apply(start, end, inserted, &plan);
    lines.validate(text.count());

    Update::Accepted
}

#[cfg(test)]
mod tests {
    use std::io::{Error, ErrorKind};

    use super::*;
    use crate::allocation;
    use crate::bounded::Random;
    use crate::json::Document as Parsed;

    const LINE_COUNT_MAX: u32 = 8;
    const TEXT_BYTES_MAX: u32 = 1 << 12;
    const URI_BYTES_MAX: u32 = 64;

    struct Failing<'source> {
        bytes: &'source [u8],
        limit: usize,
        offset: usize,
    }

    impl Read for Failing<'_> {
        fn read(&mut self, target: &mut [u8]) -> Result<usize> {
            if self.offset == self.limit {
                return Err(Error::from(ErrorKind::BrokenPipe));
            }

            let width = (self.limit - self.offset).min(target.len());

            target[..width].copy_from_slice(&self.bytes[self.offset..self.offset + width]);
            self.offset += width;

            Ok(width)
        }
    }

    fn document() -> TextDocument {
        TextDocument::reserve(LINE_COUNT_MAX, TEXT_BYTES_MAX, URI_BYTES_MAX)
    }

    fn documents() -> Documents {
        Documents::reserve(2, LINE_COUNT_MAX, TEXT_BYTES_MAX, URI_BYTES_MAX)
    }

    fn at(line: u32, character: u32) -> Position {
        Position { character, line }
    }

    fn parsed<'held>(reader: &'held mut Parsed, source: &'held [u8]) -> Cursor<'held> {
        reader.parse(source);

        reader.root(source).expect("the input parses")
    }

    #[test]
    fn a_document_indexes_its_lines_and_maps_positions() {
        let mut held = document();
        let mut reader = Parsed::reserve(4);

        allocation::frozen(|| {
            let update = held.text_set(parsed(&mut reader, b"\"one\\ntwo\\nthree\""));

            assert_eq!(update, Update::Accepted);
            assert_eq!(held.line_count(), 3);
            assert_eq!(held.text_count(), 13);
            assert_eq!(held.line(1), b"two\n");
            assert_eq!(held.line(2), b"three");
            assert_eq!(held.line(9), b"");
            assert_eq!(held.line_start_offset(2), 8);
            assert_eq!(held.line_end_offset(1), 8);
            assert_eq!(held.line_end_offset(9), 13);
            assert_eq!(held.position_of(9), at(2, 1));
            assert_eq!(held.offset_of(at(2, 1)), Some(9));
            assert_eq!(held.offset_of(at(9, 0)), None);
            assert_eq!(held.range_of(Span::between(4, 7)).end, at(1, 3));
            assert_eq!(held.range_of(Span::between(4, 99)).end, at(2, 5));
            assert_eq!(held.span_of(held.range_of(Span::between(4, 7))), Span::between(4, 7));
            assert_eq!(held.lines().count(), 3);
        });
    }

    #[test]
    fn a_position_counts_units_in_the_negotiated_encoding() {
        let mut held = document();
        let mut reader = Parsed::reserve(4);
        let source = "\"let value = \u{1F600}x;\"".as_bytes();

        allocation::frozen(|| {
            assert_eq!(held.text_set(parsed(&mut reader, source)), Update::Accepted);

            let offset = held.text_count() - 2;

            assert_eq!(held.position_of(offset), at(0, 14));
            assert_eq!(held.offset_of(at(0, 14)), Some(offset));

            held.encoding_set(Encoding::Utf8);

            assert_eq!(held.encoding(), Encoding::Utf8);
            assert_eq!(held.position_of(offset), at(0, 16));
            assert_eq!(held.offset_in(at(0, 14), Encoding::Utf16), Some(offset));
            assert_eq!(held.position_in(offset, Encoding::Utf32), at(0, 13));
        });
    }

    #[test]
    fn a_splice_replaces_the_bytes_it_names() {
        let mut held = document();
        let mut reader = Parsed::reserve(4);

        allocation::frozen(|| {
            assert_eq!(held.text_replace(b"one\ntwo\n"), Update::Accepted);

            let range = Range {
                end: at(1, 3),
                start: at(1, 0),
            };

            assert_eq!(held.apply(Some(range), b"six"), Update::Accepted);
            assert_eq!(held.text(), b"one\nsix\n");
            assert_eq!(held.splice_text(0, 3, parsed(&mut reader, b"\"a\\nb\"")), Update::Accepted);
            assert_eq!(held.text(), b"a\nb\nsix\n");
            assert_eq!(held.line_count(), 4);
            assert_eq!(held.apply(None, b"three"), Update::Accepted);
            assert_eq!(held.text(), b"three");
            assert_eq!(held.line_count(), 1);
        });
    }

    #[test]
    fn a_splice_the_document_cannot_take_is_rejected() {
        let mut held = document();
        let mut reader = Parsed::reserve(4);
        let wide = "\"\u{1F600}\"".as_bytes();

        allocation::frozen(|| {
            assert_eq!(held.text_set(parsed(&mut reader, wide)), Update::Accepted);
            assert_eq!(held.splice(1, 2, b"x"), Update::Rejected(Rejection::Utf8));
            assert_eq!(held.splice(0, 4, b"\xff"), Update::Rejected(Rejection::Utf8));
            assert_eq!(held.splice(0, 9, b"x"), Update::Rejected(Rejection::Size));
            assert_eq!(held.text_count(), 4);

            let lines = held.splice(0, 0, b"\n\n\n\n\n\n\n\n\n");

            assert_eq!(lines, Update::Rejected(Rejection::Lines));
            assert_eq!(held.text_count(), 0);
            assert_eq!(held.line_count(), 1);
        });
    }

    #[test]
    fn a_text_past_the_limits_is_rejected_whole() {
        let large = format!("\"{}\"", "x".repeat(8_192));
        let mut held = document();
        let mut reader = Parsed::reserve(4);

        allocation::frozen(|| {
            let size = held.text_set(parsed(&mut reader, large.as_bytes()));

            assert_eq!(size, Update::Rejected(Rejection::Size));
            assert_eq!(held.text_count(), 0);

            let lines = held.text_set(parsed(&mut reader, b"\"\\n\\n\\n\\n\\n\\n\\n\\n\\n\""));

            assert_eq!(lines, Update::Rejected(Rejection::Lines));
            assert_eq!(held.line_count(), 1);
            assert_eq!(held.text_replace(b"\xff"), Update::Rejected(Rejection::Utf8));

            let escaped = held.text_set(parsed(&mut reader, b"\"\\udc00\""));

            assert_eq!(escaped, Update::Rejected(Rejection::Utf8));
            assert_eq!(held.text_count(), 0);
        });
    }

    #[test]
    fn a_read_that_fails_partway_leaves_no_half_read_document() {
        let mut held = document();

        let mut source = Failing {
            bytes: b"alpha\nbeta\ngamma\n",
            limit: 8,
            offset: 0,
        };

        allocation::frozen(|| {
            assert_eq!(held.text_replace(b"one\ntwo\n"), Update::Accepted);

            let error = held
                .text_read(&mut source)
                .expect_err("the failure reaches the caller");

            assert_eq!(error.kind(), ErrorKind::BrokenPipe);
            assert_eq!(held.text(), b"");
            assert_eq!(held.line_count(), 1);

            let mut whole = b"alpha\nbeta\n".as_slice();

            assert_eq!(held.text_read(&mut whole).expect("it reads"), Update::Accepted);
            assert_eq!(held.text(), b"alpha\nbeta\n");

            let mut invalid = b"\xff\xfe".as_slice();

            assert_eq!(
                held.text_read(&mut invalid).expect("it reads"),
                Update::Rejected(Rejection::Utf8)
            );
        });
    }

    #[test]
    fn a_pool_finds_opened_documents_by_uri_and_reuses_closed_slots() {
        let mut held = documents();

        allocation::frozen(|| {
            let Open::Opened(first) = held.open(b"file:///a.rs") else {
                unreachable!()
            };

            assert_eq!(held.open(b"file:///a.rs"), Open::Opened(first));
            assert!(matches!(held.open(b"file:///b.rs"), Open::Opened(_)));
            assert_eq!(held.count(), 2);
            assert_eq!(held.open(b"file:///c.rs"), Open::Full);
            assert_eq!(held.find(b"file:///a.rs"), Some(first));
            assert_eq!(held.find(b"file:///c.rs"), None);
            assert_eq!(held.get(first).uri(), b"file:///a.rs");

            let second = held
                .find(b"file:///b.rs")
                .expect("the second document is open");
            let index = held.index_of(first);

            assert!(index < 2);
            assert_ne!(index, held.index_of(second));
            assert_eq!(held.handle_at(index), Some(first));
            assert_eq!(held.handle_at(held.index_of(second)), Some(second));

            held.get_mut(first).version_set(4);

            assert_eq!(held.get(first).version(), 4);

            held.close(first);

            assert_eq!(held.count(), 1);
            assert_eq!(held.find(b"file:///a.rs"), None);
            assert_eq!(held.handle_at(index), None);
            assert!(held.find(b"file:///b.rs").is_some());

            let Open::Opened(reused) = held.open(b"file:///c.rs") else {
                unreachable!()
            };

            assert_eq!(held.get(reused).uri(), b"file:///c.rs");
            assert_eq!(held.get(reused).version(), 0);
            assert_eq!(held.find(b"file:///c.rs"), Some(reused));
            assert_eq!(held.index_of(reused), index);
            assert_eq!(held.handle_at(index), Some(reused));
            assert_ne!(reused, first);
            assert_eq!(held.handles().count(), 2);
        });
    }

    #[test]
    fn a_pool_opens_by_json_text_and_hands_its_encoding_down() {
        let mut held = documents();
        let mut reader = Parsed::reserve(4);
        let long = format!("\"file:///{}\"", "x".repeat(URI_BYTES_MAX as usize));

        allocation::frozen(|| {
            held.encoding_set(Encoding::Utf8);

            assert_eq!(held.encoding(), Encoding::Utf8);

            let Open::Opened(handle) = held.open_text(parsed(&mut reader, b"\"file:///a.rs\""))
            else {
                unreachable!()
            };

            assert_eq!(held.get(handle).encoding(), Encoding::Utf8);
            assert_eq!(held.find_text(parsed(&mut reader, b"\"file:///a.rs\"")), Some(handle));
            assert_eq!(held.find_text(parsed(&mut reader, b"\"file:///b.rs\"")), None);
            assert_eq!(held.open_text(parsed(&mut reader, b"\"\"")), Open::Invalid);
            assert_eq!(held.open_text(parsed(&mut reader, b"7")), Open::Invalid);
            assert_eq!(held.open_text(parsed(&mut reader, long.as_bytes())), Open::Invalid);
            assert_eq!(held.open(b""), Open::Invalid);
            assert_eq!(held.count(), 1);
        });
    }

    #[test]
    fn a_random_edit_sequence_matches_a_full_rebuild() {
        let mut held = TextDocument::reserve(256, 1 << 10, URI_BYTES_MAX);
        let mut mirror = TextDocument::reserve(256, 1 << 10, URI_BYTES_MAX);
        let mut random = Random::new(0x2545_F491_4F6C_DD1D);
        let words: [&[u8]; 6] = [b"", b"a", b"\n", b"ab\nc", b"\n\n", "\u{00e9}".as_bytes()];

        allocation::frozen(|| {
            assert_eq!(held.text_replace(b"one\ntwo\nthree\n"), Update::Accepted);

            let mut edits = 0;

            for _ in 0..4_000 {
                let count = held.text_count();
                let start = random.below(count + 1);
                let end = start + random.below(count + 1 - start);
                let word = words[random.below(count_of(words.len())) as usize];

                if held.splice(start, end, word) != Update::Accepted {
                    continue;
                }

                edits += 1;

                assert_eq!(mirror.text_replace(held.text()), Update::Accepted);
                assert_eq!(held.text(), mirror.text());
                assert_eq!(&**held.lines(), &**mirror.lines());
            }

            assert!(edits > 1_000);
        });
    }
}
