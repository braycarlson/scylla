use std::fs;
use std::path::PathBuf;
use std::thread;

use scylla::bounded::Random;
use scylla::diagnostic::{Diagnostics, Severity};
use scylla::language::Language;
use scylla::lines;
use scylla::markup;
use scylla::markup::tree::TreeError;
use scylla::project::graph::Edge;
use scylla::project::store::BuildScratch;
use scylla::project::view::Sink;
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
use scylla::rule::{Fixable, Registry, Rule};
use scylla::syntax::css::semantic::Semantic as CSSSemantic;
use scylla::syntax::front;
use scylla::syntax::go::semantic::Semantic as GoSemantic;
use scylla::syntax::javascript::semantic::Semantic as JavaScriptSemantic;
use scylla::syntax::odin::semantic::Semantic as OdinSemantic;
use scylla::syntax::python::check::CheckError as PythonCheckError;
use scylla::syntax::python::semantic::Semantic as PythonSemantic;
use scylla::syntax::rust::semantic::Semantic as RustSemantic;
use scylla::syntax::zig::semantic::Semantic as ZigSemantic;
use scylla::syntax::{Fact, SyntaxError, css, go, javascript, odin, python, rust, typescript, zig};
use scylla::token::Token;
use scylla::tree::{Step, Structure};

const FILE_COUNT: u32 = 24;
const ROUND_COUNT_DEFAULT: u32 = 256;
const SEED_CHURN: u64 = 0x51A9_C3F7_20E4_86BD;
const SOUP_LENGTHS: [u32; 5] = [0, 1, 7, 64, 1_024];
const THREAD_COUNT: u32 = 4;

const LANGUAGES: [Language; 6] = [
    Language::Css,
    Language::Go,
    Language::JavaScript,
    Language::Markup,
    Language::Python,
    Language::Rust,
];

const READ_COUNT: fn(&Store) -> u32 = Store::count;
const READ_CSS_SEMANTIC: fn(&Store, FileID) -> Option<&CSSSemantic> = Store::css_semantic;
const READ_MOVES: fn(&Store) -> u64 = Store::moves;
fn graph_cycles(graph: &Graph) -> usize {
    graph.cycles().count()
}

fn graph_dependents(graph: &Graph, file: FileID) -> usize {
    graph.dependents_of(file).count()
}

fn read_files(store: &Store) -> usize {
    store.files().count()
}

fn read_walk(store: &Store, file: FileID) -> usize {
    store.walk(file).count()
}

fn read_walk_from(store: &Store, file: FileID, node: u32) -> usize {
    store.walk_from(file, node).count()
}

const READ_CSS_VIEW: fn(&Store, FileID, u32) -> Option<css::ast::View<'_>> = Store::css_view;
const READ_DECLARATION: fn(&Store, FileID, &[u8]) -> u32 = Store::declaration_of;
const READ_ERRORS: fn(&Store, FileID) -> &[SyntaxError] = Store::errors_of;
const READ_FACTS: fn(&Store, FileID) -> &[Fact] = Store::facts_of;
const READ_FILES: fn(&Store) -> usize = read_files;
const READ_FIND: fn(&Store, u64) -> u32 = Store::find;
const READ_GENERATION: fn(&Store, FileID) -> u32 = Store::generation_of;
const READ_GO_SEMANTIC: fn(&Store, FileID) -> Option<&GoSemantic> = Store::go_semantic;
const READ_GO_VIEW: fn(&Store, FileID, u32) -> Option<go::ast::View<'_>> = Store::go_view;
const READ_HASH: fn(&Store, FileID) -> u64 = Store::hash_of;

const READ_JAVASCRIPT_SEMANTIC: fn(&Store, FileID) -> Option<&JavaScriptSemantic> =
    Store::javascript_semantic;

const READ_JAVASCRIPT_VIEW: fn(&Store, FileID, u32) -> Option<javascript::ast::View<'_>> =
    Store::javascript_view;

const READ_LANGUAGE: fn(&Store, FileID) -> Language = Store::language_of;
const READ_LIMITS: fn(&Store) -> &Limits = Store::limits;
const READ_LINES: fn(&Store, FileID) -> &lines::Index = Store::lines_of;
const READ_MARKUP_ERRORS: fn(&Store, FileID) -> &[TreeError] = Store::markup_errors_of;
const READ_MARKUP_TOKENS: fn(&Store, FileID) -> &[markup::Token] = Store::markup_tokens_of;
const READ_MARKUP_TREE: fn(&Store, FileID) -> Option<&markup::tree::Tree> = Store::markup_tree_of;

