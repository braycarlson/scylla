use super::{Emitter, VALUE_ARROWS, Wrap, is_close, is_open};
use crate::bounded::count_of;
use crate::token::{Punctuation, TokenKind};

const ARGUMENT_COUNT_MAX: u32 = 64;
pub(super) const BINARY_LEVEL_MAX: u32 = 12;
pub(super) const LOGICAL_LEVEL_MAX: u32 = 3;
const ARROW: &[u8] = b"=>";
const ASYNC: &[u8] = b"async";
const CALLEE_HEADS: [&[u8]; 3] = [b"import", b"super", b"this"];
const CALLEE_LINKS: [&[u8]; 4] = [b"!", b".", b"?.", b"this"];
const FUNCTION: &[u8] = b"function";
const HOOK_ARGUMENT_MAX: u32 = 3;
const NEW: &[u8] = b"new";
const QUESTION: &[u8] = b"?";
const SIMPLE_LINKS: [&[u8]; 7] = [b"<", b">", b".", b"?.", b"new", b"this", b","];
const SIMPLE_OPERATORS: [&[u8]; 10] = [
    b"%",
    b"&&",
    b"*",
    b"+",
    b"-",
    b"/",
    b"<",
    b">",
    b"??",
    b"||",
];
const SIMPLE_TOKEN_MAX: u32 = 9;
const TEST_ARGUMENT_MAX: u32 = 3;
const TEST_MODES: [&[u8]; 7] = [
    b"concurrent",
    b"fails",
    b"failing",
    b"only",
    b"sequential",
    b"skip",
    b"todo",
];
const TEST_NAME_MAX: u32 = 5;
const TEST_STEPS: [&[u8]; 6] = [
    b"concurrent",
    b"only",
    b"sequential",
    b"shuffle",
    b"skip",
    b"todo",
];

