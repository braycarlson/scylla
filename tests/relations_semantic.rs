use scylla::bounded::{BoundedVec, Span};
use scylla::language::Lexer as _;
use scylla::lex::{GO, JAVASCRIPT, ODIN, PYTHON, RUST, TYPESCRIPT, ZIG};
use scylla::syntax::Structure;
use scylla::syntax::typescript::dialect::Dialect;
use scylla::token::Tokens;
use scylla::tree::{Events, NONE, Tree};

const ERROR_COUNT_MAX: u32 = 1 << 12;
const EVENT_COUNT_MAX: u32 = 1 << 18;
const NODE_COUNT_MAX: u32 = 1 << 16;
const TABLE_COUNT_MAX: u32 = 1 << 12;
const TOKEN_COUNT_MAX: u32 = 1 << 16;

const EVERY_LANGUAGE: [Language; 7] = [
    Language {
        comment: b"# scylla\n",
        directory: "tests/fixtures/python-semantic",
        extension: "py",
        name: "python",
        summary: python,
        wrapped: None,
    },
    Language {
        comment: b"// scylla\n",
        directory: "tests/fixtures/javascript-semantic",
        extension: "js",
        name: "javascript",
        summary: javascript,
        wrapped: Some(Wrapped {
            plain: b"const one = 1;\n\nfunction run() {\n    return one;\n}\n",
            wrapped: b"const one = 1;\n\nfunction run() {\n    {\n        return one;\n    }\n}\n",
        }),
    },
    Language {
        comment: b"// scylla\n",
        directory: "tests/fixtures/typescript-semantic",
        extension: "ts",
        name: "typescript",
        summary: typescript,
        wrapped: Some(Wrapped {
            plain: b"const one: number = 1;\n\nfunction run(): number {\n    return one;\n}\n",
            wrapped: b"const one: number = 1;\n\nfunction run(): number {\n    {\
                \n        return one;\n    }\n}\n",
        }),
    },
    Language {
        comment: b"// scylla\n",
        directory: "tests/fixtures/go-semantic",
        extension: "go",
        name: "go",
        summary: go,
        wrapped: Some(Wrapped {
            plain: b"package sample\n\nconst one = 1\n\nfunc run() int {\n\treturn one\n}\n",
            wrapped: b"package sample\n\nconst one = 1\n\nfunc run() int {\n\t{\n\t\treturn one\
                \n\t}\n}\n",
        }),
    },
    Language {
        comment: b"// scylla\n",
        directory: "tests/fixtures/rust-semantic",
        extension: "rs",
        name: "rust",
        summary: rust,
        wrapped: Some(Wrapped {
            plain: b"const ONE: usize = 1;\n\nfn run() -> usize {\n    ONE\n}\n",
            wrapped: b"const ONE: usize = 1;\n\nfn run() -> usize {\n    {\n        ONE\n    }\n}\
                \n",
        }),
    },
    Language {
        comment: b"// scylla\n",
        directory: "tests/fixtures/zig-semantic",
        extension: "zig",
        name: "zig",
        summary: zig,
        wrapped: Some(Wrapped {
            plain: b"const one: usize = 1;\n\nfn run() usize {\n    return one;\n}\n",
            wrapped:
                b"const one: usize = 1;\n\nfn run() usize {\n    {\n        return one;\n    }\
                \n}\n",
        }),
    },
    Language {
        comment: b"// scylla\n",
        directory: "tests/fixtures/odin-semantic",
        extension: "odin",
        name: "odin",
        summary: odin,
        wrapped: Some(Wrapped {
            plain: b"package sample\n\nONE :: 1\n\nrun :: proc() -> int {\n\treturn ONE\n}\n",
            wrapped: b"package sample\n\nONE :: 1\n\nrun :: proc() -> int {\n\t{\n\t\treturn ONE\
                \n\t}\n}\n",
        }),
    },
];

const UNIVERSE: [&[u8]; 12] = [
    b"None",
    b"Self",
    b"Some",
    b"bool",
    b"console",
    b"error",
    b"int",
    b"len",
    b"print",
    b"string",
    b"usize",
    b"void",
];

struct Language {
    comment: &'static [u8],
    directory: &'static str,
    extension: &'static str,
    name: &'static str,
    summary: fn(&[u8]) -> Option<Summary>,
    wrapped: Option<Wrapped>,
}

