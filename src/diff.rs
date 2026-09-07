use crate::bounded::{BoundedVec, Span};
use crate::scan::{decimal_width, text_of};
use crate::sink::{GREEN, RED, Sink};

pub const CONTEXT_LINES: u32 = 3;
pub const LINES_MAX: u32 = 512;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Step {
    Delete,
    Equal,
    Insert,
}

pub struct Diff {
    after: BoundedVec<Span>,
    before: BoundedVec<Span>,
    lengths: BoundedVec<u16>,
    steps: BoundedVec<Step>,
}

impl Diff {
    pub fn align(&mut self, before: &[u8], after: &[u8]) {
        self.after.clear();
        self.before.clear();
        self.steps.clear();

        lines_of(before, &mut self.before);
        lines_of(after, &mut self.after);

        let head = self.common_head(before, after);
        let tail = self.common_tail(before, after, head);

        let before_middle = self
            .before
            .count()
            .saturating_sub(head)
            .saturating_sub(tail);

        let after_middle = self.after.count().saturating_sub(head).saturating_sub(tail);

        for _ in 0..head {
            self.steps.push_assert(Step::Equal);
        }

        if before_middle > LINES_MAX || after_middle > LINES_MAX {
            for _ in 0..before_middle {
                self.steps.push_assert(Step::Delete);
            }

            for _ in 0..after_middle {
                self.steps.push_assert(Step::Insert);
            }
        } else {
            self.align_middle(before, after, head, before_middle, after_middle);
            self.walk_middle(before, after, head, before_middle, after_middle);
        }

        for _ in 0..tail {
            self.steps.push_assert(Step::Equal);
        }

        assert!(self.steps.count() >= self.before.count().max(self.after.count()));
    }

    fn align_middle(&mut self, before: &[u8], after: &[u8], head: u32, rows: u32, columns: u32) {
        assert!(rows <= LINES_MAX);
        assert!(columns <= LINES_MAX);

        let width = columns.saturating_add(1);

        self.lengths.clear();

        for _ in 0..rows.saturating_add(1).saturating_mul(width) {
            self.lengths.push_assert(0);
        }

        let mut row = rows;

        while row > 0 {
            row = row.saturating_sub(1);

            let mut column = columns;

            while column > 0 {
                column = column.saturating_sub(1);

                let same = self.line_equal(
                    before,
                    after,
                    head.saturating_add(row),
                    head.saturating_add(column),
                );

                let value = if same {
                    self.length_at(row.saturating_add(1), column.saturating_add(1), width)
                        .saturating_add(1)
                } else {
                    self.length_at(row.saturating_add(1), column, width)
                        .max(self.length_at(row, column.saturating_add(1), width))
                };

                self.length_set(row, column, width, value);
            }
        }
    }

    fn change_end(&self, from: u32) -> u32 {
        let mut at = from;

        while let Some(step) = self.steps.get(usize::try_from(at).unwrap_or(usize::MAX)) {
            if *step == Step::Equal {
                break;
            }

            at = at.saturating_add(1);
        }

        at
    }

    fn common_head(&self, before: &[u8], after: &[u8]) -> u32 {
        let mut count = 0_u32;

        while count < self.before.count() && count < self.after.count() {
            if !self.line_equal(before, after, count, count) {
                break;
            }

            count = count.saturating_add(1);
        }

        count
    }

    fn common_tail(&self, before: &[u8], after: &[u8], head: u32) -> u32 {
        let mut count = 0_u32;

        while count.saturating_add(head) < self.before.count()
            && count.saturating_add(head) < self.after.count()
        {
            let left = self.before.count().saturating_sub(count).saturating_sub(1);
            let right = self.after.count().saturating_sub(count).saturating_sub(1);

            if !self.line_equal(before, after, left, right) {
                break;
            }

            count = count.saturating_add(1);
        }

        count
    }

    fn length_at(&self, row: u32, column: u32, width: u32) -> u16 {
        let index = row.saturating_mul(width).saturating_add(column);

        self.lengths
            .get(usize::try_from(index).unwrap_or(usize::MAX))
            .copied()
            .unwrap_or(0)
    }

