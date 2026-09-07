use crate::bounded::Bytes;
use crate::json::{Cursor, Kind, Pen, Writer};

pub const ERROR_INTERNAL: i64 = -32603;
pub const ERROR_INVALID_PARAMS: i64 = -32602;
pub const ERROR_INVALID_REQUEST: i64 = -32600;
pub const ERROR_METHOD_NOT_FOUND: i64 = -32601;
pub const ERROR_PARSE: i64 = -32700;
pub const ERROR_REQUEST_CANCELLED: i64 = -32800;
pub const ERROR_SERVER_NOT_INITIALIZED: i64 = -32002;
pub const OVERSIZE_MESSAGE: &[u8] = b"the answer is larger than the transport buffer";
pub const VERSION: &[u8] = b"2.0";

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub enum Id<'json> {
    #[default]
    Absent,
    Number(i64),
    Text(&'json [u8]),
}

#[derive(Clone, Copy, Debug)]
pub struct Envelope<'json> {
    pub id: Id<'json>,
    pub method: Option<&'json [u8]>,
    pub params: Option<Cursor<'json>>,
    pub result: Option<Cursor<'json>>,
}

impl<'json> Id<'json> {
    pub const fn equals(self, value: i64) -> bool {
        matches!(self, Self::Number(found) if found == value)
    }

    pub const fn is_request(self) -> bool {
        !matches!(self, Self::Absent)
    }

    pub fn of(root: Cursor<'json>) -> Option<Self> {
        let Some(held) = root.member(b"id") else {
            return Some(Self::Absent);
        };

        match held.kind()? {
            Kind::Null => Some(Self::Absent),
            Kind::Number => held.number().map(Self::Number),
            Kind::String => held.raw().map(Self::Text),
            Kind::Array | Kind::False | Kind::Object | Kind::True => None,
        }
    }

    pub fn write<W>(self, writer: &mut Writer, out: &mut W) -> bool
    where
        W: Bytes,
    {
        match self {
            Self::Absent => writer.null(out),
            Self::Number(value) => writer.number(out, value),
            Self::Text(text) => writer.string_escaped(out, text),
        }
    }

    pub fn write_to<W>(self, pen: &mut Pen<'_, W>)
    where
        W: Bytes,
    {
        match self {
            Self::Absent => pen.null(),
            Self::Number(value) => pen.number(value),
            Self::Text(text) => pen.string_escaped(text),
        }
    }
}

impl<'json> Envelope<'json> {
    pub const fn is_request(&self) -> bool {
        self.method.is_some() && self.id.is_request()
    }

    pub const fn is_response(&self) -> bool {
        self.method.is_none()
    }