impl Emitter<'_> {
    pub(super) fn composed_args(&self, open: u32) -> bool {
        if !self.policy.compose_parts
            || self.tokens[open as usize].kind != TokenKind::Punctuation(Punctuation::ParenOpen)
        {
            return false;
        }

        let Some(close) = self.closing_of(open) else {
            return false;
        };

        if !self.calling(open) {
            return false;
        }

        if self.hooked_args(open, close) {
            return false;
        }

        let mut composes = false;
        let mut count = 0;
        let mut functions = 0;
        let mut start = self.next_of(open).filter(|held| *held < close);

        while let Some(from) = start {
            let to = self.argument_end(from, close);

            count += 1;

            if count > ARGUMENT_COUNT_MAX {
                return false;
            }

            if self.functioned(from, to) {
                functions += 1;
            } else if let Some((held, ends)) = self.called_args(from, to) {
                composes = composes || self.composes(held, ends);
            }

            start = self.next_of(to).filter(|held| *held < close);
        }

        count > 1 && (functions > 1 || composes)
    }

    fn argument_end(&self, from: u32, close: u32) -> u32 {
        let mut depth = 0_u32;
        let mut scan = from;

        while scan < close {
            if let Some(end) = self.spanned_body(scan) {
                scan = end + 1;

                continue;
            }

            let kind = self.tokens[scan as usize].kind;

            if is_open(kind) || kind == TokenKind::BlockStart {
                depth += 1;
            } else if is_close(kind) || kind == TokenKind::BlockEnd {
                depth = depth.saturating_sub(1);
            } else if depth == 0
                && kind == TokenKind::Punctuation(Punctuation::Comma)
                && self.brackets.angles_at(scan) == 0
            {
                return scan;
            }

            scan += 1;
        }

        close
    }

    pub(super) fn composes(&self, open: u32, close: u32) -> bool {
        let mut count = 0;
        let mut start = self.next_of(open).filter(|held| *held < close);

        while let Some(from) = start {
            let to = self.argument_end(from, close);

            count += 1;

            if count > ARGUMENT_COUNT_MAX {
                return false;
            }

            if self.functioned(from, to) {
                return true;
            }

            start = self.next_of(to).filter(|held| *held < close);
        }

        false
    }

    fn called_args(&self, from: u32, to: u32) -> Option<(u32, u32)> {
        if self.tokens[from as usize].text(self.source) == NEW {
            return None;
        }

        let last = self.word_before(to)?;

        if self.tokens[last as usize].kind != TokenKind::Punctuation(Punctuation::ParenClose) {
            return None;
        }

        let open = self.brackets.open_of(last)?;

        (open > from && self.calling(open) && self.called_head(from, open)).then_some((open, last))
    }

    fn called_head(&self, from: u32, open: u32) -> bool {
        let head = self.tokens[from as usize];

        if head.kind != TokenKind::Identifier && !CALLEE_HEADS.contains(&head.text(self.source)) {
            return false;
        }

        let mut angles = 0_u32;
        let mut depth = 0_u32;
        let mut scan = from + 1;

        while scan < open {
            if let Some(end) = self.spanned_body(scan) {
                scan = end + 1;

                continue;
            }

            let token = self.tokens[scan as usize];
            let text = token.text(self.source);

            if is_open(token.kind) || token.kind == TokenKind::BlockStart {
                depth += 1;
            } else if is_close(token.kind) || token.kind == TokenKind::BlockEnd {
                depth = depth.saturating_sub(1);
            } else if depth == 0 && text == b"<" {
                angles += 1;
            } else if depth == 0 && !text.is_empty() && text.iter().all(|byte| *byte == b'>') {
                angles = angles.saturating_sub(count_of(text.len()));
            } else if depth == 0
                && angles == 0
                && token.kind != TokenKind::Identifier
                && token.kind != TokenKind::Newline
                && token.length > 0
                && !CALLEE_LINKS.contains(&text)
            {
                return false;
            }

            scan += 1;
        }

        angles == 0
    }

    pub(super) fn hooked_args(&self, open: u32, close: u32) -> bool {
        let mut count = 0;
        let mut heads = [(0_u32, 0_u32); HOOK_ARGUMENT_MAX as usize];
        let mut start = self.next_of(open).filter(|held| *held < close);

        while let Some(from) = start {
            let to = self.argument_end(from, close);

            if count == HOOK_ARGUMENT_MAX {
                return false;
            }

            heads[count as usize] = (from, to);
            count += 1;
            start = self.next_of(to).filter(|held| *held < close);
        }

        if !(2..=3).contains(&count) {
            return false;
        }

        let (callback, callback_end) = heads[(count - 2) as usize];
        let (deps, deps_end) = heads[(count - 1) as usize];

        self.hooked_callback(callback, callback_end) && self.hooked_deps(deps, deps_end)
    }

    fn hooked_callback(&self, from: u32, to: u32) -> bool {
        let mut head = from;

        if self.tokens[head as usize].text(self.source) == ASYNC {
            let Some(after) = self.next_of(head).filter(|next| *next < to) else {
                return false;
            };

            head = after;
        }

        if self.tokens[head as usize].kind != TokenKind::Punctuation(Punctuation::ParenOpen) {
            return false;
        }

        let Some(close) = self.closing_of(head).filter(|held| *held < to) else {
            return false;
        };

        if self.next_of(head) != Some(close) {
            return false;
        }

        let Some(arrow) = self.next_of(close).filter(|held| *held < to) else {
            return false;
        };

        if self.tokens[arrow as usize].text(self.source) != ARROW {
            return false;
        }

        self.next_of(arrow)
            .is_some_and(|held| self.tokens[held as usize].kind == TokenKind::BlockStart)
    }

    fn hooked_deps(&self, from: u32, to: u32) -> bool {
        if self.tokens[from as usize].kind != TokenKind::Punctuation(Punctuation::BracketOpen) {
            return false;
        }

        self.closing_of(from)
            .is_some_and(|close| self.next_of(close).is_none_or(|held| held >= to))
    }

    pub(super) fn functioned(&self, from: u32, to: u32) -> bool {
        let mut head = from;

        if self.tokens[head as usize].text(self.source) == ASYNC {
            let Some(after) = self.next_of(head).filter(|next| *next < to) else {
                return false;
            };

            head = after;
        }

        let token = self.tokens[head as usize];

        if token.text(self.source) == FUNCTION {
            return true;
        }

        if token.kind == TokenKind::Punctuation(Punctuation::ParenOpen) {
            return self.arrow_parted(head, to);
        }

        token.kind == TokenKind::Identifier
            && self.next_of(head).is_some_and(|held| {
                held < to && self.tokens[held as usize].text(self.source) == ARROW
            })
    }

    fn arrow_parted(&self, open: u32, to: u32) -> bool {
        let Some(close) = self.closing_of(open).filter(|held| *held < to) else {
            return false;
        };

        let mut depth = 0_u32;
        let mut scan = close + 1;

        while scan < to {
            if let Some(end) = self.spanned_body(scan) {
                scan = end + 1;

                continue;
            }

            let token = self.tokens[scan as usize];

            if is_open(token.kind) || token.kind == TokenKind::BlockStart {
                depth += 1;
            } else if is_close(token.kind) || token.kind == TokenKind::BlockEnd {
                depth = depth.saturating_sub(1);
            } else if depth == 0 && token.text(self.source) == ARROW {
                return true;
            }

            scan += 1;
        }

        false
    }
}

