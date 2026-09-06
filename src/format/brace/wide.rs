use super::{DEFINE_SCAN_MAX, Emitter, MACRO_GROUPS, NEST_DEPTH_MAX, ROLE_SPACED, TYPE_SCAN_MAX};
use crate::bounded::count_of;
use crate::format::reach;
use crate::format::walk::{columns, ends_operand, is_close, is_open, simple_word};
use crate::token::{Keyword, Punctuation, Token, TokenKind};

const EXTENDS: &[u8] = b"()]}?>";
const ROOT_TOKEN_WIDTH: bool = true;
const UNARY_WALK_MAX: u32 = 4;
const OBJECT_OPERANDS: bool = true;
const VARIANT_BREAKS: bool = true;
const VARIANT_SCAN_MAX: u32 = 2048;
const BLOCK_WORDS: &[&[u8]] = &[b"async", b"const", b"gen", b"move", b"try", b"unsafe"];
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
const ARRAY_MACROS: bool = true;
const BINDING_PATTERNS: [&[u8]; 3] = [b"const", b"let", b"var"];
const CHAIN_GROUPS: bool = true;
const CHAIN_VERTICALS: bool = true;
const LAMBDA_COMMAS: bool = true;
const CHAIN_ROOT_LINES: bool = true;
const CHAIN_METAS: bool = true;
const TRIED_LISTS: bool = true;
const TRIED_ROOM: u32 = 2;
const RETURN_LISTS: bool = true;
const RETURN_ROOM: u32 = 1;
const TRIED_ITEMS: u32 = 2;
const MATCH_LISTS: bool = true;
const HUG_POINTS: bool = true;
const MACRO_BODIES: bool = true;
const MACRO_ARMS: &[&[u8]] = &[b"match"];
const ROOT_SEATS: bool = true;
const SPAN_NESTS: bool = true;
const CHAIN_INDENTS: bool = true;
const CHAIN_MARGINS: bool = true;
const LITERAL_MACROS: bool = true;
const ARM_VALUES: bool = true;
const TURBO_FISH: bool = true;
const HUG_BUDGETS: bool = true;
const LIST_BREAKS: bool = true;
const CHAIN_WRITES: bool = true;
const LAMBDA_SOLES: bool = true;
const LAMBDA_HEADS: bool = true;
const RETURN_TUPLES: bool = true;
pub(super) const RETURN_BLOCKS: bool = true;
pub(super) const MACRO_COMMAS: bool = true;
const BRANCH_LASTS: bool = true;
const BRANCH_LAST_WORDS: &[&[u8]] = &[b"for", b"if", b"loop", b"match", b"while"];
const COMMA_WIDTHS: bool = true;
const SOLE_BRACKETS: bool = true;
const MACRO_FRAMES: bool = true;
const QUAL_HEADS: bool = true;
const PATTERN_WIDTHS: bool = true;
const HEAD_ATTRS: bool = true;
const CHAIN_SOLE_ROOTS: bool = true;
const ROOT_FLATS: bool = true;
const LINK_WIDES: bool = true;
const DEFINE_WIDES: bool = true;
const HEADER_WIDES: bool = true;
const HUG_LINED: bool = true;
const LIST_LINED: bool = true;
const LAMBDA_LISTS: bool = true;
const MACRO_ASSIGNS: bool = true;
const MACRO_LEVELS: bool = true;
const SOLE_LINKS: bool = true;
const CHAIN_AWAITS: bool = true;
const MACRO_LEVEL_MAX: u32 = 63;
const UNARY_MUTS: bool = true;
pub(super) const MACRO_STREAMS: bool = true;
const ELSE_JOINS: bool = true;
const ELSE_MARGIN: u32 = 7;
const ELSE_PARTS: bool = true;
const CHAIN_TRIES: bool = true;
const CHAIN_ROOMS: bool = true;
const CHAIN_HEADS: bool = true;
const CHAIN_ANGLES: bool = true;
const CHAIN_WORDS: bool = true;
const ANGLE_COMMAS: bool = true;
const TUPLE_DEFINES: bool = true;
const TUPLE_WORDS: &[&[u8]] = &[b"enum", b"struct", b"union"];
const HUG_HEADS: &[&[u8]] = &[b"async", b"const", b"gen", b"move", b"try", b"unsafe"];

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
                    let front = self.back_of(held);

                    if front.is_some_and(|at| self.tokens[at as usize].text(self.source) == b"::") {
                        return front;
                    }

                    let qualified =
                        front.is_none_or(|at| !ends_operand(self.tokens[at as usize].kind));

                    return (QUAL_HEADS && qualified).then_some(held);
                }
            }

            scan = held;
        }

        None
    }

    pub(super) fn attribute_head(&self) -> Option<u32> {
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

    pub(super) fn blocks_wide(&self, open: u32) -> bool {
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

        if self.chained_line(open, close)
            || self.branched_line(open, close)
            || self.hugged_over(open, close)
        {
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

    fn hugged_call(&self, open: u32) -> bool {
        if !HUG_BUDGETS {
            return false;
        }

        let Some(close) = self.closing_of(open) else {
            return false;
        };

        let Some(point) = self.hugged_point(open, close) else {
            return false;
        };

        self.flat_columns(open + 1, point) <= self.lambda_room(open, point - 1)
    }

    pub(super) fn hugged_over(&self, brace: u32, close: u32) -> bool {
        if !HUG_BUDGETS || self.policy.call_width == 0 {
            return false;
        }

        let Some(end) = self.next_of(close).map(|held| {
            if self.tokens[held as usize].kind == TokenKind::Punctuation(Punctuation::Comma) {
                self.next_of(held).unwrap_or(held)
            } else {
                held
            }
        }) else {
            return false;
        };

        if !is_close(self.tokens[end as usize].kind)
            || self.tokens[end as usize].kind == TokenKind::BlockEnd
        {
            return false;
        }

        let Some(open) = self.brackets.open_of(end).filter(|held| *held < brace) else {
            return false;
        };

        let Some(head) = self.hugged_head(brace, open).filter(|held| *held > open) else {
            return false;
        };

        let Some(stop) = self.closing_of(open) else {
            return false;
        };

        let spread = self.parted_by(
            self.tokens[open as usize].end(),
            self.tokens[brace as usize].offset,
        );

        if spread > 0 || !self.elemental_list(open, stop) {
            return false;
        }

        let offset = self.flat_columns(open + 1, head) + 1;
        let stub = self.flat_columns(open + 1, brace + 1);

        if stub > self.lambda_room(open, brace) {
            return false;
        }

        let width = self.flat_columns(head, close + 1);

        offset < self.policy.call_width && width > self.policy.call_width - offset
    }

    fn literal_bound(&self, open: u32) -> u32 {
        let Some(brace) = self.varied_brace(open) else {
            return self.policy.literal_width;
        };

        if VARIANT_BREAKS && self.variant_parted(brace) {
            return 0;
        }

        self.policy.variant_width
    }

    fn variant_parted(&self, brace: u32) -> bool {
        let Some(end) = self.closing_of(brace) else {
            return false;
        };

        let mut depth = 0_u32;
        let mut lined = false;
        let mut parted = false;
        let mut start = brace + 1;

        for scan in (brace + 1..end).take(VARIANT_SCAN_MAX as usize) {
            let kind = self.tokens[scan as usize].kind;

            if is_open(kind) || kind == TokenKind::BlockStart {
                depth += 1;
            } else if is_close(kind) || kind == TokenKind::BlockEnd {
                depth = depth.saturating_sub(1);
            } else if depth == 0 && kind == TokenKind::Punctuation(Punctuation::Comma) {
                self.variant_read(start, scan, &mut lined, &mut parted);

                start = scan + 1;
            }
        }

        self.variant_read(start, end, &mut lined, &mut parted);

        lined && parted
    }

    fn variant_read(&self, from: u32, to: u32, lined: &mut bool, parted: &mut bool) {
        let mut held = from;

        while held < to && self.tokens[held as usize].length == 0 {
            held += 1;
        }

        if held >= to {
            return;
        }

        let text = self.tokens[held as usize].text(self.source);

        let marked = text == b"#"
            || self.tokens[held as usize].kind == TokenKind::Comment
                && (text.starts_with(b"///") || text.starts_with(b"//!"));

        let mut wide = false;
        let mut scan = held;

        while scan < to {
            if self.tokens[scan as usize].kind == TokenKind::BlockStart {
                let Some(close) = self.closing_of(scan).filter(|found| *found < to) else {
                    break;
                };

                let (Some(first), Some(last)) = (self.next_of(scan), self.back_of(close)) else {
                    break;
                };

                wide |=
                    first <= last && self.flat_columns(first, last + 1) > self.policy.variant_width;
                scan = close;
            }

            scan += 1;
        }

        if marked || wide {
            *parted = true;
        } else {
            *lined = true;
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

            let (Some(first), Some(last)) = (self.next_of(open), self.back_of(close)) else {
                return false;
            };

            let (from, to) = if LIST_BREAKS && first <= last {
                (
                    self.tokens[first as usize].offset,
                    self.tokens[last as usize].end(),
                )
            } else {
                (
                    self.tokens[open as usize].end(),
                    self.tokens[close as usize].offset,
                )
            };

            return columns(self.source, from, to) > self.literal_bound(open);
        }

        if !self.listed(close) {
            return false;
        }

        let held = self.sole_call(open);

        let Some(stop) = self.closing_of(held) else {
            return false;
        };

        let nested = SPAN_NESTS && self.policy.call_nests;
        let measured = if nested { open } else { held };
        let ends = if nested { close } else { stop };
        let from = self.tokens[measured as usize].end();
        let to = self.tokens[ends as usize].offset;

        columns(self.source, from, to) > self.policy.call_width && self.elemental_list(held, stop)
    }

    fn braced_line(&self, position: u32) -> bool {
        let mut depth = 0_u32;
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

            let kind = self.tokens[held as usize].kind;

            if CHAIN_GROUPS && (is_close(kind) || kind == TokenKind::BlockEnd) {
                depth += 1;
            } else if kind == TokenKind::BlockStart && depth == 0 {
                return !self.fields_wide(held)
                    && !self.literal_wide(held)
                    && !self.branched_wide(held)
                    && !self.blocks_wide(held);
            } else if CHAIN_GROUPS && depth > 0 && (is_open(kind) || kind == TokenKind::BlockStart)
            {
                depth -= 1;
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

    pub(super) fn header_wided(&self, position: u32) -> bool {
        if !HEADER_WIDES
            || !self.policy.header_widths
            || self.tokens[position as usize].kind != TokenKind::BlockStart
        {
            return false;
        }

        let Some(head) = self.head_word(position, self.policy.header_words) else {
            return false;
        };

        if self.line_first > head {
            return false;
        }

        for scan in head..position {
            if matches!(
                self.tokens[scan as usize].kind,
                TokenKind::BlockEnd | TokenKind::BlockStart
            ) {
                return false;
            }
        }

        self.header_width(head, position).is_some_and(|width| {
            self.printed * self.options.indent_width + width > self.options.line_width
        })
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

    pub(super) fn branch_head(&self, open: u32) -> Option<u32> {
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
            ) || ARM_VALUES && token.text(self.source) == b"=>"
            {
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

    pub(super) fn else_joined(&self, position: u32) -> bool {
        if !ELSE_JOINS
            || self.policy.else_width == 0
            || self.tokens[position as usize].text(self.source) != b"else"
        {
            return false;
        }

        let Some(open) = self
            .next_of(position)
            .filter(|held| self.tokens[*held as usize].kind == TokenKind::BlockStart)
        else {
            return false;
        };

        let Some(head) = self
            .statement_word(position)
            .filter(|held| *held < position)
        else {
            return false;
        };

        if self.tokens[head as usize].text(self.source) != b"let"
            || self.else_wide(open)
            || self.line_first > head
        {
            return false;
        }

        let under = (self.printed + 1) * self.options.indent_width;
        let width = self.flat_columns(self.line_first, position);

        self.options.line_width.saturating_sub(under + width) >= ELSE_MARGIN
    }

    pub(super) fn else_parted(&self, position: u32) -> bool {
        if !ELSE_PARTS
            || self.policy.else_width == 0
            || self.tokens[position as usize].text(self.source) != b"else"
        {
            return false;
        }

        if self
            .next_of(position)
            .is_none_or(|held| self.tokens[held as usize].kind != TokenKind::BlockStart)
        {
            return false;
        }

        if self
            .back_of(position)
            .is_none_or(|held| self.tokens[held as usize].kind == TokenKind::BlockEnd)
        {
            return false;
        }

        let Some(head) = self.statement_word(position).filter(|held| {
            *held < position && self.tokens[*held as usize].text(self.source) == b"let"
        }) else {
            return false;
        };

        if self.line_first <= head {
            return false;
        }

        if self
            .else_assign(head, position)
            .and_then(|assign| self.line_lead(assign))
            .is_some_and(|(first, _)| first > head)
        {
            return true;
        }

        if self
            .line_lead(head)
            .is_some_and(|(_, level)| self.printed > level)
        {
            return true;
        }

        self.back_of(position)
            .is_none_or(|held| !is_close(self.tokens[held as usize].kind))
    }

    fn else_assign(&self, head: u32, stop: u32) -> Option<u32> {
        let mut depth = 0_u32;
        let mut scan = head;

        for _ in 0..DEFINE_SCAN_MAX {
            if scan >= stop {
                return None;
            }

            let kind = self.tokens[scan as usize].kind;

            if is_open(kind) || kind == TokenKind::BlockStart {
                depth += 1;
            } else if is_close(kind) || kind == TokenKind::BlockEnd {
                depth = depth.saturating_sub(1);
            } else if depth == 0 && kind == TokenKind::Punctuation(Punctuation::Assign) {
                return Some(scan);
            }

            scan = self.next_of(scan)?;
        }

        None
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

    fn tried_over(&self, open: u32, close: u32) -> bool {
        if !TRIED_LISTS {
            return false;
        }

        let Some(head) = self.statement_word(open).filter(|held| *held < open) else {
            return false;
        };

        let Some(end) = self.tried_end(close) else {
            return false;
        };

        if !self.chained_between(head, close) || self.element_count(open, close) < TRIED_ITEMS {
            return false;
        }

        let under = self.printed * self.options.indent_width;
        let flat = under + self.flat_columns(head, end + 1);

        flat <= self.options.line_width && flat + TRIED_ROOM > self.options.line_width
    }

    fn branched_last(&self, open: u32, close: u32) -> bool {
        if !BRANCH_LASTS || self.element_count(open, close) < 2 || self.macroed(open, close) {
            return false;
        }

        let Some(last) = self.listed_last(open, close) else {
            return false;
        };

        if !BRANCH_LAST_WORDS.contains(&self.tokens[last as usize].text(self.source)) {
            return false;
        }

        let Some(stop) = self.back_of(close).filter(|held| *held > last) else {
            return false;
        };

        if self.tokens[last as usize].text(self.source) != b"if" || !self.elsed(last, stop) {
            return true;
        }

        self.flat_columns(last, stop + 1) > self.policy.else_width
    }

    fn elsed(&self, from: u32, stop: u32) -> bool {
        let mut depth = 0_u32;
        let mut scan = from;

        while scan <= stop && scan < self.count {
            let kind = self.tokens[scan as usize].kind;

            if is_open(kind) || kind == TokenKind::BlockStart {
                depth += 1;
            } else if is_close(kind) || kind == TokenKind::BlockEnd {
                depth = depth.saturating_sub(1);
            } else if depth == 0 && self.tokens[scan as usize].text(self.source) == b"else" {
                return true;
            }

            scan += 1;
        }

        false
    }

    fn sole_called(&self, open: u32) -> bool {
        let Some(first) = self.operand_of(open) else {
            return false;
        };

        let mut scan = first;

        for _ in 0..TYPE_SCAN_MAX {
            let token = self.tokens[scan as usize];

            if token.kind == TokenKind::Punctuation(Punctuation::ParenOpen) {
                return true;
            }

            if !matches!(token.kind, TokenKind::Identifier | TokenKind::Keyword(_))
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

    pub(super) fn returned_over(&self, open: u32, close: u32) -> bool {
        if !RETURN_LISTS {
            return false;
        }

        let Some(head) = self.statement_word(open).filter(|held| *held < open) else {
            return false;
        };

        if self.tokens[head as usize].text(self.source) != b"return" {
            return false;
        }

        if self.element_count(open, close) != 1 || self.sole_called(open) {
            return false;
        }

        if self.operand_of(open).is_some_and(|first| {
            matches!(
                self.tokens[first as usize].text(self.source),
                b"|" | b"||" | b"move"
            )
        }) {
            return false;
        }

        let end = self.statement_close(close);
        let flat = self.indent_of(head) + self.flat_columns(head, end + 1);

        flat <= self.options.line_width && flat + RETURN_ROOM > self.options.line_width
    }

    fn tried_end(&self, close: u32) -> Option<u32> {
        let mut scan = self.next_of(close)?;
        let mut tried = false;

        for _ in 0..TYPE_SCAN_MAX {
            let text = self.tokens[scan as usize].text(self.source);

            if text == b"?" {
                tried = true;
            } else if text == b";" {
                return tried.then_some(scan);
            } else {
                return None;
            }

            scan = self.next_of(scan)?;
        }

        None
    }

    fn chained_between(&self, head: u32, close: u32) -> bool {
        let mut depth = 0_u32;
        let mut scan = head;

        while scan < close {
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

        let separated = self.tokens[previous as usize].kind
            == TokenKind::Punctuation(Punctuation::Comma)
            && !(ANGLE_COMMAS && self.angle_head(previous).is_some());

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
                })
                || self.hugged_call(open);

            if !hugged && self.closing_of(open) == Some(position) {
                return true;
            }

            if separated
                && self.frame().open == open
                && !self.lambda_barred(open, previous)
                && !self.filled_list(frame.open)
            {
                let held = if MACRO_FRAMES { open } else { frame.open };

                return self.macro_broken(held, previous);
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
            let worded = self
                .back_of(scan)
                .is_some_and(|held| held >= head && self.block_worded(held, scan));

            let body = kind == TokenKind::BlockStart && !self.initialised(scan) && !worded;

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

                let indexed = opened == TokenKind::Punctuation(Punctuation::BracketOpen)
                    && !(CHAIN_ANGLES && angles > 0);

                if depth == 0 && indexed {
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
                if self.block_worded(held, scan) {
                    scan = held;

                    continue;
                }

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

    fn block_worded(&self, held: u32, scan: u32) -> bool {
        if !CHAIN_WORDS || !BLOCK_WORDS.contains(&self.tokens[held as usize].text(self.source)) {
            return false;
        }

        self.tokens[scan as usize].kind == TokenKind::BlockStart
            || BLOCK_WORDS.contains(&self.tokens[scan as usize].text(self.source))
    }

    fn chained_by(&self, position: u32, angles: &mut u32) -> bool {
        let text = self.tokens[position as usize].text(self.source);

        if let Some(next) = self.next_of(position) {
            if self.block_worded(position, next) {
                return true;
            }
        }

        if let Some(found) = self.angle_count(position, b'>').filter(|_| *angles > 0) {
            *angles = angles.saturating_sub(found);

            return true;
        }

        if let Some(found) = self.angle_count(position, b'<').filter(|_| *angles > 0) {
            *angles += found;

            return true;
        }

        let qualified = QUAL_HEADS
            && *angles == 0
            && self
                .back_of(position)
                .is_none_or(|held| !ends_operand(self.tokens[held as usize].kind));

        if text == b"<"
            && (qualified
                || self
                    .back_of(position)
                    .is_some_and(|held| self.tokens[held as usize].text(self.source) == b"::"))
        {
            *angles += 1;

            return true;
        }

        *angles > 0 || self.receives(position)
    }

    pub(super) fn chains_wide(&self, position: u32) -> bool {
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
                && !(ANGLE_COMMAS && self.angle_head(scan).is_some())
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
            let flat = self.flat_columns(head, end + 1) + self.chain_margin(end);
            let spread = self.spread_of(head);
            let seated_link = CHAIN_WRITES
                && self.flat_line(position, end + 1)
                && !self.linked_braced(position, end)
                && column + self.options.indent_width + self.flat_columns(position, end + 1)
                    <= self.options.line_width;

            let written =
                self.parted_by(from, to) == 0 || self.linked_over(head, end) || seated_link;

            let steady = CHAIN_ROOMS
                && spread + root <= self.options.line_width
                && spread + flat > self.options.line_width;

            let seated = !CHAIN_LINED
                || self.heads_line(head)
                || self.lined_of(head) <= self.options.line_width
                || steady;

            let lined = CHAIN_ROOT_LINES && self.root_lined(head, position);

            return SOLE_CHAIN_LINE
                && seated
                && position > head + 1
                && written
                && column + root <= self.options.line_width
                && (lined || column + flat > self.options.line_width);
        }

        if CHAIN_FLAT {
            let column = self.chained_at(head);
            let flat = self.flat_columns(head, end + 1);
            let overflowing = column + flat > self.options.line_width;
            let point = self.hug_point(head, end, overflowing);

            let rooted = column + self.flat_columns(head, self.linked_first(head, end))
                <= self.options.line_width;

            let lined = CHAIN_VERTICALS
                && self.linked_over(head, end)
                && self.flat_columns(head, point) + self.chain_tries(head, end)
                    > self.policy.chain_width;

            return rooted
                && (lined
                    || !self.linked_over(head, end)
                        && self.flat_columns(head, point) + self.chain_tries(head, end)
                            > self.policy.chain_width);
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

    fn head_column(&self, head: u32) -> Option<u32> {
        if !CHAIN_HEADS {
            return None;
        }

        let first = self.statement_word(head).filter(|held| *held < head)?;
        let returns = self.tokens[first as usize].text(self.source) == b"return";

        if !returns && self.assigned_value(first, head) != Some(head) {
            return None;
        }

        Some(self.chained_indent(head) + self.flat_columns(first, head) + 1)
    }

    fn chained_at(&self, head: u32) -> u32 {
        if self.assign_seated(head) {
            return self.chained_indent(head) + self.options.indent_width;
        }

        if self.lined_of(head) > self.options.line_width {
            return self
                .head_column(head)
                .unwrap_or_else(|| self.chained_indent(head) + self.options.indent_width);
        }

        self.spread_of(head)
    }

    pub(super) fn chain_tries(&self, head: u32, end: u32) -> u32 {
        if !CHAIN_TRIES {
            return 0;
        }

        let mut tries = 0_u32;
        let mut scan = end;

        while scan > head {
            let text = self.tokens[scan as usize].text(self.source);

            if text.is_empty() || !text.iter().all(|byte| *byte == b'?') {
                break;
            }

            tries += count_of(text.len());

            let Some(found) = self.back_of(scan) else {
                break;
            };

            scan = found;
        }

        tries
    }

    fn chain_margin(&self, end: u32) -> u32 {
        if !CHAIN_MARGINS {
            return 0;
        }

        let held = self
            .next_of(end)
            .map(|found| self.tokens[found as usize].kind);

        u32::from(matches!(
            held,
            Some(TokenKind::Punctuation(
                Punctuation::Comma | Punctuation::Semicolon
            ))
        ))
    }

    fn chained_indent(&self, head: u32) -> u32 {
        let source = self.indent_of(head);

        if !CHAIN_INDENTS {
            return source;
        }

        if let Some(first) = self.statement_word(head).filter(|held| *held < head) {
            return self.indent_of(first);
        }

        let Some(brace) = self
            .back_of(head)
            .filter(|held| self.tokens[*held as usize].kind == TokenKind::BlockStart)
        else {
            return source;
        };

        self.statement_word(brace)
            .filter(|held| *held < brace)
            .map_or(source, |held| self.indent_of(held))
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

    fn combined(&self, open: u32) -> u32 {
        let mut head = open;

        for _ in 0..TYPE_SCAN_MAX {
            let Some(back) = self.back_of(head) else {
                break;
            };

            let token = self.tokens[back as usize];

            if token.end() != self.tokens[head as usize].offset {
                break;
            }

            let text = token.text(self.source);

            let named = matches!(text, b"::" | b"!")
                || token.kind == TokenKind::Identifier
                || matches!(token.kind, TokenKind::Keyword(_));

            if !named {
                break;
            }

            head = back;
        }

        if head < open {
            self.flat_columns(head, open)
        } else {
            0
        }
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

        if self.capped_list(open, close) && listed && !self.lambda_tailed(open, close) {
            return open + 1;
        }

        let Some(brace) = self.braced_after(open, close) else {
            return end + 1;
        };

        if HUG_LINED
            && self.chained_at(head) + self.flat_columns(head, brace + 1) > self.options.line_width
        {
            return open + 1;
        }

        if overflowing || self.blocked_over(brace) {
            return brace + 1;
        }

        end + 1
    }

    fn root_lined(&self, head: u32, position: u32) -> bool {
        let mut scan = head;

        while scan < position && scan < self.count {
            if self.tokens[scan as usize].kind != TokenKind::BlockStart {
                scan += 1;

                continue;
            }

            let parted = self.closing_of(scan).is_some_and(|close| {
                self.parted_by(
                    self.tokens[scan as usize].end(),
                    self.tokens[close as usize].offset,
                ) > 0
            });

            if parted || self.literal_wide(scan) || self.blocks_wide(scan) {
                return true;
            }

            scan += 1;
        }

        false
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

    fn lambda_tailed(&self, open: u32, close: u32) -> bool {
        if !HUG_POINTS {
            return false;
        }

        let Some(brace) = self.braced_after(open, close) else {
            return false;
        };

        let Some(end) = self.closing_of(brace) else {
            return false;
        };

        let last = self.back_of(close).filter(|held| *held > open);
        let tailed = last == Some(end)
            || last.is_some_and(|held| self.commas(held) && self.back_of(held) == Some(end));

        tailed
            && self.back_of(brace).is_some_and(|bar| {
                matches!(self.tokens[bar as usize].text(self.source), b"|" | b"move")
            })
    }

    fn capped_list(&self, open: u32, close: u32) -> bool {
        let mut barred = false;
        let mut depth = 0_u32;
        let mut scan = open + 1;

        while scan < close && scan < self.count {
            let kind = self.tokens[scan as usize].kind;

            if is_open(kind) || kind == TokenKind::BlockStart {
                depth += 1;
            } else if is_close(kind) || kind == TokenKind::BlockEnd {
                depth = depth.saturating_sub(1);
            } else if LAMBDA_COMMAS
                && depth == 0
                && self.tokens[scan as usize].text(self.source) == b"|"
            {
                barred = !barred;
            } else if depth == 0 && !barred && self.commas(scan) {
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
        let returned = RETURN_TUPLES
            && self
                .back_of(open)
                .is_some_and(|held| self.tokens[held as usize].text(self.source) == b"->");

        !returned && self.worded_head(open, self.policy.define_words)
    }

    fn defined_wide(&self, open: u32, close: u32) -> bool {
        if !self.policy.define_widths
            || self.tokens[open as usize].kind != TokenKind::Punctuation(Punctuation::ParenOpen)
        {
            return false;
        }

        let Some(next) = self.next_of(close) else {
            return false;
        };

        let ended = self.tokens[next as usize].kind == TokenKind::BlockStart
            || matches!(
                self.tokens[next as usize].text(self.source),
                b"->" | b";" | b"where"
            );

        if !ended {
            return false;
        }

        let named = self.back_of(open).is_some_and(|held| {
            let text = self.tokens[held as usize].text(self.source);

            self.tokens[held as usize].kind == TokenKind::Identifier
                || !text.is_empty() && text.iter().all(|byte| *byte == b'>')
        });

        if !named {
            return false;
        }

        let Some(head) = self.statement_word(open).filter(|held| *held < open) else {
            return false;
        };

        let end = self.defined_end(close);

        if self.parted_by(
            self.tokens[head as usize].offset,
            self.tokens[end as usize].end(),
        ) > 0
        {
            return false;
        }

        let under = self.printed * self.options.indent_width;

        under + self.flat_columns(head, end + 1) > self.options.line_width
    }

    fn defined_end(&self, close: u32) -> u32 {
        let mut depth = 0_u32;
        let mut scan = close;

        for _ in 0..TYPE_SCAN_MAX {
            let Some(held) = self.next_of(scan) else {
                return scan;
            };

            let kind = self.tokens[held as usize].kind;

            if depth == 0
                && (kind == TokenKind::BlockStart
                    || kind == TokenKind::Punctuation(Punctuation::Semicolon)
                    || self.tokens[held as usize].text(self.source) == b"where")
            {
                return held;
            }

            if is_open(kind) {
                depth += 1;
            } else if is_close(kind) {
                depth = depth.saturating_sub(1);
            }

            scan = held;
        }

        close
    }

    fn tupled_define(&self, open: u32) -> bool {
        if !TUPLE_DEFINES
            || self.tokens[open as usize].kind != TokenKind::Punctuation(Punctuation::ParenOpen)
            || self
                .back_of(open)
                .is_none_or(|held| self.tokens[held as usize].kind != TokenKind::Identifier)
        {
            return false;
        }

        if self.worded_head(open, TUPLE_WORDS) {
            return true;
        }

        let mut level = self.depth;

        while level > 0 {
            level -= 1;

            let frame = self.nest[level as usize];

            if frame.kind == TokenKind::BlockStart {
                return frame.open < open && self.worded_head(frame.open, TUPLE_WORDS);
            }
        }

        false
    }

    fn tupled_sole(&self, open: u32, close: u32) -> bool {
        self.listed_count(open, close) == 1 && self.tupled_define(open)
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

    pub(super) fn elemental_list(&self, open: u32, close: u32) -> bool {
        let patterned = self
            .next_of(close)
            .is_some_and(|held| self.tokens[held as usize].text(self.source) == b"=>")
            || self
                .word_before(open)
                .and_then(|bang| self.word_before(bang))
                .is_some_and(|name| self.tokens[name as usize].text(self.source) == b"matches")
                && (!MATCH_LISTS || self.ranged_list(open, close));

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

    fn ranged_list(&self, open: u32, close: u32) -> bool {
        let mut depth = 0_u32;
        let mut scan = open + 1;

        while scan < close {
            let kind = self.tokens[scan as usize].kind;

            if is_open(kind) || kind == TokenKind::BlockStart {
                depth += 1;
            } else if is_close(kind) || kind == TokenKind::BlockEnd {
                depth = depth.saturating_sub(1);
            } else if depth == 0 && self.ranges(scan) {
                return true;
            }

            scan += 1;
        }

        false
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
            || self.header_wided(position)
            || self.calls(position, previous)
            || self.chains_wide(position)
            || self.members(position, previous)
            || self.literals(position, previous)
            || self.blocks(position, previous)
            || self.else_parted(position)
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
        let mut inside = false;

        for level in 0..self.depth {
            let frame = self.nest[level as usize];

            if MACRO_BODIES
                && frame.kind == TokenKind::BlockStart
                && !self.valued_brace(frame.open)
                && self.head_word(frame.open, MACRO_ARMS).is_none()
            {
                inside = false;
                continue;
            }

            let Some(name) = self.macro_name(frame.open) else {
                continue;
            };

            inside = !ARRAY_MACROS
                || inside
                || frame.kind != TokenKind::Punctuation(Punctuation::BracketOpen)
                || self.tokens[name as usize].text(self.source) != b"vec";
        }

        inside
    }

    fn macro_name(&self, open: u32) -> Option<u32> {
        let bang = self.back_of(open)?;

        if self.tokens[bang as usize].text(self.source) != b"!" {
            return None;
        }

        let name = self.back_of(bang)?;

        matches!(
            self.tokens[name as usize].kind,
            TokenKind::Identifier | TokenKind::Keyword(_)
        )
        .then_some(name)
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

            if HEAD_ATTRS && text == b"#" {
                return false;
            }

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
                    || ARM_VALUES && self.tokens[held as usize].text(self.source) == b"=>"
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

    pub(super) fn returned_parted(&self, close: u32) -> bool {
        let Some(arrow) = self
            .next_of(close)
            .filter(|held| self.tokens[*held as usize].text(self.source) == b"->")
        else {
            return false;
        };

        let Some(open) = self
            .next_of(arrow)
            .filter(|held| is_open(self.tokens[*held as usize].kind))
        else {
            return false;
        };

        self.listed_wide(open).is_some()
    }

    fn guard_behind(&self, open: u32) -> bool {
        let mut depth = 0_u32;
        let mut scan = open;

        for _ in 0..TYPE_SCAN_MAX {
            let Some(held) = self.back_of(scan) else {
                return false;
            };

            let kind = self.tokens[held as usize].kind;

            if is_close(kind) || kind == TokenKind::BlockEnd {
                depth += 1;
            } else if is_open(kind) || kind == TokenKind::BlockStart {
                if depth == 0 {
                    return false;
                }

                depth -= 1;
            } else if depth == 0 {
                let text = self.tokens[held as usize].text(self.source);

                if text == b"if" {
                    return true;
                }

                if text == b"=>"
                    || matches!(
                        kind,
                        TokenKind::Punctuation(Punctuation::Comma | Punctuation::Semicolon)
                    )
                {
                    return false;
                }
            }

            scan = held;
        }

        false
    }

    fn arm_patterned(&self, close: u32) -> bool {
        if self
            .brackets
            .open_of(close)
            .is_some_and(|open| self.guard_behind(open))
        {
            return false;
        }

        let mut depth = 0_u32;
        let mut scan = close;

        for _ in 0..TYPE_SCAN_MAX {
            let Some(held) = self.next_of(scan) else {
                return false;
            };

            let kind = self.tokens[held as usize].kind;

            if is_open(kind) || kind == TokenKind::BlockStart {
                depth += 1;
            } else if is_close(kind) || kind == TokenKind::BlockEnd {
                if depth == 0 {
                    return false;
                }

                depth -= 1;
            } else if depth == 0 {
                if self.tokens[held as usize].text(self.source) == b"=>" {
                    return true;
                }

                if matches!(
                    kind,
                    TokenKind::Punctuation(Punctuation::Comma | Punctuation::Semicolon)
                ) {
                    return false;
                }
            }

            scan = held;
        }

        false
    }

    fn chained_point(&self, open: u32, close: u32, ends: u32) -> u32 {
        let (Some(first), Some(last)) = (self.next_of(open), self.back_of(close)) else {
            return ends;
        };

        let flat = self.flat_columns(first, last + 1);
        let over = self.chained_at(first) + flat > self.options.line_width;

        if CHAIN_SOLE_ROOTS && self.combined(open) < self.options.indent_width {
            return self.linked_first(first, last).min(ends);
        }

        self.hug_point(first, last, over).min(ends)
    }

    fn tailed_close(&self, ends: u32, measured: u32) -> bool {
        self.back_of(ends).is_some_and(|last| {
            last > measured
                && self.tokens[last as usize].kind == TokenKind::Punctuation(Punctuation::Comma)
        })
    }

    #[expect(
        clippy::too_many_lines,
        reason = "the walk names every reason a list parts and every reason it does not, and the \
                  order it reads them in is the rule"
    )]
    pub(super) fn listed_wide(&self, open: u32) -> Option<u32> {
        let close = self.closing_of(open)?;

        if !self.listed(close) && !self.macroed(open, close) {
            return None;
        }

        if self.defined(open) {
            return (RETURN_BLOCKS && self.returned_parted(close)
                || DEFINE_WIDES && self.defined_wide(open, close))
            .then_some(open);
        }

        if self.braced_line(open) || self.remarked_value(open) {
            return None;
        }

        if self.tupled_sole(open, close) {
            return None;
        }

        if self.tried_over(open, close)
            || self.returned_over(open, close)
            || self.branched_last(open, close)
        {
            return Some(open);
        }

        if self.listed_lined(open, close) {
            return Some(open);
        }

        if self.hugged_wide(open) {
            return Some(open);
        }

        let held = self.sole_call(open);
        let stop = self.closing_of(held)?;
        let nests = self.policy.call_nests;
        let measured = if nests { open } else { held };
        let ends = if nests { close } else { stop };
        let from = self.tokens[measured as usize].end();
        let to = self.tokens[ends as usize].offset;

        if (SOLE_CHAIN_ALWAYS || self.linked_parted(open, close)) && self.chained_sole(open, close)
        {
            // `format_last_child`'s `one_line_budget` is the SHAPE for a chain of one child and
            // `min(shape, chain_width)` for every longer one, so a sole item holding a single
            // link is measured against the line and not against fn_call_width.
            if SOLE_LINKS && self.chained_soled(open) {
                return self.chained_lined(open, close).then_some(held);
            }

            let point = self.chained_point(open, close, ends);

            return (self.flat_columns(measured + 1, point) > self.policy.call_width)
                .then_some(held);
        }

        let rooted = self
            .next_of(close)
            .is_some_and(|next| self.is_dot(next) && !self.ranges(next));

        let overflowed =
            self.policy.call_budgets && held != open && !rooted && !self.linked_bracket(open);

        let tailed = COMMA_WIDTHS && self.tailed_close(ends, measured);
        let width = columns(self.source, from, to)
            - u32::from(tailed || overflowed && self.tailed_comma(measured, ends));

        if self.parted_by(from, to) > 0 {
            return None;
        }

        if self.linked_wide(open, close) {
            return Some(held);
        }

        let budget = if PATTERN_WIDTHS && self.arm_patterned(close) {
            self.options.line_width
        } else {
            self.policy.call_width
        };

        if width <= budget && !self.listed_broken(open, close) {
            return None;
        }

        if self.lambda_soled(open, close) {
            return None;
        }

        (overflowed
            || self.elemental_list(held, stop)
            || self.lambda_listed(open, close)
            || LAMBDA_HEADS && self.lambda_headed(open, close)
            || self.chained_sole(open, close)
            || self.stringed_wide(open, close, rooted))
        .then_some(held)
    }

    fn linked_wide(&self, open: u32, close: u32) -> bool {
        if !LINK_WIDES || self.policy.chain_width == 0 {
            return false;
        }

        let Some(callee) = self.back_of(open) else {
            return false;
        };

        let Some(dot) = self
            .back_of(callee)
            .filter(|held| self.is_dot(*held) && !self.ranges(*held))
        else {
            return false;
        };

        let head = self.chain_head(dot);
        let (end, links, _) = self.chain_end(head);

        if links < 1
            || self.parted_by(
                self.tokens[head as usize].offset,
                self.tokens[end as usize].end(),
            ) == 0
        {
            return false;
        }

        let under = self.chained_indent(head) + self.options.indent_width;

        under + self.flat_columns(dot, close + 1) > self.options.line_width
    }

    fn listed_lined(&self, open: u32, close: u32) -> bool {
        if !LIST_LINED {
            return false;
        }

        let Some(last) = self.listed_last(open, close) else {
            return false;
        };

        let mut scan = open + 1;

        while scan < last {
            if self.tokens[scan as usize]
                .text(self.source)
                .contains(&b'\n')
            {
                return true;
            }

            scan += 1;
        }

        false
    }

    fn linked_braced(&self, from: u32, to: u32) -> bool {
        let mut scan = from;

        while scan <= to && scan < self.count {
            if self.tokens[scan as usize].kind == TokenKind::BlockStart {
                return true;
            }

            scan += 1;
        }

        false
    }

    fn flat_line(&self, from: u32, to: u32) -> bool {
        let mut scan = from;

        while scan < to && scan < self.count {
            if self.tokens[scan as usize]
                .text(self.source)
                .contains(&b'\n')
            {
                return false;
            }

            scan += 1;
        }

        true
    }

    fn lambda_listed(&self, open: u32, close: u32) -> bool {
        if !LAMBDA_LISTS
            || self.tokens[open as usize].kind == TokenKind::BlockStart
            || self.element_count(open, close) < 2
            || self.hugged_call(open)
        {
            return false;
        }

        let Some(head) = self.listed_last(open, close) else {
            return false;
        };

        if !matches!(self.tokens[head as usize].text(self.source), b"|" | b"move") {
            return false;
        }

        let mut scan = head;

        while scan < close {
            if self.spans_wide(scan) || self.is_dot(scan) && !self.ranges(scan) {
                return false;
            }

            scan += 1;
        }

        true
    }

    pub(super) fn listed_last(&self, open: u32, close: u32) -> Option<u32> {
        let mut barred = false;
        let mut depth = 0_u32;
        let mut head = self.next_of(open).filter(|held| *held < close)?;
        let mut scan = head;

        for _ in 0..TYPE_SCAN_MAX {
            if scan >= close {
                return Some(head);
            }

            let kind = self.tokens[scan as usize].kind;

            if is_open(kind) {
                depth += 1;
            } else if is_close(kind) {
                depth = depth.saturating_sub(1);
            } else if depth == 0 && self.tokens[scan as usize].text(self.source) == b"|" {
                barred = !barred;
            } else if depth == 0 && !barred && kind == TokenKind::Punctuation(Punctuation::Comma) {
                head = self.next_of(scan).filter(|held| *held < close)?;
            }

            scan = self.next_of(scan)?;
        }

        None
    }

    fn lambda_headed(&self, open: u32, close: u32) -> bool {
        if self.tokens[open as usize].kind == TokenKind::BlockStart {
            return false;
        }

        self.next_of(open)
            .filter(|held| *held < close)
            .is_some_and(|first| {
                matches!(
                    self.tokens[first as usize].text(self.source),
                    b"|" | b"move"
                )
            })
    }

    fn lambda_soled(&self, open: u32, close: u32) -> bool {
        if !LAMBDA_SOLES {
            return false;
        }

        if LAMBDA_HEADS && self.listed_count(open, close) > 1 {
            return false;
        }

        self.lambda_headed(open, close) && !self.elemental_list(open, close)
    }

    fn listed_broken(&self, open: u32, close: u32) -> bool {
        if !LIST_BREAKS
            || self.element_count(open, close) < 2
            || self.hugged_point(open, close).is_some()
        {
            return false;
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

        self.flat_columns(open + 1, point) > self.lambda_room(open, point - 1)
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

        if HUG_BUDGETS && self.word_is(before, HUG_HEADS) {
            return Some(before);
        }

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

                (self.tokens[before as usize].end() < token.offset
                    || self.printed_gap(before, scan))
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

    fn printed_gap(&self, before: u32, scan: u32) -> bool {
        if !self.policy.printed_gaps {
            return false;
        }

        let leading = self.roled(before, ROLE_SPACED);
        let trailing = self.roled(scan, ROLE_SPACED);

        if leading || trailing {
            return !leading
                || !trailing
                || self.tokens[before as usize].end() < self.tokens[scan as usize].offset;
        }

        let kind = self.tokens[scan as usize].kind;

        if is_close(kind)
            || kind == TokenKind::BlockEnd
            || matches!(
                kind,
                TokenKind::Punctuation(
                    Punctuation::Colon | Punctuation::Comma | Punctuation::Semicolon
                )
            )
        {
            return false;
        }

        if matches!(
            self.tokens[before as usize].kind,
            TokenKind::Punctuation(Punctuation::Comma | Punctuation::Semicolon)
        ) {
            return true;
        }

        if !matches!(self.tokens[before as usize].kind, TokenKind::Keyword(_))
            || self.operand_at(before)
        {
            return false;
        }

        self.policy.keyword_gaps
            || !matches!(
                kind,
                TokenKind::Punctuation(Punctuation::BracketOpen | Punctuation::ParenOpen)
            )
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

            if TURBO_FISH && self.angle_count(back, b'>').is_some() {
                let Some(found) = self.angled_head(back) else {
                    break;
                };

                head = found;
                scan = found;

                continue;
            }

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

    fn chained_soled(&self, open: u32) -> bool {
        let Some(first) = self.operand_of(open) else {
            return false;
        };

        let (_, links, _) = self.chain_end(self.chain_head(first));

        links < 2
    }

    // rustfmt's `ident` for the bracket is the callee PATH and nothing in front of it, so the
    // walk takes name segments welded by `::` and a macro's `!`, and stops at anything else --
    // `return Err(..)` measures `Err` and not `return Err`.
    fn callee_pathed(&self, open: u32) -> u32 {
        let mut head = open;
        let mut scan = open;

        for _ in 0..TYPE_SCAN_MAX {
            let Some(back) = self.back_of(scan) else {
                break;
            };

            let text = self.tokens[back as usize].text(self.source);

            if text == b"!" {
                head = back;
                scan = back;

                continue;
            }

            let named = !text.is_empty()
                && text
                    .iter()
                    .all(|byte| byte.is_ascii_alphanumeric() || *byte == b'_');

            if !named {
                break;
            }

            head = back;
            scan = back;

            match self.back_of(scan) {
                Some(sep) if self.tokens[sep as usize].text(self.source) == b"::" => {
                    head = sep;
                    scan = sep;
                }
                _ => break,
            }
        }

        columns(
            self.source,
            self.tokens[head as usize].offset,
            self.tokens[open as usize].offset,
        )
    }

    // `format_last_child` keeps the hug where the last child's own rewrite runs to five lines or
    // more and its first line fits, and the source's own break inside that child is the tell.
    fn chained_tailed(&self, open: u32, close: u32) -> bool {
        let Some(last) = self.back_of(close) else {
            return false;
        };

        let mut depth = 0_u32;
        let mut link = None;
        let mut scan = close;

        while scan > open {
            scan -= 1;

            let kind = self.tokens[scan as usize].kind;

            if is_close(kind) || kind == TokenKind::BlockEnd {
                depth += 1;
            } else if is_open(kind) || kind == TokenKind::BlockStart {
                depth = depth.saturating_sub(1);
            } else if depth == 0 && self.is_dot(scan) && !self.ranges(scan) {
                link = Some(scan);

                break;
            }
        }

        let Some(held) = link else {
            return false;
        };

        self.parted_by(
            self.tokens[held as usize].offset,
            self.tokens[last as usize].end(),
        ) > 0
    }

    fn chained_lined(&self, open: u32, close: u32) -> bool {
        let (Some(first), Some(last)) = (self.next_of(open), self.back_of(close)) else {
            return false;
        };

        if self.callee_pathed(open) < self.options.indent_width || self.chained_tailed(open, close)
        {
            return false;
        }

        self.chained_at(first) + self.flat_columns(first, last + 1) > self.options.line_width
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
                let owed = u32::from(!SOLE_LINKS) + 1;

                return head == first && end == last && links >= owed;
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
            || !LITERAL_MACROS && self.invoked()
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

        let separated = self.tokens[previous as usize].kind
            == TokenKind::Punctuation(Punctuation::Comma)
            && !(ANGLE_COMMAS && self.angle_head(previous).is_some());

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

    pub(super) fn macroed(&self, open: u32, close: u32) -> bool {
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

    pub(super) fn macro_tailed(&self, close: u32) -> bool {
        if !MACRO_COMMAS
            || self.tokens[close as usize].kind != TokenKind::Punctuation(Punctuation::ParenClose)
        {
            return false;
        }

        reach::opened(self.source, self.tokens, close).is_some_and(|open| self.macroed(open, close))
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

        if self.policy.body_owns && BINDING_PATTERNS.contains(&held.text(self.source)) {
            return true;
        }

        if OBJECT_OPERANDS && self.policy.binary_parts && self.logical_operator(before) {
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

        // `ChainItemKind::Await` is a link like any other, so a chain does not end at `.await`.
        if matches!(kind, TokenKind::Keyword(_)) {
            return matches!(text, b"self" | b"Self" | b"super" | b"crate")
                || CHAIN_AWAITS && text == b"await";
        }

        matches!(
            kind,
            TokenKind::Identifier | TokenKind::Number | TokenKind::String
        ) || matches!(text, b"." | b"::" | b"?" | b"!")
            || CHAIN_METAS && text == b"$"
    }

    fn rooted(&self, head: u32, position: u32) -> bool {
        if self.next_of(head) != Some(position) {
            return false;
        }

        let Some(back) = self.back_of(head) else {
            return false;
        };

        let braced = self.tokens[back as usize].kind == TokenKind::BlockStart;

        if ROOT_FLATS && braced && self.flattened(back) {
            return false;
        }

        if ROOT_TOKEN_WIDTH && braced {
            let token = self.tokens[head as usize];

            return columns(self.source, token.offset, token.end()) <= self.options.indent_width;
        }

        let width = self.tokens[head as usize].length;

        let offset = self
            .root_offset(head)
            .unwrap_or_else(|| self.column_of(head) - self.leading(head));

        width <= self.options.indent_width.saturating_sub(offset)
    }

    fn root_offset(&self, head: u32) -> Option<u32> {
        if !ROOT_SEATS {
            return None;
        }

        let first = self.statement_word(head).filter(|held| *held < head)?;

        if self.assigned_value(first, head) != Some(head) {
            return None;
        }

        if self.assign_seated(head) {
            return Some(0);
        }

        Some(self.flat_columns(first, head) + 1)
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

    fn sole_bracket(&self, open: u32) -> Option<u32> {
        let close = self.closing_of(open)?;
        let mut scan = self.next_of(open).filter(|held| *held < close)?;

        for _ in 0..TYPE_SCAN_MAX {
            if matches!(
                self.tokens[scan as usize].kind,
                TokenKind::Punctuation(Punctuation::BracketOpen | Punctuation::ParenOpen)
            ) {
                return (self.closing_of(scan) == self.back_of(close)).then_some(scan);
            }

            if self.tokens[scan as usize].text(self.source) != b"&" {
                return None;
            }

            scan = self.next_of(scan)?;
        }

        None
    }

    fn sole_bracketed(&self, open: u32, held: u32, budget: u32) -> u32 {
        if !SOLE_BRACKETS || held == open {
            return held;
        }

        let Some(found) = self.sole_bracket(held) else {
            return held;
        };

        let (Some(first), Some(close)) = (self.next_of(held), self.closing_of(held)) else {
            return held;
        };

        if self.flat_columns(first, close) > budget {
            found
        } else {
            held
        }
    }

    fn sole_call(&self, open: u32) -> u32 {
        let mut budget = self.policy.call_width;
        let mut held = open;

        for _ in 0..NEST_DEPTH_MAX {
            let Some(inner) = self.sole_inner(held) else {
                return self.sole_bracketed(open, held, budget);
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

    /// The operand a bracket's sole item stands as, with the unary run in front of it stepped
    /// over.
    ///
    /// `is_nested_call` reads THROUGH an `AddrOf`, a `Try`, a `Unary` and a `Cast` to the call
    /// underneath, and an `AddrOf` carries its mutability inside it -- `&mut *g(..)` is one node,
    /// not a reference in front of a `mut` in front of a dereference. Without the `mut` the walk
    /// stops there and the whole `last_item_shape` cascade below it never runs.
    fn operand_of(&self, open: u32) -> Option<u32> {
        let mut scan = self.next_of(open)?;

        for _ in 0..UNARY_WALK_MAX {
            let text = self.tokens[scan as usize].text(self.source);
            let unary = matches!(text, b"!" | b"&" | b"&&" | b"*") || UNARY_MUTS && text == b"mut";

            if !unary {
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
            let angled = TURBO_FISH && self.angle_count(scan, b'<').is_some();

            let named = angled
                || matches!(text, b"::" | b"!")
                || !text.is_empty()
                    && text
                        .iter()
                        .all(|byte| byte.is_ascii_alphanumeric() || *byte == b'_');

            if !named {
                return None;
            }

            scan = if angled {
                self.angled_over(scan)?
            } else {
                self.next_of(scan)?
            };

            if self.tokens[scan as usize].kind == TokenKind::Punctuation(Punctuation::ParenOpen) {
                return (self.closing_of(scan) == self.back_of(close)).then_some(scan);
            }
        }

        None
    }

    fn angled_over(&self, open: u32) -> Option<u32> {
        let mut angles = self.angle_count(open, b'<')?;
        let mut scan = open;

        for _ in 0..TYPE_SCAN_MAX {
            scan = self.next_of(scan)?;

            if let Some(found) = self.angle_count(scan, b'<') {
                angles += found;
            } else if let Some(found) = self.angle_count(scan, b'>') {
                angles = angles.saturating_sub(found);

                if angles == 0 {
                    return self.next_of(scan);
                }
            }
        }

        None
    }

    fn macro_assigned(&self, position: u32) -> bool {
        if self.tokens[position as usize].kind != TokenKind::Punctuation(Punctuation::Assign) {
            return false;
        }

        let Some(name) = self
            .back_of(position)
            .filter(|held| self.tokens[*held as usize].kind == TokenKind::Identifier)
        else {
            return false;
        };

        self.back_of(name).is_some_and(|held| {
            matches!(
                self.tokens[held as usize].kind,
                TokenKind::BlockStart
                    | TokenKind::Comment
                    | TokenKind::Punctuation(Punctuation::Comma)
            )
        })
    }

    pub(super) fn defined_stream(&self, open: u32, close: u32) -> bool {
        let mut lambda = false;
        let mut previous: Option<u32> = None;
        let mut scan = open + 1;

        while scan < close {
            let token = self.tokens[scan as usize];
            let opens = previous.is_none_or(|held| !ends_operand(self.tokens[held as usize].kind));

            if token.text(self.source) == b"|" && (lambda || opens) {
                lambda = !lambda;
            } else if !lambda && self.defined_juxtaposed(scan) {
                return true;
            }

            if token.length > 0 {
                previous = Some(scan);
            }

            scan += 1;
        }

        false
    }

    fn defined_juxtaposed(&self, position: u32) -> bool {
        if !ends_operand(self.tokens[position as usize].kind) {
            return false;
        }

        self.next_of(position)
            .is_some_and(|held| self.tokens[held as usize].text(self.source) == b"$")
    }

    pub(super) fn streamed(&self, open: u32, close: u32) -> bool {
        let mut blocked = 0_u64;
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

                if depth <= MACRO_LEVEL_MAX {
                    let bit = 1_u64 << (depth - 1);

                    if kind == TokenKind::BlockStart {
                        blocked |= bit;
                    } else {
                        blocked &= !bit;
                    }
                }
            } else if is_close(kind) || kind == TokenKind::BlockEnd {
                depth = depth.saturating_sub(1);
                blocks = blocks.saturating_sub(u32::from(kind == TokenKind::BlockEnd));
            }

            if !lambda && (!MACRO_BLOCKS || blocks == 0) && self.juxtaposed(scan) {
                return true;
            }

            // The `=` that tells `parse_macro_args` apart is one standing DIRECTLY inside a
            // brace -- `dw!(DwSect(u32) { DW_SECT_INFO = 1, .. })`. A named argument inside a
            // call the brace holds, `foo("b", path = 1)`, is an assignment expression and parses.
            let braced = if MACRO_LEVELS {
                depth > 0 && depth <= MACRO_LEVEL_MAX && blocked & (1_u64 << (depth - 1)) != 0
            } else {
                blocks > 0
            };

            if MACRO_ASSIGNS && !lambda && braced && self.macro_assigned(scan) {
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
