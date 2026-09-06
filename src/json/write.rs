use core::fmt::Write as _;

use crate::bounded::{BoundedString, BoundedVec, Bytes};
use crate::json::DEPTH_MAX;

const NUMBER_BYTES_MAX: u32 = 32;
const NIBBLE_MASK: u8 = 0x0F;
const NIBBLE_SHIFT: u32 = 4;
const PRINTABLE_FIRST: u8 = 0x20;
const INDENT_COLUMNS: u32 = 2;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct Frame {
    array: bool,
    keyed: bool,
    written: bool,
}

#[derive(Debug)]
pub struct Writer {
    frames: BoundedVec<Frame>,
    number: BoundedString,
    poisoned: bool,
    pretty: bool,
}

impl Writer {
    pub fn array_close<W>(&mut self, out: &mut W) -> bool
    where
        W: Bytes,
    {
        self.close(out, true)
    }

    pub fn array_open<W>(&mut self, out: &mut W) -> bool
    where
        W: Bytes,
    {
        self.open(out, true)
    }

    fn awaiting(&mut self) -> bool {
        let Some(frame) = self.frames.last_mut() else {
            return true;
        };

        frame.keyed = true;
        frame.written = false;

        true
    }

    pub fn boolean<W>(&mut self, out: &mut W, value: bool) -> bool
    where
        W: Bytes,
    {
        let literal: &[u8] = if value { b"true" } else { b"false" };

        self.value(out, literal)
    }

    fn broke<W>(&self, out: &mut W) -> bool
    where
        W: Bytes,
    {
        if !out.push_bytes(b"\n") {
            return false;
        }

        let mut depth = self.frames.count().saturating_mul(INDENT_COLUMNS);

        while depth > 0 {
            if !out.push_bytes(b" ") {
                return false;
            }

            depth = depth.saturating_sub(1);
        }

        true
    }

    fn close<W>(&mut self, out: &mut W, array: bool) -> bool
    where
        W: Bytes,
    {
        if self.poisoned {
            return false;
        }

        let Some(frame) = self.frames.pop() else {
            return self.poison();
        };

        if frame.array != array {
            return self.poison();
        }

        let closer: &[u8] = if array { b"]" } else { b"}" };

        if self.pretty && frame.written && !self.broke(out) {
            return self.poison();
        }

        if !out.push_bytes(closer) {
            return self.poison();
        }

        self.written()
    }

    pub fn finish(&self) -> bool {
        !self.poisoned && self.frames.count() == 0
    }

    pub const fn is_poisoned(&self) -> bool {
        self.poisoned
    }

    pub fn key<W>(&mut self, out: &mut W, name: &[u8]) -> bool
    where
        W: Bytes,
    {
        if !self.separate(out) {
            return false;
        }

        if !write_string(out, name) {
            return self.poison();
        }

        let colon: &[u8] = if self.pretty { b": " } else { b":" };

        if !out.push_bytes(colon) {
            return self.poison();
        }

        self.awaiting()
    }

    pub fn null<W>(&mut self, out: &mut W) -> bool
    where
        W: Bytes,
    {
        self.value(out, b"null")
    }

    pub fn number<W>(&mut self, out: &mut W, value: i64) -> bool
    where
        W: Bytes,
    {
        if !self.separate(out) {
            return false;
        }

        self.number.clear();

        if write!(&mut self.number, "{value}").is_err() {
            return self.poison();
        }

        let spelled = self.number.as_str().as_bytes();

        if !spelled.is_empty() && out.push_bytes(spelled) {
            return self.written();
        }

        self.poison()
    }

    pub fn object_close<W>(&mut self, out: &mut W) -> bool
    where
        W: Bytes,
    {
        self.close(out, false)
    }

    pub fn object_open<W>(&mut self, out: &mut W) -> bool
    where
        W: Bytes,
    {
        self.open(out, false)
    }

    fn open<W>(&mut self, out: &mut W, array: bool) -> bool
    where
        W: Bytes,
    {
        if !self.separate(out) {
            return false;
        }

        let opener: &[u8] = if array { b"[" } else { b"{" };

        if !out.push_bytes(opener) {
            return self.poison();
        }

        let pushed = self.frames.push(Frame {
            array,
            keyed: false,
            written: false,
        });

        if pushed {
            return true;
        }

        self.poison()
    }

    const fn poison(&mut self) -> bool {
        self.poisoned = true;

        false
    }

    pub fn raw<W>(&mut self, out: &mut W, value: &[u8]) -> bool
    where
        W: Bytes,
    {
        if value.is_empty() {
            return self.null(out);
        }

        if !self.separate(out) {
            return false;
        }

        if !out.push_bytes(value) {
            return self.poison();
        }

        self.written()
    }