#[expect(
    clippy::multiple_inherent_impl,
    reason = "the argument walks and the arrow's own layout are two families of the same call, \
              and `mod.rs` reaches both"
)]
impl Emitter<'_> {
    pub(super) fn arrow_wrapped(&self, position: u32) -> Option<(u32, Wrap)> {
        if !self.policy.arrow_bodies || self.tokens[position as usize].text(self.source) != ARROW {
            return None;
        }

        if self.arrowed {
            let head = self.next_of(position)?;

            if self.bodied_arrow(head) {
                return None;
            }

            let end = self.valued_semicolon(head)?;
            let last = self.word_before(end)?;

            return (last > head).then_some((last, Wrap::Bodied));
        }

        if self.depth == 0 {
            return None;
        }

        let frame = self.nest[self.depth as usize - 1];
        let paren = frame.kind == TokenKind::Punctuation(Punctuation::ParenOpen);
        let valued = VALUE_ARROWS && frame.kind == TokenKind::BlockStart && !self.typed_frame();
        let owned = paren && self.spreads();

        if !(owned || valued && self.spreads() || paren && self.tested_joined(position)) {
            return None;
        }

        let head = self.next_of(position).filter(|held| *held < frame.close)?;

        if self.bodied_arrow(head) {
            return None;
        }

        let end = self.argument_end(head, frame.close);
        let start = self.valued_start(self.argument_start(frame.open, position), position, valued);

        if !self.functioned(start, end) {
            return None;
        }

        let ternary = self.ternary_bodied(head, end);
        let grouped = self.called_args(head, end).is_some() || ternary;

        if ternary && !(owned && (end == frame.close || self.next_of(end) == Some(frame.close))) {
            return None;
        }

        let tail = end == frame.close || self.next_of(end) == Some(frame.close);
        let last = self.word_before(end)?;

        (last > head).then_some((
            last,
            if owned && tail && grouped {
                Wrap::Hugged
            } else {
                Wrap::Bodied
            },
        ))
    }

    fn valued_start(&self, start: u32, position: u32, valued: bool) -> u32 {
        if !valued {
            return start;
        }

        let mut depth = 0_u32;
        let mut scan = start;

        while scan < position {
            let kind = self.tokens[scan as usize].kind;

            if is_open(kind) || kind == TokenKind::BlockStart {
                depth += 1;
            } else if is_close(kind) || kind == TokenKind::BlockEnd {
                depth = depth.saturating_sub(1);
            } else if depth == 0 && kind == TokenKind::Punctuation(Punctuation::Colon) {
                return self.next_of(scan).unwrap_or(start);
            }

            scan += 1;
        }

        start
    }

    fn ternary_bodied(&self, from: u32, to: u32) -> bool {
        let mut depth = 0_u32;
        let mut scan = from;

        while scan < to {
            if let Some(end) = self.spanned_body(scan) {
                scan = end + 1;

                continue;
            }

            let token = self.tokens[scan as usize];

            if is_open(token.kind) || token.kind == TokenKind::BlockStart {
                depth += 1;
            } else if is_close(token.kind) || token.kind == TokenKind::BlockEnd {
                depth = depth.saturating_sub(1);
            } else if depth == 0 && token.text(self.source) == QUESTION && !self.optional(scan) {
                return true;
            }

            scan += 1;
        }

        false
    }

    pub(super) fn argument_start(&self, open: u32, position: u32) -> u32 {
        let mut depth = 0_u32;
        let mut scan = open + 1;
        let mut start = open + 1;

        while scan < position {
            if let Some(end) = self.spanned_body(scan).filter(|end| *end < position) {
                scan = end + 1;

                continue;
            }

            let kind = self.tokens[scan as usize].kind;

            if is_open(kind) || kind == TokenKind::BlockStart {
                depth += 1;
            } else if is_close(kind) || kind == TokenKind::BlockEnd {
                depth = depth.saturating_sub(1);
            } else if depth == 0
                && kind == TokenKind::Punctuation(Punctuation::Comma)
                && self.brackets.angles_at(scan) == 0
            {
                start = scan + 1;
            }

            scan += 1;
        }

        self.next_of(start.saturating_sub(1)).unwrap_or(start)
    }

    pub(super) fn bodied_arrow(&self, head: u32) -> bool {
        let token = self.tokens[head as usize];

        if matches!(
            token.kind,
            TokenKind::BlockStart | TokenKind::Punctuation(Punctuation::BracketOpen)
        ) {
            return true;
        }

        if token.text(self.source) == b"<" {
            return true;
        }

        if token.kind == TokenKind::Punctuation(Punctuation::ParenOpen) {
            let Some(close) = self.closing_of(head) else {
                return true;
            };

            if self.arrowed_ahead(close) {
                return true;
            }

            return self.next_of(head).is_some_and(|held| {
                matches!(
                    self.tokens[held as usize].kind,
                    TokenKind::BlockStart | TokenKind::Punctuation(Punctuation::BracketOpen)
                ) && self.closing_of(held).and_then(|end| self.next_of(end)) == Some(close)
            });
        }

        self.tokens[head as usize].text(self.source) == ASYNC || self.functioned(head, self.count)
    }

    fn arrowed_ahead(&self, close: u32) -> bool {
        self.next_of(close)
            .is_some_and(|held| self.tokens[held as usize].text(self.source) == ARROW)
    }
}

