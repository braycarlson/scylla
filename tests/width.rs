use core::fmt::Write as _;

use scylla::bounded::BoundedVec;
use scylla::language::{Language, Lexer as _};
use scylla::syntax::Structure;
use scylla::syntax::front::{self, Front, Limits, Options, Scratch};
use scylla::syntax::python::bind::{self, Outcome as BindOutcome, Tables};
use scylla::syntax::python::classify::classify;
use scylla::syntax::python::kind::PythonKind;
use scylla::syntax::python::parse;
use scylla::syntax::python::stdlib::PythonVersion;
use scylla::token::Tokens;
use scylla::tree::{Events, Tree};

const NAME_COUNT: usize = 4_096;

const LIMITS: Limits = Limits {
    binding_count_max: 1 << 16,
    error_count_max: 1 << 10,
    event_count_max: 1 << 22,
    export_count_max: 1 << 14,
    fact_count_max: 1 << 14,
    node_count_max: 1 << 20,
    reference_count_max: 1 << 16,
    scope_count_max: 1 << 14,
    segment_count_max: 1 << 14,
    token_count_max: 1 << 20,
};

struct Case {
    close: &'static str,
    language: Language,
    name: &'static str,
    open: &'static str,
}

const EVERY_PARAMETER_LIST: [Case; 8] = [
    Case {
        close: ") {}\n",
        language: Language::Go,
        name: "a parameter list",
        open: "package held\n\nfunc Held(",
    },
    Case {
        close: ") {}\n",
        language: Language::JavaScript,
        name: "a parameter list",
        open: "function held(",
    },
    Case {
        close: ") {}\n",
        language: Language::Odin,
        name: "a parameter list",
        open: "package held\n\nheld :: proc(",
    },
    Case {
        close: "):\n    pass\n",
        language: Language::Python,
        name: "a parameter list",
        open: "def held(",
    },
    Case {
        close: "):\n    pass\n",
        language: Language::Python,
        name: "a base class list",
        open: "class Held(",
    },
    Case {
        close: ") {}\n",
        language: Language::Rust,
        name: "a parameter list",
        open: "pub fn held(",
    },
    Case {
        close: ") {}\n",
        language: Language::TypeScript,
        name: "a parameter list",
        open: "function held(",
    },
    Case {
        close: ") void {}\n",
        language: Language::Zig,
        name: "a parameter list",
        open: "pub fn held(",
    },
];

const EVERY_PATTERN: [Case; 4] = [
    Case {
        close: "] = held;\n",
        language: Language::JavaScript,
        name: "an array pattern",
        open: "const [",
    },
    Case {
        close: "} = held;\n",
        language: Language::JavaScript,
        name: "an object pattern",
        open: "const {",
    },
    Case {
        close: "] = held;\n",
        language: Language::TypeScript,
        name: "an array pattern",
        open: "const [",
    },
    Case {
        close: "} = held;\n",
        language: Language::TypeScript,
        name: "an object pattern",
        open: "const {",
    },
];

fn typed(case: &Case, index: usize) -> String {
    match case.language {
        Language::Go => format!("n{index} int"),
        Language::Odin => format!("n{index}: int"),
        Language::Rust => format!("n{index}: u32"),
        Language::Zig => format!("n{index}: u32"),
        _ => format!("n{index}"),
    }
}

fn source_of(case: &Case, typed_names: bool) -> Vec<u8> {
    let mut held = String::from(case.open);

    for index in 0..NAME_COUNT {
        if index > 0 {
            held.push_str(", ");
        }

        if typed_names {
            held.push_str(&typed(case, index));

            continue;
        }

        let _ = write!(held, "n{index}");
    }

    held.push_str(case.close);

    held.into_bytes()
}

