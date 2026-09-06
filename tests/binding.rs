use std::path::{Path, PathBuf};

use scylla::language::Language;
use scylla::syntax::Category;
use scylla::syntax::binding::{BindingClass, Bindings, Resolution};
use scylla::syntax::front::{self, Front, Limits, Options, Scratch};
use scylla::syntax::python::stdlib::PythonVersion;
use scylla::token::{Lex, Tokens};
use scylla::tree::Structure;

const LIMITS: Limits = Limits {
    binding_count_max: 1 << 12,
    error_count_max: 1 << 8,
    event_count_max: 1 << 18,
    export_count_max: 1 << 10,
    fact_count_max: 1 << 10,
    node_count_max: 1 << 16,
    reference_count_max: 1 << 13,
    scope_count_max: 1 << 10,
    segment_count_max: 1 << 10,
    token_count_max: 1 << 16,
};

const EVERY: [(Language, &str, &str); 6] = [
    (Language::Go, "go-semantic", "go"),
    (Language::JavaScript, "javascript-semantic", "js"),
    (Language::Odin, "odin-semantic", "odin"),
    (Language::Python, "python-semantic", "py"),
    (Language::Rust, "rust-semantic", "rs"),
    (Language::Zig, "zig-semantic", "zig"),
];

fn built(language: Language, source: &[u8]) -> Front {
    let mut front = Front::reserve(language, &LIMITS);
    let mut wanted = [false; Language::COUNT];

    wanted[language.index()] = true;

    let mut scratch = Scratch::reserve(&LIMITS, wanted);
    let mut lexed = Tokens::reserve(LIMITS.token_count_max);
    let scanner = front::lexer_of(language).expect("a code language has a lexer");

    assert_eq!(scanner.lex(source, &mut lexed), Lex::Complete);

    let options = Options {
        globals: &[],
        python_version: PythonVersion::Py310,
        template_imports: &[],
    };

    let outcome = front.build(source, lexed.as_slice(), &mut scratch, &options);

    assert_eq!(
        outcome,
        Structure::Complete,
        "{}",
        String::from_utf8_lossy(source)
    );

    front
}

fn fixtures(directory: &str, extension: &str) -> Vec<(String, Vec<u8>)> {
    let root = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("tests/fixtures")
        .join(directory);

    let mut found = Vec::new();

    collect(&root, extension, &mut found);
    found.sort();

    assert!(!found.is_empty(), "no fixtures under {}", root.display());

    found
        .into_iter()
        .map(|path| {
            (
                path.strip_prefix(&root)
                    .expect("under the root")
                    .to_string_lossy()
                    .into_owned(),
                std::fs::read(&path).expect("a fixture is readable"),
            )
        })
        .collect()
}

fn collect(directory: &Path, extension: &str, out: &mut Vec<PathBuf>) {
    let mut stack = vec![directory.to_path_buf()];

    while let Some(current) = stack.pop() {
        let Ok(entries) = std::fs::read_dir(&current) else {
            continue;
        };

        for entry in entries.flatten() {
            let path = entry.path();

            if path.is_dir() {
                stack.push(path);
            } else if path.extension().is_some_and(|held| held == extension) {
                out.push(path);
            }
        }
    }
}

#[test]
fn a_rust_function_binding_names_its_node_and_its_callers() {
    const SOURCE: &[u8] =
        b"fn run(one: u32) -> u32 {\n    run(one)\n}\n\nfn stop() {\n    run(1);\n}\n";

    let front = built(Language::Rust, SOURCE);
    let bindings = front.bindings();
    let mut functions = Vec::new();

    for index in 0..bindings.count() {
        let binding = bindings.at(index).expect("a binding");

        if binding.class == BindingClass::Function {
            functions.push((index, binding));
        }
    }

    assert_eq!(functions.len(), 2);

    let (index, run) = functions[0];

    assert_eq!(&SOURCE[run.name.range()], b"run");

    let node = front.view(run.node).expect("a view");

    let declaration = if node.category() == Category::Function {
        node
    } else {
        node.ancestor_of(Category::Function)
            .expect("a name under its function")
    };

    assert_eq!(declaration.category(), Category::Function);
    assert_eq!(declaration.span().offset, 0);

    let mut callers = 0;

    bindings.references_of(index, |reference| {
        assert_eq!(reference.resolution, Resolution::Bound(index));
        assert_eq!(&SOURCE[reference.name.range()], b"run");
        assert!(!reference.is_store);

        callers += 1;
    });

    assert_eq!(callers, 2);
}

#[test]
fn a_rust_macro_call_never_binds_the_function_that_shares_its_name() {
    const SOURCE: &[u8] =
        b"fn matches(interactive: bool) -> bool {\n    matches!(interactive, true)\n}\n";

    let front = built(Language::Rust, SOURCE);
    let bindings = front.bindings();
    let mut callers = 0;

    for index in 0..bindings.count() {
        let binding = bindings.at(index).expect("a binding");

        if binding.class != BindingClass::Function {
            continue;
        }

        bindings.references_of(index, |_| callers += 1);
    }

    assert_eq!(callers, 0);
}

#[test]
fn a_python_method_is_a_function_under_a_type_scope() {
    const SOURCE: &[u8] = b"class Held:\n    def run(self):\n        return self\n";

    let front = built(Language::Python, SOURCE);
    let bindings = front.bindings();
    let mut found = false;

    for index in 0..bindings.count() {
        let binding = bindings.at(index).expect("a binding");

        if binding.class != BindingClass::Function {
            continue;
        }

        let scope = bindings.scope_at(binding.scope).expect("a scope");

        assert_eq!(scope.class, scylla::syntax::binding::ScopeClass::Type);

        found = true;
    }

    assert!(found);
}

#[test]
fn a_front_without_a_complete_build_has_no_bindings() {
    let front = Front::reserve(Language::Rust, &LIMITS);

    assert!(matches!(front.bindings(), Bindings::Empty));
    assert_eq!(front.bindings().count(), 0);
}

#[test]
fn every_semantic_fixture_projects_its_bindings_and_references() {
    for (language, directory, extension) in EVERY {
        for (name, source) in fixtures(directory, extension) {
            let front = built(language, &source);
            let bindings = front.bindings();
            let count = bindings.count();

            for index in 0..count {
                let binding = bindings.at(index).expect("a binding");

                assert!(
                    binding.node < front.count(),
                    "{name}: a binding names a node"
                );

                assert!(
                    binding.scope < bindings.scope_count(),
                    "{name}: a binding names a scope"
                );

                if binding.class == BindingClass::Function {
                    let category = front.view(binding.node).expect("a view").category();

                    assert!(
                        matches!(
                            category,
                            Category::Function
                                | Category::Lambda
                                | Category::Name
                                | Category::Declaration
                        ),
                        "{name}: a function binding sits on a {}",
                        category.name()
                    );
                }

                bindings.references_of(index, |reference| {
                    assert_eq!(reference.resolution, Resolution::Bound(index), "{name}");
                    assert!(reference.node < front.count(), "{name}");
                });
            }

            for index in 0..bindings.reference_count() {
                let reference = bindings.reference_at(index).expect("a reference");

                if let Resolution::Bound(binding) = reference.resolution {
                    assert!(
                        binding < count,
                        "{name}: a reference names a binding in range"
                    );
                }
            }

            for scope in 0..bindings.scope_count() {
                let held = bindings.scope_at(scope).expect("a scope");

                assert!(
                    held.parent == u32::MAX || held.parent < bindings.scope_count(),
                    "{name}"
                );

                bindings.bindings_of(scope, |binding| assert!(binding < count, "{name}"));
            }
        }
    }
}
