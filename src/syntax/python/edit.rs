use crate::bounded::{Span, count_of};
use crate::lines;
use crate::syntax::python::kind::PythonKind;
use crate::token::Token;
use crate::tree::{NONE, Tree};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Deletion {
    Remove(Span),
    Replace(Span),
}

pub fn statement_deletion(
    source: &[u8],
    tokens: &[Token],
    tree: &Tree<PythonKind>,
    statement: u32,
    index: &lines::Index,
) -> Deletion {
    assert!(statement < tree.count());

    let held = tree.at(statement);
    let span = held.span(tokens);

    if is_only_statement(tree, statement) {
        return Deletion::Replace(span);
    }

    if let Some(after) = semicolon_after(source, span.end()) {
        let end = blanks_forward(source, after + 1);

        return Deletion::Remove(Span {
            length: end - span.offset,
            offset: span.offset,
        });
    }

    if has_leading_content(source, index, span.offset) {
        return Deletion::Remove(span);
    }

    Deletion::Remove(whole_lines_of(source, index, span))
}

pub fn alias_removal(
    source: &[u8],
    tokens: &[Token],
    tree: &Tree<PythonKind>,
    statement: u32,
    position: u32,
    index: &lines::Index,
) -> Deletion {
    assert!(statement < tree.count());

    let count = child_count(tree, statement, Some(PythonKind::Alias), 0);

    assert!(position < count);

    if count == 1 {
        return statement_deletion(source, tokens, tree, statement, index);
    }

    let spans = neighbour_spans(
        tree,
        tokens,
        statement,
        Some(PythonKind::Alias),
        0,
        position,
    );

    Deletion::Remove(gap_span(spans, position, count))
}

pub fn argument_removal(
    tokens: &[Token],
    tree: &Tree<PythonKind>,
    call: u32,
    position: u32,
) -> Span {
    assert!(call < tree.count());

    let count = child_count(tree, call, None, 1);

    assert!(position < count);

    let spans = neighbour_spans(tree, tokens, call, None, 1, position);

    gap_span(spans, position, count)
}

pub fn fits(
    source: &[u8],
    index: &lines::Index,
    span: Span,
    width: u32,
    line_width: u32,
    tab_width: u32,
) -> bool {
    assert!(tab_width > 0);
    assert!(span.end() as usize <= source.len());

    let first = index.line_of(span.offset);
    let last = index.line_of(span.end().saturating_sub(u32::from(span.length > 0)));
    let start = index.line_start(first) as usize;
    let end = line_end_of(source, index, last) as usize;
    let head = columns_of(&source[start..span.offset as usize], tab_width);
    let tail = columns_of(without_ending(&source[span.end() as usize..end]), tab_width);

    head + width + tail <= line_width
}

pub fn padding(source: &[u8], span: Span, replacement: &[u8]) -> (bool, bool) {
    assert!(span.end() as usize <= source.len());

    let before = span.offset > 0
        && is_word(source[span.offset as usize - 1])
        && replacement.first().copied().is_some_and(is_word);

    let after = (span.end() as usize) < source.len()
        && is_word(source[span.end() as usize])
        && replacement.last().copied().is_some_and(is_word);

    (before, after)
}

fn is_only_statement(tree: &Tree<PythonKind>, statement: u32) -> bool {
    let parent = tree.at(statement).parent;

    if parent == NONE || tree.at(parent).kind != PythonKind::Block {
        return false;
    }

    child_count(tree, parent, None, 0) == 1
}

fn has_leading_content(source: &[u8], index: &lines::Index, offset: u32) -> bool {
    let start = index.line_start(index.line_of(offset));

    assert!(start <= offset);

    !is_blank(&source[start as usize..offset as usize])
}

fn whole_lines_of(source: &[u8], index: &lines::Index, span: Span) -> Span {
    let first = index.line_of(span.offset);
    let start = index.line_start(first);
    let last = index.line_of(span.end().saturating_sub(u32::from(span.length > 0)));
    let end = line_end_of(source, index, last);

    assert!(start <= span.offset);
    assert!(span.end() <= end);

    Span {
        length: end - start,
        offset: start,
    }
}

fn line_end_of(source: &[u8], index: &lines::Index, line: u32) -> u32 {
    if line + 1 < index.count() {
        return index.line_start(line + 1);
    }

    count_of(source.len())
}

fn semicolon_after(source: &[u8], offset: u32) -> Option<u32> {
    let end = blanks_forward(source, offset);

    if (end as usize) < source.len() && source[end as usize] == b';' {
        return Some(end);
    }

    None
}

fn blanks_forward(source: &[u8], offset: u32) -> u32 {
    let mut end = (offset as usize).min(source.len());

    while end < source.len() && matches!(source[end], b'\t' | b' ') {
        end += 1;
    }

    count_of(end)
}

fn is_blank(bytes: &[u8]) -> bool {
    bytes.iter().all(|byte| matches!(*byte, b'\t' | b' '))
}

const fn is_word(byte: u8) -> bool {
    byte.is_ascii_alphanumeric() || byte == b'_' || byte >= 0x80
}

fn without_ending(bytes: &[u8]) -> &[u8] {
    let mut end = bytes.len();

    while end > 0 && matches!(bytes[end - 1], b'\n' | b'\r') {
        end -= 1;
    }

    &bytes[..end]
}

fn columns_of(bytes: &[u8], tab_width: u32) -> u32 {
    let mut found = 0;

    for byte in bytes {
        found += if *byte == b'\t' { tab_width } else { 1 };
    }

    found
}

type Neighbours = (Span, Span, Span);

fn neighbour_spans(
    tree: &Tree<PythonKind>,
    tokens: &[Token],
    node: u32,
    kind: Option<PythonKind>,
    skip: u32,
    position: u32,
) -> Neighbours {
    let mut previous = Span::EMPTY;
    let mut current = Span::EMPTY;
    let mut following = Span::EMPTY;
    let mut at = 0;
    let mut seen = 0;
    let mut child = tree.at(node).child_first;

    while child != NONE {
        let held = tree.at(child);

        if kind.is_none_or(|wanted| held.kind == wanted) {
            if seen >= skip {
                if at + 1 == position {
                    previous = held.span(tokens);
                }

                if at == position {
                    current = held.span(tokens);
                }

                if at == position + 1 {
                    following = held.span(tokens);
                }

                at += 1;
            }

            seen += 1;
        }

        child = held.sibling_next;
    }

    (previous, current, following)
}

fn child_count(tree: &Tree<PythonKind>, node: u32, kind: Option<PythonKind>, skip: u32) -> u32 {
    let mut found = 0_u32;
    let mut child = tree.at(node).child_first;

    while child != NONE {
        let held = tree.at(child);

        if kind.is_none_or(|wanted| held.kind == wanted) {
            found += 1;
        }

        child = held.sibling_next;
    }

    found.saturating_sub(skip)
}

fn gap_span(spans: Neighbours, position: u32, count: u32) -> Span {
    let (previous, current, following) = spans;

    if position + 1 < count {
        return Span {
            length: following.offset - current.offset,
            offset: current.offset,
        };
    }

    if position > 0 {
        return Span {
            length: current.end() - previous.end(),
            offset: previous.end(),
        };
    }

    current
}