const READ_MARKUP_VIEW: fn(&Store, FileID, u32) -> Option<markup::view::View<'_, '_>> =
    Store::markup_view;

const READ_ODIN_SEMANTIC: fn(&Store, FileID) -> Option<&OdinSemantic> = Store::odin_semantic;
const READ_ODIN_VIEW: fn(&Store, FileID, u32) -> Option<odin::ast::View<'_>> = Store::odin_view;
const READ_PATH_HASH: fn(&Store, FileID) -> u64 = Store::path_hash_of;
const READ_PENDING_COUNT: fn(&Store) -> u32 = Store::pending_count;
const READ_PYTHON_CHECKS: fn(&Store, FileID) -> &[PythonCheckError] = Store::python_checks_of;
const READ_PYTHON_SEMANTIC: fn(&Store, FileID) -> Option<&PythonSemantic> = Store::python_semantic;

const READ_PYTHON_VIEW: fn(&Store, FileID, u32) -> Option<python::ast::View<'_>> =
    Store::python_view;

const READ_REBUILDS: fn(&Store, FileID) -> u32 = Store::rebuilds_of;
const READ_RESIDENT: fn(&Store, FileID) -> bool = Store::resident;
const READ_RUST_SEMANTIC: fn(&Store, FileID) -> Option<&RustSemantic> = Store::rust_semantic;
const READ_RUST_VIEW: fn(&Store, FileID, u32) -> Option<rust::ast::View<'_>> = Store::rust_view;
const READ_SEQUENCE: fn(&Store, FileID) -> u64 = Store::sequence_of;
const READ_SLOT_BYTES: fn(&Store, u32) -> u32 = Store::slot_bytes_of;
const READ_SLOT_LANGUAGE: fn(&Store, u32) -> Language = Store::slot_language_of;
const READ_SOURCE: fn(&Store, FileID) -> &[u8] = Store::source_of;
const READ_STRUCTURE: fn(&Store, FileID) -> Structure = Store::structure_of;
const READ_TOKENS: fn(&Store, FileID) -> &[Token] = Store::tokens_of;

const READ_TYPESCRIPT_VIEW: fn(&Store, FileID, u32) -> Option<typescript::ast::View<'_>> =
    Store::typescript_view;

const READ_WALK: fn(&Store, FileID) -> usize = read_walk;
const READ_WALK_FROM: fn(&Store, FileID, u32) -> usize = read_walk_from;
const READ_ZIG_SEMANTIC: fn(&Store, FileID) -> Option<&ZigSemantic> = Store::zig_semantic;
const READ_ZIG_VIEW: fn(&Store, FileID, u32) -> Option<zig::ast::View<'_>> = Store::zig_view;
const GRAPH_COUNT: fn(&Graph) -> u32 = Graph::count;
const GRAPH_CURRENT: fn(&Graph, &Store) -> bool = Graph::current;
const GRAPH_CYCLES: fn(&Graph) -> usize = graph_cycles;
const GRAPH_DEPENDENTS: fn(&Graph, FileID) -> usize = graph_dependents;
const GRAPH_EDGES: fn(&Graph, FileID) -> &[Edge] = Graph::edges_of;
const GRAPH_GENERATION: fn(&Graph, FileID) -> u32 = Graph::generation_of;
const GRAPH_ORDER: fn(&Graph) -> &[FileID] = Graph::order;

const fn shared<T>()
where
    T: Send + Sync,
{
}

fn limits_of(file_count_max: u32) -> Limits {
    let mut slots = [[0_u32; CLASS_COUNT]; Language::COUNT];

    for language in LANGUAGES {
        slots[language.index()][Limits::class_of(4_096) as usize] = file_count_max;
    }

    Limits {
        file_count_max: file_count_max * u32::try_from(LANGUAGES.len()).expect("six fits"),
        front: front::Limits {
            binding_count_max: 256,
            error_count_max: 64,
            event_count_max: 4_096,
            export_count_max: 256,
            fact_count_max: 256,
            node_count_max: 2_048,
            reference_count_max: 256,
            scope_count_max: 64,
            segment_count_max: 256,
            token_count_max: 1_024,
        },
        line_count_max: 256,
        slots,
        source_bytes_max: 4_096,
    }
}

