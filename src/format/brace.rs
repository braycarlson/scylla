use crate::bounded::{Buffer, Span, count_of};
use crate::format::ir::{Document, Element, Source as ElementSource};
use crate::format::print::{self, Options};
use crate::token::{Punctuation, Token, TokenKind};

pub const NEST_DEPTH_MAX: u32 = 128;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Policy {
    pub blank_max: u32,
    pub block_words: &'static [&'static [u8]],
    pub brace_hugs: bool,
    pub brace_spaces: bool,
    pub brace_words: &'static [&'static [u8]],
    pub bracket_types: bool,
    pub cast_words: &'static [&'static [u8]],
    pub dedent_words: &'static [&'static [u8]],
    pub hug_words: &'static [&'static [u8]],
    pub operand_words: &'static [&'static [u8]],
    pub postfix_words: &'static [&'static [u8]],
    pub prefix_words: &'static [&'static [u8]],
    pub signature_words: &'static [&'static [u8]],
    pub source_gaps: bool,
    pub source_words: &'static [&'static [u8]],
    pub ternary_colon: bool,
    pub tight_from_source: &'static [&'static [u8]],
    pub tight_words: &'static [&'static [u8]],
    pub unary_words: &'static [&'static [u8]],
    pub units: bool,
}

pub struct Input<'held> {
    pub options: Options,
    pub policy: Policy,
    pub source: &'held [u8],
    pub tokens: &'held [Token],
}

#[derive(Debug)]
pub struct Formatter {
    document: Document,
}

#[derive(Clone, Copy, Debug)]
struct Frame {
    casts: bool,
    index: bool,
    inside: bool,
    kind: TokenKind,
}

struct Emitter<'held> {
    closed: Frame,
    count: u32,
    depth: u32,
    document: &'held mut Document,
    indent: u32,
    line_first: u32,
    line_start: bool,
    nest: [Frame; NEST_DEPTH_MAX as usize],
    policy: Policy,
    previous: Option<u32>,
    source: &'held [u8],
    starting: bool,
    suppress_space: bool,
    tokens: &'held [Token],
}

const fn punctuated(kind: TokenKind) -> bool {
    matches!(
        kind,
        TokenKind::BlockEnd | TokenKind::BlockStart | TokenKind::Punctuation(_)
    )
}

const fn is_close(kind: TokenKind) -> bool {
    matches!(
        kind,
        TokenKind::BlockEnd
            | TokenKind::Punctuation(Punctuation::BracketClose | Punctuation::ParenClose)
    )
}

const fn is_open(kind: TokenKind) -> bool {
    matches!(
        kind,
        TokenKind::BlockStart
            | TokenKind::Punctuation(Punctuation::BracketOpen | Punctuation::ParenOpen)
    )
}

const fn opened_by(close: TokenKind) -> TokenKind {
    if matches!(close, TokenKind::BlockEnd) {
        return TokenKind::BlockStart;
    }

    if matches!(close, TokenKind::Punctuation(Punctuation::BracketClose)) {
        return TokenKind::Punctuation(Punctuation::BracketOpen);
    }

    TokenKind::Punctuation(Punctuation::ParenOpen)
}

const fn ends_operand(kind: TokenKind) -> bool {
    matches!(
        kind,
        TokenKind::Identifier
            | TokenKind::Number
            | TokenKind::String
            | TokenKind::Punctuation(Punctuation::BracketClose | Punctuation::ParenClose)
    )
}

pub fn balanced(tokens: &[Token]) -> bool {
    let mut depth = 0;
    let mut stack = [TokenKind::BlockStart; NEST_DEPTH_MAX as usize];

    for token in tokens {
        if is_open(token.kind) {
            if depth == NEST_DEPTH_MAX {
                return false;
            }

            stack[depth as usize] = token.kind;
            depth += 1;

            continue;
        }

        if !is_close(token.kind) {
            continue;
        }

        if depth == 0 || stack[depth as usize - 1] != opened_by(token.kind) {
            return false;
        }

        depth -= 1;
    }

    depth == 0
}

