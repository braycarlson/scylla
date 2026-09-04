use crate::bounded::{BoundedVec, Span, count_of};
use crate::scan::line_break_width;
use crate::token::{Punctuation, Token, TokenKind};

const NEAR_BREAK_MAX: usize = 8;

pub(crate) const fn punctuated(kind: TokenKind) -> bool {
    matches!(
        kind,
        TokenKind::BlockEnd | TokenKind::BlockStart | TokenKind::Punctuation(_)
    )
}

pub fn substituting(source: &[u8], token: Token) -> bool {
    token.kind == TokenKind::String && token.text(source) == b"${"
}

pub(crate) fn simple_word(token: Token, source: &[u8]) -> bool {
    if matches!(
        token.kind,
        TokenKind::Identifier | TokenKind::Newline | TokenKind::Number | TokenKind::String
    ) {
        return true;
    }

    matches!(
        token.text(source),
        b"!" | b"&" | b"*" | b"-" | b"." | b"?" | b"[" | b"]" | b"as" | b"mut" | b"self"
    )
}

pub(crate) fn columns(source: &[u8], from: u32, to: u32) -> u32 {
    let stop = (to as usize).min(source.len());
    let start = (from as usize).min(stop);

    if source[start..stop].is_ascii() {
        return count_of(stop - start);
    }

    let mut held = 0_u32;
    let mut scan = from as usize;

    while scan < to as usize && scan < source.len() {
        if source[scan] & 0xC0 != 0x80 {
            held += if wide_at(source, scan) { 2 } else { 1 };
        }

        scan += 1;
    }

    held
}

fn wide_at(source: &[u8], position: usize) -> bool {
    let lead = source[position];

    let point = if lead & 0xF0 == 0xE0 {
        if position + 2 >= source.len() {
            return false;
        }

        (u32::from(lead & 0x0F) << 12)
            | (u32::from(source[position + 1] & 0x3F) << 6)
            | u32::from(source[position + 2] & 0x3F)
    } else if lead & 0xF8 == 0xF0 {
        if position + 3 >= source.len() {
            return false;
        }

        (u32::from(lead & 0x07) << 18)
            | (u32::from(source[position + 1] & 0x3F) << 12)
            | (u32::from(source[position + 2] & 0x3F) << 6)
            | u32::from(source[position + 3] & 0x3F)
    } else {
        return false;
    };

    matches!(
        point,
        0x1100..=0x115F
            | 0x2E80..=0x303E
            | 0x3041..=0x33FF
            | 0x3400..=0x4DBF
            | 0x4E00..=0x9FFF
            | 0xA000..=0xA4CF
            | 0xAC00..=0xD7A3
            | 0xF900..=0xFAFF
            | 0xFE10..=0xFE19
            | 0xFE30..=0xFE6F
            | 0xFF00..=0xFF60
            | 0xFFE0..=0xFFE6
            | 0x1F300..=0x1F64F
            | 0x1F900..=0x1F9FF
            | 0x20000..=0x3FFFD
    )
}

pub const fn is_close(kind: TokenKind) -> bool {
    matches!(
        kind,
        TokenKind::BlockEnd
            | TokenKind::Punctuation(Punctuation::BracketClose | Punctuation::ParenClose)
    )
}

pub const fn is_open(kind: TokenKind) -> bool {
    matches!(
        kind,
        TokenKind::BlockStart
            | TokenKind::Punctuation(Punctuation::BracketOpen | Punctuation::ParenOpen)
    )
}

pub const fn closed_by(open: TokenKind) -> TokenKind {
    if matches!(open, TokenKind::BlockStart) {
        return TokenKind::BlockEnd;
    }

    if matches!(open, TokenKind::Punctuation(Punctuation::BracketOpen)) {
        return TokenKind::Punctuation(Punctuation::BracketClose);
    }

    TokenKind::Punctuation(Punctuation::ParenClose)
}

pub const fn opened_by(close: TokenKind) -> TokenKind {
    if matches!(close, TokenKind::BlockEnd) {
        return TokenKind::BlockStart;
    }

    if matches!(close, TokenKind::Punctuation(Punctuation::BracketClose)) {
        return TokenKind::Punctuation(Punctuation::BracketOpen);
    }

    TokenKind::Punctuation(Punctuation::ParenOpen)
}

