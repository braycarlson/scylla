use crate::bounded::{BoundedVec, Span};
use crate::syntax::python::ast::{Literal, View};
use crate::syntax::python::kind::PythonKind;
use crate::syntax::python::semantic::Semantic;

const IMMUTABLE_PLAIN: [(&[u8], &[u8]); 11] = [
    (b"builtins", b"bool"),
    (b"builtins", b"bytes"),
    (b"builtins", b"complex"),
    (b"builtins", b"float"),
    (b"builtins", b"int"),
    (b"builtins", b"object"),
    (b"builtins", b"range"),
    (b"builtins", b"str"),
    (b"collections.abc", b"Sized"),
    (b"typing", b"LiteralString"),
    (b"typing", b"Sized"),
];

const IMMUTABLE_GENERIC: [(&[u8], &[u8]); 25] = [
    (b"builtins", b"frozendict"),
    (b"builtins", b"frozenset"),
    (b"builtins", b"tuple"),
    (b"collections.abc", b"ByteString"),
    (b"collections.abc", b"Collection"),
    (b"collections.abc", b"Container"),
    (b"collections.abc", b"Iterable"),
    (b"collections.abc", b"Mapping"),
    (b"collections.abc", b"Reversible"),
    (b"collections.abc", b"Sequence"),
    (b"collections.abc", b"Set"),
    (b"typing", b"AbstractSet"),
    (b"typing", b"ByteString"),
    (b"typing", b"Callable"),
    (b"typing", b"Collection"),
    (b"typing", b"Container"),
    (b"typing", b"FrozenSet"),
    (b"typing", b"Iterable"),
    (b"typing", b"Literal"),
    (b"typing", b"Mapping"),
    (b"typing", b"Never"),
    (b"typing", b"NoReturn"),
    (b"typing", b"Reversible"),
    (b"typing", b"Sequence"),
    (b"typing", b"Tuple"),
];

const ANNOTATED_MODULES: [&[u8]; 2] = [b"typing", b"typing_extensions"];

const MUTABLE_CALLS: [(&[u8], &[u8]); 7] = [
    (b"builtins", b"dict"),
    (b"builtins", b"list"),
    (b"builtins", b"set"),
    (b"collections", b"Counter"),
    (b"collections", b"OrderedDict"),
    (b"collections", b"defaultdict"),
    (b"collections", b"deque"),
];

pub const ANNOTATION_STACK_MAX: u32 = 1 << 6;

pub fn is_immutable_annotation(
    source: &[u8],
    semantic: &Semantic,
    view: View<'_>,
    out: &mut BoundedVec<Span>,
    stack: &mut BoundedVec<u32>,
) -> bool {
    stack.clear();

    if !stack.push(view.index()) {
        return false;
    }

    for _ in 0..=view.tree().count() {
        let Some(node) = stack.pop() else {
            return true;
        };

        if !immutable_at(source, semantic, view.at(node), out, stack) {
            return false;
        }
    }

    false
}

fn immutable_at(
    source: &[u8],
    semantic: &Semantic,
    view: View<'_>,
    out: &mut BoundedVec<Span>,
    stack: &mut BoundedVec<u32>,
) -> bool {
    if matches!(view.kind(), PythonKind::Attribute | PythonKind::Name) {
        return immutable_name(source, semantic, view, out);
    }

    if view.kind() == PythonKind::BinOp {
        return immutable_union(view, stack);
    }

    if view.kind() == PythonKind::Constant {
        return view
            .as_constant()
            .is_some_and(|held| held.literal_class() == Literal::None);
    }

    if view.kind() == PythonKind::Parenthesized {
        return push_all(view.children(), stack);
    }

    if view.kind() == PythonKind::Subscript {
        return immutable_subscript(source, semantic, view, out, stack);
    }

    false
}

fn immutable_union(view: View<'_>, stack: &mut BoundedVec<u32>) -> bool {
    let Some(operation) = view.as_operation() else {
        return false;
    };

    let Some(operator) = operation.operator_tokens().next() else {
        return false;
    };

    if view.token_kind(operator) != PythonKind::Bar {
        return false;
    }

    push_all(view.children(), stack)
}

fn immutable_subscript(
    source: &[u8],
    semantic: &Semantic,
    view: View<'_>,
    out: &mut BoundedVec<Span>,
    stack: &mut BoundedVec<u32>,
) -> bool {
    let Some(head) = view.child_first() else {
        return false;
    };

    let Some(slice) = view.child_at(1) else {
        return false;
    };

    if IMMUTABLE_GENERIC
        .iter()
        .any(|(module, member)| semantic.matches(source, head, module, member, out))
    {
        return true;
    }

    if semantic.matches(source, head, b"typing", b"Union", out) {
        if slice.kind() != PythonKind::Tuple {
            return false;
        }

        return push_all(slice.children(), stack);
    }

    if semantic.matches(source, head, b"typing", b"Optional", out) {
        return stack.push(slice.index());
    }

    if !ANNOTATED_MODULES
        .iter()
        .any(|module| semantic.matches(source, head, module, b"Annotated", out))
    {
        return false;
    }

    if slice.kind() != PythonKind::Tuple {
        return false;
    }

    slice
        .child_first()
        .is_some_and(|first| stack.push(first.index()))
}

fn push_all<'run>(held: impl Iterator<Item = View<'run>>, stack: &mut BoundedVec<u32>) -> bool {
    for view in held {
        if !stack.push(view.index()) {
            return false;
        }
    }

    true
}