struct Wrapped {
    plain: &'static [u8],
    wrapped: &'static [u8],
}

#[derive(Debug, Eq, PartialEq)]
struct Summary {
    bindings: Vec<String>,
    chain: Vec<(u32, u32)>,
    offsets: Vec<u32>,
    parents: Vec<u32>,
    references: Vec<String>,
    scopes: Vec<String>,
}

impl Summary {
    fn blank() -> Self {
        Self {
            bindings: Vec::new(),
            chain: Vec::new(),
            offsets: Vec::new(),
            parents: Vec::new(),
            references: Vec::new(),
            scopes: Vec::new(),
        }
    }
}

struct Rows<'run> {
    source: &'run [u8],
}

impl Rows<'_> {
    fn text_of(&self, name: Span) -> String {
        String::from_utf8_lossy(&self.source[name.range()]).into_owned()
    }
}

fn fixtures(directory: &str, extension: &str) -> Vec<(String, Vec<u8>)> {
    let root = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR")).join(directory);

    let Ok(entries) = std::fs::read_dir(&root) else {
        return Vec::new();
    };

    let mut found = Vec::new();

    for entry in entries.flatten() {
        let path = entry.path();

        if path.extension().and_then(|held| held.to_str()) != Some(extension) {
            continue;
        }

        let Ok(source) = std::fs::read(&path) else {
            continue;
        };

        found.push((
            path.file_name()
                .unwrap_or_default()
                .to_string_lossy()
                .into_owned(),
            source,
        ));
    }

    found.sort();

    found
}

fn renaming(source: &[u8], held: &Summary) -> Option<(String, String)> {
    for row in &held.bindings {
        let name = row.split(' ').nth(1)?;

        if name.len() < 3 || !name.bytes().all(|byte| byte.is_ascii_alphanumeric()) {
            continue;
        }

        if !name.starts_with(|byte: char| byte.is_ascii_alphabetic()) {
            continue;
        }

        let mut replacement = String::from("zq");

        while replacement.len() < name.len() {
            replacement.push('x');
        }

        if find(source, replacement.as_bytes()).is_some() {
            continue;
        }

        return Some((name.to_owned(), replacement));
    }

    None
}

fn find(source: &[u8], needle: &[u8]) -> Option<usize> {
    source.windows(needle.len()).position(|held| held == needle)
}

fn renamed(source: &[u8], name: &str, replacement: &str) -> Vec<u8> {
    let held = name.as_bytes();
    let mut found = Vec::with_capacity(source.len());
    let mut offset = 0;

    while offset < source.len() {
        if offset + held.len() <= source.len()
            && &source[offset..offset + held.len()] == held
            && !bounded(source, offset.wrapping_sub(1))
            && !bounded(source, offset + held.len())
        {
            found.extend_from_slice(replacement.as_bytes());
            offset += held.len();

            continue;
        }

        found.push(source[offset]);
        offset += 1;
    }

    found
}

fn bounded(source: &[u8], offset: usize) -> bool {
    source
        .get(offset)
        .is_some_and(|held| held.is_ascii_alphanumeric() || *held == b'_')
}

fn walks_to(held: &Summary, reference: u32, binding: u32) -> bool {
    let mut scope = reference;
    let mut steps = 0;

    while scope != NONE && steps <= held.parents.len() {
        if scope == binding {
            return true;
        }

        scope = held.parents[scope as usize];
        steps += 1;
    }

    false
}

fn swapped(row: &str, name: &str, replacement: &str) -> String {
    row.split(' ')
        .map(|word| if word == name { replacement } else { word })
        .collect::<Vec<&str>>()
        .join(" ")
}

fn substituted(held: &Summary, name: &str, replacement: &str) -> Summary {
    Summary {
        bindings: held
            .bindings
            .iter()
            .map(|row| swapped(row, name, replacement))
            .collect(),
        chain: held.chain.clone(),
        offsets: held.offsets.clone(),
        parents: held.parents.clone(),
        references: held
            .references
            .iter()
            .map(|row| swapped(row, name, replacement))
            .collect(),
        scopes: held.scopes.clone(),
    }
}