#[expect(
    clippy::multiple_inherent_impl,
    reason = "the span walk stands apart from the argument rules that use it"
)]
impl Emitter<'_> {
    fn spanned_body(&self, position: u32) -> Option<u32> {
        self.template_body(position)
            .or_else(|| self.jsx_body(position))
    }
}

#[expect(
    clippy::multiple_inherent_impl,
    reason = "the test-call rules stand apart from the argument walks above them"
)]
impl Emitter<'_> {
    pub(super) fn tested_args(&self, open: u32, close: u32) -> bool {
        if !self.policy.test_joins
            || self.tokens[open as usize].kind != TokenKind::Punctuation(Punctuation::ParenOpen)
            || !self.calling(open)
            || !self.tested_callee(open)
        {
            return false;
        }

        let mut count = 0;
        let mut heads = [(0_u32, 0_u32); TEST_ARGUMENT_MAX as usize];
        let mut start = self.next_of(open).filter(|held| *held < close);

        while let Some(from) = start {
            let to = self.argument_end(from, close);

            if count == TEST_ARGUMENT_MAX {
                return false;
            }

            heads[count as usize] = (from, to);
            count += 1;
            start = self.next_of(to).filter(|held| *held < close);
        }

        if !(2..=3).contains(&count) {
            return false;
        }

        let (first, first_end) = heads[0];
        let (second, second_end) = heads[1];

        if !self.tested_head(first, first_end) || !self.functioned(second, second_end) {
            return false;
        }

        if count == 2 {
            return true;
        }

        let (third, third_end) = heads[2];

        self.tokens[third as usize].kind == TokenKind::Number
            && self.next_of(third).is_none_or(|held| held >= third_end)
            && self.tested_simple(second, second_end)
    }

    fn tested_head(&self, from: u32, to: u32) -> bool {
        if let Some(end) = self.template_body(from) {
            return self.next_of(end).is_none_or(|held| held >= to);
        }

        self.tokens[from as usize].kind == TokenKind::String
            && self.next_of(from).is_none_or(|held| held >= to)
    }

    fn tested_simple(&self, from: u32, to: u32) -> bool {
        let mut head = from;

        if self.tokens[head as usize].text(self.source) == ASYNC {
            let Some(after) = self.next_of(head).filter(|next| *next < to) else {
                return false;
            };

            head = after;
        }

        if self.tokens[head as usize].text(self.source) == FUNCTION {
            let Some(after) = self.next_of(head).filter(|next| *next < to) else {
                return false;
            };

            head = if self.tokens[after as usize].kind == TokenKind::Identifier {
                self.next_of(after)
                    .filter(|next| *next < to)
                    .unwrap_or(after)
            } else {
                after
            };
        }

        if self.tokens[head as usize].kind != TokenKind::Punctuation(Punctuation::ParenOpen) {
            return false;
        }

        let Some(close) = self.closing_of(head).filter(|held| *held < to) else {
            return false;
        };

        let mut commas = 0;
        let mut scan = head + 1;

        while scan < close {
            if self.tokens[scan as usize].kind == TokenKind::Punctuation(Punctuation::Comma) {
                commas += 1;
            }

            scan += 1;
        }

        commas == 0 && self.tested_bodied(close, to)
    }

    fn tested_bodied(&self, close: u32, to: u32) -> bool {
        let Some(after) = self.next_of(close).filter(|held| *held < to) else {
            return false;
        };

        if self.tokens[after as usize].kind == TokenKind::BlockStart {
            return true;
        }

        self.tokens[after as usize].text(self.source) == ARROW
            && self
                .next_of(after)
                .is_some_and(|held| self.tokens[held as usize].kind == TokenKind::BlockStart)
    }

    fn tested_callee(&self, open: u32) -> bool {
        let mut count = 0;
        let mut names = [(0_u32, 0_u32); TEST_NAME_MAX as usize];
        let mut scan = self.word_before(open);

        while let Some(held) = scan {
            let token = self.tokens[held as usize];

            if token.kind == TokenKind::Identifier {
                if count == TEST_NAME_MAX {
                    return false;
                }

                names[count as usize] = (held, 0);
                count += 1;
                scan = self.word_before(held).filter(|before| {
                    self.tokens[*before as usize].kind == TokenKind::Punctuation(Punctuation::Dot)
                });

                continue;
            }

            if token.kind != TokenKind::Punctuation(Punctuation::Dot) {
                break;
            }

            scan = self.word_before(held);
        }

        if count == 0 {
            return false;
        }

        let spelled = |at: u32| self.tokens[names[at as usize].0 as usize].text(self.source);
        let first = spelled(count - 1);
        let second = (count >= 2).then(|| spelled(count - 2));
        let third = (count >= 3).then(|| spelled(count - 3));

        match first {
            b"describe" => match second {
                None => count == 1,
                Some(held) => {
                    TEST_STEPS.contains(&held) && third.is_none_or(|at| TEST_STEPS.contains(&at))
                }
            },
            b"it" | b"test" => match second {
                None => true,
                Some(b"step") => third.is_none(),
                Some(held) => {
                    TEST_MODES.contains(&held) && third.is_none_or(|at| TEST_MODES.contains(&at))
                }
            },
            b"Deno" => second == Some(b"test") && third.is_none(),
            b"skip" | b"xit" | b"xdescribe" | b"xtest" | b"fit" | b"fdescribe" | b"ftest" => true,
            _ => false,
        }
    }

    pub(super) fn tested_joined(&self, position: u32) -> bool {
        if !self.policy.test_joins || self.depth == 0 || position == 0 {
            return false;
        }

        self.nest[self.depth as usize - 1].joined
    }

    pub(super) fn joined_args(&self, open: u32, close: u32) -> bool {
        if self.tested_args(open, close) {
            return true;
        }

        self.policy.test_joins
            && self.tokens[open as usize].kind == TokenKind::Punctuation(Punctuation::ParenOpen)
            && self.calling(open)
            && self.hooked_args(open, close)
    }
}

