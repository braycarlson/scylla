use super::call::BINARY_LEVEL_MAX;
use super::{Emitter, NEST_DEPTH_MAX, ROLE_JSX, ROLE_SPACED};

const SUBSCRIPT_OPERANDS: bool = true;
const TIGHT_PRINTS: bool = true;
const ARROW_HEADS: [&[u8]; 12] = [
    b"async",
    b"await",
    b"case",
    b"default",
    b"delete",
    b"do",
    b"else",
    b"new",
    b"return",
    b"typeof",
    b"void",
    b"yield",
];

const HUGGED_HEADS: [&[u8]; 2] = [b"async", b"function"];
const ARGUMENT_HEAD_MAX: u32 = 8;

const BINARY_STOPS: [&[u8]; 17] = [
    b"%=",
    b"&&=",
    b"*=",
    b",",
    b"+=",
    b"-=",
    b"/=",
    b":",
    b";",
    b"=",
    b"=>",
    b"?",
    b"??=",
    b"case",
    b"return",
    b"throw",
    b"||=",
];

const BINARY_RANKS: [(&[u8], u32); 16] = [
    (b"!=", 7),
    (b"!==", 7),
    (b"%", 11),
    (b"&&", 3),
    (b"*", 11),
    (b"+", 10),
    (b"-", 10),
    (b"/", 11),
    (b"<=", 8),
    (b"==", 7),
    (b"===", 7),
    (b">=", 8),
    (b"??", 1),
    (b"in", 8),
    (b"instanceof", 8),
    (b"||", 2),
];

const BINARY_LOGICAL_RANK: u32 = 3;
const BINARY_EQUALITIES: [&[u8]; 4] = [b"!=", b"!==", b"==", b"==="];
const BINARY_PRODUCTS: [&[u8]; 3] = [b"%", b"*", b"/"];
const BINARY_OPERATOR_MAX: usize = 64;
const TIGHT_BEFORE: [&[u8]; 8] = [b"!", b")", b",", b"--", b".", b";", b"?.", b"]"];
const TIGHT_AFTER: [&[u8]; 7] = [b"!", b"#", b"(", b"...", b"?.", b"@", b"~"];
const CHAIN_LINK_MAX: u32 = 32;
const CHAIN_SCAN_MAX: u32 = 512;

const CHAIN_STOPS: [&[u8]; 10] = [
    b"await",
    b"case",
    b"delete",
    b"in",
    b"instanceof",
    b"new",
    b"return",
    b"throw",
    b"typeof",
    b"void",
];

const WRAPPED_WORDS: [&[u8]; 2] = [b"return", b"throw"];
const WRAPPED_REFUSED: [&[u8]; 6] = [b",", b"=", b"=>", b"?", b"as", b"satisfies"];

const WRAPPED_OPERATORS: [&[u8]; 16] = [
    b"!=",
    b"!==",
    b"%",
    b"&&",
    b"*",
    b"+",
    b"-",
    b"/",
    b"<=",
    b"==",
    b"===",
    b">=",
    b"??",
    b"in",
    b"instanceof",
    b"||",
];

const ASSIGN_LEVELS: bool = true;
const OPERAND_LEVELS: bool = true;
const CHAIN_NESTS: bool = true;
const CHAIN_ORPHANS: bool = true;
const OPERAND_ORPHANS: bool = true;
const LINK_OPERANDS: bool = true;
const ARM_BAR_MAX: u32 = 256;
const ARM_LETS: bool = true;
const HEADER_SCAN_MAX: u32 = 64;
const OPERAND_SCAN_MAX: u32 = 1024;

const OPERAND_LEADS: [&[u8]; 16] = [
    b"!=",
    b"%",
    b"&",
    b"&&",
    b"*",
    b"+",
    b"-",
    b"/",
    b"<<",
    b"<=",
    b"==",
    b">=",
    b">>",
    b"^",
    b"as",
    b"||",
];

const OPERAND_STOPS: [&[u8]; 16] = [
    b"#",
    b"%=",
    b"&=",
    b"*=",
    b"+=",
    b",",
    b"->",
    b"-=",
    b"/=",
    b":",
    b";",
    b"<<=",
    b"=",
    b"=>",
    b">>=",
    b"^=",
];

const OPERAND_STOP_WORDS: [&[u8]; 22] = [
    b"break",
    b"const",
    b"continue",
    b"else",
    b"enum",
    b"fn",
    b"for",
    b"if",
    b"impl",
    b"in",
    b"let",
    b"loop",
    b"match",
    b"mod",
    b"return",
    b"static",
    b"struct",
    b"trait",
    b"type",
    b"use",
    b"where",
    b"while",
];

const HERITAGE_SCAN_MAX: u32 = 256;
const BAR_COLUMNS: u32 = 2;
const UNION_MEMBER_MAX: usize = 64;
const UNION_SCAN_MAX: u32 = 1024;
const TYPE_HEAD_MAX: u32 = 64;
use crate::bounded::{Bytes as _, Span};
use crate::format::ir::{Element, Source};
use crate::format::stream::prefix_width;
use crate::format::text::{requoted, spaced};
use crate::format::walk::substituting;
use crate::format::walk::{columns, ends_operand, is_close, is_open};
use crate::token::{Punctuation, TokenKind};

struct Heritage {
    extends: Option<u32>,
    head: u32,
    implements: Option<u32>,
    interface: bool,
    keyword: u32,
    open: u32,
}

struct Union {
    bars: [u32; UNION_MEMBER_MAX],
    count: u32,
    head: u32,
    lead: Option<u32>,
    open: u32,
    stop: u32,
}

struct Scopes {
    depth: u32,
    held: [bool; NEST_DEPTH_MAX as usize],
}

impl Scopes {
    const fn new() -> Self {
        Self {
            depth: 0,
            held: [false; NEST_DEPTH_MAX as usize],
        }
    }

    fn open(&mut self, template: bool) {
        if self.depth == NEST_DEPTH_MAX {
            return;
        }

        self.held[self.depth as usize] = template;
        self.depth += 1;
    }

    fn close(&mut self) {
        self.depth = self.depth.saturating_sub(1);
    }

    const fn templated(&self) -> bool {
        self.depth > 0 && self.held[self.depth as usize - 1]
    }

    const fn valued(&self) -> bool {
        self.depth > 0 && !self.held[self.depth as usize - 1]
    }
}

const TAG_SCAN_MAX: u32 = 1 << 16;

#[expect(
    clippy::multiple_inherent_impl,
    reason = "the JSX walk and the verbatim-span writer live beside each other in `span.rs`, \
              which `mod.rs` and `wide.rs` both reach"
)]
impl Emitter<'_> {
    pub(super) fn jsx_body(&self, position: u32) -> Option<u32> {
        if !self.roled(position, ROLE_JSX) {
            return None;
        }

        let mut angles = 0_u32;
        let mut braces = 0_u32;
        let mut closing = false;
        let mut elements = 0_u32;
        let mut scan = position;
        let mut tagged = false;

        for _ in 0..TAG_SCAN_MAX {
            if scan >= self.count {
                return None;
            }

            let token = self.tokens[scan as usize];
            let opens = token.kind == TokenKind::BlockStart || substituting(self.source, token);
            let text = token.text(self.source);

            if braces > 0 {
                if opens {
                    braces += 1;
                } else if token.kind == TokenKind::BlockEnd {
                    braces -= 1;
                }

                scan += 1;

                continue;
            }

            if opens {
                braces += 1;
                scan += 1;

                continue;
            }

            if !tagged {
                if text == b"<" || text == b"</" {
                    closing = text == b"</";
                    tagged = true;
                }

                scan += 1;

                continue;
            }

            if text == b"</" {
                return None;
            }

            if text == b"<" {
                angles += 1;
                scan += 1;

                continue;
            }

            if angles > 0 {
                if text == b">" {
                    angles -= 1;
                }

                scan += 1;

                continue;
            }

            if text == b">" {
                tagged = false;

                if closing {
                    elements = elements.checked_sub(1)?;
                } else {
                    elements += 1;
                }
            } else if text == b"/>" {
                tagged = false;
            }

            if !tagged && elements == 0 {
                return Some(scan);
            }

            scan += 1;
        }

        None
    }

    pub(super) fn respanned(&mut self, position: u32, close: u32, indents: bool) -> bool {
        let source = self.source;
        let from = self.tokens[position as usize].offset;
        let to = self.tokens[close as usize].end();

        let tabbed =
            indents && !self.options.tabs && source[from as usize..to as usize].contains(&b'\t');

        let quoted = self.policy.string_quotes;

        if !tabbed && !quoted {
            return self.spanned(position, close);
        }

        let offset = self.arena.count();

        if !self.rewritten(from, to, position, close, tabbed) {
            self.arena.truncate(offset);

            return false;
        }

        if self.arena.as_bytes()[offset as usize..] == source[from as usize..to as usize] {
            self.arena.truncate(offset);

            return self.spanned(position, close);
        }

        self.previous = Some(close);
        self.resume = close + 1;
        self.suppress_space = false;

        self.document.push(Element::VerbatimArena(Span {
            length: self.arena.count() - offset,
            offset,
        }))
    }

    fn requotes(&self, held: u32, position: u32, scopes: &Scopes) -> bool {
        if scopes.templated() {
            return false;
        }

        if scopes.valued() {
            return true;
        }

        let mut scan = held;

        while scan > position {
            scan -= 1;

            let token = self.tokens[scan as usize];

            if token.kind == TokenKind::Newline || token.length == 0 {
                continue;
            }

            return token.kind == TokenKind::Punctuation(Punctuation::Assign);
        }

        false
    }

    fn rewritten(&mut self, from: u32, to: u32, position: u32, close: u32, tabbed: bool) -> bool {
        let source = self.source;
        let tokens = self.tokens;
        let width = self.options.indent_width;
        let mut at = from;
        let mut held = position;
        let mut scopes = Scopes::new();

        while at < to {
            while held <= close && tokens[held as usize].end() <= at {
                let token = tokens[held as usize];

                if token.kind == TokenKind::String && token.text(source) == b"`" {
                    if scopes.templated() {
                        scopes.close();
                    } else {
                        scopes.open(true);
                    }
                } else if token.kind == TokenKind::BlockStart || substituting(source, token) {
                    scopes.open(false);
                } else if token.kind == TokenKind::BlockEnd {
                    scopes.close();
                }

                held += 1;
            }

            if held <= close && tokens[held as usize].offset == at {
                let wanted = self
                    .requoting(held)
                    .filter(|_| self.requotes(held, position, &scopes));

                if let Some((body, quote)) = wanted {
                    let written = self.arena.push_bytes(&[quote])
                        && requoted(self.arena, body, quote)
                        && self.arena.push_bytes(&[quote]);

                    if !written {
                        return false;
                    }

                    at = tokens[held as usize].end();

                    continue;
                }

                if scopes.valued() && self.arrowed(held) {
                    let text = tokens[held as usize].text(source);

                    let written = self.arena.push_bytes(b"(")
                        && self.arena.push_bytes(text)
                        && self.arena.push_bytes(b")");

                    if !written {
                        return false;
                    }

                    at = tokens[held as usize].end();

                    continue;
                }
            }

            let inside = held <= close && {
                let token = tokens[held as usize];
                let text = token.text(source);

                token.offset < at
                    && matches!(token.kind, TokenKind::Comment | TokenKind::String)
                    && (scopes.depth > 0 || text.starts_with(b"\"") || text.starts_with(b"'"))
            };

            let Some(reached) = self.indented(source, at, to, tabbed && !inside, width) else {
                return false;
            };

            at = reached;
        }

        true
    }

    fn indented(
        &mut self,
        source: &[u8],
        at: u32,
        to: u32,
        tabbed: bool,
        width: u32,
    ) -> Option<u32> {
        let byte = source[at as usize];

        if !tabbed || !matches!(byte, b'\n' | b' ' | b'\t') {
            return self
                .arena
                .push_bytes(&source[at as usize..=at as usize])
                .then_some(at + 1);
        }

        let mut stop = at + u32::from(byte == b'\n');

        while stop < to && matches!(source[stop as usize], b' ' | b'\t') {
            stop += 1;
        }

        let ends = stop >= to || source[stop as usize] == b'\n';

        if byte != b'\n' {
            let written = ends || self.arena.push_bytes(&source[at as usize..stop as usize]);

            return written.then_some(stop);
        }

        let lead = prefix_width(&source[at as usize + 1..stop as usize], width);
        let written = self.arena.push_bytes(b"\n") && (ends || spaced(self.arena, lead));

        written.then_some(stop)
    }
}

