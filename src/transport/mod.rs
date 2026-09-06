pub mod relay;

use std::io::{Error, ErrorKind, Read, Result, Write};

use crate::bounded::{BoundedVec, Buffer};
use crate::scan::{DECIMAL_BYTES_MAX, decimal_read, decimal_write, starts_with_folded};

pub const HEADER_BYTES_MAX: u32 = 256;
pub const HEADER_COUNT_MAX: u32 = 16;
const CONTENT_LENGTH: &[u8] = b"content-length";
const RETRY_COUNT_MAX: u32 = 1_024;
const SKIP_BYTES: usize = 4_096;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Incoming {
    Closed,
    Failed,
    Malformed,
    Message,
    TooLarge(u32),
}

#[derive(Debug)]
pub struct Transport {
    line: BoundedVec<u8>,
    request: Buffer,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum Line {
    Closed,
    Failed,
    Read,
    TooLong,
}

impl Transport {
    pub fn reserve(request_bytes_max: u32) -> Self {
        assert!(request_bytes_max > 0);
        assert!(!crate::allocation::is_frozen());

        Self {
            line: BoundedVec::reserve(HEADER_BYTES_MAX),
            request: Buffer::reserve(request_bytes_max),
        }
    }

    pub fn body(&self) -> &[u8] {
        self.request.as_bytes()
    }

    pub fn capacity(&self) -> u32 {
        self.request.capacity()
    }

    pub fn read<R>(&mut self, source: &mut R) -> Incoming
    where
        R: Read,
    {
        let mut length: Option<u32> = None;
        let mut ended = false;

        self.request.clear();

        for headers in 1..=HEADER_COUNT_MAX {
            match read_line(source, &mut self.line) {
                Line::Closed if headers == 1 => return Incoming::Closed,
                Line::Closed | Line::TooLong => return Incoming::Malformed,
                Line::Failed => return Incoming::Failed,
                Line::Read => {}
            }

            if self.line.is_empty() {
                ended = true;

                break;
            }

            if let Some(named) = content_length_of(&self.line) {
                length = Some(named);
            }
        }

        let (true, Some(bytes)) = (ended, length) else {
            return Incoming::Malformed;
        };

        if bytes > self.request.capacity() {
            if skipped(source, bytes) {
                return Incoming::TooLarge(bytes);
            }

            return Incoming::Failed;
        }

        match self.request.read_exact_from(source, bytes) {
            Ok(true) => Incoming::Message,
            Ok(false) => Incoming::TooLarge(bytes),
            Err(_) => Incoming::Failed,
        }
    }
}

pub fn content_length_of(line: &[u8]) -> Option<u32> {
    let colon = line.iter().position(|byte| *byte == b':')?;
    let name = line[..colon].trim_ascii();

    if name.len() != CONTENT_LENGTH.len() || !starts_with_folded(name, CONTENT_LENGTH) {
        return None;
    }

    let read = decimal_read(line[colon + 1..].trim_ascii())?;

    u32::try_from(read).ok()
}

pub fn framed<W>(out: &mut W, body: &[u8]) -> Result<()>
where
    W: Write,
{
    let mut header = [0_u8; HEADER_BYTES_MAX as usize];
    let written = header_write(&mut header, u64::try_from(body.len()).unwrap_or(u64::MAX));

    out.write_all(&header[..written])?;
    out.write_all(body)?;
    out.flush()
}

pub fn header_write(header: &mut [u8; HEADER_BYTES_MAX as usize], length: u64) -> usize {
    const PREFIX: &[u8] = b"Content-Length: ";
    const SUFFIX: &[u8] = b"\r\n\r\n";

    let mut digits = [0_u8; DECIMAL_BYTES_MAX];
    let count = decimal_write(&mut digits, length);
    let mut written = 0;

    header[..PREFIX.len()].copy_from_slice(PREFIX);
    written += PREFIX.len();

    header[written..written + count].copy_from_slice(&digits[..count]);
    written += count;

    header[written..written + SUFFIX.len()].copy_from_slice(SUFFIX);
    written += SUFFIX.len();

    assert!(written <= HEADER_BYTES_MAX as usize);

    written
}

fn byte_read<R>(source: &mut R) -> Result<Option<u8>>
where
    R: Read,
{
    let mut byte = [0_u8; 1];

    for _ in 0..RETRY_COUNT_MAX {
        match source.read(&mut byte) {
            Ok(0) => return Ok(None),
            Ok(_) => return Ok(Some(byte[0])),
            Err(error) if error.kind() == ErrorKind::Interrupted => {}
            Err(error) => return Err(error),
        }
    }

    Err(Error::from(ErrorKind::Interrupted))
}

fn read_line<R>(source: &mut R, line: &mut BoundedVec<u8>) -> Line
where
    R: Read,
{
    line.clear();

    for _ in 0..=line.capacity() {
        let held = match byte_read(source) {
            Ok(Some(byte)) => byte,
            Ok(None) if line.is_empty() => return Line::Closed,
            Ok(None) | Err(_) => return Line::Failed,
        };

        if held == b'\n' {
            if line.last() == Some(&b'\r') {
                line.truncate(line.count() - 1);
            }

            return Line::Read;
        }

        if !line.push(held) {
            return Line::TooLong;
        }
    }

    Line::TooLong
}

fn skipped<R>(source: &mut R, bytes: u32) -> bool
where
    R: Read,
{
    let mut scratch = [0_u8; SKIP_BYTES];
    let mut left = bytes as usize;

    while left > 0 {
        let want = left.min(SKIP_BYTES);

        if source.read_exact(&mut scratch[..want]).is_err() {
            return false;
        }

        left -= want;
    }

    true
}

#[cfg(test)]
mod tests {
    use core::iter::repeat_n;
    use core::str::from_utf8;

