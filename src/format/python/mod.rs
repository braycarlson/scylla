use crate::bounded::{Buffer, Bytes as _, Span, count_of};
use crate::format::ir::{Document, Element, Source as ElementSource};
use crate::format::print::{self, Options};
use crate::format::walk::columns;
use crate::language::Lexer as _;
use crate::lex::PYTHON;
use crate::suppress::{Pragma, PragmaAt};
use crate::syntax::python::kind::PythonKind as Kind;
use crate::syntax::python::style::LineEnding;
use crate::token::{Lex, Token, TokenKind, Tokens};
use crate::tree::{NONE, Structure, Tree};

mod literal;

use literal::{
    TRIPLE_DOUBLE,
    TRIPLE_SINGLE,
    body_edges,
    body_escaped,
    body_indent,
    ending_of,
    escapes_of,
    numbered,
    odd_slashes,
    other_quote,
    pragmatic,
    preferring,
    prefix_of,
    prefix_written,
    quote_edges,
    quoted_body,
    relettered,
    requoted,
    settled,
    unescaped,
    wanted_quote,
};

pub const BRACKET_DEPTH_MAX: u32 = 64;
const ELEMENT_DEPTH_MAX: u32 = 8;
const FORMAT_NEST_MAX: usize = 8;
const COMMA: &[u8] = b",";
const GAP: &[u8] = b"  ";
const PAREN_CLOSE: &[u8] = b")";
const PAREN_HEAD: &[u8] = b"(";
const PAREN_OPEN: &[u8] = b" (";

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
    complex: bool,
    group_count: u32,
    hollow: bool,
    hugged: bool,
    kind: Kind,
    level_count: u32,
    levels: [u8; ELEMENT_DEPTH_MAX as usize],
    magic: bool,
    magic_source: bool,
    owes: bool,
    priority: u8,
    sole: bool,
    splits: Splits,
    trailed: bool,
}

const PRIORITY_COMPREHENSION: u8 = 20;
const PRIORITY_COMMA: u8 = 18;
const PRIORITY_TERNARY: u8 = 16;
const PRIORITY_LOGIC: u8 = 14;
const PRIORITY_STRING: u8 = 12;
const PRIORITY_COMPARATOR: u8 = 10;
const PRIORITY_DOT: u8 = 1;

#[derive(Clone, Copy, Debug)]
struct Splits {
    comprehended: bool,
    lambda: bool,
    targeting: bool,
}

impl Frame {
    const fn new() -> Self {
        Self {
            annotated: false,
            call: false,
            commas: false,
            complex: false,
            group_count: 0,
            hollow: false,
            hugged: false,
            kind: Kind::ParenOpen,
            level_count: 0,
            levels: [0; ELEMENT_DEPTH_MAX as usize],
            magic: false,
            magic_source: false,
            owes: false,
            priority: 0,
            sole: false,
            splits: Splits::new(),
            trailed: false,
        }
    }
}

impl Splits {
    const fn new() -> Self {
        Self {
            comprehended: false,
            lambda: false,
            targeting: false,
        }
    }

    fn step(&mut self, kind: Kind, previous: Option<Kind>) -> u8 {
        if kind == Kind::LambdaKeyword {
            self.lambda = true;

            return 0;
        }

        if kind == Kind::Colon {
            self.lambda = false;

            return 0;
        }

        if kind == Kind::AsyncKeyword && previous.is_some_and(ends_operand) {
            self.comprehended = true;
            self.targeting = true;

            return PRIORITY_COMPREHENSION;
        }

        if kind == Kind::ForKeyword {
            self.comprehended = true;
            self.targeting = true;

            return u8::from(previous != Some(Kind::AsyncKeyword)) * PRIORITY_COMPREHENSION;
        }

        if kind == Kind::InKeyword && self.targeting {
            self.targeting = false;

            return 0;
        }

        if kind == Kind::Comma {
            return if self.lambda || self.targeting {
                0
            } else {
                PRIORITY_COMMA
            };
        }

        if kind == Kind::IfKeyword {
            return if self.comprehended {
                PRIORITY_COMPREHENSION
            } else {
                PRIORITY_TERNARY
            };
        }

        parted(kind, previous)
    }
}

const fn prefixes(kind: Kind) -> bool {
    matches!(
        kind,
        Kind::AwaitKeyword
            | Kind::Minus
            | Kind::NotKeyword
            | Kind::Plus
            | Kind::Tilde
            | Kind::YieldKeyword
    )
}

fn parted(kind: Kind, previous: Option<Kind>) -> u8 {
    let Some(held) = previous else {
        return 0;
    };

    let binary = ends_operand(held);

    match kind {
        Kind::Ampersand => u8::from(binary) * 7,
        Kind::AndKeyword | Kind::OrKeyword => PRIORITY_LOGIC,
        Kind::At | Kind::Percent | Kind::Slash | Kind::SlashSlash | Kind::Star => {
            u8::from(binary) * 4
        }
        Kind::Bar => u8::from(binary) * 9,
        Kind::Caret => u8::from(binary) * 8,
        Kind::Dot => u8::from(is_close(held)) * PRIORITY_DOT,
        Kind::ElseKeyword => PRIORITY_TERNARY,
        Kind::EqualEqual
        | Kind::Greater
        | Kind::GreaterEqual
        | Kind::IsKeyword
        | Kind::Less
        | Kind::LessEqual
        | Kind::NotEqual => PRIORITY_COMPARATOR,
        Kind::InKeyword => u8::from(held != Kind::NotKeyword) * PRIORITY_COMPARATOR,
        Kind::FStringStart | Kind::StringBytes | Kind::StringPlain => {
            u8::from(matches!(
                held,
                Kind::FStringEnd | Kind::StringBytes | Kind::StringPlain
            )) * PRIORITY_STRING
        }
        Kind::GreaterGreater | Kind::LessLess => u8::from(binary) * 6,
        Kind::Minus | Kind::Plus => u8::from(binary) * 5,
        Kind::NotKeyword => u8::from(binary && held != Kind::IsKeyword) * PRIORITY_COMPARATOR,
        Kind::StarStar => u8::from(binary) * PRIORITY_DOT,
        _ => 0,
    }
}

fn emitting<'held>(
    input: &Input<'held>,
    arena: &'held mut Buffer,
    document: &'held mut Document,
    literals: (u32, u32),
    parentheses: (u32, u32, u32),
) -> Emitter<'held> {
    Emitter {
        after: false,
        closed: false,
        arena,
        at_lambda: NONE,
        at_previous: NONE,
        concat_at: NONE,
        concat_span: Span::EMPTY,
        blocks: [false; BRACKET_DEPTH_MAX as usize],
        columns: [0; BRACKET_DEPTH_MAX as usize],
        depth: 0,
        document,
        documented: false,
        documented_past: false,
        elided: [NONE; BRACKET_DEPTH_MAX as usize],
        elisions: 0,
        frames: [Frame::new(); BRACKET_DEPTH_MAX as usize],
        functions: [false; BRACKET_DEPTH_MAX as usize],
        hug_break: NONE,
        hug_depth: 0,
        hug_end: NONE,
        indent: 0,
        indent_width: input.options.indent_width,
        inline: 0,
        line_width: input.options.line_width,
        magic_trailing_comma: input.magic_trailing_comma,
        pragmas: input.pragmas,
        quote: input.quote,
        hugged: false,
        line_depth: 0,
        line_first: None,
        line_first_at: NONE,
        lowered: 0,
        literals,
        parentheses,
        wrap: NONE,
        wrap_sole: false,
        wrap_tuple: false,
        wrapper: Frame::new(),
        opened: false,
        pending_break: false,
        pending_word: NONE,
        power: NONE,
        previous: None,
        skip: NONE,
        starting: false,
        stubbed: false,
        until: 0,
        raw: input.raw,
        source: input.source,
        suppress_space: false,
        tokens: input.tokens,
    }
}

#[derive(Debug)]
pub struct Formatter {
    arena: Buffer,
    close: u32,
    comma: u32,
    document: Document,
    gap: u32,
    head: u32,
    open: u32,
}

struct Emitter<'held> {
    after: bool,
    arena: &'held mut Buffer,
    at_lambda: u32,
    at_previous: u32,
    blocks: [bool; BRACKET_DEPTH_MAX as usize],
    closed: bool,
    columns: [u32; BRACKET_DEPTH_MAX as usize],
    concat_at: u32,
    concat_span: Span,
    depth: u32,
    document: &'held mut Document,
    documented: bool,
    documented_past: bool,
    elided: [u32; BRACKET_DEPTH_MAX as usize],
    elisions: u32,
    frames: [Frame; BRACKET_DEPTH_MAX as usize],
    functions: [bool; BRACKET_DEPTH_MAX as usize],
    hug_break: u32,
    hug_depth: u32,
    hug_end: u32,
    hugged: bool,
    indent: u32,
    indent_width: u32,
    inline: u32,
    line_depth: u32,
    line_first: Option<Kind>,
    line_first_at: u32,
    line_width: u32,
    literals: (u32, u32),
    lowered: u32,
    magic_trailing_comma: bool,
    opened: bool,
    parentheses: (u32, u32, u32),
    pending_break: bool,
    pending_word: u32,
    power: u32,
    pragmas: &'held [PragmaAt],
    previous: Option<Kind>,
    quote: QuotePreference,
    raw: &'held [Kind],
    skip: u32,
    source: &'held [u8],
    starting: bool,
    stubbed: bool,
    suppress_space: bool,
    tokens: &'held [Token],
    until: u32,
    wrap: u32,
    wrap_sole: bool,
    wrap_tuple: bool,
    wrapper: Frame,
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

const fn is_unary(kind: Kind) -> bool {
    matches!(
        kind,
        Kind::Minus | Kind::NotKeyword | Kind::Plus | Kind::Tilde
    )
}

const fn is_close(kind: Kind) -> bool {
    matches!(
        kind,
        Kind::BraceClose | Kind::BracketClose | Kind::ParenClose
    )
}

const fn opens_suite(kind: Option<Kind>) -> bool {
    matches!(
        kind,
        Some(
            Kind::AsyncKeyword
                | Kind::ClassKeyword
                | Kind::DefKeyword
                | Kind::ElifKeyword
                | Kind::ElseKeyword
                | Kind::ExceptKeyword
                | Kind::FinallyKeyword
                | Kind::ForKeyword
                | Kind::IfKeyword
                | Kind::TryKeyword
                | Kind::WhileKeyword
                | Kind::WithKeyword
        )
    )
}

const fn signed(kind: Kind) -> bool {
    matches!(
        kind,
        Kind::Minus | Kind::Plus | Kind::Star | Kind::StarStar | Kind::Tilde
    )
}