    pub fn reserve(depth_max: u32) -> Self {
        assert!(depth_max > 0);
        assert!(depth_max <= DEPTH_MAX);
        assert!(!crate::allocation::is_frozen());

        Self {
            frames: BoundedVec::reserve(depth_max),
            number: BoundedString::reserve(NUMBER_BYTES_MAX),
            poisoned: false,
            pretty: false,
        }
    }

    pub fn reserve_pretty(depth_max: u32) -> Self {
        let mut writer = Self::reserve(depth_max);

        writer.pretty = true;

        writer
    }

    fn separate<W>(&mut self, out: &mut W) -> bool
    where
        W: Bytes,
    {
        if self.poisoned {
            return false;
        }

        let Some(frame) = self.frames.last().copied() else {
            return true;
        };

        if frame.written && !out.push_bytes(b",") {
            return self.poison();
        }

        if self.pretty && !frame.keyed && !self.broke(out) {
            return self.poison();
        }

        true
    }

    pub fn start(&mut self) {
        self.frames.clear();
        self.number.clear();
        self.poisoned = false;

        assert_eq!(self.frames.count(), 0);
    }

    pub fn string<W>(&mut self, out: &mut W, text: &[u8]) -> bool
    where
        W: Bytes,
    {
        if !self.separate(out) {
            return false;
        }

        if !write_string(out, text) {
            return self.poison();
        }

        self.written()
    }

    pub fn string_escaped<W>(&mut self, out: &mut W, escaped: &[u8]) -> bool
    where
        W: Bytes,
    {
        if !self.separate(out) {
            return false;
        }

        if !out.push_bytes(b"\"") || !out.push_bytes(escaped) || !out.push_bytes(b"\"") {
            return self.poison();
        }

        self.written()
    }

    pub fn string_close<W>(&mut self, out: &mut W) -> bool
    where
        W: Bytes,
    {
        if self.poisoned {
            return false;
        }

        if !out.push_bytes(b"\"") {
            return self.poison();
        }

        self.written()
    }

    pub fn string_open<W>(&mut self, out: &mut W) -> bool
    where
        W: Bytes,
    {
        if !self.separate(out) {
            return false;
        }

        if !out.push_bytes(b"\"") {
            return self.poison();
        }

        true
    }

    pub fn string_part<W>(&mut self, out: &mut W, text: &[u8]) -> bool
    where
        W: Bytes,
    {
        if self.poisoned {
            return false;
        }

        if !write_escaped(out, text) {
            return self.poison();
        }

        true
    }

    pub fn string_parts<W>(&mut self, out: &mut W, parts: &[&[u8]]) -> bool
    where
        W: Bytes,
    {
        if !self.separate(out) {
            return false;
        }

        if !write_string_parts(out, parts) {
            return self.poison();
        }

        self.written()
    }

    fn value<W>(&mut self, out: &mut W, literal: &[u8]) -> bool
    where
        W: Bytes,
    {
        if !self.separate(out) {
            return false;
        }

        if !out.push_bytes(literal) {
            return self.poison();
        }

        self.written()
    }

    fn written(&mut self) -> bool {
        let Some(frame) = self.frames.last_mut() else {
            return true;
        };

        frame.keyed = false;
        frame.written = true;

        true
    }
}

fn plain_end(text: &[u8], start: usize) -> usize {
    let mut offset = start;

    while let Some(byte) = text.get(offset).copied() {
        if byte == b'"' || byte == b'\\' || byte < PRINTABLE_FIRST {
            break;
        }

        offset = offset.saturating_add(1);
    }

    offset
}

fn write_escape<W>(out: &mut W, byte: u8) -> bool
where
    W: Bytes,
{
    const DIGITS: &[u8; 16] = b"0123456789abcdef";

    let short: &[u8] = match byte {
        b'"' => b"\\\"",
        b'\\' => b"\\\\",
        0x08 => b"\\b",
        0x09 => b"\\t",
        0x0A => b"\\n",
        0x0C => b"\\f",
        0x0D => b"\\r",
        _ => b"",
    };

    if !short.is_empty() {
        return out.push_bytes(short);
    }

    let high = usize::from(byte >> NIBBLE_SHIFT);
    let low = usize::from(byte & NIBBLE_MASK);

    let (Some(first), Some(second)) = (DIGITS.get(high), DIGITS.get(low)) else {
        return false;
    };

    out.push_bytes(&[b'\\', b'u', b'0', b'0', *first, *second])
}

