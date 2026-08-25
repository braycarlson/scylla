use crate::bounded::{Buffer, Bytes as _, Span, count_of};
use crate::format::ir::{Document, Element, Source as ElementSource};
use crate::format::print::{self, Options};
use crate::language::Lexer as _;
use crate::lex::PYTHON;
use crate::suppress::{Pragma, PragmaAt};
use crate::syntax::python::kind::PythonKind as Kind;
use crate::syntax::python::style::LineEnding;
use crate::token::{Lex, Token, TokenKind, Tokens};
use crate::tree::{NONE, Structure, Tree};

pub const BRACKET_DEPTH_MAX: u32 = 64;
const COMMA: &[u8] = b",";
const DOUBLE: &[u8] = b"\"";
const GAP: &[u8] = b"  ";
const PAREN_CLOSE: &[u8] = b")";
const PAREN_OPEN: &[u8] = b" (";
const TRIPLE_DOUBLE: &[u8] = b"\"\"\"";
const SINGLE: &[u8] = b"'";
const TRIPLE_SINGLE: &[u8] = b"'''";

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Outcome {
    Complete,
    Overflow,
    Refusal,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum QuotePreference {
    Double,
    Preserve,
    Single,
}

pub struct Input<'held> {
    pub line_ending: LineEnding,
    pub magic_trailing_comma: bool,
    pub options: Options,
    pub outcome: Structure,
    pub pragmas: &'held [PragmaAt],
    pub quote: QuotePreference,
    pub raw: &'held [Kind],
    pub source: &'held [u8],
    pub tokens: &'held [Token],
    pub tree: &'held Tree<Kind>,
}

impl Input<'_> {
    pub const DEFAULTS: (LineEnding, bool, QuotePreference) =
        (LineEnding::LineFeed, true, QuotePreference::Double);
}

#[derive(Clone, Copy, Debug)]
struct Frame {
    annotated: bool,
    call: bool,
    commas: bool,
    kind: Kind,
    magic: bool,
    magic_source: bool,
}

#[derive(Debug)]
pub struct Formatter {
    arena: Buffer,
    close: u32,
    comma: u32,
    document: Document,
    gap: u32,
    open: u32,
}

struct Emitter<'held> {
    after: bool,
    arena: &'held mut Buffer,
    at_lambda: u32,
    at_previous: u32,
    blocks: [bool; BRACKET_DEPTH_MAX as usize],
    depth: u32,
    document: &'held mut Document,
    frames: [Frame; BRACKET_DEPTH_MAX as usize],
    indent: u32,
    indent_width: u32,
    line_first: Option<Kind>,
    line_first_at: u32,
    literals: (u32, u32),
    magic_trailing_comma: bool,
    opened: bool,
    parentheses: (u32, u32),
    pending_break: bool,
    pragmas: &'held [PragmaAt],
    previous: Option<Kind>,
    quote: QuotePreference,
    raw: &'held [Kind],
    skip: u32,
    source: &'held [u8],
    starting: bool,
    suppress_space: bool,
    tokens: &'held [Token],
    until: u32,
    wrap: u32,
}

const fn ends_operand(kind: Kind) -> bool {
    matches!(
        kind,
        Kind::BraceClose
            | Kind::BracketClose
            | Kind::Ellipsis
            | Kind::FStringEnd
            | Kind::FalseKeyword
            | Kind::Identifier
            | Kind::NoneKeyword
            | Kind::NumberBinary
            | Kind::NumberComplex
            | Kind::NumberFloat
            | Kind::NumberHexadecimal
            | Kind::NumberInteger
            | Kind::NumberOctal
            | Kind::ParenClose
            | Kind::StringBytes
            | Kind::StringFormat
            | Kind::StringPlain
            | Kind::TrueKeyword
    )
}

fn shared_indent(text: &[u8]) -> Option<u32> {
    let count = count_of(text.split(|byte| *byte == b'\n').count());
    let mut common = u32::MAX;

    for (index, line) in text.split(|byte| *byte == b'\n').enumerate().skip(1) {
        let trimmed = line.trim_ascii_end();

        if trimmed.is_empty() {
            continue;
        }

        if trimmed[0] == b'\t' {
            return None;
        }

        if closes(trimmed) && count_of(index) == count - 1 {
            continue;
        }

        common = common.min(count_of(trimmed.len() - trimmed.trim_ascii_start().len()));
    }

    if common == u32::MAX {
        return Some(0);
    }

    Some(common)
}

fn closes(line: &[u8]) -> bool {
    let held = line.trim_ascii_start();

    held == TRIPLE_DOUBLE || held == TRIPLE_SINGLE
}

const fn is_binary(kind: Kind) -> bool {
    matches!(
        kind,
        Kind::Ampersand
            | Kind::AndKeyword
            | Kind::Bar
            | Kind::Caret
            | Kind::GreaterGreater
            | Kind::InKeyword
            | Kind::IsKeyword
            | Kind::LessLess
            | Kind::Minus
            | Kind::OrKeyword
            | Kind::Percent
            | Kind::Plus
            | Kind::Slash
            | Kind::SlashSlash
            | Kind::Star
            | Kind::StarStar
    )
}

const fn is_close(kind: Kind) -> bool {
    matches!(
        kind,
        Kind::BraceClose | Kind::BracketClose | Kind::ParenClose
    )
}

const fn is_layout(kind: Kind) -> bool {
    matches!(kind, Kind::Dedent | Kind::Indent | Kind::Newline)
}

const fn is_open(kind: Kind) -> bool {
    matches!(kind, Kind::BraceOpen | Kind::BracketOpen | Kind::ParenOpen)
}

const fn opened_by(close: Kind) -> Kind {
    if matches!(close, Kind::BraceClose) {
        return Kind::BraceOpen;
    }

    if matches!(close, Kind::BracketClose) {
        return Kind::BracketOpen;
    }

    Kind::ParenOpen
}

fn quoted(bytes: &[u8], wanted: u8) -> Option<usize> {
    let mut offset = 0;

    while offset < bytes.len() && bytes[offset] != b'"' && bytes[offset] != b'\'' {
        offset += 1;
    }

    if offset == bytes.len() || bytes[offset] == wanted {
        return None;
    }

    Some(offset)
}

