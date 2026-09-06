use core::fmt::{self, Write as _};

use crate::bounded::{BoundedVec, Buffer, Bytes as _, Span, count_of};
use crate::diagnostic::{MESSAGE_UNWRITTEN, Message};

pub const NONE: u32 = u32::MAX;

#[expect(
    clippy::arbitrary_source_item_ordering,
    reason = "the derived `Ord` makes the declared order the strength ladder that `reaches` \
              compares on"
)]
#[derive(Clone, Copy, Debug, Eq, Ord, PartialEq, PartialOrd)]
pub enum Applicability {
    DisplayOnly,
    Unsafe,
    Safe,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Edit {
    pub replacement: Span,
    pub span: Span,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Piece {
    Formatted(Span),
    Literal(&'static [u8]),
    Source(Span),
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Marker {
    pub source: u32,
    pub target: u32,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Fix {
    pub applicability: Applicability,
    pub edit_count: u32,
    pub edit_start: u32,
    pub isolation: u32,
    pub title: Message,
}

#[derive(Clone, Copy, Debug)]
struct Pending {
    applicability: Applicability,
    arena_start: u32,
    discarded: bool,
    edit_count: u32,
    edit_start: u32,
    isolation: u32,
    title: Message,
}

#[derive(Debug)]
pub struct Fixes {
    arena: Buffer,
    edits: BoundedVec<Edit>,
    items: BoundedVec<Fix>,
    overflowed: bool,
    pending: Option<Pending>,
}

struct Writer<'run> {
    buffer: &'run mut Buffer,
    full: bool,
}

impl fmt::Write for Writer<'_> {
    fn write_str(&mut self, text: &str) -> fmt::Result {
        if self.buffer.push_bytes(text.as_bytes()) {
            return Ok(());
        }

        self.full = true;

        Err(fmt::Error)
    }
}

impl Applicability {
    pub const fn name(self) -> &'static str {
        match self {
            Self::DisplayOnly => "display-only",
            Self::Safe => "safe",
            Self::Unsafe => "unsafe",
        }
    }

    pub fn reaches(self, minimum: Self) -> bool {
        match self {
            Self::DisplayOnly => false,
            Self::Safe => true,
            Self::Unsafe => minimum == Self::Unsafe,
        }
    }
}

impl Fixes {
    pub fn reserve(fix_count_max: u32, edit_count_max: u32, arena_bytes_max: u32) -> Self {
        assert!(fix_count_max > 0);
        assert!(edit_count_max > 0);
        assert!(arena_bytes_max > 0);

        assert!(!crate::allocation::is_frozen());

        Self {
            arena: Buffer::reserve(arena_bytes_max),
            edits: BoundedVec::reserve(edit_count_max),
            items: BoundedVec::reserve(fix_count_max),
            overflowed: false,
            pending: None,
        }
    }

    pub fn clear(&mut self) {
        self.arena.clear();
        self.edits.clear();
        self.items.clear();
        self.overflowed = false;
        self.pending = None;

        assert_eq!(self.count(), 0);
        assert!(!self.is_overflowed());
    }

    pub const fn is_overflowed(&self) -> bool {
        self.overflowed
    }

    pub fn close(&mut self) -> u32 {
        let Some(pending) = self.pending.take() else {
            return NONE;
        };

        if pending.discarded || pending.edit_count == 0 {
            self.rewind(&pending);

            return NONE;
        }

        let index = self.items.count();

        let pushed = self.items.push(Fix {
            applicability: pending.applicability,
            edit_count: pending.edit_count,
            edit_start: pending.edit_start,
            isolation: pending.isolation,
            title: pending.title,
        });

        if !pushed {
            self.overflowed = true;

            self.rewind(&pending);

            return NONE;
        }

        assert!(index < self.count());

        index
    }

    pub fn count(&self) -> u32 {
        self.items.count()
    }

    pub fn discard(&mut self) {
        let Some(pending) = self.pending.take() else {
            return;
        };

        self.rewind(&pending);

        assert!(self.pending.is_none());
    }

    #[must_use]
    pub fn edit(&mut self, span: Span, replacement: &[u8]) -> bool {
        assert!(self.pending.is_some());

        let mut pending = self.pending.expect("a fix is open");

        if pending.discarded {
            return false;
        }

        let arena_before = self.arena.count();

        if !self.arena.push_bytes(replacement) {
            self.overflowed = true;

            pending.discarded = true;
            self.pending = Some(pending);

            return false;
        }

        let pushed = self.edits.push(Edit {
            replacement: Span {
                length: count_of(replacement.len()),
                offset: arena_before,
            },
            span,
        });

        if !pushed {
            self.arena.truncate(arena_before);
            self.overflowed = true;

            pending.discarded = true;
            self.pending = Some(pending);

            return false;
        }

        pending.edit_count += 1;
        self.pending = Some(pending);

        true
    }

    #[must_use]
    pub fn edit_formatted(&mut self, span: Span, arguments: fmt::Arguments<'_>) -> bool {
        assert!(self.pending.is_some());

        let mut pending = self.pending.expect("a fix is open");

        if pending.discarded {
            return false;
        }

        let arena_before = self.arena.count();

        let Some(written) = self.written(arguments, arena_before) else {
            pending.discarded = true;
            self.pending = Some(pending);

            return false;
        };

        let pushed = self.edits.push(Edit {
            replacement: written,
            span,
        });

        if !pushed {
            self.arena.truncate(arena_before);
            self.overflowed = true;

            pending.discarded = true;
            self.pending = Some(pending);

            return false;
        }

        pending.edit_count += 1;
        self.pending = Some(pending);

        true
    }

    pub fn edits_of(&self, fix: &Fix) -> &[Edit] {
        let start = fix.edit_start as usize;
        let end = start + fix.edit_count as usize;

        assert!(end <= self.edits.len());

        &self.edits[start..end]
    }

    pub fn get(&self, index: u32) -> Option<&Fix> {
        if index == NONE {
            return None;
        }

        self.items.get(index as usize)
    }

    pub fn open(&mut self, title: &'static str, applicability: Applicability, isolation: u32) {
        assert!(!title.is_empty());

        self.opened(Message::Static(title), applicability, isolation);
    }

    pub fn open_formatted(
        &mut self,
        applicability: Applicability,
        isolation: u32,
        arguments: fmt::Arguments<'_>,
    ) {
        let start = self.arena.count();

        let title = self
            .written(arguments, start)
            .map_or(Message::Static(MESSAGE_UNWRITTEN), Message::Arena);

        self.opened(title, applicability, isolation);
    }

    fn opened(&mut self, title: Message, applicability: Applicability, isolation: u32) {
        assert!(self.pending.is_none());

        let arena_start = match title {
            Message::Arena(span) => span.offset,
            Message::Static(_) => self.arena.count(),
        };

        self.pending = Some(Pending {
            applicability,
            arena_start,
            discarded: false,
            edit_count: 0,
            edit_start: self.edits.count(),
            isolation,
            title,
        });

        assert!(self.pending.is_some());
    }

    pub fn reshape(&mut self, index: u32, applicability: Applicability) {
        let Some(fix) = self.items.get_mut(index as usize) else {
            return;
        };

        fix.applicability = applicability;
    }

    pub fn title_of(&self, fix: &Fix) -> &[u8] {
        match fix.title {
            Message::Arena(span) => self.arena.as_bytes().get(span.range()).unwrap_or_default(),
            Message::Static(text) => text.as_bytes(),
        }
    }

    fn written(&mut self, arguments: fmt::Arguments<'_>, start: u32) -> Option<Span> {
        let mut writer = Writer {
            buffer: &mut self.arena,
            full: false,
        };

        let outcome = write!(writer, "{arguments}");
        let full = writer.full;

        if outcome.is_err() || full {
            self.arena.truncate(start);
            self.overflowed = true;

            return None;
        }

        Some(Span {
            length: self.arena.count().saturating_sub(start),
            offset: start,
        })
    }

    #[must_use]
    pub fn render(&mut self, span: Span, source: &[u8], scratch: &[u8], pieces: &[Piece]) -> bool {
        assert!(self.pending.is_some());

        let mut pending = self.pending.expect("a fix is open");

        if pending.discarded {
            return false;
        }

        let arena_before = self.arena.count();

        for piece in pieces {
            let bytes = match *piece {
                Piece::Formatted(held) => {
                    assert!(held.end() as usize <= scratch.len());

                    &scratch[held.range()]
                }
                Piece::Literal(held) => held,
                Piece::Source(held) => {
                    assert!(held.end() as usize <= source.len());

                    &source[held.range()]
                }
            };

            if !self.arena.push_bytes(bytes) {
                self.arena.truncate(arena_before);

                pending.discarded = true;
                self.pending = Some(pending);

                return false;
            }
        }

        assert!(self.arena.count() >= arena_before);

        let pushed = self.edits.push(Edit {
            replacement: Span {
                length: self.arena.count() - arena_before,
                offset: arena_before,
            },
            span,
        });

        if !pushed {
            self.arena.truncate(arena_before);

            pending.discarded = true;
            self.pending = Some(pending);

            return false;
        }

        pending.edit_count += 1;
        self.pending = Some(pending);

        true
    }

    pub fn replacement_of(&self, edit: &Edit) -> &[u8] {
        assert!(edit.replacement.end() <= self.arena.count());

        &self.arena.as_bytes()[edit.replacement.range()]
    }

    fn rewind(&mut self, pending: &Pending) {
        assert!(pending.edit_start <= self.edits.count());

        self.arena.truncate(pending.arena_start);
        self.edits.truncate(pending.edit_start);

        assert_eq!(self.edits.count(), pending.edit_start);
    }
}

#[must_use]
pub fn apply(source: &[u8], fixes: &Fixes, edits: &[Edit], out: &mut Buffer) -> bool {
    ascending_edits(source, edits);

    out.clear();

    let mut cursor = 0;

    for edit in edits {
        if !copy_through(source, fixes, edit, cursor, out) {
            return false;
        }

        cursor = edit.span.end();
    }

    if !out.push_bytes(&source[cursor as usize..]) {
        out.clear();

        return false;
    }

    true
}

#[must_use]
pub fn apply_mapped(
    source: &[u8],
    fixes: &Fixes,
    edits: &[Edit],
    out: &mut Buffer,
    markers: &mut BoundedVec<Marker>,
) -> bool {
    ascending_edits(source, edits);

    out.clear();
    markers.clear();

    let mut cursor = 0;

    for edit in edits {
        if !copy_through(source, fixes, edit, cursor, out) {
            markers.clear();

            return false;
        }

        let target = out.count();

        if !markers.push(Marker {
            source: edit.span.offset,
            target,
        }) || !markers.push(Marker {
            source: edit.span.end(),
            target,
        }) {
            out.clear();
            markers.clear();

            return false;
        }

        cursor = edit.span.end();
    }

    if !out.push_bytes(&source[cursor as usize..]) {
        out.clear();
        markers.clear();

        return false;
    }

    true
}

pub fn offset_after(markers: &[Marker], offset: u32) -> u32 {
    let mut low = 0;
    let mut high = markers.len();

    while low < high {
        let middle = low + (high - low) / 2;

        if markers[middle].source <= offset {
            low = middle + 1;
        } else {
            high = middle;
        }
    }

    if low == 0 {
        return offset;
    }

    let held = markers[low - 1];

    if low < markers.len() && markers[low].target == held.target {
        return held.target;
    }

    assert!(offset >= held.source);

    held.target + (offset - held.source)
}

fn ascending_edits(source: &[u8], edits: &[Edit]) {
    let length = count_of(source.len());
    let mut cursor = 0;

    for edit in edits {
        assert!(edit.span.offset >= cursor);
        assert!(edit.span.end() <= length);

        cursor = edit.span.end();
    }
}

fn copy_through(source: &[u8], fixes: &Fixes, edit: &Edit, cursor: u32, out: &mut Buffer) -> bool {
    assert!(edit.span.offset >= cursor);

    if !out.push_bytes(&source[cursor as usize..edit.span.offset as usize]) {
        out.clear();

        return false;
    }

    if !out.push_bytes(fixes.replacement_of(edit)) {
        out.clear();

        return false;
    }

    true
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Pass {
    Applied(u32),
    Overflowed,
}

pub fn apply_pass(
    source: &[u8],
    fixes: &Fixes,
    minimum: Applicability,
    claimed: &mut BoundedVec<Span>,
    selected: &mut BoundedVec<u32>,
    held: &mut BoundedVec<Edit>,
    target: &mut Buffer,
) -> Pass {
    assert_ne!(minimum, Applicability::DisplayOnly);

    held.clear();
    plan(fixes, minimum, claimed, selected);

    let length = count_of(source.len());
    let mut applied = 0;
    let mut cursor = 0_u32;

    for index in selected.iter() {
        let fix = *fixes.get(*index).expect("a selected fix is recorded");
        let edits = fixes.edits_of(&fix);

        if !spliceable(edits, cursor, length) {
            continue;
        }

        for edit in edits {
            if !held.push(*edit) {
                return Pass::Overflowed;
            }

            cursor = edit.span.end();
        }

        applied += 1;
    }

    if !apply(source, fixes, held, target) {
        return Pass::Overflowed;
    }

    Pass::Applied(applied)
}

fn spliceable(edits: &[Edit], cursor: u32, length: u32) -> bool {
    let mut last = cursor;

    for edit in edits {
        if edit.span.offset < last {
            return false;
        }

        if edit.span.end() > length {
            return false;
        }

        last = edit.span.end();
    }

    true
}

pub fn plan(
    fixes: &Fixes,
    minimum: Applicability,
    claimed: &mut BoundedVec<Span>,
    selected: &mut BoundedVec<u32>,
) {
    claimed.clear();
    selected.clear();

    let count = fixes.count();
    let ordered = ascending(fixes);
    let mut claimed_end = 0;
    let mut visited = 0;
    let mut previous = NONE;

    for step in 0..count {
        let index = if ordered {
            step
        } else {
            next_of(fixes, previous)
        };

        if index == NONE {
            break;
        }

        previous = index;
        visited += 1;

        let fix = fixes.get(index).expect("the walk names a recorded fix");

        if !fix.applicability.reaches(minimum) {
            continue;
        }

        if isolated(fixes, selected, fix.isolation) {
            continue;
        }

        let edits = fixes.edits_of(fix);

        if claimed.count() as usize + edits.len() > claimed.capacity() as usize {
            break;
        }

        if selected.is_full() {
            break;
        }

        let clashes = edits
            .iter()
            .any(|edit| edit.span.offset <= claimed_end && overlaps_any(claimed, edit.span));

        if clashes || self_overlapping(edits) {
            continue;
        }

        for edit in edits {
            claimed_end = claimed_end.max(edit.span.end());
            claimed.push_assert(edit.span);
        }

        selected.push_assert(index);
    }

    assert!(visited <= count);
    assert!(selected.count() <= count);
}

fn ascending(fixes: &Fixes) -> bool {
    let count = fixes.count();
    let mut previous = 0;

    for index in 0..count {
        let fix = fixes.get(index).expect("the index names a recorded fix");
        let start = start_of(fixes, fix);

        if start < previous {
            return false;
        }

        previous = start;
    }

    true
}

fn isolated(fixes: &Fixes, selected: &[u32], isolation: u32) -> bool {
    if isolation == 0 {
        return false;
    }

    selected.iter().any(|index| {
        fixes
            .get(*index)
            .expect("a selected fix is a recorded fix")
            .isolation
            == isolation
    })
}

fn key_of(fixes: &Fixes, index: u32) -> (u32, u32) {
    let fix = fixes.get(index).expect("the index names a recorded fix");

    (start_of(fixes, fix), index)
}

fn next_of(fixes: &Fixes, previous: u32) -> u32 {
    let count = fixes.count();
    let mut best = (u32::MAX, NONE);

    for index in 0..count {
        let candidate = key_of(fixes, index);

        if previous != NONE && candidate <= key_of(fixes, previous) {
            continue;
        }

        if candidate < best {
            best = candidate;
        }
    }

    best.1
}

pub const fn overlaps(left: Span, right: Span) -> bool {
    left.offset == right.offset || (left.offset < right.end() && right.offset < left.end())
}

pub fn overlaps_any(claimed: &[Span], span: Span) -> bool {
    claimed.iter().any(|held| overlaps(*held, span))
}

fn self_overlapping(edits: &[Edit]) -> bool {
    for (position, edit) in edits.iter().enumerate() {
        let rest = edits.get(position + 1..).unwrap_or_default();

        if rest.iter().any(|other| overlaps(other.span, edit.span)) {
            return true;
        }
    }

    false
}

fn start_of(fixes: &Fixes, fix: &Fix) -> u32 {
    let edits = fixes.edits_of(fix);

    assert!(!edits.is_empty());

    edits[0].span.offset
}

#[cfg(test)]
mod tests {
    use super::*;

    const LADDER: [Applicability; 3] = [
        Applicability::DisplayOnly,
        Applicability::Safe,
        Applicability::Unsafe,
    ];

    fn reserved() -> Fixes {
        Fixes::reserve(8, 16, 64)
    }

    fn span(offset: u32, length: u32) -> Span {
        Span { length, offset }
    }

    fn one(fixes: &mut Fixes, title: &'static str, at: Span, replacement: &[u8]) -> u32 {
        fixes.open(title, Applicability::Safe, 0);

        assert!(fixes.edit(at, replacement));

        fixes.close()
    }

    fn rendered(fixes: &Fixes, index: u32) -> Vec<u8> {
        let fix = *fixes.get(index).expect("the fix is recorded");
        let edits: Vec<Edit> = fixes.edits_of(&fix).to_vec();

        assert_eq!(edits.len(), 1);

        fixes.replacement_of(&edits[0]).to_vec()
    }

    fn planned(fixes: &Fixes, minimum: Applicability) -> Vec<u32> {
        let mut claimed = BoundedVec::reserve(32);
        let mut selected = BoundedVec::reserve(32);

        plan(fixes, minimum, &mut claimed, &mut selected);

        selected.to_vec()
    }

    #[test]
    fn a_formatted_replacement_reads_back_what_was_written() {
        let mut fixes = reserved();

        fixes.open("Rename", Applicability::Safe, 0);

        assert!(fixes.edit_formatted(span(4, 5), format_args!("total_{}", 7)));

        let index = fixes.close();
        let fix = *fixes.get(index).expect("the fix is recorded");

        assert_eq!(fixes.replacement_of(&fixes.edits_of(&fix)[0]), b"total_7");
    }

    #[test]
    fn a_formatted_replacement_that_does_not_fit_discards_its_fix() {
        let mut fixes = Fixes::reserve(4, 4, 8);

        fixes.open("Rename", Applicability::Safe, 0);

        assert!(!fixes.edit_formatted(
            span(0, 1),
            format_args!("{}", "a replacement far past the arena")
        ));

        assert_eq!(fixes.close(), NONE);
        assert!(fixes.is_overflowed());
    }

    #[test]
    fn a_formatted_title_reads_back_what_was_written() {
        let mut fixes = reserved();

        fixes.open_formatted(
            Applicability::Safe,
            0,
            format_args!("Rename to `{}`", "total"),
        );

        assert!(fixes.edit(span(4, 5), b"total"));

        let index = fixes.close();
        let fix = *fixes.get(index).expect("the fix is recorded");

        assert_eq!(fixes.title_of(&fix), b"Rename to `total`");
        assert_eq!(fixes.replacement_of(&fixes.edits_of(&fix)[0]), b"total");
    }

    #[test]
    fn a_reshaped_fix_carries_the_applicability_it_was_given() {
        let mut fixes = reserved();

        fixes.open("Rename", Applicability::Safe, 0);

        assert!(fixes.edit(span(4, 5), b"total"));

        let index = fixes.close();

        fixes.reshape(index, Applicability::Unsafe);

        assert_eq!(
            fixes.get(index).expect("the fix is recorded").applicability,
            Applicability::Unsafe
        );

        fixes.reshape(NONE, Applicability::Safe);
    }

    #[test]
    fn an_arena_that_fills_says_so_and_discards_the_fix() {
        let mut fixes = Fixes::reserve(4, 4, 4);

        fixes.open("Rename", Applicability::Safe, 0);

        assert!(!fixes.edit(span(0, 1), b"far too long"));
        assert_eq!(fixes.close(), NONE);
        assert!(fixes.is_overflowed());
    }

    #[test]
    fn a_table_that_ran_out_of_room_says_so() {
        let mut fixes = Fixes::reserve(1, 4, 1 << 8);

        assert!(!fixes.is_overflowed());

        for _ in 0..2 {
            fixes.open("Rename", Applicability::Safe, 0);

            assert!(fixes.edit(span(0, 1), b"a"));

            fixes.close();
        }

        assert!(fixes.is_overflowed());

        fixes.clear();

        assert!(!fixes.is_overflowed());
    }

    #[test]
    fn a_closed_fix_reads_back_what_went_in() {
        let mut fixes = reserved();

        fixes.open("Rename", Applicability::Safe, 3);

        assert!(fixes.edit(span(4, 5), b"total"));
        assert!(fixes.edit(span(12, 0), b";"));

        let index = fixes.close();

        assert_eq!(index, 0);
        assert_eq!(fixes.count(), 1);

        let fix = *fixes.get(index).expect("the fix is recorded");

        assert_eq!(fix.applicability, Applicability::Safe);
        assert_eq!(fix.edit_count, 2);
        assert_eq!(fix.isolation, 3);
        assert_eq!(fixes.title_of(&fix), b"Rename");

        let edits: Vec<Edit> = fixes.edits_of(&fix).to_vec();

        assert_eq!(edits.len(), 2);
        assert_eq!(edits[0].span, span(4, 5));
        assert_eq!(fixes.replacement_of(&edits[0]), b"total");
        assert_eq!(edits[1].span, span(12, 0));
        assert_eq!(fixes.replacement_of(&edits[1]), b";");
        assert!(fixes.get(NONE).is_none());
    }

    #[test]
    fn an_edit_table_overflow_discards_the_open_fix() {
        let mut fixes = Fixes::reserve(4, 2, 64);

        fixes.open("First", Applicability::Safe, 0);

        assert!(fixes.edit(span(0, 1), b"a"));
        assert!(fixes.edit(span(2, 1), b"b"));
        assert!(!fixes.edit(span(4, 1), b"c"));
        assert_eq!(fixes.close(), NONE);
        assert_eq!(fixes.count(), 0);

        let index = one(&mut fixes, "Second", span(0, 1), b"z");

        assert_eq!(index, 0);
        assert_eq!(fixes.count(), 1);
    }

    #[test]
    fn an_arena_overflow_discards_the_open_fix() {
        let mut fixes = Fixes::reserve(4, 8, 4);

        fixes.open("First", Applicability::Safe, 0);

        assert!(fixes.edit(span(0, 1), b"ab"));
        assert!(!fixes.edit(span(2, 1), b"cde"));
        assert_eq!(fixes.close(), NONE);
        assert_eq!(fixes.count(), 0);

        let index = one(&mut fixes, "Second", span(0, 1), b"wxyz");

        assert_eq!(index, 0);

        let fix = *fixes.get(index).expect("the fix is recorded");
        let edits: Vec<Edit> = fixes.edits_of(&fix).to_vec();

        assert_eq!(fixes.replacement_of(&edits[0]), b"wxyz");
    }

    #[test]
    fn a_rendered_piece_of_each_kind_lands_alone() {
        let source = b"import os, sys";
        let scratch = b"os\nimport sys";
        let mut fixes = reserved();

        fixes.open("Source", Applicability::Safe, 0);

        assert!(fixes.render(span(0, 14), source, scratch, &[Piece::Source(span(7, 2))]));
        assert_eq!(fixes.close(), 0);

        fixes.open("Literal", Applicability::Safe, 0);

        assert!(fixes.render(span(0, 14), source, scratch, &[Piece::Literal(b"pass")]));
        assert_eq!(fixes.close(), 1);

        fixes.open("Formatted", Applicability::Safe, 0);

        assert!(fixes.render(
            span(0, 14),
            source,
            scratch,
            &[Piece::Formatted(span(0, 13))]
        ));

        assert_eq!(fixes.close(), 2);

        assert_eq!(rendered(&fixes, 0), b"os");
        assert_eq!(rendered(&fixes, 1), b"pass");
        assert_eq!(rendered(&fixes, 2), b"os\nimport sys");
    }

    #[test]
    fn a_rendered_fix_composes_the_three_piece_kinds_in_order() {
        let source = b"import os, sys";
        let scratch = b"    ";
        let mut fixes = reserved();

        fixes.open("Split", Applicability::Safe, 0);

        assert!(fixes.render(
            span(0, 14),
            source,
            scratch,
            &[
                Piece::Source(span(0, 9)),
                Piece::Literal(b"\n"),
                Piece::Formatted(span(0, 4)),
                Piece::Source(span(11, 3)),
            ]
        ));

        assert_eq!(fixes.close(), 0);
        assert_eq!(rendered(&fixes, 0), b"import os\n    sys");
    }

    #[test]
    fn a_rendered_fix_over_no_pieces_is_a_deletion() {
        let source = b"import os";
        let mut fixes = reserved();

        fixes.open("Delete", Applicability::Safe, 0);

        assert!(fixes.render(span(0, 9), source, &[], &[]));
        assert_eq!(fixes.close(), 0);
        assert_eq!(rendered(&fixes, 0), b"");

        let fix = *fixes.get(0).expect("the fix is recorded");
        let edits: Vec<Edit> = fixes.edits_of(&fix).to_vec();

        assert_eq!(edits[0].span, span(0, 9));
        assert_eq!(edits[0].replacement.length, 0);
    }

    #[test]
    fn a_rendered_fix_that_outgrows_the_arena_is_discarded_whole() {
        let source = b"import os, sys";
        let mut fixes = Fixes::reserve(4, 8, 8);

        fixes.open("First", Applicability::Safe, 0);

        assert!(!fixes.render(
            span(0, 14),
            source,
            &[],
            &[Piece::Source(span(0, 6)), Piece::Literal(b"abcdef")]
        ));

        assert_eq!(fixes.close(), NONE);
        assert_eq!(fixes.count(), 0);

        fixes.open("Second", Applicability::Safe, 0);

        assert!(fixes.render(span(0, 14), source, &[], &[Piece::Literal(b"pass")]));
        assert_eq!(fixes.close(), 0);
        assert_eq!(rendered(&fixes, 0), b"pass");
    }

    #[test]
    fn a_fix_that_edits_nothing_closes_to_nothing() {
        let mut fixes = reserved();

        fixes.open("Empty", Applicability::Safe, 0);

        assert_eq!(fixes.close(), NONE);
        assert_eq!(fixes.count(), 0);
        assert_eq!(fixes.close(), NONE);
    }

    #[test]
    fn a_cleared_table_forgets_every_fix() {
        let mut fixes = reserved();
        let _ = one(&mut fixes, "Rename", span(0, 1), b"x");

        fixes.clear();

        assert_eq!(fixes.count(), 0);
        assert_eq!(one(&mut fixes, "Rename", span(0, 1), b"y"), 0);
    }

    #[test]
    fn reaches_ranks_the_strength_ladder() {
        for applicability in LADDER {
            for minimum in LADDER {
                let expected = match applicability {
                    Applicability::DisplayOnly => false,
                    Applicability::Safe => true,
                    Applicability::Unsafe => minimum == Applicability::Unsafe,
                };

                assert_eq!(
                    applicability.reaches(minimum),
                    expected,
                    "{applicability:?} against {minimum:?}"
                );
            }
        }

        assert!(Applicability::DisplayOnly < Applicability::Unsafe);
        assert!(Applicability::Unsafe < Applicability::Safe);
    }

    #[test]
    fn a_plan_keeps_the_earlier_of_an_overlapping_pair() {
        let mut fixes = reserved();
        let _ = one(&mut fixes, "Second", span(1, 3), b"c");
        let _ = one(&mut fixes, "First", span(0, 3), b"b");

        assert_eq!(planned(&fixes, Applicability::Safe), vec![1]);
    }

    #[test]
    fn a_plan_never_selects_a_display_only_fix() {
        let mut fixes = reserved();

        fixes.open("Show", Applicability::DisplayOnly, 0);

        assert!(fixes.edit(span(0, 1), b"a"));

        let index = fixes.close();

        assert_eq!(index, 0);
        assert!(planned(&fixes, Applicability::Safe).is_empty());
        assert!(planned(&fixes, Applicability::Unsafe).is_empty());
    }

    #[test]
    fn a_plan_holds_an_unsafe_fix_back_until_the_minimum_reaches_it() {
        let mut fixes = reserved();

        fixes.open("Discard", Applicability::Unsafe, 0);

        assert!(fixes.edit(span(0, 0), b"_ = "));

        let index = fixes.close();

        assert_eq!(index, 0);
        assert!(planned(&fixes, Applicability::Safe).is_empty());
        assert_eq!(planned(&fixes, Applicability::Unsafe), vec![0]);
    }

    #[test]
    fn a_plan_selects_one_fix_from_an_isolation_group() {
        let mut fixes = reserved();

        fixes.open("First", Applicability::Safe, 7);

        assert!(fixes.edit(span(0, 3), b"1"));
        assert_eq!(fixes.close(), 0);

        fixes.open("Second", Applicability::Safe, 7);

        assert!(fixes.edit(span(4, 3), b"2"));
        assert_eq!(fixes.close(), 1);

        fixes.open("Third", Applicability::Safe, 0);

        assert!(fixes.edit(span(8, 3), b"3"));
        assert_eq!(fixes.close(), 2);

        assert_eq!(planned(&fixes, Applicability::Safe), vec![0, 2]);
    }

    #[test]
    fn a_second_plan_repeats_the_first() {
        let mut fixes = reserved();
        let _ = one(&mut fixes, "Second", span(6, 2), b"y");
        let _ = one(&mut fixes, "First", span(0, 2), b"x");
        let _ = one(&mut fixes, "Third", span(1, 2), b"z");
        let first = planned(&fixes, Applicability::Safe);
        let second = planned(&fixes, Applicability::Safe);

        assert_eq!(first, vec![1, 0]);
        assert_eq!(first, second);
    }

    #[test]
    fn an_apply_splices_every_edit_shape() {
        let source = b"let value = 1;";
        let mut fixes = reserved();
        let mut out = Buffer::reserve(64);

        fixes.open("Every", Applicability::Safe, 0);

        assert!(fixes.edit(span(0, 0), b"pub "));
        assert!(fixes.edit(span(4, 5), b"total"));
        assert!(fixes.edit(span(9, 1), b""));
        assert!(fixes.edit(span(13, 1), b";;"));

        let index = fixes.close();
        let fix = *fixes.get(index).expect("the fix is recorded");
        let edits: Vec<Edit> = fixes.edits_of(&fix).to_vec();

        assert!(apply(source, &fixes, &edits, &mut out));
        assert_eq!(out.as_bytes(), b"pub let total= 1;;");
    }

    #[test]
    fn an_apply_over_no_edits_copies_the_source() {
        let source = b"let value = 1;";
        let fixes = reserved();
        let mut out = Buffer::reserve(64);

        assert!(apply(source, &fixes, &[], &mut out));
        assert_eq!(out.as_bytes(), source);
    }

    #[test]
    fn an_apply_that_outgrows_the_target_clears_it() {
        let source = b"let value = 1;";
        let mut fixes = reserved();
        let mut out = Buffer::reserve(8);

        fixes.open("Rename", Applicability::Safe, 0);

        assert!(fixes.edit(span(4, 5), b"a_longer_name"));

        let index = fixes.close();
        let fix = *fixes.get(index).expect("the fix is recorded");
        let edits: Vec<Edit> = fixes.edits_of(&fix).to_vec();

        assert!(!apply(source, &fixes, &edits, &mut out));
        assert!(out.is_empty());
    }

    #[test]
    fn an_apply_runs_on_a_frozen_thread() {
        let source = b"let value = 1;";
        let mut fixes = reserved();
        let mut claimed = BoundedVec::reserve(32);
        let mut out = Buffer::reserve(64);
        let mut selected = BoundedVec::reserve(32);
        let _scope = crate::allocation::freeze_scope();

        fixes.open("Rename", Applicability::Safe, 0);

        assert!(fixes.edit(span(4, 5), b"total"));
        assert_eq!(fixes.close(), 0);

        plan(&fixes, Applicability::Safe, &mut claimed, &mut selected);

        assert_eq!(&*selected, &[0_u32][..]);

        let fix = *fixes.get(selected[0]).expect("the fix is recorded");
        let edits = fixes.edits_of(&fix);
        let held: [Edit; 1] = [edits[0]];

        assert!(apply(source, &fixes, &held, &mut out));
        assert_eq!(out.as_bytes(), b"let total = 1;");
    }

    const PASS_EDIT_COUNT_MAX: u32 = 32;
    const PASS_FIX_COUNT_MAX: u32 = 16;

    struct Harness {
        claimed: BoundedVec<Span>,
        fixes: Fixes,
        held: BoundedVec<Edit>,
        selected: BoundedVec<u32>,
        target: Buffer,
    }

    impl Harness {
        fn reserve(target_bytes_max: u32) -> Self {
            Self {
                claimed: BoundedVec::reserve(PASS_EDIT_COUNT_MAX),
                fixes: Fixes::reserve(PASS_FIX_COUNT_MAX, PASS_EDIT_COUNT_MAX, 1_024),
                held: BoundedVec::reserve(PASS_EDIT_COUNT_MAX),
                selected: BoundedVec::reserve(PASS_FIX_COUNT_MAX),
                target: Buffer::reserve(target_bytes_max),
            }
        }

        fn applied(&mut self, source: &[u8], minimum: Applicability) -> Pass {
            apply_pass(
                source,
                &self.fixes,
                minimum,
                &mut self.claimed,
                &mut self.selected,
                &mut self.held,
                &mut self.target,
            )
        }
    }

    fn pass_span(offset: u32, length: u32) -> Span {
        Span::new(offset, length)
    }

    #[test]
    fn a_pass_that_outgrows_the_target_applies_nothing() {
        const SOURCE: &[u8] = b"let value = 1;";

        let mut harness = Harness::reserve(8);

        crate::allocation::frozen(|| {
            harness.fixes.open("Rename", Applicability::Safe, NONE);

            assert!(
                harness
                    .fixes
                    .edit(pass_span(4, 5), b"a_very_long_replacement")
            );

            assert_ne!(harness.fixes.close(), NONE);

            assert_eq!(
                harness.applied(SOURCE, Applicability::Safe),
                Pass::Overflowed
            );
        });
    }

    #[test]
    fn one_edit_splices_into_the_target() {
        const SOURCE: &[u8] = b"let value = 1;";

        let mut harness = Harness::reserve(1_024);

        crate::allocation::frozen(|| {
            harness.fixes.open("Rename", Applicability::Safe, NONE);

            assert!(harness.fixes.edit(pass_span(4, 5), b"total"));
            assert_ne!(harness.fixes.close(), NONE);

            assert_eq!(
                harness.applied(SOURCE, Applicability::Safe),
                Pass::Applied(1)
            );

            assert_eq!(harness.target.as_bytes(), b"let total = 1;");
        });
    }

    #[test]
    fn an_unsafe_fix_is_held_back() {
        const SOURCE: &[u8] = b"work();";

        let mut harness = Harness::reserve(1_024);

        crate::allocation::frozen(|| {
            harness.fixes.open("Discard", Applicability::Unsafe, NONE);

            assert!(harness.fixes.edit(pass_span(0, 0), b"_ = "));
            assert_ne!(harness.fixes.close(), NONE);

            assert_eq!(
                harness.applied(SOURCE, Applicability::Safe),
                Pass::Applied(0)
            );

            assert_eq!(harness.target.as_bytes(), SOURCE);

            assert_eq!(
                harness.applied(SOURCE, Applicability::Unsafe),
                Pass::Applied(1)
            );

            assert_eq!(harness.target.as_bytes(), b"_ = work();");
        });
    }

    #[test]
    fn an_overlapping_fix_waits_for_the_next_pass() {
        const SOURCE: &[u8] = b"aaaa";

        let mut harness = Harness::reserve(1_024);

        crate::allocation::frozen(|| {
            harness.fixes.open("First", Applicability::Safe, NONE);

            assert!(harness.fixes.edit(pass_span(0, 3), b"b"));
            assert_ne!(harness.fixes.close(), NONE);

            harness.fixes.open("Second", Applicability::Safe, NONE);

            assert!(harness.fixes.edit(pass_span(1, 3), b"c"));
            assert_ne!(harness.fixes.close(), NONE);

            assert_eq!(
                harness.applied(SOURCE, Applicability::Safe),
                Pass::Applied(1)
            );

            assert_eq!(harness.target.as_bytes(), b"ba");
        });
    }

    #[test]
    fn one_fix_per_isolation_group_lands_in_a_pass() {
        const SOURCE: &[u8] = b"one two";

        let mut harness = Harness::reserve(1_024);

        crate::allocation::frozen(|| {
            harness.fixes.open("First", Applicability::Safe, 7);

            assert!(harness.fixes.edit(pass_span(0, 3), b"1"));
            assert_ne!(harness.fixes.close(), NONE);

            harness.fixes.open("Second", Applicability::Safe, 7);

            assert!(harness.fixes.edit(pass_span(4, 3), b"2"));
            assert_ne!(harness.fixes.close(), NONE);

            assert_eq!(
                harness.applied(SOURCE, Applicability::Safe),
                Pass::Applied(1)
            );

            assert_eq!(harness.target.as_bytes(), b"1 two");
        });
    }
}
