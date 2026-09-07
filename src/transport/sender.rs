use std::io::{Result, Write};

use crate::bounded::Buffer;
use crate::json::rpc::{self, Id};
use crate::json::{Pen, Writer};
use crate::transport::framed;

pub const BODY_BYTES_MIN: u32 = 256;

#[derive(Debug)]
pub struct Sender {
    body: Buffer,
    writer: Writer,
}

impl Sender {
    pub fn capacity(&self) -> u32 {
        self.body.capacity()
    }

    pub fn notify<Out, Body>(&mut self, out: &mut Out, method: &[u8], body: Body) -> Result<bool>
    where
        Body: FnOnce(&mut Pen<'_, Buffer>),
        Out: Write,
    {
        self.send(out, |pen| rpc::notify(pen, method, body))
    }

    pub fn request<Out, Body>(
        &mut self,
        out: &mut Out,
        id: i64,
        method: &[u8],
        body: Body,
    ) -> Result<bool>
    where
        Body: FnOnce(&mut Pen<'_, Buffer>),
        Out: Write,
    {
        self.send(out, |pen| rpc::request(pen, id, method, body))
    }

    pub fn reserve(body_bytes_max: u32, depth_max: u32) -> Self {
        assert!(body_bytes_max >= BODY_BYTES_MIN);
        assert!(!crate::allocation::is_frozen());

        Self {
            body: Buffer::reserve(body_bytes_max),
            writer: Writer::reserve(depth_max),
        }
    }

    pub fn respond<Out, Body>(&mut self, out: &mut Out, id: Id<'_>, body: Body) -> Result<()>
    where
        Body: FnOnce(&mut Pen<'_, Buffer>),
        Out: Write,
    {
        assert!(id.is_request());

        if self.staged(|pen| rpc::respond(pen, id, body)) {
            return framed(out, self.body.as_bytes());
        }

        crate::log_line!(
            "an answer outgrew the {} byte transport buffer; the request takes an error instead",
            self.body.capacity()
        );

        let substituted = self.staged(|pen| rpc::respond_oversize(pen, id));

        assert!(substituted);

        framed(out, self.body.as_bytes())
    }

    pub fn respond_error<Out>(
        &mut self,
        out: &mut Out,
        id: Id<'_>,
        code: i64,
        message: &[u8],
    ) -> Result<bool>
    where
        Out: Write,
    {
        self.send(out, |pen| rpc::respond_error(pen, id, code, message))
    }

    pub fn respond_null<Out>(&mut self, out: &mut Out, id: Id<'_>) -> Result<bool>
    where
        Out: Write,
    {
        self.send(out, |pen| rpc::respond_null(pen, id))
    }

    pub fn send<Out, Body>(&mut self, out: &mut Out, body: Body) -> Result<bool>
    where
        Body: FnOnce(&mut Pen<'_, Buffer>),
        Out: Write,
    {
        if !self.staged(body) {
            return Ok(false);
        }

        framed(out, self.body.as_bytes())?;

        Ok(true)
    }

    fn staged<Body>(&mut self, body: Body) -> bool
    where
        Body: FnOnce(&mut Pen<'_, Buffer>),
    {
        self.body.clear();

        let mut pen = Pen::bound(&mut self.writer, &mut self.body);

        body(&mut pen);

        pen.finish()
    }
}

#[cfg(test)]
mod tests {
    use core::str::from_utf8;
    use std::io::{Error, ErrorKind};

    use super::*;
    use crate::allocation;
    use crate::json::DEPTH_MAX;
    use crate::json::rpc::{ERROR_METHOD_NOT_FOUND, OVERSIZE_MESSAGE};

    const BODY_BYTES_MAX: u32 = 1 << 10;

    struct Refusing;

    impl Write for Refusing {
        fn flush(&mut self) -> Result<()> {
            Ok(())
        }

        fn write(&mut self, _buffer: &[u8]) -> Result<usize> {
            Err(Error::from(ErrorKind::BrokenPipe))
        }
    }

    fn body_of(framed: &[u8]) -> &str {
        let text = from_utf8(framed).expect("a framed message is utf-8");
        let at = text
            .find("\r\n\r\n")
            .expect("the frame carries a blank line");

        text.get(at + 4..).unwrap_or_default()
    }

    #[test]
    fn a_response_is_framed_with_its_length() {
        let mut sender = Sender::reserve(BODY_BYTES_MAX, DEPTH_MAX);
        let mut out = Vec::with_capacity(256);

        allocation::frozen(|| {
            sender
                .respond_null(&mut out, Id::Number(3))
                .expect("the answer is written");
        });

        let body = body_of(&out);

        assert_eq!(body, r#"{"jsonrpc":"2.0","id":3,"result":null}"#);
        assert!(out.starts_with(format!("Content-Length: {}\r\n\r\n", body.len()).as_bytes()));
    }

    #[test]
    fn every_envelope_kind_writes_through_the_sender() {
        let mut sender = Sender::reserve(BODY_BYTES_MAX, DEPTH_MAX);
        let mut out = Vec::with_capacity(1 << 10);

        allocation::frozen(|| {
            let sent = sender
                .notify(&mut out, b"exit", |pen| pen.null())
                .expect("the notification is written");

            assert!(sent);
            assert_eq!(body_of(&out), r#"{"jsonrpc":"2.0","method":"exit","params":null}"#);

            out.clear();

            let asked = sender
                .request(&mut out, 4, b"workspace/configuration", |pen| pen.null())
                .expect("the request is written");

            assert!(asked);

            assert_eq!(
                body_of(&out),
                r#"{"jsonrpc":"2.0","id":4,"method":"workspace/configuration","params":null}"#
            );

            out.clear();

            let refused = sender
                .respond_error(&mut out, Id::Number(2), ERROR_METHOD_NOT_FOUND, b"no")
                .expect("the error is written");

            assert!(refused);

            assert_eq!(
                body_of(&out),
                r#"{"jsonrpc":"2.0","id":2,"error":{"code":-32601,"message":"no"}}"#
            );

            out.clear();

            let answered = sender
                .respond(&mut out, Id::Text(b"seven"), |pen| pen.raw(b"[1]"))
                .is_ok();

            assert!(answered);
            assert_eq!(body_of(&out), r#"{"jsonrpc":"2.0","id":"seven","result":[1]}"#);
        });
    }

    #[test]
    fn a_body_that_does_not_fit_is_not_sent() {
        let mut sender = Sender::reserve(BODY_BYTES_MIN, DEPTH_MAX);
        let mut out = Vec::with_capacity(64);
        let long = "x".repeat(BODY_BYTES_MIN as usize);

        let sent = allocation::frozen(|| {
            sender.notify(&mut out, b"window/logMessage", |pen| {
                pen.string(long.as_bytes());
            })
        })
        .expect("nothing is written");

        assert!(!sent);
        assert!(out.is_empty());
        assert_eq!(sender.capacity(), BODY_BYTES_MIN);
    }

    #[test]
    fn an_answer_that_does_not_fit_becomes_an_internal_error() {
        let mut sender = Sender::reserve(BODY_BYTES_MIN, DEPTH_MAX);
        let mut out = Vec::with_capacity(512);
        let long = "x".repeat(BODY_BYTES_MIN as usize);

        allocation::frozen(|| {
            sender
                .respond(&mut out, Id::Number(1), |pen| pen.string(long.as_bytes()))
                .expect("the substitute is written");
        });

        let expected = format!(
            r#"{{"jsonrpc":"2.0","id":1,"error":{{"code":-32603,"message":"{}"}}}}"#,
            from_utf8(OVERSIZE_MESSAGE).expect("the message is utf-8")
        );

        assert_eq!(body_of(&out), expected);
    }

    #[test]
    fn a_failed_write_reaches_the_caller() {
        let mut sender = Sender::reserve(BODY_BYTES_MAX, DEPTH_MAX);
        let mut out = Refusing;

        let failed = allocation::frozen(|| {
            let sent = sender.respond_null(&mut out, Id::Number(1));
            let answered = sender.respond(&mut out, Id::Number(1), |pen| pen.null());

            sent.is_err() && answered.is_err()
        });

        assert!(failed);
    }
}