#[test]
fn every_reference_names_a_binding_on_its_own_scope_chain() {
    let mut compared = 0;

    for language in &EVERY_LANGUAGE {
        for (name, source) in fixtures(language.directory, language.extension) {
            let Some(held) = (language.summary)(&source) else {
                panic!("{}: {name} does not build", language.name);
            };

            for (reference, binding) in &held.chain {
                assert!(
                    walks_to(&held, *reference, *binding),
                    "{}: {name} resolves a reference outside its own scope chain",
                    language.name
                );
            }

            compared += 1;
        }
    }

    assert!(compared > 20, "the fixtures went missing");
}

#[test]
fn renaming_one_identifier_throughout_a_file_changes_no_resolution() {
    let mut compared = 0;

    for language in &EVERY_LANGUAGE {
        for (name, source) in fixtures(language.directory, language.extension) {
            let Some(held) = (language.summary)(&source) else {
                panic!("{}: {name} does not build", language.name);
            };

            let Some((from, to)) = renaming(&source, &held) else {
                continue;
            };

            let written = renamed(&source, &from, &to);

            assert_eq!(written.len(), source.len(), "{}: {name}", language.name);

            let Some(found) = (language.summary)(&written) else {
                panic!("{}: {name} does not build once renamed", language.name);
            };

            assert_eq!(
                found,
                substituted(&held, &from, &to),
                "{}: {name} reads {from} as {to} differently",
                language.name
            );

            compared += 1;
        }
    }

    assert!(compared > 20, "the fixtures went missing");
}

#[test]
fn prepending_a_comment_shifts_every_span_and_changes_nothing_else() {
    let mut compared = 0;

    for language in &EVERY_LANGUAGE {
        for (name, source) in fixtures(language.directory, language.extension) {
            let Some(held) = (language.summary)(&source) else {
                panic!("{}: {name} does not build", language.name);
            };

            let mut written = language.comment.to_vec();

            written.extend_from_slice(&source);

            let Some(found) = (language.summary)(&written) else {
                panic!("{}: {name} does not build under a comment", language.name);
            };

            let delta = scylla::bounded::count_of(language.comment.len());

            assert_eq!(found.bindings, held.bindings, "{}: {name}", language.name);

            assert_eq!(
                found.references,
                held.references,
                "{}: {name}",
                language.name
            );

            assert_eq!(found.scopes, held.scopes, "{}: {name}", language.name);

            assert_eq!(
                found.offsets,
                held.offsets
                    .iter()
                    .map(|offset| offset + delta)
                    .collect::<Vec<u32>>(),
                "{}: {name} does not shift its spans",
                language.name
            );

            compared += 1;
        }
    }

    assert!(compared > 20, "the fixtures went missing");
}

#[test]
fn wrapping_a_body_in_one_block_adds_one_scope_and_moves_no_resolution() {
    let mut compared = 0;

    for language in &EVERY_LANGUAGE {
        let Some(held) = language.wrapped.as_ref() else {
            continue;
        };
        let Some(plain) = (language.summary)(held.plain) else {
            panic!("{}: the plain source does not build", language.name);
        };
        let Some(found) = (language.summary)(held.wrapped) else {
            panic!("{}: the wrapped source does not build", language.name);
        };

        assert_eq!(
            found.scopes.len(),
            plain.scopes.len() + 1,
            "{}: wrapping a body adds more than one scope",
            language.name
        );

        assert_eq!(
            found.references,
            plain.references,
            "{}: wrapping a body moves a resolution",
            language.name
        );

        compared += 1;
    }

    assert!(compared == 6, "a language lost its wrapped pair");
}

