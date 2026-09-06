use core::iter::from_fn;
use core::str::from_utf8;

use crate::bounded::{BoundedVec, Bytes, Span, count_of};
use crate::json::{DEPTH_MAX, Kind};

const SURROGATE_HIGH_FIRST: u32 = 0xD800;
const SURROGATE_HIGH_LAST: u32 = 0xDBFF;
const SURROGATE_LOW_FIRST: u32 = 0xDC00;
const SURROGATE_LOW_LAST: u32 = 0xDFFF;
const SURROGATE_OFFSET: u32 = 0x1_0000;
const SURROGATE_SHIFT: u32 = 10;
const ESCAPE_BYTES: usize = 6;
const HEX_DIGITS: usize = 4;
const HEX_RADIX: u32 = 16;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Node {
    pub end: u32,
    pub kind: Kind,
    pub span: Span,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Outcome {
    Complete,
    Invalid(u32),
    TooDeep(u32),
    Truncated(u32),
}

#[derive(Debug)]
pub struct Document {
    frames: BoundedVec<u32>,
    nodes: BoundedVec<Node>,
}

#[derive(Clone, Copy, Debug)]
pub struct Cursor<'json> {
    document: &'json Document,
    index: u32,
    source: &'json [u8],
}

struct Comparison<'expected> {
    expected: &'expected [u8],
    matched: bool,
    offset: usize,
}

impl Document {
    fn advance(&mut self, source: &[u8], offset: &mut u32) -> Outcome {
        for _ in 0..=DEPTH_MAX {
            let Some(open) = self.frames.last().copied() else {
                return Outcome::Complete;
            };

            let Some(node) = self.node_at(open) else {
                return Outcome::Invalid(*offset);
            };

            *offset = skipped_space(source, *offset);

            let separator = byte_at(source, *offset);
            let closer = closer_of(node.kind);

            if separator == Some(b',') {
                *offset = skipped_space(source, offset.saturating_add(1));

                if node.kind == Kind::Object {
                    return self.scan_key(source, offset);
                }

                return Outcome::Complete;
            }

            if separator != Some(closer) {
                return Outcome::Invalid(*offset);
            }

            *offset = offset.saturating_add(1);

            let popped = self.close(*offset);

            if popped != Outcome::Complete {
                return popped;
            }

            if self.frames.count() == 0 {
                return Outcome::Complete;
            }
        }

        Outcome::TooDeep(*offset)
    }

    pub fn clear(&mut self) {
        self.frames.clear();
        self.nodes.clear();

        assert!(self.is_empty());
    }

    fn close(&mut self, offset: u32) -> Outcome {
        let Some(open) = self.frames.pop() else {
            return Outcome::Invalid(offset);
        };

        let end = self.nodes.count();

        let Ok(start) = usize::try_from(open) else {
            return Outcome::Invalid(offset);
        };

        let Some(node) = self.nodes.get_mut(start) else {
            return Outcome::Invalid(offset);
        };

        node.end = end;
        node.span.length = offset.saturating_sub(node.span.offset);

        Outcome::Complete
    }

    pub fn count(&self) -> u32 {
        self.nodes.count()
    }

    pub fn is_empty(&self) -> bool {
        self.nodes.count() == 0
    }

    fn node_at(&self, index: u32) -> Option<Node> {
        let Ok(slot) = usize::try_from(index) else {
            return None;
        };

        self.nodes.get(slot).copied()
    }

    fn open(&mut self, source: &[u8], offset: &mut u32, kind: Kind) -> Outcome {
        let index = self.nodes.count();

        let pushed = self.nodes.push(Node {
            end: index,
            kind,
            span: Span {
                length: 0,
                offset: *offset,
            },
        });

        if !pushed {
            return Outcome::Truncated(*offset);
        }

        if !self.frames.push(index) {
            return Outcome::TooDeep(*offset);
        }

        *offset = skipped_space(source, offset.saturating_add(1));

        if byte_at(source, *offset) != Some(closer_of(kind)) {
            if kind == Kind::Object {
                return self.scan_key(source, offset);
            }

            return Outcome::Complete;
        }

        *offset = offset.saturating_add(1);

        let popped = self.close(*offset);

        if popped != Outcome::Complete {
            return popped;
        }

        self.advance(source, offset)
    }

