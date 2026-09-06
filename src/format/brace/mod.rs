use crate::bounded::{BoundedVec, Buffer, Bytes as _, Span, count_of};
use crate::format::brace::call::{BINARY_LEVEL_MAX, LOGICAL_LEVEL_MAX};
use crate::format::ir::{Document, Element, Source};
pub use crate::format::mask::{Rules, Tails, marked, tailed, terminated};
pub use crate::format::policy::Policy;
use crate::format::print::{self, Options};
use crate::format::reach;
use crate::format::stream::{restreamed, spilled};
pub use crate::format::text::{balanced, closed, ranked, renumbered, versioned};
use crate::format::text::{
    bodied,
    classed,
    named_key,
    preferred,
    requoted,
    sorted,
    spaced,
    tabbed,
};
use crate::format::walk::{Brackets, Breaks, columns, ends_operand, punctuated};
pub use crate::format::walk::{closed_by, is_close, is_open, opened_by, span_of, substituting};
use crate::token::{Punctuation, Token, TokenKind};

mod bind;
mod call;
mod clause;
mod join;
mod list;
mod own;
mod span;
mod tern;
mod wide;

pub const NEST_DEPTH_MAX: u32 = 128;
const TYPE_SCAN_MAX: u32 = 64;
const ANGLE_SCAN_MAX: u32 = 256;
const ANGLE_STOPS: bool = true;
const BOUND_LEVELS: bool = true;
const OPERAND_FIRST: bool = true;
const DEFINE_SCAN_MAX: u32 = 512;
const MODULE_STAR_MAX: u32 = 4;
const ASSIGN_DEPTH_MAX: u32 = 8;
const BINDING_DEPTH_MAX: u32 = 16;
const BRANCH_DEPTH_MAX: u32 = 16;
const LINE_LEVEL_MAX: u32 = 256;
const ORDER_RUN_MAX: u32 = 8;
const LIST_ITEM_MAX: u32 = 128;
const MACRO_BRANCH_MAX: u32 = 128;
const ATTRIBUTE_REMARKS: bool = true;
const DEFINE_GAPS: bool = true;
const BRANCH_TAILS: bool = true;
const ARM_BLANKS: bool = true;
const LINK_CLOSES: bool = true;
const LINE_CLOSERS: &[u8] = b"()]}?>,";
const OPERAND_INFIX: bool = true;
const REMARK_OPENS: bool = true;
const COMMA_PARTS: bool = true;
const LIST_RAISED: bool = true;
const REMARK_TAILS: bool = true;

const MACRO_GROUPS: &[(&[u8], u32)] = &[
    (b"assert", 1),
    (b"assert_eq", 2),
    (b"assert_ne", 2),
    (b"debug", 0),
    (b"debug_assert", 1),
    (b"debug_assert_eq", 2),
    (b"debug_assert_ne", 2),
    (b"eprint", 0),
    (b"eprintln", 0),
    (b"error", 0),
    (b"format", 0),
    (b"format_args", 0),
    (b"info", 0),
    (b"panic", 0),
    (b"print", 0),
    (b"println", 0),
    (b"unreachable", 0),
    (b"warn", 0),
    (b"write", 1),
    (b"writeln", 1),
];

const COMMA: &[u8] = b",";
const ACCESSOR_WORDS: [&[u8]; 2] = [b"get", b"set"];
const PAREN_CLOSE: &[u8] = b")";
const PAREN_OPEN: &[u8] = b"(";
const PAREN_SPACED: &[u8] = b" (";
const BLOCK_SPREADS: bool = true;
const BODY_BREAKS: bool = true;
const BODY_HEADS: bool = true;
const BODY_VALUES: &[&[u8]] = &[b"async", b"const", b"gen", b"move", b"try", b"unsafe"];
const BODY_STOPS: &[&[u8]] = &[b"<", b"=", b"=>", b":", b";", b",", b"|"];

const BODY_WORDS: &[&[u8]] = &[
    b"enum",
    b"fn",
    b"impl",
    b"loop",
    b"match",
    b"mod",
    b"struct",
    b"trait",
    b"union",
];

const BLANK_MODULES: bool = true;
const BRACKET_BLANKS: bool = true;
const FOREIGN_WORDS: &[&[u8]] = &[b"extern"];
const MODULE_WORDS: &[&[u8]] = &[b"extern", b"mod"];
const REMARK_COMMAS: bool = true;
const VALUE_ARROWS: bool = true;
const WRAP_DEPTH_MAX: u32 = 16;
const SEMICOLON: &[u8] = b";";
const GIVE_ORIGINS: bool = true;
const MACRO_NAMES: bool = true;
const HEADER_LINES: bool = true;
const DEFINE_HEAD_MAX: u32 = 1024;
const BINARY_HEAVIES: bool = true;
const INLINE_LAYOUT: bool = true;
const LOGICAL_INLINES: bool = true;
pub const ROLE_BLOCK: u8 = 1 << 0;
pub const ROLE_START: u8 = 1 << 1;
pub const ROLE_TIGHT: u8 = 1 << 3;
pub const ROLE_SPACED: u8 = 1 << 4;
pub const ROLE_LAMBDA: u8 = 1 << 2;
pub const ROLE_SPAN: u8 = 1 << 5;
pub const ROLE_PART: u8 = 1 << 6;
pub const ROLE_JSX: u8 = 1 << 7;
const STRUCTURE_ROLES: u8 = ROLE_BLOCK | ROLE_LAMBDA | ROLE_PART | ROLE_SPAN | ROLE_START;

pub struct Input<'held> {
    pub added: &'held [u8],
    pub gives: &'held [u32],
    pub macros: &'held [u32],
    pub options: Options,
    pub origin: &'held [u8],
    pub origins: &'held [u32],
    pub policy: Policy,
    pub roles: &'held [u8],
    pub source: &'held [u8],
    pub tokens: &'held [Token],
}

#[derive(Debug)]
pub struct Formatter {
    arena: Buffer,
    brackets: Brackets,
    breaks: Breaks,
    closing: u32,
    comma: u32,
    document: Document,
    opening: u32,
    semicolon: u32,
    spacing: u32,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum Wrap {
    Argued,
    Bodied,
    Hugged,
    Paired,
    Parens,
    Ternary,
    Valued,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum Spread {
    Chain,
    Clauses,
    Fill,
    Members,
}

#[derive(Clone, Copy, Debug)]
struct Frame {
    bodied: bool,
    casts: bool,
    close: u32,
    held: u32,
    indents: bool,
    index: bool,
    inset: u32,
    inside: bool,
    joined: bool,
    kind: TokenKind,
    lists: bool,
    open: u32,
    parted: bool,
    spread: Option<Spread>,
    valued: (u32, u32, u32),
}

impl Frame {
    const EMPTY: Self = Self {
        bodied: false,
        casts: false,
        close: 0,
        held: 0,
        indents: false,
        index: false,
        inset: 0,
        inside: false,
        joined: false,
        kind: TokenKind::BlockStart,
        lists: false,
        open: 0,
        parted: false,
        spread: None,
        valued: (0, 0, 0),
    };
}

struct Emitter<'held> {
    arena: &'held mut Buffer,
    arrowed: bool,
    assigned: Option<(u32, u32)>,
    based: u32,
    bindings: [(u32, u32); BINDING_DEPTH_MAX as usize],
    bound: u32,
    bound_base: u32,
    bound_depth: u32,
    brackets: &'held Brackets,
    branched: u32,
    branches: [(u32, u32, u32); BRANCH_DEPTH_MAX as usize],
    breaks: &'held Breaks,
    chained: bool,
    claused: bool,
    claused_body: bool,
    claused_depth: u32,
    closed: Frame,
    closing: Span,
    comma: Span,
    constructed: u32,
    constructs: [u32; NEST_DEPTH_MAX as usize],
    continued: bool,
    count: u32,
    declared: Option<u32>,
    dedents: [u32; ASSIGN_DEPTH_MAX as usize],
    depth: u32,
    document: &'held mut Document,
    gives: &'held [u32],
    glued: bool,
    indent: u32,
    levels: u32,
    line_before: u32,
    line_first: u32,
    line_start: bool,
    lined: u32,
    lines: [(u32, u32); LINE_LEVEL_MAX as usize],
    macros: &'held [u32],
    nest: [Frame; NEST_DEPTH_MAX as usize],
    opening: Span,
    options: Options,
    origin: &'held [u8],
    origins: &'held [u32],
    owed: u32,
    owing: u32,
    policy: Policy,
    previous: Option<u32>,
    printed: u32,
    remarked: bool,
    resume: u32,
    roles: &'held [u8],
    semicolon: Span,
    source: &'held [u8],
    spacing: Span,
    starting: bool,
    structured: bool,
    suppress_space: bool,
    tokens: &'held [Token],
    typed: bool,
    wrapped: [(u32, Wrap, u32, u32, u32); WRAP_DEPTH_MAX as usize],
    wraps_aligned: [u32; WRAP_DEPTH_MAX as usize],
    wraps_owed: u32,
}

impl Formatter {
    pub fn reserve(element_count_max: u32, arena_bytes_max: u32) -> Self {
        assert!(element_count_max > 0);
        assert!(arena_bytes_max > 0);

        assert!(!crate::allocation::is_frozen());

        let mut document = Document::reserve(element_count_max, 8);
        let comma = document.literal(COMMA);
        let closing = document.literal(PAREN_CLOSE);
        let opening = document.literal(PAREN_OPEN);
        let semicolon = document.literal(SEMICOLON);
        let spacing = document.literal(PAREN_SPACED);

        Self {
            arena: Buffer::reserve(arena_bytes_max),
            brackets: Brackets::reserve(element_count_max),
            breaks: Breaks::reserve(element_count_max),
            closing,
            comma,
            document,
            opening,
            semicolon,
            spacing,
        }
    }

    pub fn document(&self) -> &Document {
        &self.document
    }

    #[must_use]
    fn indexed(&mut self, input: &Input<'_>) -> bool {
        self.breaks
            .build(input.source, input.policy.carriage_breaks)
            && self.brackets.build(input.source, input.tokens)
    }

    fn spans(&self) -> [Span; 5] {
        [
            self.document.literal_span(self.closing),
            self.document.literal_span(self.comma),
            self.document.literal_span(self.opening),
            self.document.literal_span(self.semicolon),
            self.document.literal_span(self.spacing),
        ]
    }

    pub fn format(&mut self, input: &Input<'_>, out: &mut Buffer) -> bool {
        self.formatting(input, out, None)
    }

    pub fn formatting(
        &mut self,
        input: &Input<'_>,
        out: &mut Buffer,
        lines: Option<&mut BoundedVec<u32>>,
    ) -> bool {
        self.arena.clear();
        self.document.clear();

        if !self.indexed(input) {
            return false;
        }

        if !self.emitting(input) {
            return false;
        }

        let arena = self.arena.as_bytes();

        print::printing(
            &self.document,
            input.source,
            arena,
            input.options,
            out,
            lines,
        )
    }

    fn emitting(&mut self, input: &Input<'_>) -> bool {
        let [closing, comma, opening, semicolon, spacing] = self.spans();

        self.document.suffix(input.policy.remark_suffix);

        let mut emitter = Emitter {
            arena: &mut self.arena,
            arrowed: false,
            assigned: None,
            brackets: &self.brackets,
            breaks: &self.breaks,
            based: 0,
            branched: 0,
            branches: [(0, 0, 0); BRANCH_DEPTH_MAX as usize],
            chained: false,
            claused: false,
            claused_body: false,
            claused_depth: 0,
            closed: Frame::EMPTY,
            closing,
            comma,
            bindings: [(0, 0); BINDING_DEPTH_MAX as usize],
            bound: 0,
            bound_base: 0,
            bound_depth: 0,
            constructed: 0,
            constructs: [0; NEST_DEPTH_MAX as usize],
            continued: false,
            count: count_of(input.tokens.len()),
            declared: None,
            dedents: [0; ASSIGN_DEPTH_MAX as usize],
            depth: 0,
            document: &mut self.document,
            gives: input.gives,
            glued: false,
            indent: 0,
            levels: 0,
            line_before: 0,
            lined: 0,
            lines: [(0, 0); LINE_LEVEL_MAX as usize],
            line_first: 0,
            line_start: true,
            macros: input.macros,
            nest: [Frame::EMPTY; NEST_DEPTH_MAX as usize],
            opening,
            options: input.options,
            owed: 0,
            owing: 0,
            policy: input.policy,
            origin: input.origin,
            origins: input.origins,
            previous: None,
            printed: 0,
            remarked: false,
            resume: 0,
            roles: input.roles,
            semicolon,
            source: input.source,
            spacing,
            starting: true,
            structured: input.roles.iter().any(|held| held & STRUCTURE_ROLES != 0),
            suppress_space: false,
            tokens: input.tokens,
            typed: false,
            wrapped: [(0, Wrap::Parens, 0, 0, 0); WRAP_DEPTH_MAX as usize],
            wraps_aligned: [0; WRAP_DEPTH_MAX as usize],
            wraps_owed: 0,
        };

        emitter.run()
    }
}

impl<'held> Emitter<'held> {
    fn blanks(&self, position: u32) -> u32 {
        let Some(previous) = self.previous else {
            return 0;
        };

        if self.arm_closed() {
            if !ARM_BLANKS {
                return 0;
            }

            let held = self.next_of(previous).unwrap_or(previous);

            return self
                .parted_by(
                    self.tokens[held as usize].end(),
                    self.tokens[position as usize].offset,
                )
                .saturating_sub(1);
        }

        if self.listed_blank() || self.inner_blank(position, previous) {
            return 0;
        }

        let held = self.tokens[previous as usize].kind;
        let kind = self.tokens[position as usize].kind;

        let opened = held == TokenKind::BlockStart
            && !(BLANK_MODULES && self.moduled(previous, MODULE_WORDS));

        let closed = kind == TokenKind::BlockEnd
            && !(BLANK_MODULES
                && reach::opened(self.source, self.tokens, position)
                    .is_some_and(|open| self.moduled(open, FOREIGN_WORDS)));

        let edged = opened
            || closed
            || BRACKET_BLANKS
                && (is_open(held) && held != TokenKind::BlockStart
                    || is_close(kind) && kind != TokenKind::BlockEnd);

        if self.policy.blank_edges && edged {
            return 0;
        }

        let from = self.tokens[previous as usize].end();
        let to = self.tokens[position as usize].offset;

        self.parted_by(from, to).saturating_sub(1)
    }

    fn moduled(&self, open: u32, words: &[&[u8]]) -> bool {
        let mut scan = open;

        for _ in 0..TYPE_SCAN_MAX {
            let Some(held) = self.back_of(scan) else {
                return false;
            };

            let kind = self.tokens[held as usize].kind;

            if is_close(kind)
                || matches!(kind, TokenKind::BlockEnd | TokenKind::BlockStart)
                || kind == TokenKind::Punctuation(Punctuation::Semicolon)
            {
                return false;
            }

            if words.contains(&self.tokens[held as usize].text(self.source)) {
                return true;
            }

            scan = held;
        }

        false
    }

    fn dedents(&self, position: u32) -> bool {
        let token = self.tokens[position as usize];

        if is_close(token.kind) || self.labels(position) && !self.continues(position, false) {
            return true;
        }

        if token.kind == TokenKind::Comment {
            let mut scan = self.next_of(position);

            while scan.is_some_and(|held| self.tokens[held as usize].kind == TokenKind::Comment) {
                scan = self.next_of(scan.unwrap_or_default());
            }

            return scan.is_some_and(|held| {
                let closes = self.policy.remark_dedents
                    && self.tokens[held as usize].kind == TokenKind::BlockEnd;

                (closes
                    || self
                        .policy
                        .dedent_words
                        .contains(&self.tokens[held as usize].text(self.source)))
                    && self.column_of(position) <= self.column_of(held)
            });
        }

        let bytes = token.text(self.source);

        self.policy.dedent_words.contains(&bytes)
    }

    fn pops(&self, position: u32) -> bool {
        let kind = self.tokens[position as usize].kind;

        if self.roled(position, ROLE_SPAN) || is_close(kind) {
            return false;
        }

        if self.continued && !self.policy.span_levels {
            return false;
        }

        if !self
            .previous
            .is_some_and(|held| self.roled(held, ROLE_SPAN))
        {
            return false;
        }

        let opened = self.span_start(self.previous.unwrap_or(position));

        let heads = self.back_of(opened).is_some_and(|held| {
            is_open(self.tokens[held as usize].kind)
                || self.tokens[held as usize].kind == TokenKind::Punctuation(Punctuation::Comma)
        });

        (heads || self.policy.span_levels)
            && !self
                .next_of(position)
                .is_some_and(|held| is_close(self.tokens[held as usize].kind))
    }

    fn popped(&self, position: u32) -> Option<u32> {
        if !self.pops(position) {
            return None;
        }

        if !self.policy.span_levels {
            return Some(self.levels.saturating_sub(1));
        }

        let braced =
            self.depth > 0 && self.nest[self.depth as usize - 1].kind == TokenKind::BlockStart;

        if braced && self.printed <= self.levels {
            return None;
        }

        Some(self.printed.saturating_sub(1))
    }

    fn span_start(&self, position: u32) -> u32 {
        let mut scan = position;

        while let Some(held) = self.back_of(scan) {
            if !self.roled(held, ROLE_SPAN) {
                break;
            }

            scan = held;
        }

        scan
    }

    fn column_of(&self, position: u32) -> u32 {
        let offset = self.tokens[position as usize].offset as usize;
        let mut start = offset;

        while start > 0 && self.source[start - 1] != b'\n' {
            start -= 1;
        }

        count_of(offset - start)
    }

    fn raised(&self, position: u32, parted: bool) -> bool {
        if !self.policy.brace_levels || self.depth == 0 {
            return true;
        }

        if self.fields_level(position)
            || self.literal_wide(position)
            || self.branched_wide(position)
            || self.listed_wide(position) == Some(position)
        {
            return true;
        }

        let outer = self.nest[self.depth as usize - 1];

        if self.hugged_wide(outer.open) {
            return true;
        }

        let opened = LIST_RAISED && self.line_first > outer.open;

        if !outer.parted
            && !opened
            && !self.parts_at(outer.open, position)
            && !self.parting(outer.open, position)
        {
            return false;
        }

        if self.holds_a_condition(outer.open) {
            return true;
        }

        self.policy.raise_hugged
            || !(!outer.parted
                && self.hugs(outer.open)
                && self.carries_on()
                && !parted
                && !self.hugs(position))
    }

    fn holds_a_condition(&self, open: u32) -> bool {
        if self.tokens[open as usize].kind != TokenKind::Punctuation(Punctuation::ParenOpen) {
            return false;
        }

        self.back_of(open)
            .is_some_and(|held| self.word_is(held, self.policy.header_words))
    }

    fn hugs(&self, open: u32) -> bool {
        if self.parts_body(open) {
            return false;
        }

        self.next_of(open).is_some_and(|held| {
            self.tokens[held as usize].kind != TokenKind::Comment
                && self.parted_by(
                    self.tokens[open as usize].end(),
                    self.tokens[held as usize].offset,
                ) == 0
        })
    }

    fn binding(&self, position: u32) -> Option<u32> {
        let last = self.punctuated_run(position);

        let text = if self.policy.binding_leads {
            &self.source[self.tokens[position as usize].offset as usize
                ..self.tokens[last as usize].end() as usize]
        } else {
            self.tokens[position as usize].text(self.source)
        };

        self.policy
            .binding_words
            .iter()
            .position(|tier| tier.contains(&text))
            .map(count_of)
    }

    fn bounded(&mut self, wanted: u32, leading: Option<u32>) -> u32 {
        if self.bounds() {
            self.bindings[0] = (count_of(self.policy.binding_words.len()), wanted);
            self.bound = 1;
            self.bound_base = wanted;
            self.bound_depth = self.depth;

            return wanted;
        }

        let above = if self.policy.binding_codes {
            self.coded()
        } else {
            self.previous
        };

        let held = if self.policy.binding_leads {
            leading.and_then(|found| self.binding(found))
        } else {
            above.and_then(|previous| self.binding(previous))
        };

        let Some(precedence) = held else {
            let heads = leading.is_some_and(|found| self.word_is(found, self.policy.binding_bases));

            if heads {
                self.bindings[0] = (count_of(self.policy.binding_words.len()), wanted);
                self.bound = 1;
                self.bound_base = wanted;
                self.bound_depth = self.depth;

                return wanted;
            }

            if wide::BINDING_LINKS && leading.is_some_and(|found| self.is_dot(found)) {
                return wanted;
            }

            self.bound = 0;

            return wanted;
        };

        if self.bound == 0 || self.bound_depth != self.depth {
            self.bindings[0] = (precedence, wanted);
            self.bound = 1;
            self.bound_base = wanted;
            self.bound_depth = self.depth;

            return wanted;
        }

        while self.bound > 1 && self.bindings[self.bound as usize - 1].0 < precedence {
            self.bound -= 1;
        }

        let (tier, level) = self.bindings[self.bound as usize - 1];

        if tier <= precedence {
            return level;
        }

        if self.bound < BINDING_DEPTH_MAX {
            self.bindings[self.bound as usize] = (precedence, level + 1);
            self.bound += 1;
        }

        level + 1
    }

    fn linked(&self) -> u32 {
        let held = self.tokens[self.line_before as usize].kind;

        if let Some(level) = self.link_level() {
            return level;
        }

        if is_close(held) && (!LINK_CLOSES || self.line_closed())
            || held == TokenKind::Comment
            || self.is_dot(self.line_before)
        {
            return self.printed;
        }

        if self.policy.link_spans && self.line_spans() {
            return self.printed;
        }

        self.printed + 1
    }

    fn line_closed(&self) -> bool {
        let mut scan = self.line_before;

        while scan < self.line_first {
            let token = self.tokens[scan as usize];

            let closes = token
                .text(self.source)
                .iter()
                .all(|byte| LINE_CLOSERS.contains(byte));

            if token.length > 0 && token.kind != TokenKind::Newline && !closes {
                return false;
            }

            scan += 1;
        }

        true
    }

    fn line_spans(&self) -> bool {
        let Some(found) = self.line_spanned() else {
            return false;
        };

        if self.tokens[found as usize].kind != TokenKind::String {
            return true;
        }

        self.last_line(found) <= self.options.indent_width
    }

    fn line_spanned(&self) -> Option<u32> {
        let mut found = None;
        let mut scan = self.line_before;

        while scan < self.line_first {
            if self.tokens[scan as usize]
                .text(self.source)
                .contains(&b'\n')
            {
                found = Some(scan);
            }

            scan += 1;
        }

        found
    }

    fn last_line(&self, position: u32) -> u32 {
        let token = self.tokens[position as usize];
        let end = token.end();
        let mut from = token.offset;
        let mut scan = token.offset;

        while scan < end {
            if self.source[scan as usize] == b'\n' {
                from = scan + 1;
            }

            scan += 1;
        }

        let mut to = end;

        while from < to && self.source[from as usize].is_ascii_whitespace() {
            from += 1;
        }

        while to > from && self.source[(to - 1) as usize].is_ascii_whitespace() {
            to -= 1;
        }

        columns(self.source, from, to)
    }

    fn line_brackets(&self) -> (u32, u32) {
        let mut closes = 0_u32;
        let mut opens = 0_u32;
        let mut scan = self.line_before;

        while scan < self.line_first {
            let kind = self.tokens[scan as usize].kind;

            if is_open(kind) {
                opens += 1;
            } else if is_close(kind) {
                closes += 1;
            }

            scan += 1;
        }

        (opens, closes)
    }

    fn link_level(&self) -> Option<u32> {
        if !self.policy.link_nests || !self.is_dot(self.line_before) {
            return None;
        }

        let (opens, closes) = self.line_brackets();

        if opens > closes {
            return Some(self.printed + 1);
        }

        if closes > opens {
            return self.line_level(self.closed.open);
        }

        None
    }

    fn operand_led(&self, position: u32) -> bool {
        if !OPERAND_INFIX || !self.policy.operand_levels {
            return true;
        }

        let _ = position;

        self.coded().is_some_and(|held| {
            self.operand_at(held) || self.tokens[held as usize].kind == TokenKind::BlockEnd
        })
    }