fn python(source: &[u8]) -> Option<Summary> {
    use scylla::syntax::python::bind::{self, Outcome as BindOutcome, Tables};
    use scylla::syntax::python::classify::classify;
    use scylla::syntax::python::kind::PythonKind;
    use scylla::syntax::python::parse;
    use scylla::syntax::python::semantic::{AnnotationScratch, Semantic, SemanticInput};
    use scylla::syntax::python::stdlib::PythonVersion::Py310;

    let mut lexed = Tokens::reserve(TOKEN_COUNT_MAX);
    let mut tokens = Tokens::reserve(TOKEN_COUNT_MAX);
    let mut raw = BoundedVec::reserve(TOKEN_COUNT_MAX);
    let mut events = Events::reserve(EVENT_COUNT_MAX);
    let mut tree = Tree::<PythonKind>::reserve(NODE_COUNT_MAX, ERROR_COUNT_MAX);
    let counts = TABLE_COUNT_MAX;
    let mut tables = Tables::reserve(counts, counts, counts, counts);
    let mut semantic = Semantic::reserve(counts, counts, counts);
    let mut scratch = AnnotationScratch::reserve(1 << 8, 1 << 8);

    PYTHON.lex(source, &mut lexed);

    if !classify(source, lexed.as_slice(), &mut tokens, &mut raw) {
        return None;
    }

    parse::build(source, tokens.as_slice(), &raw, &mut events, &mut tree);

    if bind::bind(source, tokens.as_slice(), &raw, &tree, &mut tables) != BindOutcome::Complete {
        return None;
    }

    let built = semantic.build(
        &SemanticInput {
            builtins: &UNIVERSE,
            raw: &raw,
            scopes: &tables,
            source,
            tokens: tokens.as_slice(),
            tree: &tree,
            version: Py310,
        },
        &mut scratch,
    );

    if built != Structure::Complete {
        return None;
    }

    Some(python_summary(&semantic, source))
}

fn python_summary(semantic: &scylla::syntax::python::semantic::Semantic, source: &[u8]) -> Summary {
    use scylla::syntax::python::semantic::Resolution;

    let rows = Rows { source };
    let mut summary = Summary::blank();

    for held in semantic.scopes() {
        summary.parents.push(held.parent);

        summary
            .scopes
            .push(format!("{:?} {}", held.kind, i64::from(held.parent)));
    }

    for held in semantic.bindings() {
        summary.offsets.push(held.name.offset);

        summary.bindings.push(format!(
            "{:?} {} {}",
            held.kind,
            rows.text_of(held.name),
            held.scope
        ));
    }

    for held in semantic.references() {
        let target = match held.resolution {
            Resolution::Bound(bound) => {
                let binding = semantic.bindings()[bound as usize];

                summary.chain.push((held.scope, binding.scope));

                format!("{} {}", rows.text_of(binding.name), binding.scope)
            }
            Resolution::Builtin => "Builtin".to_owned(),
            Resolution::Maybe => "Maybe".to_owned(),
            Resolution::Unresolved => "Unresolved".to_owned(),
        };

        summary
            .references
            .push(format!("{} {target}", rows.text_of(held.name)));
    }

    summary
}

fn javascript(source: &[u8]) -> Option<Summary> {
    use scylla::syntax::javascript::classify::classify;
    use scylla::syntax::javascript::kind::JavaScriptKind;
    use scylla::syntax::javascript::parse;
    use scylla::syntax::javascript::semantic::{Resolution, Semantic};

    let mut lexed = Tokens::reserve(TOKEN_COUNT_MAX);
    let mut tokens = Tokens::reserve(TOKEN_COUNT_MAX);
    let mut raw = BoundedVec::reserve(TOKEN_COUNT_MAX);
    let mut events = Events::reserve(EVENT_COUNT_MAX);
    let mut tree = Tree::<JavaScriptKind>::reserve(NODE_COUNT_MAX, ERROR_COUNT_MAX);

    let mut semantic = Semantic::reserve(
        TABLE_COUNT_MAX,
        TABLE_COUNT_MAX,
        TABLE_COUNT_MAX,
        TABLE_COUNT_MAX,
    );

    JAVASCRIPT.lex(source, &mut lexed);

    if !classify(source, lexed.as_slice(), &mut tokens, &mut raw) {
        return None;
    }

    parse::build(source, tokens.as_slice(), &raw, &mut events, &mut tree);

    if semantic.build(source, tokens.as_slice(), &raw, &tree, None, &UNIVERSE)
        != Structure::Complete
    {
        return None;
    }

    let rows = Rows { source };
    let mut summary = Summary::blank();

    for held in semantic.scopes() {
        summary.parents.push(held.parent);

        summary
            .scopes
            .push(format!("{:?} {}", held.kind, i64::from(held.parent)));
    }

    for held in semantic.bindings() {
        summary.offsets.push(held.name.offset);

        summary.bindings.push(format!(
            "{:?} {} {}",
            held.kind,
            rows.text_of(held.name),
            held.scope
        ));
    }

    for held in semantic.references() {
        let target = match held.resolution {
            Resolution::Bound(bound) => {
                let binding = semantic.bindings()[bound as usize];

                summary.chain.push((held.scope, binding.scope));

                format!("{} {}", rows.text_of(binding.name), binding.scope)
            }
            Resolution::Builtin => "Builtin".to_owned(),
            Resolution::Maybe => "Maybe".to_owned(),
            Resolution::Unresolved => "Unresolved".to_owned(),
        };

        summary
            .references
            .push(format!("{} {target}", rows.text_of(held.name)));
    }

    Some(summary)
}