pub fn is_mutable_expression(
    source: &[u8],
    semantic: &Semantic,
    view: View<'_>,
    out: &mut BoundedVec<Span>,
) -> bool {
    if matches!(
        view.kind(),
        PythonKind::Dict
            | PythonKind::DictComp
            | PythonKind::List
            | PythonKind::ListComp
            | PythonKind::Set
            | PythonKind::SetComp
    ) {
        return true;
    }

    if view.kind() != PythonKind::Call {
        return false;
    }

    let Some(callee) = view.child_first() else {
        return false;
    };

    MUTABLE_CALLS
        .iter()
        .any(|(module, member)| semantic.matches(source, callee, module, member, out))
}

fn immutable_name(
    source: &[u8],
    semantic: &Semantic,
    view: View<'_>,
    out: &mut BoundedVec<Span>,
) -> bool {
    IMMUTABLE_PLAIN
        .iter()
        .chain(IMMUTABLE_GENERIC.iter())
        .any(|(module, member)| semantic.matches(source, view, module, member, out))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::syntax::python::analyze::fixture::Fixture;

    fn annotated(source: &[u8]) -> bool {
        let held = Fixture::of(source);
        let node = held.first(PythonKind::AnnAssign);
        let view = held.view(node).as_assign().expect("an assignment");
        let annotation = view.annotation().expect("an annotation");
        let mut out = BoundedVec::reserve(1 << 8);
        let mut stack = BoundedVec::reserve(ANNOTATION_STACK_MAX);

        is_immutable_annotation(
            &held.source,
            &held.semantic,
            annotation,
            &mut out,
            &mut stack,
        )
    }

    fn assigned(source: &[u8]) -> bool {
        let held = Fixture::of(source);
        let node = held.first(PythonKind::Assign);
        let view = held.view(node);
        let value = view.children().last().expect("a value");
        let mut out = BoundedVec::reserve(1 << 8);

        is_mutable_expression(&held.source, &held.semantic, value, &mut out)
    }

    #[test]
    fn an_immutable_builtin_reads_as_immutable() {
        assert!(annotated(b"held: int = 1\n"));
        assert!(annotated(b"held: str = \"text\"\n"));
        assert!(annotated(b"held: frozenset = frozenset()\n"));
        assert!(annotated(b"held: tuple = ()\n"));
        assert!(!annotated(b"held: list = []\n"));
        assert!(!annotated(b"held: dict = {}\n"));
    }

    #[test]
    fn a_union_and_an_optional_carry_their_arguments() {
        assert!(annotated(
            b"import typing\nheld: typing.Optional[int] = None\n"
        ));

        assert!(annotated(
            b"import typing\nheld: typing.Union[int, str] = 1\n"
        ));

        assert!(!annotated(
            b"import typing\nheld: typing.Optional[list] = None\n"
        ));

        assert!(!annotated(
            b"import typing\nheld: typing.Union[int, list] = 1\n"
        ));
    }

    #[test]
    fn an_annotated_reads_its_first_argument_alone() {
        assert!(annotated(
            b"import typing\nheld: typing.Annotated[int, list] = 1\n"
        ));

        assert!(!annotated(
            b"import typing\nheld: typing.Annotated[list, int] = []\n"
        ));

        assert!(annotated(
            b"import typing_extensions\nheld: typing_extensions.Annotated[int, 1] = 1\n"
        ));
    }

    #[test]
    fn an_immutable_generic_passes_whatever_it_is_subscripted_with() {
        assert!(annotated(
            b"import typing\nheld: typing.Sequence[int] = ()\n"
        ));

        assert!(annotated(
            b"from typing import Sequence\nheld: Sequence[list] = ()\n"
        ));

        assert!(annotated(
            b"import typing\nheld: typing.Literal[\"one\"] = \"one\"\n"
        ));

        assert!(annotated(
            b"import typing\nheld: typing.Tuple[int, list] = (1, [])\n"
        ));

        assert!(annotated(
            b"import collections.abc\nheld: collections.abc.Sequence = ()\n"
        ));
    }

    #[test]
    fn a_final_and_a_class_var_read_as_mutable_the_way_ruff_reads_them() {
        assert!(!annotated(b"import typing\nheld: typing.Final[int] = 1\n"));

        assert!(!annotated(
            b"import typing\nheld: typing.ClassVar[int] = 1\n"
        ));
    }

    #[test]
    fn a_union_written_with_a_bar_reads_both_sides() {
        assert!(annotated(b"held: int | str = 1\n"));
        assert!(annotated(b"held: int | None = 1\n"));
        assert!(annotated(b"held: None = None\n"));
        assert!(!annotated(b"held: int | list = 1\n"));
        assert!(!annotated(b"held: int + str = 1\n"));
    }

    #[test]
    fn each_container_literal_reads_as_mutable() {
        assert!(assigned(b"held = []\n"));
        assert!(assigned(b"held = {}\n"));
        assert!(assigned(b"held = {1}\n"));
        assert!(assigned(b"held = [value for value in values]\n"));
        assert!(!assigned(b"held = ()\n"));
        assert!(!assigned(b"held = 1\n"));
    }

    #[test]
    fn each_container_constructor_reads_as_mutable() {
        assert!(assigned(b"held = list()\n"));
        assert!(assigned(b"held = dict()\n"));

        assert!(assigned(
            b"import collections\nheld = collections.defaultdict(list)\n"
        ));

        assert!(!assigned(b"held = tuple()\n"));
        assert!(!assigned(b"held = read()\n"));
    }
}
