use std::path::{Path, PathBuf};

use scylla::bounded::BoundedVec;
use scylla::language::Language;
use scylla::syntax::Category;
use scylla::syntax::front::{self, Front, Limits, Options, Scratch};
use scylla::syntax::python::stdlib::PythonVersion;
use scylla::syntax::view::{PARAMETER_COUNT_MAX, View};
use scylla::token::{Lex, TokenKind, Tokens};
use scylla::tree::Structure;

const LIMITS: Limits = Limits {
    binding_count_max: 1 << 12,
    error_count_max: 1 << 8,
    event_count_max: 1 << 18,
    export_count_max: 1 << 10,
    fact_count_max: 1 << 10,
    node_count_max: 1 << 16,
    reference_count_max: 1 << 12,
    scope_count_max: 1 << 10,
    segment_count_max: 1 << 10,
    token_count_max: 1 << 16,
};

const EVERY: [(Language, &str, &str); 7] = [
    (Language::Go, "go", "go"),
    (Language::JavaScript, "javascript", "js"),
    (Language::Odin, "odin", "odin"),
    (Language::Python, "python", "py"),
    (Language::Rust, "rust", "rs"),
    (Language::TypeScript, "typescript", "ts"),
    (Language::Zig, "zig", "zig"),
];

struct Built {
    front: Front,
}

impl Built {
    fn of(language: Language, source: &[u8]) -> Self {
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
        };

        let outcome = front.build(source, lexed.as_slice(), &mut scratch, &options);

        assert_eq!(
            outcome,
            Structure::Complete,
            "{}",
            String::from_utf8_lossy(source)
        );

        Self { front }
    }

    fn first(&self, category: Category) -> View<'_> {
        let position = *self
            .front
            .index_of(category)
            .first()
            .unwrap_or_else(|| panic!("a {} node is in the tree", category.name()));

        self.front.view(position).expect("a code front has views")
    }

    fn nth(&self, category: Category, index: usize) -> View<'_> {
        let position = self.front.index_of(category)[index];

        self.front.view(position).expect("a code front has views")
    }

    fn text_at<'source>(&self, source: &'source [u8], position: u32) -> &'source [u8] {
        self.front.tokens()[position as usize].text(source)
    }
}

fn names_of<'source>(built: &Built, source: &'source [u8], held: View<'_>) -> Vec<&'source [u8]> {
    let declaration = held.as_declaration().expect("a declaration casts");

    declaration
        .names()
        .map(|position| built.text_at(source, position))
        .collect()
}

#[test]
fn a_go_function_reads_its_name_parameters_receiver_and_body() {
    const SOURCE: &[u8] = b"package main\n\
        \nfunc (s *Server) Run(one, two int, three string) error {\n\treturn nil\n}\n";
    let built = Built::of(Language::Go, SOURCE);

    let held = built
        .first(Category::Function)
        .as_function()
        .expect("a function casts");

    let parameters: Vec<_> = held.parameters().collect();

    assert_eq!(
        built.text_at(SOURCE, held.name_token().expect("a name")),
        b"Run"
    );

    assert_eq!(parameters.len(), 3);

    assert_eq!(
        built.text_at(SOURCE, parameters[0].name.expect("a name")),
        b"one"
    );

    assert_eq!(
        built.text_at(SOURCE, parameters[1].name.expect("a name")),
        b"two"
    );

    assert_eq!(
        built.text_at(SOURCE, parameters[2].name.expect("a name")),
        b"three"
    );

    assert_eq!(parameters[1].type_of.expect("a type").text(SOURCE), b"int");
    assert!(held.receiver().is_some());
    assert!(held.body().is_some());

    assert_eq!(
        held.returns().expect("a result list").text(SOURCE),
        b"error"
    );
}

