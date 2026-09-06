use crate::scan::{DECIMAL_BYTES_MAX, decimal_read, line_scan};

pub const SEGMENT_COUNT_MAX: usize = 8;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Fault {
    ArrayUnterminated,
    InlineTableUnterminated,
    KeyExpected,
    NumberInvalid,
    StringUnterminated,
    TableUnterminated,
    TrailingText,
    ValueExpected,
    ValueUnreadable,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Error {
    pub column: u32,
    pub fault: Fault,
    pub line: u32,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Text<'source> {
    pub literal: bool,
    pub raw: &'source [u8],
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Value<'source> {
    Array(&'source [u8]),
    Boolean(bool),
    Header,
    InlineTable(&'source [u8]),
    Integer(u64),
    String(Text<'source>),
}

#[derive(Clone, Copy, Debug)]
pub struct Entry<'source> {
    pub key: &'source [u8],
    pub line: u32,
    pub table: &'source [u8],
    pub value: Value<'source>,
}

#[derive(Debug)]
pub struct Items<'source> {
    faulted: bool,
    offset: usize,
    source: &'source [u8],
}

#[derive(Debug)]
pub struct Pairs<'source> {
    faulted: bool,
    offset: usize,
    source: &'source [u8],
}

#[derive(Debug)]
pub struct Reader<'source> {
    line: u32,
    offset: usize,
    source: &'source [u8],
    table: (usize, usize),
}

#[derive(Debug)]
pub struct Segments<'source> {
    offset: usize,
    source: &'source [u8],
}

impl Fault {
    pub const fn text(self) -> &'static str {
        match self {
            Self::ArrayUnterminated => "the array is not closed",
            Self::InlineTableUnterminated => "the inline table is not closed",
            Self::KeyExpected => "a key was expected",
            Self::NumberInvalid => "the number is not a whole number",
            Self::StringUnterminated => "the string is not closed",
            Self::TableUnterminated => "the table header is not closed",
            Self::TrailingText => "text follows the value on the same line",
            Self::ValueExpected => "a value was expected",
            Self::ValueUnreadable => "the value is not a string, integer, boolean, array or table",
        }
    }
}

impl Items<'_> {
    pub const fn is_faulted(&self) -> bool {
        self.faulted
    }
}

impl<'source> Iterator for Items<'source> {
    type Item = Value<'source>;
    fn next(&mut self) -> Option<Value<'source>> {
        self.offset = trivia_skipped(self.source, self.offset);

        if self.offset >= self.source.len() {
            return None;
        }

        let Ok((value, end)) = value_read(self.source, self.offset) else {
            self.faulted = true;
            self.offset = self.source.len();

            return None;
        };

        self.offset = separator_skipped(self.source, end);

        Some(value)
    }
}

impl Pairs<'_> {
    pub const fn is_faulted(&self) -> bool {
        self.faulted
    }

    const fn stopped<T>(&mut self) -> Option<T> {
        self.faulted = true;
        self.offset = self.source.len();

        None
    }
}

impl<'source> Iterator for Pairs<'source> {
    type Item = (&'source [u8], Value<'source>);
    fn next(&mut self) -> Option<(&'source [u8], Value<'source>)> {
        self.offset = trivia_skipped(self.source, self.offset);

        if self.offset >= self.source.len() {
            return None;
        }

        let Ok((key, after_key)) = key_read(self.source, self.offset) else {
            return self.stopped();
        };

        let at = spaces_skipped(self.source, after_key);

        if self.source.get(at).copied() != Some(b'=') {
            return self.stopped();
        }

        let start = spaces_skipped(self.source, at.saturating_add(1));

        let Ok((value, end)) = value_read(self.source, start) else {
            return self.stopped();
        };

        self.offset = separator_skipped(self.source, end);

        Some((key, value))
    }
}

impl<'source> Reader<'source> {
    fn at_line_end(&self) -> bool {
        matches!(
            self.source.get(self.offset).copied(),
            None | Some(b'\n' | b'\r' | b'#')
        )
    }

