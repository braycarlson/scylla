use super::call::LOGICAL_LEVEL_MAX;

const ARGUED_VALUES: bool = false;
const VALUE_WRAPS: bool = true;
use super::{Emitter, Frame, REMARK_COMMAS, VALUE_ARROWS, Wrap, is_close, is_open};
use crate::format::ir::Element;
use crate::format::reach;
use crate::token::{Punctuation, TokenKind};

#[expect(
    clippy::multiple_inherent_impl,
    reason = "the ownership rules are their own family of the emitter and `mod.rs` reaches them"
)]
impl Emitter<'_> {
    pub(super) fn hugs_body(&mut self, position: u32) -> bool {
        if self.spreads() && self.nest[self.depth as usize - 1].open == position {
            return true;
        }

        if self.tokens[position as usize].kind != TokenKind::BlockStart || !self.hugging(position) {
            return true;
        }

        self.document.push(Element::Hugs)
    }

    pub(super) fn hugging(&self, position: u32) -> bool {
        if self.depth < 2 {
            return false;
        }

        let Some(outer) = self.hug_frame() else {
            return false;
        };

        let kind = self.tokens[position as usize].kind;

        if kind != TokenKind::BlockStart && kind != TokenKind::Punctuation(Punctuation::BracketOpen)
        {
            return false;
        }

        if !self.ending(self.nest[self.depth as usize - 1].close, outer.close) {
            return self.policy.body_owns && self.first_hugged(outer.open, outer.close, position);
        }

        let Some(before) = self.word_before(position) else {
            return false;
        };

        if self.tokens[before as usize].kind == TokenKind::Punctuation(Punctuation::Comma) {
            return self.preceding(before) != Some(kind);
        }

        if before == outer.open {
            return true;
        }

        let head = self.argument_start(outer.open, position);

        self.policy.body_owns && head < position && self.functioned(head, outer.close)
    }

    pub(super) fn wrapper_paren(&self, frame: Frame) -> bool {
        frame.close > frame.open && self.wrapper_parens(frame.open, frame.close)
    }

    pub(super) fn wrapper_parens(&self, open: u32, close: u32) -> bool {
        if self.tokens[open as usize].kind != TokenKind::Punctuation(Punctuation::ParenOpen) {
            return false;
        }

        let Some(head) = self.next_of(open).filter(|held| *held < close) else {
            return false;
        };

        if !matches!(
            self.tokens[head as usize].kind,
            TokenKind::BlockStart | TokenKind::Punctuation(Punctuation::BracketOpen)
        ) {
            return false;
        }

        self.closing_of(head)
            .and_then(|held| self.next_of(held))
            .is_some_and(|held| held == close)
    }

    pub(super) fn hug_frame(&self) -> Option<Frame> {
        let mut held = self.depth - 1;

        while held > 0 {
            held -= 1;

            let frame = self.nest[held as usize];

            if frame.kind != TokenKind::Punctuation(Punctuation::ParenOpen) {
                return None;
            }

            if frame.spread.is_some() {
                return Some(frame);
            }

            if !self.policy.body_owns {
                return None;
            }
        }

        None
    }

    fn ending(&self, position: u32, close: u32) -> bool {
        let Some(next) = self.next_of(position) else {
            return false;
        };

        let cast = matches!(
            self.tokens[next as usize].text(self.source),
            b"as" | b"satisfies"
        );
        let mut angles = 0_u32;
        let mut brackets = 0_u32;
        let mut scan = if cast { self.next_of(next) } else { Some(next) };

        while let Some(held) = scan {
            if held == close {
                return true;
            }

            let token = self.tokens[held as usize];

            if self.policy.body_owns
                && token.kind == TokenKind::Punctuation(Punctuation::ParenClose)
            {
                scan = self.next_of(held);

                continue;
            }
            let text = token.text(self.source);
            let nested = angles > 0 || brackets > 0;

            if !nested && token.kind == TokenKind::Punctuation(Punctuation::Comma) {
                return self.next_of(held) == Some(close);
            }

            if !cast {
                return false;
            }

            let typed = token.kind == TokenKind::Identifier
                || matches!(text, b"." | b"<" | b">" | b"[" | b"]" | b"|" | b"&" | b",");

            if !typed {
                return false;
            }

            Self::opened_type(text, &mut angles, &mut brackets);

            scan = self.next_of(held);
        }

        false
    }

    pub(super) fn bodied_value(&self, position: u32, close: u32) -> bool {
        if !self.policy.body_owns {
            return false;
        }

        let mut scan = position + 1;

        while scan < close {
            let kind = self.tokens[scan as usize].kind;

            if kind == TokenKind::Punctuation(Punctuation::ParenOpen)
                && self
                    .closing_of(scan)
                    .is_some_and(|held| self.wrapper_parens(scan, held))
            {
                return true;
            }

            if kind == TokenKind::BlockStart {
                let void = self
                    .next_of(scan)
                    .is_some_and(|held| self.tokens[held as usize].kind == TokenKind::BlockEnd);

                if !void && self.bodied_brace(scan) {
                    return true;
                }
            }

            scan += 1;
        }

        false
    }

    pub(super) fn valued_arrow(&self, position: u32, end: u32) -> Option<u32> {
        if !VALUE_ARROWS || !self.policy.arrow_bodies {
            return None;
        }

        let head = self.next_of(position).filter(|held| *held < end)?;

        if !self.functioned(head, end) {
            return None;
        }

        let mut depth = 0_u32;
        let mut scan = head;

        while scan < end {
            let token = self.tokens[scan as usize];

            if is_open(token.kind) || token.kind == TokenKind::BlockStart {
                depth += 1;
            } else if is_close(token.kind) || token.kind == TokenKind::BlockEnd {
                depth = depth.saturating_sub(1);
            } else if depth == 0 && token.text(self.source) == b"=>" {
                let body = self.next_of(scan).filter(|after| *after < end)?;

                return (!self.bodied_arrow(body)).then_some(scan);
            }

            scan += 1;
        }

        None
    }

    pub(super) fn trailed_comma(&self, position: u32) -> bool {
        if !REMARK_COMMAS || !self.policy.comma_adds || self.depth == 0 {
            return false;
        }

        let frame = self.nest[self.depth as usize - 1];
        let Some(remark) = self.next_of(position) else {
            return false;
        };

        if self.tokens[remark as usize].kind != TokenKind::Comment
            || !self.tokens[remark as usize]
                .text(self.source)
                .starts_with(b"//")
        {
            return false;
        }

        if self.next_of(remark) != Some(frame.close) || !self.listed(frame.close) {
            return false;
        }

        if !self.spreads() && !self.parts_at(position, frame.close) {
            return false;
        }

        !matches!(
            self.tokens[position as usize].kind,
            TokenKind::Punctuation(Punctuation::Comma | Punctuation::Semicolon)
                | TokenKind::Comment
        ) && !is_open(self.tokens[position as usize].kind)
    }

    pub(super) fn trailed_already(&self, close: u32) -> bool {
        let Some(remark) = self.word_before(close) else {
            return false;
        };

        if self.tokens[remark as usize].kind != TokenKind::Comment {
            return false;
        }

        let Some(held) = self.word_before(remark) else {
            return false;
        };

        self.trailed_comma(held)
            || matches!(
                self.tokens[held as usize].kind,
                TokenKind::Punctuation(Punctuation::Comma | Punctuation::Semicolon)
            )
    }

    #[expect(
        clippy::too_many_lines,
        reason = "the walk names every token an assignment's value may hold, and splitting it \
                  would hide the one loop the rule is"
    )]
    pub(super) fn assigning(&self, position: u32) -> Option<(u32, u32)> {
        if !self.policy.assign_groups || self.assigned.is_some() || self.owned_assign(position) {
            return None;
        }

        if self.typed || self.assign_wrap(position).is_some() {
            return None;
        }

        let text = self.tokens[position as usize].text(self.source);

        if text != b"=" {
            return None;
        }

        let held = self.depth > 0 && self.frame().kind != TokenKind::BlockStart;

        if held || !self.opened_above(position) {
            return None;
        }

        if !reach::opening_statement(self.source, self.tokens, position) {
            return None;
        }

        if let Some(arrowed) = self.assign_arrow(position) {
            return Some(arrowed);
        }

        if self
            .next_of(position)
            .is_some_and(|start| self.ternary_owns(start))
        {
            return self.assign_ternaried(position);
        }

        let breaks = self.assign_breaks(position);
        let mut close = None;
        let mut previous = None;
        let mut scan = position + 1;

        while scan < self.count {
            let token = self.tokens[scan as usize];

            if token.kind == TokenKind::Newline || token.length == 0 {
                scan += 1;

                continue;
            }

            let broken = previous.is_some_and(|last| {
                self.parts_at(last, scan) && !self.semicolon_joined(scan, last)
            });

            if is_close(token.kind) {
                return None;
            }

            if !broken && token.kind == TokenKind::Punctuation(Punctuation::Semicolon) {
                let alone = self.next_of(scan).is_none_or(|after| {
                    self.parts_at(scan, after)
                        || self.ends_body(after)
                        || self.inside_a_body() && self.parted_statement(scan)
                });

                return alone.then_some((close.unwrap_or(scan), scan));
            }

            if token.kind == TokenKind::Comment
                || broken
                || token.text(self.source).contains(&b'\n')
                || !breaks && self.chain_parts(scan, scan)
            {
                return None;
            }

            if let Some(end) = self.template_body(scan).or_else(|| self.jsx_body(scan)) {
                if self.parts_at(scan, end) {
                    return None;
                }

                previous = Some(scan);
                scan = end + 1;

                continue;
            }

            if let Some(closes) = self.parened(scan) {
                previous = Some(closes);
                scan = closes + 1;

                continue;
            }

            if is_open(token.kind) {
                let holds = self.assign_holds(scan, breaks, close.is_some());

                let Some(closes) = holds else {
                    if !self.policy.assign_lines {
                        return None;
                    }

                    let ends = self.closing_of(scan)?;

                    let braced = (scan..ends)
                        .any(|at| self.tokens[at as usize].kind == TokenKind::BlockStart);

                    if braced
                        || self.parted_by(
                            self.tokens[scan as usize].end(),
                            self.tokens[ends as usize].offset,
                        ) > 0
                    {
                        return None;
                    }

                    if close.is_none() && !self.slight(scan, ends) {
                        close = Some(scan);
                    }

                    previous = Some(ends);
                    scan = ends + 1;

                    continue;
                };

                if self.bodied_value(scan, closes) {
                    return None;
                }

                if !self.slight(scan, closes) {
                    close = Some(scan);
                }

                previous = Some(closes);
                scan = closes + 1;

                continue;
            }

            previous = Some(scan);
            scan += 1;
        }

        None
    }

    fn assign_arrow(&self, position: u32) -> Option<(u32, u32)> {
        if !self.policy.assign_lines || self.typed || self.typed_frame() {
            return None;
        }

        let mut depth = 0_u32;
        let mut scan = position + 1;

        while scan < self.count {
            if let Some(end) = self.template_body(scan).or_else(|| self.jsx_body(scan)) {
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
                let arrow = self.valued_arrow(position, scan)?;

                return Some((arrow, scan));
            }

            scan += 1;
        }

        None
    }

    pub(super) fn assign_wrap(&self, position: u32) -> Option<(u32, Wrap)> {
        if !VALUE_WRAPS || !self.policy.assign_lines || self.assigned.is_some() {
            return None;
        }

        if self.tokens[position as usize].kind != TokenKind::Punctuation(Punctuation::Assign) {
            return None;
        }

        if self.depth > 0 && self.frame().kind != TokenKind::BlockStart {
            return None;
        }

        let head = self.next_of(position)?;
        let end = self.valued_semicolon(head)?;
        let stop = self.back_of(end)?;

        if stop <= head || !self.valued_binary(head, stop) {
            return None;
        }

        if self.binary_floor(head, stop) <= LOGICAL_LEVEL_MAX && self.binary_inlined(stop) {
            return None;
        }

        Some((stop, Wrap::Valued))
    }

    pub(super) fn value_wrap(&self, position: u32) -> Option<(u32, Wrap)> {
        if !VALUE_WRAPS || !self.policy.assign_lines || self.depth == 0 {
            return None;
        }

        let before = self.back_of(position)?;
        let kind = self.tokens[before as usize].kind;

        let paired = kind == TokenKind::Punctuation(Punctuation::Colon)
            && self.policy.colon_continues
            && self.frame().kind == TokenKind::BlockStart
            && !self.ternary(before)
            && self.valued_object();

        let valued = kind == TokenKind::Punctuation(Punctuation::Assign);

        let argued = ARGUED_VALUES
            && !paired
            && !valued
            && self.spreads()
            && matches!(
                kind,
                TokenKind::Punctuation(Punctuation::Comma | Punctuation::ParenOpen)
            )
            && self.frame().kind == TokenKind::Punctuation(Punctuation::ParenOpen);

        let grouped = self.policy.spread_owns
            && !paired
            && !valued
            && !argued
            && kind == TokenKind::Punctuation(Punctuation::ParenOpen)
            && self.frame().kind == TokenKind::Punctuation(Punctuation::ParenOpen)
            && self.frame().open == before
            && !self.calling(before)
            && !self.headed(before)
            && self.back_of(before).is_none_or(|held| {
                !matches!(
                    self.tokens[held as usize].text(self.source),
                    b"return" | b"throw"
                )
            });

        if !paired && !valued && !argued && !grouped {
            return None;
        }

        if grouped {
            let close = self.frame().close;
            let stop = self.back_of(close)?;

            if stop <= position || !self.valued_binary(position, stop) {
                return None;
            }

            return Some((stop, Wrap::Argued));
        }

        let end = if paired || argued {
            self.valued_element(position)?
        } else {
            if self.frame().kind != TokenKind::BlockStart {
                return None;
            }

            self.valued_semicolon(position)?
        };

        let stop = self.back_of(end)?;

        if stop <= position {
            return None;
        }

        if let Some(question) = self.valued_question(position, stop) {
            let last = self.back_of(question)?;

            return (last > position && self.valued_binary(position, last))
                .then_some((last, Wrap::Paired));
        }

        if !(paired || argued) || !self.valued_binary(position, stop) {
            return None;
        }

        if self.binary_floor(position, stop) <= LOGICAL_LEVEL_MAX && self.binary_inlined(stop) {
            return None;
        }

        let wrap = if argued { Wrap::Argued } else { Wrap::Paired };

        Some((stop, wrap))
    }

    pub(super) fn value_joined(&self, position: u32, previous: u32) -> bool {
        if !self.policy.assign_lines
            || self.tokens[previous as usize].kind != TokenKind::Punctuation(Punctuation::Assign)
            || self.line_first > previous
        {
            return false;
        }

        let held = self.value_lead(position);

        let Some(last) = held else {
            return false;
        };

        let width = self.printed_columns(self.line_first, last);

        self.printed * self.options.indent_width + width <= self.options.line_width
    }

    fn value_lead(&self, position: u32) -> Option<u32> {
        let end = self.valued_semicolon(position)?;
        let stop = self.back_of(end)?;
        let question = self.valued_question(position, stop)?;
        let last = self.back_of(question)?;

        (last >= position && !self.valued_binary(position, last)).then_some(last)
    }

    fn valued_question(&self, head: u32, stop: u32) -> Option<u32> {
        let mut depth = 0_u32;
        let mut scan = head;

        while scan <= stop {
            if let Some(end) = self.spanned_body(scan).or_else(|| self.spanned_unit(scan)) {
                scan = end + 1;

                continue;
            }

            let kind = self.tokens[scan as usize].kind;

            if is_open(kind) || kind == TokenKind::BlockStart {
                depth += 1;
            } else if is_close(kind) || kind == TokenKind::BlockEnd {
                depth = depth.saturating_sub(1);
            } else if depth == 0
                && self.tokens[scan as usize].text(self.source) == b"?"
                && !self.optional(scan)
            {
                return Some(scan);
            }

            scan += 1;
        }

        None
    }

    fn valued_object(&self) -> bool {
        let frame = self.frame();

        if frame.kind != TokenKind::BlockStart {
            return false;
        }

        self.word_before(frame.open)
            .is_some_and(|before| self.objected(before, self.tokens[before as usize]))
    }

    fn valued_element(&self, head: u32) -> Option<u32> {
        let close = self.frame().close;
        let mut depth = 0_u32;
        let mut scan = head;

        while scan < close {
            if let Some(end) = self.spanned_unit(scan) {
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
            } else if depth == 0 && kind == TokenKind::Punctuation(Punctuation::Comma) {
                return Some(scan);
            }

            scan += 1;
        }

        (close > head).then_some(close)
    }

    fn valued_leveled(&self, head: u32, stop: u32) -> bool {
        let floor = self.binary_floor(head, stop);
        let mut depth = 0_u32;
        let mut scan = head;

        while scan <= stop {
            if let Some(end) = self.spanned_body(scan).or_else(|| self.spanned_unit(scan)) {
                scan = end + 1;

                continue;
            }

            let kind = self.tokens[scan as usize].kind;

            if is_open(kind) || kind == TokenKind::BlockStart {
                depth += 1;
            } else if is_close(kind) || kind == TokenKind::BlockEnd {
                depth = depth.saturating_sub(1);
            } else if depth == 0
                && self.wrapping_operator(scan)
                && !self.binary_floored(scan, floor)
            {
                return false;
            }

            scan += 1;
        }

        true
    }

    fn valued_binary(&self, head: u32, stop: u32) -> bool {
        let mut depth = 0_u32;
        let mut found = false;
        let mut scan = head;

        while scan <= stop {
            if let Some(end) = self.spanned_body(scan).or_else(|| self.spanned_unit(scan)) {
                scan = end + 1;

                continue;
            }

            let token = self.tokens[scan as usize];
            let kind = token.kind;

            if is_open(kind) || kind == TokenKind::BlockStart {
                depth += 1;
            } else if is_close(kind) || kind == TokenKind::BlockEnd {
                depth = depth.saturating_sub(1);
            } else if depth == 0 {
                let text = token.text(self.source);

                if text == b"?" && !self.optional(scan)
                    || text == b"=>"
                    || text == b","
                    || text == b"="
                {
                    return false;
                }

                if self.wrapping_operator(scan) {
                    found = true;
                }
            }

            scan += 1;
        }

        found
    }

    fn opened_above(&self, position: u32) -> bool {
        (0..self.depth).all(|scan| {
            let open = self.nest[scan as usize].open;

            self.parts_at(open, position) || self.parting(open, position)
        })
    }

    pub(super) fn parened(&self, position: u32) -> Option<u32> {
        if !self.policy.arrow_parens
            || self.tokens[position as usize].kind != TokenKind::Punctuation(Punctuation::ParenOpen)
        {
            return None;
        }

        let held = self.next_of(position)?;

        if self.tokens[held as usize].kind != TokenKind::Identifier {
            return None;
        }

        let mut close = self.next_of(held)?;

        if self.tokens[close as usize].kind == TokenKind::Punctuation(Punctuation::Comma) {
            close = self.next_of(close)?;
        }

        if self.tokens[close as usize].kind != TokenKind::Punctuation(Punctuation::ParenClose) {
            return None;
        }

        let arrow = self.next_of(close)?;

        (self.tokens[arrow as usize].text(self.source) == b"=>").then_some(close)
    }
}
