use crate::bounded::{BoundedVec, Buffer, Bytes as _, Span, count_of};
use crate::format::ir::{
    CHOICE_DEPTH_MAX,
    Document,
    Element,
    GROUP_DEPTH_MAX,
    INDENT_DEPTH_MAX,
    Source,
};

pub const INDENT_COLUMNS_MAX: u32 = 1 << 10;
const ALIGN_COLUMNS: u32 = 2;
const FILL_RESERVE: u32 = 1;
const SPACES: [u8; 64] = [b' '; 64];

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Options {
    pub indent_width: u32,
    pub line_width: u32,
    pub tabs: bool,
}

const LINE_SUFFIXES: bool = true;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum Width {
    Broken,
    Flat(u32),
}

#[derive(Debug)]
struct Printer {
    column: u32,
    columns: u32,
    indent: u32,
    line_start: bool,
    pending_space: bool,
    verbatim: bool,
}

#[derive(Debug)]
struct State {
    broken: [bool; GROUP_DEPTH_MAX as usize + 1],
    choices: u32,
    depth: u32,
    filled: [bool; GROUP_DEPTH_MAX as usize + 1],
    hugged: bool,
    hugs: [bool; GROUP_DEPTH_MAX as usize + 1],
    losing: bool,
    losses: u32,
    marks: [bool; GROUP_DEPTH_MAX as usize + 1],
    nested: u32,
    owes: u32,
    owing: [bool; INDENT_DEPTH_MAX as usize],
    owning: [bool; INDENT_DEPTH_MAX as usize],
    owns: u32,
    printer: Printer,
    seen: [u32; CHOICE_DEPTH_MAX as usize],
    skipping: bool,
    taken: [u32; CHOICE_DEPTH_MAX as usize],
}

impl State {
    const fn new() -> Self {
        Self {
            broken: [true; GROUP_DEPTH_MAX as usize + 1],
            choices: 0,
            depth: 0,
            filled: [false; GROUP_DEPTH_MAX as usize + 1],
            hugged: false,
            hugs: [false; GROUP_DEPTH_MAX as usize + 1],
            losing: false,
            losses: 0,
            marks: [false; GROUP_DEPTH_MAX as usize + 1],
            nested: 0,
            owes: 0,
            owing: [false; INDENT_DEPTH_MAX as usize],
            owning: [false; INDENT_DEPTH_MAX as usize],
            owns: 0,
            printer: Printer::new(),
            seen: [0; CHOICE_DEPTH_MAX as usize],
            skipping: false,
            taken: [0; CHOICE_DEPTH_MAX as usize],
        }
    }

    fn losses(&mut self, element: Element) -> bool {
        if !self.losing {
            return false;
        }

        match element {
            Element::Choice(_) => self.losses += 1,
            Element::ChoiceClose => {
                if self.losses > 0 {
                    self.losses -= 1;

                    return true;
                }

                self.losing = false;
                self.choices -= 1;
            }
            Element::Variant => {
                if self.losses > 0 {
                    return true;
                }

                let held = self.choices - 1;

                self.seen[held as usize] += 1;
                self.losing = self.seen[held as usize] != self.taken[held as usize];
            }
            _ => (),
        }

        true
    }

    fn chose(&mut self, held: &Measure<'_>, options: Options, index: u32, count: u32) -> bool {
        if self.choices == CHOICE_DEPTH_MAX {
            return false;
        }

        let column = if self.printer.line_start {
            self.printer.leading(options)
        } else {
            self.printer.column + u32::from(self.printer.pending_space)
        };

        let budget = options.line_width.saturating_sub(column);
        let blank = self.printer.line_start || self.printer.pending_space;
        let taken = fitting(held, index, count, budget, blank);

        self.seen[self.choices as usize] = 0;
        self.taken[self.choices as usize] = taken;
        self.choices += 1;
        self.losing = taken != 0;

        if self.losing {
            self.losses = 0;
        }

        true
    }

    fn variant(&mut self) -> bool {
        assert!(self.choices > 0);

        self.losing = true;
        self.losses = 0;

        true
    }

    fn chosen(&mut self) -> bool {
        assert!(self.choices > 0);

        self.choices -= 1;

        true
    }

    fn skipped(&mut self, element: Element) -> bool {
        if !self.skipping {
            return false;
        }

        if element == Element::GroupOpen {
            self.nested += 1;

            return true;
        }

        if element != Element::GroupClose {
            return true;
        }

        if self.nested > 0 {
            self.nested -= 1;

            return true;
        }

        assert!(self.depth > 0);

        self.depth -= 1;
        self.skipping = false;

        true
    }

    const fn broken(&self) -> bool {
        self.broken[self.depth as usize]
    }

    const fn marked(&self) -> bool {
        self.marks[self.depth as usize]
    }

    fn close(&mut self) -> bool {
        assert!(self.depth > 0);

        self.depth -= 1;

        true
    }

    fn dedent(&mut self) -> bool {
        assert!(self.printer.indent > 0);

        self.printer.indent -= 1;

        true
    }

    fn indent(&mut self) -> bool {
        assert!(self.printer.indent < INDENT_DEPTH_MAX);

        self.printer.indent += 1;

        true
    }

    fn aligns(&mut self) -> bool {
        if self.owns == INDENT_DEPTH_MAX {
            return false;
        }

        let held = self.broken();

        self.owning[self.owns as usize] = held;
        self.owns += 1;

        if held {
            self.printer.columns += ALIGN_COLUMNS;
        }

        true
    }

    fn aligned(&mut self) -> bool {
        assert!(self.owns > 0);

        self.owns -= 1;

        if self.owning[self.owns as usize] {
            assert!(self.printer.columns >= ALIGN_COLUMNS);

            self.printer.columns -= ALIGN_COLUMNS;
        }

        true
    }

    fn owe(&mut self) -> bool {
        if self.owes == INDENT_DEPTH_MAX {
            return false;
        }

        let held = self.broken();

        self.owing[self.owes as usize] = held;
        self.owes += 1;

        !held || self.indent()
    }