    pub fn parse(&mut self, source: &[u8]) -> Outcome {
        self.clear();

        let outcome = self.parsed(source);

        if outcome != Outcome::Complete {
            self.clear();
        }

        outcome
    }

    fn parsed(&mut self, source: &[u8]) -> Outcome {
        let mut offset = skipped_space(source, 0);
        let scanned = self.scan(source, &mut offset);

        if scanned != Outcome::Complete {
            return scanned;
        }

        let rest = skipped_space(source, offset);

        if rest < count_of(source.len()) {
            return Outcome::Invalid(rest);
        }

        Outcome::Complete
    }

    pub fn reserve(node_count_max: u32) -> Self {
        assert!(node_count_max > 0);
        assert!(!crate::allocation::is_frozen());

        Self {
            frames: BoundedVec::reserve(DEPTH_MAX),
            nodes: BoundedVec::reserve(node_count_max),
        }
    }

    pub fn root<'json>(&'json self, source: &'json [u8]) -> Option<Cursor<'json>> {
        if self.is_empty() {
            return None;
        }

        Some(Cursor {
            document: self,
            index: 0,
            source,
        })
    }

    fn scan(&mut self, source: &[u8], offset: &mut u32) -> Outcome {
        let length = count_of(source.len());

        for _ in 0..=length {
            if *offset >= length {
                return Outcome::Invalid(*offset);
            }

            let Some(byte) = byte_at(source, *offset) else {
                return Outcome::Invalid(*offset);
            };

            let opened = match byte {
                b'[' => Some(Kind::Array),
                b'{' => Some(Kind::Object),
                _ => None,
            };

            if let Some(kind) = opened {
                let outcome = self.open(source, offset, kind);

                if outcome != Outcome::Complete {
                    return outcome;
                }

                if self.frames.count() == 0 {
                    return Outcome::Complete;
                }

                continue;
            }

            let scanned = self.scan_scalar(source, offset);

            if scanned != Outcome::Complete {
                return scanned;
            }

            let advanced = self.advance(source, offset);

            if advanced != Outcome::Complete {
                return advanced;
            }

            if self.frames.count() == 0 {
                return Outcome::Complete;
            }
        }

        Outcome::Invalid(*offset)
    }

    fn scan_key(&mut self, source: &[u8], offset: &mut u32) -> Outcome {
        *offset = skipped_space(source, *offset);

        if byte_at(source, *offset) != Some(b'"') {
            return Outcome::Invalid(*offset);
        }

        let scanned = self.scan_scalar(source, offset);

        if scanned != Outcome::Complete {
            return scanned;
        }

        *offset = skipped_space(source, *offset);

        if byte_at(source, *offset) != Some(b':') {
            return Outcome::Invalid(*offset);
        }

        *offset = skipped_space(source, offset.saturating_add(1));

        Outcome::Complete
    }

    fn scan_scalar(&mut self, source: &[u8], offset: &mut u32) -> Outcome {
        let start = *offset;

        let Some(byte) = byte_at(source, start) else {
            return Outcome::Invalid(start);
        };

        let held = match byte {
            b'"' => scalar_string(source, start),
            b'f' => scalar_word(source, start, b"false", Kind::False),
            b'n' => scalar_word(source, start, b"null", Kind::Null),
            b't' => scalar_word(source, start, b"true", Kind::True),
            _ => scalar_number(source, start),
        };

        let Some((kind, span, end)) = held else {
            return Outcome::Invalid(start);
        };

        *offset = end;

        let pushed = self.nodes.push(Node {
            end: self.nodes.count().saturating_add(1),
            kind,
            span,
        });

        if pushed {
            return Outcome::Complete;
        }

        Outcome::Truncated(start)
    }
}

