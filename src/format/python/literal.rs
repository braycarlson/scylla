use crate::bounded::{Buffer, Bytes as _, count_of};
use crate::format::python::QuotePreference;

pub(super) const DOUBLE: &[u8] = b"\"";
pub(super) const SINGLE: &[u8] = b"'";
pub(super) const TRIPLE_DOUBLE: &[u8] = b"\"\"\"";
pub(super) const TRIPLE_SINGLE: &[u8] = b"'''";

pub(super) fn body_edges(text: &[u8]) -> Option<(u32, u32)> {
    let mut prefix = 0;

    while text.get(prefix).is_some_and(u8::is_ascii_alphabetic) {
        prefix += 1;
    }

    let quote = *text.get(prefix)?;

    if !matches!(quote, b'"' | b'\'') {
        return None;
    }

    let width = if text[prefix..].starts_with(&[quote, quote, quote]) {
        3
    } else {
        1
    };

    let head = prefix + width;
    let tail = text.len().checked_sub(width)?;

    if tail < head || text[tail..].iter().any(|byte| *byte != quote) {
        return None;
    }

    Some((count_of(head), count_of(tail)))
}

pub(super) fn body_escaped(text: &[u8]) -> bool {
    let Some((head, tail)) = body_edges(text) else {
        return false;
    };

    let mut escaped = false;

    for byte in &text[head as usize..tail as usize] {
        if *byte == b'\n' && escaped {
            return true;
        }

        if !matches!(*byte, b' ' | b'\t' | 0x0c) {
            escaped = *byte == b'\\';
        }
    }

    false
}

pub(super) fn body_indent(body: &[u8]) -> u32 {
    let mut common = u32::MAX;

    for line in body.split(|byte| *byte == b'\n').skip(1) {
        let stripped = line.trim_ascii_start();

        if stripped.is_empty() {
            continue;
        }

        common = common.min(count_of(line.len() - stripped.len()));
    }

    common
}

pub(super) fn ending_of<'held>(body: &'held [u8], first: &'held [u8], common: u32) -> Option<u8> {
    if common == u32::MAX {
        return first.last().copied();
    }

    let last = body.split(|byte| *byte == b'\n').skip(1).last()?;

    last.get(common as usize..)
        .unwrap_or_default()
        .trim_ascii_end()
        .last()
        .copied()
}

pub(super) fn settled(text: &[u8], head: u32, last: Option<u8>, preference: QuotePreference) -> u8 {
    let written = text[head as usize - 1];

    let wanted = match preference {
        QuotePreference::Double => b'"',
        QuotePreference::Preserve => return written,
        QuotePreference::Single => b'\'',
    };

    if written == wanted || last == Some(wanted) {
        return written;
    }

    let triple = head >= 3 && text[head as usize - 3..head as usize] == [written, written, written];
    let width = if triple { 3 } else { 1 };
    let Some(body) = text.get(head as usize..text.len() - width) else {
        return written;
    };

    let clashes = if triple {
        body.windows(width)
            .any(|run| run.iter().all(|byte| *byte == wanted))
            || body.windows(2).any(|run| run == [b'\\', wanted])
    } else {
        body.contains(&wanted) || body.contains(&b'\\')
    };

    if clashes { written } else { wanted }
}

pub(super) fn odd_slashes(text: &[u8]) -> bool {
    let mut found = false;

    for byte in text.iter().rev() {
        if *byte != b'\\' {
            break;
        }

        found = !found;
    }

    found
}

pub(super) fn quoted(bytes: &[u8], wanted: u8) -> Option<usize> {
    let mut offset = 0;

    while offset < bytes.len() && bytes[offset] != b'"' && bytes[offset] != b'\'' {
        offset += 1;
    }

    if offset == bytes.len() || bytes[offset] == wanted {
        return None;
    }

    Some(offset)
}

