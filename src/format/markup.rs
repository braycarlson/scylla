use crate::bounded::{BoundedVec, Buffer, Bytes as _, Span, count_of};
use crate::format::ir::{Document, Element, Source as ElementSource};
use crate::format::print::{self, Options};
use crate::lines;
use crate::markup::blocks::BlockMap;
use crate::markup::kind::MarkupKind as Kind;
use crate::markup::token::Token;
use crate::markup::tree::{NONE, Step, Tree, walk};

pub const VERBATIM_ELEMENTS: [&[u8]; 4] = [b"pre", b"script", b"style", b"textarea"];
const CLOSERS: [&[u8]; 3] = [b"#}", b"%}", b"}}"];
const OPENERS: [&[u8]; 3] = [b"{#", b"{%", b"{{"];

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Outcome {
    Complete,
    Overflow,
    Refusal,
}

pub struct Input<'held> {
    pub index: &'held lines::Index,
    pub map: &'held BlockMap,
    pub options: Options,
    pub source: &'held [u8],
    pub tokens: &'held [Token],
    pub tree: &'held Tree,
}

#[derive(Debug)]
pub struct Layout {
    depths: BoundedVec<u32>,
    verbatim: BoundedVec<bool>,
}

#[derive(Debug)]
pub struct Formatter {
    document: Document,
    layout: Layout,
    scratch: Buffer,
}

impl Layout {
    fn reserve(line_count_max: u32) -> Self {
        assert!(line_count_max > 0);

        Self {
            depths: BoundedVec::reserve(line_count_max),
            verbatim: BoundedVec::reserve(line_count_max),
        }
    }

    fn build(&mut self, count: u32) -> bool {
        self.depths.clear();
        self.verbatim.clear();

        for _ in 0..count {
            if !self.depths.push(0) || !self.verbatim.push(false) {
                return false;
            }
        }

        self.depths.count() == count
    }

    fn claim(&mut self, line: u32, depth: u32) {
        let Some(held) = self.depths.get_mut(line as usize) else {
            return;
        };

        if *held != u32::MAX {
            return;
        }

        *held = depth;
    }

    fn depth_of(&self, line: u32) -> u32 {
        let held = self.depths.get(line as usize).copied().unwrap_or(0);

        if held == u32::MAX { 0 } else { held }
    }

    fn is_verbatim(&self, line: u32) -> bool {
        self.verbatim.get(line as usize).copied().unwrap_or(false)
    }

    fn mark(&mut self, first: u32, last: u32) {
        for line in first..=last {
            let Some(held) = self.verbatim.get_mut(line as usize) else {
                return;
            };

            *held = true;
        }
    }

    fn open(&mut self, count: u32) -> bool {
        if !self.build(count) {
            return false;
        }

        for line in 0..count {
            self.depths[line as usize] = u32::MAX;
        }

        true
    }
}

fn is_blank(bytes: &[u8]) -> bool {
    bytes.iter().all(u8::is_ascii_whitespace)
}

fn name_of<'source>(
    tree: &Tree,
    tokens: &[Token],
    source: &'source [u8],
    node: u32,
) -> &'source [u8] {
    let held = tree.at(node);
    let mut child = held.child_first;

    while child != NONE {
        let open = tree.at(child);

        if open.kind == Kind::OpenTag {
            for position in open.token_start..open.token_end {
                if tokens[position as usize].kind == Kind::ElementName {
                    return tokens[position as usize].text(source);
                }
            }
        }

        child = open.sibling_next;
    }

    &[]
}

fn opened_of(tree: &Tree, node: u32) -> (u32, u32) {
    let held = tree.at(node);
    let mut child = held.child_first;
    let mut close = NONE;
    let mut open = NONE;

    while child != NONE {
        let kind = tree.at(child).kind;

        if kind == Kind::OpenTag {
            open = child;
        }

        if kind == Kind::CloseTag {
            close = child;
        }

        child = tree.at(child).sibling_next;
    }

    (open, close)
}

fn tightened(bytes: &[u8], out: &mut Buffer) -> bool {
    let Some(open) = OPENERS.iter().find(|held| bytes.starts_with(held)) else {
        return out.push_bytes(bytes);
    };

    let Some(close) = CLOSERS.iter().find(|held| bytes.ends_with(held)) else {
        return out.push_bytes(bytes);
    };

    if bytes.len() < open.len() + close.len() {
        return out.push_bytes(bytes);
    }

    let body = &bytes[open.len()..bytes.len() - close.len()];

    if !out.push_bytes(open) {
        return false;
    }

    if body.iter().any(|byte| !byte.is_ascii_whitespace())
        && (!out.push_bytes(b" ") || !squeezed(body, out) || !out.push_bytes(b" "))
    {
        return false;
    }

    out.push_bytes(close)
}