#[test]
fn a_rust_struct_container_lists_its_fields_as_members() {
    const SOURCE: &[u8] = b"struct Outer {\n    inner: Inner,\n    count: u32,\n}\n";
    let built = Built::of(Language::Rust, SOURCE);

    let held = built
        .first(Category::Struct)
        .as_container()
        .expect("a container casts");

    let members: Vec<_> = held.body().children().collect();
    let spelled = members[0].type_of().expect("a field type");

    assert_eq!(members.len(), 2, "{members:?}");

    assert_eq!(
        built.text_at(SOURCE, members[0].name_token().expect("a name")),
        b"inner"
    );

    assert_eq!(&SOURCE[spelled.span().range()], b"Inner");
}

#[test]
fn a_rust_parameter_reads_its_type() {
    const SOURCE: &[u8] = b"fn run(other: &Outer) {}\n";
    let built = Built::of(Language::Rust, SOURCE);
    let held = built.first(Category::Declaration);
    let spelled = held.type_of().expect("a parameter type");

    assert_eq!(&SOURCE[spelled.span().range()], b"&Outer");
}

#[test]
fn a_go_call_reads_its_receiver_name_and_arguments() {
    const SOURCE: &[u8] = b"package main\n\nfunc run() {\n\tserver.Start(one, two)\n}\n";
    let built = Built::of(Language::Go, SOURCE);
    let held = built.first(Category::Call).as_call().expect("a call casts");

    assert_eq!(
        built.text_at(SOURCE, held.name_token().expect("a name")),
        b"Start"
    );

    assert_eq!(held.receiver().expect("a receiver").text(SOURCE), b"server");
    assert_eq!(held.arguments().count(), 2);
}

#[test]
fn a_go_declaration_reads_its_names_and_constness() {
    const SOURCE: &[u8] = b"package main\n\nconst one, two = 1, 2\n\nvar three = 3\n";
    let built = Built::of(Language::Go, SOURCE);

    let constant = built
        .front
        .index_of(Category::Declaration)
        .iter()
        .map(|position| built.front.view(*position).expect("a view"))
        .find(|node| node.as_declaration().is_some())
        .expect("a value spec");

    assert_eq!(
        names_of(&built, SOURCE, constant),
        [b"one".as_slice(), b"two".as_slice()]
    );

    assert!(constant.as_declaration().expect("casts").is_constant());

    assert_eq!(
        constant
            .as_declaration()
            .expect("casts")
            .value()
            .expect("a value")
            .text(SOURCE),
        b"1"
    );
}

#[test]
fn a_rust_function_reads_its_name_parameters_return_and_body() {
    const SOURCE: &[u8] = b"pub fn run(&self, one: u32, mut two: &[u8]) -> bool {\n    true\n}\n";
    let built = Built::of(Language::Rust, SOURCE);

    let held = built
        .first(Category::Function)
        .as_function()
        .expect("a function casts");

    let parameters: Vec<_> = held.parameters().collect();

    assert_eq!(
        built.text_at(SOURCE, held.name_token().expect("a name")),
        b"run"
    );

    assert_eq!(parameters.len(), 3);

    assert_eq!(
        built.text_at(SOURCE, parameters[0].name.expect("self")),
        b"self"
    );

    assert_eq!(
        built.text_at(SOURCE, parameters[1].name.expect("a name")),
        b"one"
    );

    assert_eq!(parameters[1].type_of.expect("a type").text(SOURCE), b"u32");

    assert_eq!(
        built.text_at(SOURCE, parameters[2].name.expect("a name")),
        b"two"
    );

    assert!(held.receiver().is_some());
    assert!(held.is_public());
    assert_eq!(held.returns().expect("a return type").text(SOURCE), b"bool");
    assert!(held.body().is_some());
}