    pub fn of(root: Cursor<'json>) -> Option<Self> {
        if root.kind() != Some(Kind::Object) {
            return None;
        }

        let method = match root.member(b"method") {
            None => None,
            Some(held) if held.kind() == Some(Kind::String) => held.raw(),
            Some(_) => return None,
        };

        Some(Self {
            id: Id::of(root)?,
            method,
            params: root.member(b"params"),
            result: root.member(b"result"),
        })
    }
}

pub fn notify<W, Body>(pen: &mut Pen<'_, W>, method: &[u8], body: Body)
where
    Body: FnOnce(&mut Pen<'_, W>),
    W: Bytes,
{
    assert!(!method.is_empty());

    pen.object_open();
    pen.key(b"jsonrpc");
    pen.string(VERSION);
    pen.key(b"method");
    pen.string(method);
    pen.key(b"params");

    body(pen);

    pen.object_close();
}

pub fn request<W, Body>(pen: &mut Pen<'_, W>, id: i64, method: &[u8], body: Body)
where
    Body: FnOnce(&mut Pen<'_, W>),
    W: Bytes,
{
    assert!(!method.is_empty());

    pen.object_open();
    pen.key(b"jsonrpc");
    pen.string(VERSION);
    pen.key(b"id");
    pen.number(id);
    pen.key(b"method");
    pen.string(method);
    pen.key(b"params");

    body(pen);

    pen.object_close();
}

pub fn respond<W, Body>(pen: &mut Pen<'_, W>, id: Id<'_>, body: Body)
where
    Body: FnOnce(&mut Pen<'_, W>),
    W: Bytes,
{
    assert!(id.is_request());

    pen.object_open();
    pen.key(b"jsonrpc");
    pen.string(VERSION);
    pen.key(b"id");

    id.write_to(pen);

    pen.key(b"result");

    body(pen);

    pen.object_close();
}

pub fn respond_error<W>(pen: &mut Pen<'_, W>, id: Id<'_>, code: i64, message: &[u8])
where
    W: Bytes,
{
    assert!(!message.is_empty());

    pen.object_open();
    pen.key(b"jsonrpc");
    pen.string(VERSION);
    pen.key(b"id");

    id.write_to(pen);

    pen.key(b"error");
    pen.object_open();
    pen.key(b"code");
    pen.number(code);
    pen.key(b"message");
    pen.string(message);
    pen.object_close();
    pen.object_close();
}

pub fn respond_null<W>(pen: &mut Pen<'_, W>, id: Id<'_>)
where
    W: Bytes,
{
    respond(pen, id, |inner| inner.null());
}

pub fn respond_oversize<W>(pen: &mut Pen<'_, W>, id: Id<'_>)
where
    W: Bytes,
{
    respond_error(pen, id, ERROR_INTERNAL, OVERSIZE_MESSAGE);
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::allocation;
    use crate::bounded::{BoundedString, Buffer};
    use crate::json::{DEPTH_MAX, Document, Outcome};

    const NODE_COUNT_MAX: u32 = 64;

    fn parsed<'held>(
        document: &'held mut Document,
        message: &'held [u8],
    ) -> Option<Envelope<'held>> {
        if document.parse(message) != Outcome::Complete {
            return None;
        }

        Envelope::of(document.root(message)?)
    }

    #[test]
    fn a_request_carries_a_number_id_and_a_method() {
        let mut document = Document::reserve(NODE_COUNT_MAX);

        allocation::frozen(|| {
            let envelope = parsed(
                &mut document,
                br#"{"jsonrpc":"2.0","id":7,"method":"shutdown"}"#,
            )
            .expect("it parses");

            assert_eq!(envelope.id, Id::Number(7));
            assert!(envelope.id.equals(7));
            assert!(!envelope.id.equals(8));
            assert!(envelope.is_request());
            assert!(!envelope.is_response());
            assert_eq!(envelope.method, Some(b"shutdown".as_slice()));
            assert!(envelope.params.is_none());
            assert!(envelope.result.is_none());
        });
    }

    #[test]
    fn a_request_carries_a_text_id() {
        let mut document = Document::reserve(NODE_COUNT_MAX);

        allocation::frozen(|| {
            let envelope = parsed(
                &mut document,
                br#"{"jsonrpc":"2.0","id":"a-7","method":"shutdown","params":{}}"#,
            )
            .expect("it parses");

            assert_eq!(envelope.id, Id::Text(b"a-7"));
            assert!(envelope.is_request());
            assert!(envelope.params.is_some());
        });
    }

    #[test]
    fn a_notification_carries_no_id() {
        let mut document = Document::reserve(NODE_COUNT_MAX);

        allocation::frozen(|| {
            let envelope =
                parsed(&mut document, br#"{"jsonrpc":"2.0","method":"exit"}"#).expect("it parses");

            assert_eq!(envelope.id, Id::Absent);
            assert!(!envelope.is_request());
            assert!(!envelope.is_response());

            let nulled = parsed(
                &mut document,
                br#"{"jsonrpc":"2.0","id":null,"method":"exit"}"#,
            )
            .expect("it parses");

            assert_eq!(nulled.id, Id::Absent);
        });
    }

    #[test]
    fn a_response_carries_a_result_and_no_method() {
        let mut document = Document::reserve(NODE_COUNT_MAX);

        allocation::frozen(|| {
            let envelope = parsed(&mut document, br#"{"jsonrpc":"2.0","id":4,"result":[1]}"#)
                .expect("it parses");

            assert!(envelope.is_response());
            assert!(!envelope.is_request());
            assert!(envelope.id.is_request());
            assert_eq!(envelope.result.and_then(|held| held.kind()), Some(Kind::Array));
        });
    }

    #[test]
    fn a_malformed_envelope_is_refused() {
        let mut document = Document::reserve(NODE_COUNT_MAX);

        allocation::frozen(|| {
            assert!(parsed(&mut document, br#"{"jsonrpc":"2.0","method":"exit""#).is_none());
            assert!(parsed(&mut document, br#"{"jsonrpc":"2.0"} {}"#).is_none());
            assert!(parsed(&mut document, b"[1, 2]").is_none());
            assert!(parsed(&mut document, br#"{"id":1,"method":7}"#).is_none());
            assert!(parsed(&mut document, br#"{"id":[1],"method":"exit"}"#).is_none());
            assert!(parsed(&mut document, br#"{"id":true,"method":"exit"}"#).is_none());
        });
    }

    fn penned(out: &mut Buffer, write: impl FnOnce(&mut Pen<'_, Buffer>)) -> bool {
        let mut writer = Writer::reserve(DEPTH_MAX);
        let mut pen = Pen::bound(&mut writer, out);

        write(&mut pen);

        pen.finish()
    }

    fn spelled(out: &Buffer) -> &str {
        core::str::from_utf8(out.as_bytes()).expect("the envelope is utf-8")
    }

    #[test]
    fn a_response_names_the_id_it_answers() {
        let mut out = Buffer::reserve(256);

        assert!(penned(&mut out, |pen| respond_null(pen, Id::Number(3))));
        assert_eq!(spelled(&out), r#"{"jsonrpc":"2.0","id":3,"result":null}"#);

        out.clear();

        assert!(penned(&mut out, |pen| {
            respond(pen, Id::Text(b"seven"), |inner| inner.number(1));
        }));

        assert_eq!(spelled(&out), r#"{"jsonrpc":"2.0","id":"seven","result":1}"#);
    }

    #[test]
    fn a_refusal_carries_its_code_and_its_sentence() {
        let mut out = Buffer::reserve(256);

        assert!(penned(&mut out, |pen| {
            respond_error(pen, Id::Number(2), ERROR_METHOD_NOT_FOUND, b"no such method");
        }));

        assert_eq!(
            spelled(&out),
            r#"{"jsonrpc":"2.0","id":2,"error":{"code":-32601,"message":"no such method"}}"#
        );

        out.clear();

        assert!(penned(&mut out, |pen| respond_oversize(pen, Id::Absent)));

        assert_eq!(
            spelled(&out),
            r#"{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"the answer is larger than the transport buffer"}}"#
        );
    }

    #[test]
    fn a_notification_and_a_request_name_their_method() {
        let mut out = Buffer::reserve(256);

        assert!(penned(&mut out, |pen| {
            notify(pen, b"window/logMessage", |inner| {
                inner.object_open();
                inner.key(b"type");
                inner.number(3);
                inner.key(b"message");
                inner.string(b"hello");
                inner.object_close();
            });
        }));

        assert_eq!(
            spelled(&out),
            r#"{"jsonrpc":"2.0","method":"window/logMessage","params":{"type":3,"message":"hello"}}"#
        );

        out.clear();

        assert!(penned(&mut out, |pen| {
            request(pen, 9, b"client/registerCapability", |inner| inner.null());
        }));

        assert_eq!(
            spelled(&out),
            r#"{"jsonrpc":"2.0","id":9,"method":"client/registerCapability","params":null}"#
        );
    }

    #[test]
    fn an_envelope_that_outgrows_its_buffer_is_refused_whole() {
        let mut out = Buffer::reserve(16);

        assert!(!penned(&mut out, |pen| {
            respond(pen, Id::Number(1), |inner| inner.string(b"far longer than sixteen bytes"));
        }));
    }

    #[test]
    fn an_id_writes_back_as_it_was_read() {
        let mut document = Document::reserve(NODE_COUNT_MAX);
        let mut writer = Writer::reserve(DEPTH_MAX);
        let mut out = BoundedString::reserve(64);

        allocation::frozen(|| {
            for (message, expected) in [
                (br#"{"id":7,"method":"m"}"#.as_slice(), "7"),
                (br#"{"id":"a\"b","method":"m"}"#, r#""a\"b""#),
                (br#"{"method":"m"}"#, "null"),
            ] {
                let envelope = parsed(&mut document, message).expect("it parses");

                out.clear();
                writer.start();

                assert!(envelope.id.write(&mut writer, &mut out));
                assert!(writer.finish());
                assert_eq!(out.as_str(), expected);
            }
        });
    }
}