    fn owed(&mut self) -> bool {
        assert!(self.owes > 0);

        self.owes -= 1;

        !self.owing[self.owes as usize] || self.dedent()
    }

    fn line(&mut self, held: &Measure<'_>, options: Options, out: &mut Buffer, index: u32) -> bool {
        if !self.broken() {
            return self.space();
        }

        if self.filled[self.depth as usize] {
            let column = if self.printer.line_start {
                self.printer.leading(options)
            } else {
                self.printer.column + 1
            };

            let budget = options
                .line_width
                .saturating_sub(column)
                .saturating_sub(FILL_RESERVE);

            if fill_width(held, index + 1, budget) <= budget {
                return self.space();
            }
        }

        self.printer.newline(out)
    }

    fn open(&mut self, held: &Measure<'_>, options: Options, index: u32) -> bool {
        let document = held.document;
        let marked = self.hugged;

        assert!(self.depth < GROUP_DEPTH_MAX);

        self.hugged = false;

        let column = if self.printer.line_start {
            self.printer.leading(options)
        } else {
            self.printer.column + u32::from(self.printer.pending_space)
        };

        let budget = options.line_width.saturating_sub(column);

        let joins = matches!(
            document.elements().get((index + 1) as usize),
            Some(Element::Joined(_))
        );

        let blank = self.printer.line_start || self.printer.pending_space;

        let wide = matches!(
            document.elements().get((index + 1) as usize),
            Some(Element::Wide)
        );

        let hugging = hugged(document.elements(), index).is_some();

        let (measured, hugs) = if joins {
            (joined_width(held, index, budget, self.broken()), false)
        } else if wide {
            (wide_width(held, index, budget), false)
        } else if hugging {
            hug_width(held, index, budget, blank)
        } else {
            (width_of(held, index, budget, blank), false)
        };

        let inherits = !self.broken() && !self.hugs[self.depth as usize];
        let flat = !marked && (inherits || matches!(measured, Width::Flat(_)));

        let fills = matches!(
            document.elements().get((index + 1) as usize),
            Some(Element::Filled)
        );

        self.depth += 1;
        self.broken[self.depth as usize] = !flat;
        self.filled[self.depth as usize] = fills;
        self.hugs[self.depth as usize] = hugs;
        self.marks[self.depth as usize] = marked;

        true
    }

    fn soft(&mut self, out: &mut Buffer) -> bool {
        if self.broken() {
            return self.printer.newline(out);
        }

        true
    }

    fn space(&mut self) -> bool {
        self.printer.pending_space = !self.printer.line_start;

        true
    }
}

impl Options {
    pub const DEFAULT: Self = Self {
        indent_width: 4,
        line_width: 88,
        tabs: false,
    };
}

impl Printer {
    const fn new() -> Self {
        Self {
            column: 0,
            columns: 0,
            indent: 0,
            line_start: true,
            pending_space: false,
            verbatim: false,
        }
    }

    const fn leading(&self, options: Options) -> u32 {
        self.indent * options.indent_width + self.columns
    }

    fn aligning(&mut self, out: &mut Buffer) -> bool {
        assert!(self.columns <= count_of(SPACES.len()));

        if !out.push_bytes(&SPACES[..self.columns as usize]) {
            return false;
        }

        self.column += self.columns;

        true
    }

    fn indentation(&mut self, out: &mut Buffer, options: Options) -> bool {
        if self.indent == 0 && self.columns == 0 {
            return true;
        }

        if options.tabs {
            for _ in 0..self.indent {
                if !out.push_bytes(b"\t") {
                    return false;
                }
            }

            self.column = self.indent * options.indent_width;

            return self.columns == 0 || self.aligning(out);
        }

        let width = self.leading(options);

        assert!(width <= INDENT_COLUMNS_MAX);

        let mut written = 0;

        while written < width {
            let chunk = (width - written).min(count_of(SPACES.len()));

            if !out.push_bytes(&SPACES[..chunk as usize]) {
                return false;
            }

            written += chunk;
        }

        self.column = width;

        true
    }

    fn lead(&mut self, out: &mut Buffer, options: Options) -> bool {
        if self.line_start {
            self.pending_space = false;

            return self.indentation(out, options);
        }

        if self.pending_space {
            self.pending_space = false;

            if !out.push_bytes(&SPACES[..1]) {
                return false;
            }

            self.column += 1;
        }

        true
    }

    fn newline(&mut self, out: &mut Buffer) -> bool {
        debug_assert!(
            line_ends_clean(out, self.verbatim),
            "a printed line ends in whitespace"
        );

        self.pending_space = false;

        if !out.push_bytes(b"\n") {
            return false;
        }

        self.column = 0;
        self.line_start = true;
        self.verbatim = false;

        true
    }

    fn text(&mut self, out: &mut Buffer, bytes: &[u8], options: Options) -> bool {
        if bytes.is_empty() {
            return true;
        }

        if !self.lead(out, options) {
            return false;
        }

        if !out.push_bytes(bytes) {
            return false;
        }

        self.line_start = false;

        let (leading, trailing, broken) = columns_of(bytes);

        if broken {
            self.column = trailing;
            self.line_start = bytes.last() == Some(&b'\n');

            return true;
        }

        let _ = leading;

        self.column += trailing;

        true
    }

    fn verbatim(&mut self, out: &mut Buffer, bytes: &[u8], options: Options) -> bool {
        if !self.text(out, bytes, options) {
            return false;
        }

        self.verbatim = true;

        true
    }
}

