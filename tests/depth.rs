use scylla::language::Language;
use scylla::syntax::Structure;
use scylla::syntax::front::{self, Front, Limits, Options, Scratch};
use scylla::syntax::python::stdlib::PythonVersion;
use scylla::token::Tokens;

const ELEMENT_COUNT: usize = 4_096;

const LIMITS: Limits = Limits {
    binding_count_max: 1 << 14,
    error_count_max: 1 << 10,
    event_count_max: 1 << 22,
    export_count_max: 1 << 12,
    fact_count_max: 1 << 12,
    node_count_max: 1 << 20,
    reference_count_max: 1 << 14,
    scope_count_max: 1 << 12,
    segment_count_max: 1 << 12,
    token_count_max: 1 << 20,
};

struct Case {
    close: &'static str,
    language: Language,
    open: &'static str,
    separator: &'static str,
}

const EVERY_CASE: [Case; 8] = [
    Case {
        close: "}\n",
        language: Language::Css,
        open: ":root {\n",
        separator: "",
    },
    Case {
        close: "}\n",
        language: Language::Go,
        open: "package held\n\nvar Held = []int{",
        separator: ", ",
    },
    Case {
        close: "];\n",
        language: Language::JavaScript,
        open: "const held = [",
        separator: ", ",
    },
    Case {
        close: "}\n",
        language: Language::Odin,
        open: "package held\n\nheld := []int{",
        separator: ", ",
    },
    Case {
        close: "]\n",
        language: Language::Python,
        open: "held = [",
        separator: ", ",
    },
    Case {
        close: "];\n",
        language: Language::Rust,
        open: "pub const HELD: &[u32] = &[",
        separator: ", ",
    },
    Case {
        close: "];\n",
        language: Language::TypeScript,
        open: "const held = [",
        separator: ", ",
    },
    Case {
        close: "};\n",
        language: Language::Zig,
        open: "pub const held = [_]u32{",
        separator: ", ",
    },
];

fn source_of(case: &Case) -> Vec<u8> {
    let mut held = String::from(case.open);

    for index in 0..ELEMENT_COUNT {
        if index > 0 {
            held.push_str(case.separator);
        }

        if case.language == Language::Css {
            held.push_str("    --k");
            held.push_str(&index.to_string());
            held.push_str(": 0;\n");

            continue;
        }

        held.push_str(&(index % 9).to_string());
    }

    held.push_str(case.close);

    held.into_bytes()
}

fn read(case: &Case, source: &[u8]) -> (Structure, usize) {
    let mut front = Front::reserve(case.language, &LIMITS);
    let mut wanted = [false; Language::COUNT];

    wanted[case.language.index()] = true;

    let mut scratch = Scratch::reserve(&LIMITS, wanted);
    let mut lexed = Tokens::reserve(LIMITS.token_count_max);

    let options = Options {
        globals: &[],
        python_version: PythonVersion::Py310,
        template_imports: &[],
    };

    front::lexer_of(case.language)
        .expect("every case names a lexed language")
        .lex(source, &mut lexed);

    let outcome = front.build(source, lexed.as_slice(), &mut scratch, &options);

    (outcome, front.errors().len())
}

#[test]
fn a_flat_literal_of_four_thousand_elements_is_not_nesting() {
    for case in &EVERY_CASE {
        let source = source_of(case);
        let (outcome, errors) = read(case, &source);

        assert_eq!(
            outcome,
            Structure::Complete,
            "{} reads {ELEMENT_COUNT} flat elements as {outcome:?}",
            case.language.name()
        );

        assert_eq!(
            errors,
            0,
            "{} reads {ELEMENT_COUNT} flat elements with {errors} errors",
            case.language.name()
        );
    }
}