fn source_of(index: u32) -> Vec<u8> {
    let mut held = Vec::new();

    if index > 0 {
        held.extend_from_slice(format!("import m{:02}\n", index - 1).as_bytes());
    }

    held.extend_from_slice(format!("value{index} = {index}\n").as_bytes());
    held.extend_from_slice(b"\n\ndef run():\n    return 1\n");

    held
}

fn project() -> (Store, Graph) {
    let limits = limits_of(FILE_COUNT);
    let mut store = Store::reserve(&limits, Eviction::Reject);

    for index in 0..FILE_COUNT {
        let key = format!("m{index:02}");
        let inserted = store.insert(hash_of(key.as_bytes()), Language::Python, &source_of(index));

        assert!(inserted != NONE);
    }

    let mut graph = Graph::reserve(256, limits.file_count_max);

    assert!(graph.build(&store, resolve));

    (store, graph)
}

fn resolve(specifier: &[u8], _from: FileID, store: &Store) -> u32 {
    store.find(hash_of(specifier))
}

fn rule(store: &Store, graph: &Graph, file: FileID, sink: &mut Sink<'_>) {
    for step in store.walk(file) {
        let Step::Enter(node) = step else {
            continue;
        };

        let Some(view) = store.python_view(file, node) else {
            continue;
        };

        let recorded = sink.record("PAR001", Severity::Hint, view.span(), "a recorded finding");

        assert!(recorded);
    }

    let index = file.index();

    if index == 0 {
        return;
    }

    let name = format!("value{}", index - 1);

    let code = match target_of(store, graph, file, name.as_bytes()) {
        Target::Binding(_) => "PAR010",
        Target::Maybe => "PAR011",
        Target::Missing => "PAR012",
        Target::Unresolved => "PAR013",
    };

    let recorded = sink.record(
        code,
        Severity::Warning,
        scylla::bounded::Span {
            length: 1,
            offset: index,
        },
        "a recorded finding",
    );

    assert!(recorded);
}

fn baseline(store: &Store, graph: &Graph, files: &[FileID]) -> Vec<(u32, &'static str, u32)> {
    let held_rules = Registry::reserve(&RULES);
    let registry = &held_rules;
    let mut found = Vec::new();

    for file in files {
        let mut held = Diagnostics::reserve(1 << 12, 1 << 12);

        {
            let mut sink = Sink::new(*file, &mut held, registry);

            rule(store, graph, *file, &mut sink);
        }

        for diagnostic in &held {
            found.push((file.index(), diagnostic.code, diagnostic.span.offset));
        }
    }

    found
}

fn shards(files: &[FileID], stride: usize) -> Vec<Vec<FileID>> {
    let mut found = vec![Vec::new(); THREAD_COUNT as usize];

    for (position, file) in files.iter().enumerate() {
        let index = if stride == 0 {
            position * THREAD_COUNT as usize / files.len()
        } else {
            position % THREAD_COUNT as usize
        };

        found[index].push(*file);
    }

    found
}

fn merged(
    store: &Store,
    graph: &Graph,
    files: &[FileID],
    stride: usize,
) -> Vec<(u32, &'static str, u32)> {
    let sets = shards(files, stride);
    let held_registry = Registry::reserve(&RULES);
    let registry = &held_registry;

    let parts: Vec<Vec<(u32, &'static str, u32)>> = thread::scope(|scope| {
        let mut handles = Vec::new();

        for set in &sets {
            handles.push(scope.spawn(move || {
                let mut held = Diagnostics::reserve(1 << 12, 1 << 12);
                let mut found = Vec::new();

                for file in set {
                    held.clear();

                    {
                        let mut sink = Sink::new(*file, &mut held, registry);

                        rule(store, graph, *file, &mut sink);
                    }

                    for diagnostic in &held {
                        found.push((file.index(), diagnostic.code, diagnostic.span.offset));
                    }
                }

                found
            }));
        }

        handles
            .into_iter()
            .map(|handle| handle.join().expect("the shard finished"))
            .collect()
    });

    let mut found: Vec<(u32, &'static str, u32)> = parts.into_iter().flatten().collect();

    found.sort_unstable();

    found
}

fn files_of(store: &Store) -> Vec<FileID> {
    store.files().collect()
}

