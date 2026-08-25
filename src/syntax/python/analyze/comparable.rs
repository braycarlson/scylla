use crate::bounded::Buffer;
use crate::syntax::python::ast::{Literal, View};
use crate::syntax::python::kind::PythonKind;
use crate::syntax::python::literal::{self, Number, Outcome};
use crate::tree::{Step, walk_from};

pub fn equal(source: &[u8], left: View<'_>, right: View<'_>, scratch: &mut Buffer) -> bool {
    let mut ours = walk_from(left.tree(), left.index());
    let mut theirs = walk_from(right.tree(), right.index());
    let count = left.tree().count().max(right.tree().count());
    let steps = count.saturating_mul(2).saturating_add(2);

    for _ in 0..=steps {
        let held = (ours.next(), theirs.next());

        match held {
            (None, None) => return true,
            (Some(Step::Enter(one)), Some(Step::Enter(two))) => {
                if !nodes_equal(source, left.at(one), right.at(two), scratch) {
                    return false;
                }
            }
            (Some(Step::Leave(_)), Some(Step::Leave(_))) => {}
            (_, _) => return false,
        }
    }

    false
}

fn nodes_equal(source: &[u8], left: View<'_>, right: View<'_>, scratch: &mut Buffer) -> bool {
    if left.kind() != right.kind() {
        return false;
    }

    if left.kind() == PythonKind::Constant {
        return constants_equal(source, left, right, scratch);
    }

    let mut ours = left.positions();
    let mut theirs = right.positions();
    let steps = token_count_of(left).max(token_count_of(right));

    for _ in 0..=steps {
        let held = (ours.next(), theirs.next());

        match held {
            (None, None) => return true,
            (Some(one), Some(two)) => {
                if !tokens_equal(source, left, one, right, two) {
                    return false;
                }
            }
            (_, _) => return false,
        }
    }

    false
}

fn constants_equal(source: &[u8], left: View<'_>, right: View<'_>, scratch: &mut Buffer) -> bool {
    let Some(ours) = left.as_constant() else {
        return false;
    };

    let Some(theirs) = right.as_constant() else {
        return false;
    };

    let class = ours.literal_class();

    if class != theirs.literal_class() {
        return false;
    }

    if class == Literal::Number {
        return numbers_equal(source, left, right);
    }

    if matches!(class, Literal::Bytes | Literal::Text) {
        if let Some(found) = strings_equal(source, left, right, scratch) {
            return found;
        }
    }

    let mut one = left.positions();
    let mut two = right.positions();
    let steps = token_count_of(left).max(token_count_of(right));

    for _ in 0..=steps {
        match (one.next(), two.next()) {
            (None, None) => return true,
            (Some(first), Some(second)) => {
                if !tokens_equal(source, left, first, right, second) {
                    return false;
                }
            }
            (_, _) => return false,
        }
    }

    false
}

fn numbers_equal(source: &[u8], left: View<'_>, right: View<'_>) -> bool {
    let Some(one) = left.positions().next() else {
        return false;
    };

    let Some(two) = right.positions().next() else {
        return false;
    };

    let ours = left.token_at(one).text(source);
    let theirs = right.token_at(two).text(source);
    let first = literal::number_of(ours);
    let second = literal::number_of(theirs);

    if let Number::Integer(held) = first {
        if let Number::Integer(other) = second {
            return held == other;
        }
    }

    if left.token_kind(one) != right.token_kind(two) {
        return false;
    }

    ours == theirs
}

fn strings_equal(
    source: &[u8],
    left: View<'_>,
    right: View<'_>,
    scratch: &mut Buffer,
) -> Option<bool> {
    scratch.clear();

    if !pieces_decode(source, left, scratch) {
        return None;
    }

    let middle = scratch.count();

    if !pieces_decode(source, right, scratch) {
        return None;
    }

    let held = scratch.as_bytes();

    assert!(middle as usize <= held.len());

    Some(held[..middle as usize] == held[middle as usize..])
}

