use crate::bounded::{Buffer, Bytes as _, Span};
use crate::format::brace::{NEST_DEPTH_MAX, is_close, is_open, opened_by, substituting};
use crate::scan::string_is_terminated;
use crate::token::{Token, TokenKind};

pub fn sorted(arena: &[u8], spans: &mut [Span]) {
    let mut index = 1;

    while index < spans.len() {
        let mut scan = index;

        while scan > 0 && precedes(arena, spans[scan], spans[scan - 1]) {
            spans.swap(scan, scan - 1);

            scan -= 1;
        }

        index += 1;
    }
}

pub fn classed(text: &[u8]) -> (u8, &[u8]) {
    if text == b"self" || text.starts_with(b"self ") {
        return (0, text);
    }

    let held = if text.starts_with(b"r#") {
        &text[2..]
    } else {
        text
    };

    (1, held)
}

pub const fn ranked(byte: u8) -> u8 {
    if byte == b' ' {
        return 0;
    }

    if byte == b',' {
        return 1;
    }

    if byte == b':' {
        return 2;
    }

    if byte == b'_' {
        return 3;
    }

    if byte == b'*' {
        return 123;
    }

    if byte == b'{' { 124 } else { byte }
}

pub fn precedes(arena: &[u8], left: Span, right: Span) -> bool {
    let (first, held) = classed(&arena[left.range()]);
    let (second, other) = classed(&arena[right.range()]);

    if first != second {
        return first < second;
    }

    versioned(held, other)
}

pub fn versioned(left: &[u8], right: &[u8]) -> bool {
    let mut held = 0;
    let mut other = 0;

    while held < left.len() && other < right.len() {
        if left[held].is_ascii_digit() && right[other].is_ascii_digit() {
            let first = digits(left, held);
            let second = digits(right, other);

            if first - held != second - other {
                return first - held < second - other;
            }

            if left[held..first] != right[other..second] {
                return left[held..first] < right[other..second];
            }

            held = first;
            other = second;

            continue;
        }

        if ranked(left[held]) != ranked(right[other]) {
            return ranked(left[held]) < ranked(right[other]);
        }

        held += 1;
        other += 1;
    }

    left.len() - held < right.len() - other
}

pub fn digits(text: &[u8], from: usize) -> usize {
    let mut held = from;

    while held < text.len() && text[held].is_ascii_digit() {
        held += 1;
    }

    held
}

pub fn closed(source: &[u8], tokens: &[Token], nests: bool, raw: bool) -> bool {
    for token in tokens {
        let text = token.text(source);

        let held = match token.kind {
            TokenKind::Comment => comment_closed(text, nests),
            TokenKind::String => string_closed(text, raw),
            _ => true,
        };

        if !held {
            return false;
        }
    }

    true
}

pub fn comment_closed(text: &[u8], nests: bool) -> bool {
    if !text.starts_with(b"/*") {
        return true;
    }

    if !nests {
        return text.len() >= 4 && text.ends_with(b"*/");
    }

    let mut depth = 0_u32;
    let mut offset = 0;

    while offset + 1 < text.len() {
        if text[offset] == b'/' && text[offset + 1] == b'*' {
            depth += 1;
            offset += 2;

            continue;
        }

        if text[offset] == b'*' && text[offset + 1] == b'/' {
            assert!(depth > 0);

            depth -= 1;
            offset += 2;

            if depth == 0 {
                return offset == text.len();
            }

            continue;
        }

        offset += 1;
    }

    false
}

pub fn string_closed(text: &[u8], raw: bool) -> bool {
    let mut prefix = 0;

    while prefix < text.len() && text[prefix].is_ascii_alphabetic() {
        prefix += 1;
    }

    let Some(&quote) = text.get(prefix) else {
        return true;
    };

    if !matches!(quote, b'"' | b'\'' | b'`') {
        return true;
    }

    if text == b"`" {
        return true;
    }

    string_is_terminated(text, raw)
}

pub fn balanced(source: &[u8], tokens: &[Token]) -> bool {
    let mut depth = 0;
    let mut stack = [TokenKind::BlockStart; NEST_DEPTH_MAX as usize];

    for token in tokens {
        if is_open(token.kind) || substituting(source, *token) {
            if depth == NEST_DEPTH_MAX {
                return false;
            }

            stack[depth as usize] = if is_open(token.kind) {
                token.kind
            } else {
                TokenKind::BlockStart
            };

            depth += 1;

            continue;
        }

        if !is_close(token.kind) {
            continue;
        }

        if depth == 0 || stack[depth as usize - 1] != opened_by(token.kind) {
            return false;
        }

        depth -= 1;
    }

    depth == 0
}

