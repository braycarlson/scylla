use crate::bounded::{BoundedVec, Span};
use crate::syntax::python::ast::{FunctionDef, View};
use crate::syntax::python::kind::PythonKind;
use crate::syntax::python::semantic::Semantic;
use crate::syntax::python::stdlib;
use crate::tree::NONE;

const ABSTRACT: [&[u8]; 4] = [
    b"abstractclassmethod",
    b"abstractmethod",
    b"abstractproperty",
    b"abstractstaticmethod",
];

const IMPLICIT_CLASS_METHODS: [&[u8]; 2] = [b"__init_subclass__", b"__class_getitem__"];

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum FunctionKind {
    ClassMethod,
    Function,
    Method,
    New,
    StaticMethod,
}

pub fn function_kind(
    source: &[u8],
    semantic: &Semantic,
    definition: FunctionDef<'_>,
    out: &mut BoundedVec<Span>,
) -> FunctionKind {
    let view = definition.view();

    if enclosing_class(view) == NONE {
        return FunctionKind::Function;
    }

    if decorated(
        source,
        semantic,
        definition,
        b"builtins",
        b"staticmethod",
        out,
    ) {
        return FunctionKind::StaticMethod;
    }

    if decorated(
        source,
        semantic,
        definition,
        b"builtins",
        b"classmethod",
        out,
    ) {
        return FunctionKind::ClassMethod;
    }

    let name = definition
        .name_token()
        .map_or(&[][..], |position| view.token_at(position).text(source));

    if name == b"__new__" {
        return FunctionKind::New;
    }

    if IMPLICIT_CLASS_METHODS.contains(&name) {
        return FunctionKind::ClassMethod;
    }

    FunctionKind::Method
}

pub fn is_abstract(
    source: &[u8],
    semantic: &Semantic,
    definition: FunctionDef<'_>,
    out: &mut BoundedVec<Span>,
) -> bool {
    ABSTRACT
        .iter()
        .any(|member| decorated(source, semantic, definition, b"abc", member, out))
}

pub fn is_magic(name: &[u8]) -> bool {
    stdlib::is_dunder(name)
}

pub fn is_overload(
    source: &[u8],
    semantic: &Semantic,
    definition: FunctionDef<'_>,
    out: &mut BoundedVec<Span>,
) -> bool {
    decorated(source, semantic, definition, b"typing", b"overload", out)
}

pub fn is_override(
    source: &[u8],
    semantic: &Semantic,
    definition: FunctionDef<'_>,
    out: &mut BoundedVec<Span>,
) -> bool {
    decorated(source, semantic, definition, b"typing", b"override", out)
}

pub fn is_property(
    source: &[u8],
    semantic: &Semantic,
    definition: FunctionDef<'_>,
    out: &mut BoundedVec<Span>,
    extra: &[&[u8]],
) -> bool {
    if decorated(source, semantic, definition, b"builtins", b"property", out) {
        return true;
    }

    if decorated(
        source,
        semantic,
        definition,
        b"functools",
        b"cached_property",
        out,
    ) {
        return true;
    }

    for path in extra {
        let Some((module, member)) = split_path(path) else {
            continue;
        };

        if decorated(source, semantic, definition, module, member, out) {
            return true;
        }
    }

    false
}

