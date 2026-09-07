use core::cmp::Ordering;
use core::fmt::{self, Write as _};

use crate::bounded::{BoundedString, BoundedVec, Span, count_of};
use crate::fix::NONE as FIX_NONE;

pub const MESSAGE_UNWRITTEN: &str = "the finding message did not fit";
pub const NONE: u32 = u32::MAX;

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

#[derive(Clone, Copy, Debug, Eq, Ord, PartialEq, PartialOrd)]
pub struct FileID(u32);

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

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Finding {
    pub file: FileID,
    pub row: Diagnostic,
}

#[derive(Debug)]
pub struct Findings {
    files: BoundedVec<Diagnostics>,
    order: BoundedVec<FileID>,
}

pub struct Walk<'run> {
    at: u32,
    held: &'run Findings,
    row: u32,
}

impl FileID {
    pub const fn of(index: u32) -> Self {
        assert!(index != NONE);

        Self(index)
    }

    pub const fn index(self) -> u32 {
        assert!(self.0 != NONE);

        self.0
    }
}

impl Severity {
    pub const fn lsp_code(self) -> i64 {
        match self {
            Self::Error => 1,
            Self::Hint => 4,
            Self::Information => 3,
            Self::Warning => 2,
        }
    }

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
        self.push_formatted_row(
            Diagnostic {
                code,
                fix,
                message: Message::Static(""),
                related_count: 0,
                related_start: 0,
                rule: crate::rule::NONE,
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
        self.fix != FIX_NONE
    }
}

impl Findings {
    pub fn reserve(file_count_max: u32, count_max: u32, arena_bytes_max: u32) -> Self {
        assert!(file_count_max > 0);
        assert!(count_max > 0);
        assert!(arena_bytes_max > 0);
        assert!(!crate::allocation::is_frozen());

        let mut files = BoundedVec::reserve(file_count_max);

        for _ in 0..file_count_max {
            files.push_assert(Diagnostics::reserve(count_max, arena_bytes_max));
        }

        assert_eq!(files.count(), file_count_max);

        Self {
            files,
            order: BoundedVec::reserve(file_count_max),
        }
    }

    pub fn clear(&mut self) {
        for held in self.files.iter_mut() {
            held.clear();
        }

        self.order.clear();

        assert!(self.is_empty());
    }

    pub fn count(&self) -> u32 {
        let mut found = 0_u32;

        for held in self.files.iter() {
            found = found.saturating_add(held.count());
        }

        found
    }

    pub fn detach(&mut self, file: FileID, index: u32) {
        let Some(held) = self.of_mut(file) else {
            return;
        };

        held.attach(index, FIX_NONE);
    }

    pub fn file_count(&self) -> u32 {
        self.files.count()
    }

    pub fn is_empty(&self) -> bool {
        self.files.iter().all(Diagnostics::is_empty)
    }

    pub fn is_overflowed(&self) -> bool {
        self.files.iter().any(Diagnostics::is_overflowed)
    }

    pub const fn iter(&self) -> Walk<'_> {
        Walk {
            at: 0,
            held: self,
            row: 0,
        }
    }

    pub fn message_of(&self, finding: &Finding) -> &[u8] {
        let Some(held) = self.of(finding.file) else {
            return &[];
        };

        held.message_of(&finding.row)
    }

    pub fn of(&self, file: FileID) -> Option<&Diagnostics> {
        self.files.get(file.index() as usize)
    }

    pub fn of_mut(&mut self, file: FileID) -> Option<&mut Diagnostics> {
        self.files.get_mut(file.index() as usize)
    }

    pub fn order(&self) -> &[FileID] {
        &self.order
    }

    #[must_use]
    pub fn push(&mut self, file: FileID, row: Diagnostic) -> bool {
        let Some(held) = self.of_mut(file) else {
            return false;
        };

        held.push(row)
    }

    #[must_use]
    pub fn push_formatted(
        &mut self,
        file: FileID,
        row: Diagnostic,
        arguments: fmt::Arguments<'_>,
    ) -> bool {
        let Some(held) = self.of_mut(file) else {
            return false;
        };

        held.push_formatted_row(row, arguments)
    }

    #[must_use]
    pub fn push_related(&mut self, file: FileID, related: Related) -> bool {
        let Some(held) = self.of_mut(file) else {
            return false;
        };

        held.push_related(related)
    }