pub(super) fn requoted(
    bytes: &[u8],
    preference: QuotePreference,
) -> Option<(&[u8], &[u8], &'static [u8])> {
    let wanted = match preference {
        QuotePreference::Double => b'"',
        QuotePreference::Preserve => return None,
        QuotePreference::Single => b'\'',
    };

    let at = quoted(bytes, wanted)?;
    let (prefix, rest) = bytes.split_at(at);
    let triple = rest.starts_with(TRIPLE_SINGLE) || rest.starts_with(TRIPLE_DOUBLE);

    let quote: &'static [u8] = match (wanted, triple) {
        (b'"', true) => TRIPLE_DOUBLE,
        (b'"', false) => DOUBLE,
        (_, true) => TRIPLE_SINGLE,
        (_, false) => SINGLE,
    };

    let width = quote.len();

    if rest.len() < width * 2 {
        return None;
    }

    let body = &rest[width..rest.len() - width];
    let held = rest[0];

    let clashes = if triple {
        body.ends_with(&[wanted])
            || body.windows(width).any(|run| run == quote)
            || body.windows(2).any(|run| run == [b'\\', wanted])
    } else {
        body.contains(&wanted) || body.windows(2).any(|run| run == [b'\\', held])
    };

    if clashes {
        return None;
    }

    Some((prefix, body, quote))
}

pub(super) fn prefix_of(bytes: &[u8]) -> usize {
    let mut held = 0;

    while bytes.get(held).is_some_and(u8::is_ascii_alphabetic) {
        held += 1;
    }

    held
}

pub(super) fn prefix_written(prefix: &[u8]) -> ([u8; 2], usize) {
    let mut held = [0_u8; 2];
    let mut count = 0;

    if let Some(raw) = prefix.iter().find(|byte| matches!(**byte, b'R' | b'r')) {
        held[count] = *raw;
        count += 1;
    }

    if let Some(kind) = prefix
        .iter()
        .find(|byte| matches!(**byte, b'B' | b'F' | b'b' | b'f'))
    {
        held[count] = kind.to_ascii_lowercase();
        count += 1;
    }

    (held, count)
}

pub(super) fn escape_width(bytes: &[u8], offset: usize) -> usize {
    let digits = match bytes.get(offset + 1) {
        Some(b'U') => 8,
        Some(b'u') => 4,
        Some(b'x') => 2,
        _ => return 0,
    };

    let end = offset + 2 + digits;

    if end > bytes.len() || !bytes[offset + 2..end].iter().all(u8::is_ascii_hexdigit) {
        return 0;
    }

    end - offset
}

pub(super) fn pragmatic(bytes: &[u8]) -> bool {
    let Some(body) = bytes.strip_prefix(b"#") else {
        return false;
    };

    let at = body
        .iter()
        .position(|byte| !matches!(byte, b' ' | b'\t'))
        .unwrap_or(body.len());

    let rest = &body[at..];

    rest.get(..4)
        .is_some_and(|word| word.eq_ignore_ascii_case(b"noqa"))
        || rest.starts_with(b"flake8:")
        || rest.starts_with(b"isort:")
        || rest.starts_with(b"pylint:")
        || rest.starts_with(b"pyright:")
        || rest.starts_with(b"ruff:")
        || rest.starts_with(b"type:")
}

pub(super) const fn other_quote(quote: u8) -> u8 {
    if quote == b'"' { b'\'' } else { b'"' }
}

pub(super) const fn preferring(quote: u8) -> QuotePreference {
    if quote == b'"' {
        QuotePreference::Double
    } else {
        QuotePreference::Single
    }
}

pub(super) const fn wanted_quote(preference: QuotePreference) -> u8 {
    match preference {
        QuotePreference::Double => b'"',
        QuotePreference::Preserve => 0,
        QuotePreference::Single => b'\'',
    }
}