    fn column(&self) -> u32 {
        let mut column = 1_u32;
        let mut offset = self.offset.min(self.source.len());

        while offset > 0 {
            let Some(byte) = self.source.get(offset.saturating_sub(1)) else {
                break;
            };

            if *byte == b'\n' {
                break;
            }

            column = column.saturating_add(1);
            offset = offset.saturating_sub(1);
        }

        column
    }

    fn count_lines(&mut self, start: usize, end: usize) {
        let stop = end.min(self.source.len());

        for byte in self.source.get(start..stop).unwrap_or(&[]) {
            if *byte == b'\n' {
                self.line = self.line.saturating_add(1);
            }
        }
    }

    fn entry_read(&mut self) -> Result<Entry<'source>, Error> {
        let line = self.line;

        let (key, after_key) = match key_read(self.source, self.offset) {
            Ok(held) => held,
            Err(fault) => return Err(self.error(fault)),
        };

        self.offset = spaces_skipped(self.source, after_key);

        if self.source.get(self.offset).copied() != Some(b'=') {
            return Err(self.error(Fault::ValueExpected));
        }

        self.offset = spaces_skipped(self.source, self.offset.saturating_add(1));

        let start = self.offset;

        let (value, end) = match value_read(self.source, start) {
            Ok(held) => held,
            Err(fault) => {
                self.offset = self.source.len().min(faulted_at(self.source, start, fault));

                return Err(self.error(fault));
            }
        };

        self.count_lines(start, end);
        self.offset = spaces_skipped(self.source, end);

        if !self.at_line_end() {
            return Err(self.error(Fault::TrailingText));
        }

        Ok(Entry {
            key,
            line,
            table: self.header(),
            value,
        })
    }

    fn error(&self, fault: Fault) -> Error {
        Error {
            column: self.column(),
            fault,
            line: self.line,
        }
    }

    fn header(&self) -> &'source [u8] {
        self.source.get(self.table.0..self.table.1).unwrap_or(&[])
    }

    fn line_skip(&mut self) {
        while self.offset < self.source.len() {
            let Some(byte) = self.source.get(self.offset).copied() else {
                break;
            };

            self.offset = self.offset.saturating_add(1);

            if byte == b'\n' {
                self.line = self.line.saturating_add(1);

                break;
            }
        }
    }
    pub const fn new(source: &'source [u8]) -> Self {
        Self {
            line: 1,
            offset: 0,
            source,
            table: (0, 0),
        }
    }
    pub fn read(&mut self) -> Option<Result<Entry<'source>, Error>> {
        self.trivia_skip();

        if self.offset >= self.source.len() {
            return None;
        }

        if self.source.get(self.offset).copied() == Some(b'[') {
            if let Err(error) = self.table_read() {
                self.line_skip();

                return Some(Err(error));
            }

            return Some(Ok(Entry {
                key: &[],
                line: self.line,
                table: self.header(),
                value: Value::Header,
            }));
        }

        match self.entry_read() {
            Ok(entry) => Some(Ok(entry)),
            Err(error) => {
                self.line_skip();

                Some(Err(error))
            }
        }
    }

    fn table_read(&mut self) -> Result<(), Error> {
        let start = self.offset.saturating_add(1);
        let mut offset = start;

        while offset < self.source.len() {
            let Some(byte) = self.source.get(offset).copied() else {
                break;
            };

            if byte == b'"' || byte == b'\'' {
                let (_, end) = quoted(self.source, offset, byte);

                offset = end.min(self.source.len());

                continue;
            }

            if byte == b'\n' {
                self.offset = offset;

                return Err(self.error(Fault::TableUnterminated));
            }

            if byte == b']' {
                self.table = (start, offset);
                self.offset = spaces_skipped(self.source, offset.saturating_add(1));

                if !self.at_line_end() {
                    return Err(self.error(Fault::TrailingText));
                }

                return Ok(());
            }

            offset = offset.saturating_add(1);
        }

        self.offset = self.source.len();

        Err(self.error(Fault::TableUnterminated))
    }

    fn trivia_skip(&mut self) {
        while self.offset < self.source.len() {
            let Some(byte) = self.source.get(self.offset).copied() else {
                break;
            };

            if byte == b'\n' {
                self.line = self.line.saturating_add(1);
                self.offset = self.offset.saturating_add(1);

                continue;
            }

            if byte.is_ascii_whitespace() {
                self.offset = self.offset.saturating_add(1);

                continue;
            }

            if byte == b'#' {
                self.offset = line_scan(self.source, self.offset);

                continue;
            }

            break;
        }
    }
}

