use crate::scan;
use crate::syntax::css::kind::CSSKind;

pub const HEX_WIDTH_MAX: usize = 8;
pub const HEX_WIDTH_MIN: usize = 3;
pub const NEST_DEPTH_MAX: u32 = 64;
pub const SCAN_STEP_MAX: u32 = 1 << 16;

pub const SELECTOR_LITERALS: [&[u8]; 8] = [
    b"has",
    b"host",
    b"host-context",
    b"is",
    b"not",
    b"nth-child",
    b"nth-last-child",
    b"where",
];

pub const NTH_LITERALS: [&[u8]; 2] = [b"nth-child", b"nth-last-child"];
pub const QUERY_JOINS: [&[u8]; 2] = [b"and", b"or"];
pub const QUERY_PREFIXES: [&[u8]; 2] = [b"not", b"only"];

pub const fn is_delimiter(byte: u8) -> bool {
    matches!(
        byte,
        b'\t'
            | b'\n'
            | 0x0b
            | 0x0c
            | b'\r'
            | b' '
            | b'!'
            | b'('
            | b')'
            | b','
            | b';'
            | b'['
            | b']'
            | b'{'
            | b'}'
    )
}

pub const fn is_name_byte(byte: u8) -> bool {
    byte.is_ascii_alphanumeric() || byte == b'_' || byte == b'-' || byte >= 0x80
}

pub const fn is_name_start(byte: u8) -> bool {
    byte.is_ascii_alphabetic() || byte == b'_' || byte == b'-' || byte >= 0x80
}

pub const fn is_unit_byte(byte: u8) -> bool {
    byte.is_ascii_alphabetic() || byte == b'%'
}

pub const fn is_value_operator(kind: CSSKind) -> bool {
    matches!(
        kind,
        CSSKind::Minus | CSSKind::Plus | CSSKind::Slash | CSSKind::Star
    )
}

pub const fn is_combinator(kind: CSSKind) -> bool {
    matches!(
        kind,
        CSSKind::Greater | CSSKind::Pipe | CSSKind::Plus | CSSKind::Tilde
    )
}

pub const fn combinator_node(kind: CSSKind) -> CSSKind {
    match Some(kind) {
        Some(CSSKind::Greater) => CSSKind::ChildSelector,
        Some(CSSKind::Pipe) => CSSKind::NamespaceSelector,
        Some(CSSKind::Plus) => CSSKind::AdjacentSiblingSelector,
        Some(_) | None => CSSKind::SiblingSelector,
    }
}

pub const fn opens_a_selector(kind: CSSKind) -> bool {
    matches!(
        kind,
        CSSKind::Ampersand
            | CSSKind::BracketOpen
            | CSSKind::Colon
            | CSSKind::ColonColon
            | CSSKind::Dot
            | CSSKind::Hash
            | CSSKind::Identifier
            | CSSKind::Star
            | CSSKind::Text
    )
}

pub const fn is_tight_postfix(kind: CSSKind) -> bool {
    matches!(kind, CSSKind::Dot)
}

pub const fn is_loose_postfix(kind: CSSKind) -> bool {
    matches!(
        kind,
        CSSKind::BracketOpen | CSSKind::Colon | CSSKind::ColonColon | CSSKind::Hash
    )
}

pub fn escape_end(source: &[u8], start: usize) -> usize {
    scan::escape_end(source, start)
}

pub fn identifier_end(source: &[u8], start: usize) -> Option<usize> {
    let byte = *source.get(start)?;

    if !is_name_start(byte) {
        return None;
    }

    if byte == b'-' {
        let next = *source.get(start + 1)?;

        if next != b'-' && !is_name_start(next) {
            return None;
        }
    }

    let mut offset = start + 1;

    while offset < source.len() && is_name_byte(source[offset]) {
        offset += 1;
    }

    Some(offset)
}

pub fn plain_value_end(source: &[u8], start: usize) -> Option<usize> {
    let mut offset = start;

    for _ in 0..=source.len() {
        let Some(byte) = source.get(offset).copied() else {
            break;
        };

        if byte == b'-' || byte == b'_' {
            offset += 1;

            continue;
        }

        if byte == b'/' && slash_runs(source, offset) {
            offset += 2;

            continue;
        }

        break;
    }

    if !source.get(offset)?.is_ascii_alphabetic() {
        return None;
    }

    offset += 1;

    for _ in 0..=source.len() {
        let Some(byte) = source.get(offset).copied() else {
            break;
        };

        if byte == b'/' {
            if !slash_runs(source, offset) {
                break;
            }

            offset += 2;

            continue;
        }

        if is_delimiter(byte) {
            break;
        }

        offset += 1;
    }

    Some(offset)
}

fn slash_runs(source: &[u8], offset: usize) -> bool {
    assert!(offset < source.len());
    assert_eq!(source[offset], b'/');

    source
        .get(offset + 1)
        .is_some_and(|byte| *byte != b'*' && !is_delimiter(*byte))
}