const fn decoded(bytes: &[u8], offset: usize) -> (u32, usize) {
    let lead = bytes[offset];

    let (width, mask) = match lead {
        0x00..=0x7f => return (lead as u32, 1),
        0xc0..=0xdf => (2, 0x1f),
        0xe0..=0xef => (3, 0x0f),
        0xf0..=0xf7 => (4, 0x07),
        _ => return (lead as u32, 1),
    };

    if offset + width > bytes.len() {
        return (lead as u32, 1);
    }

    let mut held = (lead & mask) as u32;
    let mut step = 1;

    while step < width {
        held = (held << 6) | (bytes[offset + step] & 0x3f) as u32;
        step += 1;
    }

    (held, width)
}

const fn code_width(code: u32) -> u32 {
    const WIDE: [(u32, u32); 12] = [
        (0x1100, 0x115f),
        (0x2e80, 0x303e),
        (0x3041, 0x33ff),
        (0x3400, 0x4dbf),
        (0x4e00, 0x9fff),
        (0xa000, 0xa4cf),
        (0xac00, 0xd7a3),
        (0xf900, 0xfaff),
        (0xfe30, 0xfe6f),
        (0xff00, 0xff60),
        (0xffe0, 0xffe6),
        (0x1f300, 0x1f9ff),
    ];

    const ZERO: [(u32, u32); 6] = [
        (0x0300, 0x036f),
        (0x0483, 0x0489),
        (0x200b, 0x200f),
        (0x20d0, 0x20f0),
        (0xfe00, 0xfe0f),
        (0xfeff, 0xfeff),
    ];

    let mut index = 0;

    while index < ZERO.len() {
        if code >= ZERO[index].0 && code <= ZERO[index].1 {
            return 0;
        }

        index += 1;
    }

    let mut held = 0;

    while held < WIDE.len() {
        if code >= WIDE[held].0 && code <= WIDE[held].1 {
            return 2;
        }

        held += 1;
    }

    1
}

fn columns_of(bytes: &[u8]) -> (u32, u32, bool) {
    let mut broken = false;
    let mut held = 0;
    let mut leading = 0;
    let mut width = 0;

    while held < bytes.len() {
        if bytes[held] == b'\n' {
            if !broken {
                leading = width;
            }

            broken = true;
            width = 0;
            held += 1;

            continue;
        }

        let (code, step) = decoded(bytes, held);

        width += code_width(code);
        held += step;
    }

    if broken {
        return (leading, width, true);
    }

    (width, width, false)
}

struct Measure<'held> {
    arena: &'held [u8],
    document: &'held Document,
    source: &'held [u8],
}

impl Measure<'_> {
    fn columns(&self, element: Element) -> (u32, u32, bool) {
        let (held, span) = match element {
            Element::IfBroken(span) => (Source::Literal, span),
            Element::Joined(span) | Element::VerbatimArena(span) => (Source::Arena, span),
            Element::Text(held, span) => (held, span),
            Element::Verbatim(span) => (Source::Document, span),
            _ => return (0, 0, false),
        };

        let bytes = bytes_of(self.document, self.source, self.arena, held, span);

        if bytes.starts_with(b"# type:") {
            return (0, 0, false);
        }

        if LINE_SUFFIXES && self.document.suffixed() && bytes.starts_with(b"//") {
            return (0, 0, false);
        }

        columns_of(bytes)
    }
}

fn bytes_of<'held>(
    document: &'held Document,
    source: &'held [u8],
    arena: &'held [u8],
    held: Source,
    span: Span,
) -> &'held [u8] {
    match held {
        Source::Arena => {
            assert!(span.end() as usize <= arena.len());

            &arena[span.range()]
        }
        Source::Document => {
            assert!(span.end() as usize <= source.len());

            &source[span.range()]
        }
        Source::Literal => {
            let bytes = document.literal_of(span.offset);

            assert_eq!(span.length, count_of(bytes.len()));

            bytes
        }
    }
}

fn trailing(held: &Measure<'_>, element: Element, blank: bool) -> Option<u32> {
    match element {
        Element::BlankLine(_)
        | Element::HardLine
        | Element::Line
        | Element::Pragma
        | Element::SoftLine => None,
        Element::Space => Some(u32::from(!blank)),
        Element::Hugging(_) => Some(0),
        Element::IfBroken(_)
        | Element::Joined(_)
        | Element::Text(..)
        | Element::Verbatim(_)
        | Element::VerbatimArena(_) => Some(held.columns(element).0),
        Element::Choice(_) | Element::ChoiceClose | Element::Variant => None,
        Element::Dedent
        | Element::GroupClose
        | Element::GroupOpen
        | Element::Indent
        | Element::Align
        | Element::Dealign
        | Element::DedentBroken
        | Element::Filled
        | Element::Hugged
        | Element::Hugs
        | Element::IndentBroken
        | Element::Wide => Some(0),
    }
}

fn fill_width(held: &Measure<'_>, start: u32, budget: u32) -> u32 {
    let elements = held.document.elements();
    let count = count_of(elements.len());
    let mut depth = 0_u32;
    let mut index = start;
    let mut width = 0;

    while index < count {
        let element = elements[index as usize];

        index += 1;

        match element {
            Element::GroupOpen => depth += 1,
            Element::GroupClose => {
                if depth == 0 {
                    if let Some(Element::IfBroken(span)) = elements.get(index as usize) {
                        width += held.columns(Element::IfBroken(*span)).0;
                    }

                    return width;
                }

                depth -= 1;
            }
            Element::BlankLine(_) | Element::HardLine | Element::Line | Element::SoftLine => {
                if depth == 0 {
                    return width;
                }

                return budget + 1;
            }
            _ => (),
        }

        let (columns, _, spans) = held.columns(element);

        if spans {
            return budget + 1;
        }

        width += columns;

        if width > budget {
            return width;
        }
    }

    width
}

fn choice_end(elements: &[Element], start: u32) -> u32 {
    let count = count_of(elements.len());
    let mut depth = 0;
    let mut index = start;

    while index < count {
        let element = elements[index as usize];

        index += 1;

        if matches!(element, Element::Choice(_)) {
            depth += 1;
        }

        if element == Element::ChoiceClose {
            if depth == 0 {
                return index;
            }

            depth -= 1;
        }
    }

    index
}