impl<'source> Segments<'source> {
    pub const fn of(key: &'source [u8]) -> Self {
        Self {
            offset: 0,
            source: key,
        }
    }
}

impl<'source> Iterator for Segments<'source> {
    type Item = &'source [u8];
    fn next(&mut self) -> Option<&'source [u8]> {
        self.offset = spaces_skipped(self.source, self.offset);

        if self.offset >= self.source.len() {
            return None;
        }

        let byte = self.source.get(self.offset).copied()?;

        if byte == b'"' || byte == b'\'' {
            let (text, end) = quoted(self.source, self.offset, byte);

            self.offset = dot_skipped(self.source, end.min(self.source.len()));

            return Some(text.raw);
        }

        let start = self.offset;
        let mut end = start;

        while end < self.source.len() {
            let Some(held) = self.source.get(end).copied() else {
                break;
            };

            if held == b'.' || held == b' ' || held == b'\t' {
                break;
            }

            end = end.saturating_add(1);
        }

        self.offset = dot_skipped(self.source, end);

        self.source.get(start..end)
    }
}

impl Text<'_> {
    pub fn write_into(&self, out: &mut [u8]) -> Option<usize> {
        if self.literal {
            return copied(out, 0, self.raw);
        }

        let mut written = 0_usize;
        let mut offset = 0_usize;

        while offset < self.raw.len() {
            let Some(byte) = self.raw.get(offset).copied() else {
                break;
            };

            offset = offset.saturating_add(1);

            if byte != b'\\' {
                written = copied(out, written, &[byte])?;

                continue;
            }

            let escaped = self.raw.get(offset).copied()?;

            offset = offset.saturating_add(1);

            let (bytes, count) = match escaped {
                b'"' => ([b'"', 0, 0, 0], 1),
                b'\\' => ([b'\\', 0, 0, 0], 1),
                b'b' => ([0x08, 0, 0, 0], 1),
                b'f' => ([0x0c, 0, 0, 0], 1),
                b'n' => ([b'\n', 0, 0, 0], 1),
                b'r' => ([b'\r', 0, 0, 0], 1),
                b't' => ([b'\t', 0, 0, 0], 1),
                b'u' | b'U' => {
                    let width = if escaped == b'u' { 4 } else { 8 };
                    let end = offset.saturating_add(width);
                    let digits = self.raw.get(offset..end)?;

                    offset = end;

                    encoded(digits)?
                }
                _ => return None,
            };

            let taken = bytes.get(..count)?;

            written = copied(out, written, taken)?;
        }

        Some(written)
    }
}

impl<'source> Value<'source> {
    pub const fn items(&self) -> Items<'source> {
        let source: &'source [u8] = match *self {
            Self::Array(body) => body,
            Self::Boolean(_)
            | Self::Header
            | Self::InlineTable(_)
            | Self::Integer(_)
            | Self::String(_) => &[],
        };

        Items {
            faulted: false,
            offset: 0,
            source,
        }
    }
    pub const fn pairs(&self) -> Pairs<'source> {
        let source: &'source [u8] = match *self {
            Self::InlineTable(body) => body,
            Self::Array(_)
            | Self::Boolean(_)
            | Self::Header
            | Self::Integer(_)
            | Self::String(_) => &[],
        };

        Pairs {
            faulted: false,
            offset: 0,
            source,
        }
    }
}

fn bracketed(source: &[u8], offset: usize, open: u8, close: u8) -> Option<(&[u8], usize)> {
    let start = offset.saturating_add(1);
    let mut depth = 0_u32;
    let mut at = offset;

    while at < source.len() {
        let Some(byte) = source.get(at).copied() else {
            break;
        };

        if byte == b'"' || byte == b'\'' {
            let (_, end) = quoted(source, at, byte);

            at = end.min(source.len());

            continue;
        }

        if byte == b'#' {
            at = line_scan(source, at);

            continue;
        }

        if byte == open {
            depth = depth.saturating_add(1);
        }

        if byte == close {
            depth = depth.saturating_sub(1);

            if depth == 0 {
                return Some((source.get(start..at).unwrap_or(&[]), at.saturating_add(1)));
            }
        }

        at = at.saturating_add(1);
    }

    None
}