#[test]
fn a_rust_declaration_and_a_method_call_read_through_the_view() {
    const SOURCE: &[u8] = b"fn run() {\n    let mut held: u32 = 1;\n    let (one, two) = pair();\
            \n    held.push(one, two);\n}\n";

    let built = Built::of(Language::Rust, SOURCE);
    let local = built.first(Category::Declaration);
    let names = names_of(&built, SOURCE, local);

    assert_eq!(names, [b"held".as_slice()]);

    let declaration = local.as_declaration().expect("casts");

    assert!(declaration.is_mutable());
    assert!(!declaration.is_constant());
    assert_eq!(declaration.type_of().expect("a type").text(SOURCE), b"u32");
    assert_eq!(declaration.value().expect("a value").text(SOURCE), b"1");

    let pair = built
        .front
        .index_of(Category::Declaration)
        .iter()
        .map(|position| built.front.view(*position).expect("a view"))
        .filter(|node| node.as_declaration().is_some())
        .nth(1)
        .expect("a second local");

    assert_eq!(
        names_of(&built, SOURCE, pair),
        [b"one".as_slice(), b"two".as_slice()]
    );

    let call = built
        .front
        .index_of(Category::Call)
        .iter()
        .map(|position| built.front.view(*position).expect("a view"))
        .find(|node| node.as_call().and_then(|call| call.receiver()).is_some())
        .expect("a method call")
        .as_call()
        .expect("casts");

    assert_eq!(
        built.text_at(SOURCE, call.name_token().expect("a name")),
        b"push"
    );

    assert_eq!(call.receiver().expect("a receiver").text(SOURCE), b"held");
    assert_eq!(call.arguments().count(), 2);
}

#[test]
fn a_rust_container_and_use_read_through_the_view() {
    const SOURCE: &[u8] =
        b"use std::collections::HashMap;\n\npub struct Held {\n    one: u32,\n    two: bool,\n}\n\
            \nimpl Held {\n    fn run(&self) {}\n}\n";

    let built = Built::of(Language::Rust, SOURCE);

    let import = built
        .first(Category::Import)
        .as_import()
        .expect("an import casts");

    let mut segments = BoundedVec::reserve(16);

    assert!(import.segments(&mut segments));
    assert_eq!(segments.count(), 3);
    assert_eq!(&SOURCE[segments[2].range()], b"HashMap");
    assert!(!import.is_wildcard());

    let held = built
        .first(Category::Struct)
        .as_container()
        .expect("a container casts");

    assert_eq!(
        built.text_at(SOURCE, held.name_token().expect("a name")),
        b"Held"
    );

    assert_eq!(held.fields().count(), 2);

    let block = built
        .nth(Category::Struct, 1)
        .as_container()
        .expect("an impl casts");

    assert_eq!(block.members().count(), 1);
}

#[test]
fn a_python_function_reads_its_parameters_defaults_and_annotations() {
    const SOURCE: &[u8] =
        b"def run(self, one: int, two=2, *rest, **named) -> bool:\n    return True\n";

    let built = Built::of(Language::Python, SOURCE);

    let held = built
        .first(Category::Function)
        .as_function()
        .expect("a function casts");

    let parameters: Vec<_> = held.parameters().collect();

    assert_eq!(
        built.text_at(SOURCE, held.name_token().expect("a name")),
        b"run"
    );

    assert_eq!(parameters.len(), 5);

    assert_eq!(
        built.text_at(SOURCE, parameters[1].name.expect("a name")),
        b"one"
    );

    assert_eq!(
        parameters[1].type_of.expect("an annotation").text(SOURCE),
        b"int"
    );

    assert_eq!(parameters[2].default.expect("a default").text(SOURCE), b"2");
    assert_eq!(held.returns().expect("an annotation").text(SOURCE), b"bool");
    assert!(held.body().is_some());
}

#[test]
fn a_python_class_call_and_import_read_through_the_view() {
    const SOURCE: &[u8] = b"from os.path import join\n\nclass Held:\n    def run(self):\
        \n        self.items.append(1)\n\n    def stop(self):\n        pass\n\nvalue = 1\n";
    let built = Built::of(Language::Python, SOURCE);

    let class = built
        .first(Category::Struct)
        .as_container()
        .expect("a class casts");

    assert_eq!(
        built.text_at(SOURCE, class.name_token().expect("a name")),
        b"Held"
    );

    assert_eq!(class.members().count(), 2);

    let call = built.first(Category::Call).as_call().expect("a call casts");

    assert_eq!(
        built.text_at(SOURCE, call.name_token().expect("a name")),
        b"append"
    );

    assert_eq!(
        call.receiver().expect("a receiver").text(SOURCE),
        b"self.items"
    );

    assert_eq!(call.arguments().count(), 1);

    let import = built
        .first(Category::Import)
        .as_import()
        .expect("an import casts");

    let mut segments = BoundedVec::reserve(16);

    assert!(import.segments(&mut segments));
    assert_eq!(segments.count(), 2);
    assert_eq!(&SOURCE[segments[1].range()], b"path");

    let value = built
        .front
        .index_of(Category::Declaration)
        .iter()
        .map(|position| built.front.view(*position).expect("a view"))
        .find(|node| node.as_declaration().is_some())
        .expect("an assignment");

    assert_eq!(names_of(&built, SOURCE, value), [b"value".as_slice()]);
}

