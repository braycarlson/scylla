use scylla::bounded::Span;
use scylla::diagnostic::{Diagnostic, Diagnostics, Message, Severity};
use scylla::fix::NONE as FIX_NONE;
use scylla::language::Language;
use scylla::project::view::Node;
use scylla::project::{
    CLASS_COUNT,
    Eviction,
    FileID,
    Graph,
    Limits,
    NONE,
    Store,
    Target,
    hash_of,
    target_of,
};
use scylla::rule::NONE as RULE_NONE;
use scylla::syntax::FactKind;
use scylla::syntax::front;
use scylla::syntax::python::kind::PythonKind;
use scylla::tree::{Step, Structure};

const MAIN: &[u8] =
    b"import helper\nfrom missing import thing\n\n\ndef run():\n    return helper\n";

const HELPER: &[u8] = b"def thing():\n    return 1\n\n\ndef other():\n    return 2\n";

fn recorded(
    diagnostics: &mut Diagnostics,
    code: &'static str,
    severity: Severity,
    span: Span,
) -> bool {
    diagnostics.push(Diagnostic {
        code,
        fix: FIX_NONE,
        message: Message::Static("a recorded finding"),
        related_count: 0,
        related_start: 0,
        rule: RULE_NONE,
        severity,
        span,
    })
}

fn rule_definitions(store: &Store, file: FileID, out: &mut Diagnostics) {
    for step in store.walk(file) {
        let Step::Enter(node) = step else {
            continue;
        };

        let Some(view) = store.python_view(file, node) else {
            continue;
        };

        if view.kind() != PythonKind::FunctionDef {
            continue;
        }

        assert!(recorded(out, "PRJ001", Severity::Warning, view.span()));
    }
}

fn rule_imports(store: &Store, file: FileID, out: &mut Diagnostics) {
    let source = store.source_of(file);

    for fact in store.facts_of(file) {
        if !fact.kind.imports() {
            continue;
        }

        let specifier = &source[fact.specifier.range()];
        let mut path = specifier.to_vec();

        path.extend_from_slice(b".py");

        if store.find(hash_of(&path)) != NONE {
            continue;
        }

        assert!(recorded(out, "PRJ002", Severity::Error, fact.specifier));
    }
}

#[derive(Debug, Default)]
struct Collected {
    nodes: Vec<Node>,
}

fn rule_collected(store: &Store, file: FileID, out: &mut Diagnostics) {
    let mut collected = Collected::default();

    for step in store.walk(file) {
        let Step::Enter(node) = step else {
            continue;
        };

        let Some(view) = store.python_view(file, node) else {
            continue;
        };

        if view.kind() != PythonKind::FunctionDef {
            continue;
        }

        collected.nodes.push(Node::new(file, node));
    }

    for held in &collected.nodes {
        let view = store
            .python_view(held.file, held.node)
            .expect("the handle names a python node");

        assert!(recorded(out, "PRJ003", Severity::Hint, view.span()));
    }
}

fn limits_of(mix: &[(Language, u32)]) -> Limits {
    let mut slots = [[0_u32; CLASS_COUNT]; Language::COUNT];
    let mut total = 0;

    for (language, count) in mix {
        slots[language.index()][Limits::class_of(8_192) as usize] = *count;
        total += *count;
    }

    Limits {
        file_count_max: total,
        front: front::Limits {
            binding_count_max: 512,
            error_count_max: 64,
            event_count_max: 8_192,
            export_count_max: 512,
            fact_count_max: 512,
            node_count_max: 4_096,
            reference_count_max: 512,
            scope_count_max: 128,
            segment_count_max: 512,
            token_count_max: 2_048,
        },
        line_count_max: 512,
        slots,
        source_bytes_max: 8_192,
    }
}

fn project() -> (Store, FileID, FileID) {
    let limits = limits_of(&[(Language::Python, 4)]);
    let mut store = Store::reserve(&limits, Eviction::Reject);
    let main = store.insert(hash_of(b"main.py"), Language::Python, MAIN);
    let helper = store.insert(hash_of(b"helper.py"), Language::Python, HELPER);

    assert!(main != NONE);
    assert!(helper != NONE);

    (store, FileID::of(main), FileID::of(helper))
}

fn codes_of(diagnostics: &Diagnostics) -> Vec<(&'static str, Span)> {
    diagnostics
        .iter()
        .map(|held| (held.code, held.span))
        .collect()
}

#[test]
fn an_intra_file_rule_reads_one_slot() {
    let (store, main, helper) = project();
    let mut diagnostics = Diagnostics::reserve(64, 1 << 12);

    rule_definitions(&store, main, &mut diagnostics);

    assert_eq!(diagnostics.count(), 1);

    let mut second = Diagnostics::reserve(64, 1 << 12);

    rule_definitions(&store, helper, &mut second);

    assert_eq!(second.count(), 2);

    for (code, _) in codes_of(&second) {
        assert_eq!(code, "PRJ001");
    }
}

