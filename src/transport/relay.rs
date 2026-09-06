use std::io::{BufReader, Error, ErrorKind, Read, Result, Write};
use std::sync::{Condvar, Mutex, MutexGuard};
use std::thread::spawn;

use crate::bounded::BoundedVec;
use crate::transport::{Incoming, Transport, framed};

pub const CANCEL_IDS_MAX: usize = 256;
const READ_BUFFER_BYTES: usize = 1 << 16;

pub struct Relay {
    shared: &'static Shared,
}

struct Cancelled {
    count: usize,
    held: [i64; CANCEL_IDS_MAX],
    next: usize,
}

struct Feeder {
    shared: &'static Shared,
}

struct Ring {
    bytes: BoundedVec<u8>,
    closed: bool,
    faulted: bool,
    head: usize,
    used: usize,
}

struct Shared {
    cancelled: Mutex<Cancelled>,
    drained: Condvar,
    filled: Condvar,
    ring: Mutex<Ring>,
}

impl Cancelled {
    fn push(&mut self, id: i64) {
        if self.held[..self.count].contains(&id) {
            return;
        }

        self.held[self.next] = id;
        self.next = wrapped(self.next + 1, CANCEL_IDS_MAX);
        self.count = (self.count + 1).min(CANCEL_IDS_MAX);
    }

    fn take(&mut self, id: i64) -> bool {
        let Some(at) = self.held[..self.count]
            .iter()
            .position(|known| *known == id)
        else {
            return false;
        };

        let last = self.count - 1;

        self.held.swap(at, last);
        self.count = last;
        self.next = last;

        true
    }
}

impl Relay {
    pub fn spawn<In, Inspect>(
        source: In,
        request_bytes_max: u32,
        ring_bytes: u32,
        inspect: Inspect,
    ) -> Self
    where
        In: Read + Send + 'static,
        Inspect: FnMut(&[u8]) -> Option<i64> + Send + 'static,
    {
        assert!(ring_bytes > 0);
        assert!(!crate::allocation::is_frozen());

        let mut bytes = BoundedVec::reserve(ring_bytes);

        for _ in 0..ring_bytes {
            bytes.push_assert(0);
        }

        let shared: &'static Shared = Box::leak(Box::new(Shared {
            cancelled: Mutex::new(Cancelled {
                count: 0,
                held: [0; CANCEL_IDS_MAX],
                next: 0,
            }),
            drained: Condvar::new(),
            filled: Condvar::new(),
            ring: Mutex::new(Ring {
                bytes,
                closed: false,
                faulted: false,
                head: 0,
                used: 0,
            }),
        }));

        let feeder = Feeder { shared };
        let transport = Transport::reserve(request_bytes_max);
        let reader = BufReader::with_capacity(READ_BUFFER_BYTES, source);
        let _worker = spawn(move || serve(feeder, reader, transport, inspect));

        Self { shared }
    }

    pub fn cancelled(&self, id: i64) -> bool {
        locked(&self.shared.cancelled).take(id)
    }
}

impl Ring {
    fn capacity(&self) -> usize {
        self.bytes.len()
    }

    fn pop(&mut self, out: &mut [u8]) -> usize {
        let capacity = self.capacity();
        let wanted = out.len().min(self.used);
        let first = wanted.min(capacity - self.head);
        let second = wanted - first;

        out[..first].copy_from_slice(&self.bytes[self.head..self.head + first]);
        out[first..wanted].copy_from_slice(&self.bytes[..second]);

        self.head = wrapped(self.head + wanted, capacity);
        self.used -= wanted;

        wanted
    }

    fn push(&mut self, bytes: &[u8]) -> usize {
        let capacity = self.capacity();
        let wanted = bytes.len().min(capacity - self.used);
        let tail = wrapped(self.head + self.used, capacity);
        let first = wanted.min(capacity - tail);
        let second = wanted - first;

        self.bytes[tail..tail + first].copy_from_slice(&bytes[..first]);
        self.bytes[..second].copy_from_slice(&bytes[first..wanted]);

        self.used += wanted;

        wanted
    }
}

impl Feeder {
    fn close(&self, faulted: bool) {
        let mut ring = locked(&self.shared.ring);

        ring.closed = true;
        ring.faulted = faulted;

        drop(ring);

        self.shared.filled.notify_all();
    }
}

impl Read for Relay {
    fn read(&mut self, buf: &mut [u8]) -> Result<usize> {
        if buf.is_empty() {
            return Ok(0);
        }

        let mut ring = locked(&self.shared.ring);

        while ring.used == 0 {
            if ring.faulted {
                return Err(Error::new(
                    ErrorKind::BrokenPipe,
                    "the client stream failed",
                ));
            }

            if ring.closed {
                return Ok(0);
            }

            ring = wait(&self.shared.filled, ring);
        }

        let read = ring.pop(buf);

        drop(ring);

        self.shared.drained.notify_one();

        Ok(read)
    }
}

impl Write for Feeder {
    fn flush(&mut self) -> Result<()> {
        Ok(())
    }

    fn write(&mut self, buf: &[u8]) -> Result<usize> {
        if buf.is_empty() {
            return Ok(0);
        }

        let mut ring = locked(&self.shared.ring);

        while !ring.closed {
            let written = ring.push(buf);

            if written > 0 {
                drop(ring);

                self.shared.filled.notify_one();

                return Ok(written);
            }

            ring = wait(&self.shared.drained, ring);
        }

        drop(ring);

        Err(Error::new(
            ErrorKind::BrokenPipe,
            "the session stopped reading",
        ))
    }
}

fn locked<T>(held: &Mutex<T>) -> MutexGuard<'_, T> {
    match held.lock() {
        Ok(guard) => guard,
        Err(poisoned) => poisoned.into_inner(),
    }
}

