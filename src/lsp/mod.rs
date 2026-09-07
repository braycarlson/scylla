pub mod tokens;

use crate::bounded::{Arena, BoundedVec, Bytes, Span, count_of};
use crate::diagnostic::Severity;
use crate::json::{Cursor, Kind, Pen};
use crate::lines::{Encoding, Position, Range};
use crate::scan::is_char_boundary;
use crate::uri::path_write;

#[derive(Clone, Copy, Debug)]
pub struct Change<'json> {
    pub range: Option<Range>,
    pub text: Cursor<'json>,
}

#[derive(Debug)]
pub struct Roots {
    arena: Arena,
    spans: BoundedVec<Span>,
}

impl Roots {
    pub fn at(&self, index: u32) -> &[u8] {
        assert!(index < self.count());

        self.arena.bytes_of(self.spans[index as usize])
    }

    pub fn clear(&mut self) {
        self.spans.clear();
        self.arena.reset();

        assert_eq!(self.count(), 0);
    }

    pub fn count(&self) -> u32 {
        self.spans.count()
    }

    pub fn deepest(&self, path: &[u8]) -> Option<u32> {
        let mut found = None;
        let mut length = 0_usize;

        for index in 0..self.count() {
            let root = self.at(index);

            if root.len() < length || !holds(root, path) {
                continue;
            }

            found = Some(index);
            length = root.len();
        }

        found
    }

    pub fn record(&mut self, root: &[u8]) -> bool {
        let held = trimmed(root);

        if held.is_empty() {
            return false;
        }

        for index in 0..self.count() {
            if self.at(index) == held {
                return true;
            }
        }

        if self.spans.is_full() {
            return false;
        }

        let Some(span) = self.arena.intern(held) else {
            return false;
        };

        self.spans.push_assert(span);

        assert_eq!(self.at(self.count() - 1), held);

        true
    }

    pub fn reserve(root_count_max: u32, path_bytes_max: u32) -> Self {
        assert!(root_count_max > 0);
        assert!(path_bytes_max > 0);
        assert!(!crate::allocation::is_frozen());

        Self {
            arena: Arena::reserve(root_count_max * path_bytes_max),
            spans: BoundedVec::reserve(root_count_max),
        }
    }
}

pub fn content_changes<'json>(params: Cursor<'json>, mut visit: impl FnMut(Change<'json>)) -> bool {
    let Some(changes) = params.member(b"contentChanges") else {
        return params.kind() == Some(Kind::Object);
    };

    if changes.kind() != Some(Kind::Array) {
        return false;
    }

    for held in changes.elements() {
        let Some(change) = change_read(held) else {
            return false;
        };

        visit(change);
    }

    true
}

pub fn encoding_negotiate(params: Cursor<'_>) -> Encoding {
    let offered = params
        .member(b"capabilities")
        .and_then(|capabilities| capabilities.member(b"general"))
        .and_then(|general| general.member(b"positionEncodings"));

    let Some(list) = offered else {
        return Encoding::default();
    };

    if list.kind() != Some(Kind::Array) {
        return Encoding::default();
    }

    list.elements()
        .filter(|name| name.kind() == Some(Kind::String))
        .filter_map(Cursor::raw)
        .filter_map(Encoding::of)
        .max()
        .unwrap_or_default()
}

pub fn kind_covers(requested: Cursor<'_>, kind: &[u8]) -> bool {
    assert!(!kind.is_empty());

    let mut prefix = kind;

    while !prefix.is_empty() {
        if requested.text_is(prefix) {
            return true;
        }

        match prefix.iter().rposition(|byte| *byte == b'.') {
            Some(index) => prefix = &prefix[..index],
            None => return false,
        }
    }

    false
}

pub fn number_of(root: Cursor<'_>, key: &[u8]) -> u32 {
    root.member(key)
        .and_then(Cursor::number)
        .and_then(|held| u32::try_from(held).ok())
        .unwrap_or(0)
}