fn group_end(elements: &[Element], start: u32) -> u32 {
    let count = count_of(elements.len());
    let mut depth = 0;
    let mut index = start;

    while index < count {
        let element = elements[index as usize];

        index += 1;

        if element == Element::GroupOpen {
            depth += 1;
        }

        if element == Element::GroupClose {
            if depth == 0 {
                return index;
            }

            depth -= 1;
        }
    }

    index
}

fn opener_width(elements: &[Element], start: u32) -> u32 {
    match elements.get(start as usize) {
        Some(Element::Text(_, span) | Element::Verbatim(span) | Element::VerbatimArena(span)) => {
            span.length
        }
        _ => 0,
    }
}

fn hugged(elements: &[Element], start: u32) -> Option<u32> {
    let count = count_of(elements.len());
    let mut depth = 0_u32;
    let mut index = start + 1;

    while index < count {
        let element = elements[index as usize];

        if element == Element::GroupOpen {
            depth += 1;
        }

        if element == Element::GroupClose {
            if depth == 0 {
                return None;
            }

            depth -= 1;
        }

        if depth == 0 && matches!(element, Element::Hugged | Element::Hugs) {
            return Some(index);
        }

        index += 1;
    }

    None
}

fn prefix_width(held: &Measure<'_>, from: u32, to: u32, budget: u32, owed: bool) -> Option<u32> {
    let elements = held.document.elements();
    let mut blank = owed;
    let mut index = from;
    let mut width = 0;

    while index < to {
        let element = elements[index as usize];
        let spacing = matches!(element, Element::Line | Element::Space);
        let before = width;

        index += 1;

        match element {
            Element::Choice(_) | Element::ChoiceClose => (),
            Element::Variant => index = choice_end(elements, index),
            Element::BlankLine(_) | Element::HardLine => return None,
            Element::Joined(_) => {
                width += held.columns(element).0;
                index = group_end(elements, index).min(to);
            }
            Element::Line | Element::Space => width += u32::from(!blank),
            Element::Text(..) | Element::Verbatim(_) | Element::VerbatimArena(_) => {
                let (leading, _, broken) = held.columns(element);

                if broken {
                    return None;
                }

                width += leading;
            }
            Element::Dedent
            | Element::Align
            | Element::Dealign
            | Element::DedentBroken
            | Element::Filled
            | Element::GroupClose
            | Element::GroupOpen
            | Element::Hugged
            | Element::Hugging(_)
            | Element::Hugs
            | Element::IfBroken(_)
            | Element::Indent
            | Element::IndentBroken
            | Element::SoftLine
            | Element::Pragma
            | Element::Wide => (),
        }

        if width > budget {
            return None;
        }

        if spacing || width > before {
            blank = spacing;
        }
    }

    Some(width)
}

fn hug_width(held: &Measure<'_>, start: u32, budget: u32, blank: bool) -> (Width, bool) {
    if let width @ Width::Flat(_) = width_of(held, start, budget, blank) {
        return (width, false);
    }

    let elements = held.document.elements();

    let Some(hug) = hugged(elements, start) else {
        return (Width::Broken, false);
    };

    match prefix_width(held, start + 1, hug, budget, blank) {
        Some(width) => (Width::Flat(width), true),
        None => (Width::Broken, false),
    }
}

fn wide_width(held: &Measure<'_>, start: u32, budget: u32) -> Width {
    let elements = held.document.elements();

    let Some(width) = body_width(held, elements, start, budget) else {
        return Width::Broken;
    };

    spanning(
        held,
        group_end(elements, start + 1),
        budget,
        width,
        Held::Wide,
    )
}

fn body_width(held: &Measure<'_>, elements: &[Element], start: u32, budget: u32) -> Option<u32> {
    let count = count_of(elements.len());
    let mut blank = false;
    let mut depth = 0;
    let mut index = start;
    let mut width = 0;

    while index < count && width <= budget {
        let element = elements[index as usize];
        let spacing = matches!(element, Element::Line | Element::Space);
        let before = width;

        index += 1;

        match element {
            Element::Choice(_) | Element::ChoiceClose => (),
            Element::Variant => index = choice_end(elements, index),
            Element::BlankLine(_) | Element::HardLine => return None,
            Element::GroupClose => {
                depth -= 1;

                if depth == 0 {
                    return Some(width);
                }
            }
            Element::GroupOpen => depth += 1,
            Element::Joined(_) => {
                width += held.columns(element).0;
                index = group_end(elements, index);
            }
            Element::Line | Element::Space => width += u32::from(!blank),
            Element::Text(..) | Element::Verbatim(_) | Element::VerbatimArena(_) => {
                let (leading, _, broken) = held.columns(element);

                if broken {
                    return None;
                }

                width += leading;
            }
            Element::Dedent
            | Element::Align
            | Element::Dealign
            | Element::DedentBroken
            | Element::Filled
            | Element::Hugged
            | Element::Hugging(_)
            | Element::Hugs
            | Element::IfBroken(_)
            | Element::Indent
            | Element::IndentBroken
            | Element::SoftLine
            | Element::Pragma
            | Element::Wide => (),
        }

        if spacing || width > before {
            blank = spacing;
        }
    }

    None
}

fn joined_width(held: &Measure<'_>, start: u32, budget: u32, broken: bool) -> Width {
    let elements = held.document.elements();

    let Element::Joined(span) = elements[(start + 1) as usize] else {
        return Width::Broken;
    };

    let width = held.columns(Element::Joined(span)).0;
    let from = group_end(elements, start + 2);

    let Width::Flat(found) = spanning(held, from, budget, width, Held::Joined) else {
        return Width::Broken;
    };

    let owed = if broken {
        owed_width(elements, from)
    } else {
        0
    };

    if found + owed > budget {
        return Width::Broken;
    }

    Width::Flat(found + owed)
}