#[test]
fn a_zig_function_reads_its_parameters_from_the_prototype() {
    const SOURCE: &[u8] =
        b"pub fn run(one: u32, two: []const u8, comptime T: type) !void {\n    _ = one;\n}\n";

    let built = Built::of(Language::Zig, SOURCE);

    let held = built
        .first(Category::Function)
        .as_function()
        .expect("a function casts");

    let parameters: Vec<_> = held.parameters().collect();

    assert_eq!(
        built.text_at(SOURCE, held.name_token().expect("a name")),
        b"run"
    );

    assert_eq!(parameters.len(), 3);

    assert_eq!(
        built.text_at(SOURCE, parameters[0].name.expect("a name")),
        b"one"
    );

    assert_eq!(parameters[0].type_of.expect("a type").text(SOURCE), b"u32");

    assert_eq!(
        built.text_at(SOURCE, parameters[1].name.expect("a name")),
        b"two"
    );

    assert_eq!(
        built.text_at(SOURCE, parameters[2].name.expect("a name")),
        b"T"
    );

    assert!(held.is_public());
    assert!(held.returns().is_some());
    assert!(held.body().is_some());
}

#[test]
fn a_zig_container_call_and_declaration_read_through_the_view() {
    const SOURCE: &[u8] =
        b"const Held = struct {\n    one: u32 = 0,\n    fn run(self: Held) void {\
        \n        std.debug.print(\"{}\", .{self.one});\n    }\n};\n";
    let built = Built::of(Language::Zig, SOURCE);

    let container = built
        .first(Category::Struct)
        .as_container()
        .expect("a container casts");

    assert_eq!(
        built.text_at(SOURCE, container.name_token().expect("a name")),
        b"Held"
    );

    assert_eq!(container.fields().count(), 1);
    assert_eq!(container.members().count(), 1);

    let call = built.first(Category::Call).as_call().expect("a call casts");

    assert_eq!(
        built.text_at(SOURCE, call.name_token().expect("a name")),
        b"print"
    );

    assert_eq!(
        call.receiver().expect("a receiver").text(SOURCE),
        b"std.debug"
    );

    assert_eq!(call.arguments().count(), 2);

    let declaration = built.first(Category::Declaration);

    assert_eq!(names_of(&built, SOURCE, declaration), [b"Held".as_slice()]);
    assert!(declaration.as_declaration().expect("casts").is_constant());
}

#[test]
fn an_odin_procedure_reads_its_parameters_and_returns() {
    const SOURCE: &[u8] = b"package main\n\
        \nrun :: proc(one, two: int, three: string = \"\") -> bool {\n    return true\n}\n";
    let built = Built::of(Language::Odin, SOURCE);

    let held = built
        .first(Category::Function)
        .as_function()
        .expect("a procedure casts");

    let parameters: Vec<_> = held.parameters().collect();

    assert_eq!(
        built.text_at(SOURCE, held.name_token().expect("a name")),
        b"run"
    );

    assert_eq!(parameters.len(), 3);

    assert_eq!(
        built.text_at(SOURCE, parameters[0].name.expect("a name")),
        b"one"
    );

    assert_eq!(
        built.text_at(SOURCE, parameters[1].name.expect("a name")),
        b"two"
    );

    assert_eq!(parameters[1].type_of.expect("a type").text(SOURCE), b"int");
    assert!(parameters[2].default.is_some());
    assert_eq!(held.returns().expect("a return type").text(SOURCE), b"bool");
    assert!(held.body().is_some());
}

