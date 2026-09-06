use super::{DEFINE_SCAN_MAX, Emitter, is_close, is_open};
use crate::token::{Punctuation, TokenKind};

const BINDER_LEAD_MAX: u32 = 4;

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
