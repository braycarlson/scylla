use crate::token::Punctuation;

pub const BYTE_ORDER_MARK: &[u8] = &[0xef, 0xbb, 0xbf];
pub const COMMENT_DEPTH_MAX: u32 = 64;
pub const DECIMAL_BYTES_MAX: usize = 20;
pub const GROUP_PEEL_MAX: u32 = 4;

pub fn mark_width(source: &[u8]) -> usize {
    usize::from(source.starts_with(BYTE_ORDER_MARK)) * BYTE_ORDER_MARK.len()
}

pub fn identifier_scan(source: &[u8], start: usize) -> usize {
    assert!(start < source.len());
    debug_assert_eq!(whitespace_width(source, start), 0);

    let mut offset = start;

    while offset < source.len() {
        let byte = source[offset];

        if byte < 0x80 {
            if CLASSES[byte as usize] & CLASS_IDENTIFIER_PART == 0 {
                break;
            }

            offset += 1;

            continue;
        }

        if whitespace_width(source, offset) > 0 {
            break;
        }

        offset += 1;
    }

    assert!(offset > start);

    offset
}

pub const CLASS_BLANK: u8 = 1 << 4;
pub const CLASS_IDENTIFIER_PART: u8 = 1 << 1;
pub const CLASS_WHITESPACE: u8 = 1 << 3;
pub static CLASSES: [u8; 256] = classes_build();

const fn classes_build() -> [u8; 256] {
    let mut table = [0_u8; 256];
    let mut count = 0;
    let mut value = 0_u8;

    while count < table.len() {
        let mut class = 0;

        if is_identifier_part(value) {
            class |= CLASS_IDENTIFIER_PART;
        }

        if value.is_ascii_whitespace() || value == VERTICAL_TAB {
            class |= CLASS_WHITESPACE;

            if value != b'\n' && value != b'\r' {
                class |= CLASS_BLANK;
            }
        }

        table[value as usize] = class;
        count += 1;
        value = value.wrapping_add(1);
    }

    assert!(count == table.len());

    table
}

pub const fn is_identifier_part(byte: u8) -> bool {
    byte.is_ascii_alphanumeric() || byte == b'_' || byte >= 0x80
}

pub const fn is_identifier_start(byte: u8) -> bool {
    byte.is_ascii_alphabetic() || byte == b'_' || byte >= 0x80
}

pub fn is_identifier_start_at(source: &[u8], offset: usize) -> bool {
    assert!(offset <= source.len());

    let Some(byte) = source.get(offset).copied() else {
        return false;
    };

    is_identifier_start(byte) && whitespace_width(source, offset) == 0
}

pub const VERTICAL_TAB: u8 = 0x0b;

pub fn whitespace_width(source: &[u8], offset: usize) -> usize {
    assert!(offset < source.len());

    let byte = source[offset];

    if byte < 0x80 {
        return usize::from(CLASSES[byte as usize] & CLASS_WHITESPACE != 0);
    }

    let next = source.get(offset + 1).copied().unwrap_or(0);
    let third = source.get(offset + 2).copied().unwrap_or(0);

    match (byte, next, third) {
        (0xc2, 0x85 | 0xa0, _) => 2,
        (0xe1, 0x9a, 0x80) => 3,
        (0xe2, 0x80, 0x80..=0x8a | 0xa8 | 0xa9 | 0xaf) => 3,
        (0xe2, 0x81, 0x9f) => 3,
        (0xe3, 0x80, 0x80) => 3,
        (0xef, 0xbb, 0xbf) => 3,
        _ => 0,
    }
}

pub fn whitespace_scan(source: &[u8], start: usize) -> usize {
    assert!(start <= source.len());

    let mut offset = start;

    while offset < source.len() {
        let byte = source[offset];

        if byte >= 0x80 {
            break;
        }

        if CLASSES[byte as usize] & CLASS_BLANK == 0 {
            break;
        }

        offset += 1;
    }

    if offset == start && start < source.len() {
        return start + whitespace_width(source, start);
    }

    assert!(offset <= source.len());

    offset
}

pub fn line_scan(source: &[u8], start: usize) -> usize {
    let mut offset = start;

    while offset < source.len() {
        if source[offset] == b'\n' {
            break;
        }

        offset += 1;
    }

    offset
}

pub fn line_start_of(source: &[u8], offset: usize) -> usize {
    let mut start = offset.min(source.len());

    while start > 0 && source[start - 1] != b'\n' {
        start -= 1;
    }

    assert!(start <= offset.min(source.len()));

    start
}

pub fn line_break_width(source: &[u8], offset: usize) -> usize {
    assert!(offset <= source.len());

    match source.get(offset).copied() {
        Some(b'\r') => 1 + usize::from(source.get(offset + 1) == Some(&b'\n')),
        Some(b'\n') => 1,
        _ => 0,
    }
}