    fn length_set(&mut self, row: u32, column: u32, width: u32, value: u16) {
        let index = row.saturating_mul(width).saturating_add(column);

        if let Some(slot) = self
            .lengths
            .get_mut(usize::try_from(index).unwrap_or(usize::MAX))
        {
            *slot = value;
        }
    }

    fn line_equal(&self, before: &[u8], after: &[u8], left: u32, right: u32) -> bool {
        let held_left = self
            .before
            .get(usize::try_from(left).unwrap_or(usize::MAX))
            .map(|span| trimmed(before, *span));

        let held_right = self
            .after
            .get(usize::try_from(right).unwrap_or(usize::MAX))
            .map(|span| trimmed(after, *span));

        held_left.is_some() && held_left == held_right
    }

    fn next_change(&self, from: u32) -> Option<u32> {
        let mut at = from;

        while let Some(step) = self.steps.get(usize::try_from(at).unwrap_or(usize::MAX)) {
            if *step != Step::Equal {
                return Some(at);
            }

            at = at.saturating_add(1);
        }

        None
    }

    pub fn reserve(line_count_max: u32) -> Self {
        assert!(line_count_max > 0);
        assert!(!crate::allocation::is_frozen());

        let lines = line_count_max.max(LINES_MAX.saturating_add(1));

        Self {
            after: BoundedVec::reserve(lines),
            before: BoundedVec::reserve(lines),
            lengths: BoundedVec::reserve(
                LINES_MAX
                    .saturating_add(1)
                    .saturating_mul(LINES_MAX.saturating_add(1)),
            ),
            steps: BoundedVec::reserve(lines.saturating_mul(2)),
        }
    }

    pub fn steps(&self) -> &[Step] {
        &self.steps
    }

    fn walk_middle(&mut self, before: &[u8], after: &[u8], head: u32, rows: u32, columns: u32) {
        let width = columns.saturating_add(1);
        let mut at_row = 0_u32;
        let mut at_column = 0_u32;

        while at_row < rows || at_column < columns {
            let same = at_row < rows
                && at_column < columns
                && self.line_equal(
                    before,
                    after,
                    head.saturating_add(at_row),
                    head.saturating_add(at_column),
                );

            if same {
                self.steps.push_assert(Step::Equal);
                at_row = at_row.saturating_add(1);
                at_column = at_column.saturating_add(1);

                continue;
            }

            let down = if at_row < rows {
                self.length_at(at_row.saturating_add(1), at_column, width)
            } else {
                0
            };

            let right = if at_column < columns {
                self.length_at(at_row, at_column.saturating_add(1), width)
            } else {
                0
            };

            if at_row < rows && (at_column >= columns || down >= right) {
                self.steps.push_assert(Step::Delete);
                at_row = at_row.saturating_add(1);
            } else {
                self.steps.push_assert(Step::Insert);
                at_column = at_column.saturating_add(1);
            }
        }

        assert_eq!(at_row, rows);
        assert_eq!(at_column, columns);
    }