fn typescript(source: &[u8]) -> Option<Summary> {
    use scylla::syntax::javascript::semantic::{Resolution, Semantic};
    use scylla::syntax::typescript::classify::classify;
    use scylla::syntax::typescript::kind::TypeScriptKind;
    use scylla::syntax::typescript::parse;

    let mut lexed = Tokens::reserve(TOKEN_COUNT_MAX);
    let mut tokens = Tokens::reserve(TOKEN_COUNT_MAX);
    let mut raw = BoundedVec::reserve(TOKEN_COUNT_MAX);
    let mut events = Events::reserve(EVENT_COUNT_MAX);
    let mut tree = Tree::<TypeScriptKind>::reserve(NODE_COUNT_MAX, ERROR_COUNT_MAX);

    let mut semantic = Semantic::reserve(
        TABLE_COUNT_MAX,
        TABLE_COUNT_MAX,
        TABLE_COUNT_MAX,
        TABLE_COUNT_MAX,
    );

    TYPESCRIPT.lex(source, &mut lexed);

    if !classify(source, lexed.as_slice(), &mut tokens, &mut raw, Dialect::Ts) {
        return None;
    }

    parse::build(
        source,
        tokens.as_slice(),
        &raw,
        &mut events,
        &mut tree,
        Dialect::Ts,
    );

    if semantic.build(source, tokens.as_slice(), &raw, &tree, None, &UNIVERSE)
        != Structure::Complete
    {
        return None;
    }

    let rows = Rows { source };
    let mut summary = Summary::blank();

    for held in semantic.scopes() {
        summary.parents.push(held.parent);

        summary
            .scopes
            .push(format!("{:?} {}", held.kind, i64::from(held.parent)));
    }

    for held in semantic.bindings() {
        summary.offsets.push(held.name.offset);

        summary.bindings.push(format!(
            "{:?} {} {}",
            held.kind,
            rows.text_of(held.name),
            held.scope
        ));
    }

    for held in semantic.references() {
        let target = match held.resolution {
            Resolution::Bound(bound) => {
                let binding = semantic.bindings()[bound as usize];

                summary.chain.push((held.scope, binding.scope));

                format!("{} {}", rows.text_of(binding.name), binding.scope)
            }
            Resolution::Builtin => "Builtin".to_owned(),
            Resolution::Maybe => "Maybe".to_owned(),
            Resolution::Unresolved => "Unresolved".to_owned(),
        };

        summary
            .references
            .push(format!("{} {target}", rows.text_of(held.name)));
    }

    Some(summary)
}