fn breaks(source: &[u8], from: u32, to: u32) -> u32 {
    assert!(from <= to);
    assert!(to as usize <= source.len());

    let mut found = 0;

    for byte in &source[from as usize..to as usize] {
        if *byte == b'\n' {
            found += 1;
        }
    }

    found
}

impl Formatter {
    pub fn reserve(element_count_max: u32) -> Self {
        assert!(element_count_max > 0);

        assert!(!crate::allocation::is_frozen());

        Self {
            document: Document::reserve(element_count_max, 4),
        }
    }

    pub fn document(&self) -> &Document {
        &self.document
    }

    #[must_use]
    pub fn format(&mut self, input: &Input<'_>, out: &mut Buffer) -> bool {
        self.document.clear();

        let mut emitter = Emitter {
            closed: Frame {
                casts: false,
                index: false,
                inside: false,
                kind: TokenKind::BlockStart,
            },
            count: count_of(input.tokens.len()),
            depth: 0,
            starting: true,
            document: &mut self.document,
            indent: 0,
            line_first: 0,
            line_start: true,
            nest: [Frame {
                casts: false,
                index: false,
                inside: false,
                kind: TokenKind::BlockStart,
            }; NEST_DEPTH_MAX as usize],
            policy: input.policy,
            previous: None,
            source: input.source,
            suppress_space: false,
            tokens: input.tokens,
        };

        if !emitter.run() {
            return false;
        }

        print::print(&self.document, input.source, &[], input.options, out)
    }
}