pub fn line_scan_trimmed(source: &[u8], start: usize) -> usize {
    let end = line_scan(source, start);

    assert!(end >= start);

    if end > start && source[end - 1] == b'\r' {
        return end - 1;
    }

    end
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Numbers {
    pub dot_may_lead: bool,
    pub dot_may_trail: bool,
}

impl Numbers {
    pub const DEFAULT: Self = Self {
        dot_may_lead: false,
        dot_may_trail: false,
    };
    pub const ONE_SIDED: Self = Self {
        dot_may_lead: true,
        dot_may_trail: true,
    };
}

pub fn number_scan(source: &[u8], start: usize) -> usize {
    number_scan_bounded(source, start, Numbers::DEFAULT)
}

pub fn number_scan_bounded(source: &[u8], start: usize, numbers: Numbers) -> usize {
    assert!(start < source.len());
    assert!(source[start].is_ascii_digit() || numbers.dot_may_lead && source[start] == b'.');

    let hexadecimal = source[start] == b'0' && matches!(source.get(start + 1), Some(b'x' | b'X'));
    let mut offset = start + usize::from(source[start] == b'.');

    while offset < source.len() {
        let byte = source[offset];

        let exponent = if hexadecimal {
            matches!(byte, b'p' | b'P')
        } else {
            matches!(byte, b'e' | b'E')
        };

        let signed =
            exponent && offset + 1 < source.len() && matches!(source[offset + 1], b'+' | b'-');

        if signed {
            offset += 2;

            continue;
        }

        if !is_identifier_part(byte) && byte != b'.' {
            break;
        }

        if byte == b'.' && !fraction_follows(source, offset + 1, hexadecimal, numbers) {
            break;
        }

        offset += 1;
    }

    assert!(offset > start);

    offset
}

fn fraction_follows(source: &[u8], offset: usize, hexadecimal: bool, numbers: Numbers) -> bool {
    assert!(offset > 0);

    let Some(byte) = source.get(offset).copied() else {
        return numbers.dot_may_trail;
    };

    if byte.is_ascii_digit() || (hexadecimal && byte.is_ascii_hexdigit()) {
        return true;
    }

    numbers.dot_may_trail && byte != b'.'
}

pub fn punctuation_of(source: &[u8], start: usize) -> (Punctuation, usize) {
    assert!(start < source.len());

    let byte = source[start];
    let next = source.get(start + 1).copied().unwrap_or(0);
    let third = source.get(start + 2).copied().unwrap_or(0);

    match (byte, next, third) {
        (b'<', b'<', b'=')
        | (b'>', b'>', b'=')
        | (b'*', b'*', b'=')
        | (b'/', b'/', b'=')
        | (b'+' | b'-' | b'*', b'%' | b'|', b'=') => return (Punctuation::Other, 3),
        _ => {}
    }

    match (byte, next) {
        (b'&', b'&') => return (Punctuation::AmpersandDouble, 2),
        (b'-', b'>') => return (Punctuation::Arrow, 2),
        (b'=', b'>') => return (Punctuation::Other, 2),
        (b'|', b'|') => return (Punctuation::BarDouble, 2),
        (b'=', b'=') => return (Punctuation::Equal, 2),
        (b'>', b'=') => return (Punctuation::GreaterEqual, 2),
        (b'<', b'=') => return (Punctuation::LessEqual, 2),
        (b'!', b'=') => return (Punctuation::NotEqual, 2),
        (b'+' | b'-' | b'*' | b'/' | b'%' | b'&' | b'|' | b'^', b'=') => {
            return (Punctuation::Other, 2);
        }
        _ => {}
    }

    let single = match byte {
        b'!' => Punctuation::Bang,
        b'&' => Punctuation::Ampersand,
        b'(' => Punctuation::ParenOpen,
        b')' => Punctuation::ParenClose,
        b'*' => Punctuation::Star,
        b',' => Punctuation::Comma,
        b'.' => Punctuation::Dot,
        b'/' => Punctuation::Slash,
        b':' => Punctuation::Colon,
        b';' => Punctuation::Semicolon,
        b'<' => Punctuation::Less,
        b'=' => Punctuation::Assign,
        b'>' => Punctuation::Greater,
        b'[' => Punctuation::BracketOpen,
        b']' => Punctuation::BracketClose,
        _ => Punctuation::Other,
    };

    (single, 1)
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Lines {
    Continued,
    Many,
    One,
}

pub fn string_scan(source: &[u8], start: usize, quote: u8) -> usize {
    string_scan_bounded(source, start, quote, Lines::One)
}

pub fn string_scan_continued(source: &[u8], start: usize, quote: u8) -> usize {
    string_scan_bounded(source, start, quote, Lines::Continued)
}

pub fn string_scan_multiline(source: &[u8], start: usize, quote: u8) -> usize {
    string_scan_bounded(source, start, quote, Lines::Many)
}

fn string_scan_bounded(source: &[u8], start: usize, quote: u8, lines: Lines) -> usize {
    assert!(start < source.len());
    assert_eq!(source[start], quote);

    let mut offset = start + 1;

    while offset < source.len() {
        let byte = source[offset];
        let bounded = lines != Lines::Many;

        if bounded && line_break_width(source, offset) > 0 {
            return offset;
        }

        if byte == b'\\' {
            let joined = line_break_width(source, offset + 1);

            if bounded && lines == Lines::One && (joined > 0 || offset + 1 == source.len()) {
                return offset + 1;
            }

            if lines == Lines::Continued && joined > 0 {
                offset += 1 + joined;

                continue;
            }

            offset += 2;

            continue;
        }

        if byte == quote {
            return offset + 1;
        }

        offset += 1;
    }

    source.len().min(offset)
}

pub fn string_is_terminated(text: &[u8]) -> bool {
    let mut prefix = 0;

    while prefix < text.len() && text[prefix].is_ascii_alphabetic() {
        prefix += 1;
    }

    let Some(&quote) = text.get(prefix) else {
        return false;
    };

    if quote != b'"' && quote != b'\'' && quote != b'`' {
        return false;
    }

    if text.len() < prefix + 2 || text[text.len() - 1] != quote {
        return false;
    }

    let mut escapes = 0;
    let mut offset = text.len() - 1;

    while offset > prefix + 1 && text[offset - 1] == b'\\' {
        escapes += 1;
        offset -= 1;
    }

    escapes % 2 == 0
}

pub fn contains_folded(haystack: &[u8], needle: &[u8]) -> bool {
    if needle.is_empty() || needle.len() > haystack.len() {
        return false;
    }

    let first = needle[0];

    for start in 0..=haystack.len() - needle.len() {
        if haystack[start].to_ascii_lowercase() != first {
            continue;
        }

        let mut offset = 1;

        while offset < needle.len() {
            if haystack[start + offset].to_ascii_lowercase() != needle[offset] {
                break;
            }

            offset += 1;
        }

        if offset == needle.len() {
            return true;
        }
    }

    false
}

pub fn find(haystack: &[u8], needle: &[u8]) -> Option<usize> {
    if needle.is_empty() || needle.len() > haystack.len() {
        return None;
    }

    let first = needle[0];

    for start in 0..=haystack.len() - needle.len() {
        if haystack[start] != first {
            continue;
        }

        if &haystack[start..start + needle.len()] == needle {
            return Some(start);
        }
    }

    None
}

pub fn decimal_write(digits: &mut [u8], mut value: u64) -> usize {
    assert!(digits.len() >= DECIMAL_BYTES_MAX);

    let mut length = 0;

    for (slot, digit) in digits.iter_mut().enumerate().take(DECIMAL_BYTES_MAX) {
        *digit = b'0' + u8::try_from(value % 10).expect("a digit fits");
        value /= 10;
        length = slot + 1;

        if value == 0 {
            break;
        }
    }

    assert_eq!(value, 0);
    assert!(length <= DECIMAL_BYTES_MAX);

    digits[..length].reverse();

    length
}

pub fn decimal_read(text: &[u8]) -> Option<u64> {
    if text.is_empty() {
        return None;
    }

    if text.len() > 1 && text[0] == b'0' {
        return None;
    }

    let mut value = 0_u64;

    for byte in text {
        if !byte.is_ascii_digit() {
            return None;
        }

        value = value.checked_mul(10)?.checked_add(u64::from(byte - b'0'))?;
    }

    Some(value)
}

pub const fn decimal_width(value: u64) -> usize {
    let mut digits = 1;
    let mut remaining = value / 10;

    while remaining > 0 {
        digits += 1;
        remaining /= 10;
    }

    digits
}

pub fn starts_with_folded(text: &[u8], prefix: &[u8]) -> bool {
    if prefix.len() > text.len() {
        return false;
    }

    let mut offset = 0;

    while offset < prefix.len() {
        if text[offset].to_ascii_lowercase() != prefix[offset] {
            return false;
        }

        offset += 1;
    }

    true
}

pub fn indent_width(line: &[u8]) -> u32 {
    let width = line.len() - line.trim_ascii_start().len();

    u32::try_from(width).expect("a line is shorter than u32::MAX")
}

pub fn find_word(haystack: &[u8], name: &[u8]) -> bool {
    if name.is_empty() {
        return false;
    }

    let mut offset = 0;

    while offset + name.len() <= haystack.len() {
        let Some(start) = find(&haystack[offset..], name) else {
            return false;
        };

        let at = offset + start;
        let before = at.checked_sub(1).map(|index| haystack[index]);
        let after = haystack.get(at + name.len()).copied();
        let opened = before.is_none_or(|byte| !is_identifier_part(byte));
        let closed = after.is_none_or(|byte| !is_identifier_part(byte));

        if opened && closed {
            return true;
        }

        offset = at + 1;
    }

    false
}

pub fn text_of<'bytes>(bytes: &'bytes [u8], fallback: &'bytes str) -> &'bytes str {
    core::str::from_utf8(bytes).unwrap_or(fallback)
}

pub fn is_char_boundary(bytes: &[u8], offset: u32) -> bool {
    let index = offset as usize;

    assert!(index <= bytes.len());

    index == bytes.len() || (bytes[index] & 0xC0) != 0x80
}

pub fn balanced(text: &[u8]) -> bool {
    let mut braces = 0_i64;
    let mut brackets = 0_i64;
    let mut parens = 0_i64;

    for byte in text {
        match byte {
            b'{' => braces += 1,
            b'}' => braces -= 1,
            b'[' => brackets += 1,
            b']' => brackets -= 1,
            b'(' => parens += 1,
            b')' => parens -= 1,
            _ => {}
        }

        if braces < 0 || brackets < 0 || parens < 0 {
            return false;
        }
    }

    braces == 0 && brackets == 0 && parens == 0
}

pub fn stripped_group(text: &[u8]) -> &[u8] {
    let mut stripped = text.trim_ascii();
    let mut peeled = 0;

    while peeled < GROUP_PEEL_MAX {
        let Some(inner) = stripped
            .strip_prefix(b"(")
            .and_then(|rest| rest.strip_suffix(b")"))
        else {
            break;
        };

        if !balanced(inner) {
            break;
        }

        stripped = inner.trim_ascii();
        peeled += 1;
    }

    stripped
}

pub fn read_u16_le(bytes: &[u8], offset: usize) -> Option<u16> {
    let end = offset.checked_add(2)?;

    if end > bytes.len() {
        return None;
    }

    let mut value = [0_u8; 2];

    value.copy_from_slice(&bytes[offset..end]);

    Some(u16::from_le_bytes(value))
}

pub fn read_u32_le(bytes: &[u8], offset: usize) -> Option<u32> {
    let end = offset.checked_add(4)?;

    if end > bytes.len() {
        return None;
    }

    let mut value = [0_u8; 4];

    value.copy_from_slice(&bytes[offset..end]);

    Some(u32::from_le_bytes(value))
}

pub fn read_u64_le(bytes: &[u8], offset: usize) -> Option<u64> {
    let end = offset.checked_add(8)?;

    if end > bytes.len() {
        return None;
    }

    let mut value = [0_u8; 8];

    value.copy_from_slice(&bytes[offset..end]);

    Some(u64::from_le_bytes(value))
}

pub struct Words<'name> {
    name: &'name [u8],
    offset: usize,
}

pub const fn word_parts(name: &[u8]) -> Words<'_> {
    Words { name, offset: 0 }
}