fn requoted(bytes: &[u8], preference: QuotePreference) -> Option<(&[u8], &[u8], &'static [u8])> {
    let wanted = match preference {
        QuotePreference::Double => b'"',
        QuotePreference::Preserve => return None,
        QuotePreference::Single => b'\'',
    };

    let at = quoted(bytes, wanted)?;
    let (prefix, rest) = bytes.split_at(at);
    let triple = rest.starts_with(TRIPLE_SINGLE) || rest.starts_with(TRIPLE_DOUBLE);

    let quote: &'static [u8] = match (wanted, triple) {
        (b'"', true) => TRIPLE_DOUBLE,
        (b'"', false) => DOUBLE,
        (_, true) => TRIPLE_SINGLE,
        (_, false) => SINGLE,
    };

    let width = quote.len();

    if rest.len() < width * 2 {
        return None;
    }

    let body = &rest[width..rest.len() - width];

    let clashes = if triple {
        body.ends_with(&[wanted])
            || body.windows(width).any(|run| run == quote)
            || body.windows(2).any(|run| run == [b'\\', wanted])
    } else {
        body.contains(&wanted) || body.contains(&b'\\')
    };

    if clashes {
        return None;
    }

    Some((prefix, body, quote))
}

fn quote_edges(
    bytes: &[u8],
    offset: u32,
    preference: QuotePreference,
) -> Option<(u32, u32, &'static [u8])> {
    let (prefix, body, quote) = requoted(bytes, preference)?;
    let at = offset + count_of(prefix.len());

    Some((at, at + count_of(quote.len() + body.len()), quote))
}

const fn is_word(kind: TokenKind) -> bool {
    matches!(
        kind,
        TokenKind::Identifier | TokenKind::Keyword(_) | TokenKind::Number | TokenKind::String
    )
}

fn words_before(tokens: &[Token], position: u32) -> u32 {
    let mut found = 0;

    for token in &tokens[..(position as usize).min(tokens.len())] {
        if is_word(token.kind) {
            found += 1;
        }
    }

    found
}

fn statements_of(input: &Input<'_>, range: Span) -> Option<(u32, u32)> {
    if input.tree.count() == 0 {
        return None;
    }

    let mut first = NONE;
    let mut last = NONE;
    let mut child = input.tree.at(0).child_first;

    while child != NONE {
        let held = input.tree.at(child);
        let span = held.span(input.tokens);

        if span.offset < range.end() && range.offset < span.end().max(span.offset + 1) {
            if first == NONE {
                first = child;
            }

            last = child;
        }

        child = held.sibling_next;
    }

    if first == NONE {
        return None;
    }

    Some((first, last))
}

fn word_span(tokens: &[Token], before: u32, after: u32) -> Option<Span> {
    assert!(after >= before);

    let (first, last) = word_positions(tokens, before, after)?;
    let offset = tokens[line_start_of(tokens, first)].offset;
    let close = tokens[line_end_of(tokens, last)].end();

    assert!(close >= offset);

    Some(Span {
        length: close - offset,
        offset,
    })
}

fn word_positions(tokens: &[Token], before: u32, after: u32) -> Option<(usize, usize)> {
    let mut seen = 0;
    let mut first = None;
    let mut last = None;

    for (position, token) in tokens.iter().enumerate() {
        if !is_word(token.kind) {
            continue;
        }

        if seen == before {
            first = Some(position);
        }

        seen += 1;

        if seen == after {
            last = Some(position);

            break;
        }
    }

    Some((first?, last?))
}

fn line_start_of(tokens: &[Token], position: usize) -> usize {
    let mut start = position;

    for _ in 0..position {
        if start == 0 {
            break;
        }

        if is_line_edge(tokens[start - 1].kind) {
            break;
        }

        start -= 1;
    }

    start
}

fn line_end_of(tokens: &[Token], position: usize) -> usize {
    let mut end = position;

    for _ in position..tokens.len() {
        if tokens[end].kind == TokenKind::Newline || end + 1 == tokens.len() {
            break;
        }

        end += 1;
    }

    end
}

const fn is_line_edge(kind: TokenKind) -> bool {
    matches!(
        kind,
        TokenKind::BlockEnd | TokenKind::BlockStart | TokenKind::Newline
    )
}

fn source_span(input: &Input<'_>, first: u32, last: u32) -> Span {
    let opened = input.tree.at(first).span(input.tokens);
    let closed = input.tree.at(last).span(input.tokens);
    let mut end = closed.end() as usize;

    while end < input.source.len() && matches!(input.source[end], b'\t' | b' ') {
        end += 1;
    }

    if input.source.get(end) == Some(&b'#') {
        while end < input.source.len() && !matches!(input.source[end], b'\n' | b'\r') {
            end += 1;
        }
    }

    if input.source.get(end) == Some(&b'\r') {
        end += 1;
    }

    if input.source.get(end) == Some(&b'\n') {
        end += 1;
    }

    Span {
        length: count_of(end) - opened.offset,
        offset: opened.offset,
    }
}

fn balanced(raw: &[Kind]) -> bool {
    let mut depth = 0;
    let mut stack = [Kind::ParenOpen; BRACKET_DEPTH_MAX as usize];

    for kind in raw {
        if is_open(*kind) {
            if depth == BRACKET_DEPTH_MAX {
                return false;
            }

            stack[depth as usize] = *kind;
            depth += 1;

            continue;
        }

        if !is_close(*kind) {
            continue;
        }

        if depth == 0 || stack[depth as usize - 1] != opened_by(*kind) {
            return false;
        }

        depth -= 1;
    }

    depth == 0
}

fn broken(input: &Input<'_>) -> bool {
    if input.raw.contains(&Kind::ErrorToken) {
        return true;
    }

    if !balanced(input.raw) {
        return true;
    }

    input
        .tree
        .as_slice()
        .iter()
        .any(|node| node.kind == Kind::ErrorNode)
}

fn blank_lines(source: &[u8], from: u32, to: u32) -> u32 {
    assert!(from <= to);
    assert!(to as usize <= source.len());

    let mut breaks = 0_u32;

    for byte in &source[from as usize..to as usize] {
        if *byte == b'\n' {
            breaks += 1;
        }
    }

    breaks
}