fn squeezed(body: &[u8], out: &mut Buffer) -> bool {
    let mut quote = 0;
    let mut spaced = false;
    let mut written = false;

    for byte in body {
        if quote != 0 {
            if !out.push_bytes(&[*byte]) {
                return false;
            }

            if *byte == quote {
                quote = 0;
            }

            spaced = false;

            continue;
        }

        if byte.is_ascii_whitespace() {
            spaced = written;

            continue;
        }

        if spaced && !out.push_bytes(b" ") {
            return false;
        }

        if *byte == b'"' || *byte == b'\'' {
            quote = *byte;
        }

        if !out.push_bytes(&[*byte]) {
            return false;
        }

        spaced = false;
        written = true;
    }

    true
}

impl Formatter {
    pub fn reserve(element_count_max: u32, line_count_max: u32, scratch_bytes_max: u32) -> Self {
        assert!(element_count_max > 0);
        assert!(line_count_max > 0);
        assert!(scratch_bytes_max > 0);

        assert!(!crate::allocation::is_frozen());

        Self {
            document: Document::reserve(element_count_max, 4),
            layout: Layout::reserve(line_count_max),
            scratch: Buffer::reserve(scratch_bytes_max),
        }
    }

    pub fn document(&self) -> &Document {
        &self.document
    }

    #[must_use]
    pub fn format(&mut self, input: &Input<'_>, out: &mut Buffer) -> Outcome {
        if !input.tree.errors().is_empty() {
            return Outcome::Refusal;
        }

        self.document.clear();
        self.scratch.clear();

        if !self.normalize(input) {
            return Outcome::Overflow;
        }

        if !self.layout.open(input.index.count()) {
            return Outcome::Overflow;
        }

        depths(input, &mut self.layout);
        marks(input, &mut self.layout);

        if !emit(&self.scratch, &self.layout, &mut self.document) {
            return Outcome::Overflow;
        }

        if !print::print(
            &self.document,
            self.scratch.as_bytes(),
            &[],
            input.options,
            out,
        ) {
            return Outcome::Overflow;
        }

        Outcome::Complete
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

        span_of(out.as_bytes(), lines)
    }

    fn normalize(&mut self, input: &Input<'_>) -> bool {
        let mut cursor = 0;

        for node in input.tree.as_slice() {
            if !matches!(node.kind, Kind::TemplateTag | Kind::TemplateVariable) {
                continue;
            }

            let span = node.span(input.tokens);
            let bytes = &input.source[span.range()];

            if span.offset < cursor || bytes.contains(&b'\n') {
                continue;
            }

            if !self
                .scratch
                .push_bytes(&input.source[cursor as usize..span.offset as usize])
            {
                return false;
            }

            if !tightened(bytes, &mut self.scratch) {
                return false;
            }

            cursor = span.end();
        }

        self.scratch.push_bytes(&input.source[cursor as usize..])
    }
}

fn span_of(bytes: &[u8], lines: (u32, u32)) -> Option<Span> {
    let mut line = 0;
    let mut offset = 0;
    let mut start = None;
    let mut end = count_of(bytes.len());

    for position in 0..count_of(bytes.len()) {
        if line == lines.0 && start.is_none() {
            start = Some(offset);
        }

        if line == lines.1 + 1 {
            end = offset;

            break;
        }

        if bytes[position as usize] == b'\n' {
            line += 1;
            offset = position + 1;
        }
    }

    if line == lines.0 && start.is_none() {
        start = Some(offset);
    }

    let first = start?;

    assert!(end >= first);

    Some(Span {
        length: end - first,
        offset: first,
    })
}

fn depths(input: &Input<'_>, layout: &mut Layout) {
    let count = count_of(input.tokens.len());
    let mut cursor = 0;
    let mut depth = 0;

    for step in walk(input.tree) {
        match step {
            Step::Enter(node) => {
                let held = input.tree.at(node);

                claim(input, layout, &mut cursor, held.token_start, depth);

                depth = entered(input, node, depth);
            }
            Step::Leave(node) => {
                let held = input.tree.at(node);

                claim(input, layout, &mut cursor, held.token_end, depth);

                depth = left(input, node, depth);
            }
        }
    }

    claim(input, layout, &mut cursor, count, depth);
}

fn claim(input: &Input<'_>, layout: &mut Layout, cursor: &mut u32, stop: u32, depth: u32) {
    assert!(stop <= count_of(input.tokens.len()));

    while *cursor < stop {
        let token = input.tokens[*cursor as usize];

        *cursor += 1;

        if token.kind == Kind::Whitespace {
            continue;
        }

        let bytes = token.text(input.source);
        let mut offset = token.span().offset;

        for line in bytes.split_inclusive(|byte| *byte == b'\n') {
            if !is_blank(line) {
                let held = count_of(line.len() - line.trim_ascii_start().len());

                layout.claim(input.index.line_of(offset + held), depth);
            }

            offset += count_of(line.len());
        }
    }
}