impl<'name> Iterator for Words<'name> {
    type Item = &'name [u8];

    fn next(&mut self) -> Option<&'name [u8]> {
        while self.offset < self.name.len() && self.name[self.offset] == b'_' {
            self.offset += 1;
        }

        if self.offset >= self.name.len() {
            return None;
        }

        let start = self.offset;
        let mut cut = start + 1;

        while cut < self.name.len() && self.name[cut] != b'_' {
            let previous = self.name[cut - 1];
            let current = self.name[cut];

            let follows = match self.name.get(cut + 1) {
                Some(byte) if *byte != b'_' => *byte,
                _ => b'A',
            };

            let enters = current.is_ascii_uppercase() && previous.is_ascii_lowercase();

            let leaves = current.is_ascii_uppercase()
                && previous.is_ascii_uppercase()
                && follows.is_ascii_lowercase();

            if enters || leaves {
                break;
            }

            cut += 1;
        }

        assert!(cut > start);

        self.offset = cut;

        Some(&self.name[start..cut])
    }
}

pub fn word_in(list: &[&[u8]], word: &[u8]) -> bool {
    assert!(list.is_sorted());

    list.binary_search(&word).is_ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_decimal_reads_its_digits_and_refuses_everything_else() {
        assert_eq!(decimal_read(b"0"), Some(0));
        assert_eq!(decimal_read(b"7"), Some(7));
        assert_eq!(decimal_read(b"1024"), Some(1_024));
        assert_eq!(decimal_read(b"18446744073709551615"), Some(u64::MAX));
        assert_eq!(decimal_read(b""), None);
        assert_eq!(decimal_read(b"01"), None);
        assert_eq!(decimal_read(b"1_0"), None);
        assert_eq!(decimal_read(b"-1"), None);
        assert_eq!(decimal_read(b"18446744073709551616"), None);
    }

    #[test]
    fn a_decimal_width_matches_what_the_writer_writes() {
        let mut digits = [0_u8; DECIMAL_BYTES_MAX];

        for value in [0_u64, 9, 10, 99, 100, 1_000_000, u64::MAX] {
            assert_eq!(decimal_write(&mut digits, value), decimal_width(value));
        }
    }

    #[test]
    fn a_folded_prefix_ignores_the_case_of_the_text() {
        assert!(starts_with_folded(b"Content-Length: 7", b"content-length:"));
        assert!(starts_with_folded(b"abc", b"abc"));
        assert!(starts_with_folded(b"abc", b""));
        assert!(!starts_with_folded(b"ab", b"abc"));
        assert!(!starts_with_folded(b"abc", b"ABC"));
    }

    #[test]
    fn an_indent_counts_the_leading_blanks() {
        assert_eq!(indent_width(b"    let x = 1;"), 4);
        assert_eq!(indent_width(b"\tlet x = 1;"), 1);
        assert_eq!(indent_width(b"let x = 1;"), 0);
        assert_eq!(indent_width(b"    "), 4);
        assert_eq!(indent_width(b""), 0);
    }

    #[test]
    fn a_word_is_found_only_on_an_identifier_boundary() {
        assert!(find_word(b"let len = 0;", b"len"));
        assert!(find_word(b"len", b"len"));
        assert!(find_word(b"a.len()", b"len"));
        assert!(!find_word(b"let length = 0;", b"len"));
        assert!(!find_word(b"olen", b"len"));
        assert!(!find_word(b"", b"len"));
        assert!(!find_word(b"len", b""));
        assert!(find_word(b"held(value)", b"value"));
        assert!(!find_word(b"held(values)", b"value"));
        assert!(!find_word(b"held(revalue)", b"value"));
    }

    #[test]
    fn invalid_text_reads_as_its_fallback() {
        assert_eq!(text_of(b"path", "<path>"), "path");
        assert_eq!(text_of(&[0xff, 0xfe], "<path>"), "<path>");
    }

    #[test]
    fn a_boundary_falls_on_a_leading_byte_or_the_end() {
        const TEXT: &[u8] = "a\u{e9}".as_bytes();

        assert!(is_char_boundary(TEXT, 0));
        assert!(is_char_boundary(TEXT, 1));
        assert!(!is_char_boundary(TEXT, 2));
        assert!(is_char_boundary(TEXT, 3));
    }

    #[test]
    fn a_balanced_text_closes_every_bracket_kind_in_order() {
        assert!(balanced(b"f(a[0]) { }"));
        assert!(balanced(b""));
        assert!(!balanced(b"f(a"));
        assert!(!balanced(b"a)"));
        assert!(!balanced(b"(]"));
    }

    #[test]
    fn a_group_peels_its_balanced_parentheses() {
        assert_eq!(stripped_group(b"((a))"), b"a");
        assert_eq!(stripped_group(b"  ( a ) "), b"a");
        assert_eq!(stripped_group(b"(a) + (b)"), b"(a) + (b)");
        assert_eq!(stripped_group(b"a"), b"a");
        assert_eq!(stripped_group(b"((value))"), b"value");
    }

    #[test]
    fn a_little_endian_read_refuses_a_short_slice() {
        const BYTES: &[u8] = &[1, 0, 0, 0, 0, 0, 0, 0];

        assert_eq!(read_u16_le(BYTES, 0), Some(1));
        assert_eq!(read_u32_le(BYTES, 0), Some(1));
        assert_eq!(read_u64_le(BYTES, 0), Some(1));
        assert_eq!(read_u16_le(BYTES, 7), None);
        assert_eq!(read_u32_le(BYTES, 5), None);
        assert_eq!(read_u64_le(BYTES, 1), None);
    }

    #[test]
    fn a_name_splits_on_underscores_and_camel_boundaries() {
        let snake: Vec<&[u8]> = word_parts(b"heap_bytes_live").collect();
        let camel: Vec<&[u8]> = word_parts(b"HTTPServerName").collect();
        let leading: Vec<&[u8]> = word_parts(b"__leading").collect();

        assert_eq!(snake, vec![&b"heap"[..], &b"bytes"[..], &b"live"[..]]);
        assert_eq!(camel, vec![&b"HTTP"[..], &b"Server"[..], &b"Name"[..]]);
        assert_eq!(leading, vec![&b"leading"[..]]);

        let mixed: Vec<&[u8]> = word_parts(b"heldValueMax").collect();

        assert_eq!(mixed, vec![&b"held"[..], &b"Value"[..], &b"Max"[..]]);
        assert_eq!(word_parts(b"___").count(), 0);
        assert_eq!(word_parts(b"").count(), 0);

        let trailing: Vec<&[u8]> = word_parts(b"POWER_SIGN").collect();
        let bounded: Vec<&[u8]> = word_parts(b"HTTPS_KEY").collect();
        let single: Vec<&[u8]> = word_parts(b"CONTEXT_TYPE").collect();

        assert_eq!(trailing, vec![&b"POWER"[..], &b"SIGN"[..]]);
        assert_eq!(bounded, vec![&b"HTTPS"[..], &b"KEY"[..]]);
        assert_eq!(single, vec![&b"CONTEXT"[..], &b"TYPE"[..]]);
    }

    #[test]
    fn a_string_token_reports_whether_it_closed() {
        assert!(string_is_terminated(b"\"abc\""));
        assert!(string_is_terminated(b"'abc'"));
        assert!(string_is_terminated(b"`abc`"));
        assert!(string_is_terminated(b"r\"abc\""));
        assert!(string_is_terminated(b"\"a\\\\\""));
        assert!(string_is_terminated(b"\"\""));

        assert!(!string_is_terminated(b"\"abc"));
        assert!(!string_is_terminated(b"'abc"));
        assert!(!string_is_terminated(b"\"a\\\""));
        assert!(!string_is_terminated(b"\""));
        assert!(!string_is_terminated(b""));
        assert!(!string_is_terminated(b"abc"));
    }

    #[test]
    fn a_number_stops_at_a_field_access() {
        assert_eq!(number_scan(b"0.map(f)", 0), 1);
        assert_eq!(number_scan(b"1.5", 0), 3);
        assert_eq!(number_scan(b"0..8", 0), 1);
        assert_eq!(number_scan(b"0x1f", 0), 4);
    }

    #[test]
    fn a_compound_assignment_carries_its_whole_operator() {
        assert_eq!(punctuation_of(b"+=", 0), (Punctuation::Other, 2));
        assert_eq!(punctuation_of(b"-=", 0), (Punctuation::Other, 2));
        assert_eq!(punctuation_of(b"*=", 0), (Punctuation::Other, 2));
        assert_eq!(punctuation_of(b"/=", 0), (Punctuation::Other, 2));
        assert_eq!(punctuation_of(b"%=", 0), (Punctuation::Other, 2));
        assert_eq!(punctuation_of(b"&=", 0), (Punctuation::Other, 2));
        assert_eq!(punctuation_of(b"|=", 0), (Punctuation::Other, 2));
        assert_eq!(punctuation_of(b"^=", 0), (Punctuation::Other, 2));
    }

    #[test]
    fn a_three_byte_assignment_carries_all_three() {
        assert_eq!(punctuation_of(b"<<=", 0), (Punctuation::Other, 3));
        assert_eq!(punctuation_of(b">>=", 0), (Punctuation::Other, 3));
        assert_eq!(punctuation_of(b"**=", 0), (Punctuation::Other, 3));
        assert_eq!(punctuation_of(b"//=", 0), (Punctuation::Other, 3));
        assert_eq!(punctuation_of(b"+%=", 0), (Punctuation::Other, 3));
        assert_eq!(punctuation_of(b"-%=", 0), (Punctuation::Other, 3));
        assert_eq!(punctuation_of(b"*%=", 0), (Punctuation::Other, 3));
        assert_eq!(punctuation_of(b"+|=", 0), (Punctuation::Other, 3));
    }

    #[test]
    fn a_doubled_operator_without_an_equals_is_not_an_assignment() {
        assert_eq!(punctuation_of(b"<<", 0), (Punctuation::Less, 1));
        assert_eq!(punctuation_of(b">>", 0), (Punctuation::Greater, 1));
        assert_eq!(punctuation_of(b"**", 0), (Punctuation::Star, 1));
        assert_eq!(punctuation_of(b"//", 0), (Punctuation::Slash, 1));
        assert_eq!(punctuation_of(b"+%", 0), (Punctuation::Other, 1));
        assert_eq!(punctuation_of(b"+|", 0), (Punctuation::Other, 1));
    }

    #[test]
    fn a_lone_operator_is_not_an_assignment() {
        assert_eq!(punctuation_of(b"+", 0), (Punctuation::Other, 1));
        assert_eq!(punctuation_of(b"+ ", 0), (Punctuation::Other, 1));
        assert_eq!(punctuation_of(b"==", 0), (Punctuation::Equal, 2));
        assert_eq!(punctuation_of(b"~=", 0), (Punctuation::Other, 1));
    }

    #[test]
    fn a_scan_stops_at_the_source_end() {
        assert_eq!(identifier_scan(b"value", 0), 5);
        assert_eq!(identifier_scan(b"value=1", 0), 5);
        assert_eq!(line_scan(b"a line", 0), 6);
        assert_eq!(line_scan(b"a line\nnext", 0), 6);
        assert_eq!(line_scan(b"", 0), 0);
    }

    #[test]
    fn a_number_carries_its_exponent_and_stops_at_the_source_end() {
        assert_eq!(number_scan(b"1e+9", 0), 4);
        assert_eq!(number_scan(b"1e-9;", 0), 4);
        assert_eq!(number_scan(b"0x1p-4", 0), 6);
        assert_eq!(number_scan(b"1e", 0), 2);
        assert_eq!(number_scan(b"1e+", 0), 3);
        assert_eq!(number_scan(b"7", 0), 1);
        assert_eq!(number_scan(b"7 + 1", 0), 1);
        assert_eq!(number_scan(b"1_000_000", 0), 9);
    }

    #[test]
    fn a_string_that_never_closes_stops_at_the_source_end() {
        assert_eq!(string_scan(b"\"abc", 0, b'"'), 4);
        assert_eq!(string_scan(b"\"abc\ndef", 0, b'"'), 4);
        assert_eq!(string_scan_multiline(b"\"abc", 0, b'"'), 4);
        assert_eq!(string_scan_multiline(b"\"abc\ndef", 0, b'"'), 8);
        assert_eq!(string_scan(b"\"ab\\", 0, b'"'), 4);
    }

    #[test]
    fn a_hexadecimal_literal_does_not_read_its_own_digits_as_an_exponent() {
        assert_eq!(number_scan(b"0x1e-1", 0), 4);
        assert_eq!(number_scan(b"0xCAFE-1", 0), 6);
        assert_eq!(number_scan(b"0XE-1", 0), 3);
        assert_eq!(number_scan(b"1e-1", 0), 4);
        assert_eq!(number_scan(b"1E+10", 0), 5);
    }

    #[test]
    fn a_hexadecimal_float_keeps_its_fraction_and_its_exponent() {
        assert_eq!(number_scan(b"0x1.fffffep+127", 0), 15);
        assert_eq!(number_scan(b"0x1.fp-2", 0), 8);
        assert_eq!(number_scan(b"1.5e-3", 0), 6);
    }

    #[test]
    fn a_decimal_literal_has_no_binary_exponent() {
        assert_eq!(number_scan(b"1p-2", 0), 2);
    }

    #[test]
    fn a_one_sided_dot_is_a_number_only_where_the_language_says_so() {
        assert_eq!(number_scan_bounded(b"1.", 0, Numbers::ONE_SIDED), 2);
        assert_eq!(number_scan_bounded(b"1..<5", 0, Numbers::ONE_SIDED), 1);
        assert_eq!(number_scan_bounded(b".5", 0, Numbers::ONE_SIDED), 2);
        assert_eq!(number_scan(b"1.", 0), 1);
    }

    #[test]
    fn a_trailing_backslash_does_not_carry_a_one_line_string_over_the_newline() {
        assert_eq!(string_scan(b"\"a\\\nfn later() {}\n", 0, b'"'), 3);
        assert_eq!(string_scan(b"\"a\\\r\nnext\n", 0, b'"'), 3);
        assert_eq!(string_scan(b"\"a\\\"b\"", 0, b'"'), 6);
        assert_eq!(string_scan_multiline(b"\"a\\\nb\"", 0, b'"'), 6);
    }

    #[test]
    fn a_one_line_string_ends_at_a_carriage_return() {
        assert_eq!(string_scan(b"\"ab\r\ncd\"\n", 0, b'"'), 3);
    }

    #[test]
    fn a_comment_on_a_windows_line_leaves_the_carriage_return_outside_it() {
        assert_eq!(line_scan_trimmed(b"// note\r\nnext", 0), 7);
        assert_eq!(line_scan_trimmed(b"// note\nnext", 0), 7);
        assert_eq!(line_scan_trimmed(b"// note", 0), 7);
        assert_eq!(line_scan(b"// note\r\nnext", 0), 8);
    }

    #[test]
    fn the_class_table_names_what_reads_it() {
        assert_ne!(CLASSES[usize::from(b'x')] & CLASS_IDENTIFIER_PART, 0);
        assert_ne!(CLASSES[usize::from(b'5')] & CLASS_IDENTIFIER_PART, 0);
        assert_ne!(CLASSES[usize::from(b'_')] & CLASS_IDENTIFIER_PART, 0);
        assert_eq!(CLASSES[usize::from(b' ')] & CLASS_IDENTIFIER_PART, 0);

        assert_ne!(CLASSES[usize::from(b' ')] & CLASS_WHITESPACE, 0);
        assert_ne!(CLASSES[usize::from(b'\t')] & CLASS_WHITESPACE, 0);
        assert_ne!(CLASSES[usize::from(b'\n')] & CLASS_WHITESPACE, 0);
        assert_ne!(CLASSES[usize::from(b'\r')] & CLASS_WHITESPACE, 0);
        assert_ne!(CLASSES[usize::from(VERTICAL_TAB)] & CLASS_WHITESPACE, 0);
        assert_eq!(CLASSES[usize::from(b'x')] & CLASS_WHITESPACE, 0);

        assert_ne!(CLASSES[usize::from(b' ')] & CLASS_BLANK, 0);
        assert_ne!(CLASSES[usize::from(b'\t')] & CLASS_BLANK, 0);
        assert_ne!(CLASSES[usize::from(VERTICAL_TAB)] & CLASS_BLANK, 0);
        assert_eq!(CLASSES[usize::from(b'\n')] & CLASS_BLANK, 0);
        assert_eq!(CLASSES[usize::from(b'\r')] & CLASS_BLANK, 0);
    }

    #[test]
    fn every_space_the_lexers_skip_carries_its_own_width() {
        assert_eq!(whitespace_width(b" ", 0), 1);
        assert_eq!(whitespace_width(b"\n", 0), 1);
        assert_eq!(whitespace_width(b"x", 0), 0);
        assert_eq!(whitespace_width("\u{0085}".as_bytes(), 0), 2);
        assert_eq!(whitespace_width("\u{00a0}".as_bytes(), 0), 2);
        assert_eq!(whitespace_width("\u{1680}".as_bytes(), 0), 3);
        assert_eq!(whitespace_width("\u{2000}".as_bytes(), 0), 3);
        assert_eq!(whitespace_width("\u{200a}".as_bytes(), 0), 3);
        assert_eq!(whitespace_width("\u{2028}".as_bytes(), 0), 3);
        assert_eq!(whitespace_width("\u{2029}".as_bytes(), 0), 3);
        assert_eq!(whitespace_width("\u{202f}".as_bytes(), 0), 3);
        assert_eq!(whitespace_width("\u{205f}".as_bytes(), 0), 3);
        assert_eq!(whitespace_width("\u{3000}".as_bytes(), 0), 3);
        assert_eq!(whitespace_width("\u{feff}".as_bytes(), 0), 3);
        assert_eq!(whitespace_width("\u{00e4}".as_bytes(), 0), 0);
        assert_eq!(whitespace_width("\u{2013}".as_bytes(), 0), 0);
    }

    #[test]
    fn a_blank_run_ends_where_the_line_does() {
        assert_eq!(whitespace_scan(b"    x", 0), 4);
        assert_eq!(whitespace_scan(b"\t\t x", 0), 3);
        assert_eq!(whitespace_scan(b"x", 0), 0);
        assert_eq!(whitespace_scan(b"    ", 0), 4);
        assert_eq!(whitespace_scan(b"  \n  ", 0), 2);
        assert_eq!(whitespace_scan(b"", 0), 0);
        assert_eq!(whitespace_scan(b"  x", 2), 2);
    }

    #[test]
    fn an_identifier_ends_at_the_first_byte_that_cannot_continue_it() {
        assert_eq!(identifier_scan(b"value", 0), 5);
        assert_eq!(identifier_scan(b"value = 1", 0), 5);
        assert_eq!(identifier_scan(b"a1_b(", 0), 4);

        assert_eq!(
            identifier_scan("wert\u{00e4}hnlich = 1".as_bytes(), 0),
            "wert\u{00e4}hnlich".len()
        );

        assert_eq!(
            identifier_scan("const\u{00a0}value".as_bytes(), 0),
            "const".len()
        );
    }

    #[test]
    fn a_trimmed_line_drops_the_return_and_nothing_else() {
        assert_eq!(line_scan_trimmed(b"\n", 0), 0);
        assert_eq!(line_scan_trimmed(b"", 0), 0);
        assert_eq!(line_scan_trimmed(b"one\r\ntwo", 0), 3);
        assert_eq!(line_scan_trimmed(b"one\ntwo", 0), 3);
        assert_eq!(line_scan_trimmed(b"one", 0), 3);
        assert_eq!(line_scan_trimmed(b"one\r\ntwo", 5), 8);
    }

    #[test]
    fn a_continued_literal_joins_on_a_backslash_and_stops_on_a_bare_line_break() {
        assert_eq!(string_scan_continued(b"\"a\\\nb\"", 0, b'"'), 6);
        assert_eq!(string_scan_continued(b"\"a\\\r\nb\"", 0, b'"'), 7);
        assert_eq!(string_scan_continued(b"\"a\nb\"", 0, b'"'), 2);
        assert_eq!(string_scan_continued(b"\"a\\\"b\"", 0, b'"'), 6);
        assert_eq!(string_scan_continued(b"\"ab\"", 0, b'"'), 4);
        assert_eq!(string_scan_continued(b"\"ab", 0, b'"'), 3);
    }

    #[test]
    fn a_number_records_the_base_its_exponent_is_read_in() {
        assert_eq!(number_scan(b"0e-1", 0), 4);
        assert_eq!(number_scan(b"0E+1", 0), 4);
        assert_eq!(number_scan(b"0x1e-1", 0), 4);
        assert_eq!(number_scan(b"0x1p-1", 0), 6);
        assert_eq!(number_scan(b"1e-1", 0), 4);
        assert_eq!(number_scan(b"0x1.fffffep+127", 0), 15);
        assert_eq!(number_scan(b"12 ", 0), 2);
    }

    #[test]
    fn a_leading_dot_is_a_number_only_where_the_language_says_so() {
        assert_eq!(number_scan_bounded(b".5+", 0, Numbers::ONE_SIDED), 2);
        assert_eq!(number_scan_bounded(b"1.", 0, Numbers::ONE_SIDED), 2);
        assert_eq!(number_scan_bounded(b"1.5", 0, Numbers::ONE_SIDED), 3);
        assert_eq!(number_scan_bounded(b"1..2", 0, Numbers::DEFAULT), 1);
        assert_eq!(number_scan_bounded(b"0x1.f", 0, Numbers::DEFAULT), 5);
        assert_eq!(number_scan_bounded(b"1.f", 0, Numbers::DEFAULT), 1);
    }

    #[test]
    fn a_one_line_literal_ends_at_its_line_terminator_backslash_or_not() {
        assert_eq!(string_scan(b"\"a\"x", 0, b'\"'), 3);
        assert_eq!(string_scan(b"\"a\\\"b\"", 0, b'\"'), 6);
        assert_eq!(string_scan(b"\"a\n\"", 0, b'\"'), 2);
        assert_eq!(string_scan(b"\"a\\\n\"b", 0, b'\"'), 3);
        assert_eq!(string_scan(b"\"a\\", 0, b'\"'), 3);
        assert_eq!(string_scan(b"\"a", 0, b'\"'), 2);
    }
}
