use core::fmt::{self, Write as _};

use crate::bounded::{BoundedString, BoundedVec, Span, count_of};
use crate::fix::NONE;
use crate::project::store::FileID;

pub const MESSAGE_UNWRITTEN: &str = "the finding message did not fit";

#[expect(
    clippy::arbitrary_source_item_ordering,
    reason = "the derived `Ord` makes the declared order the severity ladder, weakest first"
)]
#[derive(Clone, Copy, Debug, Eq, Ord, PartialEq, PartialOrd)]
pub enum Severity {
    Hint,
    Information,
    Warning,
    Error,
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
    pub related_count: u32,
    pub related_start: u32,
    pub rule: u32,
    pub severity: Severity,
    pub span: Span,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Related {
    pub file: FileID,
    pub message: Message,
    pub span: Span,
}

#[derive(Debug)]
pub struct Diagnostics {
    arena: BoundedString,
    items: BoundedVec<Diagnostic>,
    order: BoundedVec<u32>,
    overflowed: bool,
    related: BoundedVec<Related>,
}

impl Severity {
    pub const fn name(self) -> &'static str {
        match self {
            Self::Error => "error",
            Self::Hint => "hint",
            Self::Information => "info",
            Self::Warning => "warning",
        }
    }

    pub fn of(text: &str) -> Option<Self> {
        if text.eq_ignore_ascii_case("error") {
            return Some(Self::Error);
        }

        if text.eq_ignore_ascii_case("warn") || text.eq_ignore_ascii_case("warning") {
            return Some(Self::Warning);
        }

        if text.eq_ignore_ascii_case("info") || text.eq_ignore_ascii_case("information") {
            return Some(Self::Information);
        }

        if text.eq_ignore_ascii_case("hint") {
            return Some(Self::Hint);
        }

        None
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
            related: BoundedVec::reserve(count_max),
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
        self.related.clear();

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
        self.push_formatted_row(
            Diagnostic {
                code,
                fix,
                message: Message::Static(""),
                related_count: 0,
                related_start: 0,
                rule,
                severity,
                span,
            },
            arguments,
        )
    }

    #[must_use]
    pub fn push_formatted_row(&mut self, row: Diagnostic, arguments: fmt::Arguments<'_>) -> bool {
        let offset = self.arena.count();
        let mut held = row;

        if self.arena.write_fmt(arguments).is_err() {
            self.arena.truncate(offset);

            held.message = Message::Static(MESSAGE_UNWRITTEN);

            return self.push(held);
        }

        let length = self.arena.flatten(offset);

        held.message = Message::Arena(Span { length, offset });

        self.push(held)
    }

    #[must_use]
    pub fn push_related(&mut self, related: Related) -> bool {
        if self.related.push(related) {
            return true;
        }

        self.overflowed = true;

        false
    }

    pub fn push_related_formatted(
        &mut self,
        file: FileID,
        span: Span,
        arguments: fmt::Arguments<'_>,
    ) -> bool {
        let offset = self.arena.count();

        if self.arena.write_fmt(arguments).is_err() {
            self.arena.truncate(offset);

            return self.push_related(Related {
                file,
                message: Message::Static(MESSAGE_UNWRITTEN),
                span,
            });
        }

        let length = self.arena.flatten(offset);

        self.push_related(Related {
            file,
            message: Message::Arena(Span { length, offset }),
            span,
        })
    }

    pub fn related_count(&self) -> u32 {
        self.related.count()
    }

    pub fn retain(&mut self, mut keep: impl FnMut(&Diagnostic) -> bool) {
        let mut read = 0_u32;
        let mut written = 0_u32;

        while read < self.items.count() {
            let held = self.items[read as usize];

            read += 1;

            if !keep(&held) {
                continue;
            }

            self.items[written as usize] = held;
            written += 1;
        }

        self.items.truncate(written);
    }

    pub fn related_message_of(&self, related: &Related) -> &[u8] {
        match related.message {
            Message::Arena(span) => {
                assert!(span.end() <= self.arena.count());

                &self.arena.as_bytes()[span.range()]
            }
            Message::Static(text) => text.as_bytes(),
        }
    }

