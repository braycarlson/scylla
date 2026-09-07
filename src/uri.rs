use crate::bounded::{BoundedVec, Bytes as _};

pub const SCHEME: &[u8] = b"file://";
const AUTHORITY_MARK: &[u8] = b"://";
const HEX_BASE: u8 = 16;
const HEX_DIGITS: &[u8; 16] = b"0123456789ABCDEF";
const HEX_LETTER: u8 = 10;
const LOCALHOST: &[u8] = b"localhost";
const NIBBLE_MASK: u8 = 0x0F;
const NIBBLE_SHIFT: u32 = 4;

pub fn decoded(text: &[u8], out: &mut BoundedVec<u8>) -> bool {
    let mut index = 0_usize;

    while index < text.len() {
        let byte = text[index];

        if byte == b'%'
            && let (Some(high), Some(low)) = (
                text.get(index + 1).copied().and_then(nibble_of),
                text.get(index + 2).copied().and_then(nibble_of),
            )
        {
            if !out.push(high * HEX_BASE + low) {
                return false;
            }

            index += 3;

            continue;
        }

        if !out.push(byte) {
            return false;
        }

        index += 1;
    }

    true
}

pub fn encoded(path: &[u8], out: &mut BoundedVec<u8>) -> bool {
    for byte in path {
        let held = if *byte == b'\\' { b'/' } else { *byte };

        if is_unreserved(held) {
            if !out.push(held) {
                return false;
            }

            continue;
        }

        let high = HEX_DIGITS[usize::from(held >> NIBBLE_SHIFT)];
        let low = HEX_DIGITS[usize::from(held & NIBBLE_MASK)];

        if !out.push_bytes(&[b'%', high, low]) {
            return false;
        }
    }

    true
}

pub const fn is_unreserved(byte: u8) -> bool {
    byte.is_ascii_alphanumeric() || matches!(byte, b'/' | b'-' | b'.' | b'_' | b'~' | b':')
}

pub fn path_write(uri: &[u8], out: &mut BoundedVec<u8>) -> bool {
    out.clear();

    let Some(body) = body_of(uri) else {
        return false;
    };

    if !decoded(body, out) {
        return false;
    }

    if is_drive_rooted(out) {
        let shifted = out.shift_tail(1, 0);

        assert!(shifted);
    }

    true
}

pub fn uri_write(path: &[u8], out: &mut BoundedVec<u8>) -> bool {
    out.clear();

    if !out.push_bytes(SCHEME) {
        return false;
    }

    if path.first() != Some(&b'/') && !out.push(b'/') {
        return false;
    }

    encoded(path, out)
}

fn body_of(uri: &[u8]) -> Option<&[u8]> {
    let Some(rest) = uri.strip_prefix(SCHEME) else {
        if uri
            .windows(AUTHORITY_MARK.len())
            .any(|held| held == AUTHORITY_MARK)
        {
            return None;
        }

        return Some(uri);
    };

    match rest.strip_prefix(LOCALHOST) {
        Some(path) if path.first() == Some(&b'/') => Some(path),
        Some(_) | None => Some(rest),
    }
}

fn is_drive_rooted(path: &[u8]) -> bool {
    path.first() == Some(&b'/')
        && path.get(1).is_some_and(u8::is_ascii_alphabetic)
        && matches!(path.get(2), Some(b':' | b'|'))
}