fn soup(random: &mut Random) -> Vec<u8> {
    let length =
        SOUP_LENGTHS[random.below(u32::try_from(SOUP_LENGTHS.len()).expect("five")) as usize];

    let mut found = Vec::with_capacity(length as usize);

    for _ in 0..length {
        found.push(u8::try_from(random.below(256)).expect("a byte fits in u8"));
    }

    found
}

fn rounds() -> u32 {
    let Ok(held) = std::env::var("SCYLLA_ADVERSARIAL") else {
        return ROUND_COUNT_DEFAULT;
    };

    held.parse()
        .expect("SCYLLA_ADVERSARIAL names a round count")
}

fn churn(eviction: Eviction) {
    const KEY_COUNT: u32 = 16;
    let limits = limits_of(4);
    let mut store = Store::reserve(&limits, eviction);
    let mut random = Random::new(SEED_CHURN ^ u64::from(eviction == Eviction::Reject));
    let mut keys = Vec::new();

    for index in 0..KEY_COUNT {
        keys.push(format!("f{index:02}"));
    }

    for round in 0..rounds() {
        let language =
            LANGUAGES[random.below(u32::try_from(LANGUAGES.len()).expect("six")) as usize];

        let key = &keys[random.below(KEY_COUNT) as usize];
        let source = soup(&mut random);
        let index = store.insert(hash_of(key.as_bytes()), language, &source);

        if index != NONE {
            let file = FileID::of(index);

            assert_eq!(store.source_of(file), source.as_slice());
            assert_eq!(store.language_of(file), language);
            assert_eq!(store.find(hash_of(key.as_bytes())), index);
        }

        assert_eq!(store.count(), findable(&store, &keys));
        assert!(store.count() <= limits.file_count_max);

        if round % 8 != 0 {
            continue;
        }

        let held: Vec<FileID> = store.files().collect();

        for file in held {
            store.evict(file);
        }

        assert_eq!(store.count(), 0);
        assert_eq!(findable(&store, &keys), 0);
    }

    store.clear();

    assert_eq!(store.count(), 0);
}

fn findable(store: &Store, keys: &[String]) -> u32 {
    let mut found = 0;

    for key in keys {
        if store.find(hash_of(key.as_bytes())) != NONE {
            found += 1;
        }
    }

    found
}

#[test]
fn the_store_is_shared_across_threads_and_read_only() {
    shared::<Store>();
    shared::<Graph>();
    shared::<FileID>();

    let (store, graph) = project();
    let files = files_of(&store);
    let held = files[0];

    slot_reads(&store, held);
    view_reads(&store, held);
    graph_reads(&graph, &store, held);
}

fn slot_reads(store: &Store, held: FileID) {
    assert_eq!(READ_COUNT(store), FILE_COUNT);
    assert!(READ_MOVES(store) >= u64::from(FILE_COUNT));
    assert!(READ_ERRORS(store, held).is_empty());
    assert_eq!(READ_FIND(store, hash_of(b"m00")), held.index());
    assert!(READ_LINES(store, held).count() > 0);
    assert!(!READ_SOURCE(store, held).is_empty());
    assert_eq!(READ_STRUCTURE(store, held), Structure::Complete);
    assert!(!READ_TOKENS(store, held).is_empty());
    assert_eq!(READ_FILES(store), FILE_COUNT as usize);
    assert_eq!(READ_LANGUAGE(store, held), Language::Python);

    assert_eq!(
        READ_LIMITS(store).file_count_max,
        store.limits().file_count_max
    );

    assert!(READ_RESIDENT(store, held));
    assert_ne!(READ_HASH(store, held), 0);
    assert_eq!(READ_PATH_HASH(store, held), hash_of(b"m00"));
    assert_eq!(READ_GENERATION(store, held), 1);
    assert_eq!(READ_REBUILDS(store, held), 1);
    assert!(READ_SEQUENCE(store, held) > 0);
    assert!(READ_SLOT_BYTES(store, held.index()) as usize >= READ_SOURCE(store, held).len());
    assert_eq!(
        READ_SLOT_LANGUAGE(store, held.index()),
        READ_LANGUAGE(store, held)
    );
    assert_eq!(READ_FACTS(store, held).len(), store.facts_of(held).len());
    assert_eq!(READ_DECLARATION(store, held, b"missing_name"), NONE);
    assert!(READ_MARKUP_ERRORS(store, held).is_empty());
    assert!(READ_MARKUP_TOKENS(store, held).is_empty());
    assert!(READ_MARKUP_TREE(store, held).is_none());
}