#[expect(
    clippy::multiple_inherent_impl,
    reason = "the first-argument hug stands beside the test-call rules and reads the same walks"
)]
impl Emitter<'_> {
    pub(super) fn first_hugged(&self, open: u32, close: u32, position: u32) -> bool {
        let mut count = 0_u32;
        let mut heads = [(0_u32, 0_u32); 2];
        let mut start = self.next_of(open).filter(|held| *held < close);

        while let Some(from) = start {
            let to = self.argument_end(from, close);

            if count == 2 {
                return false;
            }

            heads[count as usize] = (from, to);
            count += 1;
            start = self.next_of(to).filter(|held| *held < close);
        }

        if count != 2 {
            return false;
        }

        let (first, first_end) = heads[0];
        let (second, second_end) = heads[1];

        first < position
            && position < first_end
            && self.functioned(first, first_end)
            && self.bodied_tail(first, first_end)
            && self.simple_argument(second, second_end)
    }

    fn bodied_tail(&self, from: u32, to: u32) -> bool {
        let mut scan = from;

        while scan < to {
            if self.tokens[scan as usize].kind == TokenKind::BlockStart {
                return true;
            }

            scan += 1;
        }

        false
    }

    fn simple_argument(&self, from: u32, to: u32) -> bool {
        let mut count = 0;
        let mut operators = 0;
        let mut scan = from;

        while scan < to {
            let token = self.tokens[scan as usize];

            if token.kind == TokenKind::Newline || token.length == 0 {
                scan += 1;

                continue;
            }

            if is_open(token.kind) {
                let Some(close) = self.closing_of(scan).filter(|held| *held < to) else {
                    return false;
                };

                if self.next_of(scan) != Some(close) {
                    return false;
                }

                count += 1;
                scan = close + 1;

                continue;
            }

            let held = matches!(
                token.kind,
                TokenKind::Identifier | TokenKind::Number | TokenKind::String
            ) || SIMPLE_LINKS.contains(&token.text(self.source));

            if !held {
                if operators == 1 || !SIMPLE_OPERATORS.contains(&token.text(self.source)) {
                    return false;
                }

                operators += 1;
            }

            count += 1;

            if count > SIMPLE_TOKEN_MAX {
                return false;
            }

            scan += 1;
        }

        count > 0
    }
}