pub fn spaced(out: &mut Buffer, count: u32) -> bool {
    for _ in 0..count {
        if !out.push_bytes(b" ") {
            return false;
        }
    }

    true
}

pub fn tabbed(out: &mut Buffer, count: u32) -> bool {
    for _ in 0..count {
        if !out.push_bytes(b"\t") {
            return false;
        }
    }

    true
}

pub fn renumbered(out: &mut Buffer, text: &[u8]) -> bool {
    let split = exponent_at(text);
    let power = powered(&text[split..]);

    if text.first() == Some(&b'.') && !out.push_bytes(b"0") {
        return false;
    }

    if !lowered(out, trimmed(&text[..split])) {
        return false;
    }

    let Some((negative, digits)) = power else {
        return true;
    };

    out.push_bytes(b"e") && (!negative || out.push_bytes(b"-")) && lowered(out, digits)
}

pub fn lowered(out: &mut Buffer, text: &[u8]) -> bool {
    for byte in text {
        if !out.push_bytes(&[byte.to_ascii_lowercase()]) {
            return false;
        }
    }

    true
}

pub fn exponent_at(text: &[u8]) -> usize {
    let based = matches!(text, [b'0', held, ..] if !held.is_ascii_digit() && *held != b'.');

    if based {
        return text.len();
    }

    text.iter()
        .position(|byte| *byte == b'e' || *byte == b'E')
        .unwrap_or(text.len())
}

pub fn powered(text: &[u8]) -> Option<(bool, &[u8])> {
    if text.is_empty() {
        return None;
    }

    let signed = matches!(text.get(1), Some(b'+' | b'-'));
    let digits = &text[1 + usize::from(signed)..];
    let zeros = digits.iter().take_while(|byte| **byte == b'0').count();

    if zeros == digits.len() {
        return None;
    }

    Some((text.get(1) == Some(&b'-'), &digits[zeros..]))
}

pub fn trimmed(mantissa: &[u8]) -> &[u8] {
    let Some(dot) = mantissa.iter().position(|byte| *byte == b'.') else {
        return mantissa;
    };

    let fraction = &mantissa[dot + 1..];

    if !fraction.iter().all(u8::is_ascii_digit) {
        return mantissa;
    }

    let mut held = fraction.len();

    while held > 1 && fraction[held - 1] == b'0' {
        held -= 1;
    }

    if held == 0 {
        return &mantissa[..dot];
    }

    &mantissa[..dot + 1 + held]
}

pub fn named_key(body: &[u8]) -> bool {
    let Some(first) = body.first() else {
        return false;
    };

    if !first.is_ascii_alphabetic() && *first != b'_' && *first != b'$' {
        return false;
    }

    body.iter()
        .all(|byte| byte.is_ascii_alphanumeric() || *byte == b'_' || *byte == b'$')
}

pub fn bodied(text: &[u8]) -> Option<&[u8]> {
    let quote = *text.first()?;

    if quote != b'"' && quote != b'\'' {
        return None;
    }

    if text.len() < 2 || text[text.len() - 1] != quote {
        return None;
    }

    Some(&text[1..text.len() - 1])
}

pub fn preferred(body: &[u8]) -> u8 {
    let mut doubles = 0_u32;
    let mut singles = 0_u32;
    let mut held = 0;

    while held < body.len() {
        held += usize::from(body[held] == b'\\');

        match body.get(held) {
            Some(&b'"') => doubles += 1,
            Some(&b'\'') => singles += 1,
            _ => (),
        }

        held += 1;
    }

    if doubles > singles { b'\'' } else { b'"' }
}

pub fn requoted(out: &mut Buffer, body: &[u8], quote: u8) -> bool {
    let former = if quote == b'"' { b'\'' } else { b'"' };
    let mut held = 0;

    while held < body.len() {
        if body[held] != b'\\' {
            if body[held] == quote && !out.push_bytes(b"\\") {
                return false;
            }

            if !out.push_bytes(&body[held..=held]) {
                return false;
            }

            held += 1;

            continue;
        }

        let Some(&next) = body.get(held + 1) else {
            return out.push_bytes(b"\\");
        };

        let written = if next == former {
            out.push_bytes(&[next])
        } else {
            out.push_bytes(&[b'\\', next])
        };

        if !written {
            return false;
        }

        held += 2;
    }

    true
}