fn copied(out: &mut [u8], at: usize, bytes: &[u8]) -> Option<usize> {
    let end = at.saturating_add(bytes.len());
    let slot = out.get_mut(at..end)?;

    slot.copy_from_slice(bytes);

    Some(end)
}

fn dot_skipped(source: &[u8], offset: usize) -> usize {
    let at = spaces_skipped(source, offset);

    if source.get(at).copied() == Some(b'.') {
        return at.saturating_add(1);
    }

    at
}

fn encoded(digits: &[u8]) -> Option<([u8; 4], usize)> {
    let mut value = 0_u32;

    for digit in digits {
        let nibble = char::from(*digit).to_digit(16)?;
        let shifted = value.checked_mul(16)?;

        value = shifted.checked_add(nibble)?;
    }

    let character = char::from_u32(value)?;
    let mut bytes = [0_u8; 4];
    let count = character.encode_utf8(&mut bytes).len();

    Some((bytes, count))
}

const fn faulted_at(source: &[u8], start: usize, fault: Fault) -> usize {
    match fault {
        Fault::ArrayUnterminated | Fault::InlineTableUnterminated | Fault::StringUnterminated => {
            source.len()
        }
        Fault::KeyExpected
        | Fault::NumberInvalid
        | Fault::TableUnterminated
        | Fault::TrailingText
        | Fault::ValueExpected
        | Fault::ValueUnreadable => start,
    }
}

fn integer(text: &[u8]) -> Option<u64> {
    let mut digits = [0_u8; DECIMAL_BYTES_MAX];
    let mut length = 0_usize;

    for (index, byte) in text.iter().enumerate() {
        if *byte == b'_' {
            let next = text.get(index.saturating_add(1)).copied();

            if length == 0 || next.is_none_or(|held| held == b'_') {
                return None;
            }

            continue;
        }

        if !byte.is_ascii_digit() {
            return None;
        }

        let slot = digits.get_mut(length)?;

        *slot = *byte;
        length = length.saturating_add(1);
    }

    if length == 0 {
        return None;
    }

    decimal_read(digits.get(..length).unwrap_or(&[]))
}

const fn is_bare(byte: u8) -> bool {
    byte.is_ascii_alphanumeric() || byte == b'_' || byte == b'-'
}

fn key_read(source: &[u8], offset: usize) -> Result<(&[u8], usize), Fault> {
    let start = offset;
    let mut at = offset;
    let mut segments = 0_usize;

    while at < source.len() {
        let Some(byte) = source.get(at).copied() else {
            break;
        };

        let segment_end = if byte == b'"' || byte == b'\'' {
            let (_, end) = quoted(source, at, byte);

            if end > source.len() {
                return Err(Fault::StringUnterminated);
            }

            end
        } else {
            let mut end = at;

            while source.get(end).copied().is_some_and(is_bare) {
                end = end.saturating_add(1);
            }

            if end == at {
                return Err(Fault::KeyExpected);
            }

            end
        };

        segments = segments.saturating_add(1);

        if segments > SEGMENT_COUNT_MAX {
            return Err(Fault::KeyExpected);
        }

        let dotted = spaces_skipped(source, segment_end);

        if source.get(dotted).copied() != Some(b'.') {
            return Ok((source.get(start..segment_end).unwrap_or(&[]), segment_end));
        }

        at = spaces_skipped(source, dotted.saturating_add(1));
    }

    Err(Fault::KeyExpected)
}

fn quoted(source: &[u8], offset: usize, quote: u8) -> (Text<'_>, usize) {
    let literal = quote == b'\'';
    let triple = source.get(offset..offset.saturating_add(3)) == Some(&[quote, quote, quote]);
    let width = if triple { 3 } else { 1 };
    let start = offset.saturating_add(width);
    let mut at = start;

    while at < source.len() {
        let Some(byte) = source.get(at).copied() else {
            break;
        };

        if byte == b'\\' && !literal {
            at = at.saturating_add(2);

            continue;
        }

        if byte == b'\n' && !triple {
            break;
        }

        if byte == quote {
            let closed = if triple {
                source.get(at..at.saturating_add(3)) == Some(&[quote, quote, quote])
            } else {
                true
            };

            if closed {
                let raw = source.get(start..at).unwrap_or(&[]);

                return (Text { literal, raw }, at.saturating_add(width));
            }
        }

        at = at.saturating_add(1);
    }

    let raw = source.get(start..source.len()).unwrap_or(&[]);

    (Text { literal, raw }, source.len().saturating_add(1))
}