fn view_reads(store: &Store, held: FileID) {
    assert!(READ_WALK(store, held) > 0);
    assert!(READ_WALK_FROM(store, held, 0) > 0);
    assert!(READ_PYTHON_CHECKS(store, held).is_empty());
    assert!(READ_PYTHON_SEMANTIC(store, held).is_some());
    assert!(READ_PYTHON_VIEW(store, held, 0).is_some());
    assert!(READ_CSS_SEMANTIC(store, held).is_none());
    assert!(READ_CSS_VIEW(store, held, 0).is_none());
    assert!(READ_GO_SEMANTIC(store, held).is_none());
    assert!(READ_GO_VIEW(store, held, 0).is_none());
    assert!(READ_JAVASCRIPT_SEMANTIC(store, held).is_none());
    assert!(READ_JAVASCRIPT_VIEW(store, held, 0).is_none());
    assert!(READ_MARKUP_VIEW(store, held, 0).is_none());
    assert!(READ_ODIN_SEMANTIC(store, held).is_none());
    assert!(READ_ODIN_VIEW(store, held, 0).is_none());
    assert!(READ_RUST_SEMANTIC(store, held).is_none());
    assert!(READ_RUST_VIEW(store, held, 0).is_none());
    assert!(READ_TYPESCRIPT_VIEW(store, held, 0).is_none());
    assert!(READ_ZIG_SEMANTIC(store, held).is_none());
    assert!(READ_ZIG_VIEW(store, held, 0).is_none());
}

fn graph_reads(graph: &Graph, store: &Store, held: FileID) {
    assert_eq!(GRAPH_ORDER(graph).len(), FILE_COUNT as usize);
    assert!(GRAPH_COUNT(graph) > 0);
    assert!(GRAPH_CURRENT(graph, store));
    assert_eq!(GRAPH_CYCLES(graph), 0);
    assert_eq!(GRAPH_GENERATION(graph, held), READ_GENERATION(store, held));

    assert_eq!(
        GRAPH_DEPENDENTS(graph, held),
        graph.dependents_of(held).count()
    );

    assert_eq!(GRAPH_EDGES(graph, held).len(), graph.edges_of(held).len());
}

#[test]
fn every_read_accessor_is_named_in_the_table() {
    let root = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("src/project");

    let table = fs::read_to_string(
        PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/project_parallel.rs"),
    )
    .expect("the table is readable");

    let mut checked = 0;

    for name in ["graph.rs", "store.rs", "view.rs"] {
        let source = fs::read_to_string(root.join(name)).expect("the source is readable");
        let mut owner = String::new();

        for line in source.lines() {
            if let Some(rest) = line.strip_prefix("impl ") {
                owner = rest.trim_end_matches(" {").to_owned();
            }

            if !matches!(owner.as_str(), "Graph" | "Store") {
                continue;
            }

            let held = line.trim_start();

            let Some(rest) = held
                .strip_prefix("pub fn ")
                .or_else(|| held.strip_prefix("pub const fn "))
            else {
                continue;
            };

            let Some((accessor, tail)) = rest.split_once('(') else {
                continue;
            };

            if !tail.starts_with("&self") {
                continue;
            }

            assert!(
                table.contains(&format!("::{accessor};"))
                    || table.contains(&format!("::{accessor}\n"))
                    || table.contains(&format!(".{accessor}("))
                    || table.contains(&format!("::{accessor},")),
                "{name}: {accessor} is not named in the parallel table"
            );

            checked += 1;
        }
    }

    assert!(checked > 30, "the accessors are not being read");
}

#[test]
fn a_fan_out_matches_the_single_threaded_run() {
    let (store, graph) = project();
    let files = files_of(&store);
    let mut single = baseline(&store, &graph, &files);

    single.sort_unstable();

    assert_eq!(merged(&store, &graph, &files, 0), single);
}

#[test]
fn a_second_interleaving_reports_the_same_bytes() {
    let (store, graph) = project();
    let files = files_of(&store);
    let first = merged(&store, &graph, &files, 0);
    let second = merged(&store, &graph, &files, 1);

    assert_eq!(first, second);
    assert!(!first.is_empty());
}

#[test]
fn a_rejecting_store_churns_without_leaking_a_slot() {
    churn(Eviction::Reject);
}