fn owed_width(elements: &[Element], from: u32) -> u32 {
    let count = count_of(elements.len());
    let mut index = from;

    while index < count {
        match elements[index as usize] {
            Element::Dedent | Element::DedentBroken | Element::GroupClose => index += 1,
            Element::IfBroken(span) => return span.length,
            _ => return 0,
        }
    }

    0
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum Held {
    Joined,
    Wide,
}

#[expect(
    clippy::too_many_lines,
    reason = "the walk names every element the document holds, and a shorter form would be a \
              table the compiler cannot check"
)]
fn spanning(held: &Measure<'_>, from: u32, budget: u32, mut width: u32, kind: Held) -> Width {
    let mut glued = kind == Held::Joined;
    let elements = held.document.elements();
    let count = count_of(elements.len());
    let mut blank = false;
    let mut depth = 0;
    let mut index = from;

    while index < count && width <= budget {
        let element = elements[index as usize];
        let spacing = matches!(element, Element::Line | Element::Space);
        let before = width;

        index += 1;

        match element {
            Element::Choice(_) | Element::ChoiceClose => (),
            Element::Variant => index = choice_end(elements, index),
            Element::BlankLine(_) | Element::HardLine => {
                if depth > 0 {
                    return Width::Broken;
                }

                return Width::Flat(width);
            }
            Element::GroupClose => {
                if depth == 0 {
                    return Width::Flat(width);
                }

                depth -= 1;
            }
            Element::GroupOpen => {
                let opener = opener_width(elements, index);

                if depth == 0 && glued && opener > 0 {
                    width += opener;

                    break;
                }

                depth += 1;
            }
            Element::Joined(_) => {
                width += held.columns(element).0;
                index = group_end(elements, index);
            }
            Element::Pragma => return Width::Flat(width),
            Element::Line | Element::SoftLine => {
                if depth == 0 {
                    return Width::Flat(width);
                }

                glued = false;
                width += u32::from(element == Element::Line && !blank);
            }
            Element::Space => width += u32::from(!blank),
            Element::Text(..) | Element::Verbatim(_) | Element::VerbatimArena(_) => {
                let Some(found) = written(held, element, width, budget) else {
                    return Width::Broken;
                };

                width = found;
            }
            Element::Dedent
            | Element::Align
            | Element::Dealign
            | Element::DedentBroken
            | Element::Filled
            | Element::Hugged
            | Element::Hugging(_)
            | Element::Hugs
            | Element::IfBroken(_)
            | Element::Indent
            | Element::IndentBroken
            | Element::Wide => (),
        }

        if spacing || width > before {
            blank = spacing;
        }
    }

    if width > budget {
        return Width::Broken;
    }

    Width::Flat(width)
}

fn written(held: &Measure<'_>, element: Element, width: u32, budget: u32) -> Option<u32> {
    let (leading, trailing, broken) = held.columns(element);
    let found = width + leading;

    if !broken {
        return Some(found);
    }

    (found <= budget).then_some(trailing)
}

fn measured(
    held: &Measure<'_>,
    element: Element,
    blank: bool,
    depth: &mut u32,
    closed: &mut bool,
    skipping: &mut bool,
) -> Option<u32> {
    match element {
        Element::BlankLine(lines) => {
            if lines > 0 {
                return None;
            }

            Some(0)
        }
        Element::Choice(_) | Element::ChoiceClose | Element::Variant => Some(0),
        Element::Align
        | Element::Dealign
        | Element::Dedent
        | Element::Hugging(_)
        | Element::IfBroken(_)
        | Element::Indent
        | Element::SoftLine => Some(0),
        Element::GroupClose => {
            assert!(*depth > 0);

            *depth -= 1;
            *closed = *depth == 0;

            Some(0)
        }
        Element::GroupOpen => {
            assert!(*depth < GROUP_DEPTH_MAX);

            *depth += 1;

            Some(0)
        }
        Element::HardLine => None,
        Element::Joined(_) => {
            *skipping = true;

            Some(held.columns(element).0)
        }
        Element::Line | Element::Space => Some(u32::from(!blank)),
        Element::Text(..) | Element::Verbatim(_) | Element::VerbatimArena(_) => {
            Some(held.columns(element).0)
        }
        Element::DedentBroken
        | Element::Filled
        | Element::Hugged
        | Element::Hugs
        | Element::IndentBroken
        | Element::Pragma
        | Element::Wide => Some(0),
    }
}

fn skipped(
    element: Element,
    nested: &mut u32,
    skipping: &mut bool,
    depth: &mut u32,
    closed: &mut bool,
) {
    if element == Element::GroupOpen {
        *nested += 1;

        return;
    }

    if element != Element::GroupClose {
        return;
    }

    if *nested > 0 {
        *nested -= 1;

        return;
    }

    *skipping = false;
    *depth = depth.saturating_sub(1);
    *closed = *depth == 0;
}

fn fitting(held: &Measure<'_>, start: u32, count: u32, budget: u32, blank: bool) -> u32 {
    let elements = held.document.elements();
    let mut index = start + 1;

    for variant in 0..count {
        if variant + 1 == count {
            return variant;
        }

        if elements.get(index as usize) == Some(&Element::GroupOpen)
            && matches!(width_of(held, index, budget, blank), Width::Flat(_))
        {
            return variant;
        }

        index = group_end(elements, index + 1);

        if elements.get(index as usize) != Some(&Element::Variant) {
            return variant;
        }

        index += 1;
    }

    count.saturating_sub(1)
}

