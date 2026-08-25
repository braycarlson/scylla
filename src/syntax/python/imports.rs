use core::cmp::Ordering;

use crate::bounded::{BoundedVec, Buffer, Bytes as _, Span, count_of};
use crate::lines;
use crate::syntax::python::kind::PythonKind;
use crate::syntax::python::semantic::Semantic;
use crate::syntax::python::stdlib;
use crate::syntax::python::style::Style;
use crate::token::{Punctuation, Token, TokenKind};
use crate::tree::{NONE, Tree};

pub const IMPORT_COUNT_MAX: u32 = 1 << 8;

#[derive(Clone, Copy)]
pub struct Parsed<'file> {
    pub index: &'file lines::Index,
    pub source: &'file [u8],
    pub tokens: &'file [Token],
    pub tree: &'file Tree<PythonKind>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Symbol {
    Bound(u32),
    Insert { leading: u32, offset: u32 },
}

#[expect(
    clippy::arbitrary_source_item_ordering,
    reason = "the derived `Ord` makes the declared order the section ladder isort sorts on"
)]
#[derive(Clone, Copy, Debug, Eq, Ord, PartialEq, PartialOrd)]
pub enum Section {
    Future,
    StandardLibrary,
    ThirdParty,
    FirstParty,
    LocalFolder,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Block {
    pub span: Span,
    pub statement_first: u32,
    pub statement_last: u32,
}

#[expect(
    clippy::arbitrary_source_item_ordering,
    reason = "the derived `Ord` makes the declared order the ladder `order-by-type` sorts on"
)]
#[derive(Clone, Copy, Debug, Eq, Ord, PartialEq, PartialOrd)]
enum MemberType {
    Constant,
    Class,
    Variable,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct Row {
    as_name: Span,
    from: bool,
    level: u32,
    module: Span,
    name: Span,
    section: Section,
    trailing_comma: bool,
}

pub fn insertion_point(
    tokens: &[Token],
    tree: &Tree<PythonKind>,
    index: &lines::Index,
) -> (u32, u32) {
    if tree.count() == 0 {
        return (0, 0);
    }

    let mut last_import = NONE;
    let mut child = tree.at(0).child_first;

    while child != NONE {
        let held = tree.at(child);
        let imports = matches!(held.kind, PythonKind::Import | PythonKind::ImportFrom);

        if !imports && (last_import != NONE || !is_docstring(tree, child)) {
            break;
        }

        if imports {
            last_import = child;
        }

        child = held.sibling_next;
    }

    if last_import != NONE {
        return (0, after_line_of(tree, tokens, index, last_import));
    }

    let first = tree.at(0).child_first;

    if first != NONE && is_docstring(tree, first) {
        return (1, after_line_of(tree, tokens, index, first));
    }

    (0, 0)
}

pub fn symbol_of(
    parsed: &Parsed<'_>,
    semantic: &Semantic,
    module: &[u8],
    member: &[u8],
    out: &mut BoundedVec<Span>,
) -> Symbol {
    out.clear();

    for binding in semantic.bindings_of(0) {
        let held = semantic.bindings()[binding as usize];

        if !held.kind.imports() {
            continue;
        }

        let Some(spans) = import_path_of(parsed, held.node, module, member) else {
            continue;
        };

        if !out.push(spans.0) || !out.push(spans.1) {
            out.clear();

            break;
        }

        return Symbol::Bound(binding);
    }

    let (leading, offset) = insertion_point(parsed.tokens, parsed.tree, parsed.index);

    Symbol::Insert { leading, offset }
}

pub fn blocks(
    tokens: &[Token],
    tree: &Tree<PythonKind>,
    index: &lines::Index,
    out: &mut BoundedVec<Block>,
) -> bool {
    out.clear();

    if tree.count() == 0 {
        return true;
    }

    let mut first = NONE;
    let mut last = NONE;
    let mut child = tree.at(0).child_first;

    while child != NONE {
        let held = tree.at(child);

        if matches!(held.kind, PythonKind::Import | PythonKind::ImportFrom) {
            if first == NONE {
                first = child;
            }

            last = child;
            child = held.sibling_next;

            continue;
        }

        if first != NONE && !push_block(tokens, tree, index, first, last, out) {
            return false;
        }

        first = NONE;
        child = held.sibling_next;
    }

    if first == NONE {
        return true;
    }

    push_block(tokens, tree, index, first, last, out)
}

pub fn sort(
    parsed: &Parsed<'_>,
    block: &Block,
    first_party: &[&[u8]],
    style: Style,
    line_width: u32,
    out: &mut Buffer,
) -> bool {
    assert!(line_width > 0);

    out.clear();

    if parsed.source[block.span.range()].contains(&b'#') {
        return false;
    }

    if shares_a_line(parsed, block) {
        return false;
    }

    let mut rows = [ROW_EMPTY; IMPORT_COUNT_MAX as usize];

    let Some(count) = collect_rows(parsed, block, first_party, &mut rows) else {
        return false;
    };

    rows[..count].sort_unstable_by(|left, right| order_of(parsed.source, left, right));

    let kept = deduplicated(parsed.source, &mut rows[..count]);

    render_rows(parsed.source, &rows[..kept], style, line_width, out)
}

const ROW_EMPTY: Row = Row {
    as_name: Span::EMPTY,
    from: false,
    level: 0,
    module: Span::EMPTY,
    name: Span::EMPTY,
    section: Section::ThirdParty,
    trailing_comma: false,
};

fn is_docstring(tree: &Tree<PythonKind>, node: u32) -> bool {
    if tree.at(node).kind != PythonKind::Expr {
        return false;
    }

    let child = tree.at(node).child_first;

    child != NONE && tree.at(child).kind == PythonKind::Constant
}

fn after_line_of(
    tree: &Tree<PythonKind>,
    tokens: &[Token],
    index: &lines::Index,
    node: u32,
) -> u32 {
    let span = tree.at(node).span(tokens);
    let line = index.line_of(span.end().saturating_sub(1));

    if line + 1 < index.count() {
        return index.line_start(line + 1);
    }

    span.end()
}

fn shares_a_line(parsed: &Parsed<'_>, block: &Block) -> bool {
    let first = parsed.tree.at(block.statement_first).span(parsed.tokens);
    let last = parsed.tree.at(block.statement_last).span(parsed.tokens);
    let line_start = parsed.index.line_start(parsed.index.line_of(first.offset));

    let line_end = after_line_of(
        parsed.tree,
        parsed.tokens,
        parsed.index,
        block.statement_last,
    );

    assert!(line_start <= first.offset);
    assert!(last.end() <= line_end);

    let head = &parsed.source[line_start as usize..first.offset as usize];
    let tail = &parsed.source[last.end() as usize..line_end as usize];

    !is_blank(head) || !is_blank(tail)
}

fn is_blank(bytes: &[u8]) -> bool {
    bytes
        .iter()
        .all(|byte| matches!(*byte, b'\t' | b'\n' | b'\r' | b' '))
}

fn import_path_of(
    parsed: &Parsed<'_>,
    alias: u32,
    module: &[u8],
    member: &[u8],
) -> Option<(Span, Span)> {
    let parent = parsed.tree.at(alias).parent;

    if parent == NONE {
        return None;
    }

    let path = path_of_alias(parsed, alias);

    if parsed.tree.at(parent).kind == PythonKind::ImportFrom {
        let header = header_of(parsed, parent);

        if header.1 != 0 || &parsed.source[header.0.range()] != module {
            return None;
        }

        if &parsed.source[path.range()] != member {
            return None;
        }

        return Some((header.0, path));
    }

    let text = &parsed.source[path.range()];

    if text.len() != module.len() + member.len() + 1 {
        return None;
    }

    if !text.starts_with(module) || text[module.len()] != b'.' {
        return None;
    }

    if &text[module.len() + 1..] != member {
        return None;
    }

    Some((
        Span {
            length: count_of(module.len()),
            offset: path.offset,
        },
        Span {
            length: count_of(member.len()),
            offset: path.offset + count_of(module.len() + 1),
        },
    ))
}

fn path_of_alias(parsed: &Parsed<'_>, alias: u32) -> Span {
    let held = parsed.tree.at(alias);
    let mut end = held.token_end;

    for position in held.token_start..held.token_end {
        if parsed.tokens[position as usize].text(parsed.source) == b"as" {
            end = position;

            break;
        }
    }

    span_over(parsed.tokens, held.token_start, end)
}

fn header_of(parsed: &Parsed<'_>, statement: u32) -> (Span, u32) {
    let held = parsed.tree.at(statement);
    let mut dots = 0;
    let mut start = held.token_start + 1;
    let mut end = start;

    for position in held.token_start + 1..held.token_end {
        let text = parsed.tokens[position as usize].text(parsed.source);

        if text == b"import" {
            break;
        }

        if text == b"." || text == b"..." {
            dots += count_of(text.len());
            start = position + 1;
            end = start;

            continue;
        }

        end = position + 1;
    }

    (span_over(parsed.tokens, start, end), dots)
}

fn has_trailing_comma(parsed: &Parsed<'_>, statement: u32) -> bool {
    let held = parsed.tree.at(statement);
    let mut position = held.token_end;

    while position > held.token_start {
        position -= 1;

        let kind = parsed.tokens[position as usize].kind;

        if kind == TokenKind::Newline {
            continue;
        }

        if kind != TokenKind::Punctuation(Punctuation::ParenClose) {
            return false;
        }

        return position > held.token_start
            && parsed.tokens[position as usize - 1].kind
                == TokenKind::Punctuation(Punctuation::Comma);
    }

    false
}

fn span_over(tokens: &[Token], start: u32, end: u32) -> Span {
    if end <= start {
        return Span::EMPTY;
    }

    let offset = tokens[start as usize].offset;

    Span {
        length: tokens[end as usize - 1].end() - offset,
        offset,
    }
}

fn push_block(
    tokens: &[Token],
    tree: &Tree<PythonKind>,
    index: &lines::Index,
    first: u32,
    last: u32,
    out: &mut BoundedVec<Block>,
) -> bool {
    let start = index.line_start(index.line_of(tree.at(first).span(tokens).offset));
    let end = after_line_of(tree, tokens, index, last);

    out.push(Block {
        span: Span {
            length: end - start,
            offset: start,
        },
        statement_first: first,
        statement_last: last,
    })
}

fn collect_rows(
    parsed: &Parsed<'_>,
    block: &Block,
    first_party: &[&[u8]],
    rows: &mut [Row; IMPORT_COUNT_MAX as usize],
) -> Option<usize> {
    let mut count = 0;
    let mut statement = block.statement_first;

    for _ in 0..=parsed.tree.count() {
        let held = parsed.tree.at(statement);
        let from = held.kind == PythonKind::ImportFrom;

        let header = if from {
            header_of(parsed, statement)
        } else {
            (Span::EMPTY, 0)
        };

        count = statement_rows(parsed, statement, header, first_party, rows, count)?;

        if statement == block.statement_last {
            return Some(count);
        }

        statement = held.sibling_next;

        if statement == NONE {
            return Some(count);
        }
    }

    None
}

fn statement_rows(
    parsed: &Parsed<'_>,
    statement: u32,
    header: (Span, u32),
    first_party: &[&[u8]],
    rows: &mut [Row; IMPORT_COUNT_MAX as usize],
    at: usize,
) -> Option<usize> {
    let from = parsed.tree.at(statement).kind == PythonKind::ImportFrom;
    let trailing_comma = from && has_trailing_comma(parsed, statement);
    let mut count = at;
    let mut child = parsed.tree.at(statement).child_first;

    while child != NONE {
        let held = parsed.tree.at(child);

        if held.kind != PythonKind::Alias {
            child = held.sibling_next;

            continue;
        }

        if count == IMPORT_COUNT_MAX as usize {
            return None;
        }

        let path = path_of_alias(parsed, child);

        if parsed.source[path.range()] == *b"*" {
            return None;
        }

        let module = if from { header.0 } else { path };
        let name = if from { path } else { Span::EMPTY };

        rows[count] = Row {
            as_name: as_name_of(parsed, child),
            from,
            level: header.1,
            module,
            name,
            section: section_of(&parsed.source[module.range()], header.1, first_party),
            trailing_comma,
        };
        count += 1;
        child = held.sibling_next;
    }

    Some(count)
}

fn as_name_of(parsed: &Parsed<'_>, alias: u32) -> Span {
    let held = parsed.tree.at(alias);

    for position in held.token_start..held.token_end {
        if parsed.tokens[position as usize].text(parsed.source) == b"as" {
            return span_over(parsed.tokens, position + 1, held.token_end);
        }
    }

    Span::EMPTY
}

fn section_of(module: &[u8], level: u32, first_party: &[&[u8]]) -> Section {
    if module == b"__future__" {
        return Section::Future;
    }

    if level > 0 {
        return Section::LocalFolder;
    }

    let head = module
        .iter()
        .position(|byte| *byte == b'.')
        .unwrap_or(module.len());

    if first_party.contains(&&module[..head]) {
        return Section::FirstParty;
    }

    if stdlib::is_stdlib_module(module) {
        return Section::StandardLibrary;
    }

    Section::ThirdParty
}

fn order_of(source: &[u8], left: &Row, right: &Row) -> Ordering {
    let left_module = &source[left.module.range()];
    let right_module = &source[right.module.range()];
    let left_name = &source[left.name.range()];
    let right_name = &source[right.name.range()];

    left.section
        .cmp(&right.section)
        .then(left.from.cmp(&right.from))
        .then(right.level.cmp(&left.level))
        .then(compare_natural(left_module, right_module, true))
        .then(compare_natural(left_module, right_module, false))
        .then(alias_rank(left).cmp(&alias_rank(right)))
        .then(member_type_of(left_name).cmp(&member_type_of(right_name)))
        .then(compare_natural(left_name, right_name, true))
        .then(compare_natural(left_name, right_name, false))
        .then(source[left.as_name.range()].cmp(&source[right.as_name.range()]))
}

const fn alias_rank(row: &Row) -> u8 {
    if row.from && row.as_name.length > 0 {
        return 1;
    }

    0
}

fn member_type_of(name: &[u8]) -> MemberType {
    let has_upper = name.iter().any(u8::is_ascii_uppercase);
    let has_lower = name.iter().any(u8::is_ascii_lowercase);

    if name.len() > 1 && has_upper && !has_lower {
        return MemberType::Constant;
    }

    if name.first().is_some_and(u8::is_ascii_uppercase) {
        return MemberType::Class;
    }

    MemberType::Variable
}

fn compare_natural(left: &[u8], right: &[u8], ignore_case: bool) -> Ordering {
    let mut left_at = 0;
    let mut right_at = 0;

    for _ in 0..=left.len().max(right.len()) {
        let (Some(one), Some(two)) = (left.get(left_at), right.get(right_at)) else {
            return left
                .len()
                .saturating_sub(left_at)
                .cmp(&right.len().saturating_sub(right_at));
        };

        if one.is_ascii_digit() && two.is_ascii_digit() {
            let left_run = digit_run(left, left_at);
            let right_run = digit_run(right, right_at);
            let held = compare_digit_runs(&left[left_at..left_run], &right[right_at..right_run]);

            if held != Ordering::Equal {
                return held;
            }

            left_at = left_run;
            right_at = right_run;

            continue;
        }

        let held = if ignore_case {
            one.to_ascii_lowercase().cmp(&two.to_ascii_lowercase())
        } else {
            one.cmp(two)
        };

        if held != Ordering::Equal {
            return held;
        }

        left_at += 1;
        right_at += 1;
    }

    unreachable!("the walk consumes a byte of one side a step and stops at the longer end")
}

fn digit_run(bytes: &[u8], start: usize) -> usize {
    let mut end = start;

    while end < bytes.len() && bytes[end].is_ascii_digit() {
        end += 1;
    }

    end
}

fn compare_digit_runs(left: &[u8], right: &[u8]) -> Ordering {
    assert!(!left.is_empty());
    assert!(!right.is_empty());

    if left[0] == b'0' || right[0] == b'0' {
        return left.cmp(right);
    }

    left.len().cmp(&right.len()).then(left.cmp(right))
}

fn deduplicated(source: &[u8], rows: &mut [Row]) -> usize {
    let mut kept = 0;

    for index in 0..rows.len() {
        if kept > 0 && same_row(source, &rows[kept - 1], &rows[index]) {
            rows[kept - 1].trailing_comma |= rows[index].trailing_comma;

            continue;
        }

        rows[kept] = rows[index];
        kept += 1;
    }

    kept
}

fn same_row(source: &[u8], left: &Row, right: &Row) -> bool {
    left.from == right.from
        && left.level == right.level
        && source[left.module.range()] == source[right.module.range()]
        && source[left.name.range()] == source[right.name.range()]
        && source[left.as_name.range()] == source[right.as_name.range()]
}

fn render_rows(
    source: &[u8],
    rows: &[Row],
    style: Style,
    line_width: u32,
    out: &mut Buffer,
) -> bool {
    let ending = style.line_ending.bytes();
    let mut section = None;
    let mut index = 0;

    while index < rows.len() {
        let row = rows[index];

        if section.is_some_and(|held| held != row.section) && !out.push_bytes(ending) {
            return false;
        }

        section = Some(row.section);

        if !row.from {
            if !render_plain(source, &row, ending, out) {
                return false;
            }

            index += 1;

            continue;
        }

        let end = group_end(source, rows, index);

        if !render_group(source, &rows[index..end], style, line_width, out) {
            return false;
        }

        index = end;
    }

    true
}

fn group_end(source: &[u8], rows: &[Row], start: usize) -> usize {
    let head = rows[start];
    let mut end = start + 1;

    while end < rows.len() {
        let row = rows[end];

        if !row.from
            || row.level != head.level
            || source[row.module.range()] != source[head.module.range()]
        {
            break;
        }

        end += 1;
    }

    end
}

fn render_plain(source: &[u8], row: &Row, ending: &'static [u8], out: &mut Buffer) -> bool {
    if !out.push_bytes(b"import ") || !out.push_bytes(&source[row.module.range()]) {
        return false;
    }

    if row.as_name.length > 0
        && (!out.push_bytes(b" as ") || !out.push_bytes(&source[row.as_name.range()]))
    {
        return false;
    }

    out.push_bytes(ending)
}

fn render_group(
    source: &[u8],
    rows: &[Row],
    style: Style,
    line_width: u32,
    out: &mut Buffer,
) -> bool {
    let plain = rows
        .iter()
        .take_while(|row| row.as_name.length == 0)
        .count();

    if plain > 0 && !render_names(source, &rows[..plain], style, line_width, out) {
        return false;
    }

    for row in &rows[plain..] {
        if !render_names(source, core::slice::from_ref(row), style, line_width, out) {
            return false;
        }
    }

    true
}

fn render_names(
    source: &[u8],
    rows: &[Row],
    style: Style,
    line_width: u32,
    out: &mut Buffer,
) -> bool {
    assert!(!rows.is_empty());

    let exploded = rows.iter().any(|row| row.trailing_comma);

    if !exploded && flat_width(rows) <= line_width {
        return render_flat(source, rows, style, out);
    }

    render_wrapped(source, rows, style, out)
}

fn flat_width(rows: &[Row]) -> u32 {
    let head = rows[0];
    let mut found = count_of(b"from  import ".len()) + head.level + head.module.length;

    for (index, row) in rows.iter().enumerate() {
        found += name_width(row) + if index > 0 { 2 } else { 0 };
    }

    found
}

fn name_width(row: &Row) -> u32 {
    if row.as_name.length == 0 {
        return row.name.length;
    }

    row.name.length + count_of(b" as ".len()) + row.as_name.length
}

fn write_head(source: &[u8], row: &Row, out: &mut Buffer) -> bool {
    if !out.push_bytes(b"from ") {
        return false;
    }

    for _ in 0..row.level {
        if !out.push_bytes(b".") {
            return false;
        }
    }

    out.push_bytes(&source[row.module.range()]) && out.push_bytes(b" import ")
}

fn write_name(source: &[u8], row: &Row, out: &mut Buffer) -> bool {
    if !out.push_bytes(&source[row.name.range()]) {
        return false;
    }

    if row.as_name.length == 0 {
        return true;
    }

    out.push_bytes(b" as ") && out.push_bytes(&source[row.as_name.range()])
}

fn render_flat(source: &[u8], rows: &[Row], style: Style, out: &mut Buffer) -> bool {
    if !write_head(source, &rows[0], out) {
        return false;
    }

    for (index, row) in rows.iter().enumerate() {
        if index > 0 && !out.push_bytes(b", ") {
            return false;
        }

        if !write_name(source, row, out) {
            return false;
        }
    }

    out.push_bytes(style.line_ending.bytes())
}

fn render_wrapped(source: &[u8], rows: &[Row], style: Style, out: &mut Buffer) -> bool {
    let ending = style.line_ending.bytes();

    if !write_head(source, &rows[0], out) || !out.push_bytes(b"(") || !out.push_bytes(ending) {
        return false;
    }

    for row in rows {
        if !write_indent(source, style, out) || !write_name(source, row, out) {
            return false;
        }

        if !out.push_bytes(b",") || !out.push_bytes(ending) {
            return false;
        }
    }

    out.push_bytes(b")") && out.push_bytes(ending)
}

fn write_indent(source: &[u8], style: Style, out: &mut Buffer) -> bool {
    if style.indent.length > 0 {
        return out.push_bytes(&source[style.indent.range()]);
    }

    if style.indent_tabs {
        return out.push_bytes(b"\t");
    }

    for _ in 0..style.indent_width {
        if !out.push_bytes(b" ") {
            return false;
        }
    }

    true
}
