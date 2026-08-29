use crate::bounded::{BoundedVec, Span, count_of};
use crate::lex::javascript_token_at as typescript_token_at;
use crate::syntax::typescript::classify::{kind_of, push};
use crate::syntax::typescript::kind::TypeScriptKind;
use crate::syntax::typescript::template;
use crate::token::{Punctuation, TokenKind, Tokens};

pub const ANGLE_STEP_MAX: u32 = 1 << 14;
pub const ENTITY_LENGTH_MAX: usize = 33;
pub const JSX_DEPTH_MAX: u32 = 64;
pub const STEP_MAX: u32 = 1 << 20;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum Mode {
    Children,
    Closing,
    Expression,
    Opening,
}

#[derive(Clone, Copy)]
struct Frame {
    depth: u32,
    kind_previous: TypeScriptKind,
    mode: Mode,
    previous: TokenKind,
}

struct Scanner<'source, 'run> {
    depth: u32,
    limit: usize,
    offset: usize,
    raw: &'run mut BoundedVec<TypeScriptKind>,
    source: &'source [u8],
    stack: [Frame; JSX_DEPTH_MAX as usize],
    tokens: &'run mut Tokens,
}

impl Frame {
    const EMPTY: Self = Self {
        depth: 0,
        kind_previous: TypeScriptKind::BraceOpen,
        mode: Mode::Children,
        previous: TokenKind::Punctuation(Punctuation::BracketOpen),
    };
}

const fn is_blank(byte: u8) -> bool {
    matches!(byte, b'\t' | b'\n' | b'\x0b' | b'\x0c' | b'\r' | b' ')
}

const fn is_name_start(byte: u8) -> bool {
    byte.is_ascii_alphabetic() || matches!(byte, b'$' | b'_')
}

const fn is_name_byte(byte: u8) -> bool {
    byte.is_ascii_alphanumeric() || matches!(byte, b'$' | b'-' | b'_')
}

const fn holds_a_value(kind: TypeScriptKind) -> bool {
    matches!(
        kind,
        TypeScriptKind::BraceClose
            | TypeScriptKind::BracketClose
            | TypeScriptKind::FalseKeyword
            | TypeScriptKind::Identifier
            | TypeScriptKind::JsxTagEnd
            | TypeScriptKind::JsxTagEndSelf
            | TypeScriptKind::MinusMinus
            | TypeScriptKind::NullKeyword
            | TypeScriptKind::Number
            | TypeScriptKind::ParenClose
            | TypeScriptKind::PlusPlus
            | TypeScriptKind::PrivateIdentifier
            | TypeScriptKind::Regex
            | TypeScriptKind::String
            | TypeScriptKind::SuperKeyword
            | TypeScriptKind::TemplateChars
            | TypeScriptKind::TemplateEnd
            | TypeScriptKind::ThisKeyword
            | TypeScriptKind::TrueKeyword
            | TypeScriptKind::UndefinedKeyword
    )
}

fn entity_end(source: &[u8], from: usize, limit: usize) -> Option<usize> {
    assert_eq!(source.get(from), Some(&b'&'));

    let mut offset = from + 1;
    let stop = limit.min(from + ENTITY_LENGTH_MAX);

    if source.get(offset) == Some(&b'#') {
        offset += 1;

        let hexadecimal = matches!(source.get(offset), Some(b'x' | b'X'));

        if hexadecimal {
            offset += 1;
        }

        let start = offset;

        while offset < stop {
            let byte = source[offset];

            let held = if hexadecimal {
                byte.is_ascii_hexdigit()
            } else {
                byte.is_ascii_digit()
            };

            if !held {
                break;
            }

            offset += 1;
        }

        let width = offset - start;
        let room = if hexadecimal { 6 } else { 5 };

        if width == 0 || width > room || source.get(offset) != Some(&b';') {
            return None;
        }

        return Some(offset + 1);
    }

    let start = offset;

    while offset < stop && source[offset].is_ascii_alphabetic() {
        offset += 1;
    }

    let width = offset - start;

    if width == 0 || width > 30 || source.get(offset) != Some(&b';') {
        return None;
    }

    Some(offset + 1)
}

fn text_end(source: &[u8], from: usize, limit: usize) -> (usize, bool) {
    let mut offset = from;
    let mut at_newline = false;
    let mut saw_text = false;

    while offset < limit {
        let byte = source[offset];

        if matches!(byte, b'<' | b'{') {
            break;
        }

        if byte == b'&' && entity_end(source, offset, limit).is_some() {
            break;
        }

        if byte == b'\n' {
            at_newline = true;
        } else {
            at_newline &= is_blank(byte);

            if !at_newline {
                saw_text = true;
            }
        }

        offset += 1;
    }

    (offset, saw_text)
}

