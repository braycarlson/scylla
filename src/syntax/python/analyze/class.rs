use crate::bounded::{BoundedVec, Span};
use crate::syntax::python::analyze::visibility::decorator_of;
use crate::syntax::python::ast::ClassDef;
use crate::syntax::python::semantic::Semantic;

const DATACLASSES: [(&[u8], &[u8]); 4] = [
    (b"attr", b"s"),
    (b"attrs", b"define"),
    (b"attrs", b"frozen"),
    (b"dataclasses", b"dataclass"),
];

const ENUMERATIONS: [&[u8]; 6] = [
    b"Enum",
    b"Flag",
    b"IntEnum",
    b"IntFlag",
    b"ReprEnum",
    b"StrEnum",
];

pub fn base_matches(
    source: &[u8],
    semantic: &Semantic,
    class: ClassDef<'_>,
    module: &[u8],
    member: &[u8],
    out: &mut BoundedVec<Span>,
) -> bool {
    class
        .bases()
        .any(|base| semantic.matches(source, base, module, member, out))
}

pub fn is_dataclass(
    source: &[u8],
    semantic: &Semantic,
    class: ClassDef<'_>,
    out: &mut BoundedVec<Span>,
) -> bool {
    for decorator in class.decorators() {
        let Some(held) = decorator_of(decorator) else {
            continue;
        };

        for (module, member) in DATACLASSES {
            if semantic.matches(source, held, module, member, out) {
                return true;
            }
        }
    }

    false
}

pub fn is_enumeration(
    source: &[u8],
    semantic: &Semantic,
    class: ClassDef<'_>,
    out: &mut BoundedVec<Span>,
) -> bool {
    ENUMERATIONS
        .iter()
        .any(|member| base_matches(source, semantic, class, b"enum", member, out))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::syntax::python::analyze::fixture::Fixture;
    use crate::syntax::python::kind::PythonKind;

    #[derive(Clone, Copy)]
    enum Question {
        Dataclass,
        Enumeration,
    }

    fn asked(source: &[u8], question: Question) -> bool {
        let held = Fixture::of(source);
        let node = held.first(PythonKind::ClassDef);
        let view = held.view(node).as_class().expect("a class");
        let mut out = BoundedVec::reserve(1 << 8);

        match question {
            Question::Dataclass => is_dataclass(&held.source, &held.semantic, view, &mut out),
            Question::Enumeration => is_enumeration(&held.source, &held.semantic, view, &mut out),
        }
    }

    #[test]
    fn a_base_reads_through_the_import_that_bound_it() {
        let held = Fixture::of(b"import enum\nclass Held(enum.Enum):\n    pass\n");
        let node = held.first(PythonKind::ClassDef);
        let view = held.view(node).as_class().expect("a class");
        let mut out = BoundedVec::reserve(1 << 8);

        assert!(base_matches(
            &held.source,
            &held.semantic,
            view,
            b"enum",
            b"Enum",
            &mut out
        ));

        assert!(!base_matches(
            &held.source,
            &held.semantic,
            view,
            b"enum",
            b"Flag",
            &mut out
        ));
    }

    #[test]
    fn each_enum_base_reads_as_an_enumeration() {
        assert!(asked(
            b"from enum import Enum\nclass Held(Enum):\n    pass\n",
            Question::Enumeration
        ));

        assert!(asked(
            b"import enum\nclass Held(enum.IntFlag):\n    pass\n",
            Question::Enumeration
        ));

        assert!(!asked(
            b"class Held(object):\n    pass\n",
            Question::Enumeration
        ));
    }

    #[test]
    fn each_dataclass_decorator_reads_as_a_dataclass() {
        assert!(asked(
            b"import dataclasses\n@dataclasses.dataclass\nclass Held:\n    pass\n",
            Question::Dataclass
        ));

        assert!(asked(
            b"from dataclasses import dataclass\n@dataclass(frozen=True)\nclass Held:\n    pass\n",
            Question::Dataclass
        ));

        assert!(asked(
            b"import attrs\n@attrs.frozen\nclass Held:\n    pass\n",
            Question::Dataclass
        ));

        assert!(!asked(b"class Held:\n    pass\n", Question::Dataclass));
    }
}