fn pieces_decode(source: &[u8], view: View<'_>, scratch: &mut Buffer) -> bool {
    let steps = token_count_of(view) as usize;

    for (seen, position) in view.positions().enumerate() {
        if seen == steps {
            return false;
        }

        let kind = view.token_kind(position);

        if kind == PythonKind::StringFormat {
            return false;
        }

        if !matches!(kind, PythonKind::StringBytes | PythonKind::StringPlain) {
            continue;
        }

        if literal::decode(view.token_at(position).text(source), scratch) != Outcome::Complete {
            return false;
        }
    }

    true
}

fn tokens_equal(source: &[u8], left: View<'_>, one: u32, right: View<'_>, two: u32) -> bool {
    let kind = left.token_kind(one);

    if kind != right.token_kind(two) {
        return false;
    }

    if !carries_text(kind) {
        return true;
    }

    left.token_at(one).text(source) == right.token_at(two).text(source)
}

fn token_count_of(view: View<'_>) -> u32 {
    let node = view.tree().at(view.index());

    node.token_end.saturating_sub(node.token_start)
}

const fn carries_text(kind: PythonKind) -> bool {
    matches!(
        kind,
        PythonKind::Identifier
            | PythonKind::NumberBinary
            | PythonKind::NumberComplex
            | PythonKind::NumberFloat
            | PythonKind::NumberHexadecimal
            | PythonKind::NumberInteger
            | PythonKind::NumberOctal
            | PythonKind::StringBytes
            | PythonKind::StringFormat
            | PythonKind::StringPlain
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::syntax::python::analyze::fixture::Fixture;

    fn compared(source: &[u8]) -> bool {
        let held = Fixture::of(source);
        let node = held.first(PythonKind::Compare);
        let view = held.view(node);
        let mut children = view.children();
        let left = children.next().expect("a left operand");
        let right = children.next().expect("a right operand");
        let mut scratch = Buffer::reserve(1 << 10);

        equal(&held.source, left, right, &mut scratch)
    }

    #[test]
    fn one_expression_written_twice_reads_as_equal() {
        assert!(compared(b"held = value.first == value.first\n"));
        assert!(compared(b"held = read(1, 2) == read(1, 2)\n"));
        assert!(compared(b"held = \"text\" == \"text\"\n"));
    }

    #[test]
    fn a_different_name_reads_as_unequal() {
        assert!(!compared(b"held = value.first == value.second\n"));
        assert!(!compared(b"held = read(1, 2) == read(1, 3)\n"));
        assert!(!compared(b"held = \"text\" == \"other\"\n"));
    }

    #[test]
    fn a_different_shape_reads_as_unequal() {
        assert!(!compared(b"held = value == value.first\n"));
        assert!(!compared(b"held = read(1) == read(1, 2)\n"));
    }

    #[test]
    fn a_constant_compares_by_value_rather_than_by_bytes() {
        assert!(compared(b"held = 'a' == \"a\"\n"));
        assert!(compared(b"held = 0x10 == 16\n"));
        assert!(compared(b"held = 1_000 == 1000\n"));
        assert!(compared(b"held = \"\\x41\" == \"A\"\n"));
        assert!(compared(b"held = \"a\" \"b\" == \"ab\"\n"));
        assert!(!compared(b"held = b\"a\" == \"a\"\n"));
        assert!(!compared(b"held = 0x10 == 17\n"));
        assert!(!compared(b"held = 1 == 1.0\n"));
    }

    #[test]
    fn a_long_implicit_concatenation_reads_as_equal_to_itself() {
        let mut source = Vec::from(b"held = ".as_slice());

        source.extend_from_slice(b"\"a\" \"a\" \"a\" \"a\" \"a\" \"a\" \"a\" \"a\"");
        source.extend_from_slice(b" == ");
        source.extend_from_slice(b"\"a\" \"a\" \"a\" \"a\" \"a\" \"a\" \"a\" \"a\"\n");

        assert!(compared(&source));
    }

    #[test]
    fn a_span_that_differs_changes_nothing() {
        let held = Fixture::of(b"held = value\nother = value\n");
        let first = held.view(held.nth(PythonKind::Name, 1));
        let second = held.view(held.nth(PythonKind::Name, 3));
        let mut scratch = Buffer::reserve(1 << 10);

        assert_eq!(first.text(&held.source), b"value");
        assert_eq!(second.text(&held.source), b"value");
        assert_ne!(first.index(), second.index());
        assert!(equal(&held.source, first, second, &mut scratch));
    }
}
