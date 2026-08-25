use crate::bounded::count_of;
use crate::language::Lexer;
use crate::lex::{GO, JAVASCRIPT, ODIN, PYTHON, RUST, TYPESCRIPT, ZIG};
use crate::lines::{Encoding, Position};
use crate::token::{Lex, Tokens};

pub static LEXERS: &[&(dyn Lexer + Sync)] =
    &[&GO, &JAVASCRIPT, &ODIN, &PYTHON, &RUST, &TYPESCRIPT, &ZIG];

pub const LEXER_COUNT: usize = 7;

pub struct LexHarness {
    again: Tokens,
    tokens: Tokens,
}

impl LexHarness {
    pub fn reserve(token_count_max: u32) -> Self {
        assert!(token_count_max > 0);
        assert!(!crate::allocation::is_frozen());

        Self {
            again: Tokens::reserve(token_count_max),
            tokens: Tokens::reserve(token_count_max),
        }
    }

    pub fn check(&mut self, index: usize, source: &[u8]) {
        assert_eq!(LEXERS.len(), LEXER_COUNT);

        let lexer = LEXERS[index % LEXERS.len()];

        self.tokens.clear();

        let outcome = lexer.lex(source, &mut self.tokens);

        if outcome == Lex::Truncated {
            return;
        }

        let name = lexer.identifier();
        let mut end_previous = 0;

        for (position, token) in self.tokens.as_slice().iter().enumerate() {
            let start = token.offset as usize;
            let end = start + token.length as usize;

            assert!(
                end <= source.len(),
                "{name}: token {position} ends at {end}, past the {} byte source",
                source.len()
            );

            assert!(
                start >= end_previous,
                "{name}: token {position} starts at {start}, inside the token before it"
            );

            end_previous = end;
        }

        self.again.clear();

        assert_eq!(
            lexer.lex(source, &mut self.again),
            outcome,
            "{name}: unstable"
        );

        assert_eq!(
            self.tokens.as_slice().len(),
            self.again.as_slice().len(),
            "{name}: the same source lexed to a different token count"
        );

        for (first, second) in self
            .tokens
            .as_slice()
            .iter()
            .zip(self.again.as_slice().iter())
        {
            assert_eq!(first.kind, second.kind, "{name}: unstable kind");
            assert_eq!(first.offset, second.offset, "{name}: unstable offset");
            assert_eq!(first.length, second.length, "{name}: unstable length");
        }
    }
}

pub const MODEL_BYTES_MAX: usize = 4_096;
pub const MODEL_LINE_COUNT_MAX: usize = 64;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Applied {
    Accepted,
    RefusedLines,
    RefusedSize,
    RefusedUtf8,
}

pub struct LineModel {
    length: usize,
    line_count: usize,
    lines: [u32; MODEL_LINE_COUNT_MAX],
    text: [u8; MODEL_BYTES_MAX],
}

fn newline_count(bytes: &[u8]) -> usize {
    let mut count = 0;

    for byte in bytes {
        if *byte == b'\n' {
            count += 1;
        }
    }

    assert!(count <= bytes.len());

    count
}

impl LineModel {
    pub const fn line_count(&self) -> usize {
        self.line_count
    }

    pub const fn length(&self) -> usize {
        self.length
    }

    pub fn reserve() -> Self {
        let mut model = Self {
            length: 0,
            line_count: 0,
            lines: [0; MODEL_LINE_COUNT_MAX],
            text: [0; MODEL_BYTES_MAX],
        };

        model.clear();

        assert_eq!(model.line_count, 1);

        model
    }

    pub fn as_bytes(&self) -> &[u8] {
        assert!(self.length <= MODEL_BYTES_MAX);

        &self.text[..self.length]
    }

    pub fn as_str(&self) -> &str {
        core::str::from_utf8(self.as_bytes()).expect("the model holds valid UTF-8")
    }

    pub fn clear(&mut self) {
        self.length = 0;
        self.line_count = 1;
        self.lines[0] = 0;

        assert_eq!(self.length, 0);
    }

    fn index_rebuild(&mut self) {
        assert!(self.length <= MODEL_BYTES_MAX);

        self.line_count = 1;
        self.lines[0] = 0;

        for offset in 0..self.length {
            if self.text[offset] != b'\n' {
                continue;
            }

            assert!(self.line_count < MODEL_LINE_COUNT_MAX);

            self.lines[self.line_count] = count_of(offset + 1);
            self.line_count += 1;
        }

        assert!(self.line_count <= MODEL_LINE_COUNT_MAX);
    }