pub(super) fn relettered(out: &mut Buffer, bytes: &[u8], preference: QuotePreference) -> bool {
    let at = prefix_of(bytes);
    let (written, count) = prefix_written(&bytes[..at]);
    let marks = &bytes[..at];
    let raw = marks.iter().any(|byte| matches!(byte, b'R' | b'r'));
    let format = marks.iter().any(|byte| matches!(byte, b'F' | b'f'));

    if !out.push_bytes(&written[..count]) {
        return false;
    }

    match requoting(&bytes[at..], raw, format, preference) {
        Some((quote, body, rewrites)) => {
            out.push_bytes(quote)
                && if rewrites {
                    quoted_body(out, body, quote[0])
                } else {
                    escaped(out, body, raw)
                }
                && out.push_bytes(quote)
        }
        None => escaped(out, &bytes[at..], raw),
    }
}

pub(super) fn unescaped(body: &[u8], quote: u8) -> bool {
    let mut held = 0;

    while held < body.len() {
        if body[held] == b'\\' {
            held += 2;

            continue;
        }

        if body[held] == quote {
            return true;
        }

        held += 1;
    }

    false
}

pub(super) fn escapes_of(body: &[u8], quote: u8) -> u32 {
    let other = other_quote(quote);
    let mut count = 0;
    let mut held = 0;

    while held < body.len() {
        if body[held] != b'\\' {
            count += u32::from(body[held] == quote);
            held += 1;

            continue;
        }

        count += u32::from(body.get(held + 1) != Some(&other));
        held += 2;
    }

    count
}

pub(super) fn quoted_body(out: &mut Buffer, body: &[u8], quote: u8) -> bool {
    let other = other_quote(quote);
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

        let width = escape_width(body, held);

        if width > 0 {
            if !out.push_bytes(&body[held..held + 2]) {
                return false;
            }

            for byte in &body[held + 2..held + width] {
                if !out.push_bytes(&[byte.to_ascii_lowercase()]) {
                    return false;
                }
            }

            held += width;

            continue;
        }

        let Some(next) = body.get(held + 1) else {
            return out.push_bytes(b"\\");
        };

        let written = if *next == other {
            out.push_bytes(&[*next])
        } else {
            out.push_bytes(&[b'\\', *next])
        };

        if !written {
            return false;
        }

        held += 2;
    }

    true
}

pub(super) fn requoting(
    rest: &[u8],
    raw: bool,
    format: bool,
    preference: QuotePreference,
) -> Option<(&'static [u8], &[u8], bool)> {
    let wanted = match preference {
        QuotePreference::Double => b'"',
        QuotePreference::Preserve => return None,
        QuotePreference::Single => b'\'',
    };

    if rest.len() < 2 {
        return None;
    }

    if rest.starts_with(TRIPLE_DOUBLE) || rest.starts_with(TRIPLE_SINGLE) {
        return tripled(rest, wanted, format);
    }

    let orig = rest[0];

    if orig != b'"' && orig != b'\'' {
        return None;
    }

    let body = &rest[1..rest.len() - 1];

    if raw {
        if orig == wanted || unescaped(body, wanted) {
            return None;
        }

        let written: &'static [u8] = if wanted == b'"' { DOUBLE } else { SINGLE };

        return Some((written, body, false));
    }

    let other = other_quote(wanted);
    let held = escapes_of(body, wanted);
    let alone = escapes_of(body, other);

    let quote = if orig == wanted {
        if alone < held { other } else { wanted }
    } else if held <= alone {
        wanted
    } else {
        other
    };

    if format && quote != orig && body.contains(&quote) {
        return None;
    }

    let written: &'static [u8] = if quote == b'"' { DOUBLE } else { SINGLE };

    Some((written, body, true))
}

pub(super) fn fielded_quote(body: &[u8], wanted: u8) -> bool {
    let mut depth = 0_u32;
    let mut held = 0;
    let mut quotes = 0;

    while held < body.len() {
        let byte = body[held];

        if depth > 0 {
            depth -= u32::from(byte == b'}');
            depth += u32::from(byte == b'{');
            held += 1;

            continue;
        }

        if byte == b'\\' || byte == b'{' && body.get(held + 1) == Some(&b'{') {
            held += 2;
            quotes = 0;

            continue;
        }

        if byte == b'{' {
            if quotes > 0 {
                return true;
            }

            depth = 1;
            held += 1;

            continue;
        }

        quotes = if byte == wanted { quotes + 1 } else { 0 };
        held += 1;
    }

    false
}