    fn write_hunk(&self, out: &mut Sink, before: &[u8], after: &[u8], start: u32, end: u32) {
        assert!(start <= end);

        let mut left = 0_u32;
        let mut right = 0_u32;
        let mut index = 0_u32;

        while index < start {
            match self.steps.get(usize::try_from(index).unwrap_or(usize::MAX)) {
                Some(Step::Delete) => left = left.saturating_add(1),
                Some(Step::Insert) => right = right.saturating_add(1),
                Some(Step::Equal) => {
                    left = left.saturating_add(1);
                    right = right.saturating_add(1);
                }
                None => break,
            }

            index = index.saturating_add(1);
        }

        let mut removed = 0_u32;
        let mut added = 0_u32;

        for at in start..end {
            match self.steps.get(usize::try_from(at).unwrap_or(usize::MAX)) {
                Some(Step::Delete) => removed = removed.saturating_add(1),
                Some(Step::Insert) => added = added.saturating_add(1),
                Some(Step::Equal) => {
                    removed = removed.saturating_add(1);
                    added = added.saturating_add(1);
                }
                None => break,
            }
        }

        out.push("@@ -");
        write_range(out, left, removed);
        out.push(" +");
        write_range(out, right, added);
        out.push(" @@\n");

        let mut at_left = usize::try_from(left).unwrap_or(usize::MAX);
        let mut at_right = usize::try_from(right).unwrap_or(usize::MAX);

        for at in start..end {
            match self.steps.get(usize::try_from(at).unwrap_or(usize::MAX)) {
                Some(Step::Delete) => {
                    write_line(out, "-", before, self.before.get(at_left).copied());
                    at_left = at_left.saturating_add(1);
                }
                Some(Step::Insert) => {
                    write_line(out, "+", after, self.after.get(at_right).copied());
                    at_right = at_right.saturating_add(1);
                }
                Some(Step::Equal) => {
                    write_line(out, " ", after, self.after.get(at_right).copied());
                    at_left = at_left.saturating_add(1);
                    at_right = at_right.saturating_add(1);
                }
                None => break,
            }
        }
    }

    pub fn write_unified(
        &mut self,
        out: &mut Sink,
        path: &str,
        before: &[u8],
        after: &[u8],
        context_lines: u32,
    ) {
        self.align(before, after);

        if self.steps.iter().all(|step| *step == Step::Equal) {
            return;
        }

        out.push_line(format_args!("--- {path}\n+++ {path}"));

        let count = self.steps.count();
        let mut at = 0_u32;

        while at < count {
            let Some(start) = self.next_change(at) else {
                break;
            };

            let hunk_start = start.saturating_sub(context_lines).max(at);
            let mut hunk_end = start;

            for _ in 0..count {
                let found = self.next_change(hunk_end);
                let padded = hunk_end.saturating_add(context_lines).min(count);

                let Some(next) = found else {
                    hunk_end = padded;

                    break;
                };

                if next.saturating_sub(hunk_end) > context_lines.saturating_mul(2) {
                    hunk_end = padded;

                    break;
                }

                hunk_end = self.change_end(next);
            }

            self.write_hunk(out, before, after, hunk_start, hunk_end);

            assert!(hunk_end > at);

            at = hunk_end;
        }
    }

    pub fn write_window(&mut self, out: &mut Sink, before: &[u8], after: &[u8], number_first: u32) {
        self.align(before, after);

        let width_columns =
            decimal_width(u64::from(number_first.saturating_add(self.after.count())));

        let mut number = number_first;
        let mut left = 0_usize;
        let mut right = 0_usize;

        write_gutter(out, width_columns);

        for step in self.steps.iter() {
            match *step {
                Step::Delete => {
                    let text = self
                        .before
                        .get(left)
                        .map_or("", |span| text_of(trimmed(before, *span), ""));

                    left = left.saturating_add(1);

                    for _ in 0..width_columns {
                        out.push(" ");
                    }

                    write_moved(out, "-", text, RED);
                }
                Step::Equal => {
                    let text = self
                        .after
                        .get(right)
                        .map_or("", |span| text_of(trimmed(after, *span), ""));

                    left = left.saturating_add(1);
                    right = right.saturating_add(1);

                    out.push_line(format_args!("{number:>width_columns$} | {text}"));

                    number = number.saturating_add(1);
                }
                Step::Insert => {
                    let text = self
                        .after
                        .get(right)
                        .map_or("", |span| text_of(trimmed(after, *span), ""));

                    right = right.saturating_add(1);

                    out.push_format(format_args!("{number:>width_columns$}"));
                    write_moved(out, "+", text, GREEN);

                    number = number.saturating_add(1);
                }
            }
        }

        write_gutter(out, width_columns);
    }
}