fn separator_skipped(source: &[u8], offset: usize) -> usize {
    let at = trivia_skipped(source, offset);

    if source.get(at).copied() == Some(b',') {
        return trivia_skipped(source, at.saturating_add(1));
    }

    at
}

fn spaces_skipped(source: &[u8], offset: usize) -> usize {
    let mut at = offset;

    while matches!(source.get(at).copied(), Some(b' ' | b'\t')) {
        at = at.saturating_add(1);
    }

    at
}

fn trivia_skipped(source: &[u8], offset: usize) -> usize {
    let mut at = offset;

    while at < source.len() {
        let Some(byte) = source.get(at).copied() else {
            break;
        };

        if byte.is_ascii_whitespace() {
            at = at.saturating_add(1);

            continue;
        }

        if byte == b'#' {
            at = line_scan(source, at);

            continue;
        }

        break;
    }

    at
}

fn value_read(source: &[u8], offset: usize) -> Result<(Value<'_>, usize), Fault> {
    let Some(byte) = source.get(offset).copied() else {
        return Err(Fault::ValueExpected);
    };

    if byte == b'"' || byte == b'\'' {
        let (text, end) = quoted(source, offset, byte);

        if end > source.len() {
            return Err(Fault::StringUnterminated);
        }

        return Ok((Value::String(text), end));
    }

    if byte == b'[' {
        let Some((body, end)) = bracketed(source, offset, b'[', b']') else {
            return Err(Fault::ArrayUnterminated);
        };

        return Ok((Value::Array(body), end));
    }

    if byte == b'{' {
        let Some((body, end)) = bracketed(source, offset, b'{', b'}') else {
            return Err(Fault::InlineTableUnterminated);
        };

        return Ok((Value::InlineTable(body), end));
    }

    bare_read(source, offset)
}

