use super::{DEFINE_SCAN_MAX, Emitter, MACRO_GROUPS, NEST_DEPTH_MAX, TYPE_SCAN_MAX};
use crate::bounded::count_of;
use crate::format::reach;
use crate::format::walk::{columns, ends_operand, is_close, is_open, simple_word};
use crate::token::{Keyword, Punctuation, Token, TokenKind};

const EXTENDS: &[u8] = b"()]}?>";
const ROOT_TOKEN_WIDTH: bool = true;
const UNARY_WALK_MAX: u32 = 4;
const SOLE_CHAIN_LINE: bool = true;
const FLAT_WELDS: bool = true;
const SOLE_CHAIN_ALWAYS: bool = true;
const CHAIN_FLAT: bool = true;
pub(super) const LIST_NESTS: bool = true;
pub(super) const LIST_WIDES: bool = true;
const HUG_WIDTH: bool = true;
const BAR_COMMAS: bool = true;
const MACRO_BLOCKS: bool = true;
const INNER_BLANKS: bool = true;
const CHAIN_LINED: bool = true;
const CHAIN_SEATS: bool = true;
const CHAIN_ROOTS: bool = true;
const STRING_SOLES: bool = true;
const STRING_SPANS: bool = true;
pub(super) const BINDING_LINKS: bool = true;