fn entered(input: &Input<'_>, node: u32, depth: u32) -> u32 {
    let held = input.tree.at(node);

    if held.kind == Kind::CloseTag {
        return depth.saturating_sub(1);
    }

    if held.kind != Kind::TemplateTag {
        return depth;
    }

    let offset = held.span(input.tokens).offset;

    if closes(input, offset) || intermediates(input, offset) {
        return depth.saturating_sub(1);
    }

    depth
}

fn left(input: &Input<'_>, node: u32, depth: u32) -> u32 {
    let held = input.tree.at(node);

    if held.kind == Kind::OpenTag {
        if !paired(input, held.parent) {
            return depth;
        }

        return depth + 1;
    }

    if held.kind != Kind::TemplateTag {
        return depth;
    }

    let offset = held.span(input.tokens).offset;

    if opens(input, offset) || intermediates(input, offset) {
        return depth + 1;
    }

    depth
}

fn closes(input: &Input<'_>, offset: u32) -> bool {
    input
        .map
        .blocks()
        .iter()
        .any(|block| !block.close.is_none() && block.close.span.offset == offset)
}

fn intermediates(input: &Input<'_>, offset: u32) -> bool {
    input.map.blocks().iter().any(|block| {
        !block.close.is_none()
            && input
                .map
                .intermediates_of(block)
                .iter()
                .any(|held| held.span.offset == offset)
    })
}

fn opens(input: &Input<'_>, offset: u32) -> bool {
    input
        .map
        .blocks()
        .iter()
        .any(|block| !block.close.is_none() && block.open.span.offset == offset)
}

fn paired(input: &Input<'_>, element: u32) -> bool {
    if element == NONE || input.tree.at(element).kind != Kind::Element {
        return false;
    }

    let (_, close) = opened_of(input.tree, element);

    close != NONE
}

fn marks(input: &Input<'_>, layout: &mut Layout) {
    for (index, node) in input.tree.as_slice().iter().enumerate() {
        if node.kind == Kind::TemplateTag {
            for position in node.token_start..node.token_end {
                if input.tokens[position as usize].kind == Kind::VerbatimText {
                    mark(input, layout, input.tokens[position as usize].span());
                }
            }

            continue;
        }

        if node.kind != Kind::Element {
            continue;
        }

        let name = name_of(input.tree, input.tokens, input.source, count_of(index));

        if !VERBATIM_ELEMENTS
            .iter()
            .any(|held| held.eq_ignore_ascii_case(name))
        {
            continue;
        }

        let (open, close) = opened_of(input.tree, count_of(index));

        if open == NONE || close == NONE {
            continue;
        }

        let start = input.tree.at(open).span(input.tokens).end();
        let end = input.tree.at(close).span(input.tokens).offset;

        if end <= start {
            continue;
        }

        mark(
            input,
            layout,
            Span {
                length: end - start,
                offset: start,
            },
        );
    }
}

fn mark(input: &Input<'_>, layout: &mut Layout, span: Span) {
    if span.length == 0 {
        return;
    }

    let first = input.index.line_of(span.offset) + 1;
    let last = input.index.line_of(span.end());

    if last < first {
        return;
    }

    layout.mark(first, last);
}

fn emit(scratch: &Buffer, layout: &Layout, document: &mut Document) -> bool {
    let bytes = scratch.as_bytes();

    let Some(last) = last_of(bytes, layout) else {
        if bytes.is_empty() {
            return true;
        }

        return document.push(Element::HardLine);
    };

    let mut indent = 0;
    let mut line = 0;
    let mut offset = 0;

    for held in bytes.split(|byte| *byte == b'\n') {
        if line > last {
            break;
        }

        let span = Span {
            length: count_of(held.len()),
            offset,
        };

        offset += span.length + 1;
        line += 1;

        if !line_of(document, layout, bytes, (span, line - 1), &mut indent) {
            return false;
        }
    }

    level(document, &mut indent, 0)
}

fn line_of(
    document: &mut Document,
    layout: &Layout,
    bytes: &[u8],
    held: (Span, u32),
    indent: &mut u32,
) -> bool {
    let (span, line) = held;
    let text = &bytes[span.range()];
    let verbatim = layout.is_verbatim(line);

    let empty = if verbatim {
        text.is_empty()
    } else {
        is_blank(text)
    };

    if empty {
        return document.push(Element::HardLine);
    }

    let wanted = if verbatim { 0 } else { layout.depth_of(line) };

    if !level(document, indent, wanted) {
        return false;
    }

    let written = if verbatim {
        document.push(Element::Verbatim(span))
    } else {
        document.push(Element::Text(ElementSource::Document, trimmed(bytes, span)))
    };

    written && document.push(Element::HardLine)
}

