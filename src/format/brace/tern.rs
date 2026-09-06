use super::{Emitter, WRAP_DEPTH_MAX, Wrap, is_close, is_open};
use crate::format::ir::Element;
use crate::token::{Punctuation, TokenKind};

const TERNARY_SCAN_MAX: u32 = 1 << 14;

const BINARY_OPERATORS: [&[u8]; 18] = [
    b"!=",
    b"!==",
    b"%",
    b"&",
    b"&&",
    b"*",
    b"**",
    b"+",
    b"-",
    b"/",
    b"==",
    b"===",
    b"^",
    b"in",
    b"instanceof",
    b"|",
    b"||",
    b"??",
];

#[expect(
    clippy::multiple_inherent_impl,
    reason = "the ternary rules are their own family of the emitter and `mod.rs` reaches them"
)]
impl Emitter<'_> {
    pub(super) fn ternaried(&self, position: u32, previous: u32) -> bool {
        if !self.policy.ternary_colon {
            return false;
        }

        let colon = TokenKind::Punctuation(Punctuation::Colon);

        self.tokens[position as usize].kind == colon && self.ternary(position)
            || self.tokens[previous as usize].kind == colon && self.ternary(previous)
    }

    pub(super) fn ternary(&self, colon: u32) -> bool {
        let stop = if self.depth == 0 {
            0
        } else {
            self.frame().open
        };

        let mut depth = 0_u32;
        let mut owed = 0_u32;
        let mut scan = colon;

        while scan > stop {
            scan -= 1;

            let kind = self.tokens[scan as usize].kind;

            if is_close(kind) {
                let jumped = self
                    .brackets
                    .open_of(scan)
                    .filter(|open| depth == 0 && is_open(self.tokens[*open as usize].kind));

                if let Some(open) = jumped {
                    scan = open;

                    continue;
                }

                depth += 1;

                continue;
            }

            if is_open(kind) {
                depth = depth.saturating_sub(1);

                continue;
            }

            if depth > 0 {
                continue;
            }

            let bytes = self.tokens[scan as usize].text(self.source);

            if bytes == b";" {
                return false;
            }

            if bytes == b":" {
                owed += 1;

                continue;
            }

            if bytes == b"?" && !self.optional(scan) {
                if owed == 0 {
                    return true;
                }

                owed -= 1;
            }
        }

        false
    }

    pub(super) fn optional(&self, position: u32) -> bool {
        self.next_of(position).is_some_and(|held| {
            let kind = self.tokens[held as usize].kind;

            let signed = kind == TokenKind::Punctuation(Punctuation::ParenOpen)
                && self.tokens[position as usize].end() == self.tokens[held as usize].offset;

            is_close(kind)
                || signed
                || matches!(
                    kind,
                    TokenKind::Punctuation(
                        Punctuation::Colon | Punctuation::Comma | Punctuation::Semicolon
                    )
                )
        })
    }

    pub(super) fn ternary_level(&self, position: u32) -> Option<u32> {
        if !self.policy.ternary_levels {
            return None;
        }

        let text = self.tokens[position as usize].text(self.source);

        let branched = if text == b"?" {
            !self.optional(position)
        } else {
            text == b":" && self.ternary(position)
        };

        if !branched {
            return None;
        }

        let head = self.ternary_test(position);
        let opens = self.line_opened(head).unwrap_or(head);

        Some(self.line_level(opens).unwrap_or(self.levels) + 1)
    }

    fn ternary_test(&self, position: u32) -> u32 {
        let mut head = position;
        let mut owed = u32::from(self.tokens[position as usize].text(self.source) == b":");

        for _ in 0..TERNARY_SCAN_MAX {
            let Some(before) = self.back_of(head) else {
                break;
            };

            let kind = self.tokens[before as usize].kind;
            let text = self.tokens[before as usize].text(self.source);

            if is_close(kind) || kind == TokenKind::BlockEnd {
                let Some(open) = self.brackets.open_of(before) else {
                    break;
                };

                head = open;

                continue;
            }

            if text == b"?" && !self.optional(before) {
                if owed == 0 {
                    break;
                }

                owed -= 1;
                head = before;

                continue;
            }

            if text == b":" && self.ternary(before) {
                if owed == 0 {
                    break;
                }

                owed += 1;
                head = before;

                continue;
            }

            if is_open(kind)
                || kind == TokenKind::BlockStart
                || kind == TokenKind::Comment
                || matches!(
                    kind,
                    TokenKind::Punctuation(
                        Punctuation::Assign | Punctuation::Comma | Punctuation::Semicolon
                    )
                )
                || matches!(text, b"=>" | b"return" | b"throw" | b"case")
            {
                break;
            }

            head = before;
        }

        head
    }

    pub(super) fn typed_frame(&self) -> bool {
        if self.policy.type_words.is_empty() {
            return false;
        }

        let mut depth = self.depth;

        while depth > 0 {
            let frame = self.nest[depth as usize - 1];

            if self.typing(self.union_head(frame.open)) {
                return true;
            }

            depth -= 1;
        }

        false
    }

    pub(super) fn ternary_opens(&mut self, position: u32) -> bool {
        if self.wraps_owed == WRAP_DEPTH_MAX {
            return true;
        }

        let Some((close, question)) = self.ternary_headed(position) else {
            return true;
        };

        self.wrapped[self.wraps_owed as usize] =
            (close, Wrap::Ternary, self.depth, question, position);
        self.wraps_owed += 1;

        self.document.push(Element::GroupOpen)
    }

    pub(super) fn ternary_owns(&self, position: u32) -> bool {
        self.ternary_headed(position).is_some()
    }

    pub(super) fn assign_ternaried(&self, position: u32) -> Option<(u32, u32)> {
        let head = self.next_of(position)?;
        let (close, question) = self.ternary_headed(head)?;
        let end = self.next_of(close)?;

        if self.tokens[end as usize].kind != TokenKind::Punctuation(Punctuation::Semicolon) {
            return None;
        }

        if !self.ternary_binary(head, question) {
            return None;
        }

        let colon = self.ternary_branch(question)?;
        let written = self.parted_by(
            self.tokens[head as usize].end(),
            self.tokens[close as usize].offset,
        );

        let owned = self.ternary_parted_at(question) + self.ternary_parted_at(colon);

        (written == owned).then_some((end, end))
    }

    fn ternary_parted_at(&self, position: u32) -> u32 {
        let Some(before) = self.back_of(position) else {
            return 0;
        };

        self.parted_by(
            self.tokens[before as usize].end(),
            self.tokens[position as usize].offset,
        )
    }

    fn ternary_binary(&self, head: u32, question: u32) -> bool {
        let mut scan = head;

        while scan < question {
            let token = self.tokens[scan as usize];

            if let Some(end) = self.spanned_unit(scan) {
                scan = end + 1;

                continue;
            }

            if is_open(token.kind) || token.kind == TokenKind::BlockStart {
                let Some(end) = self.closing_of(scan) else {
                    return false;
                };

                scan = end + 1;

                continue;
            }

            if BINARY_OPERATORS.contains(&token.text(self.source)) {
                return true;
            }

            scan += 1;
        }

        false
    }

    fn ternary_headed(&self, position: u32) -> Option<(u32, u32)> {
        if !self.policy.ternary_parts {
            return None;
        }

        let question = self.ternary_ahead(position)?;

        if self.ternary_head(question) != Some(position) {
            return None;
        }

        if self.typing_ahead(position, question) {
            return None;
        }

        let colon = self.ternary_branch(question)?;
        let close = self.ternary_end(colon)?;

        if self.ternary_linked(question, colon)
            || self.ternary_linked(colon, close + 1)
            || self.ternary_chained(question)
        {
            return None;
        }

        if self.sequenced(close) || !self.ternary_seated() {
            return None;
        }

        Some((close, question))
    }

    fn ternary_seated(&self) -> bool {
        let mut depth = self.depth;

        while depth > 0 {
            let frame = self.nest[depth as usize - 1];

            if frame.kind == TokenKind::BlockStart {
                return true;
            }

            if frame.spread.is_none() {
                return false;
            }

            depth -= 1;
        }

        true
    }

    fn sequenced(&self, close: u32) -> bool {
        if self.depth == 0 {
            return false;
        }

        let frame = self.frame();

        if frame.kind != TokenKind::Punctuation(Punctuation::ParenOpen) || self.calling(frame.open)
        {
            return false;
        }

        self.next_of(close).is_some_and(|held| {
            self.tokens[held as usize].kind == TokenKind::Punctuation(Punctuation::Comma)
        })
    }

    fn ternary_head(&self, question: u32) -> Option<u32> {
        let mut head = question;

        for _ in 0..TERNARY_SCAN_MAX {
            let Some(before) = self.back_of(head) else {
                break;
            };

            let token = self.tokens[before as usize];
            let text = token.text(self.source);

            if is_open(token.kind)
                || token.kind == TokenKind::BlockStart
                || token.kind == TokenKind::BlockEnd
                || token.kind == TokenKind::Comment
            {
                break;
            }

            if is_close(token.kind) {
                head = self.brackets.open_of(before)?;

                continue;
            }

            let ended = matches!(
                token.kind,
                TokenKind::Punctuation(
                    Punctuation::Assign | Punctuation::Comma | Punctuation::Semicolon
                )
            ) || text.ends_with(b"=")
                && !matches!(text, b"==" | b"===" | b"!=" | b"!==" | b">=" | b"<=")
                || matches!(text, b"=>" | b"return" | b"throw" | b"case" | b"?" | b":");

            if ended {
                break;
            }

            head = before;
        }

        (head != question).then_some(head)
    }

    fn ternary_ahead(&self, position: u32) -> Option<u32> {
        let mut scan = position;

        while scan < self.count && scan - position < TERNARY_SCAN_MAX {
            let token = self.tokens[scan as usize];

            if let Some(end) = self.spanned_unit(scan) {
                scan = end + 1;

                continue;
            }

            if token.kind == TokenKind::BlockStart {
                return None;
            }

            if is_open(token.kind) {
                scan = self.closing_of(scan)? + 1;

                continue;
            }

            if is_close(token.kind) || token.kind == TokenKind::BlockEnd {
                return None;
            }

            let text = token.text(self.source);

            if matches!(text, b";" | b",") || token.kind == TokenKind::Comment {
                return None;
            }

            if text == b"?" && !self.optional(scan) {
                return Some(scan);
            }

            scan += 1;
        }

        None
    }

    pub(super) fn ternary_leads(&mut self, position: u32) -> bool {
        if !self.ternary_parted(position) {
            return true;
        }

        if self.tokens[position as usize].text(self.source) == b"?" {
            return self.document.push(Element::IndentBroken);
        }

        self.document.push(Element::Dealign)
    }

    pub(super) fn ternary_aligns(&mut self, position: u32) -> bool {
        !self.ternary_parted(position) || self.document.push(Element::Align)
    }

    pub(super) fn ternary_parted(&self, position: u32) -> bool {
        if !self.policy.ternary_parts || self.wraps_owed == 0 {
            return false;
        }

        let text = self.tokens[position as usize].text(self.source);

        if text != b"?" && text != b":" {
            return false;
        }

        (0..self.wraps_owed).rev().any(|held| {
            let (close, wrap, _, question, _) = self.wrapped[held as usize];

            wrap == Wrap::Ternary
                && position <= close
                && (position == question || self.ternary_branch(question) == Some(position))
        })
    }

    fn ternary_branch(&self, question: u32) -> Option<u32> {
        let mut owed = 0_u32;
        let mut scan = question + 1;

        while scan < self.count {
            let token = self.tokens[scan as usize];

            if let Some(end) = self.spanned_unit(scan) {
                scan = end + 1;

                continue;
            }

            if is_open(token.kind) || token.kind == TokenKind::BlockStart {
                scan = self.closing_of(scan)? + 1;

                continue;
            }

            if is_close(token.kind) || token.kind == TokenKind::BlockEnd {
                return None;
            }

            let text = token.text(self.source);

            if text == b";" {
                return None;
            }

            if text == b"?" && !self.optional(scan) {
                owed += 1;
            } else if token.kind == TokenKind::Punctuation(Punctuation::Colon) {
                if owed == 0 {
                    return Some(scan);
                }

                owed -= 1;
            }

            scan += 1;
        }

        None
    }

    fn ternary_end(&self, colon: u32) -> Option<u32> {
        let mut held = None;
        let mut scan = colon + 1;

        while scan < self.count {
            let token = self.tokens[scan as usize];

            if let Some(end) = self.spanned_unit(scan) {
                held = Some(end);
                scan = end + 1;

                continue;
            }

            if is_open(token.kind) || token.kind == TokenKind::BlockStart {
                let end = self.closing_of(scan)?;

                held = Some(end);
                scan = end + 1;

                continue;
            }

            if is_close(token.kind) || token.kind == TokenKind::BlockEnd {
                return held;
            }

            let text = token.text(self.source);

            if matches!(text, b";" | b",") || token.kind == TokenKind::Comment {
                return held;
            }

            held = Some(scan);
            scan += 1;
        }

        held
    }

    fn ternary_chained(&self, question: u32) -> bool {
        let Some(head) = self.ternary_head(question) else {
            return true;
        };

        self.back_of(head).is_some_and(|held| {
            let text = self.tokens[held as usize].text(self.source);

            text == b"?" && !self.optional(held) || text == b":" && self.ternary(held)
        })
    }

    fn ternary_linked(&self, from: u32, to: u32) -> bool {
        let mut scan = from + 1;

        while scan < to {
            let token = self.tokens[scan as usize];

            if let Some(end) = self.spanned_unit(scan) {
                scan = end + 1;

                continue;
            }

            if is_open(token.kind) || token.kind == TokenKind::BlockStart {
                let Some(end) = self.closing_of(scan) else {
                    return true;
                };

                scan = end + 1;

                continue;
            }

            if token.text(self.source) == b"?" && !self.optional(scan) {
                return true;
            }

            scan += 1;
        }

        false
    }

    fn typing_ahead(&self, head: u32, question: u32) -> bool {
        (head..question).any(|held| self.word_is(held, &[b"extends"]))
    }
}
