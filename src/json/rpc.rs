use crate::bounded::Bytes;
use crate::json::{Cursor, Kind, Writer};

pub const ERROR_INTERNAL: i64 = -32603;
pub const ERROR_INVALID_PARAMS: i64 = -32602;
pub const ERROR_INVALID_REQUEST: i64 = -32600;
pub const ERROR_METHOD_NOT_FOUND: i64 = -32601;
pub const ERROR_PARSE: i64 = -32700;
pub const ERROR_REQUEST_CANCELLED: i64 = -32800;
pub const ERROR_SERVER_NOT_INITIALIZED: i64 = -32002;
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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::allocation;
    use crate::bounded::BoundedString;
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
