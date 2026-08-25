use crate::bounded::{BoundedVec, Buffer, Bytes as _, Span, count_of};

pub const FIELD_COUNT_MAX_DEFAULT: u32 = 1 << 8;
const CONVERSIONS: &[u8] = b"diouxXeEfFgGcrsa%";
const PREFIX_LENGTH_MAX: usize = 2;

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct Prefix {
    pub bytes: bool,
    pub format: bool,
    pub raw: bool,
    pub template: bool,
    pub unicode: bool,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Quote {
    pub byte: u8,
    pub triple: bool,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Shape {
    pub content: Span,
    pub prefix: Prefix,
    pub quote: Quote,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Number {
    Complex,
    Float,
    Integer(u64),
    Overflow,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Outcome {
    Complete,
    Malformed { at: u32 },
    Overflow,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct PercentField {
    pub conversion: u8,
    pub key: Span,
    pub precision_star: bool,
    pub span: Span,
    pub width_star: bool,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum FieldName {
    Auto,
    Keyword(Span),
    Positional(u32),
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct FormatField {
    pub conversion: u8,
    pub name: FieldName,
    pub span: Span,
    pub specification: Span,
}

impl Outcome {
    pub const fn is_complete(self) -> bool {
        matches!(self, Self::Complete)
    }
}

pub fn shape_of(token: &[u8], offset: u32) -> Option<Shape> {
    let prefix_end = prefix_end_of(token)?;
    let quote = quote_of(&token[prefix_end..])?;
    let width = if quote.triple { 3 } else { 1 };
    let opening = prefix_end + width;
    let closing = token.len().checked_sub(width)?;

    if closing < opening || token[closing..] != token[prefix_end..opening] {
        return None;
    }

    Some(Shape {
        content: Span {
            length: count_of(closing - opening),
            offset: offset + count_of(opening),
        },
        prefix: prefix_of(token),
        quote,
    })
}

pub fn prefix_of(token: &[u8]) -> Prefix {
    let mut found = Prefix::default();

    let Some(end) = prefix_end_of(token) else {
        return found;
    };

    for byte in &token[..end] {
        let lower = byte.to_ascii_lowercase();

        found.bytes |= lower == b'b';
        found.format |= lower == b'f';
        found.raw |= lower == b'r';
        found.template |= lower == b't';
        found.unicode |= lower == b'u';
    }

    found
}

pub fn decode(token: &[u8], out: &mut Buffer) -> Outcome {
    let Some(shape) = shape_of(token, 0) else {
        return Outcome::Malformed { at: 0 };
    };

    let content = &token[shape.content.range()];
    let base = shape.content.offset;

    if shape.prefix.raw {
        return push_or_overflow(out.push_bytes(content));
    }

    let mut offset = 0;

    while offset < content.len() {
        if content[offset] != b'\\' {
            if !out.push_bytes(&content[offset..=offset]) {
                return Outcome::Overflow;
            }

            offset += 1;

            continue;
        }

        match escape_of(content, offset, shape.prefix.bytes, out) {
            Escape::Malformed => {
                return Outcome::Malformed {
                    at: base + count_of(offset),
                };
            }
            Escape::Overflow => return Outcome::Overflow,
            Escape::Read(next) => offset = next,
        }
    }

    Outcome::Complete
}

pub fn number_of(text: &[u8]) -> Number {
    assert!(!text.is_empty());

    if text[text.len() - 1].eq_ignore_ascii_case(&b'j') {
        return Number::Complex;
    }

    let radix = radix_of(text);

    if radix != 10 {
        return integer_of(&text[2..], radix);
    }

    if text.iter().any(|byte| matches!(*byte, b'.' | b'E' | b'e')) {
        return Number::Float;
    }

    integer_of(text, 10)
}

pub fn percent_fields(template: &[u8], offset: u32, out: &mut BoundedVec<PercentField>) -> Outcome {
    let mut index = 0;

    while index < template.len() {
        if template[index] != b'%' {
            index += 1;

            continue;
        }

        if template.get(index + 1) == Some(&b'%') {
            index += 2;

            continue;
        }

        match percent_field(template, index, offset, out) {
            Field::Malformed => {
                return Outcome::Malformed {
                    at: offset + count_of(index),
                };
            }
            Field::Overflow => return Outcome::Overflow,
            Field::Read(next) => index = next,
        }
    }

    Outcome::Complete
}

pub fn format_fields(template: &[u8], offset: u32, out: &mut BoundedVec<FormatField>) -> Outcome {
    let mut index = 0;

    while index < template.len() {
        let byte = template[index];

        if byte == b'}' {
            if template.get(index + 1) != Some(&b'}') {
                return Outcome::Malformed {
                    at: offset + count_of(index),
                };
            }

            index += 2;

            continue;
        }

        if byte != b'{' {
            index += 1;

            continue;
        }

        if template.get(index + 1) == Some(&b'{') {
            index += 2;

            continue;
        }

        match format_field(template, index, offset, out) {
            Field::Malformed => {
                return Outcome::Malformed {
                    at: offset + count_of(index),
                };
            }
            Field::Overflow => return Outcome::Overflow,
            Field::Read(next) => index = next,
        }
    }

    Outcome::Complete
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum Escape {
    Malformed,
    Overflow,
    Read(usize),
}

type Field = Escape;

const fn push_or_overflow(pushed: bool) -> Outcome {
    if pushed {
        Outcome::Complete
    } else {
        Outcome::Overflow
    }
}

const fn read_or_overflow(pushed: bool, next: usize) -> Escape {
    if pushed {
        Escape::Read(next)
    } else {
        Escape::Overflow
    }
}

fn prefix_end_of(token: &[u8]) -> Option<usize> {
    let end = token
        .iter()
        .take(PREFIX_LENGTH_MAX + 1)
        .position(|byte| matches!(*byte, b'"' | b'\''))?;

    if end > PREFIX_LENGTH_MAX {
        return None;
    }

    let letters = &token[..end];

    if !letters.iter().all(|byte| is_prefix_letter(*byte)) {
        return None;
    }

    if let [head, tail] = letters {
        let first = head.to_ascii_lowercase();
        let second = tail.to_ascii_lowercase();

        let pairs = first == b'r' && matches!(second, b'b' | b'f' | b't')
            || second == b'r' && matches!(first, b'b' | b'f' | b't');

        if !pairs {
            return None;
        }
    }

    Some(end)
}

const fn is_prefix_letter(byte: u8) -> bool {
    matches!(
        byte,
        b'B' | b'F' | b'R' | b'T' | b'U' | b'b' | b'f' | b'r' | b't' | b'u'
    )
}

fn quote_of(bytes: &[u8]) -> Option<Quote> {
    let byte = *bytes.first()?;

    if !matches!(byte, b'"' | b'\'') {
        return None;
    }

    let triple = bytes.len() >= 3 && bytes[1..3] == [byte, byte];

    if triple && bytes.len() < 6 {
        return None;
    }

    Some(Quote { byte, triple })
}

fn escape_of(content: &[u8], offset: usize, bytes: bool, out: &mut Buffer) -> Escape {
    let Some(byte) = content.get(offset + 1).copied() else {
        return read_or_overflow(out.push_bytes(b"\\"), offset + 1);
    };

    if byte == b'\n' {
        return Escape::Read(offset + 2);
    }

    if byte == b'\r' {
        let paired = usize::from(content.get(offset + 2) == Some(&b'\n'));

        return Escape::Read(offset + 2 + paired);
    }

    if let Some(mapped) = simple_escape_of(byte) {
        return read_or_overflow(out.push_bytes(&[mapped]), offset + 2);
    }

    if matches!(byte, b'0'..=b'7') {
        return octal_escape(content, offset, bytes, out);
    }

    if byte == b'x' {
        return hex_escape(content, offset, 2, bytes, out);
    }

    if !bytes && byte == b'N' {
        return Escape::Malformed;
    }

    if !bytes && matches!(byte, b'U' | b'u') {
        let width = if byte == b'u' { 4 } else { 8 };

        return hex_escape(content, offset, width, bytes, out);
    }

    read_or_overflow(out.push_bytes(&content[offset..offset + 2]), offset + 2)
}

const fn simple_escape_of(byte: u8) -> Option<u8> {
    match byte {
        b'"' => Some(b'"'),
        b'\'' => Some(b'\''),
        b'\\' => Some(b'\\'),
        b'a' => Some(0x07),
        b'b' => Some(0x08),
        b'f' => Some(0x0C),
        b'n' => Some(b'\n'),
        b'r' => Some(b'\r'),
        b't' => Some(b'\t'),
        b'v' => Some(0x0B),
        _ => None,
    }
}

fn octal_escape(content: &[u8], offset: usize, bytes: bool, out: &mut Buffer) -> Escape {
    let mut value = 0_u32;
    let mut read = 0;

    while read < 3 {
        let Some(byte) = content.get(offset + 1 + read).copied() else {
            break;
        };

        if !matches!(byte, b'0'..=b'7') {
            break;
        }

        value = value * 8 + u32::from(byte - b'0');
        read += 1;
    }

    push_code_point(value, bytes, out, offset + 1 + read)
}

fn hex_escape(
    content: &[u8],
    offset: usize,
    width: usize,
    bytes: bool,
    out: &mut Buffer,
) -> Escape {
    let end = offset + 2 + width;

    if end > content.len() {
        return Escape::Malformed;
    }

    let mut value = 0_u32;

    for byte in &content[offset + 2..end] {
        let Some(digit) = char::from(*byte).to_digit(16) else {
            return Escape::Malformed;
        };

        value = value * 16 + digit;
    }

    push_code_point(value, bytes, out, end)
}

fn push_code_point(value: u32, bytes: bool, out: &mut Buffer, next: usize) -> Escape {
    if bytes || value < 0x80 {
        let Ok(byte) = u8::try_from(value) else {
            return Escape::Malformed;
        };

        return read_or_overflow(out.push_bytes(&[byte]), next);
    }

    if let Some(held) = char::from_u32(value) {
        let mut encoded = [0_u8; 4];

        return read_or_overflow(
            out.push_bytes(held.encode_utf8(&mut encoded).as_bytes()),
            next,
        );
    }

    if !(0xD800..=0xDFFF).contains(&value) {
        return Escape::Malformed;
    }

    let Ok(lead) = u8::try_from(0xE0 | (value >> 12)) else {
        return Escape::Malformed;
    };

    let Ok(middle) = u8::try_from(0x80 | ((value >> 6) & 0x3F)) else {
        return Escape::Malformed;
    };

    let Ok(trail) = u8::try_from(0x80 | (value & 0x3F)) else {
        return Escape::Malformed;
    };

    read_or_overflow(out.push_bytes(&[lead, middle, trail]), next)
}

fn radix_of(text: &[u8]) -> u32 {
    let [head, marker, ..] = text else {
        return 10;
    };

    if *head != b'0' {
        return 10;
    }

    match *marker {
        b'B' | b'b' => 2,
        b'O' | b'o' => 8,
        b'X' | b'x' => 16,
        _ => 10,
    }
}

fn integer_of(text: &[u8], radix: u32) -> Number {
    let mut value = 0_u64;
    let mut digits = 0_u32;

    for byte in text {
        if *byte == b'_' {
            continue;
        }

        let Some(digit) = char::from(*byte).to_digit(radix) else {
            return Number::Overflow;
        };

        let Some(scaled) = value.checked_mul(u64::from(radix)) else {
            return Number::Overflow;
        };

        let Some(summed) = scaled.checked_add(u64::from(digit)) else {
            return Number::Overflow;
        };

        value = summed;
        digits += 1;
    }

    if digits == 0 {
        return Number::Overflow;
    }

    Number::Integer(value)
}

fn percent_field(
    template: &[u8],
    start: usize,
    offset: u32,
    out: &mut BoundedVec<PercentField>,
) -> Field {
    let mut index = start + 1;

    let Some(key) = percent_key(template, &mut index, offset) else {
        return Field::Malformed;
    };

    while matches!(template.get(index), Some(b'#' | b' ' | b'+' | b'-' | b'0')) {
        index += 1;
    }

    let width_star = percent_width(template, &mut index);

    let precision_star = if template.get(index) == Some(&b'.') {
        index += 1;

        percent_width(template, &mut index)
    } else {
        false
    };

    while matches!(template.get(index), Some(b'L' | b'h' | b'l')) {
        index += 1;
    }

    let Some(conversion) = template.get(index).copied() else {
        return Field::Malformed;
    };

    if !CONVERSIONS.contains(&conversion) {
        return Field::Malformed;
    }

    let pushed = out.push(PercentField {
        conversion,
        key,
        precision_star,
        span: Span {
            length: count_of(index + 1 - start),
            offset: offset + count_of(start),
        },
        width_star,
    });

    read_or_overflow(pushed, index + 1)
}

fn percent_key(template: &[u8], index: &mut usize, offset: u32) -> Option<Span> {
    if template.get(*index) != Some(&b'(') {
        return Some(Span::EMPTY);
    }

    let start = *index + 1;
    let mut end = start;
    let mut depth = 1_u32;

    while end < template.len() {
        let byte = template[end];

        if byte == b'(' {
            depth += 1;
        }

        if byte == b')' {
            depth -= 1;
        }

        if depth == 0 {
            break;
        }

        end += 1;
    }

    if depth > 0 {
        return None;
    }

    *index = end + 1;

    Some(Span {
        length: count_of(end - start),
        offset: offset + count_of(start),
    })
}

fn percent_width(template: &[u8], index: &mut usize) -> bool {
    if template.get(*index) == Some(&b'*') {
        *index += 1;

        return true;
    }

    while template.get(*index).is_some_and(u8::is_ascii_digit) {
        *index += 1;
    }

    false
}

fn format_field(
    template: &[u8],
    start: usize,
    offset: u32,
    out: &mut BoundedVec<FormatField>,
) -> Field {
    let (field, next) = match field_of(template, start, offset, true) {
        Ok(read) => read,
        Err(failed) => return failed,
    };

    let specification = field.specification;

    if !out.push(field) {
        return Field::Overflow;
    }

    if specification.length == 0 {
        return Field::Read(next);
    }

    let base = (specification.offset - offset) as usize;
    let end = base + specification.length as usize;

    debug_assert!(start < base);
    debug_assert!(end < next);

    match specification_fields(template, base, end, offset, out) {
        Field::Malformed => Field::Malformed,
        Field::Overflow => Field::Overflow,
        Field::Read(_) => Field::Read(next),
    }
}

fn format_field_nested(
    template: &[u8],
    start: usize,
    offset: u32,
    out: &mut BoundedVec<FormatField>,
) -> Field {
    let (field, next) = match field_of(template, start, offset, false) {
        Ok(read) => read,
        Err(failed) => return failed,
    };

    debug_assert!(start < next);

    read_or_overflow(out.push(field), next)
}

fn field_of(
    template: &[u8],
    start: usize,
    offset: u32,
    nested: bool,
) -> Result<(FormatField, usize), Field> {
    debug_assert_eq!(template.get(start), Some(&b'{'));

    let Some(mut index) = field_name_end(template, start + 1) else {
        return Err(Field::Malformed);
    };

    let Some(name) = field_name_of(&template[start + 1..index], offset, start + 1) else {
        return Err(Field::Overflow);
    };

    let mut conversion = 0;

    if template.get(index) == Some(&b'!') {
        let Some(held) = template.get(index + 1).copied() else {
            return Err(Field::Malformed);
        };

        if !matches!(held, b'a' | b'r' | b's') {
            return Err(Field::Malformed);
        }

        conversion = held;
        index += 2;
    }

    let specification = if template.get(index) == Some(&b':') {
        let opened = index + 1;

        let Some(closed) = specification_end(template, opened, nested) else {
            return Err(Field::Malformed);
        };

        index = closed;

        Span {
            length: count_of(index - opened),
            offset: offset + count_of(opened),
        }
    } else {
        Span::EMPTY
    };

    if template.get(index) != Some(&b'}') {
        return Err(Field::Malformed);
    }

    debug_assert!(start < index);

    Ok((
        FormatField {
            conversion,
            name,
            span: Span {
                length: count_of(index + 1 - start),
                offset: offset + count_of(start),
            },
            specification,
        },
        index + 1,
    ))
}

fn specification_fields(
    template: &[u8],
    start: usize,
    end: usize,
    offset: u32,
    out: &mut BoundedVec<FormatField>,
) -> Field {
    debug_assert!(start <= end);
    debug_assert!(end <= template.len());

    let mut index = start;

    while index < end {
        let doubled = template.get(index + 1) == Some(&template[index]);

        if matches!(template[index], b'{' | b'}') && doubled {
            index += 2;

            continue;
        }

        if template[index] != b'{' {
            index += 1;

            continue;
        }

        match format_field_nested(template, index, offset, out) {
            Field::Malformed => return Field::Malformed,
            Field::Overflow => return Field::Overflow,
            Field::Read(next) => index = next,
        }
    }

    Field::Read(end)
}

fn field_name_end(template: &[u8], start: usize) -> Option<usize> {
    let mut index = start;
    let mut depth = 0_u32;

    while index < template.len() {
        let byte = template[index];

        if byte == b'{' {
            return None;
        }

        if byte == b'[' {
            depth += 1;
        }

        if byte == b']' {
            depth = depth.saturating_sub(1);
        }

        if depth == 0 && matches!(byte, b'!' | b':' | b'}') {
            return Some(index);
        }

        index += 1;
    }

    Some(index)
}

fn field_name_of(bytes: &[u8], offset: u32, at: usize) -> Option<FieldName> {
    let head = bytes
        .iter()
        .position(|byte| matches!(*byte, b'.' | b'['))
        .unwrap_or(bytes.len());

    if head == 0 {
        return Some(FieldName::Auto);
    }

    if bytes[..head].iter().all(u8::is_ascii_digit) {
        let mut value = 0_u32;

        for byte in &bytes[..head] {
            value = value.checked_mul(10)?.checked_add(u32::from(byte - b'0'))?;
        }

        return Some(FieldName::Positional(value));
    }

    Some(FieldName::Keyword(Span {
        length: count_of(head),
        offset: offset + count_of(at),
    }))
}

fn specification_end(template: &[u8], start: usize, nested: bool) -> Option<usize> {
    let mut index = start;
    let mut depth = 0_u32;

    while index < template.len() {
        let byte = template[index];
        let doubled = template.get(index + 1) == Some(&byte);

        if matches!(byte, b'{' | b'}') && doubled && depth == 0 {
            index += 2;

            continue;
        }

        if byte == b'{' {
            depth += 1;

            if depth > 1 || !nested {
                return None;
            }
        }

        if byte == b'}' {
            if depth == 0 {
                return Some(index);
            }

            depth -= 1;
        }

        index += 1;
    }

    None
}

#[cfg(test)]
mod tests {
    use super::*;

    fn decoded(token: &[u8]) -> Option<Vec<u8>> {
        let mut out = Buffer::reserve(1 << 8);

        if decode(token, &mut out) != Outcome::Complete {
            return None;
        }

        Some(out.as_bytes().to_vec())
    }

    fn percents(template: &[u8]) -> Option<Vec<PercentField>> {
        let mut out = BoundedVec::reserve(FIELD_COUNT_MAX_DEFAULT);

        if percent_fields(template, 0, &mut out) != Outcome::Complete {
            return None;
        }

        Some(out.iter().copied().collect())
    }

    fn formats(template: &[u8]) -> Option<Vec<FormatField>> {
        let mut out = BoundedVec::reserve(FIELD_COUNT_MAX_DEFAULT);

        if format_fields(template, 0, &mut out) != Outcome::Complete {
            return None;
        }

        Some(out.iter().copied().collect())
    }

    #[test]
    fn a_plain_string_reads_its_quote_and_its_content() {
        let held = shape_of(b"'text'", 10).expect("a shape");

        assert_eq!(held.quote.byte, b'\'');
        assert!(!held.quote.triple);
        assert_eq!(held.content.offset, 11);
        assert_eq!(held.content.length, 4);
        assert_eq!(held.prefix, Prefix::default());
    }

    #[test]
    fn a_triple_quoted_string_reads_three_quotes_a_side() {
        let held = shape_of(b"\"\"\"text\"\"\"", 0).expect("a shape");

        assert!(held.quote.triple);
        assert_eq!(held.content.offset, 3);
        assert_eq!(held.content.length, 4);
    }

    #[test]
    fn an_empty_string_reads_as_a_shape_with_no_content() {
        assert_eq!(shape_of(b"''", 0).expect("a shape").content.length, 0);
        assert_eq!(shape_of(b"''''''", 0).expect("a shape").content.length, 0);
    }

    #[test]
    fn every_prefix_letter_reads_into_its_own_flag() {
        assert!(shape_of(b"rb'text'", 0).expect("a shape").prefix.bytes);
        assert!(shape_of(b"rb'text'", 0).expect("a shape").prefix.raw);
        assert!(shape_of(b"F'text'", 0).expect("a shape").prefix.format);
        assert!(shape_of(b"t'text'", 0).expect("a shape").prefix.template);
        assert!(shape_of(b"U'text'", 0).expect("a shape").prefix.unicode);
    }

    #[test]
    fn a_prefix_of_three_letters_is_no_prefix_python_spells() {
        assert!(shape_of(b"rbu'text'", 0).is_none());
        assert!(shape_of(b"q'text'", 0).is_none());
        assert!(shape_of(b"text", 0).is_none());
    }

    #[test]
    fn a_quote_that_never_closes_reads_as_no_shape() {
        assert!(shape_of(b"'text", 0).is_none());
        assert!(shape_of(b"'text\"", 0).is_none());
        assert!(shape_of(b"'''", 0).is_none());
        assert!(shape_of(b"''''", 0).is_none());
        assert!(shape_of(b"'''x''", 0).is_none());
    }

    #[test]
    fn a_raw_bytes_triple_reads_its_prefix_and_its_content() {
        let held = shape_of(b"rb'''x'''", 4).expect("a shape");

        assert!(held.prefix.raw);
        assert!(held.prefix.bytes);
        assert!(held.quote.triple);
        assert_eq!(held.content.offset, 9);
        assert_eq!(held.content.length, 1);
    }

    #[test]
    fn a_pair_python_never_spells_is_no_prefix() {
        assert!(shape_of(b"bu'text'", 0).is_none());
        assert!(shape_of(b"tb'text'", 0).is_none());
        assert!(shape_of(b"ur'text'", 0).is_none());
        assert!(shape_of(b"rr'text'", 0).is_none());
        assert!(shape_of(b"Rt'text'", 0).is_some());
        assert!(shape_of(b"fR'text'", 0).is_some());
    }

    #[test]
    fn every_escape_decodes_the_way_cpython_encodes_it() {
        assert_eq!(
            decoded(b"\"a\\x41\\u00e9\\101\\n\""),
            Some(b"aA\xc3\xa9A\n".to_vec())
        );

        assert_eq!(decoded(b"b\"\\x41\\u00e9\""), Some(b"A\\u00e9".to_vec()));
        assert_eq!(decoded(b"\"\\377\""), Some(b"\xc3\xbf".to_vec()));
        assert_eq!(decoded(b"b\"\\377\""), Some(b"\xff".to_vec()));
        assert_eq!(decoded(b"\"\\xe9\""), Some(b"\xc3\xa9".to_vec()));
        assert_eq!(decoded(b"b\"\\xe9\""), Some(b"\xe9".to_vec()));
    }

    #[test]
    fn each_single_byte_escape_maps_to_its_own_byte() {
        assert_eq!(
            decoded(b"\"\\a\\b\\f\\n\\r\\t\\v\\\\\\'\\\"\""),
            Some(b"\x07\x08\x0c\n\r\t\x0b\\'\"".to_vec())
        );
    }

    #[test]
    fn an_unknown_escape_keeps_its_backslash_the_way_cpython_keeps_it() {
        assert_eq!(decoded(b"\"\\q\""), Some(b"\\q".to_vec()));
        assert_eq!(decoded(b"b\"\\q\""), Some(b"\\q".to_vec()));
        assert_eq!(decoded(b"b\"\\N{X}\""), Some(b"\\N{X}".to_vec()));
    }

    #[test]
    fn a_named_escape_is_the_one_form_the_decoder_refuses() {
        assert_eq!(decoded(b"\"\\N{DASH}\""), None);
    }

    #[test]
    fn a_malformed_hexadecimal_escape_refuses_rather_than_guesses() {
        assert_eq!(decoded(b"\"\\x4\""), None);
        assert_eq!(decoded(b"\"\\xzz\""), None);
        assert_eq!(decoded(b"\"\\u00e\""), None);
    }

    #[test]
    fn a_raw_string_copies_its_content_byte_for_byte() {
        assert_eq!(decoded(b"r\"a\\x41\\n\""), Some(b"a\\x41\\n".to_vec()));
    }

    #[test]
    fn a_backslash_before_a_newline_drops_both() {
        let mut source = Vec::from(b"\"a\\".as_slice());

        source.extend_from_slice(b"\nb\"");

        assert_eq!(decoded(&source), Some(b"ab".to_vec()));

        let mut carriage = Vec::from(b"\"a\\".as_slice());

        carriage.extend_from_slice(b"\r\nb\"");

        assert_eq!(decoded(&carriage), Some(b"ab".to_vec()));
    }

    #[test]
    fn a_buffer_that_fills_reports_the_decode_incomplete() {
        let mut out = Buffer::reserve(2);

        assert_eq!(decode(b"\"abcd\"", &mut out), Outcome::Overflow);

        let mut narrow = Buffer::reserve(1);

        assert_eq!(decode(b"\"\\u00e9\"", &mut narrow), Outcome::Overflow);

        assert_eq!(
            decode(b"\"\\N{X}\"", &mut narrow),
            Outcome::Malformed { at: 1 }
        );
    }

    #[test]
    fn a_lone_surrogate_writes_the_bytes_wtf8_gives_it() {
        assert_eq!(decoded(b"\"\\ud800\""), Some(b"\xed\xa0\x80".to_vec()));
        assert_eq!(decoded(b"\"\\U00000041\""), Some(b"A".to_vec()));
        assert_eq!(decoded(b"\"\\U00110000\""), None);
    }

    #[test]
    fn a_digit_past_seven_is_no_octal_escape_at_all() {
        assert_eq!(decoded(b"\"\\8\\9\""), Some(b"\\8\\9".to_vec()));
        assert_eq!(decoded(b"\"\\18\""), Some(b"\x018".to_vec()));
    }

    #[test]
    fn a_number_reads_its_radix_the_way_cpython_reads_it() {
        assert_eq!(number_of(b"0x_ff"), Number::Integer(255));
        assert_eq!(number_of(b"1_000"), Number::Integer(1000));
        assert_eq!(number_of(b"0o17"), Number::Integer(15));
        assert_eq!(number_of(b"0b1010"), Number::Integer(10));
        assert_eq!(number_of(b"0"), Number::Integer(0));
    }

    #[test]
    fn a_radix_with_no_digit_after_it_spells_no_value() {
        assert_eq!(number_of(b"0x"), Number::Overflow);
        assert_eq!(number_of(b"0b_"), Number::Overflow);
    }

    #[test]
    fn a_float_and_a_complex_read_as_themselves() {
        assert_eq!(number_of(b"1.5"), Number::Float);
        assert_eq!(number_of(b"1e10"), Number::Float);
        assert_eq!(number_of(b"1E10"), Number::Float);
        assert_eq!(number_of(b"1j"), Number::Complex);
        assert_eq!(number_of(b"1.5J"), Number::Complex);
    }

    #[test]
    fn a_hexadecimal_e_is_a_digit_rather_than_an_exponent() {
        assert_eq!(number_of(b"0x1e5"), Number::Integer(485));
    }

    #[test]
    fn a_number_past_the_word_reads_as_an_overflow() {
        assert_eq!(
            number_of(b"18446744073709551615"),
            Number::Integer(u64::MAX)
        );

        assert_eq!(number_of(b"18446744073709551616"), Number::Overflow);
    }

    #[test]
    fn a_percent_template_reads_one_field_per_conversion() {
        let held = percents(b"%(name)s %*d %.2f %%").expect("fields");

        assert_eq!(held.len(), 3);
        assert_eq!(held[0].conversion, b's');
        assert_eq!(held[0].key.offset, 2);
        assert_eq!(held[0].key.length, 4);
        assert_eq!(held[0].span.offset, 0);
        assert_eq!(held[0].span.length, 8);
        assert!(held[1].width_star);
        assert_eq!(held[1].conversion, b'd');
        assert!(!held[2].width_star);
        assert!(!held[2].precision_star);
        assert_eq!(held[2].conversion, b'f');
    }

    #[test]
    fn a_starred_precision_reads_as_a_star() {
        let held = percents(b"%.*f").expect("fields");

        assert!(held[0].precision_star);
        assert!(!held[0].width_star);
    }

    #[test]
    fn a_percent_template_python_refuses_names_where() {
        let mut out = BoundedVec::reserve(FIELD_COUNT_MAX_DEFAULT);

        assert_eq!(
            percent_fields(b"ab %z", 10, &mut out),
            Outcome::Malformed { at: 13 }
        );

        assert_eq!(
            percent_fields(b"%(name", 0, &mut out),
            Outcome::Malformed { at: 0 }
        );
    }

    #[test]
    fn a_key_balances_its_own_parentheses_the_way_cpython_counts_them() {
        let held = percents(b"%(a(b))s").expect("fields");

        assert_eq!(held.len(), 1);
        assert_eq!(held[0].key.offset, 2);
        assert_eq!(held[0].key.length, 4);
        assert_eq!(percents(b"%(a(b)s"), None);
    }

    #[test]
    fn every_flag_and_length_modifier_steps_to_the_conversion() {
        let held = percents(b"%-05.2ld").expect("fields");

        assert_eq!(held.len(), 1);
        assert_eq!(held[0].conversion, b'd');
        assert_eq!(held[0].span.length, 8);
        assert!(!held[0].width_star);
        assert!(!held[0].precision_star);
    }

    #[test]
    fn a_full_table_is_an_overflow_rather_than_a_malformed_template() {
        let mut percent = BoundedVec::reserve(1);

        assert_eq!(percent_fields(b"%s%s", 0, &mut percent), Outcome::Overflow);

        let mut format = BoundedVec::reserve(1);

        assert_eq!(format_fields(b"{}{}", 0, &mut format), Outcome::Overflow);
        assert_eq!(format.count(), 1);
    }

    #[test]
    fn a_format_template_reads_its_names_the_way_cpython_reads_them() {
        let held = formats(b"{} {0} {name!r:>{w}} {{x}}").expect("fields");

        assert_eq!(held.len(), 4);
        assert_eq!(held[0].name, FieldName::Auto);
        assert_eq!(held[1].name, FieldName::Positional(0));
        assert_eq!(held[2].conversion, b'r');
        assert_eq!(held[2].specification.offset, 15);
        assert_eq!(held[2].specification.length, 4);

        let FieldName::Keyword(name) = held[2].name else {
            panic!("the third field names a keyword");
        };

        assert_eq!(name.offset, 8);
        assert_eq!(name.length, 4);

        let FieldName::Keyword(width) = held[3].name else {
            panic!("the nested field names a keyword");
        };

        assert_eq!(width.offset, 17);
        assert_eq!(width.length, 1);
    }

    #[test]
    fn a_colon_inside_an_index_closes_no_specification() {
        let held = formats(b"{a[b:c]}").expect("fields");

        assert_eq!(held.len(), 1);
        assert_eq!(held[0].specification, Span::EMPTY);

        let FieldName::Keyword(name) = held[0].name else {
            panic!("the field names a keyword");
        };

        assert_eq!(name.length, 1);
    }

    #[test]
    fn a_name_opening_with_an_index_or_an_attribute_is_automatic() {
        assert_eq!(formats(b"{[0]}").expect("fields")[0].name, FieldName::Auto);

        assert_eq!(
            formats(b"{.attr}").expect("fields")[0].name,
            FieldName::Auto
        );
    }

    #[test]
    fn a_dotted_keyword_names_the_head_alone() {
        let held = formats(b"{0[1]!s:>{1}}").expect("fields");

        assert_eq!(held[0].name, FieldName::Positional(0));
        assert_eq!(held[0].conversion, b's');
    }

    #[test]
    fn a_format_template_python_refuses_names_where() {
        let mut out = BoundedVec::reserve(FIELD_COUNT_MAX_DEFAULT);

        assert_eq!(
            format_fields(b"{", 0, &mut out),
            Outcome::Malformed { at: 0 }
        );

        assert_eq!(
            format_fields(b"a}", 0, &mut out),
            Outcome::Malformed { at: 1 }
        );

        assert_eq!(formats(b"{a!z}"), None);
        assert_eq!(formats(b"{a{b}"), None);
        assert_eq!(formats(b"{:{:{}}}"), None);
    }

    #[test]
    fn a_doubled_brace_inside_a_specification_is_a_literal_one() {
        let held = formats(b"{a:{{b}}}").expect("fields");

        assert_eq!(held.len(), 1);
        assert_eq!(held[0].specification.length, 5);
    }

    #[test]
    fn a_field_nested_in_a_specification_consumes_an_argument_of_its_own() {
        let held = formats(b"{:{}}").expect("fields");

        assert_eq!(held.len(), 2);
        assert_eq!(held[0].span.length, 5);
        assert_eq!(held[1].span.offset, 2);
        assert_eq!(held[1].span.length, 2);
        assert_eq!(held[1].name, FieldName::Auto);

        let plan = formats(b"{0}{}{key.attr[0]!s:>{1}}").expect("fields");

        assert_eq!(plan.len(), 4);
        assert_eq!(plan[0].name, FieldName::Positional(0));
        assert_eq!(plan[1].name, FieldName::Auto);
        assert_eq!(plan[2].conversion, b's');
        assert_eq!(plan[2].specification.length, 4);
        assert_eq!(plan[3].name, FieldName::Positional(1));
    }

    #[test]
    fn a_positional_index_past_a_word_is_an_overflow_rather_than_a_guess() {
        let mut out = BoundedVec::reserve(FIELD_COUNT_MAX_DEFAULT);

        assert_eq!(
            format_fields(b"{4294967295}", 0, &mut out),
            Outcome::Complete
        );

        assert_eq!(
            format_fields(b"{4294967296}", 0, &mut out),
            Outcome::Overflow
        );
    }

    #[test]
    fn a_doubled_brace_carries_no_field() {
        assert_eq!(formats(b"{{}}").expect("fields").len(), 0);
    }
}