#[test]
fn a_cross_file_rule_reaches_the_second_slot_through_the_store() {
    let (store, main, _) = project();
    let mut diagnostics = Diagnostics::reserve(64, 1 << 12);

    rule_imports(&store, main, &mut diagnostics);

    let found = codes_of(&diagnostics);

    assert_eq!(found.len(), 1);
    assert_eq!(found[0].0, "PRJ002");
    assert_eq!(&store.source_of(main)[found[0].1.range()], b"missing");
}

#[test]
fn a_rule_holds_node_handles_past_the_traversal() {
    let (store, _, helper) = project();
    let mut diagnostics = Diagnostics::reserve(64, 1 << 12);

    rule_collected(&store, helper, &mut diagnostics);

    let found = codes_of(&diagnostics);

    assert_eq!(found.len(), 2);
    assert_eq!(found[0].0, "PRJ003");
    assert_eq!(found[1].0, "PRJ003");
    assert!(found[0].1.offset < found[1].1.offset);
}

#[test]
fn a_view_of_the_wrong_language_is_none() {
    let limits = limits_of(&[(Language::Python, 1), (Language::Rust, 1)]);
    let mut store = Store::reserve(&limits, Eviction::Reject);
    let python = store.insert(hash_of(b"a.py"), Language::Python, HELPER);
    let rust = store.insert(hash_of(b"a.rs"), Language::Rust, b"fn run() {}\n");

    assert!(store.python_view(FileID::of(python), 0).is_some());
    assert!(store.rust_view(FileID::of(python), 0).is_none());
    assert!(store.rust_view(FileID::of(rust), 0).is_some());
    assert!(store.python_view(FileID::of(rust), 0).is_none());
    assert!(store.markup_view(FileID::of(rust), 0).is_none());
}

#[test]
fn a_node_past_the_tree_is_none() {
    let (store, main, _) = project();

    assert!(store.python_view(main, 0).is_some());
    assert!(store.python_view(main, u32::MAX - 1).is_none());
}

#[test]
fn the_facts_table_is_the_shared_shape_every_front_end_fills() {
    let (store, main, _) = project();
    let kinds: Vec<FactKind> = store.facts_of(main).iter().map(|held| held.kind).collect();

    assert_eq!(kinds.len(), 2);
    assert!(kinds.iter().all(|held| held.imports()));
}

const CHAIN: [(&[u8], &str); 20] = [
    (b"m00", "m00.py"),
    (b"m01", "m01.py"),
    (b"m02", "m02.py"),
    (b"m03", "m03.py"),
    (b"m04", "m04.py"),
    (b"m05", "m05.py"),
    (b"m06", "m06.py"),
    (b"m07", "m07.py"),
    (b"m08", "m08.py"),
    (b"m09", "m09.py"),
    (b"m10", "m10.py"),
    (b"m11", "m11.py"),
    (b"m12", "m12.py"),
    (b"m13", "m13.py"),
    (b"m14", "m14.py"),
    (b"m15", "m15.py"),
    (b"m16", "m16.py"),
    (b"m17", "m17.py"),
    (b"m18", "m18.py"),
    (b"m19", "m19.py"),
];

const CYCLE: [(&[u8], &str); 2] = [(b"a", "a.py"), (b"b", "b.py")];

const DJANGO: [(&[u8], &str); 3] = [
    (b"base.html", "base.html"),
    (b"page.html", "page.html"),
    (b"partial.html", "partial.html"),
];

const PACKAGE: [(&[u8], &str); 3] = [
    (b"main", "main.py"),
    (b"pkg", "pkg/__init__.py"),
    (b"pkg.models", "pkg/models.py"),
];

const STAR: [(&[u8], &str); 3] = [
    (b"main", "main.py"),
    (b"pkg", "pkg/__init__.py"),
    (b"pkg.models", "pkg/models.py"),
];

const BARREL: [(&[u8], &str); 4] = [
    (b"lib", "lib.ts"),
    (b"lib/inner", "inner.ts"),
    (b"lib/inner/widget", "widget.ts"),
    (b"main", "main.ts"),
];

fn specifier_resolve(specifier: &[u8], _from: FileID, store: &Store) -> u32 {
    store.find(hash_of(specifier))
}

