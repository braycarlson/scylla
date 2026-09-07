use core::fmt::{self, Arguments, Write as _};
use core::str::from_utf8;
use std::env::var_os;
use std::ffi::OsStr;
use std::fs::File;
use std::io::{IsTerminal as _, StderrLock, StdoutLock, Write as _, stdout};

use crate::bounded::{BoundedString, Bytes};

pub const BLUE: &str = "\u{1b}[34m";
pub const BOLD: &str = "\u{1b}[1m";
pub const CYAN: &str = "\u{1b}[36m";
pub const GREEN: &str = "\u{1b}[32m";
pub const RED: &str = "\u{1b}[31m";
pub const RESET: &str = "\u{1b}[0m";
pub const YELLOW: &str = "\u{1b}[33m";
const HYPERLINK_CLOSE: &str = "\u{1b}]8;;\u{1b}\\";
const HYPERLINK_OPEN: &str = "\u{1b}]8;;";
const HYPERLINK_SEPARATOR: &str = "\u{1b}\\";
const TERMINAL_DUMB: &str = "dumb";

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub enum Color {
    Always,
    #[default]
    Auto,
    Never,
}

pub enum Target {
    File(File),
    Memory,
    Stderr(StderrLock<'static>),
    Stdout(StdoutLock<'static>),
}

pub struct Sink {
    buffer: BoundedString,
    colored: bool,
    failed: bool,
    silent: bool,
    target: Target,
    truncated: bool,
}

impl Color {
    pub fn decided(self) -> bool {
        let force_color = var_os("FORCE_COLOR");
        let no_color = var_os("NO_COLOR");
        let term = var_os("TERM");

        self.resolved(
            force_color.as_deref(),
            no_color.as_deref(),
            term.as_deref(),
            stdout().is_terminal(),
        )
    }

    pub fn of(name: &str) -> Option<Self> {
        match name {
            "always" => Some(Self::Always),
            "auto" => Some(Self::Auto),
            "never" => Some(Self::Never),
            _ => None,
        }
    }

    pub fn resolved(
        self,
        force_color: Option<&OsStr>,
        no_color: Option<&OsStr>,
        term: Option<&OsStr>,
        terminal: bool,
    ) -> bool {
        match self {
            Self::Always => return true,
            Self::Never => return false,
            Self::Auto => (),
        }

        if let Some(forced) = force_color {
            return !forced.is_empty();
        }

        if no_color.is_some_and(|value| !value.is_empty()) {
            return false;
        }

        if term.is_some_and(|value| value == TERMINAL_DUMB) {
            return false;
        }

        terminal
    }
}

impl Sink {
    pub fn as_str(&self) -> &str {
        self.buffer.as_str()
    }

    pub fn clear(&mut self) {
        self.buffer.clear();
        self.truncated = false;

        assert!(self.buffer.is_empty());
    }

    pub const fn colored(&self) -> bool {
        self.colored
    }

    pub fn flush(&mut self) {
        if self.buffer.is_empty() {
            return;
        }

        if self.failed {
            self.buffer.clear();

            return;
        }

        let written = match &mut self.target {
            Target::File(file) => file.write_all(self.buffer.as_bytes()),
            Target::Memory => return,
            Target::Stderr(stream) => stream.write_all(self.buffer.as_bytes()),
            Target::Stdout(stream) => stream.write_all(self.buffer.as_bytes()),
        };

        self.latch(written.is_err());
        self.buffer.clear();
    }

    pub fn hyperlink(&mut self, text: &str, url: &str) {
        assert!(!url.is_empty());

        if !self.colored {
            self.push(text);

            return;
        }

        self.push(HYPERLINK_OPEN);
        self.push(url);
        self.push(HYPERLINK_SEPARATOR);
        self.push(text);
        self.push(HYPERLINK_CLOSE);
    }

    pub fn is_empty(&self) -> bool {
        self.buffer.is_empty()
    }

    pub const fn is_failed(&self) -> bool {
        self.failed
    }

    pub const fn is_silent(&self) -> bool {
        self.silent
    }

    pub const fn is_truncated(&self) -> bool {
        self.truncated
    }

    const fn latch(&mut self, failed: bool) {
        if failed {
            self.failed = true;
        }
    }

    pub fn painted(&mut self, text: &str, codes: &[&str]) {
        assert!(!codes.is_empty());

        if !self.colored {
            self.push(text);

            return;
        }

        for code in codes {
            self.push(code);
        }

        self.push(text);
        self.push(RESET);
    }

    pub fn push(&mut self, text: &str) {
        if self.failed || self.silent {
            return;
        }

        if self.buffer.push_str(text) {
            return;
        }

        self.flush();

        if self.failed || self.buffer.push_str(text) {
            return;
        }

        self.push_long(text);
    }

    pub fn push_format(&mut self, arguments: Arguments<'_>) {
        let _written = self.write_fmt(arguments);
    }

    pub fn push_line(&mut self, arguments: Arguments<'_>) {
        let _written = self.write_fmt(arguments);

        self.push("\n");
    }

    fn push_long(&mut self, text: &str) {
        assert!(!self.failed);
        assert!(!self.silent);

        let written = match &mut self.target {
            Target::File(file) => file.write_all(text.as_bytes()),
            Target::Memory => {
                self.truncated = true;

                Ok(())
            }
            Target::Stderr(stream) => stream.write_all(text.as_bytes()),
            Target::Stdout(stream) => stream.write_all(text.as_bytes()),
        };

        self.latch(written.is_err());
    }

    pub fn reserve(bytes_max: u32, target: Target, colored: bool) -> Self {
        assert!(bytes_max > 0);
        assert!(!crate::allocation::is_frozen());

        Self {
            buffer: BoundedString::reserve(bytes_max),
            colored,
            failed: false,
            silent: false,
            target,
            truncated: false,
        }
    }

    pub fn retarget(&mut self, target: Target) {
        self.flush();
        self.target = target;
    }

    pub fn silence(&mut self) {
        self.buffer.clear();
        self.silent = true;

        assert!(self.is_silent());
    }
}

impl fmt::Write for Sink {
    fn write_str(&mut self, text: &str) -> fmt::Result {
        self.push(text);

        Ok(())
    }
}

impl Bytes for Sink {
    fn push_bytes(&mut self, bytes: &[u8]) -> bool {
        let Ok(text) = from_utf8(bytes) else {
            return false;
        };

        self.push(text);

        true
    }
}

#[cfg(test)]
mod tests {
    use std::ffi::OsStr;
    use std::fs::File;

    use super::{BOLD, Color, RED, RESET, Sink, Target};
    use crate::allocation;

    const BYTES_MAX: u32 = 32;

    fn memory() -> Sink {
        Sink::reserve(BYTES_MAX, Target::Memory, false)
    }

    #[test]
    fn a_memory_sink_keeps_what_fits_and_marks_the_spill() {
        let mut out = memory();

        allocation::frozen(|| {
            out.push("0123456789abcdef");
            out.push("0123456789abcdef");

            assert!(!out.is_truncated());

            out.push("x");

            assert!(out.is_truncated());
        });
    }

    #[test]
    fn a_failed_write_latches_and_the_rest_is_dropped() {
        let read_only = File::open("Cargo.toml").expect("the manifest opens");
        let mut out = Sink::reserve(BYTES_MAX, Target::File(read_only), false);

        allocation::frozen(|| {
            out.push("0123456789abcdef0123456789abcdef");

            assert!(!out.is_failed());

            out.push("x");

            assert!(out.is_failed());
            assert!(out.is_empty());

            out.push("y");
            out.flush();

            assert!(out.is_empty());
        });
    }

    #[test]
    fn a_silenced_sink_drops_every_push() {
        let mut out = memory();

        allocation::frozen(|| {
            out.push("kept");
            out.silence();
            out.push("dropped");

            assert!(out.is_empty());
            assert!(out.is_silent());
        });
    }

    #[test]
    fn paint_is_only_written_when_the_sink_is_colored() {
        let mut plain = memory();
        let mut colored = Sink::reserve(BYTES_MAX, Target::Memory, true);
        let expected = format!("{BOLD}{RED}x{RESET}");

        allocation::frozen(|| {
            plain.painted("x", &[BOLD, RED]);
            colored.painted("x", &[BOLD, RED]);

            assert_eq!(plain.as_str(), "x");
            assert_eq!(colored.as_str(), expected);
        });
    }

    #[test]
    fn a_hyperlink_wraps_its_text_in_the_osc_8_sequence() {
        let mut out = Sink::reserve(64, Target::Memory, true);

        allocation::frozen(|| {
            out.hyperlink("t", "u");

            assert_eq!(out.as_str(), "\u{1b}]8;;u\u{1b}\\t\u{1b}]8;;\u{1b}\\");
        });
    }

    #[test]
    fn the_color_switch_is_resolved_in_order() {
        let empty = OsStr::new("");
        let set = OsStr::new("1");
        let dumb = OsStr::new("dumb");

        assert!(Color::Always.resolved(None, Some(set), None, false));
        assert!(!Color::Never.resolved(Some(set), None, None, true));
        assert!(Color::Auto.resolved(Some(set), Some(set), None, false));
        assert!(!Color::Auto.resolved(Some(empty), None, None, true));
        assert!(!Color::Auto.resolved(None, Some(set), None, true));
        assert!(Color::Auto.resolved(None, Some(empty), None, true));
        assert!(!Color::Auto.resolved(None, None, Some(dumb), true));
        assert!(Color::Auto.resolved(None, None, None, true));
        assert!(!Color::Auto.resolved(None, None, None, false));
        assert_eq!(Color::of("always"), Some(Color::Always));
        assert_eq!(Color::of("sometimes"), None);
    }
}