    pub fn related_of(&self, diagnostic: &Diagnostic) -> &[Related] {
        let first = diagnostic.related_start as usize;
        let count = diagnostic.related_count as usize;

        self.related
            .get(first..first.saturating_add(count))
            .unwrap_or_default()
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

    fn related_row(offset: u32) -> Related {
        Related {
            file: FileID::of(0),
            message: Message::Static("declared here"),
            span: Span { length: 1, offset },
        }
    }

    #[test]
    fn a_diagnostic_owns_the_related_rows_it_names() {
        let mut diagnostics = Diagnostics::reserve(8, 1 << 12);

        assert_eq!(diagnostics.related_count(), 0);
        assert!(diagnostics.push_related(related_row(4)));
        assert!(diagnostics.push_related(related_row(8)));

        assert!(diagnostics.push(Diagnostic {
            related_count: 2,
            related_start: 0,
            ..row("TS001", 0, NONE)
        }));

        let held = diagnostics.at(0).copied().expect("the row was pushed");
        let related = diagnostics.related_of(&held);

        assert_eq!(related.len(), 2);
        assert_eq!(related[0].span.offset, 4);
        assert_eq!(related[1].span.offset, 8);
        assert_eq!(
            diagnostics.related_message_of(&related[0]),
            b"declared here"
        );
    }

    #[test]
    fn a_formatted_row_keeps_the_related_run_it_named() {
        let mut diagnostics = Diagnostics::reserve(8, 1 << 12);

        assert!(diagnostics.push_related(related_row(4)));

        assert!(diagnostics.push_formatted_row(
            Diagnostic {
                related_count: 1,
                related_start: 0,
                ..row("TS001", 0, NONE)
            },
            format_args!("names {}", "one"),
        ));

        let held = diagnostics.at(0).copied().expect("the row was pushed");

        assert_eq!(diagnostics.message_of(&held), b"names one");
        assert_eq!(diagnostics.related_of(&held).len(), 1);
    }

    #[test]
    fn a_diagnostic_naming_no_related_row_reads_none() {
        let mut diagnostics = Diagnostics::reserve(8, 1 << 12);

        assert!(diagnostics.push(row("TS001", 0, NONE)));

        let held = diagnostics.at(0).copied().expect("the row was pushed");

        assert!(diagnostics.related_of(&held).is_empty());
    }

    #[test]
    fn a_formatted_related_row_writes_into_the_arena() {
        let mut diagnostics = Diagnostics::reserve(8, 1 << 12);

        assert!(diagnostics.push_related_formatted(
            FileID::of(0),
            Span {
                length: 1,
                offset: 0
            },
            format_args!("bound at line {}", 12),
        ));

        let related = diagnostics.related_of(&Diagnostic {
            related_count: 1,
            related_start: 0,
            ..row("TS001", 0, NONE)
        });

        assert_eq!(
            diagnostics.related_message_of(&related[0]),
            b"bound at line 12"
        );
    }

    #[test]
    fn a_cleared_table_forgets_its_related_rows() {
        let mut diagnostics = Diagnostics::reserve(8, 1 << 12);

        assert!(diagnostics.push_related(related_row(4)));

        diagnostics.clear();

        assert_eq!(diagnostics.related_count(), 0);
    }

    #[test]
    fn a_retained_table_keeps_the_rows_the_test_names() {
        let mut diagnostics = Diagnostics::reserve(8, 1 << 12);

        for offset in 0..4 {
            assert!(diagnostics.push(row("TS001", offset, NONE)));
        }

        diagnostics.retain(|held| held.span.offset % 2 == 0);

        assert_eq!(diagnostics.count(), 2);
        assert_eq!(diagnostics.at(0).expect("kept").span.offset, 0);
        assert_eq!(diagnostics.at(1).expect("kept").span.offset, 2);
    }

    fn row(code: &'static str, offset: u32, fix: u32) -> Diagnostic {
        Diagnostic {
            code,
            fix,
            message: Message::Static("a recorded finding"),
            related_count: 0,
            related_start: 0,
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
        assert_eq!(Severity::Information.name(), "info");
        assert_eq!(Severity::of("WARN"), Some(Severity::Warning));
        assert_eq!(Severity::of("information"), Some(Severity::Information));
        assert_eq!(Severity::of("loud"), None);
        assert!(Severity::Error > Severity::Warning);
        assert!(Severity::Hint < Severity::Information);
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