fn go(source: &[u8]) -> Option<Summary> {
    use scylla::syntax::go::classify::classify;
    use scylla::syntax::go::kind::GoKind;
    use scylla::syntax::go::parse;
    use scylla::syntax::go::semantic::{Resolution, Semantic};

    let mut lexed = Tokens::reserve(TOKEN_COUNT_MAX);
    let mut tokens = Tokens::reserve(TOKEN_COUNT_MAX);
    let mut raw = BoundedVec::reserve(TOKEN_COUNT_MAX);
    let mut events = Events::reserve(EVENT_COUNT_MAX);
    let mut tree = Tree::<GoKind>::reserve(NODE_COUNT_MAX, ERROR_COUNT_MAX);

    let mut semantic = Semantic::reserve(
        TABLE_COUNT_MAX,
        TABLE_COUNT_MAX,
        TABLE_COUNT_MAX,
        TABLE_COUNT_MAX,
    );

    GO.lex(source, &mut lexed);

    if !classify(source, lexed.as_slice(), &mut tokens, &mut raw) {
        return None;
    }

    parse::build(source, tokens.as_slice(), &raw, &mut events, &mut tree);

    if semantic.build(source, tokens.as_slice(), &raw, &tree, &UNIVERSE) != Structure::Complete {
        return None;
    }

    let rows = Rows { source };
    let mut summary = Summary::blank();

    for held in semantic.scopes() {
        summary.parents.push(held.parent);

        summary
            .scopes
            .push(format!("{:?} {}", held.kind, i64::from(held.parent)));
    }

    for held in semantic.bindings() {
        summary.offsets.push(held.name.offset);

        summary.bindings.push(format!(
            "{:?} {} {}",
            held.kind,
            rows.text_of(held.name),
            held.scope
        ));
    }

    for held in semantic.references() {
        let target = match held.resolution {
            Resolution::Bound(bound) => {
                let binding = semantic.bindings()[bound as usize];

                summary.chain.push((held.scope, binding.scope));

                format!("{} {}", rows.text_of(binding.name), binding.scope)
            }
            Resolution::Builtin => "Builtin".to_owned(),
            Resolution::Maybe => "Maybe".to_owned(),
            Resolution::Unresolved => "Unresolved".to_owned(),
        };

        summary
            .references
            .push(format!("{} {target}", rows.text_of(held.name)));
    }

    Some(summary)
}

fn rust(source: &[u8]) -> Option<Summary> {
    use scylla::syntax::rust::classify::classify;
    use scylla::syntax::rust::kind::RustKind;
    use scylla::syntax::rust::parse;
    use scylla::syntax::rust::semantic::{Resolution, Semantic};

    let mut lexed = Tokens::reserve(TOKEN_COUNT_MAX);
    let mut tokens = Tokens::reserve(TOKEN_COUNT_MAX);
    let mut raw = BoundedVec::reserve(TOKEN_COUNT_MAX);
    let mut events = Events::reserve(EVENT_COUNT_MAX);
    let mut tree = Tree::<RustKind>::reserve(NODE_COUNT_MAX, ERROR_COUNT_MAX);

    let mut semantic = Semantic::reserve(
        TABLE_COUNT_MAX,
        TABLE_COUNT_MAX,
        TABLE_COUNT_MAX,
        TABLE_COUNT_MAX,
    );

    RUST.lex(source, &mut lexed);

    if !classify(source, lexed.as_slice(), &mut tokens, &mut raw) {
        return None;
    }

    parse::build(source, tokens.as_slice(), &raw, &mut events, &mut tree);

    if semantic.build(source, tokens.as_slice(), &raw, &tree, &UNIVERSE) != Structure::Complete {
        return None;
    }

    let rows = Rows { source };
    let mut summary = Summary::blank();

    for held in semantic.scopes() {
        summary.parents.push(held.parent);

        summary
            .scopes
            .push(format!("{:?} {}", held.kind, i64::from(held.parent)));
    }

    for held in semantic.bindings() {
        summary.offsets.push(held.name.offset);

        summary.bindings.push(format!(
            "{:?} {} {}",
            held.kind,
            rows.text_of(held.name),
            held.scope
        ));
    }

    for held in semantic.references() {
        let target = match held.resolution {
            Resolution::Bound(bound) => {
                let binding = semantic.bindings()[bound as usize];

                summary.chain.push((held.scope, binding.scope));

                format!("{} {}", rows.text_of(binding.name), binding.scope)
            }
            Resolution::Builtin => "Builtin".to_owned(),
            Resolution::External => "External".to_owned(),
            Resolution::Maybe => "Maybe".to_owned(),
            Resolution::Unresolved => "Unresolved".to_owned(),
        };

        summary
            .references
            .push(format!("{} {target}", rows.text_of(held.name)));
    }

    Some(summary)
}

