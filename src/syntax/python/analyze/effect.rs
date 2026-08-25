use crate::bounded::{BoundedVec, Span};
use crate::syntax::python::ast::View;
use crate::syntax::python::kind::PythonKind;
use crate::syntax::python::semantic::{Qualified, Semantic};
use crate::tree::{Step, walk_from};

const EMPTY_BUILDERS: [&[u8]; 5] = [b"dict", b"frozenset", b"list", b"set", b"tuple"];

pub fn contains_effect(
    source: &[u8],
    semantic: &Semantic,
    view: View<'_>,
    out: &mut BoundedVec<Span>,
) -> bool {
    for step in walk_from(view.tree(), view.index()) {
        let Step::Enter(node) = step else {
            continue;
        };

        let held = view.at(node);

        if held.kind() == PythonKind::Call {
            if empty_builder(source, semantic, held, out) {
                continue;
            }

            return true;
        }

        if matches!(
            held.kind(),
            PythonKind::Await
                | PythonKind::NamedExpr
                | PythonKind::Subscript
                | PythonKind::Yield
                | PythonKind::YieldFrom
        ) {
            return true;
        }

        if operates_on_value(held) {
            return true;
        }
    }

    false
}

fn empty_builder(
    source: &[u8],
    semantic: &Semantic,
    call: View<'_>,
    out: &mut BoundedVec<Span>,
) -> bool {
    if call.children().count() != 1 {
        return false;
    }

    let Some(callee) = call.child_first() else {
        return false;
    };

    if callee.kind() != PythonKind::Name {
        return false;
    }

    if semantic.qualified_name_of(source, callee, out) != Qualified::Builtin {
        return false;
    }

    EMPTY_BUILDERS.contains(&callee.text(source))
}

fn operates_on_value(view: View<'_>) -> bool {
    if !matches!(
        view.kind(),
        PythonKind::BinOp | PythonKind::Compare | PythonKind::UnaryOp
    ) {
        return false;
    }

    view.children()
        .any(|held| held.kind() != PythonKind::Constant)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::syntax::python::analyze::fixture::Fixture;

    fn assigned(source: &[u8]) -> bool {
        let held = Fixture::of(source);
        let node = held.first(PythonKind::Assign);
        let view = held.view(node);
        let value = view.children().last().expect("a value");
        let mut out = BoundedVec::reserve(1 << 8);

        contains_effect(&held.source, &held.semantic, value, &mut out)
    }

    #[test]
    fn a_call_that_is_no_empty_builtin_runs_code() {
        assert!(assigned(b"held = read()\n"));
        assert!(assigned(b"held = list(values)\n"));
        assert!(assigned(b"held = value[0]\n"));
    }

    #[test]
    fn an_empty_builtin_constructor_runs_nothing() {
        assert!(!assigned(b"held = list()\n"));
        assert!(!assigned(b"held = dict()\n"));
        assert!(!assigned(b"held = set()\n"));
    }

    #[test]
    fn an_operator_over_two_literals_runs_nothing() {
        assert!(!assigned(b"held = 1 + 2\n"));
        assert!(!assigned(b"held = -1\n"));
        assert!(!assigned(b"held = 1 < 2\n"));
    }

    #[test]
    fn an_operator_over_a_name_runs_whatever_the_name_carries() {
        assert!(assigned(b"held = value + 1\n"));
        assert!(assigned(b"held = -value\n"));
    }

    #[test]
    fn a_walrus_and_an_await_both_run_code() {
        assert!(assigned(b"held = (other := 1)\n"));

        let source = b"async def read(value):\n    held = await value\n";
        let fixture = Fixture::of(source);
        let node = fixture.first(PythonKind::Assign);
        let view = fixture.view(node);
        let value = view.children().last().expect("a value");
        let mut out = BoundedVec::reserve(1 << 8);

        assert!(contains_effect(
            &fixture.source,
            &fixture.semantic,
            value,
            &mut out
        ));
    }

    #[test]
    fn a_plain_name_and_a_literal_run_nothing() {
        assert!(!assigned(b"held = value\n"));
        assert!(!assigned(b"held = \"text\"\n"));
        assert!(!assigned(b"held = [1, 2]\n"));
    }
}