fn write_string<W>(out: &mut W, text: &[u8]) -> bool
where
    W: Bytes,
{
    write_string_parts(out, &[text])
}

fn write_string_parts<W>(out: &mut W, parts: &[&[u8]]) -> bool
where
    W: Bytes,
{
    if !out.push_bytes(b"\"") {
        return false;
    }

    for part in parts {
        if !write_escaped(out, part) {
            return false;
        }
    }

    out.push_bytes(b"\"")
}

fn write_escaped<W>(out: &mut W, text: &[u8]) -> bool
where
    W: Bytes,
{
    let mut offset = 0_usize;

    while offset < text.len() {
        let plain = plain_end(text, offset);

        if plain > offset {
            let Some(run) = text.get(offset..plain) else {
                return false;
            };

            if !out.push_bytes(run) {
                return false;
            }

            offset = plain;

            continue;
        }

        let Some(byte) = text.get(offset).copied() else {
            return false;
        };

        if !write_escape(out, byte) {
            return false;
        }

        offset = offset.saturating_add(1);
    }

    true
}

#[cfg(test)]
mod tests {
    use core::str::from_utf8;

    use super::*;
    use crate::allocation;
    use crate::bounded::Buffer;
    use crate::json::read::{Document, Outcome};

    const OUT_BYTES_MAX: u32 = 4_096;

    fn spelled(out: &Buffer) -> &str {
        from_utf8(out.as_bytes()).expect("the document is utf-8")
    }

    #[test]
    fn the_writer_spells_a_document_the_reader_reads_back() {
        let mut writer = Writer::reserve(16);
        let mut out = Buffer::reserve(OUT_BYTES_MAX);

        writer.start();

        assert!(writer.object_open(&mut out));
        assert!(writer.key(&mut out, b"jsonrpc"));
        assert!(writer.string(&mut out, b"2.0"));
        assert!(writer.key(&mut out, b"id"));
        assert!(writer.number(&mut out, 7));
        assert!(writer.key(&mut out, b"result"));
        assert!(writer.object_open(&mut out));
        assert!(writer.key(&mut out, b"items"));
        assert!(writer.array_open(&mut out));
        assert!(writer.number(&mut out, 1));
        assert!(writer.boolean(&mut out, true));
        assert!(writer.null(&mut out));
        assert!(writer.string(&mut out, b"a\"b\nc"));
        assert!(writer.array_close(&mut out));
        assert!(writer.object_close(&mut out));
        assert!(writer.object_close(&mut out));
        assert!(!writer.is_poisoned());
        assert!(writer.finish());

        assert_eq!(
            spelled(&out),
            r#"{"jsonrpc":"2.0","id":7,"result":{"items":[1,true,null,"a\"b\nc"]}}"#
        );

        let mut document = Document::reserve(64);

        assert_eq!(document.parse(out.as_bytes()), Outcome::Complete);

        let root = document
            .root(out.as_bytes())
            .expect("the document has a root");

        assert!(root.member(b"jsonrpc").is_some_and(|held| held.text_is(b"2.0")));
    }