impl<'json> Cursor<'json> {
    const fn at(self, index: u32) -> Self {
        Self {
            document: self.document,
            index,
            source: self.source,
        }
    }

    fn children_of(self, kind: Kind) -> (u32, u32) {
        let Some(node) = self.node() else {
            return (0, 0);
        };

        if node.kind != kind {
            return (0, 0);
        }

        (self.index.saturating_add(1), node.end)
    }

    pub fn elements(self) -> impl Iterator<Item = Self> + 'json {
        let (mut index, end) = self.children_of(Kind::Array);

        from_fn(move || {
            if index >= end {
                return None;
            }

            let value = self.at(index);

            index = self.sibling_after(index);

            Some(value)
        })
    }

    pub fn is_null(self) -> bool {
        self.kind() == Some(Kind::Null)
    }

    pub fn is_true(self) -> bool {
        self.kind() == Some(Kind::True)
    }

    pub fn boolean(self) -> Option<bool> {
        match self.kind()? {
            Kind::False => Some(false),
            Kind::True => Some(true),
            Kind::Array | Kind::Null | Kind::Number | Kind::Object | Kind::String => None,
        }
    }

    pub fn span(self) -> Option<Span> {
        let node = self.node()?;

        if node.kind != Kind::String {
            return Some(node.span);
        }

        Some(Span {
            length: node.span.length.saturating_add(2),
            offset: node.span.offset.saturating_sub(1),
        })
    }

    pub fn kind(self) -> Option<Kind> {
        let node = self.node()?;

        Some(node.kind)
    }

    pub fn member(self, key: &[u8]) -> Option<Self> {
        for (name, value) in self.members() {
            if name.text_is(key) {
                return Some(value);
            }
        }

        None
    }

    pub fn members(self) -> impl Iterator<Item = (Self, Self)> + 'json {
        let (mut index, end) = self.children_of(Kind::Object);

        from_fn(move || {
            if index >= end {
                return None;
            }

            let key = self.at(index);
            let slot = self.sibling_after(index);

            if slot >= end {
                return None;
            }

            let value = self.at(slot);

            index = self.sibling_after(slot);

            Some((key, value))
        })
    }

    fn node(self) -> Option<Node> {
        self.document.node_at(self.index)
    }

    pub fn number(self) -> Option<i64> {
        if self.kind() != Some(Kind::Number) {
            return None;
        }

        let raw = self.raw()?;

        let Ok(text) = from_utf8(raw) else {
            return None;
        };

        text.parse::<i64>().ok()
    }

    pub fn number_unsigned(self) -> Option<u32> {
        u32::try_from(self.number()?).ok()
    }

    pub fn number_real(self) -> Option<f64> {
        if self.kind() != Some(Kind::Number) {
            return None;
        }

        let raw = self.raw()?;

        let Ok(text) = from_utf8(raw) else {
            return None;
        };

        text.parse::<f64>().ok()
    }

    pub fn raw(self) -> Option<&'json [u8]> {
        let node = self.node()?;

        self.source.get(node.span.range())
    }

    fn sibling_after(self, index: u32) -> u32 {
        let Some(node) = self.document.node_at(index) else {
            return index.saturating_add(1);
        };

        node.end.max(index.saturating_add(1))
    }

    pub fn text<W>(self, out: &mut W) -> bool
    where
        W: Bytes,
    {
        if self.kind() != Some(Kind::String) {
            return false;
        }

        let Some(raw) = self.raw() else {
            return false;
        };

        unescaped(raw, out)
    }

    pub fn text_is(self, expected: &[u8]) -> bool {
        if self.kind() != Some(Kind::String) {
            return false;
        }

        let Some(raw) = self.raw() else {
            return false;
        };

        if !raw.contains(&b'\\') {
            return raw == expected;
        }

        let mut compared = Comparison {
            expected,
            matched: true,
            offset: 0,
        };

        unescaped(raw, &mut compared) && compared.matched && compared.offset == expected.len()
    }
}