impl Emitter<'_> {
    fn blanks(&self, position: u32) -> u32 {
        let Some(previous) = self.previous else {
            return 0;
        };

        let from = self.tokens[previous as usize].end();
        let to = self.tokens[position as usize].offset;

        breaks(self.source, from, to).saturating_sub(1)
    }

    fn dedents(&self, position: u32) -> bool {
        let token = self.tokens[position as usize];

        if is_close(token.kind) || self.labels(position) {
            return true;
        }

        let bytes = token.text(self.source);

        self.policy.dedent_words.contains(&bytes)
    }

    fn level(&mut self, wanted: u32) -> bool {
        while self.indent > wanted {
            if !self.document.push(Element::Dedent) {
                return false;
            }

            self.indent -= 1;
        }

        while self.indent < wanted {
            if !self.document.push(Element::Indent) {
                return false;
            }

            self.indent += 1;
        }

        true
    }

    fn newline(&mut self, position: u32) -> bool {
        let blanks = self.blanks(position).min(self.policy.blank_max);

        self.line_start = true;
        self.suppress_space = false;

        self.document.push(Element::HardLine) && self.document.push(Element::BlankLine(blanks))
    }

    fn nested(&mut self, position: u32) -> bool {
        let kind = self.tokens[position as usize].kind;

        if is_open(kind) {
            if self.depth == NEST_DEPTH_MAX {
                return false;
            }

            self.nest[self.depth as usize] = Frame {
                casts: self
                    .previous
                    .is_some_and(|held| self.word_is(held, self.policy.cast_words)),
                index: self.indexes(),
                inside: kind == TokenKind::BlockStart
                    && (self.hugs_a_word()
                        || self.inline(position)
                            && (self.opens_a_block(position)
                                || self.policy.brace_spaces
                                    && !self.previous.is_some_and(|held| {
                                        self.word_is(held, self.policy.hug_words)
                                    }))),
                kind,
            };

            self.depth += 1;

            return true;
        }

        if is_close(kind)
            && self.depth > 0
            && self.nest[self.depth as usize - 1].kind == opened_by(kind)
        {
            self.depth -= 1;
            self.closed = self.nest[self.depth as usize];
        }

        true
    }

    fn indexes(&self) -> bool {
        if self.starting {
            return false;
        }

        let Some(previous) = self.previous else {
            return false;
        };

        let held = self.tokens[previous as usize].kind;

        if held == TokenKind::Punctuation(Punctuation::BracketClose) {
            return self.closed.index;
        }

        ends_operand(held)
    }

    const fn frame(&self) -> Frame {
        if self.depth == 0 {
            return Frame {
                casts: false,
                index: false,
                inside: false,
                kind: TokenKind::BlockStart,
            };
        }

        self.nest[self.depth as usize - 1]
    }

    fn word_is(&self, position: u32, words: &[&[u8]]) -> bool {
        let bytes = self.tokens[position as usize].text(self.source);

        words.contains(&bytes)
    }

    fn hugs_a_word(&self) -> bool {
        self.previous
            .is_some_and(|held| self.word_is(held, self.policy.brace_words))
    }

    fn inline(&self, position: u32) -> bool {
        let count = self.count;
        let open = self.tokens[position as usize].kind;
        let mut depth = 0;
        let mut scan = position;

        while scan < count {
            let kind = self.tokens[scan as usize].kind;

            if is_open(kind) {
                depth += 1;
            }

            if is_close(kind) {
                depth -= 1;

                if depth == 0 {
                    return opened_by(kind) == open
                        && breaks(
                            self.source,
                            self.tokens[position as usize].end(),
                            self.tokens[scan as usize].offset,
                        ) == 0;
                }
            }

            scan += 1;
        }

        false
    }

    fn run(&mut self) -> bool {
        let count = self.count;
        let mut written = false;

        for position in 0..count {
            let token = self.tokens[position as usize];

            if token.kind == TokenKind::Newline || token.length == 0 {
                continue;
            }

            if written && self.split(position) && !self.newline(position) {
                return false;
            }

            if !self.token(position) {
                return false;
            }

            written = true;
        }

        if !self.level(0) {
            return false;
        }

        if !written {
            return true;
        }

        self.document.push(Element::HardLine)
    }

    fn split(&self, position: u32) -> bool {
        let Some(previous) = self.previous else {
            return false;
        };

        let from = self.tokens[previous as usize].end();
        let to = self.tokens[position as usize].offset;

        breaks(self.source, from, to) > 0
    }

    fn spaced(&self, position: u32) -> bool {
        let held = self.decided(position);

        if !held && self.joins(position) {
            return true;
        }

        held
    }

    fn joins(&self, position: u32) -> bool {
        let Some(previous) = self.previous else {
            return false;
        };

        let held = self.tokens[previous as usize];
        let token = self.tokens[position as usize];
        punctuated(held.kind) && punctuated(token.kind) && held.end() < token.offset
    }

    fn decided(&self, position: u32) -> bool {
        let Some(previous) = self.previous else {
            return false;
        };

        if let Some(held) = self.sourced(position, previous) {
            return held;
        }

        if self.suppress_space {
            return false;
        }

        let held = self.tokens[previous as usize].kind;
        let kind = self.tokens[position as usize].kind;
        let frame = self.frame();

        if is_open(held) {
            return held == TokenKind::BlockStart && frame.inside && kind != TokenKind::BlockEnd;
        }

        if self.word_is(position, self.policy.postfix_words) {
            return false;
        }

        if let Some(decided) = self.worded(position, previous) {
            return decided;
        }

        if self.ternaried(position, previous) {
            return true;
        }

        if self.is_dot(position) {
            return !self.operand_at(previous)
                && !self.is_dot(previous)
                && !self.word_is(previous, self.policy.hug_words);
        }

        if matches!(
            kind,
            TokenKind::Punctuation(
                Punctuation::Comma | Punctuation::Semicolon | Punctuation::Colon
            )
        ) || self.is_dot(previous)
        {
            return false;
        }

        if let Some(decided) = self.braced(position, previous, frame) {
            return decided;
        }

        if matches!(
            kind,
            TokenKind::Punctuation(Punctuation::BracketOpen | Punctuation::ParenOpen)
        ) {
            return self.bracketed(position, previous);
        }

        if self.arrow(position) && self.word_is(previous, self.policy.hug_words) {
            return false;
        }

        true
    }

    fn sourced(&self, position: u32, previous: u32) -> Option<bool> {
        if let Some(held) = self.paired(position, previous) {
            return Some(held);
        }

        if self.policy.units
            && self.tokens[previous as usize].kind == TokenKind::Number
            && self.tokens[previous as usize].end() == self.tokens[position as usize].offset
        {
            return Some(false);
        }

        if self.policy.source_gaps {
            return self.gapped(position, previous);
        }

        None
    }

    fn braced(&self, position: u32, previous: u32, frame: Frame) -> Option<bool> {
        let held = self.tokens[previous as usize].kind;
        let kind = self.tokens[position as usize].kind;

        if kind == TokenKind::BlockEnd {
            return Some(frame.inside && held != TokenKind::BlockStart);
        }

        if is_close(kind) {
            return Some(false);
        }

        if kind == TokenKind::BlockStart {
            return Some(!self.hugged(position, previous));
        }

        None
    }

    fn ternaried(&self, position: u32, previous: u32) -> bool {
        if !self.policy.ternary_colon {
            return false;
        }

        let colon = TokenKind::Punctuation(Punctuation::Colon);

        self.tokens[position as usize].kind == colon && self.ternary(position)
            || self.tokens[previous as usize].kind == colon && self.ternary(previous)
    }

    fn ternary(&self, colon: u32) -> bool {
        let mut scan = colon;

        while scan > self.line_first {
            scan -= 1;

            let bytes = self.tokens[scan as usize].text(self.source);

            if bytes == b":" {
                return false;
            }

            if bytes == b"?" {
                return true;
            }
        }

        false
    }

    fn declares(&self, colon: u32) -> bool {
        if self.depth == 0 || colon < 2 {
            return false;
        }

        let name = self.tokens[(colon - 1) as usize].kind;
        let before = self.tokens[(colon - 2) as usize].kind;

        name == TokenKind::Identifier
            && matches!(
                before,
                TokenKind::BlockEnd
                    | TokenKind::BlockStart
                    | TokenKind::Punctuation(Punctuation::Semicolon)
            )
    }

    fn gapped(&self, position: u32, previous: u32) -> Option<bool> {
        let held = self.tokens[previous as usize].kind;
        let kind = self.tokens[position as usize].kind;

        if matches!(kind, TokenKind::BlockStart | TokenKind::BlockEnd)
            || matches!(held, TokenKind::BlockStart | TokenKind::BlockEnd)
        {
            return None;
        }

        let colon = TokenKind::Punctuation(Punctuation::Colon);
        let gap = self.tokens[previous as usize].end() < self.tokens[position as usize].offset;

        if kind == colon {
            return Some(false);
        }

        if held == colon {
            return Some(if self.declares(previous) { true } else { gap });
        }

        if matches!(
            kind,
            TokenKind::Punctuation(Punctuation::Comma | Punctuation::Semicolon)
        ) {
            return Some(false);
        }

        if matches!(
            held,
            TokenKind::Punctuation(Punctuation::Comma | Punctuation::Semicolon)
        ) {
            return Some(true);
        }

        Some(self.tokens[previous as usize].end() < self.tokens[position as usize].offset)
    }

    fn paired(&self, position: u32, previous: u32) -> Option<bool> {
        let gap = self.tokens[previous as usize].end() < self.tokens[position as usize].offset;

        if self.ellipsis(position) {
            return Some(!self.starting);
        }

        if self.ranges(previous) || self.ranges(position) {
            return Some(gap);
        }

        if previous > 0 && self.doubled(previous - 1) && self.is_dot(previous) {
            return Some(gap);
        }

        None
    }

    fn worded(&self, position: u32, previous: u32) -> Option<bool> {
        let held = self.tokens[previous as usize].kind;
        let gap = self.tokens[previous as usize].end() < self.tokens[position as usize].offset;

        if self.word_is(position, self.policy.tight_words)
            || self.word_is(previous, self.policy.tight_words)
        {
            return Some(false);
        }

        if self.doubled(previous) && previous + 1 == position {
            return Some(false);
        }

        if previous > 0
            && self.doubled(previous - 1)
            && held == TokenKind::Punctuation(Punctuation::Colon)
        {
            return Some(false);
        }

        if self.word_is(position, self.policy.source_words)
            || self.word_is(previous, self.policy.source_words)
        {
            return Some(gap);
        }

        if (self.word_is(position, self.policy.tight_from_source)
            || self.word_is(previous, self.policy.tight_from_source))
            && !gap
        {
            return Some(false);
        }

        None
    }

    fn bracketed(&self, position: u32, previous: u32) -> bool {
        let held = self.tokens[previous as usize].kind;

        if previous == self.line_first && self.word_is(previous, self.policy.signature_words) {
            return true;
        }

        if self.word_is(previous, self.policy.hug_words)
            || self.tokens[previous as usize]
                .text(self.source)
                .starts_with(b"@")
        {
            return false;
        }

        if self.prefixed(previous) {
            return true;
        }

        if matches!(held, TokenKind::Keyword(_))
            && self.tokens[previous as usize].end() == self.tokens[position as usize].offset
        {
            return false;
        }

        if held == TokenKind::BlockEnd {
            return false;
        }

        if held == TokenKind::Punctuation(Punctuation::ParenClose)
            && self.word_is(self.line_first, self.policy.signature_words)
        {
            return true;
        }

        if held == TokenKind::String {
            return true;
        }

        !self.operand_at(previous)
    }

    fn hugged(&self, position: u32, previous: u32) -> bool {
        if self.word_is(previous, self.policy.hug_words)
            && self.tokens[previous as usize].end() == self.tokens[position as usize].offset
        {
            return true;
        }

        if !self.inline(position)
            || self.opens_a_block(position)
            || self.word_is(self.line_first, self.policy.block_words)
        {
            return false;
        }

        let held = self.tokens[previous as usize].kind;

        if self.pathed(previous) {
            return true;
        }

        self.policy.brace_hugs
            && self.operand_at(previous)
            && held != TokenKind::Punctuation(Punctuation::ParenClose)
            || self.word_is(previous, self.policy.hug_words)
                && self.tokens[previous as usize].end() == self.tokens[position as usize].offset
            || self.word_is(previous, self.policy.tight_words)
    }

    fn opens_a_block(&self, position: u32) -> bool {
        self.next_of(position)
            .is_some_and(|held| matches!(self.tokens[held as usize].kind, TokenKind::Keyword(_)))
    }

    fn ranges(&self, position: u32) -> bool {
        self.tokens[position as usize].kind == TokenKind::Punctuation(Punctuation::Dot)
            && self.tokens[position as usize].length > 1
    }

    fn is_dot(&self, position: u32) -> bool {
        self.tokens[position as usize].kind == TokenKind::Punctuation(Punctuation::Dot)
            && self.tokens[position as usize].length == 1
    }

    fn operand_at(&self, position: u32) -> bool {
        ends_operand(self.tokens[position as usize].kind)
            || self.word_is(position, self.policy.operand_words)
    }

    fn pathed(&self, position: u32) -> bool {
        self.tokens[position as usize].kind == TokenKind::Punctuation(Punctuation::Colon)
            && position > 0
            && self.doubled(position - 1)
    }

    fn doubled(&self, position: u32) -> bool {
        let count = self.count;

        if position + 1 >= count {
            return false;
        }

        let held = self.tokens[position as usize];
        let next = self.tokens[(position + 1) as usize];

        if held.end() != next.offset || held.length != next.length {
            return false;
        }

        held.text(self.source) == next.text(self.source)
    }

    fn prefixed(&self, position: u32) -> bool {
        if position == 0 {
            return false;
        }

        let held = position - 1;

        self.word_is(held, self.policy.prefix_words)
            && self.tokens[held as usize].end() == self.tokens[position as usize].offset
    }

    fn arrow(&self, position: u32) -> bool {
        let token = self.tokens[position as usize];

        token.length == 2 && token.text(self.source) == b"<-"
    }

    fn ellipsis(&self, position: u32) -> bool {
        let count = self.count;

        if position + 2 >= count {
            return false;
        }

        (0..3).all(|held| {
            let token = self.tokens[(position + held) as usize];

            token.length == 1 && self.source[token.offset as usize] == b'.'
        })
    }

    fn labels(&self, position: u32) -> bool {
        if self.tokens[position as usize].kind != TokenKind::Identifier {
            return false;
        }

        let Some(colon) = self.next_of(position) else {
            return false;
        };

        if self.tokens[colon as usize].kind != TokenKind::Punctuation(Punctuation::Colon) {
            return false;
        }

        let Some(after) = self.next_of(colon) else {
            return true;
        };

        breaks(
            self.source,
            self.tokens[colon as usize].end(),
            self.tokens[after as usize].offset,
        ) > 0
    }

    fn next_of(&self, position: u32) -> Option<u32> {
        let count = self.count;
        let mut scan = position + 1;

        while scan < count {
            let token = self.tokens[scan as usize];

            if token.kind != TokenKind::Newline && token.length > 0 {
                return Some(scan);
            }

            scan += 1;
        }

        None
    }

    fn suppresses(&self, position: u32) -> bool {
        let token = self.tokens[position as usize];
        let frame = self.frame();

        if self.is_dot(position) {
            return !self.doubled(position) && (position == 0 || !self.doubled(position - 1));
        }

        if is_open(token.kind) {
            return token.kind != TokenKind::BlockStart || !frame.inside;
        }

        if token.kind == TokenKind::Punctuation(Punctuation::BracketClose) {
            return self.policy.bracket_types && !self.closed.index;
        }

        if token.kind == TokenKind::Punctuation(Punctuation::ParenClose) {
            return self.closed.casts;
        }

        if self.ellipsis(position)
            || self.word_is(position, self.policy.tight_words)
            || self.word_is(position, self.policy.prefix_words)
        {
            return true;
        }

        if self.arrow(position) {
            return self.starting
                || self.previous.is_none_or(|held| {
                    !ends_operand(self.tokens[held as usize].kind)
                        || self.word_is(held, self.policy.hug_words)
                })
                || self.follows_a_hug_word(position);
        }

        if self.word_is(position, self.policy.source_words) {
            return false;
        }

        if token.kind == TokenKind::Punctuation(Punctuation::Colon) {
            return frame.kind == TokenKind::Punctuation(Punctuation::BracketOpen);
        }

        if !matches!(token.kind, TokenKind::Punctuation(_)) {
            return false;
        }

        if !self.word_is(position, self.policy.unary_words)
            || self.doubled(position)
            || (position > 0 && self.doubled(position - 1))
        {
            return false;
        }

        if !self.adjacent(position) {
            return false;
        }

        self.starting
            || self
                .previous
                .is_none_or(|held| !ends_operand(self.tokens[held as usize].kind))
    }

    fn adjacent(&self, position: u32) -> bool {
        self.next_of(position).is_none_or(|held| {
            self.tokens[position as usize].end() == self.tokens[held as usize].offset
        })
    }

    fn follows_a_hug_word(&self, position: u32) -> bool {
        self.next_of(position)
            .is_some_and(|held| self.word_is(held, self.policy.hug_words))
    }

    fn token(&mut self, position: u32) -> bool {
        let token = self.tokens[position as usize];

        self.starting = self.line_start;

        if self.line_start {
            self.line_first = position;

            let wanted = if self.dedents(position) {
                self.depth.saturating_sub(1)
            } else {
                self.depth
            };

            if !self.level(wanted) {
                return false;
            }

            self.line_start = false;
        } else {
            let spaced = self.spaced(position);

            if spaced && !self.document.push(Element::Space) {
                return false;
            }
        }

        if !self.nested(position) {
            return false;
        }

        self.suppress_space = self.suppresses(position);
        self.previous = Some(position);

        let span = token.span();

        if self.source[span.range()].contains(&b'\n') {
            return self.document.push(Element::Verbatim(span));
        }

        self.document
            .push(Element::Text(ElementSource::Document, span))
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