fn tree_of(name: &str, files: &[(&[u8], &str)], language: Language) -> (Store, Graph) {
    let root = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("tests/fixtures/project")
        .join(name);

    let limits = limits_of(&[(language, u32::try_from(files.len()).expect("a small tree"))]);
    let mut store = Store::reserve(&limits, Eviction::Reject);

    store.template_imports_set(&[b"extends", b"include"]);

    for (key, path) in files {
        let source = std::fs::read(root.join(path)).expect("the fixture is readable");
        let index = store.insert(hash_of(key), language, &source);

        assert!(index != NONE, "{path} did not reach a slot");

        assert_eq!(
            store.structure_of(FileID::of(index)),
            Structure::Complete,
            "{path} did not parse"
        );
    }

    let mut graph = Graph::reserve(64, u32::try_from(files.len()).expect("a small tree"));

    assert!(graph.build(&store, &specifier_resolve));

    (store, graph)
}

fn file_of(store: &Store, key: &[u8]) -> FileID {
    let index = store.find(hash_of(key));

    assert!(index != NONE);

    FileID::of(index)
}

fn reaches(store: &Store, node: Node) -> bool {
    store
        .walk(node.file)
        .any(|step| step == Step::Enter(node.node))
}

#[test]
fn a_package_reexport_resolves_to_the_class_it_names() {
    let (store, graph) = tree_of("python-package", &PACKAGE, Language::Python);
    let main = file_of(&store, b"main");
    let models = file_of(&store, b"pkg.models");
    let found = target_of(&store, &graph, main, b"Widget");

    let Target::Binding(node) = found else {
        panic!("the name resolves to a binding, found {found:?}");
    };

    assert_eq!(node.file, models);
    assert_eq!(store.declaration_of(models, b"Widget"), node.node);
    assert!(reaches(&store, node));
    assert_eq!(target_of(&store, &graph, main, b"Hidden"), Target::Missing);
}

#[test]
fn a_barrel_two_levels_deep_follows_the_rename() {
    let (store, graph) = tree_of("typescript-barrel", &BARREL, Language::TypeScript);
    let main = file_of(&store, b"main");
    let widget = file_of(&store, b"lib/inner/widget");
    let found = target_of(&store, &graph, main, b"Widget");

    let Target::Binding(node) = found else {
        panic!("the barrel resolves to a binding, found {found:?}");
    };

    assert_eq!(node.file, widget);
    assert_eq!(store.declaration_of(widget, b"Thing"), node.node);
    assert!(reaches(&store, node));
}

#[test]
fn a_star_reexport_answers_maybe() {
    let (store, graph) = tree_of("star-reexport", &STAR, Language::Python);
    let main = file_of(&store, b"main");

    assert_eq!(target_of(&store, &graph, main, b"Widget"), Target::Maybe);
}

#[test]
fn a_cycle_still_terminates() {
    let (store, graph) = tree_of("cycle", &CYCLE, Language::Python);
    let first = file_of(&store, b"a");
    let second = file_of(&store, b"b");

    assert_eq!(graph.cycles().count(), 1);

    let value = target_of(&store, &graph, first, b"value");
    let other = target_of(&store, &graph, second, b"other");

    assert_eq!(
        value,
        Target::Binding(Node::new(second, node_of(&store, second, b"value")))
    );

    assert_eq!(
        other,
        Target::Binding(Node::new(first, node_of(&store, first, b"other")))
    );
}

fn node_of(store: &Store, file: FileID, name: &[u8]) -> u32 {
    let node = store.declaration_of(file, name);

    assert!(node != NONE);

    node
}

#[test]
fn a_chain_past_the_bound_answers_maybe() {
    let (store, graph) = tree_of("chain", &CHAIN, Language::Python);
    let head = file_of(&store, b"m00");
    let near = file_of(&store, b"m17");

    assert_eq!(target_of(&store, &graph, head, b"value"), Target::Maybe);

    let found = target_of(&store, &graph, near, b"value");

    let Target::Binding(node) = found else {
        panic!("a short chain resolves, found {found:?}");
    };

    assert_eq!(node.file, file_of(&store, b"m19"));
}

#[test]
fn a_template_tree_resolves_through_the_same_machinery() {
    let (store, graph) = tree_of("django", &DJANGO, Language::Markup);
    let base = file_of(&store, b"base.html");
    let page = file_of(&store, b"page.html");
    let partial = file_of(&store, b"partial.html");
    let edges = graph.edges_of(page);

    assert_eq!(edges.len(), 2);
    assert!(edges.iter().all(|held| held.resolved));
    assert_eq!(edges[0].to, base.index());
    assert_eq!(edges[1].to, partial.index());
    assert_eq!(graph.edges_of(base).len(), 0);
    assert_eq!(graph.dependents_of(base).count(), 1);
    assert_eq!(target_of(&store, &graph, page, b"body"), Target::Missing);
}