#[expect(
    clippy::multiple_inherent_impl,
    reason = "the spread walks stand apart from the JSX one above them, and both are the \
              emitter's own"
)]
impl Emitter<'_> {
    pub(super) fn spread_source(&self, open: u32, close: u32) -> bool {
        if !self.policy.list_spreads || close <= open || self.bodied_brace(open) {
            return false;
        }

        let mut depth = 0_u32;
        let mut scan = open;

        while scan < close {
            let kind = self.tokens[scan as usize].kind;

            if let Some(end) = self.template_body(scan).or_else(|| self.jsx_body(scan)) {
                scan = end + 1;

                continue;
            }

            if scan > open && is_open(kind) {
                depth += 1;
            } else if is_close(kind) {
                depth = depth.saturating_sub(1);
            }

            let trails = self.next_of(scan) == Some(close);

            if !trails && self.spread_edge(scan, depth, open) && self.spread_break(scan) {
                return true;
            }

            scan += 1;
        }

        false
    }

    pub(super) fn spread_listed(&self, position: u32, previous: u32) -> bool {
        if !self.policy.list_spreads || self.depth == 0 || self.assign_owed() {
            return false;
        }

        let frame = self.frame();

        if !frame.parted {
            return false;
        }

        if self.tokens[position as usize].kind == TokenKind::Comment && !self.spread_break(previous)
        {
            return false;
        }

        if previous == frame.open || position == frame.close {
            return true;
        }

        self.spread_edge(previous, 0, frame.open)
    }

    fn spread_edge(&self, position: u32, depth: u32, open: u32) -> bool {
        if position == open {
            return true;
        }

        depth == 0
            && matches!(
                self.tokens[position as usize].kind,
                TokenKind::Punctuation(Punctuation::Comma | Punctuation::Semicolon)
            )
            && self.brackets.angles_at(position) == 0
    }

    fn spread_break(&self, position: u32) -> bool {
        let Some(next) = self.next_of(position) else {
            return false;
        };

        self.parted_by(
            self.tokens[position as usize].end(),
            self.tokens[next as usize].offset,
        ) > 0
    }
    pub(super) fn spread_rest(&self, close: u32) -> bool {
        if !self.policy.prefix_words.contains(&b"...".as_slice())
            || self.tokens[close as usize].kind != TokenKind::Punctuation(Punctuation::ParenClose)
        {
            return false;
        }

        let Some(open) = self.brackets.open_of(close) else {
            return false;
        };

        if self.policy.rest_binds && !self.bound_pattern(close) {
            return false;
        }

        let mut depth = 0_u32;
        let mut head = None;
        let mut scan = open + 1;

        while scan < close {
            let kind = self.tokens[scan as usize].kind;

            if is_open(kind) {
                depth += 1;
            } else if is_close(kind) {
                depth = depth.saturating_sub(1);
            } else if depth == 0
                && kind == TokenKind::Punctuation(Punctuation::Comma)
                && self.brackets.angles_at(scan) == 0
            {
                head = self.next_of(scan);
            } else if head.is_none()
                && kind != TokenKind::Newline
                && self.tokens[scan as usize].length > 0
            {
                head = Some(scan);
            }

            scan += 1;
        }

        head.is_some_and(|held| self.tokens[held as usize].text(self.source) == b"...")
    }
    pub(super) fn spread_forced(&self, open: u32, close: u32) -> bool {
        if !self.policy.hug_lasts
            || self.tokens[open as usize].kind != TokenKind::Punctuation(Punctuation::ParenOpen)
            || !self.listed(close)
        {
            return false;
        }

        let mut heads = [0_u32; ARGUMENT_HEAD_MAX as usize];
        let count = self.spread_heads(open, close, &mut heads);

        if count == 0 || self.spread_hooked(&heads, count, close) {
            return false;
        }

        let last = heads[(count - 1) as usize];

        let (from, to) = if self.spread_hugged(last, close) {
            (open + 1, last)
        } else if count == 2 && self.spread_hugged(heads[0], close) {
            (heads[1], close)
        } else {
            (open + 1, close)
        };

        self.spread_breaks(from, to)
    }

    fn spread_breaks(&self, from: u32, to: u32) -> bool {
        let mut scan = from;

        while scan < to {
            if let Some(end) = self.template_body(scan).or_else(|| self.jsx_body(scan)) {
                scan = end + 1;

                continue;
            }

            if self.parts_body(scan) {
                return true;
            }

            scan += 1;
        }

        false
    }

    fn spread_heads(&self, open: u32, close: u32, heads: &mut [u32]) -> u32 {
        let mut count = 0;
        let mut depth = 0_u32;
        let mut scan = open;

        while scan < close {
            if let Some(end) = self.template_body(scan).or_else(|| self.jsx_body(scan)) {
                scan = end + 1;

                continue;
            }

            let kind = self.tokens[scan as usize].kind;

            let heads_one = scan == open
                || depth == 0
                    && kind == TokenKind::Punctuation(Punctuation::Comma)
                    && self.brackets.angles_at(scan) == 0;

            if heads_one {
                let Some(held) = self.next_of(scan).filter(|held| *held < close) else {
                    break;
                };

                if count == ARGUMENT_HEAD_MAX {
                    return 0;
                }

                heads[count as usize] = held;
                count += 1;
            } else if scan > open && is_open(kind) {
                depth += 1;
            } else if is_close(kind) {
                depth = depth.saturating_sub(1);
            }

            scan += 1;
        }

        count
    }

    fn spread_hooked(&self, heads: &[u32], count: u32, close: u32) -> bool {
        if !(2..=3).contains(&count) {
            return false;
        }

        let at = (count - 2) as usize;
        let held = heads[at];

        if self.tokens[heads[(count - 1) as usize] as usize].kind
            != TokenKind::Punctuation(Punctuation::BracketOpen)
        {
            return false;
        }

        if self.tokens[held as usize].kind != TokenKind::Punctuation(Punctuation::ParenOpen) {
            return false;
        }

        self.next_of(held).is_some_and(|after| {
            self.tokens[after as usize].kind == TokenKind::Punctuation(Punctuation::ParenClose)
                && self.spread_hugged(held, close)
        })
    }

    fn spread_hugged(&self, head: u32, close: u32) -> bool {
        let kind = self.tokens[head as usize].kind;

        if matches!(
            kind,
            TokenKind::BlockStart | TokenKind::Punctuation(Punctuation::BracketOpen)
        ) {
            return self.closing_of(head) != self.next_of(head);
        }

        if HUGGED_HEADS.contains(&self.tokens[head as usize].text(self.source)) {
            return true;
        }

        if kind == TokenKind::Punctuation(Punctuation::ParenOpen) {
            return self
                .closing_of(head)
                .filter(|held| *held < close)
                .is_some_and(|held| self.spread_arrowed(held));
        }

        if kind != TokenKind::Identifier {
            return false;
        }

        if self.spread_arrowed(head) {
            return true;
        }

        self.spread_typed(head)
    }

    pub(super) fn spread_arrowed(&self, position: u32) -> bool {
        let Some(after) = self.next_of(position) else {
            return false;
        };

        let text = self.tokens[after as usize].text(self.source);

        if text == b"=>" {
            return true;
        }

        if self.tokens[after as usize].kind != TokenKind::Punctuation(Punctuation::Colon)
            || self.ternary(after)
        {
            return false;
        }

        let mut depth = 0_u32;
        let mut scan = after;

        for _ in 0..TYPE_HEAD_MAX {
            let Some(held) = self.next_of(scan) else {
                return false;
            };

            let kind = self.tokens[held as usize].kind;

            if is_open(kind) {
                depth += 1;
            } else if is_close(kind) {
                if depth == 0 {
                    return false;
                }

                depth -= 1;
            } else if depth == 0 && self.tokens[held as usize].text(self.source) == b"=>" {
                return true;
            }

            scan = held;
        }

        false
    }

    fn spread_typed(&self, head: u32) -> bool {
        let Some(after) = self.next_of(head) else {
            return false;
        };

        if self.tokens[after as usize].kind != TokenKind::Punctuation(Punctuation::Colon) {
            return false;
        }

        self.next_of(after)
            .is_some_and(|held| self.tokens[held as usize].kind == TokenKind::BlockStart)
    }
    pub(super) fn spread_matrix(&self, open: u32, close: u32) -> bool {
        if !self.policy.hug_lasts
            || self.tokens[open as usize].kind != TokenKind::Punctuation(Punctuation::BracketOpen)
        {
            return false;
        }

        let mut count = 0;
        let mut held = None;
        let mut scan = self.next_of(open).filter(|item| *item < close);

        while let Some(head) = scan {
            let kind = self.tokens[head as usize].kind;

            if !matches!(
                kind,
                TokenKind::BlockStart | TokenKind::Punctuation(Punctuation::BracketOpen)
            ) || held.is_some_and(|item| item != kind)
            {
                return false;
            }

            let Some(stop) = self.closing_of(head).filter(|item| *item < close) else {
                return false;
            };

            if self.spread_items(head, stop) < 2 {
                return false;
            }

            held = Some(kind);
            count += 1;
            scan = self.spread_next(stop, close);
        }

        count > 1
    }

    fn spread_next(&self, stop: u32, close: u32) -> Option<u32> {
        let after = self.next_of(stop).filter(|item| *item < close)?;

        if self.tokens[after as usize].kind != TokenKind::Punctuation(Punctuation::Comma) {
            return None;
        }

        self.next_of(after).filter(|item| *item < close)
    }

    fn spread_items(&self, open: u32, close: u32) -> u32 {
        let mut count = 0;
        let mut depth = 0_u32;
        let mut scan = open + 1;
        let mut written = false;

        while scan < close {
            let kind = self.tokens[scan as usize].kind;

            if is_open(kind) {
                depth += 1;
            } else if is_close(kind) {
                depth = depth.saturating_sub(1);
            } else if depth == 0 && kind == TokenKind::Punctuation(Punctuation::Comma) {
                count += u32::from(written);
                written = false;
                scan += 1;

                continue;
            }

            written |= self.tokens[scan as usize].length > 0 && kind != TokenKind::Newline;
            scan += 1;
        }

        count + u32::from(written)
    }
    pub(super) fn spread_arrows(&self, open: u32) -> bool {
        if !self.policy.hug_lasts
            || self.tokens[open as usize].kind != TokenKind::Punctuation(Punctuation::ParenOpen)
        {
            return false;
        }

        let typed = self.back_of(open).is_some_and(|held| {
            self.tokens[held as usize].kind == TokenKind::Punctuation(Punctuation::Colon)
                && self.back_of(held).is_some_and(|before| {
                    self.tokens[before as usize].kind
                        == TokenKind::Punctuation(Punctuation::ParenClose)
                })
        });

        if typed || !self.arrow_opens(open) {
            return false;
        }

        self.closing_of(open).is_some_and(|close| {
            let items = self.spread_items(open, close);

            self.spread_arrowed(close)
                && (items > 1
                    || self.policy.hug_soles
                        && items == 1
                        && self.spread_typing(open, close)
                        && !self.spread_hugs(open, close))
        })
    }

    fn arrow_opens(&self, open: u32) -> bool {
        self.back_of(open).is_none_or(|held| {
            let token = self.tokens[held as usize];

            token.kind != TokenKind::Identifier
                && (!matches!(token.kind, TokenKind::Keyword(_))
                    || ARROW_HEADS.contains(&token.text(self.source)))
        })
    }

    fn spread_typing(&self, open: u32, close: u32) -> bool {
        let Some(head) = self.next_of(open).filter(|held| *held < close) else {
            return false;
        };

        self.next_of(head).is_some_and(|held| held < close)
    }

    fn spread_hugs(&self, open: u32, close: u32) -> bool {
        let Some(head) = self.next_of(open).filter(|held| *held < close) else {
            return false;
        };

        let kind = self.tokens[head as usize].kind;

        if matches!(
            kind,
            TokenKind::BlockStart | TokenKind::Punctuation(Punctuation::BracketOpen)
        ) {
            return true;
        }

        if kind != TokenKind::Identifier {
            return false;
        }

        let Some(mut scan) = self.next_of(head) else {
            return false;
        };

        if self.tokens[scan as usize].text(self.source) == b"?"
            && let Some(held) = self.next_of(scan)
        {
            scan = held;
        }

        if self.tokens[scan as usize].kind != TokenKind::Punctuation(Punctuation::Colon) {
            return false;
        }

        let Some(typed) = self.next_of(scan) else {
            return false;
        };

        if self.tokens[typed as usize].kind != TokenKind::BlockStart {
            return false;
        }

        self.closing_of(typed).and_then(|end| self.next_of(end)) == Some(close)
    }
    pub(super) fn wrapped_paren(&self, open: u32) -> bool {
        self.policy.return_parens
            && self.tokens[open as usize].kind == TokenKind::Punctuation(Punctuation::ParenOpen)
            && self.back_of(open).is_some_and(|held| {
                WRAPPED_WORDS.contains(&self.tokens[held as usize].text(self.source))
            })
    }

    pub(super) fn wrapping(&self, position: u32) -> Option<u32> {
        if !self.policy.return_parens || self.line_first != position {
            return None;
        }

        let text = self.tokens[position as usize].text(self.source);

        if !WRAPPED_WORDS.contains(&text) {
            return None;
        }

        let head = self.next_of(position)?;
        let (end, operated) = self.wrapping_end(head)?;

        if !operated || end == head {
            return None;
        }

        if self.wrapping_parted(head, end) || self.wrapping_chained(head, end) {
            return None;
        }

        if self.tokens[head as usize].kind == TokenKind::Punctuation(Punctuation::ParenOpen)
            && self.closing_of(head) == Some(end)
        {
            let (found, close) = self.wrap_parens(position)?;

            if found != head {
                return None;
            }

            return self.back_of(close);
        }

        Some(end)
    }

    pub(super) fn wrap_parens(&self, position: u32) -> Option<(u32, u32)> {
        if !self.policy.binary_lines {
            return None;
        }

        let open = self.next_of(position)?;

        if !self.wrapped_paren(open) {
            return None;
        }

        let close = self.closing_of(open)?;
        let ends = self.next_of(close).is_none_or(|held| {
            self.tokens[held as usize].kind == TokenKind::Punctuation(Punctuation::Semicolon)
        });

        (ends && self.binary_floor(open, close) != BINARY_LEVEL_MAX).then_some((open, close))
    }

    pub(super) fn wrap_dropped(&self, position: u32) -> bool {
        if !self.policy.binary_lines {
            return false;
        }

        let token = self.tokens[position as usize];

        let held = match token.kind {
            TokenKind::Punctuation(Punctuation::ParenOpen) => Some(position),
            TokenKind::Punctuation(Punctuation::ParenClose) => self.brackets.open_of(position),
            _ => None,
        };

        let Some(open) = held else {
            return false;
        };

        let Some(word) = self.back_of(open) else {
            return false;
        };

        self.wrap_parens(word) == Some((open, self.closing_of(open).unwrap_or(0)))
    }

    fn wrapping_end(&self, head: u32) -> Option<(u32, bool)> {
        let mut depth = 0_u32;
        let mut end = head;
        let mut operated = false;
        let mut scan = head;

        while scan < self.count {
            if self.jsx_body(scan).is_some() {
                return None;
            }

            if let Some(stop) = self.template_body(scan) {
                end = stop;
                scan = stop + 1;

                continue;
            }

            let token = self.tokens[scan as usize];
            let kind = token.kind;

            if token.text(self.source) == b"?" && !self.optional(scan) {
                return None;
            }

            if kind == TokenKind::Newline || token.length == 0 {
                scan += 1;

                continue;
            }

            if kind == TokenKind::Comment {
                return None;
            }

            if is_open(kind) {
                depth += 1;
            } else if is_close(kind) {
                if depth == 0 {
                    break;
                }

                depth -= 1;
            } else if depth == 0 && kind == TokenKind::Punctuation(Punctuation::Semicolon) {
                break;
            } else if depth == 0 && WRAPPED_REFUSED.contains(&token.text(self.source)) {
                return None;
            } else if depth == 0 && self.wrapping_operator(scan) {
                operated = true;
            }

            end = scan;
            scan += 1;
        }

        Some((end, operated))
    }

    pub(super) fn wrapping_operator(&self, position: u32) -> bool {
        let text = self.tokens[position as usize].text(self.source);

        if !WRAPPED_OPERATORS.contains(&text) {
            return false;
        }

        self.back_of(position).is_some_and(|held| {
            let token = self.tokens[held as usize];

            matches!(
                token.kind,
                TokenKind::Identifier | TokenKind::Number | TokenKind::String
            ) || is_close(token.kind)
                || token.kind == TokenKind::BlockEnd
        })
    }
    fn wrapping_parted(&self, head: u32, end: u32) -> bool {
        let mut depth = 0_u32;
        let mut previous = head;
        let mut scan = head;

        while scan <= end {
            if let Some(stop) = self.template_body(scan).or_else(|| self.jsx_body(scan)) {
                previous = stop;
                scan = stop + 1;

                continue;
            }

            let token = self.tokens[scan as usize];

            if token.kind == TokenKind::Newline || token.length == 0 {
                scan += 1;

                continue;
            }

            let operated =
                self.policy.binary_lines && depth == 0 && self.wrapping_operator(previous);

            if scan > head
                && self.parted_by(self.tokens[previous as usize].end(), token.offset) > 0
                && !operated
                && !self.binary_leveled(previous)
            {
                return true;
            }

            if is_open(token.kind) {
                depth += 1;
            } else if is_close(token.kind) {
                depth = depth.saturating_sub(1);
            }

            previous = scan;
            scan += 1;
        }

        false
    }
    pub(super) fn assign_breaks(&self, position: u32) -> bool {
        if !self.policy.hug_lasts {
            return false;
        }

        let mut depth = 0_u32;
        let mut scan = position + 1;

        while scan < self.count {
            if let Some(stop) = self.template_body(scan).or_else(|| self.jsx_body(scan)) {
                scan = stop + 1;

                continue;
            }

            let token = self.tokens[scan as usize];
            let text = token.text(self.source);

            if is_open(token.kind) {
                depth += 1;
            } else if is_close(token.kind) {
                if depth == 0 {
                    return false;
                }

                depth -= 1;
            } else if depth == 0 {
                if matches!(text, b";" | b"=>") || text == b"?" && !self.optional(scan) {
                    return false;
                }

                if self.wrapping_operator(scan) {
                    return true;
                }
            }

            scan += 1;
        }

        false
    }
    pub(super) fn chain_broken(&self, position: u32) -> bool {
        if !self.policy.chain_groups || !self.is_dot(position) || self.assign_owed() {
            return false;
        }

        if !self.inside_a_body() {
            return false;
        }

        let Some(head) = self.chain_start(position) else {
            return false;
        };

        let Some(stop) = self.chain_stop(head) else {
            return false;
        };

        if !self.chain_composed(head, stop) {
            return false;
        }

        let mut links = [0_u32; CHAIN_LINK_MAX as usize];
        let count = self.chain_groups(head, stop, &mut links);
        let merges = self.chain_merges(head, &links, count);
        let cutoff = if merges { 3 } else { 2 };
        let from = usize::from(merges);

        count >= cutoff && links[from..count as usize].contains(&position)
    }

    pub(super) fn chain_parts(&self, position: u32, previous: u32) -> bool {
        if !self.policy.chain_groups || !self.is_dot(position) {
            return false;
        }

        if self.assign_owed() || !self.inside_a_body() {
            return false;
        }

        let Some(head) = self.chain_start(position) else {
            return false;
        };

        let Some(stop) = self.chain_stop(head) else {
            return false;
        };

        let composed = self.chain_composed(head, stop);

        if !composed
            && self.parted_by(
                self.tokens[head as usize].offset,
                self.tokens[stop as usize].end(),
            ) > 0
        {
            return false;
        }

        let mut links = [0_u32; CHAIN_LINK_MAX as usize];
        let count = self.chain_groups(head, stop, &mut links);
        let merges = self.chain_merges(head, &links, count);
        let cutoff = if merges { 3 } else { 2 };
        let from = usize::from(merges);

        if count < cutoff || !links[from..count as usize].contains(&position) {
            return false;
        }

        if self.chain_calls(head, stop) < 2 {
            return false;
        }

        let _ = previous;

        composed || self.chain_wide(head, stop, position == links[from])
    }

    fn chain_wide(&self, head: u32, stop: u32, first: bool) -> bool {
        let seated = self.back_of(head).is_some_and(|held| {
            WRAPPED_WORDS.contains(&self.tokens[held as usize].text(self.source))
        });

        let opens = if seated { head } else { self.chain_opens(head) };
        let from_at = opens;
        let from = self.tokens[opens as usize].offset;
        let to = self.tokens[stop as usize].end();

        if to <= from {
            return false;
        }

        let levels = if first {
            self.printed
        } else {
            self.printed.saturating_sub(1)
        } + u32::from(seated);

        let width = self.printed_columns(from_at, stop) + self.chain_widened(head, stop);

        levels * self.options.indent_width + width + 1 > self.options.line_width
    }

    fn chain_start(&self, position: u32) -> Option<u32> {
        let mut head = position;
        let mut scan = position;

        for _ in 0..CHAIN_SCAN_MAX {
            let before = self.back_of(scan)?;
            let kind = self.tokens[before as usize].kind;

            if is_close(kind) {
                scan = self.brackets.open_of(before)?;
                head = scan;

                continue;
            }

            let text = self.tokens[before as usize].text(self.source);

            let carried = matches!(kind, TokenKind::Identifier | TokenKind::Keyword(_))
                && !CHAIN_STOPS.contains(&text)
                || text == b"!"
                || self.is_dot(before);

            if !carried {
                return (head < position).then_some(head);
            }

            scan = before;
            head = before;
        }

        None
    }

    fn chain_stop(&self, head: u32) -> Option<u32> {
        let mut scan = head;
        let mut stop = head;

        for _ in 0..CHAIN_SCAN_MAX {
            let Some(after) = self.next_of(scan) else {
                break;
            };

            let kind = self.tokens[after as usize].kind;

            if is_open(kind) {
                let close = self.closing_of(after)?;

                scan = close;
                stop = close;

                continue;
            }

            let text = self.tokens[after as usize].text(self.source);

            let carried = matches!(kind, TokenKind::Identifier | TokenKind::Keyword(_))
                && !CHAIN_STOPS.contains(&text)
                || text == b"!"
                || self.is_dot(after)
                || text == b"<";

            if !carried {
                break;
            }

            if text == b"<" {
                return None;
            }

            scan = after;
            stop = after;
        }

        (stop > head).then_some(stop)
    }

    fn chain_groups(&self, head: u32, stop: u32, links: &mut [u32]) -> u32 {
        let mut called = false;
        let mut count = 0;
        let mut headed = false;
        let mut scan = head;

        while scan <= stop {
            let kind = self.tokens[scan as usize].kind;

            if is_open(kind) {
                called |= kind == TokenKind::Punctuation(Punctuation::ParenOpen);
                scan = self.closing_of(scan).unwrap_or(stop) + 1;

                continue;
            }

            let opens = self.is_dot(scan)
                && if headed {
                    called
                } else {
                    self.chain_called(scan)
                };

            if opens {
                if count == CHAIN_LINK_MAX {
                    return 0;
                }

                links[count as usize] = scan;
                called = false;
                count += 1;
                headed = true;
            }

            scan += 1;
        }

        count
    }

    fn chain_called(&self, dot: u32) -> bool {
        let Some(name) = self.next_of(dot) else {
            return false;
        };

        self.next_of(name).is_some_and(|held| {
            self.tokens[held as usize].kind == TokenKind::Punctuation(Punctuation::ParenOpen)
        })
    }

    fn chain_merges(&self, head: u32, links: &[u32], count: u32) -> bool {
        if count < 2 {
            return false;
        }

        let text = self.tokens[head as usize].text(self.source);

        let factory = text.first().is_some_and(u8::is_ascii_uppercase)
            || !text.is_empty() && text.iter().all(|byte| matches!(*byte, b'_' | b'$'))
            || self.line_first == head && text.len() <= self.options.indent_width as usize;

        if self.back_of(links[0]) == Some(head) {
            return factory;
        }

        self.back_of(links[0]).is_some_and(|held| {
            self.tokens[held as usize]
                .text(self.source)
                .first()
                .is_some_and(u8::is_ascii_uppercase)
        })
    }
    fn chain_opens(&self, head: u32) -> u32 {
        let mut opens = head;

        for _ in 0..CHAIN_SCAN_MAX {
            let Some(before) = self.back_of(opens) else {
                break;
            };

            if self.binary_assigned(before) {
                break;
            }

            if self.parted_by(
                self.tokens[before as usize].end(),
                self.tokens[opens as usize].offset,
            ) > 0
            {
                break;
            }

            let kind = self.tokens[before as usize].kind;

            if matches!(kind, TokenKind::BlockStart | TokenKind::BlockEnd)
                || matches!(
                    kind,
                    TokenKind::Punctuation(Punctuation::Semicolon | Punctuation::Comma)
                )
            {
                break;
            }

            opens = before;
        }

        opens
    }
    fn chain_calls(&self, head: u32, stop: u32) -> u32 {
        let mut count = 0;
        let mut scan = head;

        while scan <= stop {
            let kind = self.tokens[scan as usize].kind;

            if is_open(kind) {
                count += u32::from(kind == TokenKind::Punctuation(Punctuation::ParenOpen));
                scan = self.closing_of(scan).unwrap_or(stop) + 1;

                continue;
            }

            scan += 1;
        }

        count
    }
    fn chain_widened(&self, head: u32, stop: u32) -> u32 {
        let mut count = 0;
        let mut scan = head;

        while scan <= stop {
            count += 2 * u32::from(self.arrowed(scan));
            scan += 1;
        }

        count
    }
    fn wrapping_chained(&self, head: u32, end: u32) -> bool {
        let mut scan = head;

        while scan <= end {
            if self.is_dot(scan) && self.chain_parts(scan, scan) {
                return true;
            }

            scan += 1;
        }

        false
    }
    pub(super) fn typed_brace(&self, close: u32) -> bool {
        if self.policy.type_words.is_empty()
            || self.tokens[close as usize].kind != TokenKind::BlockEnd
        {
            return false;
        }

        let Some(open) = self.brackets.open_of(close) else {
            return false;
        };

        self.typed_open(open)
    }

    pub(super) fn typed_open(&self, open: u32) -> bool {
        if self.policy.type_words.is_empty()
            || self.tokens[open as usize].kind != TokenKind::BlockStart
            || self.bodied_brace(open)
        {
            return false;
        }

        let returned = self.back_of(open).is_some_and(|held| {
            self.tokens[held as usize].kind == TokenKind::Punctuation(Punctuation::Colon)
                && self.back_of(held).is_some_and(|before| {
                    self.tokens[before as usize].kind
                        == TokenKind::Punctuation(Punctuation::ParenClose)
                })
        });

        let hugged = self.back_of(open).is_some_and(|held| {
            self.tokens[held as usize].kind == TokenKind::Punctuation(Punctuation::Colon)
                && self.back_of(held).is_some_and(|name| {
                    self.back_of(name).is_some_and(|before| {
                        self.tokens[before as usize].kind
                            == TokenKind::Punctuation(Punctuation::ParenOpen)
                    })
                })
        });

        !returned && !hugged && self.brackets.angles_at(open) == 0 && self.typed_members(open)
    }

    fn typed_members(&self, open: u32) -> bool {
        let Some(close) = self.closing_of(open) else {
            return false;
        };

        let mut depth = 0_u32;
        let mut scan = open + 1;

        while scan < close {
            if let Some(end) = self.template_body(scan).or_else(|| self.jsx_body(scan)) {
                scan = end + 1;

                continue;
            }

            let kind = self.tokens[scan as usize].kind;

            if is_open(kind) {
                depth += 1;
            } else if is_close(kind) {
                depth = depth.saturating_sub(1);
            } else if depth == 0 && kind == TokenKind::Punctuation(Punctuation::Semicolon) {
                return true;
            }

            scan += 1;
        }

        false
    }
    pub(super) fn printed_columns(&self, from: u32, to: u32) -> u32 {
        let mut previous = None;
        let mut scan = from;
        let mut width = 0;

        while scan <= to {
            let token = self.tokens[scan as usize];

            if token.length == 0 || token.kind == TokenKind::Newline {
                scan += 1;

                continue;
            }

            if token.kind == TokenKind::Punctuation(Punctuation::Comma)
                && self
                    .next_of(scan)
                    .is_some_and(|held| is_close(self.tokens[held as usize].kind))
            {
                scan += 1;

                continue;
            }

            if self.wrap_dropped(scan) {
                scan += 1;

                continue;
            }

            width += self.quoted_columns(scan);

            if let Some(held) = previous {
                width += u32::from(self.printed_blank(held, scan));
            }

            previous = Some(scan);
            scan += 1;
        }

        width
    }

    fn quoted_columns(&self, position: u32) -> u32 {
        let token = self.tokens[position as usize];
        let plain = columns(self.source, token.offset, token.end());

        if let Some(span) = self.unquoting(position) {
            return columns(self.source, span.offset, span.offset + span.length);
        }

        let Some((body, quote)) = self.requoting(position) else {
            return plain;
        };

        let former = if quote == b'"' { b'\'' } else { b'"' };
        let mut held = 0;
        let mut written = 0;

        while held < body.len() {
            if body[held] != b'\\' {
                written += usize::from(body[held] == quote) + 1;
                held += 1;

                continue;
            }

            let Some(&next) = body.get(held + 1) else {
                written += 1;

                break;
            };

            written += usize::from(next != former) + 1;
            held += 2;
        }

        let moved = i64::try_from(written).unwrap_or_default()
            - i64::try_from(body.len()).unwrap_or_default();

        plain.saturating_add_signed(i32::try_from(moved).unwrap_or_default())
    }

    fn binary_inline(&self) -> bool {
        let mut depth = self.depth;

        while depth > 0 {
            let frame = self.nest[depth as usize - 1];

            if frame.kind == TokenKind::BlockStart {
                return frame.open >= self.line_first;
            }

            depth -= 1;
        }

        false
    }

    fn printed_blank(&self, previous: u32, position: u32) -> bool {
        let held = self.tokens[previous as usize];
        let token = self.tokens[position as usize];
        let before = held.text(self.source);
        let text = token.text(self.source);

        if self.is_dot(position) || self.is_dot(previous) {
            return false;
        }

        if TIGHT_AFTER.contains(&before) || is_open(held.kind) {
            return false;
        }

        if TIGHT_BEFORE.contains(&text) || is_close(token.kind) {
            return false;
        }

        if text == b":" {
            return self.ternary(position);
        }

        if text == b"?" {
            return !self.optional(position);
        }

        if matches!(
            token.kind,
            TokenKind::Punctuation(Punctuation::BracketOpen | Punctuation::ParenOpen)
        ) {
            return !self.operand_at(previous);
        }

        if before == b"<"
            || text == b">"
            || text == b"<" && self.brackets.angles_at(position + 1) > 0
        {
            return false;
        }

        if TIGHT_PRINTS
            && (self.word_is(position, self.policy.tight_from_source)
                || self.word_is(previous, self.policy.tight_from_source))
            && held.end() == token.offset
            && !self.roled(position, ROLE_SPACED)
            && !self.roled(previous, ROLE_SPACED)
        {
            return false;
        }

        true
    }
    pub(super) fn binary_broken(&self, position: u32, previous: u32) -> bool {
        if self.tokens[position as usize].length == 0 {
            return false;
        }

        let Some((head, stop)) = self.binary_owned(previous) else {
            return false;
        };

        if self.binary_parted(head, stop) {
            return false;
        }

        self.binary_wide(head, stop)
    }

    pub(super) fn binary_leveled(&self, previous: u32) -> bool {
        self.binary_owned(previous).is_some()
    }

    fn binary_owned(&self, previous: u32) -> Option<(u32, u32)> {
        if !self.policy.binary_parts || self.assign_owed() || self.binary_inline() {
            return None;
        }

        if !self.wrapping_operator(previous) {
            return None;
        }

        let (head, stop) = self.binary_run(previous)?;
        let seat = self.binary_seat(head, stop)?;

        if self.binary_inlined(stop) {
            return None;
        }

        if self.wraps_owed == 0
            && WRAPPED_WORDS.contains(&self.tokens[seat as usize].text(self.source))
        {
            return None;
        }

        self.binary_spine(head, stop, previous)
            .then_some((head, stop))
    }

    fn binary_spine(&self, head: u32, stop: u32, previous: u32) -> bool {
        let mut ranks = [(0_u32, 0_u32); BINARY_OPERATOR_MAX];

        let Some(count) = self.binary_ranked(head, stop, &mut ranks) else {
            return false;
        };

        let least = ranks[..count]
            .iter()
            .map(|(_, rank)| *rank)
            .min()
            .unwrap_or_default();

        let mut owned = false;
        let mut walk = count;

        while walk > 0 {
            walk -= 1;

            let (position, rank) = ranks[walk];

            if rank != least {
                continue;
            }

            if owned && !self.binary_flattens(position) {
                return false;
            }

            if position == previous {
                return true;
            }

            owned = true;
        }

        false
    }

    fn binary_ranked(
        &self,
        head: u32,
        stop: u32,
        ranks: &mut [(u32, u32); BINARY_OPERATOR_MAX],
    ) -> Option<usize> {
        let mut count = 0;
        let mut depth = 0_u32;
        let mut scan = head;

        while scan <= stop {
            if let Some(end) = self.template_body(scan).or_else(|| self.jsx_body(scan)) {
                scan = end + 1;

                continue;
            }

            let kind = self.tokens[scan as usize].kind;

            if is_open(kind) {
                depth += 1;
            } else if is_close(kind) {
                depth = depth.saturating_sub(1);
            } else if depth == 0
                && let Some(rank) = self.binary_rank(scan)
            {
                if count == BINARY_OPERATOR_MAX {
                    return None;
                }

                ranks[count] = (scan, rank);
                count += 1;
            }

            scan += 1;
        }

        (count > 0).then_some(count)
    }

    fn binary_soled(&self, head: u32, stop: u32) -> bool {
        let mut ranks = [(0_u32, 0_u32); BINARY_OPERATOR_MAX];

        let Some(count) = self.binary_ranked(head, stop, &mut ranks) else {
            return false;
        };

        let least = ranks[..count]
            .iter()
            .map(|(_, rank)| *rank)
            .min()
            .unwrap_or_default();

        let logical = least <= BINARY_LOGICAL_RANK;

        ranks[..count]
            .iter()
            .filter(|(_, rank)| (*rank <= BINARY_LOGICAL_RANK) == logical)
            .count()
            == 1
    }

    fn binary_flattens(&self, position: u32) -> bool {
        let text = self.tokens[position as usize].text(self.source);

        if BINARY_EQUALITIES.contains(&text) {
            return false;
        }

        !BINARY_PRODUCTS.contains(&text)
    }

    fn binary_rank(&self, position: u32) -> Option<u32> {
        if !self.wrapping_operator(position) {
            return None;
        }

        let text = self.tokens[position as usize].text(self.source);

        BINARY_RANKS
            .iter()
            .find(|(spelled, _)| *spelled == text)
            .map(|(_, rank)| *rank)
    }

    fn binary_seat(&self, head: u32, stop: u32) -> Option<u32> {
        let seat = self.back_of(head)?;
        let token = self.tokens[seat as usize];
        let text = token.text(self.source);

        if token.kind == TokenKind::Punctuation(Punctuation::Assign)
            || WRAPPED_WORDS.contains(&text)
        {
            return Some(seat);
        }

        if token.kind != TokenKind::Punctuation(Punctuation::ParenOpen) {
            return None;
        }

        let word = self.back_of(seat)?;

        if !WRAPPED_WORDS.contains(&self.tokens[word as usize].text(self.source)) {
            return None;
        }

        let close = self.closing_of(seat)?;

        if self.next_of(stop) != Some(close) {
            return None;
        }

        (self.next_of(close).is_none_or(|after| {
            self.tokens[after as usize].kind == TokenKind::Punctuation(Punctuation::Semicolon)
        }))
        .then_some(seat)
    }

    pub(super) fn binary_joined(&self, position: u32, previous: u32) -> bool {
        if !self.policy.binary_parts || !self.wrapping_operator(previous) {
            return false;
        }

        if self.parted_by(
            self.tokens[previous as usize].end(),
            self.tokens[position as usize].offset,
        ) > 0
        {
            return false;
        }

        let Some((head, stop)) = self.binary_run(previous) else {
            return false;
        };

        !self.binary_spine(head, stop, previous)
    }

    pub(super) fn binary_inlined(&self, stop: u32) -> bool {
        let kind = self.tokens[stop as usize].kind;

        if self.roled(stop, ROLE_JSX) {
            return true;
        }

        if !matches!(
            kind,
            TokenKind::BlockEnd | TokenKind::Punctuation(Punctuation::BracketClose)
        ) {
            return false;
        }

        let Some(open) = self.brackets.open_of(stop) else {
            return false;
        };

        if SUBSCRIPT_OPERANDS
            && self
                .word_before(open)
                .is_some_and(|held| self.tokens[held as usize].ends_a_value())
        {
            return false;
        }

        self.next_of(open).is_some_and(|held| held != stop)
    }

    pub(super) fn binary_assigned(&self, previous: u32) -> bool {
        let Some((head, stop)) = self.binary_assigns(previous) else {
            return false;
        };

        !self.binary_parted(head, stop)
    }

    pub(super) fn assign_level(&self, _position: u32) -> Option<u32> {
        if !ASSIGN_LEVELS || !self.policy.operand_levels || !self.continued {
            return None;
        }

        let previous = self.coded()?;

        if self.tokens[previous as usize].kind != TokenKind::Punctuation(Punctuation::Assign) {
            return None;
        }

        if self.leveled_at(previous) != Some(self.printed) {
            return None;
        }

        Some(self.printed + 1)
    }

    pub(super) fn operand_level(&self, position: u32) -> Option<u32> {
        if !OPERAND_LEVELS || !self.policy.operand_levels {
            return None;
        }

        if !OPERAND_LEADS.contains(&self.tokens[position as usize].text(self.source)) {
            return None;
        }

        let previous = self.coded()?;

        if !self.operand_at(previous) || self.attributed(previous) {
            return None;
        }

        let head = self.operand_run_head(position)?;

        if self
            .back_of(head)
            .is_some_and(|held| self.tokens[held as usize].text(self.source) == b":")
        {
            return None;
        }

        self.leveled_at(head).map(|level| level + 1)
    }

    fn chain_orphan(&self, position: u32, lead: u32) -> Option<u32> {
        if !CHAIN_ORPHANS
            || !self.policy.operand_levels
            || !self.is_dot(position)
            || self.ranges(position)
        {
            return None;
        }

        let previous = self.coded()?;

        if self.tokens[previous as usize].kind != TokenKind::BlockEnd {
            return None;
        }

        let head = self.chain_head(position);

        (head < lead).then_some(head)
    }

    pub(super) fn chain_orphaned(&self, position: u32) -> bool {
        self.chain_orphan(position, self.line_first).is_some()
    }

    pub(super) fn chain_level(&self, position: u32) -> Option<u32> {
        if let Some(head) = self.chain_orphan(position, self.line_before) {
            return self.leveled_at(head);
        }

        self.chain_nested(position)
    }

    fn chain_nested(&self, position: u32) -> Option<u32> {
        if !CHAIN_NESTS
            || !self.policy.operand_levels
            || !self.is_dot(position)
            || self.ranges(position)
        {
            return None;
        }

        let previous = self.coded()?;

        if !is_close(self.tokens[previous as usize].kind) {
            return None;
        }

        let head = self.chain_head(position);

        if head >= self.line_before
            || self.brackets.open_of(previous) != Some(head)
            || self.tokens[head as usize].kind != TokenKind::Punctuation(Punctuation::ParenOpen)
        {
            return None;
        }

        let called = self
            .back_of(head)
            .is_some_and(|held| ends_operand(self.tokens[held as usize].kind));

        if called || self.element_count(head, previous) > 1 || !self.binary_inside(head, previous) {
            return None;
        }

        self.leveled_at(head).map(|level| level + 1)
    }

    fn binary_inside(&self, open: u32, close: u32) -> bool {
        let mut depth = 0_u32;
        let mut scan = open + 1;

        while scan < close && scan < self.count {
            let kind = self.tokens[scan as usize].kind;

            if is_open(kind) || kind == TokenKind::BlockStart {
                depth += 1;
            } else if is_close(kind) || kind == TokenKind::BlockEnd {
                depth = depth.saturating_sub(1);
            } else if depth == 0 && self.binary_rank(scan).is_some() {
                return true;
            }

            scan += 1;
        }

        false
    }

    fn operand_orphan(&self, position: u32, previous: u32) -> Option<bool> {
        if !OPERAND_ORPHANS || !self.policy.operand_levels {
            return None;
        }

        if !OPERAND_LEADS.contains(&self.tokens[position as usize].text(self.source)) {
            return None;
        }

        if !self.operand_at(previous) || self.attributed(previous) {
            return None;
        }

        let head = self.operand_run_head(position)?;

        if head >= self.line_first {
            return None;
        }

        let nested = self.leveled_at(head)? + 1;
        let spread = self.header_width(self.line_first, previous)?;
        let under = self.printed * self.options.indent_width;

        Some(under + spread > nested * self.options.indent_width)
    }

    pub(super) fn arm_barred(&self, position: u32) -> Option<u32> {
        if !self.policy.arm_bars || self.tokens[position as usize].text(self.source) != b"|" {
            return None;
        }

        self.back_of(position).filter(|held| {
            let kind = self.tokens[*held as usize].kind;

            ends_operand(kind) || ARM_LETS && kind == TokenKind::BlockEnd
        })?;

        let mut depth = 0_i32;
        let mut scan = position + 1;
        let mut steps = 0_u32;

        while scan < self.count && steps < ARM_BAR_MAX {
            let token = self.tokens[scan as usize];
            let kind = token.kind;

            if is_open(kind) {
                depth += 1;
            } else if is_close(kind) || kind == TokenKind::BlockEnd {
                if depth == 0 && kind != TokenKind::Punctuation(Punctuation::ParenClose) {
                    return None;
                }

                depth -= 1;
            } else if depth <= 0 {
                let text = token.text(self.source);

                let bound = ARM_LETS
                    && kind == TokenKind::Punctuation(Punctuation::Assign)
                    && self.arm_letted(position);

                if text == b"=>" || bound {
                    return self.levels.checked_sub(depth.unsigned_abs());
                }

                if matches!(
                    kind,
                    TokenKind::Punctuation(Punctuation::Comma | Punctuation::Semicolon)
                ) {
                    return None;
                }
            }

            scan += 1;
            steps += 1;
        }

        None
    }

    fn arm_letted(&self, position: u32) -> bool {
        let mut depth = 0_u32;
        let mut scan = position;

        for _ in 0..ARM_BAR_MAX {
            let Some(held) = self.back_of(scan) else {
                return false;
            };

            let kind = self.tokens[held as usize].kind;

            if is_close(kind) || kind == TokenKind::BlockEnd {
                depth += 1;
            } else if is_open(kind) {
                if depth == 0 {
                    return false;
                }

                depth -= 1;
            } else if depth == 0 {
                if self.tokens[held as usize].text(self.source) == b"let" {
                    return true;
                }

                if kind == TokenKind::Punctuation(Punctuation::Semicolon) {
                    return false;
                }
            }

            scan = held;
        }

        false
    }

    pub(super) fn header_lined(&self, open: u32) -> Option<u32> {
        if self.tokens[open as usize].kind != TokenKind::BlockStart {
            return None;
        }

        let mut scan = open;

        for _ in 0..HEADER_SCAN_MAX {
            let held = self.back_of(scan)?;
            let kind = self.tokens[held as usize].kind;

            if is_close(kind) || kind == TokenKind::BlockEnd {
                scan = self.brackets.open_of(held)?;

                continue;
            }

            if is_open(kind) || kind == TokenKind::BlockStart {
                return None;
            }

            if self.word_is(held, self.policy.header_words) {
                return Some(held);
            }

            if kind == TokenKind::Punctuation(Punctuation::Semicolon)
                || self.word_is(held, self.policy.head_stops)
            {
                return None;
            }

            scan = held;
        }

        None
    }

    pub(super) fn linked_operand(&self, position: u32, previous: u32) -> bool {
        if !LINK_OPERANDS || !self.policy.operand_levels {
            return false;
        }

        let text = self.tokens[position as usize].text(self.source);

        if !OPERAND_LEADS.contains(&text) || text == b"as" {
            return false;
        }

        if !self.operand_at(previous) || self.attributed(previous) {
            return false;
        }

        self.is_dot(self.line_first) && self.linked_run(position)
    }

    fn linked_run(&self, position: u32) -> bool {
        let mut depth = 0_i32;
        let mut scan = self.line_first;

        while scan < position {
            let kind = self.tokens[scan as usize].kind;

            if is_open(kind) {
                depth += 1;
            } else if is_close(kind) || kind == TokenKind::BlockEnd {
                depth -= 1;

                if depth < 0 {
                    return false;
                }
            }

            scan += 1;
        }

        depth == 0
    }

    pub(super) fn operand_snuggled(&self, position: u32, previous: u32) -> bool {
        self.operand_orphan(position, previous) == Some(false)
    }

    fn operand_run_head(&self, position: u32) -> Option<u32> {
        let mut head = position;
        let mut scan = position;

        for _ in 0..OPERAND_SCAN_MAX {
            let Some(before) = self.back_of(scan) else {
                break;
            };

            if is_close(self.tokens[before as usize].kind) {
                scan = self.brackets.open_of(before)?;
                head = scan;

                continue;
            }

            if self.operand_stops(before) {
                break;
            }

            scan = before;
            head = before;
        }

        (head < position).then_some(head)
    }

    fn operand_stops(&self, position: u32) -> bool {
        let token = self.tokens[position as usize];

        if is_open(token.kind) || token.kind == TokenKind::Comment {
            return true;
        }

        if self.angle_generic(position) {
            return true;
        }

        let text = token.text(self.source);

        OPERAND_STOPS.contains(&text) || OPERAND_STOP_WORDS.contains(&text)
    }

    pub(super) fn binary_level(&self, _position: u32) -> Option<u32> {
        let held = self.coded()?;

        if self.binary_leveled(held) {
            return Some(self.printed);
        }

        self.binary_assigns(held).map(|_| self.printed + 1)
    }

    fn binary_assigns(&self, previous: u32) -> Option<(u32, u32)> {
        if !self.policy.binary_parts
            || self.tokens[previous as usize].kind != TokenKind::Punctuation(Punctuation::Assign)
            || self.assign_owed()
            || !self.inside_a_body()
            || self.binary_inline()
        {
            return None;
        }

        let (head, stop) = self.binary_valued(previous)?;

        if self.binary_inlined(stop) {
            return None;
        }

        self.binary_lined(head, stop).then_some((head, stop))
    }

    fn binary_parted(&self, head: u32, stop: u32) -> bool {
        let mut depth = 0_u32;
        let mut previous = head;
        let mut scan = head;

        while scan <= stop {
            if let Some(end) = self.template_body(scan).or_else(|| self.jsx_body(scan)) {
                previous = end;
                scan = end + 1;

                continue;
            }

            let token = self.tokens[scan as usize];

            if token.kind == TokenKind::Newline || token.length == 0 {
                scan += 1;

                continue;
            }

            if depth == 0
                && scan > head
                && self.parted_by(self.tokens[previous as usize].end(), token.offset) > 0
            {
                return true;
            }

            if is_open(token.kind) {
                depth += 1;
            } else if is_close(token.kind) {
                depth = depth.saturating_sub(1);
            }

            previous = scan;
            scan += 1;
        }

        false
    }

    fn binary_wide(&self, head: u32, stop: u32) -> bool {
        let seat = self.binary_seat(head, stop);
        let opens = if seat.is_some() {
            head
        } else {
            self.binary_origin(head)
        };

        if stop <= opens {
            return false;
        }

        let carried = seat.is_some_and(|held| {
            self.tokens[held as usize].kind == TokenKind::Punctuation(Punctuation::Assign)
        });

        let trailing = u32::from(
            carried
                && self.next_of(stop).is_some_and(|held| {
                    matches!(
                        self.tokens[held as usize].kind,
                        TokenKind::Punctuation(Punctuation::Comma | Punctuation::Semicolon)
                    )
                }),
        );

        let wrapped = self.wraps_owed > 0 && head <= self.wrapped[self.wraps_owed as usize - 1].0;
        let stepped = wrapped || seat.is_some_and(|held| held >= self.line_first);
        let levels = self.printed + u32::from(stepped);
        let room = self.options.line_width;
        let width = self.printed_columns(opens, stop) + self.chain_widened(head, stop);

        if self.binary_soled(head, stop) {
            let Some(operator) = self.binary_last(head, stop) else {
                return false;
            };

            let before = self.printed_columns(opens, operator);

            if levels * self.options.indent_width + before > room {
                return false;
            }
        }

        if !self.binary_fits(head, stop, levels) {
            return false;
        }

        levels * self.options.indent_width + width + trailing > room
    }

    fn binary_fits(&self, head: u32, stop: u32, levels: u32) -> bool {
        let mut ranks = [(0_u32, 0_u32); BINARY_OPERATOR_MAX];

        let Some(count) = self.binary_ranked(head, stop, &mut ranks) else {
            return false;
        };

        let least = ranks[..count]
            .iter()
            .map(|(_, rank)| *rank)
            .min()
            .unwrap_or_default();

        let indent = levels * self.options.indent_width;
        let room = self.options.line_width;
        let mut from = head;

        for (position, rank) in &ranks[..count] {
            if *rank != least {
                continue;
            }

            if from < *position && indent + self.printed_columns(from, *position) > room {
                return false;
            }

            let Some(next) = self.next_of(*position) else {
                return false;
            };

            from = next;
        }

        from > stop || indent + self.printed_columns(from, stop) <= room
    }

    fn binary_last(&self, head: u32, stop: u32) -> Option<u32> {
        let mut ranks = [(0_u32, 0_u32); BINARY_OPERATOR_MAX];
        let count = self.binary_ranked(head, stop, &mut ranks)?;

        Some(ranks[count - 1].0)
    }

    fn binary_lined(&self, head: u32, stop: u32) -> bool {
        let opens = self.binary_origin(head);

        if stop <= opens {
            return false;
        }

        let width = self.printed_columns(opens, stop) + self.chain_widened(head, stop);

        if !self.binary_fits(head, stop, self.printed + 1) {
            return false;
        }

        self.printed * self.options.indent_width + width + 1 > self.options.line_width
    }

    fn binary_origin(&self, head: u32) -> u32 {
        let mut opens = head;

        for _ in 0..CHAIN_SCAN_MAX {
            let Some(before) = self.back_of(opens) else {
                break;
            };

            let kind = self.tokens[before as usize].kind;

            if is_close(kind) && kind != TokenKind::BlockEnd {
                let Some(open) = self.brackets.open_of(before) else {
                    break;
                };

                opens = open;

                continue;
            }

            if is_open(kind)
                || is_close(kind)
                || kind == TokenKind::Comment
                || matches!(
                    kind,
                    TokenKind::Punctuation(
                        Punctuation::Colon | Punctuation::Comma | Punctuation::Semicolon
                    )
                )
            {
                break;
            }

            opens = before;
        }

        opens
    }

    fn binary_run(&self, position: u32) -> Option<(u32, u32)> {
        let mut head = position;
        let mut scan = position;

        for _ in 0..CHAIN_SCAN_MAX {
            let Some(before) = self.back_of(scan) else {
                break;
            };

            let kind = self.tokens[before as usize].kind;

            if is_close(kind) {
                scan = self.brackets.open_of(before)?;
                head = scan;

                continue;
            }

            if is_open(kind)
                || BINARY_STOPS.contains(&self.tokens[before as usize].text(self.source))
            {
                break;
            }

            scan = before;
            head = before;
        }

        let mut stop = position;

        scan = position;

        for _ in 0..CHAIN_SCAN_MAX {
            let Some(after) = self.next_of(scan) else {
                break;
            };

            if let Some(end) = self.template_body(after).or_else(|| self.jsx_body(after)) {
                scan = end;
                stop = end;

                continue;
            }

            let kind = self.tokens[after as usize].kind;

            if is_open(kind) {
                let close = self.closing_of(after)?;

                scan = close;
                stop = close;

                continue;
            }

            if is_close(kind)
                || BINARY_STOPS.contains(&self.tokens[after as usize].text(self.source))
            {
                break;
            }

            scan = after;
            stop = after;
        }

        (head < position && stop > position).then_some((head, stop))
    }

    fn binary_valued(&self, equals: u32) -> Option<(u32, u32)> {
        let mut depth = 0_u32;
        let mut scan = self.next_of(equals)?;

        for _ in 0..CHAIN_SCAN_MAX {
            if let Some(end) = self.template_body(scan).or_else(|| self.jsx_body(scan)) {
                scan = self.next_of(end)?;

                continue;
            }

            let token = self.tokens[scan as usize];

            if is_open(token.kind) {
                depth += 1;
            } else if is_close(token.kind) {
                if depth == 0 {
                    return None;
                }

                depth -= 1;
            } else if depth == 0 {
                if BINARY_STOPS.contains(&token.text(self.source)) {
                    return None;
                }

                if self.wrapping_operator(scan) {
                    return self.binary_run(scan);
                }
            }

            scan = self.next_of(scan)?;
        }

        None
    }
    pub(super) fn rested_run(&self, close: u32) -> bool {
        let Some(open) = self.brackets.open_of(close) else {
            return false;
        };

        let mut depth = 0_u32;
        let mut held = open;
        let mut scan = open;

        while let Some(next) = self.next_of(scan) {
            if next >= close {
                break;
            }

            scan = next;

            if let Some(end) = self.templated_unit(scan) {
                scan = end;

                continue;
            }

            let kind = self.tokens[scan as usize].kind;

            if is_open(kind) {
                depth += 1;
            } else if is_close(kind) {
                depth = depth.saturating_sub(1);
            } else if depth == 0 && kind == TokenKind::Punctuation(Punctuation::Comma) {
                held = scan;
            }
        }

        let rested = self.next_of(held).is_some_and(|found| {
            self.tokens[found as usize]
                .text(self.source)
                .starts_with(b"..")
        });

        rested && (!self.policy.rest_binds || self.bound_pattern(close))
    }

    fn bound_pattern(&self, close: u32) -> bool {
        let Some(after) = self.next_of(close) else {
            return false;
        };

        let token = self.tokens[after as usize];
        let text = token.text(self.source);

        if matches!(
            token.kind,
            TokenKind::BlockStart
                | TokenKind::Punctuation(Punctuation::Assign | Punctuation::Colon)
        ) {
            return true;
        }

        if text == b"=>" {
            return true;
        }

        if self.tokens[close as usize].kind == TokenKind::Punctuation(Punctuation::ParenClose) {
            return false;
        }

        matches!(
            token.kind,
            TokenKind::Punctuation(Punctuation::Comma | Punctuation::ParenClose)
        ) && self
            .frame_close(after)
            .is_some_and(|held| self.bound_pattern(held))
    }

    fn frame_close(&self, position: u32) -> Option<u32> {
        let mut depth = self.depth;

        while depth > 0 {
            let frame = self.nest[depth as usize - 1];

            if frame.close > position {
                return Some(frame.close);
            }

            depth -= 1;
        }

        None
    }

    pub(super) fn branched_list(&self, open: u32) -> bool {
        self.policy.rest_binds
            && self
                .back_of(open)
                .is_some_and(|held| self.tokens[held as usize].text(self.source) == b"?")
    }

    pub(super) fn property_head(&self, position: u32) -> bool {
        if !self.word_is(position, self.policy.parameter_words) {
            return false;
        }

        let mut scan = position;

        for _ in 0..ARGUMENT_HEAD_MAX {
            let Some(before) = self.back_of(scan) else {
                return true;
            };

            if matches!(
                self.tokens[before as usize].kind,
                TokenKind::Punctuation(Punctuation::ParenOpen | Punctuation::Comma)
            ) {
                return true;
            }

            if !self.word_is(before, self.policy.parameter_words)
                && self.tokens[before as usize].text(self.source) != b"@"
            {
                return false;
            }

            scan = before;
        }

        false
    }
    fn heritage_of(&self, position: u32) -> Option<Heritage> {
        let token = self.tokens[position as usize];
        let text = token.text(self.source);
        let opens = token.kind == TokenKind::BlockStart;

        if !opens && text != b"extends" && text != b"implements" {
            return None;
        }

        let mut scan = if opens {
            self.back_of(position)?
        } else {
            position
        };
        let mut depth = 0_u32;
        let mut word = None;

        for _ in 0..HERITAGE_SCAN_MAX {
            let kind = self.tokens[scan as usize].kind;

            if is_close(kind) || kind == TokenKind::BlockEnd {
                depth += 1;
            } else if is_open(kind) || kind == TokenKind::BlockStart {
                if depth == 0 {
                    return None;
                }

                depth -= 1;
            } else if depth == 0 {
                let held = self.tokens[scan as usize].text(self.source);

                if held == b"class" || held == b"interface" {
                    word = Some((scan, held == b"interface"));

                    break;
                }

                if kind == TokenKind::Punctuation(Punctuation::Semicolon) {
                    return None;
                }
            }

            scan = self.back_of(scan)?;
        }

        let (keyword, interface) = word?;
        let held = self.heritage_clauses(keyword, interface)?;

        (position == held.open
            || Some(position) == held.extends
            || Some(position) == held.implements)
            .then_some(held)
    }

    fn heritage_clauses(&self, keyword: u32, interface: bool) -> Option<Heritage> {
        let mut scan = keyword;
        let mut nested = 0_u32;
        let mut depth = 0_u32;
        let mut extends = None;
        let mut implements = None;

        for _ in 0..HERITAGE_SCAN_MAX {
            scan = self.next_of(scan)?;

            let kind = self.tokens[scan as usize].kind;
            let angled = nested > 0;

            if is_open(kind) || kind == TokenKind::BlockStart {
                if depth == 0 && kind == TokenKind::BlockStart && !angled {
                    return Some(Heritage {
                        extends,
                        head: self.heritage_head(keyword),
                        implements,
                        interface,
                        keyword,
                        open: scan,
                    });
                }

                depth += 1;
            } else if is_close(kind) || kind == TokenKind::BlockEnd {
                depth = depth.checked_sub(1)?;
            } else if depth == 0 {
                let text = self.tokens[scan as usize].text(self.source);

                if text == b"<" {
                    nested += 1;

                    continue;
                }

                if text == b">" {
                    nested = nested.saturating_sub(1);

                    continue;
                }

                if angled {
                    continue;
                }

                if text == b"extends" {
                    extends = Some(scan);
                } else if text == b"implements" {
                    implements = Some(scan);
                } else if kind == TokenKind::Punctuation(Punctuation::Semicolon) {
                    return None;
                }
            }
        }

        None
    }

    fn heritage_head(&self, keyword: u32) -> u32 {
        if let Some(head) = self.line_opened(keyword) {
            return head;
        }

        let mut head = keyword;

        for _ in 0..HERITAGE_SCAN_MAX {
            let Some(before) = self.back_of(head) else {
                break;
            };

            let kind = self.tokens[before as usize].kind;

            if is_open(kind)
                || is_close(kind)
                || kind == TokenKind::Comment
                || matches!(
                    kind,
                    TokenKind::Punctuation(
                        Punctuation::Colon | Punctuation::Comma | Punctuation::Semicolon
                    )
                )
            {
                break;
            }

            head = before;
        }

        head
    }

    pub(super) fn line_opened(&self, position: u32) -> Option<u32> {
        let mut held: Option<(u32, u32)> = None;

        for line in self.lines {
            if line.0 == 0 || line.0 - 1 > position {
                continue;
            }

            if held.is_none_or(|found| line.0 > found.0) {
                held = Some(line);
            }
        }

        held.map(|found| found.0 - 1)
    }

    fn heritage_wrapped(&self, held: &Heritage) -> u32 {
        let keyword = held.keyword;

        u32::from(
            self.word_is(keyword, self.policy.declaration_words)
                && self
                    .back_of(keyword)
                    .is_some_and(|word| self.word_is(word, self.policy.construct_words)),
        )
    }

    fn heritage_wide(&self, held: &Heritage) -> bool {
        let level = self.line_level(held.head).unwrap_or(self.levels);
        let width = self.printed_columns(held.head, held.open) + self.heritage_wrapped(held);

        level * self.options.indent_width + width > self.options.line_width
    }

    fn heritage_split(&self, position: u32) -> Option<bool> {
        if !self.policy.heritage_parts {
            return None;
        }

        let held = self.heritage_of(position)?;
        let grouped = if held.interface {
            held.extends.is_some()
        } else {
            held.implements.is_some()
        };

        if !grouped {
            return Some(false);
        }

        if position == held.open {
            let bodied = self
                .closing(held.open)
                .is_some_and(|close| self.next_of(held.open) != Some(close));

            return Some(!held.interface && bodied && self.heritage_wide(&held));
        }

        Some(self.heritage_wide(&held))
    }

    pub(super) fn angled_object(&self, open: u32) -> bool {
        if !self.policy.angle_objects || self.brackets.angles_at(open) == 0 {
            return false;
        }

        let angled = self.back_of(open).is_some_and(|held| {
            matches!(self.tokens[held as usize].text(self.source), b"<" | b",")
        });

        if !angled {
            return false;
        }

        let mut scan = open;

        for _ in 0..UNION_SCAN_MAX {
            let Some(held) = self.back_of(scan) else {
                return true;
            };

            let kind = self.tokens[held as usize].kind;

            if matches!(
                kind,
                TokenKind::BlockStart
                    | TokenKind::BlockEnd
                    | TokenKind::Comment
                    | TokenKind::Punctuation(Punctuation::Semicolon)
            ) {
                return true;
            }

            if kind == TokenKind::Punctuation(Punctuation::ParenClose) {
                return false;
            }

            scan = held;
        }

        false
    }

    pub(super) fn marked_callee(&self, position: u32) -> bool {
        if !self.word_is(position, self.policy.callee_marks) || !self.optional(position) {
            return false;
        }

        let Some(name) = self.word_before(position) else {
            return false;
        };

        if !self.named(name) {
            return false;
        }

        if self.tokens[position as usize].text(self.source) != b"?" {
            return true;
        }

        self.typed_frame()
    }

    pub(super) fn owned_break(&self, position: u32) -> bool {
        self.heritage_broken(position) || self.union_broken(position)
    }

    fn heritage_broken(&self, position: u32) -> bool {
        self.heritage_split(position) == Some(true)
    }

    pub(super) fn owned_join(&self, position: u32) -> bool {
        self.heritage_joined(position) || self.union_joined(position)
    }

    fn heritage_joined(&self, position: u32) -> bool {
        self.heritage_split(position) == Some(false)
    }

    pub(super) fn heritage_bodied(&self, position: u32) -> bool {
        if !self.policy.heritage_parts
            || self.tokens[position as usize].kind != TokenKind::BlockStart
        {
            return false;
        }

        let Some(held) = self.heritage_of(position) else {
            return false;
        };

        let grouped = if held.interface {
            held.extends.is_some()
        } else {
            held.implements.is_some()
        };

        held.open == position && grouped && self.heritage_wide(&held)
    }

    pub(super) fn heritage_level(&self, position: u32) -> Option<u32> {
        if !self.policy.heritage_parts {
            return None;
        }

        let held = self.heritage_of(position)?;

        if held.interface && held.extends.is_none() || !held.interface && held.implements.is_none()
        {
            return None;
        }

        let level = self.line_level(held.head).unwrap_or(self.levels);

        if position == held.open {
            return Some(level);
        }

        Some(level + 1)
    }
    fn union_open(&self, position: u32) -> Option<u32> {
        let mut angles = 0_u32;
        let mut depth = 0_u32;
        let mut scan = position;

        for _ in 0..UNION_SCAN_MAX {
            let held = self.back_of(scan)?;
            let kind = self.tokens[held as usize].kind;
            let text = self.tokens[held as usize].text(self.source);

            if is_close(kind) || kind == TokenKind::BlockEnd {
                depth += 1;
            } else if is_open(kind) || kind == TokenKind::BlockStart {
                if depth == 0 {
                    return None;
                }

                depth -= 1;
            } else if depth == 0 {
                if text == b">" {
                    angles += 1;
                } else if text == b"<" {
                    if angles == 0 {
                        return None;
                    }

                    angles -= 1;
                } else if angles == 0 {
                    if matches!(
                        kind,
                        TokenKind::Punctuation(Punctuation::Assign | Punctuation::Colon)
                    ) {
                        return Some(held);
                    }

                    if matches!(
                        kind,
                        TokenKind::Punctuation(Punctuation::Comma | Punctuation::Semicolon)
                    ) || text == b"=>"
                    {
                        return None;
                    }
                }
            }

            scan = held;
        }

        None
    }

    fn union_inline(&self, open: u32) -> bool {
        let head = self.line_opened(open).unwrap_or(open);
        let mut depth = self.depth;

        while depth > 0 {
            let frame = self.nest[depth as usize - 1];

            if frame.kind == TokenKind::BlockStart && frame.open < open {
                return frame.open >= head;
            }

            depth -= 1;
        }

        false
    }

    fn union_seated(&self, open: u32) -> bool {
        for depth in 0..self.depth {
            let frame = self.nest[depth as usize];

            if frame.open >= open {
                continue;
            }

            if frame.kind != TokenKind::BlockStart
                || frame.spread.is_some()
                || self.brackets.angles_at(frame.open) > 0
            {
                return false;
            }
        }

        self.back_of(open).is_none_or(|held| {
            self.tokens[held as usize].kind != TokenKind::Punctuation(Punctuation::ParenClose)
        })
    }

    fn union_typed(&self, open: u32) -> bool {
        !self.policy.type_words.is_empty()
            && (self.typing(self.union_head(open)) || self.typed_frame())
    }

    pub(super) fn union_head(&self, position: u32) -> u32 {
        let mut scan = position;

        for _ in 0..UNION_SCAN_MAX {
            let Some(held) = self.back_of(scan) else {
                break;
            };

            if matches!(
                self.tokens[held as usize].kind,
                TokenKind::BlockStart
                    | TokenKind::BlockEnd
                    | TokenKind::Comment
                    | TokenKind::Punctuation(Punctuation::Semicolon)
            ) {
                break;
            }

            scan = held;
        }

        scan
    }

    fn union_of(&self, position: u32) -> Option<Union> {
        if !self.policy.union_parts || self.assign_owed() {
            return None;
        }

        let open = self.union_open(position)?;

        if !self.union_typed(open) || !self.union_seated(open) || self.union_inline(open) {
            return None;
        }

        let first = self.coding(open)?;
        let leading = self.tokens[first as usize].text(self.source) == b"|";
        let head = if leading { self.coding(first)? } else { first };
        let (bars, braced, count, stop) = self.union_bars(head)?;

        let owned = !self.union_hugs(head, &bars, count, stop)
            && (!braced || self.union_fits(open, head, &bars, count, stop));

        owned.then_some(Union {
            bars,
            count,
            head,
            lead: leading.then_some(first),
            open,
            stop,
        })
    }

    fn union_fits(
        &self,
        open: u32,
        head: u32,
        bars: &[u32; UNION_MEMBER_MAX],
        count: u32,
        stop: u32,
    ) -> bool {
        let opens = self.line_opened(open).unwrap_or(open);
        let level = self.line_level(opens).unwrap_or(self.levels) + 1;
        let room = self
            .options
            .line_width
            .saturating_sub(level * self.options.indent_width + BAR_COLUMNS);

        let mut from = head;

        for index in 0..=count {
            let to = if index == count {
                stop
            } else {
                match self.back_of(bars[index as usize]) {
                    Some(before) => before,
                    None => return false,
                }
            };

            if from > to || self.printed_columns(from, to) > room {
                return false;
            }

            let Some(next) = self.next_of(to).and_then(|bar| self.next_of(bar)) else {
                break;
            };

            from = next;
        }

        true
    }

    fn union_bars(&self, head: u32) -> Option<([u32; UNION_MEMBER_MAX], bool, u32, u32)> {
        let mut angles = 0_u32;
        let mut bars = [0_u32; UNION_MEMBER_MAX];
        let mut braced = false;
        let mut count = 0_u32;
        let mut depth = 0_u32;
        let mut scan = head;
        let mut stop = head;

        for _ in 0..UNION_SCAN_MAX {
            let kind = self.tokens[scan as usize].kind;
            let text = self.tokens[scan as usize].text(self.source);

            if is_open(kind) || kind == TokenKind::BlockStart {
                braced |= kind == TokenKind::BlockStart;
                depth += 1;
            } else if is_close(kind) || kind == TokenKind::BlockEnd {
                if depth == 0 {
                    break;
                }

                depth -= 1;
            } else if depth == 0 {
                if text == b"<" {
                    angles += 1;
                } else if text == b">" {
                    if angles == 0 {
                        break;
                    }

                    angles -= 1;
                } else if angles == 0 {
                    if matches!(
                        kind,
                        TokenKind::Punctuation(
                            Punctuation::Comma | Punctuation::Semicolon | Punctuation::Assign
                        )
                    ) || text == b"=>"
                    {
                        break;
                    }

                    if text == b"|" {
                        if count as usize == UNION_MEMBER_MAX {
                            return None;
                        }

                        bars[count as usize] = scan;
                        count += 1;
                    }
                }
            }

            stop = scan;

            let Some(next) = self.next_of(scan) else {
                break;
            };

            scan = next;
        }

        (count > 0).then_some((bars, braced, count, stop))
    }

    fn union_hugs(&self, head: u32, bars: &[u32; UNION_MEMBER_MAX], count: u32, stop: u32) -> bool {
        let mut named = false;
        let mut voided = 0_u32;
        let mut from = head;

        for index in 0..=count {
            let to = if index == count {
                stop
            } else {
                self.back_of(bars[index as usize]).unwrap_or(stop)
            };

            let text = self.tokens[from as usize].text(self.source);

            if from == to && matches!(text, b"void" | b"null") {
                voided += 1;
            } else if self.tokens[from as usize].kind == TokenKind::BlockStart
                || self.tokens[to as usize].kind == TokenKind::Identifier
                || self.tokens[to as usize].text(self.source) == b">"
            {
                named = true;
            }

            let Some(next) = self.next_of(to).and_then(|bar| self.next_of(bar)) else {
                break;
            };

            from = next;
        }

        named && voided == count
    }

    fn union_wide(&self, held: &Union) -> bool {
        let opens = self.line_opened(held.open).unwrap_or(held.open);
        let level = self.line_level(opens).unwrap_or(self.levels);
        let trailing = self.next_of(held.stop).is_some_and(|after| {
            matches!(
                self.tokens[after as usize].kind,
                TokenKind::Punctuation(Punctuation::Comma | Punctuation::Semicolon)
            )
        });

        let width = self.printed_columns(opens, held.stop) + u32::from(trailing)
            - held.lead.map_or(0, |_| BAR_COLUMNS);

        level * self.options.indent_width + width > self.options.line_width
    }

    fn union_parted(&self, position: u32) -> Option<&'static str> {
        let held = self.union_of(position)?;
        let leads = position == held.lead.unwrap_or(held.head);

        if !leads && !held.bars[..held.count as usize].contains(&position) {
            return None;
        }

        if !self.union_wide(&held) {
            return None;
        }

        Some(if leads && held.lead.is_none() {
            "lead"
        } else {
            "bar"
        })
    }

    fn union_broken(&self, position: u32) -> bool {
        self.union_parted(position).is_some()
    }

    pub(super) fn union_joined(&self, position: u32) -> bool {
        let Some(held) = self.union_of(position) else {
            return false;
        };

        let leads = position == held.head || Some(position) == held.lead;

        if !leads && !held.bars[..held.count as usize].contains(&position) {
            return false;
        }

        !self.union_wide(&held)
    }

    pub(super) fn union_dropped(&self, position: u32) -> bool {
        let Some(held) = self.union_of(position) else {
            return false;
        };

        held.lead == Some(position) && !self.union_wide(&held)
    }

    pub(super) fn owned_assign(&self, position: u32) -> bool {
        self.binary_assigned(position)
            || self.union_assigned(position)
            || self.assign_valued(position)
    }

    fn assign_valued(&self, position: u32) -> bool {
        if !self.policy.assign_values
            || self.tokens[position as usize].kind != TokenKind::Punctuation(Punctuation::Assign)
        {
            return false;
        }

        let Some(value) = self.coding(position) else {
            return false;
        };

        let token = self.tokens[value as usize];
        let text = token.text(self.source);

        let held = token.kind == TokenKind::Number
            || matches!(text, b"class" | b"false" | b"true")
            || token.kind == TokenKind::String && text.starts_with(b"`");

        if !held {
            return false;
        }

        let close = self
            .template_body(value)
            .or_else(|| self.bodied_of(value))
            .unwrap_or(value);

        let ends = self.next_of(close).is_none_or(|after| {
            self.tokens[after as usize].kind == TokenKind::Punctuation(Punctuation::Semicolon)
        });

        ends && self.assign_narrow(position)
    }

    fn assign_narrow(&self, equals: u32) -> bool {
        let mut scan = equals;

        for _ in 0..UNION_SCAN_MAX {
            let Some(held) = self.back_of(scan) else {
                return true;
            };

            let kind = self.tokens[held as usize].kind;
            let text = self.tokens[held as usize].text(self.source);

            if matches!(
                kind,
                TokenKind::BlockStart
                    | TokenKind::BlockEnd
                    | TokenKind::Comment
                    | TokenKind::Punctuation(Punctuation::Semicolon)
            ) {
                return true;
            }

            if is_open(kind) || is_close(kind) || text == b"<" || text == b">" {
                return false;
            }

            scan = held;
        }

        false
    }

    fn union_assigned(&self, position: u32) -> bool {
        if !self.policy.union_parts
            || self.tokens[position as usize].kind != TokenKind::Punctuation(Punctuation::Assign)
        {
            return false;
        }

        let Some(next) = self.next_of(position) else {
            return false;
        };

        self.union_parted(next).is_some()
    }

    pub(super) fn union_level(&self, position: u32) -> Option<u32> {
        if !self.policy.union_parts {
            return None;
        }

        self.union_parted(position)?;

        let held = self.union_of(position)?;
        let opens = self.line_opened(held.open).unwrap_or(held.open);

        Some(self.line_level(opens).unwrap_or(self.levels) + 1)
    }

    pub(super) fn union_leads(&mut self, position: u32) -> bool {
        if !self.starting || self.union_parted(position) != Some("lead") {
            return true;
        }

        let offset = self.arena.count();

        if !self.arena.push_bytes(b"| ") {
            return false;
        }

        self.document.push(Element::Text(
            Source::Arena,
            Span {
                length: self.arena.count() - offset,
                offset,
            },
        ))
    }
}