#[expect(
    clippy::multiple_inherent_impl,
    reason = "the break-forcing family is a child module of `brace`, whose own `impl Emitter` \
              block stands in `mod.rs`"
)]
impl Emitter<'_> {
    fn angle_count(&self, position: u32, angle: u8) -> Option<u32> {
        let text = self.tokens[position as usize].text(self.source);

        if text.is_empty() || !text.iter().all(|byte| *byte == angle) {
            return None;
        }

        Some(count_of(text.len()))
    }

    fn angled_head(&self, close: u32) -> Option<u32> {
        let mut angles = self.angle_count(close, b'>')?;
        let mut scan = close;

        for _ in 0..TYPE_SCAN_MAX {
            let held = self.back_of(scan)?;

            if let Some(found) = self.angle_count(held, b'>') {
                angles += found;
            } else if let Some(found) = self.angle_count(held, b'<') {
                angles = angles.saturating_sub(found);

                if angles == 0 {
                    return self
                        .back_of(held)
                        .filter(|head| self.tokens[*head as usize].text(self.source) == b"::");
                }
            }

            scan = held;
        }

        None
    }

    fn attribute_head(&self) -> Option<u32> {
        for level in 0..self.depth {
            let frame = self.nest[level as usize];

            if frame.kind == TokenKind::Punctuation(Punctuation::BracketOpen)
                && self.hashed(frame.open)
            {
                return Some(frame.open);
            }
        }

        None
    }

    fn attribute_parted(&self, held: u32) -> Option<u32> {
        let bracket = self.attribute_head()?;
        let word = self.next_of(bracket)?;

        if self.word_is(word, self.policy.attribute_words) {
            return None;
        }

        let open = self.sole_call(held);
        let close = self.closing_of(open)?;

        if !self.metaed(open, close) {
            return None;
        }

        let from = self.tokens[open as usize].end();
        let to = self.tokens[close as usize].offset;

        (self.parted_by(from, to) == 0
            && columns(self.source, from, to) > self.policy.attribute_width)
            .then_some(open)
    }

    fn attributes(&self, position: u32, previous: u32) -> bool {
        if self.policy.attribute_width == 0 {
            return false;
        }

        let separated =
            self.tokens[previous as usize].kind == TokenKind::Punctuation(Punctuation::Comma);

        for level in 0..self.depth {
            let frame = self.nest[level as usize];

            if frame.kind != TokenKind::Punctuation(Punctuation::ParenOpen) {
                continue;
            }

            let Some(open) = self.attribute_parted(frame.open) else {
                continue;
            };

            if previous == open || self.closing_of(open) == Some(position) {
                return true;
            }

            if separated && self.frame().open == open {
                return true;
            }
        }

        false
    }

    fn blocks(&self, position: u32, previous: u32) -> bool {
        for level in 0..self.depth {
            let frame = self.nest[level as usize];

            if frame.kind != TokenKind::BlockStart || !self.blocks_wide(frame.open) {
                continue;
            }

            if previous == frame.open || self.closing(frame.open) == Some(position) {
                return true;
            }
        }

        false
    }

    fn blocks_wide(&self, open: u32) -> bool {
        if self.policy.literal_width == 0
            || self.tokens[open as usize].kind != TokenKind::BlockStart
            || self.valued_brace(open)
        {
            return false;
        }

        let Some(close) = self.closing_of(open) else {
            return false;
        };

        let from = self.tokens[open as usize].end();
        let to = self.tokens[close as usize].offset;

        if self.parted_by(from, to) > 0 {
            return false;
        }

        if self.remarked_value(open) {
            return false;
        }

        if self.chained_line(open, close) || self.branched_line(open, close) {
            return true;
        }

        let mut scan = open + 1;

        while scan < close {
            if self.spans_wide(scan) {
                return true;
            }

            scan += 1;
        }

        false
    }

    fn literal_bound(&self, open: u32) -> u32 {
        if self.varied_brace(open).is_some() {
            self.policy.variant_width
        } else {
            self.policy.literal_width
        }
    }

    fn varied_brace(&self, open: u32) -> Option<u32> {
        if self.policy.variant_width == 0 {
            return None;
        }

        let mut depth = 0_u32;
        let mut scan = open;

        for _ in 0..TYPE_SCAN_MAX {
            let held = self.back_of(scan)?;
            let kind = self.tokens[held as usize].kind;

            if is_close(kind) || kind == TokenKind::BlockEnd {
                depth += 1;
            } else if is_open(kind) || kind == TokenKind::BlockStart {
                if depth > 0 {
                    depth -= 1;
                } else if kind == TokenKind::BlockStart
                    && self.head_word(held, &[b"enum"]).is_some()
                {
                    return Some(held);
                } else {
                    return None;
                }
            }

            scan = held;
        }

        None
    }

    fn spans_wide(&self, open: u32) -> bool {
        let kind = self.tokens[open as usize].kind;

        if !is_open(kind) && kind != TokenKind::BlockStart {
            return false;
        }

        let Some(close) = self.closing_of(open) else {
            return false;
        };

        if kind == TokenKind::BlockStart {
            if !self.valued_brace(open) {
                return false;
            }

            let from = self.tokens[open as usize].end();
            let to = self.tokens[close as usize].offset;

            return columns(self.source, from, to) > self.literal_bound(open);
        }

        if !self.listed(close) {
            return false;
        }

        let held = self.sole_call(open);

        let Some(stop) = self.closing_of(held) else {
            return false;
        };

        let from = self.tokens[held as usize].end();
        let to = self.tokens[stop as usize].offset;

        columns(self.source, from, to) > self.policy.call_width && self.elemental_list(held, stop)
    }

    fn braced_line(&self, position: u32) -> bool {
        let mut scan = position;

        for _ in 0..TYPE_SCAN_MAX {
            let Some(held) = self.back_of(scan) else {
                return false;
            };

            let parted = self.parted_by(
                self.tokens[held as usize].end(),
                self.tokens[scan as usize].offset,
            ) > 0;

            if parted {
                return false;
            }

            if self.tokens[held as usize].kind == TokenKind::BlockStart {
                return !self.fields_wide(held)
                    && !self.literal_wide(held)
                    && !self.branched_wide(held)
                    && !self.blocks_wide(held);
            }

            scan = held;
        }

        false
    }

    fn braces_a_header(&self, position: u32) -> bool {
        let braced = self.tokens[position as usize].kind == TokenKind::BlockStart;

        if !self.policy.header_braces || !braced || self.printed <= self.levels {
            return false;
        }

        let ended = self.back_of(position).is_some_and(|held| {
            self.tokens[held as usize].kind == TokenKind::Punctuation(Punctuation::ParenClose)
                || self.word_is(held, self.policy.source_words)
        });

        if !ended {
            return false;
        }

        let Some(head) = self.head_word(position, self.policy.header_words) else {
            return false;
        };

        for scan in head..position {
            if matches!(
                self.tokens[scan as usize].kind,
                TokenKind::BlockEnd | TokenKind::BlockStart
            ) || self.word_is(scan, self.policy.level_words)
            {
                return false;
            }
        }

        if self.policy.header_extends && self.extendable(position) {
            return false;
        }

        self.line_first > head
    }

    fn bracket_after(&self, position: u32, wanted: TokenKind) -> Option<u32> {
        let mut depth = 0_u32;
        let mut scan = position;

        for _ in 0..TYPE_SCAN_MAX {
            scan = self.next_of(scan)?;

            let kind = self.tokens[scan as usize].kind;

            if kind == wanted && depth == 0 {
                return Some(scan);
            }

            if is_open(kind) || kind == TokenKind::BlockStart {
                depth += 1;
            } else if is_close(kind) || kind == TokenKind::BlockEnd {
                depth = depth.checked_sub(1)?;
            }
        }

        None
    }

    fn branch_brace(&self, position: u32) -> Option<u32> {
        let mut scan = position;

        for _ in 0..TYPE_SCAN_MAX {
            let held = self.bracket_after(scan, TokenKind::BlockStart)?;

            let opened = self.back_of(held).is_some_and(|found| {
                matches!(
                    self.tokens[found as usize].text(self.source),
                    b"async" | b"const" | b"do" | b"gen" | b"move" | b"try" | b"unsafe"
                )
            });

            if !opened {
                return Some(held);
            }

            scan = self.closing(held)?;
        }

        None
    }

    fn branch_end(&self, head: u32) -> Option<u32> {
        let mut scan = head;

        for _ in 0..TYPE_SCAN_MAX {
            let open = self.branch_brace(scan)?;
            let close = self.closing(open)?;

            let Some(next) = self.next_of(close) else {
                return Some(close);
            };

            if self.tokens[next as usize].text(self.source) != b"else" {
                return Some(close);
            }

            scan = next;
        }

        None
    }

    fn branch_head(&self, open: u32) -> Option<u32> {
        let mut depth = 0_u32;
        let mut scan = open;

        for _ in 0..TYPE_SCAN_MAX {
            scan = self.back_of(scan)?;

            let token = self.tokens[scan as usize];

            if token.kind == TokenKind::BlockEnd {
                scan = reach::opened(self.source, self.tokens, scan)?;

                continue;
            }

            if is_close(token.kind) {
                depth += 1;

                continue;
            }

            if is_open(token.kind) || token.kind == TokenKind::BlockStart {
                if depth == 0 {
                    return None;
                }

                depth -= 1;

                continue;
            }

            if depth > 0 {
                continue;
            }

            if self.word_is(scan, self.policy.branch_words) {
                return Some(scan);
            }

            if matches!(
                token.kind,
                TokenKind::Punctuation(Punctuation::Comma | Punctuation::Semicolon)
            ) {
                return None;
            }
        }

        None
    }

    pub(super) fn branched_wide(&self, open: u32) -> bool {
        let Some(head) = self.branch_head(open) else {
            return false;
        };

        if self.braced_line(head) || self.remarked_value(head) {
            return false;
        }

        self.branched_over(head)
    }

    fn branched_over(&self, head: u32) -> bool {
        let Some(end) = self.branch_end(head) else {
            return false;
        };

        let from = self.tokens[head as usize].offset;
        let to = self.tokens[end as usize].end();

        self.parted_by(from, to) == 0 && columns(self.source, from, to) > self.policy.branch_width
    }

    fn branched_line(&self, open: u32, close: u32) -> bool {
        if self.policy.branch_width == 0 || !self.policy.block_chains {
            return false;
        }

        let Some(head) = self.next_of(open) else {
            return false;
        };

        head < close && self.word_is(head, self.policy.branch_words) && self.branched_over(head)
    }

    pub(super) fn else_wide(&self, open: u32) -> bool {
        if self.policy.else_width == 0 || self.tokens[open as usize].kind != TokenKind::BlockStart {
            return false;
        }

        let Some(previous) = self.back_of(open) else {
            return false;
        };

        if self.tokens[previous as usize].text(self.source) != b"else" {
            return false;
        }

        let branched = self
            .back_of(previous)
            .is_none_or(|held| self.tokens[held as usize].kind == TokenKind::BlockEnd);

        if branched {
            return false;
        }

        let Some(head) = self.statement_word(previous) else {
            return false;
        };

        if self.tokens[head as usize].text(self.source) != b"let" || self.braced_line(head) {
            return false;
        }

        let Some(close) = self.closing(open) else {
            return false;
        };

        let end = self.statement_close(close);
        let from = self.tokens[head as usize].offset;
        let to = self.tokens[end as usize].end();

        self.parted_by(from, to) == 0 && columns(self.source, from, to) > self.policy.else_width
    }

    fn statement_word(&self, position: u32) -> Option<u32> {
        let mut head = self.statement_head(position)?;

        for _ in 0..TYPE_SCAN_MAX {
            if self.tokens[head as usize].kind != TokenKind::Comment {
                return Some(head);
            }

            head = self.next_of(head)?;
        }

        None
    }

    fn statement_close(&self, close: u32) -> u32 {
        let Some(next) = self.next_of(close) else {
            return close;
        };

        if self.tokens[next as usize].kind == TokenKind::Punctuation(Punctuation::Semicolon) {
            next
        } else {
            close
        }
    }

    fn let_elses(&self, position: u32, previous: u32) -> bool {
        if self.policy.else_width == 0 {
            return false;
        }

        let open = if self.tokens[previous as usize].kind == TokenKind::BlockStart {
            previous
        } else if self.tokens[position as usize].kind == TokenKind::BlockEnd {
            match reach::opened(self.source, self.tokens, position) {
                Some(held) => held,
                None => return false,
            }
        } else {
            return false;
        };

        self.else_wide(open)
    }

    pub(super) fn used_wide(&self, open: u32) -> bool {
        if self.policy.list_width == 0 || self.tokens[open as usize].kind != TokenKind::BlockStart {
            return false;
        }

        let led = self
            .word_before(open)
            .is_some_and(|lead| self.word_is(lead, self.policy.list_leads));

        let Some(head) = self.statement_word(open).filter(|_| led) else {
            return false;
        };

        if !self.word_is(head, self.policy.list_words) {
            return false;
        }

        let Some(close) = self.closing_of(open) else {
            return false;
        };

        if self.next_of(open) == Some(close) {
            return false;
        }

        let end = self.statement_close(close);
        let under = self.printed * self.options.indent_width;

        under + self.used_columns(head, open, close, end) > self.policy.list_width
    }

    fn used_columns(&self, head: u32, open: u32, close: u32, end: u32) -> u32 {
        let mut spelled = 0;
        let mut previous: Option<u32> = None;
        let mut scan = head;

        while scan <= end && (scan as usize) < self.tokens.len() {
            let token = self.tokens[scan as usize];

            let dropped = token.length == 0
                || token.kind == TokenKind::Newline
                || token.kind == TokenKind::Punctuation(Punctuation::Comma)
                    && self.next_of(scan) == Some(close);

            if dropped {
                scan += 1;

                continue;
            }

            let gapped = previous.is_some_and(|before| {
                self.tokens[before as usize].end() < token.offset && before != open && scan != close
            });

            spelled += u32::from(gapped) + columns(self.source, token.offset, token.end());
            previous = Some(scan);
            scan += 1;
        }

        spelled
    }

    fn uses(&self, position: u32, previous: u32) -> bool {
        if self.policy.list_width == 0 {
            return false;
        }

        let open = if self.tokens[previous as usize].kind == TokenKind::BlockStart {
            previous
        } else if self.tokens[position as usize].kind == TokenKind::BlockEnd {
            match reach::opened(self.source, self.tokens, position) {
                Some(held) => held,
                None => return false,
            }
        } else {
            return false;
        };

        let Some(close) = self.closing_of(open) else {
            return false;
        };

        self.parted_by(
            self.tokens[open as usize].end(),
            self.tokens[close as usize].offset,
        ) == 0
            && self.used_wide(open)
    }

    fn branches(&self, position: u32, previous: u32) -> bool {
        if self.policy.branch_width == 0 {
            return false;
        }

        let open = if self.tokens[previous as usize].kind == TokenKind::BlockStart {
            previous
        } else if self.tokens[position as usize].kind == TokenKind::BlockEnd {
            match reach::opened(self.source, self.tokens, position) {
                Some(held) => held,
                None => return false,
            }
        } else {
            return false;
        };

        self.branched_wide(open)
    }

    pub(super) fn calls(&self, position: u32, previous: u32) -> bool {
        if self.policy.call_width == 0 || self.attribute_head().is_some() {
            return false;
        }

        let separated =
            self.tokens[previous as usize].kind == TokenKind::Punctuation(Punctuation::Comma);

        let mut reached = (0_u32, 0_u32);

        for level in 0..self.depth {
            let frame = self.nest[level as usize];

            if frame.open > reached.0 && frame.open <= reached.1 {
                continue;
            }

            let called = frame.kind == TokenKind::Punctuation(Punctuation::ParenOpen)
                || self
                    .closing_of(frame.open)
                    .is_some_and(|close| self.macroed(frame.open, close));

            let arrayed = frame.kind == TokenKind::Punctuation(Punctuation::BracketOpen);

            if !called && !arrayed {
                continue;
            }

            let Some(open) = self.listed_wide(frame.open) else {
                continue;
            };

            let overflowed = self.policy.call_budgets && open > frame.open;

            if overflowed {
                reached = (frame.open, open);
            }

            if previous == open {
                return true;
            }

            let hugged = overflowed
                && self.closing_of(open).is_some_and(|end| {
                    !self.elemental_list(open, end)
                        && self.back_of(end).is_some_and(|last| {
                            self.tokens[last as usize].kind == TokenKind::BlockEnd
                        })
                });

            if !hugged && self.closing_of(open) == Some(position) {
                return true;
            }

            if separated
                && self.frame().open == open
                && !self.lambda_barred(open, previous)
                && !self.filled_list(frame.open)
            {
                return self.macro_broken(frame.open, previous);
            }
        }

        false
    }

    pub(super) fn chain_end(&self, head: u32) -> (u32, u32, u32) {
        let mut angles = 0_u32;
        let mut depth = 0_u32;
        let mut end = head;
        let mut links = 0;
        let mut opened = TokenKind::Newline;
        let mut parent = head;
        let mut scan = head;

        while scan < self.count {
            let kind = self.tokens[scan as usize].kind;
            let body = kind == TokenKind::BlockStart && !self.initialised(scan);

            if depth == 0 && scan > head && body {
                break;
            }

            if is_open(kind) || kind == TokenKind::BlockStart {
                if depth == 0 {
                    opened = kind;
                }

                depth += 1;
            } else if is_close(kind) || kind == TokenKind::BlockEnd {
                if depth == 0 {
                    break;
                }

                depth -= 1;

                if depth == 0 && opened == TokenKind::Punctuation(Punctuation::BracketOpen) {
                    links = 0;
                    parent = scan;
                }
            } else if depth == 0 && !self.chained_by(scan, &mut angles) {
                break;
            }

            if depth == 0 && angles == 0 && scan > head && self.is_dot(scan) && !self.ranges(scan) {
                links += 1;
            }

            end = scan;
            scan += 1;
        }

        (end, links, parent)
    }

    pub(super) fn chain_head(&self, position: u32) -> u32 {
        let mut depth = 0_u32;
        let mut scan = position;

        for _ in 0..TYPE_SCAN_MAX {
            let Some(held) = self.back_of(scan) else {
                return scan;
            };

            let kind = self.tokens[held as usize].kind;

            if is_close(kind) || kind == TokenKind::BlockEnd {
                let ended = kind == TokenKind::BlockEnd || !self.is_dot(scan);

                if depth == 0 && ended && self.policy.head_blocks && self.parts_at(held, scan) {
                    return scan;
                }

                depth += 1;
            } else if is_open(kind) || kind == TokenKind::BlockStart {
                if depth == 0 {
                    return scan;
                }

                depth -= 1;
            } else if depth == 0 && !self.received(held, scan) {
                let Some(found) = self.angled_head(held) else {
                    return scan;
                };

                scan = found;

                continue;
            }

            scan = held;
        }

        scan
    }

    fn chained_by(&self, position: u32, angles: &mut u32) -> bool {
        let text = self.tokens[position as usize].text(self.source);

        if let Some(found) = self.angle_count(position, b'>').filter(|_| *angles > 0) {
            *angles = angles.saturating_sub(found);

            return true;
        }

        if let Some(found) = self.angle_count(position, b'<').filter(|_| *angles > 0) {
            *angles += found;

            return true;
        }

        if text == b"<"
            && self
                .back_of(position)
                .is_some_and(|held| self.tokens[held as usize].text(self.source) == b"::")
        {
            *angles += 1;

            return true;
        }

        *angles > 0 || self.receives(position)
    }

    fn chains_wide(&self, position: u32) -> bool {
        if self.policy.chain_width == 0 || !self.is_dot(position) || self.ranges(position) {
            return false;
        }

        let head = self.chain_head(position);

        !self.braced_line(head) && self.chained_over(head, position)
    }

    fn remarked_value(&self, value: u32) -> bool {
        let mut remarked = false;
        let mut scan = value;

        for _ in 0..TYPE_SCAN_MAX {
            let Some(held) = self.back_of(scan) else {
                return false;
            };

            let token = self.tokens[held as usize];

            if token.kind == TokenKind::Comment {
                remarked = true;
            } else if matches!(token.text(self.source), b"=" | b":" | b"return") {
                return remarked;
            } else if is_open(token.kind)
                || is_close(token.kind)
                || matches!(token.kind, TokenKind::BlockEnd | TokenKind::BlockStart)
                || matches!(
                    token.kind,
                    TokenKind::Punctuation(Punctuation::Comma | Punctuation::Semicolon)
                )
            {
                return false;
            }

            scan = held;
        }

        false
    }

    fn rooted_parted(&self, head: u32, position: u32) -> bool {
        if !CHAIN_ROOTS || self.policy.call_width == 0 {
            return false;
        }

        let Some(close) = self.back_of(position) else {
            return false;
        };

        if !matches!(
            self.tokens[close as usize].kind,
            TokenKind::Punctuation(Punctuation::ParenClose | Punctuation::BracketClose)
        ) {
            return false;
        }

        let Some(open) = self.brackets.open_of(close).filter(|held| *held >= head) else {
            return false;
        };

        if self.next_of(open) == Some(close) {
            return false;
        }

        self.listed_count(open, close) > 1
            && self.flat_columns(open + 1, close) > self.policy.call_width
    }

    fn listed_count(&self, open: u32, close: u32) -> u32 {
        let mut depth = 0_u32;
        let mut held = 1_u32;
        let mut lambda = false;
        let mut previous: Option<u32> = None;
        let mut scan = open + 1;

        while scan < close {
            let token = self.tokens[scan as usize];
            let kind = token.kind;
            let opens =
                previous.is_none_or(|found| !ends_operand(self.tokens[found as usize].kind));

            if depth == 0 && token.text(self.source) == b"|" && (lambda || opens) {
                lambda = !lambda;
            } else if is_open(kind) {
                depth += 1;
            } else if is_close(kind) {
                depth = depth.saturating_sub(1);
            } else if depth == 0
                && !lambda
                && kind == TokenKind::Punctuation(Punctuation::Comma)
                && self.next_of(scan) != Some(close)
            {
                held += 1;
            }

            if token.length > 0 {
                previous = Some(scan);
            }

            scan += 1;
        }

        held
    }

    fn chained_over(&self, head: u32, position: u32) -> bool {
        if self.remarked_value(head) {
            return false;
        }

        let (end, links, parent) = self.chain_end(head);

        if links == 0 || position <= parent {
            return false;
        }

        if parent == head && self.rooted(head, position) {
            return false;
        }

        if self.rooted_parted(head, position) {
            return true;
        }

        let from = self.tokens[head as usize].offset;
        let to = self.tokens[end as usize].end();

        if links < 2 {
            let column = self.chained_at(head);
            let root = self.flat_columns(head, position);
            let flat = self.flat_columns(head, end + 1);
            let written = self.parted_by(from, to) == 0 || self.linked_over(head, end);

            let seated = !CHAIN_LINED
                || self.heads_line(head)
                || self.lined_of(head) <= self.options.line_width;

            return SOLE_CHAIN_LINE
                && seated
                && position > head + 1
                && written
                && column + root <= self.options.line_width
                && column + flat > self.options.line_width;
        }

        if CHAIN_FLAT {
            let column = self.chained_at(head);
            let flat = self.flat_columns(head, end + 1);
            let overflowing = column + flat > self.options.line_width;
            let point = self.hug_point(head, end, overflowing);

            let rooted = column + self.flat_columns(head, self.linked_first(head, end))
                <= self.options.line_width;

            return rooted
                && !self.linked_over(head, end)
                && self.flat_columns(head, point) > self.policy.chain_width;
        }

        self.parted_by(from, to) == 0 && columns(self.source, from, to) > self.policy.chain_width
    }

    fn tabbed(&self, from: usize, to: usize) -> u32 {
        let mut tabs = 0;

        for byte in &self.source[from..to] {
            tabs += u32::from(*byte == b'\t');
        }

        columns(self.source, count_of(from), count_of(to))
            + tabs * self.options.indent_width.saturating_sub(1)
    }

    fn opened_at(&self, position: u32) -> usize {
        let mut start = self.tokens[position as usize].offset as usize;

        while start > 0 && self.source[start - 1] != b'\n' {
            start -= 1;
        }

        start
    }

    fn lined_of(&self, position: u32) -> u32 {
        let mut stop = self.tokens[position as usize].offset as usize;

        while stop < self.source.len() && self.source[stop] != b'\n' {
            stop += 1;
        }

        self.tabbed(self.opened_at(position), stop)
    }

    pub(super) fn indent_of(&self, position: u32) -> u32 {
        let start = self.opened_at(position);
        let mut stop = start;

        while stop < self.source.len() && matches!(self.source[stop], b' ' | b'\t') {
            stop += 1;
        }

        self.tabbed(start, stop)
    }

    fn spread_of(&self, position: u32) -> u32 {
        self.tabbed(
            self.opened_at(position),
            self.tokens[position as usize].offset as usize,
        )
    }

    fn chained_at(&self, head: u32) -> u32 {
        if self.lined_of(head) > self.options.line_width || self.assign_seated(head) {
            return self.indent_of(head) + self.options.indent_width;
        }

        self.spread_of(head)
    }

    fn assign_seated(&self, head: u32) -> bool {
        if !CHAIN_SEATS || self.heads_line(head) {
            return false;
        }

        let Some(first) = self.statement_word(head).filter(|held| *held < head) else {
            return false;
        };

        if self.assigned_value(first, head) != Some(head) {
            return false;
        }

        let stop = self.statement_close(self.chain_end(head).0);
        let under = self.indent_of(first);

        under + self.flat_columns(first, stop + 1) > self.options.line_width
            && under + self.options.indent_width + self.flat_columns(head, stop + 1)
                <= self.options.line_width
    }

    fn heads_line(&self, position: u32) -> bool {
        let head = self.opened_at(position);
        let from = (self.tokens[position as usize].offset as usize).min(self.source.len());

        self.source[head..from]
            .iter()
            .all(|byte| matches!(*byte, b' ' | b'\t'))
    }

    fn linked_over(&self, head: u32, end: u32) -> bool {
        let mut depth = 0_u32;
        let mut scan = head + 1;

        while scan <= end && scan < self.count {
            let kind = self.tokens[scan as usize].kind;

            if is_open(kind) || kind == TokenKind::BlockStart {
                depth += 1;
            } else if is_close(kind) || kind == TokenKind::BlockEnd {
                depth = depth.saturating_sub(1);
            } else if depth == 0
                && self.is_dot(scan)
                && self
                    .back_of(scan)
                    .is_some_and(|held| self.parts_at(held, scan))
            {
                return true;
            }

            scan += 1;
        }

        false
    }

    fn linked_first(&self, head: u32, end: u32) -> u32 {
        let mut depth = 0_u32;
        let mut scan = head;

        while scan <= end && scan < self.count {
            let kind = self.tokens[scan as usize].kind;

            if is_open(kind) || kind == TokenKind::BlockStart {
                depth += 1;
            } else if is_close(kind) || kind == TokenKind::BlockEnd {
                depth = depth.saturating_sub(1);
            } else if depth == 0 && scan > head && self.is_dot(scan) && !self.ranges(scan) {
                return scan;
            }

            scan += 1;
        }

        end + 1
    }

    fn hug_point(&self, head: u32, end: u32, overflowing: bool) -> u32 {
        let mut depth = 0_u32;
        let mut link = head;
        let mut scan = head;

        while scan <= end && scan < self.count {
            let kind = self.tokens[scan as usize].kind;

            if is_open(kind) || kind == TokenKind::BlockStart {
                depth += 1;
            } else if is_close(kind) || kind == TokenKind::BlockEnd {
                depth = depth.saturating_sub(1);
            } else if depth == 0 && self.is_dot(scan) && !self.ranges(scan) {
                link = scan;
            }

            scan += 1;
        }

        let Some(open) = self.opened_after(link, end) else {
            return end + 1;
        };

        let Some(close) = self.closing_of(open) else {
            return end + 1;
        };

        let listed = overflowing || self.flat_columns(open + 1, close) > self.policy.call_width;

        if self.capped_list(open, close) && listed {
            return open + 1;
        }

        let Some(brace) = self.braced_after(open, close) else {
            return end + 1;
        };

        if overflowing || self.blocked_over(brace) {
            return brace + 1;
        }

        end + 1
    }

    fn opened_after(&self, link: u32, end: u32) -> Option<u32> {
        let mut scan = link;

        while scan <= end && scan < self.count {
            if is_open(self.tokens[scan as usize].kind) {
                return Some(scan);
            }

            scan += 1;
        }

        None
    }

    fn braced_after(&self, open: u32, close: u32) -> Option<u32> {
        let mut scan = open + 1;

        while scan < close && scan < self.count {
            if self.tokens[scan as usize].kind == TokenKind::BlockStart {
                return Some(scan);
            }

            scan += 1;
        }

        None
    }

    fn capped_list(&self, open: u32, close: u32) -> bool {
        let mut depth = 0_u32;
        let mut scan = open + 1;

        while scan < close && scan < self.count {
            let kind = self.tokens[scan as usize].kind;

            if is_open(kind) || kind == TokenKind::BlockStart {
                depth += 1;
            } else if is_close(kind) || kind == TokenKind::BlockEnd {
                depth = depth.saturating_sub(1);
            } else if depth == 0 && self.commas(scan) {
                return true;
            }

            scan += 1;
        }

        !matches!(
            self.tokens[(open + 1) as usize].text(self.source),
            b"|" | b"||" | b"move"
        )
    }

    fn literal_head(&self, brace: u32) -> bool {
        self.back_of(brace).is_some_and(|held| {
            let token = self.tokens[held as usize];

            matches!(token.kind, TokenKind::Identifier) || matches!(token.text(self.source), b">")
        })
    }

    fn blocked_over(&self, brace: u32) -> bool {
        let Some(close) = self.closing_of(brace) else {
            return true;
        };

        if self.policy.literal_width > 0
            && self.literal_head(brace)
            && self.flat_columns(brace + 1, close) > self.policy.literal_width
        {
            return true;
        }

        if self.next_of(brace).is_some_and(|held| {
            matches!(
                self.tokens[held as usize].text(self.source),
                b"if" | b"for" | b"loop" | b"match" | b"while"
            )
        }) {
            return true;
        }

        let mut depth = 0_u32;
        let mut scan = brace + 1;

        while scan < close && scan < self.count {
            let token = self.tokens[scan as usize];

            if is_open(token.kind) || token.kind == TokenKind::BlockStart {
                depth += 1;
            } else if is_close(token.kind) || token.kind == TokenKind::BlockEnd {
                depth = depth.saturating_sub(1);
            } else if depth == 0
                && (token.kind == TokenKind::Comment
                    || token.kind == TokenKind::Punctuation(Punctuation::Semicolon))
            {
                return true;
            }

            scan += 1;
        }

        false
    }

    fn chained_line(&self, open: u32, close: u32) -> bool {
        if self.policy.chain_width == 0 || !self.policy.block_chains {
            return false;
        }

        let mut scan = open + 1;

        while scan < close {
            if self.is_dot(scan) && !self.ranges(scan) {
                let head = self.chain_head(scan);

                if head > open && self.chained_over(head, scan) {
                    return true;
                }
            }

            scan += 1;
        }

        false
    }

    fn commas(&self, position: u32) -> bool {
        self.tokens[position as usize].kind == TokenKind::Punctuation(Punctuation::Comma)
    }

    pub(super) fn defined(&self, open: u32) -> bool {
        self.worded_head(open, self.policy.define_words)
    }

    fn element_ahead(&self, separator: u32) -> bool {
        let stop = self.frame().close;
        let mut depth = 0_u32;
        let mut scan = separator;

        for _ in 0..DEFINE_SCAN_MAX {
            let Some(held) = self.next_of(scan) else {
                return false;
            };

            if held >= stop || depth == 0 && self.commas(held) {
                return false;
            }

            if self.broke(scan, held) {
                return true;
            }

            if is_open(self.tokens[held as usize].kind) {
                depth += 1;
            }

            if is_close(self.tokens[held as usize].kind) {
                depth = depth.saturating_sub(1);
            }

            scan = held;
        }

        false
    }

    fn element_behind(&self, separator: u32) -> bool {
        let stop = self.frame().open;
        let mut depth = 0_u32;
        let mut scan = separator;

        for _ in 0..DEFINE_SCAN_MAX {
            let Some(held) = self.back_of(scan) else {
                return false;
            };

            if held <= stop || depth == 0 && self.commas(held) {
                return false;
            }

            if self.broke(held, scan) {
                return true;
            }

            if is_close(self.tokens[held as usize].kind) {
                depth += 1;
            }

            if is_open(self.tokens[held as usize].kind) {
                depth = depth.saturating_sub(1);
            }

            scan = held;
        }

        false
    }

    pub(super) fn element_count(&self, open: u32, close: u32) -> u32 {
        let mut count = 1_u32;
        let mut depth = 0_u32;
        let mut scan = open + 1;

        while scan < close {
            let kind = self.tokens[scan as usize].kind;

            if is_open(kind) || kind == TokenKind::BlockStart {
                depth += 1;
            } else if is_close(kind) || kind == TokenKind::BlockEnd {
                depth = depth.saturating_sub(1);
            } else if depth == 0
                && kind == TokenKind::Punctuation(Punctuation::Comma)
                && self.next_of(scan) != Some(close)
            {
                count += 1;
            }

            scan += 1;
        }

        count
    }

    fn element_index(&self, open: u32, position: u32) -> u32 {
        let mut depth = 0_u32;
        let mut index = 0_u32;
        let mut scan = open + 1;

        while scan < position {
            let kind = self.tokens[scan as usize].kind;

            if is_open(kind) || kind == TokenKind::BlockStart {
                depth += 1;
            } else if is_close(kind) || kind == TokenKind::BlockEnd {
                depth = depth.saturating_sub(1);
            } else if depth == 0 && kind == TokenKind::Punctuation(Punctuation::Comma) {
                index += 1;
            }

            scan += 1;
        }

        index
    }

    fn elemental_list(&self, open: u32, close: u32) -> bool {
        let patterned = self
            .next_of(close)
            .is_some_and(|held| self.tokens[held as usize].text(self.source) == b"=>")
            || self
                .word_before(open)
                .and_then(|bang| self.word_before(bang))
                .is_some_and(|name| self.tokens[name as usize].text(self.source) == b"matches");

        let mut depth = 0_u32;
        let mut elements = 1;
        let mut scan = open + 1;

        while scan < close {
            let token = self.tokens[scan as usize];

            if token.kind == TokenKind::Comment
                && (!self.policy.list_remarks || !token.text(self.source).starts_with(b"/*"))
            {
                return false;
            }

            if is_open(token.kind) || token.kind == TokenKind::BlockStart {
                depth += 1;
            } else if is_close(token.kind) || token.kind == TokenKind::BlockEnd {
                depth = depth.saturating_sub(1);
            } else if depth == 0
                && token.text(self.source) == b"|"
                && (patterned || self.lambda_bars(open, scan))
            {
                return false;
            } else if depth == 0
                && token.kind == TokenKind::Punctuation(Punctuation::Comma)
                && self.next_of(scan) != Some(close)
            {
                elements += 1;
            }

            scan += 1;
        }

        elements > 1
    }

    fn extendable(&self, position: u32) -> bool {
        for scan in self.line_first..position {
            let text = self.tokens[scan as usize].text(self.source);

            if !text.is_empty() && !text.iter().all(|byte| EXTENDS.contains(byte)) {
                return false;
            }
        }

        true
    }

    fn filled_list(&self, open: u32) -> bool {
        let Some(close) = self.closing_of(open) else {
            return false;
        };

        if !self.simple_elements(open, close, 0, u32::MAX)
            || !reach::short_elements(self.tokens, open, close)
        {
            return false;
        }

        let from = self.tokens[open as usize].end();
        let to = self.tokens[close as usize].offset;
        let under = (self.printed + 1) * self.options.indent_width;

        under + columns(self.source, from, to) <= self.options.line_width
    }

    pub(super) fn fields_called(&self, first: u32, last: u32) -> bool {
        let mut scan = first;

        for _ in 0..TYPE_SCAN_MAX {
            if self.tokens[scan as usize].kind == TokenKind::Punctuation(Punctuation::ParenOpen) {
                return true;
            }

            if scan == last {
                return false;
            }

            let Some(next) = self.next_of(scan).filter(|held| *held <= last) else {
                return false;
            };

            scan = next;
        }

        false
    }

    pub(super) fn fields_parted(&self, first: u32, last: u32) -> bool {
        let mut depth = 0_u32;
        let mut scan = first;

        loop {
            let kind = self.tokens[scan as usize].kind;

            if kind == TokenKind::Comment || kind == TokenKind::BlockStart && self.fields_wide(scan)
            {
                return true;
            }

            if is_open(kind) || kind == TokenKind::BlockStart {
                depth += 1;
            } else if is_close(kind) || kind == TokenKind::BlockEnd {
                depth = depth.saturating_sub(1);
            } else if depth == 0
                && scan != last
                && kind == TokenKind::Punctuation(Punctuation::Semicolon)
            {
                return true;
            }

            if scan == last {
                return false;
            }

            let Some(next) = self.next_of(scan) else {
                return false;
            };

            scan = next;
        }
    }

    fn fields_span(&self, from: u32, last: u32) -> u32 {
        let mut found = 0;
        let mut scan = from;

        for _ in 0..TYPE_SCAN_MAX {
            found += self.tokens[scan as usize].length;

            if scan == last {
                break;
            }

            let Some(next) = self.next_of(scan).filter(|held| *held <= last) else {
                break;
            };

            found += 1;
            scan = next;
        }

        found
    }

    pub(super) fn fields_width(&self, first: u32, last: u32) -> u32 {
        let whole = self.fields_span(first, last);
        let mut scan = first;

        for _ in 0..TYPE_SCAN_MAX {
            if self.tokens[scan as usize].kind != TokenKind::Identifier {
                return whole;
            }

            let Some(next) = self.next_of(scan).filter(|held| *held <= last) else {
                return whole;
            };

            let token = self.tokens[next as usize];
            let gapped = token.offset > self.tokens[scan as usize].end();

            if gapped {
                if token.text(self.source) == b"|" {
                    return whole;
                }

                return 1 + self.fields_span(next, last);
            }

            if token.kind == TokenKind::Punctuation(Punctuation::ParenOpen) {
                return 5 + self.fields_span(next, last);
            }

            if token.kind != TokenKind::Punctuation(Punctuation::Comma) {
                return whole;
            }

            let Some(held) = self.next_of(next).filter(|found| *found <= last) else {
                return whole;
            };

            scan = held;
        }

        whole
    }

    fn defines(&self, position: u32, previous: u32) -> bool {
        if !self.policy.macro_bodies {
            return false;
        }

        for level in 0..self.depth {
            let frame = self.nest[level as usize];

            if frame.kind != TokenKind::BlockStart {
                continue;
            }

            let Some(body) = self.defined_body(frame.open) else {
                continue;
            };

            let Some(close) = self.closing(body) else {
                continue;
            };

            if self.next_of(body) == Some(close) {
                continue;
            }

            if previous == body || close == position {
                return true;
            }
        }

        false
    }

    pub(super) fn forced(&self, position: u32, previous: u32) -> bool {
        self.branches(position, previous)
            || self.defines(position, previous)
            || self.uses(position, previous)
            || self.let_elses(position, previous)
            || self.attributes(position, previous)
            || self.braces_a_header(position)
            || self.calls(position, previous)
            || self.chains_wide(position)
            || self.members(position, previous)
            || self.literals(position, previous)
            || self.blocks(position, previous)
            || self.rowed(previous)
    }

    pub(super) fn strung(&self, position: u32) -> Option<u32> {
        if !STRING_SPANS || !self.line_start {
            return None;
        }

        let head = self.opened_at(position);
        let from = (self.tokens[position as usize].offset as usize).min(self.source.len());
        let indent = &self.source[head..from];

        if indent.is_empty() || indent.iter().any(|byte| *byte != b' ') {
            return None;
        }

        if self.worded_head(position, self.policy.define_words)
            || self.word_is(position, self.policy.item_words)
            || self.word_is(position, self.policy.body_words)
        {
            return None;
        }

        let end = self.skipped_item(position.saturating_sub(1))?;
        let mut scan = position;

        while scan <= end && scan < self.count {
            if self.tokens[scan as usize].kind == TokenKind::String && self.overran(scan) {
                return Some(end);
            }

            scan += 1;
        }

        None
    }

    fn overran(&self, position: u32) -> bool {
        let token = self.tokens[position as usize];
        let stop = (token.end() as usize).min(self.source.len());
        let mut scan = token.offset as usize;

        while scan < stop {
            if self.source[scan] != b'\n' || scan == 0 || self.source[scan - 1] != b'\\' {
                scan += 1;

                continue;
            }

            let head = scan + 1;
            let mut tail = head;

            while tail < self.source.len() && self.source[tail] != b'\n' {
                tail += 1;
            }

            if columns(self.source, count_of(head), count_of(tail)) > self.options.line_width {
                return true;
            }

            scan = tail;
        }

        false
    }

    pub(super) fn inner_blank(&self, position: u32, previous: u32) -> bool {
        if !INNER_BLANKS || self.depth > 0 {
            return false;
        }

        self.inner_ends(previous) && self.inner_ahead(position)
            || self.inner_opens(position) && self.inner_behind(previous)
    }

    fn inner_ends(&self, position: u32) -> bool {
        self.tokens[position as usize].kind == TokenKind::Punctuation(Punctuation::BracketClose)
            && self
                .brackets
                .open_of(position)
                .is_some_and(|open| self.inner_hashed(open))
    }

    fn inner_opens(&self, position: u32) -> bool {
        let text = self.tokens[position as usize].text(self.source);

        text == b"#!"
            || text == b"#"
                && self
                    .next_of(position)
                    .is_some_and(|held| self.tokens[held as usize].text(self.source) == b"!")
    }

    fn inner_ahead(&self, position: u32) -> bool {
        let mut scan = position;

        for _ in 0..TYPE_SCAN_MAX {
            if self.inner_opens(scan) {
                return true;
            }

            if self.tokens[scan as usize].kind != TokenKind::Comment {
                return false;
            }

            let Some(held) = self.next_of(scan) else {
                return false;
            };

            scan = held;
        }

        false
    }

    fn inner_behind(&self, position: u32) -> bool {
        let mut scan = position;

        for _ in 0..TYPE_SCAN_MAX {
            if self.inner_ends(scan) {
                return true;
            }

            if self.tokens[scan as usize].kind != TokenKind::Comment {
                return false;
            }

            let Some(held) = self.back_of(scan) else {
                return false;
            };

            scan = held;
        }

        false
    }

    fn inner_hashed(&self, open: u32) -> bool {
        let Some(previous) = self.back_of(open) else {
            return false;
        };

        let text = self.tokens[previous as usize].text(self.source);

        text == b"#!"
            || text == b"!"
                && self
                    .back_of(previous)
                    .is_some_and(|held| self.tokens[held as usize].text(self.source) == b"#")
    }

    fn hashed(&self, open: u32) -> bool {
        let Some(previous) = self.back_of(open) else {
            return false;
        };

        let text = self.tokens[previous as usize].text(self.source);

        if text == b"#" || text == b"#!" {
            return true;
        }

        text == b"!"
            && self
                .back_of(previous)
                .is_some_and(|held| self.tokens[held as usize].text(self.source) == b"#")
    }

    fn initialised(&self, open: u32) -> bool {
        if self.bodied(open) {
            return false;
        }

        self.back_of(open)
            .is_some_and(|held| self.is_dot(held) || self.valued_brace(open))
    }

    pub(super) fn invoked(&self) -> bool {
        for level in 0..self.depth {
            let frame = self.nest[level as usize];

            let held = self.back_of(frame.open).is_some_and(|found| {
                self.tokens[found as usize].text(self.source) == b"!"
                    && self.back_of(found).is_some_and(|name| {
                        matches!(
                            self.tokens[name as usize].kind,
                            TokenKind::Identifier | TokenKind::Keyword(_)
                        )
                    })
            });

            if held {
                return true;
            }
        }

        false
    }

    fn juxtaposed(&self, position: u32) -> bool {
        let token = self.tokens[position as usize];

        if !token.ends_a_value() || token.text(self.source) == b"'" {
            return false;
        }

        if matches!(token.kind, TokenKind::Keyword(_)) {
            return false;
        }

        if self
            .back_of(position)
            .is_some_and(|held| self.tokens[held as usize].text(self.source) == b"'")
        {
            return false;
        }

        let Some(next) = self.next_of(position) else {
            return false;
        };

        if self.tokens[next as usize].text(self.source) == b"if" {
            return true;
        }

        matches!(
            self.tokens[next as usize].kind,
            TokenKind::Identifier | TokenKind::Number | TokenKind::String
        ) && self.tokens[next as usize].text(self.source) != b"'"
    }

    pub(super) fn joins_a_value(&self, close: u32) -> bool {
        self.next_of(close).is_some_and(|held| {
            let text = self.tokens[held as usize].text(self.source);

            matches!(self.tokens[held as usize].kind, TokenKind::Punctuation(_))
                || matches!(text, b"else" | b"as")
        })
    }

    fn leads_a_block(&self, open: u32) -> bool {
        let mut depth = 0_u32;
        let mut scan = open;

        for _ in 0..TYPE_SCAN_MAX {
            let Some(held) = self.back_of(scan) else {
                return false;
            };

            let kind = self.tokens[held as usize].kind;

            if is_close(kind) || kind == TokenKind::BlockEnd {
                if depth == 0 && kind == TokenKind::BlockEnd && !self.joins_a_value(held) {
                    return false;
                }

                depth += 1;
            } else if is_open(kind) || kind == TokenKind::BlockStart {
                if depth == 0 {
                    return false;
                }

                depth -= 1;
            } else if depth == 0 {
                if self.word_is(held, self.policy.block_leads) {
                    return true;
                }

                if kind == TokenKind::Punctuation(Punctuation::Semicolon)
                    || self.word_is(held, self.policy.head_stops)
                {
                    return false;
                }
            }

            scan = held;
        }

        false
    }

    fn leading(&self, position: u32) -> u32 {
        let mut offset = self.tokens[position as usize].offset as usize;

        while offset > 0 && self.source[offset - 1] != b'\n' {
            offset -= 1;
        }

        let mut held = offset;

        while held < self.source.len() && matches!(self.source[held], b' ' | b'\t') {
            held += 1;
        }

        count_of(held - offset)
    }

    pub(super) fn listed_wide(&self, open: u32) -> Option<u32> {
        let close = self.closing_of(open)?;

        if !self.listed(close) && !self.macroed(open, close) {
            return None;
        }

        if self.defined(open) || self.braced_line(open) || self.remarked_value(open) {
            return None;
        }

        if self.hugged_wide(open) {
            return Some(open);
        }

        let held = self.sole_call(open);
        let stop = self.closing_of(held)?;
        let measured = if self.policy.call_nests { open } else { held };
        let ends = if self.policy.call_nests { close } else { stop };
        let from = self.tokens[measured as usize].end();
        let to = self.tokens[ends as usize].offset;

        if (SOLE_CHAIN_ALWAYS || self.linked_parted(open, close)) && self.chained_sole(open, close)
        {
            let point = match (self.next_of(open), self.back_of(close)) {
                (Some(first), Some(last)) => {
                    let flat = self.flat_columns(first, last + 1);
                    let over = self.chained_at(first) + flat > self.options.line_width;

                    self.hug_point(first, last, over).min(ends)
                }
                _ => ends,
            };

            return (self.flat_columns(measured + 1, point) > self.policy.call_width)
                .then_some(held);
        }

        let rooted = self
            .next_of(close)
            .is_some_and(|next| self.is_dot(next) && !self.ranges(next));

        let overflowed =
            self.policy.call_budgets && held != open && !rooted && !self.linked_bracket(open);

        let width = columns(self.source, from, to)
            - u32::from(overflowed && self.tailed_comma(measured, ends));

        if self.parted_by(from, to) > 0 || width <= self.policy.call_width {
            return None;
        }

        (overflowed
            || self.elemental_list(held, stop)
            || self.chained_sole(open, close)
            || self.stringed_wide(open, close, rooted))
        .then_some(held)
    }

    fn stringed_wide(&self, open: u32, close: u32, rooted: bool) -> bool {
        if !STRING_SOLES || rooted || self.linked_bracket(open) {
            return false;
        }

        let Some(first) = self.next_of(open).filter(|held| *held < close) else {
            return false;
        };

        if self.tokens[first as usize].kind != TokenKind::String
            || self.next_of(first) != Some(close)
        {
            return false;
        }

        let Some(head) = self.statement_word(open) else {
            return false;
        };

        let end = self.statement_close(close);
        let under = self.printed * self.options.indent_width;

        if self.assigned_value(head, open).is_some_and(|value| {
            self.indent_of(head) + self.options.indent_width + self.flat_columns(value, end + 1)
                <= self.options.line_width
        }) {
            return false;
        }

        under + self.flat_columns(head, end + 1) > self.options.line_width
    }

    fn assigned_value(&self, head: u32, stop: u32) -> Option<u32> {
        let mut depth = 0_u32;
        let mut scan = head;

        while scan < stop {
            let kind = self.tokens[scan as usize].kind;

            if is_open(kind) {
                depth += 1;
            } else if is_close(kind) {
                depth = depth.saturating_sub(1);
            } else if depth == 0 && self.tokens[scan as usize].text(self.source) == b"=" {
                return self.next_of(scan);
            }

            scan += 1;
        }

        None
    }

    fn lambda_barred(&self, open: u32, position: u32) -> bool {
        if !BAR_COMMAS {
            return false;
        }

        let mut depth = 0_u32;
        let mut lambda = false;
        let mut previous: Option<u32> = None;
        let mut scan = open + 1;

        while scan < position && scan < self.count {
            let token = self.tokens[scan as usize];
            let kind = token.kind;
            let opens = previous.is_none_or(|held| !ends_operand(self.tokens[held as usize].kind));

            if depth == 0 && token.text(self.source) == b"|" && (lambda || opens) {
                lambda = !lambda;
            } else if is_open(kind) {
                depth += 1;
            } else if is_close(kind) {
                depth = depth.saturating_sub(1);
            }

            if token.length > 0 {
                previous = Some(scan);
            }

            scan += 1;
        }

        lambda
    }

    fn tailed_comma(&self, open: u32, close: u32) -> bool {
        let mut scan = self.back_of(close);

        for _ in 0..NEST_DEPTH_MAX {
            let Some(held) = scan.filter(|found| *found > open) else {
                return false;
            };

            let kind = self.tokens[held as usize].kind;

            if is_close(kind) || kind == TokenKind::BlockEnd {
                scan = self.back_of(held);

                continue;
            }

            return kind == TokenKind::Punctuation(Punctuation::Comma);
        }

        false
    }

    fn lambda_bars(&self, open: u32, position: u32) -> bool {
        let mut lambda = false;
        let mut previous: Option<u32> = None;

        for scan in (open + 1)..(open + 1 + DEFINE_SCAN_MAX) {
            if scan > position || scan >= self.count {
                return false;
            }

            let token = self.tokens[scan as usize];
            let opens = previous.is_none_or(|held| !ends_operand(self.tokens[held as usize].kind));

            if token.text(self.source) == b"|" && (lambda || opens) {
                if scan == position {
                    return true;
                }

                lambda = !lambda;
            }

            if token.length > 0 {
                previous = Some(scan);
            }
        }

        false
    }

    pub(super) fn linked_bracket(&self, open: u32) -> bool {
        self.back_of(open)
            .and_then(|held| self.back_of(held))
            .is_some_and(|held| self.is_dot(held))
    }

    pub(super) fn hugged_wide(&self, open: u32) -> bool {
        if !HUG_WIDTH || self.policy.call_width == 0 {
            return false;
        }

        let Some(close) = self.closing_of(open) else {
            return false;
        };

        if !self.listed(close) && !self.macroed(open, close) {
            return false;
        }

        if self.defined(open) || self.braced_line(open) || self.remarked_value(open) {
            return false;
        }

        let Some(point) = self.hugged_point(open, close) else {
            return false;
        };

        self.flat_columns(open + 1, point) > self.policy.call_width
    }

    fn hugged_point(&self, open: u32, close: u32) -> Option<u32> {
        let last = self.back_of(close).filter(|held| *held > open)?;

        if self.tokens[last as usize].kind != TokenKind::BlockEnd {
            return None;
        }

        let brace = self.brackets.open_of(last).filter(|held| *held > open)?;
        let head = self.hugged_head(brace, open)?;
        let behind = self.back_of(head)?;

        let separated = behind == open
            || self.tokens[behind as usize].kind == TokenKind::Punctuation(Punctuation::Comma);

        separated.then_some(brace + 1)
    }

    fn hugged_head(&self, brace: u32, open: u32) -> Option<u32> {
        let mut head = brace;
        let Some(before) = self.back_of(brace).filter(|held| *held > open) else {
            return Some(brace);
        };

        let text = self.tokens[before as usize].text(self.source);

        if text == b"||" {
            head = before;
        } else if text == b"|" {
            let mut scan = self.back_of(before)?;

            for _ in 0..TYPE_SCAN_MAX {
                if scan <= open {
                    return None;
                }

                if self.tokens[scan as usize].text(self.source) == b"|" {
                    head = scan;

                    break;
                }

                scan = self.back_of(scan)?;
            }

            if head == brace {
                return None;
            }
        } else {
            return Some(brace);
        }

        match self.back_of(head) {
            Some(found)
                if found > open && self.tokens[found as usize].text(self.source) == b"move" =>
            {
                Some(found)
            }
            _ => Some(head),
        }
    }

    fn linked_parted(&self, open: u32, close: u32) -> bool {
        let mut depth = 0_u32;
        let mut scan = open + 1;

        while scan < close {
            let kind = self.tokens[scan as usize].kind;

            if is_open(kind) || kind == TokenKind::BlockStart {
                depth += 1;
            } else if is_close(kind) || kind == TokenKind::BlockEnd {
                depth = depth.saturating_sub(1);
            } else if depth == 0
                && self.is_dot(scan)
                && self
                    .back_of(scan)
                    .is_some_and(|held| self.parts_at(held, scan))
            {
                return true;
            }

            scan += 1;
        }

        false
    }

    pub(super) fn flat_columns(&self, from: u32, to: u32) -> u32 {
        let mut previous: Option<u32> = None;
        let mut scan = from;
        let mut spelled = 0;

        while scan < to && scan < self.count {
            let token = self.tokens[scan as usize];

            if token.length == 0
                || token.kind == TokenKind::Newline
                || FLAT_WELDS && self.commas(scan) && self.closes_after(scan, to)
            {
                scan += 1;

                continue;
            }

            let gapped = previous.is_some_and(|before| {
                let welded = FLAT_WELDS && self.tight_pair(before, scan);

                self.tokens[before as usize].end() < token.offset
                    && !self.is_dot(scan)
                    && !self.is_dot(before)
                    && !welded
            });

            spelled += u32::from(gapped) + columns(self.source, token.offset, token.end());
            previous = Some(scan);
            scan += 1;
        }

        spelled
    }

    fn closes_after(&self, scan: u32, to: u32) -> bool {
        let mut ahead = scan + 1;

        while ahead < to && ahead < self.count {
            let token = self.tokens[ahead as usize];

            if token.length == 0 || token.kind == TokenKind::Newline {
                ahead += 1;

                continue;
            }

            return is_close(token.kind) || token.kind == TokenKind::BlockEnd;
        }

        true
    }

    fn tight_pair(&self, before: u32, scan: u32) -> bool {
        let held = self.tokens[before as usize];
        let token = self.tokens[scan as usize];

        let bracketed = |kind| {
            matches!(
                kind,
                TokenKind::Punctuation(Punctuation::ParenOpen | Punctuation::BracketOpen)
            )
        };

        let closes = matches!(
            token.kind,
            TokenKind::Punctuation(Punctuation::ParenClose | Punctuation::BracketClose)
        );

        let called = bracketed(token.kind)
            && (held.kind == TokenKind::Identifier
                || is_close(held.kind)
                || held.text(self.source) == b"!");

        bracketed(held.kind) || closes || called
    }

    pub(super) fn callee_columns(&self, open: u32) -> u32 {
        let mut head = open;
        let mut scan = open;

        for _ in 0..TYPE_SCAN_MAX {
            let Some(back) = self.back_of(scan) else {
                break;
            };

            let text = self.tokens[back as usize].text(self.source);

            let named = text == b"::"
                || text == b"!"
                || !text.is_empty()
                    && text
                        .iter()
                        .all(|byte| byte.is_ascii_alphanumeric() || *byte == b'_');

            if !named {
                break;
            }

            head = back;
            scan = back;
        }

        if head == open {
            return 0;
        }

        columns(
            self.source,
            self.tokens[head as usize].offset,
            self.tokens[open as usize].offset,
        )
    }

    fn chained_sole(&self, open: u32, close: u32) -> bool {
        if !self.policy.chain_soles || self.callee_columns(open) < self.options.indent_width {
            return false;
        }

        let (Some(first), Some(last)) = (self.operand_of(open), self.back_of(close)) else {
            return false;
        };

        let mut depth = 0_u32;
        let mut scan = open + 1;

        while scan < close {
            let kind = self.tokens[scan as usize].kind;

            if is_open(kind) || kind == TokenKind::BlockStart {
                depth += 1;
            } else if is_close(kind) || kind == TokenKind::BlockEnd {
                depth = depth.saturating_sub(1);
            } else if depth == 0 && self.is_dot(scan) && !self.ranges(scan) {
                let head = self.chain_head(scan);
                let (end, links, _) = self.chain_end(head);

                return head == first && end == last && links >= 2;
            }

            scan += 1;
        }

        false
    }

    fn literal_after(&self, position: u32) -> bool {
        let Some(held) = self.next_of(position) else {
            return false;
        };

        let token = self.tokens[held as usize];

        let literal = matches!(token.kind, TokenKind::Number | TokenKind::String)
            || matches!(token.text(self.source), b"true" | b"false");

        let ends = self.next_of(held).is_none_or(|found| {
            matches!(
                self.tokens[found as usize].kind,
                TokenKind::Punctuation(Punctuation::Comma | Punctuation::ParenClose)
            )
        });

        literal && ends
    }

    pub(super) fn literal_wide(&self, open: u32) -> bool {
        if !self.valued_brace(open)
            || self.braced_line(open)
            || self.invoked()
            || self.remarked_value(open)
            || self.attribute_head().is_some()
        {
            return false;
        }

        let Some(close) = self.closing(open) else {
            return false;
        };

        let Some(first) = self.next_of(open) else {
            return false;
        };

        if first == close {
            return false;
        }

        let last = self.back_of(close).unwrap_or(first);
        let from = self.tokens[first as usize].offset;
        let to = self.tokens[last as usize].end();

        self.parted_by(from, to) == 0 && columns(self.source, from, to) > self.literal_bound(open)
    }

    pub(super) fn literals(&self, position: u32, previous: u32) -> bool {
        if self.policy.literal_width == 0 {
            return false;
        }

        let separated =
            self.tokens[previous as usize].kind == TokenKind::Punctuation(Punctuation::Comma);

        for level in 0..self.depth {
            let frame = self.nest[level as usize];

            if frame.kind != TokenKind::BlockStart || !self.literal_wide(frame.open) {
                continue;
            }

            if previous == frame.open || self.closing(frame.open) == Some(position) {
                return true;
            }

            if separated && self.frame().open == frame.open {
                return true;
            }
        }

        false
    }

    fn macro_broken(&self, open: u32, previous: u32) -> bool {
        let Some(close) = self.closing_of(open) else {
            return true;
        };

        let Some(name) = self
            .word_before(open)
            .filter(|bang| {
                self.tokens[*bang as usize].kind == TokenKind::Punctuation(Punctuation::Bang)
            })
            .and_then(|bang| self.word_before(bang))
        else {
            return true;
        };

        let Some(group) = self.macro_group(name) else {
            return !self.simple_elements(open, close, 0, u32::MAX)
                || !reach::short_elements(self.tokens, open, close);
        };

        let count = self.element_count(open, close);

        let special = count > group
            && self.simple_elements(open, close, 0, group)
            && self.simple_elements(open, close, group + 1, u32::MAX);

        !special || self.element_index(open, previous) <= group
    }

    fn macro_group(&self, name: u32) -> Option<u32> {
        let text = self.tokens[name as usize].text(self.source);

        for (word, held) in MACRO_GROUPS {
            if text == *word {
                return Some(*held);
            }
        }

        None
    }

    fn macroed(&self, open: u32, close: u32) -> bool {
        if !self.policy.macro_spans {
            return false;
        }

        let Some(bang) = self.word_before(open) else {
            return false;
        };

        if self.tokens[bang as usize].kind != TokenKind::Punctuation(Punctuation::Bang) {
            return false;
        }

        let Some(name) = self.word_before(bang) else {
            return false;
        };

        if !matches!(
            self.tokens[name as usize].kind,
            TokenKind::Identifier | TokenKind::Keyword(_)
        ) {
            return false;
        }

        !self.streamed(open, close)
    }

    fn members(&self, position: u32, previous: u32) -> bool {
        if self.policy.field_width == 0 {
            return false;
        }

        let separated = self.back_of(position).is_some_and(|held| {
            self.tokens[held as usize].kind == TokenKind::Punctuation(Punctuation::Semicolon)
        });

        for level in 0..self.depth {
            let frame = self.nest[level as usize];

            if frame.kind != TokenKind::BlockStart || !self.fields_wide(frame.open) {
                continue;
            }

            if previous == frame.open || self.closing(frame.open) == Some(position) {
                return true;
            }

            if separated && self.frame().open == frame.open {
                return true;
            }
        }

        false
    }

    fn metaed(&self, open: u32, close: u32) -> bool {
        let mut elements = 1;
        let mut depth = 0_u32;
        let mut scan = open + 1;

        while scan < close {
            let token = self.tokens[scan as usize];

            if token.kind == TokenKind::Comment {
                return false;
            }

            if is_open(token.kind) || token.kind == TokenKind::BlockStart {
                depth += 1;
            } else if is_close(token.kind) || token.kind == TokenKind::BlockEnd {
                depth = depth.saturating_sub(1);
            } else if depth == 0
                && token.kind == TokenKind::Punctuation(Punctuation::Comma)
                && self.next_of(scan) != Some(close)
            {
                elements += 1;
            } else if token.text(self.source) == b"=" && !self.literal_after(scan) {
                return false;
            }

            scan += 1;
        }

        elements > 1
    }

    pub(super) fn named(&self, position: u32) -> bool {
        if self.tokens[position as usize].kind != TokenKind::Identifier {
            return false;
        }

        let reached = self
            .word_before(position)
            .is_some_and(|held| self.is_dot(held));

        reached || !self.word_is(position, self.policy.group_words)
    }

    pub(super) fn objected(&self, before: u32, held: Token) -> bool {
        if matches!(
            held.kind,
            TokenKind::Keyword(Keyword::Return)
                | TokenKind::Punctuation(
                    Punctuation::Assign
                        | Punctuation::BracketOpen
                        | Punctuation::Colon
                        | Punctuation::Comma
                        | Punctuation::ParenOpen
                )
        ) {
            return true;
        }

        if self.policy.ternary_colon && held.text(self.source) == b"?" {
            return true;
        }

        held.kind == TokenKind::Identifier
            && self
                .word_before(before)
                .is_some_and(|word| self.word_is(word, self.policy.value_words))
    }

    fn received(&self, held: u32, scan: u32) -> bool {
        if self.tokens[held as usize].text(self.source) == b"!" {
            return is_open(self.tokens[scan as usize].kind);
        }

        self.receives(held)
    }

    fn receives(&self, position: u32) -> bool {
        let kind = self.tokens[position as usize].kind;
        let text = self.tokens[position as usize].text(self.source);

        if matches!(kind, TokenKind::Keyword(_)) {
            return matches!(text, b"self" | b"Self" | b"super" | b"crate");
        }

        matches!(
            kind,
            TokenKind::Identifier | TokenKind::Number | TokenKind::String
        ) || matches!(text, b"." | b"::" | b"?" | b"!")
    }

    fn rooted(&self, head: u32, position: u32) -> bool {
        if self.next_of(head) != Some(position) {
            return false;
        }

        let braced = ROOT_TOKEN_WIDTH
            && self
                .back_of(head)
                .is_some_and(|held| self.tokens[held as usize].kind == TokenKind::BlockStart);

        if braced {
            let token = self.tokens[head as usize];

            return columns(self.source, token.offset, token.end()) <= self.options.indent_width;
        }

        let indent = self.column_of(head);
        let width = self.tokens[head as usize].length;
        let room = self
            .options
            .indent_width
            .saturating_sub(indent - self.leading(head));

        width <= room
    }

    fn rowed(&self, separator: u32) -> bool {
        if !self.policy.row_parts
            || self.tokens[separator as usize].kind != TokenKind::Punctuation(Punctuation::Comma)
        {
            return false;
        }

        let frame = self.frame();

        if frame.kind != TokenKind::BlockStart || !self.initialised(frame.open) {
            return false;
        }

        if self
            .next_of(separator)
            .is_some_and(|held| self.tokens[held as usize].kind == TokenKind::Comment)
        {
            return false;
        }

        let magic = self
            .back_of(frame.close)
            .is_some_and(|held| held != separator && self.commas(held));

        magic && (self.element_ahead(separator) || self.element_behind(separator))
    }

    fn simple_elements(&self, open: u32, close: u32, first: u32, last: u32) -> bool {
        let mut index = 0_u32;
        let mut depth = 0_u32;
        let mut scan = open + 1;

        while scan < close {
            let token = self.tokens[scan as usize];
            let kind = token.kind;

            if depth == 0 && kind == TokenKind::Punctuation(Punctuation::Comma) {
                index += 1;
            } else if index >= first && index < last && !simple_word(token, self.source) {
                return false;
            }

            if is_open(kind) || kind == TokenKind::BlockStart {
                depth += 1;
            } else if is_close(kind) || kind == TokenKind::BlockEnd {
                depth = depth.saturating_sub(1);
            }

            scan += 1;
        }

        true
    }

    fn sole_call(&self, open: u32) -> u32 {
        let mut budget = self.policy.call_width;
        let mut held = open;

        for _ in 0..NEST_DEPTH_MAX {
            let Some(inner) = self.sole_inner(held) else {
                return held;
            };

            let width = self.callee_columns(inner) + 2;

            if !self.policy.call_budgets {
                held = inner;

                continue;
            }

            if width > budget {
                return held;
            }

            budget -= width;
            held = inner;
        }

        held
    }

    fn operand_of(&self, open: u32) -> Option<u32> {
        let mut scan = self.next_of(open)?;

        for _ in 0..UNARY_WALK_MAX {
            if !matches!(
                self.tokens[scan as usize].text(self.source),
                b"!" | b"&" | b"&&" | b"*"
            ) {
                return Some(scan);
            }

            scan = self.next_of(scan)?;
        }

        Some(scan)
    }

    pub(super) fn sole_inner(&self, open: u32) -> Option<u32> {
        let close = self.closing_of(open)?;
        let steps = if self.policy.call_nests {
            TYPE_SCAN_MAX
        } else {
            1
        };

        let mut scan = self.operand_of(open)?;

        for _ in 0..steps {
            let token = self.tokens[scan as usize];
            let text = token.text(self.source);

            let named = matches!(text, b"::" | b"!")
                || !text.is_empty()
                    && text
                        .iter()
                        .all(|byte| byte.is_ascii_alphanumeric() || *byte == b'_');

            if !named {
                return None;
            }

            scan = self.next_of(scan)?;

            if self.tokens[scan as usize].kind == TokenKind::Punctuation(Punctuation::ParenOpen) {
                return (self.closing_of(scan) == self.back_of(close)).then_some(scan);
            }
        }

        None
    }

    pub(super) fn streamed(&self, open: u32, close: u32) -> bool {
        let mut blocks = 0_u32;
        let mut depth = 0_u32;
        let mut lambda = false;
        let mut previous: Option<u32> = None;
        let mut scan = open + 1;

        while scan < close {
            let token = self.tokens[scan as usize];
            let kind = token.kind;
            let text = token.text(self.source);
            let opens = previous.is_none_or(|held| !ends_operand(self.tokens[held as usize].kind));

            if text == b"|" && (lambda || opens) {
                lambda = !lambda;
                previous = Some(scan);
                scan += 1;

                continue;
            }

            let punctuated = kind == TokenKind::Punctuation(Punctuation::Arrow)
                || matches!(text, b":" | b"=>" | b"@");

            let separated = kind == TokenKind::Punctuation(Punctuation::Semicolon);

            if !lambda && depth == 0 && (separated || punctuated) {
                return true;
            }

            if is_open(kind) || kind == TokenKind::BlockStart {
                depth += 1;
                blocks += u32::from(kind == TokenKind::BlockStart);
            } else if is_close(kind) || kind == TokenKind::BlockEnd {
                depth = depth.saturating_sub(1);
                blocks = blocks.saturating_sub(u32::from(kind == TokenKind::BlockEnd));
            }

            if !lambda && (!MACRO_BLOCKS || blocks == 0) && self.juxtaposed(scan) {
                return true;
            }

            if token.length > 0 {
                previous = Some(scan);
            }

            scan += 1;
        }

        false
    }

    pub(super) fn tupled(&self, open: u32, close: u32) -> bool {
        if self.policy.call_width == 0
            || self.tokens[open as usize].kind != TokenKind::Punctuation(Punctuation::ParenOpen)
        {
            return false;
        }

        let banged = self.word_before(open).is_some_and(|held| {
            self.tokens[held as usize].kind == TokenKind::Punctuation(Punctuation::Bang)
        });

        let bound = self.next_of(close).is_some_and(|held| {
            matches!(
                self.tokens[held as usize].text(self.source),
                b"=" | b"=>" | b"in"
            )
        });

        !banged && !bound && self.element_count(open, close) > 1
    }

    pub(super) fn valued_brace(&self, open: u32) -> bool {
        let Some(previous) = self.back_of(open) else {
            return false;
        };

        let kind = self.tokens[previous as usize].kind;
        let text = self.tokens[previous as usize].text(self.source);
        let named = kind == TokenKind::Identifier || text == b"Self";

        named && !self.leads_a_block(open)
    }
}