#[test]
fn a_javascript_function_call_and_class_read_through_the_view() {
    const SOURCE: &[u8] = b"import { join } from \"path\";\n\nclass Held {\
        \n  constructor(one, two = 2, ...rest) {\n    this.items.push(one);\n  }\n}\n\
        \nconst value = 1;\n";
    let built = Built::of(Language::JavaScript, SOURCE);

    let held = built
        .first(Category::Function)
        .as_function()
        .expect("a function casts");

    let parameters: Vec<_> = held.parameters().collect();

    assert_eq!(parameters.len(), 3);

    assert_eq!(
        built.text_at(SOURCE, parameters[0].name.expect("a name")),
        b"one"
    );

    assert_eq!(
        built.text_at(SOURCE, parameters[1].name.expect("a name")),
        b"two"
    );

    assert_eq!(parameters[1].default.expect("a default").text(SOURCE), b"2");

    assert_eq!(
        built.text_at(SOURCE, parameters[2].name.expect("a name")),
        b"rest"
    );

    assert!(held.body().is_some());

    let call = built.first(Category::Call).as_call().expect("a call casts");

    assert_eq!(
        built.text_at(SOURCE, call.name_token().expect("a name")),
        b"push"
    );

    assert_eq!(
        call.receiver().expect("a receiver").text(SOURCE),
        b"this.items"
    );

    assert_eq!(call.arguments().count(), 1);

    let class = built
        .first(Category::Struct)
        .as_container()
        .expect("a class casts");

    assert_eq!(
        built.text_at(SOURCE, class.name_token().expect("a name")),
        b"Held"
    );

    assert_eq!(class.members().count(), 1);

    let import = built
        .first(Category::Import)
        .as_import()
        .expect("an import casts");

    let mut segments = BoundedVec::reserve(16);

    assert!(import.segments(&mut segments));
    assert_eq!(segments.count(), 1);

    let value = built
        .front
        .index_of(Category::Declaration)
        .iter()
        .map(|position| built.front.view(*position).expect("a view"))
        .find(|node| node.as_declaration().is_some())
        .expect("a declarator");

    assert_eq!(names_of(&built, SOURCE, value), [b"value".as_slice()]);
    assert!(value.as_declaration().expect("casts").is_constant());
}

#[test]
fn a_typescript_function_reads_typed_parameters() {
    const SOURCE: &[u8] = b"export function run(one: number, two?: string, three = 3): boolean {\
        \n  return true;\n}\n";
    let built = Built::of(Language::TypeScript, SOURCE);

    let held = built
        .first(Category::Function)
        .as_function()
        .expect("a function casts");

    let parameters: Vec<_> = held.parameters().collect();

    assert_eq!(
        built.text_at(SOURCE, held.name_token().expect("a name")),
        b"run"
    );

    assert_eq!(parameters.len(), 3);

    assert_eq!(
        built.text_at(SOURCE, parameters[0].name.expect("a name")),
        b"one"
    );

    assert!(parameters[0].type_of.is_some());

    assert_eq!(
        built.text_at(SOURCE, parameters[1].name.expect("a name")),
        b"two"
    );

    assert_eq!(
        built.text_at(SOURCE, parameters[2].name.expect("a name")),
        b"three"
    );

    assert_eq!(parameters[2].default.expect("a default").text(SOURCE), b"3");
    assert!(held.returns().is_some());
}