pub(crate) const fn ends_operand(kind: TokenKind) -> bool {
    matches!(
        kind,
        TokenKind::Identifier
            | TokenKind::Number
            | TokenKind::String
            | TokenKind::Punctuation(Punctuation::BracketClose | Punctuation::ParenClose)
    )
}

#[derive(Clone, Copy, Debug)]
struct Angle {
    depth: u32,
    drop: u32,
    total: i64,
}

impl Angle {
    const EMPTY: Self = Self {
        depth: 0,
        drop: 0,
        total: 0,
    };

    fn closed(&mut self, width: u32) {
        self.depth = self.depth.saturating_sub(width);
        self.total -= i64::from(width);

        let below = u32::try_from(-self.total).unwrap_or(0);

        self.drop = self.drop.max(below);
    }

    fn joined(self, inner: Self) -> Self {
        let reached = i64::from(self.depth.max(inner.drop)) + inner.total;
        let depth = u32::try_from(reached).expect("a saturating count never falls below zero");
        let below = u32::try_from(-(self.total + inner.total)).unwrap_or(0);

        Self {
            depth,
            drop: self.drop.max(below),
            total: self.total + inner.total,
        }
    }

    fn opened(&mut self) {
        self.depth += 1;
        self.total += 1;
    }
}

#[derive(Debug)]
pub(crate) struct Brackets {
    angles: BoundedVec<u32>,
    blocks: BoundedVec<u32>,
    closes: BoundedVec<u32>,
    held: BoundedVec<u32>,
    nested: BoundedVec<Angle>,
    opens: BoundedVec<u32>,
}

impl Brackets {
    pub(crate) fn reserve(count_max: u32) -> Self {
        Self {
            angles: BoundedVec::reserve(count_max),
            blocks: BoundedVec::reserve(count_max),
            closes: BoundedVec::reserve(count_max),
            held: BoundedVec::reserve(count_max),
            nested: BoundedVec::reserve(count_max),
            opens: BoundedVec::reserve(count_max),
        }
    }

    pub(crate) fn angles_at(&self, position: u32) -> u32 {
        self.angles.get(position as usize).copied().unwrap_or(0)
    }

    pub(crate) fn block_after(&self, position: u32) -> Option<u32> {
        let block = *self.blocks.get(position as usize)?;

        (block != u32::MAX).then_some(block)
    }

    pub(crate) fn close_of(&self, position: u32) -> Option<u32> {
        let close = *self.closes.get(position as usize)?;

        (close != u32::MAX).then_some(close)
    }

    pub(crate) fn open_of(&self, position: u32) -> Option<u32> {
        let open = *self.opens.get(position as usize)?;

        (open != u32::MAX).then_some(open)
    }

    pub(crate) fn build(&mut self, source: &[u8], tokens: &[Token]) -> bool {
        self.closes.clear();
        self.opens.clear();

        for _ in 0..tokens.len() {
            if !self.closes.push(u32::MAX) || !self.opens.push(u32::MAX) {
                return false;
            }
        }

        for kind in [
            TokenKind::BlockStart,
            TokenKind::Punctuation(Punctuation::BracketOpen),
            TokenKind::Punctuation(Punctuation::ParenOpen),
        ] {
            if !self.matched(source, tokens, kind) {
                return false;
            }
        }

        self.blocked(source, tokens) && self.angled(source, tokens)
    }

    fn angled(&mut self, source: &[u8], tokens: &[Token]) -> bool {
        self.angles.clear();
        self.nested.clear();

        let mut held = Angle::EMPTY;

        for token in tokens {
            if !self.angles.push(held.depth) {
                return false;
            }

            if is_open(token.kind) || substituting(source, *token) {
                if !self.nested.push(held) {
                    return false;
                }

                held = Angle::EMPTY;

                continue;
            }

            if is_close(token.kind) {
                held = self
                    .nested
                    .pop()
                    .map_or(Angle::EMPTY, |outer| outer.joined(held));

                continue;
            }

            let text = token.text(source);

            if text == b"<" {
                held.opened();
            } else if !text.is_empty() && text.iter().all(|byte| *byte == b'>') {
                held.closed(count_of(text.len()));
            }
        }

        true
    }