pub fn decorator_of(view: View<'_>) -> Option<View<'_>> {
    let held = if view.kind() == PythonKind::Decorator {
        view.child_first()?
    } else {
        view
    };

    if held.kind() != PythonKind::Call {
        return Some(held);
    }

    held.child_first()
}

fn decorated(
    source: &[u8],
    semantic: &Semantic,
    definition: FunctionDef<'_>,
    module: &[u8],
    member: &[u8],
    out: &mut BoundedVec<Span>,
) -> bool {
    for decorator in definition.decorators() {
        let Some(held) = decorator_of(decorator) else {
            continue;
        };

        if semantic.matches(source, held, module, member, out) {
            return true;
        }
    }

    false
}

fn split_path(path: &[u8]) -> Option<(&[u8], &[u8])> {
    let at = path.iter().rposition(|byte| *byte == b'.')?;

    Some((&path[..at], &path[at + 1..]))
}

fn enclosing_class(view: View<'_>) -> u32 {
    let mut held = view.parent();

    while let Some(node) = held {
        if node.kind() == PythonKind::ClassDef {
            return node.index();
        }

        if matches!(
            node.kind(),
            PythonKind::AsyncFunctionDef | PythonKind::FunctionDef | PythonKind::Lambda
        ) {
            return NONE;
        }

        held = node.parent();
    }

    NONE
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::syntax::python::analyze::fixture::Fixture;

    fn kind_of(source: &[u8]) -> FunctionKind {
        let held = Fixture::of(source);
        let node = last_definition(&held);
        let view = held.view(node).as_function().expect("a definition");
        let mut out = BoundedVec::reserve(1 << 8);

        function_kind(&held.source, &held.semantic, view, &mut out)
    }

    fn last_definition(held: &Fixture) -> u32 {
        let mut found = NONE;

        for node in 0..held.tree.count() {
            if matches!(
                held.tree.at(node).kind,
                PythonKind::AsyncFunctionDef | PythonKind::FunctionDef
            ) {
                found = node;
            }
        }

        found
    }

    #[test]
    fn a_definition_outside_a_class_is_a_plain_function() {
        assert_eq!(kind_of(b"def read():\n    pass\n"), FunctionKind::Function);
    }

    #[test]
    fn a_definition_inside_a_class_is_a_method() {
        assert_eq!(
            kind_of(b"class Holder:\n    def read(self):\n        pass\n"),
            FunctionKind::Method
        );
    }

    #[test]
    fn a_static_and_a_class_decorator_each_name_their_own_kind() {
        assert_eq!(
            kind_of(b"class Holder:\n    @staticmethod\n    def read():\n        pass\n"),
            FunctionKind::StaticMethod
        );

        assert_eq!(
            kind_of(b"class Holder:\n    @classmethod\n    def read(cls):\n        pass\n"),
            FunctionKind::ClassMethod
        );
    }

    #[test]
    fn the_three_names_cpython_treats_as_implicit_read_that_way() {
        assert_eq!(
            kind_of(b"class Holder:\n    def __new__(cls):\n        pass\n"),
            FunctionKind::New
        );

        assert_eq!(
            kind_of(b"class Holder:\n    def __init_subclass__(cls):\n        pass\n"),
            FunctionKind::ClassMethod
        );
    }

    #[test]
    fn a_decorator_outranks_the_name_cpython_treats_as_implicit() {
        assert_eq!(
            kind_of(&source_of(&[
                "class Holder:",
                "    @staticmethod",
                "    def __class_getitem__(item):",
                "        pass",
            ])),
            FunctionKind::StaticMethod
        );

        assert_eq!(
            kind_of(&source_of(&[
                "class Holder:",
                "    @classmethod",
                "    def __new__(cls):",
                "        pass",
            ])),
            FunctionKind::ClassMethod
        );
    }

    #[test]
    fn a_definition_nested_in_a_method_is_a_plain_function() {
        assert_eq!(
            kind_of(&source_of(&[
                "class Holder:",
                "    def read(self):",
                "        def inner():",
                "            pass",
            ])),
            FunctionKind::Function
        );
    }

    #[derive(Clone, Copy)]
    enum Question {
        Abstract,
        Overload,
        Override,
    }

    fn asked(source: &[u8], question: Question) -> bool {
        let held = Fixture::of(source);
        let node = last_definition(&held);
        let view = held.view(node).as_function().expect("a definition");
        let mut out = BoundedVec::reserve(1 << 8);

        match question {
            Question::Abstract => is_abstract(&held.source, &held.semantic, view, &mut out),
            Question::Overload => is_overload(&held.source, &held.semantic, view, &mut out),
            Question::Override => is_override(&held.source, &held.semantic, view, &mut out),
        }
    }

    fn source_of(lines: &[&str]) -> Vec<u8> {
        let mut found = Vec::new();

        for line in lines {
            found.extend_from_slice(line.as_bytes());
            found.push(b'\n');
        }

        found
    }

    #[test]
    fn an_abstract_decorator_reads_as_abstract_however_it_is_spelled() {
        let dotted = source_of(&[
            "import abc",
            "class Holder:",
            "    @abc.abstractmethod",
            "    def read(self):",
            "        pass",
        ]);

        let named = source_of(&[
            "from abc import abstractproperty",
            "class Holder:",
            "    @abstractproperty",
            "    def read(self):",
            "        pass",
        ]);

        assert!(asked(&dotted, Question::Abstract));
        assert!(asked(&named, Question::Abstract));
        assert!(!asked(b"def read():\n    pass\n", Question::Abstract));
    }

    #[test]
    fn an_overload_and_an_override_each_read_as_themselves() {
        let overloaded = source_of(&[
            "import typing",
            "@typing.overload",
            "def read():",
            "    pass",
        ]);

        let overridden = source_of(&[
            "from typing import override",
            "class Holder:",
            "    @override",
            "    def read(self):",
            "        pass",
        ]);

        assert!(asked(&overloaded, Question::Overload));
        assert!(asked(&overridden, Question::Override));
    }

    #[test]
    fn a_property_reads_through_builtins_functools_and_a_caller_s_own_path() {
        let cached = source_of(&[
            "import functools",
            "class Holder:",
            "    @functools.cached_property",
            "    def read(self):",
            "        pass",
        ]);

        let held = Fixture::of(&cached);
        let node = last_definition(&held);
        let view = held.view(node).as_function().expect("a definition");
        let mut out = BoundedVec::reserve(1 << 8);

        assert!(is_property(
            &held.source,
            &held.semantic,
            view,
            &mut out,
            &[]
        ));

        let lazy = source_of(&[
            "import mypkg",
            "class Holder:",
            "    @mypkg.lazy",
            "    def read(self):",
            "        pass",
        ]);

        let own = Fixture::of(&lazy);
        let held_node = last_definition(&own);
        let held_view = own.view(held_node).as_function().expect("a definition");

        assert!(is_property(
            &own.source,
            &own.semantic,
            held_view,
            &mut out,
            &[b"mypkg.lazy"]
        ));

        assert!(!is_property(
            &own.source,
            &own.semantic,
            held_view,
            &mut out,
            &[]
        ));
    }

    #[test]
    fn a_dunder_name_is_magic_and_a_private_one_is_not() {
        assert!(is_magic(b"__init__"));
        assert!(!is_magic(b"_private"));
        assert!(!is_magic(b"read"));
    }
}
