use core::fmt::{self, Write as _};
use core::sync::atomic::{AtomicBool, Ordering};
use std::io::Write as _;
use std::panic::PanicHookInfo;
use std::sync::OnceLock;

pub const LINE_BYTES_MAX: usize = 1_024;
const TRUNCATION: &str = "[truncated]";
const CONTENT_BYTES_MAX: usize = LINE_BYTES_MAX - TRUNCATION.len() - 1;
static BACKTRACE_ENABLED: AtomicBool = AtomicBool::new(false);
static PREFIX: OnceLock<&'static str> = OnceLock::new();

#[macro_export]
macro_rules! log_line {
    ($($argument:tt)*) => {
        $crate::log::line(format_args!($($argument)*))
    };
}

pub fn prefix_install(prefix: &'static str) {
    assert!(!crate::allocation::is_frozen());
    assert!(prefix.len() < CONTENT_BYTES_MAX);

    let installed = PREFIX.set(prefix);

    assert!(installed.is_ok());
}

pub fn prefix() -> &'static str {
    PREFIX.get().copied().unwrap_or("")
}

pub fn line(arguments: fmt::Arguments<'_>) {
    let mut line = Line::new();
    let written = line.write_fmt(arguments);

    if written.is_err() {
        line.mark_truncated();
    }

    line.emit();
}

pub fn panic_hook_install() {
    assert!(!crate::allocation::is_frozen());

    let backtrace = std::env::var_os("RUST_BACKTRACE").is_some_and(|value| value != "0");

    BACKTRACE_ENABLED.store(backtrace, Ordering::SeqCst);
    std::panic::set_hook(Box::new(panic_hook));

    assert_eq!(BACKTRACE_ENABLED.load(Ordering::SeqCst), backtrace);
}

struct Line {
    bytes: [u8; LINE_BYTES_MAX],
    length: usize,
}

impl Line {
    fn new() -> Self {
        let mut line = Self {
            bytes: [0; LINE_BYTES_MAX],
            length: 0,
        };

        let installed = prefix();
        let pushed = line.push(installed.as_bytes());

        assert!(pushed);
        assert_eq!(line.length, installed.len());

        line
    }

    fn emit(&mut self) {
        assert!(self.length < LINE_BYTES_MAX);

        self.bytes[self.length] = b'\n';
        self.length += 1;

        let _ = std::io::stderr().write_all(&self.bytes[..self.length]);
    }

    fn mark_truncated(&mut self) {
        let length_new = self.length + TRUNCATION.len();

        assert!(length_new < LINE_BYTES_MAX);

        self.bytes[self.length..length_new].copy_from_slice(TRUNCATION.as_bytes());
        self.length = length_new;
    }

    fn push(&mut self, bytes: &[u8]) -> bool {
        let length_new = self.length + bytes.len();

        if length_new > CONTENT_BYTES_MAX {
            return false;
        }

        self.bytes[self.length..length_new].copy_from_slice(bytes);
        self.length = length_new;

        true
    }
}

impl fmt::Write for Line {
    fn write_str(&mut self, text: &str) -> fmt::Result {
        if self.push(text.as_bytes()) {
            return Ok(());
        }

        Err(fmt::Error)
    }
}

fn panic_hook(info: &PanicHookInfo<'_>) {
    crate::allocation::stand_down();

    let payload = info.payload_as_str().unwrap_or("panic");

    match info.location() {
        Some(location) => {
            line(format_args!(
                "panic at {}:{}: {payload}",
                location.file(),
                location.line()
            ));
        }
        None => line(format_args!("panic: {payload}")),
    }

    if BACKTRACE_ENABLED.load(Ordering::Relaxed) {
        let backtrace = std::backtrace::Backtrace::force_capture();

        let _ = writeln!(std::io::stderr(), "{backtrace}");
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn line_holds_prefix_and_content() {
        let mut line = Line::new();
        let start = line.length;

        crate::allocation::frozen(|| {
            let written = line.write_fmt(format_args!("count {}", 7_u32));

            assert!(written.is_ok());
            assert_eq!(&line.bytes[start..line.length], b"count 7");
        });
    }

    #[test]
    fn line_refuses_content_past_capacity() {
        let mut line = Line::new();
        let start = line.length;
        let overflow = "x".repeat(CONTENT_BYTES_MAX + 1);

        crate::allocation::frozen(|| {
            let written = line.write_fmt(format_args!("{overflow}"));

            assert!(written.is_err());
            assert_eq!(line.length, start);

            line.mark_truncated();

            assert_eq!(line.length, start + TRUNCATION.len());
        });
    }

    #[test]
    fn line_fills_to_capacity_without_truncation() {
        let mut line = Line::new();
        let content = "x".repeat(CONTENT_BYTES_MAX - line.length);

        crate::allocation::frozen(|| {
            let written = line.write_fmt(format_args!("{content}"));

            assert!(written.is_ok());
            assert_eq!(line.length, CONTENT_BYTES_MAX);
        });
    }
}