pub fn position_of(params: Cursor<'_>) -> Option<Position> {
    position_read(params.member(b"position")?)
}

pub fn position_read(held: Cursor<'_>) -> Option<Position> {
    let character = held.member(b"character")?.number()?;
    let line = held.member(b"line")?.number()?;

    Some(Position {
        character: u32::try_from(character).ok()?,
        line: u32::try_from(line).ok()?,
    })
}

pub fn position_write<W>(pen: &mut Pen<'_, W>, position: Position)
where
    W: Bytes,
{
    pen.object_open();
    pen.key(b"line");
    pen.number(i64::from(position.line));
    pen.key(b"character");
    pen.number(i64::from(position.character));
    pen.object_close();
}

pub fn range_read(held: Cursor<'_>) -> Option<Range> {
    let start = position_read(held.member(b"start")?)?;
    let end = position_read(held.member(b"end")?)?;

    Some(Range { end, start })
}

pub fn range_write<W>(pen: &mut Pen<'_, W>, range: Range)
where
    W: Bytes,
{
    pen.object_open();
    pen.key(b"start");

    position_write(pen, range.start);

    pen.key(b"end");

    position_write(pen, range.end);

    pen.object_close();
}

pub fn replacement_span(before: &[u8], after: &[u8]) -> Option<(Span, Span)> {
    if before == after {
        return None;
    }

    let shortest = before.len().min(after.len());
    let mut head = 0_usize;

    while head < shortest && before[head] == after[head] {
        head += 1;
    }

    while head > 0
        && !(is_char_boundary(before, count_of(head)) && is_char_boundary(after, count_of(head)))
    {
        head -= 1;
    }

    let mut tail = 0_usize;

    while tail < shortest - head && before[before.len() - tail - 1] == after[after.len() - tail - 1]
    {
        tail += 1;
    }

    let mut stop = before.len() - tail;
    let mut cut = after.len() - tail;

    while stop < before.len()
        && !(is_char_boundary(before, count_of(stop)) && is_char_boundary(after, count_of(cut)))
    {
        stop += 1;
        cut += 1;
    }

    assert!(head <= stop);
    assert!(head <= cut);

    Some((
        Span::between(count_of(head), count_of(stop)),
        Span::between(count_of(head), count_of(cut)),
    ))
}

pub fn roots_read(params: Cursor<'_>, path: &mut BoundedVec<u8>, mut visit: impl FnMut(&[u8])) {
    let mut named = false;

    if let Some(folders) = params.member(b"workspaceFolders")
        && folders.kind() == Some(Kind::Array)
    {
        for folder in folders.elements() {
            let Some(uri) = folder.member(b"uri").and_then(string_raw) else {
                continue;
            };

            if path_write(uri, path) {
                named = true;

                visit(path);
            }
        }
    }

    if named {
        return;
    }

    if let Some(uri) = params.member(b"rootUri").and_then(string_raw)
        && path_write(uri, path)
    {
        visit(path);

        return;
    }

    if let Some(held) = params.member(b"rootPath")
        && held.kind() == Some(Kind::String)
    {
        path.clear();

        if held.text(path) {
            visit(path);
        }
    }
}

pub const fn severity_code(severity: Severity) -> i64 {
    severity.lsp_code()
}

pub fn text_document_integer(params: Cursor<'_>, key: &[u8]) -> Option<i64> {
    params.member(b"textDocument")?.member(key)?.number()
}

pub fn text_document_string<'json>(params: Cursor<'json>, key: &[u8]) -> Option<Cursor<'json>> {
    let held = params.member(b"textDocument")?.member(key)?;

    (held.kind() == Some(Kind::String)).then_some(held)
}

pub fn uri_of(params: Cursor<'_>) -> Option<&[u8]> {
    text_document_string(params, b"uri").and_then(Cursor::raw)
}

