use core::cell::RefCell;
use core::mem::swap;
use core::ops::Range;

use crate::bounded::{BoundedVec, Bytes as _};
use crate::path::is_separator;

pub const CLASS_BYTES: u32 = 32;
pub const SEPARATOR: u8 = b'/';
const BITS_PER_BYTE: u32 = 8;
const BITS_PER_WORD: u32 = 64;
const BRACE_DEPTH_MAX: usize = 8;
const CLASS_BYTES_USIZE: usize = 32;
const EXPANSION_STEPS_MAX: u32 = 1_024;
const NIBBLE_LOW: u8 = 0x07;
const NIBBLE_SHIFT: u32 = 3;
const VARIANT_BYTES_MAX: u32 = 8_192;
const VARIANT_COUNT_MAX: u32 = 128;
const WORD_MASK: u32 = 63;
const WORD_SHIFT: u32 = 6;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Anchoring {
    Anchored,
    Inferred,
    Unanchored,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Error {
    BraceTooDeep(u32),
    BraceUnclosed(u32),
    ClassUnclosed(u32),
    DoubleStarComponent(u32),
    Empty,
    EscapeUnfinished(u32),
    Overflow,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Row {
    pub end: u32,
    pub start: u32,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Shape {
    General,
    LastSegment { head: Row, star: bool, tail: Row },
    SegmentUnder { head: Row, star: bool, tail: Row },
    Whole { head: Row, star: bool, tail: Row },
    WholePrefix { head: Row, star: bool, tail: Row },
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Token {
    Any,
    Class { negated: bool, offset: u32 },
    Literal(u8),
    SegmentStar,
    Star,
    TailStar,
}

#[derive(Debug)]
pub struct Scratch {
    live: BoundedVec<u64>,
    next: BoundedVec<u64>,
}

#[derive(Debug)]
struct Expansion {
    pending: BoundedVec<(u32, u32)>,
    spans: BoundedVec<(u32, u32)>,
    work: BoundedVec<u8>,
}

#[derive(Debug)]
pub struct Patterns {
    classes: BoundedVec<u8>,
    expansion: Expansion,
    rows: BoundedVec<Row>,
    scratch: RefCell<Scratch>,
    shapes: BoundedVec<Shape>,
    tokens: BoundedVec<Token>,
}

impl Error {
    pub const fn message(self) -> &'static str {
        match self {
            Self::BraceTooDeep(_) => {
                "the alternation nests or expands further than the reader reads"
            }
            Self::BraceUnclosed(_) => "the alternation opens with { and never closes",
            Self::ClassUnclosed(_) => "the character class opens with [ and never closes",
            Self::DoubleStarComponent(_) => "** stands as a whole path component or not at all",
            Self::Empty => "the pattern names nothing",
            Self::EscapeUnfinished(_) => "the pattern ends in a backslash that escapes nothing",
            Self::Overflow => "the pattern table has no room left",
        }
    }

    pub const fn offset(self) -> u32 {
        match self {
            Self::BraceTooDeep(offset)
            | Self::BraceUnclosed(offset)
            | Self::ClassUnclosed(offset)
            | Self::DoubleStarComponent(offset)
            | Self::EscapeUnfinished(offset) => offset,
            Self::Empty | Self::Overflow => 0,
        }
    }
}

impl Row {
    pub const fn is_empty(self) -> bool {
        self.start >= self.end
    }
}

impl Token {
    pub const fn is_skippable(self) -> bool {
        matches!(self, Self::SegmentStar | Self::Star | Self::TailStar)
    }
}

impl Scratch {
    pub fn capacity(&self) -> u32 {
        self.live.count().saturating_mul(BITS_PER_WORD)
    }

    pub fn reserve(token_count_max: u32) -> Self {
        assert!(token_count_max > 0);
        assert!(!crate::allocation::is_frozen());

        let words = words_for(token_count_max);

        Self {
            live: filled(words),
            next: filled(words),
        }
    }
}

impl Patterns {
    pub fn clear(&mut self) {
        self.classes.clear();
        self.rows.clear();
        self.shapes.clear();
        self.tokens.clear();
    }

    pub fn count(&self) -> u32 {
        self.rows.count()
    }

    pub fn is_empty(&self) -> bool {
        self.rows.count() == 0
    }

    pub fn matched(&self, path: &[u8]) -> Option<u32> {
        let mut index = 0_u32;

        for row in self.rows.iter() {
            if self.row_matches(*row, index, path) {
                return Some(index);
            }

            index = index.saturating_add(1);
        }

        None
    }

    pub fn matches(&self, path: &[u8]) -> bool {
        self.matched(path).is_some()
    }

    pub fn matches_walked(&self, path: &[u8]) -> bool {
        let mut scratch = self.scratch.borrow_mut();

        for row in self.rows.iter() {
            if matches(*row, &self.tokens, &self.classes, &mut scratch, path) {
                return true;
            }
        }

        false
    }

    pub fn matches_within(&self, first: u32, end: u32, path: &[u8]) -> bool {
        let Some(rows) = self
            .rows
            .get(usize::try_from(first).unwrap_or(usize::MAX)..usize::try_from(end).unwrap_or(0))
        else {
            return false;
        };

        let mut index = first;

        for row in rows {
            if self.row_matches(*row, index, path) {
                return true;
            }

            index = index.saturating_add(1);
        }

        false
    }

    pub fn push(&mut self, pattern: &[u8]) -> Result<(), Error> {
        self.pushed(pattern, Anchoring::Inferred)
    }

    pub fn push_anchored(&mut self, pattern: &[u8]) -> Result<(), Error> {
        self.pushed(pattern, Anchoring::Anchored)
    }

    pub fn push_unanchored(&mut self, pattern: &[u8]) -> Result<(), Error> {
        self.pushed(pattern, Anchoring::Unanchored)
    }

    fn pushed(&mut self, pattern: &[u8], anchoring: Anchoring) -> Result<(), Error> {
        let trimmed = trimmed(pattern);

        if trimmed.is_empty() {
            return Err(Error::Empty);
        }

        let Expansion {
            pending,
            spans,
            work,
        } = &mut self.expansion;

        pending.clear();
        spans.clear();
        work.clear();

        expand(trimmed, work, pending, spans)?;

        let mut index = 0_u32;

        while index < spans.count() {
            let Ok(row) = usize::try_from(index) else {
                return Err(Error::Overflow);
            };

            let Some((start, end)) = spans.get(row).copied() else {
                return Err(Error::Overflow);
            };

            let (Ok(from), Ok(to)) = (usize::try_from(start), usize::try_from(end)) else {
                return Err(Error::Overflow);
            };

            let Some(alternative) = work.get(from..to) else {
                return Err(Error::Overflow);
            };

            let compiled = anchor(
                alternative,
                anchoring,
                &mut self.tokens,
                &mut self.classes,
                &mut self.rows,
                self.scratch.borrow().capacity(),
            );

            compiled?;

            index = index.saturating_add(1);
        }

        while self.shapes.count() < self.rows.count() {
            let at = usize::try_from(self.shapes.count()).unwrap_or(usize::MAX);

            let Some(row) = self.rows.get(at).copied() else {
                return Err(Error::Overflow);
            };

            let held = classify(&self.tokens, row);

            if !self.shapes.push(held) {
                return Err(Error::Overflow);
            }
        }

        Ok(())
    }

    pub fn reserve(row_count_max: u32, token_count_max: u32, class_count_max: u32) -> Self {
        assert!(row_count_max > 0);
        assert!(token_count_max > 0);
        assert!(class_count_max > 0);
        assert!(!crate::allocation::is_frozen());

        Self {
            classes: BoundedVec::reserve(class_count_max.saturating_mul(CLASS_BYTES)),
            expansion: Expansion {
                pending: BoundedVec::reserve(VARIANT_COUNT_MAX),
                spans: BoundedVec::reserve(VARIANT_COUNT_MAX),
                work: BoundedVec::reserve(VARIANT_BYTES_MAX),
            },
            rows: BoundedVec::reserve(row_count_max),
            scratch: RefCell::new(Scratch::reserve(token_count_max)),
            shapes: BoundedVec::reserve(row_count_max),
            tokens: BoundedVec::reserve(token_count_max),
        }
    }

    fn row_matches(&self, row: Row, index: u32, path: &[u8]) -> bool {
        let held = self
            .shapes
            .get(usize::try_from(index).unwrap_or(usize::MAX))
            .copied()
            .unwrap_or(Shape::General);

        if let Some(answer) = shaped(held, &self.tokens, &self.classes, path) {
            return answer;
        }

        let mut scratch = self.scratch.borrow_mut();

        matches(row, &self.tokens, &self.classes, &mut scratch, path)
    }

    pub fn truncate(&mut self, count: u32) {
        assert!(count <= self.rows.count());

        self.rows.truncate(count);
        self.shapes.truncate(count);

        let tokens = self.rows.last().map_or(0, |row| row.end);

        self.tokens.truncate(tokens);

        let classes = self
            .tokens
            .iter()
            .filter_map(|token| match *token {
                Token::Class { offset, .. } => Some(offset.saturating_add(CLASS_BYTES)),
                Token::Any
                | Token::Literal(_)
                | Token::SegmentStar
                | Token::Star
                | Token::TailStar => None,
            })
            .max()
            .unwrap_or(0);

        self.classes.truncate(classes);

        assert_eq!(self.rows.count(), count);
        assert_eq!(self.shapes.count(), count);
    }
}

fn anchor(
    pattern: &[u8],
    anchoring: Anchoring,
    tokens: &mut BoundedVec<Token>,
    classes: &mut BoundedVec<u8>,
    rows: &mut BoundedVec<Row>,
    capacity: u32,
) -> Result<(), Error> {
    let rooted = pattern.first() == Some(&SEPARATOR) || pattern.starts_with(b"**/");

    let anchored = match anchoring {
        Anchoring::Anchored => true,
        Anchoring::Inferred => pattern.contains(&SEPARATOR),
        Anchoring::Unanchored => false,
    };

    let prefix: &[u8] = if rooted || anchored { b"" } else { b"**/" };

    row(pattern, prefix, b"", tokens, classes, rows, capacity)?;

    row(pattern, prefix, b"/**", tokens, classes, rows, capacity)
}

fn row(
    pattern: &[u8],
    prefix: &[u8],
    suffix: &[u8],
    tokens: &mut BoundedVec<Token>,
    classes: &mut BoundedVec<u8>,
    rows: &mut BoundedVec<Row>,
    capacity: u32,
) -> Result<(), Error> {
    let start = tokens.count();

    for run in [prefix, pattern, suffix] {
        compile(run, tokens, classes)?;
    }

    let end = tokens.count();

    if end > capacity {
        return Err(Error::Overflow);
    }

    if rows.push(Row { end, start }) {
        return Ok(());
    }

    Err(Error::Overflow)
}

fn trimmed(pattern: &[u8]) -> &[u8] {
    let mut held = pattern;

    while let Some(rest) = held.strip_prefix(b"./") {
        held = rest;
    }

    while let Some(rest) = held.strip_suffix(b"/") {
        held = rest;
    }

    held
}

pub fn compile(
    pattern: &[u8],
    tokens: &mut BoundedVec<Token>,
    classes: &mut BoundedVec<u8>,
) -> Result<(), Error> {
    let mut offset = 0_usize;

    while offset < pattern.len() {
        let Some(byte) = pattern.get(offset).copied() else {
            return Err(Error::Overflow);
        };

        let read = match byte {
            b'\\' => escaped(pattern, offset, tokens),
            b'*' => star(pattern, offset, tokens),
            b'[' => class(pattern, offset, tokens, classes),
            b'?' => literal(tokens, Token::Any, offset),
            _ => literal(tokens, Token::Literal(byte), offset),
        };

        offset = read?;
    }

    Ok(())
}

pub fn expand(
    pattern: &[u8],
    work: &mut BoundedVec<u8>,
    pending: &mut BoundedVec<(u32, u32)>,
    spans: &mut BoundedVec<(u32, u32)>,
) -> Result<(), Error> {
    let seed = appended(work, pattern)?;

    if !pending.push(seed) {
        return Err(Error::Overflow);
    }

    let mut steps = 0_u32;

    while let Some((start, end)) = pending.pop() {
        steps = steps.saturating_add(1);

        if steps > EXPANSION_STEPS_MAX {
            return Err(Error::BraceTooDeep(0));
        }

        let held = brace_of(work, start, end)?;

        let Some((open, close)) = held else {
            if spans.push((start, end)) {
                continue;
            }

            return Err(Error::Overflow);
        };

        split(work, pending, (start, end), (open, close))?;
    }

    Ok(())
}

pub fn is_member(bitmap: &[u8], byte: u8) -> bool {
    let slot = usize::from(byte >> NIBBLE_SHIFT);
    let bit = byte & NIBBLE_LOW;

    let Some(cell) = bitmap.get(slot) else {
        return false;
    };

    (*cell >> bit) & 1_u8 == 1_u8
}

fn appended(work: &mut BoundedVec<u8>, bytes: &[u8]) -> Result<(u32, u32), Error> {
    let start = work.count();

    if !work.push_bytes(bytes) {
        return Err(Error::Overflow);
    }

    Ok((start, work.count()))
}

fn append_run(work: &mut BoundedVec<u8>, start: u32, end: u32) -> Result<(), Error> {
    let mut index = start;

    while index < end {
        let Ok(slot) = usize::try_from(index) else {
            return Err(Error::Overflow);
        };

        let Some(byte) = work.get(slot).copied() else {
            return Err(Error::Overflow);
        };

        if !work.push(byte) {
            return Err(Error::Overflow);
        }

        index = index.saturating_add(1);
    }

    Ok(())
}

fn brace_of(work: &BoundedVec<u8>, start: u32, end: u32) -> Result<Option<(u32, u32)>, Error> {
    let mut offset = start;
    let mut open = None;
    let mut depth = 0_usize;

    while offset < end {
        let Ok(slot) = usize::try_from(offset) else {
            return Err(Error::Overflow);
        };

        let Some(byte) = work.get(slot).copied() else {
            return Err(Error::Overflow);
        };

        if byte == b'\\' {
            if offset.saturating_add(1) >= end {
                return Err(Error::EscapeUnfinished(offset.saturating_sub(start)));
            }

            offset = offset.saturating_add(2);

            continue;
        }

        if byte == b'{' {
            depth = depth.saturating_add(1);

            if depth > BRACE_DEPTH_MAX {
                return Err(Error::BraceTooDeep(offset.saturating_sub(start)));
            }

            if open.is_none() {
                open = Some(offset);
            }
        } else if byte == b'}' {
            depth = depth.saturating_sub(1);

            if depth == 0 {
                let Some(at) = open else {
                    return Ok(None);
                };

                return Ok(Some((at, offset)));
            }
        }

        offset = offset.saturating_add(1);
    }

    if let Some(at) = open {
        return Err(Error::BraceUnclosed(at.saturating_sub(start)));
    }

    Ok(None)
}

fn class(
    pattern: &[u8],
    start: usize,
    tokens: &mut BoundedVec<Token>,
    classes: &mut BoundedVec<u8>,
) -> Result<usize, Error> {
    let mut offset = start.saturating_add(1);
    let mut negated = false;

    if matches!(pattern.get(offset).copied(), Some(b'!' | b'^')) {
        negated = true;
        offset = offset.saturating_add(1);
    }

    let mut bitmap = [0_u8; CLASS_BYTES_USIZE];

    let Some(end) = class_members(pattern, offset, &mut bitmap) else {
        return Err(Error::ClassUnclosed(count(start)));
    };

    let at = classes.count();

    for byte in bitmap {
        if !classes.push(byte) {
            return Err(Error::Overflow);
        }
    }

    push(
        tokens,
        Token::Class {
            negated,
            offset: at,
        },
    )?;

    Ok(end)
}

fn class_members(
    pattern: &[u8],
    start: usize,
    bitmap: &mut [u8; CLASS_BYTES_USIZE],
) -> Option<usize> {
    let mut offset = start;
    let mut first = true;

    while offset < pattern.len() {
        let byte = pattern.get(offset).copied()?;

        if byte == b']' && !first {
            return Some(offset.saturating_add(1));
        }

        first = false;

        let dashed = pattern.get(offset.saturating_add(1)).copied() == Some(b'-');
        let high = pattern.get(offset.saturating_add(2)).copied();

        if dashed && high.is_some() && high != Some(b']') {
            let last = high?;

            set_range(bitmap, byte, last);

            offset = offset.saturating_add(3);

            continue;
        }

        set_bit(bitmap, byte);

        offset = offset.saturating_add(1);
    }

    None
}

fn count(offset: usize) -> u32 {
    u32::try_from(offset).unwrap_or(u32::MAX)
}

fn escaped(pattern: &[u8], start: usize, tokens: &mut BoundedVec<Token>) -> Result<usize, Error> {
    let Some(byte) = pattern.get(start.saturating_add(1)).copied() else {
        return Err(Error::EscapeUnfinished(count(start)));
    };

    literal(tokens, Token::Literal(byte), start.saturating_add(1))
}

fn literal(tokens: &mut BoundedVec<Token>, token: Token, offset: usize) -> Result<usize, Error> {
    push(tokens, token)?;

    Ok(offset.saturating_add(1))
}

fn push(tokens: &mut BoundedVec<Token>, token: Token) -> Result<(), Error> {
    if tokens.push(token) {
        return Ok(());
    }

    Err(Error::Overflow)
}

fn set_bit(bitmap: &mut [u8; CLASS_BYTES_USIZE], byte: u8) {
    let slot = usize::from(byte >> NIBBLE_SHIFT);
    let bit = byte & NIBBLE_LOW;

    let Some(cell) = bitmap.get_mut(slot) else {
        return;
    };

    *cell |= 1_u8 << bit;
}

fn set_range(bitmap: &mut [u8; CLASS_BYTES_USIZE], low: u8, high: u8) {
    let mut byte = low;

    while byte <= high {
        set_bit(bitmap, byte);

        if byte == u8::MAX {
            break;
        }

        byte = byte.saturating_add(1);
    }
}

fn split(
    work: &mut BoundedVec<u8>,
    pending: &mut BoundedVec<(u32, u32)>,
    outer: (u32, u32),
    brace: (u32, u32),
) -> Result<(), Error> {
    let (start, end) = outer;
    let (open, close) = brace;
    let body_start = open.saturating_add(1);
    let tail_start = close.saturating_add(1);
    let mut cursor = body_start;
    let mut depth = 0_usize;
    let mut offset = body_start;

    while offset <= close {
        let Ok(slot) = usize::try_from(offset) else {
            return Err(Error::Overflow);
        };

        let Some(byte) = work.get(slot).copied() else {
            return Err(Error::Overflow);
        };

        let boundary = offset == close || (byte == b',' && depth == 0);

        if byte == b'{' {
            depth = depth.saturating_add(1);
        } else if byte == b'}' && offset != close {
            depth = depth.saturating_sub(1);
        }

        if boundary {
            let at = work.count();

            append_run(work, start, open)?;

            append_run(work, cursor, offset)?;

            append_run(work, tail_start, end)?;

            if !pending.push((at, work.count())) {
                return Err(Error::Overflow);
            }

            cursor = offset.saturating_add(1);
        }

        offset = offset.saturating_add(1);
    }

    Ok(())
}

fn star(pattern: &[u8], start: usize, tokens: &mut BoundedVec<Token>) -> Result<usize, Error> {
    if pattern.get(start.saturating_add(1)).copied() != Some(b'*') {
        return literal(tokens, Token::Star, start);
    }

    let before = if start == 0 {
        Some(SEPARATOR)
    } else {
        pattern.get(start.saturating_sub(1)).copied()
    };

    if before != Some(SEPARATOR) {
        return Err(Error::DoubleStarComponent(count(start)));
    }

    match pattern.get(start.saturating_add(2)).copied() {
        Some(SEPARATOR) => {
            push(tokens, Token::SegmentStar)?;

            Ok(start.saturating_add(3))
        }
        None => {
            push(tokens, Token::TailStar)?;

            Ok(start.saturating_add(2))
        }
        Some(_) => Err(Error::DoubleStarComponent(count(start))),
    }
}

pub fn matches(
    row: Row,
    tokens: &[Token],
    classes: &[u8],
    scratch: &mut Scratch,
    path: &[u8],
) -> bool {
    if row.is_empty() {
        return path.is_empty();
    }

    clear(&mut scratch.live, row);
    set(&mut scratch.live, row.start);
    close(&mut scratch.live, row, tokens);

    for byte in path {
        clear(&mut scratch.next, row);

        let mut index = row.start;

        while index < row.end {
            if test(&scratch.live, index) {
                step(tokens, classes, &mut scratch.next, index, *byte);
            }

            index = index.saturating_add(1);
        }

        close(&mut scratch.next, row, tokens);
        swap(&mut scratch.live, &mut scratch.next);

        if empty(&scratch.live, row) {
            return false;
        }
    }

    test(&scratch.live, row.end)
}

fn clear(words: &mut BoundedVec<u64>, row: Row) {
    let Some(range) = words.get_mut(word_range(row)) else {
        return;
    };

    for word in range {
        *word = 0;
    }
}

fn close(words: &mut BoundedVec<u64>, row: Row, tokens: &[Token]) {
    let mut index = row.start;

    while index < row.end {
        if !test(words, index) {
            index = index.saturating_add(1);

            continue;
        }

        let Ok(slot) = usize::try_from(index) else {
            return;
        };

        let Some(token) = tokens.get(slot) else {
            return;
        };

        if token.is_skippable() {
            set(words, index.saturating_add(1));
        }

        index = index.saturating_add(1);
    }
}

fn empty(words: &BoundedVec<u64>, row: Row) -> bool {
    let Some(range) = words.get(word_range(row)) else {
        return true;
    };

    for word in range {
        if *word != 0 {
            return false;
        }
    }

    true
}

fn filled(words: u32) -> BoundedVec<u64> {
    let mut held = BoundedVec::reserve(words);

    for _ in 0_u32..words {
        held.push_assert(0);
    }

    held
}

fn set(words: &mut BoundedVec<u64>, index: u32) {
    let Ok(slot) = usize::try_from(index >> WORD_SHIFT) else {
        return;
    };

    let Some(word) = words.get_mut(slot) else {
        return;
    };

    *word |= 1_u64 << (index & WORD_MASK);
}

fn step(tokens: &[Token], classes: &[u8], next: &mut BoundedVec<u64>, index: u32, byte: u8) {
    let Ok(slot) = usize::try_from(index) else {
        return;
    };

    let Some(token) = tokens.get(slot) else {
        return;
    };

    let forward = index.saturating_add(1);

    match *token {
        Token::Any => {
            if !is_separator(byte) {
                set(next, forward);
            }
        }
        Token::Class { negated, offset } => {
            if is_separator(byte) {
                return;
            }

            let Ok(start) = usize::try_from(offset) else {
                return;
            };

            let Some(bitmap) = classes.get(start..start.saturating_add(CLASS_BYTES_USIZE)) else {
                return;
            };

            if is_member(bitmap, byte) != negated {
                set(next, forward);
            }
        }
        Token::Literal(held) => {
            if literal_matches(held, byte) {
                set(next, forward);
            }
        }
        Token::SegmentStar => {
            set(next, index);

            if is_separator(byte) {
                set(next, forward);
            }
        }
        Token::Star => {
            if !is_separator(byte) {
                set(next, index);
            }
        }
        Token::TailStar => {
            set(next, index);
        }
    }
}

fn test(words: &BoundedVec<u64>, index: u32) -> bool {
    let Ok(slot) = usize::try_from(index >> WORD_SHIFT) else {
        return false;
    };

    let Some(word) = words.get(slot) else {
        return false;
    };

    (*word >> (index & WORD_MASK)) & 1_u64 == 1_u64
}

fn word_range(row: Row) -> Range<usize> {
    let first = usize::try_from(row.start >> WORD_SHIFT).unwrap_or(usize::MAX);
    let last = usize::try_from(row.end >> WORD_SHIFT).unwrap_or(usize::MAX);

    first..last.saturating_add(1)
}

fn words_for(token_count_max: u32) -> u32 {
    let bits = token_count_max.saturating_add(2);

    bits.div_ceil(BITS_PER_WORD).max(1)
}

pub fn classify(tokens: &[Token], row: Row) -> Shape {
    let (Ok(start), Ok(end)) = (usize::try_from(row.start), usize::try_from(row.end)) else {
        return Shape::General;
    };

    let Some(run) = tokens.get(start..end) else {
        return Shape::General;
    };

    let Some((&Token::SegmentStar, rest)) = run.split_first() else {
        return rooted(run, row.start);
    };

    let base = row.start.saturating_add(1);

    let (middle, under) = if let Some((&Token::TailStar, kept)) = rest.split_last()
        && let Some((&Token::Literal(SEPARATOR), inner)) = kept.split_last()
    {
        (inner, true)
    } else {
        (rest, false)
    };

    if middle
        .iter()
        .any(|token| matches!(token, Token::Literal(SEPARATOR)))
    {
        return Shape::General;
    }

    let Some((head, star, tail)) = split_fixed(middle, base) else {
        return Shape::General;
    };

    if under {
        return Shape::SegmentUnder { head, star, tail };
    }

    Shape::LastSegment { head, star, tail }
}

pub fn shaped(shape: Shape, tokens: &[Token], classes: &[u8], path: &[u8]) -> Option<bool> {
    match shape {
        Shape::General => None,
        Shape::LastSegment { head, star, tail } => {
            let segment = path
                .rsplit(|byte| is_separator(*byte))
                .next()
                .unwrap_or(path);

            Some(run_matches(tokens, classes, head, star, tail, segment))
        }
        Shape::SegmentUnder { head, star, tail } => {
            Some(under_matches(tokens, classes, head, star, tail, path))
        }
        Shape::Whole { head, star, tail } => {
            Some(run_matches(tokens, classes, head, star, tail, path))
        }
        Shape::WholePrefix { head, star, tail } => Some(rooted_prefix_matches(
            tokens,
            classes,
            head,
            star,
            tail,
            path,
        )),
    }
}

fn byte_matches(token: Token, classes: &[u8], byte: u8) -> bool {
    match token {
        Token::Any => !is_separator(byte),
        Token::Class { negated, offset } => {
            if is_separator(byte) {
                return false;
            }

            let Ok(start) = usize::try_from(offset) else {
                return false;
            };

            let Some(bitmap) = classes.get(start..start.saturating_add(CLASS_BYTES_USIZE)) else {
                return false;
            };

            is_member(bitmap, byte) != negated
        }
        Token::Literal(held) => literal_matches(held, byte),
        Token::SegmentStar | Token::Star | Token::TailStar => false,
    }
}

fn literal_matches(held: u8, byte: u8) -> bool {
    byte == held || (held == SEPARATOR && is_separator(byte))
}

fn prefix_matches(tokens: &[Token], classes: &[u8], run: Row, bytes: &[u8]) -> bool {
    let Some(held) = run_tokens(tokens, run) else {
        return false;
    };

    let Some(front) = bytes.get(..held.len()) else {
        return false;
    };

    for (token, byte) in held.iter().zip(front) {
        if !byte_matches(*token, classes, *byte) {
            return false;
        }
    }

    true
}

fn rooted(run: &[Token], start: u32) -> Shape {
    if let Some((&Token::TailStar, before)) = run.split_last() {
        let Some((head, star, tail)) = split_fixed(before, start) else {
            return Shape::General;
        };

        return Shape::WholePrefix { head, star, tail };
    }

    let Some((head, star, tail)) = split_fixed(run, start) else {
        return Shape::General;
    };

    Shape::Whole { head, star, tail }
}

fn rooted_prefix_matches(
    tokens: &[Token],
    classes: &[u8],
    head: Row,
    star: bool,
    tail: Row,
    path: &[u8],
) -> bool {
    if !star {
        return prefix_matches(tokens, classes, head, path);
    }

    if !prefix_matches(tokens, classes, head, path) {
        return false;
    }

    let head_len = run_len(head);

    let Some(rest) = path.get(head_len..) else {
        return false;
    };

    let limit = rest
        .iter()
        .position(|byte| is_separator(*byte))
        .unwrap_or(rest.len());

    let mut gap = 0_usize;

    while gap <= limit {
        let at = head_len.saturating_add(gap);

        if let Some(subject) = path.get(at..)
            && prefix_matches(tokens, classes, tail, subject)
        {
            return true;
        }

        gap = gap.saturating_add(1);
    }

    false
}

fn run_len(run: Row) -> usize {
    usize::try_from(run.end.saturating_sub(run.start)).unwrap_or(0)
}

fn run_matches(
    tokens: &[Token],
    classes: &[u8],
    head: Row,
    star: bool,
    tail: Row,
    subject: &[u8],
) -> bool {
    let head_len = run_len(head);

    if !star {
        return subject.len() == head_len && prefix_matches(tokens, classes, head, subject);
    }

    let Some(gap_end) = subject.len().checked_sub(run_len(tail)) else {
        return false;
    };

    if gap_end < head_len {
        return false;
    }

    if !prefix_matches(tokens, classes, head, subject)
        || !suffix_matches(tokens, classes, tail, subject)
    {
        return false;
    }

    let Some(gap) = subject.get(head_len..gap_end) else {
        return false;
    };

    !gap.iter().any(|byte| is_separator(*byte))
}

fn run_tokens(tokens: &[Token], run: Row) -> Option<&[Token]> {
    let (Ok(start), Ok(end)) = (usize::try_from(run.start), usize::try_from(run.end)) else {
        return None;
    };

    tokens.get(start..end)
}

fn split_fixed(run: &[Token], base: u32) -> Option<(Row, bool, Row)> {
    let mut split = None;
    let mut offset = 0_u32;

    for token in run {
        match *token {
            Token::Any | Token::Class { .. } | Token::Literal(_) => {}
            Token::Star => {
                if split.is_some() {
                    return None;
                }

                split = Some(offset);
            }
            Token::SegmentStar | Token::TailStar => return None,
        }

        offset = offset.saturating_add(1);
    }

    let stop = base.saturating_add(offset);

    let Some(at) = split else {
        return Some((
            Row {
                end: stop,
                start: base,
            },
            false,
            Row {
                end: stop,
                start: stop,
            },
        ));
    };

    Some((
        Row {
            end: base.saturating_add(at),
            start: base,
        },
        true,
        Row {
            end: stop,
            start: base.saturating_add(at).saturating_add(1),
        },
    ))
}

fn suffix_matches(tokens: &[Token], classes: &[u8], run: Row, bytes: &[u8]) -> bool {
    let Some(held) = run_tokens(tokens, run) else {
        return false;
    };

    let Some(start) = bytes.len().checked_sub(held.len()) else {
        return false;
    };

    let Some(tail) = bytes.get(start..) else {
        return false;
    };

    for (token, byte) in held.iter().zip(tail) {
        if !byte_matches(*token, classes, *byte) {
            return false;
        }
    }

    true
}

fn under_matches(
    tokens: &[Token],
    classes: &[u8],
    head: Row,
    star: bool,
    tail: Row,
    path: &[u8],
) -> bool {
    let mut parts = path.split(|byte| is_separator(*byte));
    let _last = parts.next_back();

    for segment in parts {
        if run_matches(tokens, classes, head, star, tail, segment) {
            return true;
        }
    }

    false
}

const _: () = assert!(CLASS_BYTES * BITS_PER_BYTE == 256);
const _: () = assert!(CLASS_BYTES_USIZE * 8 == 256);
const _: () = assert!((1_u32 << WORD_SHIFT) == BITS_PER_WORD);
const _: () = assert!(WORD_MASK == BITS_PER_WORD - 1);

#[cfg(test)]
mod tests {
    use super::*;
    use crate::allocation;

    const CLASS_COUNT_MAX: u32 = 32;
    const ROW_COUNT_MAX: u32 = 256;
    const TOKEN_COUNT_MAX: u32 = 4_096;

    const SHAPES: &[&str] = &[
        "venv",
        "*.db",
        "robit.log*",
        "dev_tool*.exe",
        "static_files/core",
        "docs/**",
        "*.py[cod]",
        "*.rs.bk",
        "page?.html",
        "[!x]env",
        "cache[0-9]/**",
        "dev_tool?v*.exe",
        "editors/vscode/*.vsix",
        "editors/*/out",
        "build/*",
        "static_files/core[0-9]/*.js",
        "a*b",
    ];

    const PATHS: &[&[u8]] = &[
        b"",
        b"venv",
        b"venv/",
        b"venv/page.html",
        b"app/venv/deep/page.html",
        b"venved/page.html",
        b"a/venv",
        b"app.db",
        b"deep/app.db",
        b"app.db/inside",
        b"app.dbx",
        b".db",
        b"robit.log",
        b"robit.log.1",
        b"deep/robit.log.1/held",
        b"robit.lo",
        b"dev_tool.exe",
        b"dev_tool_v2.exe",
        b"dev_tool.exes",
        b"static_files/core",
        b"static_files/core/js",
        b"app/static_files/core",
        b"docs",
        b"docs/",
        b"docs/guide.md",
        b"docsx/guide.md",
        b"app.pyc",
        b"app.pyo",
        b"app.pyd",
        b"app.pye",
        b"deep/app.pyc",
        b"main.rs.bk",
        b"page1.html",
        b"page.html",
        b"page12.html",
        b"xenv/page.html",
        b"cache7",
        b"cache7/held",
        b"cachex/held",
        b"dev_tool_v2.exe",
        b"dev_toolxv.exe",
        b"editors/vscode/parhelion.vsix",
        b"editors/vscode/parhelion.vsix/held",
        b"editors/vscode/deep/parhelion.vsix",
        b"editors/vscode/.vsix",
        b"editors/intellij/out",
        b"editors/intellij/out/held",
        b"editors/out",
        b"build/main.js",
        b"build/deep/main.js",
        b"build/",
        b"static_files/core7/app.js",
        b"static_files/core7/deep/app.js",
        b"static_files/corex/app.js",
        b"ab",
        b"axb",
        b"a/b",
        b"axxb",
    ];

    fn built(patterns: &[&str]) -> Patterns {
        let mut held = reserved();

        for pattern in patterns {
            held.push(pattern.as_bytes()).expect("the pattern compiles");
        }

        held
    }

    fn floating(patterns: &[&str]) -> Patterns {
        let mut held = reserved();

        for pattern in patterns {
            held.push_unanchored(pattern.as_bytes())
                .expect("the pattern compiles");
        }

        held
    }

    fn reserved() -> Patterns {
        Patterns::reserve(ROW_COUNT_MAX, TOKEN_COUNT_MAX, CLASS_COUNT_MAX)
    }

    #[test]
    fn an_empty_set_matches_nothing() {
        let patterns = reserved();

        assert!(patterns.is_empty());
        assert!(!patterns.matches(b"templates/page.html"));
    }

    #[test]
    fn a_bare_name_matches_that_directory_at_any_depth() {
        let patterns = built(&["vendor"]);

        assert!(patterns.matches(b"vendor"));
        assert!(patterns.matches(b"vendor/page.html"));
        assert!(patterns.matches(b"app/vendor/deep/page.html"));
        assert!(!patterns.matches(b"vendored/page.html"));
    }

    #[test]
    fn a_trailing_slash_reads_the_same_as_the_bare_name() {
        let patterns = built(&["vendor/"]);

        assert!(patterns.matches(b"vendor/page.html"));
        assert!(patterns.matches(b"app/vendor/page.html"));
        assert!(!patterns.matches(b"vendored/page.html"));
    }

    #[test]
    fn a_leading_dot_slash_is_cut_before_anything_else() {
        let patterns = built(&["./vendor"]);

        assert!(patterns.matches(b"vendor/page.html"));
        assert!(patterns.matches(b"app/vendor/page.html"));
    }

    #[test]
    fn a_pattern_holding_a_slash_is_anchored_at_the_root() {
        let patterns = built(&["app/vendor"]);

        assert!(patterns.matches(b"app/vendor/page.html"));
        assert!(!patterns.matches(b"site/app/vendor/page.html"));
    }

    #[test]
    fn an_unanchored_pattern_holding_a_slash_matches_at_any_depth() {
        let patterns = floating(&["tests/*"]);

        assert!(patterns.matches(b"/home/work/tests/lint.rs"));
        assert!(patterns.matches(b"tests/lint.rs"));
        assert!(!patterns.matches(b"/home/work/src/lint.rs"));

        let rooted = floating(&["/home/work/tests/*"]);

        assert!(rooted.matches(b"/home/work/tests/lint.rs"));
        assert!(!rooted.matches(b"/other/home/work/tests/lint.rs"));
    }

    #[test]
    fn an_anchored_pattern_matches_at_the_root_alone() {
        let mut patterns = reserved();

        patterns
            .push_anchored(b"vendor")
            .expect("the pattern compiles");

        assert!(patterns.matches(b"vendor"));
        assert!(patterns.matches(b"vendor/page.html"));
        assert!(!patterns.matches(b"app/vendor"));
        assert!(!patterns.matches(b"app/vendor/page.html"));
    }

    #[test]
    fn a_star_stops_at_a_directory_separator() {
        let patterns = built(&["*.min.js"]);

        assert!(patterns.matches(b"static/app.min.js"));
        assert!(!patterns.matches(b"static/app.min.js.map"));
    }

    #[test]
    fn a_double_star_pattern_reaches_through_directories() {
        let patterns = built(&["**/admin/*.html"]);

        assert!(patterns.matches(b"templates/admin/list.html"));
        assert!(patterns.matches(b"admin/list.html"));
        assert!(!patterns.matches(b"templates/admin/deep/list.html"));
    }

    #[test]
    fn a_trailing_double_star_takes_the_rest_of_the_path() {
        let patterns = built(&["static/**"]);

        assert!(patterns.matches(b"static/a.js"));
        assert!(patterns.matches(b"static/deep/a.js"));
        assert!(!patterns.matches(b"static"));
    }

    #[test]
    fn a_question_mark_takes_one_byte_that_is_not_a_separator() {
        let patterns = built(&["page?.html"]);

        assert!(patterns.matches(b"page1.html"));
        assert!(!patterns.matches(b"page.html"));
        assert!(!patterns.matches(b"page12.html"));
        assert!(!patterns.matches(b"pag/e.html"));
    }

    #[test]
    fn a_character_class_takes_the_bytes_it_names() {
        let patterns = built(&["page[0-9].html"]);

        assert!(patterns.matches(b"page7.html"));
        assert!(!patterns.matches(b"pagex.html"));
    }

    #[test]
    fn a_negated_class_takes_every_byte_it_does_not_name() {
        let patterns = built(&["page[!0-9].html"]);

        assert!(patterns.matches(b"pagex.html"));
        assert!(!patterns.matches(b"page7.html"));
    }

    #[test]
    fn a_caret_negates_a_class_the_same_way_a_bang_does() {
        let patterns = built(&["page[^0-9].html"]);

        assert!(patterns.matches(b"pagex.html"));
        assert!(!patterns.matches(b"page7.html"));
    }

    #[test]
    fn a_class_never_takes_a_separator() {
        let patterns = built(&["a[!x]b"]);

        assert!(patterns.matches(b"a-b"));
        assert!(!patterns.matches(b"a/b"));
    }

    #[test]
    fn an_alternation_stands_for_each_of_its_branches() {
        let patterns = built(&["*.{css,js}"]);

        assert!(patterns.matches(b"static/app.css"));
        assert!(patterns.matches(b"static/app.js"));
        assert!(!patterns.matches(b"static/app.map"));
    }

    #[test]
    fn a_nested_alternation_expands_through_every_level() {
        let patterns = built(&["a/{b,c/{d,e}}/f"]);

        assert!(patterns.matches(b"a/b/f"));
        assert!(patterns.matches(b"a/c/d/f"));
        assert!(patterns.matches(b"a/c/e/f"));
        assert!(!patterns.matches(b"a/c/f"));
    }

    #[test]
    fn an_escaped_metacharacter_stands_for_itself() {
        let patterns = built(&[r"a\*b"]);

        assert!(patterns.matches(b"a*b"));
        assert!(!patterns.matches(b"axb"));
    }

    #[test]
    fn several_patterns_match_as_one_set() {
        let patterns = built(&["vendor", "*.min.js", "**/admin/*.html"]);

        assert!(patterns.matches(b"vendor/a.html"));
        assert!(patterns.matches(b"static/a.min.js"));
        assert!(patterns.matches(b"t/admin/list.html"));
        assert!(!patterns.matches(b"t/page.html"));
    }

    #[test]
    fn the_matched_row_names_the_pattern_that_covered_the_path() {
        let patterns = built(&["vendor", "static"]);
        let vendor = patterns.matched(b"vendor/a.html");
        let held = patterns.matched(b"static/a.js");

        assert!(vendor.is_some());
        assert!(held.is_some());
        assert_ne!(vendor, held);
        assert!(patterns.matched(b"src/a.rs").is_none());
    }

    #[test]
    fn a_row_range_answers_for_the_patterns_it_spans() {
        let mut patterns = reserved();

        patterns.push(b"vendor").expect("the pattern compiles");

        let first = patterns.count();

        patterns.push(b"static").expect("the pattern compiles");

        let end = patterns.count();

        assert!(patterns.matches_within(first, end, b"static/a.js"));
        assert!(!patterns.matches_within(first, end, b"vendor/a.html"));
        assert!(patterns.matches_within(0, first, b"vendor/a.html"));
    }

    #[test]
    fn a_truncated_set_forgets_the_rows_past_the_mark() {
        let mut patterns = reserved();

        patterns.push(b"vendor").expect("the pattern compiles");

        let mark = patterns.count();
        let tokens = patterns.tokens.count();

        patterns
            .push(b"page[0-9].html")
            .expect("the pattern compiles");

        assert!(patterns.matches(b"page7.html"));
        assert!(patterns.classes.count() > 0);

        patterns.truncate(mark);

        assert_eq!(patterns.count(), mark);
        assert_eq!(patterns.tokens.count(), tokens);
        assert_eq!(patterns.classes.count(), 0);
        assert!(patterns.matches(b"vendor/a.html"));
        assert!(!patterns.matches(b"page7.html"));

        patterns
            .push(b"page[0-9].html")
            .expect("the pattern compiles");

        assert!(patterns.matches(b"page7.html"));
    }

    #[test]
    fn an_empty_pattern_is_refused() {
        let mut patterns = reserved();

        assert_eq!(patterns.push(b""), Err(Error::Empty));
        assert_eq!(patterns.push(b"./"), Err(Error::Empty));
        assert_eq!(patterns.push(b"///"), Err(Error::Empty));
    }

    #[test]
    fn an_unclosed_class_names_where_it_opened() {
        let mut patterns = reserved();
        let refused = patterns.push(b"templates/[");

        assert!(matches!(refused, Err(Error::ClassUnclosed(_))));
        assert!(
            refused
                .expect_err("the pattern is refused")
                .message()
                .contains("character class")
        );
    }

    #[test]
    fn an_unclosed_brace_is_refused() {
        let mut patterns = reserved();

        assert!(matches!(
            patterns.push(b"a/{b,c"),
            Err(Error::BraceUnclosed(_))
        ));
    }

    #[test]
    fn a_trailing_backslash_is_refused() {
        let mut patterns = reserved();

        assert!(matches!(
            patterns.push(br"a\"),
            Err(Error::EscapeUnfinished(_))
        ));
    }

    #[test]
    fn a_double_star_that_is_not_a_whole_component_is_refused() {
        let mut patterns = reserved();

        assert!(matches!(
            patterns.push(b"a/b**c"),
            Err(Error::DoubleStarComponent(_))
        ));
    }

    #[test]
    fn a_set_that_outgrows_its_tables_says_so() {
        let mut patterns = Patterns::reserve(2, 16, 1);
        let mut refused = false;

        for _ in 0_u32..64_u32 {
            if patterns.push(b"templates/deeply/nested/name").is_err() {
                refused = true;

                break;
            }
        }

        assert!(refused);
    }

    #[test]
    fn a_pathological_pattern_still_answers_in_one_pass() {
        let patterns = built(&["**/*a*/**/*b*/**/*c*"]);
        let path = b"a/aaaa/aaaa/aaaa/aaaa/aaaa/aaaa/aaaa/aaaa/aaaa/aaaa/aaaa/aaaa/aaaa";

        assert!(!patterns.matches(path));
    }

    #[test]
    fn matching_allocates_nothing() {
        let patterns = built(&["vendor", "**/admin/*.html", "*.{css,js}"]);

        allocation::frozen(|| {
            assert!(patterns.matches(b"app/vendor/page.html"));
            assert!(patterns.matches(b"t/admin/list.html"));
            assert!(patterns.matches(b"static/app.css"));
            assert!(!patterns.matches(b"src/main.rs"));
        });
    }

    #[test]
    fn a_windows_separator_bounds_a_component_only_on_windows() {
        let patterns = built(&["*.rs"]);
        let nested = built(&["src/*.rs"]);

        assert_eq!(!patterns.matches(br"src\main.rs"), cfg!(windows));
        assert_eq!(nested.matches(br"src\main.rs"), cfg!(windows));
        assert_eq!(!patterns.matches_walked(br"src\main.rs"), cfg!(windows));
        assert_eq!(nested.matches_walked(br"src\main.rs"), cfg!(windows));
    }

    #[test]
    fn a_shaped_row_answers_the_same_as_the_walk() {
        for shape in SHAPES {
            let patterns = built(&[shape]);

            for path in PATHS {
                assert_eq!(
                    patterns.matches(path),
                    patterns.matches_walked(path),
                    "{shape} shaped and walked disagree on {}",
                    str::from_utf8(path).expect("every corpus path is text"),
                );
            }
        }
    }
}