const fn worded(kind: Kind) -> bool {
    matches!(
        kind,
        Kind::AndKeyword
            | Kind::AsKeyword
            | Kind::AwaitKeyword
            | Kind::ElseKeyword
            | Kind::ForKeyword
            | Kind::IfKeyword
            | Kind::InKeyword
            | Kind::IsKeyword
            | Kind::LambdaKeyword
            | Kind::NotKeyword
            | Kind::OrKeyword
    )
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct Field {
    lambda: bool,
    mapped: bool,
    operand: bool,
    prefixed: bool,
    spec: bool,
    stacked: bool,
    tupled: u32,
}

impl Field {
    const NONE: Self = Self {
        lambda: false,
        mapped: false,
        operand: false,
        prefixed: false,
        spec: false,
        stacked: false,
        tupled: NONE,
    };
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct Nest {
    base: u32,
    field: Field,
    quote: u8,
    raw: bool,
    want: u8,
}

impl Nest {
    const NONE: Self = Self {
        base: 0,
        field: Field::NONE,
        quote: 0,
        raw: false,
        want: 0,
    };
}

struct Fields {
    brackets: [Kind; BRACKET_DEPTH_MAX as usize],
    depth: u32,
    formats: usize,
    held: Field,
    nests: [Nest; FORMAT_NEST_MAX],
    previous: Option<Kind>,
}

impl Fields {
    const NONE: Self = Self {
        brackets: [Kind::BraceOpen; BRACKET_DEPTH_MAX as usize],
        depth: 0,
        formats: 0,
        held: Field::NONE,
        nests: [Nest::NONE; FORMAT_NEST_MAX],
        previous: None,
    };
}

fn fielding(
    kind: Kind,
    previous: Option<Kind>,
    brackets: &mut [Kind],
    depth: &mut u32,
    held: &mut Field,
) -> bool {
    if is_open(kind) {
        if *depth == BRACKET_DEPTH_MAX {
            return false;
        }

        brackets[*depth as usize] =
            if kind == Kind::BraceOpen && (held.spec || previous == Some(Kind::Colon)) {
                Kind::Colon
            } else {
                kind
            };

        *depth += 1;
    } else if is_close(kind) {
        let inner = depth.saturating_sub(1);

        held.stacked = *depth > 1 && brackets[inner as usize] != Kind::Colon;
        *depth = inner;
    }

    let bodied = previous == Some(Kind::Colon);

    held.lambda = kind == Kind::LambdaKeyword || held.lambda && !bodied;
    held.mapped = *depth > 1 && brackets[*depth as usize - 1] == Kind::BraceOpen;
    held.prefixed = signed(kind) && !held.operand;
    held.spec = *depth > 0 && (held.spec || kind == Kind::Colon && *depth == 1);
    held.operand = ends_operand(kind);

    true
}

fn fielded(previous: Kind, kind: Kind, held: Field) -> bool {
    if previous == Kind::BraceOpen && kind == Kind::BraceOpen
        || previous == Kind::BraceClose && kind == Kind::BraceClose && held.stacked
    {
        return true;
    }

    if is_open(previous) || is_close(kind) || held.prefixed {
        return false;
    }

    if matches!(kind, Kind::Comma | Kind::Dot | Kind::Semicolon) || previous == Kind::Dot {
        return false;
    }

    if kind == Kind::Colon {
        return false;
    }

    if previous == Kind::Colon {
        return held.lambda || held.mapped;
    }

    if matches!(kind, Kind::Bang | Kind::Equal | Kind::StarStar)
        || matches!(previous, Kind::Bang | Kind::Equal | Kind::StarStar)
    {
        return false;
    }

    if worded(previous) || worded(kind) {
        return true;
    }

    if is_open(kind) {
        return !held.operand;
    }

    true
}

fn blanked(previous: Kind, current: Kind) -> bool {
    if is_open(previous) || is_close(current) {
        return false;
    }

    if matches!(previous, Kind::FStringStart | Kind::FStringMiddle)
        || matches!(current, Kind::FStringEnd | Kind::FStringMiddle)
    {
        return false;
    }

    if matches!(current, Kind::Comma | Kind::Dot | Kind::Semicolon) || previous == Kind::Dot {
        return false;
    }

    if matches!(current, Kind::BracketOpen | Kind::ParenOpen) {
        return !ends_operand(previous);
    }

    true
}

const fn joined(kind: Kind) -> bool {
    matches!(
        kind,
        Kind::FStringEnd | Kind::StringBytes | Kind::StringPlain
    )
}

fn joined_head(kind: Kind, text: &[u8]) -> Option<u32> {
    match kind {
        Kind::FStringStart => Some(count_of(text.len())),
        Kind::StringBytes | Kind::StringPlain => body_edges(text).map(|(head, _)| head),
        _ => None,
    }
}

fn joined_tail(kind: Kind, text: &[u8]) -> u32 {
    match kind {
        Kind::FStringEnd => count_of(text.len()),
        Kind::StringBytes | Kind::StringPlain => {
            body_edges(text).map_or(0, |(_, tail)| count_of(text.len()) - tail)
        }
        _ => 0,
    }
}

const fn is_layout(kind: Kind) -> bool {
    matches!(kind, Kind::Dedent | Kind::Indent | Kind::Newline)
}

const fn is_number(kind: Kind) -> bool {
    matches!(
        kind,
        Kind::NumberBinary
            | Kind::NumberComplex
            | Kind::NumberFloat
            | Kind::NumberHexadecimal
            | Kind::NumberInteger
            | Kind::NumberOctal
    )
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

const fn elides_after(kind: Kind) -> bool {
    matches!(
        kind,
        Kind::AmpersandEqual
            | Kind::Arrow
            | Kind::AssertKeyword
            | Kind::AtEqual
            | Kind::AwaitKeyword
            | Kind::BarEqual
            | Kind::CaretEqual
            | Kind::ColonEqual
            | Kind::DelKeyword
            | Kind::ElifKeyword
            | Kind::Equal
            | Kind::GreaterGreaterEqual
            | Kind::IfKeyword
            | Kind::LessLessEqual
            | Kind::MinusEqual
            | Kind::PercentEqual
            | Kind::PlusEqual
            | Kind::ReturnKeyword
            | Kind::SlashEqual
            | Kind::SlashSlashEqual
            | Kind::StarEqual
            | Kind::StarStarEqual
            | Kind::WhileKeyword
            | Kind::WithKeyword
    )
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

        let mut document = Document::reserve(element_count_max, 5);
        let comma = document.literal(COMMA);
        let gap = document.literal(GAP);
        let open = document.literal(PAREN_OPEN);
        let head = document.literal(PAREN_HEAD);
        let close = document.literal(PAREN_CLOSE);

        Self {
            arena: Buffer::reserve(arena_bytes_max),
            close,
            comma,
            document,
            head,
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

        if input.outcome != Structure::Complete || !input.tree.errors().is_empty() || broken(input)
        {
            return Outcome::Refusal;
        }

        self.arena.clear();
        self.document.clear();

        let mut emitter = emitting(
            input,
            &mut self.arena,
            &mut self.document,
            (self.comma, self.gap),
            (self.open, self.head, self.close),
        );

        if !emitter.run()
            || !print::print(
                &self.document,
                input.source,
                self.arena.as_bytes(),
                input.options,
                out,
            )
        {
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

        let held = if self.ends_semicolon(position) {
            0
        } else {
            self.blanks_before(position, token.offset).min(allowed)
        };

        let stubbed = self.stubbed
            && held == 0
            && (self.opens_definition(position) || self.heads_a_definition(position));

        let definition = !stubbed
            && (self.opens_definition(position) && !self.follows_a_comment(position)
                || self.heads_a_definition(position));
        let remarked = self.raw[position as usize] == Kind::Comment
            && position > 0
            && self.remarks_trail(position - 1);

        let closed = if remarked { self.closed } else { self.after };
        let continued = self.continues(position);
        let spaced = closed && !continued || definition || self.stubbed && !stubbed && !continued;
        let hugged = is_close(self.raw[position as usize]) || self.previous.is_some_and(is_open);
        let nested = self.opened
            && self.nests()
            && self.opens_definition(position)
            && !self.follows_a_comment(position);

        let documented = self.documented && !spaced;

        let parted = documented
            || self.follows_an_import(position) && !self.remarks_trail(position.saturating_sub(1));

        let heads = self.opened
            && self.indent > 0
            && self.functions[self.indent as usize - 1]
            && self.raw[position as usize] != Kind::StringPlain;

        let blanks = if self.depth > 0
            || self.line_first == Some(Kind::At)
            || self.opened && !nested && !heads
            || hugged
        {
            0
        } else if heads {
            held
        } else if spaced && self.at_previous != NONE {
            allowed
        } else if documented {
            if self.documented_past { held } else { 1 }
        } else if parted {
            held.max(1)
        } else {
            held
        };

        self.after = false;
        self.closed = false;

        let carried = self.documented
            && self.documented_past
            && self.indent == 0
            && self.raw[position as usize] == Kind::Comment;

        self.documented = carried;
        self.documented_past = carried && self.remarks_trail(position);
        self.stubbed = false;
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

        if held.hugged {
            self.depth -= 1;

            return self.text(position, false);
        }

        if !self.ends_element(0) {
            return false;
        }

        self.depth -= 1;

        let comma = self.document.literal_span(self.literals.0);
        let started = self.starting;

        let separator = if held.magic {
            Element::HardLine
        } else {
            Element::SoftLine
        };

        let listed = !started && !held.trailed && held.commas;

        if listed && !self.document.push(Element::IfBroken(comma)) {
            return false;
        }

        if !held.sole && !held.hollow && !self.document.push(Element::GroupClose) {
            return false;
        }

        if !started
            && !held.trailed
            && !held.commas
            && held.owes
            && !self.document.push(Element::IfBroken(comma))
        {
            return false;
        }

        if !self.document.push(Element::Dedent) {
            return false;
        }

        if !started && !self.document.push(separator) {
            return false;
        }

        self.text(position, false) && self.document.push(Element::GroupClose)
    }

    const fn frame(&self) -> Frame {
        if self.depth == 0 {
            return self.wrapper;
        }

        self.frames[self.depth as usize - 1]
    }

    const fn set_frame(&mut self, held: Frame) {
        if self.depth == 0 {
            self.wrapper = held;

            return;
        }

        self.frames[self.depth as usize - 1] = held;
    }

    fn ends_semicolon(&self, position: u32) -> bool {
        let mut scan = position;

        while scan > 0 {
            scan -= 1;

            let kind = self.raw[scan as usize];

            if is_layout(kind) {
                continue;
            }

            return kind == Kind::Semicolon;
        }

        false
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

    fn parted(&self) -> bool {
        for element in self.document.elements().iter().rev() {
            match element {
                Element::BlankLine(_) | Element::HardLine | Element::Line | Element::SoftLine => {
                    return true;
                }
                Element::Dedent
                | Element::GroupClose
                | Element::GroupOpen
                | Element::IfBroken(_)
                | Element::Indent => {}
                _ => return false,
            }
        }

        true
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

    fn heads_line(&self, position: u32) -> bool {
        let offset = self.tokens[position as usize].offset;

        offset == self.line_start(offset) + self.line_indent(offset)
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

            if scan == self.skip {
                self.skip = NONE;
                scan += 1;

                continue;
            }

            if kind == Kind::Indent {
                self.line_first = Some(self.line_opener(scan));

                if !self.indented(scan, self.column_after(scan)) {
                    return false;
                }
            }

            if kind == Kind::Dedent {
                if self.indent == 0 {
                    return false;
                }

                self.indent -= 1;
                self.closed = self.blocks[self.indent as usize];
                self.after = self.after || self.closed;
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
        self.raw[self.line_opener_at(position) as usize]
    }

    fn line_opener_at(&self, position: u32) -> u32 {
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

        scan
    }

    fn fstring(&mut self, position: u32) -> bool {
        let closing = self.fstring_end(position);
        let end = if closing == NONE { position } else { closing };

        assert!(end >= position);

        let own_line = self.pending_break || self.previous.is_none();

        if self.pending_break && !self.break_line(position) {
            return false;
        }

        if own_line {
            self.line_first = Some(Kind::FStringStart);

            if self.concat_at == NONE && !self.opens_deferred() {
                return false;
            }
        }

        let parting = self.parting(Kind::FStringStart);
        let kept = self.parts(parting);
        let parted = self.parted_join(position);

        if kept != NONE && !self.ends_element(kept) {
            return false;
        }

        if parted || kept != NONE || self.spaced(Kind::FStringStart) {
            let separator = if parted {
                Element::HardLine
            } else if kept == NONE {
                Element::Space
            } else {
                Element::Line
            };

            if !self.document.push(separator) {
                return false;
            }
        }

        if kept != NONE && !self.starts_element(position, Kind::FStringStart, parting) {
            return false;
        }

        if !self.opens_join() {
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

        if let Some(respaced) = self.respaced(position, end) {
            return self.document.push(Element::VerbatimArena(respaced));
        }

        if let Some(swapped) = self.relit(held) {
            return self.document.push(Element::VerbatimArena(swapped));
        }

        self.document.push(Element::Verbatim(held))
    }

    fn format_quote(&self, position: u32, preference: u8) -> u8 {
        let text = &self.source[self.tokens[position as usize].span().range()];
        let at = prefix_of(text);
        let rest = &text[at..];

        if preference == 0 || rest.starts_with(TRIPLE_DOUBLE) || rest.starts_with(TRIPLE_SINGLE) {
            return 0;
        }

        let end = self.fstring_end(position);

        if end == NONE {
            return 0;
        }

        let raw = text[..at].iter().any(|byte| matches!(byte, b'R' | b'r'));
        let other = other_quote(preference);
        let mut alone = 0;
        let mut wanted = 0;
        let mut depth = 0_u32;
        let mut scan = position;

        while scan <= end {
            let kind = self.raw[scan as usize];

            depth += u32::from(kind == Kind::FStringStart);

            if kind == Kind::FStringMiddle && depth == 1 {
                let body = &self.source[self.tokens[scan as usize].span().range()];

                if raw {
                    alone += u32::from(unescaped(body, other));
                    wanted += u32::from(unescaped(body, preference));
                } else {
                    alone += escapes_of(body, other);
                    wanted += escapes_of(body, preference);
                }
            }

            depth -= u32::from(kind == Kind::FStringEnd);
            scan += 1;
        }

        if raw {
            if wanted == 0 {
                return preference;
            }

            return if alone == 0 { other } else { rest[0] };
        }

        if alone < wanted { other } else { preference }
    }

    fn opens_format(&mut self, position: u32, preference: u8) -> Option<u8> {
        let text = &self.source[self.tokens[position as usize].span().range()];
        let at = prefix_of(text);
        let quote = self.format_quote(position, preference);

        if quote == 0 {
            return self.arena.push_bytes(text).then_some(0);
        }

        let (written, count) = prefix_written(&text[..at]);

        (self.arena.push_bytes(&written[..count]) && self.arena.push_bytes(&[quote]))
            .then_some(quote)
    }

    fn respaced(&mut self, position: u32, end: u32) -> Option<Span> {
        let bytes = &self.source[self.tokens[position as usize].offset as usize
            ..self.tokens[end as usize].end() as usize];

        let offset = self.arena.count();

        if !self.refielded(position, end, 0) {
            self.arena.truncate(offset);

            return None;
        }

        self.written(offset, bytes)
    }

    fn refielded(&mut self, position: u32, end: u32, imposed: u8) -> bool {
        let mut state = Fields::NONE;
        let mut scan = position;

        while scan <= end {
            let kind = self.raw[scan as usize];

            if kind != Kind::FStringMiddle
                && self.source[self.tokens[scan as usize].span().range()].contains(&b'\n')
            {
                return false;
            }

            let written = if matches!(
                kind,
                Kind::FStringStart | Kind::FStringMiddle | Kind::FStringEnd
            ) {
                self.renested(scan, imposed, &mut state)
            } else {
                self.refield(scan, &mut state)
            };

            if !written {
                return false;
            }

            scan += 1;
        }

        state.formats == 0
    }

    fn renested(&mut self, position: u32, imposed: u8, state: &mut Fields) -> bool {
        let kind = self.raw[position as usize];
        let text = &self.source[self.tokens[position as usize].span().range()];

        if kind == Kind::FStringStart {
            if state.formats == FORMAT_NEST_MAX {
                return false;
            }

            let blank = state
                .previous
                .is_some_and(|word| fielded(word, kind, state.held));

            if blank && !self.arena.push_bytes(b" ") {
                return false;
            }

            return self.opens_nest(position, imposed, state);
        }

        if state.formats == 0 {
            return false;
        }

        let inner = state.formats - 1;
        let nest = state.nests[inner];

        if kind == Kind::FStringMiddle {
            let written = if nest.quote == 0 || nest.raw {
                self.arena.push_bytes(text)
            } else {
                quoted_body(self.arena, text, nest.quote)
            };

            if state.depth == nest.base {
                state.held = Field::NONE;
            }

            state.previous = None;

            return written;
        }

        let written = if inner == 0 && imposed != 0 {
            true
        } else if nest.quote == 0 {
            self.arena.push_bytes(text)
        } else {
            self.arena.push_bytes(&[nest.quote])
        };

        state.depth = nest.base;
        state.formats = inner;
        state.held = nest.field;
        state.held.operand = true;
        state.held.prefixed = false;
        state.previous = (inner > 0).then_some(Kind::FStringEnd);

        written
    }

    fn opens_nest(&mut self, position: u32, imposed: u8, state: &mut Fields) -> bool {
        let text = &self.source[self.tokens[position as usize].span().range()];
        let formats = state.formats;

        let preference = if formats == 0 {
            wanted_quote(self.quote)
        } else {
            state.nests[formats - 1].want
        };

        let quote = if formats == 0 && imposed != 0 {
            imposed
        } else {
            match self.opens_format(position, preference) {
                Some(found) => found,
                None => return false,
            }
        };

        state.nests[formats] = Nest {
            base: state.depth,
            field: state.held,
            quote,
            raw: text[..prefix_of(text)]
                .iter()
                .any(|byte| matches!(byte, b'R' | b'r')),
            want: if quote == 0 {
                preference
            } else {
                other_quote(quote)
            },
        };

        state.depth = 0;
        state.formats = formats + 1;
        state.held = Field::NONE;
        state.previous = None;

        true
    }

    fn refield(&mut self, position: u32, state: &mut Fields) -> bool {
        if state.formats == 0 {
            return false;
        }

        let kind = self.raw[position as usize];
        let text = &self.source[self.tokens[position as usize].span().range()];

        let blank = state
            .previous
            .is_some_and(|word| fielded(word, kind, state.held));

        if blank && !self.arena.push_bytes(b" ") {
            return false;
        }

        if state.held.tupled == position && !self.arena.push_bytes(b")") {
            return false;
        }

        let opens = kind == Kind::BraceOpen && state.depth == 0;
        let want = state.nests[state.formats - 1].want;

        let requotes =
            !state.held.spec && want != 0 && matches!(kind, Kind::StringBytes | Kind::StringPlain);

        let written = if requotes {
            relettered(self.arena, text, preferring(want))
        } else {
            self.arena.push_bytes(text)
        };

        if !written
            || !fielding(
                kind,
                state.previous,
                &mut state.brackets,
                &mut state.depth,
                &mut state.held,
            )
        {
            return false;
        }

        if opens {
            state.held.tupled = self.field_tuple(position);

            if state.held.tupled != NONE && !self.arena.push_bytes(b"(") {
                return false;
            }
        }

        state.previous = Some(kind);

        true
    }

    fn field_tuple(&self, position: u32) -> u32 {
        let count = count_of(self.tokens.len());
        let mut comma = NONE;
        let mut depth = 0_u32;
        let mut held = NONE;
        let mut scan = position + 1;

        while scan < count {
            let kind = self.raw[scan as usize];

            if is_layout(kind) {
                scan += 1;

                continue;
            }

            if depth == 0 && kind == Kind::Equal {
                return NONE;
            }

            if depth == 0 && (is_close(kind) || matches!(kind, Kind::Bang | Kind::Colon)) {
                return if comma == held { scan } else { NONE };
            }

            if is_open(kind) {
                depth += 1;
            } else if is_close(kind) {
                depth -= 1;
            } else if depth == 0 && kind == Kind::Comma {
                if comma != NONE {
                    return NONE;
                }

                comma = scan;
            }

            held = scan;
            scan += 1;
        }

        NONE
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

    fn column_after(&self, position: u32) -> u32 {
        let count = count_of(self.tokens.len());
        let mut scan = position + 1;

        while scan < count {
            if !is_layout(self.raw[scan as usize]) {
                return self.line_indent(self.tokens[scan as usize].offset);
            }

            scan += 1;
        }

        0
    }

    fn dedents_after(&self, position: u32) -> u32 {
        let count = count_of(self.tokens.len());
        let mut found = 0;
        let mut scan = position;

        while scan < count {
            let kind = self.raw[scan as usize];

            if matches!(kind, Kind::Comment | Kind::Newline) {
                scan += 1;

                continue;
            }

            if kind != Kind::Dedent {
                break;
            }

            found += 1;
            scan += 1;
        }

        found
    }

    fn lower(&mut self, position: u32) -> bool {
        if !self.heads_line(position) {
            return true;
        }

        let column = self.line_indent(self.tokens[position as usize].offset);
        let mut pending = self.dedents_after(position).saturating_sub(self.lowered);

        while pending > 0 && self.indent > 0 && column < self.columns[self.indent as usize - 1] {
            self.indent -= 1;
            self.closed = self.blocks[self.indent as usize];
            self.after = self.after || self.closed;
            self.lowered += 1;
            pending -= 1;

            if !self.document.push(Element::Dedent) {
                return false;
            }
        }

        true
    }

    fn indented(&mut self, position: u32, column: u32) -> bool {
        if self.indent == BRACKET_DEPTH_MAX {
            return false;
        }

        let opener = self.line_opener_at(position);

        self.blocks[self.indent as usize] = self.opens_definition(opener);
        self.functions[self.indent as usize] =
            self.opens_definition(opener) && self.raw[opener as usize] != Kind::ClassKeyword;

        self.columns[self.indent as usize] = column;
        self.indent += 1;
        self.opened = true;

        self.document.push(Element::Indent)
    }

    fn heads_a_definition(&self, position: u32) -> bool {
        if self.raw[position as usize] != Kind::Comment {
            return false;
        }

        if self.follows_a_comment(position) || self.remarks_alone(position) {
            return false;
        }

        let offset = self.tokens[position as usize].offset;

        if offset != self.line_start(offset) + self.line_indent(offset) {
            return false;
        }

        let count = count_of(self.tokens.len());
        let mut end_previous = self.tokens[position as usize].end();
        let mut scan = position + 1;

        while scan < count {
            let kind = self.raw[scan as usize];
            let held = self.tokens[scan as usize];

            if is_layout(kind) || held.length == 0 {
                scan += 1;

                continue;
            }

            if blank_lines(self.source, end_previous, held.offset) > 1 {
                return false;
            }

            if kind != Kind::Comment {
                return self.opens_definition(scan)
                    && self.line_indent(held.offset) == self.line_indent(offset);
            }

            end_previous = held.end();
            scan += 1;
        }

        false
    }

    fn remarks_alone(&self, position: u32) -> bool {
        let mut found = false;
        let mut scan = position;

        while scan > 0 {
            scan -= 1;

            let kind = self.raw[scan as usize];

            if is_layout(kind) || self.tokens[scan as usize].length == 0 {
                continue;
            }

            if kind != Kind::Comment {
                return false;
            }

            found = true;
        }

        found
    }

    fn follows_a_comment(&self, position: u32) -> bool {
        let start = self.tokens[position as usize].offset;
        let mut scan = position;

        while scan > 0 {
            scan -= 1;

            let kind = self.raw[scan as usize];
            let held = self.tokens[scan as usize];

            if is_layout(kind) || held.length == 0 {
                continue;
            }

            if kind != Kind::Comment || blank_lines(self.source, held.end(), start) > 1 {
                return false;
            }

            let offset = held.offset;

            return offset == self.line_start(offset) + self.line_indent(offset)
                && self.line_indent(offset) == self.line_indent(start);
        }

        false
    }

    fn follows_an_import(&self, position: u32) -> bool {
        let importing = matches!(
            self.line_first,
            Some(Kind::FromKeyword | Kind::ImportKeyword)
        );

        if !importing || self.line_first_at == NONE {
            return false;
        }

        if matches!(
            self.raw[position as usize],
            Kind::FromKeyword | Kind::ImportKeyword
        ) {
            return false;
        }

        self.line_depth == self.indent
    }

    fn continues(&self, position: u32) -> bool {
        matches!(
            self.raw[position as usize],
            Kind::ElifKeyword | Kind::ElseKeyword | Kind::ExceptKeyword | Kind::FinallyKeyword
        )
    }

    fn nests(&self) -> bool {
        self.indent > 0 && !self.blocks[self.indent as usize - 1]
    }

    fn opens_definition(&self, position: u32) -> bool {
        let kind = self.raw[position as usize];

        if kind == Kind::AsyncKeyword {
            return self.follows_definition(position);
        }

        matches!(kind, Kind::At | Kind::ClassKeyword | Kind::DefKeyword)
    }

    fn follows_definition(&self, position: u32) -> bool {
        let count = count_of(self.tokens.len());
        let mut scan = position + 1;

        while scan < count {
            let kind = self.raw[scan as usize];

            if !is_layout(kind) && kind != Kind::Comment {
                return kind == Kind::DefKeyword;
            }

            scan += 1;
        }

        false
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
                previous = Some(kind);

                continue;
            }

            if is_close(kind) {
                depth -= 1;

                if depth == 0 {
                    let listed = matches!(
                        self.line_first,
                        Some(Kind::FromKeyword | Kind::ImportKeyword)
                    ) || self.previous == Some(Kind::WithKeyword);

                    if open == Kind::ParenOpen && !call && !listed && commas == 1 {
                        return false;
                    }

                    return opened_by(kind) == open && previous == Some(Kind::Comma);
                }

                previous = Some(kind);

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

    fn complicated(&self, position: u32) -> bool {
        const COMPLEX: [Kind; 12] = [
            Kind::AndKeyword,
            Kind::ColonEqual,
            Kind::Dot,
            Kind::ElseKeyword,
            Kind::EqualEqual,
            Kind::Greater,
            Kind::GreaterEqual,
            Kind::IfKeyword,
            Kind::LambdaKeyword,
            Kind::Less,
            Kind::LessEqual,
            Kind::NotKeyword,
        ];

        let count = count_of(self.tokens.len());
        let mut depth = 0;
        let mut previous = None;
        let mut scan = position;

        while scan < count {
            let kind = self.raw[scan as usize];

            if is_layout(kind) {
                scan += 1;

                continue;
            }

            if is_open(kind) {
                depth += 1;

                if depth > 1 {
                    return true;
                }

                previous = Some(kind);
                scan += 1;

                continue;
            }

            if is_close(kind) {
                depth -= 1;

                if depth == 0 {
                    return false;
                }

                previous = Some(kind);
                scan += 1;

                continue;
            }

            if COMPLEX.contains(&kind) || kind == Kind::NotEqual || kind == Kind::OrKeyword {
                return true;
            }

            if is_binary(kind) && previous.is_some_and(ends_operand) {
                return true;
            }

            previous = Some(kind);
            scan += 1;
        }

        false
    }

    fn open(&mut self, position: u32, kind: Kind) -> bool {
        if self.depth == BRACKET_DEPTH_MAX {
            return self.text(position, false);
        }

        let call = !(self.starting && self.depth == 0)
            && self.previous.is_some_and(ends_operand)
            && !(kind == Kind::BracketOpen && self.parameterised());
        let magic_source = self.magic_of(position, call);
        let magic = self.magic_trailing_comma && magic_source;
        let priority = self.priority_of(position);

        let defines = self.line_first == Some(Kind::AsyncKeyword)
            && self.next_kind(self.line_first_at) == Some(Kind::DefKeyword);

        let owes = kind == Kind::ParenOpen
            && self.depth == 0
            && self.previous != Some(Kind::Arrow)
            && (defines
                || matches!(
                    self.line_first,
                    Some(Kind::DefKeyword | Kind::FromKeyword | Kind::ImportKeyword)
                ));

        self.frames[self.depth as usize] = Frame {
            call,
            complex: kind == Kind::BracketOpen && call && self.complicated(position),
            owes,
            kind,
            magic,
            hugged: self.hugs_literal(position, call) || self.hollow(position),
            magic_source,
            priority,
            sole: !call && priority == PRIORITY_COMMA && self.listed(position),
            ..Frame::new()
        };

        self.depth += 1;

        if self.frames[self.depth as usize - 1].hugged {
            return self.text(position, false);
        }

        let riding = self.rider(position);

        let separator = if magic || riding != NONE {
            Element::HardLine
        } else {
            Element::SoftLine
        };

        let wide = kind == Kind::ParenOpen
            && self.depth == 1
            && matches!(self.line_first, Some(Kind::AsyncKeyword | Kind::DefKeyword));

        if !(self.document.push(Element::GroupOpen)
            && (!wide || self.document.push(Element::Wide))
            && self.text(position, false))
        {
            return false;
        }

        if riding != NONE && !self.rides(riding) {
            return false;
        }

        if !self.document.push(Element::Indent) {
            return false;
        }

        let cap = self.frame().priority;

        if self.frames[self.depth as usize - 1].sole {
            return self.document.push(separator) && self.starts_element(position, kind, cap);
        }

        let (first, second) = if magic {
            (Element::GroupOpen, separator)
        } else {
            (separator, Element::GroupOpen)
        };

        self.document.push(first)
            && self.document.push(second)
            && self.starts_element(position, kind, cap)
    }

    fn enjoin(&mut self, position: u32) -> bool {
        let strung = matches!(
            self.raw[position as usize],
            Kind::FStringStart | Kind::StringBytes | Kind::StringPlain
        );

        let opened = matches!(
            self.previous,
            Some(Kind::FStringEnd | Kind::StringBytes | Kind::StringPlain)
        );

        if !strung || opened || self.concat_at != NONE || self.documents(position) {
            return true;
        }

        let end = self.joinable(position);

        if end == NONE {
            return true;
        }

        let Some(held) = self.joined(position, end) else {
            return true;
        };

        self.concat_at = end;
        self.concat_span = held;

        true
    }

    fn opens_join(&mut self) -> bool {
        if self.concat_span.length == 0 {
            return true;
        }

        let held = self.concat_span;
        let hugs = self.joins_hug(self.at_previous, self.concat_at);
        let tail = self.hug_tail(self.concat_at);

        if hugs && tail != self.concat_at && !self.hug_fits(self.at_previous, self.concat_at) {
            self.hug_break = self
                .next_token(self.concat_at, count_of(self.tokens.len()))
                .unwrap_or(NONE);

            self.hug_depth = self.depth;
            self.hug_end = tail;
        }

        self.concat_span = Span {
            length: 0,
            offset: 0,
        };

        (!hugs || self.document.push(Element::Hugged))
            && self.document.push(Element::GroupOpen)
            && self.document.push(Element::Joined(held))
    }

    fn joins_hug(&self, position: u32, end: u32) -> bool {
        if !self.previous.is_some_and(is_binary) || end == NONE {
            return false;
        }

        let column = (self.indent + self.depth) * self.indent_width;
        let start = self.element_start(position);

        column + self.measured(start, self.part_end(position)) <= self.line_width
    }

    fn hug_breaks(&self, position: u32) -> bool {
        self.hug_break != NONE
            && position >= self.hug_break
            && position <= self.hug_end
            && self.depth == self.hug_depth
    }

    fn hug_fits(&self, position: u32, end: u32) -> bool {
        let column = (self.indent + self.depth) * self.indent_width;
        let last = self.part_last(position, end);

        column + self.measured(last, self.hug_tail(end)) <= self.line_width
    }

    fn part_last(&self, position: u32, end: u32) -> u32 {
        let count = count_of(self.tokens.len()).min(end + 1);
        let mut held = position;
        let mut scan = position;

        while scan < count {
            let kind = self.raw[scan as usize];

            if is_layout(kind) || kind == Kind::Comment {
                scan += 1;

                continue;
            }

            held = scan;
            scan = self.part_end(scan) + 1;
        }

        held
    }

    fn hug_tail(&self, end: u32) -> u32 {
        let count = count_of(self.tokens.len());
        let mut depth = 0_u32;
        let mut held = end;
        let mut scan = end + 1;

        while scan < count {
            let kind = self.raw[scan as usize];

            if kind == Kind::Newline || depth == 0 && (kind == Kind::Comma || is_close(kind)) {
                break;
            }

            if is_open(kind) {
                depth += 1;
            } else if is_close(kind) {
                depth -= 1;
            }

            if !is_layout(kind) && kind != Kind::Comment {
                held = scan;
            }

            scan += 1;
        }

        held
    }

    fn unjoin(&mut self) -> bool {
        if self.concat_at == NONE {
            return true;
        }

        self.concat_at = NONE;

        if self.concat_span.length > 0 {
            self.concat_span = Span {
                length: 0,
                offset: 0,
            };

            return true;
        }

        self.document.push(Element::GroupClose) && self.opens_deferred()
    }

    fn concat_end(&self, position: u32) -> u32 {
        let count = count_of(self.tokens.len());
        let mut end = NONE;
        let mut parts = 0;
        let mut scan = position;

        while scan < count {
            let kind = self.raw[scan as usize];

            if kind == Kind::Newline {
                scan += 1;

                continue;
            }

            let held = match kind {
                Kind::FStringStart => self.fstring_end(scan),
                Kind::StringBytes | Kind::StringPlain => scan,
                _ => break,
            };

            if held == NONE {
                break;
            }

            end = held;
            parts += 1;
            scan = held + 1;
        }

        if parts < 2 { NONE } else { end }
    }

    fn fstring_end(&self, position: u32) -> u32 {
        let count = count_of(self.tokens.len());
        let mut depth = 0;
        let mut scan = position;

        while scan < count {
            let kind = self.raw[scan as usize];

            if kind == Kind::FStringStart {
                depth += 1;
            }

            if kind == Kind::FStringEnd {
                depth -= 1;

                if depth == 0 {
                    return scan;
                }
            }

            scan += 1;
        }

        NONE
    }

    fn joined(&mut self, position: u32, end: u32) -> Option<Span> {
        let (bytes, format) = self.marks_of(position, end)?;

        self.written_join(position, end, bytes, format)
    }

    fn marks_of(&self, position: u32, end: u32) -> Option<(bool, bool)> {
        let mut bytes = false;
        let mut format = false;
        let mut scan = position;

        while scan <= end {
            let held = self.part(scan)?;
            let text = &self.source[held.range()];
            let marks = &text[..prefix_of(text)];

            bytes = bytes || marks.iter().any(|byte| matches!(byte, b'B' | b'b'));
            format = format || marks.iter().any(|byte| matches!(byte, b'F' | b'f'));
            scan = self.part_end(scan) + 1;
        }

        Some((bytes, format))
    }

    fn joinable(&self, position: u32) -> u32 {
        let end = self.concat_end(position);

        if end == NONE {
            return NONE;
        }

        let Some((_, format)) = self.marks_of(position, end) else {
            return NONE;
        };

        if self.join_quote(position, end, format).is_none() {
            return NONE;
        }

        if !format {
            return end;
        }

        let mut scan = position;

        while scan <= end {
            let Some(held) = self.part(scan) else {
                return NONE;
            };

            let text = &self.source[held.range()];
            let at = prefix_of(text);
            let body = &text[at + 1..text.len() - 1];
            let formats = text[..at].iter().any(|byte| matches!(byte, b'F' | b'f'));

            if !formats && body.iter().any(|byte| matches!(byte, b'{' | b'}')) {
                return NONE;
            }

            scan = self.part_end(scan) + 1;
        }

        end
    }

    fn part(&self, position: u32) -> Option<Span> {
        let end = self.part_end(position);
        let offset = self.tokens[position as usize].offset;

        let held = Span {
            length: self.tokens[end as usize].end() - offset,
            offset,
        };

        let text = &self.source[held.range()];
        let at = prefix_of(text);
        let rest = &text[at..];

        if text[..at].iter().any(|byte| matches!(byte, b'R' | b'r')) {
            return None;
        }

        if rest.starts_with(TRIPLE_DOUBLE) || rest.starts_with(TRIPLE_SINGLE) || rest.len() < 2 {
            return None;
        }

        Some(held)
    }

    fn join_quote(&self, position: u32, end: u32, format: bool) -> Option<u8> {
        let wanted = match self.quote {
            QuotePreference::Single => b'\'',
            QuotePreference::Double | QuotePreference::Preserve => b'"',
        };

        let other = other_quote(wanted);
        let mut alone = 0;
        let mut held = 0;
        let mut scan = position;

        while scan <= end {
            self.part(scan)?;

            alone += self.part_escapes(scan, other);
            held += self.part_escapes(scan, wanted);
            scan = self.part_end(scan) + 1;
        }

        let quote = if alone < held { other } else { wanted };

        (!format || self.join_swaps(position, end, quote)).then_some(quote)
    }

    fn part_escapes(&self, position: u32, quote: u8) -> u32 {
        let end = self.part_end(position);

        if self.raw[position as usize] != Kind::FStringStart {
            let text = &self.source[self.tokens[position as usize].span().range()];
            let at = prefix_of(text);

            return escapes_of(&text[at + 1..text.len() - 1], quote);
        }

        let mut count = 0;
        let mut depth = 0_u32;
        let mut scan = position;

        while scan <= end {
            let kind = self.raw[scan as usize];

            depth += u32::from(kind == Kind::FStringStart);

            if kind == Kind::FStringMiddle && depth == 1 {
                let body = &self.source[self.tokens[scan as usize].span().range()];

                count += escapes_of(body, quote);
            }

            depth -= u32::from(kind == Kind::FStringEnd);
            scan += 1;
        }

        count
    }

    fn join_swaps(&self, position: u32, end: u32, quote: u8) -> bool {
        let mut scan = position;

        while scan <= end {
            let Some(piece) = self.part(scan) else {
                return false;
            };

            let text = &self.source[piece.range()];
            let at = prefix_of(text);

            if self.raw[scan as usize] != Kind::FStringStart
                && text[at] != quote
                && text[at + 1..text.len() - 1].contains(&quote)
            {
                return false;
            }

            scan = self.part_end(scan) + 1;
        }

        true
    }

    fn part_end(&self, position: u32) -> u32 {
        if self.raw[position as usize] == Kind::FStringStart {
            return self.fstring_end(position);
        }

        position
    }

    fn written_join(&mut self, position: u32, end: u32, bytes: bool, format: bool) -> Option<Span> {
        let offset = self.arena.count();
        let mut written = true;

        if bytes {
            written = written && self.arena.push_bytes(b"b");
        }

        if format {
            written = written && self.arena.push_bytes(b"f");
        }

        let quote = self.join_quote(position, end, format)?;

        written = written && self.arena.push_bytes(&[quote]);

        let mut scan = position;

        while scan <= end && written {
            let stop = self.part_end(scan);

            if self.raw[scan as usize] == Kind::FStringStart {
                written = self.refielded(scan, stop, quote);
                scan = stop + 1;

                continue;
            }

            let held = self.part(scan)?;
            let text = &self.source[held.range()];
            let at = prefix_of(text);
            let body = &text[at + 1..text.len() - 1];

            if format && body.iter().any(|byte| matches!(byte, b'{' | b'}')) {
                self.arena.truncate(offset);

                return None;
            }

            written = quoted_body(self.arena, body, quote);
            scan = stop + 1;
        }

        written = written && self.arena.push_bytes(&[quote]);

        if !written {
            self.arena.truncate(offset);

            return None;
        }

        Some(Span {
            length: self.arena.count() - offset,
            offset,
        })
    }

    fn listed(&self, position: u32) -> bool {
        let count = count_of(self.tokens.len());
        let mut commas = 0;
        let mut depth = 0;
        let mut previous = None;
        let mut scan = position;

        while scan < count {
            let kind = self.raw[scan as usize];

            scan += 1;

            if is_open(kind) {
                depth += 1;
            }

            if is_close(kind) {
                depth -= 1;

                if depth == 0 {
                    return commas > u32::from(previous == Some(Kind::Comma));
                }
            }

            if kind == Kind::Comma && depth == 1 {
                commas += 1;
            }

            if !is_layout(kind) && kind != Kind::Comment {
                previous = Some(kind);
            }
        }

        false
    }

    fn hollow(&self, position: u32) -> bool {
        let count = count_of(self.tokens.len());
        let mut scan = position + 1;

        while scan < count && is_layout(self.raw[scan as usize]) {
            scan += 1;
        }

        scan < count && is_close(self.raw[scan as usize])
    }

    fn hugs_literal(&self, position: u32, call: bool) -> bool {
        if !call || self.raw[position as usize] != Kind::ParenOpen {
            return false;
        }

        let count = count_of(self.tokens.len());
        let mut scan = position + 1;

        while scan < count && is_layout(self.raw[scan as usize]) {
            scan += 1;
        }

        if scan >= count {
            return false;
        }

        let opened = self.tokens[position as usize].end() as usize;
        let starts = self.tokens[scan as usize].offset as usize;

        if starts > opened && self.source[opened..starts].contains(&b'\n') {
            return false;
        }

        let end = self.part_end(scan);

        if end == NONE || end >= count {
            return false;
        }

        let literal = Span {
            length: self.tokens[end as usize].end() - self.tokens[scan as usize].offset,
            offset: self.tokens[scan as usize].offset,
        };

        if !matches!(
            self.raw[scan as usize],
            Kind::FStringStart | Kind::StringBytes | Kind::StringPlain
        ) || !self.source[literal.range()].contains(&b'\n')
        {
            return false;
        }

        let mut after = end + 1;

        while after < count && is_layout(self.raw[after as usize]) {
            after += 1;
        }

        after < count && is_close(self.raw[after as usize])
    }

    fn priority_of(&self, position: u32) -> u8 {
        let count = count_of(self.tokens.len());
        let mut depth = 0;
        let mut found = 0;
        let mut held = Splits::new();
        let mut previous = None;
        let mut repeats = 0;
        let mut scan = position;

        while scan < count {
            let kind = self.raw[scan as usize];

            scan += 1;

            if is_layout(kind) || kind == Kind::Comment {
                continue;
            }

            if is_close(kind) {
                depth -= 1;

                if depth == 0 {
                    break;
                }
            }

            if depth == 1 {
                let priority = held.step(kind, previous);

                if priority > found {
                    found = priority;
                    repeats = 0;
                }

                repeats += u32::from(priority > 0 && priority == found);
            }

            depth += u32::from(is_open(kind));
            previous = Some(kind);
        }

        if found == PRIORITY_DOT && repeats < 2 {
            return 0;
        }

        found
    }

    fn priority_of_element(&self, position: u32, mut previous: Option<Kind>, cap: u8) -> u8 {
        let count = count_of(self.tokens.len());
        let mut depth = 0;
        let mut found = 0;
        let mut held = self.frame().splits;
        let mut repeats = 0;
        let mut scan = position;

        while scan < count {
            let kind = self.raw[scan as usize];

            scan += 1;

            if is_layout(kind) || kind == Kind::Comment {
                continue;
            }

            if is_close(kind) {
                if depth == 0 {
                    break;
                }

                depth -= 1;
            }

            if depth == 0 {
                let priority = held.step(kind, previous);

                if priority >= cap {
                    break;
                }

                if kind == Kind::Colon
                    && self.frame().kind == Kind::BraceOpen
                    && self.entered(scan - 1)
                {
                    found = 0;
                    repeats = 0;
                }

                if priority > found {
                    found = priority;
                    repeats = 0;
                }

                repeats += u32::from(priority > 0 && priority == found);
            }

            depth += u32::from(is_open(kind));
            previous = Some(kind);
        }

        if found == PRIORITY_DOT && repeats < 2 {
            return 0;
        }

        found
    }

    fn ends_element(&mut self, kept: u32) -> bool {
        if self.depth == 0 && self.wrap == NONE {
            return true;
        }

        while self.frame().level_count > kept {
            let mut held = self.frame();

            held.level_count -= 1;

            let closes = held.group_count > held.level_count && self.concat_at == NONE;

            held.group_count -= u32::from(closes);
            self.set_frame(held);

            if closes && !self.document.push(Element::GroupClose) {
                return false;
            }
        }

        true
    }

    fn remarks_trail(&self, position: u32) -> bool {
        let count = count_of(self.tokens.len());
        let mut found = NONE;
        let mut scan = position + 1;

        while scan < count {
            let kind = self.raw[scan as usize];

            if is_layout(kind) {
                scan += 1;

                continue;
            }

            if kind != Kind::Comment || !self.heads_line(scan) {
                break;
            }

            if found != NONE && self.blanked_above(scan) {
                return true;
            }

            found = scan;
            scan += 1;
        }

        found != NONE && (scan == count || self.blanked_above(scan))
    }

    fn blanked_above(&self, position: u32) -> bool {
        self.blanks_before(position, self.tokens[position as usize].offset) > 0
    }

    fn remarks_next(&self, position: u32) -> bool {
        let count = count_of(self.tokens.len());
        let mut scan = position + 1;

        while scan < count {
            let kind = self.raw[scan as usize];

            if kind == Kind::Comment {
                return self.heads_line(scan);
            }

            if !is_layout(kind) {
                return false;
            }

            scan += 1;
        }

        false
    }

    fn hollows(&self, position: u32, own_line: bool) -> bool {
        if self.previous.is_some_and(is_open) {
            return true;
        }

        if own_line || self.heads_line(position) {
            return false;
        }

        let count = count_of(self.tokens.len());
        let mut scan = position + 1;

        while scan < count {
            let kind = self.raw[scan as usize];

            if kind == Kind::Comment || is_layout(kind) {
                scan += 1;

                continue;
            }

            return is_close(kind);
        }

        false
    }

    fn closes_deferred(&mut self, hollows: bool) -> bool {
        if self.depth == 0 && self.wrap == NONE {
            return true;
        }

        while self.frame().group_count > 0 {
            let mut frame = self.frame();

            frame.group_count -= 1;
            self.set_frame(frame);

            if !self.document.push(Element::GroupClose) {
                return false;
            }
        }

        let mut held = self.frame();

        if !hollows
            || self.depth == 0
            || held.sole
            || held.hollow
            || matches!(held.priority, PRIORITY_COMMA | PRIORITY_COMPREHENSION)
        {
            return true;
        }

        held.hollow = true;
        self.set_frame(held);

        self.document.push(Element::GroupClose)
    }

    fn opens_deferred(&mut self) -> bool {
        if self.depth == 0 && self.wrap == NONE {
            return true;
        }

        let mut hollow = self.frame();

        if self.depth > 0 && hollow.hollow {
            hollow.hollow = false;
            self.set_frame(hollow);

            if !self.document.push(Element::GroupOpen) {
                return false;
            }
        }

        while self.frame().group_count > self.frame().level_count {
            let mut held = self.frame();

            held.group_count -= 1;
            self.set_frame(held);

            if !self.document.push(Element::GroupClose) {
                return false;
            }
        }

        while self.frame().group_count < self.frame().level_count {
            let mut held = self.frame();

            held.group_count += 1;
            self.set_frame(held);

            if !self.document.push(Element::GroupOpen) {
                return false;
            }
        }

        true
    }

    fn starts_element(&mut self, position: u32, kind: Kind, cap: u8) -> bool {
        if self.depth == 0 && self.wrap == NONE {
            return true;
        }

        let mut held = cap;

        while held > 0 {
            let priority = self.priority_of_element(position + 1, Some(kind), held);
            let mut frame = self.frame();
            let at = frame.level_count;

            if priority == 0 || at == ELEMENT_DEPTH_MAX {
                break;
            }

            frame.levels[at as usize] = priority;
            frame.level_count = at + 1;

            let opens = self.concat_at == NONE && !self.remarks_next(position);

            if opens {
                frame.group_count = at + 1;
            }

            self.set_frame(frame);

            if opens && !self.document.push(Element::GroupOpen) {
                return false;
            }

            held = priority;
        }

        true
    }

    fn inlined(&mut self, position: u32) -> bool {
        let spaced = self.spaced(Kind::Colon);
        let held = self.text(position, spaced);
        let column = self.line_indent(self.tokens[position as usize].offset);

        self.inline += 1;
        self.pending_break = true;

        held && self.indented(position, column + self.indent_width)
    }

    fn remark(&mut self, position: u32, own_line: bool) -> bool {
        let standalone = !own_line && self.heads_line(position);

        if standalone && !self.separates(position) {
            return false;
        }

        if standalone && !self.parted() && !self.document.push(Element::HardLine) {
            return false;
        }

        if !own_line && !standalone && !self.separates(position) {
            return false;
        }

        let held = if own_line || standalone {
            self.text(position, false)
        } else {
            let gap = self.document.literal_span(self.literals.1);
            let held = self.tokens[position as usize].span();
            let marked = pragmatic(&self.source[held.range()]);

            (!marked || self.document.push(Element::Pragma))
                && self
                    .document
                    .push(Element::Text(ElementSource::Literal, gap))
                && self.text(position, false)
        };

        self.pending_break = true;

        held
    }

    fn separates(&mut self, position: u32) -> bool {
        if self.depth == 0 {
            return true;
        }

        let held = self.frame();
        let prior = self.prior_token(position, 0);

        if held.hugged
            || held.trailed
            || self.previous == Some(Kind::Comma)
            || prior.is_some_and(|at| self.raw[at as usize] == Kind::Comment)
            || !held.commas && !held.owes
        {
            return true;
        }

        let count = count_of(self.tokens.len());
        let mut scan = position + 1;

        while scan < count {
            let kind = self.raw[scan as usize];

            if kind == Kind::Comment || is_layout(kind) {
                scan += 1;

                continue;
            }

            if !is_close(kind) || opened_by(kind) != held.kind {
                return true;
            }

            break;
        }

        let comma = self.document.literal_span(self.literals.0);

        self.document.push(Element::IfBroken(comma))
    }

    fn suite(&mut self, position: u32) -> Option<bool> {
        if !opens_suite(self.line_first) {
            return None;
        }

        let definition = self.opens_definition(self.line_first_at);
        let gathers = definition && self.stubbed_at(position) != NONE;

        self.stubbed = definition && (gathers || self.stubs(position));

        if gathers {
            return Some(self.stubbing(position));
        }

        if !self.stubbed && self.inlines(position) {
            return Some(self.inlined(position));
        }

        None
    }

    fn stubbing(&mut self, position: u32) -> bool {
        let ellipsis = self.stubbed_at(position);
        let end = self.stubbed_end(ellipsis);
        let remark = self.rider(ellipsis);
        let spaced = self.spaced(Kind::Colon);

        let held = self.text(position, spaced)
            && self.document.push(Element::Space)
            && self.text(ellipsis, false)
            && (remark == NONE || self.rides(remark));

        self.pending_break = true;
        self.until = end + 1;

        held
    }

    fn stubbed_at(&self, position: u32) -> u32 {
        let count = count_of(self.tokens.len());
        let mut indent = false;
        let mut scan = position + 1;

        while scan < count {
            let kind = self.raw[scan as usize];

            if kind == Kind::Newline {
                scan += 1;

                continue;
            }

            if kind == Kind::Indent && !indent {
                indent = true;
                scan += 1;

                continue;
            }

            if kind == Kind::Ellipsis && indent && self.stubbed_end(scan) != NONE {
                return scan;
            }

            return NONE;
        }

        NONE
    }

    fn stubbed_end(&self, position: u32) -> u32 {
        let count = count_of(self.tokens.len());
        let mut remarked = false;
        let mut scan = position + 1;

        while scan < count {
            let kind = self.raw[scan as usize];

            if matches!(kind, Kind::Newline | Kind::Semicolon) {
                scan += 1;

                continue;
            }

            if kind == Kind::Comment && !remarked && !self.heads_line(scan) {
                remarked = true;
                scan += 1;

                continue;
            }

            if kind == Kind::Dedent {
                return scan;
            }

            return NONE;
        }

        NONE
    }

    fn stubs(&self, position: u32) -> bool {
        let count = count_of(self.tokens.len());
        let mut found = false;
        let mut scan = position + 1;

        while scan < count {
            let kind = self.raw[scan as usize];

            scan += 1;

            if is_layout(kind) {
                return found && kind == Kind::Newline;
            }

            if matches!(kind, Kind::Comment | Kind::Semicolon) && found {
                continue;
            }

            if kind != Kind::Ellipsis || found {
                return false;
            }

            found = true;
        }

        false
    }

    fn inlines(&self, position: u32) -> bool {
        let count = count_of(self.tokens.len());
        let mut scan = position + 1;

        while scan < count {
            let kind = self.raw[scan as usize];

            if kind == Kind::Comment || kind == Kind::Newline {
                return false;
            }

            if !is_layout(kind) {
                return true;
            }

            scan += 1;
        }

        false
    }

    fn outlines(&mut self) -> bool {
        while self.inline > 0 {
            self.inline -= 1;
            self.indent -= 1;
            self.closed = self.blocks[self.indent as usize];
            self.after = self.after || self.closed;

            if !self.document.push(Element::Dedent) {
                return false;
            }
        }

        true
    }

    fn parting(&mut self, kind: Kind) -> u8 {
        let previous = self.previous;

        if self.depth == 0 {
            return Splits::new().step(kind, previous);
        }

        self.frames[self.depth as usize - 1]
            .splits
            .step(kind, previous)
    }

    fn valued(&self, position: u32) -> Option<u32> {
        let count = count_of(self.tokens.len());
        let mut depth = 0_u32;
        let mut previous = None;
        let mut prior = None;
        let mut splits = Splits::new();
        let mut scan = position;

        while scan < count {
            let kind = self.raw[scan as usize];

            scan += 1;

            if is_layout(kind) || kind == Kind::Comment {
                continue;
            }

            if is_close(kind) {
                if depth == 0 {
                    return None;
                }

                depth -= 1;
            }

            if depth == 0 {
                if kind == Kind::Comma {
                    return None;
                }

                if is_open(kind) && self.holds(scan) {
                    return Some(scan - 1);
                }

                if splits.step(kind, previous) > 0 {
                    return prior;
                }
            }

            depth += u32::from(is_open(kind));
            previous = Some(kind);
            prior = Some(scan - 1);
        }

        None
    }

    fn holds(&self, position: u32) -> bool {
        let count = count_of(self.tokens.len());
        let mut scan = position;

        while scan < count {
            let kind = self.raw[scan as usize];

            if !is_layout(kind) && kind != Kind::Comment {
                return !is_close(kind);
            }

            scan += 1;
        }

        false
    }

    fn entry_at(&self, position: u32) -> Option<u32> {
        let mut depth = 0_u32;
        let mut scan = position;

        while scan > 0 {
            scan -= 1;

            let kind = self.raw[scan as usize];

            if is_open(kind) {
                if depth == 0 {
                    return Some(scan + 1);
                }

                depth -= 1;
            } else if is_close(kind) {
                depth += 1;
            } else if depth == 0 && kind == Kind::Comma {
                return Some(scan + 1);
            }
        }

        None
    }

    fn measured(&self, from: u32, to: u32) -> u32 {
        let mut held = None;
        let mut scan = from;
        let mut width = 0;

        while scan <= to {
            let kind = self.raw[scan as usize];
            let token = self.tokens[scan as usize];

            if is_layout(kind) || token.length == 0 {
                scan += 1;

                continue;
            }

            if kind == Kind::FStringStart {
                let end = self.format_end(scan);

                width += self.tokens[end as usize].end() - token.offset
                    + u32::from(held.is_some_and(|prior| blanked(prior, kind)));

                held = Some(Kind::FStringEnd);
                scan = end + 1;

                continue;
            }

            let spaced = kind != Kind::Colon && held.is_some_and(|prior| blanked(prior, kind));

            width += columns(self.source, token.offset, token.end()) + u32::from(spaced);
            held = Some(kind);
            scan += 1;
        }

        width
    }

    fn entered(&self, position: u32) -> bool {
        let Some(head) = self.valued(position + 1) else {
            return false;
        };

        let Some(start) = self.entry_at(position) else {
            return false;
        };

        (self.indent + self.depth) * self.indent_width + self.measured(start, head)
            <= self.line_width
    }

    fn keyed(&self, position: u32) -> bool {
        if self.depth == 0 || self.frame().kind != Kind::BraceOpen {
            return false;
        }

        let count = count_of(self.tokens.len());
        let mut depth = 0_u32;
        let mut scan = position;

        while scan < count {
            let kind = self.raw[scan as usize];

            if is_close(kind) {
                if depth == 0 {
                    return false;
                }

                depth -= 1;
            } else if is_open(kind) {
                depth += 1;
            } else if depth == 0 {
                if kind == Kind::Comma || kind == Kind::Newline {
                    return false;
                }

                if kind == Kind::Colon {
                    return self.entered(scan);
                }
            }

            scan += 1;
        }

        false
    }

    fn priority_of_line(&self, position: u32) -> u8 {
        let count = count_of(self.tokens.len());
        let mut depth = 0_u32;
        let mut found = 0;
        let mut previous = self.previous;
        let mut splits = Splits::new();
        let mut scan = position + 1;

        while scan < count {
            let kind = self.raw[scan as usize];

            scan += 1;

            if kind == Kind::Newline || depth == 0 && kind == Kind::Colon {
                break;
            }

            if is_layout(kind) {
                continue;
            }

            if depth == 0 {
                let priority = splits.step(kind, previous);

                if priority > found {
                    found = priority;
                }
            }

            if is_open(kind) {
                depth += 1;
            } else if is_close(kind) {
                depth = depth.saturating_sub(1);
            }

            previous = Some(kind);
        }

        found
    }

    fn rides(&mut self, position: u32) -> bool {
        let gap = self.document.literal_span(self.literals.1);

        self.until = position + 1;

        self.document
            .push(Element::Text(ElementSource::Literal, gap))
            && self.text(position, false)
    }

    fn remarked(&mut self, span: Span) -> Option<Span> {
        let bytes = &self.source[span.range()];
        let held = *bytes.get(1)?;

        if matches!(held, b' ' | b'!' | b'#' | b'\'' | b':') {
            return None;
        }

        let offset = self.arena.count();
        let written = self.arena.push_bytes(b"# ") && self.arena.push_bytes(&bytes[1..]);

        if !written {
            self.arena.truncate(offset);

            return None;
        }

        Some(Span {
            length: self.arena.count() - offset,
            offset,
        })
    }

    fn relit(&mut self, span: Span) -> Option<Span> {
        let bytes = &self.source[span.range()];
        let offset = self.arena.count();

        if !relettered(self.arena, bytes, self.quote) {
            self.arena.truncate(offset);

            return None;
        }

        self.written(offset, bytes)
    }

    fn written(&mut self, offset: u32, bytes: &[u8]) -> Option<Span> {
        let held = Span {
            length: self.arena.count() - offset,
            offset,
        };

        if self.arena.as_bytes()[held.range()] == *bytes {
            self.arena.truncate(offset);

            return None;
        }

        Some(held)
    }

    fn renumber(&mut self, span: Span) -> Option<Span> {
        let bytes = &self.source[span.range()];
        let offset = self.arena.count();

        if !numbered(self.arena, bytes) {
            self.arena.truncate(offset);

            return None;
        }

        self.written(offset, bytes)
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
            if self.lowered > 0 {
                self.lowered -= 1;

                return true;
            }

            self.indent -= 1;
            self.closed = self.blocks[self.indent as usize];
            self.after = self.after || self.closed;

            return self.document.push(Element::Dedent);
        }

        if kind == Kind::Indent {
            return self.indented(position, self.column_after(position));
        }

        if kind == Kind::Newline {
            if position == self.wrap && !self.unwrap() {
                return false;
            }

            self.pending_break = *written;

            return self.outlines();
        }

        *written = true;

        if position == self.wrap && !self.unwrap() {
            return false;
        }

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

    fn elides(&mut self, position: u32, kind: Kind) -> bool {
        if kind == Kind::ParenClose
            && self.elisions > 0
            && self.elided[self.elisions as usize - 1] == position
        {
            self.elisions -= 1;

            return true;
        }

        if kind != Kind::ParenOpen || self.elisions == BRACKET_DEPTH_MAX {
            return false;
        }

        if let Some(close) = self.doubled(position) {
            self.elided[self.elisions as usize] = close;
            self.elisions += 1;

            return true;
        }

        if self.depth > 0 {
            return false;
        }

        let Some(close) = self.elidable(position) else {
            return false;
        };

        self.elided[self.elisions as usize] = close;
        self.elisions += 1;

        true
    }

    fn doubled(&self, position: u32) -> Option<u32> {
        let held = self.frame();

        if self.depth == 0
            || self.previous != Some(Kind::ParenOpen)
            || held.call
            || held.kind != Kind::ParenOpen
        {
            return None;
        }

        let close = self.elided_close(position)?;
        let after = self.next_token(close, count_of(self.tokens.len()))?;

        if self.raw[after as usize] != Kind::ParenClose || self.grouped(position, close) {
            return None;
        }

        Some(close)
    }

    fn grouped(&self, open: u32, close: u32) -> bool {
        let mut depth = 0_u32;
        let mut scan = open + 1;

        if self.next_token(open, close).is_none() {
            return true;
        }

        while scan < close {
            let kind = self.raw[scan as usize];

            if is_open(kind) {
                depth += 1;
            } else if is_close(kind) {
                depth -= 1;
            } else if depth == 0 && matches!(kind, Kind::Comma | Kind::ForKeyword) {
                return true;
            }

            scan += 1;
        }

        false
    }

    fn elidable(&self, position: u32) -> Option<u32> {
        let held = self.previous?;
        let asserted = self.line_first == Some(Kind::AssertKeyword) && held == Kind::Comma;
        let targeted = held == Kind::ForKeyword;
        let withed = held == Kind::WithKeyword;

        let iterated = held == Kind::InKeyword
            && matches!(self.line_first, Some(Kind::AsyncKeyword | Kind::ForKeyword));

        let imported = held == Kind::ImportKeyword && self.line_first == Some(Kind::FromKeyword);
        let bodied = held == Kind::Colon && self.lambdas(self.at_previous);

        let excepted = held == Kind::ExceptKeyword
            || held == Kind::Star
                && self.at_previous > 0
                && self.raw[self.at_previous as usize - 1] == Kind::ExceptKeyword;

        if held == Kind::Identifier
            && self.line_first == Some(Kind::ClassKeyword)
            && self.at_previous == self.line_first_at + 1
        {
            let close = self.elided_close(position)?;

            return (close == position + 1).then_some(close);
        }

        let headed = matches!(
            held,
            Kind::ElifKeyword | Kind::IfKeyword | Kind::WhileKeyword
        );

        if !elides_after(held)
            && !asserted
            && !bodied
            && !excepted
            && !targeted
            && !iterated
            && !imported
        {
            return None;
        }

        if held == Kind::IfKeyword && self.line_first != Some(Kind::IfKeyword) {
            return None;
        }

        let close = self.elided_close(position)?;
        let next = self.next_kind(close);

        let ended = matches!(
            next,
            None | Some(
                Kind::AsKeyword | Kind::Colon | Kind::Comment | Kind::Newline | Kind::Semicolon
            )
        ) || self.line_first == Some(Kind::AssertKeyword) && next == Some(Kind::Comma)
            || targeted && next == Some(Kind::InKeyword)
            || held == Kind::Equal && next == Some(Kind::Equal)
            || bodied && (next == Some(Kind::Comma) || next.is_some_and(is_close));

        let after = self.next_token(close, count_of(self.tokens.len()));
        let nested = after.is_some_and(|at| self.elided[..self.elisions as usize].contains(&at));

        if !ended && !nested {
            return None;
        }

        if self.elided_columns(close) > self.line_width && !self.omits(position, close, position) {
            return None;
        }

        if (imported || targeted || withed)
            && self
                .prior_token(close, position)
                .is_some_and(|last| self.raw[last as usize] == Kind::Comma)
        {
            return None;
        }

        self.elided_body(position, close, targeted || imported || withed, headed)
            .then_some(close)
    }

    fn omits(&self, open: u32, ceiling: u32, dropped: u32) -> bool {
        let close = if self.listed_line(open, ceiling) {
            ceiling
        } else {
            self.named_end(open, ceiling)
        };

        let mut count = 0_u32;
        let mut depth = 0_u32;
        let mut found = 0_u8;
        let mut previous = None;
        let mut splits = Splits::new();
        let mut scan = open + 1;

        while scan < close {
            let kind = self.raw[scan as usize];

            if is_layout(kind) {
                scan += 1;

                continue;
            }

            if depth == 0 {
                let priority = splits.step(kind, previous);

                if priority > found {
                    found = priority;
                    count = 0;
                }

                if priority > 0 && priority == found {
                    count += 1;
                }
            }

            if is_open(kind) {
                depth += 1;
            } else if is_close(kind) {
                depth = depth.saturating_sub(1);
            }

            previous = Some(kind);
            scan += 1;
        }

        if count > 1 {
            return false;
        }

        if self.omits_spanned(open, close, found) {
            return true;
        }

        if !matches!(found, 0 | PRIORITY_DOT) && self.spans(open, close) {
            return self.spans_head(open, close);
        }

        if self.omits_whole(open, close) {
            return true;
        }

        if self
            .next_token(open, close)
            .is_some_and(|first| is_open(self.raw[first as usize]) && self.filled(first, close))
        {
            return true;
        }

        if matches!(found, 0 | PRIORITY_DOT) && self.primaried(open, close) {
            return self.omits_primary(open, close, dropped);
        }

        let listed = found == PRIORITY_COMMA
            && self
                .parted_at(open, close, PRIORITY_COMMA)
                .is_some_and(|comma| self.omits_tail(open, comma, dropped));

        listed || self.omits_tail(open, close, dropped)
    }

    fn omits_spanned(&self, open: u32, close: u32, found: u8) -> bool {
        if !matches!(found, 0 | PRIORITY_DOT) {
            return false;
        }

        let Some(first) = self.next_token(open, close) else {
            return false;
        };

        let end = match self.raw[first as usize] {
            Kind::FStringStart => self.format_end(first),
            Kind::StringBytes | Kind::StringPlain => first,
            _ => return false,
        };

        let held = Span {
            length: self.tokens[end as usize].end() - self.tokens[first as usize].offset,
            offset: self.tokens[first as usize].offset,
        };

        self.source[held.range()].contains(&b'\n')
    }

    fn spans(&self, open: u32, close: u32) -> bool {
        let mut depth = 0_u32;
        let mut scan = open + 1;

        while scan < close {
            let kind = self.raw[scan as usize];
            let held = self.tokens[scan as usize].span();

            if depth == 0 && self.source[held.range()].contains(&b'\n') {
                return true;
            }

            if is_open(kind) {
                depth += 1;
            } else if is_close(kind) {
                depth -= 1;
            }

            scan += 1;
        }

        false
    }

    fn spans_head(&self, open: u32, close: u32) -> bool {
        let Some(first) = self.next_token(open, close) else {
            return false;
        };

        let end = match self.raw[first as usize] {
            Kind::FStringStart => self.format_end(first),
            Kind::StringBytes | Kind::StringPlain => first,
            _ => return false,
        };

        let held = Span {
            length: self.tokens[end as usize].end() - self.tokens[first as usize].offset,
            offset: self.tokens[first as usize].offset,
        };

        if !self.source[held.range()].contains(&b'\n') {
            return false;
        }

        let parted = self.next_token(end, close).is_some_and(|at| {
            matches!(
                self.raw[at as usize],
                Kind::FStringStart | Kind::StringBytes | Kind::StringPlain
            )
        });

        !parted
            && self
                .prior_token(close, open)
                .is_some_and(|last| is_close(self.raw[last as usize]))
    }

    fn omits_whole(&self, open: u32, close: u32) -> bool {
        let Some(last) = self.prior_token(close, open) else {
            return false;
        };

        if !is_close(self.raw[last as usize]) {
            return false;
        }

        let Some(opening) = self.opened_at(last) else {
            return false;
        };

        let mut scan = open;

        while let Some(held) = self.next_token(scan, close) {
            if held == opening {
                return true;
            }

            if !is_unary(self.raw[held as usize]) {
                return false;
            }

            scan = held;
        }

        false
    }

    fn omits_primary(&self, open: u32, close: u32, dropped: u32) -> bool {
        if !self.wrap_opens(open, dropped) {
            return true;
        }

        if self.omits_target(open, dropped) {
            return true;
        }

        match self.primary_bracket(open, close) {
            Some(opening) => self.omits_width(open, opening, dropped),
            None => !self.wrap_holds(open, close),
        }
    }

    fn omits_target(&self, open: u32, dropped: u32) -> bool {
        let equal = if self.raw[open as usize] == Kind::Equal {
            open
        } else if self.raw[open as usize] == Kind::ParenOpen {
            match self.prior_token(open, self.line_first_at) {
                Some(held) if self.raw[held as usize] == Kind::Equal => held,
                _ => return false,
            }
        } else {
            return false;
        };

        let chained = self.target_end(equal + 1) != NONE;

        if self.assigned(equal) && !chained {
            return false;
        }

        self.target_bracket(equal, dropped, !chained)
    }

    fn target_bracket(&self, end: u32, dropped: u32, trailed: bool) -> bool {
        let mut scan = end;

        while scan > self.line_first_at {
            scan -= 1;

            if !is_close(self.raw[scan as usize]) {
                continue;
            }

            let Some(opening) = self.opened_at(scan) else {
                return false;
            };

            if !self.filled(opening, scan) {
                scan = opening;

                continue;
            }

            return (!trailed || self.next_token(scan, end).is_some())
                && self.head_columns(opening, dropped) <= self.line_width;
        }

        false
    }

    fn assigned(&self, position: u32) -> bool {
        let mut depth = 0_u32;
        let mut scan = position;

        while scan > self.line_first_at {
            scan -= 1;

            let kind = self.raw[scan as usize];

            if is_close(kind) {
                depth += 1;
            } else if is_open(kind) {
                depth = depth.saturating_sub(1);
            } else if depth == 0 && kind == Kind::Equal {
                return true;
            }
        }

        false
    }

    fn format_end(&self, position: u32) -> u32 {
        let count = count_of(self.tokens.len());
        let mut depth = 0_u32;
        let mut scan = position;

        while scan < count {
            let kind = self.raw[scan as usize];

            depth += u32::from(kind == Kind::FStringStart);

            if kind == Kind::FStringEnd {
                depth -= 1;

                if depth == 0 {
                    return scan;
                }
            }

            scan += 1;
        }

        position
    }

    fn wrap_opens(&self, open: u32, dropped: u32) -> bool {
        self.head_columns(open, dropped) + 2 <= self.line_width
    }

    fn wrap_holds(&self, open: u32, close: u32) -> bool {
        let mut held = None;
        let mut scan = open + 1;
        let mut width = (self.indent + 1) * self.indent_width;

        while scan < close {
            let kind = self.raw[scan as usize];
            let token = self.tokens[scan as usize];

            if is_layout(kind) || token.length == 0 {
                scan += 1;

                continue;
            }

            if kind == Kind::FStringStart {
                let end = self.format_end(scan);

                width += self.tokens[end as usize].end() - token.offset
                    + u32::from(held.is_some_and(|prior| blanked(prior, kind)));

                held = Some(Kind::FStringEnd);
                scan = end + 1;

                continue;
            }

            width += columns(self.source, token.offset, token.end())
                + u32::from(held.is_some_and(|prior| blanked(prior, kind)));

            held = Some(kind);
            scan += 1;
        }

        width <= self.line_width
    }

    fn element_start(&self, ceiling: u32) -> u32 {
        if self.depth == 0 {
            return self.line_first_at;
        }

        let mut depth = 0_u32;
        let mut scan = ceiling;

        while scan > self.line_first_at {
            scan -= 1;

            let kind = self.raw[scan as usize];

            if is_close(kind) {
                depth += 1;
            } else if is_open(kind) {
                if depth == 0 {
                    return scan + 1;
                }

                depth -= 1;
            } else if depth == 0 && kind == Kind::Comma {
                return scan + 1;
            }
        }

        self.line_first_at
    }

    fn head_columns(&self, ceiling: u32, dropped: u32) -> u32 {
        let start = self.element_start(ceiling);
        let mut held = None;
        let mut scan = start;

        let mut width = if start == self.line_first_at {
            self.indent * self.indent_width
        } else {
            (self.indent + self.depth) * self.indent_width
        };

        while scan <= ceiling {
            let kind = self.raw[scan as usize];
            let token = self.tokens[scan as usize];

            if scan == dropped || is_layout(kind) || token.length == 0 {
                scan += 1;

                continue;
            }

            if kind == Kind::FStringStart {
                let end = self.format_end(scan);

                width += self.tokens[end as usize].end() - token.offset
                    + u32::from(held.is_some_and(|prior| blanked(prior, kind)));

                held = Some(Kind::FStringEnd);
                scan = end + 1;

                continue;
            }

            width += columns(self.source, token.offset, token.end())
                + u32::from(held.is_some_and(|prior| blanked(prior, kind)));

            held = Some(kind);
            scan += 1;
        }

        width
    }

    fn named_end(&self, open: u32, close: u32) -> u32 {
        let Some(last) = self.prior_token(close, open) else {
            return close;
        };

        if self.raw[last as usize] != Kind::Identifier {
            return close;
        }

        match self.prior_token(last, open) {
            Some(word) if self.raw[word as usize] == Kind::AsKeyword => word,
            _ => close,
        }
    }

    fn parted_at(&self, open: u32, close: u32, parting: u8) -> Option<u32> {
        let mut depth = 0_u32;
        let mut previous = None;
        let mut splits = Splits::new();
        let mut scan = open + 1;

        while scan < close {
            let kind = self.raw[scan as usize];

            if is_layout(kind) {
                scan += 1;

                continue;
            }

            if depth == 0 && splits.step(kind, previous) == parting {
                return Some(scan);
            }

            if is_open(kind) {
                depth += 1;
            } else if is_close(kind) {
                depth = depth.saturating_sub(1);
            }

            previous = Some(kind);
            scan += 1;
        }

        None
    }

    fn primaried(&self, open: u32, close: u32) -> bool {
        let mut depth = 0_u32;
        let mut format = 0_u32;
        let mut held = false;
        let mut scan = open + 1;

        while scan < close {
            let kind = self.raw[scan as usize];

            if kind == Kind::FStringStart {
                format += 1;
            }

            if format > 0 {
                format -= u32::from(kind == Kind::FStringEnd);
                scan += 1;

                continue;
            }

            if is_open(kind) {
                depth += 1;
            } else if is_close(kind) {
                depth = depth.saturating_sub(1);
            }

            if depth == 0 && !is_layout(kind) {
                if !held && prefixes(kind) {
                    scan += 1;

                    continue;
                }

                if kind != Kind::Dot && !ends_operand(kind) {
                    return false;
                }

                held = true;
            }

            scan += 1;
        }

        true
    }

    fn filled(&self, position: u32, ceiling: u32) -> bool {
        self.next_token(position, ceiling)
            .is_some_and(|inner| !is_close(self.raw[inner as usize]))
    }

    fn primary_bracket(&self, open: u32, close: u32) -> Option<u32> {
        let mut format = 0_u32;
        let mut scan = open + 1;

        while scan < close {
            let kind = self.raw[scan as usize];

            if kind == Kind::FStringStart {
                format += 1;
            }

            if format > 0 {
                format -= u32::from(kind == Kind::FStringEnd);
                scan += 1;

                continue;
            }

            if is_open(kind) {
                if self.filled(scan, close) {
                    return Some(scan);
                }

                scan = self.next_token(scan, close)?;
            }

            scan += 1;
        }

        None
    }

    fn next_token(&self, position: u32, ceiling: u32) -> Option<u32> {
        let mut scan = position + 1;

        while scan < ceiling {
            if !is_layout(self.raw[scan as usize]) && self.tokens[scan as usize].length > 0 {
                return Some(scan);
            }

            scan += 1;
        }

        None
    }

    fn omits_tail(&self, open: u32, close: u32, dropped: u32) -> bool {
        let Some(last) = self.prior_token(close, open) else {
            return false;
        };

        let kind = self.raw[last as usize];

        if !is_close(kind) {
            return false;
        }

        let Some(opening) = self.opened_at(last) else {
            return false;
        };

        if self.prior_token(last, open) == Some(opening) {
            return false;
        }

        let indexed = kind == Kind::BracketClose
            && self
                .prior_token(opening, open)
                .is_some_and(|held| ends_operand(self.raw[held as usize]));

        !indexed && self.omits_width(open, opening, dropped)
    }

    fn omits_width(&self, open: u32, opening: u32, dropped: u32) -> bool {
        let start = self.element_start(open);
        let mut held = None;
        let mut seen = false;
        let mut scan = start;

        let mut width = if start == self.line_first_at {
            self.indent * self.indent_width
        } else {
            (self.indent + self.depth) * self.indent_width
        };

        while scan <= opening {
            let kind = self.raw[scan as usize];
            let token = self.tokens[scan as usize];

            if scan == dropped || is_layout(kind) || token.length == 0 {
                scan += 1;

                continue;
            }

            if scan < open && is_close(kind) && held == Some(Kind::Comma) {
                width = self.indent * self.indent_width;
                held = None;
            }

            if kind == Kind::FStringStart {
                let end = self.format_end(scan);
                let last = self.tokens[end as usize].end();

                width = self.spanned_from(token.offset, last).unwrap_or_else(|| {
                    width + last - token.offset
                        + u32::from(held.is_some_and(|prior| blanked(prior, kind)))
                });

                held = Some(Kind::FStringEnd);
                scan = end + 1;

                continue;
            }

            width = self
                .spanned_from(token.offset, token.end())
                .unwrap_or_else(|| {
                    width
                        + columns(self.source, token.offset, token.end())
                        + u32::from(held.is_some_and(|prior| blanked(prior, kind)))
                });

            if scan == opening {
                return seen || width <= self.line_width;
            }

            if is_open(kind) && scan > open {
                seen = true;
            }

            held = Some(kind);
            scan += 1;
        }

        false
    }

    fn spanned_from(&self, offset: u32, end: u32) -> Option<u32> {
        let text = &self.source[offset as usize..end as usize];
        let at = text.iter().rposition(|byte| *byte == b'\n')?;

        Some(columns(self.source, offset + count_of(at) + 1, end))
    }

    fn prior_token(&self, position: u32, floor: u32) -> Option<u32> {
        let mut scan = position;

        while scan > floor + 1 {
            scan -= 1;

            if !is_layout(self.raw[scan as usize]) && self.tokens[scan as usize].length > 0 {
                return Some(scan);
            }
        }

        None
    }

    fn opened_at(&self, position: u32) -> Option<u32> {
        let mut depth = 0_u32;
        let mut scan = position + 1;

        while scan > 0 {
            scan -= 1;

            let kind = self.raw[scan as usize];

            if is_close(kind) {
                depth += 1;
            } else if is_open(kind) {
                depth -= 1;

                if depth == 0 {
                    return Some(scan);
                }
            }
        }

        None
    }

    fn tails_line(&self, position: u32) -> bool {
        let count = count_of(self.tokens.len());
        let mut scan = position + 1;

        while scan < count {
            let kind = self.raw[scan as usize];

            if kind == Kind::Newline {
                return true;
            }

            if !is_layout(kind) && !is_close(kind) {
                return false;
            }

            scan += 1;
        }

        true
    }

    fn elided_columns(&self, close: u32) -> u32 {
        if self.line_first_at == NONE {
            return u32::MAX;
        }

        let count = count_of(self.tokens.len());
        let mut depth = 0_u32;
        let mut held = None;
        let mut scan = self.line_first_at;
        let mut width = self.indent * self.indent_width;

        while scan < count {
            let kind = self.raw[scan as usize];
            let token = self.tokens[scan as usize];

            if kind == Kind::Newline {
                break;
            }

            if kind == Kind::Comment {
                width += columns(self.source, token.offset, token.end()) + 2;

                break;
            }

            if scan > close && depth == 0 && kind == Kind::Comma {
                break;
            }

            if is_open(kind) {
                depth += 1;
            } else if is_close(kind) {
                depth = depth.saturating_sub(1);
            }

            if is_layout(kind) || token.length == 0 {
                scan += 1;

                continue;
            }

            let text = &self.source[token.span().range()];
            let headed = depth == 0 && kind == Kind::Colon;

            if let Some(at) = text.iter().position(|byte| *byte == b'\n')
                && self.tails_line(scan)
            {
                width += count_of(at)
                    + u32::from(held.is_some_and(|(prior, _)| blanked(prior, kind) && !headed));

                break;
            }

            let (added, dropped) = match (held, joined_head(kind, text)) {
                (Some((prior, closes)), Some(opens)) if joined(prior) => {
                    (count_of(text.len()), opens + closes)
                }
                (Some((prior, _)), _) => (
                    count_of(text.len()) + u32::from(blanked(prior, kind) && !headed),
                    0,
                ),
                _ => (count_of(text.len()), 0),
            };

            width = (width + added).saturating_sub(dropped);

            held = Some((kind, joined_tail(kind, text)));

            scan += 1;
        }

        width.saturating_sub(2)
    }

    fn elided_close(&self, position: u32) -> Option<u32> {
        let count = count_of(self.tokens.len());
        let mut depth = 0_u32;
        let mut scan = position;

        while scan < count {
            let kind = self.raw[scan as usize];

            if is_open(kind) {
                depth += 1;
            } else if is_close(kind) {
                depth -= 1;

                if depth == 0 {
                    return (kind == Kind::ParenClose).then_some(scan);
                }
            }

            scan += 1;
        }

        None
    }

    fn elided_body(&self, position: u32, close: u32, targeted: bool, headed: bool) -> bool {
        let mut depth = 0_u32;
        let mut held = false;
        let mut prior = None;
        let mut scan = position + 1;

        while scan < close {
            let kind = self.raw[scan as usize];

            let unpacked =
                matches!(kind, Kind::Star | Kind::StarStar) && !prior.is_some_and(ends_operand);

            if is_open(kind) {
                depth += 1;
            } else if is_close(kind) {
                depth -= 1;
            } else if kind == Kind::Comment
                || depth == 0
                    && (unpacked
                        || matches!(kind, Kind::ForKeyword | Kind::YieldKeyword)
                        || kind == Kind::ColonEqual && !headed
                        || kind == Kind::Comma && !targeted)
            {
                return false;
            }

            if matches!(
                kind,
                Kind::FStringStart | Kind::StringBytes | Kind::StringPlain
            ) && prior.is_some_and(|word| {
                matches!(
                    word,
                    Kind::FStringEnd | Kind::StringBytes | Kind::StringPlain
                )
            }) && blank_lines(
                self.source,
                self.tokens[scan as usize - 1].end(),
                self.tokens[scan as usize].offset,
            ) > 0
                && self.part(scan).is_none()
            {
                return false;
            }

            if !is_layout(kind) {
                held = true;
                prior = Some(kind);
            }

            scan += 1;
        }

        held
    }

    fn next_kind(&self, position: u32) -> Option<Kind> {
        let count = count_of(self.tokens.len());
        let mut scan = position + 1;

        while scan < count {
            let kind = self.raw[scan as usize];

            if !matches!(kind, Kind::Dedent | Kind::Indent) && self.tokens[scan as usize].length > 0
            {
                return Some(kind);
            }

            scan += 1;
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

            if self.elides(position, kind) {
                continue;
            }

            if position > self.concat_at && !self.unjoin() {
                return false;
            }

            if !self.enjoin(position) {
                return false;
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
                && !self.indented(self.skip, self.column_after(self.skip))
            {
                return false;
            }

            if kind == Kind::Comment && !self.lower(position) {
                return false;
            }

            if !self.step(position, kind, &mut written) {
                return false;
            }
        }

        if !self.unjoin() {
            return false;
        }

        while self.depth > 0 {
            self.depth -= 1;

            if !self.document.push(Element::GroupClose)
                || !self.document.push(Element::Dedent)
                || !self.document.push(Element::GroupClose)
            {
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

    fn separator(&mut self, position: u32, splits: bool) -> bool {
        let held = self.frame();

        if self.depth == 0 && self.wrap != NONE && splits {
            if self.wrap_ends(position) {
                return self.text(position, false);
            }

            return self.text(position, false) && self.document.push(Element::Line);
        }

        if self.depth == 0 || !splits {
            return self.text(position, false) && self.wrapped(position, Kind::Comma);
        }

        self.frames[self.depth as usize - 1].annotated = false;
        self.frames[self.depth as usize - 1].commas = true;

        if self.trails(position) {
            let commented = self.commented(position);

            if !commented && (held.magic || (!self.magic_trailing_comma && held.magic_source)) {
                return true;
            }

            self.frames[self.depth as usize - 1].trailed = true;

            return self.text(position, false);
        }

        if self.commented(position) {
            return self.text(position, false) && self.ends_element(0);
        }

        let separator = if held.magic {
            Element::HardLine
        } else {
            Element::Line
        };

        let cap = held.priority;

        self.text(position, false)
            && self.ends_element(0)
            && self.document.push(separator)
            && self.starts_element(position, Kind::Comma, cap)
    }

    fn hugs_power(&self, position: u32) -> bool {
        self.simple_operand(position, false) && self.simple_operand(position, true)
    }

    fn simple_operand(&self, position: u32, exponent: bool) -> bool {
        let count = count_of(self.tokens.len());
        let mut scan = position;

        loop {
            let held = if exponent {
                scan + 1
            } else {
                scan.wrapping_sub(1)
            };

            if held >= count {
                return false;
            }

            scan = held;

            let kind = self.raw[scan as usize];

            if is_layout(kind) {
                return false;
            }

            if kind == Kind::Comment {
                continue;
            }

            if exponent && matches!(kind, Kind::Minus | Kind::Plus) {
                continue;
            }

            if !matches!(kind, Kind::Identifier) && !is_number(kind) {
                return false;
            }

            break;
        }

        self.simple_lookup(scan, exponent)
    }

    fn simple_lookup(&self, position: u32, exponent: bool) -> bool {
        let count = count_of(self.tokens.len());
        let mut scan = position;

        loop {
            let held = if exponent {
                scan + 1
            } else {
                scan.wrapping_sub(1)
            };

            if held >= count {
                return true;
            }

            scan = held;

            let kind = self.raw[scan as usize];

            if is_layout(kind) {
                return true;
            }

            if kind == Kind::Comment {
                continue;
            }

            if exponent && matches!(kind, Kind::BracketOpen | Kind::ParenOpen) {
                return false;
            }

            if !exponent && matches!(kind, Kind::BracketClose | Kind::ParenClose) {
                return false;
            }

            if !matches!(kind, Kind::Dot | Kind::Identifier) {
                return true;
            }
        }
    }

    fn spaced(&self, current: Kind) -> bool {
        let Some(previous) = self.previous else {
            return false;
        };

        if self.suppress_space || is_open(previous) {
            return false;
        }

        if current == Kind::Dot {
            if previous == Kind::NumberInteger {
                return true;
            }

            return !ends_operand(previous) && previous != Kind::Dot;
        }

        if previous == Kind::Dot {
            return current == Kind::ImportKeyword;
        }

        if previous == Kind::Ellipsis && self.line_first == Some(Kind::FromKeyword) {
            return current == Kind::ImportKeyword;
        }

        if current == Kind::Colon {
            let held = self.frame();

            return held.complex
                && held.kind == Kind::BracketOpen
                && held.call
                && previous != Kind::Colon
                && !is_open(previous);
        }

        if matches!(current, Kind::Comma | Kind::Semicolon) || is_close(current) {
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
            return held.complex && current != Kind::Colon;
        }

        if (previous == Kind::Equal || current == Kind::Equal) && self.unspaced_default() {
            return false;
        }

        if current == Kind::StarStar && ends_operand(previous) {
            return !self.hugged;
        }

        true
    }

    fn powered(&self, position: u32) -> u32 {
        if !is_unary(self.raw[position as usize]) || self.previous.is_some_and(ends_operand) {
            return NONE;
        }

        let count = count_of(self.tokens.len());
        let mut depth = 0_u32;
        let mut end = NONE;
        let mut found = false;
        let mut previous = None;
        let mut scan = position + 1;

        while scan < count {
            let kind = self.raw[scan as usize];

            if kind == Kind::Newline {
                break;
            }

            if is_layout(kind) || kind == Kind::Comment {
                scan += 1;

                continue;
            }

            if is_close(kind) {
                if depth == 0 {
                    break;
                }

                depth -= 1;
            } else if depth == 0 {
                if matches!(
                    kind,
                    Kind::Colon | Kind::Comma | Kind::Equal | Kind::Semicolon
                ) || parted(kind, previous) > PRIORITY_DOT
                {
                    break;
                }

                found = found || kind == Kind::StarStar;
            }

            depth += u32::from(is_open(kind));
            end = scan;
            previous = Some(kind);
            scan += 1;
        }

        if found { end } else { NONE }
    }

    fn text(&mut self, position: u32, spaced: bool) -> bool {
        let opens = if self.power == NONE {
            self.powered(position)
        } else {
            NONE
        };

        let closes = self.power == position;

        if !self.texted(position, spaced) {
            return false;
        }

        if opens != NONE {
            let worded = self.raw[position as usize] == Kind::NotKeyword;

            let head = self.document.literal_span(if worded {
                self.parentheses.0
            } else {
                self.parentheses.1
            });

            self.power = opens;
            self.suppress_space = true;

            if !self
                .document
                .push(Element::Text(ElementSource::Literal, head))
            {
                return false;
            }
        }

        if closes {
            let close = self.document.literal_span(self.parentheses.2);

            self.power = NONE;
            self.previous = Some(Kind::ParenClose);

            if !self
                .document
                .push(Element::Text(ElementSource::Literal, close))
            {
                return false;
            }
        }

        true
    }

    fn texted(&mut self, position: u32, spaced: bool) -> bool {
        let kind = self.raw[position as usize];

        self.at_previous = position;
        let span = self.tokens[position as usize].span();

        if spaced && !self.document.push(Element::Space) {
            return false;
        }

        if !self.opens_join() {
            return false;
        }

        self.suppress_space = self.suppresses(kind);

        if kind != Kind::Comment {
            self.previous = Some(kind);
        }

        self.mark(kind);

        if span.length == 0 {
            return true;
        }

        if kind == Kind::Comment {
            if let Some(held) = self.remarked(span) {
                return self
                    .document
                    .push(Element::Text(ElementSource::Arena, held));
            }
        }

        if kind == Kind::StringPlain && self.documents(position) {
            self.documented = self.indent == 0 && self.depth == 0 || self.classes_above(position);

            self.documented_past = self.indent == 0 && self.remarks_trail(position);

            return self.docstring(span);
        }

        if matches!(kind, Kind::StringBytes | Kind::StringPlain) {
            if let Some(held) = self.relit(span) {
                return self
                    .document
                    .push(Element::Text(ElementSource::Arena, held));
            }
        }

        if is_number(kind) {
            if let Some(held) = self.renumber(span) {
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

        if body_escaped(&self.source[span.range()]) {
            if let Some(held) = self.requote(span, preference) {
                return self.document.push(Element::VerbatimArena(held));
            }

            return self.document.push(Element::Verbatim(span));
        }

        let Some(held) = self.reindented(span, preference) else {
            if let Some(held) = self.requote(span, preference) {
                return self
                    .document
                    .push(Element::Text(ElementSource::Arena, held));
            }

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

    fn classes_above(&self, position: u32) -> bool {
        let mut back = position;

        while back > 0 {
            back -= 1;

            let kind = self.raw[back as usize];

            if is_layout(kind) || kind == Kind::Comment {
                continue;
            }

            return kind == Kind::Colon && self.opens_class(back);
        }

        false
    }

    fn opens_class(&self, position: u32) -> bool {
        self.raw[self.line_opener_at(position + 1) as usize] == Kind::ClassKeyword
    }

    fn defines(&self, position: u32) -> bool {
        self.opens_definition(self.line_opener_at(position + 1))
    }

    fn reindented(&mut self, span: Span, preference: QuotePreference) -> Option<Span> {
        let text = &self.source[span.range()];
        let (head, tail) = body_edges(text)?;
        let width = self.indent * self.indent_width;
        let offset = self.arena.count();
        let body = &text[head as usize..tail as usize];
        let common = body_indent(body);
        let mut lines = body.split(|byte| *byte == b'\n');
        let mut written = self.arena.push_bytes(&text[..head as usize]);
        let mut ends_open = false;
        let first = lines.next().unwrap_or_default().trim_ascii();
        let quote = settled(text, head, ending_of(body, first, common), preference);

        if first.first() == Some(&quote) {
            written = written && self.arena.push_bytes(b" ");
        }

        written = written && self.arena.push_bytes(first);

        if common != u32::MAX {
            let count = count_of(body.split(|byte| *byte == b'\n').count());

            for (index, line) in lines.enumerate() {
                let stripped = line
                    .get(common as usize..)
                    .unwrap_or_default()
                    .trim_ascii_end();

                written = written && self.arena.push_bytes(b"\n");

                if stripped.is_empty() && count_of(index) + 2 != count {
                    continue;
                }

                for _ in 0..width {
                    written = written && self.arena.push_bytes(b" ");
                }

                written = written && self.arena.push_bytes(stripped);
                ends_open = stripped.is_empty();
            }
        }

        if !ends_open && !first.is_empty() && first.last() == Some(&b'\\') && common == u32::MAX {
            written = written && self.arena.push_bytes(b"\n");

            for _ in 0..width {
                written = written && self.arena.push_bytes(b" ");
            }

            ends_open = true;
        }

        if !ends_open && !first.is_empty() {
            let closing = self
                .arena
                .as_bytes()
                .get(offset as usize..)
                .unwrap_or_default();

            if closing.last() == Some(&quote) || odd_slashes(closing) {
                written = written && self.arena.push_bytes(b" ");
            }
        }

        written = written && self.arena.push_bytes(&text[tail as usize..]);

        if !written {
            self.arena.truncate(offset);

            return None;
        }

        Some(Span {
            length: self.arena.count() - offset,
            offset,
        })
    }

    fn wraps(&self, position: u32, lambdaed: bool) -> bool {
        if !lambdaed && (self.depth > 0 || self.at_lambda != NONE) {
            return false;
        }

        let count = count_of(self.tokens.len());
        let end = self.wrap_end(position);
        let mut depth = 0_u32;
        let mut format = 0_u32;
        let mut held = false;
        let mut remarked = false;
        let mut scan = position + 1;

        if end >= count {
            return false;
        }

        while scan < end {
            let kind = self.raw[scan as usize];

            if is_layout(kind) {
                scan += 1;

                continue;
            }

            let spans = matches!(
                kind,
                Kind::FStringMiddle | Kind::StringBytes | Kind::StringPlain
            );

            if !spans && self.source[self.tokens[scan as usize].span().range()].contains(&b'\n') {
                return false;
            }

            if kind == Kind::FStringStart {
                format += 1;
            }

            if kind == Kind::FStringEnd {
                format -= 1;
            }

            if format > 0 && kind != Kind::FStringStart {
                scan += 1;

                continue;
            }

            if is_open(kind) {
                depth += 1;
            } else if is_close(kind) {
                depth = depth.saturating_sub(1);
            }

            if depth == 0 && matches!(kind, Kind::Equal | Kind::LambdaKeyword | Kind::Semicolon) {
                return false;
            }

            remarked = remarked || kind == Kind::Comment;
            held = true;
            scan += 1;
        }

        held && (!remarked || self.wrap_holds(position, end))
            && self.wrap_rides(end)
            && !self.omits(position, self.wrap_bound(position, end), NONE)
    }

    fn wraps_chain(&self, position: u32, chained: u32) -> bool {
        if self.target_bracket(self.wrap_end(position), NONE, false) {
            return false;
        }

        let count = count_of(self.tokens.len());
        let mut depth = 0_u32;
        let mut scan = chained;

        while scan < count {
            let kind = self.raw[scan as usize];

            if kind == Kind::Newline {
                break;
            }

            if is_open(kind) {
                depth += 1;
            } else if is_close(kind) {
                depth = depth.saturating_sub(1);
            } else if depth == 0 && kind == Kind::Equal && self.wrap_opens(scan, NONE) {
                return false;
            }

            scan += 1;
        }

        self.wrap_opens(position, NONE) && !self.omits(position, chained, NONE)
    }

    fn wrap_bound(&self, position: u32, end: u32) -> u32 {
        let mut scan = end;

        while scan > position + 1 {
            let kind = self.raw[scan as usize - 1];

            if !is_layout(kind) && kind != Kind::Comment {
                break;
            }

            scan -= 1;
        }

        scan
    }

    fn wrap_rides(&self, end: u32) -> bool {
        let riding = self.raw[end as usize] == Kind::Comment;
        let remark = if riding { end } else { self.rider(end) };

        if remark == NONE {
            return true;
        }

        let span = self.tokens[remark as usize].span();
        let closing = if riding { 3 } else { 4 };

        let width = self.indent * self.indent_width
            + closing
            + columns(self.source, span.offset, span.offset + span.length);

        width <= self.line_width
    }

    fn lambdas(&self, position: u32) -> bool {
        let mut depth = 0_u32;
        let mut scan = position;

        while scan > 0 {
            scan -= 1;

            let kind = self.raw[scan as usize];

            if is_close(kind) {
                depth += 1;

                continue;
            }

            if is_open(kind) {
                if depth == 0 {
                    return false;
                }

                depth -= 1;

                continue;
            }

            if depth > 0 {
                continue;
            }

            if kind == Kind::LambdaKeyword {
                return true;
            }

            if is_layout(kind) || matches!(kind, Kind::Colon | Kind::Comment | Kind::Semicolon) {
                return false;
            }
        }

        false
    }

    fn wrap_end(&self, position: u32) -> u32 {
        let count = count_of(self.tokens.len());
        let mut depth = 0_u32;
        let mut scan = position + 1;
        let asserted = self.raw[position as usize] == Kind::AssertKeyword;
        let bodied = self.raw[position as usize] == Kind::Colon;
        let targeted = self.raw[position as usize] == Kind::ForKeyword;
        let mut words = 0_u32;

        while scan < count {
            let kind = self.raw[scan as usize];

            let clause = kind == Kind::ForKeyword
                || kind == Kind::AsyncKeyword && self.next_kind(scan) == Some(Kind::ForKeyword);

            if kind == Kind::Newline
                || depth == 0
                    && (kind == Kind::Colon
                        || asserted && kind == Kind::Comma
                        || targeted && kind == Kind::InKeyword
                        || bodied && (kind == Kind::Comma || clause || is_close(kind))
                        || kind == Kind::Comment && words > 1)
            {
                return scan;
            }

            if kind == Kind::FStringStart {
                words += 1;
                scan = self.format_end(scan) + 1;

                continue;
            }

            if !is_layout(kind) && kind != Kind::Comment {
                words += 1;
            }

            if is_open(kind) {
                depth += 1;
            } else if is_close(kind) {
                depth = depth.saturating_sub(1);
            }

            scan += 1;
        }

        count
    }

    fn wrap(&mut self, position: u32) -> bool {
        let end = self.wrap_end(position);
        let sole = self.listed_line(position, end) || self.line_first == Some(Kind::FromKeyword);
        let tuple = self.tupled_line(position, end);

        self.wrapping(position, end, sole, tuple, false)
    }

    fn wrapping(&mut self, position: u32, end: u32, sole: bool, tuple: bool, heads: bool) -> bool {
        let literal = if heads {
            self.parentheses.1
        } else {
            self.parentheses.0
        };

        let open = self.document.literal_span(literal);

        self.wrap = end;

        self.wrap_sole = sole;
        self.wrap_tuple = tuple;
        self.wrapper = Frame {
            priority: self.priority_of_line(position),
            ..Frame::new()
        };

        let opened = if self.wrap_tuple {
            Element::Text(ElementSource::Literal, open)
        } else {
            Element::IfBroken(open)
        };

        let edge = if self.wrap_tuple && self.wrap_sole {
            Element::HardLine
        } else {
            Element::SoftLine
        };

        self.suppress_space = self.suppress_space || self.wrap_tuple;

        let held = self.document.push(Element::GroupOpen)
            && self.document.push(opened)
            && self.document.push(Element::Indent)
            && self.document.push(edge);

        let cap = self.wrapper.priority;

        held && (self.wrap_sole || self.document.push(Element::GroupOpen))
            && self.starts_element(position, self.raw[position as usize], cap)
    }

    fn wrap_ends(&self, position: u32) -> bool {
        let count = count_of(self.tokens.len());
        let mut scan = position + 1;

        while scan < count && scan < self.wrap {
            let kind = self.raw[scan as usize];

            if !is_layout(kind) && kind != Kind::Comment {
                return false;
            }

            scan += 1;
        }

        true
    }

    fn tupled_line(&self, position: u32, stop: u32) -> bool {
        let count = count_of(self.tokens.len()).min(stop);
        let mut depth = 0_u32;
        let mut previous = None;
        let mut scan = position + 1;

        while scan < count {
            let kind = self.raw[scan as usize];

            scan += 1;

            if kind == Kind::Newline || depth == 0 && kind == Kind::Colon {
                break;
            }

            if is_open(kind) {
                depth += 1;
            } else if is_close(kind) {
                depth = depth.saturating_sub(1);
            }

            if is_layout(kind) || kind == Kind::Comment {
                continue;
            }

            if depth > 0 && kind == Kind::Comma {
                previous = Some(kind);

                continue;
            }

            previous = Some(kind);
        }

        previous == Some(Kind::Comma)
    }

    fn listed_line(&self, position: u32, stop: u32) -> bool {
        let count = count_of(self.tokens.len()).min(stop);
        let mut commas = 0;
        let mut depth = 0_u32;
        let mut previous = None;
        let mut scan = position + 1;

        while scan < count {
            let kind = self.raw[scan as usize];

            scan += 1;

            if kind == Kind::Newline || depth == 0 && kind == Kind::Colon {
                break;
            }

            if is_open(kind) {
                depth += 1;
            } else if is_close(kind) {
                depth = depth.saturating_sub(1);
            }

            if is_layout(kind) || kind == Kind::Comment {
                continue;
            }

            commas += u32::from(depth == 0 && kind == Kind::Comma);
            previous = Some(kind);
        }

        commas > u32::from(previous == Some(Kind::Comma))
    }

    fn unwrap(&mut self) -> bool {
        if !self.ends_element(0) {
            return false;
        }

        let close = self.document.literal_span(self.parentheses.2);
        let comma = self.document.literal_span(self.literals.0);
        let tuple = self.wrap_tuple;
        let sole = self.wrap_sole;
        let trailed = self.previous == Some(Kind::Comma);

        self.wrap = NONE;
        self.wrap_sole = false;
        self.wrap_tuple = false;
        self.wrapper = Frame::new();

        let closed = if tuple {
            Element::Text(ElementSource::Literal, close)
        } else {
            Element::IfBroken(close)
        };

        if tuple {
            self.previous = Some(Kind::ParenClose);
        }

        (sole || self.document.push(Element::GroupClose))
            && (!sole || trailed || self.document.push(Element::IfBroken(comma)))
            && self.document.push(Element::Dedent)
            && self.document.push(Element::SoftLine)
            && self.document.push(closed)
            && self.document.push(Element::GroupClose)
    }

    fn parameterised(&self) -> bool {
        if self.at_previous == NONE || self.previous != Some(Kind::Identifier) {
            return false;
        }

        if self.at_previous > 0
            && matches!(
                self.raw[self.at_previous as usize - 1],
                Kind::ClassKeyword | Kind::DefKeyword
            )
        {
            return true;
        }

        if self.at_previous != self.line_first_at + 1 || self.line_first != Some(Kind::Identifier) {
            return false;
        }

        let span = self.tokens[self.line_first_at as usize].span();

        self.source[span.range()] == *b"type"
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
        if kind == Kind::StarStar {
            return self.hugged || !self.previous.is_some_and(ends_operand);
        }

        if is_open(kind) {
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
            return !held.complex;
        }

        if kind == Kind::Equal && self.unspaced_default() {
            return true;
        }

        matches!(
            kind,
            Kind::At | Kind::Minus | Kind::Plus | Kind::Star | Kind::Tilde
        ) && (self.starting && self.depth == 0 || !self.previous.is_some_and(ends_operand))
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

        if !self.heading(position, kind, own_line) {
            return false;
        }

        self.starting = own_line;

        if kind == Kind::Comment {
            return self.remark(position, own_line);
        }

        if kind == Kind::Colon && self.depth == 0 && self.at_lambda == NONE {
            if let Some(held) = self.suite(position) {
                return held;
            }
        }

        if kind == Kind::Semicolon {
            self.at_previous = position;
            self.pending_break = !opens_suite(self.line_first);

            return true;
        }

        if kind == Kind::StarStar {
            self.hugged = self.hugs_power(position);
        }

        let stepped = self.parting(kind);
        let parting = if self.keyed(position) { 0 } else { stepped };

        if self.defers(position, kind, parting) {
            self.pending_word = position;

            return true;
        }

        if kind == Kind::Comma {
            return self.separator(position, parting == PRIORITY_COMMA);
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

        let kept = self.parts(parting);

        if kept != NONE {
            let separator = if self.parted_join(position) || self.hug_breaks(position) {
                Element::HardLine
            } else if self.spaced(kind) {
                Element::Line
            } else {
                Element::SoftLine
            };

            if !self.ends_element(kept) {
                return false;
            }

            if !own_line && !self.document.push(separator) {
                return false;
            }

            if !self.starts_element(position, kind, parting) {
                return false;
            }

            return self.text(position, false) && self.wrapped(position, kind);
        }

        if self.parted_join(position) {
            return self.document.push(Element::HardLine)
                && self.text(position, false)
                && self.wrapped(position, kind);
        }

        let spaced = self.spaced(kind) || self.slices(position, kind);

        self.text(position, spaced) && self.wrapped(position, kind)
    }

    fn parted_join(&self, position: u32) -> bool {
        if self.concat_at != NONE || self.at_previous == NONE {
            return false;
        }

        if !matches!(
            self.raw[position as usize],
            Kind::FStringStart | Kind::StringBytes | Kind::StringPlain
        ) {
            return false;
        }

        if !matches!(
            self.previous,
            Some(Kind::FStringEnd | Kind::StringBytes | Kind::StringPlain)
        ) {
            return false;
        }

        let mut scan = self.at_previous + 1;

        while scan < position {
            if self.raw[scan as usize] == Kind::Newline {
                return false;
            }

            scan += 1;
        }

        let from = self.tokens[self.at_previous as usize].end();
        let to = self.tokens[position as usize].offset;

        blank_lines(self.source, from, to) > 0
    }

    fn slices(&self, position: u32, kind: Kind) -> bool {
        if kind != Kind::Colon || self.previous != Some(Kind::Colon) {
            return false;
        }

        let held = self.frame();

        held.call
            && held.complex
            && held.kind == Kind::BracketOpen
            && self.next_kind(position) == Some(Kind::BracketClose)
    }

    fn heading(&mut self, position: u32, kind: Kind, own_line: bool) -> bool {
        if kind == Kind::Comment {
            let hollows = self.hollows(position, own_line);

            if !self.closes_deferred(hollows) || own_line && !self.separates(position) {
                return false;
            }
        }

        if self.pending_break && !self.break_line(position) {
            return false;
        }

        if own_line && kind != Kind::Comment && self.concat_at == NONE && !self.opens_deferred() {
            return false;
        }

        if kind != Kind::Comment && !self.deferred() {
            return false;
        }

        if own_line && self.depth == 0 {
            self.line_depth = self.indent;
            self.line_first = Some(kind);
            self.line_first_at = position;

            if self.wrap == NONE && kind != Kind::Comment && !self.wrap_target(position) {
                return false;
            }
        }

        true
    }

    fn deferred(&mut self) -> bool {
        if self.pending_word == NONE {
            return true;
        }

        let held = self.pending_word;

        self.pending_word = NONE;

        self.text(held, false)
    }

    fn defers(&self, position: u32, kind: Kind, parting: u8) -> bool {
        self.pending_word == NONE
            && self.depth > 0
            && parting > 0
            && parting != PRIORITY_COMMA
            && !ends_operand(kind)
            && !is_open(kind)
            && !self.concats_before(position)
            && self.rider(position) != NONE
    }

    fn part_start(&self, end: u32) -> u32 {
        if self.raw[end as usize] != Kind::FStringEnd {
            return end;
        }

        let mut depth = 0_u32;
        let mut scan = end;

        while scan > 0 {
            scan -= 1;

            let kind = self.raw[scan as usize];

            if kind == Kind::FStringEnd {
                depth += 1;
            } else if kind == Kind::FStringStart {
                if depth == 0 {
                    return scan;
                }

                depth -= 1;
            }
        }

        end
    }

    fn part_before(&self, position: u32) -> u32 {
        let mut scan = position;

        while let Some(held) = self.prior_token(scan, 0) {
            if self.raw[held as usize] != Kind::Comment {
                return held;
            }

            scan = held;
        }

        NONE
    }

    fn concats_before(&self, position: u32) -> bool {
        let last = self.part_before(position);

        if last == NONE
            || !matches!(
                self.raw[last as usize],
                Kind::FStringEnd | Kind::StringBytes | Kind::StringPlain
            )
        {
            return false;
        }

        let prior = self.part_before(self.part_start(last));

        prior != NONE
            && matches!(
                self.raw[prior as usize],
                Kind::FStringEnd | Kind::StringBytes | Kind::StringPlain
            )
    }

    fn parts(&self, parting: u8) -> u32 {
        if parting == 0 || parting == PRIORITY_COMMA {
            return NONE;
        }

        let held = self.frame();

        if parting == held.priority {
            return 0;
        }

        for index in 0..held.level_count {
            if held.levels[index as usize] == parting {
                return index + 1;
            }
        }

        NONE
    }

    fn wrapped(&mut self, position: u32, kind: Kind) -> bool {
        if self.wrap != NONE {
            return true;
        }

        let asserted =
            kind == Kind::Comma && self.depth == 0 && self.line_first == Some(Kind::AssertKeyword);

        let chained = if kind == Kind::Equal && self.depth == 0 {
            self.target_end(position + 1)
        } else {
            NONE
        };

        let imported = kind == Kind::ImportKeyword && self.line_first == Some(Kind::FromKeyword);

        let opener = position == self.line_first_at
            || position > 0 && self.raw[position as usize - 1] == Kind::AsyncKeyword;

        let headed = matches!(
            kind,
            Kind::AssertKeyword
                | Kind::AwaitKeyword
                | Kind::ElifKeyword
                | Kind::ExceptKeyword
                | Kind::IfKeyword
                | Kind::WhileKeyword
                | Kind::WithKeyword
        ) && opener;

        let targeted = kind == Kind::ForKeyword && opener;
        let lambdaed = kind == Kind::Colon && self.lambdas(position);
        let yielded = kind == Kind::YieldKeyword;

        if !matches!(kind, Kind::Equal | Kind::ReturnKeyword)
            && !yielded
            && !asserted
            && !headed
            && !imported
            && !lambdaed
            && !targeted
        {
            return true;
        }

        if kind == Kind::Equal && self.depth == 0 && chained != NONE {
            if self.tupled_line(position, chained) {
                let sole = self.listed_line(position, chained);

                return self.wrapping(position, chained, sole, true, false);
            }

            if self.wraps_chain(position, chained) {
                return self.wrapping(position, chained, false, false, false);
            }
        }

        if !yielded && self.next_kind(position) == Some(Kind::YieldKeyword) {
            return true;
        }

        let end = self.wrap_end(position);

        let tupled = self.depth == 0
            && (self.tupled_line(position, end)
                || kind == Kind::Equal
                    && chained == NONE
                    && self.listed_line(position, end)
                    && self.wraps_wide(end));

        if !(tupled || !targeted && self.wraps(position, lambdaed)) {
            return true;
        }

        self.wrap(position)
    }

    fn target_end(&self, position: u32) -> u32 {
        let count = count_of(self.tokens.len());
        let mut depth = 0_u32;
        let mut scan = position;

        while scan < count {
            let kind = self.raw[scan as usize];

            if kind == Kind::Newline || depth == 0 && kind == Kind::Colon {
                return NONE;
            }

            if depth == 0 && kind == Kind::Equal {
                return scan;
            }

            if is_open(kind) {
                depth += 1;
            } else if is_close(kind) {
                depth = depth.saturating_sub(1);
            }

            scan += 1;
        }

        NONE
    }

    fn wrap_target(&mut self, position: u32) -> bool {
        let anchor = position.saturating_sub(1);
        let end = self.target_end(position);

        if end == NONE {
            return self.wrap_bare(anchor, position);
        }

        let sole = self.listed_line(anchor, end);

        if !(self.tupled_line(anchor, end) || sole && self.targets_wide(end)) {
            return true;
        }

        self.wrapping(anchor, end, sole, true, true)
    }

    fn wrap_bare(&mut self, anchor: u32, position: u32) -> bool {
        let kind = self.raw[position as usize];

        if !ends_operand(kind) && !is_open(kind) {
            return true;
        }

        let end = self.wrap_end(anchor);
        let sole = self.listed_line(anchor, end);

        if !(self.tupled_line(anchor, end) || sole && self.wraps_wide(end)) {
            return true;
        }

        self.wrapping(anchor, end, sole, true, true)
    }

    fn wraps_wide(&self, end: u32) -> bool {
        self.indent * self.indent_width + self.measured(self.line_first_at, end) > self.line_width
    }

    fn targets_wide(&self, end: u32) -> bool {
        self.indent * self.indent_width + self.measured(self.line_first_at, end) + 2
            > self.line_width
    }

    fn commented(&self, position: u32) -> bool {
        self.rider(position) != NONE
    }

    fn rider(&self, position: u32) -> u32 {
        let count = count_of(self.tokens.len());
        let from = self.tokens[position as usize].end() as usize;
        let mut scan = position + 1;

        while scan < count {
            let kind = self.raw[scan as usize];

            if kind == Kind::Comment {
                let to = self.tokens[scan as usize].offset as usize;

                if self.source[from..to].contains(&b'\n') {
                    return NONE;
                }

                return scan;
            }

            if !is_layout(kind) {
                return NONE;
            }

            scan += 1;
        }

        NONE
    }

    fn trails(&self, position: u32) -> bool {
        let count = count_of(self.tokens.len());
        let riding = self.commented(position);
        let mut scan = position + 1;

        while scan < count {
            let kind = self.raw[scan as usize];

            scan += 1;

            if is_layout(kind) {
                continue;
            }

            if kind == Kind::Comment && riding {
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
                              argument_four, argument_fivess)\n";

        assert_eq!(
            formatted(source),
            "result = call(\n    argument_one, argument_two, argument_three, argument_four, \
             argument_fivess\n)\n"
        );
    }

    #[test]
    fn a_bracket_whose_body_is_still_too_wide_splits_at_its_commas() {
        let source: &[u8] = b"outcome = call(argument_one, argument_two, argument_three, \
                              argument_four, argument_five, argument_six, argument_seven)\n";

        assert_eq!(
            formatted(source),
            "outcome = call(\n    argument_one,\n    argument_two,\n    argument_three,\n    \
             argument_four,\n    argument_five,\n    argument_six,\n    argument_seven,\n)\n"
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
        assert_eq!(formatted(b"x = f'{y}'\n"), "x = f\"{y}\"\n");
    }

    #[test]
    fn a_format_field_takes_the_spacing_its_own_expression_takes() {
        assert_eq!(
            formatted(b"x = f'{ a!r :>{width}}'\n"),
            "x = f\"{a!r:>{width}}\"\n"
        );

        assert_eq!(formatted(b"x = f'{ \"a\" }'\n"), "x = f\"{'a'}\"\n");
    }

    #[test]
    fn a_remark_at_a_runs_edge_stands_outside_its_group() {
        assert_eq!(
            formatted(b"g(\n    aaa and bbb  # c\n)\n"),
            "g(\n    aaa and bbb  # c\n)\n"
        );

        assert_eq!(
            formatted(b"h(\n    # lead\n    aaa and bbb\n)\n"),
            "h(\n    # lead\n    aaa and bbb\n)\n"
        );

        assert_eq!(
            formatted(b"f(\n    aaa,\n    bbb  # c\n)\n"),
            "f(\n    aaa,\n    bbb,  # c\n)\n"
        );
    }

    #[test]
    fn a_yield_tuple_and_a_multiline_value_take_their_own_pair() {
        assert_eq!(
            formatted(b"def f():\n    yield \"a\", self.b, None,\n"),
            "def f():\n    yield (\n        \"a\",\n        self.b,\n        None,\n    )\n"
        );

        assert_eq!(formatted(b"def g():\n    x = yield 1,\n"), "def g():\n    x = yield (1,)\n");

        assert_eq!(
            formatted(b"Event.action.__doc__ = (\"\"\"Executing the event means executing\naction(*argument, **kwargs)\"\"\")\n"),
            "Event.action.__doc__ = \"\"\"Executing the event means executing\naction(*argument, **kwargs)\"\"\"\n"
        );
    }

    #[test]
    fn an_operator_past_a_remark_leads_the_line_below() {
        let source = concat!(
            "encoded += (\n    b32tab2[c >> 30] +  # bits 1 - 10\n",
            "    b32tab2[c & 0x3FF]  # bits 31 - 40\n)\n"
        );

        let wanted = concat!(
            "encoded += (\n    b32tab2[c >> 30]  # bits 1 - 10\n",
            "    + b32tab2[c & 0x3FF]  # bits 31 - 40\n)\n"
        );

        assert_eq!(formatted(source.as_bytes()), wanted);
    }

    #[test]
    fn a_parted_concatenation_the_join_cannot_merge_keeps_its_lines() {
        assert_eq!(
            formatted(b"a = re.compile(r\"(?:x \"\n    r\".*\"\n    r\"\\[\\]\")\n"),
            "a = re.compile(\n    r\"(?:x \"\n    r\".*\"\n    r\"\\[\\]\"\n)\n"
        );

        assert_eq!(formatted(b"c = (\"x\"\n     \"y\")\n"), "c = \"xy\"\n");
        assert_eq!(formatted(b"d = r\"x\" r\"y\"\n"), "d = r\"x\" r\"y\"\n");
    }

    #[test]
    fn a_type_parameter_and_a_slice_take_their_own_colon_spacing() {
        assert_eq!(
            formatted(b"def override[F: _Func](method: F, /) -> F:\n    pass\n"),
            "def override[F: _Func](method: F, /) -> F:\n    pass\n"
        );

        assert_eq!(
            formatted(b"class K[T:int]:\n    pass\n"),
            "class K[T: int]:\n    pass\n"
        );

        assert_eq!(formatted(b"a = name[len(p)::]\n"), "a = name[len(p) : :]\n");
        assert_eq!(formatted(b"b = name[x() :: 2]\n"), "b = name[x() :: 2]\n");
        assert_eq!(formatted(b"c = name[a:b:c]\n"), "c = name[a:b:c]\n");
    }

    #[test]
    fn a_module_head_remark_run_keeps_its_own_gaps() {
        assert_eq!(
            formatted(b"# a\n\n# b\ndef f():\n    pass\n"),
            "# a\n\n# b\ndef f():\n    pass\n"
        );

        assert_eq!(
            formatted(b"x = 1\n\n# a\n\n# b\ndef f():\n    pass\n"),
            "x = 1\n\n# a\n\n\n# b\ndef f():\n    pass\n"
        );
    }

    #[test]
    fn an_augmented_assignment_and_a_walrus_header_drop_a_bare_pair() {
        assert_eq!(formatted(b"x += (a + b)\n"), "x += a + b\n");
        assert_eq!(formatted(b"y //= (c)\n"), "y //= c\n");
        assert_eq!(formatted(b"if (a := f()):\n    pass\n"), "if a := f():\n    pass\n");
        assert_eq!(formatted(b"z = (e := j())\n"), "z = (e := j())\n");
    }

    #[test]
    fn a_with_item_list_drops_a_pair_the_line_holds() {
        assert_eq!(
            formatted(b"def f():\n    with (open(\"a\") as p, open(\"b\") as q):\n        pass\n"),
            "def f():\n    with open(\"a\") as p, open(\"b\") as q:\n        pass\n"
        );

        assert_eq!(
            formatted(b"def g():\n    with (\n        open(\"a\") as p,\n    ):\n        pass\n"),
            "def g():\n    with (\n        open(\"a\") as p,\n    ):\n        pass\n"
        );
    }

    #[test]
    fn a_with_item_list_takes_the_pair_and_a_line_per_item() {
        let source = concat!(
            "def g():\n    with open(src, \"r\", encoding=\"utf-8\") as inn,",
            " open(dst, \"w\", encoding=\"utf-8\") as out:\n        pass\n"
        );

        let wanted = concat!(
            "def g():\n    with (\n        open(src, \"r\", encoding=\"utf-8\") as inn,\n",
            "        open(dst, \"w\", encoding=\"utf-8\") as out,\n    ):\n        pass\n"
        );

        assert_eq!(formatted(source.as_bytes()), wanted);
    }

    #[test]
    fn a_width_counts_the_columns_a_value_spells() {
        let held = "\u{df}\u{e0}\u{e1}\u{e2}\u{e3}\u{e4}\u{e5}\u{e6}\u{e7}\u{e8}\u{e9}\u{ea}\\
                    u{eb}\u{ec}\u{ed}\u{ee}\u{ef}\u{f0}\u{f1}\u{f2}\u{f3}\u{f4}\u{f5}\u{f6}\u{f8}\\
                    u{f9}\u{fa}\u{fb}\u{fc}\u{fd}\u{fe}\u{ff}";
        let source = format!("x += \"{held}\"\n");

        assert_eq!(formatted(source.as_bytes()), source);
    }

    #[test]
    fn a_trailing_remark_settles_the_pair_a_value_takes() {
        let atom = concat!(
            "def f():\n    extended_args_offset = 0",
            "  # Number of EXTENDED_ARG instructions preceding the current\n"
        );

        let wanted = concat!(
            "def f():\n    extended_args_offset = (\n        0",
            "  # Number of EXTENDED_ARG instructions preceding the current\n    )\n"
        );

        assert_eq!(formatted(atom.as_bytes()), wanted);

        let held = concat!(
            "def f():\n    header_value_end_offset = match.start(1) + length - 1",
            "  # Last byte of the header xxxx\n"
        );

        let parted = concat!(
            "def f():\n    header_value_end_offset = (\n        match.start(1) + length - 1\n",
            "    )  # Last byte of the header xxxx\n"
        );

        assert_eq!(formatted(held.as_bytes()), parted);
    }

    #[test]
    fn a_pragma_remark_is_no_part_of_the_width() {
        let source = concat!(
            "def loads(s: str, /, *, parse_float: ParseFloat = float)",
            " -> dict[str, Any]:  # noqa: C901\n    pass\n"
        );

        assert_eq!(formatted(source.as_bytes()), source);

        let plain = concat!(
            "y = some_function_named(argument_one, argument_two, argument_three, arg_four)",
            "  # a remark here\n"
        );

        let wanted = concat!(
            "y = some_function_named(\n    argument_one, argument_two, argument_three, arg_four\n",
            ")  # a remark here\n"
        );

        assert_eq!(formatted(plain.as_bytes()), wanted);
    }

    #[test]
    fn a_blank_line_inside_a_bracket_is_dropped() {
        assert_eq!(
            formatted(b"x = [\n    1,\n    # note\n\n    2,\n]\n"),
            "x = [\n    1,\n    # note\n    2,\n]\n"
        );
    }

    #[test]
    fn a_stub_holds_its_blank_only_ahead_of_a_definition() {
        assert_eq!(
            formatted(b"class C:\n    def a(self) -> int: ...\n    x = 1\n"),
            "class C:\n    def a(self) -> int: ...\n\n    x = 1\n"
        );

        assert_eq!(
            formatted(b"class D:\n    def a(self) -> int: ...\n    def b(self) -> str: ...\n"),
            "class D:\n    def a(self) -> int: ...\n    def b(self) -> str: ...\n"
        );
    }

    #[test]
    fn a_parted_list_writes_its_separator_ahead_of_a_remark() {
        assert_eq!(
            formatted(b"f(\n    \"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\n    \"b\"  # note\n)\n"),
            "f(\n    \"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\n    \"b\",  # note\n)\n"
        );
    }

    #[test]
    fn a_lambda_body_takes_the_pair_its_width_needs() {
        let source = concat!(
            "f(\n    \"a\",\n    b,\n    lambda name: name.isupper() and (name.startswith(\"SIG\")",
            " and not name.startswith(\"SIG_\")) or name.startswith(\"CTRL_\"),\n)\n"
        );

        let wanted = concat!(
            "f(\n    \"a\",\n    b,\n    lambda name: (\n        name.isupper()\n",
            "        and (name.startswith(\"SIG\") and not name.startswith(\"SIG_\"))\n",
            "        or name.startswith(\"CTRL_\")\n    ),\n)\n"
        );

        assert_eq!(formatted(source.as_bytes()), wanted);
        assert_eq!(formatted(b"g = lambda o: o.pk\n"), "g = lambda o: o.pk\n");
    }

    #[test]
    fn a_class_head_and_an_except_clause_drop_a_bare_pair() {
        assert_eq!(formatted(b"class A():\n    pass\n"), "class A:\n    pass\n");
        assert_eq!(
            formatted(b"class B(object):\n    pass\n"),
            "class B(object):\n    pass\n"
        );

        assert_eq!(
            formatted(b"try:\n    pass\nexcept (E):\n    pass\n"),
            "try:\n    pass\nexcept E:\n    pass\n"
        );

        assert_eq!(
            formatted(b"try:\n    pass\nexcept (F, G):\n    pass\n"),
            "try:\n    pass\nexcept (F, G):\n    pass\n"
        );
    }

    #[test]
    fn a_bare_tuple_target_takes_the_parentheses() {
        assert_eq!(formatted(b"a, = xs\n"), "(a,) = xs\n");
        assert_eq!(formatted(b"b, c = xs\n"), "b, c = xs\n");
        assert_eq!(formatted(b"d, = e, = xs\n"), "(d,) = (e,) = xs\n");
        assert_eq!(formatted(b"for f, in xs:\n    pass\n"), "for (f,) in xs:\n    pass\n");
        assert_eq!(formatted(b"for (g, h) in xs:\n    pass\n"), "for g, h in xs:\n    pass\n");
        assert_eq!(formatted(b"for (i,) in xs:\n    pass\n"), "for (i,) in xs:\n    pass\n");
    }

    #[test]
    fn a_redundant_semicolon_is_dropped() {
        assert_eq!(formatted(b"a = 1;\n"), "a = 1\n");
        assert_eq!(formatted(b"b = 2; c = 3;\n"), "b = 2\nc = 3\n");
        assert_eq!(formatted(b"if x:\n    d = 4;\n"), "if x:\n    d = 4\n");
    }

    #[test]
    fn a_trailing_remark_closes_the_groups_it_stands_past() {
        assert_eq!(
            formatted(
                b"def f():\n    def g():\n        return (\n            value in cls._unhashables_  # both are lists\n            or value in cls._hashables_\n        )\n"
            ),
            "def f():\n    def g():\n        return (\n            value in cls._unhashables_  # both are lists\n            or value in cls._hashables_\n        )\n"
        );
    }

    #[test]
    fn a_tripled_body_swaps_its_quote_past_an_escaped_one() {
        assert_eq!(formatted(br"x = '''it\'s'''"), "x = \"\"\"it\\'s\"\"\"\n");
        assert_eq!(formatted(b"x = '''q \" end'''\n"), "x = \"\"\"q \" end\"\"\"\n");
        assert_eq!(formatted(b"x = '''ends \"'''\n"), "x = '''ends \"'''\n");
    }

    #[test]
    fn a_raw_string_swaps_its_quote_past_an_escaped_one() {
        assert_eq!(formatted(br#"x = r'a\"b'"#), "x = r\"a\\\"b\"\n");
        assert_eq!(formatted(b"x = r'a\"b'\n"), "x = r'a\"b'\n");
        assert_eq!(formatted(br#"x = r'a\"b"c'"#), "x = r'a\\\"b\"c'\n");
    }

    #[test]
    fn a_power_operand_is_read_inside_its_own_line() {
        assert_eq!(
            formatted(b"l = l * f**n\nshapesize(l / 100.0)\n"),
            "l = l * f**n\nshapesize(l / 100.0)\n"
        );

        assert_eq!(formatted(b"x = f(a) ** 2\n"), "x = f(a) ** 2\n");
        assert_eq!(formatted(b"g(a)\nx = b**2\n"), "g(a)\nx = b**2\n");
    }

    #[test]
    fn a_remark_trailing_a_module_docstring_keeps_its_own_gap() {
        assert_eq!(
            formatted(b"\"\"\"Doc.\"\"\"\n# c\n\nx = 1\n"),
            "\"\"\"Doc.\"\"\"\n# c\n\nx = 1\n"
        );

        assert_eq!(
            formatted(b"\"\"\"Doc.\"\"\"\n# c\nx = 1\n"),
            "\"\"\"Doc.\"\"\"\n\n# c\nx = 1\n"
        );

        assert_eq!(
            formatted(b"\"\"\"Doc.\"\"\"\n# c\n\n# d\nx = 1\n"),
            "\"\"\"Doc.\"\"\"\n# c\n\n# d\nx = 1\n"
        );

        assert_eq!(
            formatted(b"class C:\n    \"\"\"Doc.\"\"\"\n    # c\n\n    x = 1\n"),
            "class C:\n    \"\"\"Doc.\"\"\"\n\n    # c\n\n    x = 1\n"
        );
    }

    #[test]
    fn a_quote_preference_reaches_inside_a_replacement_field() {
        assert_eq!(
            formatted(b"x = f'{c.__name__}({\", \".join(v)})'\n"),
            "x = f\"{c.__name__}({', '.join(v)})\"\n"
        );

        assert_eq!(formatted(b"x = f'a \"q\" {d[\'k\']}'\n"), "x = f'a \"q\" {d[\"k\"]}'\n");
        assert_eq!(formatted(b"x = f'{f\"{y}\"}'\n"), "x = f\"{f'{y}'}\"\n");
        assert_eq!(formatted(b"x = f'{y:{\"w\"}}'\n"), "x = f\"{y:{\"w\"}}\"\n");
        assert_eq!(
            formatted(b"x = f'{d[\"a\"]}' f'{d[\"b\"]}'\n"),
            "x = f\"{d['a']}{d['b']}\"\n"
        );
    }
}