fn change_read(held: Cursor<'_>) -> Option<Change<'_>> {
    if held.kind() != Some(Kind::Object) {
        return None;
    }

    let text = held.member(b"text")?;

    if text.kind() != Some(Kind::String) {
        return None;
    }

    let range = match held.member(b"range") {
        Some(inner) => Some(range_read(inner)?),
        None => None,
    };

    Some(Change { range, text })
}

fn holds(root: &[u8], path: &[u8]) -> bool {
    if !path.starts_with(root) {
        return false;
    }

    path.len() == root.len() || root.ends_with(b"/") || path[root.len()] == b'/'
}

fn string_raw(held: Cursor<'_>) -> Option<&[u8]> {
    if held.kind() != Some(Kind::String) {
        return None;
    }

    held.raw()
}

fn trimmed(root: &[u8]) -> &[u8] {
    if root.len() > 1 && root.ends_with(b"/") {
        return &root[..root.len() - 1];
    }

    root
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::allocation;
    use crate::bounded::Buffer;
    use crate::json::{DEPTH_MAX, Document, Outcome, Writer};

    const DID_CHANGE: &[u8] = concat!(
        r#"{"textDocument":{"uri":"file:///a.rs","version":3},"#,
        r#""contentChanges":[{"text":"fn main() {}"}]}"#,
    )
    .as_bytes();

    const DID_OPEN: &[u8] = concat!(
        r#"{"textDocument":{"uri":"file:///a.rs","languageId":"rust","#,
        r#""version":1,"text":"fn main() {}"}}"#,
    )
    .as_bytes();

    const HOVER: &[u8] =
        br#"{"textDocument":{"uri":"file:///a.rs"},"position":{"line":4,"character":11}}"#;

    const INCREMENTAL: &[u8] = concat!(
        r#"{"textDocument":{"uri":"file:///a.rs","version":3},"contentChanges":[{"range":"#,
        r#"{"start":{"line":0,"character":0},"end":{"line":0,"character":1}},"text":"x"}]}"#,
    )
    .as_bytes();

    const INITIALIZE: &[u8] = concat!(
        r#"{"rootUri":"file:///root","rootPath":"/root","workspaceFolders":[{"uri":"#,
        r#""file:///one%20two"},{"name":"x"},{"uri":"file:///three"}],"capabilities":"#,
        r#"{"general":{"positionEncodings":["utf-16",7,"utf-8"]}}}"#,
    )
    .as_bytes();

    fn root<'held>(document: &'held mut Document, message: &'held [u8]) -> Cursor<'held> {
        assert_eq!(document.parse(message), Outcome::Complete);

        document.root(message).expect("the params parse")
    }

    fn at(line: u32, character: u32) -> Position {
        Position { character, line }
    }

    #[test]
    fn an_open_carries_its_uri_and_text() {
        let mut document = Document::reserve(32);

        allocation::frozen(|| {
            let params = root(&mut document, DID_OPEN);
            let uri = text_document_string(params, b"uri").expect("the uri is present");
            let text = text_document_string(params, b"text").expect("the text is present");

            assert!(uri.text_is(b"file:///a.rs"));
            assert!(text.text_is(b"fn main() {}"));
            assert_eq!(uri_of(params), Some(b"file:///a.rs".as_slice()));
            assert_eq!(text_document_integer(params, b"version"), Some(1));
            assert_eq!(number_of(params.member(b"textDocument").expect("present"), b"version"), 1);
            assert_eq!(number_of(params, b"missing"), 0);
        });
    }

    #[test]
    fn a_change_carries_its_text_and_its_range() {
        let mut document = Document::reserve(64);

        allocation::frozen(|| {
            let full = root(&mut document, DID_CHANGE);
            let mut seen = 0;

            assert!(content_changes(full, |change| {
                assert!(change.range.is_none());
                assert!(change.text.text_is(b"fn main() {}"));

                seen += 1;
            }));

            assert_eq!(seen, 1);

            let incremental = root(&mut document, INCREMENTAL);

            assert!(content_changes(incremental, |change| {
                assert_eq!(
                    change.range,
                    Some(Range {
                        end: at(0, 1),
                        start: at(0, 0),
                    })
                );

                seen += 1;
            }));

            assert_eq!(seen, 2);
        });
    }

    #[test]
    fn a_malformed_change_list_is_refused() {
        let mut document = Document::reserve(64);

        allocation::frozen(|| {
            let scalar = root(&mut document, br#"{"contentChanges":7}"#);

            assert!(!content_changes(scalar, |_change| {}));

            let missing_text = root(&mut document, br#"{"contentChanges":[{"range":{}}]}"#);

            assert!(!content_changes(missing_text, |_change| {}));

            let bad_range = root(
                &mut document,
                br#"{"contentChanges":[{"range":{"start":{}},"text":"x"}]}"#,
            );

            assert!(!content_changes(bad_range, |_change| {}));

            let absent = root(&mut document, br#"{"textDocument":{}}"#);

            assert!(content_changes(absent, |_change| unreachable!()));

            let array = root(&mut document, b"[]");

            assert!(!content_changes(array, |_change| unreachable!()));
        });
    }

    #[test]
    fn a_hover_carries_its_position() {
        let mut document = Document::reserve(32);

        allocation::frozen(|| {
            let params = root(&mut document, HOVER);

            assert_eq!(position_of(params), Some(at(4, 11)));
            assert!(text_document_string(params, b"text").is_none());
            assert!(text_document_integer(params, b"version").is_none());

            let negative = root(&mut document, br#"{"position":{"line":-1,"character":0}}"#);

            assert!(position_of(negative).is_none());
        });
    }

    #[test]
    fn a_range_writes_the_way_it_is_read() {
        let mut document = Document::reserve(32);
        let mut writer = Writer::reserve(DEPTH_MAX);
        let mut out = Buffer::reserve(256);

        allocation::frozen(|| {
            let mut pen = Pen::bound(&mut writer, &mut out);

            range_write(
                &mut pen,
                Range {
                    end: at(2, 3),
                    start: at(1, 0),
                },
            );

            assert!(pen.finish());
        });

        assert_eq!(
            core::str::from_utf8(out.as_bytes()).expect("utf-8"),
            r#"{"start":{"line":1,"character":0},"end":{"line":2,"character":3}}"#
        );

        allocation::frozen(|| {
            let held = root(&mut document, out.as_bytes());

            assert_eq!(
                range_read(held),
                Some(Range {
                    end: at(2, 3),
                    start: at(1, 0),
                })
            );

            assert!(range_read(root(&mut document, br#"{"start":{}}"#)).is_none());
        });
    }

    #[test]
    fn the_best_offered_encoding_wins() {
        let mut document = Document::reserve(64);

        allocation::frozen(|| {
            assert_eq!(encoding_negotiate(root(&mut document, INITIALIZE)), Encoding::Utf8);

            let sixteen = root(
                &mut document,
                br#"{"capabilities":{"general":{"positionEncodings":["utf-16","utf-32"]}}}"#,
            );

            assert_eq!(encoding_negotiate(sixteen), Encoding::Utf32);

            let absent = root(&mut document, br#"{"capabilities":{}}"#);

            assert_eq!(encoding_negotiate(absent), Encoding::Utf16);

            let scalar = root(
                &mut document,
                br#"{"capabilities":{"general":{"positionEncodings":"utf-8"}}}"#,
            );

            assert_eq!(encoding_negotiate(scalar), Encoding::Utf16);
        });
    }

    #[test]
    fn workspace_folders_win_over_the_root_uri_and_path() {
        let mut document = Document::reserve(64);
        let mut path = BoundedVec::reserve(64);
        let mut roots = Roots::reserve(4, 64);

        allocation::frozen(|| {
            roots_read(root(&mut document, INITIALIZE), &mut path, |held| {
                assert!(roots.record(held));
            });

            assert_eq!(roots.count(), 2);
            assert_eq!(roots.at(0), b"/one two");
            assert_eq!(roots.at(1), b"/three");

            roots.clear();

            roots_read(
                root(
                    &mut document,
                    br#"{"rootUri":"file:///r/","rootPath":"/p"}"#,
                ),
                &mut path,
                |held| {
                    assert!(roots.record(held));
                },
            );

            assert_eq!(roots.count(), 1);
            assert_eq!(roots.at(0), b"/r");

            roots.clear();

            roots_read(
                root(&mut document, br#"{"rootUri":null,"rootPath":"/p/q"}"#),
                &mut path,
                |held| {
                    assert!(roots.record(held));
                },
            );

            assert_eq!(roots.count(), 1);
            assert_eq!(roots.at(0), b"/p/q");
        });
    }

    #[test]
    fn the_deepest_root_holding_a_path_is_found() {
        let mut roots = Roots::reserve(4, 32);

        allocation::frozen(|| {
            assert!(roots.record(b"/home"));
            assert!(roots.record(b"/home/one/"));
            assert!(roots.record(b"/home/one"));
            assert!(!roots.record(b""));
            assert_eq!(roots.count(), 2);
            assert_eq!(roots.deepest(b"/home/one/a.rs"), Some(1));
            assert_eq!(roots.deepest(b"/home/one"), Some(1));
            assert_eq!(roots.deepest(b"/home/oneself/a.rs"), Some(0));
            assert_eq!(roots.deepest(b"/homeless"), None);
            assert_eq!(roots.deepest(b"/tmp/a.rs"), None);
        });
    }

    #[test]
    fn a_full_root_table_refuses_the_next_root() {
        let mut roots = Roots::reserve(2, 8);

        allocation::frozen(|| {
            assert!(roots.record(b"/a"));
            assert!(roots.record(b"/b"));
            assert!(!roots.record(b"/c"));
            assert!(roots.record(b"/a"));
            assert_eq!(roots.count(), 2);
        });

        let mut narrow = Roots::reserve(4, 4);

        allocation::frozen(|| {
            assert!(narrow.record(b"/aaaaaaaaaaa"));
            assert!(!narrow.record(b"/bbbbbbbbbbb"));
            assert_eq!(narrow.count(), 1);
        });
    }

    #[test]
    fn a_kind_covers_its_dotted_prefixes() {
        let mut document = Document::reserve(16);

        allocation::frozen(|| {
            let quickfix = root(&mut document, br#""quickfix""#);

            assert!(kind_covers(quickfix, b"quickfix"));
            assert!(!kind_covers(quickfix, b"source.fixAll"));

            let source = root(&mut document, br#""source""#);

            assert!(kind_covers(source, b"source.fixAll.tool"));

            let fix_all = root(&mut document, br#""source.fixAll""#);

            assert!(kind_covers(fix_all, b"source.fixAll.tool"));
            assert!(!kind_covers(fix_all, b"source.organizeImports"));
        });
    }

    #[test]
    fn a_replacement_is_the_smallest_span_on_character_boundaries() {
        allocation::frozen(|| {
            assert_eq!(replacement_span(b"abc", b"abc"), None);

            assert_eq!(
                replacement_span(b"abcdef", b"abXYef"),
                Some((Span::between(2, 4), Span::between(2, 4)))
            );

            assert_eq!(
                replacement_span(b"abc", b"abcde"),
                Some((Span::between(3, 3), Span::between(3, 5)))
            );

            assert_eq!(
                replacement_span(b"abcde", b"abc"),
                Some((Span::between(3, 5), Span::between(3, 3)))
            );

            let before = "a\u{00e9}b".as_bytes();
            let after = "a\u{00e8}b".as_bytes();

            assert_eq!(
                replacement_span(before, after),
                Some((Span::between(1, 3), Span::between(1, 3)))
            );
        });
    }

    #[test]
    fn each_severity_has_its_protocol_code() {
        assert_eq!(severity_code(Severity::Error), 1);
        assert_eq!(severity_code(Severity::Warning), 2);
        assert_eq!(severity_code(Severity::Information), 3);
        assert_eq!(severity_code(Severity::Hint), 4);
    }
}