#[test]
fn an_evicting_store_churns_without_leaking_a_slot() {
    churn(Eviction::LeastRecentlyUsed);
}

static RULES: [Rule; 4] = [
    Rule {
        citation_nasa: "",
        citation_tigerstyle: "",
        default_on: true,
        description: "",
        code: "A001",
        explanation: "",
        fix_title: "",
        fixable: Fixable::Never,
        name: "probe-one",
        preview: false,
        severity: Severity::Warning,
        summary: "",
        url: "",
    },
    Rule {
        citation_nasa: "",
        citation_tigerstyle: "",
        default_on: true,
        description: "",
        code: "B001",
        explanation: "",
        fix_title: "",
        fixable: Fixable::Never,
        name: "probe-two",
        preview: false,
        severity: Severity::Warning,
        summary: "",
        url: "",
    },
    Rule {
        citation_nasa: "",
        citation_tigerstyle: "",
        default_on: true,
        description: "",
        code: "C001",
        explanation: "",
        fix_title: "",
        fixable: Fixable::Never,
        name: "probe-three",
        preview: false,
        severity: Severity::Warning,
        summary: "",
        url: "",
    },
    Rule {
        citation_nasa: "",
        citation_tigerstyle: "",
        default_on: true,
        description: "",
        code: "D001",
        explanation: "",
        fix_title: "",
        fixable: Fixable::Never,
        name: "probe-four",
        preview: false,
        severity: Severity::Warning,
        summary: "",
        url: "",
    },
];

#[test]
fn pending_builds_run_in_parallel_and_match_the_serial_answer() {
    let limits = limits_of(FILE_COUNT);
    let mut serial = Store::reserve(&limits, Eviction::Reject);
    let mut parallel = Store::reserve(&limits, Eviction::Reject);

    for index in 0..FILE_COUNT {
        let key = format!("m{index:02}");
        let source = source_of(index);
        let built = serial.insert(hash_of(key.as_bytes()), Language::Python, &source);
        let placed = parallel.insert_pending(hash_of(key.as_bytes()), Language::Python, &source);

        assert!(built != NONE);
        assert_eq!(built, placed);
    }

    assert_eq!(parallel.pending_count(), FILE_COUNT);

    let mut scratches = Vec::new();

    for _ in 0..4 {
        scratches.push(BuildScratch::reserve(&limits));
    }

    {
        let builds = parallel.pending_builds();
        let count = builds.count();

        thread::scope(|scope| {
            for (worker, scratch) in scratches.iter_mut().enumerate() {
                let handle = &builds;

                scope.spawn(move || {
                    let mut at = u32::try_from(worker).expect("four fits");

                    while at < count {
                        handle.build(at, scratch);

                        at += 4;
                    }
                });
            }
        });
    }

    parallel.pending_clear();

    assert_eq!(parallel.pending_count(), 0);
    assert_eq!(READ_PENDING_COUNT(&parallel), 0);
    assert_eq!(serial.count(), parallel.count());

    for index in 0..FILE_COUNT {
        let key = format!("m{index:02}");
        let file = FileID::of(serial.find(hash_of(key.as_bytes())));
        let twin = FileID::of(parallel.find(hash_of(key.as_bytes())));

        assert_eq!(serial.structure_of(file), parallel.structure_of(twin));
        assert_eq!(serial.source_of(file), parallel.source_of(twin));
        assert_eq!(serial.tokens_of(file).len(), parallel.tokens_of(twin).len());
        assert_eq!(serial.facts_of(file).len(), parallel.facts_of(twin).len());
        assert_eq!(serial.errors_of(file).len(), parallel.errors_of(twin).len());

        assert_eq!(
            serial.lines_of(file).count(),
            parallel.lines_of(twin).count()
        );
    }
}

#[test]
#[should_panic(expected = "a pending slot is built exactly once")]
fn a_pending_slot_refuses_a_second_build() {
    let limits = limits_of(FILE_COUNT);
    let mut store = Store::reserve(&limits, Eviction::Reject);
    let placed = store.insert_pending(hash_of(b"m00"), Language::Python, &source_of(0));

    assert!(placed != NONE);

    let mut scratch = BuildScratch::reserve(&limits);
    let builds = store.pending_builds();

    builds.build(0, &mut scratch);
    builds.build(0, &mut scratch);
}
