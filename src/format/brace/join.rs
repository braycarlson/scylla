use super::{DEFINE_SCAN_MAX, Emitter, NEST_DEPTH_MAX, TYPE_SCAN_MAX};
use crate::bounded::{Buffer, Bytes as _, Span, count_of};
use crate::format::ir::Element;
use crate::format::reach;
use crate::format::stream::{prefix_width, spilled};
use crate::format::text::spaced;
use crate::format::walk::{columns, is_close, is_open};
use crate::token::{Punctuation, TokenKind};

const ARM_TAILS: bool = true;
const GIVE_INDENTS: bool = true;
const ASSIGN_ELSES: bool = true;
const CHAIN_ANGLED: bool = true;
const ASSIGN_SOLES: bool = true;
const SOLE_RETURNS: bool = true;
const CHAIN_LAMBDAS: bool = true;
const CHAIN_LAMBDA_TRIES: bool = true;
const FLAT_TRIED: bool = true;
const FLAT_TRIES: u32 = 2;
const ASSIGN_HUGS: bool = true;
const HUG_CLOSERS: &[u8] = b");],?";
const HUG_ROOM: u32 = 2;
const HUG_TRIES: u32 = 3;
const ASSIGN_CALLEES: bool = true;
const ASSIGN_CHAINS: bool = true;
const ARM_SEATS: bool = true;
const CAST_JOINS: bool = true;
const CAST_MARGIN: u32 = 4;
const CHAIN_LASTS: bool = true;
const CHAIN_LEFTS: bool = true;
const CHAIN_TAILS: bool = true;
const CHAIN_KIDS: bool = true;
const HUG_KIDS: bool = true;
const HUG_SOLES: bool = true;
const CHAIN_BLOCKS: bool = true;
const LAMBDA_CAPS: bool = true;
const LAMBDA_TRIES: bool = true;
const LITERAL_JOINS: bool = true;
const LONE_ANGLES: bool = true;
const MARK_REMARKS: bool = true;
const ASSIGN_HEADS: bool = true;
const MIXED_FILLS: bool = true;
const MIXED_MARGIN: u32 = 2;
const MIXED_BUDGETS: bool = true;
const MIXED_REFUSED: &[&[u8]] = &[b"enum", b"fn", b"impl", b"struct", b"trait", b"union"];
const JOIN_MARGIN: u32 = 1;
const ASSIGN_ROOM: u32 = 0;
const ASSIGN_TRIES: u32 = 2;
const ARM_MARGIN: u32 = 2;
const ARM_BLOCKS: &[&[u8]] = &[b"for", b"if", b"while"];
const ARM_PLAINS: bool = true;
const ARM_JUMPS: &[&[u8]] = &[b"break", b"continue", b"return", b"yield"];

const ARM_ASSIGNS: [&[u8]; 11] = [
    b"%=",
    b"&=",
    b"*=",
    b"+=",
    b"-=",
    b"/=",
    b"<<=",
    b"=",
    b">>=",
    b"^=",
    b"|=",
];
const LAMBDA_BLOCKS: &[&[u8]] = &[b"for", b"if", b"loop", b"while"];
const LAMBDA_BRACES: u32 = 4;
const HUG_LINES: bool = true;
const HUG_PARAMS: bool = true;
const LAMBDA_ROOM: u32 = 1;
const BLOCK_CAPS: bool = true;
const BLOCK_AHEAD: bool = true;
pub(super) const HUG_NESTS: bool = true;
const HUG_NEST_MAX: u32 = 16;
const ASSIGN_MARGINS: bool = true;
const ASSIGN_ROOTS: bool = true;
const ASSIGN_ROOT_MARGIN: u32 = 1;
const ASSIGN_MARGIN: u32 = 2;
const ASSIGN_ITEMS: &[&[u8]] = &[b"const", b"pub", b"static", b"type"];
const ASSIGN_ROOT_HEADS: &[&[u8]] = &[b"const", b"let", b"pub", b"static", b"type"];
const ANGLE_JOINS: bool = true;
const ATTRIBUTE_BREAKS: bool = true;
const DERIVE_MERGES: bool = true;
const BRACE_PARTS: bool = true;
const BRACE_EXTENDS: &[u8] = b"()]}?>";
const ITEM_ANGLES: bool = true;
const ITEM_HEADS: &[&[u8]] = &[b"default", b"pub", b"unsafe"];
const DERIVE_WALK_MAX: u32 = 6;
const OPERAND_ROOMS: bool = true;

const OPERAND_JOINS: &[&[u8]] = &[
    b"!=",
    b"%",
    b"*",
    b"+",
    b"/",
    b"<<",
    b"<=",
    b"==",
    b">=",
    b">>",
    b"^",
    b"|",
    b"||",
];

const HUG_REFUSED: &[&[u8]] = &[
    b"const",
    b"enum",
    b"fn",
    b"impl",
    b"mod",
    b"static",
    b"struct",
    b"trait",
    b"type",
    b"union",
];

const HUG_BLOCKS: &[&[u8]] = &[b"async", b"do", b"gen", b"move", b"try", b"unsafe"];
const VALUE_HEADS: &[&[u8]] = &[b"else", b"if", b"loop", b"match", b"unsafe"];

const OPERAND_STOPS: &[&[u8]] = &[
    b"=>",
    b"break",
    b"continue",
    b"else",
    b"if",
    b"in",
    b"let",
    b"loop",
    b"match",
    b"return",
    b"while",
    b"yield",
];

const VALUE_BLOCKS: &[&[u8]] = &[
    b"async",
    b"const",
    b"do",
    b"gen",
    b"loop",
    b"move",
    b"try",
    b"unsafe",
];

fn respread(out: &mut Buffer, text: &[u8], width: u32, base: u32) -> bool {
    let mut least = u32::MAX;

    for line in text.split(|byte| *byte == b'\n').skip(1) {
        if !line.trim_ascii().is_empty() {
            least = least.min(prefix_width(line, width));
        }
    }

    let mut first = true;

    for line in text.split(|byte| *byte == b'\n') {
        if !first && !out.push_bytes(b"\n") {
            return false;
        }

        if first {
            first = false;

            if !out.push_bytes(line.trim_ascii_end()) {
                return false;
            }

            continue;
        }

        let body = line.trim_ascii();

        if body.is_empty() {
            continue;
        }

        let held = base + prefix_width(line, width).saturating_sub(least);

        if !spaced(out, held) || !out.push_bytes(body) {
            return false;
        }
    }

    true
}