const fn nibble_of(byte: u8) -> Option<u8> {
    match byte {
        b'0'..=b'9' => Some(byte - b'0'),
        b'a'..=b'f' => Some(byte - b'a' + HEX_LETTER),
        b'A'..=b'F' => Some(byte - b'A' + HEX_LETTER),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::allocation;

    const BYTES_MAX: u32 = 1 << 10;

    fn path_of(uri: &str, out: &mut BoundedVec<u8>) -> Option<String> {
        if !path_write(uri.as_bytes(), out) {
            return None;
        }

        Some(String::from_utf8_lossy(out).into_owned())
    }

    fn uri_of(path: &str, out: &mut BoundedVec<u8>) -> Option<String> {
        if !uri_write(path.as_bytes(), out) {
            return None;
        }

        Some(String::from_utf8_lossy(out).into_owned())
    }

    #[test]
    fn a_uri_reads_back_as_its_path() {
        let mut out = BoundedVec::reserve(BYTES_MAX);

        assert_eq!(
            path_of("file:///home/one/page.html", &mut out).as_deref(),
            Some("/home/one/page.html")
        );

        assert_eq!(
            path_of("file://localhost/home/one/page.html", &mut out).as_deref(),
            Some("/home/one/page.html")
        );

        assert_eq!(
            path_of("file://localhostile/page.html", &mut out).as_deref(),
            Some("localhostile/page.html")
        );

        assert_eq!(
            path_of("file:///home/one%20two/a%2Eb%2ec.html", &mut out).as_deref(),
            Some("/home/one two/a.b.c.html")
        );

        assert_eq!(path_of("/tmp/a.rs", &mut out).as_deref(), Some("/tmp/a.rs"));
    }

    #[test]
    fn an_escape_that_is_not_two_digits_is_left_alone() {
        let mut out = BoundedVec::reserve(BYTES_MAX);

        assert_eq!(
            path_of("file:///tmp/100%.rs", &mut out).as_deref(),
            Some("/tmp/100%.rs")
        );

        assert_eq!(path_of("file:///tmp/%zz.rs", &mut out).as_deref(), Some("/tmp/%zz.rs"));
        assert_eq!(path_of("file:///tmp/a%2", &mut out).as_deref(), Some("/tmp/a%2"));
    }

    #[test]
    fn a_windows_drive_loses_the_uris_own_slash() {
        let mut out = BoundedVec::reserve(BYTES_MAX);

        assert_eq!(
            path_of("file:///C:/one/page.html", &mut out).as_deref(),
            Some("C:/one/page.html")
        );

        assert_eq!(
            path_of("file:///c%3a/code/a.rs", &mut out).as_deref(),
            Some("c:/code/a.rs")
        );

        assert_eq!(
            path_of("file:///C|/code/a.rs", &mut out).as_deref(),
            Some("C|/code/a.rs")
        );
    }

    #[test]
    fn another_scheme_names_no_file() {
        let mut out = BoundedVec::reserve(BYTES_MAX);

        assert!(path_of("http://example.com/page.html", &mut out).is_none());
        assert!(path_of("untitled://a", &mut out).is_none());
    }

    #[test]
    fn a_path_writes_back_as_a_uri() {
        let mut out = BoundedVec::reserve(BYTES_MAX);

        assert_eq!(
            uri_of("/home/one/page.html", &mut out).as_deref(),
            Some("file:///home/one/page.html")
        );

        assert_eq!(
            uri_of("/home/one two/page.html", &mut out).as_deref(),
            Some("file:///home/one%20two/page.html")
        );

        assert_eq!(
            uri_of("C:\\one\\page.html", &mut out).as_deref(),
            Some("file:///C:/one/page.html")
        );
    }

    #[test]
    fn every_path_survives_the_round_trip() {
        let mut uri = BoundedVec::reserve(BYTES_MAX);
        let mut path = BoundedVec::reserve(BYTES_MAX);

        allocation::frozen(|| {
            for held in [
                "/home/one/page.html",
                "/home/one two/page.html",
                "/home/one+two/page.html",
                "/home/one%two/page.html",
                "C:/one/page.html",
            ] {
                assert!(uri_write(held.as_bytes(), &mut uri));
                assert!(path_write(&uri, &mut path));
                assert_eq!(&*path, held.as_bytes(), "{held}");
            }
        });
    }

    #[test]
    fn a_path_that_outgrows_the_buffer_is_refused() {
        let mut out = BoundedVec::reserve(8);

        assert!(!path_write(b"file:///home/one/page.html", &mut out));
        assert!(!uri_write(b"/a", &mut out));
        assert!(uri_write(b"", &mut out));
        assert_eq!(&*out, b"file:///");
    }
}