    #[test]
    fn the_writer_escapes_every_control_byte() {
        let mut writer = Writer::reserve(4);
        let mut out = Buffer::reserve(OUT_BYTES_MAX);

        writer.start();

        assert!(writer.string(&mut out, b"\x00\x01\x1f\x08\x09\x0a\x0c\x0d\\\""));
        assert_eq!(spelled(&out), r#""\u0000\u0001\u001f\b\t\n\f\r\\\"""#);
    }

    #[test]
    fn a_control_character_is_escaped_as_a_code_unit() {
        let mut writer = Writer::reserve(4);
        let mut out = Buffer::reserve(64);

        writer.start();

        assert!(writer.string(&mut out, b"bell\x07end"));
        assert_eq!(spelled(&out), "\"bell\\u0007end\"");
    }

    #[test]
    fn a_writer_that_runs_out_of_room_stays_refused() {
        let mut writer = Writer::reserve(4);
        let mut out = Buffer::reserve(8);

        writer.start();

        assert!(writer.array_open(&mut out));

        let mut refused = false;

        for _ in 0_u32..64_u32 {
            if !writer.string(&mut out, b"padding") {
                refused = true;

                break;
            }
        }

        assert!(refused);
        assert!(writer.is_poisoned());
        assert!(!writer.array_close(&mut out));
        assert!(!writer.finish());
        assert!(out.as_bytes().len() <= 8);
    }

    #[test]
    fn a_writer_reused_after_start_forgets_the_last_document() {
        let mut writer = Writer::reserve(4);
        let mut out = Buffer::reserve(OUT_BYTES_MAX);

        writer.start();

        assert!(writer.array_open(&mut out));
        assert!(writer.number(&mut out, 1));
        assert!(!writer.finish());

        out.clear();
        writer.start();

        assert!(writer.array_open(&mut out));
        assert!(writer.number(&mut out, 2));
        assert!(writer.array_close(&mut out));
        assert!(writer.finish());
        assert_eq!(out.as_bytes(), b"[2]");
    }

    #[test]
    fn a_closing_brace_that_does_not_match_its_opener_is_refused() {
        let mut writer = Writer::reserve(4);
        let mut out = Buffer::reserve(OUT_BYTES_MAX);

        writer.start();

        assert!(writer.object_open(&mut out));
        assert!(!writer.array_close(&mut out));
        assert!(writer.is_poisoned());
    }

    #[test]
    fn a_write_runs_on_a_frozen_thread() {
        let mut writer = Writer::reserve(16);
        let mut out = Buffer::reserve(OUT_BYTES_MAX);

        allocation::frozen(|| {
            writer.start();

            assert!(writer.object_open(&mut out));
            assert!(writer.key(&mut out, b"echo"));
            assert!(writer.string(&mut out, b"value"));
            assert!(writer.object_close(&mut out));
        });

        assert_eq!(out.as_bytes(), br#"{"echo":"value"}"#);
    }

    #[test]
    fn a_raw_value_goes_out_verbatim_and_still_earns_its_comma() {
        let mut writer = Writer::reserve(8);
        let mut out = Buffer::reserve(OUT_BYTES_MAX);

        writer.start();

        assert!(writer.array_open(&mut out));
        assert!(writer.raw(&mut out, br#"{"kind":"quickfix"}"#));
        assert!(writer.number(&mut out, 1));
        assert!(writer.array_close(&mut out));
        assert_eq!(spelled(&out), r#"[{"kind":"quickfix"},1]"#);
    }

    #[test]
    fn an_empty_raw_value_is_written_as_null() {
        let mut writer = Writer::reserve(8);
        let mut out = Buffer::reserve(OUT_BYTES_MAX);

        writer.start();

        assert!(writer.raw(&mut out, b""));
        assert_eq!(spelled(&out), "null");
    }

    #[test]
    fn an_already_escaped_string_keeps_the_escape_it_arrived_with() {
        let mut writer = Writer::reserve(8);
        let mut out = Buffer::reserve(OUT_BYTES_MAX);

        writer.start();

        assert!(writer.string_escaped(&mut out, br#"a\"b"#));
        assert_eq!(spelled(&out), r#""a\"b""#);
    }

    #[test]
    fn a_string_written_in_parts_reads_as_one() {
        let mut writer = Writer::reserve(8);
        let mut out = Buffer::reserve(OUT_BYTES_MAX);

        writer.start();

        assert!(writer.array_open(&mut out));
        assert!(writer.string_open(&mut out));
        assert!(writer.string_part(&mut out, b"one\n"));
        assert!(writer.string_part(&mut out, b"two \"quoted\""));
        assert!(writer.string_close(&mut out));
        assert!(writer.string_parts(&mut out, &[b"a", b"\t", b"b"]));
        assert!(writer.array_close(&mut out));
        assert_eq!(spelled(&out), r#"["one\ntwo \"quoted\"","a\tb"]"#);
    }

    #[test]
    fn a_pretty_writer_lays_the_document_out_one_value_a_line() {
        let mut out = Buffer::reserve(OUT_BYTES_MAX);
        let mut writer = Writer::reserve_pretty(8);

        assert!(writer.array_open(&mut out));
        assert!(writer.object_open(&mut out));
        assert!(writer.key(&mut out, b"code"));
        assert!(writer.string(&mut out, b"DG002"));
        assert!(writer.key(&mut out, b"line"));
        assert!(writer.number(&mut out, 3));
        assert!(writer.key(&mut out, b"related"));
        assert!(writer.array_open(&mut out));
        assert!(writer.array_close(&mut out));
        assert!(writer.key(&mut out, b"location"));
        assert!(writer.object_open(&mut out));
        assert!(writer.key(&mut out, b"path"));
        assert!(writer.string(&mut out, b"a.html"));
        assert!(writer.object_close(&mut out));
        assert!(writer.object_close(&mut out));
        assert!(writer.array_close(&mut out));

        assert_eq!(
            spelled(&out),
            "[\n  {\n    \"code\": \"DG002\",\n    \"line\": 3,\n    \"related\": [],\n    \
             \"location\": {\n      \"path\": \"a.html\"\n    }\n  }\n]"
        );
    }
}