fn read(language: Language, source: &[u8]) -> (Structure, usize) {
    let mut front = Front::reserve(language, &LIMITS);
    let mut wanted = [false; Language::COUNT];

    wanted[language.index()] = true;

    let mut scratch = Scratch::reserve(&LIMITS, wanted);
    let mut lexed = Tokens::reserve(LIMITS.token_count_max);

    let options = Options {
        globals: &[],
        python_version: PythonVersion::Py310,
    };

    front::lexer_of(language)
        .expect("every case names a lexed language")
        .lex(source, &mut lexed);

    let outcome = front.build(source, lexed.as_slice(), &mut scratch, &options);

    (outcome, front.errors().len())
}

fn complete(case: &Case, typed_names: bool) {
    let source = source_of(case, typed_names);
    let (outcome, errors) = read(case.language, &source);

    assert_eq!(
        outcome,
        Structure::Complete,
        "{} reads {NAME_COUNT} names in {} as {outcome:?}",
        case.language.name(),
        case.name
    );

    assert_eq!(
        errors,
        0,
        "{} reads {NAME_COUNT} names in {} with {errors} errors",
        case.language.name(),
        case.name
    );
}

#[test]
fn a_wide_parameter_list_is_not_nesting() {
    for case in &EVERY_PARAMETER_LIST {
        complete(case, case.name == "a parameter list");
    }
}

#[test]
fn a_wide_pattern_is_not_nesting() {
    for case in &EVERY_PATTERN {
        complete(case, false);
    }
}

#[test]
fn a_wide_comprehension_reads_every_target() {
    let mut held = String::from("held = [x");

    for index in 0..NAME_COUNT {
        let _ = write!(held, " for x in s{index}");
    }

    held.push_str("]\n");

    let (outcome, errors) = read(Language::Python, held.as_bytes());

    assert_eq!(outcome, Structure::Complete, "{outcome:?}");
    assert_eq!(errors, 0, "{errors} errors");
}

fn bound(source: &[u8]) -> (Structure, bool, u32) {
    let mut lexed = Tokens::reserve(LIMITS.token_count_max);
    let mut tokens = Tokens::reserve(LIMITS.token_count_max);
    let mut raw = BoundedVec::<PythonKind>::reserve(LIMITS.token_count_max);
    let mut events = Events::reserve(LIMITS.event_count_max);
    let mut tree = Tree::<PythonKind>::reserve(LIMITS.node_count_max, LIMITS.error_count_max);

    scylla::lex::PYTHON.lex(source, &mut lexed);

    assert!(classify(source, lexed.as_slice(), &mut tokens, &mut raw));

    let parsed = parse::build(source, tokens.as_slice(), &raw, &mut events, &mut tree);

    let mut tables = Tables::reserve(
        LIMITS.scope_count_max,
        LIMITS.binding_count_max,
        LIMITS.reference_count_max,
        LIMITS.segment_count_max,
    );

    let held =
        bind::bind(source, tokens.as_slice(), &raw, &tree, &mut tables) == BindOutcome::Complete;

    (parsed, held, tables.bindings.count())
}

#[test]
fn the_binder_reads_a_flat_literal_of_any_width() {
    let mut held = String::from("held = [");

    for index in 0..NAME_COUNT {
        if index > 0 {
            held.push_str(", ");
        }

        held.push_str(&(index % 9).to_string());
    }

    held.push_str("]\n");

    let (parsed, complete, _) = bound(held.as_bytes());

    assert_eq!(parsed, Structure::Complete, "{parsed:?}");
    assert!(
        complete,
        "the binder truncated a flat literal of {NAME_COUNT}"
    );
}

#[test]
fn the_binder_reads_a_wide_target_tuple_in_full() {
    let mut held = String::new();

    for index in 0..NAME_COUNT {
        if index > 0 {
            held.push_str(", ");
        }

        let _ = write!(held, "n{index}");
    }

    held.push_str(" = xs\n");

    let (parsed, complete, bindings) = bound(held.as_bytes());

    assert_eq!(parsed, Structure::Complete, "{parsed:?}");
    assert!(complete, "the binder truncated a tuple of {NAME_COUNT}");

    assert_eq!(
        bindings,
        u32::try_from(NAME_COUNT).expect("the name count is small"),
        "the binder bound {bindings} of {NAME_COUNT} targets"
    );
}
