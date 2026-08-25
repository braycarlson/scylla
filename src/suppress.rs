use crate::bounded::{BoundedVec, Span, count_of};
use crate::lines;
use crate::token::{Token, TokenKind};

pub const NONE: u32 = u32::MAX;
pub const FILE_LINE: u32 = u32::MAX - 1;
const FILE_PREFIXES: [&[u8]; 2] = [b"flake8:", b"ruff:"];
const OFFSET_NONE: u32 = u32::MAX;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Pragma {
    FormatOff,
    FormatOn,
    FormatSkip,
    IsortOff,
    IsortOn,
    IsortSkip,
    IsortSplit,
    TypeIgnore,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct PragmaAt {
    pub kind: Pragma,
    pub line: u32,
    pub span: Span,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Joined {
    pub line_first: u32,
    pub line_last: u32,
}

#[derive(Debug)]
pub struct Pragmas {
    items: BoundedVec<PragmaAt>,
}

static PRAGMA_WORDS: [(&[u8], Pragma); 8] = [
    (b"fmt:off", Pragma::FormatOff),
    (b"fmt:on", Pragma::FormatOn),
    (b"fmt:skip", Pragma::FormatSkip),
    (b"isort:off", Pragma::IsortOff),
    (b"isort:on", Pragma::IsortOn),
    (b"isort:skip", Pragma::IsortSkip),
    (b"isort:split", Pragma::IsortSplit),
    (b"type:ignore", Pragma::TypeIgnore),
];

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Directive {
    pub blanket: bool,
    pub code_count: u32,
    pub code_start: u32,
    pub line: u32,
    pub span: Span,
}

#[derive(Debug)]
pub struct Suppressions {
    codes: BoundedVec<Span>,
    consumed: BoundedVec<bool>,
    file: BoundedVec<u32>,
    items: BoundedVec<Directive>,
    joined: BoundedVec<Joined>,
    placed: BoundedVec<u32>,
}

#[derive(Clone, Copy, Debug)]
struct Reading {
    blanket: bool,
    end: u32,
    invalid: bool,
    overflowed: bool,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum Run {
    Code(Span),
    Malformed,
    Prose,
}

impl Suppressions {
    pub fn reserve(directive_count_max: u32, code_count_max: u32) -> Self {
        assert!(directive_count_max > 0);
        assert!(code_count_max > 0);

        assert!(!crate::allocation::is_frozen());

        Self {
            codes: BoundedVec::reserve(code_count_max),
            consumed: BoundedVec::reserve(directive_count_max),
            file: BoundedVec::reserve(directive_count_max),
            items: BoundedVec::reserve(directive_count_max),
            joined: BoundedVec::reserve(directive_count_max),
            placed: BoundedVec::reserve(directive_count_max),
        }
    }

    pub fn clear(&mut self) {
        self.codes.clear();
        self.consumed.clear();
        self.file.clear();
        self.items.clear();
        self.joined.clear();
        self.placed.clear();

        assert_eq!(self.count(), 0);
    }

    #[must_use]
    pub fn join(&mut self, source: &[u8], tokens: &[Token], index: &lines::Index) -> bool {
        self.joined.clear();

        for (position, token) in tokens.iter().enumerate() {
            if token.kind == TokenKind::String {
                let merged = self.merge_joined(
                    index.line_of(token.offset),
                    index.line_of(token.end().saturating_sub(1)),
                );

                if !merged {
                    return false;
                }
            }

            let Some(next) = tokens.get(position + 1) else {
                continue;
            };

            if !self.push_continuations(source, index, token.end(), next.offset) {
                return false;
            }
        }

        true
    }

    pub fn joined(&self) -> &[Joined] {
        &self.joined
    }

    fn joined_of(&self, line: u32) -> u32 {
        let mut low = 0;
        let mut high = self.joined.count();

        while low < high {
            let middle = low + (high - low) / 2;

            if self.joined[middle as usize].line_first <= line {
                low = middle + 1;
            } else {
                high = middle;
            }
        }

        if low == 0 {
            return line;
        }

        let held = self.joined[low as usize - 1];

        if line <= held.line_last {
            return held.line_last;
        }

        line
    }

    fn merge_joined(&mut self, line_first: u32, line_last: u32) -> bool {
        if line_last <= line_first {
            return true;
        }

        let count = self.joined.count();

        if count > 0 {
            let held = self.joined[count as usize - 1];

            if line_first <= held.line_last {
                self.joined[count as usize - 1] = Joined {
                    line_first: held.line_first,
                    line_last: held.line_last.max(line_last),
                };

                return true;
            }
        }

        self.joined.push(Joined {
            line_first,
            line_last,
        })
    }

    fn push_continuations(
        &mut self,
        source: &[u8],
        index: &lines::Index,
        from: u32,
        to: u32,
    ) -> bool {
        let end = (to as usize).min(source.len());
        let mut offset = from as usize;

        for _ in from as usize..end {
            if offset + 1 >= end {
                break;
            }

            if source[offset] != b'\\' {
                offset += 1;

                continue;
            }

            let width = continuation_width(source, offset);

            if width == 0 {
                offset += 1;

                continue;
            }

            let line = index.line_of(count_of(offset));

            if line + 1 < index.count() && !self.merge_joined(line, line + 1) {
                return false;
            }

            offset += width;
        }

        true
    }

    pub fn code_of(&self, index: u32) -> Span {
        assert!(index < self.codes.count());

        self.codes[index as usize]
    }

    pub fn consume(&mut self, directive: u32) {
        assert!(directive < self.count());

        self.consumed[directive as usize] = true;
    }

    pub fn count(&self) -> u32 {
        let count = self.items.count();

        assert_eq!(count, self.consumed.count());

        count
    }

    pub fn get(&self, index: u32) -> Option<&Directive> {
        if index == NONE {
            return None;
        }

        self.items.get(index as usize)
    }

    pub fn matches(&self, line: u32, code: &[u8], source: &[u8]) -> u32 {
        assert!(!code.is_empty());

        for index in self.file.iter() {
            if self.covers(*index, code, source) {
                return *index;
            }
        }

        let target = self.joined_of(line);
        let from = self.placed_from(target);

        for index in from..self.count() {
            if self.placed[index as usize] != target {
                break;
            }

            if self.items[index as usize].line != target {
                continue;
            }

            if self.covers(index, code, source) {
                return index;
            }
        }

        NONE
    }

    fn covers(&self, index: u32, code: &[u8], source: &[u8]) -> bool {
        let directive = self.items[index as usize];

        directive.blanket || self.names(&directive, code, source)
    }

    fn placed_from(&self, line: u32) -> u32 {
        let mut low = 0;
        let mut high = self.placed.count();

        while low < high {
            let middle = low + (high - low) / 2;

            if self.placed[middle as usize] < line {
                low = middle + 1;
            } else {
                high = middle;
            }
        }

        low
    }

    pub fn scan(
        &mut self,
        source: &[u8],
        comments: impl Iterator<Item = Span>,
        word: &[u8],
        index: &lines::Index,
    ) {
        assert!(!word.is_empty());

        self.clear();

        for comment in comments {
            assert!(comment.end() as usize <= source.len());

            let start = word_in(source, comment, word);

            if start == OFFSET_NONE {
                continue;
            }

            if self.items.is_full() {
                return;
            }

            let reading = self.read_codes(source, comment, start + count_of(word.len()));

            if reading.invalid {
                continue;
            }

            let file_wide = file_prefixed(source, comment, start);
            let recorded = self.record(source, comment, start, reading, index, file_wide);

            assert!(recorded);

            if reading.overflowed {
                return;
            }
        }
    }

    pub fn unconsumed(&self) -> impl Iterator<Item = u32> {
        (0..self.count()).filter(|index| !self.consumed[*index as usize])
    }

    fn names(&self, directive: &Directive, code: &[u8], source: &[u8]) -> bool {
        let start = directive.code_start as usize;
        let end = start + directive.code_count as usize;

        assert!(end <= self.codes.len());

        self.codes[start..end]
            .iter()
            .any(|span| &source[span.range()] == code)
    }

    fn read_codes(&mut self, source: &[u8], comment: Span, after: u32) -> Reading {
        let end = comment.end();
        let colon = after < end && source[after as usize] == b':';
        let opened = code_start_of(source, comment, after);

        if opened == OFFSET_NONE {
            return Reading {
                blanket: true,
                end: after,
                invalid: false,
                overflowed: false,
            };
        }

        let count = self.codes.count();
        let mut offset = opened;
        let mut written = opened;

        for _ in 0..comment.length {
            if offset >= end {
                break;
            }

            let byte = source[offset as usize];

            if byte == b',' || byte.is_ascii_whitespace() {
                offset += 1;

                continue;
            }

            let code = match code_at(source, offset, end) {
                Run::Code(span) => span,
                Run::Prose => break,
                Run::Malformed => {
                    self.codes.truncate(count);

                    return Reading {
                        blanket: !colon,
                        end: after,
                        invalid: colon,
                        overflowed: false,
                    };
                }
            };

            if !self.codes.push(code) {
                return Reading {
                    blanket: false,
                    end: written,
                    invalid: false,
                    overflowed: true,
                };
            }

            offset = code.end();
            written = code.end();
        }

        Reading {
            blanket: written == opened,
            end: written,
            invalid: colon && written == opened,
            overflowed: false,
        }
    }

    fn record(
        &mut self,
        source: &[u8],
        comment: Span,
        start: u32,
        reading: Reading,
        index: &lines::Index,
        file_wide: bool,
    ) -> bool {
        assert!(comment.offset <= start);
        assert!(reading.end >= start);

        let code_start = self.code_start();
        let placed = index.line_of(start);

        let directive = Directive {
            blanket: reading.blanket,
            code_count: self.codes.count() - code_start,
            code_start,
            line: if file_wide {
                FILE_LINE
            } else {
                index.line_of(start)
            },
            span: Span {
                length: reading.end - start,
                offset: start,
            },
        };

        assert!(directive.span.end() as usize <= source.len());

        debug_assert!(
            self.placed
                .last()
                .is_none_or(|previous| *previous <= placed)
        );

        if !self.items.push(directive) {
            return false;
        }

        self.consumed.push_assert(false);
        self.placed.push_assert(placed);

        if file_wide {
            self.file.push_assert(self.items.count() - 1);
        }

        true
    }

    fn code_start(&self) -> u32 {
        let count = self.items.count();

        if count == 0 {
            return 0;
        }

        let held = self.items[count as usize - 1];

        held.code_start + held.code_count
    }
}

impl Pragmas {
    pub fn reserve(pragma_count_max: u32) -> Self {
        assert!(pragma_count_max > 0);

        assert!(!crate::allocation::is_frozen());

        Self {
            items: BoundedVec::reserve(pragma_count_max),
        }
    }

    pub fn as_slice(&self) -> &[PragmaAt] {
        &self.items
    }

    pub fn clear(&mut self) {
        self.items.clear();

        assert_eq!(self.count(), 0);
    }

    pub fn count(&self) -> u32 {
        self.items.count()
    }

    pub fn scan(
        &mut self,
        source: &[u8],
        comments: impl Iterator<Item = Span>,
        index: &lines::Index,
    ) {
        self.clear();

        for comment in comments {
            assert!(comment.end() as usize <= source.len());

            let Some(kind) = pragma_of(source, comment) else {
                continue;
            };

            let pushed = self.items.push(PragmaAt {
                kind,
                line: index.line_of(comment.offset),
                span: comment,
            });

            if !pushed {
                return;
            }
        }
    }
}

fn pragma_of(source: &[u8], comment: Span) -> Option<Pragma> {
    let start = text_start_of(source, comment);
    let text = source[start as usize..comment.end() as usize].trim_ascii_end();

    for (word, kind) in PRAGMA_WORDS {
        if !word_matches(text, word) {
            continue;
        }

        return Some(kind);
    }

    None
}

fn word_matches(text: &[u8], word: &[u8]) -> bool {
    let mut read = 0;

    for byte in word {
        if *byte == b':' {
            if text.get(read) != Some(&b':') {
                return false;
            }

            read += 1;

            if text.get(read) == Some(&b' ') {
                read += 1;
            }

            continue;
        }

        if text.get(read) != Some(byte) {
            return false;
        }

        read += 1;
    }

    if word == b"type:ignore" {
        return true;
    }

    read == text.len()
}

fn text_start_of(source: &[u8], comment: Span) -> u32 {
    let mut start = comment.offset;

    while start < comment.end() && matches!(source[start as usize], b'#' | b'\t' | b' ') {
        start += 1;
    }

    start
}

fn file_prefixed(source: &[u8], comment: Span, start: u32) -> bool {
    let text = text_start_of(source, comment);

    for prefix in FILE_PREFIXES {
        let width = count_of(prefix.len());

        if start < text + width {
            continue;
        }

        if &source[text as usize..(text + width) as usize] != prefix {
            continue;
        }

        let between = &source[(text + width) as usize..start as usize];

        if between.iter().all(|byte| matches!(*byte, b'\t' | b' ')) {
            return true;
        }
    }

    false
}

fn code_start_of(source: &[u8], comment: Span, after: u32) -> u32 {
    let end = comment.end();

    if after < end && source[after as usize] == b':' {
        return after + 1;
    }

    let mut offset = after;

    while offset < end && matches!(source[offset as usize], b'\t' | b' ') {
        offset += 1;
    }

    if offset == after || offset >= end {
        return OFFSET_NONE;
    }

    if code_at(source, offset, end) == Run::Prose {
        return OFFSET_NONE;
    }

    offset
}

fn code_at(source: &[u8], offset: u32, end: u32) -> Run {
    assert!(offset < end);

    let mut cursor = offset;

    while cursor < end && source[cursor as usize].is_ascii_uppercase() {
        cursor += 1;
    }

    let letters = cursor - offset;

    while cursor < end && source[cursor as usize].is_ascii_digit() {
        cursor += 1;
    }

    let digits = cursor - offset - letters;

    if letters == 0 || digits == 0 {
        return Run::Prose;
    }

    if cursor < end {
        let byte = source[cursor as usize];

        if byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_') {
            return Run::Malformed;
        }
    }

    Run::Code(Span {
        length: cursor - offset,
        offset,
    })
}

fn continuation_width(source: &[u8], offset: usize) -> usize {
    if source.get(offset + 1) == Some(&b'\n') {
        return 1;
    }

    if source.get(offset + 1) != Some(&b'\r') {
        return 0;
    }

    if source.get(offset + 2) == Some(&b'\n') {
        return 2;
    }

    1
}

fn word_in(source: &[u8], comment: Span, word: &[u8]) -> u32 {
    let width = count_of(word.len());

    if comment.length < width {
        return OFFSET_NONE;
    }

    for start in comment.offset..=comment.end() - width {
        let held = &source[start as usize..(start + width) as usize];

        if !held.eq_ignore_ascii_case(word) {
            continue;
        }

        if !opens_at(source, comment, start) && !file_prefixed(source, comment, start) {
            continue;
        }

        if !closes_at(source, comment, start + width) {
            continue;
        }

        return start;
    }

    OFFSET_NONE
}

fn closes_at(source: &[u8], comment: Span, end: u32) -> bool {
    if end >= comment.end() {
        return true;
    }

    let byte = source[end as usize];

    byte == b':' || byte.is_ascii_whitespace()
}

fn opens_at(source: &[u8], comment: Span, start: u32) -> bool {
    let mut cursor = start;

    while cursor > comment.offset && matches!(source[cursor as usize - 1], b'\t' | b' ') {
        cursor -= 1;
    }

    if cursor == comment.offset {
        return true;
    }

    matches!(source[cursor as usize - 1], b'#' | b'*' | b'/')
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Markers {
    pub annotation: &'static [u8],
    pub disable: &'static [u8],
    pub enable: &'static [u8],
    pub file: &'static [u8],
    pub line: &'static [u8],
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Region {
    Disable,
    Enable,
    File,
    Line,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Reason {
    Closes,
    Dead,
    Unknown,
}

#[derive(Clone, Copy, Debug)]
pub struct Unused {
    pub kept: u64,
    pub payload: Span,
    pub reason: Reason,
    pub span: Span,
    pub trailing: bool,
}

#[derive(Debug)]
pub struct Regions {
    dropped: u32,
    entries: BoundedVec<Suppression>,
    file: u64,
}

#[derive(Clone, Copy, Debug)]
struct Parsed {
    codes: u64,
    kind: Region,
    payload: Span,
    unknown: bool,
    wildcard: bool,
}

#[derive(Clone, Copy, Debug)]
struct Suppression {
    codes: u64,
    kind: Region,
    line: u32,
    payload: Span,
    span: Span,
    trailing: bool,
    unknown: bool,
    used: u64,
    wildcard: bool,
}

const ANNOTATION_COUNT_MAX: u32 = 32;

fn annotation_skipped(source: &[u8], index: &lines::Index, prefix: &[u8], from: u32) -> u32 {
    if prefix.is_empty() {
        return from;
    }

    let mut line = from;

    for _ in 0..ANNOTATION_COUNT_MAX {
        if line >= index.count() {
            return from;
        }

        let text = &source[index.line_span(line, source).range()];

        if !text.trim_ascii_start().starts_with(prefix) {
            return line;
        }

        let mut depth = 0_i32;
        let mut walked = line;

        for _ in 0..ANNOTATION_COUNT_MAX {
            if walked >= index.count() {
                return from;
            }

            let body = &source[index.line_span(walked, source).range()];

            for byte in body {
                match byte {
                    b'[' | b'(' => depth += 1,
                    b']' | b')' => depth -= 1,
                    _ => {}
                }
            }

            walked += 1;

            if depth <= 0 {
                break;
            }
        }

        if walked <= line {
            return from;
        }

        line = walked;
    }

    from
}

impl Regions {
    pub fn reserve(directive_count_max: u32) -> Self {
        assert!(directive_count_max > 0);
        assert!(!crate::allocation::is_frozen());

        Self {
            dropped: 0,
            entries: BoundedVec::reserve(directive_count_max),
            file: 0,
        }
    }

    pub fn scan(
        &mut self,
        source: &[u8],
        tokens: &[Token],
        index: &lines::Index,
        markers: &Markers,
        code_of: &impl Fn(&[u8]) -> Option<u32>,
    ) {
        self.dropped = 0;
        self.entries.clear();
        self.file = 0;

        let mut line_previous = u32::MAX;

        for token in tokens {
            let line = index.line_of(token.offset);

            if token.kind != TokenKind::Comment {
                line_previous = line;

                continue;
            }

            let text = token.text(source);
            let own_line = line_previous != line;

            let Some(parsed) = directive_of(text, markers, code_of) else {
                continue;
            };

            if parsed.kind == Region::File {
                self.file |= parsed.codes;
            }

            let target = if parsed.kind == Region::Line && own_line {
                annotation_skipped(source, index, markers.annotation, line + 1)
            } else {
                line
            };

            let pushed = self.entries.push(Suppression {
                codes: parsed.codes,
                kind: parsed.kind,
                line: target,
                payload: Span::new(token.offset + parsed.payload.offset, parsed.payload.length),
                span: token.span(),
                trailing: !own_line,
                unknown: parsed.unknown,
                used: if parsed.kind == Region::File {
                    parsed.codes
                } else {
                    0
                },
                wildcard: parsed.wildcard,
            });

            if !pushed {
                self.dropped += 1;
            }
        }
    }

    pub fn dropped(&self) -> u32 {
        self.dropped
    }

    pub fn capacity(&self) -> u32 {
        self.entries.capacity()
    }

    pub fn count(&self) -> u32 {
        self.entries.count()
    }

    pub fn unused_at(&self, index: u32, enabled: u64) -> Option<Unused> {
        let entry = self.entries.get(index as usize)?;

        let whole = Unused {
            kept: 0,
            payload: entry.payload,
            reason: Reason::Dead,
            span: entry.span,
            trailing: entry.trailing,
        };

        if entry.unknown {
            return Some(Unused {
                reason: Reason::Unknown,
                ..whole
            });
        }

        if entry.kind == Region::Enable {
            if self.opened(index) {
                return None;
            }

            return Some(Unused {
                reason: Reason::Closes,
                ..whole
            });
        }

        if entry.wildcard {
            if entry.used != 0 {
                return None;
            }

            return Some(whole);
        }

        let dead = entry.codes & enabled & !entry.used;

        if dead == 0 {
            return None;
        }

        Some(Unused {
            kept: entry.codes & !dead,
            ..whole
        })
    }

    pub fn claim(&mut self, line: u32, code: u32) -> bool {
        assert!(code < crate::rule::CODE_COUNT_MAX);

        let mask = 1_u64 << code;

        if self.file & mask != 0 {
            self.mark(Region::File, mask);

            return true;
        }

        for index in 0..self.entries.count() as usize {
            let entry = self.entries[index];

            if entry.codes & mask == 0 {
                continue;
            }

            if entry.kind == Region::Line && entry.line == line {
                self.entries[index].used |= mask;

                return true;
            }

            if entry.kind != Region::Disable || entry.line > line {
                continue;
            }

            if self.reopened(index, line, mask) {
                continue;
            }

            self.entries[index].used |= mask;

            return true;
        }

        false
    }

    fn opened(&self, index: u32) -> bool {
        for earlier in 0..index as usize {
            let entry = self.entries[earlier];

            if entry.kind != Region::Disable {
                continue;
            }

            if entry.codes & self.entries[index as usize].codes != 0 {
                return true;
            }
        }

        false
    }

    fn mark(&mut self, kind: Region, mask: u64) {
        for index in 0..self.entries.count() as usize {
            if self.entries[index].kind == kind && self.entries[index].codes & mask != 0 {
                self.entries[index].used |= mask;
            }
        }
    }

    fn reopened(&self, start: usize, line: u32, mask: u64) -> bool {
        let opened = self.entries[start].line;

        for index in start + 1..self.entries.count() as usize {
            let entry = self.entries[index];

            if entry.kind != Region::Enable {
                continue;
            }

            if entry.line <= opened || entry.line > line {
                continue;
            }

            if entry.codes & mask != 0 {
                return true;
            }
        }

        false
    }
}

pub fn directive_removed(source: &[u8], index: &lines::Index, found: &Unused) -> Span {
    let at = index.line_of(found.span.offset);
    let line = index.line_span(at, source);

    if !found.trailing {
        return index.line_span_terminated(at, source);
    }

    let before = &source[line.offset as usize..found.span.offset as usize];
    let start = line.offset + count_of(before.trim_ascii_end().len());

    Span::between(start, line.end())
}

pub fn codes_written(codes: u64, prefix: &[u8], width: usize, target: &mut [u8]) -> Option<usize> {
    assert!(width >= 1);

    let mut length = 0;

    for code in 0..crate::rule::CODE_COUNT_MAX {
        if codes & (1_u64 << code) == 0 {
            continue;
        }

        if length > 0 {
            *target.get_mut(length)? = b',';
            *target.get_mut(length + 1)? = b' ';
            length += 2;
        }

        for byte in prefix {
            *target.get_mut(length)? = *byte;
            length += 1;
        }

        let mut scale = 10_u32.checked_pow(u32::try_from(width).ok()? - 1)?;

        while scale > 0 {
            *target.get_mut(length)? = b'0' + u8::try_from(code / scale % 10).ok()?;
            length += 1;
            scale /= 10;
        }
    }

    if length == 0 {
        return None;
    }

    Some(length)
}

fn code_end(text: &[u8], start: usize) -> usize {
    let mut offset = start;

    while offset < text.len() && text[offset].is_ascii_alphanumeric() {
        offset += 1;
    }

    offset
}

fn directive_of(
    text: &[u8],
    markers: &Markers,
    code_of: &impl Fn(&[u8]) -> Option<u32>,
) -> Option<Parsed> {
    let body = reason_strip(text);

    for (marker, kind) in [
        (markers.file, Region::File),
        (markers.disable, Region::Disable),
        (markers.enable, Region::Enable),
        (markers.line, Region::Line),
    ] {
        let Some(start) = crate::scan::find(body, marker) else {
            continue;
        };

        let mut open = start + marker.len();

        while open < body.len() && body[open] == b' ' {
            open += 1;
        }

        let listed = &body[open..];
        let (codes, unknown, wildcard) = codes_of(listed, code_of);

        return Some(Parsed {
            codes,
            kind,
            payload: Span::new(count_of(open), count_of(listed.trim_ascii_end().len())),
            unknown,
            wildcard,
        });
    }

    None
}

fn codes_of(text: &[u8], code_of: &impl Fn(&[u8]) -> Option<u32>) -> (u64, bool, bool) {
    let mut codes = 0_u64;
    let mut found = false;
    let mut offset = 0;
    let mut unknown = false;

    while offset < text.len() {
        if !text[offset].is_ascii_alphanumeric() {
            if text[offset] == b'*' {
                return (u64::MAX, false, true);
            }

            offset += 1;

            continue;
        }

        let end = code_end(text, offset);

        match code_of(&text[offset..end]) {
            Some(index) if index < crate::rule::CODE_COUNT_MAX => {
                codes |= 1_u64 << index;
                found = true;
            }
            _ => unknown = true,
        }

        offset = end;
    }

    if !found && !unknown {
        return (u64::MAX, false, true);
    }

    (codes, unknown, false)
}

fn reason_strip(text: &[u8]) -> &[u8] {
    match crate::scan::find(text, b" -- ") {
        Some(offset) => &text[..offset],
        None => text,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::language::Lexer as _;
    use crate::lex::{GO, PYTHON, RUST};
    use crate::markup::{self, MarkupKind, Tokens as MarkupTokens};
    use crate::token::{TokenKind, Tokens};

    const WORD: &[u8] = b"noqa";

    fn indexed(source: &[u8]) -> lines::Index {
        let mut index = lines::Index::reserve(64);

        assert!(index.build(source));

        index
    }

    fn comment_of(source: &[u8]) -> Span {
        Span {
            length: count_of(source.len()),
            offset: 0,
        }
    }

    fn scanned(source: &[u8], spans: &[Span]) -> Suppressions {
        let index = indexed(source);
        let mut suppressions = Suppressions::reserve(8, 16);

        suppressions.scan(source, spans.iter().copied(), WORD, &index);

        suppressions
    }

    fn one(source: &[u8]) -> Suppressions {
        scanned(source, &[comment_of(source)])
    }

    fn codes_of(suppressions: &Suppressions, index: u32, source: &[u8]) -> Vec<Vec<u8>> {
        let directive = *suppressions.get(index).expect("the directive is recorded");

        (0..directive.code_count)
            .map(|position| {
                let span = suppressions.code_of(directive.code_start + position);

                source[span.range()].to_vec()
            })
            .collect()
    }

    fn comments_of(source: &[u8], lexer: &dyn crate::language::Lexer) -> Vec<Span> {
        let mut tokens = Tokens::reserve(1_024);

        lexer.lex(source, &mut tokens);

        tokens
            .as_slice()
            .iter()
            .filter(|token| token.kind == TokenKind::Comment)
            .map(Token::span)
            .collect()
    }

    #[test]
    fn a_word_inside_a_longer_identifier_is_not_a_directive() {
        for source in [
            &b"# noqable"[..],
            &b"# a_noqa_thing"[..],
            &b"# (noqa)"[..],
            &b"# (noqa "[..],
            &b"# noqa1"[..],
            &b"# remove noqa comments later"[..],
        ] {
            let suppressions = one(source);

            assert_eq!(
                suppressions.count(),
                0,
                "{}",
                String::from_utf8_lossy(source)
            );

            assert_eq!(suppressions.matches(0, b"E501", source), NONE);
        }
    }

    #[test]
    fn a_word_at_every_boundary_form_is_a_directive() {
        for source in [
            &b"noqa"[..],
            &b"# noqa"[..],
            &b"# noqa "[..],
            &b"# noqa   "[..],
            &b"#noqa"[..],
            &b"#\tnoqa"[..],
            &b"# fixed # noqa"[..],
            &b"# noqa:E501"[..],
            &b"# NOQA"[..],
            &b"# NoQA: F401"[..],
        ] {
            let suppressions = one(source);

            assert_eq!(
                suppressions.count(),
                1,
                "{}",
                String::from_utf8_lossy(source)
            );
        }
    }

    #[test]
    fn a_directive_in_another_case_names_its_codes() {
        let source = b"# NoQA: F401";
        let suppressions = one(source);

        assert_eq!(codes_of(&suppressions, 0, source), vec![b"F401".to_vec()]);
        assert_eq!(suppressions.matches(0, b"F401", source), 0);
        assert_eq!(suppressions.matches(0, b"E501", source), NONE);
    }

    #[test]
    fn a_code_list_closes_on_the_first_run_that_is_not_a_code() {
        for source in [
            &b"# noqa: E501 or F401"[..],
            &b"# noqa:E501 or F401"[..],
            &b"# noqa: E501, or F401"[..],
            &b"# noqa: E501 trailing"[..],
        ] {
            let suppressions = one(source);

            assert_eq!(
                codes_of(&suppressions, 0, source),
                vec![b"E501".to_vec()],
                "{}",
                String::from_utf8_lossy(source)
            );

            assert_eq!(suppressions.matches(0, b"F401", source), NONE);
        }
    }

    #[test]
    fn a_malformed_code_after_the_colon_drops_the_directive() {
        for source in [
            &b"# noqa:"[..],
            &b"# noqa: because"[..],
            &b"# noqa: f401"[..],
            &b"# noqa: F401x"[..],
            &b"# noqa: F401-E501"[..],
            &b"# noqa: E501, F401x"[..],
        ] {
            let suppressions = one(source);

            assert_eq!(
                suppressions.count(),
                0,
                "{}",
                String::from_utf8_lossy(source)
            );

            assert_eq!(suppressions.codes.count(), 0);
            assert_eq!(suppressions.matches(0, b"F401", source), NONE);
        }
    }

    #[test]
    fn a_malformed_code_without_the_colon_leaves_a_blanket() {
        let source = b"# noqa F401x";
        let suppressions = one(source);
        let directive = *suppressions.get(0).expect("the directive is recorded");

        assert!(directive.blanket);
        assert_eq!(directive.code_count, 0);
        assert_eq!(suppressions.matches(0, b"F401", source), 0);
    }

    #[test]
    fn a_doubled_separator_still_reads_the_code_after_it() {
        let source = b"# noqa: F401,,E501";
        let suppressions = one(source);

        assert_eq!(
            codes_of(&suppressions, 0, source),
            vec![b"F401".to_vec(), b"E501".to_vec()]
        );
    }

    #[test]
    fn a_directive_without_a_code_list_is_a_blanket() {
        let source = b"# noqa";
        let suppressions = one(source);
        let directive = *suppressions.get(0).expect("the directive is recorded");

        assert!(directive.blanket);
        assert_eq!(directive.code_count, 0);
        assert_eq!(directive.line, 0);
        assert_eq!(suppressions.matches(0, b"E501", source), 0);
        assert_eq!(suppressions.matches(1, b"E501", source), NONE);
    }

    #[test]
    fn a_one_code_list_names_one_code() {
        let source = b"# noqa:E501";
        let suppressions = one(source);
        let directive = *suppressions.get(0).expect("the directive is recorded");

        assert!(!directive.blanket);
        assert_eq!(directive.code_count, 1);
        assert_eq!(codes_of(&suppressions, 0, source), vec![b"E501".to_vec()]);
        assert_eq!(suppressions.matches(0, b"E501", source), 0);
        assert_eq!(suppressions.matches(0, b"F401", source), NONE);
    }

    #[test]
    fn a_three_code_list_names_three_codes() {
        let source = b"# noqa: E501, F401 W605";
        let suppressions = one(source);

        assert_eq!(
            codes_of(&suppressions, 0, source),
            vec![b"E501".to_vec(), b"F401".to_vec(), b"W605".to_vec()]
        );

        assert_eq!(suppressions.matches(0, b"W605", source), 0);
    }

    #[test]
    fn a_trailing_separator_closes_the_list() {
        let source = b"# noqa: E501, F401,  ";
        let suppressions = one(source);
        let directive = *suppressions.get(0).expect("the directive is recorded");

        assert_eq!(directive.code_count, 2);
        assert_eq!(directive.span.end(), 18);
    }

    #[test]
    fn a_lookup_finds_the_row_on_its_line_among_many() {
        let source =
            b"a = 1  # noqa: E501\nb = 2\n# ruff: noqa: F401\nc = 3  # noqa\nd = 4  # noqa: W605\n";

        let held = python(source);

        assert_eq!(held.count(), 4);
        assert_eq!(held.matches(0, b"E501", source), 0);
        assert_eq!(held.matches(0, b"W605", source), NONE);
        assert_eq!(held.matches(1, b"E501", source), NONE);
        assert_eq!(held.matches(1, b"F401", source), 1);
        assert_eq!(held.matches(2, b"F401", source), 1);
        assert_eq!(held.matches(2, b"E501", source), NONE);
        assert_eq!(held.matches(3, b"E501", source), 2);
        assert_eq!(held.matches(4, b"W605", source), 3);
        assert_eq!(held.matches(4, b"E501", source), NONE);
        assert_eq!(held.matches(5, b"E501", source), NONE);
    }

    #[test]
    fn a_full_run_table_reports_the_overflow() {
        let source = b"a = \"\"\"one\ntwo\"\"\"\nb = \"\"\"one\ntwo\"\"\"\n";
        let (lexed, index) = commented(source);
        let mut suppressions = Suppressions::reserve(1, 1);

        assert!(!suppressions.join(source, lexed.as_slice(), &index));
        assert_eq!(suppressions.joined().len(), 1);
    }

    #[test]
    fn a_full_directive_table_stops_the_scan() {
        let source = b"# noqa\n# noqa\n# noqa\n";
        let index = indexed(source);
        let mut suppressions = Suppressions::reserve(2, 8);

        let spans = [
            Span {
                length: 6,
                offset: 0,
            },
            Span {
                length: 6,
                offset: 7,
            },
            Span {
                length: 6,
                offset: 14,
            },
        ];

        suppressions.scan(source, spans.iter().copied(), WORD, &index);

        assert_eq!(suppressions.count(), 2);
        assert_eq!(suppressions.matches(1, b"E501", source), 1);
        assert_eq!(suppressions.matches(2, b"E501", source), NONE);
    }

    #[test]
    fn a_full_code_table_stops_the_scan() {
        let source = b"# noqa: E501, F401, W605";
        let index = indexed(source);
        let mut suppressions = Suppressions::reserve(4, 2);

        suppressions.scan(source, core::iter::once(comment_of(source)), WORD, &index);

        assert_eq!(suppressions.count(), 1);

        let directive = *suppressions.get(0).expect("the directive is recorded");

        assert!(!directive.blanket);
        assert_eq!(directive.code_count, 2);
        assert_eq!(suppressions.matches(0, b"W605", source), NONE);
    }

    #[test]
    fn a_carriage_return_source_reports_the_lines_a_line_feed_source_does() {
        let feed = b"a = 1\n# noqa: E501\nb = 2\n";
        let carriage = b"a = 1\r\n# noqa: E501\r\nb = 2\r\n";

        let held = scanned(
            feed,
            &[Span {
                length: 12,
                offset: 6,
            }],
        );

        let other = scanned(
            carriage,
            &[Span {
                length: 12,
                offset: 7,
            }],
        );

        assert_eq!(held.count(), 1);
        assert_eq!(other.count(), 1);

        assert_eq!(
            held.get(0).expect("the directive is recorded").line,
            other.get(0).expect("the directive is recorded").line
        );

        assert_eq!(held.matches(1, b"E501", feed), 0);
        assert_eq!(other.matches(1, b"E501", carriage), 0);
    }

    #[test]
    fn a_consumed_directive_leaves_the_unconsumed_behind() {
        let source = b"# noqa\n# noqa: E501\n";
        let index = indexed(source);
        let mut suppressions = Suppressions::reserve(8, 8);

        let spans = [
            Span {
                length: 6,
                offset: 0,
            },
            Span {
                length: 12,
                offset: 7,
            },
        ];

        suppressions.scan(source, spans.iter().copied(), WORD, &index);

        assert_eq!(suppressions.unconsumed().count(), 2);

        suppressions.consume(0);

        assert_eq!(suppressions.unconsumed().collect::<Vec<u32>>(), vec![1]);
    }

    fn commented(source: &[u8]) -> (Tokens, lines::Index) {
        let mut lexed = Tokens::reserve(1 << 12);

        PYTHON.lex(source, &mut lexed);

        (lexed, indexed(source))
    }

    fn spans_of(lexed: &Tokens, kind: TokenKind) -> Vec<Span> {
        lexed
            .as_slice()
            .iter()
            .filter(|token| token.kind == kind)
            .map(Token::span)
            .collect()
    }

    fn python(source: &[u8]) -> Suppressions {
        let (lexed, index) = commented(source);
        let mut suppressions = Suppressions::reserve(32, 64);

        suppressions.scan(
            source,
            spans_of(&lexed, TokenKind::Comment).into_iter(),
            WORD,
            &index,
        );

        assert!(suppressions.join(source, lexed.as_slice(), &index));

        suppressions
    }

    fn pragmas_of(source: &[u8]) -> Vec<Pragma> {
        let (lexed, index) = commented(source);
        let mut pragmas = Pragmas::reserve(32);

        pragmas.scan(
            source,
            spans_of(&lexed, TokenKind::Comment).into_iter(),
            &index,
        );

        pragmas.as_slice().iter().map(|held| held.kind).collect()
    }

    #[test]
    fn a_ruff_file_directive_suppresses_every_line() {
        let source = b"# ruff: noqa\nimport os\n";
        let held = python(source);

        assert_eq!(held.count(), 1);
        assert_eq!(held.get(0).expect("a directive").line, FILE_LINE);
        assert!(held.matches(1, b"F401", source) != NONE);
        assert!(held.matches(9, b"E501", source) != NONE);
    }

    #[test]
    fn a_flake8_file_directive_suppresses_every_line() {
        let source = b"# flake8: noqa\nimport os\n";

        assert!(python(source).matches(1, b"F401", source) != NONE);
    }

    #[test]
    fn a_file_directive_naming_codes_suppresses_only_those() {
        let source = b"# flake8: noqa: F401\nimport os\n";
        let held = python(source);

        assert!(held.matches(1, b"F401", source) != NONE);
        assert_eq!(held.matches(1, b"E501", source), NONE);
    }

    #[test]
    fn a_ruff_file_directive_naming_another_code_leaves_the_row_standing() {
        let source = b"# ruff: noqa: E501\nimport os\n";

        assert_eq!(python(source).matches(1, b"F401", source), NONE);
    }

    #[test]
    fn a_directive_with_no_colon_still_names_its_codes() {
        let source = b"import sys  # noqa F401\n";
        let held = python(source);

        assert!(held.matches(0, b"F401", source) != NONE);
        assert_eq!(held.matches(0, b"E501", source), NONE);
        assert_eq!(codes_of(&held, 0, source), vec![b"F401".to_vec()]);
    }

    #[test]
    fn a_directive_followed_by_prose_stays_a_blanket() {
        let source = b"import sys  # noqa because reasons\n";
        let held = python(source);

        assert!(held.get(0).expect("a directive").blanket);
        assert!(held.matches(0, b"E501", source) != NONE);
    }

    #[test]
    fn a_directive_on_a_closing_line_covers_the_whole_string() {
        let mut source = Vec::from(b"held = \"\"\"one\n".as_slice());

        source.extend_from_slice(b"two\n");
        source.extend_from_slice(b"three\"\"\"  # noqa: E501\n");

        let held = python(&source);

        assert_eq!(
            held.joined(),
            &[Joined {
                line_first: 0,
                line_last: 2
            }]
        );

        assert!(held.matches(1, b"E501", &source) != NONE);
        assert!(held.matches(2, b"E501", &source) != NONE);
    }

    #[test]
    fn a_backslash_continuation_carries_its_line_forward() {
        let mut source = Vec::from(b"held = 1 + \\".as_slice());

        source.extend_from_slice(b"\n    2  # noqa: E501\n");

        let held = python(&source);

        assert_eq!(
            held.joined(),
            &[Joined {
                line_first: 0,
                line_last: 1
            }]
        );

        assert!(held.matches(0, b"E501", &source) != NONE);
    }

    #[test]
    fn a_line_that_stands_alone_maps_to_itself() {
        let source = b"held = 1  # noqa: E501\n";
        let scan = python(source);

        assert!(scan.joined().is_empty());
        assert!(scan.matches(0, b"E501", source) != NONE);
        assert_eq!(scan.matches(1, b"E501", source), NONE);
    }

    #[test]
    fn each_pragma_reads_as_its_own_kind() {
        let mut source = Vec::from(b"# fmt: off\n".as_slice());

        source.extend_from_slice(b"# fmt: on\n");
        source.extend_from_slice(b"held = 1  # fmt: skip\n");
        source.extend_from_slice(b"# isort: off\n");
        source.extend_from_slice(b"# isort: on\n");
        source.extend_from_slice(b"held = 2  # isort: skip\n");
        source.extend_from_slice(b"# isort: split\n");
        source.extend_from_slice(b"held = 3  # type: ignore[arg-type]\n");

        assert_eq!(
            pragmas_of(&source),
            vec![
                Pragma::FormatOff,
                Pragma::FormatOn,
                Pragma::FormatSkip,
                Pragma::IsortOff,
                Pragma::IsortOn,
                Pragma::IsortSkip,
                Pragma::IsortSplit,
                Pragma::TypeIgnore,
            ]
        );
    }

    #[test]
    fn a_pragma_written_without_its_blank_reads_the_same() {
        assert_eq!(
            pragmas_of(b"held = 1  # fmt:skip\n"),
            vec![Pragma::FormatSkip]
        );
    }

    #[test]
    fn a_pragma_with_blanks_after_it_reads_the_same() {
        assert_eq!(pragmas_of(b"# fmt: off   \n"), vec![Pragma::FormatOff]);

        assert_eq!(
            pragmas_of(b"held = 1  # fmt: skip  \n"),
            vec![Pragma::FormatSkip]
        );

        assert_eq!(pragmas_of(b"# isort: split\t\n"), vec![Pragma::IsortSplit]);
    }

    #[test]
    fn a_directive_with_blanks_after_it_suppresses_its_line() {
        let source = b"import os  # noqa   \n";
        let held = python(source);

        assert_eq!(held.count(), 1);
        assert_eq!(held.matches(0, b"F401", source), 0);
    }

    #[test]
    fn a_comment_that_only_opens_like_a_pragma_is_no_pragma() {
        assert!(pragmas_of(b"# fmt: offside\n").is_empty());
        assert!(pragmas_of(b"# format: off\n").is_empty());
        assert!(pragmas_of(b"# isort: splitter\n").is_empty());
    }

    #[test]
    fn a_pragma_records_the_line_it_stands_on() {
        let source = b"held = 1\n# fmt: off\n";
        let (lexed, index) = commented(source);
        let mut pragmas = Pragmas::reserve(8);

        pragmas.scan(
            source,
            spans_of(&lexed, TokenKind::Comment).into_iter(),
            &index,
        );

        assert_eq!(pragmas.count(), 1);
        assert_eq!(pragmas.as_slice()[0].kind, Pragma::FormatOff);
        assert_eq!(pragmas.as_slice()[0].line, 1);
    }

    #[test]
    fn a_python_comment_carries_a_directive() {
        let source = b"import os  # noqa: F401\n";
        let spans = comments_of(source, &PYTHON);
        let suppressions = scanned(source, &spans);

        assert_eq!(spans.len(), 1);
        assert_eq!(suppressions.matches(0, b"F401", source), 0);
    }

    #[test]
    fn a_rust_comment_carries_a_directive() {
        let source = b"let value = 1; // noqa: TS032\n";
        let spans = comments_of(source, &RUST);
        let suppressions = scanned(source, &spans);

        assert_eq!(spans.len(), 1);
        assert_eq!(suppressions.matches(0, b"TS032", source), 0);
    }

    #[test]
    fn a_go_block_comment_carries_a_directive() {
        let source = b"var value = 1 /* noqa: TS032 */\n";
        let spans = comments_of(source, &GO);
        let suppressions = scanned(source, &spans);

        assert_eq!(spans.len(), 1);
        assert_eq!(suppressions.matches(0, b"TS032", source), 0);
    }

    #[test]
    fn a_markup_comment_carries_a_directive() {
        let source = b"<div>{# noqa: TS032 #}</div>\n";
        let mut tokens = MarkupTokens::reserve(1_024);

        markup::lex(source, &mut tokens);

        let spans: Vec<Span> = tokens
            .as_slice()
            .iter()
            .filter(|token| token.kind == MarkupKind::CommentText)
            .map(|token| Span {
                length: token.length,
                offset: token.offset,
            })
            .collect();

        let suppressions = scanned(source, &spans);

        assert_eq!(spans.len(), 1);
        assert_eq!(suppressions.matches(0, b"TS032", source), 0);
    }

    #[test]
    fn a_scan_runs_on_a_frozen_thread() {
        let source = b"# noqa: E501\nvalue = 1  # noqa\n";
        let index = indexed(source);
        let mut suppressions = Suppressions::reserve(8, 8);

        let spans = [
            Span {
                length: 12,
                offset: 0,
            },
            Span {
                length: 6,
                offset: 24,
            },
        ];

        let _scope = crate::allocation::freeze_scope();

        suppressions.scan(source, spans.iter().copied(), WORD, &index);

        assert_eq!(suppressions.count(), 2);
        assert_eq!(suppressions.matches(0, b"E501", source), 0);
        assert_eq!(suppressions.matches(1, b"F401", source), 1);

        suppressions.consume(1);

        assert_eq!(suppressions.unconsumed().count(), 1);
    }

    const TIGERSTYLE: Markers = Markers {
        annotation: b"#[",
        disable: b"tigerstyle-disable:",
        enable: b"tigerstyle-enable:",
        file: b"tigerstyle-file-ignore:",
        line: b"tigerstyle-ignore:",
    };

    fn tigerstyle_code(code: &[u8]) -> Option<u32> {
        if code.len() < 3 || &code[..2] != b"TS" {
            return None;
        }

        crate::rule::code_number_of(code)
    }

    fn parsed_of(text: &[u8]) -> (Region, u64, bool) {
        let parsed = directive_of(text, &TIGERSTYLE, &tigerstyle_code).expect("it parses");

        (parsed.kind, parsed.codes, parsed.unknown)
    }

    #[test]
    fn a_directive_lists_its_codes() {
        assert_eq!(
            parsed_of(b"// tigerstyle-ignore: TS002, TS003"),
            (Region::Line, (1 << 2) | (1 << 3), false)
        );

        assert_eq!(
            parsed_of(b"# tigerstyle-ignore: *"),
            (Region::Line, u64::MAX, false)
        );

        assert_eq!(
            parsed_of(b"# tigerstyle-ignore:"),
            (Region::Line, u64::MAX, false)
        );

        assert!(directive_of(b"# a note", &TIGERSTYLE, &tigerstyle_code).is_none());
    }

    #[test]
    fn a_directive_drops_its_reason() {
        assert_eq!(
            parsed_of(b"// tigerstyle-ignore: TS002 -- the vendor writes it this way"),
            (Region::Line, 1 << 2, false)
        );
    }

    #[test]
    fn a_directive_spans_its_payload() {
        let parsed = directive_of(
            b"// tigerstyle-ignore: TS002, TS003 -- a reason",
            &TIGERSTYLE,
            &tigerstyle_code,
        )
        .expect("the directive parses");

        assert_eq!(parsed.payload.offset, 22);
        assert_eq!(parsed.payload.length, 12);
        assert!(!parsed.wildcard);
    }

    #[test]
    fn a_region_directive_reads_its_kind() {
        assert_eq!(
            parsed_of(b"// tigerstyle-disable: TS012"),
            (Region::Disable, 1 << 12, false)
        );

        assert_eq!(
            parsed_of(b"// tigerstyle-enable: TS012"),
            (Region::Enable, 1 << 12, false)
        );

        assert_eq!(
            parsed_of(b"// tigerstyle-file-ignore: TS012"),
            (Region::File, 1 << 12, false)
        );
    }

    #[test]
    fn an_unknown_code_is_recorded() {
        assert_eq!(
            parsed_of(b"// tigerstyle-ignore: TS999"),
            (Region::Line, 0, true)
        );
    }

    #[test]
    fn a_written_list_spells_every_code_it_holds() {
        let mut target = [0_u8; 64];

        let length = codes_written((1 << 2) | (1 << 12), b"TS", 3, &mut target)
            .expect("the mask holds two codes");

        assert_eq!(&target[..length], b"TS002, TS012");
        assert!(codes_written(0, b"TS", 3, &mut target).is_none());
    }
}