#[expect(
    clippy::multiple_inherent_impl,
    reason = "the binary levels stand beside the call rules and are read from `mod.rs` alone"
)]
impl Emitter<'_> {
    pub(super) fn binary_floor(&self, head: u32, close: u32) -> u32 {
        let mut depth = 0_u32;
        let mut floor = BINARY_LEVEL_MAX;
        let mut scan = head;

        while scan < close {
            if let Some(end) = self.spanned_body(scan) {
                scan = end + 1;

                continue;
            }

            let kind = self.tokens[scan as usize].kind;

            if is_open(kind) || kind == TokenKind::BlockStart {
                depth += 1;
            } else if is_close(kind) || kind == TokenKind::BlockEnd {
                depth = depth.saturating_sub(1);
            } else if depth == 0 && self.wrapping_operator(scan) {
                floor = floor.min(binary_level(self.tokens[scan as usize].text(self.source)));
            }

            scan += 1;
        }

        floor
    }

    pub(super) fn binary_first(&self, head: u32, close: u32) -> Option<u32> {
        let floor = self.binary_floor(head, close);
        let mut depth = 0_u32;
        let mut scan = head;

        while scan < close {
            if let Some(end) = self.spanned_body(scan) {
                scan = end + 1;

                continue;
            }

            let kind = self.tokens[scan as usize].kind;

            if is_open(kind) || kind == TokenKind::BlockStart {
                depth += 1;
            } else if is_close(kind) || kind == TokenKind::BlockEnd {
                depth = depth.saturating_sub(1);
            } else if depth == 0 && self.binary_floored(scan, floor) {
                return Some(scan);
            }

            scan += 1;
        }

        None
    }

    pub(super) fn binary_heavy(&self, head: u32, close: u32, levels: u32) -> bool {
        let Some(first) = self.binary_first(head, close) else {
            return false;
        };

        levels * self.options.indent_width + self.printed_columns(head, first)
            > self.options.line_width
    }

    pub(super) fn logical_operator(&self, position: u32) -> bool {
        self.wrapping_operator(position)
            && binary_level(self.tokens[position as usize].text(self.source)) <= LOGICAL_LEVEL_MAX
    }

    pub(super) fn binary_floored(&self, position: u32, floor: u32) -> bool {
        self.wrapping_operator(position)
            && binary_level(self.tokens[position as usize].text(self.source)) == floor
    }
}