fn serve<In, Inspect>(
    mut feeder: Feeder,
    mut source: BufReader<In>,
    mut transport: Transport,
    mut inspect: Inspect,
) where
    In: Read,
    Inspect: FnMut(&[u8]) -> Option<i64>,
{
    let mut incoming = transport.read(&mut source);

    while matches!(incoming, Incoming::Message | Incoming::TooLarge(_)) {
        if incoming == Incoming::Message {
            let body = transport.body();

            if let Some(id) = inspect(body) {
                locked(&feeder.shared.cancelled).push(id);
            }

            if framed(&mut feeder, body).is_err() {
                return;
            }
        }

        incoming = transport.read(&mut source);
    }

    match incoming {
        Incoming::Malformed => {
            let _written = feeder.write_all(b"\r\n");

            feeder.close(false);
        }
        Incoming::Failed => feeder.close(true),
        Incoming::Closed | Incoming::Message | Incoming::TooLarge(_) => feeder.close(false),
    }
}

fn wait<'held, T>(signal: &Condvar, guard: MutexGuard<'held, T>) -> MutexGuard<'held, T> {
    match signal.wait(guard) {
        Ok(held) => held,
        Err(poisoned) => poisoned.into_inner(),
    }
}

const fn wrapped(at: usize, capacity: usize) -> usize {
    if at >= capacity {
        return at - capacity;
    }

    at
}

#[cfg(test)]
mod tests {
    use std::io::Cursor;

    use super::*;
    use crate::allocation;

    const CANCEL: &str = r#"{"jsonrpc":"2.0","method":"$/cancelRequest","params":{"id":1}}"#;
    const FIRST: &str = r#"{"jsonrpc":"2.0","id":1,"method":"textDocument/hover"}"#;
    const REQUEST_BYTES_MAX: u32 = 1 << 12;
    const SECOND: &str = r#"{"jsonrpc":"2.0","id":2,"method":"textDocument/hover"}"#;

    fn framed_all(bodies: &[&str]) -> Vec<u8> {
        let mut out = Vec::new();

        for body in bodies {
            out.extend_from_slice(format!("Content-Length: {}\r\n\r\n", body.len()).as_bytes());
            out.extend_from_slice(body.as_bytes());
        }

        out
    }

    fn inspect(body: &[u8]) -> Option<i64> {
        body.windows(CANCEL.len())
            .any(|held| held == CANCEL.as_bytes())
            .then_some(1)
    }

    fn relayed(source: Vec<u8>, ring_bytes: u32) -> (Relay, Vec<u8>) {
        let mut out = vec![0_u8; source.len() + 1];
        let mut relay = Relay::spawn(Cursor::new(source), REQUEST_BYTES_MAX, ring_bytes, inspect);

        let filled = allocation::frozen(|| {
            let mut filled = 0_usize;

            for _ in 0..=out.len() {
                let read = relay.read(&mut out[filled..]).unwrap_or(0);

                if read == 0 {
                    return filled;
                }

                filled += read;
            }

            filled
        });

        out.truncate(filled);

        (relay, out)
    }

    #[test]
    fn a_cancel_read_ahead_marks_its_request_before_the_session_reaches_it() {
        let source = framed_all(&[FIRST, CANCEL, SECOND]);
        let (relay, out) = relayed(source.clone(), 1 << 12);

        assert_eq!(out, source);
        assert!(relay.cancelled(1));
        assert!(!relay.cancelled(1));
        assert!(!relay.cancelled(2));
    }

    #[test]
    fn a_ring_smaller_than_one_message_still_streams_it_through() {
        let source = framed_all(&[FIRST, SECOND]);
        let (_relay, out) = relayed(source.clone(), 16);

        assert_eq!(out, source);
    }

    #[test]
    fn a_closed_source_closes_the_relay() {
        let (_relay, out) = relayed(Vec::new(), 1 << 12);

        assert!(out.is_empty());
    }

    #[test]
    fn a_malformed_frame_reaches_the_session_as_malformed() {
        let mut relay = Relay::spawn(
            Cursor::new(b"nonsense\r\n\r\n".to_vec()),
            REQUEST_BYTES_MAX,
            1 << 12,
            inspect,
        );

        let mut transport = Transport::reserve(REQUEST_BYTES_MAX);

        let (first, second) = allocation::frozen(|| {
            let first = transport.read(&mut relay);
            let second = transport.read(&mut relay);

            (first, second)
        });

        assert_eq!(first, Incoming::Malformed);
        assert_eq!(second, Incoming::Closed);
    }

    #[test]
    fn a_cancel_table_remembers_each_id_once_and_spends_it_on_take() {
        let mut cancelled = Cancelled {
            count: 0,
            held: [0; CANCEL_IDS_MAX],
            next: 0,
        };

        cancelled.push(7);
        cancelled.push(7);
        cancelled.push(9);

        assert_eq!(cancelled.count, 2);
        assert!(cancelled.take(7));
        assert!(!cancelled.take(7));
        assert!(cancelled.take(9));
        assert_eq!(cancelled.count, 0);
    }

    #[test]
    fn a_full_cancel_table_overwrites_its_oldest_entry() {
        let mut cancelled = Cancelled {
            count: 0,
            held: [0; CANCEL_IDS_MAX],
            next: 0,
        };

        for id in 0..=CANCEL_IDS_MAX {
            cancelled.push(i64::try_from(id).expect("the id fits"));
        }

        assert_eq!(cancelled.count, CANCEL_IDS_MAX);
        assert!(!cancelled.take(0));
        assert!(cancelled.take(i64::try_from(CANCEL_IDS_MAX).expect("the id fits")));
    }
}