    pub const fn line_start(&self, line: u32) -> u32 {
        if line as usize >= self.line_count {
            return 0;
        }

        self.lines[line as usize]
    }

    pub fn line_end(&self, line: u32) -> u32 {
        assert!(self.line_count > 0);

        if line as usize + 1 < self.line_count {
            return self.lines[line as usize + 1];
        }

        count_of(self.length)
    }

    pub fn line_of(&self, offset: u32) -> u32 {
        let mut line = 0;

        for index in 0..self.line_count {
            if self.lines[index] <= offset {
                line = count_of(index);
            }
        }

        assert!((line as usize) < self.line_count);

        line
    }

    pub fn boundary_at(&self, offset: u32) -> u32 {
        let text = self.as_str();
        let mut candidate = offset as usize;

        assert!(candidate <= text.len());

        while !text.is_char_boundary(candidate) {
            candidate -= 1;
        }

        count_of(candidate)
    }

    pub fn units_of(&self, line: u32, encoding: Encoding) -> u32 {
        let start = self.line_start(line);
        let end = self.line_end(line);

        assert!(start <= end);

        encoding.count(self.slice(start, end))
    }

    pub fn slice(&self, start: u32, end: u32) -> &str {
        assert!(start <= end);
        assert!(end as usize <= self.length);

        core::str::from_utf8(&self.text[start as usize..end as usize])
            .expect("the model slices on character boundaries")
    }

    pub fn position_in(&self, offset: u32, encoding: Encoding) -> Position {
        assert!(offset as usize <= self.length);

        let line = self.line_of(offset);
        let start = self.line_start(line);

        assert!(start <= offset);

        Position {
            character: encoding.count(self.slice(start, offset)),
            line,
        }
    }

    pub fn offset_in(&self, position: Position, encoding: Encoding) -> Option<u32> {
        if position.line as usize >= self.line_count {
            return None;
        }

        let start = self.line_start(position.line);
        let end = self.line_end(position.line);
        let text = self.slice(start, end);
        let mut units = 0;

        for (index, character) in text.char_indices() {
            if units == position.character {
                return Some(start + count_of(index));
            }

            units += encoding.width(character);
        }

        if units == position.character {
            return Some(end);
        }

        None
    }

    pub fn replaced(&mut self, insertion: &[u8]) -> Applied {
        if core::str::from_utf8(insertion).is_err() {
            self.clear();

            return Applied::RefusedUtf8;
        }

        if insertion.len() > MODEL_BYTES_MAX {
            self.clear();

            return Applied::RefusedSize;
        }

        if newline_count(insertion) + 1 > MODEL_LINE_COUNT_MAX {
            self.clear();

            return Applied::RefusedLines;
        }

        self.text[..insertion.len()].copy_from_slice(insertion);
        self.length = insertion.len();
        self.index_rebuild();

        Applied::Accepted
    }

    pub fn spliced(&mut self, start: u32, end: u32, insertion: &[u8]) -> Applied {
        assert!(start <= end);
        assert!(end as usize <= self.length);

        if core::str::from_utf8(insertion).is_err() {
            return Applied::RefusedUtf8;
        }

        let removed = (end - start) as usize;
        let length = self.length - removed + insertion.len();

        if insertion.len() > MODEL_BYTES_MAX || length > MODEL_BYTES_MAX {
            return Applied::RefusedSize;
        }

        if self.line_count_after(start, end, insertion) > MODEL_LINE_COUNT_MAX {
            self.clear();

            return Applied::RefusedLines;
        }

        self.text
            .copy_within(end as usize..self.length, start as usize + insertion.len());

        self.text[start as usize..start as usize + insertion.len()].copy_from_slice(insertion);
        self.length = length;
        self.index_rebuild();

        Applied::Accepted
    }

    fn line_count_after(&self, start: u32, end: u32, insertion: &[u8]) -> usize {
        let first = self.lines[..self.line_count]
            .iter()
            .filter(|offset| **offset <= start)
            .count();

        let last = self.lines[..self.line_count]
            .iter()
            .filter(|offset| **offset <= end)
            .count();

        assert!(first <= last);
        assert!(last <= self.line_count);

        first + newline_count(insertion) + (self.line_count - last)
    }
}