impl Formatter {
    pub fn reserve(element_count_max: u32, arena_bytes_max: u32) -> Self {
        assert!(element_count_max > 0);
        assert!(arena_bytes_max > 0);

        assert!(!crate::allocation::is_frozen());

        let mut document = Document::reserve(element_count_max, 4);
        let comma = document.literal(COMMA);
        let gap = document.literal(GAP);
        let open = document.literal(PAREN_OPEN);
        let close = document.literal(PAREN_CLOSE);

        Self {
            arena: Buffer::reserve(arena_bytes_max),
            close,
            comma,
            document,
            gap,
            open,
        }
    }

    pub fn document(&self) -> &Document {
        &self.document
    }

    #[must_use]
    pub fn format(&mut self, input: &Input<'_>, out: &mut Buffer) -> Outcome {
        assert_eq!(input.tokens.len(), input.raw.len());
        debug_assert!(input.pragmas.is_sorted_by_key(|held| held.span.offset));

        if input.outcome != Structure::Complete || !input.tree.errors().is_empty() {
            return Outcome::Refusal;
        }

        if broken(input) {
            return Outcome::Refusal;
        }

        self.arena.clear();
        self.document.clear();

        let mut emitter = Emitter {
            after: false,
            arena: &mut self.arena,
            at_lambda: NONE,
            at_previous: NONE,
            blocks: [false; BRACKET_DEPTH_MAX as usize],
            depth: 0,
            document: &mut self.document,
            frames: [Frame {
                annotated: false,
                call: false,
                commas: false,
                kind: Kind::ParenOpen,
                magic: false,
                magic_source: false,
            }; BRACKET_DEPTH_MAX as usize],
            indent: 0,
            indent_width: input.options.indent_width,
            magic_trailing_comma: input.magic_trailing_comma,
            pragmas: input.pragmas,
            quote: input.quote,
            line_first: None,
            line_first_at: NONE,
            literals: (self.comma, self.gap),
            parentheses: (self.open, self.close),
            wrap: NONE,
            opened: false,
            pending_break: false,
            previous: None,
            skip: NONE,
            starting: false,
            until: 0,
            raw: input.raw,
            source: input.source,
            suppress_space: false,
            tokens: input.tokens,
        };

        if !emitter.run() {
            return Outcome::Overflow;
        }

        if !print::print(
            &self.document,
            input.source,
            self.arena.as_bytes(),
            input.options,
            out,
        ) {
            return Outcome::Overflow;
        }

        self.reline(input.line_ending, out)
    }

    fn reline(&mut self, ending: LineEnding, out: &mut Buffer) -> Outcome {
        if ending == LineEnding::LineFeed && !out.as_bytes().contains(&b'\r') {
            return Outcome::Complete;
        }

        self.arena.clear();

        if !self.arena.push_bytes(out.as_bytes()) {
            return Outcome::Overflow;
        }

        out.clear();

        let bytes = self.arena.as_bytes();
        let mut offset = 0;

        for _ in 0..bytes.len() {
            if offset >= bytes.len() {
                break;
            }

            let width = crate::scan::line_break_width(bytes, offset);

            let written = if width > 0 {
                out.push_bytes(ending.bytes())
            } else {
                out.push_bytes(&bytes[offset..=offset])
            };

            if !written {
                return Outcome::Overflow;
            }

            offset += width.max(1);
        }

        assert_eq!(offset, bytes.len());

        Outcome::Complete
    }

    #[must_use]
    pub fn format_range(
        &mut self,
        input: &Input<'_>,
        range: Span,
        scratch: &mut Buffer,
        lexed: &mut Tokens,
        out: &mut Buffer,
    ) -> Option<Span> {
        if self.format(input, scratch) != Outcome::Complete {
            return None;
        }

        let (first, last) = statements_of(input, range)?;
        let before = words_before(input.tokens, input.tree.at(first).token_start);
        let after = words_before(input.tokens, input.tree.at(last).token_end);

        lexed.clear();

        if PYTHON.lex(scratch.as_bytes(), lexed) != Lex::Complete {
            return None;
        }

        let held = word_span(lexed.as_slice(), before, after)?;

        out.clear();

        if !out.push_bytes(&scratch.as_bytes()[held.range()]) {
            return None;
        }

        Some(source_span(input, first, last))
    }

    #[must_use]
    pub fn range(
        &mut self,
        input: &Input<'_>,
        lines: (u32, u32),
        out: &mut Buffer,
    ) -> Option<Span> {
        assert!(lines.0 <= lines.1);

        if self.format(input, out) != Outcome::Complete {
            return None;
        }

        let bytes = out.as_bytes();
        let mut line = 0;
        let mut offset = 0;
        let mut start = None;
        let mut end = count_of(bytes.len());

        for position in 0..=count_of(bytes.len()) {
            if line == lines.0 && start.is_none() {
                start = Some(offset);
            }

            if line == lines.1 + 1 {
                end = offset;

                break;
            }

            if position as usize == bytes.len() {
                break;
            }

            if bytes[position as usize] == b'\n' {
                line += 1;
                offset = position + 1;
            }
        }

        let first = start?;

        assert!(end >= first);

        Some(Span {
            length: end - first,
            offset: first,
        })
    }
}