    #[must_use]
    pub fn push_related_formatted(
        &mut self,
        file: FileID,
        related: Related,
        arguments: fmt::Arguments<'_>,
    ) -> bool {
        let Some(held) = self.of_mut(file) else {
            return false;
        };

        held.push_related_formatted(related.file, related.span, arguments)
    }

    pub fn related_count(&self, file: FileID) -> u32 {
        self.of(file).map_or(0, Diagnostics::related_count)
    }

    pub fn related_message_of(&self, finding: &Finding, related: &Related) -> &[u8] {
        let Some(held) = self.of(finding.file) else {
            return &[];
        };

        held.related_message_of(related)
    }

    pub fn related_of(&self, finding: &Finding) -> &[Related] {
        let Some(held) = self.of(finding.file) else {
            return &[];
        };

        held.related_of(&finding.row)
    }

    pub fn sort(&mut self, mut compare: impl FnMut(FileID, FileID) -> Ordering) {
        self.order.clear();

        for index in 0..self.files.count() {
            let held = &mut self.files[index as usize];

            if held.is_empty() {
                continue;
            }

            held.sort();
            self.order.push_assert(FileID::of(index));
        }

        self.order.sort_by(|left, right| compare(*left, *right));

        assert!(self.order.count() <= self.files.count());
    }
}

impl Iterator for Walk<'_> {
    type Item = Finding;

    fn next(&mut self) -> Option<Finding> {
        loop {
            let file = self.held.order.get(self.at as usize).copied()?;
            let held = self.held.of(file)?;

            if self.row >= held.count() {
                self.at = self.at.saturating_add(1);
                self.row = 0;

                continue;
            }

            let row = held.at(self.row).copied()?;

            self.row = self.row.saturating_add(1);

            return Some(Finding { file, row });
        }
    }
}

impl<'run> IntoIterator for &'run Findings {
    type IntoIter = Walk<'run>;
    type Item = Finding;

    fn into_iter(self) -> Self::IntoIter {
        self.iter()
    }
}

pub fn path_order(left: &[u8], right: &[u8]) -> Ordering {
    let folded = |byte: &u8| if *byte == b'/' { 0_u8 } else { *byte };

    left.iter().map(folded).cmp(right.iter().map(folded))
}