fn last_of(bytes: &[u8], layout: &Layout) -> Option<u32> {
    let mut found = None;

    for (line, held) in bytes.split(|byte| *byte == b'\n').enumerate() {
        let empty = if layout.is_verbatim(count_of(line)) {
            held.is_empty()
        } else {
            is_blank(held)
        };

        if !empty {
            found = Some(count_of(line));
        }
    }

    found
}

fn level(document: &mut Document, indent: &mut u32, wanted: u32) -> bool {
    while *indent > wanted {
        if !document.push(Element::Dedent) {
            return false;
        }

        *indent -= 1;
    }

    while *indent < wanted {
        if !document.push(Element::Indent) {
            return false;
        }

        *indent += 1;
    }

    true
}

fn trimmed(bytes: &[u8], span: Span) -> Span {
    let held = &bytes[span.range()];
    let start = count_of(held.len() - held.trim_ascii_start().len());
    let length = count_of(held.trim_ascii().len());

    Span {
        length,
        offset: span.offset + start,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::markup::blocks::{self, TagSpecification};
    use crate::markup::tree::build;
    use crate::markup::{self, Tokens};

    const SPECIFICATIONS: &[TagSpecification] = &[TagSpecification {
        intermediates: &[b"elif", b"else"],
        name: b"if",
    }];

    const WORDS: &[&[u8]] = &[b"elif", b"else"];

    fn formatted(source: &[u8]) -> String {
        let mut formatter = Formatter::reserve(1 << 14, 1 << 10, 1 << 16);
        let mut index = lines::Index::reserve(1 << 10);
        let mut map = BlockMap::reserve(1 << 8);
        let mut out = Buffer::reserve(1 << 16);
        let mut tokens = Tokens::reserve(1 << 12);
        let mut tree = Tree::reserve(1 << 12, 1 << 6);

        assert!(index.build(source));

        markup::lex(source, &mut tokens);
        let _ = build(source, tokens.as_slice(), &mut tree);

        blocks::build(
            source,
            tokens.as_slice(),
            &tree,
            SPECIFICATIONS,
            WORDS,
            &mut map,
        );

        let input = Input {
            index: &index,
            map: &map,
            options: Options::DEFAULT,
            source,
            tokens: tokens.as_slice(),
            tree: &tree,
        };

        assert_eq!(formatter.format(&input, &mut out), Outcome::Complete);

        String::from_utf8_lossy(out.as_bytes()).into_owned()
    }

    #[test]
    fn an_element_indents_its_children() {
        assert_eq!(
            formatted(b"<div>\n<p>a</p>\n</div>\n"),
            "<div>\n    <p>a</p>\n</div>\n"
        );

        assert_eq!(formatted(b"<br>\n<hr>\n"), "<br>\n<hr>\n");
    }

    #[test]
    fn a_paired_template_tag_indents_its_body() {
        assert_eq!(
            formatted(b"{% if a %}\nx\n{% else %}\ny\n{% endif %}\n"),
            "{% if a %}\n    x\n{% else %}\n    y\n{% endif %}\n"
        );
    }

    #[test]
    fn a_single_line_tag_is_tightened() {
        assert_eq!(formatted(b"{{  a|title  }}\n"), "{{ a|title }}\n");

        assert_eq!(
            formatted(b"{%if  a%}\n{%endif%}\n"),
            "{% if a %}\n{% endif %}\n"
        );

        assert_eq!(formatted(b"{{}}\n"), "{{}}\n");

        assert_eq!(
            formatted(b"{% trans  \"a   b\"  %}\n"),
            "{% trans \"a   b\" %}\n"
        );
    }

    #[test]
    fn a_verbatim_body_keeps_every_byte() {
        assert_eq!(
            formatted(b"<div>\n<pre>\n  a  \n</pre>\n</div>\n"),
            "<div>\n    <pre>\n  a  \n</pre>\n</div>\n"
        );
    }

    #[test]
    fn a_trailing_blank_run_becomes_one_newline() {
        assert_eq!(formatted(b"<p>a</p>\n\n\n"), "<p>a</p>\n");
        assert_eq!(formatted(b"   \n\n"), "\n");
        assert_eq!(formatted(b""), "");
    }

    #[test]
    fn an_interior_blank_line_survives() {
        assert_eq!(
            formatted(b"<p>a</p>\n\n<p>b</p>\n"),
            "<p>a</p>\n\n<p>b</p>\n"
        );
    }
}