fn width_of(held: &Measure<'_>, start: u32, budget: u32, owed: bool) -> Width {
    let elements = held.document.elements();
    let count = count_of(elements.len());

    assert!(start < count);
    assert_eq!(elements[start as usize], Element::GroupOpen);

    let mut blank = owed;
    let mut closed = false;
    let mut depth = 0;
    let mut index = start;
    let mut nested = 0;
    let mut skipping = false;
    let mut width = 0;

    for _ in start..count {
        if index >= count {
            break;
        }

        let element = elements[index as usize];

        index += 1;

        if skipping {
            skipped(element, &mut nested, &mut skipping, &mut depth, &mut closed);

            continue;
        }

        if element == Element::Variant {
            index = choice_end(elements, index);

            continue;
        }

        let spacing = matches!(element, Element::Line | Element::Space);

        if closed {
            let Some(step) = trailing(held, element, blank) else {
                return Width::Flat(width);
            };

            skipping = matches!(element, Element::Joined(_));
            width += step;

            if spacing || step > 0 {
                blank = spacing;
            }

            if width > budget {
                return Width::Broken;
            }

            continue;
        }

        if held.columns(element).2 {
            return Width::Broken;
        }

        let Some(step) = measured(held, element, blank, &mut depth, &mut closed, &mut skipping)
        else {
            return Width::Broken;
        };

        width += step;

        if spacing || step > 0 {
            blank = spacing;
        }

        if width > budget {
            return Width::Broken;
        }

        if index == count {
            break;
        }
    }

    if closed {
        return Width::Flat(width);
    }

    Width::Broken
}

#[must_use]
pub fn print(
    document: &Document,
    source: &[u8],
    arena: &[u8],
    options: Options,
    out: &mut Buffer,
) -> bool {
    printing(document, source, arena, options, out, None)
}

pub fn printing(
    document: &Document,
    source: &[u8],
    arena: &[u8],
    options: Options,
    out: &mut Buffer,
    mut lines: Option<&mut BoundedVec<u32>>,
) -> bool {
    assert!(options.indent_width > 0);
    assert!(options.line_width > 0);

    document.close();
    out.clear();

    if let Some(held) = lines.as_deref_mut() {
        held.clear();
    }

    let count = count_of(document.elements().len());
    let mut held = 0_u32;
    let mut state = State::new();

    for index in 0..count {
        let element = document.elements()[index as usize];
        let before = out.count();

        if !step(&mut state, document, source, arena, options, out, index) {
            out.clear();

            return false;
        }

        let Some(mapped) = lines.as_deref_mut() else {
            continue;
        };

        if let Element::Text(Source::Document, span) | Element::Verbatim(span) = element {
            held = span.offset;
        }

        for byte in &out.as_bytes()[before as usize..] {
            if *byte == b'\n' && !mapped.push(held) {
                out.clear();

                return false;
            }
        }
    }

    assert_eq!(state.choices, 0);
    assert_eq!(state.depth, 0);
    assert_eq!(state.printer.indent, 0);

    debug_assert!(
        line_ends_clean(out, state.printer.verbatim),
        "a printed line ends in whitespace"
    );

    true
}

fn line_ends_clean(out: &Buffer, verbatim: bool) -> bool {
    if verbatim {
        return true;
    }

    let bytes = out.as_bytes();

    let start = bytes
        .iter()
        .rposition(|byte| *byte == b'\n')
        .map_or(0, |at| at + 1);

    !matches!(bytes[start..].last(), Some(b' ' | b'\t'))
}

fn step(
    state: &mut State,
    document: &Document,
    source: &[u8],
    arena: &[u8],
    options: Options,
    out: &mut Buffer,
    index: u32,
) -> bool {
    let element = document.elements()[index as usize];

    if state.skipped(element) {
        return true;
    }

    if state.losses(element) {
        return true;
    }

    if let Some(held) = chosen(state, document, source, arena, options, index, element) {
        return held;
    }

    match element {
        Element::BlankLine(lines) => blank(&mut state.printer, out, lines),
        Element::Choice(_) | Element::ChoiceClose | Element::Variant => true,
        Element::Dedent => state.dedent(),
        Element::GroupClose => state.close(),
        Element::GroupOpen => state.open(
            &Measure {
                arena,
                document,
                source,
            },
            options,
            index,
        ),
        Element::HardLine => state.printer.newline(out),
        Element::Hugging(span) => hugs(state, document, source, arena, options, out, span),
        Element::IfBroken(span) => {
            if !state.broken() {
                return true;
            }

            let bytes = bytes_of(document, source, arena, Source::Literal, span);

            state.printer.text(out, bytes, options)
        }
        Element::Align => state.aligns(),
        Element::Dealign => state.aligned(),
        Element::Indent => state.indent(),
        Element::IndentBroken => state.owe(),
        Element::DedentBroken => state.owed(),
        Element::Filled | Element::Pragma | Element::Wide => true,
        Element::Hugged => {
            state.hugged = state.hugs[state.depth as usize];

            true
        }
        Element::Hugs => true,
        Element::Joined(span) => joins(state, document, source, arena, options, out, span),
        Element::Line => state.line(
            &Measure {
                arena,
                document,
                source,
            },
            options,
            out,
            index,
        ),
        Element::SoftLine => state.soft(out),
        Element::Space => state.space(),
        Element::Text(held, span) => {
            let bytes = bytes_of(document, source, arena, held, span);

            state.printer.text(out, bytes, options)
        }
        Element::Verbatim(span) => {
            let bytes = bytes_of(document, source, arena, Source::Document, span);

            state.printer.verbatim(out, bytes, options)
        }
        Element::VerbatimArena(span) => {
            let bytes = bytes_of(document, source, arena, Source::Arena, span);

            state.printer.verbatim(out, bytes, options)
        }
    }
}

fn chosen(
    state: &mut State,
    document: &Document,
    source: &[u8],
    arena: &[u8],
    options: Options,
    index: u32,
    element: Element,
) -> Option<bool> {
    let held = Measure {
        arena,
        document,
        source,
    };

    match element {
        Element::Choice(count) => Some(state.chose(&held, options, index, count)),
        Element::ChoiceClose => Some(state.chosen()),
        Element::Variant => Some(state.variant()),
        _ => None,
    }
}

fn hugs(
    state: &mut State,
    document: &Document,
    source: &[u8],
    arena: &[u8],
    options: Options,
    out: &mut Buffer,
    span: Span,
) -> bool {
    if !state.marked() {
        return true;
    }

    let bytes = bytes_of(document, source, arena, Source::Literal, span);

    state.printer.text(out, bytes, options) && state.printer.newline(out)
}