fn lines_of(text: &[u8], out: &mut BoundedVec<Span>) {
    let mut start = 0_usize;

    while start < text.len() {
        let end = text
            .get(start..)
            .and_then(|rest| rest.iter().position(|byte| *byte == b'\n'))
            .map_or(text.len(), |at| start.saturating_add(at).saturating_add(1));

        assert!(end > start);

        let span = Span::between(
            u32::try_from(start).unwrap_or(u32::MAX),
            u32::try_from(end).unwrap_or(u32::MAX),
        );

        if !out.push(span) {
            return;
        }

        start = end;
    }
}

fn trimmed(text: &[u8], span: Span) -> &[u8] {
    let mut held = text.get(span.range()).unwrap_or(&[]);

    while let Some((last, rest)) = held.split_last() {
        if *last != b'\n' && *last != b'\r' {
            break;
        }

        held = rest;
    }

    held
}

fn write_gutter(out: &mut Sink, width_columns: usize) {
    for _ in 0..width_columns {
        out.push(" ");
    }

    out.push(" |\n");
}

fn write_line(out: &mut Sink, marker: &str, text: &[u8], line: Option<Span>) {
    let Some(span) = line else {
        return;
    };

    let held = text.get(span.range()).unwrap_or(&[]);

    out.push(marker);
    out.push(text_of(trimmed(text, span), ""));
    out.push("\n");

    if !held.ends_with(b"\n") {
        out.push("\\ No newline at end of file\n");
    }
}

fn write_moved(out: &mut Sink, marker: &str, text: &str, ink: &str) {
    out.push(" ");
    out.painted(marker, &[ink]);
    out.push(" ");
    out.painted(text, &[ink]);
    out.push("\n");
}

fn write_range(out: &mut Sink, start: u32, count: u32) {
    let shown = if count == 0 {
        start
    } else {
        start.saturating_add(1)
    };

    if count == 1 {
        out.push_format(format_args!("{shown}"));
    } else {
        out.push_format(format_args!("{shown},{count}"));
    }
}

#[cfg(test)]
mod tests {
    use super::{CONTEXT_LINES, Diff, Step};
    use crate::allocation;
    use crate::sink::{Sink, Target};

    const OUT_BYTES_MAX: u32 = 1 << 12;

    fn steps_of(before: &[u8], after: &[u8]) -> Vec<Step> {
        let mut diff = Diff::reserve(1 << 6);

        allocation::frozen(|| diff.align(before, after));

        diff.steps().to_vec()
    }

    fn unified(before: &str, after: &str) -> String {
        let mut diff = Diff::reserve(1 << 6);
        let mut out = Sink::reserve(OUT_BYTES_MAX, Target::Memory, false);

        allocation::frozen(|| {
            diff.write_unified(
                &mut out,
                "a.txt",
                before.as_bytes(),
                after.as_bytes(),
                CONTEXT_LINES,
            );
        });

        out.as_str().to_owned()
    }

    #[test]
    fn an_identical_text_aligns_as_equal_steps() {
        assert_eq!(steps_of(b"a\nb\n", b"a\nb\n"), [Step::Equal, Step::Equal]);
    }

    #[test]
    fn a_replaced_line_aligns_as_a_delete_then_an_insert() {
        assert_eq!(
            steps_of(b"a\nb\nc\n", b"a\nB\nc\n"),
            [Step::Equal, Step::Delete, Step::Insert, Step::Equal]
        );
    }

    #[test]
    fn a_line_moved_past_another_keeps_the_longest_common_run() {
        assert_eq!(
            steps_of(b"a\nb\nc\nd\n", b"b\nc\nd\na\n"),
            [
                Step::Delete,
                Step::Equal,
                Step::Equal,
                Step::Equal,
                Step::Insert
            ]
        );
    }

    #[test]
    fn a_missing_final_newline_is_noted_on_both_sides() {
        assert_eq!(
            unified("a", "b"),
            "--- a.txt\n+++ a.txt\n@@ -1 +1 @@\n-a\n\\ No newline at end of file\n+b\n\\ No newline at end of file\n",
        );
    }

    #[test]
    fn carriage_returns_do_not_make_two_lines_differ() {
        assert_eq!(unified("a\r\nb\r\n", "a\nb\n"), "");
    }
}