#[test]
fn a_statement_reads_its_clauses_in_every_language() {
    let cases: [(Language, &[u8], usize); 5] = [
        (
            Language::Go,
            b"package main\n\nfunc run(one int) {\n\tswitch one {\n\tcase 1:\n\tcase 2:\
            \n\tdefault:\n\t}\n}\n",
            3,
        ),
        (
            Language::Rust,
            b"fn run(one: u32) {\n    match one {\n        1 => {}\n        2 => {}\
            \n        _ => {}\n    }\n}\n",
            3,
        ),
        (
            Language::Python,
            b"def run(one):\n    try:\n        pass\n    except ValueError:\
            \n        pass\n    except KeyError:\n        pass\n    finally:\n        pass\n",
            3,
        ),
        (
            Language::Zig,
            b"fn run(one: u32) void {\n    switch (one) {\n        1 => {},\
            \n        2 => {},\n        else => {},\n    }\n}\n",
            3,
        ),
        (
            Language::JavaScript,
            b"function run(one) {\n  if (one) {\n  } else {\n  }\n}\n",
            1,
        ),
    ];

    for (language, source, expected) in cases {
        let built = Built::of(language, source);

        let category = if matches!(language, Language::Python | Language::JavaScript) {
            if language == Language::Python {
                Category::Try
            } else {
                Category::Branch
            }
        } else {
            Category::Match
        };

        let held = built
            .first(category)
            .as_statement()
            .expect("a statement casts");

        assert_eq!(held.clauses().count(), expected, "{}", language.name());
    }
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

fn functions_answer(name: &str, front: &Front) {
    for position in front.index_of(Category::Function) {
        let held = front.view(*position).expect("a view");

        let function = held
            .as_function()
            .unwrap_or_else(|| panic!("{name}: a Function node casts"));

        let count = function.parameters().count();

        assert!(count <= PARAMETER_COUNT_MAX as usize, "{name}");

        for parameter in function.parameters() {
            let Some(token) = parameter.name else {
                continue;
            };

            let kind = front.tokens()[token as usize].kind;

            assert!(
                matches!(kind, TokenKind::Identifier | TokenKind::Keyword(_)),
                "{name}: a parameter name is a word, not {kind:?}"
            );
        }

        let _ = function.body();
        let _ = function.returns();
        let _ = function.receiver();
        let _ = function.parameter_nodes().count();
    }
}

fn calls_answer(name: &str, front: &Front) {
    for position in front.index_of(Category::Call) {
        let held = front.view(*position).expect("a view");

        let call = held
            .as_call()
            .unwrap_or_else(|| panic!("{name}: a Call node casts"));

        assert!(
            call.callee().is_some() || call.name_token().is_some(),
            "{name}: a call names something"
        );

        let _ = call.receiver();
        let _ = call.arguments().count();
    }
}

fn declarations_answer(front: &Front) {
    for position in front.index_of(Category::Declaration) {
        let held = front.view(*position).expect("a view");

        if let Some(declaration) = held.as_declaration() {
            let _ = declaration.names().count();
            let _ = declaration.type_of();
            let _ = declaration.value();
            let _ = declaration.is_constant();
        }

        if let Some(field) = held.as_field() {
            let _ = field.name_token();
            let _ = field.type_of();
        }
    }

    for position in front.index_of(Category::Struct) {
        let held = front.view(*position).expect("a view");

        if let Some(container) = held.as_container() {
            let _ = container.name_token();
            let _ = container.fields().count();
            let _ = container.members().count();
        }
    }

    for position in front.index_of(Category::Import) {
        let held = front.view(*position).expect("a view");

        if let Some(import) = held.as_import() {
            let mut segments = BoundedVec::reserve(64);

            let _ = import.segments(&mut segments);
            let _ = import.is_wildcard();
        }
    }
}

fn every_node_answers(name: &str, source: &[u8], front: &Front) {
    for node in 0..front.count() {
        let held = front.view(node).expect("a view");

        assert_eq!(held.index(), node);
        assert!(held.token_start() <= held.token_end(), "{name}");

        if let Some(statement) = held.as_statement() {
            let _ = statement.header();
            let _ = statement.body();
            let _ = statement.clauses().count();
        }

        if let Some(constant) = held.as_constant() {
            let _ = constant.literal_class(source);
        }
    }
}

#[test]
fn every_fixture_answers_the_typed_questions_without_panicking() {
    for (language, directory, extension) in EVERY {
        for (name, source) in fixtures(directory, extension) {
            let built = Built::of(language, &source);

            functions_answer(&name, &built.front);
            calls_answer(&name, &built.front);
            declarations_answer(&built.front);
            every_node_answers(&name, &source, &built.front);
        }
    }
}