fn joins(
    state: &mut State,
    document: &Document,
    source: &[u8],
    arena: &[u8],
    options: Options,
    out: &mut Buffer,
    span: Span,
) -> bool {
    if state.broken() {
        return true;
    }

    state.skipping = true;
    state.nested = 0;

    let bytes = bytes_of(document, source, arena, Source::Arena, span);

    state.printer.text(out, bytes, options)
}

fn blank(printer: &mut Printer, out: &mut Buffer, lines: u32) -> bool {
    if lines == 0 {
        return true;
    }

    if !printer.line_start && !printer.newline(out) {
        return false;
    }

    for _ in 0..lines {
        if !printer.newline(out) {
            return false;
        }
    }

    true
}

#[cfg(test)]
mod tests {
    use super::*;

    const SOURCE: &[u8] = b"alpha bravo charlie delta echo foxtrot golf hotel india juliet";

    struct Built {
        document: Document,
    }

    impl Built {
        fn new() -> Self {
            Self {
                document: Document::reserve(1 << 8, 1 << 4),
            }
        }

        fn push(&mut self, element: Element) -> &mut Self {
            assert!(self.document.push(element));

            self
        }

        fn word(&mut self, offset: u32, length: u32) -> &mut Self {
            self.push(Element::Text(Source::Document, Span { length, offset }))
        }
    }

    fn options(line_width: u32) -> Options {
        Options {
            line_width,
            ..Options::DEFAULT
        }
    }

    fn printed(built: &Built, line_width: u32) -> Vec<u8> {
        let mut out = Buffer::reserve(1 << 12);

        assert!(print(
            &built.document,
            SOURCE,
            &[],
            options(line_width),
            &mut out
        ));

        out.as_bytes().to_vec()
    }

    fn grouped() -> Built {
        let mut built = Built::new();

        built.push(Element::GroupOpen);
        let _ = built.word(0, 5);
        built.push(Element::Line);
        let _ = built.word(6, 5);
        built.push(Element::Line);
        let _ = built.word(12, 7);
        built.push(Element::GroupClose);

        built
    }

    #[test]
    fn a_group_that_fits_prints_flat_and_a_narrow_one_breaks() {
        let built = grouped();

        assert_eq!(printed(&built, 80), b"alpha bravo charlie");
        assert_eq!(printed(&built, 8), b"alpha\nbravo\ncharlie");
    }

    #[test]
    fn a_hard_line_breaks_its_group_at_any_width() {
        let mut built = Built::new();

        built.push(Element::GroupOpen);
        let _ = built.word(0, 5);
        built.push(Element::HardLine);
        let _ = built.word(6, 5);
        built.push(Element::Line);
        let _ = built.word(12, 7);
        built.push(Element::GroupClose);

        assert_eq!(printed(&built, 1 << 10), b"alpha\nbravo\ncharlie");
    }

    #[test]
    fn a_nested_group_breaks_outermost_first() {
        let mut built = Built::new();

        built.push(Element::GroupOpen);
        let _ = built.word(0, 5);
        built.push(Element::Line);
        built.push(Element::GroupOpen);
        let _ = built.word(6, 5);
        built.push(Element::Line);
        let _ = built.word(12, 7);
        built.push(Element::GroupClose);
        built.push(Element::GroupClose);

        assert_eq!(printed(&built, 80), b"alpha bravo charlie");
        assert_eq!(printed(&built, 16), b"alpha\nbravo charlie");
        assert_eq!(printed(&built, 8), b"alpha\nbravo\ncharlie");
    }

    #[test]
    fn an_if_broken_element_prints_only_in_the_broken_state() {
        let mut built = Built::new();
        let comma = built.document.literal(b",");
        let span = built.document.literal_span(comma);

        built.push(Element::GroupOpen);
        let _ = built.word(0, 5);
        built.push(Element::IfBroken(span));
        built.push(Element::Line);
        let _ = built.word(6, 5);
        built.push(Element::IfBroken(span));
        built.push(Element::GroupClose);

        assert_eq!(printed(&built, 80), b"alpha bravo");
        assert_eq!(printed(&built, 4), b"alpha,\nbravo,");
    }

    #[test]
    fn an_indent_changes_the_next_line_and_nothing_else() {
        let mut built = Built::new();

        let _ = built.word(0, 5);
        built.push(Element::Indent);
        built.push(Element::HardLine);
        let _ = built.word(6, 5);
        built.push(Element::Indent);
        built.push(Element::HardLine);
        let _ = built.word(12, 7);
        built.push(Element::Dedent);
        built.push(Element::Dedent);
        built.push(Element::HardLine);
        let _ = built.word(20, 5);

        assert_eq!(
            printed(&built, 80),
            b"alpha\n    bravo\n        charlie\ndelta"
        );
    }

    #[test]
    fn an_indent_of_tabs_writes_one_tab_a_level() {
        let mut built = Built::new();
        let mut out = Buffer::reserve(1 << 8);

        let _ = built.word(0, 5);
        built.push(Element::Indent);
        built.push(Element::HardLine);
        let _ = built.word(6, 5);
        built.push(Element::Dedent);

        let held = Options {
            tabs: true,
            ..Options::DEFAULT
        };

        assert!(print(&built.document, SOURCE, &[], held, &mut out));
        assert_eq!(out.as_bytes(), b"alpha\n\tbravo");
    }

    #[test]
    fn a_blank_line_emits_exactly_its_count() {
        for lines in 0..3_u32 {
            let mut built = Built::new();

            let _ = built.word(0, 5);
            built.push(Element::HardLine);
            built.push(Element::BlankLine(lines));
            let _ = built.word(6, 5);

            let mut expected = b"alpha\n".to_vec();

            expected.extend(core::iter::repeat_n(b'\n', lines as usize));
            expected.extend_from_slice(b"bravo");

            assert_eq!(printed(&built, 80), expected, "over {lines} blank lines");
        }
    }