fn line_end(source: &[u8], from: usize, limit: usize) -> usize {
    let mut offset = from + 2;

    while offset < limit && source[offset] != b'\n' {
        offset += 1;
    }

    offset
}

fn block_end(source: &[u8], from: usize, limit: usize) -> usize {
    let mut offset = from + 2;

    while offset < limit {
        if source[offset] == b'*' && source.get(offset + 1) == Some(&b'/') {
            return (offset + 2).min(limit);
        }

        offset += 1;
    }

    limit
}

fn name_end(source: &[u8], from: usize, limit: usize) -> usize {
    let mut offset = from + 1;

    while offset < limit && is_name_byte(source[offset]) {
        offset += 1;
    }

    offset
}

fn angles_end(source: &[u8], from: usize, limit: usize) -> Option<usize> {
    assert_eq!(source.get(from), Some(&b'<'));

    let mut depth = 0_u32;
    let mut offset = from;

    for _ in 0..ANGLE_STEP_MAX {
        if offset >= limit {
            return None;
        }

        let byte = source[offset];

        if matches!(byte, b';' | b'}') {
            return None;
        }

        if byte == b'{' {
            offset = braces_end(source, offset, limit);

            continue;
        }

        if matches!(byte, b'"' | b'\'' | b'`') {
            offset = string_end(source, offset, limit);

            continue;
        }

        if byte == b'<' {
            depth += 1;
        }

        if byte == b'>' {
            depth -= 1;

            if depth == 0 {
                return Some(offset + 1);
            }
        }

        offset += 1;
    }

    None
}

fn braces_end(source: &[u8], from: usize, limit: usize) -> usize {
    let mut depth = 0_u32;
    let mut offset = from;

    for _ in 0..ANGLE_STEP_MAX {
        if offset >= limit {
            return limit;
        }

        let byte = source[offset];

        if matches!(byte, b'"' | b'\'' | b'`') {
            offset = string_end(source, offset, limit);

            continue;
        }

        if byte == b'{' {
            depth += 1;
        }

        if byte == b'}' {
            depth -= 1;

            if depth == 0 {
                return offset + 1;
            }
        }

        offset += 1;
    }

    limit
}

fn generic_arrow_at(source: &[u8], from: usize, limit: usize) -> bool {
    let Some(end) = angles_end(source, from, limit) else {
        return false;
    };

    let mut offset = end;

    while offset < limit && is_blank(source[offset]) {
        offset += 1;
    }

    source.get(offset) == Some(&b'(')
}

fn string_end(source: &[u8], from: usize, limit: usize) -> usize {
    let quote = source[from];
    let mut offset = from + 1;

    while offset < limit {
        if source[offset] == quote {
            return offset + 1;
        }

        offset += 1;
    }

    limit
}

