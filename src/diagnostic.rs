use core::fmt::{self, Write as _};

use crate::bounded::{BoundedString, BoundedVec, Span, count_of};
use crate::fix::NONE;

pub const MESSAGE_UNWRITTEN: &str = "the finding message did not fit";

#[expect(
    clippy::arbitrary_source_item_ordering,
    reason = "the declared order is the severity ladder, strongest first"
)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Severity {
    Error,
    Warning,
    Information,
    Hint,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Message {
    Arena(Span),
    Static(&'static str),
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Diagnostic {
    pub code: &'static str,
    pub fix: u32,
    pub message: Message,
    pub rule: u32,
    pub severity: Severity,
    pub span: Span,
}

#[derive(Debug)]
pub struct Diagnostics {
    arena: BoundedString,
    items: BoundedVec<Diagnostic>,
    order: BoundedVec<u32>,
    overflowed: bool,
}

impl Severity {
    pub const fn name(self) -> &'static str {
        match self {
            Self::Error => "error",
            Self::Hint => "hint",
            Self::Information => "information",
            Self::Warning => "warning",
        }
    }
}

impl Diagnostics {
    pub fn reserve(count_max: u32, arena_bytes_max: u32) -> Self {
        assert!(count_max > 0);
        assert!(arena_bytes_max > 0);

        assert!(!crate::allocation::is_frozen());

        Self {
            arena: BoundedString::reserve(arena_bytes_max),
            items: BoundedVec::reserve(count_max),
            order: BoundedVec::reserve(count_max),
            overflowed: false,
        }
    }

    pub fn at(&self, index: u32) -> Option<&Diagnostic> {
        self.items.get(index as usize)
    }

    pub fn attach(&mut self, index: u32, fix: u32) {
        assert!(index < self.count());

        self.items[index as usize].fix = fix;
    }

    pub fn clear(&mut self) {
        self.arena.clear();
        self.items.clear();
        self.order.clear();
        self.overflowed = false;

        assert_eq!(self.count(), 0);
        assert!(!self.is_overflowed());
    }

    pub fn count(&self) -> u32 {
        self.items.count()
    }

    pub fn is_empty(&self) -> bool {
        self.items.is_empty()
    }

    pub const fn is_overflowed(&self) -> bool {
        self.overflowed
    }

    pub fn message_of(&self, diagnostic: &Diagnostic) -> &[u8] {
        match diagnostic.message {
            Message::Arena(span) => {
                assert!(span.end() <= self.arena.count());

                &self.arena.as_bytes()[span.range()]
            }
            Message::Static(text) => text.as_bytes(),
        }
    }

    pub fn iter(&self) -> core::slice::Iter<'_, Diagnostic> {
        self.items.iter()
    }

    #[must_use]
    pub fn push(&mut self, diagnostic: Diagnostic) -> bool {
        if self.items.push(diagnostic) {
            return true;
        }

        self.overflowed = true;

        false
    }

    #[must_use]
    pub fn push_formatted(
        &mut self,
        code: &'static str,
        severity: Severity,
        span: Span,
        fix: u32,
        arguments: fmt::Arguments<'_>,
    ) -> bool {
        self.push_formatted_for(code, crate::rule::NONE, severity, span, fix, arguments)
    }

    pub fn push_formatted_for(
        &mut self,
        code: &'static str,
        rule: u32,
        severity: Severity,
        span: Span,
        fix: u32,
        arguments: fmt::Arguments<'_>,
    ) -> bool {
        let offset = self.arena.count();

        if self.arena.write_fmt(arguments).is_err() {
            self.arena.truncate(offset);

            return self.push(Diagnostic {
                code,
                fix,
                message: Message::Static(MESSAGE_UNWRITTEN),
                rule,
                severity,
                span,
            });
        }

        let length = self.arena.flatten(offset);

        self.push(Diagnostic {
            code,
            fix,
            message: Message::Arena(Span { length, offset }),
            rule,
            severity,
            span,
        })
    }

    pub fn sort(&mut self) {
        let count = self.count();

        self.order.clear();

        for index in 0..count {
            self.order.push_assert(index);
        }

        let items = &self.items;

        self.order
            .sort_unstable_by_key(|index| key_at(items, *index));

        for start in 0..count as usize {
            if self.order[start] as usize == start {
                continue;
            }

            let held = self.items[start];
            let mut current = start;

            for _ in 0..count {
                let source = self.order[current] as usize;

                self.order[current] = count_of(current);

                if source == start {
                    self.items[current] = held;

                    break;
                }

                self.items[current] = self.items[source];
                current = source;
            }
        }

        assert_eq!(self.order.count(), count);
        assert!(self.items.is_sorted_by_key(key_of));
    }
}

impl<'items> IntoIterator for &'items Diagnostics {
    type IntoIter = core::slice::Iter<'items, Diagnostic>;
    type Item = &'items Diagnostic;

    fn into_iter(self) -> Self::IntoIter {
        self.iter()
    }
}

impl Diagnostic {
    pub const fn is_fixed(&self) -> bool {
        self.fix != NONE
    }
}

fn key_of(diagnostic: &Diagnostic) -> (u32, &'static str) {
    (diagnostic.span.offset, diagnostic.code)
}

fn key_at(items: &[Diagnostic], index: u32) -> (u32, &'static str, u32) {
    let held = items[index as usize];

    (held.span.offset, held.code, index)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn row(code: &'static str, offset: u32, fix: u32) -> Diagnostic {
        Diagnostic {
            code,
            fix,
            message: Message::Static("a recorded finding"),
            rule: crate::rule::NONE,
            severity: Severity::Warning,
            span: Span { length: 1, offset },
        }
    }

    #[test]
    fn a_push_stops_at_the_reserved_count() {
        let mut diagnostics = Diagnostics::reserve(2, 1 << 12);

        assert!(diagnostics.push(row("TS001", 0, NONE)));
        assert!(diagnostics.push(row("TS002", 4, 1)));
        assert!(!diagnostics.push(row("TS003", 8, NONE)));
        assert_eq!(diagnostics.count(), 2);

        diagnostics.clear();

        assert_eq!(diagnostics.count(), 0);
        assert!(diagnostics.push(row("TS003", 8, NONE)));
    }

    #[test]
    fn a_sort_orders_by_offset_then_code() {
        let mut diagnostics = Diagnostics::reserve(8, 1 << 12);

        assert!(diagnostics.push(row("TS009", 12, NONE)));
        assert!(diagnostics.push(row("TS002", 4, NONE)));
        assert!(diagnostics.push(row("TS001", 4, NONE)));
        assert!(diagnostics.push(row("TS005", 0, NONE)));

        diagnostics.sort();

        let ordered: Vec<(u32, &'static str)> = diagnostics
            .iter()
            .map(|diagnostic| (diagnostic.span.offset, diagnostic.code))
            .collect();

        assert_eq!(
            ordered,
            vec![(0, "TS005"), (4, "TS001"), (4, "TS002"), (12, "TS009")]
        );
    }

    #[test]
    fn a_sort_keeps_the_order_a_tie_arrived_in() {
        let mut diagnostics = Diagnostics::reserve(8, 1 << 12);

        assert!(diagnostics.push(row("TS001", 4, 2)));
        assert!(diagnostics.push(row("TS001", 4, 0)));
        assert!(diagnostics.push(row("TS001", 4, 1)));
        assert!(diagnostics.push(row("TS001", 0, 9)));

        diagnostics.sort();

        let ordered: Vec<u32> = diagnostics
            .iter()
            .map(|diagnostic| diagnostic.fix)
            .collect();

        assert_eq!(ordered, vec![9, 2, 0, 1]);
    }

    #[test]
    fn a_fix_index_reads_back_as_a_fixed_row() {
        let fixed = row("TS001", 0, 4);
        let bare = row("TS001", 0, NONE);

        assert!(fixed.is_fixed());
        assert!(!bare.is_fixed());
        assert_eq!(Severity::Error.name(), "error");
        assert_eq!(Severity::Hint.name(), "hint");
        assert_eq!(Severity::Information.name(), "information");
        assert_eq!(Severity::Warning.name(), "warning");
    }

    #[test]
    fn a_sort_runs_on_a_frozen_thread() {
        let mut diagnostics = Diagnostics::reserve(64, 1 << 12);
        let mut random = crate::bounded::Random::new(0x51E1_9C43_7B0D_A2F5);
        let _scope = crate::allocation::freeze_scope();

        for _ in 0..64 {
            assert!(diagnostics.push(row("TS001", random.below(1_000), NONE)));
        }

        diagnostics.sort();

        let mut offset_previous = 0;

        for diagnostic in &diagnostics {
            assert!(diagnostic.span.offset >= offset_previous);

            offset_previous = diagnostic.span.offset;
        }
    }
}