pub(super) fn tripled(
    rest: &[u8],
    wanted: u8,
    format: bool,
) -> Option<(&'static [u8], &[u8], bool)> {
    let quote: &'static [u8] = if wanted == b'"' {
        TRIPLE_DOUBLE
    } else {
        TRIPLE_SINGLE
    };

    if rest.starts_with(quote) || rest.len() < 6 {
        return None;
    }

    let body = &rest[3..rest.len() - 3];

    if body.ends_with(&[wanted]) || body.windows(3).any(|run| run == quote) {
        return None;
    }

    if format && fielded_quote(body, wanted) {
        return None;
    }

    Some((quote, body, false))
}

pub(super) fn escaped(out: &mut Buffer, bytes: &[u8], raw: bool) -> bool {
    if raw {
        return out.push_bytes(bytes);
    }

    let mut held = 0;

    while held < bytes.len() {
        if bytes[held] != b'\\' {
            if !out.push_bytes(&bytes[held..=held]) {
                return false;
            }

            held += 1;

            continue;
        }

        let width = escape_width(bytes, held);

        if width == 0 {
            let step = 2.min(bytes.len() - held);

            if !out.push_bytes(&bytes[held..held + step]) {
                return false;
            }

            held += step;

            continue;
        }

        if !out.push_bytes(&bytes[held..held + 2]) {
            return false;
        }

        for byte in &bytes[held + 2..held + width] {
            if !out.push_bytes(&[byte.to_ascii_lowercase()]) {
                return false;
            }
        }

        held += width;
    }

    true
}

pub(super) fn mantissa(out: &mut Buffer, bytes: &[u8]) -> bool {
    let Some(at) = bytes.iter().position(|byte| *byte == b'.') else {
        return out.push_bytes(bytes);
    };

    let (before, after) = bytes.split_at(at);
    let leading: &[u8] = if before.is_empty() { b"0" } else { before };
    let trailing: &[u8] = if after.len() == 1 { b"0" } else { &after[1..] };

    out.push_bytes(leading) && out.push_bytes(b".") && out.push_bytes(trailing)
}

pub(super) fn numbered(out: &mut Buffer, bytes: &[u8]) -> bool {
    let based = bytes.len() > 2
        && bytes.first() == Some(&b'0')
        && bytes.get(1).is_some_and(u8::is_ascii_alphabetic);

    if based {
        let marker = *bytes.get(1).unwrap_or(&b'x');
        let upper = matches!(marker, b'X' | b'x');

        if !out.push_bytes(&[b'0', marker.to_ascii_lowercase()]) {
            return false;
        }

        for byte in &bytes[2..] {
            let held = if upper {
                byte.to_ascii_uppercase()
            } else {
                *byte
            };

            if !out.push_bytes(&[held]) {
                return false;
            }
        }

        return true;
    }

    let (body, suffix) = match bytes.last() {
        Some(b'J' | b'j') => (&bytes[..bytes.len() - 1], b"j".as_slice()),
        _ => (bytes, b"".as_slice()),
    };

    let Some(at) = body.iter().position(|byte| matches!(*byte, b'E' | b'e')) else {
        return mantissa(out, body) && out.push_bytes(suffix);
    };

    let held = &body[at + 1..];
    let exponent = held.strip_prefix(b"+").unwrap_or(held);

    mantissa(out, &body[..at])
        && out.push_bytes(b"e")
        && out.push_bytes(exponent)
        && out.push_bytes(suffix)
}

pub(super) fn quote_edges(
    bytes: &[u8],
    offset: u32,
    preference: QuotePreference,
) -> Option<(u32, u32, &'static [u8])> {
    let (prefix, body, quote) = requoted(bytes, preference)?;
    let at = offset + count_of(prefix.len());

    Some((at, at + count_of(quote.len() + body.len()), quote))
}
