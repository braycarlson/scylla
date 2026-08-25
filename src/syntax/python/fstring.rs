use crate::bounded::{BoundedVec, Span};
use crate::lex::python_token_at;
use crate::syntax::python::kind::PythonKind;
use crate::token::{Punctuation, TokenKind, Tokens};

pub const FIELD_DEPTH_MAX: u32 = 32;
pub const STEP_MAX: u32 = 1 << 20;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum Mode {
    Body,
    Expression,
    Field,
    Spec,
}

#[derive(Clone, Copy, Debug)]
struct Frame {
    end: usize,
    mode: Mode,
    quote: u8,
    stage: u8,
    width: usize,
}

struct Scanner<'source, 'run> {
    depth: u32,
    limit: usize,
    offset: usize,
    raw: &'run mut BoundedVec<PythonKind>,
    source: &'source [u8],
    stack: [Frame; FIELD_DEPTH_MAX as usize],
    tokens: &'run mut Tokens,
}

impl Frame {
    const EMPTY: Self = Self {
        end: 0,
        mode: Mode::Body,
        quote: b'"',
        stage: 0,
        width: 1,
    };
}

const COARSE: [(PythonKind, TokenKind); 5] = [
    (PythonKind::Bang, TokenKind::Punctuation(Punctuation::Bang)),
    (
        PythonKind::BraceClose,
        TokenKind::Punctuation(Punctuation::BracketClose),
    ),
    (
        PythonKind::BraceOpen,
        TokenKind::Punctuation(Punctuation::BracketOpen),
    ),
    (
        PythonKind::Colon,
        TokenKind::Punctuation(Punctuation::Colon),
    ),
    (
        PythonKind::Equal,
        TokenKind::Punctuation(Punctuation::Assign),
    ),
];

fn coarse_of(kind: PythonKind) -> TokenKind {
    COARSE
        .iter()
        .find(|entry| entry.0 == kind)
        .map_or(TokenKind::String, |entry| entry.1)
}

pub fn is_format(bytes: &[u8]) -> bool {
    let quote = bytes
        .iter()
        .position(|byte| matches!(*byte, b'"' | b'\''))
        .unwrap_or(bytes.len());

    bytes[..quote]
        .iter()
        .any(|byte| byte.eq_ignore_ascii_case(&b'f'))
}

fn is_blank(byte: u8) -> bool {
    matches!(byte, b'\t' | b'\n' | b'\x0b' | b'\x0c' | b'\r' | b' ')
}

fn quote_width(source: &[u8], start: usize, quote: u8) -> usize {
    if source.len() > start + 2 && source[start + 1] == quote && source[start + 2] == quote {
        return 3;
    }

    1
}

fn closes(source: &[u8], offset: usize, quote: u8, width: usize) -> bool {
    offset + width <= source.len()
        && source[offset..offset + width]
            .iter()
            .all(|byte| *byte == quote)
}

fn expression_end(source: &[u8], from: usize, limit: usize) -> usize {
    let mut offset = from;
    let mut depth = 0_u32;

    for _ in 0..STEP_MAX {
        while offset < limit && is_blank(source[offset]) {
            offset += 1;
        }

        if offset >= limit {
            return limit;
        }

        let (_, next) = python_token_at(source, offset);
        let end = next.min(limit).max(offset + 1);
        let text = &source[offset..end];

        if depth == 0 && matches!(text, b"}" | b":" | b"!" | b"=") {
            return offset;
        }

        if matches!(text, b"(" | b"[" | b"{") {
            depth += 1;
        }

        if matches!(text, b")" | b"]" | b"}") {
            depth = depth.saturating_sub(1);
        }

        offset = end;
    }

    limit
}

fn literal_end(source: &[u8], from: usize, limit: usize, quote: u8, width: usize) -> usize {
    let mut offset = from;

    while offset < limit {
        assert!(offset >= from);

        let byte = source[offset];

        if byte == b'\\' {
            offset += 2;

            continue;
        }

        if matches!(byte, b'{' | b'}') {
            if source.get(offset + 1) == Some(&byte) {
                offset += 2;

                continue;
            }

            return offset;
        }

        if quote != 0 && byte == quote && closes(source, offset, quote, width) {
            return offset;
        }

        offset += 1;
    }

    offset.min(limit).max(from)
}

impl Scanner<'_, '_> {
    fn push(&mut self, kind: PythonKind, offset: usize, end: usize) -> bool {
        self.push_coarse(coarse_of(kind), kind, offset, end)
    }

    fn push_coarse(
        &mut self,
        coarse: TokenKind,
        kind: PythonKind,
        offset: usize,
        end: usize,
    ) -> bool {
        let start = offset.max(self.tokens.end_previous() as usize);
        let stop = end.min(self.limit).min(self.source.len());

        if stop <= start {
            return true;
        }

        if self.raw.is_full() {
            return false;
        }

        if !self.tokens.push(self.source, coarse, start, stop - start) {
            return false;
        }

        self.raw.push(kind)
    }

    fn open(&mut self, frame: Frame) -> bool {
        if self.depth >= FIELD_DEPTH_MAX {
            return false;
        }

        self.stack[self.depth as usize] = frame;
        self.depth += 1;

        true
    }

    fn top(&self) -> Frame {
        assert!(self.depth > 0);

        self.stack[self.depth as usize - 1]
    }

    fn open_string(&mut self) -> bool {
        let start = self.offset;
        let mut quote = start;

        while quote < self.limit && !matches!(self.source[quote], b'"' | b'\'') {
            quote += 1;
        }

        if quote >= self.limit {
            let end = self.limit;

            self.offset = end;

            return self.push(PythonKind::StringFormat, start, end);
        }

        let held = self.source[quote];
        let width = quote_width(self.source, quote, held);

        if !self.push(PythonKind::FStringStart, start, quote + width) {
            return false;
        }

        self.offset = quote + width;

        self.open(Frame {
            mode: Mode::Body,
            quote: held,
            width,
            ..Frame::EMPTY
        })
    }

