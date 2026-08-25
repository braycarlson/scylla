use crate::bounded::{BoundedVec, Span, count_of};
use crate::syntax::python::ast::FunctionDef;
use crate::syntax::python::kind::PythonKind;
use crate::syntax::python::semantic::{BindingKind, Semantic};
use crate::syntax::python::stdlib;
use crate::tree::{NONE, Step, Tree, walk};

const HEADERS_GOOGLE: [&[u8]; 30] = [
    b"args",
    b"arguments",
    b"attention",
    b"attributes",
    b"caution",
    b"danger",
    b"error",
    b"example",
    b"examples",
    b"hint",
    b"important",
    b"keyword args",
    b"keyword arguments",
    b"methods",
    b"note",
    b"notes",
    b"other args",
    b"other arguments",
    b"raises",
    b"references",
    b"return",
    b"returns",
    b"see also",
    b"tip",
    b"todo",
    b"warning",
    b"warnings",
    b"warns",
    b"yield",
    b"yields",
];

const HEADERS_NUMPY: [&[u8]; 17] = [
    b"attributes",
    b"examples",
    b"extended summary",
    b"methods",
    b"notes",
    b"other parameters",
    b"other params",
    b"parameters",
    b"raises",
    b"receives",
    b"references",
    b"returns",
    b"see also",
    b"short summary",
    b"warnings",
    b"warns",
    b"yields",
];