    fn continued_by(&self, position: u32) -> bool {
        let last = self.punctuated_run(position);

        let text = &self.source[self.tokens[position as usize].offset as usize
            ..self.tokens[last as usize].end() as usize];

        if !self.policy.continue_words.contains(&text) {
            return false;
        }

        self.next_of(last).is_some_and(|held| {
            self.tokens[last as usize].end() < self.tokens[held as usize].offset
        })
    }

    fn punctuated_run(&self, position: u32) -> u32 {
        let mut scan = position;

        while scan + 1 < self.count {
            let held = self.tokens[scan as usize];
            let next = self.tokens[(scan + 1) as usize];

            if held.end() != next.offset || !matches!(next.kind, TokenKind::Punctuation(_)) {
                break;
            }

            scan += 1;
        }

        scan
    }

    fn carries_on(&self) -> bool {
        let mut scan = self.line_first;

        while scan > 0 {
            scan -= 1;

            let token = self.tokens[scan as usize];

            if token.length == 0 {
                continue;
            }

            if token.kind == TokenKind::Newline {
                return false;
            }

            return !is_open(token.kind)
                && !matches!(
                    token.kind,
                    TokenKind::Punctuation(Punctuation::Comma | Punctuation::Semicolon)
                );
        }

        false
    }

    fn clause_level(&self, position: u32) -> Option<u32> {
        if !self.policy.header_levels
            || self.tokens[position as usize].kind != TokenKind::Punctuation(Punctuation::Colon)
        {
            return None;
        }

        let head = self.head_word(position, self.policy.header_words)?;

        self.line_level(head)
    }

    fn branch_level(&mut self) -> Option<u32> {
        while self.branched > 0 && self.branches[self.branched as usize - 1].1 > self.depth {
            self.branched -= 1;
        }

        while self.branched > 0
            && self.word_is(
                self.branches[self.branched as usize - 1].2,
                self.policy.level_words,
            )
        {
            self.branched -= 1;
        }

        if self.branched == 0 || self.branches[self.branched as usize - 1].1 != self.depth {
            return None;
        }

        self.branched -= 1;

        Some(self.branches[self.branched as usize].0)
    }

    fn branch_opened(&mut self, level: u32, held: u32) {
        if self.branched < BRANCH_DEPTH_MAX {
            self.branches[self.branched as usize] = (level, self.depth, held);
            self.branched += 1;
        }
    }

    fn header_level(&self, position: u32) -> Option<u32> {
        if !self.policy.header_levels {
            return None;
        }

        let previous = self.coded()?;

        if self.branched > 0 && self.branches[self.branched as usize - 1].2 == previous {
            return None;
        }

        if self.word_is(previous, self.policy.level_words) {
            return Some(self.printed);
        }

        if !self.heads_a_body(position, previous) {
            return None;
        }

        let head = self.head_word(position, self.policy.header_words)?;

        Some(self.line_level(head).unwrap_or(self.printed))
    }

    fn line_level(&self, position: u32) -> Option<u32> {
        let mut held: Option<(u32, u32)> = None;

        for line in self.lines {
            if line.0 == 0 || line.0 - 1 > position {
                continue;
            }

            if held.is_none_or(|found| line.0 > found.0) {
                held = Some(line);
            }
        }

        held.map(|found| found.1)
    }

    fn heads_a_body(&self, position: u32, previous: u32) -> bool {
        if self.policy.header_words.is_empty()
            || self.tokens[position as usize].kind == TokenKind::BlockStart
        {
            return false;
        }

        if self.word_is(previous, self.policy.source_words) {
            return self.word_is(self.line_before, self.policy.header_words);
        }

        if self.tokens[previous as usize].kind != TokenKind::Punctuation(Punctuation::ParenClose)
            || self.closed.kind != TokenKind::Punctuation(Punctuation::ParenOpen)
        {
            return false;
        }

        self.closed.open > 0 && self.word_is(self.closed.open - 1, self.policy.header_words)
    }

    fn nested_already(&self, previous: u32) -> bool {
        let mut depth = self.depth;

        while depth > 0 {
            let frame = self.nest[depth as usize - 1];

            if frame.indents {
                if self.parts_body(frame.open) || frame.parted {
                    return false;
                }

                return self.parted_by(
                    self.tokens[frame.open as usize].end(),
                    self.tokens[previous as usize].end(),
                ) == 0;
            }

            depth -= 1;
        }

        false
    }

    fn bounds(&self) -> bool {
        if !self.policy.clause_bases || !self.claused {
            return false;
        }

        self.coded().is_some_and(|held| {
            self.word_is(held, self.policy.clause_words)
                || self.tokens[held as usize].kind == TokenKind::Punctuation(Punctuation::Comma)
        })
    }

    fn clause_holds(&self, position: u32) -> bool {
        if self.claused_body {
            return false;
        }

        if self.depth > self.claused_depth {
            return true;
        }

        if self.policy.clause_ends
            && self.coded().is_some_and(|held| {
                self.tokens[held as usize].kind == TokenKind::Punctuation(Punctuation::Semicolon)
            })
        {
            return false;
        }

        let kind = self.tokens[position as usize].kind;

        !is_close(kind)
            && kind != TokenKind::BlockStart
            && kind != TokenKind::Punctuation(Punctuation::Semicolon)
    }

    fn arming(&self, position: u32) -> bool {
        self.word_is(position, self.policy.clause_words) && !self.keying()
    }

    fn keying(&self) -> bool {
        let frame = self.frame();

        frame.kind == TokenKind::BlockStart && frame.lists
    }

    fn clauses(&self, position: u32) -> bool {
        if self.opens_a_clause(position) {
            return true;
        }

        self.claused && self.clause_holds(position)
    }

    fn opens_a_clause(&self, position: u32) -> bool {
        if self.arming(position) {
            return true;
        }

        !self.claused
            && self
                .coded()
                .is_some_and(|held| self.word_is(held, self.policy.clause_words))
    }

    fn chains(&self, position: u32) -> bool {
        if !self.policy.brace_continues {
            return false;
        }

        if self.tokens[position as usize].kind != TokenKind::Punctuation(Punctuation::Dot) {
            return false;
        }

        let Some(previous) = self.coded() else {
            return false;
        };

        if !self.next_of(position).is_some_and(|held| {
            matches!(
                self.tokens[held as usize].kind,
                TokenKind::Identifier | TokenKind::Keyword(_) | TokenKind::Number
            )
        }) {
            return false;
        }

        let held = self.tokens[previous as usize].kind;

        !is_open(held)
            && !matches!(
                held,
                TokenKind::Punctuation(Punctuation::Comma | Punctuation::Semicolon)
            )
    }

    fn spanned_run(&self, position: u32) -> Option<bool> {
        if self.valued_source(position) {
            return Some(true);
        }

        if !self.roled(position, ROLE_SPAN) {
            return None;
        }

        if self.coded().is_some_and(|held| self.roled(held, ROLE_SPAN)) {
            return Some(self.continued);
        }

        self.is_dot(self.line_before).then_some(false)
    }