impl Emitter<'_> {
    fn break_line(&mut self, position: u32) -> bool {
        let token = self.tokens[position as usize];
        let allowed = if self.indent == 0 { 2 } else { 1 };
        let held = self.blanks_before(position, token.offset).min(allowed);
        let spaced = self.after || self.opens_definition(position);
        let hugged = is_close(self.raw[position as usize]) || self.previous.is_some_and(is_open);

        let blanks = if self.line_first == Some(Kind::At) || self.opened || hugged {
            0
        } else if spaced && self.previous.is_some() {
            allowed
        } else {
            held
        };

        self.after = false;
        self.at_lambda = NONE;
        self.opened = false;
        self.pending_break = false;
        self.suppress_space = false;

        self.document.push(Element::HardLine) && self.document.push(Element::BlankLine(blanks))
    }

    fn close(&mut self, position: u32, kind: Kind) -> bool {
        let held = self.frame();

        if self.depth == 0 || held.kind != opened_by(kind) {
            return self.text(position, false);
        }

        self.depth -= 1;

        let comma = self.document.literal_span(self.literals.0);

        let separator = if held.magic {
            Element::HardLine
        } else {
            Element::SoftLine
        };

        let listed = held.commas || (held.call && held.kind == Kind::ParenOpen);

        if listed && !self.document.push(Element::IfBroken(comma)) {
            return false;
        }

        self.document.push(Element::Dedent)
            && self.document.push(separator)
            && self.text(position, false)
            && self.document.push(Element::GroupClose)
    }

    const fn frame(&self) -> Frame {
        if self.depth == 0 {
            return Frame {
                annotated: false,
                call: false,
                commas: false,
                kind: Kind::ParenOpen,
                magic: false,
                magic_source: false,
            };
        }

        self.frames[self.depth as usize - 1]
    }

    fn blanks_before(&self, position: u32, offset: u32) -> u32 {
        let mut scan = position;

        while scan > 0 {
            scan -= 1;

            let held = self.tokens[scan as usize];

            if held.length == 0 {
                continue;
            }

            let breaks = blank_lines(self.source, held.end(), offset);

            if self.raw[scan as usize] == Kind::Newline {
                return breaks;
            }

            return breaks.saturating_sub(1);
        }

        blank_lines(self.source, 0, offset)
    }

    fn pragma_at(&self, position: u32) -> Option<Pragma> {
        if self.raw[position as usize] != Kind::Comment {
            return None;
        }

        let offset = self.tokens[position as usize].offset;

        self.pragmas
            .binary_search_by_key(&offset, |held| held.span.offset)
            .ok()
            .map(|index| self.pragmas[index].kind)
    }

    fn region_end(&self, position: u32) -> u32 {
        if !self.pending_break && self.previous.is_some() {
            return NONE;
        }

        if self.pragma_at(position) == Some(Pragma::FormatOff) {
            return self.format_off_end(position);
        }

        self.format_skip_end(position)
    }

    fn format_off_end(&self, position: u32) -> u32 {
        let column = self.line_indent(self.tokens[position as usize].offset);
        let count = count_of(self.tokens.len());
        let mut scan = position + 1;
        let mut last = position;

        while scan < count {
            let kind = self.raw[scan as usize];

            if is_layout(kind) {
                last = scan;
                scan += 1;

                continue;
            }

            let held = self.line_indent(self.tokens[scan as usize].offset);

            if self.pragma_at(scan) == Some(Pragma::FormatOn) && held == column {
                return scan;
            }

            if held < column {
                return last;
            }

            last = scan;
            scan += 1;
        }

        last
    }

    fn line_indent(&self, offset: u32) -> u32 {
        let start = self.line_start(offset);
        let mut held = start;

        while self
            .source
            .get(held as usize)
            .is_some_and(|byte| matches!(*byte, b' ' | b'\t'))
        {
            held += 1;
        }

        held - start
    }

    fn format_skip_end(&self, position: u32) -> u32 {
        let count = count_of(self.tokens.len());
        let mut scan = position;
        let mut found = false;

        while scan < count {
            let kind = self.raw[scan as usize];

            if matches!(kind, Kind::Dedent | Kind::Indent | Kind::Newline) {
                break;
            }

            found = found || self.pragma_at(scan) == Some(Pragma::FormatSkip);
            scan += 1;
        }

        if !found || scan == position {
            return NONE;
        }

        scan - 1
    }

    fn line_start(&self, offset: u32) -> u32 {
        let mut held = offset;

        while held > 0 && self.source[held as usize - 1] != b'\n' {
            held -= 1;
        }

        held
    }

    fn verbatim(&mut self, position: u32, end: u32) -> bool {
        assert!(end >= position);

        let opening = self.region_opening(position, end);

        if !self.region_blocks(position, opening) {
            return false;
        }

        if self.pending_break && !self.break_line(position) {
            return false;
        }

        let offset = self.tokens[position as usize].offset;
        let mut length = self.tokens[end as usize].end() - offset;
        let mut broken = false;

        while length > 0 && self.source[(offset + length - 1) as usize] == b'\n' {
            broken = true;
            length -= 1;
        }

        let held = Span { length, offset };

        self.line_first = Some(self.raw[position as usize]);
        self.pending_break = broken || self.raw[end as usize] == Kind::Comment;
        self.previous = Some(self.raw[end as usize]);
        self.suppress_space = false;
        self.until = end + 1;

        if !self.document.push(Element::Verbatim(held)) {
            return false;
        }

        self.region_blocks(opening, end)
    }

    fn region_opening(&self, position: u32, end: u32) -> u32 {
        let mut scan = position;

        while scan < end {
            if !is_layout(self.raw[(scan + 1) as usize]) {
                return scan;
            }

            scan += 1;
        }

        position
    }

    fn region_blocks(&mut self, position: u32, end: u32) -> bool {
        let held = self.line_first;
        let mut scan = position + 1;

        while scan <= end && scan < count_of(self.tokens.len()) {
            let kind = self.raw[scan as usize];

            if kind == Kind::Indent {
                self.line_first = Some(self.line_opener(scan));

                if !self.indented() {
                    return false;
                }
            }

            if kind == Kind::Dedent {
                if self.indent == 0 {
                    return false;
                }

                self.indent -= 1;
                self.after = self.after || self.blocks[self.indent as usize];
                self.opened = false;

                if !self.document.push(Element::Dedent) {
                    return false;
                }
            }

            scan += 1;
        }

        self.line_first = held;

        true
    }

    fn line_opener(&self, position: u32) -> Kind {
        let mut scan = position;

        while scan > 0 {
            scan -= 1;

            if !is_layout(self.raw[scan as usize]) && self.raw[scan as usize] != Kind::Comment {
                break;
            }
        }

        while scan > 0 {
            let kind = self.raw[scan as usize - 1];

            if is_layout(kind) || kind == Kind::Comment {
                break;
            }

            scan -= 1;
        }

        self.raw[scan as usize]
    }

    fn fstring(&mut self, position: u32) -> bool {
        let count = count_of(self.tokens.len());
        let mut depth = 0;
        let mut scan = position;
        let mut end = position;

        while scan < count {
            let kind = self.raw[scan as usize];

            if kind == Kind::FStringStart {
                depth += 1;
            }

            if kind == Kind::FStringEnd {
                depth -= 1;

                if depth == 0 {
                    end = scan;

                    break;
                }
            }

            scan += 1;
        }

        assert!(end >= position);

        let own_line = self.pending_break || self.previous.is_none();

        if self.pending_break && !self.break_line(position) {
            return false;
        }

        if own_line {
            self.line_first = Some(Kind::FStringStart);
        }

        if self.spaced(Kind::FStringStart) && !self.document.push(Element::Space) {
            return false;
        }

        let offset = self.tokens[position as usize].offset;

        let held = Span {
            length: self.tokens[end as usize].end() - offset,
            offset,
        };

        self.previous = Some(Kind::FStringEnd);
        self.suppress_space = false;
        self.until = end + 1;

        self.document.push(Element::Verbatim(held))
    }

    fn hoist(&mut self, position: u32) -> bool {
        let count = count_of(self.tokens.len());
        let mut scan = position;

        while scan < count {
            let kind = self.raw[scan as usize];

            if kind == Kind::Indent {
                self.skip = scan;

                return true;
            }

            if !matches!(kind, Kind::Comment | Kind::Newline) {
                return false;
            }

            scan += 1;
        }

        false
    }

    fn indented(&mut self) -> bool {
        if self.indent == BRACKET_DEPTH_MAX {
            return false;
        }

        self.blocks[self.indent as usize] = matches!(
            self.line_first,
            Some(Kind::AsyncKeyword | Kind::At | Kind::ClassKeyword | Kind::DefKeyword)
        );

        self.indent += 1;
        self.opened = true;

        self.document.push(Element::Indent)
    }

    fn opens_definition(&self, position: u32) -> bool {
        matches!(
            self.raw[position as usize],
            Kind::AsyncKeyword | Kind::At | Kind::ClassKeyword | Kind::DefKeyword
        )
    }

    fn mark(&mut self, kind: Kind) {
        if kind == Kind::LambdaKeyword {
            self.at_lambda = self.depth;

            return;
        }

        if kind != Kind::Colon {
            return;
        }

        if self.at_lambda == self.depth {
            self.at_lambda = NONE;
        }

        if self.depth > 0 {
            self.frames[self.depth as usize - 1].annotated = true;
        }
    }

    fn magic_of(&self, position: u32, call: bool) -> bool {
        let count = count_of(self.tokens.len());
        let open = self.raw[position as usize];
        let mut commas = 0;
        let mut depth = 0;
        let mut previous = None;
        let mut scan = position;

        while scan < count {
            let kind = self.raw[scan as usize];

            scan += 1;

            if is_open(kind) {
                depth += 1;

                continue;
            }

            if is_close(kind) {
                depth -= 1;

                if depth == 0 {
                    if open == Kind::ParenOpen && !call && commas == 1 {
                        return false;
                    }

                    return opened_by(kind) == open && previous == Some(Kind::Comma);
                }

                continue;
            }

            if kind == Kind::Comma && depth == 1 {
                commas += 1;
            }

            if !is_layout(kind) {
                previous = Some(kind);
            }
        }

        false
    }

    fn open(&mut self, position: u32, kind: Kind) -> bool {
        if self.depth == BRACKET_DEPTH_MAX {
            return self.text(position, false);
        }

        let call = self.previous.is_some_and(ends_operand);
        let magic_source = self.magic_of(position, call);
        let magic = self.magic_trailing_comma && magic_source;

        self.frames[self.depth as usize] = Frame {
            annotated: false,
            call,
            commas: false,
            kind,
            magic,
            magic_source,
        };

        self.depth += 1;

        let separator = if magic {
            Element::HardLine
        } else {
            Element::SoftLine
        };

        self.document.push(Element::GroupOpen)
            && self.text(position, false)
            && self.document.push(Element::Indent)
            && self.document.push(separator)
    }

    fn requote(&mut self, span: Span, preference: QuotePreference) -> Option<Span> {
        let (prefix, body, quote) = requoted(&self.source[span.range()], preference)?;
        let offset = self.arena.count();

        let written = self.arena.push_bytes(prefix)
            && self.arena.push_bytes(quote)
            && self.arena.push_bytes(body)
            && self.arena.push_bytes(quote);

        if !written {
            self.arena.truncate(offset);

            return None;
        }

        Some(Span {
            length: self.arena.count() - offset,
            offset,
        })
    }

    fn step(&mut self, position: u32, kind: Kind, written: &mut bool) -> bool {
        if kind == Kind::Dedent {
            self.indent -= 1;
            self.after = self.after || self.blocks[self.indent as usize];

            return self.document.push(Element::Dedent);
        }

        if kind == Kind::Indent {
            return self.indented();
        }

        if kind == Kind::Newline {
            if position == self.wrap && !self.unwrap() {
                return false;
            }

            self.pending_break = *written;

            return true;
        }

        *written = true;

        self.token(position, kind)
    }

    fn wide(&mut self, position: u32, kind: Kind) -> Option<bool> {
        let region = self.region_end(position);

        if region != NONE {
            return Some(self.verbatim(position, region));
        }

        if kind == Kind::FStringStart {
            return Some(self.fstring(position));
        }

        None
    }

    fn run(&mut self) -> bool {
        let count = count_of(self.tokens.len());
        let mut written = false;

        for position in 0..count {
            let kind = self.raw[position as usize];

            if position < self.until {
                continue;
            }

            if position == self.skip {
                self.skip = NONE;

                continue;
            }

            match self.wide(position, kind) {
                None => {}
                Some(false) => return false,
                Some(true) => {
                    written = true;

                    continue;
                }
            }

            if kind == Kind::Comment
                && self.skip == NONE
                && self.hoist(position)
                && !self.indented()
            {
                return false;
            }

            if !self.step(position, kind, &mut written) {
                return false;
            }
        }

        while self.depth > 0 {
            self.depth -= 1;

            if !self.document.push(Element::Dedent) || !self.document.push(Element::GroupClose) {
                return false;
            }
        }

        while self.indent > 0 {
            self.indent -= 1;

            if !self.document.push(Element::Dedent) {
                return false;
            }
        }

        if !written {
            return true;
        }

        self.document.push(Element::HardLine)
    }

    fn separator(&mut self, position: u32) -> bool {
        let held = self.frame();

        if self.depth == 0 {
            return self.text(position, false);
        }

        self.frames[self.depth as usize - 1].annotated = false;
        self.frames[self.depth as usize - 1].commas = true;

        if self.trails(position) {
            if held.magic || (!self.magic_trailing_comma && held.magic_source) {
                return true;
            }

            return self.text(position, false);
        }

        let separator = if held.magic {
            Element::HardLine
        } else {
            Element::Line
        };

        self.text(position, false) && self.document.push(separator)
    }

    fn spaced(&self, current: Kind) -> bool {
        let Some(previous) = self.previous else {
            return false;
        };

        if self.suppress_space || is_open(previous) {
            return false;
        }

        if current == Kind::Dot {
            return !ends_operand(previous) && previous != Kind::Dot;
        }

        if previous == Kind::Dot {
            return current == Kind::ImportKeyword;
        }

        if previous == Kind::Ellipsis && self.line_first == Some(Kind::FromKeyword) {
            return current == Kind::ImportKeyword;
        }

        if matches!(current, Kind::Colon | Kind::Comma | Kind::Semicolon) || is_close(current) {
            return false;
        }

        if current == Kind::Star && previous == Kind::ExceptKeyword {
            return false;
        }

        if matches!(current, Kind::BracketOpen | Kind::ParenOpen) {
            return self.soft_keyword() || !ends_operand(previous);
        }

        let held = self.frame();

        if previous == Kind::Colon && held.kind == Kind::BracketOpen && held.call {
            return false;
        }

        if (previous == Kind::Equal || current == Kind::Equal) && self.unspaced_default() {
            return false;
        }

        if current == Kind::StarStar && ends_operand(previous) {
            return false;
        }

        true
    }

    fn text(&mut self, position: u32, spaced: bool) -> bool {
        let kind = self.raw[position as usize];

        self.at_previous = position;
        let span = self.tokens[position as usize].span();

        if spaced && !self.document.push(Element::Space) {
            return false;
        }

        self.suppress_space = self.suppresses(kind);
        self.previous = Some(kind);

        self.mark(kind);

        if span.length == 0 {
            return true;
        }

        if kind == Kind::StringPlain && self.documents(position) {
            return self.docstring(span);
        }

        if matches!(kind, Kind::StringBytes | Kind::StringPlain) {
            if let Some(held) = self.requote(span, self.quote) {
                return self
                    .document
                    .push(Element::Text(ElementSource::Arena, held));
            }
        }

        if self.source[span.range()].contains(&b'\n') {
            return self.document.push(Element::Verbatim(span));
        }

        self.document
            .push(Element::Text(ElementSource::Document, span))
    }

    fn docstring(&mut self, span: Span) -> bool {
        let preference = if self.quote == QuotePreference::Preserve {
            QuotePreference::Preserve
        } else {
            QuotePreference::Double
        };

        if !self.source[span.range()].contains(&b'\n') {
            if let Some(held) = self.requote(span, preference) {
                return self
                    .document
                    .push(Element::Text(ElementSource::Arena, held));
            }

            return self
                .document
                .push(Element::Text(ElementSource::Document, span));
        }

        let Some(held) = self.reindented(span) else {
            return self.document.push(Element::Verbatim(span));
        };

        self.requote_arena(held, preference);

        self.document.push(Element::VerbatimArena(held))
    }

    fn requote_arena(&mut self, held: Span, preference: QuotePreference) {
        let bytes = &self.arena.as_bytes()[held.range()];

        let Some((at, close, quote)) = quote_edges(bytes, held.offset, preference) else {
            return;
        };

        assert_eq!(close + count_of(quote.len()), held.end());
        assert!(self.arena.patch(at, quote));
        assert!(self.arena.patch(close, quote));
    }

    fn documents(&self, position: u32) -> bool {
        if !self.starting {
            return false;
        }

        let count = count_of(self.tokens.len());
        let mut scan = position + 1;

        while scan < count {
            let kind = self.raw[scan as usize];

            if kind == Kind::Comment {
                scan += 1;

                continue;
            }

            if !is_layout(kind) {
                return false;
            }

            break;
        }

        let mut back = position;

        while back > 0 {
            back -= 1;

            let kind = self.raw[back as usize];

            if is_layout(kind) || kind == Kind::Comment {
                continue;
            }

            return kind == Kind::Colon && self.defines(back);
        }

        true
    }

    fn defines(&self, position: u32) -> bool {
        let mut back = position;

        while back > 0 {
            back -= 1;

            let kind = self.raw[back as usize];

            if kind == Kind::Newline || kind == Kind::Indent || kind == Kind::Dedent {
                return self.opens_definition(back + 1);
            }
        }

        self.opens_definition(0)
    }

    fn reindented(&mut self, span: Span) -> Option<Span> {
        let text = &self.source[span.range()];
        let common = shared_indent(text)?;
        let width = self.indent * self.indent_width;
        let offset = self.arena.count();
        let mut written = true;
        let count = count_of(text.split(|byte| *byte == b'\n').count());

        for (index, line) in text.split(|byte| *byte == b'\n').enumerate() {
            if index == 0 {
                written = written && self.arena.push_bytes(line);

                continue;
            }

            written = written && self.arena.push_bytes(b"\n");

            let trimmed = line.trim_ascii_end();

            if trimmed.is_empty() {
                continue;
            }

            let lead = if closes(trimmed) && count_of(index) == count - 1 {
                width
            } else {
                count_of(trimmed.len() - trimmed.trim_ascii_start().len()).saturating_sub(common)
                    + width
            };

            for _ in 0..lead {
                written = written && self.arena.push_bytes(b" ");
            }

            written = written && self.arena.push_bytes(trimmed.trim_ascii_start());
        }

        if !written {
            self.arena.truncate(offset);

            return None;
        }

        Some(Span {
            length: self.arena.count() - offset,
            offset,
        })
    }

    fn wraps(&self, position: u32) -> bool {
        if self.depth > 0 || self.at_lambda != NONE {
            return false;
        }

        let count = count_of(self.tokens.len());
        let mut scan = position + 1;
        let mut operands = 0;
        let mut operators = 0;

        while scan < count {
            let kind = self.raw[scan as usize];

            if kind == Kind::Newline {
                break;
            }

            if is_open(kind) || is_close(kind) || is_layout(kind) {
                return false;
            }

            if matches!(kind, Kind::Comment | Kind::Semicolon | Kind::LambdaKeyword) {
                return false;
            }

            if self.source[self.tokens[scan as usize].span().range()].contains(&b'\n') {
                return false;
            }

            if is_binary(kind) {
                operators += 1;
            }

            if ends_operand(kind) {
                operands += 1;
            }

            scan += 1;
        }

        operators > 0 && operands > operators
    }

    fn line_end(&self, position: u32) -> u32 {
        let count = count_of(self.tokens.len());
        let mut scan = position + 1;

        while scan < count {
            if self.raw[scan as usize] == Kind::Newline {
                return scan;
            }

            scan += 1;
        }

        count
    }

    fn wrap(&mut self, position: u32) -> bool {
        let open = self.document.literal_span(self.parentheses.0);

        self.wrap = self.line_end(position);

        self.document.push(Element::GroupOpen)
            && self.document.push(Element::IfBroken(open))
            && self.document.push(Element::Indent)
            && self.document.push(Element::SoftLine)
    }

    fn unwrap(&mut self) -> bool {
        let close = self.document.literal_span(self.parentheses.1);

        self.wrap = NONE;

        self.document.push(Element::Dedent)
            && self.document.push(Element::SoftLine)
            && self.document.push(Element::IfBroken(close))
            && self.document.push(Element::GroupClose)
    }

    fn soft_keyword(&self) -> bool {
        if self.previous != Some(Kind::Identifier) || self.at_previous != self.line_first_at {
            return false;
        }

        let span = self.tokens[self.at_previous as usize].span();
        let bytes = &self.source[span.range()];

        bytes == b"case" || bytes == b"match"
    }

    fn suppresses(&self, kind: Kind) -> bool {
        if kind == Kind::StarStar || is_open(kind) {
            return true;
        }

        if kind == Kind::Dot {
            return self.previous.is_some_and(ends_operand);
        }

        if kind == Kind::Star && self.previous == Some(Kind::ExceptKeyword) {
            return false;
        }

        if kind == Kind::At && self.starting {
            return true;
        }

        let held = self.frame();

        if kind == Kind::Colon && held.kind == Kind::BracketOpen && held.call {
            return true;
        }

        if kind == Kind::Equal && self.unspaced_default() {
            return true;
        }

        matches!(
            kind,
            Kind::At | Kind::Minus | Kind::Plus | Kind::Star | Kind::Tilde
        ) && !self.previous.is_some_and(ends_operand)
    }

    fn unspaced_default(&self) -> bool {
        if self.at_lambda != NONE {
            return true;
        }

        let held = self.frame();

        held.kind == Kind::ParenOpen && held.call && !held.annotated
    }

    fn token(&mut self, position: u32, kind: Kind) -> bool {
        let own_line = self.pending_break || self.previous.is_none();

        if self.pending_break && !self.break_line(position) {
            return false;
        }

        if own_line {
            self.line_first = Some(kind);
            self.line_first_at = position;
        }

        self.starting = own_line;

        if kind == Kind::Comment {
            let held = if own_line {
                self.text(position, false)
            } else {
                let gap = self.document.literal_span(self.literals.1);

                self.document
                    .push(Element::Text(ElementSource::Literal, gap))
                    && self.text(position, false)
            };

            self.pending_break = true;

            return held;
        }

        if kind == Kind::Semicolon {
            let held = self.text(position, false);

            self.pending_break = true;

            return held;
        }

        if kind == Kind::Comma {
            return self.separator(position);
        }

        if is_open(kind) {
            let spaced = self.spaced(kind);

            if spaced && !self.document.push(Element::Space) {
                return false;
            }

            return self.open(position, kind);
        }

        if is_close(kind) {
            return self.close(position, kind);
        }

        let spaced = self.spaced(kind);

        self.text(position, spaced) && self.wrapped(position, kind)
    }

    fn wrapped(&mut self, position: u32, kind: Kind) -> bool {
        if self.wrap != NONE {
            return true;
        }

        if !matches!(kind, Kind::Equal | Kind::ReturnKeyword) || !self.wraps(position) {
            return true;
        }

        self.wrap(position)
    }

    fn trails(&self, position: u32) -> bool {
        let count = count_of(self.tokens.len());
        let mut scan = position + 1;

        while scan < count {
            let kind = self.raw[scan as usize];

            scan += 1;

            if is_layout(kind) {
                continue;
            }

            return is_close(kind);
        }

        false
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::bounded::BoundedVec;
    use crate::lex::PYTHON;
    use crate::lines;
    use crate::suppress::Pragmas;
    use crate::syntax::python::classify::classify;
    use crate::syntax::python::parse;
    use crate::token::{Token, TokenKind, Tokens};
    use crate::tree::Events;

    fn pragmatic(source: &[u8]) -> String {
        let mut events = Events::reserve(1 << 14);
        let mut formatter = Formatter::reserve(1 << 14, 1 << 16);
        let mut index = lines::Index::reserve(1 << 12);
        let mut lexed = Tokens::reserve(1 << 12);
        let mut out = Buffer::reserve(1 << 14);
        let mut pragmas = Pragmas::reserve(1 << 8);
        let mut raw = BoundedVec::reserve(1 << 12);
        let mut tokens = Tokens::reserve(1 << 12);
        let mut tree = Tree::<Kind>::reserve(1 << 12, 1 << 6);

        PYTHON.lex(source, &mut lexed);

        assert!(classify(source, lexed.as_slice(), &mut tokens, &mut raw));
        assert!(index.build(source));

        let comments: Vec<Span> = lexed
            .as_slice()
            .iter()
            .filter(|token| token.kind == TokenKind::Comment)
            .map(Token::span)
            .collect();

        pragmas.scan(source, comments.iter().copied(), &index);

        let outcome = parse::build(source, tokens.as_slice(), &raw, &mut events, &mut tree);

        let input = Input {
            line_ending: LineEnding::LineFeed,
            magic_trailing_comma: true,
            options: Options::DEFAULT,
            outcome,
            pragmas: pragmas.as_slice(),
            quote: QuotePreference::Double,
            raw: &raw,
            source,
            tokens: tokens.as_slice(),
            tree: &tree,
        };

        assert_eq!(formatter.format(&input, &mut out), Outcome::Complete);

        String::from_utf8_lossy(out.as_bytes()).into_owned()
    }

    #[test]
    fn a_region_spanning_a_block_is_emitted_verbatim() {
        let mut source = Vec::from(b"def held(a):\n".as_slice());

        source.extend_from_slice(b"    # fmt: off\n");
        source.extend_from_slice(b"    if a:\n");
        source.extend_from_slice(b"          b = [1,2,\n");
        source.extend_from_slice(b"     3]\n");
        source.extend_from_slice(b"    # fmt: on\n");
        source.extend_from_slice(b"    c = [1,2]\n");

        let mut expected = String::from("def held(a):\n");

        expected.push_str("    # fmt: off\n");
        expected.push_str("    if a:\n");
        expected.push_str("          b = [1,2,\n");
        expected.push_str("     3]\n");
        expected.push_str("    # fmt: on\n");
        expected.push_str("    c = [1, 2]\n");

        assert_eq!(pragmatic(&source), expected);
    }

    #[test]
    fn an_unbalanced_region_closes_at_its_dedent() {
        let mut source = Vec::from(b"def held(a):\n".as_slice());

        source.extend_from_slice(b"    # fmt: off\n");
        source.extend_from_slice(b"    if a:\n");
        source.extend_from_slice(b"          b = [1,2,\n");
        source.extend_from_slice(b"     3]\n");
        source.extend_from_slice(b"\n");
        source.extend_from_slice(b"\n");
        source.extend_from_slice(b"c = [1,2]\n");

        let mut expected = String::from("def held(a):\n");

        expected.push_str("    # fmt: off\n");
        expected.push_str("    if a:\n");
        expected.push_str("          b = [1,2,\n");
        expected.push_str("     3]\n");
        expected.push('\n');
        expected.push('\n');
        expected.push_str("c = [1, 2]\n");

        assert_eq!(pragmatic(&source), expected);
    }

    fn formatted(source: &[u8]) -> String {
        let mut events = Events::reserve(1 << 14);
        let mut formatter = Formatter::reserve(1 << 14, 1 << 16);
        let mut lexed = Tokens::reserve(1 << 12);
        let mut out = Buffer::reserve(1 << 14);
        let mut raw = BoundedVec::reserve(1 << 12);
        let mut tokens = Tokens::reserve(1 << 12);
        let mut tree = Tree::<Kind>::reserve(1 << 12, 1 << 6);

        PYTHON.lex(source, &mut lexed);

        assert!(classify(source, lexed.as_slice(), &mut tokens, &mut raw));

        let outcome = parse::build(source, tokens.as_slice(), &raw, &mut events, &mut tree);

        let input = Input {
            line_ending: LineEnding::LineFeed,
            magic_trailing_comma: true,
            options: Options::DEFAULT,
            outcome,
            pragmas: &[],
            quote: QuotePreference::Double,
            raw: &raw,
            source,
            tokens: tokens.as_slice(),
            tree: &tree,
        };

        assert_eq!(formatter.format(&input, &mut out), Outcome::Complete);

        String::from_utf8_lossy(out.as_bytes()).into_owned()
    }

    #[test]
    fn a_statement_is_spaced_the_way_ruff_spaces_one() {
        assert_eq!(formatted(b"x=1\ny  =  2\n"), "x = 1\ny = 2\n");
        assert_eq!(formatted(b"a=b+c*d\n"), "a = b + c * d\n");
        assert_eq!(formatted(b"a=b**c\n"), "a = b**c\n");
        assert_eq!(formatted(b"a=-b\n"), "a = -b\n");
        assert_eq!(formatted(b"a=x.y.z\n"), "a = x.y.z\n");
        assert_eq!(formatted(b"a=x[1:2]\n"), "a = x[1:2]\n");
        assert_eq!(formatted(b"f(a,b=1,*c,**d)\n"), "f(a, b=1, *c, **d)\n");
    }

    #[test]
    fn a_definition_carries_the_blank_lines_ruff_gives_it() {
        assert_eq!(
            formatted(b"import os\ndef f():\n    pass\n"),
            "import os\n\n\ndef f():\n    pass\n"
        );

        assert_eq!(
            formatted(b"class A:\n\n    def m(self):\n        pass\n"),
            "class A:\n    def m(self):\n        pass\n"
        );
    }

    #[test]
    fn a_line_over_the_width_breaks_inside_its_brackets() {
        let source: &[u8] = b"result = call(argument_one, argument_two, argument_three, \
                              argument_four, argument_five)\n";

        assert_eq!(
            formatted(source),
            "result = call(\n    argument_one,\n    argument_two,\n    argument_three,\n    \
             argument_four,\n    argument_five,\n)\n"
        );
    }

    #[test]
    fn a_magic_trailing_comma_holds_its_brackets_open() {
        assert_eq!(
            formatted(b"x = [\n    1,\n    2,\n]\n"),
            "x = [\n    1,\n    2,\n]\n"
        );

        assert_eq!(formatted(b"x = [1, 2]\n"), "x = [1, 2]\n");
        assert_eq!(formatted(b"y = (1,)\n"), "y = (1,)\n");
    }

    #[test]
    fn a_comment_keeps_its_line_and_its_indentation() {
        assert_eq!(
            formatted(b"def f():\n    # leading\n    return 1  # trailing\n"),
            "def f():\n    # leading\n    return 1  # trailing\n"
        );

        assert_eq!(formatted(b"x = 1 # tight\n"), "x = 1  # tight\n");
    }

    #[test]
    fn a_single_quoted_string_becomes_a_double_quoted_one() {
        assert_eq!(formatted(b"x = 'text'\n"), "x = \"text\"\n");
        assert_eq!(formatted(b"x = 'a \"b\"'\n"), "x = 'a \"b\"'\n");
        assert_eq!(formatted(b"x = f'{y}'\n"), "x = f'{y}'\n");
    }

    #[test]
    fn a_format_string_is_reproduced_byte_for_byte() {
        assert_eq!(
            formatted(b"x = f'{ a!r :>{width}}'\n"),
            "x = f'{ a!r :>{width}}'\n"
        );
    }
}