fn binary_level(text: &[u8]) -> u32 {
    match text {
        b"??" => 1,
        b"||" => 2,
        b"&&" => 3,
        b"|" => 4,
        b"^" => 5,
        b"&" => 6,
        b"==" | b"===" | b"!=" | b"!==" => 7,
        b"<" | b">" | b"<=" | b">=" | b"in" | b"instanceof" => 8,
        b"<<" | b">>" | b">>>" => 9,
        b"+" | b"-" => 10,
        b"*" | b"/" | b"%" => 11,
        _ => BINARY_LEVEL_MAX,
    }
}

#[expect(
    clippy::multiple_inherent_impl,
    reason = "the statement walk stands beside the arrow rules that read it"
)]
impl Emitter<'_> {
    fn valued_semicolon(&self, head: u32) -> Option<u32> {
        let mut depth = 0_u32;
        let mut scan = head;

        while scan < self.count {
            if let Some(end) = self.spanned_body(scan) {
                scan = end + 1;

                continue;
            }

            let kind = self.tokens[scan as usize].kind;

            if is_open(kind) || kind == TokenKind::BlockStart {
                depth += 1;
            } else if is_close(kind) || kind == TokenKind::BlockEnd {
                if depth == 0 {
                    return None;
                }

                depth -= 1;
            } else if depth == 0 && kind == TokenKind::Punctuation(Punctuation::Semicolon) {
                return Some(scan);
            }

            scan += 1;
        }

        None
    }
}

#[expect(
    clippy::multiple_inherent_impl,
    reason = "the chain's own composition test reads the argument walks above it"
)]
impl Emitter<'_> {
    pub(super) fn chain_composed(&self, head: u32, stop: u32) -> bool {
        if !self.policy.compose_parts {
            return false;
        }

        let mut breaks = false;
        let mut calls = 0;
        let mut found = false;
        let mut last = 0;
        let mut scan = head;

        while scan <= stop {
            if let Some(end) = self.spanned_body(scan) {
                scan = end + 1;

                continue;
            }

            let kind = self.tokens[scan as usize].kind;

            if is_open(kind) {
                let close = self.closing_of(scan).unwrap_or(stop);

                if kind == TokenKind::Punctuation(Punctuation::ParenOpen) && self.calling(scan) {
                    calls += 1;
                    found = found || self.composes(scan, close);

                    breaks = breaks || last > 0 && self.chain_hardened(last, scan);
                    last = scan;
                }

                scan = close + 1;

                continue;
            }

            scan += 1;
        }

        calls > 2 && found || breaks
    }

    fn chain_hardened(&self, from: u32, to: u32) -> bool {
        let mut scan = from;

        while scan < to {
            if self.tokens[scan as usize].kind == TokenKind::Comment {
                return true;
            }

            if self.tokens[scan as usize].kind == TokenKind::BlockStart
                && self.bodied_brace(scan)
                && self
                    .next_of(scan)
                    .is_some_and(|held| self.tokens[held as usize].kind != TokenKind::BlockEnd)
            {
                return true;
            }

            scan += 1;
        }

        false
    }
}