fn zig(source: &[u8]) -> Option<Summary> {
    use scylla::syntax::zig::classify::classify;
    use scylla::syntax::zig::kind::ZigKind;
    use scylla::syntax::zig::parse;
    use scylla::syntax::zig::semantic::{Resolution, Semantic};

    let mut lexed = Tokens::reserve(TOKEN_COUNT_MAX);
    let mut tokens = Tokens::reserve(TOKEN_COUNT_MAX);
    let mut raw = BoundedVec::reserve(TOKEN_COUNT_MAX);
    let mut events = Events::reserve(EVENT_COUNT_MAX);
    let mut tree = Tree::<ZigKind>::reserve(NODE_COUNT_MAX, ERROR_COUNT_MAX);

    let mut semantic = Semantic::reserve(
        TABLE_COUNT_MAX,
        TABLE_COUNT_MAX,
        TABLE_COUNT_MAX,
        TABLE_COUNT_MAX,
    );

    ZIG.lex(source, &mut lexed);

    if !classify(source, lexed.as_slice(), &mut tokens, &mut raw) {
        return None;
    }

    parse::build(source, tokens.as_slice(), &raw, &mut events, &mut tree);

    if semantic.build(source, tokens.as_slice(), &raw, &tree, &UNIVERSE) != Structure::Complete {
        return None;
    }

    let rows = Rows { source };
    let mut summary = Summary::blank();

    for held in semantic.scopes() {
        summary.parents.push(held.parent);

        summary
            .scopes
            .push(format!("{:?} {}", held.kind, i64::from(held.parent)));
    }

    for held in semantic.bindings() {
        summary.offsets.push(held.name.offset);

        summary.bindings.push(format!(
            "{:?} {} {}",
            held.kind,
            rows.text_of(held.name),
            held.scope
        ));
    }

    for held in semantic.references() {
        let target = match held.resolution {
            Resolution::Bound(bound) => {
                let binding = semantic.bindings()[bound as usize];

                summary.chain.push((held.scope, binding.scope));

                format!("{} {}", rows.text_of(binding.name), binding.scope)
            }
            Resolution::Builtin => "Builtin".to_owned(),
            Resolution::Unresolved => "Unresolved".to_owned(),
        };

        summary
            .references
            .push(format!("{} {target}", rows.text_of(held.name)));
    }

    Some(summary)
}

fn odin(source: &[u8]) -> Option<Summary> {
    use scylla::syntax::odin::classify::classify;
    use scylla::syntax::odin::kind::OdinKind;
    use scylla::syntax::odin::parse;
    use scylla::syntax::odin::semantic::{Resolution, Semantic};

    let mut lexed = Tokens::reserve(TOKEN_COUNT_MAX);
    let mut tokens = Tokens::reserve(TOKEN_COUNT_MAX);
    let mut raw = BoundedVec::reserve(TOKEN_COUNT_MAX);
    let mut events = Events::reserve(EVENT_COUNT_MAX);
    let mut tree = Tree::<OdinKind>::reserve(NODE_COUNT_MAX, ERROR_COUNT_MAX);

    let mut semantic = Semantic::reserve(
        TABLE_COUNT_MAX,
        TABLE_COUNT_MAX,
        TABLE_COUNT_MAX,
        TABLE_COUNT_MAX,
    );

    ODIN.lex(source, &mut lexed);

    if !classify(source, lexed.as_slice(), &mut tokens, &mut raw) {
        return None;
    }

    parse::build(source, tokens.as_slice(), &raw, &mut events, &mut tree);

    if semantic.build(source, tokens.as_slice(), &raw, &tree, &UNIVERSE) != Structure::Complete {
        return None;
    }

    let rows = Rows { source };
    let mut summary = Summary::blank();

    for held in semantic.scopes() {
        summary.parents.push(held.parent);

        summary
            .scopes
            .push(format!("{:?} {}", held.kind, i64::from(held.parent)));
    }

    for held in semantic.bindings() {
        summary.offsets.push(held.name.offset);

        summary.bindings.push(format!(
            "{:?} {} {}",
            held.kind,
            rows.text_of(held.name),
            held.scope
        ));
    }

    for held in semantic.references() {
        let target = match held.resolution {
            Resolution::Bound(bound) => {
                let binding = semantic.bindings()[bound as usize];

                summary.chain.push((held.scope, binding.scope));

                format!("{} {}", rows.text_of(binding.name), binding.scope)
            }
            Resolution::Builtin => "Builtin".to_owned(),
            Resolution::Maybe => "Maybe".to_owned(),
            Resolution::Unresolved => "Unresolved".to_owned(),
        };

        summary
            .references
            .push(format!("{} {target}", rows.text_of(held.name)));
    }

    Some(summary)
}