impl Scanner<'_, '_> {
    fn emit(&mut self, kind: TypeScriptKind, coarse: TokenKind, offset: usize, end: usize) -> bool {
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

    fn take(&mut self, kind: TypeScriptKind, coarse: TokenKind, end: usize) -> bool {
        let held = self.emit(kind, coarse, self.offset, end);

        self.offset = end;

        held
    }

    fn room(&self) -> bool {
        self.depth < JSX_DEPTH_MAX
    }

    fn open(&mut self, mode: Mode) -> bool {
        if self.depth >= JSX_DEPTH_MAX {
            return false;
        }

        self.stack[self.depth as usize] = Frame {
            mode,
            ..Frame::EMPTY
        };

        self.depth += 1;

        true
    }

    fn blanks(&mut self) {
        while self.offset < self.limit && is_blank(self.source[self.offset]) {
            self.offset += 1;
        }
    }

    fn comment(&mut self) -> Option<bool> {
        if self.source[self.offset] != b'/' {
            return None;
        }

        let next = self.source.get(self.offset + 1).copied();

        if next == Some(b'/') {
            let end = line_end(self.source, self.offset, self.limit);

            return Some(self.take(TypeScriptKind::Comment, TokenKind::Comment, end));
        }

        if next != Some(b'*') {
            return None;
        }

        let end = block_end(self.source, self.offset, self.limit);

        Some(self.take(TypeScriptKind::Comment, TokenKind::Comment, end))
    }

    fn tag_step(&mut self, mode: Mode) -> bool {
        self.blanks();

        if self.offset >= self.limit {
            self.depth -= 1;

            return true;
        }

        let byte = self.source[self.offset];

        if byte == b'/' && self.source.get(self.offset + 1) == Some(&b'>') {
            let end = self.offset + 2;

            self.depth -= 1;

            return self.take(
                TypeScriptKind::JsxTagEndSelf,
                TokenKind::Punctuation(Punctuation::Other),
                end,
            );
        }

        if let Some(held) = self.comment() {
            return held;
        }

        if let Some(held) = self.tag_angle(byte) {
            return held;
        }

        if byte == b'>' {
            let end = self.offset + 1;

            let held = self.take(
                TypeScriptKind::JsxTagEnd,
                TokenKind::Punctuation(Punctuation::Greater),
                end,
            );

            self.depth -= 1;

            if mode == Mode::Closing || !self.room() {
                return held;
            }

            return held && self.open(Mode::Children);
        }

        if byte == b'{' && self.room() {
            let end = self.offset + 1;
            let held = self.take(TypeScriptKind::BraceOpen, TokenKind::BlockStart, end);

            return held && self.open(Mode::Expression);
        }

        self.tag_atom(byte)
    }

    fn tag_angle(&mut self, byte: u8) -> Option<bool> {
        let index = self.depth as usize - 1;

        if byte == b'<' {
            let end = self.offset + 1;

            self.stack[index].depth += 1;

            return Some(self.take(
                TypeScriptKind::Less,
                TokenKind::Punctuation(Punctuation::Less),
                end,
            ));
        }

        if byte == b'>' && self.stack[index].depth > 0 {
            let end = self.offset + 1;

            self.stack[index].depth -= 1;

            return Some(self.take(
                TypeScriptKind::Greater,
                TokenKind::Punctuation(Punctuation::Greater),
                end,
            ));
        }

        None
    }

    fn tag_atom(&mut self, byte: u8) -> bool {
        if byte == b'"' || byte == b'\'' {
            let end = string_end(self.source, self.offset, self.limit);

            return self.take(TypeScriptKind::String, TokenKind::String, end);
        }

        if is_name_start(byte) {
            let end = name_end(self.source, self.offset, self.limit);

            return self.take(TypeScriptKind::Identifier, TokenKind::Identifier, end);
        }

        let (kind, coarse) = match byte {
            b',' => (
                TypeScriptKind::Comma,
                TokenKind::Punctuation(Punctuation::Comma),
            ),
            b'.' => (
                TypeScriptKind::Dot,
                TokenKind::Punctuation(Punctuation::Dot),
            ),
            b':' => (
                TypeScriptKind::Colon,
                TokenKind::Punctuation(Punctuation::Colon),
            ),
            b'=' => (
                TypeScriptKind::Equal,
                TokenKind::Punctuation(Punctuation::Assign),
            ),
            _ => (
                TypeScriptKind::ErrorToken,
                TokenKind::Punctuation(Punctuation::Other),
            ),
        };

        let end = self.offset + 1;
        let held = self.take(kind, coarse, end);

        if kind == TypeScriptKind::ErrorToken {
            self.depth -= 1;
        }

        held
    }

    fn children_step(&mut self) -> bool {
        if self.offset >= self.limit {
            self.depth -= 1;

            return true;
        }

        let byte = self.source[self.offset];

        if byte == b'<' && self.room() {
            return self.children_tag();
        }

        if byte == b'{' && self.room() {
            let end = self.offset + 1;
            let held = self.take(TypeScriptKind::BraceOpen, TokenKind::BlockStart, end);

            return held && self.open(Mode::Expression);
        }

        if byte == b'&' {
            if let Some(end) = entity_end(self.source, self.offset, self.limit) {
                return self.take(TypeScriptKind::JsxEntity, TokenKind::String, end);
            }
        }

        self.children_text()
    }

    fn children_tag(&mut self) -> bool {
        if self.source.get(self.offset + 1) == Some(&b'/') {
            let end = self.offset + 2;

            let held = self.take(
                TypeScriptKind::JsxTagStartClose,
                TokenKind::Punctuation(Punctuation::Less),
                end,
            );

            self.depth -= 1;

            return held && self.open(Mode::Closing);
        }

        let end = self.offset + 1;

        let held = self.take(
            TypeScriptKind::JsxTagStart,
            TokenKind::Punctuation(Punctuation::Less),
            end,
        );

        held && self.open(Mode::Opening)
    }

    fn children_text(&mut self) -> bool {
        let (end, kept) = text_end(self.source, self.offset, self.limit);

        if end == self.offset {
            let stop = self.offset + 1;

            let kind = if self.source[self.offset] == b'<' {
                TypeScriptKind::JsxChars
            } else {
                TypeScriptKind::ErrorToken
            };

            return self.take(kind, TokenKind::String, stop);
        }

        if !kept {
            self.offset = end;

            return true;
        }

        self.take(TypeScriptKind::JsxChars, TokenKind::String, end)
    }

    fn expression_step(&mut self) -> bool {
        self.blanks();

        if self.offset >= self.limit {
            self.depth -= 1;

            return true;
        }

        let byte = self.source[self.offset];
        let index = self.depth as usize - 1;

        if byte == b'}' && self.stack[index].depth == 0 {
            let end = self.offset + 1;
            let held = self.take(TypeScriptKind::BraceClose, TokenKind::BlockEnd, end);

            self.depth -= 1;

            return held;
        }

        if byte == b'`' {
            return self.expression_template(index);
        }

        if self.room()
            && opens_at(
                Some(self.stack[index].kind_previous),
                self.source,
                self.offset,
            )
        {
            return self.expression_jsx_open(index);
        }

        let (coarse, stop) =
            typescript_token_at(self.source, self.offset, self.stack[index].previous);

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
            self.stack[index].previous = coarse;
            self.stack[index].kind_previous = kind;
        }

        self.offset = reach.min(self.limit).max(self.offset + 1);

        held
    }