impl Bytes for Comparison<'_> {
    fn push_bytes(&mut self, bytes: &[u8]) -> bool {
        let end = self.offset.saturating_add(bytes.len());

        if self.expected.get(self.offset..end) != Some(bytes) {
            self.matched = false;

            return false;
        }

        self.offset = end;

        true
    }
}

fn byte_at(source: &[u8], offset: u32) -> Option<u8> {
    let Ok(slot) = usize::try_from(offset) else {
        return None;
    };

    source.get(slot).copied()
}

const fn closer_of(kind: Kind) -> u8 {
    match kind {
        Kind::Array => b']',
        Kind::False | Kind::Null | Kind::Number | Kind::Object | Kind::String | Kind::True => b'}',
    }
}

fn hex_at(raw: &[u8], start: usize) -> Option<u32> {
    let digits = raw.get(start..start.saturating_add(HEX_DIGITS))?;
    let mut code = 0_u32;

    for digit in digits {
        let value = match *digit {
            b'0'..=b'9' => u32::from(digit.saturating_sub(b'0')),
            b'A'..=b'F' => u32::from(digit.saturating_sub(b'A')).saturating_add(10),
            b'a'..=b'f' => u32::from(digit.saturating_sub(b'a')).saturating_add(10),
            _ => return None,
        };

        code = code.saturating_mul(HEX_RADIX).saturating_add(value);
    }

    Some(code)
}

fn matches(source: &[u8], offset: u32, word: &[u8]) -> bool {
    let Ok(start) = usize::try_from(offset) else {
        return false;
    };

    let end = start.saturating_add(word.len());

    source.get(start..end) == Some(word)
}

fn number_end(source: &[u8], start: u32) -> u32 {
    let mut offset = start;

    while let Some(byte) = byte_at(source, offset) {
        let held = matches!(byte, b'-' | b'+' | b'.' | b'0'..=b'9' | b'E' | b'e');

        if !held {
            break;
        }

        offset = offset.saturating_add(1);
    }

    offset
}

fn plain_end(raw: &[u8], start: usize) -> usize {
    let mut offset = start;

    while let Some(byte) = raw.get(offset).copied() {
        if byte == b'\\' {
            break;
        }

        offset = offset.saturating_add(1);
    }

    offset
}

fn scalar_number(source: &[u8], start: u32) -> Option<(Kind, Span, u32)> {
    let end = number_end(source, start);

    if end == start {
        return None;
    }

    let span = Span {
        length: end.saturating_sub(start),
        offset: start,
    };

    Some((Kind::Number, span, end))
}

fn scalar_string(source: &[u8], start: u32) -> Option<(Kind, Span, u32)> {
    let end = string_end(source, start)?;

    let span = Span {
        length: end.saturating_sub(start).saturating_sub(2),
        offset: start.saturating_add(1),
    };

    Some((Kind::String, span, end))
}

fn scalar_word(source: &[u8], start: u32, word: &[u8], kind: Kind) -> Option<(Kind, Span, u32)> {
    if !matches(source, start, word) {
        return None;
    }

    let length = count_of(word.len());

    let span = Span {
        length,
        offset: start,
    };

    Some((kind, span, start.saturating_add(length)))
}

fn skipped_space(source: &[u8], start: u32) -> u32 {
    let mut offset = start;

    while let Some(byte) = byte_at(source, offset) {
        if !matches!(byte, b' ' | b'\t' | b'\n' | b'\r') {
            break;
        }

        offset = offset.saturating_add(1);
    }

    offset
}

fn string_end(source: &[u8], start: u32) -> Option<u32> {
    let mut offset = start.saturating_add(1);

    for _ in 0..=source.len() {
        let byte = byte_at(source, offset)?;

        if byte == b'"' {
            return Some(offset.saturating_add(1));
        }

        if byte == b'\\' {
            offset = offset.saturating_add(2);

            continue;
        }

        offset = offset.saturating_add(1);
    }

    None
}