    use super::*;
    use crate::allocation;

    const REQUEST_BYTES_MAX: u32 = 1 << 12;

    fn framed_all(bodies: &[&str]) -> Vec<u8> {
        let mut out = Vec::new();

        for body in bodies {
            out.extend_from_slice(format!("Content-Length: {}\r\n\r\n", body.len()).as_bytes());
            out.extend_from_slice(body.as_bytes());
        }

        out
    }

    fn text_of(held: &Transport) -> &str {
        from_utf8(held.body()).unwrap_or("")
    }

    #[test]
    fn one_message_reads_back_byte_for_byte() {
        let source = framed_all(&[r#"{"jsonrpc":"2.0","id":1,"method":"initialize"}"#]);
        let mut held = Transport::reserve(REQUEST_BYTES_MAX);
        let mut cursor = source.as_slice();

        assert_eq!(held.read(&mut cursor), Incoming::Message);
        assert_eq!(
            text_of(&held),
            r#"{"jsonrpc":"2.0","id":1,"method":"initialize"}"#
        );
    }

    #[test]
    fn one_message_after_another_reads_in_order() {
        let source = framed_all(&[r#"{"id":1}"#, r#"{"id":2}"#, r#"{"id":3}"#]);
        let mut held = Transport::reserve(REQUEST_BYTES_MAX);
        let mut cursor = source.as_slice();

        for index in 1_u32..4_u32 {
            assert_eq!(held.read(&mut cursor), Incoming::Message);
            assert_eq!(text_of(&held), format!(r#"{{"id":{index}}}"#));
        }

        assert_eq!(held.read(&mut cursor), Incoming::Closed);
    }

    #[test]
    fn a_header_the_reader_does_not_need_is_read_past() {
        let body = r#"{"id":1}"#;

        let source = format!(
            "Content-Type: application/vscode-jsonrpc; charset=utf-8\r\nContent-Length: \
             {}\r\n\r\n{body}",
            body.len()
        );

        let mut held = Transport::reserve(REQUEST_BYTES_MAX);
        let mut cursor = source.as_bytes();

        assert_eq!(held.read(&mut cursor), Incoming::Message);
        assert_eq!(text_of(&held), body);
    }

    #[test]
    fn a_header_name_matches_whatever_case_it_is_written_in() {
        let body = r#"{"id":1}"#;
        let source = format!("content-length: {}\r\n\r\n{body}", body.len());
        let mut held = Transport::reserve(REQUEST_BYTES_MAX);
        let mut cursor = source.as_bytes();

        assert_eq!(held.read(&mut cursor), Incoming::Message);
        assert_eq!(text_of(&held), body);
    }

    #[test]
    fn a_lone_newline_terminates_a_header_too() {
        let body = r#"{"id":1}"#;
        let source = format!("Content-Length: {}\n\n{body}", body.len());
        let mut held = Transport::reserve(REQUEST_BYTES_MAX);
        let mut cursor = source.as_bytes();

        assert_eq!(held.read(&mut cursor), Incoming::Message);
        assert_eq!(text_of(&held), body);
    }

    #[test]
    fn an_empty_body_is_a_message_of_no_bytes() {
        let source = framed_all(&[""]);
        let mut held = Transport::reserve(REQUEST_BYTES_MAX);
        let mut cursor = source.as_slice();

        assert_eq!(held.read(&mut cursor), Incoming::Message);
        assert_eq!(held.body(), b"");
    }

    #[test]
    fn a_stream_that_ends_between_messages_is_a_clean_close() {
        let source = framed_all(&[r#"{"id":1}"#]);
        let mut held = Transport::reserve(REQUEST_BYTES_MAX);
        let mut cursor = source.as_slice();

        assert_eq!(held.read(&mut cursor), Incoming::Message);
        assert_eq!(held.read(&mut cursor), Incoming::Closed);
        assert_eq!(held.read(&mut cursor), Incoming::Closed);
    }

    #[test]
    fn a_message_with_no_length_is_malformed() {
        let mut held = Transport::reserve(REQUEST_BYTES_MAX);
        let mut cursor = b"Content-Type: text/plain\r\n\r\n".as_slice();

        assert_eq!(held.read(&mut cursor), Incoming::Malformed);
    }

    #[test]
    fn a_length_that_is_not_a_number_is_malformed() {
        let mut held = Transport::reserve(REQUEST_BYTES_MAX);
        let mut cursor = b"Content-Length: many\r\n\r\n".as_slice();

        assert_eq!(held.read(&mut cursor), Incoming::Malformed);
    }

    #[test]
    fn a_header_longer_than_the_line_buffer_is_malformed() {
        let mut source = Vec::from(b"Content-Length: ".as_slice());

        source.extend(repeat_n(b'0', 1_024));
        source.extend_from_slice(b"1\r\n\r\n");

        let mut held = Transport::reserve(REQUEST_BYTES_MAX);
        let mut cursor = source.as_slice();

        assert_eq!(held.read(&mut cursor), Incoming::Malformed);
    }

    #[test]
    fn a_stream_that_ends_inside_a_header_is_malformed() {
        let mut held = Transport::reserve(REQUEST_BYTES_MAX);
        let mut cursor = b"Content-Length: 8\r\n".as_slice();

        assert_eq!(held.read(&mut cursor), Incoming::Malformed);
    }

    #[test]
    fn a_body_larger_than_the_buffer_is_read_past_so_the_next_one_still_lands() {
        let long = "x".repeat(4_096);
        let source = framed_all(&[&long, r#"{"id":2}"#]);
        let mut held = Transport::reserve(64);
        let mut cursor = source.as_slice();

        assert_eq!(held.read(&mut cursor), Incoming::TooLarge(4_096));
        assert_eq!(held.read(&mut cursor), Incoming::Message);
        assert_eq!(text_of(&held), r#"{"id":2}"#);
    }

    #[test]
    fn a_body_the_stream_never_finishes_is_a_failure() {
        let mut held = Transport::reserve(REQUEST_BYTES_MAX);
        let mut cursor = b"Content-Length: 32\r\n\r\nshort".as_slice();

        assert_eq!(held.read(&mut cursor), Incoming::Failed);
    }

    #[test]
    fn a_written_message_reads_back_through_the_same_reader() {
        let body = r#"{"jsonrpc":"2.0","id":7,"result":{"ok":true}}"#;
        let mut held = Transport::reserve(REQUEST_BYTES_MAX);
        let mut out = Vec::new();

        framed(&mut out, body.as_bytes()).expect("the message is written");

        assert!(out.starts_with(format!("Content-Length: {}\r\n\r\n", body.len()).as_bytes()));

        let mut cursor = out.as_slice();

        assert_eq!(held.read(&mut cursor), Incoming::Message);
        assert_eq!(text_of(&held), body);
    }

    #[test]
    fn a_round_trip_allocates_nothing() {
        let body = r#"{"id":1,"method":"textDocument/didChange"}"#;
        let mut held = Transport::reserve(REQUEST_BYTES_MAX);
        let mut out = Vec::with_capacity(1 << 12);

        framed(&mut out, body.as_bytes()).expect("the message is written");

        let source = out.clone();

        let (outcome, matched) = allocation::frozen(|| {
            let mut cursor = source.as_slice();
            let outcome = held.read(&mut cursor);

            (outcome, held.body() == body.as_bytes())
        });

        assert_eq!(outcome, Incoming::Message);
        assert!(matched);
    }

    #[test]
    fn a_header_carries_the_length() {
        let mut header = [0_u8; HEADER_BYTES_MAX as usize];

        allocation::frozen(|| {
            let long = header_write(&mut header, 4_096);

            assert_eq!(&header[..long], b"Content-Length: 4096\r\n\r\n");

            let short = header_write(&mut header, 0);

            assert_eq!(&header[..short], b"Content-Length: 0\r\n\r\n");
        });
    }

    #[test]
    fn a_length_header_parses_case_insensitively() {
        allocation::frozen(|| {
            assert_eq!(content_length_of(b"Content-Length: 42"), Some(42));
            assert_eq!(content_length_of(b"content-length:42"), Some(42));
            assert_eq!(content_length_of(b"Content-Type: application/json"), None);
            assert_eq!(content_length_of(b"Content-Length: "), None);
            assert_eq!(content_length_of(b"Content-Length: 4a2"), None);
            assert_eq!(content_length_of(b"Content-Length: 99999999999"), None);
            assert_eq!(content_length_of(b"no colon"), None);
        });
    }
}