pub fn number_end(source: &[u8], start: usize) -> Option<(CSSKind, usize)> {
    let byte = *source.get(start)?;
    let signed = byte == b'+' || byte == b'-';
    let mut offset = start + usize::from(signed);
    let mut digits = 0;

    while offset < source.len() && source[offset].is_ascii_digit() {
        digits += 1;
        offset += 1;
    }

    let dotted =
        source.get(offset) == Some(&b'.') && source.get(offset + 1).is_some_and(u8::is_ascii_digit);

    if digits == 0 && !dotted {
        return None;
    }

    let mut float = dotted;

    if dotted {
        offset += 1;

        while offset < source.len() && source[offset].is_ascii_digit() {
            offset += 1;
        }
    }

    if let Some(reach) = exponent_end(source, offset) {
        float = true;
        offset = reach;
    }

    if float {
        return Some((CSSKind::Float, offset));
    }

    Some((CSSKind::Number, offset))
}

fn exponent_end(source: &[u8], start: usize) -> Option<usize> {
    if !matches!(source.get(start), Some(b'e' | b'E')) {
        return None;
    }

    let negative = source.get(start + 1) == Some(&b'-');
    let mut offset = start + 1 + usize::from(negative);

    if !source.get(offset).is_some_and(u8::is_ascii_digit) {
        return None;
    }

    while offset < source.len() && source[offset].is_ascii_digit() {
        offset += 1;
    }

    Some(offset)
}

pub fn unit_end(source: &[u8], start: usize) -> Option<usize> {
    let mut offset = start;

    while offset < source.len() && is_unit_byte(source[offset]) {
        offset += 1;
    }

    if offset == start {
        return None;
    }

    if plain_value_end(source, start).is_some_and(|reach| reach > offset) {
        return None;
    }

    Some(offset)
}

pub fn hex_end(source: &[u8], start: usize) -> Option<usize> {
    let stop = (start + HEX_WIDTH_MAX).min(source.len());
    let mut offset = start;

    while offset < stop && source[offset].is_ascii_hexdigit() {
        offset += 1;
    }

    if offset - start < HEX_WIDTH_MIN {
        return None;
    }

    Some(offset)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_plain_value_stops_at_a_delimiter_and_swallows_a_slash() {
        assert_eq!(plain_value_end(b"red;", 0), Some(3));
        assert_eq!(plain_value_end(b"a.png)", 0), Some(5));
        assert_eq!(plain_value_end(b"px/1.5 x", 0), Some(6));
        assert_eq!(plain_value_end(b"//x.com/a.png)", 0), Some(13));
        assert_eq!(plain_value_end(b"/* note */", 0), None);
        assert_eq!(plain_value_end(b"100%", 0), None);
        assert_eq!(plain_value_end(b"startColorstr='#fff')", 0), Some(20));
    }

    #[test]
    fn an_identifier_runs_over_its_name_bytes() {
        assert_eq!(identifier_end(b"-webkit-x(", 0), Some(9));
        assert_eq!(identifier_end(b"--gap)", 0), Some(5));
        assert_eq!(identifier_end(b"1px", 0), None);
    }

    #[test]
    fn a_number_splits_from_its_unit_unless_a_plain_value_is_longer() {
        assert_eq!(number_end(b"10px", 0), Some((CSSKind::Number, 2)));
        assert_eq!(unit_end(b"10px", 2), Some(4));
        assert_eq!(number_end(b"1.5em", 0), Some((CSSKind::Float, 3)));
        assert_eq!(unit_end(b"1.5em", 3), Some(5));
        assert_eq!(number_end(b"-50%", 0), Some((CSSKind::Number, 3)));
        assert_eq!(unit_end(b"-50%", 3), Some(4));
        assert_eq!(number_end(b"12px/1.5", 0), Some((CSSKind::Number, 2)));
        assert_eq!(unit_end(b"12px/1.5", 2), None);
        assert_eq!(number_end(b".5;", 0), Some((CSSKind::Float, 2)));
        assert_eq!(number_end(b"1e5;", 0), Some((CSSKind::Float, 3)));
        assert_eq!(number_end(b"px", 0), None);
    }

    #[test]
    fn a_colour_takes_three_to_eight_hexadecimal_digits() {
        assert_eq!(hex_end(b"fff;", 0), Some(3));
        assert_eq!(hex_end(b"aabbccdd;", 0), Some(8));
        assert_eq!(hex_end(b"aabbccddee;", 0), Some(8));
        assert_eq!(hex_end(b"ff;", 0), None);
    }

    #[test]
    fn an_escape_takes_its_digits_or_its_one_byte() {
        assert_eq!(escape_end(b"\\41 y", 0), 4);
        assert_eq!(escape_end(b"\\:e", 0), 2);
        assert_eq!(escape_end(b"\\", 0), 1);
    }
}