fn bare_read(source: &[u8], offset: usize) -> Result<(Value<'_>, usize), Fault> {
    let mut end = offset;

    while end < source.len() {
        let Some(held) = source.get(end).copied() else {
            break;
        };

        if matches!(
            held,
            b'\n' | b'\r' | b'#' | b',' | b']' | b'}' | b' ' | b'\t'
        ) {
            break;
        }

        end = end.saturating_add(1);
    }

    let text = source.get(offset..end).unwrap_or(&[]);

    if text.is_empty() {
        return Err(Fault::ValueExpected);
    }

    if text == b"true" {
        return Ok((Value::Boolean(true), end));
    }

    if text == b"false" {
        return Ok((Value::Boolean(false), end));
    }

    let Some(value) = integer(text) else {
        if text[0].is_ascii_digit() {
            return Err(Fault::NumberInvalid);
        }

        return Err(Fault::ValueUnreadable);
    };

    Ok((Value::Integer(value), end))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn entries(source: &[u8]) -> Vec<Entry<'_>> {
        let mut reader = Reader::new(source);
        let mut collected = Vec::new();

        while let Some(entry) = reader.read() {
            collected.push(entry.expect("the entry parses"));
        }

        collected
    }

    fn error_of(source: &[u8]) -> Error {
        let mut reader = Reader::new(source);

        for _ in 0..8 {
            match reader.read() {
                Some(Err(error)) => return error,
                Some(Ok(_)) => {}
                None => break,
            }
        }

        panic!("the source carries an error")
    }

    fn strings<'source>(value: &Value<'source>) -> Vec<&'source [u8]> {
        value
            .items()
            .map(|item| match item {
                Value::String(text) => text.raw,
                _ => panic!("an item is a string"),
            })
            .collect()
    }

    #[test]
    fn a_scalar_of_each_kind_reads() {
        let source = b"line_length_max = 88\npreview = true\nextend = \"../a.toml\"\n";
        let read = entries(source);

        assert_eq!(read.len(), 3);
        assert_eq!(read[0].key, b"line_length_max");
        assert_eq!(read[0].value, Value::Integer(88));
        assert_eq!(read[1].value, Value::Boolean(true));

        let Value::String(text) = read[2].value else {
            panic!("the third value is a string")
        };

        assert_eq!(text.raw, b"../a.toml");
        assert!(!text.literal);
    }

    #[test]
    fn an_array_yields_its_strings() {
        let source = b"select = [\"ALL\", \"TS001\"]\n";
        let read = entries(source);

        assert_eq!(strings(&read[0].value), vec![&b"ALL"[..], &b"TS001"[..]]);
        assert!(!read[0].value.items().is_faulted());
    }

    #[test]
    fn an_array_spans_lines_and_carries_comments() {
        let source = b"select = [\n    \"ALL\", # every rule\n    \"TS001\",\n]\nafter = 1\n";
        let read = entries(source);

        assert_eq!(strings(&read[0].value), vec![&b"ALL"[..], &b"TS001"[..]]);
        assert_eq!(read[1].line, 5);
    }

    #[test]
    fn a_table_header_names_the_entries_under_it() {
        let source = b"[language.python]\nline_length_max = 88\n";
        let read = entries(source);

        assert_eq!(read[0].value, Value::Header);
        assert_eq!(read[0].table, b"language.python");
        assert_eq!(read[1].table, b"language.python");
        assert_eq!(read[1].key, b"line_length_max");
    }

    #[test]
    fn a_comment_is_skipped_and_lines_are_counted() {
        let source = b"# A note.\n\nline_length_max = 88\n";
        let read = entries(source);

        assert_eq!(read[0].line, 3);
    }

    #[test]
    fn an_unterminated_string_names_its_line() {
        let error = error_of(b"first = 1\nextend = \"open\nline_length_max = 88\n");

        assert_eq!(error.fault, Fault::StringUnterminated);
        assert_eq!(error.line, 2);
    }

    #[test]
    fn a_missing_value_is_an_error() {
        assert_eq!(error_of(b"line_length_max\n").fault, Fault::ValueExpected);
        assert_eq!(error_of(b"line_length_max =\n").fault, Fault::ValueExpected);
    }

    #[test]
    fn a_bad_number_and_a_bare_word_are_told_apart() {
        assert_eq!(error_of(b"width = 1__0\n").fault, Fault::NumberInvalid);
        assert_eq!(error_of(b"width = 12abc\n").fault, Fault::NumberInvalid);
        assert_eq!(error_of(b"width = maybe\n").fault, Fault::ValueUnreadable);
    }

    #[test]
    fn an_underscore_groups_digits() {
        let read = entries(b"width = 1_000\n");

        assert_eq!(read[0].value, Value::Integer(1_000));
    }

    #[test]
    fn a_quoted_key_reads() {
        let source = b"[per-file-ignores]\n\"tests/*\" = [\"TS004\"]\n";
        let read = entries(source);

        assert_eq!(read[1].key, b"\"tests/*\"");
        assert_eq!(Segments::of(read[1].key).next(), Some(&b"tests/*"[..]));
    }

    #[test]
    fn a_dotted_key_keeps_its_segments() {
        let read = entries(b"lint.per-file-ignores.\"a/*\" = 1\n");
        let segments: Vec<&[u8]> = Segments::of(read[0].key).collect();

        assert_eq!(segments, vec![&b"lint"[..], &b"per-file-ignores"[..], &b"a/*"[..]]);
    }

    #[test]
    fn a_key_with_too_many_segments_is_refused() {
        assert_eq!(error_of(b"a.b.c.d.e.f.g.h.i = 1\n").fault, Fault::KeyExpected);
    }

    #[test]
    fn an_inline_table_yields_its_pairs() {
        let read = entries(b"tool = { name = \"x\", on = true, rows = [1, 2] }\n");
        let mut pairs = read[0].value.pairs();
        let (first, name) = pairs.next().expect("the first pair");

        assert_eq!(first, b"name");
        assert!(matches!(name, Value::String(text) if text.raw == b"x"));

        let (second, on) = pairs.next().expect("the second pair");

        assert_eq!(second, b"on");
        assert_eq!(on, Value::Boolean(true));

        let (third, held) = pairs.next().expect("the third pair");

        assert_eq!(third, b"rows");

        let rows: Vec<Value<'_>> = held.items().collect();

        assert_eq!(rows, vec![Value::Integer(1), Value::Integer(2)]);
        assert!(pairs.next().is_none());
        assert!(!pairs.is_faulted());
    }

    #[test]
    fn a_broken_inline_table_marks_its_pairs_faulted() {
        let read = entries(b"tool = { name \"x\" }\n");
        let mut pairs = read[0].value.pairs();

        assert!(pairs.next().is_none());
        assert!(pairs.is_faulted());
        assert_eq!(error_of(b"tool = { name = 1\n").fault, Fault::InlineTableUnterminated);
    }

    #[test]
    fn trailing_text_after_a_value_is_an_error() {
        let error = error_of(b"width = 1 extra\n");

        assert_eq!(error.fault, Fault::TrailingText);
        assert_eq!(error.column, 11);
    }

    #[test]
    fn an_unclosed_table_header_is_an_error() {
        assert_eq!(error_of(b"[lint\nwidth = 1\n").fault, Fault::TableUnterminated);
        assert_eq!(error_of(b"[lint] extra\n").fault, Fault::TrailingText);
    }

    #[test]
    fn a_quoted_header_may_hold_a_bracket() {
        let read = entries(b"[per-file.\"a]b\"]\nx = 1\n");

        assert_eq!(read[0].table, b"per-file.\"a]b\"");
    }

    #[test]
    fn a_literal_string_keeps_its_backslashes_and_a_basic_one_unescapes() {
        let read = entries(b"a = 'C:\\\\x'\nb = \"tab\\tnew\\nquote\\\" \\u00e9\"\n");
        let mut out = [0_u8; 32];

        let Value::String(literal) = read[0].value else {
            panic!("a is a string")
        };

        let written = literal.write_into(&mut out).expect("the literal fits");

        assert_eq!(&out[..written], b"C:\\\\x");

        let Value::String(basic) = read[1].value else {
            panic!("b is a string")
        };

        let unescaped = basic.write_into(&mut out).expect("the escapes fit");

        assert_eq!(&out[..unescaped], "tab\tnew\nquote\" \u{e9}".as_bytes());
    }

    #[test]
    fn a_triple_quoted_string_spans_lines() {
        let read = entries(b"a = \"\"\"one\ntwo\"\"\"\nb = 1\n");

        let Value::String(text) = read[0].value else {
            panic!("a is a string")
        };

        assert_eq!(text.raw, b"one\ntwo");
        assert_eq!(read[1].line, 3);
    }

    #[test]
    fn a_bad_escape_refuses_to_write() {
        let read = entries(b"a = \"\\q\"\n");
        let mut out = [0_u8; 8];

        let Value::String(text) = read[0].value else {
            panic!("a is a string")
        };

        assert!(text.write_into(&mut out).is_none());
    }

    #[test]
    fn a_faulted_line_is_skipped_and_reading_resumes() {
        let source = b"bad =\ngood = 1\n";
        let mut reader = Reader::new(source);

        assert!(reader.read().expect("the first line").is_err());

        let entry = reader.read().expect("the second line").expect("it parses");

        assert_eq!(entry.key, b"good");
        assert_eq!(entry.line, 2);
        assert!(reader.read().is_none());
    }

    #[test]
    fn corrupt_input_never_panics() {
        let mut random = crate::bounded::Random::new(0x9E37_79B9_7F4A_7C15);

        for _ in 0..2_048 {
            let length = random.below(64) as usize;
            let mut source = Vec::with_capacity(length);

            for _ in 0..length {
                source.push(u8::try_from(random.below(128)).expect("a byte"));
            }

            let mut reader = Reader::new(&source);
            let mut steps = 0;

            while let Some(entry) = reader.read() {
                if let Ok(held) = entry {
                    for item in held.value.items() {
                        let _ = item.items().count();
                    }

                    let _ = held.value.pairs().count();
                }

                steps += 1;

                assert!(steps <= length + 1, "{source:?}");
            }
        }
    }
}