    #[test]
    fn a_verbatim_element_keeps_every_byte_it_holds() {
        let held: &[u8] = b"x = '''\n    a  \n\tb\n'''";
        let mut built = Built::new();
        let mut out = Buffer::reserve(1 << 8);

        built.push(Element::Indent);

        built.push(Element::Verbatim(Span {
            length: count_of(held.len()),
            offset: 0,
        }));

        built.push(Element::HardLine);
        built.push(Element::Dedent);

        assert!(print(
            &built.document,
            held,
            &[],
            Options::DEFAULT,
            &mut out
        ));

        assert_eq!(out.as_bytes(), b"    x = '''\n    a  \n\tb\n'''\n");
    }

    #[test]
    fn a_verbatim_element_resets_the_column_from_its_last_break() {
        let held: &[u8] = b"aaaa\nbb";
        let mut built = Built::new();
        let mut out = Buffer::reserve(1 << 8);

        built.push(Element::Verbatim(Span {
            length: count_of(held.len()),
            offset: 0,
        }));

        built.push(Element::GroupOpen);
        built.push(Element::Line);

        built.push(Element::Text(
            Source::Document,
            Span {
                length: 4,
                offset: 0,
            },
        ));

        built.push(Element::GroupClose);

        assert!(print(&built.document, held, &[], options(8), &mut out));
        assert_eq!(out.as_bytes(), b"aaaa\nbb aaaa");
    }

    #[test]
    fn an_arena_text_element_reads_the_arena() {
        let arena: &[u8] = b"rendered";
        let mut built = Built::new();
        let mut out = Buffer::reserve(1 << 8);

        built.push(Element::Text(
            Source::Arena,
            Span {
                length: 8,
                offset: 0,
            },
        ));

        assert!(print(
            &built.document,
            SOURCE,
            arena,
            Options::DEFAULT,
            &mut out
        ));

        assert_eq!(out.as_bytes(), b"rendered");
    }

    #[test]
    fn an_output_overflow_clears_the_target() {
        let built = grouped();
        let mut out = Buffer::reserve(4);

        assert!(!print(
            &built.document,
            SOURCE,
            &[],
            Options::DEFAULT,
            &mut out
        ));

        assert!(out.is_empty());
    }

    #[test]
    fn a_space_before_a_break_is_never_written() {
        let mut built = Built::new();

        let _ = built.word(0, 5);
        built.push(Element::Space);
        built.push(Element::HardLine);
        built.push(Element::Space);
        let _ = built.word(6, 5);

        assert_eq!(printed(&built, 80), b"alpha\nbravo");
    }

    fn choice(width: u32, first: u32, second: u32) -> Vec<u8> {
        let mut built = Built::new();

        built
            .push(Element::Choice(2))
            .push(Element::GroupOpen)
            .word(0, first)
            .push(Element::GroupClose)
            .push(Element::Variant)
            .push(Element::GroupOpen)
            .word(0, second)
            .push(Element::HardLine)
            .word(6, 5)
            .push(Element::GroupClose)
            .push(Element::ChoiceClose);

        printed(&built, width)
    }

    #[test]
    fn a_choice_takes_the_first_variant_that_fits_flat() {
        assert_eq!(choice(40, 5, 5), b"alpha".to_vec());
    }

    #[test]
    fn a_choice_takes_the_last_variant_when_none_of_them_fits() {
        assert_eq!(choice(3, 5, 5), b"alpha\nbravo".to_vec());
    }

    #[test]
    fn a_choice_reads_a_forced_break_in_a_variant_as_one_that_does_not_fit() {
        let mut built = Built::new();

        built
            .push(Element::Choice(2))
            .push(Element::GroupOpen)
            .word(0, 5)
            .push(Element::HardLine)
            .word(6, 5)
            .push(Element::GroupClose)
            .push(Element::Variant)
            .push(Element::GroupOpen)
            .word(12, 7)
            .push(Element::GroupClose)
            .push(Element::ChoiceClose);

        assert_eq!(printed(&built, 80), b"charlie".to_vec());
    }

    #[test]
    fn a_choice_nested_in_a_losing_variant_is_never_printed() {
        let mut built = Built::new();

        built
            .push(Element::Choice(2))
            .push(Element::GroupOpen)
            .push(Element::Choice(2))
            .push(Element::GroupOpen)
            .word(0, 5)
            .push(Element::HardLine)
            .word(6, 5)
            .push(Element::GroupClose)
            .push(Element::Variant)
            .push(Element::GroupOpen)
            .word(6, 5)
            .push(Element::HardLine)
            .word(0, 5)
            .push(Element::GroupClose)
            .push(Element::ChoiceClose)
            .push(Element::GroupClose)
            .push(Element::Variant)
            .push(Element::GroupOpen)
            .word(12, 7)
            .push(Element::GroupClose)
            .push(Element::ChoiceClose);

        assert_eq!(printed(&built, 80), b"charlie".to_vec());
    }

    #[test]
    fn a_choice_the_line_is_too_narrow_for_still_prints_its_last_variant_whole() {
        let mut built = Built::new();

        built
            .push(Element::Choice(3))
            .push(Element::GroupOpen)
            .word(0, 5)
            .push(Element::Space)
            .word(6, 5)
            .push(Element::GroupClose)
            .push(Element::Variant)
            .push(Element::GroupOpen)
            .word(0, 5)
            .push(Element::GroupClose)
            .push(Element::Variant)
            .push(Element::GroupOpen)
            .word(12, 7)
            .push(Element::GroupClose)
            .push(Element::ChoiceClose);

        assert_eq!(printed(&built, 80), b"alpha bravo".to_vec());
        assert_eq!(printed(&built, 8), b"alpha".to_vec());
        assert_eq!(printed(&built, 4), b"charlie".to_vec());
    }
}