#[expect(
    clippy::multiple_inherent_impl,
    reason = "the joining family is a child module of `brace`, whose own `impl Emitter` block \
              stands in `mod.rs`"
)]
impl Emitter<'_> {
    pub(super) fn assign_joined(&self, position: u32, previous: u32) -> bool {
        let braced =
            self.depth == 0 || self.nest[self.depth as usize - 1].kind == TokenKind::BlockStart;

        if !self.policy.assign_joins
            || self.tokens[previous as usize].kind != TokenKind::Punctuation(Punctuation::Assign)
            || !braced
        {
            return false;
        }

        let Some(head) = self.assign_first(previous) else {
            return false;
        };

        let Some(end) = self.statement_end(position) else {
            return false;
        };

        let opened = self
            .value_brace(position, end)
            .filter(|_| !self.assign_wrapped(position, previous));

        let elsed = if ASSIGN_ELSES {
            self.assign_elsed(position, end)
        } else {
            None
        };

        let parted = self
            .parted_bracket(position, end)
            .filter(|held| opened.is_none_or(|brace| *held < brace));

        let stop = parted.or(elsed).or(opened).unwrap_or(end);

        let tried = match self.hugged_tail(position, end).filter(|hug| hug.0 == stop) {
            Some((_, tries)) => HUG_ROOM + HUG_TRIES * tries,
            None if self.assign_tried(position, end) => ASSIGN_TRIES,
            None => ASSIGN_ROOM,
        };

        let room = self.options.line_width.saturating_sub(tried);

        if let Some(width) = self.joined_width(head, stop, previous) {
            if self.printed * self.options.indent_width + width <= room {
                return true;
            }
        }

        if let Some((inner, closes)) = self.sole_chain(position, end) {
            if self.chain_joined(head, previous, inner, closes) {
                return true;
            }
        }

        self.chain_joined(head, previous, position, end)
    }

    fn sole_chain(&self, position: u32, end: u32) -> Option<(u32, u32)> {
        if !ASSIGN_SOLES {
            return None;
        }

        let mut scan = position;

        for _ in 0..DEFINE_SCAN_MAX {
            let token = self.tokens[scan as usize];

            if matches!(
                token.kind,
                TokenKind::Punctuation(Punctuation::ParenOpen | Punctuation::BracketOpen)
            ) {
                break;
            }

            if !matches!(token.kind, TokenKind::Identifier | TokenKind::Keyword(_))
                && !matches!(token.text(self.source), b"::" | b"!")
            {
                return None;
            }

            scan = self.next_of(scan).filter(|held| *held < end)?;
        }

        if scan == position {
            return None;
        }

        let close = self.closing_of(scan)?;

        if self.back_of(end) != Some(close) || self.parted_items(scan, close) != 1 {
            return None;
        }

        let first = self.next_of(scan).filter(|held| *held < close)?;

        Some((first, close))
    }

    fn assign_tried(&self, position: u32, end: u32) -> bool {
        let Some(last) = self.back_of(end).filter(|held| *held > position) else {
            return false;
        };

        if self.tokens[last as usize].text(self.source) != b"?" {
            return false;
        }

        let mut depth = 0_u32;
        let mut scan = position;

        while scan < end {
            let kind = self.tokens[scan as usize].kind;

            if is_open(kind) || kind == TokenKind::BlockStart {
                depth += 1;
            } else if is_close(kind) || kind == TokenKind::BlockEnd {
                depth = depth.saturating_sub(1);
            } else if depth == 0 && self.is_dot(scan) && !self.ranges(scan) {
                return true;
            }

            scan += 1;
        }

        false
    }

    pub(super) fn capped_spans(&self, from: u32, to: u32) -> bool {
        self.capped_run(from, to, false)
    }

    fn capped_lambdas(&self, from: u32, to: u32) -> bool {
        self.capped_run(from, to, true)
    }

    fn capped_run(&self, from: u32, to: u32, lambdas: bool) -> bool {
        let mut scan = from;

        for _ in 0..DEFINE_SCAN_MAX {
            if scan >= to {
                return true;
            }

            let kind = self.tokens[scan as usize].kind;

            if scan > from && self.is_dot(scan) && !self.ranges(scan) && !self.chained_flat(scan) {
                return false;
            }

            if is_open(kind) || kind == TokenKind::BlockStart {
                let Some(close) = self.closing_of(scan) else {
                    return false;
                };

                if lambdas && kind == TokenKind::BlockStart && self.lambda_bar(scan) {
                    scan = close;

                    continue;
                }

                if LAMBDA_CAPS && kind == TokenKind::BlockStart && self.flattened(scan) {
                    scan = match self.next_of(scan) {
                        Some(held) => held,
                        None => return true,
                    };

                    continue;
                }

                if kind == TokenKind::BlockStart && !self.valued_brace(scan) {
                    return false;
                }

                let cap = if kind == TokenKind::BlockStart {
                    self.policy.literal_width
                } else {
                    self.policy.call_width
                };

                let held = self.next_of(scan).filter(|found| *found < close);
                let stop = self.back_of(close);

                let (Some(first), Some(last)) = (held, stop) else {
                    scan = close;

                    continue;
                };

                if last < first {
                    scan = close;

                    continue;
                }

                let soled = LAMBDA_CAPS
                    && kind != TokenKind::BlockStart
                    && matches!(
                        self.tokens[first as usize].text(self.source),
                        b"|" | b"move"
                    )
                    && !self.elemental_list(scan, close);

                let Some(inside) = self.flat_width(first, last) else {
                    return false;
                };

                if !soled && inside > cap {
                    return false;
                }
            }

            scan = match self.next_of(scan) {
                Some(held) => held,
                None => return true,
            };
        }

        false
    }

    fn chain_joined(&self, head: u32, previous: u32, position: u32, end: u32) -> bool {
        if self.policy.chain_width == 0 {
            return false;
        }

        let (last, links, _) = self.chain_end(position);

        let ended = self.next_of(last) == Some(end)
            || ASSIGN_CHAINS
                && self
                    .next_of(last)
                    .is_some_and(|held| self.tokens[held as usize].kind == TokenKind::BlockStart);

        if links == 0 || !ended {
            return false;
        }

        let Some(width) = self.spanned_width(position, last) else {
            return false;
        };

        let Some(parent) = self.chain_parent(position, last) else {
            return false;
        };

        let Some(lead) = self.joined_width(head, parent, previous) else {
            return false;
        };

        if self.printed * self.options.indent_width + lead > self.options.line_width {
            return false;
        }

        let under = (self.printed + 1) * self.options.indent_width + JOIN_MARGIN;
        let room = self.options.line_width.saturating_sub(under);

        let (budget, tries) = if links == 1 {
            (room, 0)
        } else {
            (
                room.min(self.policy.chain_width),
                self.chain_tries(position, last),
            )
        };

        width + tries > budget
    }

    fn chain_parent(&self, from: u32, last: u32) -> Option<u32> {
        let mut depth = 0_u32;
        let mut held = from;
        let mut scan = from;

        for _ in 0..DEFINE_SCAN_MAX {
            let kind = self.tokens[scan as usize].kind;

            if depth == 0 && scan > from && self.is_dot(scan) && !self.ranges(scan) {
                return Some(held);
            }

            if is_open(kind) {
                depth += 1;
            } else if is_close(kind) {
                depth = depth.saturating_sub(1);
            }

            if scan >= last {
                return None;
            }

            held = scan;
            scan = self.next_of(scan)?;
        }

        None
    }

    fn chained_flat(&self, position: u32) -> bool {
        if self.policy.chain_width == 0 {
            return true;
        }

        let head = self.chain_head(position);
        let (last, links, _) = self.chain_end(head);

        if links < 2 {
            return true;
        }

        self.flat_width(head, last)
            .is_some_and(|width| width + self.chain_tries(head, last) <= self.policy.chain_width)
    }

    pub(super) fn arm_opened(&self, position: u32, previous: u32) -> bool {
        let Some(held) = self.next_of(previous) else {
            return false;
        };

        let kind = self.tokens[held as usize].kind;

        if kind == TokenKind::BlockEnd {
            return reach::opened(self.source, self.tokens, held)
                .is_some_and(|open| self.lambdas(open) || self.block_flat(open));
        }

        if kind == TokenKind::BlockStart && self.next_of(held) == Some(position) {
            return matches!(
                self.tokens[previous as usize].text(self.source),
                b"=>" | b"|"
            ) && self.flattened(held);
        }

        self.tokens[previous as usize].kind == TokenKind::BlockStart
            && self.next_of(previous) == Some(position)
            && self.block_flat(previous)
    }

    pub(super) fn arm_commas(&self, position: u32) -> bool {
        self.tokens[position as usize].kind == TokenKind::BlockEnd
            && reach::opened(self.source, self.tokens, position)
                .is_some_and(|open| self.flattens(open))
            && self.next_of(position).is_none_or(|held| {
                self.tokens[held as usize].kind != TokenKind::Punctuation(Punctuation::Comma)
            })
    }

    pub(super) fn arm_dropped(&self, position: u32) -> bool {
        if !ARM_TAILS
            || !self.policy.arm_guards
            || self.tokens[position as usize].kind != TokenKind::Punctuation(Punctuation::Comma)
        {
            return false;
        }

        let Some(close) = self
            .back_of(position)
            .filter(|held| self.tokens[*held as usize].kind == TokenKind::BlockEnd)
        else {
            return false;
        };

        reach::opened(self.source, self.tokens, close)
            .is_some_and(|open| self.arm_braced(open) && !self.flattened(close))
    }

    pub(super) fn arm_tailed(&self, position: u32) -> bool {
        if !ARM_TAILS
            || !self.policy.arm_guards
            || self.tokens[position as usize].kind != TokenKind::BlockEnd
        {
            return false;
        }

        let Some(open) = reach::opened(self.source, self.tokens, position) else {
            return false;
        };

        let Some(last) = self.back_of(position).filter(|held| *held > open) else {
            return false;
        };

        let kind = self.tokens[last as usize].kind;

        if matches!(
            kind,
            TokenKind::Comment | TokenKind::Punctuation(Punctuation::Comma)
        ) {
            return false;
        }

        if kind == TokenKind::BlockEnd
            && reach::opened(self.source, self.tokens, last)
                .is_some_and(|brace| self.arm_braced(brace))
        {
            return false;
        }

        self.arm_arrow(open, last)
    }

    fn arm_braced(&self, open: u32) -> bool {
        let mut scan = open;

        for _ in 0..DEFINE_SCAN_MAX {
            let Some(held) = self.back_of(scan) else {
                return false;
            };

            if self.tokens[held as usize].kind != TokenKind::Comment {
                return self.tokens[held as usize].text(self.source) == b"=>";
            }

            scan = held;
        }

        false
    }

    fn arm_arrow(&self, open: u32, last: u32) -> bool {
        let mut scan = last;

        for _ in 0..DEFINE_SCAN_MAX {
            if scan <= open {
                return false;
            }

            let kind = self.tokens[scan as usize].kind;

            if is_close(kind) {
                scan = match self.brackets.open_of(scan) {
                    Some(found) => found,
                    None => return false,
                };
            } else if is_open(kind) {
                return false;
            } else if self.tokens[scan as usize].text(self.source) == b"=>" {
                return true;
            } else if kind == TokenKind::Punctuation(Punctuation::Semicolon) {
                return false;
            }

            scan = match self.back_of(scan) {
                Some(found) => found,
                None => return false,
            };
        }

        false
    }

    pub(super) fn arm_closed(&self) -> bool {
        let Some(previous) = self.previous else {
            return false;
        };

        self.next_of(previous)
            .is_some_and(|held| self.tokens[held as usize].kind == TokenKind::BlockEnd)
            && self
                .next_of(previous)
                .is_some_and(|held| self.flattened(held))
    }

    fn angle_open(&self, head: u32, end: u32) -> bool {
        let mut angles = 0_u32;
        let mut scan = head;

        for _ in 0..DEFINE_SCAN_MAX {
            if scan >= end {
                return angles > 0;
            }

            let text = self.tokens[scan as usize].text(self.source);

            if !text.is_empty() && text.iter().all(|byte| *byte == b'<') {
                angles += count_of(text.len());
            } else if !text.is_empty() && text.iter().all(|byte| *byte == b'>') {
                angles = angles.saturating_sub(count_of(text.len()));
            }

            scan = match self.next_of(scan) {
                Some(found) => found,
                None => return angles > 0,
            };
        }

        true
    }

    fn dot_open(&self, from: u32, to: u32) -> u32 {
        let mut depth = 0_u32;
        let mut links = 0_u32;
        let mut scan = from;

        for _ in 0..DEFINE_SCAN_MAX {
            if scan >= to {
                return links;
            }

            let kind = self.tokens[scan as usize].kind;

            if is_open(kind) {
                depth += 1;
            } else if is_close(kind) {
                depth = depth.saturating_sub(1);
            } else if depth == 0
                && (self.is_dot(scan) && !self.ranges(scan)
                    || self.tokens[scan as usize].text(self.source) == b"?")
            {
                links += 1;
            }

            scan = match self.next_of(scan) {
                Some(found) => found,
                None => return links,
            };
        }

        links
    }

    fn assign_first(&self, previous: u32) -> Option<u32> {
        let held = self.line_first;

        if held <= previous {
            return Some(held);
        }

        self.statement_head(previous)
    }

    fn block_capped(&self, open: u32, end: u32) -> bool {
        let Some(close) = self.closing(open) else {
            return false;
        };

        if self.next_of(close) != Some(end) {
            return false;
        }

        let (Some(first), Some(last)) = (
            self.next_of(open).filter(|held| *held < close),
            self.back_of(close).filter(|held| *held > open),
        ) else {
            return false;
        };

        self.simple_body(first, last)
            && self.lone_item(open, close)
            && self.capped_spans(first, last)
    }

    fn hugged_tail(&self, position: u32, end: u32) -> Option<(u32, u32)> {
        if !ASSIGN_HUGS {
            return None;
        }

        let mut scan = end;
        let mut tries = 0_u32;

        for stepped in 0..DEFINE_SCAN_MAX {
            let held = self.back_of(scan).filter(|found| *found > position)?;
            let token = self.tokens[held as usize];

            if token.kind == TokenKind::BlockEnd {
                if stepped == 0 {
                    return None;
                }

                let open = self.brackets.open_of(held).filter(|open| {
                    *open > position
                        && self.back_of(*open).is_some_and(|bar| {
                            matches!(self.tokens[bar as usize].text(self.source), b"|" | b"move")
                        })
                })?;

                return Some((open, tries));
            }

            let text = token.text(self.source);

            if !HUG_CLOSERS.contains(&text.first().copied().unwrap_or(0)) || token.length != 1 {
                return None;
            }

            tries += u32::from(text == b"?");
            scan = held;
        }

        None
    }

    fn value_brace(&self, position: u32, end: u32) -> Option<u32> {
        if self.tokens[position as usize].kind == TokenKind::BlockStart {
            return (position < end).then_some(position);
        }

        if !self.word_is(position, self.policy.header_words) {
            if !VALUE_BLOCKS.contains(&self.tokens[position as usize].text(self.source)) {
                return self.hugged_tail(position, end).map(|(open, _)| open);
            }

            return self.next_of(position).filter(|held| {
                *held < end && self.tokens[*held as usize].kind == TokenKind::BlockStart
            });
        }

        let mut depth = 0_u32;
        let mut scan = position;

        for _ in 0..DEFINE_SCAN_MAX {
            if scan >= end {
                return None;
            }

            let kind = self.tokens[scan as usize].kind;

            if kind == TokenKind::BlockStart && depth == 0 {
                let close = self.closing(scan)?;
                let after = self.next_of(close)?;

                if after == end || self.tokens[after as usize].text(self.source) == b"else" {
                    return Some(scan);
                }

                scan = close;

                continue;
            }

            if is_open(kind) {
                depth += 1;
            } else if is_close(kind) {
                depth = depth.saturating_sub(1);
            }

            scan = self.next_of(scan)?;
        }

        None
    }

    pub(super) fn assign_headed(&self, position: u32, previous: u32) -> bool {
        let braced =
            self.depth == 0 || self.nest[self.depth as usize - 1].kind == TokenKind::BlockStart;

        if !ASSIGN_HEADS
            || !self.policy.assign_wraps
            || self.tokens[previous as usize].kind != TokenKind::Punctuation(Punctuation::Assign)
            || !braced
            || self.line_first > previous
        {
            return false;
        }

        let Some(end) = self.statement_end(position) else {
            return false;
        };

        if self.value_brace(position, end).is_some() || self.angle_open(self.line_first, previous) {
            return false;
        }

        let spread = self.assign_spread(position, end);

        let Some(open) = self
            .parted_bracket(position, end)
            .or(spread)
            .filter(|held| self.assign_opens(position, *held))
        else {
            return false;
        };

        let (Some(front), Some(lead)) = (
            self.header_width(position, open),
            self.header_width(self.line_first, previous),
        ) else {
            return false;
        };

        let under = self.printed * self.options.indent_width;

        let room = if ASSIGN_MARGINS {
            self.options.line_width.saturating_sub(self.assign_margin())
        } else {
            self.options.line_width.saturating_sub(under + JOIN_MARGIN)
        };

        let seats = under + self.options.indent_width + front <= self.options.line_width;

        let calleed = ASSIGN_CALLEES
            && spread == Some(open)
            && self
                .callee_named(position, open)
                .is_some_and(|width| under + lead + 1 + width + 1 > self.options.line_width);

        (lead + front > room || calleed) && seats
    }

    fn assign_margin(&self) -> u32 {
        if self.word_is(self.line_first, ASSIGN_ITEMS) {
            return ASSIGN_MARGIN - 1;
        }

        ASSIGN_MARGIN
    }

    fn callee_named(&self, position: u32, open: u32) -> Option<u32> {
        let mut named = None;
        let mut scan = position;

        for _ in 0..DEFINE_SCAN_MAX {
            if scan >= open {
                break;
            }

            if self.tokens[scan as usize].kind == TokenKind::Identifier
                && self.brackets.angles_at(scan) == 0
            {
                named = Some(scan);
            }

            scan = self.next_of(scan)?;
        }

        self.header_width(position, named?)
    }

    fn assign_spread(&self, position: u32, end: u32) -> Option<u32> {
        let mut scan = position;

        for _ in 0..DEFINE_SCAN_MAX {
            if scan >= end {
                return None;
            }

            if is_open(self.tokens[scan as usize].kind) {
                let close = self.closing_of(scan)?;

                return self.parts_at(scan, close).then_some(scan);
            }

            scan = self.next_of(scan)?;
        }

        None
    }

    fn assign_elsed(&self, position: u32, end: u32) -> Option<u32> {
        let mut depth = 0_u32;
        let mut scan = position;

        for _ in 0..DEFINE_SCAN_MAX {
            if scan >= end {
                return None;
            }

            let kind = self.tokens[scan as usize].kind;

            if is_open(kind) {
                depth += 1;
            } else if is_close(kind) {
                depth = depth.saturating_sub(1);
            } else if depth == 0 && self.tokens[scan as usize].text(self.source) == b"else" {
                if self
                    .back_of(scan)
                    .is_some_and(|held| self.tokens[held as usize].kind == TokenKind::BlockEnd)
                {
                    return None;
                }

                return self.next_of(scan);
            }

            scan = self.next_of(scan)?;
        }

        None
    }

    fn assign_opens(&self, position: u32, open: u32) -> bool {
        let mut scan = position;

        for _ in 0..DEFINE_SCAN_MAX {
            if scan >= open {
                return scan == open;
            }

            if is_open(self.tokens[scan as usize].kind) {
                return false;
            }

            scan = match self.next_of(scan) {
                Some(found) => found,
                None => return false,
            };
        }

        false
    }

    pub(super) fn assign_wrapped(&self, position: u32, previous: u32) -> bool {
        let braced =
            self.depth == 0 || self.nest[self.depth as usize - 1].kind == TokenKind::BlockStart;

        if !self.policy.assign_wraps
            || self.tokens[previous as usize].kind != TokenKind::Punctuation(Punctuation::Assign)
            || !braced
        {
            return false;
        }

        let head = self.line_first;

        let Some(end) = self.statement_end(position) else {
            return false;
        };

        let capped = match self.value_brace(position, end) {
            Some(open) => self.block_capped(open, end),
            None => self.capped_spans(position, end),
        };

        if head > previous
            || self.angle_open(head, previous)
            || self.parted_bracket(position, end).is_some()
            || !capped
        {
            return false;
        }

        let (Some(whole), Some(width)) = (
            self.header_width(head, end),
            self.header_width(position, end),
        ) else {
            return false;
        };

        let room = self.options.line_width;
        let chained =
            self.dot_open(position, end) > 1 && (ASSIGN_CHAINS || width > self.policy.chain_width);

        !chained
            && self.printed * self.options.indent_width + whole > room
            && (self.printed + 1) * self.options.indent_width + width <= room
    }

    pub(super) fn assign_rooted(&self, position: u32, previous: u32) -> bool {
        let braced =
            self.depth == 0 || self.nest[self.depth as usize - 1].kind == TokenKind::BlockStart;

        if !ASSIGN_ROOTS
            || !self.policy.assign_wraps
            || self.tokens[previous as usize].kind != TokenKind::Punctuation(Punctuation::Assign)
            || !braced
            || self.line_first > previous
            || !self.word_is(self.line_first, ASSIGN_ROOT_HEADS)
        {
            return false;
        }

        let Some(end) = self.statement_end(position) else {
            return false;
        };

        if self.chain_dots(position, end) < 2 || self.value_brace(position, end).is_some() {
            return false;
        }

        let Some(root) = self
            .chain_rooted(position, end)
            .and_then(|held| self.back_of(held))
            .filter(|held| *held >= position)
        else {
            return false;
        };

        let (Some(front), Some(lead)) = (
            self.header_width(position, root),
            self.header_width(self.line_first, previous),
        ) else {
            return false;
        };

        let under = self.printed * self.options.indent_width;
        let width = self.options.line_width;

        under + lead + 1 + front > width.saturating_sub(ASSIGN_ROOT_MARGIN)
            && under + self.options.indent_width + front <= width
            && self.capped_spans(position, root)
    }

    fn chain_dots(&self, from: u32, end: u32) -> u32 {
        let mut depth = 0_u32;
        let mut links = 0_u32;
        let mut scan = from;

        for _ in 0..DEFINE_SCAN_MAX {
            if scan >= end {
                return links;
            }

            let kind = self.tokens[scan as usize].kind;

            if is_open(kind) {
                depth += 1;
            } else if is_close(kind) {
                depth = depth.saturating_sub(1);
            } else if depth == 0 && self.is_dot(scan) && !self.ranges(scan) {
                links += 1;
            }

            scan = match self.next_of(scan) {
                Some(found) => found,
                None => return links,
            };
        }

        links
    }

    fn chain_rooted(&self, from: u32, end: u32) -> Option<u32> {
        let mut depth = 0_u32;
        let mut scan = from;

        for _ in 0..DEFINE_SCAN_MAX {
            if scan >= end {
                return None;
            }

            let kind = self.tokens[scan as usize].kind;

            if is_open(kind) {
                depth += 1;
            } else if is_close(kind) {
                depth = depth.saturating_sub(1);
            } else if depth == 0 && self.is_dot(scan) && !self.ranges(scan) && scan > from {
                return Some(scan);
            }

            scan = self.next_of(scan)?;
        }

        None
    }

    fn arm_head(&self, arrow: u32) -> Option<u32> {
        let mut depth = 0_u32;
        let mut scan = arrow;

        for _ in 0..DEFINE_SCAN_MAX {
            let held = self.back_of(scan)?;
            let kind = self.tokens[held as usize].kind;

            if is_close(kind) {
                if depth == 0 && kind == TokenKind::BlockEnd {
                    let open = reach::opened(self.source, self.tokens, held)?;

                    if self.arm_brace(open) {
                        return Some(scan);
                    }

                    scan = open;

                    continue;
                }

                depth += 1;
            } else if is_open(kind) {
                if depth == 0 {
                    return Some(scan);
                }

                depth -= 1;
            } else if depth == 0
                && matches!(
                    kind,
                    TokenKind::Punctuation(Punctuation::Comma | Punctuation::Semicolon)
                )
            {
                return Some(scan);
            }

            scan = held;
        }

        None
    }

    fn arm_brace(&self, open: u32) -> bool {
        self.back_of(open)
            .is_some_and(|held| self.tokens[held as usize].text(self.source) == b"=>")
    }

    fn arm_guarded(&self, head: u32, arrow: u32) -> bool {
        if !self.parts_at(head, arrow) {
            return false;
        }

        let mut depth = 0_u32;
        let mut scan = head;

        for _ in 0..DEFINE_SCAN_MAX {
            if scan >= arrow {
                return false;
            }

            let kind = self.tokens[scan as usize].kind;

            if is_open(kind) {
                depth += 1;
            } else if is_close(kind) {
                depth = depth.saturating_sub(1);
            } else if depth == 0 && self.tokens[scan as usize].text(self.source) == b"if" {
                return true;
            }

            scan = match self.next_of(scan) {
                Some(found) => found,
                None => return false,
            };
        }

        true
    }

    fn arm_called(&self, last: u32) -> bool {
        if !is_close(self.tokens[last as usize].kind) {
            return false;
        }

        let Some(open) = reach::opened(self.source, self.tokens, last) else {
            return false;
        };

        self.back_of(open)
            .is_some_and(|held| self.tokens[held as usize].text(self.source) == b"!")
    }

    fn arm_seated(&self, head: u32, arrow: u32, first: u32, last: u32) -> bool {
        if !ARM_SEATS || !self.capped_spans(first, last) {
            return false;
        }

        let start = match self.line_lead(arrow) {
            Some((found, _)) if found > head => found,
            _ => head,
        };

        let (Some(pattern), Some(body)) = (
            self.header_width(start, arrow),
            self.header_width(first, last),
        ) else {
            return false;
        };

        let under = self.line_level(start).unwrap_or(self.printed) * self.options.indent_width;

        under + pattern + body + ARM_MARGIN > self.options.line_width
            && under + self.options.indent_width + body + JOIN_MARGIN <= self.options.line_width
    }

    fn arm_fits(&self, head: u32, arrow: u32, first: u32, stop: u32) -> bool {
        let start = match self.line_lead(arrow) {
            Some((found, _)) if found > head => found,
            _ => head,
        };

        let Some(pattern) = self.header_width(start, arrow) else {
            return false;
        };

        let Some(body) = self.header_width(first, stop) else {
            return false;
        };

        let level = self.line_level(start).unwrap_or(self.printed);
        let width = pattern + body + ARM_MARGIN;

        level * self.options.indent_width + width <= self.options.line_width
    }

    fn arm_chain(&self, first: u32, last: u32) -> Option<u32> {
        let mut depth = 0_u32;
        let mut scan = first;

        for _ in 0..DEFINE_SCAN_MAX {
            if scan >= last {
                return None;
            }

            let kind = self.tokens[scan as usize].kind;

            if is_open(kind) {
                depth += 1;
            } else if is_close(kind) {
                depth = depth.saturating_sub(1);
            } else if depth == 0 && self.is_dot(scan) && !self.ranges(scan) {
                return (scan > first && !self.chained_flat(scan)).then(|| scan - 1);
            }

            scan = self.next_of(scan)?;
        }

        None
    }

    fn arm_open(&self, first: u32, last: u32) -> Option<u32> {
        let mut scan = first;

        for _ in 0..DEFINE_SCAN_MAX {
            if scan >= last {
                return None;
            }

            let next = self.next_of(scan)?;

            if is_open(self.tokens[scan as usize].kind)
                && self.parts_at(scan, next)
                && self.arm_extends(scan, last)
            {
                return Some(scan);
            }

            scan = next;
        }

        None
    }

    fn arm_extends(&self, open: u32, last: u32) -> bool {
        let mut depth = 0_u32;
        let mut scan = open;

        for _ in 0..DEFINE_SCAN_MAX {
            let kind = self.tokens[scan as usize].kind;

            if is_open(kind) {
                depth += 1;
            } else if is_close(kind) {
                depth = depth.saturating_sub(1);

                if depth == 0 {
                    return self.arm_tail(scan, last);
                }
            }

            if scan >= last {
                return false;
            }

            scan = match self.next_of(scan) {
                Some(found) => found,
                None => return false,
            };
        }

        false
    }

    fn arm_tail(&self, close: u32, last: u32) -> bool {
        let mut scan = close;

        for _ in 0..DEFINE_SCAN_MAX {
            if scan >= last {
                return scan == last;
            }

            scan = match self.next_of(scan) {
                Some(found) => found,
                None => return false,
            };

            let kind = self.tokens[scan as usize].kind;

            if !is_close(kind) && self.tokens[scan as usize].text(self.source) != b"?" {
                return false;
            }
        }

        false
    }

    pub(super) fn flattened(&self, position: u32) -> bool {
        if !self.policy.arm_flattens {
            return false;
        }

        let kind = self.tokens[position as usize].kind;

        let open = if kind == TokenKind::BlockStart {
            position
        } else if kind == TokenKind::BlockEnd {
            match reach::opened(self.source, self.tokens, position) {
                Some(held) => held,
                None => return false,
            }
        } else {
            return false;
        };

        self.flattens(open) || self.lambdas(open)
    }

    fn flattens(&self, open: u32) -> bool {
        let Some(arrow) = self
            .back_of(open)
            .filter(|held| self.tokens[*held as usize].text(self.source) == b"=>")
        else {
            return false;
        };

        if self.defined_branch(open) {
            return false;
        }

        let Some(close) = self.closing(open) else {
            return false;
        };

        let (Some(first), Some(last)) = (
            self.next_of(open).filter(|held| *held < close),
            self.back_of(close).filter(|held| *held > open),
        ) else {
            return false;
        };

        let Some(head) = self.arm_head(arrow) else {
            return false;
        };

        if head >= arrow
            || self.word_is(first, ARM_BLOCKS)
            || self.arm_guarded(head, arrow)
            || self.arm_called(last)
            || !self.simple_body(first, last)
            || !self.arm_plain(first, last)
        {
            return false;
        }

        let stop = self
            .parted_bracket(first, last)
            .or_else(|| self.arm_open(first, last));

        let chained = self.arm_chain(first, last);

        let inside = match stop {
            Some(bracket) => self.arm_extends(bracket, last),
            None if chained.is_some() => true,
            None => self.capped_spans(first, last),
        };

        inside
            && !self.arm_seated(head, arrow, first, last)
            && self.arm_fits(head, arrow, first, stop.or(chained).unwrap_or(last))
    }

    fn arm_plain(&self, first: u32, last: u32) -> bool {
        if !ARM_PLAINS {
            return true;
        }

        if self.word_is(first, ARM_JUMPS) {
            return false;
        }

        let mut depth = 0_u32;
        let mut scan = first;

        for _ in 0..DEFINE_SCAN_MAX {
            let kind = self.tokens[scan as usize].kind;

            if is_open(kind) || kind == TokenKind::BlockStart {
                depth += 1;
            } else if is_close(kind) || kind == TokenKind::BlockEnd {
                depth = depth.saturating_sub(1);
            } else if depth == 0
                && ARM_ASSIGNS.contains(&self.tokens[scan as usize].text(self.source))
            {
                return false;
            }

            if scan >= last {
                return true;
            }

            scan = match self.next_of(scan) {
                Some(found) => found,
                None => return true,
            };
        }

        true
    }

    fn simple_body(&self, first: u32, last: u32) -> bool {
        if self.tokens[first as usize].text(self.source) == b"#" {
            return false;
        }

        let mut depth = 0_u32;
        let mut scan = first;

        for _ in 0..DEFINE_SCAN_MAX {
            let kind = self.tokens[scan as usize].kind;

            if kind == TokenKind::Comment {
                return false;
            }

            if depth == 0 && kind == TokenKind::Punctuation(Punctuation::Semicolon) {
                return false;
            }

            if is_open(kind) {
                depth += 1;
            } else if is_close(kind) {
                depth = depth.saturating_sub(1);
            }

            if scan >= last {
                return true;
            }

            scan = match self.next_of(scan) {
                Some(found) => found,
                None => return true,
            };
        }

        false
    }

    pub(super) fn flat_end(&self, close: u32) -> u32 {
        let mut scan = close;

        for _ in 0..DEFINE_SCAN_MAX {
            let Some(held) = self.next_of(scan) else {
                return scan;
            };

            if self.parts_at(scan, held) || LAMBDA_CAPS && self.chains_wide(held) {
                return scan;
            }

            scan = held;
        }

        scan
    }

    pub(super) fn cast_joined(&self, position: u32, previous: u32) -> bool {
        if !CAST_JOINS
            || !self.policy.cast_joins
            || self.tokens[position as usize].text(self.source) != b"as"
            || !is_close(self.tokens[previous as usize].kind)
        {
            return false;
        }

        let Some(head) = self.cast_head(previous) else {
            return false;
        };

        let Some((lead, level)) = self.line_lead(head) else {
            return false;
        };

        let start = if head > lead {
            let Some(width) = self.header_width(lead, head) else {
                return false;
            };

            let token = self.tokens[head as usize];

            level * self.options.indent_width + width
                - columns(self.source, token.offset, token.end())
        } else {
            level * self.options.indent_width
        };

        let reached = if self.line_first <= head {
            self.header_width(head, previous)
        } else {
            self.header_width(self.line_first, previous)
                .map(|width| self.printed * self.options.indent_width + width)
        };

        let Some(last) = reached else {
            return false;
        };

        let Some(typed) = self.cast_width(position) else {
            return false;
        };

        start + last + CAST_MARGIN + typed <= self.options.line_width
    }

    fn cast_head(&self, previous: u32) -> Option<u32> {
        let mut head = previous;
        let mut scan = previous;

        for _ in 0..DEFINE_SCAN_MAX {
            if is_close(self.tokens[scan as usize].kind) {
                scan = self.brackets.open_of(scan)?;
                head = scan;
            }

            let found = self.back_of(scan)?;
            let kind = self.tokens[found as usize].kind;

            if is_open(kind)
                || kind == TokenKind::BlockStart
                || matches!(
                    kind,
                    TokenKind::Punctuation(
                        Punctuation::Colon | Punctuation::Comma | Punctuation::Semicolon
                    )
                )
                || matches!(self.tokens[found as usize].text(self.source), b"=" | b"=>")
                || self.word_is(found, self.policy.head_stops)
            {
                return Some(head);
            }

            head = found;
            scan = found;
        }

        None
    }

    fn cast_width(&self, position: u32) -> Option<u32> {
        let mut end = self.flat_end(position);

        if matches!(
            self.tokens[end as usize].kind,
            TokenKind::Punctuation(Punctuation::Comma | Punctuation::Semicolon)
        ) {
            end = self.back_of(end)?;
        }

        let first = self.next_of(position).filter(|held| *held <= end)?;

        self.header_width(first, end)
    }

    pub(super) fn define_joined(&self, position: u32) -> bool {
        self.policy.define_joins
            && self.depth > 0
            && self.defined(self.nest[self.depth as usize - 1].open)
            && self.flat_joined(position)
    }

    fn define_head(&self, open: u32) -> Option<u32> {
        let mut depth = 0_u32;
        let mut scan = open;

        for _ in 0..DEFINE_SCAN_MAX {
            let held = self.back_of(scan)?;
            let kind = self.tokens[held as usize].kind;

            if is_close(kind) {
                depth += 1;
            } else if is_open(kind) {
                if depth == 0 {
                    return None;
                }

                depth -= 1;
            } else if depth == 0 && self.word_is(held, self.policy.define_words) {
                return Some(held);
            }

            scan = held;
        }

        None
    }

    fn define_end(&self, close: u32) -> Option<u32> {
        let mut depth = 0_u32;
        let mut scan = close;

        for _ in 0..DEFINE_SCAN_MAX {
            scan = self.next_of(scan)?;

            let kind = self.tokens[scan as usize].kind;

            if depth == 0
                && (matches!(
                    kind,
                    TokenKind::BlockStart | TokenKind::Punctuation(Punctuation::Semicolon)
                ) || self.word_is(scan, self.policy.clause_words))
            {
                return Some(scan);
            }

            if is_open(kind) {
                depth += 1;
            } else if is_close(kind) {
                depth = depth.saturating_sub(1);
            }
        }

        None
    }

    pub(super) fn literal_joined(&self, open: u32) -> bool {
        if !LITERAL_JOINS || open < self.line_first || !self.valued_brace(open) {
            return false;
        }

        let Some(close) = self.closing_of(open) else {
            return false;
        };

        let Some(width) = self.flat_width(self.line_first, self.flat_end(close)) else {
            return false;
        };

        self.printed * self.options.indent_width + width <= self.options.line_width
            && self.capped_spans(self.line_first, close)
    }

    pub(super) fn flat_joined(&self, position: u32) -> bool {
        if self.policy.call_width == 0 || self.depth == 0 {
            return false;
        }

        let frame = self.nest[self.depth as usize - 1];

        let listed = matches!(
            frame.kind,
            TokenKind::Punctuation(Punctuation::ParenOpen | Punctuation::BracketOpen)
        ) || LITERAL_JOINS
            && frame.kind == TokenKind::BlockStart
            && self.valued_brace(frame.open);

        let defined = self.defined(frame.open);

        if !listed || frame.open < self.line_first || defined && !self.policy.define_joins {
            return false;
        }

        let Some(close) = self.closing_of(frame.open) else {
            return false;
        };

        if position > close {
            return false;
        }

        if !defined {
            if self.returned_over(frame.open, close) {
                return false;
            }

            let stop = self.flat_end(close);

            let Some(width) = self.flat_width(self.line_first, stop) else {
                return false;
            };

            let tried = if FLAT_TRIED && self.assign_tried(self.line_first, stop) {
                FLAT_TRIES
            } else {
                0
            };

            let under = self.printed * self.options.indent_width;

            return under + width + tried <= self.options.line_width
                && self.capped_spans(self.line_first, close);
        }

        let (Some(head), Some(stop)) = (self.define_head(frame.open), self.define_end(close))
        else {
            return false;
        };

        let Some((first, level)) = self.line_lead(head) else {
            return false;
        };

        let ended = if self.word_is(stop, self.policy.clause_words) {
            match self.back_of(stop) {
                Some(found) => found,
                None => return false,
            }
        } else {
            stop
        };

        if ended > close
            && self.parted_by(
                self.tokens[close as usize].end(),
                self.tokens[ended as usize].end(),
            ) > 0
        {
            return false;
        }

        let Some(width) = self.header_width(first, ended) else {
            return false;
        };

        level * self.options.indent_width + width <= self.options.line_width
            && self.capped_spans(head, close)
    }

    fn flat_width(&self, from: u32, to: u32) -> Option<u32> {
        let first = self.tokens[from as usize];
        let mut width = columns(self.source, first.offset, first.end());
        let mut scan = from;

        for _ in 0..DEFINE_SCAN_MAX {
            if scan >= to {
                return Some(width);
            }

            let next = self.next_of(scan)?;
            let token = self.tokens[next as usize];
            let held = self.tokens[scan as usize];
            let text = token.text(self.source);

            if token.kind == TokenKind::Comment || text.contains(&b'\n') || text == b"#" {
                return None;
            }

            let comma = token.kind == TokenKind::Punctuation(Punctuation::Comma);

            let dropped = comma
                && self
                    .next_of(next)
                    .is_some_and(|found| is_close(self.tokens[found as usize].kind));

            if !dropped {
                let glued = self.welded(next, scan);

                width += u32::from(token.offset > held.end() && !glued)
                    + columns(self.source, token.offset, token.end());
            }

            scan = next;
        }

        None
    }

    fn header_brace(&self, head: u32) -> Option<u32> {
        let mut depth = 0_u32;
        let mut scan = head;

        for _ in 0..DEFINE_SCAN_MAX {
            scan = self.next_of(scan)?;

            let kind = self.tokens[scan as usize].kind;

            if is_close(kind) {
                depth = depth.checked_sub(1)?;

                continue;
            }

            if depth == 0
                && (kind == TokenKind::Punctuation(Punctuation::Semicolon)
                    || self.tokens[scan as usize].text(self.source) == b"=>")
            {
                return None;
            }

            if is_open(kind) && (kind != TokenKind::BlockStart || depth > 0) {
                depth += 1;

                continue;
            }

            if kind != TokenKind::BlockStart {
                continue;
            }

            let opened = self.back_of(scan).is_some_and(|found| {
                matches!(
                    self.tokens[found as usize].text(self.source),
                    b"async" | b"const" | b"do" | b"gen" | b"move" | b"try" | b"unsafe"
                )
            });

            if !opened && !self.valued_brace(scan) {
                return Some(scan);
            }

            scan = self.closing(scan)?;
            depth = 0;
        }

        None
    }

    fn header_head(&self, position: u32) -> Option<u32> {
        let mut depth = 0_u32;
        let mut scan = position;

        for _ in 0..DEFINE_SCAN_MAX {
            let token = self.tokens[scan as usize];

            if depth == 0 && self.word_is(scan, self.policy.header_words) && self.looping(scan) {
                return Some(scan);
            }

            if depth == 0
                && matches!(
                    token.kind,
                    TokenKind::Punctuation(Punctuation::Comma | Punctuation::Semicolon)
                )
            {
                return None;
            }

            if is_close(token.kind) || token.kind == TokenKind::BlockEnd {
                depth += 1;
            } else if is_open(token.kind) || token.kind == TokenKind::BlockStart {
                depth = depth.checked_sub(1)?;
            }

            scan = self.back_of(scan)?;
        }

        None
    }

    pub(super) fn angle_head(&self, position: u32) -> Option<u32> {
        let depth = self.brackets.angles_at(position);

        if depth == 0 {
            return None;
        }

        let mut scan = position;

        for _ in 0..DEFINE_SCAN_MAX {
            let held = self.back_of(scan)?;
            let kind = self.tokens[held as usize].kind;

            if is_close(kind) || kind == TokenKind::BlockEnd {
                scan = self.brackets.open_of(held)?;

                continue;
            }

            if self.brackets.angles_at(held) < depth {
                return self.angle_generic(held).then_some(held);
            }

            scan = held;
        }

        None
    }

    pub(super) fn angle_generic(&self, open: u32) -> bool {
        if self.tokens[open as usize].text(self.source) != b"<" {
            return false;
        }

        let Some(before) = self.back_of(open) else {
            return false;
        };

        let token = self.tokens[before as usize];
        let text = token.text(self.source);

        let named = matches!(token.kind, TokenKind::Identifier | TokenKind::Keyword(_))
            || matches!(
                token.kind,
                TokenKind::Punctuation(Punctuation::BracketClose | Punctuation::ParenClose)
            )
            || text == b"::"
            || !text.is_empty() && text.iter().all(|byte| *byte == b'>');

        named && token.end() == self.tokens[open as usize].offset
    }

    pub(super) fn angle_close(&self, open: u32) -> Option<u32> {
        let depth = self.brackets.angles_at(open);
        let mut held = open;
        let mut scan = open;

        for _ in 0..DEFINE_SCAN_MAX {
            let found = self.next_of(scan)?;
            let kind = self.tokens[found as usize].kind;

            if self.brackets.angles_at(found) <= depth {
                let text = self.tokens[held as usize].text(self.source);

                return (!text.is_empty() && text.iter().all(|byte| *byte == b'>')).then_some(held);
            }

            if is_open(kind) || kind == TokenKind::BlockStart {
                held = self.brackets.close_of(found)?;
                scan = held;

                continue;
            }

            held = found;
            scan = found;
        }

        None
    }

    fn angle_stop(&self, close: u32) -> u32 {
        let mut scan = close;

        for _ in 0..DEFINE_SCAN_MAX {
            let Some(held) = self.next_of(scan) else {
                return scan;
            };

            let token = self.tokens[held as usize];

            if token.kind == TokenKind::Comment
                || self.parted_by(self.tokens[scan as usize].end(), token.offset) > 0
            {
                return scan;
            }

            if is_open(token.kind) || token.kind == TokenKind::BlockStart {
                return held;
            }

            scan = held;
        }

        scan
    }

    pub(super) fn angle_joined(&self, position: u32) -> bool {
        if !ANGLE_JOINS || self.brackets.angles_at(position) == 0 {
            return false;
        }

        let Some(open) = self
            .angle_head(position)
            .filter(|held| *held >= self.line_first)
        else {
            return false;
        };

        let Some(close) = self.angle_close(open) else {
            return false;
        };

        let Some(width) = self.flat_width(self.line_first, self.angle_stop(close)) else {
            return false;
        };

        self.printed * self.options.indent_width + width <= self.options.line_width
            && self.capped_spans(self.line_first, close)
    }

    pub(super) fn angle_tight(&self, position: u32, previous: u32) -> bool {
        if !ANGLE_JOINS {
            return false;
        }

        let text = self.tokens[position as usize].text(self.source);
        let depth = self.brackets.angles_at(position);

        let opened = self.tokens[previous as usize].text(self.source) == b"<"
            && depth > self.brackets.angles_at(previous);

        let closed = depth > 0 && !text.is_empty() && text.iter().all(|byte| *byte == b'>');

        (opened || closed) && self.angle_joined(position)
    }

    pub(super) fn angle_dropped(&self, position: u32) -> bool {
        if !ANGLE_JOINS
            || self.tokens[position as usize].kind != TokenKind::Punctuation(Punctuation::Comma)
        {
            return false;
        }

        let Some(next) = self.next_of(position) else {
            return false;
        };

        let text = self.tokens[next as usize].text(self.source);

        !text.is_empty() && text.iter().all(|byte| *byte == b'>') && self.angle_joined(next)
    }

    pub(super) fn header_joined(&self, position: u32, previous: u32) -> bool {
        if !self.policy.header_joins {
            return false;
        }

        let Some(head) = self.header_head(previous) else {
            return false;
        };

        let Some(open) = self.header_brace(head) else {
            return false;
        };

        if position > open || self.line_first > head {
            return false;
        }

        if self.parted_bracket(head, open).is_some()
            || self.letting(head, open)
            || !self.capped_spans(self.line_first, open)
        {
            return false;
        }

        let stop = if position == open {
            open
        } else {
            match self.back_of(open) {
                Some(found) => found,
                None => return false,
            }
        };

        let Some(width) = self.header_width(self.line_first, stop) else {
            return false;
        };

        self.printed * self.options.indent_width + width <= self.options.line_width
    }

    fn lambda_chains(&self, open: u32, close: u32) -> bool {
        let named = self
            .lambda_frame(open)
            .and_then(|frame| self.back_of(frame))
            .unwrap_or(open);

        let head = self.chain_head(named);
        let (last, links, _) = self.chain_end(head);

        if links < 2 || head >= open || last <= close {
            return true;
        }

        let ahead = self.parted_by(
            self.tokens[head as usize].end(),
            self.tokens[open as usize].offset,
        );

        let behind = self.parted_by(
            self.tokens[close as usize].end(),
            self.tokens[last as usize].end(),
        );

        if ahead + behind > 0 {
            return true;
        }

        self.flat_width(head, last)
            .is_some_and(|width| width.saturating_sub(LAMBDA_BRACES) <= self.policy.chain_width)
    }

    fn lambda_tries(&self, close: u32, end: u32) -> u32 {
        let mut tries = 0_u32;
        let mut scan = close;

        for _ in 0..DEFINE_SCAN_MAX {
            let Some(held) = self.next_of(scan).filter(|found| *found <= end) else {
                return tries;
            };

            tries += u32::from(self.tokens[held as usize].text(self.source) == b"?");
            scan = held;
        }

        tries
    }

    fn lambda_frame(&self, open: u32) -> Option<u32> {
        let mut depth = 0_u32;
        let mut scan = open;

        for _ in 0..DEFINE_SCAN_MAX {
            let held = self.back_of(scan)?;
            let kind = self.tokens[held as usize].kind;

            if is_close(kind) {
                depth += 1;
            } else if is_open(kind) {
                if depth == 0 {
                    return (kind != TokenKind::BlockStart).then_some(held);
                }

                depth -= 1;
            }

            scan = held;
        }

        None
    }

    fn lambda_hugged(&self, open: u32) -> bool {
        let mut inner = true;
        let mut scan = open;

        for _ in 0..NEST_DEPTH_MAX {
            let Some(frame) = self.lambda_frame(scan) else {
                return true;
            };

            let Some(close) = self.closing_of(frame) else {
                return true;
            };

            let hugged = inner && self.lone_item(frame, close);

            if !hugged && !self.lambda_fits(frame, close) {
                return false;
            }

            inner = false;
            scan = frame;
        }

        false
    }

    fn lambda_fits(&self, open: u32, close: u32) -> bool {
        let (Some(first), Some(last)) = (
            self.next_of(open).filter(|held| *held < close),
            self.back_of(close).filter(|held| *held > open),
        ) else {
            return true;
        };

        self.flat_width(first, last)
            .is_some_and(|width| width.saturating_sub(LAMBDA_BRACES) <= self.policy.call_width)
    }

    fn coded_before(&self, position: u32) -> Option<u32> {
        let mut scan = self.back_of(position)?;

        for _ in 0..DEFINE_SCAN_MAX {
            if self.tokens[scan as usize].kind != TokenKind::Comment {
                return Some(scan);
            }

            scan = self.back_of(scan)?;
        }

        None
    }

    fn lone_item(&self, open: u32, close: u32) -> bool {
        let mut depth = 0_u32;
        let mut scan = open;

        for _ in 0..DEFINE_SCAN_MAX {
            if scan >= close {
                return true;
            }

            let kind = self.tokens[scan as usize].kind;

            if is_open(kind) {
                depth += 1;
            } else if is_close(kind) {
                depth = depth.saturating_sub(1);
            } else if depth == 1
                && kind == TokenKind::Punctuation(Punctuation::Comma)
                && (!LONE_ANGLES || self.brackets.angles_at(scan) == 0)
            {
                return false;
            }

            scan = match self.next_of(scan) {
                Some(found) => found,
                None => return true,
            };
        }

        false
    }

    fn lambda_macro(&self) -> bool {
        for level in 0..self.depth {
            let open = self.nest[level as usize].open;

            let banged = self.back_of(open).is_some_and(|held| {
                self.tokens[held as usize].kind == TokenKind::Punctuation(Punctuation::Bang)
            });

            if banged {
                return true;
            }
        }

        false
    }

    fn lambda_bar(&self, open: u32) -> bool {
        let Some(held) = self.back_of(open) else {
            return false;
        };

        let text = self.tokens[held as usize].text(self.source);

        if text == b"|" {
            return true;
        }

        if text != b"||" {
            return false;
        }

        self.back_of(held).is_none_or(|found| {
            let kind = self.tokens[found as usize].kind;

            is_open(kind)
                || matches!(
                    self.tokens[found as usize].text(self.source),
                    b"," | b"=" | b";" | b"=>" | b"move" | b"async" | b"static"
                )
        })
    }

    fn typed_body(&self, open: u32) -> bool {
        let mut arrow = false;
        let mut depth = 0_u32;
        let mut scan = open;

        for _ in 0..TYPE_SCAN_MAX {
            let Some(held) = self.back_of(scan) else {
                return false;
            };

            let kind = self.tokens[held as usize].kind;
            let text = self.tokens[held as usize].text(self.source);

            if is_close(kind) {
                depth += 1;
            } else if is_open(kind) {
                if depth == 0 {
                    return false;
                }

                depth -= 1;
            } else if depth == 0 {
                if text == b"->" {
                    arrow = true;
                } else if matches!(text, b"|" | b"||") {
                    return arrow;
                } else if matches!(text, b";" | b"=" | b"," | b"=>")
                    || kind == TokenKind::Comment
                    || self.word_is(held, self.policy.define_words)
                {
                    return false;
                }
            }

            scan = held;
        }

        false
    }

    fn block_shaped(&self, open: u32) -> bool {
        if !self.policy.block_joins || self.tokens[open as usize].kind != TokenKind::BlockStart {
            return false;
        }

        let word = self.back_of(open);

        let valued = word.is_none_or(|held| {
            let text = self.tokens[held as usize].text(self.source);

            self.tokens[held as usize].kind == TokenKind::BlockStart
                || matches!(text, b";" | b"=")
                || VALUE_BLOCKS.contains(&text)
        }) || self.typed_body(open);

        let before = if MARK_REMARKS {
            word.and_then(|held| self.coded_before(held))
        } else {
            word.and_then(|held| self.back_of(held))
        };

        let marked = before.is_some_and(|held| {
            self.tokens[held as usize].kind == TokenKind::Punctuation(Punctuation::BracketClose)
        });

        let headed = word
            .and_then(|held| self.header_head(held))
            .is_some_and(|head| self.header_brace(head) == Some(open));

        let Some(close) = self.closing(open).filter(|_| valued && !marked && !headed) else {
            return false;
        };

        let (Some(first), Some(last)) = (
            self.next_of(open).filter(|held| *held < close),
            self.back_of(close).filter(|held| *held > open),
        ) else {
            return false;
        };

        self.simple_body(first, last)
            && self.lone_item(open, close)
            && self.capped_lambdas(first, last)
            && self.parted_bracket(first, last).is_none()
    }

    fn outer_line(&self, position: u32) -> Option<(u32, u32)> {
        let mut held = position;
        let mut scan = position;

        for _ in 0..NEST_DEPTH_MAX {
            let Some(open) = self.outer_brace(scan) else {
                break;
            };

            if !self.block_shaped(open) {
                break;
            }

            held = open;
            scan = open;
        }

        self.line_lead(held)
    }

    fn outer_brace(&self, position: u32) -> Option<u32> {
        let mut depth = 0_u32;
        let mut scan = position;

        for _ in 0..DEFINE_SCAN_MAX {
            let held = self.back_of(scan)?;
            let kind = self.tokens[held as usize].kind;

            if is_close(kind) {
                depth += 1;
            } else if is_open(kind) {
                if depth == 0 {
                    return (kind == TokenKind::BlockStart).then_some(held);
                }

                depth -= 1;
            }

            scan = held;
        }

        None
    }

    fn flat_span(&self, from: u32, to: u32) -> Option<u32> {
        let width = self.header_width(from, to)?;
        let mut given = 0_u32;
        let mut scan = from;

        for _ in 0..DEFINE_SCAN_MAX {
            if scan >= to {
                return Some(width.saturating_sub(given));
            }

            if self.tokens[scan as usize].kind == TokenKind::BlockStart && self.lambda_bar(scan) {
                given += LAMBDA_BRACES;
            }

            scan = match self.next_of(scan) {
                Some(found) => found,
                None => return Some(width.saturating_sub(given)),
            };
        }

        None
    }

    fn block_chains(&self, open: u32, close: u32) -> bool {
        let Some(dot) = self
            .next_of(close)
            .filter(|held| self.is_dot(*held) && !self.ranges(*held))
        else {
            return true;
        };

        let (_, last, links) = self.chain_span(dot);

        if links < 2 || last < dot {
            return true;
        }

        self.flat_span(open, last)
            .is_some_and(|width| width <= self.policy.chain_width)
    }

    fn block_held(&self, brace: u32) -> Option<u32> {
        let close = self.closing(brace)?;
        let mut held = self.next_of(close)?;

        for _ in 0..HUG_NEST_MAX {
            if !matches!(self.tokens[held as usize].text(self.source), b"?" | b",") {
                break;
            }

            held = self.next_of(held)?;
        }

        if !matches!(
            self.tokens[held as usize].kind,
            TokenKind::Punctuation(Punctuation::ParenClose | Punctuation::BracketClose)
        ) {
            return None;
        }

        self.brackets.open_of(held)
    }

    pub(super) fn block_budgeted(&self, brace: u32) -> bool {
        if !BLOCK_CAPS || !self.policy.call_budgets {
            return false;
        }

        let Some(held) = self.block_held(brace) else {
            return false;
        };

        let Some(close) = self.closing_of(held) else {
            return false;
        };

        let emptied = self
            .closing_of(brace)
            .is_some_and(|end| self.next_of(brace) == Some(end));

        if BLOCK_AHEAD && emptied {
            return false;
        }

        let last = if BLOCK_AHEAD {
            self.listed_last(held, close).unwrap_or(held + 1)
        } else {
            held + 1
        };

        let ahead = self.flat_columns(held + 1, last);
        let budget = self.sole_budget(held).saturating_sub(ahead);

        if budget >= self.policy.call_width {
            return false;
        }

        let overflows = self.hug_block(brace) || self.lambda_bar(brace);

        (overflows || self.parted_items(held, close) == 1)
            && self.flat_columns(held + 1, close).saturating_sub(ahead) > budget
    }

    fn block_flat(&self, open: u32) -> bool {
        if !self.block_shaped(open) || self.body_clauses(open) || self.blocks_wide(open) {
            return false;
        }

        let Some(close) = self.closing(open) else {
            return false;
        };

        if self.hugged_over(open, close) {
            return false;
        }

        let Some((head, level)) = self.outer_line(open) else {
            return false;
        };

        if !self.block_chains(open, close) {
            return false;
        }

        self.flat_span(head, self.flat_end(close))
            .is_some_and(|width| {
                level * self.options.indent_width + width <= self.options.line_width
            })
    }

    fn branch_pair(&self, position: u32, previous: u32) -> Option<u32> {
        let held = self.tokens[previous as usize].kind;
        let kind = self.tokens[position as usize].kind;

        let brace = if held == TokenKind::BlockStart {
            previous
        } else if kind == TokenKind::BlockEnd {
            reach::opened(self.source, self.tokens, position)?
        } else if held == TokenKind::BlockEnd
            && self.tokens[position as usize].text(self.source) == b"else"
        {
            reach::opened(self.source, self.tokens, previous)?
        } else {
            return None;
        };

        let word = self.back_of(brace)?;

        if self.tokens[word as usize].text(self.source) != b"else" {
            return Some(brace);
        }

        let close = self.back_of(word)?;

        reach::opened(self.source, self.tokens, close)
    }

    pub(super) fn branch_inline(&self, open: u32) -> bool {
        if self.tokens[open as usize].kind != TokenKind::BlockStart {
            return false;
        }

        self.block_flat(open)
            || self.policy.branch_joins
                && self
                    .branch_pair(open, open)
                    .is_some_and(|held| self.branch_flat(held))
    }

    pub(super) fn branch_joined(&self, position: u32, previous: u32) -> bool {
        if !self.policy.branch_joins || self.policy.branch_width == 0 {
            return false;
        }

        let Some(open) = self.branch_pair(position, previous) else {
            return false;
        };

        self.branch_flat(open)
    }

    fn branch_flat(&self, open: u32) -> bool {
        let Some(head) = self.back_of(open).and_then(|held| self.header_head(held)) else {
            return false;
        };

        if !self.word_is(head, self.policy.branch_words)
            || self
                .back_of(head)
                .is_some_and(|held| self.tokens[held as usize].text(self.source) == b"else")
        {
            return false;
        }

        let (Some(close), Some(other)) = (self.closing(open), self.branch_else(open)) else {
            return false;
        };

        let Some(shut) = self.closing(other) else {
            return false;
        };

        if !self.branch_simple(open, close) || !self.branch_simple(other, shut) {
            return false;
        }

        if !self.branch_valued(head, shut) {
            return false;
        }

        let narrow = self
            .header_width(head, shut)
            .is_some_and(|width| width <= self.policy.branch_width);

        if !narrow {
            return false;
        }

        let (first, level) = self
            .line_lead(head)
            .unwrap_or((self.line_first, self.printed));

        self.header_width(first, self.flat_end(shut))
            .is_some_and(|width| {
                level * self.options.indent_width + width <= self.options.line_width
            })
    }

    fn branch_else(&self, open: u32) -> Option<u32> {
        let close = self.closing(open)?;
        let word = self.next_of(close)?;

        if self.tokens[word as usize].text(self.source) != b"else" {
            return None;
        }

        self.next_of(word)
            .filter(|held| self.tokens[*held as usize].kind == TokenKind::BlockStart)
    }

    fn branch_simple(&self, open: u32, close: u32) -> bool {
        let (Some(first), Some(last)) = (
            self.next_of(open).filter(|held| *held < close),
            self.back_of(close).filter(|held| *held > open),
        ) else {
            return false;
        };

        self.simple_body(first, last)
    }

    fn branch_valued(&self, head: u32, shut: u32) -> bool {
        let statement = self.back_of(head).is_none_or(|held| {
            matches!(
                self.tokens[held as usize].kind,
                TokenKind::BlockStart
                    | TokenKind::BlockEnd
                    | TokenKind::Punctuation(Punctuation::Semicolon)
            )
        });

        if !statement {
            return true;
        }

        let Some(end) = self
            .next_of(shut)
            .filter(|held| self.tokens[*held as usize].kind == TokenKind::BlockEnd)
        else {
            return false;
        };

        reach::opened(self.source, self.tokens, end)
            .and_then(|open| self.back_of(open))
            .is_none_or(|held| self.tokens[held as usize].text(self.source) != b"=>")
    }

    fn lambdas(&self, open: u32) -> bool {
        if !self.policy.lambda_flattens || !self.lambda_bar(open) {
            return false;
        }

        let Some(close) = self.closing(open) else {
            return false;
        };

        let (Some(first), Some(last)) = (
            self.next_of(open).filter(|held| *held < close),
            self.back_of(close).filter(|held| *held > open),
        ) else {
            return false;
        };

        if self.word_is(first, LAMBDA_BLOCKS)
            || self.lambda_macro()
            || !self.simple_body(first, last)
        {
            return false;
        }

        let (head, level) = self
            .outer_line(open)
            .unwrap_or((self.line_first, self.printed));

        let end = self.flat_end(close);

        let Some(width) = self.flat_span(head, end) else {
            return false;
        };

        let tries = if LAMBDA_TRIES {
            self.lambda_tries(close, end)
        } else {
            0
        };

        self.lambda_hugged(open)
            && self.lambda_chains(open, close)
            && self.capped_lambdas(first, last)
            && self.parted_bracket(first, last).is_none()
            && level * self.options.indent_width + width + tries <= self.options.line_width
    }

    pub(super) fn line_lead(&self, position: u32) -> Option<(u32, u32)> {
        let mut held: Option<(u32, u32)> = None;

        for line in self.lines {
            if line.0 == 0 || line.0 - 1 > position {
                continue;
            }

            if held.is_none_or(|found| line.0 > found.0) {
                held = Some(line);
            }
        }

        held.map(|found| (found.0 - 1, found.1))
    }

    fn chain_span(&self, dot: u32) -> (u32, u32, u32) {
        let mut head = dot;
        let mut depth = 0_u32;
        let mut scan = dot;

        for _ in 0..DEFINE_SCAN_MAX {
            let Some(found) = self.back_of(scan) else {
                break;
            };

            if !self.chains_over(found, &mut depth, true) {
                break;
            }

            head = found;
            scan = found;
        }

        let mut last = dot;

        depth = 0;
        scan = dot;

        for _ in 0..DEFINE_SCAN_MAX {
            let Some(found) = self.next_of(scan) else {
                break;
            };

            if !self.chains_over(found, &mut depth, false) {
                break;
            }

            last = found;
            scan = found;
        }

        (head, last, self.chain_links(head, last))
    }

    fn chain_kids(&self, head: u32, last: u32) -> u32 {
        if !CHAIN_KIDS {
            return self.chain_links(head, last);
        }

        let mut depth = 0_u32;
        let mut links = 0_u32;
        let mut scan = head;

        for _ in 0..DEFINE_SCAN_MAX {
            if scan > last {
                return links;
            }

            let kind = self.tokens[scan as usize].kind;

            if is_open(kind) {
                depth += 1;
            } else if is_close(kind) {
                depth = depth.saturating_sub(1);
            } else if depth == 0 && self.is_dot(scan) && !self.ranges(scan) {
                links += 1;
            }

            scan = match self.next_of(scan) {
                Some(found) => found,
                None => return links,
            };
        }

        links
    }

    fn chain_links(&self, head: u32, last: u32) -> u32 {
        let mut depth = 0_u32;
        let mut links = 0_u32;
        let mut scan = head;

        for _ in 0..DEFINE_SCAN_MAX {
            if scan > last {
                return links;
            }

            let kind = self.tokens[scan as usize].kind;

            if is_open(kind) {
                depth += 1;
            } else if is_close(kind) {
                depth = depth.saturating_sub(1);
            } else if depth == 0
                && (self.is_dot(scan) && !self.ranges(scan)
                    || self.tokens[scan as usize].text(self.source) == b"?")
            {
                links += 1;
            }

            scan = match self.next_of(scan) {
                Some(found) => found,
                None => return links,
            };
        }

        links
    }

    fn chains_over(&self, position: u32, depth: &mut u32, back: bool) -> bool {
        let kind = self.tokens[position as usize].kind;
        let braced =
            CHAIN_BLOCKS && back && matches!(kind, TokenKind::BlockStart | TokenKind::BlockEnd);

        let opens = if back {
            is_close(kind) || braced && kind == TokenKind::BlockEnd
        } else {
            is_open(kind)
        };

        let closes = if back {
            is_open(kind) || braced && kind == TokenKind::BlockStart
        } else {
            is_close(kind)
        };

        if *depth == 0 && !braced && matches!(kind, TokenKind::BlockStart | TokenKind::BlockEnd) {
            return false;
        }

        if opens {
            *depth += 1;

            return true;
        }

        if closes {
            if *depth == 0 {
                return false;
            }

            *depth -= 1;

            return true;
        }

        if *depth > 0 {
            return kind != TokenKind::Comment;
        }

        if kind == TokenKind::Comment {
            return false;
        }

        let text = self.tokens[position as usize].text(self.source);
        let angled = !text.is_empty()
            && (text.iter().all(|byte| *byte == b'<') || text.iter().all(|byte| *byte == b'>'));

        matches!(
            kind,
            TokenKind::Identifier | TokenKind::String | TokenKind::Number
        ) || self.is_dot(position)
            || angled
            || self.word_is(position, self.policy.operand_words)
            || matches!(text, b"::" | b"?" | b"!")
            || CHAIN_ANGLED
                && kind == TokenKind::Punctuation(Punctuation::Comma)
                && self.angle_head(position).is_some()
    }

    pub(super) fn chain_flat(&self, position: u32, previous: u32) -> bool {
        if !self.policy.chain_joins || !self.is_dot(position) || self.ranges(position) {
            return false;
        }

        let (head, last, links) = self.chain_span(position);

        let cut = self.back_of(head).is_some_and(|held| {
            matches!(
                self.tokens[held as usize].kind,
                TokenKind::Comment | TokenKind::BlockEnd
            )
        });

        if cut {
            return false;
        }

        let spelled = !self.tokens[head as usize]
            .text(self.source)
            .contains(&b'\n');

        let ended = !self.is_dot(last)
            && spelled
            && self.next_of(last).is_none_or(|held| {
                let token = self.tokens[held as usize];

                !self.is_dot(held)
                    && token.kind != TokenKind::Identifier
                    && token.kind != TokenKind::Comment
                    && token.text(self.source) != b"?"
            });

        if links == 0 || head > previous || position > last || !ended {
            return false;
        }

        let Some(chain) = self.header_width(head, last) else {
            return false;
        };

        let stop = self.flat_end(last);

        let hugged = if CHAIN_TAILS {
            self.hugged_tail(head, stop)
        } else {
            None
        };

        let capped = match hugged {
            Some((open, _)) => self.capped_spans(head, open),
            None => self.capped_spans(head, last),
        };

        if self.chain_kids(head, last) > 1 && chain > self.policy.chain_width || !capped {
            return false;
        }

        let (first, level) = self
            .line_lead(head)
            .unwrap_or((self.line_first, self.printed));

        let under = level * self.options.indent_width;

        if CHAIN_LEFTS
            && let Some(margin) = self.assign_lefted(last)
            && self
                .header_width(first, last)
                .is_some_and(|width| under + width + margin <= self.options.line_width)
        {
            return true;
        }

        if let Some((open, tries)) = hugged
            && self.header_width(first, open).is_some_and(|width| {
                under + width + HUG_ROOM + HUG_TRIES * tries <= self.options.line_width
            })
        {
            return true;
        }

        self.header_width(first, stop)
            .is_some_and(|width| under + width <= self.options.line_width)
    }

    fn assign_lefted(&self, last: u32) -> Option<u32> {
        let next = self.next_of(last)?;
        let token = self.tokens[next as usize];

        if !ARM_ASSIGNS.contains(&token.text(self.source)) {
            return None;
        }

        Some(columns(self.source, token.offset, token.end()) + 2)
    }

    pub(super) fn root_joined(&self, position: u32, previous: u32) -> bool {
        if !self.policy.root_joins || !self.is_dot(position) || self.ranges(position) {
            return false;
        }

        let (first, _) = self
            .line_lead(previous)
            .unwrap_or((self.line_first, self.printed));

        let (head, _, _) = self.chain_span(position);

        if first > previous || head < first || is_close(self.tokens[first as usize].kind) {
            return false;
        }

        self.header_width(first, previous)
            .is_some_and(|width| width <= self.options.indent_width)
    }

    pub(super) fn macro_joined(&self, position: u32) -> bool {
        if self.policy.special_macros.is_empty() || self.depth == 0 {
            return false;
        }

        let frame = self.nest[self.depth as usize - 1];

        if frame.kind != TokenKind::Punctuation(Punctuation::ParenOpen) {
            return false;
        }

        let (Some(leading), Some(close)) =
            (self.macro_leading(frame.open), self.closing_of(frame.open))
        else {
            return false;
        };

        let Some((index, items)) = self.macro_index(frame.open, close, position) else {
            return false;
        };

        if items <= leading || index == 0 || index == leading || index == leading + 1 {
            return false;
        }

        let wide = self
            .flat_run(frame.open, close)
            .is_some_and(|width| width > self.policy.call_width);

        wide && self.macro_packed(frame.open, close, leading)
    }

    fn macro_leading(&self, open: u32) -> Option<u32> {
        let bang = self.back_of(open)?;

        if self.tokens[bang as usize].text(self.source) != b"!" {
            return None;
        }

        let name = self.back_of(bang)?;

        if self
            .back_of(name)
            .is_some_and(|held| self.tokens[held as usize].text(self.source) == b"::")
        {
            return None;
        }

        let text = self.tokens[name as usize].text(self.source);

        self.policy
            .special_macros
            .iter()
            .find(|(word, _)| *word == text)
            .map(|(_, leading)| *leading)
    }

    fn macro_index(&self, open: u32, close: u32, position: u32) -> Option<(u32, u32)> {
        let mut depth = 0_u32;
        let mut index = None;
        let mut items = 1_u32;
        let mut last = open;
        let mut scan = open;

        for _ in 0..DEFINE_SCAN_MAX {
            let next = self.next_of(scan)?;

            if next >= close {
                if self.tokens[last as usize].kind == TokenKind::Punctuation(Punctuation::Comma) {
                    items -= 1;
                }

                return index.map(|held| (held, items));
            }

            let kind = self.tokens[next as usize].kind;

            if is_open(kind) {
                depth += 1;
            } else if is_close(kind) {
                depth = depth.saturating_sub(1);
            } else if depth == 0 && kind == TokenKind::Punctuation(Punctuation::Comma) {
                items += 1;
            }

            if next == position && depth == 0 {
                index = Some(items - 1);
            }

            last = next;
            scan = next;
        }

        None
    }

    fn macro_item(&self, open: u32, close: u32, index: u32) -> Option<u32> {
        let mut depth = 0_u32;
        let mut items = 0_u32;
        let mut scan = open;

        for _ in 0..DEFINE_SCAN_MAX {
            let next = self.next_of(scan)?;

            if next >= close {
                return None;
            }

            let kind = self.tokens[next as usize].kind;

            if is_open(kind) {
                depth += 1;
            } else if is_close(kind) {
                depth = depth.saturating_sub(1);
            } else if depth == 0 && kind == TokenKind::Punctuation(Punctuation::Comma) {
                items += 1;
                scan = next;

                continue;
            }

            if items == index {
                return Some(next);
            }

            scan = next;
        }

        None
    }

    fn macro_packed(&self, open: u32, close: u32, leading: u32) -> bool {
        let Some(string) = self.macro_item(open, close, leading) else {
            return false;
        };

        let after = self.macro_item(open, close, leading + 1);
        let stop = after.unwrap_or(close);
        let under = self.printed * self.options.indent_width;
        let mut scan = open;

        for _ in 0..DEFINE_SCAN_MAX {
            let Some(next) = self.next_of(scan) else {
                return false;
            };

            if next >= close {
                break;
            }

            let token = self.tokens[next as usize];

            if under + columns(self.source, token.offset, token.end()) > self.options.line_width {
                return false;
            }

            if (next < string || next >= stop) && !self.macro_plain(next) {
                return false;
            }

            scan = next;
        }

        let held = leading == 0 || self.macro_run(open, self.back_of(string));

        held && after.is_none_or(|found| {
            self.back_of(found)
                .is_some_and(|comma| self.macro_run(comma, Some(close)))
        })
    }

    fn macro_run(&self, from: u32, to: Option<u32>) -> bool {
        let (Some(first), Some(end)) = (self.next_of(from), to.and_then(|held| self.back_of(held)))
        else {
            return false;
        };

        if first > end {
            return false;
        }

        let under = self.printed * self.options.indent_width;

        self.header_width(first, end)
            .is_some_and(|width| under + width <= self.options.line_width)
    }

    fn macro_plain(&self, position: u32) -> bool {
        let token = self.tokens[position as usize];

        match token.kind {
            TokenKind::Identifier | TokenKind::Number | TokenKind::String => {
                !token.text(self.source).contains(&b'\n')
            }
            TokenKind::Punctuation(Punctuation::Dot) => self.is_dot(position),
            TokenKind::Punctuation(
                Punctuation::BracketOpen | Punctuation::BracketClose | Punctuation::Comma,
            ) => true,
            TokenKind::Punctuation(Punctuation::Ampersand | Punctuation::Star) => {
                self.macro_prefix(position)
            }
            _ => {
                let text = token.text(self.source);

                text == b"?" || matches!(text, b"!" | b"-") && self.macro_prefix(position)
            }
        }
    }

    fn macro_prefix(&self, position: u32) -> bool {
        self.back_of(position)
            .is_none_or(|held| !self.operand_at(held))
    }

    fn flat_run(&self, open: u32, close: u32) -> Option<u32> {
        let first = self.next_of(open)?;
        let end = self.back_of(close)?;

        if first > end {
            return None;
        }

        self.header_width(first, end)
    }

    pub(super) fn mixed_filled(&self, position: u32) -> Option<bool> {
        if !MIXED_FILLS || self.policy.list_mixes == 0 || self.depth == 0 {
            return None;
        }

        let frame = self.nest[self.depth as usize - 1];

        if !matches!(
            frame.kind,
            TokenKind::Punctuation(Punctuation::BracketOpen | Punctuation::ParenOpen)
        ) {
            return None;
        }

        let close = self.closing_of(frame.open)?;
        let previous = self.previous?;

        if position > close
            || self.attribute_head().is_some()
            || self.worded_head(frame.open, MIXED_REFUSED)
            || previous != frame.open
                && self.tokens[previous as usize].kind != TokenKind::Punctuation(Punctuation::Comma)
        {
            return None;
        }

        let (index, items) = self.macro_index(frame.open, close, position)?;

        if items < 2 || !self.mixed_short(frame.open, close, items) {
            return None;
        }

        let under = self.printed * self.options.indent_width;
        let flat = self.flat_run(frame.open, close)?;

        let budget = if MIXED_BUDGETS {
            self.sole_budget(frame.open)
        } else {
            self.policy.call_width
        };

        if flat <= budget && under + flat <= self.options.line_width {
            return None;
        }

        if previous == frame.open {
            return Some(true);
        }

        let end = self.mixed_end(frame.open, close, index)?;
        let width = self.header_width(position, end)? + u32::from(index + 1 < items);
        let column = under + self.header_width(self.line_first, previous)?;

        Some(column + width + MIXED_MARGIN > self.options.line_width)
    }

    pub(super) fn mixed_joined(&self, position: u32) -> bool {
        if self.policy.list_mixes == 0 || self.depth == 0 {
            return false;
        }

        let frame = self.nest[self.depth as usize - 1];

        if frame.kind != TokenKind::Punctuation(Punctuation::BracketOpen) {
            return false;
        }

        let Some(close) = self.closing_of(frame.open) else {
            return false;
        };

        if position > close {
            return false;
        }

        let Some((index, items)) = self.macro_index(frame.open, close, position) else {
            return false;
        };

        let under = self.printed * self.options.indent_width;

        let vertical = self.flat_run(frame.open, close).is_some_and(|width| {
            width > self.policy.call_width || under + width > self.options.line_width
        });

        let filled = self
            .flat_run(frame.open, close)
            .is_some_and(|width| under + width < self.options.line_width);

        index > 0 && items > 1 && vertical && filled && self.mixed_short(frame.open, close, items)
    }

    fn mixed_end(&self, open: u32, close: u32, index: u32) -> Option<u32> {
        match self.macro_item(open, close, index + 1) {
            Some(next) => self.back_of(self.back_of(next)?),
            None => self.back_of(close),
        }
    }

    fn mixed_short(&self, open: u32, close: u32, items: u32) -> bool {
        for index in 0..items.min(DEFINE_SCAN_MAX) {
            let (Some(from), Some(to)) = (
                self.macro_item(open, close, index),
                self.mixed_end(open, close, index),
            ) else {
                return false;
            };

            if from > to
                || self
                    .header_width(from, to)
                    .is_none_or(|w| w > self.policy.list_mixes)
            {
                return false;
            }

            let mut scan = from;

            for _ in 0..DEFINE_SCAN_MAX {
                if !self.macro_plain(scan) {
                    return false;
                }

                if scan >= to {
                    break;
                }

                match self.next_of(scan) {
                    Some(found) => scan = found,
                    None => return false,
                }
            }
        }

        true
    }

    fn hug_block(&self, open: u32) -> bool {
        self.back_of(open).is_none_or(|held| {
            let token = self.tokens[held as usize];

            matches!(
                token.kind,
                TokenKind::Punctuation(Punctuation::Comma | Punctuation::ParenOpen)
            ) || HUG_BLOCKS.contains(&token.text(self.source))
        })
    }

    pub(super) fn hug_joined(&self, position: u32) -> bool {
        if !self.policy.hug_lambdas || self.depth == 0 {
            return false;
        }

        let frame = self.nest[self.depth as usize - 1];

        if frame.kind != TokenKind::Punctuation(Punctuation::ParenOpen) {
            return false;
        }

        let (Some(close), Some(brace)) = (self.closing_of(frame.open), self.hug_lambda(frame.open))
        else {
            return false;
        };

        if position <= frame.open || brace > close || position > brace && position != close {
            return false;
        }

        let Some((first, level)) = self.line_lead(frame.open) else {
            return false;
        };

        let room = self.lambda_room(frame.open, brace);

        let inside = self
            .next_of(frame.open)
            .and_then(|head| self.header_width(head, brace))
            .is_some_and(|width| width <= room);

        inside
            && first <= frame.open
            && self.header_width(first, brace).is_some_and(|width| {
                level * self.options.indent_width + width < self.options.line_width
            })
    }

    pub(super) fn lambda_room(&self, open: u32, brace: u32) -> u32 {
        let width = self.policy.call_width;

        if !HUG_PARAMS {
            return width;
        }

        let Some(bar) = self.back_of(brace).filter(|held| *held > open) else {
            return width;
        };

        let text = self.tokens[bar as usize].text(self.source);

        if text == b"||" {
            return width.saturating_sub(LAMBDA_ROOM + 1);
        }

        if text != b"|" {
            return width;
        }

        let mut depth = 0_u32;
        let mut measured = false;
        let mut scan = self.back_of(bar);

        for _ in 0..DEFINE_SCAN_MAX {
            let Some(held) = scan.filter(|found| *found > open) else {
                return width;
            };

            let kind = self.tokens[held as usize].kind;

            if is_close(kind) {
                depth += 1;
            } else if is_open(kind) {
                depth = depth.saturating_sub(1);
            } else if depth == 0 {
                if self.tokens[held as usize].text(self.source) == b"|" {
                    return width.saturating_sub(u32::from(measured) * LAMBDA_ROOM);
                }

                measured |= matches!(
                    kind,
                    TokenKind::Punctuation(Punctuation::Comma | Punctuation::Colon)
                );
            }

            scan = self.back_of(held);
        }

        width
    }

    fn derive_next(&self, close: u32) -> Option<u32> {
        if !DERIVE_MERGES
            || !self.policy.attribute_ends
            || self.tokens[close as usize].kind != TokenKind::Punctuation(Punctuation::ParenClose)
        {
            return None;
        }

        let open = self.brackets.open_of(close)?;

        if self.next_of(open) == Some(close) {
            return None;
        }

        let held = self.back_of(open)?;

        if self.tokens[held as usize].text(self.source) != b"derive" {
            return None;
        }

        let bracket = self.back_of(held)?;
        let hash = self.back_of(bracket)?;

        if self.tokens[bracket as usize].kind != TokenKind::Punctuation(Punctuation::BracketOpen)
            || self.tokens[hash as usize].text(self.source) != b"#"
        {
            return None;
        }

        let shut = self.next_of(close)?;
        let mark = self.next_of(shut)?;
        let opened = self.next_of(mark)?;
        let named = self.next_of(opened)?;
        let paren = self.next_of(named)?;

        let matched = self.tokens[shut as usize].kind
            == TokenKind::Punctuation(Punctuation::BracketClose)
            && self.tokens[mark as usize].text(self.source) == b"#"
            && self.tokens[opened as usize].kind
                == TokenKind::Punctuation(Punctuation::BracketOpen)
            && self.tokens[named as usize].text(self.source) == b"derive"
            && self.tokens[paren as usize].kind == TokenKind::Punctuation(Punctuation::ParenOpen);

        if !matched
            || self
                .closing_of(paren)
                .is_some_and(|end| self.next_of(paren) == Some(end))
        {
            return None;
        }

        Some(paren)
    }

    pub(super) fn derive_dropped(&self, position: u32) -> bool {
        let mut scan = position;

        for _ in 0..DERIVE_WALK_MAX {
            if self
                .derive_next(scan)
                .is_some_and(|end| scan <= position && position <= end)
            {
                return true;
            }

            scan = match self.back_of(scan) {
                Some(held) => held,
                None => return false,
            };
        }

        false
    }

    pub(super) fn derive_added(&self, position: u32) -> bool {
        let Some(open) = self.back_of(position) else {
            return false;
        };

        let mut scan = open;

        for _ in 0..DERIVE_WALK_MAX {
            scan = match self.back_of(scan) {
                Some(held) => held,
                None => return false,
            };

            if self.derive_next(scan) == Some(open) {
                return true;
            }
        }

        false
    }

    fn hug_nested(&self, outer: u32) -> Option<(u32, u32)> {
        let mut close = self.closing_of(outer)?;
        let mut head = outer;

        if !HUG_NESTS {
            return Some((head, close));
        }

        for _ in 0..HUG_NEST_MAX {
            let mut last = self.back_of(close)?;

            for _ in 0..HUG_NEST_MAX {
                if !matches!(self.tokens[last as usize].text(self.source), b"?" | b",") {
                    break;
                }

                last = self.back_of(last)?;
            }

            if last <= head
                || self.tokens[last as usize].kind == TokenKind::BlockEnd
                || !is_close(self.tokens[last as usize].kind)
            {
                return Some((head, close));
            }

            let Some(inner) = self.brackets.open_of(last).filter(|found| *found > head) else {
                return Some((head, close));
            };

            if self.parted_items(head, close) != 1
                || !self.hug_direct(head, inner)
                || self.flat_columns(head + 1, close) <= self.policy.call_width
            {
                return Some((head, close));
            }

            close = last;
            head = inner;
        }

        Some((head, close))
    }

    fn hug_lambda(&self, outer: u32) -> Option<u32> {
        let (open, close) = self.hug_nested(outer)?;
        let mut held = self.back_of(close)?;

        if self.tokens[held as usize].kind == TokenKind::Punctuation(Punctuation::Comma) {
            held = self.back_of(held)?;
        }

        for _ in 0..HUG_NEST_MAX {
            if !HUG_NESTS || self.tokens[held as usize].text(self.source) != b"?" {
                break;
            }

            held = self.back_of(held)?;
        }

        if self.tokens[held as usize].kind != TokenKind::BlockEnd {
            return None;
        }

        let mut depth = 0_u32;
        let mut scan = held;

        for _ in 0..DEFINE_SCAN_MAX {
            let found = self.back_of(scan)?;

            if found <= open {
                return None;
            }

            let kind = self.tokens[found as usize].kind;

            if is_close(kind) {
                depth += 1;
            } else if is_open(kind) {
                if depth == 0 {
                    if kind != TokenKind::BlockStart {
                        return None;
                    }

                    let blocked = self.lambda_bar(found) || self.hug_block(found);
                    let items = self.parted_items(open, close);

                    let plain = items > 0
                        && self.macro_item(open, close, items - 1).is_some_and(|head| {
                            let text = self.tokens[head as usize].text(self.source);

                            text != b"#" && !HUG_REFUSED.contains(&text)
                        });

                    return (plain && (blocked || items == 1)).then_some(found);
                }

                depth -= 1;
            }

            scan = found;
        }

        None
    }

    pub(super) fn operand_joined(&self, position: u32, previous: u32) -> bool {
        if !self.policy.operand_joins || !self.logical(position) || !self.operand_at(previous) {
            return false;
        }

        if self.attributed(previous) {
            return false;
        }

        let (Some(head), Some(end)) = (self.operand_head(position), self.operand_end(position))
        else {
            return false;
        };

        let Some((first, level)) = self.line_lead(head) else {
            return false;
        };

        let owed = u32::from(!OPERAND_ROOMS || self.operand_owed(end));

        first <= head
            && !self.operand_letting(first, end)
            && self.capped_spans(first, end)
            && self.header_width(first, end).is_some_and(|width| {
                level * self.options.indent_width + width + owed <= self.options.line_width
            })
    }

    fn operand_owed(&self, end: u32) -> bool {
        self.next_of(end)
            .is_none_or(|held| self.tokens[held as usize].kind != TokenKind::BlockEnd)
    }

    fn operand_letting(&self, from: u32, to: u32) -> bool {
        if self.tokens[from as usize].text(self.source) == b"let" {
            return false;
        }

        let mut scan = from;

        for _ in 0..DEFINE_SCAN_MAX {
            if self.tokens[scan as usize].text(self.source) == b"let" {
                return true;
            }

            if scan >= to {
                return false;
            }

            match self.next_of(scan) {
                Some(held) => scan = held,
                None => return true,
            }
        }

        true
    }

    fn operand_head(&self, position: u32) -> Option<u32> {
        let mut depth = 0_u32;
        let mut first = position;
        let mut scan = position;

        for _ in 0..DEFINE_SCAN_MAX {
            let held = self.back_of(scan)?;
            let token = self.tokens[held as usize];

            if depth == 0 && token.kind == TokenKind::BlockEnd {
                return Some(first);
            }

            if is_close(token.kind) {
                depth += 1;
            } else if is_open(token.kind) {
                if depth == 0 {
                    return Some(first);
                }

                depth -= 1;
            } else if depth == 0
                && (token.kind == TokenKind::Comment || token.text(self.source) == b">")
            {
                return None;
            } else if depth == 0
                && (matches!(
                    token.kind,
                    TokenKind::Punctuation(
                        Punctuation::Assign | Punctuation::Comma | Punctuation::Semicolon
                    )
                ) || OPERAND_STOPS.contains(&token.text(self.source))
                    || token.text(self.source) == b"|" && !self.operand_bar(held))
            {
                return Some(first);
            }

            first = held;
            scan = held;
        }

        None
    }

    fn operand_bar(&self, position: u32) -> bool {
        self.back_of(position)
            .is_some_and(|held| self.operand_at(held))
    }

    fn logical(&self, position: u32) -> bool {
        let token = self.tokens[position as usize];

        if OPERAND_JOINS.contains(&token.text(self.source)) {
            return true;
        }

        token.text(self.source) == b"&"
            && self.next_of(position).is_some_and(|held| {
                let next = self.tokens[held as usize];

                next.text(self.source) == b"&" && next.offset == token.end()
            })
    }

    fn operand_end(&self, position: u32) -> Option<u32> {
        let mut depth = 0_u32;
        let mut last = position;
        let mut scan = position;
        let mut valued = false;

        for _ in 0..DEFINE_SCAN_MAX {
            let next = self.next_of(scan)?;
            let kind = self.tokens[next as usize].kind;

            if depth == 0 && kind == TokenKind::BlockStart && !valued {
                return Some(last);
            }

            valued |= VALUE_HEADS.contains(&self.tokens[next as usize].text(self.source));

            if is_open(kind) {
                depth += 1;
            } else if is_close(kind) {
                if depth == 0 {
                    return Some(last);
                }

                depth -= 1;
            } else if depth == 0
                && matches!(
                    kind,
                    TokenKind::Punctuation(Punctuation::Comma | Punctuation::Semicolon)
                )
            {
                return Some(last);
            } else if depth == 0 && matches!(self.tokens[next as usize].text(self.source), b"<") {
                return None;
            }

            last = next;
            scan = next;
        }

        None
    }

    pub(super) fn chain_hugged(&self, position: u32) -> bool {
        if !self.policy.chain_hugs || !self.is_dot(position) || self.ranges(position) {
            return false;
        }

        if self.depth > 0 && self.armed_frame(self.nest[self.depth as usize - 1].open) {
            return false;
        }

        let (head, last, links) = self.chain_span(position);
        let (Some(tail), Some(before)) = (
            self.chain_tail(head, last),
            self.chain_tail(head, last)
                .and_then(|held| self.back_of(held)),
        ) else {
            return false;
        };

        if links == 0 || head > position || position > tail || head > before {
            return false;
        }

        let Some(open) = self.chain_call(tail, last) else {
            return false;
        };

        let kids = if HUG_KIDS {
            self.chain_kids(head, last)
        } else {
            links
        };

        let Some((first, level)) = self.line_lead(head) else {
            return false;
        };

        let under = level * self.options.indent_width;

        let Some(almost) = self.header_width(head, before) else {
            return false;
        };

        let widened = almost
            + if CHAIN_LAMBDA_TRIES {
                self.chain_tries(head, last)
            } else {
                0
            };

        let hugged = self.chain_shown(open, kids, tail, last, under);
        let stop = hugged.unwrap_or(open);

        let Some(shown) = self.header_width(tail, stop) else {
            return false;
        };

        if widened >= self.policy.chain_width || shown > self.policy.chain_width - widened {
            return false;
        }

        if CHAIN_LASTS && hugged.is_none() && self.chain_lasted(open, tail, last, under) {
            return false;
        }

        let parted = hugged.is_some()
            || self.closing_of(open).is_some_and(|close| {
                self.flat_run(open, close)
                    .is_some_and(|args| args > self.policy.call_width)
                    && self.hug_lambda(open).is_none()
                    && self.parted_items(open, close) > 1
            });

        parted
            && first <= head
            && self
                .header_width(first, stop)
                .is_some_and(|width| under + width <= self.options.line_width)
    }

    fn armed_frame(&self, open: u32) -> bool {
        self.tokens[open as usize].kind == TokenKind::BlockStart
            && self
                .back_of(open)
                .is_some_and(|held| self.tokens[held as usize].text(self.source) == b"=>")
    }

    fn parted_items(&self, open: u32, close: u32) -> u32 {
        let mut depth = 0_u32;
        let mut items = 1_u32;
        let mut last = open;
        let mut scan = open;

        for _ in 0..DEFINE_SCAN_MAX {
            let Some(next) = self.next_of(scan) else {
                return 0;
            };

            if next >= close {
                let ended =
                    self.tokens[last as usize].kind == TokenKind::Punctuation(Punctuation::Comma);

                return items - u32::from(ended);
            }

            let kind = self.tokens[next as usize].kind;

            if is_open(kind) {
                depth += 1;
            } else if is_close(kind) {
                depth = depth.saturating_sub(1);
            } else if depth == 0 && kind == TokenKind::Punctuation(Punctuation::Comma) {
                items += 1;
            }

            last = next;
            scan = next;
        }

        0
    }

    fn hugged_brace(&self, open: u32, close: u32) -> Option<u32> {
        let mut held = self.back_of(close)?;

        if self.tokens[held as usize].kind == TokenKind::Punctuation(Punctuation::Comma) {
            held = self.back_of(held)?;
        }

        (self.tokens[held as usize].kind == TokenKind::BlockEnd && held > open).then_some(held)
    }

    fn chain_tail(&self, head: u32, last: u32) -> Option<u32> {
        let mut depth = 0_u32;
        let mut found = None;
        let mut scan = head;

        for _ in 0..DEFINE_SCAN_MAX {
            if scan > last {
                return found;
            }

            let kind = self.tokens[scan as usize].kind;

            if is_open(kind) {
                depth += 1;
            } else if is_close(kind) {
                depth = depth.saturating_sub(1);
            } else if depth == 0 && self.is_dot(scan) && !self.ranges(scan) {
                found = Some(scan);
            }

            scan = self.next_of(scan)?;
        }

        found
    }

    fn chain_lasted(&self, open: u32, tail: u32, last: u32, under: u32) -> bool {
        let Some(close) = self.closing_of(open) else {
            return false;
        };

        let Some(first) = self.next_of(open).filter(|held| *held < close) else {
            return false;
        };

        let Some(held) = self.back_of(close).filter(|found| *found >= first) else {
            return false;
        };

        if !matches!(
            self.tokens[first as usize].text(self.source),
            b"|" | b"move"
        ) || !self.capped_spans(first, held)
        {
            return false;
        }

        self.header_width(tail, last).is_some_and(|width| {
            under + self.options.indent_width + width <= self.options.line_width
        })
    }

    fn chain_shown(&self, open: u32, links: u32, tail: u32, last: u32, under: u32) -> Option<u32> {
        let Some(brace) = self.hug_lambda(open) else {
            return self.chain_soled(open, links);
        };

        let barred = CHAIN_LAMBDAS
            && self.lambda_bar(brace)
            && self
                .closing_of(open)
                .and_then(|close| self.next_of(close))
                .is_none_or(|next| !self.is_dot(next) || self.ranges(next))
            && !self.chain_flattens(tail, last, under);

        if !self.valued_brace(brace) && !barred {
            return None;
        }

        let close = self.closing_of(brace)?;
        let head = self.next_of(brace)?;
        let ends = self.back_of(close)?;

        if barred {
            return (ends >= head).then_some(brace);
        }

        (ends >= head
            && self
                .header_width(head, ends)
                .is_none_or(|width| width > self.policy.literal_width))
        .then_some(brace)
    }

    fn chain_flattens(&self, tail: u32, last: u32, under: u32) -> bool {
        let Some(spelled) = self.header_width(tail, last) else {
            return false;
        };

        let mut braces = 0_u32;
        let mut scan = tail;

        while scan <= last && scan < self.count {
            braces += u32::from(
                self.tokens[scan as usize].kind == TokenKind::BlockStart && self.lambda_bar(scan),
            );
            scan += 1;
        }

        let width = spelled.saturating_sub(4 * braces);

        if under + self.options.indent_width + width > self.options.line_width {
            return false;
        }

        scan = tail;

        while scan <= last && scan < self.count {
            let kind = self.tokens[scan as usize].kind;

            if !is_open(kind) || kind == TokenKind::BlockStart {
                scan += 1;

                continue;
            }

            let Some(close) = self.closing_of(scan) else {
                return false;
            };

            let held = self.next_of(scan).filter(|found| *found < close);
            let stop = self.back_of(close);

            if let (Some(first), Some(end)) = (held, stop) {
                let soled = matches!(
                    self.tokens[first as usize].text(self.source),
                    b"|" | b"move"
                );

                if !soled && end >= first {
                    let Some(inside) = self.flat_width(first, end) else {
                        return false;
                    };

                    if inside > self.policy.call_width {
                        return false;
                    }
                }
            }

            scan += 1;
        }

        true
    }

    fn chain_soled(&self, open: u32, links: u32) -> Option<u32> {
        let close = self.closing_of(open)?;

        if self.parted_items(open, close) != 1 {
            return None;
        }

        let mut held = self.back_of(close)?;

        if self.tokens[held as usize].kind == TokenKind::Punctuation(Punctuation::Comma) {
            held = self.back_of(held)?;
        }

        if self.tokens[held as usize].kind != TokenKind::Punctuation(Punctuation::ParenClose) {
            return None;
        }

        let inner = reach::opened(self.source, self.tokens, held)?;

        if inner <= open {
            return None;
        }

        if self
            .flat_run(inner, held)
            .is_some_and(|width| width > self.policy.call_width)
        {
            return Some(inner);
        }

        if HUG_SOLES
            && self.hug_direct(open, inner)
            && self
                .flat_run(open, close)
                .is_some_and(|width| width > self.policy.call_width)
        {
            return Some(inner);
        }

        if !HUG_LINES || links < 2 || !self.hug_direct(open, inner) {
            return None;
        }

        let (first, level) = self.line_lead(open)?;
        let width = self.header_width(first, close)?;

        (level * self.options.indent_width + width > self.options.line_width).then_some(inner)
    }

    fn hug_direct(&self, open: u32, inner: u32) -> bool {
        let Some(mut scan) = self.next_of(open) else {
            return false;
        };

        for _ in 0..DEFINE_SCAN_MAX {
            if scan == inner {
                return true;
            }

            let token = self.tokens[scan as usize];

            if token.kind != TokenKind::Identifier
                && !matches!(token.text(self.source), b"::" | b"!")
            {
                return false;
            }

            scan = match self.next_of(scan) {
                Some(held) => held,
                None => return false,
            };
        }

        false
    }

    fn chain_call(&self, tail: u32, last: u32) -> Option<u32> {
        let mut scan = tail;

        for _ in 0..DEFINE_SCAN_MAX {
            let next = self.next_of(scan)?;

            if next > last {
                return None;
            }

            let kind = self.tokens[next as usize].kind;

            if kind == TokenKind::Punctuation(Punctuation::ParenOpen) {
                return Some(next);
            }

            if is_open(kind) || is_close(kind) {
                return None;
            }

            scan = next;
        }

        None
    }

    pub(super) fn sole_budget(&self, open: u32) -> u32 {
        if !self.policy.call_budgets || self.depth == 0 {
            return self.policy.call_width;
        }

        let mut budget = self.policy.call_width;

        for level in 0..self.depth - 1 {
            let frame = self.nest[level as usize];
            let held = self.nest[(level + 1) as usize];

            if held.open > open {
                break;
            }

            let width = self.callee_columns(held.open) + 2;

            let called = frame.kind == TokenKind::Punctuation(Punctuation::ParenOpen)
                && held.kind == TokenKind::Punctuation(Punctuation::ParenOpen)
                && !self.linked_bracket(frame.open);

            let nested =
                called && self.sole_inner(frame.open) == Some(held.open) && width <= budget;

            budget = if nested {
                budget - width
            } else {
                self.policy.call_width
            };
        }

        budget
    }

    pub(super) fn sole_joined(&self, position: u32) -> bool {
        if !self.policy.sole_joins || self.depth == 0 {
            return false;
        }

        let frame = self.nest[self.depth as usize - 1];

        if frame.kind != TokenKind::Punctuation(Punctuation::ParenOpen) {
            return false;
        }

        let Some(close) = self.closing_of(frame.open) else {
            return false;
        };

        if position <= frame.open
            || position > close
            || self.parted_items(frame.open, close) != 1
            || self.defined(frame.open)
            || self.hugged_brace(frame.open, close).is_some()
        {
            return false;
        }

        let Some((first, level)) = self.line_lead(frame.open) else {
            return false;
        };

        let budget = self.sole_budget(frame.open);

        let capped = self
            .flat_run(frame.open, close)
            .is_some_and(|width| width <= budget)
            || budget == self.policy.call_width && !self.sole_nested(frame.open, close);

        let held = !self.sole_capped()
            || self.sole_head(frame.open).is_some_and(|head| {
                self.header_width(head, close)
                    .is_some_and(|width| width < self.policy.call_width)
            });

        let returned =
            u32::from(SOLE_RETURNS && self.tokens[first as usize].text(self.source) == b"return");

        capped
            && held
            && first <= frame.open
            && self
                .next_of(frame.open)
                .is_some_and(|head| self.capped_spans(head, close))
            && self.header_width(first, close).is_some_and(|width| {
                level * self.options.indent_width + width + self.sole_owed() + returned
                    <= self.options.line_width
            })
    }

    pub(super) fn sole_owed(&self) -> u32 {
        let mut owed = 1;

        for level in 0..self.depth.saturating_sub(1) {
            if matches!(
                self.nest[level as usize].kind,
                TokenKind::Punctuation(Punctuation::ParenOpen | Punctuation::BracketOpen)
            ) {
                owed += 1;
            }
        }

        owed
    }

    fn sole_capped(&self) -> bool {
        if self.depth < 2 {
            return false;
        }

        let outer = self.nest[self.depth as usize - 2];

        if !matches!(
            outer.kind,
            TokenKind::Punctuation(Punctuation::ParenOpen | Punctuation::BracketOpen)
        ) {
            return false;
        }

        self.closing_of(outer.open)
            .is_some_and(|close| self.parted_items(outer.open, close) == 1)
    }

    fn sole_head(&self, open: u32) -> Option<u32> {
        let mut head = self.back_of(open)?;

        if !matches!(
            self.tokens[head as usize].kind,
            TokenKind::Identifier | TokenKind::Keyword(_)
        ) {
            return None;
        }

        for _ in 0..NEST_DEPTH_MAX {
            let Some(joint) = self.back_of(head) else {
                return Some(head);
            };

            let text = self.tokens[joint as usize].text(self.source);

            if text != b"::" && text != b"!" {
                return Some(head);
            }

            head = match self.back_of(joint) {
                Some(found) => found,
                None => return Some(head),
            };
        }

        Some(head)
    }

    fn sole_nested(&self, open: u32, close: u32) -> bool {
        let Some(mut held) = self.back_of(close) else {
            return false;
        };

        if self.tokens[held as usize].kind == TokenKind::Punctuation(Punctuation::Comma) {
            held = match self.back_of(held) {
                Some(found) if found > open => found,
                _ => return false,
            };
        }

        for _ in 0..NEST_DEPTH_MAX {
            if !matches!(self.tokens[held as usize].text(self.source), b"?") {
                break;
            }

            held = match self.back_of(held) {
                Some(found) => found,
                None => return false,
            };
        }

        if self.tokens[held as usize].kind != TokenKind::Punctuation(Punctuation::ParenClose) {
            return false;
        }

        let Some(inner) = reach::opened(self.source, self.tokens, held) else {
            return false;
        };

        if inner <= open {
            return false;
        }

        let Some(named) = self.back_of(inner) else {
            return false;
        };

        matches!(
            self.tokens[named as usize].kind,
            TokenKind::Identifier | TokenKind::Keyword(_)
        ) && self.back_of(named).is_none_or(|found| {
            !self.is_dot(found) && self.tokens[found as usize].text(self.source) != b"!"
        })
    }

    pub(super) fn fields_joined(&self, position: u32) -> bool {
        if !self.policy.literal_joins || self.policy.literal_width == 0 || self.depth == 0 {
            return false;
        }

        let frame = self.nest[self.depth as usize - 1];

        if frame.kind != TokenKind::BlockStart || !self.valued_brace(frame.open) {
            return false;
        }

        let (Some(close), Some(head)) = (self.closing_of(frame.open), self.next_of(frame.open))
        else {
            return false;
        };

        let Some(last) = self.fields_last(frame.open, close) else {
            return false;
        };

        if position > close || head > last {
            return false;
        }

        let Some((first, level)) = self.line_lead(frame.open) else {
            return false;
        };

        let parted = self.back_of(close).is_some_and(|end| {
            end > head
                && self
                    .header_width(head, end)
                    .is_none_or(|width| width > self.policy.literal_width)
        });

        parted
            && position > head
            && position < close
            && first <= frame.open
            && self
                .header_width(head, last)
                .is_some_and(|width| width <= self.policy.literal_width)
            && self.header_width(first, close).is_some_and(|width| {
                level * self.options.indent_width + width <= self.options.line_width
            })
    }

    fn fields_last(&self, open: u32, close: u32) -> Option<u32> {
        let mut last = self.back_of(close)?;

        if last <= open {
            return None;
        }

        if self.tokens[last as usize].kind == TokenKind::Punctuation(Punctuation::Comma) {
            last = self.back_of(last)?;
        }

        if self.ranges(last) {
            last = self.back_of(last)?;

            if self.tokens[last as usize].kind == TokenKind::Punctuation(Punctuation::Comma) {
                last = self.back_of(last)?;
            }
        }

        (last > open).then_some(last)
    }

    pub(super) fn attribute_joined(&self, position: u32) -> bool {
        if !self.policy.attribute_joins || self.policy.attribute_width == 0 || self.depth == 0 {
            return false;
        }

        let frame = self.nest[self.depth as usize - 1];

        if frame.kind != TokenKind::Punctuation(Punctuation::ParenOpen) {
            return false;
        }

        let Some(close) = self.closing_of(frame.open) else {
            return false;
        };

        if position > close {
            return false;
        }

        let Some((first, level)) = self.line_lead(frame.open) else {
            return false;
        };

        if first > frame.open || !self.attribute_lead(first) {
            return false;
        }

        self.flat_run(frame.open, close)
            .is_some_and(|width| width <= self.policy.attribute_width)
            && self.header_width(first, close).is_some_and(|width| {
                level * self.options.indent_width + width <= self.options.line_width
            })
    }

    pub(super) fn attribute_broken(&self, position: u32) -> bool {
        if !ATTRIBUTE_BREAKS || self.policy.attribute_width == 0 || self.depth == 0 {
            return false;
        }

        let frame = self.nest[self.depth as usize - 1];

        if frame.kind != TokenKind::Punctuation(Punctuation::ParenOpen) {
            return false;
        }

        let Some(close) = self.closing_of(frame.open) else {
            return false;
        };

        if position != close && self.back_of(position) != Some(frame.open) {
            return false;
        }

        let Some((first, level)) = self.line_lead(frame.open) else {
            return false;
        };

        if first > frame.open || !self.attribute_lead(first) {
            return false;
        }

        if !self.attribute_plain(frame.open, close) {
            return false;
        }

        self.header_width(first, close).is_some_and(|width| {
            level * self.options.indent_width + width + 1 > self.options.line_width
        })
    }

    fn attribute_plain(&self, open: u32, close: u32) -> bool {
        let mut scan = open + 1;

        while scan < close {
            let kind = self.tokens[scan as usize].kind;

            if is_open(kind) || kind == TokenKind::BlockStart {
                return false;
            }

            scan += 1;
        }

        true
    }

    fn attribute_lead(&self, first: u32) -> bool {
        if self.tokens[first as usize].text(self.source) != b"#" {
            return false;
        }

        let mut scan = first;

        for _ in 0..NEST_DEPTH_MAX {
            let Some(next) = self.next_of(scan) else {
                return false;
            };

            if matches!(
                self.tokens[next as usize].text(self.source),
                b"!" | b"[" | b"::"
            ) {
                scan = next;

                continue;
            }

            return !self.word_is(next, self.policy.attribute_words);
        }

        false
    }

    pub(super) fn arm_emptied(&self, position: u32, previous: u32) -> bool {
        self.policy.arm_empties
            && self.tokens[position as usize].kind == TokenKind::BlockEnd
            && self.tokens[previous as usize].kind == TokenKind::BlockStart
            && self.armed_frame(previous)
    }

    pub(super) fn item_joined(&self, position: u32) -> bool {
        if self.policy.item_words.is_empty() {
            return false;
        }

        let Some((first, level)) = self.line_lead(position) else {
            return false;
        };

        let braced =
            self.depth == 0 || self.nest[self.depth as usize - 1].kind == TokenKind::BlockStart;

        if !braced || !self.word_is(first, self.policy.item_words) || !self.item_headed(first) {
            return false;
        }

        let Some(brace) = self.item_brace(first) else {
            return false;
        };

        position <= brace
            && self.header_width(first, brace).is_some_and(|width| {
                level * self.options.indent_width + width <= self.options.line_width
            })
    }

    fn item_headed(&self, first: u32) -> bool {
        if ITEM_ANGLES && self.angle_head(first).is_some() {
            return false;
        }

        self.back_of(first).is_none_or(|held| {
            matches!(
                self.tokens[held as usize].kind,
                TokenKind::BlockStart
                    | TokenKind::BlockEnd
                    | TokenKind::Punctuation(Punctuation::BracketClose | Punctuation::Semicolon)
            ) || self.word_is(held, ITEM_HEADS)
        })
    }

    fn item_brace(&self, first: u32) -> Option<u32> {
        let mut depth = 0_u32;
        let mut scan = first;

        for _ in 0..DEFINE_SCAN_MAX {
            let kind = self.tokens[scan as usize].kind;

            if kind == TokenKind::BlockStart && depth == 0 {
                return Some(scan);
            }

            if is_open(kind) {
                depth += 1;
            } else if is_close(kind) {
                depth = depth.saturating_sub(1);
            } else if depth == 0
                && (kind == TokenKind::Comment
                    || self.word_is(scan, self.policy.clause_words)
                    || kind == TokenKind::Punctuation(Punctuation::Semicolon)
                    || kind == TokenKind::Punctuation(Punctuation::Comma)
                        && !(ITEM_ANGLES && self.angle_head(scan).is_some()))
            {
                return None;
            }

            scan = self.next_of(scan)?;
        }

        None
    }

    pub(super) fn listed_blank(&self) -> bool {
        self.policy.list_blanks
            && self.depth > 0
            && matches!(
                self.nest[self.depth as usize - 1].kind,
                TokenKind::Punctuation(Punctuation::BracketOpen | Punctuation::ParenOpen)
            )
    }

    pub(super) fn header_width(&self, from: u32, end: u32) -> Option<u32> {
        let first = self.tokens[from as usize];
        let mut width = columns(self.source, first.offset, first.end());
        let mut scan = from;

        for _ in 0..DEFINE_SCAN_MAX {
            if scan >= end {
                return Some(width);
            }

            let next = self.next_of(scan)?;
            let token = self.tokens[next as usize];
            let after = self.tokens[scan as usize].end();

            if token.kind == TokenKind::Comment || token.text(self.source).contains(&b'\n') {
                return None;
            }

            let dropped = token.kind == TokenKind::Punctuation(Punctuation::Comma)
                && self
                    .next_of(next)
                    .is_some_and(|found| is_close(self.tokens[found as usize].kind));

            if !dropped {
                let glued = self.welded(next, scan);

                width += u32::from(token.offset > after && !glued)
                    + columns(self.source, token.offset, token.end());
            }

            scan = next;
        }

        None
    }

    pub(super) fn joins_a_break(&self, position: u32, previous: u32) -> bool {
        self.flat_joined(position)
            || self.header_joined(position, previous)
            || self.arm_opened(position, previous)
            || self.chain_flat(position, previous)
            || self.hug_joined(position)
            || self.sole_joined(position)
            || self.macro_joined(position)
            || self.mixed_joined(position)
            || self.attribute_joined(position)
            || self.arm_emptied(position, previous)
    }

    pub(super) fn joined_dot(&self, position: u32, previous: u32) -> bool {
        self.is_dot(position)
            && !self.ranges(position)
            && (self.chain_hugged(position)
                || self.root_joined(position, previous)
                || self.chain_flatted(position)
                || self.chain_flat(position, previous))
    }

    fn joined_width(&self, from: u32, end: u32, parted: u32) -> Option<u32> {
        let first = self.tokens[from as usize];
        let mut width = columns(self.source, first.offset, first.end());
        let mut scan = from;

        for _ in 0..DEFINE_SCAN_MAX {
            if scan >= end {
                return Some(width);
            }

            let next = self.next_of(scan)?;
            let token = self.tokens[next as usize];
            let after = self.tokens[scan as usize].end();
            let broken = self.parted_by(after, token.offset) > 0;
            let elsed = ASSIGN_ELSES && token.text(self.source) == b"else";
            let kept = broken
                && scan != parted
                && !elsed
                && !self.chain_flat(next, scan)
                && !self.semicolon_joined(next, scan);

            if token.kind == TokenKind::Comment || kept {
                return None;
            }

            if token.text(self.source).contains(&b'\n') {
                return None;
            }

            width +=
                u32::from(token.offset > after) + columns(self.source, token.offset, token.end());
            scan = next;
        }

        None
    }

    fn letting(&self, head: u32, open: u32) -> bool {
        let mut depth = 0_u32;
        let mut bound = false;
        let mut chained = false;
        let mut ampersand = 0_u32;
        let mut scan = head;

        for _ in 0..DEFINE_SCAN_MAX {
            if scan >= open {
                return bound && chained;
            }

            let text = self.tokens[scan as usize].text(self.source);
            let kind = self.tokens[scan as usize].kind;

            if is_open(kind) {
                depth += 1;
                ampersand = 0;
            } else if is_close(kind) {
                depth = depth.saturating_sub(1);
                ampersand = 0;
            } else if depth == 0 {
                ampersand = if text == b"&" { ampersand + 1 } else { 0 };
                bound = bound || text == b"let";
                chained = chained || text == b"&&" || ampersand > 1;
            }

            scan = match self.next_of(scan) {
                Some(found) => found,
                None => return bound && chained,
            };
        }

        false
    }

    fn brace_parted(&self, position: u32, lead: u32) -> Option<u32> {
        if !BRACE_PARTS || !self.policy.header_joins {
            return None;
        }

        if self.tokens[position as usize].kind != TokenKind::BlockStart {
            return None;
        }

        let previous = self.coded()?;
        let head = self.header_head(previous)?;

        if self.header_brace(head) != Some(position) || self.brace_extended(lead, previous) {
            return None;
        }

        (head < lead).then_some(head)
    }

    fn brace_extended(&self, lead: u32, previous: u32) -> bool {
        let mut scan = lead;

        for _ in 0..DEFINE_SCAN_MAX {
            if !self.tokens[scan as usize]
                .text(self.source)
                .iter()
                .all(|byte| BRACE_EXTENDS.contains(byte))
            {
                return false;
            }

            if scan >= previous {
                return true;
            }

            scan = match self.next_of(scan) {
                Some(held) => held,
                None => return true,
            };
        }

        false
    }

    pub(super) fn brace_broken(&self, position: u32) -> bool {
        self.brace_parted(position, self.line_first).is_some()
    }

    pub(super) fn brace_level(&self, position: u32) -> Option<u32> {
        let head = self.brace_parted(position, self.line_before)?;

        self.leveled_at(head)
    }

    fn looping(&self, position: u32) -> bool {
        if self.tokens[position as usize].text(self.source) != b"for" {
            return true;
        }

        let Some(previous) = self.back_of(position) else {
            return true;
        };

        matches!(
            self.tokens[previous as usize].kind,
            TokenKind::BlockStart
                | TokenKind::BlockEnd
                | TokenKind::Punctuation(Punctuation::Colon | Punctuation::Semicolon)
        )
    }

    fn parted_bracket(&self, from: u32, end: u32) -> Option<u32> {
        let mut scan = from;

        for _ in 0..DEFINE_SCAN_MAX {
            if scan >= end {
                return None;
            }

            let kind = self.tokens[scan as usize].kind;

            if kind == TokenKind::BlockStart
                && (self.literal_wide(scan) || self.branched_wide(scan))
                || is_open(kind) && self.listed_wide(scan).is_some()
            {
                return Some(scan);
            }

            scan = self.next_of(scan)?;
        }

        None
    }

    fn spanned_width(&self, from: u32, to: u32) -> Option<u32> {
        let first = self.tokens[from as usize];
        let mut width = columns(self.source, first.offset, first.end());
        let mut scan = from;

        for _ in 0..DEFINE_SCAN_MAX {
            if scan >= to {
                return Some(width);
            }

            let next = self.next_of(scan)?;
            let token = self.tokens[next as usize];
            let after = self.tokens[scan as usize].end();
            let glued = self.is_dot(next) || self.is_dot(scan);

            if token.kind == TokenKind::Comment || token.text(self.source).contains(&b'\n') {
                return None;
            }

            if !glued && self.parted_by(after, token.offset) > 0 {
                return None;
            }

            width += u32::from(token.offset > after && !glued)
                + columns(self.source, token.offset, token.end());
            scan = next;
        }

        None
    }

    fn spelled(&self, position: u32, close: u32) -> bool {
        let Some(previous) = self.previous else {
            return false;
        };

        self.tokens[previous as usize].kind == TokenKind::Identifier
            && self.defining(previous)
            && self.unparsed(position, close)
    }

    pub(super) fn spread(&mut self, position: u32, close: u32) -> bool {
        let source = self.source;

        let held = Span {
            length: self.tokens[close as usize].end() - self.tokens[position as usize].offset,
            offset: self.tokens[position as usize].offset,
        };

        if self.macro_bracket(position) {
            return self.restreamed(position, close);
        }

        let blocked = self.tokens[position as usize].kind == TokenKind::BlockStart
            || GIVE_INDENTS && self.blocked_give(position, close);

        if !self.policy.macro_indents
            || self.options.tabs
            || !blocked
            || self.spelled(position, close)
            || spilled(self.tokens, source, position, close)
        {
            return self.spanned(position, close);
        }

        self.previous = Some(close);
        self.resume = close + 1;
        self.suppress_space = false;

        let base = self.printed * self.options.indent_width;
        let offset = self.arena.count();

        if !respread(
            self.arena,
            &source[held.range()],
            self.options.indent_width,
            base,
        ) {
            self.arena.truncate(offset);

            return false;
        }

        self.document.push(Element::VerbatimArena(Span {
            length: self.arena.count() - offset,
            offset,
        }))
    }

    fn blocked_give(&self, position: u32, close: u32) -> bool {
        if self.macros.binary_search(&position).is_err() {
            return false;
        }

        let from = self.tokens[position as usize].offset as usize;
        let to = self.tokens[close as usize].end() as usize;
        let text = &self.source[from..to];

        let Some(at) = text.iter().rposition(|byte| *byte == b'\n') else {
            return false;
        };

        let last = text[at + 1..].trim_ascii();
        let held = last.strip_suffix(b";").unwrap_or(last);

        !held.is_empty() && held.iter().all(|byte| matches!(*byte, b'}' | b')' | b']'))
    }

    fn statement_end(&self, position: u32) -> Option<u32> {
        let mut depth = 0_u32;
        let mut scan = position;

        for _ in 0..DEFINE_SCAN_MAX {
            let kind = self.tokens[scan as usize].kind;

            if depth == 0 && kind == TokenKind::Punctuation(Punctuation::Semicolon) {
                return Some(scan);
            }

            if is_open(kind) || kind == TokenKind::BlockStart {
                depth += 1;
            } else if is_close(kind) || kind == TokenKind::BlockEnd {
                depth = depth.checked_sub(1)?;
            }

            scan = self.next_of(scan)?;
        }

        None
    }
}