    fn step_text(&mut self, frame: Frame) -> bool {
        let quote = if frame.mode == Mode::Body {
            frame.quote
        } else {
            0
        };

        let end = literal_end(self.source, self.offset, self.limit, quote, frame.width);

        if !self.push(PythonKind::FStringMiddle, self.offset, end) {
            return false;
        }

        self.offset = end;

        if self.offset >= self.limit {
            self.depth -= 1;

            return true;
        }

        let byte = self.source[self.offset];

        if frame.mode == Mode::Body && byte == frame.quote {
            if !self.push(
                PythonKind::FStringEnd,
                self.offset,
                self.offset + frame.width,
            ) {
                return false;
            }

            self.offset += frame.width;
            self.depth -= 1;

            return true;
        }

        if byte == b'}' && frame.mode == Mode::Spec {
            self.depth -= 1;

            return true;
        }

        if byte != b'{' {
            let stop = self.offset + 1;
            let pushed = self.push(PythonKind::FStringMiddle, self.offset, stop);

            self.offset = stop;

            return pushed;
        }

        if !self.push(PythonKind::BraceOpen, self.offset, self.offset + 1) {
            return false;
        }

        self.offset += 1;

        let stop = expression_end(self.source, self.offset, self.limit);

        self.open(Frame {
            mode: Mode::Field,
            ..Frame::EMPTY
        }) && self.open(Frame {
            end: stop,
            mode: Mode::Expression,
            ..Frame::EMPTY
        })
    }

    fn step_expression(&mut self, frame: Frame) -> bool {
        while self.offset < frame.end && is_blank(self.source[self.offset]) {
            self.offset += 1;
        }

        if self.offset >= frame.end {
            self.depth -= 1;

            return true;
        }

        let (coarse, next) = python_token_at(self.source, self.offset);
        let end = next.min(frame.end).max(self.offset + 1);
        let text = &self.source[self.offset..end];

        if coarse == TokenKind::String && is_format(text) {
            return self.open_string();
        }

        let (kind, span) =
            crate::syntax::python::classify::kind_of(self.source, coarse, self.offset, end);

        if !self.push_coarse(coarse, kind, self.offset, span) {
            return false;
        }

        self.offset = span;

        true
    }

    fn step_field(&mut self, frame: Frame) -> bool {
        while self.offset < self.limit && is_blank(self.source[self.offset]) {
            self.offset += 1;
        }

        if self.offset >= self.limit {
            self.depth -= 1;

            return true;
        }

        let byte = self.source[self.offset];

        if byte == b'}' {
            if !self.push(PythonKind::BraceClose, self.offset, self.offset + 1) {
                return false;
            }

            self.offset += 1;
            self.depth -= 1;

            return true;
        }

        if frame.stage == 0 && byte == b'=' {
            if !self.push(PythonKind::Equal, self.offset, self.offset + 1) {
                return false;
            }

            self.offset += 1;

            return true;
        }

        if frame.stage == 0 && byte == b'!' {
            return self.step_conversion();
        }

        if frame.stage == 0 && byte == b':' {
            if !self.push(PythonKind::Colon, self.offset, self.offset + 1) {
                return false;
            }

            self.offset += 1;
            self.stack[self.depth as usize - 1].stage = 1;

            return self.open(Frame {
                mode: Mode::Spec,
                ..Frame::EMPTY
            });
        }

        let end = self.offset + 1;
        let pushed = self.push_coarse(TokenKind::String, PythonKind::ErrorToken, self.offset, end);

        self.offset = end;

        pushed
    }

    fn step_conversion(&mut self) -> bool {
        if !self.push(PythonKind::Bang, self.offset, self.offset + 1) {
            return false;
        }

        self.offset += 1;

        let start = self.offset;

        while self.offset < self.limit && self.source[self.offset].is_ascii_alphabetic() {
            self.offset += 1;
        }

        self.push_coarse(
            TokenKind::Identifier,
            PythonKind::Identifier,
            start,
            self.offset,
        )
    }

    fn run(&mut self) -> bool {
        if !self.open_string() {
            return false;
        }

        for _ in 0..STEP_MAX {
            if self.depth == 0 {
                break;
            }

            let frame = self.top();
            let before = (self.offset, self.depth);

            let stepped = match frame.mode {
                Mode::Body | Mode::Spec => self.step_text(frame),
                Mode::Expression => self.step_expression(frame),
                Mode::Field => self.step_field(frame),
            };

            if !stepped {
                return false;
            }

            if before == (self.offset, self.depth) {
                let end = (self.offset + 1).min(self.limit);

                if end <= self.offset {
                    break;
                }

                if !self.push_coarse(TokenKind::String, PythonKind::ErrorToken, self.offset, end) {
                    return false;
                }

                self.offset = end;
            }
        }

        self.flush()
    }

    fn flush(&mut self) -> bool {
        if self.offset >= self.limit {
            return true;
        }

        let end = self.limit;
        let pushed = self.push(PythonKind::FStringMiddle, self.offset, end);

        self.offset = end;

        pushed
    }
}

pub fn expand(
    source: &[u8],
    span: Span,
    tokens: &mut Tokens,
    raw: &mut BoundedVec<PythonKind>,
) -> bool {
    let mut scanner = Scanner {
        depth: 0,
        limit: span.end() as usize,
        offset: span.offset as usize,
        raw,
        source,
        stack: [Frame::EMPTY; FIELD_DEPTH_MAX as usize],
        tokens,
    };

    scanner.run()
}