    fn blocked(&mut self, source: &[u8], tokens: &[Token]) -> bool {
        self.blocks.clear();

        for _ in 0..tokens.len() {
            if !self.blocks.push(u32::MAX) {
                return false;
            }
        }

        let mut next = u32::MAX;

        for position in (0..tokens.len()).rev() {
            let token = tokens[position];

            if matches!(token.kind, TokenKind::BlockStart | TokenKind::BlockEnd)
                || substituting(source, token)
            {
                next = count_of(position);
            }

            self.blocks[position] = next;
        }

        true
    }

    fn matched(&mut self, source: &[u8], tokens: &[Token], open: TokenKind) -> bool {
        let close = closed_by(open);

        self.held.clear();

        for position in 0..count_of(tokens.len()) {
            let token = tokens[position as usize];

            let opens =
                token.kind == open || open == TokenKind::BlockStart && substituting(source, token);

            if opens {
                if !self.held.push(position) {
                    return false;
                }

                continue;
            }

            if token.kind != close {
                continue;
            }

            if let Some(held) = self.held.pop() {
                self.closes[held as usize] = position;
                self.opens[position as usize] = held;
            }
        }

        true
    }
}

#[derive(Debug)]
pub(crate) struct Breaks {
    held: BoundedVec<u32>,
    leads: BoundedVec<u32>,
    plain: BoundedVec<u32>,
}

impl Breaks {
    pub(crate) fn reserve(count_max: u32) -> Self {
        Self {
            held: BoundedVec::reserve(count_max),
            leads: BoundedVec::reserve(count_max),
            plain: BoundedVec::reserve(count_max),
        }
    }

    pub(crate) fn counted(&self, from: u32, to: u32) -> u32 {
        assert!(from <= to);

        let start = self.plain.partition_point(|offset| *offset < from);
        let mut stop = start;

        while stop < self.plain.len() && stop - start < NEAR_BREAK_MAX && self.plain[stop] < to {
            stop += 1;
        }

        if stop - start == NEAR_BREAK_MAX {
            stop = self.plain.partition_point(|offset| *offset < to);
        }

        let found = count_of(stop - start);
        let first = self.held.partition_point(|offset| *offset < from);

        let owed = self
            .held
            .get(first)
            .is_some_and(|offset| *offset < to && self.leads[first] < from);

        found + u32::from(owed)
    }

    pub(crate) fn build(&mut self, source: &[u8], carriage: bool) -> bool {
        self.held.clear();
        self.leads.clear();
        self.plain.clear();

        let stop = source.len();
        let mut offset = 0;

        while offset < stop {
            if source[offset] == b'\\' {
                let mut cursor = offset + 1;

                while cursor < stop && matches!(source[cursor], b' ' | b'\t') {
                    cursor += 1;
                }

                let width = line_break_width(source, cursor);

                if width > 0 {
                    let counts = carriage || source[cursor] == b'\n' || width == 2;

                    if counts
                        && (!self.held.push(count_of(cursor)) || !self.leads.push(count_of(offset)))
                    {
                        return false;
                    }

                    offset = cursor + width;

                    continue;
                }
            }

            let width = line_break_width(source, offset);

            if width > 0 && (carriage || source[offset] == b'\n' || width == 2) {
                if !self.plain.push(count_of(offset)) {
                    return false;
                }

                offset += width;

                continue;
            }

            offset += 1;
        }

        true
    }
}

pub fn span_of(bytes: &[u8], lines: (u32, u32)) -> Option<Span> {
    assert!(lines.0 <= lines.1);

    let mut line = 0;
    let mut offset = 0;
    let mut start = None;
    let mut end = count_of(bytes.len());

    for position in 0..count_of(bytes.len()) {
        if line == lines.0 && start.is_none() {
            start = Some(offset);
        }

        if line == lines.1 + 1 {
            end = offset;

            break;
        }

        if bytes[position as usize] == b'\n' {
            line += 1;
            offset = position + 1;
        }
    }

    if line == lines.0 && start.is_none() {
        start = Some(offset);
    }

    let first = start?;

    assert!(end >= first);

    Some(Span {
        length: end - first,
        offset: first,
    })
}
