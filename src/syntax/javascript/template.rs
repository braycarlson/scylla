use crate::bounded::{BoundedVec, Span};
use crate::lex::javascript_token_at;
use crate::syntax::javascript::classify::{kind_of, push};
use crate::syntax::javascript::kind::JavaScriptKind;
use crate::token::{TokenKind, Tokens};

pub const TEMPLATE_DEPTH_MAX: u32 = 32;
pub const STEP_MAX: u32 = 1 << 20;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum Mode {
    Chars,
    Substitution,
}

#[derive(Clone, Copy, Debug)]
struct Frame {
    depth: u32,
    mode: Mode,
}

struct Scanner<'source, 'run> {
    depth: u32,
    limit: usize,
    offset: usize,
    previous: TokenKind,
    raw: &'run mut BoundedVec<JavaScriptKind>,
    source: &'source [u8],
    stack: [Frame; TEMPLATE_DEPTH_MAX as usize],
    tokens: &'run mut Tokens,
}

impl Frame {
    const EMPTY: Self = Self {
        depth: 0,
        mode: Mode::Chars,
    };
}

fn is_blank(byte: u8) -> bool {
    matches!(byte, b'\t' | b'\n' | b'\x0b' | b'\x0c' | b'\r' | b' ')
}

fn literal_end(source: &[u8], from: usize, limit: usize) -> usize {
    let mut offset = from;

    while offset < limit {
        let byte = source[offset];

        if byte == b'\\' {
            offset = (offset + 2).min(limit);

            continue;
        }

        if byte == b'`' {
            return offset;
        }

        if byte == b'$' && source.get(offset + 1) == Some(&b'{') {
            return offset;
        }

        offset += 1;
    }

    limit
}

impl Scanner<'_, '_> {
    fn emit(&mut self, kind: JavaScriptKind, coarse: TokenKind, offset: usize, end: usize) -> bool {
        push(
            self.source,
            self.tokens,
            self.raw,
            coarse,
            kind,
            offset,
            end,
        )
    }

    fn open(&mut self, mode: Mode) -> bool {
        if self.depth >= TEMPLATE_DEPTH_MAX {
            return false;
        }

        self.stack[self.depth as usize] = Frame { depth: 0, mode };
        self.depth += 1;

        true
    }

    fn chars_step(&mut self) -> bool {
        if self.offset >= self.limit {
            self.depth -= 1;

            return true;
        }

        let byte = self.source[self.offset];

        if byte == b'`' {
            let end = self.offset + 1;

            let held = self.emit(
                JavaScriptKind::TemplateEnd,
                TokenKind::String,
                self.offset,
                end,
            );

            self.offset = end;
            self.depth -= 1;

            return held;
        }

        if byte == b'$' && self.source.get(self.offset + 1) == Some(&b'{') {
            let end = self.offset + 2;

            let held = self.emit(
                JavaScriptKind::SubstitutionStart,
                TokenKind::String,
                self.offset,
                end,
            );

            self.offset = end;
            self.previous = TokenKind::Punctuation(crate::token::Punctuation::BracketOpen);

            return held && self.open(Mode::Substitution);
        }

        let end = literal_end(self.source, self.offset, self.limit);

        let held = self.emit(
            JavaScriptKind::TemplateChars,
            TokenKind::String,
            self.offset,
            end,
        );

        self.offset = end.max(self.offset + 1);

        held
    }

    fn substitution_step(&mut self) -> bool {
        while self.offset < self.limit && is_blank(self.source[self.offset]) {
            self.offset += 1;
        }

        if self.offset >= self.limit {
            self.depth -= 1;

            return true;
        }

        let byte = self.source[self.offset];
        let index = self.depth as usize - 1;

        if byte == b'}' && self.stack[index].depth == 0 {
            let end = self.offset + 1;

            let held = self.emit(
                JavaScriptKind::BraceClose,
                TokenKind::BlockEnd,
                self.offset,
                end,
            );

            self.offset = end;
            self.depth -= 1;
            self.previous = TokenKind::BlockEnd;

            return held;
        }

        if byte == b'`' {
            let end = self.offset + 1;

            let held = self.emit(
                JavaScriptKind::TemplateStart,
                TokenKind::String,
                self.offset,
                end,
            );

            self.offset = end;

            return held && self.open(Mode::Chars);
        }

        let (coarse, stop) = javascript_token_at(self.source, self.offset, self.previous);
        let end = stop.min(self.limit).max(self.offset + 1);

        if byte == b'{' {
            self.stack[index].depth += 1;
        }

        if byte == b'}' {
            self.stack[index].depth -= 1;
        }

        let (kind, reach) = kind_of(self.source, coarse, self.offset, end);
        let held = self.emit(kind, coarse, self.offset, reach.min(self.limit));

        if coarse != TokenKind::Comment {
            self.previous = coarse;
        }

        self.offset = reach.min(self.limit).max(self.offset + 1);

        held
    }

    fn run(&mut self) -> bool {
        for _ in 0..STEP_MAX {
            if self.depth == 0 {
                return true;
            }

            let mode = self.stack[self.depth as usize - 1].mode;

            let held = match mode {
                Mode::Chars => self.chars_step(),
                Mode::Substitution => self.substitution_step(),
            };

            if !held {
                return false;
            }
        }

        false
    }
}

#[must_use]
pub fn expand(
    source: &[u8],
    span: Span,
    tokens: &mut Tokens,
    raw: &mut BoundedVec<JavaScriptKind>,
) -> bool {
    assert!(span.end() as usize <= source.len());
    assert_eq!(source.get(span.offset as usize), Some(&b'`'));

    let offset = span.offset as usize;

    if !push(
        source,
        tokens,
        raw,
        TokenKind::String,
        JavaScriptKind::TemplateStart,
        offset,
        offset + 1,
    ) {
        return false;
    }

    let mut scanner = Scanner {
        depth: 0,
        limit: span.end() as usize,
        offset: offset + 1,
        previous: TokenKind::Punctuation(crate::token::Punctuation::BracketOpen),
        raw,
        source,
        stack: [Frame::EMPTY; TEMPLATE_DEPTH_MAX as usize],
        tokens,
    };

    if !scanner.open(Mode::Chars) {
        return false;
    }

    scanner.run()
}
