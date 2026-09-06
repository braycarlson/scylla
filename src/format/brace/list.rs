use super::{
    ANGLE_SCAN_MAX,
    BRACKET_BLANKS,
    Emitter,
    NEST_DEPTH_MAX,
    Spread,
    Wrap,
    count_of,
    is_close,
    is_open,
    wide,
};
use crate::format::ir::Element;
use crate::token::{Punctuation, TokenKind};

#[expect(
    clippy::multiple_inherent_impl,
    reason = "the list rules are their own family of the emitter and `mod.rs` reaches them"
)]
impl Emitter<'_> {
    pub(super) fn membered(&self, position: u32) -> bool {
        self.typed
            && self.depth > 0
            && self.tokens[position as usize].kind == TokenKind::Punctuation(Punctuation::Comma)
            && self.frame().kind == TokenKind::BlockStart
            && !self.angled(position)
    }

    pub(super) fn angled(&self, position: u32) -> bool {
        self.depth > 0 && self.brackets.angles_at(position) > 0
    }

    pub(super) fn importing(&self, position: u32) -> Option<u32> {
        let led = self
            .word_before(position)
            .is_some_and(|lead| self.word_is(lead, self.policy.list_leads));

        let headed =
            self.word_is(self.line_first, self.policy.list_words) || self.policy.list_sorts && led;

        if !self.policy.list_groups
            || self.tokens[position as usize].kind != TokenKind::BlockStart
            || !headed
        {
            return None;
        }

        if !led {
            return None;
        }

        let close = self.closing(position)?;
        let mut names = 0;
        let mut scan = position + 1;

        while scan < close {
            let kind = self.tokens[scan as usize].kind;

            let nested =
                wide::LIST_NESTS && matches!(kind, TokenKind::BlockStart | TokenKind::BlockEnd);

            if !nested
                && !matches!(
                    kind,
                    TokenKind::Identifier
                        | TokenKind::Keyword(_)
                        | TokenKind::Newline
                        | TokenKind::Punctuation(Punctuation::Comma)
                )
                && !self.word_is(scan, self.policy.list_tight)
            {
                return None;
            }

            names += u32::from(matches!(
                kind,
                TokenKind::Identifier | TokenKind::Keyword(_)
            ));
            scan += 1;
        }

        if names == 0 {
            return None;
        }

        let room = self
            .options
            .line_width
            .saturating_sub(self.indent_of(position) + self.options.indent_width);

        let mut item = position + 1;

        while item < close {
            let stop = self.parted_at(item, close);
            let held = self.list_depth(item, stop);

            let opaque = if wide::LIST_WIDES {
                held > 1 || held == 1 && self.flat_columns(item, stop) > room
            } else {
                held > 1 || self.flat_columns(item, stop) > room
            };

            if item < stop && opaque {
                return None;
            }

            item = stop + 1;
        }

        Some(close)
    }

    pub(super) fn spreading(&self, position: u32, close: u32) -> Option<Spread> {
        let listed = self.policy.width_lists && self.listed(close);
        let grouped = self.paren_grouped(position, close) || self.bracket_grouped(position, close);

        if !(listed
            || grouped
            || self.define_parted(position) && self.define_settled(position, close))
        {
            return None;
        }

        if self.joined_args(position, close)
            || self.sequence_spread(position)
            || self.pattern_brace(position, close)
        {
            return None;
        }

        if wide::RETURN_BLOCKS && self.returned_parted(close) {
            return None;
        }

        let mut inside = false;

        for held in 0..self.depth {
            let frame = self.nest[held as usize];

            if frame.spread.is_some() {
                inside = true;

                continue;
            }

            if self.headed_loop(frame.open) {
                continue;
            }

            let owned = self.policy.body_owns && (frame.bodied || self.wrapper_paren(frame))
                || frame.joined;

            if inside && !owned && !self.policy.spread_owns {
                return None;
            }

            if owned {
                continue;
            }

            let broken = (held..self.depth).any(|at| self.nest[at as usize].parted);

            if !broken
                && !self.policy.spread_owns
                && !self.parts_at(frame.open, position)
                && !self.parting(frame.open, position)
            {
                return None;
            }
        }

        if !self.guarded(position, close)
            || !self.settled(position, close)
            || !self.elements(position, close)
        {
            return None;
        }

        if self.headed(position) {
            if self.claused_header(position, close) {
                return Some(Spread::Clauses);
            }

            if self.headed_loop(position) {
                return None;
            }

            return Some(Spread::Chain);
        }

        let bracketed =
            self.tokens[position as usize].kind == TokenKind::Punctuation(Punctuation::BracketOpen);

        if bracketed && self.numeric(position, close) {
            return Some(Spread::Fill);
        }

        Some(Spread::Members)
    }

    pub(super) fn paren_grouped(&self, open: u32, close: u32) -> bool {
        if !self.policy.chain_simples
            || self.tokens[open as usize].kind != TokenKind::Punctuation(Punctuation::ParenOpen)
            || self.calling(open)
            || self.headed(open)
        {
            return false;
        }

        let unary = self.back_of(open).is_some_and(|held| {
            matches!(self.tokens[held as usize].text(self.source), b"!" | b"~")
        });

        let membered = self.next_of(close).is_some_and(|held| {
            self.is_dot(held)
                || matches!(
                    self.tokens[held as usize].kind,
                    TokenKind::Punctuation(Punctuation::BracketOpen | Punctuation::ParenOpen)
                )
        });

        if !unary && !membered {
            return false;
        }

        let mut depth = 0_u32;
        let mut found = false;
        let mut scan = open + 1;

        while scan < close {
            if let Some(end) = self.spanned_unit(scan) {
                scan = end + 1;

                continue;
            }

            let kind = self.tokens[scan as usize].kind;

            if is_open(kind) || kind == TokenKind::BlockStart {
                depth += 1;
            } else if is_close(kind) || kind == TokenKind::BlockEnd {
                depth = depth.saturating_sub(1);
            } else if depth == 0 {
                if matches!(
                    self.tokens[scan as usize].kind,
                    TokenKind::Punctuation(Punctuation::Comma | Punctuation::Semicolon)
                ) || self.tokens[scan as usize].text(self.source) == b"=>"
                {
                    return false;
                }

                found = found || self.wrapping_operator(scan);
            }

            scan += 1;
        }

        found
    }

    pub(super) fn bracket_grouped(&self, open: u32, close: u32) -> bool {
        self.policy.chain_simples
            && self.tokens[open as usize].kind == TokenKind::Punctuation(Punctuation::BracketOpen)
            && self.next_of(open) != Some(close)
            && self
                .word_before(open)
                .is_some_and(|held| self.tokens[held as usize].ends_a_value())
            && self.next_of(close).is_some_and(|held| {
                self.tokens[held as usize].kind == TokenKind::Punctuation(Punctuation::Assign)
            })
    }

    fn guarded(&self, position: u32, close: u32) -> bool {
        let kind = self.tokens[position as usize].kind;

        if kind == TokenKind::Punctuation(Punctuation::ParenOpen) {
            if self.clause_seated(position) {
                return false;
            }

            let closed = self.policy.chain_simples
                && self.word_before(position).is_some_and(|held| {
                    matches!(
                        self.tokens[held as usize].kind,
                        TokenKind::Punctuation(Punctuation::BracketClose | Punctuation::ParenClose)
                    )
                });

            return self.calling(position)
                || closed
                || self.headed(position)
                || self.define_parted(position)
                || self.spread_arrows(position)
                || self.paren_grouped(position, close);
        }

        if kind != TokenKind::Punctuation(Punctuation::BracketOpen) {
            return true;
        }

        if self.bracket_grouped(position, close) {
            return true;
        }

        let keyed = !self.branched_list(position)
            && self.next_of(close).is_some_and(|held| {
                matches!(
                    self.tokens[held as usize].kind,
                    TokenKind::Punctuation(Punctuation::Colon | Punctuation::ParenOpen)
                )
            });

        let typed = self
            .word_before(position)
            .is_none_or(|held| self.tokens[held as usize].text(self.source) != b">");

        !keyed && typed
    }

    fn grouped_paren(&self, open: u32) -> bool {
        if self.tokens[open as usize].kind != TokenKind::Punctuation(Punctuation::ParenOpen) {
            return false;
        }

        self.next_of(open)
            .and_then(|held| self.value_wrap(held))
            .is_some_and(|(_, wrap)| wrap == Wrap::Argued)
    }

    fn headed_loop(&self, open: u32) -> bool {
        self.policy.chain_simples
            && self.headed(open)
            && self
                .word_before(open)
                .is_some_and(|held| self.tokens[held as usize].text(self.source) == b"for")
            && self
                .closing_of(open)
                .is_some_and(|close| !self.claused_header(open, close))
    }

    pub(super) fn settled(&self, position: u32, close: u32) -> bool {
        let mut depth = 0_u32;
        let mut opens = [0_u32; NEST_DEPTH_MAX as usize];
        let mut scan = position + 1;

        while scan < close {
            if let Some(held) = self.templated_unit(scan) {
                scan = held + 1;

                continue;
            }

            let kind = self.tokens[scan as usize].kind;

            if is_open(kind) {
                if depth == NEST_DEPTH_MAX {
                    return false;
                }

                opens[depth as usize] = scan;
                depth += 1;
                scan += 1;

                continue;
            }

            if is_close(kind) {
                if depth == 0 {
                    return false;
                }

                depth -= 1;

                let open = opens[depth as usize];
                let void = self.next_of(open) == Some(scan);
                let emptied = void && self.emptied(scan, open) == Some(false);
                let bodied = self.policy.body_parts && !void && self.bodied_brace(open);
                let broken = bodied || self.parts_at(open, scan) && !emptied;

                let held = self.policy.body_owns
                    && (bodied || self.bodied_value(open, scan))
                    && !self.declared_body(open);

                if broken && !held && !self.ownable(open, scan) {
                    return false;
                }
            }

            scan += 1;
        }

        depth == 0
    }

    fn ownable(&self, open: u32, close: u32) -> bool {
        if self.policy.body_owns && (self.wrapped_paren(open) || self.wrapper_parens(open, close)) {
            return true;
        }

        if self.policy.chain_simples
            && self.tokens[open as usize].kind == TokenKind::Punctuation(Punctuation::ParenOpen)
            && self
                .next_of(open)
                .is_some_and(|held| held < close && self.ternary_owns(held))
        {
            return true;
        }

        self.listed(close) && self.guarded(open, close) && self.elements(open, close)
    }

    fn numeric(&self, position: u32, close: u32) -> bool {
        let mut scan = position + 1;

        while scan < close {
            let token = self.tokens[scan as usize];
            let text = token.text(self.source);
            let numbered = token.kind == TokenKind::Number && !text.ends_with(b"n");

            let held = token.kind == TokenKind::Newline
                || token.length == 0
                || numbered
                || matches!(text, b"," | b"-" | b"+");

            if !held {
                return false;
            }

            scan += 1;
        }

        true
    }

    #[expect(
        clippy::too_many_lines,
        reason = "the walk names every token a list's element may hold, and splitting it would \
                  hide the one loop the rule is"
    )]
    pub(super) fn elements(&self, position: u32, close: u32) -> bool {
        let edged = self.policy.blank_edges
            && (self.tokens[position as usize].kind == TokenKind::BlockStart
                || BRACKET_BLANKS && is_open(self.tokens[position as usize].kind));

        let mut angles = 0_u32;
        let mut commas = 0;
        let mut found = false;
        let mut templates = false;
        let mut previous = position;
        let mut scan = position + 1;

        while scan < close {
            let token = self.tokens[scan as usize];

            if token.kind == TokenKind::Newline || token.length == 0 {
                scan += 1;

                continue;
            }

            if let Some(held) = self.parened(scan) {
                previous = held;
                scan = held + 1;
                found = true;

                continue;
            }

            if let Some(held) = self.templated_unit(scan) {
                if !edged && !self.policy.spread_blanks && self.blanked(previous, scan) {
                    return false;
                }

                templates |= self.parted_by(token.offset, self.tokens[held as usize].end()) > 0;
                previous = held;
                scan = held + 1;
                found = true;

                continue;
            }

            if is_open(token.kind) {
                let Some(held) = self.closing_of(scan).filter(|held| *held < close) else {
                    return false;
                };

                if !edged && !self.policy.spread_blanks && self.blanked(previous, scan) {
                    return false;
                }

                found = true;
                previous = held;
                scan = held + 1;

                continue;
            }

            if is_close(token.kind)
                || token.kind == TokenKind::Comment
                    && !self.inline_remark(scan, close)
                    && !self.trailing_remark(scan, previous, close)
            {
                return false;
            }

            if !edged && !self.policy.spread_blanks && self.blanked(previous, scan) {
                return false;
            }

            if !self.elemental(scan, position, previous) {
                return false;
            }

            Self::opened_type(token.text(self.source), &mut angles, &mut 0);

            let parts = angles == 0 && token.kind == TokenKind::Punctuation(Punctuation::Comma);

            commas += u32::from(parts);
            found = true;
            previous = scan;
            templates |= !self.policy.template_units
                && token.kind == TokenKind::String
                && token.text(self.source) == b"`";
            scan += 1;
        }

        if !found || !edged && !self.policy.spread_blanks && self.blanked(previous, close) {
            return false;
        }

        let trailing = u32::from(
            self.tokens[previous as usize].kind == TokenKind::Punctuation(Punctuation::Comma),
        );

        commas > trailing || !templates
    }

    fn trailing_remark(&self, position: u32, previous: u32, close: u32) -> bool {
        let token = self.tokens[position as usize];

        if token.kind != TokenKind::Comment || !token.text(self.source).starts_with(b"//") {
            return false;
        }

        previous != position
            && !self.parts_at(previous, position)
            && self
                .next_of(position)
                .is_some_and(|held| held == close || self.parts_at(position, held))
    }

    pub(super) fn inline_remark(&self, position: u32, close: u32) -> bool {
        let token = self.tokens[position as usize];

        if token.kind != TokenKind::Comment || !self.policy.inline_remarks {
            return false;
        }

        token.text(self.source).starts_with(b"/*")
            && !token.text(self.source).contains(&b'\n')
            && self
                .next_of(position)
                .is_some_and(|held| held == close || !self.parts_at(position, held))
    }

    fn elemental(&self, scan: u32, position: u32, previous: u32) -> bool {
        let token = self.tokens[scan as usize];
        let membered = self.typed_open(position);

        let semicolon = token.kind == TokenKind::Punctuation(Punctuation::Semicolon)
            && !self.typed
            && !membered
            && !self.headed(position);

        let ranged = token.text(self.source) == b"..."
            && !self.policy.prefix_words.contains(&b"...".as_slice());

        if semicolon || ranged {
            return false;
        }

        let elided = token.kind == TokenKind::Punctuation(Punctuation::Comma)
            && (previous == position
                || self.tokens[previous as usize].kind
                    == TokenKind::Punctuation(Punctuation::Comma));

        !elided
    }

    pub(super) fn calling(&self, position: u32) -> bool {
        let Some(held) = self.word_before(position) else {
            return false;
        };

        let text = self.tokens[held as usize].text(self.source);

        if self.policy.angle_calls && !text.is_empty() && text.iter().all(|byte| *byte == b'>') {
            return self
                .opening(held, count_of(text.len()))
                .is_some_and(|name| self.named(name));
        }

        self.named(held) || self.word_is(held, self.policy.callee_words) || self.marked_callee(held)
    }

    pub(super) fn opening(&self, position: u32, depth: u32) -> Option<u32> {
        let mut held = position;
        let mut owed = depth;

        for _ in 0..ANGLE_SCAN_MAX {
            let scan = self.word_before(held)?;

            held = scan;

            let text = self.tokens[held as usize].text(self.source);

            if matches!(text, b";" | b"{" | b"}" | b"&&" | b"||" | b"?") {
                return None;
            }

            if text == b"<" {
                owed -= 1;

                if owed == 0 {
                    return self.word_before(held);
                }
            } else if !text.is_empty() && text.iter().all(|byte| *byte == b'>') {
                owed += count_of(text.len());
            }
        }

        None
    }

    pub(super) fn assign_holds(&self, open: u32, breaks: bool, counted: bool) -> Option<u32> {
        let close = self.closing_of(open)?;

        if breaks && self.next_of(open) == Some(close) {
            return Some(close);
        }

        self.holding(open, counted && !breaks)
    }

    pub(super) fn arrowed(&self, position: u32) -> bool {
        let held = self.policy.arrow_parens
            && self.tokens[position as usize].kind == TokenKind::Identifier
            && self
                .next_of(position)
                .is_some_and(|next| self.tokens[next as usize].text(self.source) == b"=>");

        if !held {
            return false;
        }

        let Some(before) = self.word_before(position) else {
            return true;
        };

        let text = self.tokens[before as usize].text(self.source);

        if matches!(text, b"|" | b"&" | b"." | b">" | b"]" | b")") {
            return false;
        }

        if text != b":" {
            return true;
        }

        let Some(key) = self.word_before(before) else {
            return false;
        };

        if !matches!(
            self.tokens[key as usize].kind,
            TokenKind::Identifier | TokenKind::Number | TokenKind::String
        ) {
            return false;
        }

        self.word_before(key).is_some_and(|first| {
            matches!(
                self.tokens[first as usize].text(self.source),
                b"{" | b"," | b";"
            )
        })
    }

    pub(super) fn holding(&self, position: u32, held: bool) -> Option<u32> {
        let close = self.closing_of(position)?;

        if held || self.spreading(position, close).is_none() {
            return None;
        }

        Some(close)
    }

    pub(super) fn slight(&self, position: u32, close: u32) -> bool {
        if self.policy.assign_values
            && self.tokens[position as usize].kind == TokenKind::BlockStart
            && self.parts_at(position, close)
        {
            return false;
        }

        let mut found = None;
        let mut scan = position + 1;

        while scan < close {
            let token = self.tokens[scan as usize];

            let carried = token.kind == TokenKind::Punctuation(Punctuation::Comma)
                && self.next_of(scan) == Some(close);

            if token.kind != TokenKind::Newline && token.length > 0 && !carried {
                if found.is_some() {
                    return false;
                }

                found = Some(token);
            }

            scan += 1;
        }

        let Some(held) = found else {
            return false;
        };

        matches!(
            held.kind,
            TokenKind::Identifier | TokenKind::Number | TokenKind::String
        ) && held.length <= self.options.line_width / 4
    }

    pub(super) fn blanked(&self, previous: u32, position: u32) -> bool {
        self.parted_by(
            self.tokens[previous as usize].end(),
            self.tokens[position as usize].offset,
        ) > 1
    }

    pub(super) const fn edged(kind: TokenKind) -> Element {
        if matches!(kind, TokenKind::BlockStart) {
            Element::Line
        } else {
            Element::SoftLine
        }
    }

    pub(super) fn assign_owed(&self) -> bool {
        self.assigned.is_some() || self.owed > 0
    }

    pub(super) fn spreads(&self) -> bool {
        self.depth > 0 && self.nest[self.depth as usize - 1].spread.is_some()
    }

    pub(super) fn chains_a_header(&self) -> bool {
        matches!(self.frame().spread, Some(Spread::Chain | Spread::Clauses)) && self.depth > 0
    }

    pub(super) fn operating(&self, position: u32) -> bool {
        let held = self.tokens[position as usize];

        let parted = if self.frame().spread == Some(Spread::Clauses) {
            held.kind == TokenKind::Punctuation(Punctuation::Semicolon)
        } else {
            self.word_is(position, self.policy.operator_words)
        };

        parted && !self.angled(position) && !self.nested_at(position)
    }

    fn claused_header(&self, position: u32, close: u32) -> bool {
        let mut depth = 0_u32;
        let mut scan = position + 1;

        while scan < close {
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

    fn nested_at(&self, position: u32) -> bool {
        let mut depth = 0_u32;
        let mut scan = self.frame().open + 1;

        while scan < position {
            let kind = self.tokens[scan as usize].kind;

            if is_open(kind) {
                depth += 1;
            } else if is_close(kind) {
                depth = depth.saturating_sub(1);
            }

            scan += 1;
        }

        depth > 0
    }

    pub(super) fn separating(&self) -> bool {
        if self.chains_a_header() {
            return self.previous.is_some_and(|held| self.operating(held));
        }

        self.spreads()
            && self.previous.is_some_and(|held| {
                matches!(
                    self.tokens[held as usize].kind,
                    TokenKind::Punctuation(Punctuation::Comma | Punctuation::Semicolon)
                ) && !self.angled(held)
                    || self.remark_ended(held)
            })
    }

    pub(super) fn parted_at(&self, from: u32, close: u32) -> u32 {
        let mut depth = 0_u32;
        let mut scan = from;

        while scan < close {
            let kind = self.tokens[scan as usize].kind;

            if wide::LIST_NESTS && (is_open(kind) || kind == TokenKind::BlockStart) {
                depth += 1;
            } else if wide::LIST_NESTS && (is_close(kind) || kind == TokenKind::BlockEnd) {
                depth = depth.saturating_sub(1);
            } else if depth == 0 && kind == TokenKind::Punctuation(Punctuation::Comma) {
                return scan;
            }

            scan += 1;
        }

        close
    }
}
