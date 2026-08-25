use crate::bounded::{Buffer, Bytes as _, Span, count_of};
use crate::format::ir::{Document, Element, GROUP_DEPTH_MAX, INDENT_DEPTH_MAX, Source};

pub const INDENT_COLUMNS_MAX: u32 = 1 << 10;
const SPACES: [u8; 64] = [b' '; 64];

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Options {
    pub indent_width: u32,
    pub line_width: u32,
    pub tabs: bool,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum Width {
    Broken,
    Flat(u32),
}

#[derive(Debug)]
struct Printer {
    column: u32,
    indent: u32,
    line_start: bool,
    pending_space: bool,
    verbatim: bool,
}

#[derive(Debug)]
struct State {
    broken: [bool; GROUP_DEPTH_MAX as usize + 1],
    depth: u32,
    printer: Printer,
}

impl State {
    const fn new() -> Self {
        Self {
            broken: [true; GROUP_DEPTH_MAX as usize + 1],
            depth: 0,
            printer: Printer::new(),
        }
    }

    const fn broken(&self) -> bool {
        self.broken[self.depth as usize]
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

    fn line(&mut self, out: &mut Buffer) -> bool {
        if self.broken() {
            return self.printer.newline(out);
        }

        self.space()
    }

    fn open(&mut self, document: &Document, options: Options, index: u32) -> bool {
        assert!(self.depth < GROUP_DEPTH_MAX);

        let budget = options.line_width.saturating_sub(self.printer.column);
        let flat = !self.broken() || matches!(width_of(document, index, budget), Width::Flat(_));

        self.depth += 1;
        self.broken[self.depth as usize] = !flat;

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
            indent: 0,
            line_start: true,
            pending_space: false,
            verbatim: false,
        }
    }

    fn indentation(&mut self, out: &mut Buffer, options: Options) -> bool {
        if self.indent == 0 {
            return true;
        }

        if options.tabs {
            for _ in 0..self.indent {
                if !out.push_bytes(b"\t") {
                    return false;
                }
            }

            self.column = self.indent * options.indent_width;

            return true;
        }

        let width = self.indent * options.indent_width;

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

        self.column += count_of(bytes.len());
        self.line_start = false;

        true
    }

    fn verbatim(&mut self, out: &mut Buffer, bytes: &[u8], options: Options) -> bool {
        if !self.text(out, bytes, options) {
            return false;
        }

        self.verbatim = true;

        let mut offset = bytes.len();

        while offset > 0 {
            offset -= 1;

            if bytes[offset] != b'\n' {
                continue;
            }

            self.column = count_of(bytes.len() - offset - 1);
            self.line_start = offset + 1 == bytes.len();

            return true;
        }

        true
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

fn width_of(document: &Document, start: u32, budget: u32) -> Width {
    let elements = document.elements();
    let count = count_of(elements.len());

    assert!(start < count);
    assert_eq!(elements[start as usize], Element::GroupOpen);

    let mut depth = 0;
    let mut index = start;
    let mut width = 0;

    for _ in start..count {
        let element = elements[index as usize];

        index += 1;

        let held = match element {
            Element::BlankLine(lines) => {
                if lines > 0 {
                    return Width::Broken;
                }

                0
            }
            Element::Dedent | Element::IfBroken(_) | Element::Indent | Element::SoftLine => 0,
            Element::GroupClose => {
                assert!(depth > 0);

                depth -= 1;

                if depth == 0 {
                    return Width::Flat(width);
                }

                0
            }
            Element::GroupOpen => {
                assert!(depth < GROUP_DEPTH_MAX);

                depth += 1;

                0
            }
            Element::HardLine => return Width::Broken,
            Element::Line | Element::Space => 1,
            Element::Text(_, span) | Element::Verbatim(span) | Element::VerbatimArena(span) => {
                span.length
            }
        };

        width += held;

        if width > budget {
            return Width::Broken;
        }

        if index == count {
            break;
        }
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
    assert!(options.indent_width > 0);
    assert!(options.line_width > 0);

    document.close();
    out.clear();

    let count = count_of(document.elements().len());
    let mut state = State::new();

    for index in 0..count {
        if !step(&mut state, document, source, arena, options, out, index) {
            out.clear();

            return false;
        }
    }

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
    match document.elements()[index as usize] {
        Element::BlankLine(lines) => blank(&mut state.printer, out, lines),
        Element::Dedent => state.dedent(),
        Element::GroupClose => state.close(),
        Element::GroupOpen => state.open(document, options, index),
        Element::HardLine => state.printer.newline(out),
        Element::IfBroken(span) => {
            if !state.broken() {
                return true;
            }

            let bytes = bytes_of(document, source, arena, Source::Literal, span);

            state.printer.text(out, bytes, options)
        }
        Element::Indent => state.indent(),
        Element::Line => state.line(out),
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
}