    fn expression_jsx_open(&mut self, index: usize) -> bool {
        let end = self.offset + 1;

        let held = self.take(
            TypeScriptKind::JsxTagStart,
            TokenKind::Punctuation(Punctuation::Less),
            end,
        );

        self.stack[index].previous = TokenKind::Punctuation(Punctuation::Greater);
        self.stack[index].kind_previous = TypeScriptKind::JsxTagEnd;

        held && self.open(Mode::Opening)
    }

    fn expression_template(&mut self, index: usize) -> bool {
        let (_, stop) = typescript_token_at(self.source, self.offset, self.stack[index].previous);
        let end = stop.min(self.limit).max(self.offset + 1);

        let span = Span {
            length: count_of(end - self.offset),
            offset: count_of(self.offset),
        };

        self.offset = end;
        self.stack[index].previous = TokenKind::String;
        self.stack[index].kind_previous = TypeScriptKind::TemplateEnd;

        template::expand(self.source, span, self.tokens, self.raw)
    }

    fn run(&mut self) -> Option<usize> {
        for _ in 0..STEP_MAX {
            if self.depth == 0 {
                return Some(self.offset);
            }

            let mode = self.stack[self.depth as usize - 1].mode;

            let held = match mode {
                Mode::Children => self.children_step(),
                Mode::Closing => self.tag_step(Mode::Closing),
                Mode::Expression => self.expression_step(),
                Mode::Opening => self.tag_step(Mode::Opening),
            };

            if !held {
                return None;
            }
        }

        None
    }
}

pub(crate) fn opens_at(previous: Option<TypeScriptKind>, source: &[u8], offset: usize) -> bool {
    if source.get(offset) != Some(&b'<') {
        return false;
    }

    let opens = source
        .get(offset + 1)
        .is_some_and(|byte| *byte == b'>' || is_name_start(*byte));

    if !opens {
        return false;
    }

    if previous.is_some_and(holds_a_value) {
        return false;
    }

    if source.get(offset + 1) == Some(&b'>') {
        return true;
    }

    !generic_arrow_at(source, offset, source.len())
}

#[must_use]
pub fn expand(
    source: &[u8],
    offset: usize,
    tokens: &mut Tokens,
    raw: &mut BoundedVec<TypeScriptKind>,
) -> Option<usize> {
    assert!(offset < source.len());
    assert_eq!(source.get(offset), Some(&b'<'));

    if !push(
        source,
        tokens,
        raw,
        TokenKind::Punctuation(Punctuation::Less),
        TypeScriptKind::JsxTagStart,
        offset,
        offset + 1,
    ) {
        return None;
    }

    let mut scanner = Scanner {
        depth: 0,
        limit: source.len(),
        offset: offset + 1,
        raw,
        source,
        stack: [Frame::EMPTY; JSX_DEPTH_MAX as usize],
        tokens,
    };

    if !scanner.open(Mode::Opening) {
        return None;
    }

    scanner.run()
}