const PARAGRAPH_ENDS: &[u8] = b",;.-\\/]})";
const DIRECTIVE_OPEN: &[u8] = b".. ";

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Convention {
    Google,
    Numpy,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Section {
    pub body: Span,
    pub colon: bool,
    pub name: Span,
    pub underline: bool,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum DefinitionKind {
    Class,
    Function,
    Method,
    Module,
    NestedClass,
    NestedFunction,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Visibility {
    Private,
    Public,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Definition {
    pub docstring: u32,
    pub kind: DefinitionKind,
    pub node: u32,
    pub visibility: Visibility,
}

#[derive(Clone, Copy)]
struct Header {
    colon: bool,
    indent: usize,
    name: Span,
    underline: bool,
}

pub fn docstring_of(tree: &Tree<PythonKind>, raw: &[PythonKind], body: u32) -> u32 {
    if body >= tree.count() {
        return NONE;
    }

    let first = tree.at(body).child_first;

    if first == NONE || tree.at(first).kind != PythonKind::Expr {
        return NONE;
    }

    let held = tree.at(first).child_first;

    if held == NONE || tree.at(held).kind != PythonKind::Constant {
        return NONE;
    }

    let node = tree.at(held);

    if node.token_end <= node.token_start {
        return NONE;
    }

    if raw[node.token_start as usize] != PythonKind::StringPlain {
        return NONE;
    }

    held
}

pub fn sections(
    source: &[u8],
    content: Span,
    convention: Convention,
    definition: Option<FunctionDef<'_>>,
    out: &mut BoundedVec<Section>,
) -> bool {
    assert!(content.end() as usize <= source.len());

    out.clear();

    let text = &source[content.range()];
    let mut open: Option<(Header, u32)> = None;
    let mut directive: Option<usize> = None;
    let mut previous = (0, line_end_of(text, 0));
    let mut offset = next_line_of(text, previous.1);

    while offset < text.len() {
        let end = line_end_of(text, offset);
        let indent = indent_of(&text[offset..end]);

        directive = directive_of(&text[offset..end], indent, directive);

        let found = if directive.is_some() {
            None
        } else {
            header_of(text, offset, end, convention, content.offset).filter(|header| {
                let enclosing = open.as_ref().map(|(opened, _)| opened);

                opens_section(
                    source,
                    header,
                    &text[previous.0..previous.1],
                    enclosing,
                    definition,
                )
            })
        };

        if let Some(header) = found {
            if !close_section(out, &mut open, content.offset + count_of(offset)) {
                return false;
            }

            let body = body_start_of(text, end, header.underline);

            open = Some((header, content.offset + count_of(body)));
        }

        previous = (offset, end);
        offset = next_line_of(text, end);
    }

    close_section(out, &mut open, content.offset + count_of(text.len()))
}

fn opens_section(
    source: &[u8],
    header: &Header,
    line_previous: &[u8],
    enclosing: Option<&Header>,
    definition: Option<FunctionDef<'_>>,
) -> bool {
    assert!(header.name.end() as usize <= source.len());

    if header.underline {
        return true;
    }

    if !paragraph_ended(line_previous) {
        return false;
    }

    let Some(opened) = enclosing else {
        return true;
    };

    let verbatim = &source[header.name.range()];

    if opened.indent < header.indent {
        if !canonical(verbatim) || has_parameter(source, definition, verbatim) {
            return false;
        }
    }

    if line_previous.trim_ascii().is_empty() {
        return true;
    }

    !verbatim.first().is_some_and(u8::is_ascii_lowercase)
}

fn canonical(name: &[u8]) -> bool {
    assert!(!name.is_empty());

    let mut word_start = true;

    for byte in name {
        if word_start && !byte.is_ascii_uppercase() {
            return false;
        }

        if !word_start && byte.is_ascii_uppercase() {
            return false;
        }

        word_start = *byte == b' ';
    }

    true
}

fn has_parameter(source: &[u8], definition: Option<FunctionDef<'_>>, name: &[u8]) -> bool {
    assert!(!name.is_empty());

    let Some(function) = definition else {
        return false;
    };

    function.parameters().any(|parameter| {
        parameter
            .name_token()
            .is_some_and(|token| function.view().token_at(token).text(source) == name)
    })
}

fn directive_of(line: &[u8], indent: usize, active: Option<usize>) -> Option<usize> {
    assert!(indent <= line.len());

    if let Some(held) = active {
        if line.trim_ascii().is_empty() || indent > held {
            return Some(held);
        }
    }

    if line[indent..].starts_with(DIRECTIVE_OPEN) {
        return Some(indent);
    }

    None
}

fn indent_of(line: &[u8]) -> usize {
    line.iter()
        .position(|byte| !byte.is_ascii_whitespace())
        .unwrap_or(line.len())
}

pub fn definitions(
    source: &[u8],
    semantic: &Semantic,
    tree: &Tree<PythonKind>,
    raw: &[PythonKind],
    out: &mut BoundedVec<Definition>,
) -> bool {
    out.clear();

    if tree.count() == 0 {
        return true;
    }

    let exported = semantic.exports().next().is_some();

    if !out.push(Definition {
        docstring: docstring_of(tree, raw, 0),
        kind: DefinitionKind::Module,
        node: 0,
        visibility: Visibility::Public,
    }) {
        return false;
    }

    for step in walk(tree) {
        let Step::Enter(node) = step else {
            continue;
        };

        if !opens_definition(tree.at(node).kind) {
            continue;
        }

        let parent = enclosing_definition(tree, node);

        let row = Definition {
            docstring: docstring_of(tree, raw, body_of(tree, node)),
            kind: kind_of(tree, parent, tree.at(node).kind == PythonKind::ClassDef),
            node,
            visibility: visibility_of(source, semantic, node, parent, exported, out),
        };

        if !out.push(row) {
            return false;
        }
    }

    true
}

const fn opens_definition(kind: PythonKind) -> bool {
    matches!(
        kind,
        PythonKind::AsyncFunctionDef | PythonKind::ClassDef | PythonKind::FunctionDef
    )
}

fn kind_of(tree: &Tree<PythonKind>, parent: u32, class: bool) -> DefinitionKind {
    if parent == NONE {
        if class {
            return DefinitionKind::Class;
        }

        return DefinitionKind::Function;
    }

    if class {
        return DefinitionKind::NestedClass;
    }

    if tree.at(parent).kind == PythonKind::ClassDef {
        return DefinitionKind::Method;
    }

    DefinitionKind::NestedFunction
}

fn body_of(tree: &Tree<PythonKind>, node: u32) -> u32 {
    let mut child = tree.at(node).child_first;

    while child != NONE {
        if tree.at(child).kind == PythonKind::Block {
            return child;
        }

        child = tree.at(child).sibling_next;
    }

    NONE
}

fn enclosing_definition(tree: &Tree<PythonKind>, node: u32) -> u32 {
    let mut held = tree.at(node).parent;
    let mut steps = 0;

    while held != NONE && steps <= tree.count() {
        if opens_definition(tree.at(held).kind) {
            return held;
        }

        held = tree.at(held).parent;
        steps += 1;
    }

    NONE
}

fn visibility_of(
    source: &[u8],
    semantic: &Semantic,
    node: u32,
    parent: u32,
    exported: bool,
    rows: &BoundedVec<Definition>,
) -> Visibility {
    let name = name_of(source, semantic, node);

    if private_name(name) {
        return Visibility::Private;
    }

    if parent == NONE {
        if !exported || semantic.exports().any(|span| &source[span.range()] == name) {
            return Visibility::Public;
        }

        return Visibility::Private;
    }

    rows.iter()
        .rev()
        .find(|row| row.node == parent)
        .map_or(Visibility::Private, |row| row.visibility)
}

fn private_name(name: &[u8]) -> bool {
    if stdlib::is_dunder(name) {
        return false;
    }

    name.first() == Some(&b'_')
}

fn name_of<'run>(source: &'run [u8], semantic: &Semantic, node: u32) -> &'run [u8] {
    for binding in semantic.bindings() {
        if binding.node != node {
            continue;
        }

        if !matches!(
            binding.kind,
            BindingKind::ClassDefinition | BindingKind::FunctionDefinition
        ) {
            continue;
        }

        return &source[binding.name.range()];
    }

    &[]
}

fn line_end_of(text: &[u8], offset: usize) -> usize {
    let mut end = offset;

    while end < text.len() && text[end] != b'\n' {
        end += 1;
    }

    end
}

fn next_line_of(text: &[u8], end: usize) -> usize {
    if end < text.len() {
        end + 1
    } else {
        text.len()
    }
}

fn header_of(
    text: &[u8],
    offset: usize,
    end: usize,
    convention: Convention,
    base: u32,
) -> Option<Header> {
    let mut start = offset;

    while start < end && text[start].is_ascii_whitespace() {
        start += 1;
    }

    let line = text[start..end].trim_ascii_end();
    let words = leading_words(line);
    let name = words.trim_ascii_end();
    let suffix = line[words.len()..].trim_ascii();

    let headers: &[&[u8]] = match convention {
        Convention::Google => &HEADERS_GOOGLE,
        Convention::Numpy => &HEADERS_NUMPY,
    };

    if !headers
        .iter()
        .any(|header| header.eq_ignore_ascii_case(name))
    {
        return None;
    }

    if !suffix.is_empty() && suffix != b":" {
        return None;
    }

    Some(Header {
        colon: suffix == b":",
        indent: start - offset,
        name: Span {
            length: count_of(name.len()),
            offset: base + count_of(start),
        },
        underline: underlined(text, next_line_of(text, end)),
    })
}

fn leading_words(line: &[u8]) -> &[u8] {
    let Ok(held) = core::str::from_utf8(line) else {
        return line
            .iter()
            .position(|byte| !byte.is_ascii_alphanumeric() && !byte.is_ascii_whitespace())
            .map_or(line, |at| &line[..at]);
    };

    held.char_indices()
        .find(|(_, character)| !character.is_alphanumeric() && !character.is_whitespace())
        .map_or(line, |(at, _)| &line[..at])
}

fn underlined(text: &[u8], offset: usize) -> bool {
    let end = line_end_of(text, offset);
    let line = text[offset..end].trim_ascii();

    !line.is_empty() && line.iter().all(|byte| matches!(*byte, b'-' | b'='))
}

fn paragraph_ended(line: &[u8]) -> bool {
    let held = line.trim_ascii();

    held.last().is_none_or(|byte| PARAGRAPH_ENDS.contains(byte))
}

fn body_start_of(text: &[u8], end: usize, underline: bool) -> usize {
    let after = next_line_of(text, end);

    if !underline {
        return after;
    }

    next_line_of(text, line_end_of(text, after))
}

fn close_section(
    out: &mut BoundedVec<Section>,
    open: &mut Option<(Header, u32)>,
    end: u32,
) -> bool {
    let Some((header, start)) = open.take() else {
        return true;
    };

    out.push(Section {
        body: Span {
            length: end.saturating_sub(start),
            offset: start,
        },
        colon: header.colon,
        name: header.name,
        underline: header.underline,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::syntax::python::analyze::fixture::Fixture;
    use crate::syntax::python::literal::shape_of;

    fn sectioned(text: &[u8], convention: Convention) -> Vec<(String, String, bool, bool)> {
        let mut source = Vec::from(b"\"\"\"".as_slice());

        source.extend_from_slice(text);
        source.extend_from_slice(b"\"\"\"\n");

        sectioned_in(&source, convention)
    }

    fn sectioned_in(source: &[u8], convention: Convention) -> Vec<(String, String, bool, bool)> {
        let held = Fixture::of(source);
        let node = held.first(PythonKind::Constant);
        let view = held.view(node);
        let function = held.first(PythonKind::FunctionDef);
        let definition = (function != NONE).then(|| held.view(function).as_function());
        let token = view.token_at(held.tree.at(node).token_start);

        let content = shape_of(token.text(&held.source), token.offset)
            .expect("a docstring is a shape")
            .content;

        let mut out = BoundedVec::reserve(1 << 6);

        assert!(sections(
            &held.source,
            content,
            convention,
            definition.flatten(),
            &mut out
        ));

        out.iter()
            .map(|section| {
                (
                    String::from_utf8_lossy(&held.source[section.name.range()]).into_owned(),
                    String::from_utf8_lossy(&held.source[section.body.range()]).into_owned(),
                    section.colon,
                    section.underline,
                )
            })
            .collect()
    }

    fn documented(parameters: &[u8], text: &[u8]) -> Vec<u8> {
        let mut source = Vec::from(b"def func(".as_slice());

        source.extend_from_slice(parameters);
        source.extend_from_slice(b"):\n    \"\"\"");
        source.extend_from_slice(text);
        source.extend_from_slice(b"\"\"\"\n");

        source
    }

    fn defined(source: &[u8]) -> Vec<(DefinitionKind, Visibility, bool)> {
        let held = Fixture::of(source);
        let mut out = BoundedVec::reserve(1 << 8);

        assert!(definitions(
            &held.source,
            &held.semantic,
            &held.tree,
            &held.raw,
            &mut out
        ));

        out.iter()
            .map(|row| (row.kind, row.visibility, row.docstring != NONE))
            .collect()
    }

    #[test]
    fn a_google_docstring_reads_its_headers_and_their_bodies() {
        let held = sectioned(
            b"Read a value.\n\nArgs:\n    value: The value.\n\nReturns:\n    The value.\n",
            Convention::Google,
        );

        assert_eq!(held.len(), 2);
        assert_eq!(held[0].0, "Args");
        assert_eq!(held[0].1, "    value: The value.\n\n");
        assert!(held[0].2);
        assert!(!held[0].3);
        assert_eq!(held[1].0, "Returns");
        assert_eq!(held[1].1, "    The value.\n");
    }

    #[test]
    fn a_numpy_docstring_reads_past_the_underline_below_the_header() {
        let held = sectioned(
            b"Read a value.\n\nParameters\n----------\nvalue : int\n\nReturns\n-------\nint\n",
            Convention::Numpy,
        );

        assert_eq!(held.len(), 2);
        assert_eq!(held[0].0, "Parameters");
        assert_eq!(held[0].1, "value : int\n\n");
        assert!(!held[0].2);
        assert!(held[0].3);
        assert_eq!(held[1].0, "Returns");
        assert_eq!(held[1].1, "int\n");
    }

    #[test]
    fn a_header_missing_its_colon_or_its_underline_still_opens_a_section() {
        let numpy = sectioned(
            b"Read a value.\n\nParameters\nvalue : int\n",
            Convention::Numpy,
        );

        assert_eq!(numpy.len(), 1);
        assert_eq!(numpy[0].0, "Parameters");
        assert_eq!(numpy[0].1, "value : int\n");
        assert!(!numpy[0].2);
        assert!(!numpy[0].3);

        let google = sectioned(b"Read a value.\n\nArgs\n    text\n", Convention::Google);

        assert_eq!(google.len(), 1);
        assert_eq!(google[0].0, "Args");
        assert!(!google[0].2);
    }

    #[test]
    fn a_letter_outside_ascii_is_part_of_the_leading_words() {
        let held = sectioned(
            "Read a value.\n\nArgs\u{e9}:\n    value: The value.\n\nArgs:\n    other: The other.\n"
                .as_bytes(),
            Convention::Google,
        );

        assert_eq!(held.len(), 1);
        assert_eq!(held[0].0, "Args");
    }

    #[test]
    fn a_header_is_read_in_any_case_and_keeps_the_bytes_the_author_wrote() {
        let held = sectioned(
            b"Read a value.\n\nreturns:\n    The value.\n",
            Convention::Google,
        );

        assert_eq!(held.len(), 1);
        assert_eq!(held[0].0, "returns");
        assert!(held[0].2);
    }

    #[test]
    fn an_underline_opens_a_section_even_mid_paragraph() {
        let held = sectioned(
            b"Read a value.\nmore text\nReturns\n=======\nint\n",
            Convention::Numpy,
        );

        assert_eq!(held.len(), 1);
        assert_eq!(held[0].0, "Returns");
        assert!(held[0].3);
    }

    #[test]
    fn a_word_that_is_no_header_opens_no_section() {
        assert!(sectioned(b"Read a value.\n\nNotable:\n    text\n", Convention::Google).is_empty());
        assert!(sectioned(b"Read a value.\n\nReturns the value.\n", Convention::Google).is_empty());

        assert!(
            sectioned(
                b"Read a value.\nmore text\nReturns:\n    int\n",
                Convention::Google
            )
            .is_empty()
        );

        assert!(sectioned(b"Returns:\n    int\n", Convention::Google).is_empty());

        assert!(
            sectioned(
                b"Read a value.\n\nParameters:\n    int\n",
                Convention::Google
            )
            .is_empty()
        );
    }

    #[test]
    fn a_deeper_header_in_another_case_is_a_subsection() {
        let held = sectioned_in(
            &documented(
                b"args",
                b"Toggle the gizmo.\n\n    Args:\n        args: The arguments.\n    ",
            ),
            Convention::Google,
        );

        assert_eq!(held.len(), 1);
        assert_eq!(held[0].0, "Args");
        assert_eq!(held[0].1, "        args: The arguments.\n    ");
    }

    #[test]
    fn a_deeper_header_spelled_exactly_opens_a_section_unless_a_parameter_bears_its_name() {
        let text = [
            b"Toggle the gizmo.\n\n    Args:\n        first: The first.\n".as_slice(),
            b"        Args:\n            The arguments.\n    ",
        ]
        .concat();

        let lower = sectioned_in(&documented(b"args", &text), Convention::Google);

        assert_eq!(lower.len(), 2);
        assert_eq!(lower[0].1, "        first: The first.\n");
        assert_eq!(lower[1].0, "Args");
        assert_eq!(lower[1].1, "            The arguments.\n    ");

        let exact = sectioned_in(&documented(b"Args", &text), Convention::Google);

        assert_eq!(exact.len(), 1);

        let bare = sectioned(
            b"Toggle the gizmo.\n\nArgs:\n    first: The first.\n    Args:\n        text\n",
            Convention::Google,
        );

        assert_eq!(bare.len(), 2);
    }

    #[test]
    fn a_lower_case_header_under_a_blank_line_opens_a_section() {
        let held = sectioned_in(
            &documented(
                b"args",
                &[
                    b"Toggle the gizmo.\n\n    Args:\n        args: The arguments.\n\n".as_slice(),
                    b"    returns:\n        The value.\n    ",
                ]
                .concat(),
            ),
            Convention::Google,
        );

        assert_eq!(held.len(), 2);
        assert_eq!(held[1].0, "returns");
        assert_eq!(held[1].1, "        The value.\n    ");
    }

    #[test]
    fn a_lower_case_header_with_no_underline_inside_a_section_is_a_subsection() {
        let held = sectioned_in(
            &documented(
                b"parameters",
                &[
                    b"Toggle the gizmo.\n\n    Parameters:\n    -----\n".as_slice(),
                    b"    parameters:\n        The arguments.\n    ",
                ]
                .concat(),
            ),
            Convention::Numpy,
        );

        assert_eq!(held.len(), 1);
        assert_eq!(held[0].0, "Parameters");

        let underlined = sectioned(
            b"Toggle the gizmo.\n\nParameters\n----------\nvalue : int.\nreturns\n-------\nint\n",
            Convention::Numpy,
        );

        assert_eq!(underlined.len(), 2);
        assert_eq!(underlined[1].0, "returns");
    }

    #[test]
    fn a_directive_swallows_the_headers_indented_inside_it() {
        let held = sectioned(
            b"Read a value.\n\n.. note::\n\n    Args:\n        text\n\nReturns:\n    int\n",
            Convention::Google,
        );

        assert_eq!(held.len(), 1);
        assert_eq!(held[0].0, "Returns");

        let nested = sectioned(
            b"Read a value.\n\n.. note::\n    .. warning::\n        Args:\n    Raises:\n",
            Convention::Google,
        );

        assert!(nested.is_empty());
    }

    #[test]
    fn a_module_docstring_reads_off_the_module_body() {
        let held = Fixture::of(b"\"doc\"\nvalue = 1\n");

        assert!(docstring_of(&held.tree, &held.raw, 0) != NONE);

        let other = Fixture::of(b"value = 1\n\"doc\"\n");

        assert_eq!(docstring_of(&other.tree, &other.raw, 0), NONE);
    }

    #[test]
    fn a_constant_that_is_no_plain_string_is_no_docstring() {
        for source in [
            b"def read():\n    ...\n".as_slice(),
            b"def read():\n    42\n",
            b"def read():\n    b\"doc\"\n",
            b"def read():\n    None\n",
        ] {
            let held = Fixture::of(source);
            let body = body_of(&held.tree, held.first(PythonKind::FunctionDef));

            assert_ne!(body, NONE);
            assert_eq!(docstring_of(&held.tree, &held.raw, body), NONE);
        }

        let held = Fixture::of(b"def read():\n    \"doc\"\n");
        let body = body_of(&held.tree, held.first(PythonKind::FunctionDef));

        assert_ne!(docstring_of(&held.tree, &held.raw, body), NONE);
    }

    #[test]
    fn every_definition_reads_its_kind_and_its_docstring() {
        let mut source = Vec::from(b"\"module\"\n".as_slice());

        source.extend_from_slice(b"class Holder:\n");
        source.extend_from_slice(b"    \"class\"\n");
        source.extend_from_slice(b"    def read(self):\n");
        source.extend_from_slice(b"        \"method\"\n");
        source.extend_from_slice(b"        def inner():\n");
        source.extend_from_slice(b"            pass\n");
        source.extend_from_slice(b"def free():\n");
        source.extend_from_slice(b"    pass\n");

        assert_eq!(
            defined(&source),
            vec![
                (DefinitionKind::Module, Visibility::Public, true),
                (DefinitionKind::Class, Visibility::Public, true),
                (DefinitionKind::Method, Visibility::Public, true),
                (DefinitionKind::NestedFunction, Visibility::Public, false),
                (DefinitionKind::Function, Visibility::Public, false),
            ]
        );
    }

    #[test]
    fn a_leading_underscore_makes_a_definition_private() {
        assert_eq!(
            defined(b"def _read():\n    pass\n"),
            vec![
                (DefinitionKind::Module, Visibility::Public, false),
                (DefinitionKind::Function, Visibility::Private, false),
            ]
        );
    }

    #[test]
    fn a_definition_inside_a_private_one_is_private_too() {
        let mut source = Vec::from(b"def _read():\n".as_slice());

        source.extend_from_slice(b"    def inner():\n");
        source.extend_from_slice(b"        pass\n");

        assert_eq!(
            defined(&source),
            vec![
                (DefinitionKind::Module, Visibility::Public, false),
                (DefinitionKind::Function, Visibility::Private, false),
                (DefinitionKind::NestedFunction, Visibility::Private, false),
            ]
        );
    }

    #[test]
    fn a_definition_two_levels_inside_a_hidden_one_is_private_too() {
        let mut source = Vec::from(b"__all__ = [\"read\"]\n".as_slice());

        source.extend_from_slice(b"def other():\n");
        source.extend_from_slice(b"    class Inner:\n");
        source.extend_from_slice(b"        def deep(self):\n");
        source.extend_from_slice(b"            pass\n");

        assert_eq!(
            defined(&source),
            vec![
                (DefinitionKind::Module, Visibility::Public, false),
                (DefinitionKind::Function, Visibility::Private, false),
                (DefinitionKind::NestedClass, Visibility::Private, false),
                (DefinitionKind::Method, Visibility::Private, false),
            ]
        );
    }

    #[test]
    fn a_module_that_writes_dunder_all_hides_what_it_leaves_out() {
        let mut source = Vec::from(b"__all__ = [\"read\"]\n".as_slice());

        source.extend_from_slice(b"def read():\n    pass\n");
        source.extend_from_slice(b"def other():\n    pass\n");

        assert_eq!(
            defined(&source),
            vec![
                (DefinitionKind::Module, Visibility::Public, false),
                (DefinitionKind::Function, Visibility::Public, false),
                (DefinitionKind::Function, Visibility::Private, false),
            ]
        );
    }

    #[test]
    fn a_dunder_method_stays_public() {
        assert_eq!(
            defined(b"class Holder:\n    def __init__(self):\n        pass\n"),
            vec![
                (DefinitionKind::Module, Visibility::Public, false),
                (DefinitionKind::Class, Visibility::Public, false),
                (DefinitionKind::Method, Visibility::Public, false),
            ]
        );
    }
}
