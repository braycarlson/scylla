use crate::bounded::{Buffer, Bytes as _, count_of};

pub const PADDING_MAX: u32 = 128;
const BLOCK_CLOSE: &[u8] = b"*/";
const BLOCK_OPEN: &[u8] = b"/*";
const COMMENT: &[u8] = b"//";

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Target {
    Assign,
    Comment,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct Cut {
    head: u32,
    tail: u32,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct Quotes {
    backtick: bool,
    double: bool,
    single: bool,
    skip: bool,
}

impl Quotes {
    const NONE: Self = Self {
        backtick: false,
        double: false,
        single: false,
        skip: false,
    };

    const fn inside(self) -> bool {
        self.backtick || self.double || self.single
    }

    fn opens(&mut self, byte: u8) {
        match byte {
            b'"' => self.double = true,
            b'\'' => self.single = true,
            b'`' => self.backtick = true,
            _ => (),
        }
    }

    fn step(&mut self, byte: u8) {
        if self.skip {
            self.skip = false;

            return;
        }

        if self.double && byte == b'\\' {
            self.skip = true;

            return;
        }

        match byte {
            b'"' if !self.single && !self.backtick => self.double = !self.double,
            b'\'' if !self.double && !self.backtick => self.single = !self.single,
            b'`' if !self.double && !self.single => self.backtick = !self.backtick,
            _ => (),
        }
    }
}

fn indent_of(line: &[u8]) -> u32 {
    let mut held = 0;

    while held < line.len() && (line[held] == b' ' || line[held] == b'\t') {
        held += 1;
    }

    count_of(held)
}

fn padded(out: &mut Buffer, width: u32) -> bool {
    for _ in 0..width {
        if !out.push_bytes(b" ") {
            return false;
        }
    }

    true
}

fn crosses(line: &[u8], inside: bool) -> bool {
    let mut held = inside;
    let mut offset = 0;

    while offset < line.len() {
        if held {
            if line[offset..].starts_with(b"*/") || line[offset] == b'`' {
                held = false;
                offset += 1;
            }

            offset += 1;

            continue;
        }

        if line[offset..].starts_with(b"//") {
            return false;
        }

        if line[offset..].starts_with(b"/*") || line[offset] == b'`' {
            held = true;
            offset += 1;
        }

        offset += 1;
    }

    held
}

fn cuts_at(line: &[u8], target: Target, held: usize, indent: usize) -> bool {
    match target {
        Target::Assign => {
            line[held] == b'='
                && held > indent
                && line[held - 1] == b' '
                && line.get(held + 1) != Some(&b'=')
                && line.get(held.wrapping_sub(2)) != Some(&b'=')
                && line.get(held.wrapping_sub(2)) != Some(&b'!')
                && line.get(held.wrapping_sub(2)) != Some(&b'<')
                && line.get(held.wrapping_sub(2)) != Some(&b'>')
                && line.get(held.wrapping_sub(2)) != Some(&b':')
        }
        Target::Comment => line[held..].starts_with(COMMENT) && held > indent,
    }
}

fn cut_of(line: &[u8], target: Target) -> Option<Cut> {
    let indent = indent_of(line) as usize;
    let mut block = false;
    let mut held = indent;
    let mut quotes = Quotes::NONE;

    while held < line.len() {
        let byte = line[held];

        if block {
            if line[held..].starts_with(BLOCK_CLOSE) {
                block = false;
                held += BLOCK_CLOSE.len();

                continue;
            }

            held += 1;

            continue;
        }

        if quotes.inside() {
            quotes.step(byte);
            held += 1;

            continue;
        }

        if line[held..].starts_with(BLOCK_OPEN) {
            if target == Target::Assign || held == indent {
                return None;
            }

            block = true;
            held += BLOCK_OPEN.len();

            continue;
        }

        if line[held..].starts_with(COMMENT) {
            if target == Target::Assign || held == indent {
                return None;
            }
        }

        if !cuts_at(line, target, held, indent) {
            quotes.opens(byte);
            held += 1;

            continue;
        }

        let mut start = held;

        while start > indent && line[start - 1] == b' ' {
            start -= 1;
        }

        if start == indent {
            return None;
        }

        return Some(Cut {
            head: count_of(start),
            tail: count_of(held),
        });
    }

    None
}

fn line_at(bytes: &[u8], offset: u32) -> (u32, u32) {
    let mut end = offset as usize;

    while end < bytes.len() && bytes[end] != b'\n' {
        end += 1;
    }

    (offset, count_of(end))
}

fn width_of(bytes: &[u8], start: u32, target: Target) -> (u32, u32) {
    let mut inside = false;
    let mut offset = start;
    let mut stop = start;
    let mut width = 0;

    let indent = {
        let (from, to) = line_at(bytes, start);

        indent_of(&bytes[from as usize..to as usize])
    };

    while offset < count_of(bytes.len()) {
        let (from, to) = line_at(bytes, offset);
        let line = &bytes[from as usize..to as usize];
        let held = inside;

        inside = crosses(line, inside);

        if held {
            stop = to + 1;
            offset = to + 1;

            continue;
        }

        if indent_of(line) != indent {
            break;
        }

        let Some(cut) = cut_of(line, target) else {
            break;
        };

        width = width.max(cut.head);
        stop = to + 1;
        offset = to + 1;
    }

    (width, stop)
}

#[must_use]
pub fn align(bytes: &[u8], target: Target, out: &mut Buffer) -> bool {
    out.clear();

    let count = count_of(bytes.len());
    let mut inside = false;
    let mut offset = 0;

    while offset < count {
        let (from, to) = line_at(bytes, offset);
        let line = &bytes[from as usize..to as usize];
        let held = inside;

        inside = crosses(line, inside);

        let (width, stop) = if held {
            (0, 0)
        } else {
            width_of(bytes, offset, target)
        };

        if held || cut_of(line, target).is_none() || stop <= to + 1 || width > PADDING_MAX {
            if !out.push_bytes(&bytes[from as usize..(to + 1).min(count) as usize]) {
                return false;
            }

            offset = to + 1;

            continue;
        }

        let mut scan = offset;

        while scan < stop {
            let (start, end) = line_at(bytes, scan);
            let text = &bytes[start as usize..end as usize];
            let crossed = inside;

            inside = crosses(text, inside);

            match cut_of(text, target).filter(|_| !crossed) {
                Some(cut) => {
                    if !out.push_bytes(&text[..cut.head as usize]) {
                        return false;
                    }

                    if !padded(out, (width + 1).saturating_sub(cut.head)) {
                        return false;
                    }

                    if !out.push_bytes(&text[cut.tail as usize..]) {
                        return false;
                    }
                }
                None => {
                    if !out.push_bytes(text) {
                        return false;
                    }
                }
            }

            if end < count && !out.push_bytes(b"\n") {
                return false;
            }

            scan = end + 1;
        }

        offset = stop;
    }

    true
}
