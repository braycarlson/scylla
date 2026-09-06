use super::{DEFINE_SCAN_MAX, Emitter, Wrap, is_close, is_open};
use crate::token::{Punctuation, TokenKind};

const BINDER_LEAD_MAX: u32 = 4;

const SEQUENCE_HEADS: [&[u8]; 15] = [
    b"(",
    b",",
    b":",
    b";",
    b"=",
    b"=>",
    b"?",
    b"??",
    b"&&",
    b"[",
    b"case",
    b"do",
    b"return",
    b"throw",
    b"||",
];

#[expect(
    clippy::multiple_inherent_impl,
    reason = "the binding rules are their own family of the emitter and `mod.rs` reaches them"
)]
impl Emitter<'_> {
    pub(super) fn declare_broken(&self, position: u32, previous: u32) -> bool {
        if !self.policy.declare_lines || self.tokens[position as usize].kind == TokenKind::Comment {
            return false;
        }

        if self.tokens[previous as usize].kind != TokenKind::Punctuation(Punctuation::Comma) {
            return false;
        }

        if !self.statement_level() {
            return false;
        }

        let Some(head) = self.statement_head(previous) else {
            return false;
        };

        let Some(binder) = self.binder_of(head) else {
            return false;
        };

        self.opens_a_declarator(previous) && self.declares_a_value(binder)
    }

    fn opens_a_declarator(&self, comma: u32) -> bool {
        let Some(name) = self.next_of(comma) else {
            return false;
        };

        let kind = self.tokens[name as usize].kind;

        let after = if kind == TokenKind::Identifier {
            self.next_of(name)
        } else if is_open(kind) || kind == TokenKind::BlockStart {
            self.closing_of(name).and_then(|close| self.next_of(close))
        } else {
            return false;
        };

        after.is_none_or(|held| {
            matches!(
                self.tokens[held as usize].kind,
                TokenKind::Punctuation(
                    Punctuation::Assign
                        | Punctuation::Colon
                        | Punctuation::Comma
                        | Punctuation::Semicolon
                )
            )
        })
    }

    pub(super) fn sequence_broken(&self, position: u32, previous: u32) -> bool {
        if self.tokens[position as usize].kind == TokenKind::Comment {
            return false;
        }

        let Some((head, _)) = self.sequence_comma(previous) else {
            return false;
        };

        self.sequence_parted(head, previous)
    }

    pub(super) fn sequence_level(&self, _position: u32) -> Option<u32> {
        let previous = self.coded()?;
        let (head, indented) = self.sequence_comma(previous)?;

        self.leveled_at(head)
            .map(|level| level + u32::from(indented && !self.sequence_wrapped()))
    }

    pub(super) fn sequence_wrapped_item(&self, previous: u32) -> bool {
        if !self.policy.sequence_lines || !self.sequence_wrapped() {
            return false;
        }

        let close = self.wrapped[self.wraps_owed as usize - 1].0;
        let head = self.statement_head(previous).unwrap_or(previous);
        let stop = close.min(self.count.saturating_sub(1));
        let mut depth = 0_u32;
        let mut scan = head;

        while scan <= stop {
            let kind = self.tokens[scan as usize].kind;

            if is_open(kind) {
                depth += 1;
            } else if is_close(kind) {
                depth = depth.saturating_sub(1);
            } else if depth == 0
                && kind == TokenKind::Punctuation(Punctuation::Comma)
                && self.brackets.angles_at(scan) == 0
            {
                return true;
            }

            scan += 1;
        }

        false
    }

    fn sequence_wrapped(&self) -> bool {
        if self.wraps_owed == 0 {
            return false;
        }

        let (_, wrap, depth, _, _) = self.wrapped[self.wraps_owed as usize - 1];

        wrap == Wrap::Parens && depth == self.depth
    }

    fn sequence_comma(&self, previous: u32) -> Option<(u32, bool)> {
        if !self.policy.sequence_lines {
            return None;
        }

        if self.tokens[previous as usize].kind != TokenKind::Punctuation(Punctuation::Comma) {
            return None;
        }

        if self.brackets.angles_at(previous) != 0 {
            return None;
        }

        let indented = self.statement_level();

        if !indented && !self.sequence_grouped() {
            return None;
        }

        let found = self.statement_head(previous)?;
        let head = if self.tokens[found as usize].kind == TokenKind::Comment {
            self.coding(found)?
        } else {
            found
        };

        if self.binder_of(head).is_some() || self.word_is(head, self.policy.sequence_stops) {
            return None;
        }

        Some((head, indented))
    }

    fn sequence_grouped(&self) -> bool {
        if self.depth == 0 {
            return false;
        }

        let frame = self.nest[self.depth as usize - 1];

        self.sequence_paren(frame.open)
    }

    fn sequence_paren(&self, open: u32) -> bool {
        if self.tokens[open as usize].kind != TokenKind::Punctuation(Punctuation::ParenOpen) {
            return false;
        }

        if self
            .closing_of(open)
            .is_some_and(|close| self.sequence_arrowed(close))
        {
            return false;
        }

        let Some(before) = self.back_of(open) else {
            return true;
        };

        let text = self.tokens[before as usize].text(self.source);

        if text == b"?" {
            return !self.optional(before);
        }

        SEQUENCE_HEADS.contains(&text)
    }

    fn sequence_arrowed(&self, close: u32) -> bool {
        let Some(after) = self.next_of(close) else {
            return false;
        };

        let text = self.tokens[after as usize].text(self.source);

        if text == b"=>" {
            return true;
        }

        if text != b":" {
            return false;
        }

        let mut depth = 0_u32;
        let mut scan = after + 1;

        for _ in 0..DEFINE_SCAN_MAX {
            if scan >= self.count {
                return false;
            }

            let kind = self.tokens[scan as usize].kind;

            if is_open(kind) || kind == TokenKind::BlockStart {
                depth += 1;
            } else if is_close(kind) || kind == TokenKind::BlockEnd {
                if depth == 0 {
                    return false;
                }

                depth -= 1;
            } else if depth == 0 {
                let held = self.tokens[scan as usize].text(self.source);

                if held == b"=>" {
                    return true;
                }

                if matches!(held, b";" | b",") {
                    return false;
                }
            }

            scan += 1;
        }

        false
    }

    pub(super) fn sequence_spread(&self, open: u32) -> bool {
        if !self.policy.sequence_lines || !self.sequence_paren(open) {
            return false;
        }

        let Some(close) = self.closing_of(open) else {
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
            } else if depth == 0
                && kind == TokenKind::Punctuation(Punctuation::Comma)
                && self.brackets.angles_at(scan) == 0
            {
                return true;
            }

            scan += 1;
        }

        false
    }

    fn sequence_parted(&self, head: u32, comma: u32) -> bool {
        let Some(stop) = self.sequence_end(comma) else {
            return false;
        };

        let level = self.leveled_at(head).unwrap_or(self.printed);
        let room = level * self.options.indent_width + self.printed_columns(head, stop);

        room > self.options.line_width
    }

    fn sequence_end(&self, comma: u32) -> Option<u32> {
        let mut depth = 0_u32;
        let mut scan = comma;

        for _ in 0..DEFINE_SCAN_MAX {
            if scan >= self.count {
                return None;
            }

            let kind = self.tokens[scan as usize].kind;

            if is_open(kind) || kind == TokenKind::BlockStart {
                depth += 1;
            } else if is_close(kind) || kind == TokenKind::BlockEnd {
                if depth == 0 {
                    return Some(scan);
                }

                depth -= 1;
            } else if depth == 0 && kind == TokenKind::Punctuation(Punctuation::Semicolon) {
                return Some(scan);
            }

            scan += 1;
        }

        None
    }

    fn binder_of(&self, head: u32) -> Option<u32> {
        for scan in head..head + BINDER_LEAD_MAX {
            if scan >= self.count {
                return None;
            }

            if self.word_is(scan, self.policy.binder_words) {
                return Some(scan);
            }

            if !matches!(self.tokens[scan as usize].kind, TokenKind::Keyword(_)) {
                return None;
            }
        }

        None
    }

    fn declares_a_value(&self, binder: u32) -> bool {
        let mut depth = 0_u32;

        for scan in binder + 1..binder + 1 + DEFINE_SCAN_MAX {
            if scan >= self.count {
                return false;
            }

            let kind = self.tokens[scan as usize].kind;

            if is_open(kind) || kind == TokenKind::BlockStart {
                depth += 1;
            } else if is_close(kind) || kind == TokenKind::BlockEnd {
                if depth == 0 {
                    return false;
                }

                depth -= 1;
            } else if depth == 0 {
                if kind == TokenKind::Punctuation(Punctuation::Semicolon) {
                    return false;
                }

                if kind == TokenKind::Punctuation(Punctuation::Assign) {
                    return true;
                }
            }
        }

        false
    }
}