pub fn shared(count: u32, files: u32) -> u32 {
    assert!(files > 0);

    count.checked_div(files).unwrap_or(count).max(1)
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
            ..row("TS001", 0, FIX_NONE)
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
                ..row("TS001", 0, FIX_NONE)
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

        assert!(diagnostics.push(row("TS001", 0, FIX_NONE)));

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
            ..row("TS001", 0, FIX_NONE)
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
            assert!(diagnostics.push(row("TS001", offset, FIX_NONE)));
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

        assert!(diagnostics.push(row("TS001", 0, FIX_NONE)));
        assert!(diagnostics.push(row("TS002", 4, 1)));
        assert!(!diagnostics.push(row("TS003", 8, FIX_NONE)));
        assert_eq!(diagnostics.count(), 2);

        diagnostics.clear();

        assert_eq!(diagnostics.count(), 0);
        assert!(diagnostics.push(row("TS003", 8, FIX_NONE)));
    }

    #[test]
    fn a_sort_orders_by_offset_then_code() {
        let mut diagnostics = Diagnostics::reserve(8, 1 << 12);

        assert!(diagnostics.push(row("TS009", 12, FIX_NONE)));
        assert!(diagnostics.push(row("TS002", 4, FIX_NONE)));
        assert!(diagnostics.push(row("TS001", 4, FIX_NONE)));
        assert!(diagnostics.push(row("TS005", 0, FIX_NONE)));

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
        let bare = row("TS001", 0, FIX_NONE);

        assert!(fixed.is_fixed());
        assert!(!bare.is_fixed());
        assert_eq!(Severity::Error.name(), "error");
        assert_eq!(Severity::Hint.name(), "hint");
        assert_eq!(Severity::Information.name(), "info");
        assert_eq!(Severity::of("WARN"), Some(Severity::Warning));
        assert_eq!(Severity::of("information"), Some(Severity::Information));
        assert_eq!(Severity::of("loud"), None);
        assert_eq!(Severity::Error.lsp_code(), 1);
        assert_eq!(Severity::Warning.lsp_code(), 2);
        assert_eq!(Severity::Information.lsp_code(), 3);
        assert_eq!(Severity::Hint.lsp_code(), 4);
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
            assert!(diagnostics.push(row("TS001", random.below(1_000), FIX_NONE)));
        }

        diagnostics.sort();

        let mut offset_previous = 0;

        for diagnostic in &diagnostics {
            assert!(diagnostic.span.offset >= offset_previous);

            offset_previous = diagnostic.span.offset;
        }
    }

    #[test]
    fn a_findings_table_walks_its_files_in_the_sorted_order() {
        let mut findings = Findings::reserve(3, 4, 1 << 10);
        let paths: [&[u8]; 3] = [b"b/z.rs", b"a/y.rs", b"a-x.rs"];

        assert!(findings.push(FileID::of(0), row("TS002", 8, FIX_NONE)));
        assert!(findings.push(FileID::of(0), row("TS001", 2, FIX_NONE)));
        assert!(findings.push(FileID::of(2), row("TS003", 0, FIX_NONE)));
        assert_eq!(findings.count(), 3);
        assert!(!findings.is_empty());
        assert!(!findings.is_overflowed());

        findings.sort(|left, right| {
            path_order(paths[left.index() as usize], paths[right.index() as usize])
        });

        assert_eq!(findings.order(), &[FileID::of(2), FileID::of(0)]);

        let walked: Vec<(u32, u32)> = findings
            .iter()
            .map(|finding| (finding.file.index(), finding.row.span.offset))
            .collect();

        assert_eq!(walked, vec![(2, 0), (0, 2), (0, 8)]);

        let first = findings.iter().next().expect("a row was walked");

        assert_eq!(findings.message_of(&first), b"a recorded finding");
        assert!(findings.related_of(&first).is_empty());

        findings.clear();

        assert!(findings.is_empty());
        assert_eq!(findings.count(), 0);
    }

    #[test]
    fn a_findings_table_carries_related_rows_and_detaches_a_fix() {
        let mut findings = Findings::reserve(2, 4, 1 << 10);
        let file = FileID::of(1);

        assert!(findings.push_related(file, related_row(4)));

        assert!(findings.push_related_formatted(
            file,
            related_row(8),
            format_args!("bound at {}", 8)
        ));

        assert_eq!(findings.related_count(file), 2);
        assert_eq!(findings.related_count(FileID::of(0)), 0);

        assert!(findings.push_formatted(
            file,
            Diagnostic {
                related_count: 2,
                related_start: 0,
                ..row("TS001", 0, 3)
            },
            format_args!("names {}", "two"),
        ));

        findings.sort(|_, _| Ordering::Equal);

        let finding = findings.iter().next().expect("a row was walked");
        let related = findings.related_of(&finding);

        assert_eq!(related.len(), 2);
        assert_eq!(findings.message_of(&finding), b"names two");
        assert_eq!(
            findings.related_message_of(&finding, &related[1]),
            b"bound at 8"
        );
        assert!(finding.row.is_fixed());

        findings.detach(file, 0);

        let detached = findings.iter().next().expect("a row was walked");

        assert!(!detached.row.is_fixed());
        assert_eq!(findings.file_count(), 2);
    }

    #[test]
    fn a_findings_table_refuses_a_file_it_does_not_hold() {
        let mut findings = Findings::reserve(1, 2, 1 << 10);
        let missing = FileID::of(4);

        assert!(!findings.push(missing, row("TS001", 0, FIX_NONE)));
        assert!(!findings.push_related(missing, related_row(0)));
        assert!(findings.of(missing).is_none());
        assert!(findings.of_mut(missing).is_none());
    }

    #[test]
    fn a_path_order_sorts_a_separator_before_every_byte() {
        assert_eq!(path_order(b"a/b.rs", b"a-b.rs"), Ordering::Less);
        assert_eq!(path_order(b"a.rs", b"a.rs"), Ordering::Equal);
        assert_eq!(path_order(b"b", b"a"), Ordering::Greater);
        assert_eq!(shared(10, 4), 2);
        assert_eq!(shared(1, 4), 1);
        assert_eq!(shared(8, 1), 8);
    }
}