fn unescaped<W>(raw: &[u8], out: &mut W) -> bool
where
    W: Bytes,
{
    let mut offset = 0_usize;

    while offset < raw.len() {
        let Some(byte) = raw.get(offset).copied() else {
            return false;
        };

        if byte != b'\\' {
            let plain = plain_end(raw, offset);

            let Some(run) = raw.get(offset..plain) else {
                return false;
            };

            if !out.push_bytes(run) {
                return false;
            }

            offset = plain;

            continue;
        }

        let Some(escape) = raw.get(offset.saturating_add(1)).copied() else {
            return false;
        };

        let literal: &[u8] = match escape {
            b'"' => b"\"",
            b'/' => b"/",
            b'\\' => b"\\",
            b'b' => b"\x08",
            b'f' => b"\x0C",
            b'n' => b"\n",
            b'r' => b"\r",
            b't' => b"\t",
            b'u' => b"",
            _ => return false,
        };

        if literal.is_empty() {
            let Some(next) = write_escaped_code(raw, offset, out) else {
                return false;
            };

            offset = next;

            continue;
        }

        if !out.push_bytes(literal) {
            return false;
        }

        offset = offset.saturating_add(2);
    }

    true
}

fn write_escaped_code<W>(raw: &[u8], start: usize, out: &mut W) -> Option<usize>
where
    W: Bytes,
{
    let first = hex_at(raw, start.saturating_add(2))?;
    let mut offset = start.saturating_add(ESCAPE_BYTES);

    let code = if (SURROGATE_HIGH_FIRST..=SURROGATE_HIGH_LAST).contains(&first) {
        if raw.get(offset..offset.saturating_add(2)) != Some(b"\\u") {
            return None;
        }

        let second = hex_at(raw, offset.saturating_add(2))?;

        if !(SURROGATE_LOW_FIRST..=SURROGATE_LOW_LAST).contains(&second) {
            return None;
        }

        offset = offset.saturating_add(ESCAPE_BYTES);

        let high = first.saturating_sub(SURROGATE_HIGH_FIRST) << SURROGATE_SHIFT;
        let low = second.saturating_sub(SURROGATE_LOW_FIRST);

        SURROGATE_OFFSET.saturating_add(high).saturating_add(low)
    } else {
        first
    };

    let point = char::from_u32(code)?;
    let mut encoded = [0_u8; 4];

    if !out.push_bytes(point.encode_utf8(&mut encoded).as_bytes()) {
        return None;
    }

    Some(offset)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::allocation;
    use crate::bounded::{BoundedString, Buffer, Random};

    const DID_OPEN: &[u8] = br#"{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///tmp/main.rs","languageId":"rust","version":1,"text":"fn main() {\n    let value = \"quoted\";\n}\n"}}}"#;
    const INITIALIZE: &[u8] = br#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"processId":4321,"rootUri":null,"capabilities":{"textDocument":{"synchronization":{"dynamicRegistration":false}}},"trace":"off"}}"#;
    const NODE_COUNT_MAX: u32 = 512;
    const OUT_BYTES_MAX: u32 = 4_096;

    fn parsed(source: &[u8]) -> Document {
        let mut document = Document::reserve(NODE_COUNT_MAX);

        assert_eq!(document.parse(source), Outcome::Complete, "{source:?}");

        document
    }

    fn text_of(document: &Document, source: &[u8], key: &[u8]) -> String {
        let root = document.root(source).expect("the document has a root");
        let value = root.member(key).expect("the object carries the key");
        let mut out = Buffer::reserve(OUT_BYTES_MAX);

        assert!(value.text(&mut out));

        String::from_utf8(out.as_bytes().to_vec()).expect("the text is utf-8")
    }

    fn parses(source: &[u8]) -> bool {
        let mut document = Document::reserve(NODE_COUNT_MAX);

        document.parse(source) == Outcome::Complete
    }

    #[test]
    fn an_object_reads_back_member_by_member() {
        let source = br#"{"jsonrpc":"2.0","id":7,"method":"initialize"}"#;
        let document = parsed(source);
        let root = document.root(source).expect("the document has a root");

        assert_eq!(root.kind(), Some(Kind::Object));
        assert_eq!(text_of(&document, source, b"jsonrpc"), "2.0");
        assert_eq!(text_of(&document, source, b"method"), "initialize");
        assert_eq!(root.member(b"id").and_then(Cursor::number), Some(7));
        assert!(root.member(b"params").is_none());
    }

    #[test]
    fn a_nested_object_reads_through_its_parent() {
        let source = br#"{"params":{"capabilities":{"textDocument":{"synchronization":true}}}}"#;
        let document = parsed(source);
        let root = document.root(source).expect("the document has a root");

        let held = root
            .member(b"params")
            .and_then(|params| params.member(b"capabilities"))
            .and_then(|capabilities| capabilities.member(b"textDocument"))
            .and_then(|text_document| text_document.member(b"synchronization"))
            .is_some_and(Cursor::is_true);

        assert!(held);
    }

    #[test]
    fn an_array_yields_every_element_in_order() {
        let source = br#"{"items":[1,2,3,{"deep":[4]},5]}"#;
        let document = parsed(source);
        let root = document.root(source).expect("the document has a root");
        let items = root.member(b"items").expect("the object carries items");

        let numbers = items
            .elements()
            .filter_map(Cursor::number)
            .collect::<Vec<_>>();

        assert_eq!(numbers, [1_i64, 2_i64, 3_i64, 5_i64]);
        assert_eq!(items.elements().count(), 5);
    }

    #[test]
    fn an_empty_container_carries_nothing() {
        let source = br#"{"a":{},"b":[],"c":null}"#;
        let document = parsed(source);
        let root = document.root(source).expect("the document has a root");

        assert_eq!(root.members().count(), 3);
        assert_eq!(
            root.member(b"a").map(Cursor::members).map(Iterator::count),
            Some(0)
        );
        assert_eq!(
            root.member(b"b").map(Cursor::elements).map(Iterator::count),
            Some(0)
        );
        assert_eq!(root.member(b"c").and_then(Cursor::kind), Some(Kind::Null));
        assert!(root.member(b"c").is_some_and(Cursor::is_null));
    }

    #[test]
    fn every_escape_resolves_on_the_way_out() {
        let source = br#"{"text":"a\"b\\c\/d\be\ff\ng\rh\ti\u00e9j\ud83d\ude00"}"#;
        let document = parsed(source);

        assert_eq!(
            text_of(&document, source, b"text"),
            "a\"b\\c/d\u{8}e\u{c}f\ng\rh\ti\u{e9}j\u{1f600}"
        );
    }

    #[test]
    fn a_key_carrying_an_escape_still_matches() {
        let source = br#"{"a\nb":1}"#;
        let document = parsed(source);
        let root = document.root(source).expect("the document has a root");

        assert!(root.member(b"a\nb").is_some());
        assert!(root.member(b"a\\nb").is_none());
    }

    #[test]
    fn a_number_reads_as_an_integer_and_as_a_double() {
        let source = br#"{"whole":-12,"real":1.5e2,"word":"7"}"#;
        let document = parsed(source);
        let root = document.root(source).expect("the document has a root");

        assert_eq!(root.member(b"whole").and_then(Cursor::number), Some(-12));
        assert_eq!(
            root.member(b"real").and_then(Cursor::number_real),
            Some(150.0_f64)
        );
        assert_eq!(root.member(b"real").and_then(Cursor::number), None);
        assert_eq!(root.member(b"word").and_then(Cursor::number), None);
        assert_eq!(root.member(b"whole").and_then(Cursor::number_unsigned), None);
    }

    #[test]
    fn an_integer_reads_to_the_bounds_of_its_type_and_no_further() {
        let source = b"[-9223372036854775808, 9223372036854775807, -9223372036854775809, 4321]";
        let document = parsed(source);
        let root = document.root(source).expect("the document has a root");
        let mut items = root.elements();

        assert_eq!(items.next().and_then(Cursor::number), Some(i64::MIN));
        assert_eq!(items.next().and_then(Cursor::number), Some(i64::MAX));
        assert_eq!(items.next().and_then(Cursor::number), None);
        assert_eq!(items.next().and_then(Cursor::number_unsigned), Some(4321));
        assert!(items.next().is_none());
    }

    #[test]
    fn a_boolean_reads_as_itself_and_nothing_else_does() {
        let source = b"[true,false,null,1]";
        let document = parsed(source);
        let root = document.root(source).expect("the document has a root");
        let mut items = root.elements();

        assert_eq!(items.next().and_then(Cursor::boolean), Some(true));
        assert_eq!(items.next().and_then(Cursor::boolean), Some(false));
        assert_eq!(items.next().and_then(Cursor::boolean), None);
        assert_eq!(items.next().and_then(Cursor::boolean), None);
    }

    #[test]
    fn a_span_covers_the_whole_value_quotes_included() {
        fn of<'json>(root: Cursor<'json>, source: &'json [u8], key: &[u8]) -> &'json [u8] {
            let span = root
                .member(key)
                .and_then(Cursor::span)
                .expect("the member exists");

            &source[span.range()]
        }

        let source = br#"{"a":"xy","b":[1,2],"c":12}"#;
        let document = parsed(source);
        let root = document.root(source).expect("the document has a root");

        assert_eq!(of(root, source, b"a"), br#""xy""#);
        assert_eq!(of(root, source, b"b"), b"[1,2]");
        assert_eq!(of(root, source, b"c"), b"12");
        assert_eq!(root.span().map(|span| span.range()), Some(0..source.len()));
    }

    #[test]
    fn a_request_yields_its_method_and_identifier() {
        let document = parsed(INITIALIZE);
        let root = document.root(INITIALIZE).expect("the document has a root");

        assert_eq!(root.member(b"id").and_then(Cursor::number), Some(1));
        assert!(root.member(b"method").is_some_and(|method| method.text_is(b"initialize")));

        let params = root.member(b"params").expect("the params are present");
        let (first, value) = params.members().next().expect("the params are not empty");

        assert!(first.text_is(b"processId"));
        assert_eq!(value.number(), Some(4321));
        assert!(params.member(b"rootUri").is_some_and(Cursor::is_null));
    }

    #[test]
    fn a_string_with_escapes_decodes_into_a_bounded_string() {
        let mut text = BoundedString::reserve(256);
        let document = parsed(DID_OPEN);
        let root = document.root(DID_OPEN).expect("the document has a root");

        let held = root
            .member(b"params")
            .and_then(|params| params.member(b"textDocument"))
            .and_then(|held| held.member(b"text"))
            .expect("the text is present");

        assert!(held.text(&mut text));
        assert_eq!(
            text.as_str(),
            "fn main() {\n    let value = \"quoted\";\n}\n"
        );
    }

    #[test]
    fn a_surrogate_pair_decodes_to_one_scalar() {
        let mut text = BoundedString::reserve(64);
        let source = b"\"a\\uD83D\\uDE00b\"";
        let document = parsed(source);
        let root = document.root(source).expect("the document has a root");

        assert!(root.text(&mut text));
        assert_eq!(text.as_str(), "a\u{1F600}b");
        assert!(root.text_is("a\u{1F600}b".as_bytes()));
    }

    #[test]
    fn a_lone_surrogate_is_rejected() {
        let mut text = BoundedString::reserve(64);
        let source = br#""a\uD83Db""#;
        let document = parsed(source);
        let root = document.root(source).expect("the document has a root");

        assert!(!root.text(&mut text));
        assert!(!root.text_is(b"a"));
    }

    #[test]
    fn a_text_that_does_not_fit_is_refused() {
        let mut text = BoundedString::reserve(4);
        let source = br#""a\nlonger text""#;
        let document = parsed(source);
        let root = document.root(source).expect("the document has a root");

        assert!(!root.text(&mut text));
    }

    #[test]
    fn whitespace_between_every_token_changes_nothing() {
        let dense = br#"{"a":[1,{"b":2}]}"#;
        let loose = b"  {  \"a\" : [ 1 , { \"b\" : 2 } ]  }  ";
        let first = parsed(dense);
        let second = parsed(loose);

        assert_eq!(first.count(), second.count());
        assert_eq!(
            first
                .root(dense)
                .and_then(|root| root.member(b"a"))
                .map(|value| value.elements().count()),
            second
                .root(loose)
                .and_then(|root| root.member(b"a"))
                .map(|value| value.elements().count())
        );
    }

    #[test]
    fn a_document_that_is_not_json_says_where_it_stopped() {
        let mut document = Document::reserve(NODE_COUNT_MAX);

        assert!(matches!(document.parse(b"{"), Outcome::Invalid(_)));
        assert!(matches!(document.parse(b"{\"a\"}"), Outcome::Invalid(_)));
        assert!(matches!(document.parse(b"[1,]"), Outcome::Invalid(_)));
        assert!(matches!(document.parse(b"tru"), Outcome::Invalid(_)));
        assert!(matches!(document.parse(b""), Outcome::Invalid(_)));
        assert!(matches!(document.parse(b"{} {}"), Outcome::Invalid(_)));
        assert!(document.root(b"").is_none());
    }

    #[test]
    fn each_truncation_is_rejected_without_panicking() {
        for length in 0..INITIALIZE.len() {
            assert!(!parses(&INITIALIZE[..length]), "length {length}");
        }

        assert!(parses(INITIALIZE));
    }

    #[test]
    fn each_corruption_is_handled_without_panicking() {
        let mut random = Random::new(0x0DDB_1A5E_5BAD_5EED);
        let mut corrupted = [0_u8; 512];
        let mut rejected = 0;

        assert!(DID_OPEN.len() <= corrupted.len());

        for _ in 0..4_096 {
            corrupted[..DID_OPEN.len()].copy_from_slice(DID_OPEN);

            let offset = random.below(u32::try_from(DID_OPEN.len()).expect("the length fits"));
            let byte = u8::try_from(random.below(256)).expect("the byte fits");

            corrupted[offset as usize] = byte;

            if !parses(&corrupted[..DID_OPEN.len()]) {
                rejected += 1;
            }
        }

        assert!(rejected > 0, "not one corruption was rejected");
    }

    #[test]
    fn a_document_deeper_than_the_frames_is_refused() {
        let mut source = Vec::new();

        source.extend(core::iter::repeat_n(b'[', 128));
        source.push(b'1');
        source.extend(core::iter::repeat_n(b']', 128));

        let mut document = Document::reserve(NODE_COUNT_MAX);

        assert!(matches!(document.parse(&source), Outcome::TooDeep(_)));
    }

    #[test]
    fn a_document_larger_than_the_node_table_is_truncated() {
        let mut source = Vec::from(b"[".as_slice());

        for index in 0_u32..64_u32 {
            if index > 0 {
                source.push(b',');
            }

            source.push(b'1');
        }

        source.push(b']');

        let mut document = Document::reserve(8);

        assert!(matches!(document.parse(&source), Outcome::Truncated(_)));
    }

    #[test]
    fn a_parse_runs_on_a_frozen_thread() {
        let source = br#"{"a":[1,2,{"b":"c\u00e9"}],"d":true}"#;
        let mut document = Document::reserve(NODE_COUNT_MAX);
        let mut text = BoundedString::reserve(64);

        allocation::frozen(|| {
            assert_eq!(document.parse(source), Outcome::Complete);

            let root = document.root(source).expect("the document has a root");

            assert_eq!(root.members().count(), 2);

            let held = root
                .member(b"a")
                .and_then(|items| items.elements().nth(2))
                .and_then(|object| object.member(b"b"))
                .expect("the nested string is present");

            assert!(held.text(&mut text));
        });

        assert_eq!(text.as_str(), "c\u{e9}");
    }
}