    #[expect(
        clippy::too_many_lines,
        reason = "the walk names every token that opens a line of its own, and splitting it would \
                  hide the one order the rule is"
    )]
    fn continues(&self, position: u32, deep: bool) -> bool {
        if let Some(held) = self.spanned_run(position) {
            return held;
        }

        if !self.policy.brace_continues {
            return false;
        }

        if self.arming(position) {
            return false;
        }

        if self.policy.brace_dedents && self.tokens[position as usize].kind == TokenKind::BlockStart
        {
            return false;
        }

        if self.depth == 0 && self.word_is(position, self.policy.follow_heads) {
            return true;
        }

        let bodied = self.depth > self.claused_depth && self.frame().kind == TokenKind::BlockStart;

        if self.claused && !bodied {
            return self.depth == self.claused_depth && self.clause_holds(position);
        }

        let Some(previous) = self.coded() else {
            return false;
        };

        if is_close(self.tokens[position as usize].kind) {
            return false;
        }

        if let Some(decided) = self.brace_carries(position, previous) {
            return decided;
        }

        let held = self.tokens[previous as usize].kind;
        let separated = matches!(
            held,
            TokenKind::Punctuation(Punctuation::Comma | Punctuation::Semicolon)
        );

        if self.word_is(position, self.policy.level_words) {
            return false;
        }

        if self.alternates(position) {
            return false;
        }

        if self.policy.attribute_ends && self.attributed(previous) {
            return false;
        }

        if self.chains(position) || self.continued_by(position) && self.operand_led(position) {
            return true;
        }

        if self.heads_a_body(position, previous) {
            return true;
        }

        if self.parted_by(
            self.tokens[previous as usize].end(),
            self.tokens[position as usize].offset,
        ) == 0
            && (self.clause_parted(position, previous) || self.declare_broken(position, previous))
        {
            return true;
        }

        if deep && self.nested_already(previous) {
            return false;
        }

        if is_open(held) || is_close(held) || held == TokenKind::Comment {
            return false;
        }

        if held == TokenKind::Punctuation(Punctuation::Comma) {
            return self.generic_open(position)
                || self.policy.comma_continues && self.statement_level();
        }

        if separated {
            return false;
        }

        if held == TokenKind::Punctuation(Punctuation::Colon) {
            return self.policy.colon_continues;
        }

        if self.word_is(previous, self.policy.postfix_words)
            || self.word_is(previous, self.policy.end_words)
        {
            return false;
        }

        !self.operand_at(previous)
    }

    fn remarked_level(&self, position: u32) -> Option<u32> {
        if !self.policy.remark_levels {
            return None;
        }

        let previous = self.back_of(position)?;
        let token = self.tokens[previous as usize];

        if token.kind != TokenKind::Comment || token.text(self.source).starts_with(b"/*") {
            return None;
        }

        let above = self.coded_at(previous)?;

        if self.tokens[above as usize].text(self.source) == b"=>" {
            return self.line_level(above);
        }

        if let Some(named) = self.fielded(above).filter(|_| !self.broke(above, previous)) {
            return self.line_level(named);
        }

        self.binding(position)?;

        if !self.holds_a_condition(self.frame().open) || self.broke(above, previous) {
            return None;
        }

        self.line_level(self.frame().open)
    }

    fn fielded(&self, position: u32) -> Option<u32> {
        if self.tokens[position as usize].kind != TokenKind::Punctuation(Punctuation::Assign) {
            return None;
        }

        let name = self.back_of(position)?;
        let dot = self.back_of(name)?;

        self.fields(dot).then_some(dot)
    }

    fn barred(&self, position: u32) -> Option<u32> {
        if !self.policy.bar_levels {
            return None;
        }

        let mut bars = 0_u32;
        let mut depth = 0_u32;
        let mut opened = position;
        let mut scan = position;

        for _ in 0..ANGLE_SCAN_MAX {
            let Some(held) = self.back_of(scan) else {
                break;
            };

            let kind = self.tokens[held as usize].kind;

            if kind == TokenKind::BlockEnd
                || depth == 0 && kind == TokenKind::Punctuation(Punctuation::Semicolon)
            {
                break;
            }

            if is_close(kind) {
                depth += 1;
            } else if is_open(kind) || kind == TokenKind::BlockStart {
                if depth == 0 {
                    break;
                }

                depth -= 1;
            } else if depth == 0 && self.tokens[held as usize].text(self.source) == b"|" {
                bars += 1;
                opened = held;
            }

            scan = held;
        }

        if bars != 1 || !self.payload_bar(opened) {
            return None;
        }

        if self.tokens[position as usize].text(self.source) == b"|" {
            return Some(self.levels);
        }

        Some(self.levels + 1)
    }

    fn payload_bar(&self, open: u32) -> bool {
        let heads = self.back_of(open).is_some_and(|held| {
            self.tokens[held as usize].kind == TokenKind::Punctuation(Punctuation::ParenClose)
        });

        heads
            && self
                .next_of(open)
                .is_some_and(|held| self.broke(open, held))
    }

    fn generic_open(&self, position: u32) -> bool {
        if !self.policy.generic_levels {
            return false;
        }

        let opening = self.tokens[position as usize].text(self.source);

        if !opening.is_empty() && opening.iter().all(|byte| *byte == b'>') {
            return false;
        }

        let mut angles = 0_u32;
        let mut depth = 0_u32;
        let mut scan = position;

        for _ in 0..TYPE_SCAN_MAX {
            let Some(held) = self.back_of(scan) else {
                return false;
            };

            let kind = self.tokens[held as usize].kind;
            let text = self.tokens[held as usize].text(self.source);

            if is_close(kind) || kind == TokenKind::BlockEnd {
                depth += 1;
            } else if is_open(kind) || kind == TokenKind::BlockStart {
                if depth == 0 {
                    return false;
                }

                depth -= 1;
            } else if depth == 0 && !text.is_empty() {
                if text.iter().all(|byte| *byte == b'>') {
                    angles += count_of(text.len());
                } else if text.iter().all(|byte| *byte == b'<') {
                    let run = count_of(text.len());

                    if run > angles {
                        return self.angled_apart(held);
                    }

                    angles -= run;
                }
            }

            scan = held;
        }

        false
    }

    fn generic_level(&self, position: u32) -> Option<u32> {
        let angles = self.generic_angles(position)?;
        let closes = self.closing_angles(position);
        let bound = u32::from(BOUND_LEVELS && self.bounded_type(position));

        Some(self.levels + bound + angles.saturating_sub(closes))
    }

    fn bounded_type(&self, position: u32) -> bool {
        let mut colon = false;
        let mut depth = 0_u32;
        let mut scan = position;

        for _ in 0..TYPE_SCAN_MAX {
            let Some(held) = self.back_of(scan) else {
                return false;
            };

            let kind = self.tokens[held as usize].kind;

            if is_close(kind) || kind == TokenKind::BlockEnd {
                depth += 1;
            } else if is_open(kind) || kind == TokenKind::BlockStart {
                if depth == 0 {
                    return false;
                }

                depth -= 1;
            } else if depth == 0 {
                if kind == TokenKind::Punctuation(Punctuation::Semicolon) {
                    return false;
                }

                if self.tokens[held as usize].text(self.source) == b":"
                    && !self.doubled(held)
                    && !self.pathed(held)
                {
                    colon = true;
                } else if self.tokens[held as usize].text(self.source) == b"type" {
                    return colon;
                }
            }

            scan = held;
        }

        false
    }

    fn closing_angles(&self, position: u32) -> u32 {
        let text = self.tokens[position as usize].text(self.source);

        if text.is_empty() || !text.iter().all(|byte| *byte == b'>') {
            return 0;
        }

        count_of(text.len())
    }

    fn generic_angles(&self, position: u32) -> Option<u32> {
        if !self.policy.generic_nests {
            return None;
        }

        let mut angles = 0_u32;
        let mut depth = 0_u32;
        let mut open = 0_u32;
        let mut scan = position;
        let mut stopped = false;

        for _ in 0..ANGLE_SCAN_MAX {
            let Some(held) = self.back_of(scan) else {
                stopped = true;

                break;
            };

            let kind = self.tokens[held as usize].kind;
            let text = self.tokens[held as usize].text(self.source);

            if ANGLE_STOPS
                && depth == 0
                && (kind == TokenKind::BlockEnd
                    || kind == TokenKind::Punctuation(Punctuation::Semicolon))
            {
                stopped = true;

                break;
            }

            if is_close(kind) || kind == TokenKind::BlockEnd {
                depth += 1;
            } else if is_open(kind) || kind == TokenKind::BlockStart {
                if depth == 0 {
                    stopped = true;

                    break;
                }

                depth -= 1;
            } else if depth == 0 && !text.is_empty() {
                if text.iter().all(|byte| *byte == b'>') {
                    angles += count_of(text.len());
                } else if text.iter().all(|byte| *byte == b'<') {
                    let run = count_of(text.len());

                    if run <= angles {
                        angles -= run;
                    } else {
                        if open == 0 && !self.angled_apart(held) {
                            return None;
                        }

                        open += run - angles;
                        angles = 0;
                    }
                }
            }

            scan = held;
        }

        (stopped && open > 0).then_some(open)
    }

    fn angled_apart(&self, open: u32) -> bool {
        self.next_of(open)
            .is_some_and(|next| self.parts_at(open, next))
    }

    fn ranged(&self, open: u32, close: u32) -> bool {
        let mut scan = open + 1;

        while scan < close {
            let held = self.tokens[scan as usize];

            scan += 1;

            if held.text(self.source).starts_with(b"..") {
                return true;
            }

            if !self.is_dot(scan - 1) || scan >= close {
                continue;
            }

            if self.is_dot(scan) && held.end() == self.tokens[scan as usize].offset {
                return true;
            }
        }

        false
    }

    pub(super) fn attributed(&self, position: u32) -> bool {
        if self.tokens[position as usize].kind != TokenKind::Punctuation(Punctuation::BracketClose)
        {
            return false;
        }

        let Some(open) = reach::opened(self.source, self.tokens, position) else {
            return false;
        };

        self.word_before(open)
            .is_some_and(|held| self.tokens[held as usize].text(self.source) == b"#")
    }

    fn alternates(&self, position: u32) -> bool {
        if self.policy.pattern_words.is_empty()
            || self.tokens[position as usize].text(self.source) != b"|"
        {
            return false;
        }

        let mut level = self.depth;

        while level > 0 {
            level -= 1;

            let frame = self.nest[level as usize];

            if frame.kind == TokenKind::BlockStart {
                return self.patterned(frame.open);
            }

            if !self.policy.pattern_frames {
                return false;
            }
        }

        false
    }

    fn patterned(&self, open: u32) -> bool {
        self.worded_head(open, self.policy.pattern_words)
    }

    fn brace_carries(&self, position: u32, previous: u32) -> Option<bool> {
        let opens = self.tokens[position as usize].kind == TokenKind::BlockStart;

        let blocks = if self.structured {
            self.bodied(position)
        } else {
            self.bodied_brace(position)
        };

        if self.policy.header_braces && opens && blocks {
            return Some(false);
        }

        if !self.policy.arm_guards {
            return None;
        }

        if self.tokens[previous as usize].text(self.source) == b"=>"
            && (opens || self.frame().kind != TokenKind::BlockStart)
        {
            return Some(false);
        }

        self.guards_an_arm(position).then_some(true)
    }

    fn guards_an_arm(&self, position: u32) -> bool {
        if self.tokens[position as usize].text(self.source) != b"if" {
            return false;
        }

        let frame = self.frame();

        if frame.kind != TokenKind::BlockStart || !self.patterned(frame.open) {
            return false;
        }

        let mut depth = 0_u32;
        let mut scan = position + 1;

        while scan < frame.close {
            let token = self.tokens[scan as usize];

            scan += 1;

            if is_open(token.kind) || token.kind == TokenKind::BlockStart {
                depth += 1;

                continue;
            }

            if is_close(token.kind) || token.kind == TokenKind::BlockEnd {
                depth = depth.saturating_sub(1);

                continue;
            }

            if depth > 0 {
                continue;
            }

            if token.text(self.source) == b"=>" {
                return true;
            }

            if token.kind == TokenKind::Punctuation(Punctuation::Comma) {
                return false;
            }
        }

        false
    }

    fn worded_head(&self, open: u32, words: &[&[u8]]) -> bool {
        self.head_word(open, words).is_some()
    }

    pub(super) fn head_word(&self, open: u32, words: &[&[u8]]) -> Option<u32> {
        let mut depth = 0_u32;
        let mut scan = open;

        for _ in 0..TYPE_SCAN_MAX {
            let held = self.back_of(scan)?;
            let kind = self.tokens[held as usize].kind;

            if is_close(kind) || kind == TokenKind::BlockEnd {
                if self.policy.head_blocks
                    && depth == 0
                    && kind == TokenKind::BlockEnd
                    && !self.joins_a_value(held)
                {
                    return None;
                }

                depth += 1;
            } else if is_open(kind) || kind == TokenKind::BlockStart {
                if depth == 0 {
                    return None;
                }

                depth -= 1;
            } else if depth == 0 {
                if self.word_is(held, words) {
                    return Some(held);
                }

                if kind == TokenKind::Punctuation(Punctuation::Semicolon)
                    || self.word_is(held, self.policy.head_stops)
                {
                    return None;
                }
            }

            scan = held;
        }

        None
    }

    fn signature_end(&self, close: u32) -> Option<u32> {
        let mut depth = 0_u32;
        let mut scan = close;

        for _ in 0..DEFINE_SCAN_MAX {
            scan = self.next_of(scan)?;

            let kind = self.tokens[scan as usize].kind;

            if depth == 0
                && (kind == TokenKind::BlockStart
                    || kind == TokenKind::Punctuation(Punctuation::Semicolon)
                    || self.word_is(scan, self.policy.clause_words))
            {
                return Some(scan);
            }

            if is_open(kind) || kind == TokenKind::BlockStart {
                depth += 1;
            } else if is_close(kind) || kind == TokenKind::BlockEnd {
                depth = depth.checked_sub(1)?;
            }
        }

        None
    }

    fn define_settled(&self, open: u32, close: u32) -> bool {
        let Some(end) = self.signature_end(close) else {
            return false;
        };

        let mut depth = 1_u32;
        let mut scan = open;

        for _ in 0..DEFINE_SCAN_MAX {
            let Some(next) = self.next_of(scan) else {
                return false;
            };

            let edged = depth == 1
                && (scan == open
                    || next == close
                    || self.tokens[scan as usize].kind
                        == TokenKind::Punctuation(Punctuation::Comma));

            if !edged && self.parts_at(scan, next) {
                return false;
            }

            if next >= end {
                return true;
            }

            let kind = self.tokens[next as usize].kind;

            if is_open(kind) || kind == TokenKind::BlockStart {
                depth += 1;
            } else if is_close(kind) || kind == TokenKind::BlockEnd {
                depth = depth.saturating_sub(1);
            }

            scan = next;
        }

        false
    }

    fn define_parted(&self, open: u32) -> bool {
        if !self.policy.define_widths
            || self.tokens[open as usize].kind != TokenKind::Punctuation(Punctuation::ParenOpen)
        {
            return false;
        }

        let mut scan = open;

        for _ in 0..DEFINE_HEAD_MAX {
            let Some(held) = self.back_of(scan) else {
                return false;
            };

            let kind = self.tokens[held as usize].kind;

            if is_open(kind)
                || is_close(kind)
                || kind == TokenKind::BlockStart
                || kind == TokenKind::BlockEnd
                || kind == TokenKind::Punctuation(Punctuation::Semicolon)
            {
                return false;
            }

            if self.word_is(held, self.policy.define_words) {
                return scan != open;
            }

            scan = held;
        }

        false
    }

    fn coded(&self) -> Option<u32> {
        let mut held = self.previous?;

        while self.tokens[held as usize].kind == TokenKind::Comment {
            held = self.back_of(held)?;
        }

        Some(held)
    }

    fn coding(&self, position: u32) -> Option<u32> {
        let mut held = self.next_of(position)?;

        while self.tokens[held as usize].kind == TokenKind::Comment {
            held = self.next_of(held)?;
        }

        Some(held)
    }

    fn statement_level(&self) -> bool {
        if self.depth == 0 {
            return true;
        }

        let frame = self.nest[self.depth as usize - 1];

        if frame.kind != TokenKind::BlockStart {
            return false;
        }

        if self.bodied(frame.open) {
            return true;
        }

        if self.structured {
            return false;
        }

        let Some(previous) = self.back_of(frame.open) else {
            return true;
        };

        matches!(
            self.tokens[previous as usize].kind,
            TokenKind::Punctuation(Punctuation::ParenClose) | TokenKind::BlockEnd
        ) || self.word_is(previous, self.policy.body_words)
    }

    fn level(&mut self, wanted: u32) -> bool {
        while self.indent > wanted {
            if !self.document.push(Element::Dedent) {
                return false;
            }

            self.indent -= 1;
        }

        while self.indent < wanted {
            if !self.document.push(Element::Indent) {
                return false;
            }

            self.indent += 1;
        }

        true
    }

    fn assign_closed(&mut self) -> bool {
        if self.assigned.take().is_some() && !self.document.push(Element::GroupClose) {
            return false;
        }

        self.owing = self.owed;

        while self.owed > 0 {
            self.owed -= 1;

            if !self.document.push(Element::DedentBroken) {
                return false;
            }
        }

        true
    }

    fn newline(&mut self, position: u32) -> bool {
        if !self.assign_closed() {
            return false;
        }

        let blanks = if self.policy.brace_parts && self.edges(position) {
            0
        } else {
            self.blanks(position)
                .min(self.policy.blank_max)
                .max(self.apart(position))
        };

        self.line_start = true;
        self.suppress_space = false;

        self.document.push(Element::HardLine) && self.document.push(Element::BlankLine(blanks))
    }

    fn nested(&mut self, position: u32) -> bool {
        let kind = self.tokens[position as usize].kind;

        if is_open(kind) {
            if self.depth == NEST_DEPTH_MAX {
                return false;
            }

            let bounded = self.clause_bounded(position, kind);
            let closes = self.closing_of(position);

            self.claused_body |= bounded;

            let parted = closes.is_some_and(|held| {
                self.spread_source(position, held)
                    || self.spread_forced(position, held)
                    || BLOCK_SPREADS && self.blocks_wide(position)
                    || self.body_clauses(position)
            });
            let indents = self.raised(position, parted);
            let spread = closes.and_then(|held| self.spreading(position, held));
            let lists = self.policy.width_lists && closes.is_some_and(|held| self.listed(held));

            self.nest[self.depth as usize] = Frame {
                bodied: self.bodied_brace(position),
                casts: self
                    .previous
                    .is_some_and(|held| self.word_is(held, self.policy.cast_words)),
                close: closes.unwrap_or(0),
                held: self.levels,
                indents,
                index: self.indexes(position),
                inset: self.indent,
                inside: kind == TokenKind::BlockStart && self.inside(position),
                joined: closes.is_some_and(|held| self.joined_args(position, held)),
                kind,
                lists,
                open: position,
                parted,
                spread,
                valued: (0, 0, 0),
            };

            self.depth += 1;

            let heads = self.word_is(self.line_first, self.policy.header_words)
                || self.word_is(self.line_first, self.policy.block_words);

            let headed = self.policy.header_words.is_empty()
                || self.head_word(position, self.policy.header_words).is_some();

            let statement = bounded
                || self.heritage_bodied(position)
                || self.bodied(position) && self.printed > self.levels && !heads && headed;

            let carried = if HEADER_LINES && self.policy.header_lines {
                self.header_lined(position)
                    .and_then(|head| self.line_level(head))
                    .filter(|level| *level < self.printed)
            } else {
                None
            };

            if indents {
                self.levels = if statement {
                    self.levels + 1
                } else if let Some(level) = carried {
                    level + 1
                } else {
                    self.printed + 1
                };
            }

            return true;
        }

        if is_close(kind)
            && self.depth > 0
            && self.nest[self.depth as usize - 1].kind == opened_by(kind)
        {
            self.depth -= 1;
            self.closed = self.nest[self.depth as usize];
            self.levels = self.closed.held;
        }

        true
    }

    fn indexes(&self, position: u32) -> bool {
        if self.starting {
            return false;
        }

        if self.empties(position) {
            return false;
        }

        if self.roled(position, ROLE_START) {
            return false;
        }

        let Some(previous) = self.previous else {
            return false;
        };

        let held = self.tokens[previous as usize].kind;

        if held == TokenKind::Punctuation(Punctuation::BracketClose) {
            return self.closed.index;
        }

        ends_operand(held)
    }

    const fn frame(&self) -> Frame {
        if self.depth == 0 {
            return Frame::EMPTY;
        }

        self.nest[self.depth as usize - 1]
    }

    fn word_is(&self, position: u32, words: &[&[u8]]) -> bool {
        let bytes = self.tokens[position as usize].text(self.source);

        words.contains(&bytes)
    }

    fn inside(&self, position: u32) -> bool {
        if let Some(held) = self.counted(position) {
            return held;
        }

        if self.bodied(position) && self.inline(position) {
            return true;
        }

        self.hugs_a_word()
            || self.inline(position)
                && (self.opens_a_block(position)
                    || self.policy.brace_spaces
                        && !self
                            .previous
                            .is_some_and(|held| self.word_is(held, self.policy.hug_words)))
            || self.policy.brace_counts && self.opens_with(position)
    }

    fn opens_with(&self, position: u32) -> bool {
        let Some(next) = self.next_of(position) else {
            return false;
        };

        let held = self.tokens[next as usize].kind != TokenKind::BlockEnd
            && self.parted_by(
                self.tokens[position as usize].end(),
                self.tokens[next as usize].offset,
            ) == 0;

        held && !self.hugs_sole(position)
    }

    fn hugs_sole(&self, position: u32) -> bool {
        let count = self.count;
        let mut depth = 0;
        let mut elements = 0;
        let mut first = None;
        let mut fresh = true;
        let mut last = position;
        let mut scan = position;

        while scan < count {
            let token = self.tokens[scan as usize];

            scan += 1;

            if token.kind == TokenKind::Newline || token.length == 0 {
                continue;
            }

            let level = depth;

            if is_open(token.kind) {
                depth += 1;
            }

            if is_close(token.kind) {
                depth -= 1;

                if depth == 0 {
                    break;
                }
            }

            last = scan - 1;

            if level != 1 {
                continue;
            }

            if token.kind == TokenKind::Punctuation(Punctuation::Comma) {
                fresh = true;
            } else if fresh {
                elements += 1;
                fresh = false;

                if first.is_none() {
                    first = Some(scan - 1);
                }
            }
        }

        if elements != 1 {
            return false;
        }

        if self
            .next_of(position)
            .is_some_and(|held| self.opens_a_literal(held))
        {
            return true;
        }

        let Some(held) = first.filter(|_| self.policy.sole_hugs) else {
            return false;
        };

        !self.fields(held)
            && !self.roled(held, ROLE_SPAN)
            && !matches!(
                self.tokens[last as usize].kind,
                TokenKind::Comment | TokenKind::Punctuation(Punctuation::Comma)
            )
    }

    fn opens_a_literal(&self, position: u32) -> bool {
        let kind = self.tokens[position as usize].kind;

        if kind == TokenKind::BlockStart {
            return true;
        }

        self.is_dot(position)
            && self
                .next_of(position)
                .is_some_and(|held| self.tokens[held as usize].kind == TokenKind::BlockStart)
    }

    fn counted(&self, position: u32) -> Option<bool> {
        if !self.policy.brace_counts || self.hugs_a_word() || self.bodied(position) {
            return None;
        }

        let previous = self.previous?;

        if !self.inline(position) || !self.hugged(position, previous) && !self.is_dot(previous) {
            return None;
        }

        let count = self.count;
        let mut depth = 0;
        let mut elements = 0;
        let mut first = None;
        let mut fresh = true;
        let mut scan = position;

        while scan < count {
            let token = self.tokens[scan as usize];

            if token.kind == TokenKind::Newline || token.length == 0 {
                scan += 1;

                continue;
            }

            let level = depth;

            if is_open(token.kind) {
                depth += 1;
            }

            if is_close(token.kind) {
                depth -= 1;

                if depth == 0 {
                    break;
                }
            }

            if level == 1 {
                if token.kind == TokenKind::Punctuation(Punctuation::Semicolon) {
                    return None;
                }

                if token.kind == TokenKind::Punctuation(Punctuation::Comma) {
                    fresh = true;
                } else if fresh {
                    elements += 1;
                    fresh = false;

                    if first.is_none() {
                        first = Some(scan);
                    }
                }
            }

            scan += 1;
        }

        if elements == 0 {
            return Some(false);
        }

        if first.is_some_and(|held| self.fields(held)) {
            return Some(true);
        }

        Some(elements > 1)
    }

    fn fields(&self, position: u32) -> bool {
        if !self.is_dot(position) {
            return false;
        }

        let Some(name) = self.next_of(position) else {
            return false;
        };

        if self.tokens[name as usize].kind != TokenKind::Identifier {
            return false;
        }

        self.next_of(name)
            .is_some_and(|held| self.tokens[held as usize].text(self.source) == b"=")
    }

    fn hugs_a_word(&self) -> bool {
        let Some(held) = self.previous else {
            return false;
        };

        if self.word_is(held, self.policy.brace_words) {
            return true;
        }

        self.tokens[held as usize].kind == TokenKind::Punctuation(Punctuation::ParenClose)
            && self.closed.open > 0
            && self.word_is(self.closed.open - 1, self.policy.brace_words)
    }

    fn inline(&self, position: u32) -> bool {
        let Some(close) = self.closing_of(position) else {
            return false;
        };

        !self.fields_wide(position)
            && (INLINE_LAYOUT && self.policy.inline_layout
                || !self.parts_at(position, close)
                || self.branch_inline(position)
                || self.literal_joined(position))
            && !self.parting(position, close)
    }

    fn pattern_brace(&self, open: u32, close: u32) -> bool {
        if !self.policy.chain_simples || self.tokens[open as usize].kind != TokenKind::BlockStart {
            return false;
        }

        if self.pattern_nested(open, close) || !self.pattern_fits(open, close) {
            return false;
        }

        if self
            .next_of(close)
            .is_some_and(|held| self.tokens[held as usize].text(self.source) == b"=")
        {
            return true;
        }

        let Some(before) = self.back_of(open) else {
            return false;
        };

        if matches!(
            self.tokens[before as usize].text(self.source),
            b"const" | b"let" | b"var"
        ) {
            return true;
        }

        let paren = if self.tokens[before as usize].kind
            == TokenKind::Punctuation(Punctuation::ParenOpen)
        {
            before
        } else if self.tokens[before as usize].kind == TokenKind::Punctuation(Punctuation::Comma) {
            let Some(held) = self.enclosing_open(open) else {
                return false;
            };

            held
        } else {
            return false;
        };

        if self.tokens[paren as usize].kind != TokenKind::Punctuation(Punctuation::ParenOpen) {
            return false;
        }

        let Some(shut) = self.closing_of(paren) else {
            return false;
        };

        self.next_of(shut).is_some_and(|held| {
            self.tokens[held as usize].kind == TokenKind::BlockStart
                || self.tokens[held as usize].text(self.source) == b"=>"
        })
    }

    pub(super) fn pattern_joined(&self, position: u32) -> bool {
        if !self.policy.chain_simples || self.depth == 0 {
            return false;
        }

        let frame = self.nest[self.depth as usize - 1];

        if frame.kind != TokenKind::BlockStart || frame.open < self.line_first {
            return false;
        }

        let Some(close) = self.closing_of(frame.open) else {
            return false;
        };

        position <= close && self.pattern_brace(frame.open, close)
    }

    fn enclosing_open(&self, position: u32) -> Option<u32> {
        let mut depth = 0_u32;
        let mut scan = position;

        for _ in 0..DEFINE_SCAN_MAX {
            let held = self.back_of(scan)?;
            let kind = self.tokens[held as usize].kind;

            if is_close(kind) || kind == TokenKind::BlockEnd {
                depth += 1;
            } else if is_open(kind) || kind == TokenKind::BlockStart {
                if depth == 0 {
                    return Some(held);
                }

                depth -= 1;
            }

            scan = held;
        }

        None
    }

    fn pattern_fits(&self, open: u32, close: u32) -> bool {
        let (from, level) = self
            .line_lead(open)
            .unwrap_or((self.line_first, self.printed));

        if from > open {
            return false;
        }

        let width = self.printed_columns(from, self.pattern_end(close));

        level * self.options.indent_width + width <= self.options.line_width
    }

    fn pattern_end(&self, close: u32) -> u32 {
        let mut depth = 0_u32;
        let mut scan = close;

        for _ in 0..DEFINE_SCAN_MAX {
            let Some(next) = self.next_of(scan) else {
                return scan;
            };

            let kind = self.tokens[next as usize].kind;

            if kind == TokenKind::BlockStart {
                return next;
            }

            if is_open(kind) {
                depth += 1;
            } else if is_close(kind) || kind == TokenKind::BlockEnd {
                if depth == 0 {
                    return scan;
                }

                depth -= 1;
            } else if depth == 0
                && matches!(
                    kind,
                    TokenKind::Punctuation(Punctuation::Comma | Punctuation::Semicolon)
                )
            {
                return next;
            }

            scan = next;
        }

        scan
    }

    fn pattern_nested(&self, open: u32, close: u32) -> bool {
        let mut depth = 0_u32;
        let mut scan = open + 1;

        while scan < close {
            let kind = self.tokens[scan as usize].kind;

            if is_open(kind) || kind == TokenKind::BlockStart {
                if depth == 0
                    && matches!(
                        kind,
                        TokenKind::BlockStart | TokenKind::Punctuation(Punctuation::BracketOpen)
                    )
                {
                    return true;
                }

                depth += 1;
            } else if is_close(kind) || kind == TokenKind::BlockEnd {
                depth = depth.saturating_sub(1);
            }

            scan += 1;
        }

        false
    }

    fn bodied_brace(&self, position: u32) -> bool {
        if self.tokens[position as usize].kind != TokenKind::BlockStart {
            return false;
        }

        if self.policy.angle_calls && self.brackets.angles_at(position) > 0 {
            return false;
        }

        let Some(before) = self
            .word_before(position)
            .and_then(|held| self.coded_at(held))
        else {
            return true;
        };

        let held = self.tokens[before as usize];

        if matches!(
            held.kind,
            TokenKind::BlockEnd
                | TokenKind::BlockStart
                | TokenKind::Punctuation(Punctuation::ParenClose | Punctuation::Semicolon)
        ) {
            return true;
        }

        let text = held.text(self.source);

        if matches!(text, b"else" | b"do" | b"try" | b"finally") {
            return true;
        }

        if self.declared_body(position) {
            return true;
        }

        if held.kind == TokenKind::Punctuation(Punctuation::Colon) {
            return self.armed(before) || self.returned(before);
        }

        text == b"=>" && !self.typed || self.returned(before)
    }

    fn declared_body(&self, position: u32) -> bool {
        if self.policy.declaration_words.is_empty() {
            return false;
        }

        let mut depth = 0_u32;
        let mut scan = position;

        for _ in 0..TYPE_SCAN_MAX {
            if scan == 0 {
                return false;
            }

            scan -= 1;

            let token = self.tokens[scan as usize];

            if token.kind == TokenKind::BlockEnd && depth == 0 {
                return false;
            }

            if is_close(token.kind) {
                depth += 1;

                continue;
            }

            if is_open(token.kind) || substituting(self.source, token) {
                if depth == 0 {
                    return false;
                }

                depth -= 1;

                continue;
            }

            if depth > 0 {
                continue;
            }

            if self.word_is(scan, self.policy.declaration_words) {
                return true;
            }

            let held = matches!(
                token.kind,
                TokenKind::Identifier | TokenKind::Keyword(_) | TokenKind::String
            ) || matches!(token.text(self.source), b"." | b"," | b"<" | b">");

            if !held {
                return false;
            }
        }

        false
    }

    fn returned(&self, position: u32) -> bool {
        let mut angles = 0_u32;
        let mut brackets = 0_u32;
        let mut scan = Some(position);

        for read in 0..TYPE_SCAN_MAX {
            let Some(held) = scan else {
                return false;
            };

            let token = self.tokens[held as usize];
            let text = token.text(self.source);

            if !Self::nested_type(text, &mut angles, &mut brackets) {
                return false;
            }

            if token.kind == TokenKind::Punctuation(Punctuation::Colon) {
                return read > 0
                    && !reach::branched(self.source, self.tokens, self.brackets, held)
                    && self.word_before(held).is_some_and(|before| {
                        self.tokens[before as usize].kind
                            == TokenKind::Punctuation(Punctuation::ParenClose)
                    });
            }

            let typed = matches!(token.kind, TokenKind::Identifier | TokenKind::Keyword(_))
                || matches!(text, b"." | b"<" | b">" | b"[" | b"]" | b"|" | b"&" | b",");

            if !typed {
                return false;
            }

            scan = self.word_before(held);
        }

        false
    }

    fn nested_type(text: &[u8], angles: &mut u32, brackets: &mut u32) -> bool {
        if text == b"<" {
            if *angles == 0 {
                return false;
            }

            *angles -= 1;
        } else if !text.is_empty() && text.iter().all(|byte| *byte == b'>') {
            *angles += count_of(text.len());
        } else if text == b"[" {
            if *brackets == 0 {
                return false;
            }

            *brackets -= 1;
        } else if text == b"]" {
            *brackets += 1;
        }

        true
    }

    fn parting(&self, from: u32, to: u32) -> bool {
        if !self.policy.body_parts {
            return false;
        }

        let mut scan = from;

        while scan < to {
            if self.parts_after(scan, from) {
                return true;
            }

            scan += 1;
        }

        false
    }

    fn parts_after(&self, position: u32, open: u32) -> bool {
        self.parts_body(position) || self.arms(position) || self.ends_statement(position, open)
    }

    fn ends_statement(&self, position: u32, open: u32) -> bool {
        self.bodied_brace(open) && self.parted_statement(position)
    }

    fn parted_statement(&self, position: u32) -> bool {
        self.policy.body_parts
            && (self.tokens[position as usize].kind
                == TokenKind::Punctuation(Punctuation::Semicolon)
                || self.membered(position))
    }

    fn ends_body(&self, position: u32) -> bool {
        self.depth > 0
            && self.nest[self.depth as usize - 1].close == position
            && self.parts_body(self.nest[self.depth as usize - 1].open)
    }

    fn parts_body(&self, position: u32) -> bool {
        self.policy.body_parts
            && self.bodied_brace(position)
            && self
                .next_of(position)
                .is_some_and(|held| self.tokens[held as usize].kind != TokenKind::BlockEnd)
    }

    pub(super) fn parted_by(&self, from: u32, to: u32) -> u32 {
        self.breaks.counted(from, to)
    }

    fn parts_at(&self, previous: u32, position: u32) -> bool {
        self.parted_by(
            self.tokens[previous as usize].end(),
            self.tokens[position as usize].offset,
        ) > 0
    }

    fn run(&mut self) -> bool {
        let count = self.count;
        let mut written = false;

        for position in 0..count {
            let token = self.tokens[position as usize];

            if !self.wrapped_close(position) {
                return false;
            }

            if position < self.resume || token.kind == TokenKind::Newline || token.length == 0 {
                continue;
            }

            if written && self.added(position) && !self.separated(position) {
                return false;
            }

            if self.dropped(position) {
                continue;
            }

            if written && self.split(position) && !self.newline(position) {
                return false;
            }

            if !self.token(position) {
                return false;
            }

            written = true;
        }

        if !self.wrapped_close(count) || !self.level(0) {
            return false;
        }

        if !written {
            return true;
        }

        if self.previous.is_some_and(|held| {
            self.tokens[held as usize]
                .text(self.source)
                .ends_with(b"\n")
        }) {
            return true;
        }

        self.document.push(Element::HardLine)
    }

    fn remark_ended(&self, previous: u32) -> bool {
        let token = self.tokens[previous as usize];
        let text = token.text(self.source);

        token.kind == TokenKind::Comment && text.starts_with(b"//") && !text.ends_with(b"\n")
    }

    fn remark_opened(&self, position: u32, previous: u32) -> bool {
        REMARK_OPENS
            && self.policy.brace_remarks
            && self.tokens[position as usize].kind == TokenKind::Comment
            && self.tokens[position as usize]
                .text(self.source)
                .starts_with(b"//")
            && is_open(self.tokens[previous as usize].kind)
    }

    fn breaks(&self, position: u32, previous: u32) -> bool {
        self.remark_opened(position, previous)
            || self.forced(position, previous)
            || self.declare_broken(position, previous)
            || self.header_broken(position, previous)
            || self.sequence_broken(position, previous)
            || self.body_broken(position, previous)
            || self.spread_listed(position, previous)
            || self.assign_wrapped(position, previous)
            || self.assign_headed(position, previous)
            || self.assign_rooted(position, previous)
            || self.chain_parts(position, previous)
            || self.binary_broken(position, previous)
            || self.binary_assigned(previous)
            || self.brace_broken(position)
            || self.attribute_broken(position)
            || self.chain_orphaned(position)
            || self.linked_operand(position, previous)
    }

    #[expect(
        clippy::too_many_lines,
        reason = "the list names every rule that joins or parts a line, and the order it reads \
                  them in is the rule"
    )]
    fn split(&self, position: u32) -> bool {
        let Some(previous) = self.previous else {
            return false;
        };

        if self.remark_ended(previous) && !self.spreads() {
            return true;
        }

        if self.chain_broken(position) || self.member_parted(position) {
            return true;
        }

        if self.clause_parted(position, previous) {
            return true;
        }

        if self.value_parted(position, previous) {
            return true;
        }

        if self.policy.chain_simples
            && self.spreads()
            && (self.binary_spread(position, previous) || self.chain_parts(position, previous))
        {
            return true;
        }

        if self.spreads()
            || self.assigned.is_some_and(|(held, _)| previous == held)
            || self.arm_opened(position, previous)
            || self.define_joined(position)
            || self.root_joined(position, previous)
            || self.macro_joined(position)
            || self.mixed_joined(position)
            || self.hug_joined(position)
            || self.operand_joined(position, previous)
            || self.binary_joined(position, previous)
            || self.chain_hugged(position)
            || self.chain_flatted(position)
            || self.pattern_joined(position)
            || self.sole_joined(position)
            || self.fields_joined(position)
            || self.attribute_joined(position)
            || self.arm_emptied(position, previous)
            || self.item_joined(position)
            || self.owned_join(position)
            || self.operand_snuggled(position, previous)
            || self.wrap_headed()
            || self.brace_joined(position, previous)
            || self.header_fitted(position, previous)
            || self.value_joined(position, previous)
            || self.binary_wrapped()
            || self.ternary_parted(position)
            || self.ternary_parted(previous)
            || self.tested_joined(position)
            || self.derive_added(position)
        {
            return false;
        }

        if let Some(held) = self.mixed_filled(position) {
            return held;
        }

        if self.parts_role(position, previous) || self.owned_break(position) {
            return true;
        }

        if let Some(held) = self.emptied(position, previous) {
            return held;
        }

        if self.bodied_edge(position, previous) || self.arm_broken(position, previous) {
            return true;
        }

        if self.policy.brace_parts {
            if self.parted(position, previous) {
                return true;
            }

            let remarked = self.tokens[position as usize].kind == TokenKind::Comment
                || self.tokens[previous as usize].kind == TokenKind::Comment;

            if !remarked && !self.valued_source(position) {
                return false;
            }
        }

        if self.breaks(position, previous) {
            return true;
        }

        if self.follows_a_brace(position, previous) {
            return false;
        }

        let from = self.tokens[previous as usize].end();
        let to = self.tokens[position as usize].offset;

        if self.semicolon_joined(position, previous) {
            return false;
        }

        self.parted_by(from, to) > 0
            && !self.assign_joined(position, previous)
            && !self.cast_joined(position, previous)
            && !self.flat_joined(position)
            && !self.header_joined(position, previous)
            && !self.branch_joined(position, previous)
            && !self.chain_flat(position, previous)
            && !self.else_joined(position)
            && !self.angle_joined(position)
    }

    fn body_broken(&self, position: u32, previous: u32) -> bool {
        if self.body_remarked(position, previous) {
            return false;
        }

        if self.tokens[previous as usize].kind == TokenKind::BlockStart {
            return self.body_clauses(previous);
        }

        if self.tokens[position as usize].kind == TokenKind::BlockEnd {
            return reach::opened(self.source, self.tokens, position)
                .is_some_and(|open| self.body_clauses(open));
        }

        self.tokens[previous as usize].kind == TokenKind::Punctuation(Punctuation::Semicolon)
            && self.depth > 0
            && self.nest[self.depth as usize - 1].kind == TokenKind::BlockStart
            && self.body_clauses(self.nest[self.depth as usize - 1].open)
    }

    pub(super) fn body_clauses(&self, open: u32) -> bool {
        BODY_BREAKS
            && self.policy.brace_bodies
            && !self.body_defined(open)
            && (self.braced_clauses(open) || self.body_headed(open) || self.block_budgeted(open))
    }

    fn body_headed(&self, open: u32) -> bool {
        BODY_HEADS
            && self.tokens[open as usize].kind == TokenKind::BlockStart
            && !self
                .back_of(open)
                .is_some_and(|held| self.word_is(held, BODY_VALUES))
            && self.body_worded(open)
            && self
                .closing_of(open)
                .is_some_and(|close| self.next_of(open) != Some(close))
    }

    fn body_worded(&self, open: u32) -> bool {
        let mut depth = 0_u32;
        let mut scan = open;

        for _ in 0..TYPE_SCAN_MAX {
            let Some(held) = self.back_of(scan) else {
                return false;
            };

            let kind = self.tokens[held as usize].kind;

            if is_close(kind) {
                if depth == 0 && kind == TokenKind::BlockEnd {
                    return false;
                }

                depth += 1;
            } else if is_open(kind) {
                if depth == 0 {
                    return false;
                }

                depth -= 1;
            } else if depth == 0 {
                if self.word_is(held, BODY_WORDS) {
                    return true;
                }

                if self.word_is(held, BODY_STOPS) {
                    return false;
                }
            }

            scan = held;
        }

        false
    }

    fn body_defined(&self, open: u32) -> bool {
        (0..self.depth)
            .map(|level| self.nest[level as usize])
            .any(|frame| frame.open <= open && self.body_defining(frame.open))
            || self.body_defining(open)
    }

    fn body_defining(&self, open: u32) -> bool {
        if self.defined_brace(open) {
            return true;
        }

        let Some(close) = self.back_of(open).filter(|held| {
            self.tokens[*held as usize].kind == TokenKind::Punctuation(Punctuation::ParenClose)
        }) else {
            return false;
        };

        reach::opened(self.source, self.tokens, close)
            .and_then(|found| self.back_of(found))
            .is_some_and(|name| self.defining(name))
    }

    fn body_remarked(&self, position: u32, previous: u32) -> bool {
        self.tokens[position as usize].kind == TokenKind::Comment
            && !self.parts_at(previous, position)
    }

    fn braced_clauses(&self, open: u32) -> bool {
        let Some(close) = self.closing_of(open) else {
            return false;
        };

        let mut depth = 0_u32;
        let mut scan = open + 1;

        while scan < close {
            let kind = self.tokens[scan as usize].kind;

            if is_open(kind) && kind != TokenKind::BlockStart {
                depth += 1;
            } else if is_close(kind) && kind != TokenKind::BlockEnd {
                depth = depth.saturating_sub(1);
            } else if depth == 0 && kind == TokenKind::Punctuation(Punctuation::Semicolon) {
                return true;
            }

            scan += 1;
        }

        false
    }

    fn arm_broken(&self, position: u32, previous: u32) -> bool {
        self.arms(previous) && self.tokens[position as usize].kind != TokenKind::BlockStart
            || self.policy.body_parts
                && self.arming(position)
                && matches!(
                    self.tokens[previous as usize].kind,
                    TokenKind::BlockEnd | TokenKind::Punctuation(Punctuation::Semicolon)
                )
    }

    fn valued_source(&self, position: u32) -> bool {
        if self.policy.source_values.is_empty() && self.policy.value_cap == 0 {
            return false;
        }

        let Some(head) = self.statement_head(position) else {
            return false;
        };

        if head == position {
            return false;
        }

        let Some(named) = self.next_of(head).filter(|held| {
            self.tokens[*held as usize].kind == TokenKind::Punctuation(Punctuation::Colon)
        }) else {
            return false;
        };

        if self.word_is(head, self.policy.source_values) {
            return true;
        }

        self.policy.value_cap > 0
            && self.tokens[head as usize]
                .text(self.source)
                .starts_with(b"--")
            && self.valued_count(named) > self.policy.value_cap
            && self.levels * self.options.indent_width + self.valued_width(head)
                > self.options.line_width
    }

    fn valued_width(&self, head: u32) -> u32 {
        let first = self.tokens[head as usize];
        let mut width = columns(self.source, first.offset, first.end());
        let mut scan = head;

        for _ in 0..DEFINE_SCAN_MAX {
            let Some(next) = self.next_of(scan) else {
                return width;
            };

            let token = self.tokens[next as usize];
            let after = self.tokens[scan as usize].end();

            width +=
                u32::from(token.offset > after) + columns(self.source, token.offset, token.end());

            if token.kind == TokenKind::Punctuation(Punctuation::Semicolon) {
                return width;
            }

            scan = next;
        }

        width
    }

    fn valued_count(&self, colon: u32) -> u32 {
        let mut depth = 0_u32;
        let mut found = 0_u32;
        let mut scan = colon;

        for _ in 0..DEFINE_SCAN_MAX {
            let Some(held) = self.next_of(scan) else {
                return found;
            };

            let kind = self.tokens[held as usize].kind;

            if depth == 0
                && matches!(
                    kind,
                    TokenKind::Punctuation(Punctuation::Semicolon) | TokenKind::BlockEnd
                )
            {
                return found;
            }

            if is_open(kind) {
                depth += 1;
            } else if is_close(kind) {
                depth = depth.saturating_sub(1);
            } else if depth == 0 && kind != TokenKind::Punctuation(Punctuation::Comma) {
                found += 1;
            }

            scan = held;
        }

        found
    }

    fn welded(&self, position: u32, previous: u32) -> bool {
        let held = self.tokens[previous as usize].kind;
        let kind = self.tokens[position as usize].kind;
        let spaced = self.policy.brace_spaces;
        let opened = is_open(held) && !(spaced && held == TokenKind::BlockStart);
        let closed = is_close(kind) && !(spaced && kind == TokenKind::BlockEnd);

        opened
            || closed
            || self.is_dot(position)
            || self.is_dot(previous)
            || matches!(
                kind,
                TokenKind::Punctuation(Punctuation::Comma | Punctuation::Semicolon)
            )
    }

    fn semicolon_joined(&self, position: u32, previous: u32) -> bool {
        if self.tokens[position as usize].kind != TokenKind::Punctuation(Punctuation::Semicolon) {
            return false;
        }

        let token = self.tokens[previous as usize];
        let text = token.text(self.source);

        token.kind != TokenKind::Punctuation(Punctuation::Semicolon)
            && !text.starts_with(b"//")
            && !text.starts_with(br"\\")
            && !text.contains(&b'\n')
    }

    fn statement_head(&self, position: u32) -> Option<u32> {
        let mut depth = 0_u32;
        let mut scan = position;

        for _ in 0..DEFINE_SCAN_MAX {
            let Some(held) = self.back_of(scan) else {
                return Some(scan);
            };

            let kind = self.tokens[held as usize].kind;

            if is_close(kind) || kind == TokenKind::BlockEnd {
                if depth == 0 && kind == TokenKind::BlockEnd && !self.joins_a_value(held) {
                    return Some(scan);
                }

                depth += 1;
            } else if is_open(kind) || kind == TokenKind::BlockStart {
                if depth == 0 {
                    return Some(scan);
                }

                depth -= 1;
            } else if depth == 0 && kind == TokenKind::Punctuation(Punctuation::Semicolon) {
                return Some(scan);
            }

            scan = held;
        }

        None
    }

    fn follows_a_brace(&self, position: u32, previous: u32) -> bool {
        if self.policy.follow_words.is_empty()
            || self.tokens[previous as usize].kind != TokenKind::BlockEnd
            || !self.word_is(position, self.policy.follow_words)
        {
            return false;
        }

        if self.tokens[position as usize].text(self.source) != b"while" {
            return true;
        }

        self.back_of(self.closed.open)
            .is_some_and(|held| self.tokens[held as usize].text(self.source) == b"do")
    }

    fn columned(&self, position: u32, previous: u32) -> bool {
        let token = self.tokens[position as usize];

        if token.kind != TokenKind::Comment || !token.text(self.source).starts_with(b"/*") {
            return false;
        }

        if self.broke(previous, position) {
            return false;
        }

        let frame = self.frame();

        let grouped = frame.kind == TokenKind::Punctuation(Punctuation::ParenOpen)
            && self
                .back_of(frame.open)
                .is_some_and(|held| self.word_is(held, self.policy.declare_words));

        if !grouped {
            return false;
        }

        let Some(next) = self.next_of(position) else {
            return false;
        };

        if self.tokens[next as usize].kind == TokenKind::Punctuation(Punctuation::Assign)
            || self.broke(position, next)
        {
            return false;
        }

        self.named_run(previous)
    }

    fn named_run(&self, position: u32) -> bool {
        let mut scan = position;

        while scan > self.line_first {
            let kind = self.tokens[scan as usize].kind;

            if kind != TokenKind::Identifier && kind != TokenKind::Punctuation(Punctuation::Comma) {
                return false;
            }

            let Some(held) = self.back_of(scan) else {
                return false;
            };

            scan = held;
        }

        self.tokens[scan as usize].kind == TokenKind::Identifier
    }

    fn broke(&self, from: u32, to: u32) -> bool {
        self.parted_by(
            self.tokens[from as usize].end(),
            self.tokens[to as usize].offset,
        ) > 0
    }

    fn fields_level(&self, open: u32) -> bool {
        if self.policy.field_width == 0 {
            return false;
        }

        if !self
            .back_of(open)
            .is_some_and(|held| self.word_is(held, self.policy.brace_words))
        {
            return false;
        }

        self.fields_wide(open)
            || self
                .closing(open)
                .is_some_and(|close| self.parts_at(open, close))
    }

    fn fields_wide(&self, open: u32) -> bool {
        if self.policy.field_width == 0
            || !self
                .back_of(open)
                .is_some_and(|held| self.word_is(held, self.policy.brace_words))
        {
            return false;
        }

        let Some(close) = self.closing(open) else {
            return false;
        };

        let Some(first) = self.next_of(open) else {
            return false;
        };

        if first == close
            || self.parted_by(
                self.tokens[open as usize].end(),
                self.tokens[close as usize].offset,
            ) > 0
        {
            return false;
        }

        let last = self.back_of(close).unwrap_or(first);

        self.fields_parted(first, last)
            || !self.fields_called(first, last)
                && self.fields_width(first, last) > self.policy.field_width
    }

    fn rested(&self, position: u32) -> bool {
        self.rested_run(position)
    }

    fn arms(&self, position: u32) -> bool {
        self.policy.body_parts
            && self.tokens[position as usize].kind == TokenKind::Punctuation(Punctuation::Colon)
            && self.armed(position)
    }

    fn armed(&self, position: u32) -> bool {
        let mut depth = 0_u32;
        let mut scan = position;

        while scan > 0 {
            scan -= 1;

            let token = self.tokens[scan as usize];

            if is_close(token.kind) {
                if depth == 0 {
                    if let Some(open) = self.brackets.open_of(scan) {
                        scan = open;

                        continue;
                    }
                }

                depth += 1;

                continue;
            }

            if is_open(token.kind) || substituting(self.source, token) {
                if depth == 0 {
                    return false;
                }

                depth -= 1;

                continue;
            }

            if depth > 0 {
                continue;
            }

            let reached = self.word_before(scan).is_some_and(|held| self.is_dot(held));
            let armed = !reached && self.word_is(scan, self.policy.clause_words);

            if armed {
                return self.word_before(scan).is_none_or(|before| {
                    let kind = self.tokens[before as usize].kind;

                    matches!(
                        kind,
                        TokenKind::BlockEnd
                            | TokenKind::Punctuation(Punctuation::Colon | Punctuation::Semicolon)
                    ) || kind == TokenKind::BlockStart
                        && self.word_before(before).is_some_and(|held| {
                            self.tokens[held as usize].kind
                                == TokenKind::Punctuation(Punctuation::ParenClose)
                        })
                });
            }

            if matches!(token.kind, TokenKind::Keyword(_)) {
                return false;
            }

            let held = matches!(
                token.kind,
                TokenKind::Comment
                    | TokenKind::Punctuation(
                        Punctuation::Colon | Punctuation::Comma | Punctuation::Semicolon
                    )
            );

            if held || token.text(self.source) == b"?" {
                return false;
            }
        }

        false
    }

    fn bodied_edge(&self, position: u32, previous: u32) -> bool {
        if !self.policy.body_parts || !self.inside_a_body() {
            return false;
        }

        let kind = self.tokens[position as usize].kind;
        let held = self.tokens[previous as usize].kind;

        if self.depth > 0 && (held == TokenKind::BlockStart || kind == TokenKind::BlockEnd) {
            return true;
        }

        let ended = held == TokenKind::Punctuation(Punctuation::Semicolon)
            || self.membered(previous)
            || held == TokenKind::BlockEnd
                && self.parts_body(self.closed.open)
                && self.opens_a_statement(position);

        ended && !self.rides_a_line(position, previous)
    }

    pub(super) fn inside_a_body(&self) -> bool {
        self.depth == 0 || self.frame().bodied
    }

    fn opens_a_statement(&self, position: u32) -> bool {
        let token = self.tokens[position as usize];

        if matches!(
            token.text(self.source),
            b"as"
                | b"catch"
                | b"else"
                | b"finally"
                | b"in"
                | b"instanceof"
                | b"satisfies"
                | b"while"
        ) {
            return false;
        }

        matches!(
            token.kind,
            TokenKind::BlockStart | TokenKind::Identifier | TokenKind::Keyword(_)
        )
    }

    fn rides_a_line(&self, position: u32, previous: u32) -> bool {
        self.tokens[position as usize].kind == TokenKind::Comment
            && !self.parts_at(previous, position)
    }

    fn separated(&mut self, position: u32) -> bool {
        let typed = self.typed || self.typed_brace(position) || self.branch_tailed(position);

        let held = if typed && self.tokens[position as usize].kind == TokenKind::BlockEnd {
            self.semicolon
        } else {
            self.comma
        };

        self.document.push(Element::Text(Source::Literal, held))
    }

    fn fields_separator(&self, position: u32) -> bool {
        if self.policy.field_width == 0
            || self.depth == 0
            || self.tokens[position as usize].kind != TokenKind::Punctuation(Punctuation::Semicolon)
        {
            return false;
        }

        let frame = self.frame();

        if frame.kind != TokenKind::BlockStart
            || !self
                .back_of(frame.open)
                .is_some_and(|held| self.word_is(held, self.policy.brace_words))
        {
            return false;
        }

        self.fields_wide(frame.open) || self.next_of(position) == self.closing(frame.open)
    }

    fn dropped(&self, position: u32) -> bool {
        if self.derive_dropped(position) || self.wrap_dropped(position) {
            return true;
        }

        if self.arm_dropped(position)
            || self.angle_dropped(position)
            || self.fields_separator(position)
            || self.flattened(position)
            || self.union_dropped(position)
        {
            return true;
        }

        let separator = matches!(
            self.tokens[position as usize].kind,
            TokenKind::Punctuation(Punctuation::Comma | Punctuation::Semicolon)
        );

        let Some(next) = self.next_of(position).filter(|_| separator) else {
            return false;
        };

        if !is_close(self.tokens[next as usize].kind) {
            return false;
        }

        if self.spreads()
            && !self.chains_a_header()
            && (!self.soled_tuple(next) || self.parts_at(position, next))
            && next == self.nest[self.depth as usize - 1].close
        {
            return true;
        }

        if self.macro_tailed(next) {
            return false;
        }

        let joined = self.parts_at(position, next)
            && (self.flat_joined(next)
                || self.hug_joined(next)
                || self.pattern_joined(next)
                || self.sole_joined(next)
                || self.fields_joined(next)
                || self.tested_joined(position))
            && !self.soled_tuple(next);

        if !self.policy.comma_drops && !joined
            || self.tokens[position as usize].kind != TokenKind::Punctuation(Punctuation::Comma)
        {
            return false;
        }

        let held = self
            .word_before(position)
            .map(|before| self.tokens[before as usize].kind);

        let elided = held
            .is_none_or(|kind| is_open(kind) || kind == TokenKind::Punctuation(Punctuation::Comma));

        if elided {
            return false;
        }

        joined || !self.parts_at(position, next)
    }

    fn soled_tuple(&self, close: u32) -> bool {
        if self.tokens[close as usize].kind != TokenKind::Punctuation(Punctuation::ParenClose) {
            return false;
        }

        let Some(open) = reach::opened(self.source, self.tokens, close) else {
            return false;
        };

        !self.calling(open) && self.element_count(open, close) < 2
    }

    fn emptied(&self, position: u32, previous: u32) -> Option<bool> {
        if self.policy.empty_words.is_empty()
            || self.tokens[position as usize].kind != TokenKind::BlockEnd
            || self.tokens[previous as usize].kind != TokenKind::BlockStart
        {
            return None;
        }

        Some(self.clausing(previous))
    }

    fn clausing(&self, position: u32) -> bool {
        let Some(before) = self.word_before(position) else {
            return true;
        };

        if self.word_is(before, self.policy.empty_words) {
            return true;
        }

        if self.tokens[before as usize].kind != TokenKind::Punctuation(Punctuation::ParenClose) {
            return false;
        }

        let Some(open) = reach::opened(self.source, self.tokens, before) else {
            return false;
        };

        if !self
            .word_before(open)
            .is_some_and(|word| self.word_is(word, self.policy.empty_words))
        {
            return false;
        }

        !self.clauses_at(open, before)
    }

    fn clauses_at(&self, open: u32, close: u32) -> bool {
        let mut scan = open + 1;

        while scan < close {
            if self.tokens[scan as usize].kind == TokenKind::Punctuation(Punctuation::Semicolon) {
                return true;
            }

            scan += 1;
        }

        false
    }

    fn comma_parted(&self, position: u32, previous: u32) -> bool {
        if !matches!(
            self.tokens[position as usize].kind,
            TokenKind::Punctuation(Punctuation::BracketClose | Punctuation::ParenClose)
        ) {
            return false;
        }

        let Some(open) = self.brackets.open_of(position) else {
            return false;
        };

        COMMA_PARTS
            && self.policy.comma_parts
            && self.element_count(open, position) > 1
            && self.listed(position)
            && self.attribute_head().is_none()
            && self.parts_at(previous, position)
            && self.split(position)
    }

    fn added(&self, position: u32) -> bool {
        if self.derive_added(position) {
            return true;
        }

        if self.branch_tailed(position) {
            return true;
        }

        if self.spreads() {
            return false;
        }

        if !matches!(
            self.tokens[position as usize].kind,
            TokenKind::BlockEnd
                | TokenKind::Punctuation(Punctuation::BracketClose | Punctuation::ParenClose)
        ) {
            return false;
        }

        if self.policy.arm_guards && (self.arm_commas(position) || self.arm_tailed(position)) {
            return true;
        }

        let Some(previous) = self.previous else {
            return false;
        };

        if !self.policy.comma_adds
            && !self.calls(position, previous)
            && !self.literals(position, previous)
            && !self.comma_parted(position, previous)
        {
            return false;
        }

        let held = self.tokens[previous as usize].kind;

        if is_open(held)
            || held == TokenKind::Comment
            || held == TokenKind::Punctuation(Punctuation::Comma)
        {
            return false;
        }

        if self.tokens[position as usize].kind == TokenKind::BlockEnd
            && held == TokenKind::Punctuation(Punctuation::Semicolon)
        {
            return false;
        }

        if self.spread_rest(position) {
            return false;
        }

        let membered = self.typed && self.tokens[position as usize].kind == TokenKind::BlockEnd;
        let parted = self.parts_at(previous, position)
            || self.forced(position, previous)
            || self.spread_listed(position, previous)
            || membered && self.bodied_edge(position, previous);

        parted
            && (self.listed(position) || membered || self.literals(position, previous))
            && !self.comma_denied(position)
            && !self.rested(position)
            && !(join::HUG_NESTS && self.hug_joined(position))
            && !self.tested_joined(previous)
            && !self.pattern_joined(position)
            && !self.invoked()
    }

    fn listed(&self, position: u32) -> bool {
        let kind = self.tokens[position as usize].kind;
        let bracketed = kind == TokenKind::Punctuation(Punctuation::BracketClose);

        let Some(open) = reach::opened(self.source, self.tokens, position) else {
            return false;
        };

        let Some(before) = self.word_before(open) else {
            return bracketed;
        };

        let held = self.tokens[before as usize];

        if kind == TokenKind::BlockEnd {
            return self.objected(before, held) || self.angled_object(open);
        }

        if bracketed {
            return !held.ends_a_value();
        }

        self.calling(open)
            || self.headed(open)
            || self.spread_arrows(open)
            || is_close(held.kind)
            || self.tupled(open, position)
    }

    fn comma_denied(&self, position: u32) -> bool {
        if !self.policy.chain_simples
            || self.tokens[position as usize].kind
                != TokenKind::Punctuation(Punctuation::ParenClose)
        {
            return false;
        }

        let Some(open) = reach::opened(self.source, self.tokens, position) else {
            return false;
        };

        if self.headed(open) || self.paren_grouped(open, position) {
            return true;
        }

        self.word_before(open).is_some_and(|held| {
            self.tokens[held as usize].kind == TokenKind::BlockEnd && self.declares_a_body(held)
        })
    }

    fn declares_a_body(&self, close: u32) -> bool {
        let Some(open) = self.brackets.open_of(close) else {
            return false;
        };

        let Some(head) = self.statement_head(open) else {
            return false;
        };

        matches!(
            self.tokens[head as usize].text(self.source),
            b"async" | b"class" | b"function"
        )
    }

    pub(super) fn headed(&self, position: u32) -> bool {
        self.policy.header_parens
            && self
                .word_before(position)
                .is_some_and(|held| self.word_is(held, self.policy.header_words))
    }

    fn parted(&self, position: u32, previous: u32) -> bool {
        let token = self.tokens[position as usize].kind;
        let before = self.tokens[previous as usize].kind;

        if token == TokenKind::BlockEnd || before == TokenKind::BlockStart {
            return true;
        }

        if token == TokenKind::Comment
            && self.parted_by(
                self.tokens[previous as usize].end(),
                self.tokens[position as usize].offset,
            ) == 0
        {
            return false;
        }

        if before == TokenKind::Comment {
            return token != TokenKind::Punctuation(Punctuation::Semicolon) && !self.remarked;
        }

        if before == TokenKind::BlockEnd || before == TokenKind::Punctuation(Punctuation::Semicolon)
        {
            return true;
        }

        before == TokenKind::Punctuation(Punctuation::Comma) && self.selects(previous)
    }

    fn carries(&self, position: u32) -> bool {
        if !self.policy.remark_carries || self.tokens[position as usize].kind != TokenKind::Comment
        {
            return false;
        }

        if !self.continued {
            return false;
        }

        let Some(below) = self.coding(position) else {
            return true;
        };

        if self.tokens[below as usize].kind == TokenKind::BlockEnd {
            return false;
        }

        self.column_of(position) > self.column_of(below)
    }

    fn apart(&self, position: u32) -> u32 {
        if self.policy.declare_words.is_empty() || self.depth > 0 || self.carries(position) {
            return 0;
        }

        let Some(word) = self.declaring(position) else {
            return 0;
        };

        if word == position && self.documented(position) {
            return 0;
        }

        let held = self.tokens[word as usize].text(self.source);

        let changed = self
            .declared
            .is_none_or(|before| self.tokens[before as usize].text(self.source) != held);

        u32::from(word != position || changed)
    }

    fn declaring(&self, position: u32) -> Option<u32> {
        if self.word_is(position, self.policy.declare_words) {
            return Some(position);
        }

        if self.tokens[position as usize].kind != TokenKind::Comment || self.documented(position) {
            return None;
        }

        let mut scan = position;

        while self.tokens[scan as usize].kind == TokenKind::Comment {
            let next = self.next_of(scan)?;

            if self.parted_by(
                self.tokens[scan as usize].end(),
                self.tokens[next as usize].offset,
            ) > 1
            {
                return None;
            }

            scan = next;
        }

        self.word_is(scan, self.policy.declare_words)
            .then_some(scan)
    }

    fn documented(&self, position: u32) -> bool {
        let Some(before) = self.word_before(position) else {
            return false;
        };

        self.tokens[before as usize].kind == TokenKind::Comment
            && self.parted_by(
                self.tokens[before as usize].end(),
                self.tokens[position as usize].offset,
            ) <= 1
    }

    fn edges(&self, position: u32) -> bool {
        self.tokens[position as usize].kind == TokenKind::BlockEnd
            || self
                .previous
                .is_some_and(|held| self.tokens[held as usize].kind == TokenKind::BlockStart)
    }

    fn selects(&self, position: u32) -> bool {
        let mut depth = 0;
        let mut scan = position + 1;

        while scan < self.count {
            match self.tokens[scan as usize].kind {
                TokenKind::Punctuation(Punctuation::BracketOpen | Punctuation::ParenOpen) => {
                    depth += 1;
                }
                TokenKind::Punctuation(Punctuation::BracketClose | Punctuation::ParenClose) => {
                    if depth == 0 {
                        return false;
                    }

                    depth -= 1;
                }
                TokenKind::BlockStart if depth == 0 => return !self.at_rule(position),
                TokenKind::BlockEnd | TokenKind::Punctuation(Punctuation::Semicolon)
                    if depth == 0 =>
                {
                    return false;
                }
                _ => (),
            }

            scan += 1;
        }

        false
    }

    fn at_rule(&self, position: u32) -> bool {
        let mut scan = position;

        while scan > 0 {
            let kind = self.tokens[scan as usize - 1].kind;

            if matches!(
                kind,
                TokenKind::BlockEnd
                    | TokenKind::BlockStart
                    | TokenKind::Punctuation(Punctuation::Semicolon)
            ) {
                break;
            }

            scan -= 1;
        }

        while scan < position {
            let token = self.tokens[scan as usize];

            if token.kind != TokenKind::Newline && token.length > 0 {
                return self.word_is(scan, &[b"@"]);
            }

            scan += 1;
        }

        false
    }

    fn spaced(&self, position: u32) -> bool {
        if self
            .previous
            .is_some_and(|held| self.emptied(position, held) == Some(false))
        {
            return false;
        }

        let held = self.decided(position);

        if !held && !self.glued && self.joins(position) {
            return true;
        }

        held
    }

    fn module_star(&self, position: u32, previous: u32) -> bool {
        if !self.policy.chain_simples {
            return false;
        }

        let held = self.tokens[previous as usize].text(self.source);

        if held == b"*" {
            return self.module_word(previous);
        }

        self.tokens[position as usize].text(self.source) == b"*" && self.module_word(position)
    }

    fn module_word(&self, star: u32) -> bool {
        let mut scan = star;

        for _ in 0..MODULE_STAR_MAX {
            let Some(held) = self.back_of(scan) else {
                return false;
            };

            let token = self.tokens[held as usize];
            let text = token.text(self.source);

            if matches!(text, b"export" | b"import") {
                return true;
            }

            if token.kind != TokenKind::Identifier
                && token.kind != TokenKind::Punctuation(Punctuation::Comma)
            {
                return false;
            }

            scan = held;
        }

        false
    }

    fn generator_star(&self, previous: u32) -> bool {
        if !self.policy.chain_simples || self.tokens[previous as usize].text(self.source) != b"*" {
            return false;
        }

        let Some(before) = self.back_of(previous) else {
            return false;
        };

        if self.module_word(previous) {
            return false;
        }

        matches!(
            self.tokens[before as usize].kind,
            TokenKind::BlockStart
                | TokenKind::BlockEnd
                | TokenKind::Punctuation(Punctuation::Comma | Punctuation::Semicolon)
        ) || matches!(
            self.tokens[before as usize].text(self.source),
            b"async" | b"get" | b"set" | b"static"
        )
    }

    fn joins(&self, position: u32) -> bool {
        let Some(previous) = self.previous else {
            return false;
        };

        let held = self.tokens[previous as usize];
        let token = self.tokens[position as usize];

        if matches!(
            token.kind,
            TokenKind::Punctuation(Punctuation::Comma | Punctuation::Semicolon)
        ) {
            return false;
        }

        if self.angle_tight(position, previous) {
            return false;
        }

        if self.policy.chain_simples
            && matches!(
                token.kind,
                TokenKind::Punctuation(Punctuation::BracketClose | Punctuation::ParenClose)
            )
        {
            return false;
        }

        let settled = self.policy.brace_parts || self.spreads() || self.tested_joined(position);

        if settled && (is_close(token.kind) || is_open(held.kind)) {
            return false;
        }

        if self.policy.sole_hugs && (is_close(token.kind) || is_open(held.kind)) {
            return false;
        }

        if self.policy.close_hugs
            && matches!(
                held.kind,
                TokenKind::BlockEnd | TokenKind::Punctuation(Punctuation::BracketClose)
            )
            && (is_close(token.kind) || is_open(token.kind) && !self.bodied(position))
        {
            return false;
        }

        if self.welded(position, previous) && self.joins_a_break(position, previous)
            || self.arm_emptied(position, previous)
            || self.joined_dot(position, previous)
        {
            return false;
        }

        punctuated(held.kind) && punctuated(token.kind) && held.end() < token.offset
    }

    fn roled_pair(&self, position: u32, previous: u32) -> Option<bool> {
        if self.roled(position, ROLE_TIGHT) || self.roled(previous, ROLE_TIGHT) {
            return Some(false);
        }

        if self.roled(position, ROLE_SPACED) || self.roled(previous, ROLE_SPACED) {
            if self.roled(position, ROLE_SPACED)
                && self.roled(previous, ROLE_SPACED)
                && self.tokens[previous as usize].end() == self.tokens[position as usize].offset
            {
                return Some(false);
            }

            return Some(true);
        }

        None
    }

    fn marked(&self, position: u32, previous: u32) -> Option<bool> {
        if self.ternaried(position, previous) || self.labelled(position, previous) {
            return Some(true);
        }

        if previous > 0 && self.labelled(previous, previous - 1) {
            return Some(false);
        }

        if previous > 1 && self.labelled(previous - 1, previous - 2) {
            let kind = self.tokens[position as usize].kind;

            return Some(
                !is_close(kind)
                    && !matches!(
                        kind,
                        TokenKind::Punctuation(
                            Punctuation::Comma | Punctuation::Semicolon | Punctuation::Colon
                        )
                    ),
            );
        }

        None
    }

    fn dotted(&self, position: u32, previous: u32) -> bool {
        if self.tokens[previous as usize].kind == TokenKind::Number {
            return self.tokens[previous as usize].end() < self.tokens[position as usize].offset;
        }

        if self.tokens[previous as usize].kind == TokenKind::BlockEnd {
            return false;
        }

        if self.policy.hug_lasts
            && matches!(self.tokens[previous as usize].kind, TokenKind::Keyword(_))
        {
            return false;
        }

        !self.operand_at(previous)
            && !self.closes_a_value(previous)
            && !self.is_dot(previous)
            && !self.word_is(previous, self.policy.hug_words)
    }

    fn opens_inside(&self, kind: TokenKind, held: TokenKind, frame: Frame) -> bool {
        if self.policy.brace_pairs && kind == TokenKind::BlockStart {
            return false;
        }

        held == TokenKind::BlockStart && frame.inside && kind != TokenKind::BlockEnd
    }

    fn remarked_brace(&self, position: u32, previous: u32) -> bool {
        if !self.policy.brace_remarks || !self.frame().inside {
            return false;
        }

        let kind = self.tokens[position as usize].kind;
        let held = self.tokens[previous as usize].kind;

        kind == TokenKind::BlockEnd && self.blocked(previous)
            || held == TokenKind::BlockStart && self.blocked(position)
    }

    fn kept(&self, position: u32, previous: u32) -> Option<bool> {
        let kind = self.tokens[position as usize].kind;
        let gap = self.tokens[previous as usize].end() < self.tokens[position as usize].offset;

        if self.remarked_brace(position, previous) {
            return Some(true);
        }

        if self.policy.sentinel_colons
            && kind == TokenKind::Punctuation(Punctuation::Colon)
            && self.frame().kind == TokenKind::Punctuation(Punctuation::BracketOpen)
            && self.ranged(self.frame().open, position)
        {
            return Some(true);
        }

        if self.policy.lifetime_tight
            && self.tokens[position as usize].text(self.source) == b"'"
            && self.tokens[previous as usize].text(self.source) == b"&"
        {
            return Some(false);
        }

        if self.blocked(position) || self.blocked(previous) {
            if is_close(kind) {
                return Some(false);
            }

            return Some(gap);
        }

        if self.word_is(position, self.policy.tight_words)
            && matches!(self.tokens[previous as usize].kind, TokenKind::Keyword(_))
        {
            return Some(gap);
        }

        if is_open(self.tokens[previous as usize].kind) && kind == TokenKind::Comment {
            return Some(true);
        }

        if previous > 0
            && self.tokens[previous as usize].text(self.source) == b"#"
            && self.tokens[(previous - 1) as usize].kind == TokenKind::Identifier
            && self.tokens[(previous - 1) as usize].end() == self.tokens[previous as usize].offset
        {
            return Some(gap);
        }

        if kind == TokenKind::String && self.word_is(previous, self.policy.tight_words) {
            return Some(gap);
        }

        None
    }

    fn decided(&self, position: u32) -> bool {
        let Some(previous) = self.previous else {
            return false;
        };

        if self.generator_star(previous) {
            return false;
        }

        if self.module_star(position, previous) {
            return true;
        }

        if let Some(held) = self.sourced(position, previous) {
            return held;
        }

        if let Some(held) = self.kept(position, previous) {
            return held;
        }

        let opened = is_open(self.tokens[previous as usize].kind);

        if self.suppress_space || self.pointed(position) {
            return false;
        }

        if let Some(held) = self.roled_pair(position, previous) {
            return held;
        }

        let held = self.tokens[previous as usize].kind;
        let kind = self.tokens[position as usize].kind;
        let frame = self.frame();

        if opened {
            return self.opens_inside(kind, held, frame);
        }

        if self.word_is(position, self.policy.postfix_words)
            || self.word_is(position, self.policy.member_words)
            || self.word_is(previous, self.policy.member_words)
        {
            return false;
        }

        if let Some(decided) = self.worded(position, previous) {
            return decided;
        }

        if let Some(decided) = self.marked(position, previous) {
            return decided;
        }

        if self.is_dot(position) {
            return self.dotted(position, previous);
        }

        if kind == TokenKind::Punctuation(Punctuation::Semicolon)
            && matches!(held, TokenKind::Keyword(_))
        {
            return self.tokens[previous as usize].end() < self.tokens[position as usize].offset;
        }

        if kind == TokenKind::Punctuation(Punctuation::Semicolon)
            && held == TokenKind::Punctuation(Punctuation::Semicolon)
        {
            return frame.kind != TokenKind::Punctuation(Punctuation::ParenOpen);
        }

        if matches!(
            kind,
            TokenKind::Punctuation(
                Punctuation::Comma | Punctuation::Semicolon | Punctuation::Colon
            )
        ) || self.is_dot(previous) && !self.spaced_dot(position, previous)
        {
            return false;
        }

        if let Some(decided) = self.braced(position, previous, frame) {
            return decided;
        }

        if matches!(
            kind,
            TokenKind::Punctuation(Punctuation::BracketOpen | Punctuation::ParenOpen)
        ) {
            return self.bracketed(position, previous);
        }

        if self.policy.chain_simples
            && matches!(
                kind,
                TokenKind::Punctuation(Punctuation::BracketClose | Punctuation::ParenClose)
            )
        {
            return false;
        }

        if self.arrow(position) && self.word_is(previous, self.policy.hug_words) {
            return false;
        }

        true
    }

    fn sourced(&self, position: u32, previous: u32) -> Option<bool> {
        if self.policy.brace_leads && self.tokens[position as usize].kind == TokenKind::BlockStart {
            return Some(true);
        }

        if let Some(held) = self.paired(position, previous) {
            return Some(held);
        }

        if self.policy.units
            && self.tokens[position as usize].kind != TokenKind::Punctuation(Punctuation::Bang)
            && !self.word_is(position, self.policy.spaced_words)
            && self.tokens[previous as usize].kind == TokenKind::Number
            && self.tokens[previous as usize].end() == self.tokens[position as usize].offset
        {
            return Some(false);
        }

        if self.policy.remark_leads && self.columned(position, previous) {
            return Some(false);
        }

        if self.policy.remark_gaps
            && self.tokens[previous as usize].kind == TokenKind::Comment
            && self.tokens[previous as usize]
                .text(self.source)
                .starts_with(b"/*")
        {
            let opened = self.back_of(previous).is_some_and(|held| {
                let kind = self.tokens[held as usize].kind;

                is_open(kind) || kind == TokenKind::BlockStart
            });

            let kind = self.tokens[position as usize].kind;

            if matches!(
                kind,
                TokenKind::Punctuation(Punctuation::Comma | Punctuation::Semicolon)
            ) {
                return Some(false);
            }

            let body = kind == TokenKind::BlockEnd && self.bodied(self.frame().open);

            return Some(!is_close(kind) || opened || body);
        }

        if self.policy.source_gaps {
            if self.tokens[position as usize].kind == TokenKind::Comment {
                return Some(true);
            }

            if self.tokens[previous as usize].kind == TokenKind::Comment {
                let kind = self.tokens[position as usize].kind;

                return Some(
                    !is_close(kind)
                        && !matches!(
                            kind,
                            TokenKind::Punctuation(Punctuation::Comma | Punctuation::Semicolon)
                        ),
                );
            }

            return self.gapped(position, previous);
        }

        None
    }

    fn verbatim(&self) -> bool {
        if self.policy.verbatim_words.is_empty() {
            return false;
        }

        for held in 0..self.depth {
            let frame = self.nest[held as usize];

            if frame.kind != TokenKind::Punctuation(Punctuation::ParenOpen) {
                continue;
            }

            if self
                .back_of(frame.open)
                .is_some_and(|word| self.word_is(word, self.policy.verbatim_words))
            {
                return true;
            }
        }

        false
    }

    fn braced(&self, position: u32, previous: u32, frame: Frame) -> Option<bool> {
        let held = self.tokens[previous as usize].kind;
        let kind = self.tokens[position as usize].kind;

        if kind == TokenKind::BlockEnd {
            return Some(frame.inside && held != TokenKind::BlockStart);
        }

        if is_close(kind) {
            return Some(false);
        }

        if kind == TokenKind::BlockStart {
            return Some(!self.hugged(position, previous));
        }

        None
    }

    fn closes_a_value(&self, position: u32) -> bool {
        self.structured
            && self.tokens[position as usize].kind == TokenKind::BlockEnd
            && self.closed.kind == TokenKind::BlockStart
            && !self.bodied(self.closed.open)
    }

    fn labelled(&self, position: u32, previous: u32) -> bool {
        self.tokens[position as usize].kind == TokenKind::Punctuation(Punctuation::Colon)
            && self.word_is(previous, self.policy.label_words)
    }

    fn queries(&self, colon: u32) -> bool {
        if self.depth == 0 || self.frame().kind != TokenKind::Punctuation(Punctuation::ParenOpen) {
            return false;
        }

        let open = self.frame().open;

        let held = self.word_before(open).is_none_or(|before| {
            self.tokens[before as usize].end() < self.tokens[open as usize].offset
        });

        held && self.at_rule(colon)
    }

    fn valued(&self, colon: u32) -> bool {
        let mut depth = 0;
        let mut scan = colon + 1;

        while scan < self.count {
            match self.tokens[scan as usize].kind {
                TokenKind::Punctuation(Punctuation::BracketOpen | Punctuation::ParenOpen) => {
                    depth += 1;
                }
                TokenKind::Punctuation(Punctuation::BracketClose | Punctuation::ParenClose) => {
                    if depth == 0 {
                        return false;
                    }

                    depth -= 1;
                }
                TokenKind::BlockStart if depth == 0 => return false,
                TokenKind::BlockEnd | TokenKind::Punctuation(Punctuation::Semicolon)
                    if depth == 0 =>
                {
                    return true;
                }
                _ => (),
            }

            scan += 1;
        }

        false
    }

    fn declares(&self, colon: u32) -> bool {
        if self.depth == 0 || colon < 2 || !self.valued(colon) {
            return false;
        }

        if self.tokens[(colon - 1) as usize].kind != TokenKind::Identifier {
            return false;
        }

        let mut scan = colon - 1;

        while scan > 0 && self.word_is(scan - 1, self.policy.prefix_words) {
            scan -= 1;
        }

        let Some(before) = self.word_before(scan).and_then(|held| self.coded_at(held)) else {
            return false;
        };

        matches!(
            self.tokens[before as usize].kind,
            TokenKind::BlockEnd
                | TokenKind::BlockStart
                | TokenKind::Punctuation(Punctuation::Semicolon)
        )
    }

    fn coded_at(&self, position: u32) -> Option<u32> {
        let mut held = position;

        while self.tokens[held as usize].kind == TokenKind::Comment {
            held = self.word_before(held)?;
        }

        Some(held)
    }

    fn gapped(&self, position: u32, previous: u32) -> Option<bool> {
        let held = self.tokens[previous as usize].kind;
        let kind = self.tokens[position as usize].kind;

        if matches!(kind, TokenKind::BlockStart | TokenKind::BlockEnd)
            || matches!(held, TokenKind::BlockStart | TokenKind::BlockEnd)
        {
            return None;
        }

        if is_open(held) || is_close(kind) {
            return Some(false);
        }

        let colon = TokenKind::Punctuation(Punctuation::Colon);
        let gap = self.tokens[previous as usize].end() < self.tokens[position as usize].offset;

        if kind == TokenKind::Punctuation(Punctuation::Bang) {
            return Some(true);
        }

        if held == TokenKind::Punctuation(Punctuation::Bang) {
            return Some(false);
        }

        if (self.word_is(position, self.policy.spaced_words)
            || self.word_is(previous, self.policy.spaced_words))
            && !self.verbatim()
        {
            return Some(true);
        }

        if kind == colon {
            return Some(!self.declares(position) && gap);
        }

        if held == colon {
            let parted = self.declares(previous) || self.queries(previous);

            return Some(if parted { true } else { gap });
        }

        if matches!(
            kind,
            TokenKind::Punctuation(Punctuation::Comma | Punctuation::Semicolon)
        ) {
            return Some(false);
        }

        if matches!(
            held,
            TokenKind::Punctuation(Punctuation::Comma | Punctuation::Semicolon)
        ) {
            return Some(true);
        }

        Some(self.tokens[previous as usize].end() < self.tokens[position as usize].offset)
    }

    fn paired(&self, position: u32, previous: u32) -> Option<bool> {
        let gap = self.tokens[previous as usize].end() < self.tokens[position as usize].offset;

        if self.ellipsis(position) {
            return Some(!self.starting && gap);
        }

        if self.ranges(previous) || self.ranges(position) {
            return Some(gap);
        }

        if previous > 0 && self.doubled(previous - 1) && self.is_dot(previous) {
            return Some(gap);
        }

        None
    }

    fn worded(&self, position: u32, previous: u32) -> Option<bool> {
        let held = self.tokens[previous as usize].kind;
        let gap = self.tokens[previous as usize].end() < self.tokens[position as usize].offset;

        if self.word_is(position, self.policy.tight_words)
            || self.word_is(previous, self.policy.tight_words)
        {
            return Some(false);
        }

        if self.doubled(previous) && previous + 1 == position {
            return Some(false);
        }

        if previous > 0
            && self.doubled(previous - 1)
            && held == TokenKind::Punctuation(Punctuation::Colon)
        {
            return Some(false);
        }

        if self.word_is(position, self.policy.source_words)
            || self.word_is(previous, self.policy.source_words)
        {
            return Some(gap);
        }

        let braced = self.policy.brace_parts
            && (matches!(held, TokenKind::BlockEnd | TokenKind::BlockStart)
                || matches!(
                    self.tokens[position as usize].kind,
                    TokenKind::BlockEnd | TokenKind::BlockStart
                ));

        let grouped = self.word_is(previous, self.policy.group_words)
            && self
                .back_of(previous)
                .is_some_and(|at| ends_operand(self.tokens[at as usize].kind));

        if grouped
            && matches!(
                self.tokens[position as usize].kind,
                TokenKind::Punctuation(Punctuation::ParenOpen | Punctuation::BracketOpen)
            )
        {
            return Some(true);
        }

        if self.angle_tight(position, previous) {
            return Some(false);
        }

        let parted = matches!(
            held,
            TokenKind::Punctuation(Punctuation::Colon | Punctuation::Comma)
        ) || self.tokens[previous as usize].text(self.source) == b"return";

        let angled = matches!(
            self.tokens[position as usize].text(self.source),
            b"<" | b">"
        );

        if (self.word_is(position, self.policy.tight_from_source)
            || self.word_is(previous, self.policy.tight_from_source))
            && !gap
            && !braced
            && !(self.policy.chain_simples && parted && !angled)
        {
            return Some(false);
        }

        None
    }

    fn bracketed(&self, position: u32, previous: u32) -> bool {
        let held = self.tokens[previous as usize].kind;

        if self.word_is(previous, self.policy.signature_words) {
            if self.roled(previous, ROLE_LAMBDA) {
                return false;
            }

            if previous == self.line_first && self.depth == 0 {
                return true;
            }
        }

        if self.policy.bracket_types
            && matches!(
                self.tokens[position as usize].kind,
                TokenKind::Punctuation(Punctuation::BracketOpen | Punctuation::ParenOpen)
            )
            && self.roled(position, ROLE_START)
            && (self.operand_at(previous) || self.word_is(previous, self.policy.hug_words))
        {
            return true;
        }

        if self.empties(position) && !self.word_is(previous, self.policy.hug_words) {
            return true;
        }

        if self.word_is(previous, self.policy.hug_words)
            || self.tokens[previous as usize]
                .text(self.source)
                .starts_with(b"@")
        {
            return false;
        }

        if self.prefixed(previous) {
            return self.tokens[previous as usize].end() < self.tokens[position as usize].offset;
        }

        let hugs = !self.policy.keyword_gaps || self.word_is(previous, self.policy.signature_words);

        if matches!(held, TokenKind::Keyword(_))
            && hugs
            && self.tokens[previous as usize].end() == self.tokens[position as usize].offset
        {
            return false;
        }

        if held == TokenKind::BlockEnd {
            return false;
        }

        if held == TokenKind::Punctuation(Punctuation::ParenClose)
            && self.word_is(self.line_first, self.policy.signature_words)
            && self.signing(previous)
        {
            return true;
        }

        if self.policy.convention_strings
            && held == TokenKind::String
            && self.tokens[position as usize].kind == TokenKind::Punctuation(Punctuation::ParenOpen)
        {
            return true;
        }

        if self.policy.hug_lasts
            && ACCESSOR_WORDS.contains(&self.tokens[previous as usize].text(self.source))
            && self.tokens[position as usize].kind
                == TokenKind::Punctuation(Punctuation::BracketOpen)
            && self.closing_of(position).is_some_and(|close| {
                self.next_of(close).is_some_and(|after| {
                    self.tokens[after as usize].kind
                        == TokenKind::Punctuation(Punctuation::ParenOpen)
                })
            })
        {
            return true;
        }

        !self.operand_at(previous)
    }

    fn signing(&self, previous: u32) -> bool {
        for scan in self.line_first..previous {
            if self.tokens[scan as usize].kind == TokenKind::BlockStart {
                return false;
            }
        }

        true
    }

    pub(super) fn roled(&self, position: u32, role: u8) -> bool {
        self.roles
            .get(position as usize)
            .is_some_and(|held| held & role != 0)
    }

    fn bodied(&self, position: u32) -> bool {
        self.roled(position, ROLE_BLOCK)
    }

    fn parts_role(&self, position: u32, previous: u32) -> bool {
        if self.tokens[position as usize].kind == TokenKind::Comment
            && !self.parts_at(previous, position)
        {
            return false;
        }

        if self.roled(previous, ROLE_PART) {
            return true;
        }

        self.depth > 0
            && self.nest[self.depth as usize - 1].close == position
            && self.roled(self.nest[self.depth as usize - 1].open, ROLE_PART)
    }

    fn hugged(&self, position: u32, previous: u32) -> bool {
        if self.bodied(position) {
            return false;
        }

        let held = if self.policy.hug_braces {
            self.inline(position)
        } else {
            self.tokens[previous as usize].end() == self.tokens[position as usize].offset
        };

        if self.word_is(previous, self.policy.hug_words) && held {
            return true;
        }

        if self.opens_a_block(position) || self.word_is(self.line_first, self.policy.block_words) {
            return false;
        }

        let spans = self.policy.brace_spans || self.inline(position);

        if spans && self.pathed(previous) {
            return true;
        }

        spans
            && self.policy.brace_hugs
            && (self.operand_at(previous) || self.closes_a_value(previous))
            || self.inline(position) && self.word_is(previous, self.policy.tight_words)
    }

    fn opens_a_block(&self, position: u32) -> bool {
        if self.structured {
            return false;
        }

        self.next_of(position).is_some_and(|held| {
            matches!(self.tokens[held as usize].kind, TokenKind::Keyword(_))
                && !self.word_is(held, self.policy.operand_words)
        })
    }

    pub(super) fn ranges(&self, position: u32) -> bool {
        let token = self.tokens[position as usize];
        let text = token.text(self.source);

        token.kind == TokenKind::Punctuation(Punctuation::Dot)
            && token.length > 1
            && text.starts_with(b".")
            && !text.iter().any(u8::is_ascii_digit)
    }

    fn spaced_dot(&self, position: u32, previous: u32) -> bool {
        if !self.is_dot(previous) {
            return false;
        }

        if self.tokens[position as usize].kind == TokenKind::String {
            return true;
        }

        let held = self.tokens[previous as usize];
        let token = self.tokens[position as usize];

        held.end() < token.offset
            && self
                .source
                .get(token.offset as usize)
                .is_some_and(u8::is_ascii_digit)
    }

    pub(super) fn is_dot(&self, position: u32) -> bool {
        self.tokens[position as usize].kind == TokenKind::Punctuation(Punctuation::Dot)
            && self.tokens[position as usize].length == 1
    }

    pub(super) fn operand_at(&self, position: u32) -> bool {
        ends_operand(self.tokens[position as usize].kind)
            || self.word_is(position, self.policy.operand_words)
    }

    fn pathed(&self, position: u32) -> bool {
        self.tokens[position as usize].kind == TokenKind::Punctuation(Punctuation::Colon)
            && position > 0
            && self.doubled(position - 1)
    }

    fn doubled(&self, position: u32) -> bool {
        let count = self.count;

        if position + 1 >= count {
            return false;
        }

        let held = self.tokens[position as usize];
        let next = self.tokens[(position + 1) as usize];

        if held.end() != next.offset || held.length != next.length {
            return false;
        }

        held.text(self.source) == next.text(self.source)
    }

    fn prefixed(&self, position: u32) -> bool {
        if position == 0 {
            return false;
        }

        let held = position - 1;

        self.word_is(held, self.policy.prefix_words)
            && self.tokens[held as usize].end() == self.tokens[position as usize].offset
    }

    fn pointed(&self, position: u32) -> bool {
        self.pointing(position) || position > 0 && self.pointing(position - 1)
    }

    fn pointing(&self, position: u32) -> bool {
        if self.policy.arrow_after.is_empty() || position == 0 || position + 1 >= self.count {
            return false;
        }

        let held = self.tokens[position as usize];
        let next = self.tokens[(position + 1) as usize];

        held.length == 1
            && next.length == 1
            && held.end() == next.offset
            && self.source[held.offset as usize] == b'-'
            && self.source[next.offset as usize] == b'>'
            && self.word_is(position - 1, self.policy.arrow_after)
    }

    fn arrow(&self, position: u32) -> bool {
        let token = self.tokens[position as usize];

        token.length == 2 && token.text(self.source) == b"<-"
    }

    fn ellipsis(&self, position: u32) -> bool {
        let count = self.count;

        if position + 2 >= count {
            return false;
        }

        (0..3).all(|held| {
            let token = self.tokens[(position + held) as usize];

            token.length == 1 && self.source[token.offset as usize] == b'.'
        })
    }

    fn written(&self, position: u32) -> Span {
        let token = self.tokens[position as usize];
        let span = token.span();

        if token.kind != TokenKind::Comment || self.documenting(position) {
            return span;
        }

        let text = token.text(self.source);
        let held = text.trim_ascii_end();

        Span {
            length: count_of(held.len()),
            offset: span.offset,
        }
    }

    fn documenting(&self, position: u32) -> bool {
        if !REMARK_TAILS || !self.policy.remark_tails {
            return false;
        }

        let text = self.tokens[position as usize].text(self.source);

        if let Some(rest) = text.strip_prefix(b"///") {
            return !rest.starts_with(b"/");
        }

        text.starts_with(b"//!")
    }

    fn blocked(&self, position: u32) -> bool {
        self.tokens[position as usize].kind == TokenKind::Comment
            && self.tokens[position as usize]
                .text(self.source)
                .starts_with(b"/*")
    }

    fn labels(&self, position: u32) -> bool {
        if !self.policy.label_lines {
            return false;
        }

        if self.tokens[position as usize].kind != TokenKind::Identifier {
            return false;
        }

        if self.keying() || self.typed_frame() {
            return false;
        }

        let Some(colon) = self.next_of(position) else {
            return false;
        };

        if self.tokens[colon as usize].kind != TokenKind::Punctuation(Punctuation::Colon) {
            return false;
        }

        if self.roled(colon, ROLE_PART) {
            return true;
        }

        let mut scan = self.next_of(colon);

        while scan.is_some_and(|held| self.tokens[held as usize].kind == TokenKind::Comment) {
            scan = self.next_of(scan.unwrap_or_default());
        }

        let Some(after) = scan else {
            return true;
        };

        self.parted_by(
            self.tokens[colon as usize].end(),
            self.tokens[after as usize].offset,
        ) > 0
    }

    fn empties(&self, position: u32) -> bool {
        if !self.policy.bracket_types {
            return false;
        }

        if self.tokens[position as usize].kind != TokenKind::Punctuation(Punctuation::BracketOpen) {
            return false;
        }

        self.next_of(position).is_some_and(|held| {
            self.tokens[held as usize].kind == TokenKind::Punctuation(Punctuation::BracketClose)
        })
    }

    fn types_at(&self, position: u32) -> bool {
        self.policy.bracket_types
            && self.tokens[position as usize].kind
                == TokenKind::Punctuation(Punctuation::BracketClose)
            && !self.closed.index
    }

    pub(super) fn back_of(&self, position: u32) -> Option<u32> {
        let mut scan = position;

        while scan > 0 {
            scan -= 1;

            let token = self.tokens[scan as usize];

            if token.kind != TokenKind::Newline && token.length > 0 {
                return Some(scan);
            }
        }

        None
    }

    pub(super) fn next_of(&self, position: u32) -> Option<u32> {
        let count = self.count;
        let mut scan = position + 1;

        while scan < count {
            let token = self.tokens[scan as usize];

            if token.kind != TokenKind::Newline && token.length > 0 {
                return Some(scan);
            }

            scan += 1;
        }

        None
    }

    fn suppresses(&self, position: u32) -> bool {
        let token = self.tokens[position as usize];
        let frame = self.frame();

        if self.roled(position, ROLE_TIGHT) {
            return true;
        }

        if self.roled(position, ROLE_SPACED) {
            return false;
        }

        if self.pointed(position) {
            return true;
        }

        if self.is_dot(position) {
            if self
                .next_of(position)
                .is_some_and(|held| self.spaced_dot(held, position))
            {
                return false;
            }

            return !self.doubled(position) && (position == 0 || !self.doubled(position - 1));
        }

        if is_open(token.kind) {
            return token.kind != TokenKind::BlockStart || !frame.inside;
        }

        if token.kind == TokenKind::Punctuation(Punctuation::BracketClose) {
            return self.policy.bracket_types && !self.closed.index;
        }

        if token.kind == TokenKind::Punctuation(Punctuation::ParenClose) {
            return self.closed.casts;
        }

        if self.ellipsis(position) || self.word_is(position, self.policy.tight_words) {
            return true;
        }

        if self.word_is(position, self.policy.prefix_words) {
            return self.adjacent(position);
        }

        if self.arrow(position) {
            if self
                .previous
                .is_some_and(|held| self.word_is(held, self.policy.hug_words))
            {
                return false;
            }

            return self.starting
                || self
                    .previous
                    .is_none_or(|held| !ends_operand(self.tokens[held as usize].kind))
                || self.follows_a_hug_word(position) && self.adjacent(position);
        }

        if self.word_is(position, self.policy.source_words) {
            return false;
        }

        if token.kind == TokenKind::Punctuation(Punctuation::Colon) {
            return self.policy.slice_colons
                && frame.kind == TokenKind::Punctuation(Punctuation::BracketOpen);
        }

        if !matches!(token.kind, TokenKind::Punctuation(_)) {
            return false;
        }

        if !self.word_is(position, self.policy.unary_words) {
            return false;
        }

        if !self.adjacent(position) {
            return false;
        }

        self.starting
            || self.roled(position, ROLE_START)
            || self.previous.is_none_or(|held| {
                !ends_operand(self.tokens[held as usize].kind) || self.types_at(held)
            })
    }

    fn adjacent(&self, position: u32) -> bool {
        self.next_of(position).is_none_or(|held| {
            self.tokens[position as usize].end() == self.tokens[held as usize].offset
        })
    }

    fn follows_a_hug_word(&self, position: u32) -> bool {
        self.next_of(position)
            .is_some_and(|held| self.word_is(held, self.policy.hug_words))
    }

    fn macro_body(&self, position: u32) -> Option<u32> {
        if !self.policy.macro_spans {
            return None;
        }

        let opened = self.tokens[position as usize].kind;

        if opened != TokenKind::BlockStart && !is_open(opened) {
            return None;
        }

        if opened == TokenKind::Punctuation(Punctuation::ParenOpen) && self.defined_branch(position)
        {
            return self.closing_of(position);
        }

        let previous = self.previous?;

        if self.tokens[previous as usize].kind == TokenKind::Identifier {
            if !self.defining(previous) {
                return None;
            }

            if self.policy.macro_defines && opened != TokenKind::BlockStart {
                return self.closing_of(position);
            }

            if self.policy.macro_bodies && self.branched_def(position) {
                return None;
            }

            return self.closing(position);
        }

        if self.matcher_body(position, previous) {
            let close = self.closing_of(position)?;
            let held = self.streamed(position, close) || self.unparsed(position, close);

            return held.then_some(close);
        }

        if self.tokens[previous as usize].kind != TokenKind::Punctuation(Punctuation::Bang) {
            return None;
        }

        let named = self.word_before(previous)?;
        let kind = self.tokens[named as usize].kind;

        let kinded = if MACRO_NAMES {
            matches!(kind, TokenKind::Identifier | TokenKind::Keyword(_))
        } else {
            kind == TokenKind::Identifier
        };

        if !kinded {
            return None;
        }

        if opened == TokenKind::BlockStart {
            return self.closing(position);
        }

        let close = self.closing_of(position)?;

        self.streamed(position, close).then_some(close)
    }

    fn branched_def(&self, brace: u32) -> bool {
        let Some(close) = self.closing_of(brace) else {
            return false;
        };

        let mut scan = brace + 1;
        let mut branched = false;

        for _ in 0..MACRO_BRANCH_MAX {
            if scan >= close {
                return branched;
            }

            if self.tokens[scan as usize].kind != TokenKind::Punctuation(Punctuation::ParenOpen) {
                return false;
            }

            let Some(matcher) = self.closing_of(scan) else {
                return false;
            };

            let Some(arrow) = self
                .next_of(matcher)
                .filter(|held| self.tokens[*held as usize].text(self.source) == b"=>")
            else {
                return false;
            };

            let Some(body) = self
                .next_of(arrow)
                .filter(|held| self.tokens[*held as usize].kind == TokenKind::BlockStart)
            else {
                return false;
            };

            let Some(end) = self.closing_of(body) else {
                return false;
            };

            if self.unparsed(body, end)
                || self.overrun(body, end)
                || wide::MACRO_STREAMS && self.defined_stream(body, end)
            {
                return false;
            }

            branched = true;
            scan = match self.next_of(end) {
                Some(held)
                    if self.tokens[held as usize].kind
                        == TokenKind::Punctuation(Punctuation::Semicolon) =>
                {
                    held + 1
                }
                _ => end + 1,
            };
        }

        false
    }

    fn overrun(&self, open: u32, close: u32) -> bool {
        let mut scan = open + 1;

        while scan < close {
            let token = self.tokens[scan as usize];

            scan += 1;

            if !matches!(token.kind, TokenKind::Comment | TokenKind::String) {
                continue;
            }

            let from = self.source[..token.offset as usize]
                .iter()
                .rposition(|byte| *byte == b'\n')
                .map_or(0, |held| held + 1);

            let to = match self.source[token.offset as usize..]
                .iter()
                .position(|byte| *byte == b'\n')
            {
                Some(held) => token.offset as usize + held,
                None => self.source.len(),
            };

            if columns(self.source, count_of(from), count_of(to)) > self.options.line_width {
                return true;
            }
        }

        false
    }

    fn unparsed(&self, open: u32, close: u32) -> bool {
        let mut scan = open + 1;

        while scan < close {
            let text = self.tokens[scan as usize].text(self.source);

            scan += 1;

            if text != b"$" && text != b"#" {
                continue;
            }

            let Some(next) = self.next_of(scan - 1) else {
                continue;
            };

            let kind = self.tokens[next as usize].kind;

            let repeated = kind == TokenKind::Punctuation(Punctuation::ParenOpen)
                || kind == TokenKind::BlockStart;

            if text == b"$" && repeated
                || text == b"#" && kind != TokenKind::Punctuation(Punctuation::BracketOpen)
            {
                return true;
            }
        }

        false
    }

    fn matcher_body(&self, position: u32, previous: u32) -> bool {
        if !self.policy.macro_defines
            || self.tokens[position as usize].kind != TokenKind::BlockStart
            || self.tokens[previous as usize].kind
                != TokenKind::Punctuation(Punctuation::ParenClose)
        {
            return false;
        }

        let Some(open) = reach::opened(self.source, self.tokens, previous) else {
            return false;
        };

        let Some(named) = self.word_before(open) else {
            return false;
        };

        if self.tokens[named as usize].kind != TokenKind::Identifier {
            return false;
        }

        self.word_before(named)
            .is_some_and(|held| self.tokens[held as usize].text(self.source) == b"macro")
    }

    fn attribute_span(&self, position: u32) -> Option<u32> {
        if !self.policy.attribute_spans || self.tokens[position as usize].text(self.source) != b"#"
        {
            return None;
        }

        let mut open = self.next_of(position)?;

        if self.tokens[open as usize].kind == TokenKind::Punctuation(Punctuation::Bang) {
            open = self.next_of(open)?;
        }

        if self.tokens[open as usize].kind != TokenKind::Punctuation(Punctuation::BracketOpen) {
            return None;
        }

        let close = self.closing_of(open)?;

        (!self.meta_item(open, close) || self.attribute_remarked(open, close)).then_some(close)
    }

    fn attribute_remarked(&self, open: u32, close: u32) -> bool {
        if !ATTRIBUTE_REMARKS
            || self
                .next_of(open)
                .is_some_and(|held| self.tokens[held as usize].text(self.source) == b"derive")
        {
            return false;
        }

        let mut scan = open + 1;

        while scan < close {
            if self.tokens[scan as usize].kind == TokenKind::Comment {
                return true;
            }

            scan += 1;
        }

        false
    }

    fn meta_item(&self, open: u32, close: u32) -> bool {
        let mut scan = open + 1;

        while scan < close {
            let token = self.tokens[scan as usize];
            let text = token.text(self.source);

            let held = matches!(
                token.kind,
                TokenKind::Identifier
                    | TokenKind::Keyword(_)
                    | TokenKind::Newline
                    | TokenKind::Number
                    | TokenKind::String
            ) || matches!(
                token.kind,
                TokenKind::Punctuation(
                    Punctuation::Assign
                        | Punctuation::Comma
                        | Punctuation::ParenClose
                        | Punctuation::ParenOpen
                )
            ) || text == b"::";

            if !held {
                return false;
            }

            if token.kind == TokenKind::Punctuation(Punctuation::Assign) {
                let Some(value) = self.next_of(scan) else {
                    return false;
                };

                let literal = matches!(
                    self.tokens[value as usize].kind,
                    TokenKind::Number | TokenKind::String
                ) || matches!(
                    self.tokens[value as usize].text(self.source),
                    b"true" | b"false"
                );

                if !literal {
                    return false;
                }

                let ends = self.next_of(value).is_none_or(|found| {
                    found == close
                        || matches!(
                            self.tokens[found as usize].kind,
                            TokenKind::Punctuation(Punctuation::Comma | Punctuation::ParenClose)
                        )
                });

                if !ends {
                    return false;
                }
            }

            scan += 1;
        }

        true
    }

    fn giving(&self, position: u32) -> Option<u32> {
        if !self.line_start || self.gives.binary_search(&position).is_err() {
            return None;
        }

        self.skipped_item(position.saturating_sub(1))
            .filter(|close| *close >= position)
    }

    fn skipping(&self, position: u32) -> Option<u32> {
        let words = self.policy.skip_words;

        if words.is_empty() || self.tokens[position as usize].text(self.source) != b"#" {
            return None;
        }

        let mut scan = self.next_of(position)?;

        if self.tokens[scan as usize].kind != TokenKind::Punctuation(Punctuation::BracketOpen) {
            return None;
        }

        for word in words {
            scan = self.next_of(scan)?;

            if self.tokens[scan as usize].text(self.source) != *word {
                return None;
            }
        }

        scan = self.next_of(scan)?;

        if self.tokens[scan as usize].kind != TokenKind::Punctuation(Punctuation::BracketClose) {
            return None;
        }

        self.skipped_item(scan)
    }

    fn skipped_item(&self, position: u32) -> Option<u32> {
        let mut braces = 0_u32;
        let mut brackets = 0_u32;
        let mut scan = position + 1;

        while scan < self.count {
            let kind = self.tokens[scan as usize].kind;

            if kind == TokenKind::BlockStart {
                braces += 1;
            } else if is_open(kind) {
                brackets += 1;
            } else if kind == TokenKind::BlockEnd {
                if braces == 0 {
                    return Some(scan.saturating_sub(1));
                }

                braces -= 1;

                if braces == 0 && brackets == 0 && !self.carried(scan) {
                    return Some(self.ended_item(scan));
                }
            } else if is_close(kind) {
                brackets = brackets.checked_sub(1)?;
            } else if braces == 0
                && brackets == 0
                && kind == TokenKind::Punctuation(Punctuation::Semicolon)
            {
                return Some(scan);
            }

            scan += 1;
        }

        None
    }

    fn carried(&self, position: u32) -> bool {
        let Some(next) = self.next_of(position) else {
            return false;
        };

        let text = self.tokens[next as usize].text(self.source);

        text == b"else"
            || text == b"."
            || text == b"?"
            || self.policy.continue_words.contains(&text)
    }

    fn ended_item(&self, position: u32) -> u32 {
        match self.next_of(position) {
            Some(held)
                if self.tokens[held as usize].kind
                    == TokenKind::Punctuation(Punctuation::Semicolon) =>
            {
                held
            }
            _ => position,
        }
    }

    fn defined_brace(&self, open: u32) -> bool {
        if self.tokens[open as usize].kind != TokenKind::BlockStart {
            return false;
        }

        let Some(name) = self
            .back_of(open)
            .filter(|held| self.tokens[*held as usize].kind == TokenKind::Identifier)
        else {
            return false;
        };

        let held = match self.back_of(name) {
            Some(found) if self.tokens[found as usize].text(self.source) == b"$" => found,
            _ => name,
        };

        self.defining(held)
    }

    pub(super) fn defined_body(&self, open: u32) -> Option<u32> {
        if !self.policy.macro_bodies
            || self.tokens[open as usize].kind != TokenKind::BlockStart
            || !self.defined_branch(open)
            || self
                .back_of(open)
                .is_none_or(|held| self.tokens[held as usize].text(self.source) != b"=>")
        {
            return None;
        }

        let close = self.closing_of(open)?;
        let first = self.next_of(open).filter(|held| *held < close)?;

        (self.tokens[first as usize].kind != TokenKind::BlockStart).then_some(open)
    }

    pub(super) fn defined_branch(&self, open: u32) -> bool {
        if !self.policy.macro_bodies {
            return false;
        }

        (0..self.depth)
            .rev()
            .map(|level| self.nest[level as usize])
            .find(|frame| frame.open < open)
            .is_some_and(|frame| self.defined_brace(frame.open))
    }

    fn branch_tailed(&self, position: u32) -> bool {
        if !BRANCH_TAILS || self.tokens[position as usize].kind != TokenKind::BlockEnd {
            return false;
        }

        let Some(open) = self.brackets.open_of(position) else {
            return false;
        };

        if !self.defined_brace(open) || !self.ruled(open) || !self.branch_fits(open, position) {
            return false;
        }

        self.back_of(position)
            .is_some_and(|held| self.tokens[held as usize].kind == TokenKind::BlockEnd)
    }

    fn branch_fits(&self, open: u32, close: u32) -> bool {
        let room = self
            .options
            .line_width
            .saturating_sub(self.indent_of(open) + 2 * self.options.indent_width);

        let mut start = self.tokens[open as usize].end() as usize;
        let stop = (self.tokens[close as usize].offset as usize).min(self.source.len());

        while start < stop {
            let end = self.source[start..stop]
                .iter()
                .position(|byte| *byte == b'\n')
                .map_or(stop, |at| start + at);

            let text = &self.source[start..end];

            let head = text
                .iter()
                .position(|byte| !matches!(*byte, b' ' | b'\t'))
                .map_or(&text[..0], |at| &text[at..]);

            if !head.starts_with(b"//")
                && columns(self.source, count_of(start), count_of(end)) > room
            {
                return false;
            }

            start = end + 1;
        }

        true
    }

    fn ruled(&self, open: u32) -> bool {
        let Some(name) = self.back_of(open) else {
            return false;
        };

        let held = match self.back_of(name) {
            Some(found) if self.tokens[found as usize].text(self.source) == b"$" => found,
            _ => name,
        };

        self.word_before(held).is_some_and(|bang| {
            self.tokens[bang as usize].kind == TokenKind::Punctuation(Punctuation::Bang)
        })
    }

    fn defining(&self, position: u32) -> bool {
        let Some(bang) = self.word_before(position) else {
            return false;
        };

        if self.policy.macro_defines && self.tokens[bang as usize].text(self.source) == b"macro" {
            return true;
        }

        if self.tokens[bang as usize].kind != TokenKind::Punctuation(Punctuation::Bang) {
            return false;
        }

        let Some(word) = self.word_before(bang) else {
            return false;
        };

        self.tokens[word as usize].text(self.source) == b"macro_rules"
    }

    fn word_before(&self, position: u32) -> Option<u32> {
        let mut scan = position;

        while scan > 0 {
            scan -= 1;

            let token = self.tokens[scan as usize];

            if token.kind != TokenKind::Newline && token.length > 0 {
                return Some(scan);
            }
        }

        None
    }

    fn opening_at(&self, position: u32) -> bool {
        let token = self.tokens[position as usize];

        token.kind == TokenKind::BlockStart || substituting(self.source, token)
    }

    fn closing(&self, position: u32) -> Option<u32> {
        if self.opening_at(position) {
            return self.brackets.close_of(position);
        }

        let block = self.brackets.block_after(position)?;

        if self.tokens[block as usize].kind == TokenKind::BlockEnd {
            return None;
        }

        self.brackets.close_of(block)
    }

    pub(super) fn spanned_unit(&self, position: u32) -> Option<u32> {
        self.template_body(position)
            .or_else(|| self.jsx_body(position))
    }

    fn templated_unit(&self, position: u32) -> Option<u32> {
        self.policy
            .template_units
            .then(|| self.template_body(position))
            .flatten()
    }

    pub(super) fn template_body(&self, position: u32) -> Option<u32> {
        let token = self.tokens[position as usize];

        if !self.policy.template_spans
            || token.kind != TokenKind::String
            || token.text(self.source) != b"`"
        {
            return None;
        }

        let mut depth = 0_u32;
        let mut scan = position + 1;

        while scan < self.count {
            let held = self.tokens[scan as usize];

            if held.kind == TokenKind::BlockStart || substituting(self.source, held) {
                depth += 1;
            } else if held.kind == TokenKind::BlockEnd {
                depth = depth.checked_sub(1)?;
            } else if depth == 0 && held.kind == TokenKind::String && held.text(self.source) == b"`"
            {
                return Some(scan);
            }

            scan += 1;
        }

        None
    }

    fn macro_bracket(&self, position: u32) -> bool {
        let kind = self.tokens[position as usize].kind;

        kind != TokenKind::BlockStart && is_open(kind)
    }

    fn restreamed(&mut self, position: u32, close: u32) -> bool {
        let source = self.source;

        let held = Span {
            length: self.tokens[close as usize].end() - self.tokens[position as usize].offset,
            offset: self.tokens[position as usize].offset,
        };

        let text = &source[held.range()];

        if self.options.tabs
            || !text.contains(&b'\t')
            || spilled(self.tokens, source, position, close)
        {
            return self.spanned(position, close);
        }

        self.previous = Some(close);
        self.resume = close + 1;
        self.suppress_space = false;

        let offset = self.arena.count();

        if !restreamed(self.arena, text, self.options.indent_width) {
            self.arena.truncate(offset);

            return false;
        }

        self.document.push(Element::VerbatimArena(Span {
            length: self.arena.count() - offset,
            offset,
        }))
    }

    fn spanned(&mut self, position: u32, close: u32) -> bool {
        let from = self.tokens[position as usize].offset;
        let to = self.tokens[close as usize].end();

        self.previous = Some(close);
        self.resume = close + 1;
        self.suppress_space = false;

        if GIVE_ORIGINS {
            if let Some(held) = self.origined(position, close) {
                return self.document.push(Element::VerbatimArena(held));
            }
        }

        self.document.push(Element::Verbatim(Span {
            length: to - from,
            offset: from,
        }))
    }

    fn origined(&mut self, position: u32, close: u32) -> Option<Span> {
        let from = self.origins.get(position as usize).copied()?;
        let held = self.origins.get(close as usize).copied()?;
        let to = held.checked_add(self.tokens[close as usize].length)?;

        if from == u32::MAX || held == u32::MAX || to as usize > self.origin.len() || to <= from {
            return None;
        }

        let offset = self.arena.count();

        if !self
            .arena
            .push_bytes(&self.origin[from as usize..to as usize])
        {
            self.arena.truncate(offset);

            return None;
        }

        Some(Span {
            length: self.arena.count() - offset,
            offset,
        })
    }

    pub(super) fn closing_of(&self, position: u32) -> Option<u32> {
        if is_open(self.tokens[position as usize].kind) {
            return self.brackets.close_of(position);
        }

        let open = self.tokens[position as usize].kind;
        let close = closed_by(open);
        let mut depth = 0_u32;
        let mut scan = position;

        while scan < self.count {
            let held = self.tokens[scan as usize];
            let kind = held.kind;

            let opens =
                kind == open || open == TokenKind::BlockStart && substituting(self.source, held);

            if opens {
                depth += 1;
            } else if kind == close {
                depth -= 1;

                if depth == 0 {
                    return Some(scan);
                }
            }

            scan += 1;
        }

        None
    }

    fn typing(&self, position: u32) -> bool {
        let mut scan = Some(position);

        while let Some(held) = scan {
            if self.word_is(held, self.policy.type_words) {
                return true;
            }

            if !self.word_is(held, self.policy.type_leads) {
                return false;
            }

            scan = self.next_of(held);
        }

        false
    }

    fn specified(&mut self, from: u32, to: u32) -> bool {
        let offset = self.arena.count();

        if !self.written_into(from, to) {
            return false;
        }

        self.document.push(Element::VerbatimArena(Span {
            length: self.arena.count() - offset,
            offset,
        }))
    }

    fn nested_into(&mut self, open: u32, close: u32) -> bool {
        let mut count = 0;
        let mut held = [(0_u32, 0_u32); LIST_ITEM_MAX as usize];
        let mut scan = open + 1;

        while scan < close {
            let stop = self.parted_at(scan, close);

            if scan < stop {
                if count == LIST_ITEM_MAX as usize {
                    return false;
                }

                held[count] = (scan, stop);
                count += 1;
            }

            scan = stop + 1;
        }

        let mut index = 1;

        while index < count {
            let mut back = index;

            while back > 0 && self.item_precedes(held[back], held[back - 1]) {
                held.swap(back, back - 1);

                back -= 1;
            }

            index += 1;
        }

        if !self.arena.push_bytes(b"{") {
            return false;
        }

        for (at, item) in held.iter().take(count).enumerate() {
            if at > 0 && !self.arena.push_bytes(b", ") {
                return false;
            }

            if !self.written_into(item.0, item.1) {
                return false;
            }
        }

        self.arena.push_bytes(b"}")
    }

    fn item_precedes(&self, left: (u32, u32), right: (u32, u32)) -> bool {
        let held = self.spelling(left);
        let other = self.spelling(right);
        let (first, one) = classed(held);
        let (second, two) = classed(other);

        if first != second {
            return first < second;
        }

        versioned(one, two)
    }

    fn spelling(&self, item: (u32, u32)) -> &'held [u8] {
        let from = self.tokens[item.0 as usize].offset as usize;
        let to = (self.tokens[(item.1 - 1) as usize].end() as usize).min(self.source.len());

        if from >= to {
            return b"";
        }

        &self.source[from..to]
    }

    fn written_into(&mut self, from: u32, to: u32) -> bool {
        let offset = self.arena.count();
        let mut tight = false;
        let mut skip = 0;

        for scan in from..to {
            if scan < skip {
                continue;
            }

            let token = self.tokens[scan as usize];

            if wide::LIST_NESTS && token.kind == TokenKind::BlockStart {
                let Some(close) = self.closing(scan) else {
                    return false;
                };

                if close >= to || !self.nested_into(scan, close) {
                    return false;
                }

                skip = close + 1;
                tight = false;

                continue;
            }

            if token.length == 0 || token.kind == TokenKind::Newline {
                continue;
            }

            let text = token.text(self.source);
            let held = self.word_is(scan, self.policy.list_tight);
            let welded = wide::LIST_NESTS && matches!(text, b"}" | b")" | b"]" | b",");
            let parted = !tight && !held && !welded;

            tight = held || wide::LIST_NESTS && matches!(text, b"{" | b"(" | b"[");

            if parted && self.arena.count() > offset && !self.arena.push_bytes(b" ") {
                return false;
            }

            if !self.arena.push_bytes(token.text(self.source)) {
                return false;
            }
        }

        true
    }

    fn separated_list(&self, position: u32, close: u32) -> bool {
        let mut scan = position + 1;

        while scan < close {
            if self.tokens[scan as usize].kind == TokenKind::Punctuation(Punctuation::Comma)
                && self.next_of(scan) != Some(close)
            {
                return true;
            }

            scan += 1;
        }

        false
    }

    fn soled(&mut self, position: u32, close: u32, hugged: bool) -> bool {
        let opened = self
            .document
            .push(Element::Verbatim(self.written(position)))
            && (hugged || self.document.push(Element::Space));

        if !opened || !self.listing(position, close, false) {
            return false;
        }

        self.closed = Frame {
            close,
            open: position,
            ..Frame::EMPTY
        };
        self.previous = Some(close);
        self.resume = close + 1;
        self.suppress_space = false;

        (hugged || self.document.push(Element::Space))
            && self.document.push(Element::Verbatim(self.written(close)))
    }

    fn grouped(&mut self, position: u32, close: u32) -> bool {
        let hugged = self.policy.list_hugs;

        if !self.separated_list(position, close) {
            return self.soled(position, close, hugged);
        }

        let edge = if self.used_wide(position) || self.nested_list(position, close) {
            Element::HardLine
        } else if hugged {
            Element::SoftLine
        } else {
            Element::Line
        };

        let filled = self.policy.list_fills;

        let opened = self
            .document
            .push(Element::Verbatim(self.written(position)))
            && self.document.push(Element::GroupOpen)
            && self.document.push(Element::Indent)
            && self.document.push(edge)
            && (!filled
                || self.document.push(Element::GroupOpen) && self.document.push(Element::Filled));

        if !opened {
            return false;
        }

        if !self.listing(position, close, filled) {
            return false;
        }

        self.closed = Frame {
            close,
            open: position,
            ..Frame::EMPTY
        };
        self.previous = Some(close);
        self.resume = close + 1;
        self.suppress_space = false;

        (!filled || self.document.push(Element::GroupClose))
            && self.document.push(Element::IfBroken(self.comma))
            && self.document.push(Element::Dedent)
            && self.document.push(edge)
            && self.document.push(Element::Verbatim(self.written(close)))
            && self.document.push(Element::GroupClose)
    }

    fn listing(&mut self, position: u32, close: u32, filled: bool) -> bool {
        let nested = self.nested_list(position, close);
        let mut count = 0;
        let mut held = [Span {
            length: 0,
            offset: 0,
        }; LIST_ITEM_MAX as usize];
        let mut scan = position + 1;

        while scan < close {
            let stop = self.parted_at(scan, close);

            if scan < stop {
                if count == LIST_ITEM_MAX {
                    return self.ordered(position, close);
                }

                let offset = self.arena.count();

                if !self.written_into(scan, stop) {
                    return false;
                }

                held[count as usize] = Span {
                    length: self.arena.count() - offset,
                    offset,
                };

                count += 1;
            }

            scan = stop + 1;
        }

        if self.policy.list_sorts {
            sorted(self.arena.as_bytes(), &mut held[..count as usize]);
        }

        for index in 0..count {
            let broken = wide::LIST_NESTS
                && filled
                && nested
                && index > 0
                && (self.item_pathed(held[index as usize])
                    || self.item_pathed(held[(index - 1) as usize]));

            if index > 0 && !self.separates_at(broken) {
                return false;
            }

            if !self
                .document
                .push(Element::VerbatimArena(held[index as usize]))
            {
                return false;
            }
        }

        true
    }

    fn list_depth(&self, from: u32, to: u32) -> u32 {
        let mut depth = 0_u32;
        let mut deepest = 0_u32;
        let mut scan = from;

        while scan < to {
            if self.tokens[scan as usize].kind == TokenKind::BlockStart {
                depth += 1;
                deepest = deepest.max(depth);
            } else if self.tokens[scan as usize].kind == TokenKind::BlockEnd {
                depth = depth.saturating_sub(1);
            }

            scan += 1;
        }

        deepest
    }

    fn nested_list(&self, position: u32, close: u32) -> bool {
        if !wide::LIST_NESTS || !self.policy.list_sorts {
            return false;
        }

        let mut scan = position + 1;

        while scan < close {
            if self.tokens[scan as usize].kind == TokenKind::BlockStart {
                return true;
            }

            scan += 1;
        }

        false
    }

    fn item_pathed(&self, span: Span) -> bool {
        self.arena.as_bytes()[span.range()]
            .windows(2)
            .any(|pair| pair == b"::")
    }

    fn ordered(&mut self, position: u32, close: u32) -> bool {
        let mut first = true;
        let mut scan = position + 1;

        while scan < close {
            let stop = self.parted_at(scan, close);

            if scan < stop {
                if !first && !self.separates() {
                    return false;
                }

                if !self.specified(scan, stop) {
                    return false;
                }

                first = false;
            }

            scan = stop + 1;
        }

        true
    }

    fn separates(&mut self) -> bool {
        self.separates_at(false)
    }

    fn separates_at(&mut self, broken: bool) -> bool {
        if !self
            .document
            .push(Element::Text(Source::Literal, self.comma))
        {
            return false;
        }

        if !self.inset() {
            return false;
        }

        if !broken {
            return self.document.push(Element::Line);
        }

        self.document.push(Element::GroupClose)
            && self.document.push(Element::Line)
            && self.document.push(Element::GroupOpen)
            && self.document.push(Element::Filled)
    }

    fn remark_trailing(&self, position: u32) -> bool {
        let token = self.tokens[position as usize];

        token.kind == TokenKind::Comment
            && token.text(self.source).starts_with(b"//")
            && self
                .previous
                .is_some_and(|first| !self.parts_at(first, position))
    }

    fn preceded(&mut self, position: u32, body: bool, template: bool, held: bool) -> bool {
        let closing = self.spreads() && position == self.nest[self.depth as usize - 1].close;

        if self.spreads() && self.remark_trailing(position) {
            return self.document.push(Element::Space);
        }
        let token = self.tokens[position as usize];

        let tagged = template
            && self
                .previous
                .is_some_and(|first| ends_operand(self.tokens[first as usize].kind));

        let streamed = body && self.macro_bracket(position);

        let gapped = self
            .previous
            .is_none_or(|first| self.tokens[first as usize].end() < token.offset);

        let defined = body
            && self.previous.is_some_and(|first| {
                self.tokens[first as usize].kind == TokenKind::Identifier && self.defining(first)
            });

        let spaced = if body && !streamed && self.policy.macro_gaps || DEFINE_GAPS && defined {
            gapped
        } else {
            body && !streamed || !streamed && self.spaced(position) && !tagged
        };

        if !closing && (self.separating() || self.binary_wrapped() || self.ternary_parted(position))
            || !held
            || self.previous.is_some_and(|held| self.valued_colon(held))
        {
            if self.policy.chain_simples
                && self.ternary_parted(position)
                && let Some(level) = self.ternary_level(position)
                && !self.level(level.saturating_sub(1))
            {
                return false;
            }

            if !closing && self.separating() && !self.inset() {
                return false;
            }

            return self.parts(position);
        }

        !spaced || closing || self.document.push(Element::Space)
    }

    fn valued_colon(&self, previous: u32) -> bool {
        if !self.policy.chain_simples || !self.policy.assign_groups || self.depth == 0 {
            return false;
        }

        let frame = self.nest[self.depth as usize - 1];

        frame.valued.0 != 0 && frame.valued.0 == previous
    }

    fn brace_joined(&self, position: u32, previous: u32) -> bool {
        if !self.policy.chain_simples
            || self.tokens[position as usize].kind != TokenKind::BlockStart
            || self.tokens[previous as usize].kind != TokenKind::Punctuation(Punctuation::Colon)
        {
            return false;
        }

        self.clauses(previous)
    }

    fn wrap_headed(&self) -> bool {
        self.policy.assign_lines
            && self.wraps_owed > 0
            && self.previous == Some(self.wrapped[self.wraps_owed as usize - 1].4)
    }

    fn binary_wrapped(&self) -> bool {
        if !self.policy.binary_lines || self.wraps_owed == 0 {
            return false;
        }

        let (close, wrap, depth, floor, _) = self.wrapped[self.wraps_owed as usize - 1];

        if !matches!(
            wrap,
            Wrap::Argued | Wrap::Paired | Wrap::Parens | Wrap::Valued
        ) || depth != self.depth
        {
            return false;
        }

        self.previous
            .is_some_and(|held| held < close && self.binary_floored(held, floor))
    }

    fn valuing(&self) -> bool {
        if self
            .assigned
            .is_some_and(|(held, _)| self.previous == Some(held))
        {
            return true;
        }

        self.depth > 0
            && self.previous.is_some_and(|held| {
                self.nest[self.depth as usize - 1].valued.0 == held
                    && self.nest[self.depth as usize - 1].valued.2 != 0
            })
    }

    fn spanning(&mut self, position: u32, close: u32, body: bool, element: bool) -> bool {
        let written = if element {
            self.respanned(position, close, true)
        } else if body {
            self.spread(position, close)
        } else if self.template_body(position).is_some() {
            self.respanned(position, close, false)
        } else {
            self.spanned(position, close)
        };

        written && self.assigns(position) && self.wraps(position)
    }

    fn spanning_body(&self, position: u32) -> Option<u32> {
        self.macro_body(position)
            .or_else(|| self.giving(position))
            .or_else(|| self.skipping(position))
            .or_else(|| self.strung(position))
            .or_else(|| self.attribute_span(position))
    }

    #[expect(
        clippy::too_many_lines,
        reason = "the order the token's own pieces are written in is the rule, and splitting it \
                  would hide it"
    )]
    fn token(&mut self, position: u32) -> bool {
        self.arrowed = false;
        self.starting = self.line_start;

        if !self.ternary_leads(position) {
            return false;
        }

        let body = self.spanning_body(position);
        let template = self.template_body(position);
        let element = self.jsx_body(position);

        if element.is_none() && self.roled(position, ROLE_JSX) {
            return false;
        }

        let closing = self.spreads() && position == self.nest[self.depth as usize - 1].close;
        let valued = self.valuing();

        if self.line_start {
            if !self.leads(position) {
                return false;
            }
        } else if !self.preceded(
            position,
            body.is_some(),
            template.is_some(),
            closing || !valued,
        ) {
            return false;
        }

        if let Some(close) = body.or(template).or(element) {
            return self.spanning(position, close, body.is_some(), element.is_some());
        }

        if let Some(close) = self.importing(position) {
            return self.grouped(position, close);
        }

        if !self.ends_value(position) {
            return false;
        }

        if closing && !self.closes(position) {
            return false;
        }

        if !self.nested(position) {
            return false;
        }

        self.remarked = self.starting && self.tokens[position as usize].kind == TokenKind::Comment;
        self.suppress_space = self.suppresses(position);
        self.previous = Some(position);

        if !self.constructing(position)
            || !self.union_leads(position)
            || !self.ternary_opens(position)
            || !self.emitted(position)
            || !self.ternary_aligns(position)
            || !self.hugs_body(position)
            || !self.remarks_comma(position)
            || !self.constructed(position)
        {
            return false;
        }

        if !self.assigns(position)
            || !self.holds_value(position)
            || !self.values(position)
            || !self.wraps(position)
        {
            return false;
        }

        if closing {
            return self.document.push(Element::GroupClose);
        }

        let spread = self.spreads().then(|| {
            let frame = self.nest[self.depth as usize - 1];

            (frame.open, frame.spread)
        });

        match spread {
            Some((open, held)) if open == position => {
                self.marks(position) && self.opens(position, held)
            }
            _ => true,
        }
    }

    fn constructing(&mut self, position: u32) -> bool {
        self.glued = false;

        if self.policy.construct_words.is_empty()
            || !self.word_is(position, self.policy.declaration_words)
            || self.constructed == NEST_DEPTH_MAX
        {
            return true;
        }

        let reached = self
            .previous_word(position)
            .is_some_and(|held| self.word_is(held, self.policy.construct_words));

        if !reached {
            return true;
        }

        let Some(close) = self.bodied_of(position) else {
            return true;
        };

        self.constructs[self.constructed as usize] = close;
        self.constructed += 1;

        self.document
            .push(Element::Text(Source::Literal, self.opening))
    }

    fn constructed(&mut self, position: u32) -> bool {
        if self.constructed == 0 || self.constructs[self.constructed as usize - 1] != position {
            return true;
        }

        self.constructed -= 1;

        if !self
            .document
            .push(Element::Text(Source::Literal, self.closing))
        {
            return false;
        }

        let called = self.next_of(position).is_some_and(|held| {
            self.tokens[held as usize].kind == TokenKind::Punctuation(Punctuation::ParenOpen)
        });

        if called {
            self.glued = true;
            self.suppress_space = true;

            return true;
        }

        self.document
            .push(Element::Text(Source::Literal, self.opening))
            && self
                .document
                .push(Element::Text(Source::Literal, self.closing))
    }

    fn bodied_of(&self, position: u32) -> Option<u32> {
        let mut angles = 0_u32;
        let mut depth = 0_u32;
        let mut scan = position + 1;

        while scan < self.count {
            let kind = self.tokens[scan as usize].kind;
            let text = self.tokens[scan as usize].text(self.source);

            if kind == TokenKind::BlockStart && depth == 0 && angles == 0 {
                return self.closing(scan);
            }

            if depth == 0 && text == b"<" {
                angles += 1;
            } else if depth == 0
                && angles > 0
                && !text.is_empty()
                && text.iter().all(|byte| *byte == b'>')
            {
                angles = angles.saturating_sub(count_of(text.len()));
            }

            if is_open(kind) {
                depth += 1;
            } else if is_close(kind) {
                depth = depth.checked_sub(1)?;
            } else if kind == TokenKind::Punctuation(Punctuation::Semicolon)
                && depth == 0
                && angles == 0
            {
                return None;
            }

            scan += 1;
        }

        None
    }

    fn previous_word(&self, position: u32) -> Option<u32> {
        self.back_of(position)
    }

    fn remarks_comma(&mut self, position: u32) -> bool {
        if !self.trailed_comma(position) {
            return true;
        }

        let close = self.nest[self.depth as usize - 1].close;
        let typed = self.typed || self.typed_brace(close);

        let held = if typed && self.tokens[close as usize].kind == TokenKind::BlockEnd {
            self.semicolon
        } else {
            self.comma
        };

        self.document.push(Element::Text(Source::Literal, held))
    }

    fn marks(&mut self, position: u32) -> bool {
        if !self.hugging(position) {
            return true;
        }

        self.document.push(Element::Hugged)
    }

    fn opened_type(text: &[u8], angles: &mut u32, brackets: &mut u32) {
        if text == b"<" {
            *angles += 1;
        } else if !text.is_empty() && text.iter().all(|byte| *byte == b'>') {
            *angles = angles.saturating_sub(count_of(text.len()));
        } else if text == b"[" {
            *brackets += 1;
        } else if text == b"]" {
            *brackets = brackets.saturating_sub(1);
        }
    }

    fn preceding(&self, position: u32) -> Option<TokenKind> {
        let held = self.word_before(position)?;

        if !is_close(self.tokens[held as usize].kind) {
            return None;
        }

        let open = reach::opened(self.source, self.tokens, held)?;

        Some(self.tokens[open as usize].kind)
    }

    fn parts(&mut self, position: u32) -> bool {
        if self.policy.spread_blanks
            && self
                .previous
                .is_some_and(|held| self.blanked(held, position))
        {
            return self.document.push(Element::HardLine)
                && self.document.push(Element::BlankLine(1));
        }

        let element = if self.chains_a_header() && self.operating(position) {
            Element::SoftLine
        } else {
            Element::Line
        };

        self.document.push(element)
    }

    fn carrying(&mut self, bodies: Option<u32>) -> u32 {
        if let Some(level) = bodies {
            self.branch_opened(level, self.coded().unwrap_or_default());

            return level + 1;
        }

        if self.chained && self.policy.link_levels {
            return self.linked();
        }

        if self.clause_within() {
            if self.clause_started() {
                return self.clause_base();
            }

            return self.clause_base().min(self.printed) + 1;
        }

        if self.continued {
            if self.policy.nested_levels {
                return self.levels.max(self.based + 1);
            }

            return self.printed;
        }

        if self.policy.header_levels {
            return self.printed + 1;
        }

        self.levels.min(self.printed) + 1
    }

    fn seated(
        &self,
        position: u32,
        leading: u32,
        branch: Option<u32>,
        popped: Option<u32>,
    ) -> Option<u32> {
        self.value_level(leading)
            .or_else(|| self.arm_barred(leading))
            .or(branch)
            .or_else(|| self.clause_level(leading))
            .or(popped)
            .or_else(|| OPERAND_FIRST.then(|| self.operand_level(leading)).flatten())
            .or_else(|| self.generic_level(leading))
            .or_else(|| self.barred(leading))
            .or_else(|| self.remarked_level(leading))
            .or_else(|| {
                self.dedents(position)
                    .then(|| self.levels.saturating_sub(1))
            })
            .or_else(|| self.sequence_level(leading))
            .or_else(|| self.header_bodied(leading))
            .or_else(|| self.binary_level(leading))
            .or_else(|| self.binary_carried(leading))
            .or_else(|| self.heritage_level(leading))
            .or_else(|| self.union_level(leading))
            .or_else(|| self.ternary_level(leading))
            .or_else(|| self.operand_level(leading))
            .or_else(|| self.assign_level(leading))
            .or_else(|| self.brace_level(leading))
            .or_else(|| self.chain_level(leading))
    }

    pub(super) fn leveled_at(&self, position: u32) -> Option<u32> {
        let mut found: Option<(u32, u32)> = None;

        for (start, level) in self.lines {
            if start == 0 || start - 1 > position {
                continue;
            }

            if found.is_none_or(|(held, _)| start > held) {
                found = Some((start, level));
            }
        }

        found.map(|(_, level)| level)
    }

    fn owing_operand(&self) -> bool {
        self.policy.chain_simples
            && self.spreads()
            && self
                .coded()
                .is_some_and(|held| self.wrapping_operator(held))
    }

    fn leads(&mut self, position: u32) -> bool {
        assert!(self.assigned.is_none());
        assert_eq!(self.owed, 0);

        self.line_before = self.line_first;
        self.line_first = position;

        let leading = if self.tokens[position as usize].kind == TokenKind::Comment {
            self.coding(position).unwrap_or(position)
        } else {
            position
        };

        self.chained = self.chains(leading);

        let popped = self.popped(leading);
        let held = popped.is_none() && self.continues(leading, true);
        let ending = self.policy.header_levels && self.word_is(leading, self.policy.level_words);
        let branch = if ending { self.branch_level() } else { None };
        let bodies = if held && branch.is_none() {
            self.header_level(leading)
        } else {
            None
        };

        let carries = popped.is_none() && self.continues(leading, false);

        let wanted = if let Some(level) = self.seated(position, leading, branch, popped) {
            level
        } else if held {
            self.carrying(bodies)
        } else {
            self.levels
        };

        let bound = if self.policy.binding_words.is_empty() {
            wanted
        } else {
            self.bounded(wanted, held.then_some(leading))
        };

        let stepped = if self.carries(position) {
            self.printed
        } else {
            bound
        } + if (self.chained || self.owing_operand()) && !self.member_parted(position)
        {
            core::mem::take(&mut self.owing)
        } else {
            self.owing = 0;

            0
        };

        if self.opens_a_clause(position) {
            self.claused_body = false;
            self.claused_depth = self.depth;
        }

        let opens = carries && (bodies.is_none() || leading != position);

        if !held && !ending {
            while self.branched > 0 && self.branches[self.branched as usize - 1].1 >= self.depth {
                self.branched -= 1;
            }
        }

        self.claused = self.clauses(position);
        self.continued = opens;

        if !opens {
            self.based = stepped;
        }

        if self.depth == 0 && self.word_is(position, self.policy.declare_words) {
            self.declared = Some(position);
        }

        if self.depth == 0 {
            self.typed = self.typing(position);
        }

        if !self.level(stepped) {
            return false;
        }

        self.printed = stepped;
        self.lines[self.lined as usize] = (position + 1, stepped);
        self.lined = (self.lined + 1) % LINE_LEVEL_MAX;
        self.line_start = false;

        true
    }

    fn wraps(&mut self, position: u32) -> bool {
        if self.wraps_owed == WRAP_DEPTH_MAX {
            return true;
        }

        let held = self
            .wrapping(position)
            .map(|close| (close, Wrap::Parens))
            .or_else(|| self.arrow_wrapped(position))
            .or_else(|| self.assign_wrap(position))
            .or_else(|| self.value_wrap(position));

        let Some((close, wrap)) = held else {
            return true;
        };

        let floor = if matches!(
            wrap,
            Wrap::Argued | Wrap::Paired | Wrap::Parens | Wrap::Valued
        ) {
            let floored = self.binary_floor(position, close);

            let heavy = BINARY_HEAVIES
                && self
                    .next_of(position)
                    .is_some_and(|head| self.binary_heavy(head, close, self.printed + 1));

            if heavy
                || LOGICAL_INLINES && floored <= LOGICAL_LEVEL_MAX && self.binary_inlined(close)
            {
                BINARY_LEVEL_MAX
            } else {
                floored
            }
        } else {
            0
        };

        self.wrapped[self.wraps_owed as usize] = (close, wrap, self.depth, floor, position);
        self.wraps_owed += 1;

        if wrap == Wrap::Paired {
            return self.document.push(Element::GroupOpen);
        }

        let marked = wrap != Wrap::Hugged || self.document.push(Element::Hugged);

        let opened = marked
            && self.document.push(Element::GroupOpen)
            && (wrap != Wrap::Parens || self.document.push(Element::IfBroken(self.spacing)))
            && self.document.push(Element::IndentBroken);

        if !opened {
            return false;
        }

        if wrap == Wrap::Argued {
            return floor == BINARY_LEVEL_MAX || self.document.push(Element::GroupOpen);
        }

        if !matches!(wrap, Wrap::Parens | Wrap::Valued) {
            return self.document.push(Element::Line);
        }

        let broken = if wrap == Wrap::Valued {
            Element::Line
        } else {
            Element::SoftLine
        };

        self.document.push(broken)
            && (floor == BINARY_LEVEL_MAX || self.document.push(Element::GroupOpen))
    }

    fn ternary_dealigned(&mut self, wrap: Wrap) -> bool {
        if wrap != Wrap::Ternary {
            return true;
        }

        let owed = self.wraps_aligned[self.wraps_owed as usize];

        self.wraps_aligned[self.wraps_owed as usize] = 0;

        for _ in 0..owed {
            if !self.document.push(Element::Dealign) {
                return false;
            }
        }

        true
    }

    fn wrapped_close(&mut self, position: u32) -> bool {
        while self.wraps_owed > 0 && position > self.wrapped[self.wraps_owed as usize - 1].0 {
            self.wraps_owed -= 1;

            let (_, wrap, _, floor, _) = self.wrapped[self.wraps_owed as usize];

            if wrap == Wrap::Paired {
                if !self.document.push(Element::GroupClose) {
                    return false;
                }

                continue;
            }

            if matches!(wrap, Wrap::Argued | Wrap::Parens | Wrap::Valued)
                && floor != BINARY_LEVEL_MAX
                && !self.document.push(Element::GroupClose)
            {
                return false;
            }

            let closed = self.ternary_dealigned(wrap)
                && self.document.push(Element::DedentBroken)
                && (wrap != Wrap::Hugged || self.document.push(Element::Hugging(self.comma)))
                && (wrap != Wrap::Parens || self.document.push(Element::SoftLine))
                && (wrap != Wrap::Parens || self.document.push(Element::IfBroken(self.closing)))
                && self.document.push(Element::GroupClose);

            if !closed {
                return false;
            }
        }

        true
    }

    fn assigns(&mut self, position: u32) -> bool {
        if let Some((close, dedent)) = self.assigning(position) {
            if self.owed == ASSIGN_DEPTH_MAX {
                return false;
            }

            self.assigned = Some((position, close));
            self.dedents[self.owed as usize] = dedent;
            self.owed += 1;

            let opened =
                self.document.push(Element::GroupOpen) && self.document.push(Element::IndentBroken);

            if !opened {
                return false;
            }
        }

        if self.assigned.is_some_and(|(_, close)| position == close) {
            self.assigned = None;
            self.arrowed = self.tokens[position as usize].text(self.source) == b"=>";

            if !self.document.push(Element::GroupClose) {
                return false;
            }
        }

        while self.owed > 0 && self.dedents[self.owed as usize - 1] == position {
            self.owed -= 1;

            if !self.document.push(Element::DedentBroken) {
                return false;
            }
        }

        true
    }

    fn propertied(&self, position: u32) -> Option<(u32, u32, u32)> {
        if !self.policy.assign_groups || !self.spreads() {
            return None;
        }

        let frame = self.nest[self.depth as usize - 1];

        if frame.kind != TokenKind::BlockStart
            || frame.valued.2 != 0
            || self.tokens[position as usize].kind != TokenKind::Punctuation(Punctuation::Colon)
        {
            return None;
        }

        if self.typed || self.slight_key(position) && !self.paired_binary(position) {
            return None;
        }

        let end = self.ended(position, frame.close)?;

        if self.lone_value(position, end) {
            return None;
        }

        let mut close = None;
        let mut scan = position + 1;

        while scan < end {
            let token = self.tokens[scan as usize];

            if token.kind == TokenKind::Newline || token.length == 0 {
                scan += 1;

                continue;
            }

            if let Some(held) = self
                .template_body(scan)
                .or_else(|| self.jsx_body(scan))
                .or_else(|| self.parened(scan))
            {
                scan = held + 1;

                continue;
            }

            if is_open(token.kind) {
                let held = self.closing_of(scan)?;

                if close.is_none() && !self.slight(scan, held) {
                    close = Some(scan);
                }

                scan = held + 1;

                continue;
            }

            scan += 1;
        }

        if let Some(arrow) = self.valued_arrow(position, end) {
            return Some((position, arrow, end));
        }

        if self.paired_binary(position) {
            return Some((position, end, end));
        }

        Some((position, close.unwrap_or(end), end))
    }

    fn paired_binary(&self, colon: u32) -> bool {
        self.next_of(colon)
            .is_some_and(|head| self.value_wrap(head).is_some())
    }

    fn slight_key(&self, position: u32) -> bool {
        let Some(found) = self.word_before(position) else {
            return false;
        };

        let optional = self.tokens[found as usize].text(self.source) == b"?";

        let Some(held) = (if optional {
            self.word_before(found)
        } else {
            Some(found)
        }) else {
            return false;
        };

        let width = u32::from(optional);
        let token = self.tokens[held as usize];

        if !matches!(
            token.kind,
            TokenKind::Identifier | TokenKind::Keyword(_) | TokenKind::Number | TokenKind::String
        ) {
            return false;
        }

        let quoted = u32::from(self.unquoting(held).is_some()) * 2;

        width + token.length - quoted < self.options.indent_width + 3
    }

    fn lone_value(&self, position: u32, end: u32) -> bool {
        let Some(held) = self.next_of(position).filter(|held| *held < end) else {
            return false;
        };

        let token = self.tokens[held as usize];

        let alone = match self.template_body(held) {
            Some(close) => self.trails(close, end),
            None => self.trails(held, end),
        };

        alone
            && (token.kind == TokenKind::Number
                || token.kind == TokenKind::String && token.text(self.source) == b"`")
    }

    fn trails(&self, position: u32, end: u32) -> bool {
        let Some(next) = self.next_of(position) else {
            return true;
        };

        if next >= end {
            return true;
        }

        matches!(
            self.tokens[next as usize].kind,
            TokenKind::Punctuation(Punctuation::Comma | Punctuation::Semicolon)
        ) && self.next_of(next).is_none_or(|held| held >= end)
    }

    fn ended(&self, position: u32, close: u32) -> Option<u32> {
        let mut depth = 0_u32;
        let mut scan = position + 1;

        while scan < close {
            let held = self.tokens[scan as usize];
            let kind = held.kind;

            if is_open(kind) || substituting(self.source, held) {
                depth += 1;
            } else if is_close(kind) {
                depth = depth.checked_sub(1)?;
            } else if depth == 0
                && matches!(
                    kind,
                    TokenKind::Punctuation(Punctuation::Comma | Punctuation::Semicolon)
                )
            {
                return Some(if self.next_of(scan) == Some(close) {
                    close
                } else {
                    scan
                });
            }

            scan += 1;
        }

        (scan == close).then_some(close)
    }

    fn values(&mut self, position: u32) -> bool {
        let Some(held) = self.propertied(position) else {
            return true;
        };

        self.nest[self.depth as usize - 1].valued = held;

        self.document.push(Element::GroupOpen) && self.document.push(Element::IndentBroken)
    }

    fn ends_value(&mut self, position: u32) -> bool {
        if self.depth == 0 {
            return true;
        }

        let frame = self.nest[self.depth as usize - 1];

        if frame.valued.2 != position {
            return true;
        }

        self.nest[self.depth as usize - 1].valued = (0, 0, 0);

        if frame.valued.1 == position && !self.document.push(Element::GroupClose) {
            return false;
        }

        self.document.push(Element::DedentBroken)
    }

    fn holds_value(&mut self, position: u32) -> bool {
        let owed = 1 + u32::from(is_open(self.tokens[position as usize].kind));

        if self.depth < owed {
            return true;
        }

        let index = (self.depth - owed) as usize;
        let frame = self.nest[index];

        if frame.valued.1 != position || frame.valued.2 == position {
            return true;
        }

        self.nest[index].valued.1 = 0;

        self.document.push(Element::GroupClose)
    }

    fn opens(&mut self, position: u32, spread: Option<Spread>) -> bool {
        let kind = self.tokens[position as usize].kind;
        let filled = spread == Some(Spread::Fill);

        let parted = kind == TokenKind::BlockStart
            && self
                .next_of(position)
                .is_some_and(|held| self.parts_at(position, held))
            || self.parted_params(position)
            || self.parted_generics(position)
            || kind == TokenKind::BlockStart && self.declared_body(position)
            || self.composed_args(position)
            || self
                .closing_of(position)
                .is_some_and(|close| self.spread_matrix(position, close))
            || spread.is_some()
                && self
                    .closing_of(position)
                    .is_some_and(|close| self.spread_remarked(position, close));

        let edge = if parted {
            Element::HardLine
        } else {
            Self::edged(kind)
        };

        self.document.push(Element::GroupOpen)
            && (!filled || self.document.push(Element::Filled))
            && self.document.push(Element::IndentBroken)
            && self.document.push(edge)
    }

    fn spread_remarked(&self, open: u32, close: u32) -> bool {
        let mut depth = 0_u32;
        let mut scan = open + 1;

        while scan < close {
            let token = self.tokens[scan as usize];

            if is_open(token.kind) || token.kind == TokenKind::BlockStart {
                depth += 1;
            } else if is_close(token.kind) || token.kind == TokenKind::BlockEnd {
                depth = depth.saturating_sub(1);
            } else if depth == 0
                && token.kind == TokenKind::Comment
                && token.text(self.source).starts_with(b"//")
                && self
                    .word_before(scan)
                    .is_some_and(|held| held > open && !self.parts_at(held, scan))
            {
                return true;
            }

            scan += 1;
        }

        false
    }

    fn parted_generics(&self, position: u32) -> bool {
        if !self.policy.generic_parts || !self.define_parted(position) {
            return false;
        }

        let Some(angle) = self.back_of(position) else {
            return false;
        };

        if self.tokens[angle as usize].text(self.source) != b">" {
            return false;
        }

        self.back_of(angle)
            .is_some_and(|held| self.parts_at(held, angle))
    }

    fn parted_params(&self, position: u32) -> bool {
        if self.policy.parameter_words.is_empty()
            || self.tokens[position as usize].kind != TokenKind::Punctuation(Punctuation::ParenOpen)
        {
            return false;
        }

        let Some(close) = self.closing_of(position) else {
            return false;
        };

        let mut angles = 0_u32;
        let mut commas = 0;
        let mut depth = 0_u32;
        let mut held = false;
        let mut scan = position + 1;

        while scan < close {
            let token = self.tokens[scan as usize];
            let text = token.text(self.source);

            Self::opened_type(text, &mut angles, &mut 0);

            if is_open(token.kind) {
                depth += 1;
            } else if is_close(token.kind) {
                depth = depth.saturating_sub(1);
            } else if depth == 0 && angles == 0 {
                let parting = token.kind == TokenKind::Punctuation(Punctuation::Comma)
                    && self.next_of(scan) != Some(close);

                commas += u32::from(parting);
                held |= self.property_head(scan);
            }

            scan += 1;
        }

        held && commas > 0
    }

    fn inset(&mut self) -> bool {
        if !self.policy.chain_simples || self.depth == 0 {
            return true;
        }

        let wanted = self.nest[self.depth as usize - 1].inset;

        self.level(wanted)
    }

    fn closes(&mut self, position: u32) -> bool {
        if !self.inset() {
            return false;
        }

        let frame = self.nest[self.depth as usize - 1];
        let typed = self.typed || self.typed_brace(position);

        let separator = if typed && self.tokens[position as usize].kind == TokenKind::BlockEnd {
            self.semicolon
        } else {
            self.comma
        };

        let edge = Self::edged(frame.kind);

        if matches!(frame.spread, Some(Spread::Chain | Spread::Clauses)) {
            return self.document.push(Element::DedentBroken) && self.document.push(edge);
        }

        (self.spread_rest(position)
            || self.trailed_already(position)
            || self.paren_grouped(frame.open, position)
            || self.bracket_grouped(frame.open, position)
            || self.document.push(Element::IfBroken(separator)))
            && self.document.push(Element::DedentBroken)
            && self.document.push(edge)
    }

    fn starred(&mut self, text: &[u8]) -> bool {
        let indent = self.printed * self.options.indent_width;
        let mut offset = 0;

        while offset < text.len() {
            let stop = text[offset..]
                .iter()
                .position(|byte| *byte == b'\n')
                .map_or(text.len(), |at| offset + at);

            if offset > 0 {
                let written = if self.options.tabs {
                    tabbed(self.arena, self.printed)
                } else {
                    spaced(self.arena, indent)
                };

                if !written || !self.arena.push_bytes(b" ") {
                    return false;
                }
            }

            if !self.arena.push_bytes(text[offset..stop].trim_ascii()) {
                return false;
            }

            if stop < text.len() && !self.arena.push_bytes(b"\n") {
                return false;
            }

            offset = stop + 1;
        }

        true
    }

    fn starring(&self, position: u32) -> bool {
        let token = self.tokens[position as usize];

        if !self.starting || token.kind != TokenKind::Comment {
            return false;
        }

        let text = token.text(self.source);

        if !self
            .policy
            .lead_words
            .iter()
            .any(|word| text.starts_with(word))
        {
            return false;
        }

        let mut lines = text.split(|byte| *byte == b'\n');
        let first = lines.next();

        first.is_some()
            && lines.clone().count() > 0
            && lines.all(|line| line.trim_ascii_start().starts_with(b"*"))
    }

    fn unquoting(&self, position: u32) -> Option<Span> {
        if !self.policy.key_quotes {
            return None;
        }

        let token = self.tokens[position as usize];

        if token.kind != TokenKind::String {
            return None;
        }

        let body = bodied(token.text(self.source))?;

        if !named_key(body) || self.policy.key_words.contains(&body) {
            return None;
        }

        let opens = self.word_before(position).is_some_and(|held| {
            matches!(
                self.tokens[held as usize].kind,
                TokenKind::BlockEnd
                    | TokenKind::BlockStart
                    | TokenKind::Punctuation(Punctuation::Comma | Punctuation::Semicolon)
            )
        });

        if !opens || !self.keyed(position) {
            return None;
        }

        Some(Span {
            length: token.length - 2,
            offset: token.offset + 1,
        })
    }

    fn keyed(&self, position: u32) -> bool {
        let Some(next) = self.next_of(position) else {
            return false;
        };

        let kind = self.tokens[next as usize].kind;

        if kind == TokenKind::Punctuation(Punctuation::Colon) {
            return true;
        }

        if self.tokens[next as usize].text(self.source) != b"?" {
            return false;
        }

        self.next_of(next).is_some_and(|held| {
            self.tokens[held as usize].kind == TokenKind::Punctuation(Punctuation::Colon)
        })
    }

    fn casting(&self, position: u32) -> Option<&'static [u8]> {
        if self.policy.order_words.is_empty() || !self.casted(position) {
            return None;
        }

        let mut head = position;

        for _ in 0..ORDER_RUN_MAX {
            let Some(above) = self.cast_above(head) else {
                break;
            };

            head = above;
        }

        let mut ranks = [0_u32; ORDER_RUN_MAX as usize];
        let mut count = 0;
        let mut index = 0;
        let mut scan = Some(head);

        while let Some(held) = scan {
            if count == ORDER_RUN_MAX {
                return None;
            }

            if held == position {
                index = count;
            }

            ranks[count as usize] = self.ranking(held)?;
            count += 1;
            scan = self.cast_under(held);
        }

        if count < 2 {
            return None;
        }

        for step in 1..count {
            let rank = ranks[step as usize];
            let mut place = step;

            while place > 0 && ranks[place as usize - 1] > rank {
                ranks[place as usize] = ranks[place as usize - 1];
                place -= 1;
            }

            ranks[place as usize] = rank;
        }

        let wanted = self.policy.order_words[ranks[index as usize] as usize];

        (wanted != self.tokens[position as usize].text(self.source)).then_some(wanted)
    }

    fn casted(&self, position: u32) -> bool {
        self.word_is(position, self.policy.order_words)
            && self.next_of(position).is_some_and(|held| {
                self.tokens[held as usize].kind == TokenKind::Punctuation(Punctuation::ParenOpen)
            })
    }

    fn ranking(&self, position: u32) -> Option<u32> {
        let text = self.tokens[position as usize].text(self.source);

        self.policy
            .order_words
            .iter()
            .position(|held| *held == text)
            .map(count_of)
    }

    fn cast_above(&self, position: u32) -> Option<u32> {
        let open = self.back_of(position)?;

        if self.tokens[open as usize].kind != TokenKind::Punctuation(Punctuation::ParenOpen) {
            return None;
        }

        let held = self.back_of(open)?;

        self.casted(held).then_some(held)
    }

    fn cast_under(&self, position: u32) -> Option<u32> {
        let open = self.next_of(position)?;
        let held = self.next_of(open)?;

        self.casted(held).then_some(held)
    }

    fn renumbering(&self, position: u32) -> bool {
        if !self.policy.number_forms || self.tokens[position as usize].kind != TokenKind::Number {
            return false;
        }

        let held = self.tokens[position as usize]
            .text(self.source)
            .ends_with(b".");

        let reached = self
            .next_of(position)
            .is_some_and(|next| self.tokens[next as usize].text(self.source) == b".");

        !held || !reached
    }

    pub(super) fn requoting(&self, position: u32) -> Option<(&'held [u8], u8)> {
        if !self.policy.string_quotes {
            return None;
        }

        let token = self.tokens[position as usize];

        if token.kind != TokenKind::String {
            return None;
        }

        let text = token.text(self.source);
        let body = bodied(text)?;
        let wanted = preferred(body);

        (wanted != text[0]).then_some((body, wanted))
    }

    fn emitted(&mut self, position: u32) -> bool {
        if self.arrowed(position) {
            return self
                .document
                .push(Element::Text(Source::Literal, self.opening))
                && self
                    .document
                    .push(Element::Verbatim(self.written(position)))
                && self
                    .document
                    .push(Element::Text(Source::Literal, self.closing));
        }

        if self.membered(position) {
            return self
                .document
                .push(Element::Text(Source::Literal, self.semicolon));
        }

        if self.starring(position) {
            let offset = self.arena.count();
            let text = self.tokens[position as usize].text(self.source);

            if !self.starred(text) {
                return false;
            }

            return self.document.push(Element::VerbatimArena(Span {
                length: self.arena.count() - offset,
                offset,
            }));
        }

        if let Some(span) = self.unquoting(position) {
            return self.document.push(Element::Verbatim(span));
        }

        if let Some(text) = self.casting(position) {
            let offset = self.arena.count();

            if !self.arena.push_bytes(text) {
                return false;
            }

            return self.document.push(Element::VerbatimArena(Span {
                length: self.arena.count() - offset,
                offset,
            }));
        }

        if self.renumbering(position) {
            let offset = self.arena.count();

            if !renumbered(self.arena, self.tokens[position as usize].text(self.source)) {
                return false;
            }

            return self.document.push(Element::VerbatimArena(Span {
                length: self.arena.count() - offset,
                offset,
            }));
        }

        let Some((body, quote)) = self.requoting(position) else {
            return self
                .document
                .push(Element::Verbatim(self.written(position)));
        };

        let offset = self.arena.count();

        if !self.arena.push_bytes(&[quote])
            || !requoted(self.arena, body, quote)
            || !self.arena.push_bytes(&[quote])
        {
            return false;
        }

        self.document.push(Element::VerbatimArena(Span {
            length: self.arena.count() - offset,
            offset,
        }))
    }
}
