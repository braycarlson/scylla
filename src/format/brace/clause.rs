use super::{DEFINE_SCAN_MAX, Emitter, is_close, is_open};
use crate::format::reach;
use crate::token::{Punctuation, TokenKind};

#[expect(
    clippy::multiple_inherent_impl,
    reason = "the clause rules are their own family of the emitter and `mod.rs` reaches them"
)]
impl Emitter<'_> {
    pub(super) fn clause_parted(&self, position: u32, previous: u32) -> bool {
        if !self.policy.clause_lines {
            return false;
        }

        if self.tokens[previous as usize].kind != TokenKind::Punctuation(Punctuation::ParenClose) {
            return false;
        }

        let Some(head) = self.clause_head(previous) else {
            return false;
        };

        self.clause_bodied(position) && self.clause_over(head, previous)
    }

    pub(super) fn clause_bounded(&self, position: u32, kind: TokenKind) -> bool {
        self.policy.clause_ends
            && kind == TokenKind::BlockStart
            && self.claused
            && self.depth == self.claused_depth
            && self.brackets.angles_at(position) == 0
    }

    pub(super) fn clause_within(&self) -> bool {
        self.policy.clause_lines && self.claused && self.depth == self.claused_depth
    }

    pub(super) fn clause_base(&self) -> u32 {
        self.levels + u32::from(self.clause_within())
    }

    pub(super) fn clause_started(&self) -> bool {
        self.coded().is_some_and(|held| {
            matches!(
                self.tokens[held as usize].kind,
                TokenKind::BlockEnd
                    | TokenKind::Punctuation(Punctuation::Colon | Punctuation::Semicolon)
            )
        })
    }

    pub(super) fn value_parted(&self, position: u32, previous: u32) -> bool {
        self.line_first <= previous && self.value_claused(self.line_first, position)
    }

    pub(super) fn value_level(&self, position: u32) -> Option<u32> {
        self.value_claused(self.line_before, position)
            .then_some(self.printed + 1)
    }

    fn value_claused(&self, head: u32, equals: u32) -> bool {
        if self.policy.clause_values.is_empty()
            || self.tokens[equals as usize].kind != TokenKind::Punctuation(Punctuation::Assign)
            || head >= equals
            || self.brackets.angles_at(equals) > 0
        {
            return false;
        }

        self.value_item(head, equals) && self.value_clause(equals)
    }

    fn value_item(&self, head: u32, equals: u32) -> bool {
        let mut scan = head;

        for _ in 0..DEFINE_SCAN_MAX {
            if scan >= equals {
                return false;
            }

            if self.word_is(scan, self.policy.clause_values) {
                return true;
            }

            let Some(next) = self.next_of(scan) else {
                return false;
            };

            scan = next;
        }

        false
    }

    fn value_clause(&self, equals: u32) -> bool {
        let Some(mut scan) = self.next_of(equals) else {
            return false;
        };

        let mut depth = 0_u32;

        for _ in 0..DEFINE_SCAN_MAX {
            let kind = self.tokens[scan as usize].kind;

            if depth == 0 && kind == TokenKind::Punctuation(Punctuation::Semicolon) {
                return false;
            }

            if is_open(kind) || kind == TokenKind::BlockStart {
                depth += 1;
            } else if is_close(kind) || kind == TokenKind::BlockEnd {
                let Some(held) = depth.checked_sub(1) else {
                    return false;
                };

                depth = held;
            } else if depth == 0 && self.word_is(scan, self.policy.clause_words) {
                return self.parted_before(scan);
            }

            let Some(next) = self.next_of(scan) else {
                return false;
            };

            scan = next;
        }

        false
    }

    fn parted_before(&self, position: u32) -> bool {
        let Some(held) = self.back_of(position) else {
            return false;
        };

        self.parted_by(
            self.tokens[held as usize].end(),
            self.tokens[position as usize].offset,
        ) > 0
    }

    pub(super) fn clause_seated(&self, open: u32) -> bool {
        if !self.policy.clause_lines || !self.headed(open) {
            return false;
        }

        let Some(close) = self.closing_of(open) else {
            return false;
        };

        let Some(after) = self.next_of(close) else {
            return false;
        };

        if !self.clause_bodied(after) {
            return false;
        }

        let Some(head) = self.word_before(open) else {
            return false;
        };

        self.clause_columns(head, close + 1) <= self.options.line_width
    }

    fn clause_head(&self, close: u32) -> Option<u32> {
        let open = reach::opened(self.source, self.tokens, close)?;

        if !self.headed(open) {
            return None;
        }

        self.word_before(open)
    }

    fn clause_bodied(&self, position: u32) -> bool {
        !matches!(
            self.tokens[position as usize].kind,
            TokenKind::BlockStart
                | TokenKind::Comment
                | TokenKind::Punctuation(Punctuation::Semicolon)
        )
    }

    fn clause_over(&self, head: u32, close: u32) -> bool {
        let Some(end) = self.clause_end(head) else {
            return false;
        };

        let welded = self.next_of(close).is_some_and(|body| {
            self.tokens[close as usize].end() == self.tokens[body as usize].offset
        });

        self.clause_columns(head, end + 1) + u32::from(welded) > self.options.line_width
    }

    fn clause_columns(&self, head: u32, end: u32) -> u32 {
        self.printed * self.options.indent_width + self.flat_columns(head, end)
    }

    fn clause_end(&self, head: u32) -> Option<u32> {
        let mut depth = 0_u32;
        let mut scan = head;

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
