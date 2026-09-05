#![expect(
    clippy::print_stdout,
    reason = "a benchmark binary reports its table through stdout"
)]

use core::alloc::{GlobalAlloc, Layout};
use core::sync::atomic::{AtomicU64, Ordering};
use std::alloc::System;
use std::path::PathBuf;
use std::time::Instant;

use scylla::bounded::{BoundedVec, Buffer};
use scylla::brackets::Pairs;
use scylla::diagnostic::{Diagnostic, Diagnostics, Message, Severity};
use scylla::fix::{self, Applicability, Fixes};
use scylla::format::print::Options;
use scylla::language::{Language, Lexer};
use scylla::lex::{CSS, GO, JAVASCRIPT, ODIN, PYTHON, RUST, TYPESCRIPT, ZIG};
use scylla::lines;
use scylla::markup::blocks::{self, BlockMap};
use scylla::markup::tree as markup_tree;
use scylla::markup::{self, Tokens as MarkupTokens};
use scylla::outline::{javascript as outline_javascript, python as outline_python};
use scylla::project::{
    CLASS_COUNT,
    Eviction,
    FileID,
    Graph,
    Limits,
    NONE,
    Store,
    hash_of,
    target_of,
};
use scylla::structure::{self, Nodes, Shape};
use scylla::syntax::front;
use scylla::syntax::typescript::dialect::Dialect;
use scylla::token::{Token, TokenKind, Tokens};
use scylla::tree::{Events, Kind, Structure, Tree};

fn main() {
    println!(
        "{:<40} {:>9}    {:>13}    {:>16}    {:>9}",
        "benchmark", "bytes", "minimum", "median", "throughput",
    );

    css_benches();
    fix_benches();
    diagnostic_benches();
    go_benches();
    go_shape_benches();
    javascript_benches();
    markup_benches();
    odin_benches();
    outline_benches();
    project_benches();
    python_benches();
    small_file_benches();
    python_shape_benches();
    rust_benches();
    typescript_benches();
    zig_benches();
}

const ARENA_BYTES_MAX: u32 = 1 << 22;
const BYTES_TARGET: usize = 1 << 20;
const EDGE_COUNT_MAX: u32 = 1 << 10;
const ELEMENT_COUNT_MAX: u32 = 1 << 21;
const ERROR_COUNT_MAX: u32 = 1 << 12;
const EVENT_COUNT_MAX: u32 = 1 << 22;
const ITERATION_COUNT_MAX: u32 = 1 << 20;
const LINE_COUNT_MAX: u32 = 1 << 18;
const NODE_COUNT_MAX: u32 = 1 << 21;
const OUT_BYTES_MAX: u32 = 1 << 23;
const SAMPLE_COUNT: usize = 11;
const SAMPLE_NANOS_MIN: u128 = 20_000_000;
const SLOT_COUNT: u32 = 64;
const TOKEN_COUNT_MAX: u32 = 1 << 21;
const WARMUP_COUNT: u32 = 3;
const ALLOWED_ALLOCATING: [&str; 0] = [];

struct Counting;

static ALLOCATIONS: AtomicU64 = AtomicU64::new(0);

unsafe impl GlobalAlloc for Counting {
    unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
        ALLOCATIONS.fetch_add(1, Ordering::Relaxed);

        unsafe { System.alloc(layout) }
    }

    unsafe fn dealloc(&self, pointer: *mut u8, layout: Layout) {
        unsafe { System.dealloc(pointer, layout) }
    }
}

#[global_allocator]
static ALLOCATOR: Counting = Counting;

fn filter() -> Option<String> {
    std::env::var("SCYLLA_BENCH").ok()
}

fn selected(name: &str, filter: Option<&String>) -> bool {
    filter.is_none_or(|held| name.contains(held.as_str()))
}

fn measure(name: &str, bytes: usize, run: &mut dyn FnMut()) {
    if !selected(name, filter().as_ref()) {
        return;
    }

    for _ in 0..WARMUP_COUNT {
        run();
    }

    let calibration = Instant::now();

    run();

    let single = calibration.elapsed().as_nanos().max(1);

    let iterations = u32::try_from((SAMPLE_NANOS_MIN / single) + 1)
        .unwrap_or(ITERATION_COUNT_MAX)
        .min(ITERATION_COUNT_MAX);

    let before = ALLOCATIONS.load(Ordering::Relaxed);
    let mut samples = [0_u64; SAMPLE_COUNT];

    for sample in &mut samples {
        let start = Instant::now();

        for _ in 0..iterations {
            run();
        }

        *sample = u64::try_from(start.elapsed().as_nanos() / u128::from(iterations))
            .expect("one iteration fits a u64 of nanoseconds");
    }

    let allocated = ALLOCATIONS.load(Ordering::Relaxed) - before;

    samples.sort_unstable();

    let median = samples[SAMPLE_COUNT / 2].max(1);
    let minimum = samples[0];
    let tenths = u64::try_from(bytes).expect("an input fits a u64 of bytes") * 10_000 / median;

    println!(
        "{name:<40} {bytes:>9} B  min {minimum:>9} ns  median {median:>9} ns  {:>7}.{} MB/s{}",
        tenths / 10,
        tenths % 10,
        if allocated == 0 {
            String::new()
        } else {
            format!("  ALLOCATED {allocated}")
        }
    );

    assert!(
        allocated == 0 || ALLOWED_ALLOCATING.contains(&name),
        "{name} allocated {allocated} times inside its measured loop"
    );
}

fn root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
}

fn collect_of(directory: &std::path::Path, extension: &str, out: &mut Vec<Vec<u8>>) {
    let mut stack = vec![directory.to_path_buf()];

    while let Some(current) = stack.pop() {
        let Ok(entries) = std::fs::read_dir(&current) else {
            continue;
        };

        for entry in entries.flatten() {
            let path = entry.path();

            if path.is_dir() {
                stack.push(path);

                continue;
            }

            if path.extension().is_none_or(|held| held != extension) {
                continue;
            }

            let Ok(source) = std::fs::read(&path) else {
                continue;
            };

            out.push(source);
        }
    }
}

fn sources_of(directory: &str, extension: &str) -> Vec<Vec<u8>> {
    let mut sources = Vec::new();

    collect_of(
        &root().join("tests/fixtures").join(directory),
        extension,
        &mut sources,
    );

    sources.sort_unstable();

    assert!(
        !sources.is_empty(),
        "{directory} holds no {extension} fixture"
    );

    sources
}

fn corpus_of(directory: &str, extension: &str) -> Vec<u8> {
    let sources = sources_of(directory, extension);
    let mut out = Vec::with_capacity(BYTES_TARGET + (1 << 16));

    while out.len() < BYTES_TARGET {
        for source in &sources {
            out.extend_from_slice(source);
            out.push(b'\n');
        }
    }

    out
}

fn shape_chain() -> Vec<u8> {
    let mut out = Vec::new();

    out.extend_from_slice(b"fn chain() {\n    let sum = a");

    for _ in 0..2_000 {
        out.extend_from_slice(b" + a");
    }

    out.extend_from_slice(b";\n    let member = x");

    for _ in 0..2_000 {
        out.extend_from_slice(b".a");
    }

    out.extend_from_slice(b";\n    let tried = q");

    out.resize(out.len() + 1_000, b'?');

    out.extend_from_slice(b";\n}\n");

    out
}

fn shape_identifiers() -> Vec<u8> {
    let mut out = Vec::new();

    for index in 0..100_000_u32 {
        out.extend_from_slice(b"abcdef");
        out.push(b' ');

        if index % 16 == 15 {
            out.push(b'\n');
        }
    }

    out
}

fn shape_doc_comments() -> Vec<u8> {
    let mut out = Vec::new();

    for index in 0..5_000_u32 {
        for _ in 0..20 {
            out.extend_from_slice(b"/// a documented line of prose about the item below\n");
        }

        out.extend_from_slice(format!("fn item_{index}() {{\n    let held = 1;\n}}\n").as_bytes());
    }

    out
}

fn shape_names_python() -> Vec<u8> {
    let mut out = Vec::new();

    for index in 0..2_000_u32 {
        out.extend_from_slice(format!("name_{index} = {index}\n").as_bytes());
    }

    for function in 0..200_u32 {
        out.extend_from_slice(format!("def read_{function}():\n").as_bytes());

        for index in 0..100_u32 {
            out.extend_from_slice(
                format!("    print(name_{})\n", function * 10 + index).as_bytes(),
            );
        }
    }

    out
}

fn shape_rebound_names_python() -> Vec<u8> {
    let mut out = Vec::new();

    for index in 0..200_u32 {
        out.extend_from_slice(format!("name_{index} = 0\n").as_bytes());
    }

    for index in 0..4_000_u32 {
        out.extend_from_slice(format!("print(name_{})\n", index % 200).as_bytes());
    }

    for round in 1..40_u32 {
        for index in 0..200_u32 {
            out.extend_from_slice(format!("name_{index} = {round}\n").as_bytes());
        }
    }

    out
}

fn shape_names_javascript() -> Vec<u8> {
    let mut out = Vec::new();

    for index in 0..2_000_u32 {
        out.extend_from_slice(format!("const name_{index} = {index};\n").as_bytes());
    }

    for function in 0..200_u32 {
        out.extend_from_slice(format!("function read_{function}() {{\n").as_bytes());

        for index in 0..100_u32 {
            out.extend_from_slice(
                format!("    console.log(name_{});\n", function * 10 + index).as_bytes(),
            );
        }

        out.extend_from_slice(b"}\n");
    }

    out
}

fn shape_names_go() -> Vec<u8> {
    let mut out = Vec::new();

    out.extend_from_slice(b"package held\n");

    for index in 0..2_000_u32 {
        out.extend_from_slice(format!("var name_{index} = {index}\n").as_bytes());
    }

    for function in 0..200_u32 {
        out.extend_from_slice(format!("func read_{function}() {{\n").as_bytes());

        for index in 0..100_u32 {
            out.extend_from_slice(format!("    use(name_{})\n", function * 10 + index).as_bytes());
        }

        out.extend_from_slice(b"}\n");
    }

    out
}

fn shape_short_decls() -> Vec<u8> {
    let mut out = Vec::new();

    out.extend_from_slice(b"package held\n");

    for function in 0..5_000_u32 {
        out.extend_from_slice(format!("func held_{function}() {{\n").as_bytes());

        for index in 0..20_u32 {
            out.extend_from_slice(format!("\tname_{index} := {index}\n").as_bytes());
        }

        out.extend_from_slice(b"}\n");
    }

    out
}

fn shape_facts_typescript() -> Vec<u8> {
    let mut out = Vec::new();

    for index in 0..4_000_u32 {
        out.extend_from_slice(format!("const name_{index} = {index};\n").as_bytes());
    }

    for index in 0..4_000_u32 {
        out.extend_from_slice(format!("export {{ name_{index} }};\n").as_bytes());
    }

    out
}

fn shape_facts_python() -> Vec<u8> {
    let mut out = Vec::new();

    for index in 0..4_000_u32 {
        out.extend_from_slice(format!("name_{index} = {index}\n").as_bytes());
    }

    for index in 0..4_000_u32 {
        out.extend_from_slice(format!("from held import name_{index}\n").as_bytes());
    }

    out
}

fn shape_facts_go() -> Vec<u8> {
    let mut out = Vec::new();

    out.extend_from_slice(b"package held\n");

    for index in 0..4_000_u32 {
        out.extend_from_slice(format!("import name_{index} \"held/name_{index}\"\n").as_bytes());
    }

    for index in 0..4_000_u32 {
        out.extend_from_slice(format!("var value_{index} = {index}\n").as_bytes());
    }

    out
}

fn shape_deep_blocks() -> Vec<u8> {
    let mut out = Vec::new();

    out.extend_from_slice(b"package held\n");

    for index in 0..500_u32 {
        out.extend_from_slice(format!("func held_{index}() {{\n").as_bytes());

        for outer in 0..4_u32 {
            out.extend_from_slice(format!("\tfor a := 0; a < {outer}; a++ {{\n").as_bytes());
            out.extend_from_slice(b"\t\tif a > 1 {\n");
            out.extend_from_slice(b"\t\t\tswitch a {\n\t\t\tcase 0:\n");
            out.extend_from_slice(b"\t\t\t\tuse(a)\n\t\t\t}\n\t\t}\n\t}\n");
        }

        out.extend_from_slice(b"}\n");
    }

    out
}

fn shape_nested_literal() -> Vec<u8> {
    let mut out = Vec::new();

    out.extend_from_slice(b"const held = ");

    for _ in 0..40 {
        out.extend_from_slice(b"{ a: [ ");
    }

    for index in 0..2_000_u32 {
        out.extend_from_slice(format!("{{ key_{index}: {index} }}, ").as_bytes());
    }

    for _ in 0..40 {
        out.extend_from_slice(b" ] }");
    }

    out.extend_from_slice(b";\n");

    out
}

fn shape_comparisons() -> Vec<u8> {
    let mut out = Vec::new();

    out.extend_from_slice(b"const held = [");

    for _ in 0..5_000 {
        out.extend_from_slice(b"x < y, ");
    }

    out.extend_from_slice(b"];\n");

    out
}

fn shape_punctuation() -> Vec<u8> {
    let mut out = Vec::new();

    while out.len() < BYTES_TARGET {
        out.extend_from_slice(b"a=(b?c[d]:{e:f})+g(h,i)-j;k={l:[m,n],o:p};q=r?s:t;");
    }

    out
}

fn shape_many_functions_python() -> Vec<u8> {
    let mut out = Vec::new();

    for index in 0..3_000_u32 {
        out.extend_from_slice(
            format!("def held_{index}(a, b):\n    return a + b + {index}\n\n").as_bytes(),
        );
    }

    out
}

fn shape_many_functions_javascript() -> Vec<u8> {
    let mut out = Vec::new();

    for index in 0..3_000_u32 {
        out.extend_from_slice(
            format!("function held_{index}(a, b) {{\n    return a + b + {index};\n}}\n\n")
                .as_bytes(),
        );
    }

    out
}

fn shape_wide_literal() -> Vec<u8> {
    let mut out = Vec::new();

    out.extend_from_slice(b"function held() {\n    const wide = {\n");

    for index in 0..5_000_u32 {
        out.extend_from_slice(format!("        key_{index}: {index},\n").as_bytes());
    }

    out.extend_from_slice(b"    };\n\n    return wide;\n}\n");

    out
}

fn shape_renames() -> Vec<u8> {
    let mut out = Vec::new();

    for index in 0..5_000_u32 {
        out.extend_from_slice(format!("name_{index} = one_{index}\n").as_bytes());
    }

    out
}

type ClassifyOf<K> = fn(&[u8], &[Token], &mut Tokens, &mut BoundedVec<K>) -> bool;
type ParseOf<K> = fn(&[u8], &[Token], &[K], &mut Events<K>, &mut Tree<K>) -> Structure;

struct Syntax<K>
where
    K: Kind,
{
    events: Events<K>,
    lexed: Tokens,
    raw: BoundedVec<K>,
    tokens: Tokens,
    tree: Tree<K>,
}

impl<K> Syntax<K>
where
    K: Kind,
{
    fn reserve() -> Self {
        Self {
            events: Events::reserve(EVENT_COUNT_MAX),
            lexed: Tokens::reserve(TOKEN_COUNT_MAX),
            raw: BoundedVec::reserve(TOKEN_COUNT_MAX),
            tokens: Tokens::reserve(TOKEN_COUNT_MAX),
            tree: Tree::reserve(NODE_COUNT_MAX, ERROR_COUNT_MAX),
        }
    }

    fn lex(&mut self, lexer: &dyn Lexer, source: &[u8]) {
        self.lexed.clear();
        lexer.lex(source, &mut self.lexed);
    }

    fn classify(&mut self, lexer: &dyn Lexer, classify: ClassifyOf<K>, source: &[u8]) {
        self.lex(lexer, source);

        classify(
            source,
            self.lexed.as_slice(),
            &mut self.tokens,
            &mut self.raw,
        );
    }

    fn parse(
        &mut self,
        lexer: &dyn Lexer,
        classify: ClassifyOf<K>,
        parse: ParseOf<K>,
        source: &[u8],
    ) -> Structure {
        self.classify(lexer, classify, source);

        parse(
            source,
            self.tokens.as_slice(),
            &self.raw,
            &mut self.events,
            &mut self.tree,
        )
    }
}

fn syntax_of<K>(
    language: &str,
    source: &[u8],
    lexer: &'static dyn Lexer,
    classify: ClassifyOf<K>,
    parse: ParseOf<K>,
    held: &mut Syntax<K>,
) where
    K: Kind,
{
    measure(&format!("lex-{language}"), source.len(), &mut || {
        held.lex(lexer, source);
    });

    measure(&format!("classify-{language}"), source.len(), &mut || {
        held.classify(lexer, classify, source);
    });

    measure(&format!("parse-{language}"), source.len(), &mut || {
        let _ = held.parse(lexer, classify, parse, source);
    });
}

fn typescript_classify(
    source: &[u8],
    tokens: &[Token],
    out: &mut Tokens,
    raw: &mut BoundedVec<scylla::syntax::typescript::kind::TypeScriptKind>,
) -> bool {
    scylla::syntax::typescript::classify::classify(source, tokens, out, raw, Dialect::Ts)
}

fn typescript_parse(
    source: &[u8],
    tokens: &[Token],
    raw: &[scylla::syntax::typescript::kind::TypeScriptKind],
    events: &mut Events<scylla::syntax::typescript::kind::TypeScriptKind>,
    tree: &mut Tree<scylla::syntax::typescript::kind::TypeScriptKind>,
) -> Structure {
    scylla::syntax::typescript::parse::build(source, tokens, raw, events, tree, Dialect::Ts)
}

fn rust_benches() {
    use scylla::syntax::rust::classify::classify;
    use scylla::syntax::rust::kind::RustKind;
    use scylla::syntax::rust::parse;
    use scylla::syntax::rust::semantic::Semantic;

    let chain = shape_chain();
    let corpus = corpus_of("rust", "rs");
    let documented = shape_doc_comments();
    let identifiers = shape_identifiers();
    let universe: [&[u8]; 3] = [b"Self", b"usize", b"Some"];
    let mut held = Syntax::<RustKind>::reserve();

    syntax_of("rust", &corpus, &RUST, classify, parse::build, &mut held);

    measure("classify-rust-identifiers", identifiers.len(), &mut || {
        held.classify(&RUST, classify, &identifiers);
    });

    measure("parse-rust-chain", chain.len(), &mut || {
        let _ = held.parse(&RUST, classify, parse::build, &chain);
    });

    measure("parse-rust-doc-comments", documented.len(), &mut || {
        let _ = held.parse(&RUST, classify, parse::build, &documented);
    });

    let mut semantic = Semantic::reserve(1 << 18, 1 << 19, 1 << 16, 1 << 16);

    measure("semantic-rust", corpus.len(), &mut || {
        let _ = held.parse(&RUST, classify, parse::build, &corpus);

        let _ = semantic.build(
            &corpus,
            held.tokens.as_slice(),
            &held.raw,
            &held.tree,
            &universe,
        );
    });

    drop(semantic);

    let mut formatter = scylla::format::rust::Formatter::reserve(ELEMENT_COUNT_MAX, OUT_BYTES_MAX);
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    measure("format-rust", corpus.len(), &mut || {
        let outcome = held.parse(&RUST, classify, parse::build, &corpus);

        let input = scylla::format::rust::Input {
            options: Options::DEFAULT,
            outcome,
            raw: &held.raw,
            source: &corpus,
            tokens: held.tokens.as_slice(),
            tree: &held.tree,
        };

        let _ = formatter.format(&input, &mut out);
    });
}

fn go_shape_benches() {
    use scylla::syntax::go::classify::classify;
    use scylla::syntax::go::kind::GoKind;
    use scylla::syntax::go::parse;
    use scylla::syntax::go::semantic::Semantic;

    let facts = shape_facts_go();
    let shorts = shape_short_decls();
    let universe: [&[u8]; 3] = [b"error", b"len", b"string"];
    let mut held = Syntax::<GoKind>::reserve();
    let _ = held.parse(&GO, classify, parse::build, &facts);
    let mut semantic = Semantic::reserve(1 << 18, 1 << 19, 1 << 16, 1 << 16);

    measure("shape-facts-go", facts.len(), &mut || {
        let _ = held.parse(&GO, classify, parse::build, &facts);

        let _ = semantic.build(
            &facts,
            held.tokens.as_slice(),
            &held.raw,
            &held.tree,
            &universe,
        );
    });

    measure("shape-short-decls", shorts.len(), &mut || {
        let _ = held.parse(&GO, classify, parse::build, &shorts);

        let _ = semantic.build(
            &shorts,
            held.tokens.as_slice(),
            &held.raw,
            &held.tree,
            &universe,
        );
    });
}

fn go_benches() {
    use scylla::syntax::go::classify::classify;
    use scylla::syntax::go::kind::GoKind;
    use scylla::syntax::go::parse;
    use scylla::syntax::go::semantic::Semantic;

    let blocks = shape_deep_blocks();
    let corpus = corpus_of("go", "go");
    let names = shape_names_go();
    let universe: [&[u8]; 3] = [b"error", b"len", b"string"];
    let mut held = Syntax::<GoKind>::reserve();

    syntax_of("go", &corpus, &GO, classify, parse::build, &mut held);

    let mut semantic = Semantic::reserve(1 << 18, 1 << 19, 1 << 16, 1 << 16);

    measure("semantic-go", corpus.len(), &mut || {
        let _ = held.parse(&GO, classify, parse::build, &corpus);

        let _ = semantic.build(
            &corpus,
            held.tokens.as_slice(),
            &held.raw,
            &held.tree,
            &universe,
        );
    });

    measure("semantic-go-names", names.len(), &mut || {
        let _ = held.parse(&GO, classify, parse::build, &names);

        let _ = semantic.build(
            &names,
            held.tokens.as_slice(),
            &held.raw,
            &held.tree,
            &universe,
        );
    });

    drop(semantic);

    let mut formatter = scylla::format::go::Formatter::reserve(ELEMENT_COUNT_MAX, OUT_BYTES_MAX);
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    let options = Options {
        indent_width: 8,
        tabs: true,
        ..Options::DEFAULT
    };

    measure("format-go", corpus.len(), &mut || {
        let outcome = held.parse(&GO, classify, parse::build, &corpus);

        let input = scylla::format::go::Input {
            options,
            outcome,
            raw: &held.raw,
            source: &corpus,
            tokens: held.tokens.as_slice(),
            tree: &held.tree,
        };

        let _ = formatter.format(&input, &mut out);
    });

    measure("format-go-deep-blocks", blocks.len(), &mut || {
        let outcome = held.parse(&GO, classify, parse::build, &blocks);

        let input = scylla::format::go::Input {
            options,
            outcome,
            raw: &held.raw,
            source: &blocks,
            tokens: held.tokens.as_slice(),
            tree: &held.tree,
        };

        let _ = formatter.format(&input, &mut out);
    });
}

fn zig_benches() {
    use scylla::syntax::zig::classify::classify;
    use scylla::syntax::zig::kind::ZigKind;
    use scylla::syntax::zig::parse;
    use scylla::syntax::zig::semantic::Semantic;

    let corpus = corpus_of("zig", "zig");
    let universe: [&[u8]; 3] = [b"bool", b"usize", b"void"];
    let mut held = Syntax::<ZigKind>::reserve();

    syntax_of("zig", &corpus, &ZIG, classify, parse::build, &mut held);

    let mut semantic = Semantic::reserve(1 << 18, 1 << 19, 1 << 16, 1 << 16);

    measure("semantic-zig", corpus.len(), &mut || {
        let _ = held.parse(&ZIG, classify, parse::build, &corpus);

        let _ = semantic.build(
            &corpus,
            held.tokens.as_slice(),
            &held.raw,
            &held.tree,
            &universe,
        );
    });

    drop(semantic);

    let mut formatter = scylla::format::zig::Formatter::reserve(ELEMENT_COUNT_MAX, OUT_BYTES_MAX);
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    measure("format-zig", corpus.len(), &mut || {
        let outcome = held.parse(&ZIG, classify, parse::build, &corpus);

        let input = scylla::format::zig::Input {
            options: Options::DEFAULT,
            outcome,
            raw: &held.raw,
            source: &corpus,
            tokens: held.tokens.as_slice(),
            tree: &held.tree,
        };

        let _ = formatter.format(&input, &mut out);
    });
}

fn odin_benches() {
    use scylla::syntax::odin::classify::classify;
    use scylla::syntax::odin::kind::OdinKind;
    use scylla::syntax::odin::parse;
    use scylla::syntax::odin::semantic::Semantic;

    let corpus = corpus_of("odin", "odin");
    let universe: [&[u8]; 3] = [b"bool", b"int", b"string"];
    let mut held = Syntax::<OdinKind>::reserve();

    syntax_of("odin", &corpus, &ODIN, classify, parse::build, &mut held);

    let mut semantic = Semantic::reserve(1 << 18, 1 << 19, 1 << 16, 1 << 16);

    measure("semantic-odin", corpus.len(), &mut || {
        let _ = held.parse(&ODIN, classify, parse::build, &corpus);

        let _ = semantic.build(
            &corpus,
            held.tokens.as_slice(),
            &held.raw,
            &held.tree,
            &universe,
        );
    });

    drop(semantic);

    let mut formatter = scylla::format::odin::Formatter::reserve(ELEMENT_COUNT_MAX, OUT_BYTES_MAX);
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    let options = Options {
        tabs: true,
        ..Options::DEFAULT
    };

    measure("format-odin", corpus.len(), &mut || {
        let outcome = held.parse(&ODIN, classify, parse::build, &corpus);

        let input = scylla::format::odin::Input {
            options,
            outcome,
            raw: &held.raw,
            source: &corpus,
            tokens: held.tokens.as_slice(),
            tree: &held.tree,
        };

        let _ = formatter.format(&input, &mut out);
    });
}

fn css_benches() {
    use scylla::syntax::css::classify::classify;
    use scylla::syntax::css::kind::CSSKind;
    use scylla::syntax::css::parse;
    use scylla::syntax::css::semantic::Semantic;

    let corpus = corpus_of("css", "css");
    let mut held = Syntax::<CSSKind>::reserve();

    syntax_of("css", &corpus, &CSS, classify, parse::build, &mut held);

    let mut semantic = Semantic::reserve(1 << 18, 1 << 18, 1 << 16);

    measure("semantic-css", corpus.len(), &mut || {
        let _ = held.parse(&CSS, classify, parse::build, &corpus);
        let _ = semantic.build(&corpus, held.tokens.as_slice(), &held.raw, &held.tree);
    });

    drop(semantic);

    let mut formatter = scylla::format::css::Formatter::reserve(ELEMENT_COUNT_MAX, OUT_BYTES_MAX);
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    measure("format-css", corpus.len(), &mut || {
        let outcome = held.parse(&CSS, classify, parse::build, &corpus);

        let input = scylla::format::css::Input {
            options: Options::DEFAULT,
            outcome,
            raw: &held.raw,
            source: &corpus,
            tokens: held.tokens.as_slice(),
            tree: &held.tree,
        };

        let _ = formatter.format(&input, &mut out);
    });
}

fn javascript_syntax_benches(held: &mut Syntax<scylla::syntax::javascript::kind::JavaScriptKind>) {
    use scylla::syntax::javascript::classify::classify;
    use scylla::syntax::javascript::parse;

    let comparisons = shape_comparisons();
    let corpus = corpus_of("javascript", "js");
    let nested = shape_nested_literal();
    let punctuation = shape_punctuation();

    syntax_of(
        "javascript",
        &corpus,
        &JAVASCRIPT,
        classify,
        parse::build,
        held,
    );

    measure("lex-javascript-punctuation", punctuation.len(), &mut || {
        held.lex(&JAVASCRIPT, &punctuation);
    });

    measure("parse-javascript-nested-literal", nested.len(), &mut || {
        let _ = held.parse(&JAVASCRIPT, classify, parse::build, &nested);
    });

    measure(
        "parse-javascript-comparisons",
        comparisons.len(),
        &mut || {
            let _ = held.parse(&JAVASCRIPT, classify, parse::build, &comparisons);
        },
    );
}

fn javascript_benches() {
    use scylla::syntax::javascript::classify::classify;
    use scylla::syntax::javascript::kind::JavaScriptKind;
    use scylla::syntax::javascript::parse;
    use scylla::syntax::javascript::semantic::Semantic;

    let corpus = corpus_of("javascript", "js");
    let globals: [&[u8]; 3] = [b"console", b"eval", b"require"];
    let names = shape_names_javascript();
    let wide = shape_wide_literal();
    let mut held = Syntax::<JavaScriptKind>::reserve();

    javascript_syntax_benches(&mut held);

    {
        let mut semantic = Semantic::reserve(1 << 18, 1 << 19, 1 << 16, 1 << 16);

        measure("semantic-javascript", corpus.len(), &mut || {
            let _ = held.parse(&JAVASCRIPT, classify, parse::build, &corpus);

            let _ = semantic.build(
                &corpus,
                held.tokens.as_slice(),
                &held.raw,
                &held.tree,
                None,
                &globals,
            );
        });

        measure("semantic-javascript-names", names.len(), &mut || {
            let _ = held.parse(&JAVASCRIPT, classify, parse::build, &names);

            let _ = semantic.build(
                &names,
                held.tokens.as_slice(),
                &held.raw,
                &held.tree,
                None,
                &globals,
            );
        });

        measure("semantic-javascript-wide-literal", wide.len(), &mut || {
            let _ = held.parse(&JAVASCRIPT, classify, parse::build, &wide);

            let _ = semantic.build(
                &wide,
                held.tokens.as_slice(),
                &held.raw,
                &held.tree,
                None,
                &globals,
            );
        });
    }

    let mut formatter =
        scylla::format::javascript::Formatter::reserve(ELEMENT_COUNT_MAX, OUT_BYTES_MAX);
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    measure("format-javascript", corpus.len(), &mut || {
        let outcome = held.parse(&JAVASCRIPT, classify, parse::build, &corpus);

        let input = scylla::format::javascript::Input {
            options: Options::DEFAULT,
            outcome,
            raw: &held.raw,
            source: &corpus,
            tokens: held.tokens.as_slice(),
            tree: &held.tree,
        };

        let _ = formatter.format(&input, &mut out);
    });
}

fn typescript_benches() {
    use scylla::syntax::javascript::semantic::Semantic;
    use scylla::syntax::typescript::kind::TypeScriptKind;

    let comparisons = shape_comparisons();
    let corpus = corpus_of("typescript", "ts");
    let facts = shape_facts_typescript();
    let globals: [&[u8]; 3] = [b"console", b"eval", b"require"];
    let nested = shape_nested_literal();
    let mut held = Syntax::<TypeScriptKind>::reserve();

    syntax_of(
        "typescript",
        &corpus,
        &TYPESCRIPT,
        typescript_classify,
        typescript_parse,
        &mut held,
    );

    measure("parse-typescript-nested-literal", nested.len(), &mut || {
        let _ = held.parse(&TYPESCRIPT, typescript_classify, typescript_parse, &nested);
    });

    measure(
        "parse-typescript-comparisons",
        comparisons.len(),
        &mut || {
            let _ = held.parse(
                &TYPESCRIPT,
                typescript_classify,
                typescript_parse,
                &comparisons,
            );
        },
    );

    let mut semantic = Semantic::reserve(1 << 18, 1 << 19, 1 << 16, 1 << 16);

    measure("semantic-typescript", corpus.len(), &mut || {
        let _ = held.parse(&TYPESCRIPT, typescript_classify, typescript_parse, &corpus);

        let _ = semantic.build(
            &corpus,
            held.tokens.as_slice(),
            &held.raw,
            &held.tree,
            None,
            &globals,
        );
    });

    measure("shape-facts-typescript", facts.len(), &mut || {
        let _ = held.parse(&TYPESCRIPT, typescript_classify, typescript_parse, &facts);

        let _ = semantic.build(
            &facts,
            held.tokens.as_slice(),
            &held.raw,
            &held.tree,
            None,
            &globals,
        );
    });

    drop(semantic);

    let mut formatter =
        scylla::format::typescript::Formatter::reserve(ELEMENT_COUNT_MAX, OUT_BYTES_MAX);
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    measure("format-typescript", corpus.len(), &mut || {
        let outcome = held.parse(&TYPESCRIPT, typescript_classify, typescript_parse, &corpus);

        let input = scylla::format::typescript::Input {
            options: Options::DEFAULT,
            outcome,
            raw: &held.raw,
            source: &corpus,
            tokens: held.tokens.as_slice(),
            tree: &held.tree,
        };

        let _ = formatter.format(&input, &mut out);
    });
}

fn python_rebound_benches(
    held: &mut Syntax<scylla::syntax::python::kind::PythonKind>,
    semantic: &mut scylla::syntax::python::semantic::Semantic,
    scratch: &mut scylla::syntax::python::semantic::AnnotationScratch,
    tables: &mut scylla::syntax::python::bind::Tables,
) {
    use scylla::syntax::python::bind::bind;
    use scylla::syntax::python::classify::classify;
    use scylla::syntax::python::parse;
    use scylla::syntax::python::semantic::SemanticInput;
    use scylla::syntax::python::stdlib::PythonVersion;

    let builtins: [&[u8]; 4] = [b"len", b"list", b"print", b"str"];
    let rebound = shape_rebound_names_python();

    measure("shape-rebound-names-python", rebound.len(), &mut || {
        let _ = held.parse(&PYTHON, classify, parse::build, &rebound);

        let _ = bind(
            &rebound,
            held.tokens.as_slice(),
            &held.raw,
            &held.tree,
            tables,
        );

        let _ = semantic.build(
            &SemanticInput {
                builtins: &builtins,
                raw: &held.raw,
                scopes: tables,
                source: &rebound,
                tokens: held.tokens.as_slice(),
                tree: &held.tree,
                version: PythonVersion::Py310,
            },
            scratch,
        );
    });
}

fn python_shape_benches() {
    use scylla::syntax::python::bind::{self, Tables};
    use scylla::syntax::python::classify::classify;
    use scylla::syntax::python::kind::PythonKind;
    use scylla::syntax::python::parse;
    use scylla::syntax::python::semantic::{AnnotationScratch, Semantic, SemanticInput};
    use scylla::syntax::python::stdlib::PythonVersion;

    let builtins: [&[u8]; 4] = [b"len", b"list", b"print", b"str"];
    let facts = shape_facts_python();
    let functions = shape_many_functions_python();
    let mut held = Syntax::<PythonKind>::reserve();
    let _ = held.parse(&PYTHON, classify, parse::build, &facts);
    let mut semantic = Semantic::reserve(1 << 18, 1 << 19, 1 << 16);
    let mut scratch = AnnotationScratch::reserve(1 << 8, 1 << 8);
    let mut tables = Tables::reserve(1 << 16, 1 << 18, 1 << 19, 1 << 16);

    measure("shape-facts-python", facts.len(), &mut || {
        let _ = held.parse(&PYTHON, classify, parse::build, &facts);

        let _ = bind::bind(
            &facts,
            held.tokens.as_slice(),
            &held.raw,
            &held.tree,
            &mut tables,
        );

        let _ = semantic.build(
            &SemanticInput {
                builtins: &builtins,
                raw: &held.raw,
                scopes: &tables,
                source: &facts,
                tokens: held.tokens.as_slice(),
                tree: &held.tree,
                version: PythonVersion::Py310,
            },
            &mut scratch,
        );
    });

    python_rebound_benches(&mut held, &mut semantic, &mut scratch, &mut tables);

    measure("shape-many-functions-python", functions.len(), &mut || {
        let _ = held.parse(&PYTHON, classify, parse::build, &functions);

        let _ = bind::bind(
            &functions,
            held.tokens.as_slice(),
            &held.raw,
            &held.tree,
            &mut tables,
        );

        let _ = semantic.build(
            &SemanticInput {
                builtins: &builtins,
                raw: &held.raw,
                scopes: &tables,
                source: &functions,
                tokens: held.tokens.as_slice(),
                tree: &held.tree,
                version: PythonVersion::Py310,
            },
            &mut scratch,
        );
    });
}

fn python_benches() {
    use scylla::syntax::python::classify::classify;
    use scylla::syntax::python::kind::PythonKind;
    use scylla::syntax::python::parse;

    let corpus = corpus_of("python", "py");
    let mut held = Syntax::<PythonKind>::reserve();

    syntax_of(
        "python",
        &corpus,
        &PYTHON,
        classify,
        parse::build,
        &mut held,
    );

    python_semantic_benches(&corpus, &mut held);
    python_format_benches(&mut held);
}

fn python_semantic_benches(
    corpus: &[u8],
    held: &mut Syntax<scylla::syntax::python::kind::PythonKind>,
) {
    use scylla::syntax::python::bind::{self, Tables};
    use scylla::syntax::python::classify::classify;
    use scylla::syntax::python::parse;
    use scylla::syntax::python::semantic::{AnnotationScratch, Semantic, SemanticInput};
    use scylla::syntax::python::stdlib::PythonVersion;

    let builtins: [&[u8]; 4] = [b"len", b"list", b"print", b"str"];
    let names = shape_names_python();
    let mut semantic = Semantic::reserve(1 << 18, 1 << 19, 1 << 16);
    let mut scratch = AnnotationScratch::reserve(1 << 8, 1 << 8);
    let mut tables = Tables::reserve(1 << 16, 1 << 18, 1 << 19, 1 << 16);

    measure("semantic-python-bind-only", corpus.len(), &mut || {
        let _ = held.parse(&PYTHON, classify, parse::build, corpus);
        let tokens = held.tokens.as_slice();
        let _ = bind::bind(corpus, tokens, &held.raw, &held.tree, &mut tables);
    });

    measure("semantic-python", corpus.len(), &mut || {
        let _ = held.parse(&PYTHON, classify, parse::build, corpus);

        let _ = bind::bind(
            corpus,
            held.tokens.as_slice(),
            &held.raw,
            &held.tree,
            &mut tables,
        );

        let _ = semantic.build(
            &SemanticInput {
                builtins: &builtins,
                raw: &held.raw,
                scopes: &tables,
                source: corpus,
                tokens: held.tokens.as_slice(),
                tree: &held.tree,
                version: PythonVersion::Py310,
            },
            &mut scratch,
        );
    });

    measure("semantic-python-names", names.len(), &mut || {
        let _ = held.parse(&PYTHON, classify, parse::build, &names);

        let _ = bind::bind(
            &names,
            held.tokens.as_slice(),
            &held.raw,
            &held.tree,
            &mut tables,
        );

        let _ = semantic.build(
            &SemanticInput {
                builtins: &builtins,
                raw: &held.raw,
                scopes: &tables,
                source: &names,
                tokens: held.tokens.as_slice(),
                tree: &held.tree,
                version: PythonVersion::Py310,
            },
            &mut scratch,
        );
    });

    drop(semantic);
    drop(tables);
}

fn python_format_benches(held: &mut Syntax<scylla::syntax::python::kind::PythonKind>) {
    use scylla::syntax::python::classify::classify;
    use scylla::syntax::python::parse;

    let corpus = corpus_of("python", "py");

    let mut formatter =
        scylla::format::python::Formatter::reserve(ELEMENT_COUNT_MAX, ARENA_BYTES_MAX);

    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    measure("format-python", corpus.len(), &mut || {
        let outcome = held.parse(&PYTHON, classify, parse::build, &corpus);

        let input = scylla::format::python::Input {
            line_ending: scylla::syntax::python::style::LineEnding::LineFeed,
            magic_trailing_comma: true,
            options: Options::DEFAULT,
            pragmas: &[],
            quote: scylla::format::python::QuotePreference::Double,
            outcome,
            raw: &held.raw,
            source: &corpus,
            tokens: held.tokens.as_slice(),
            tree: &held.tree,
        };

        let _ = formatter.format(&input, &mut out);
    });
}

const SPECIFICATIONS: &[blocks::TagSpecification] = &[
    blocks::TagSpecification {
        intermediates: &[b"empty"],
        name: b"for",
    },
    blocks::TagSpecification {
        intermediates: &[b"elif", b"else"],
        name: b"if",
    },
    blocks::TagSpecification {
        intermediates: &[b"else"],
        name: b"ifequal",
    },
    blocks::TagSpecification {
        intermediates: &[b"else"],
        name: b"ifnotequal",
    },
    blocks::TagSpecification {
        intermediates: &[b"plural"],
        name: b"blocktranslate",
    },
];

const WORDS: &[&[u8]] = &[b"elif", b"else", b"empty", b"plural"];

fn markup_benches() {
    let corpus = corpus_of("templates", "html");
    let sources = sources_of("templates", "html");
    let small = sources.iter().map(Vec::len).sum::<usize>();
    let mut index = lines::Index::reserve(LINE_COUNT_MAX);
    let mut map = BlockMap::reserve(1 << 16);
    let mut tokens = MarkupTokens::reserve(TOKEN_COUNT_MAX);
    let mut tree = markup_tree::Tree::reserve(NODE_COUNT_MAX, ERROR_COUNT_MAX);

    measure("markup-lex", corpus.len(), &mut || {
        markup::lex(&corpus, &mut tokens);
    });

    measure("markup-tree", corpus.len(), &mut || {
        markup::lex(&corpus, &mut tokens);
        markup_tree::build(&corpus, tokens.as_slice(), &mut tree);
    });

    measure("markup-blocks", corpus.len(), &mut || {
        markup::lex(&corpus, &mut tokens);
        markup_tree::build(&corpus, tokens.as_slice(), &mut tree);

        blocks::build(
            &corpus,
            tokens.as_slice(),
            &tree,
            SPECIFICATIONS,
            WORDS,
            &mut map,
        );
    });

    measure("markup-blocks-small", small, &mut || {
        for source in &sources {
            markup::lex(source, &mut tokens);
            markup_tree::build(source, tokens.as_slice(), &mut tree);

            blocks::build(
                source,
                tokens.as_slice(),
                &tree,
                SPECIFICATIONS,
                WORDS,
                &mut map,
            );
        }
    });

    let mut formatter = scylla::format::markup::Formatter::reserve(
        ELEMENT_COUNT_MAX,
        LINE_COUNT_MAX,
        OUT_BYTES_MAX,
    );

    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    measure("markup-format", corpus.len(), &mut || {
        markup::lex(&corpus, &mut tokens);

        let _ = index.build(&corpus);

        markup_tree::build(&corpus, tokens.as_slice(), &mut tree);

        blocks::build(
            &corpus,
            tokens.as_slice(),
            &tree,
            SPECIFICATIONS,
            WORDS,
            &mut map,
        );

        let input = scylla::format::markup::Input {
            index: &index,
            map: &map,
            options: Options::DEFAULT,
            source: &corpus,
            tokens: tokens.as_slice(),
            tree: &tree,
        };

        let _ = formatter.format(&input, &mut out);
    });
}

fn outline_benches() {
    let javascript = corpus_of("javascript", "js");
    let javascript_functions = shape_many_functions_javascript();
    let python = corpus_of("python", "py");
    let python_functions = shape_many_functions_python();
    let mut pairs = Pairs::reserve(TOKEN_COUNT_MAX);
    let mut tokens = Tokens::reserve(TOKEN_COUNT_MAX);

    {
        let mut nodes = Nodes::reserve(1 << 18);
        let mut outline = outline_python::Outline::reserve(1 << 17, 1 << 18);

        let mut run = |source: &[u8]| {
            tokens.clear();
            PYTHON.lex(source, &mut tokens);
            pairs.build(source, tokens.as_slice());

            structure::build(
                tokens.as_slice(),
                source,
                &mut nodes,
                Shape::DEFAULT,
                structure::DEPTH_MAX,
            );

            outline_python::build(
                source,
                tokens.as_slice(),
                &pairs,
                nodes.as_slice(),
                &mut outline,
            );
        };

        measure("outline-python", python.len(), &mut || {
            run(&python);
        });

        measure(
            "outline-python-many-functions",
            python_functions.len(),
            &mut || {
                run(&python_functions);
            },
        );
    }

    let mut islands = outline_javascript::Outline::reserve(1 << 17, 1 << 18, 1 << 20);

    let mut run = |source: &[u8]| {
        tokens.clear();
        JAVASCRIPT.lex(source, &mut tokens);
        pairs.build(source, tokens.as_slice());
        outline_javascript::build(source, tokens.as_slice(), &pairs, &mut islands);
    };

    measure("outline-javascript", javascript.len(), &mut || {
        run(&javascript);
    });

    measure(
        "outline-javascript-many-functions",
        javascript_functions.len(),
        &mut || {
            run(&javascript_functions);
        },
    );
}

fn record_renames(tokens: &[Token], fixes: &mut Fixes, diagnostics: &mut Diagnostics) {
    for token in tokens {
        if token.kind != TokenKind::Identifier {
            continue;
        }

        fixes.open("Rename", Applicability::Safe, 0);

        if !fixes.edit(token.span(), b"held") {
            let _ = fixes.close();

            break;
        }

        let index = fixes.close();

        if index == fix::NONE {
            break;
        }

        let pushed = diagnostics.push(Diagnostic {
            code: "PR001",
            fix: index,
            message: Message::Static("a name is renamed"),
            related_count: 0,
            related_start: 0,
            rule: scylla::rule::NONE,
            severity: Severity::Warning,
            span: token.span(),
        });

        if !pushed {
            break;
        }
    }
}

fn fix_benches() {
    let source = shape_renames();
    let mut tokens = Tokens::reserve(1 << 17);

    PYTHON.lex(&source, &mut tokens);

    let mut claimed = BoundedVec::reserve(1 << 15);
    let mut diagnostics = Diagnostics::reserve(1 << 15, 1 << 16);
    let mut fixes = Fixes::reserve(1 << 15, 1 << 16, 1 << 20);
    let mut held = BoundedVec::reserve(1 << 16);
    let mut out = Buffer::reserve(OUT_BYTES_MAX);
    let mut selected = BoundedVec::reserve(1 << 15);

    measure("fix-plan", source.len(), &mut || {
        claimed.clear();
        diagnostics.clear();
        fixes.clear();
        held.clear();
        selected.clear();
        record_renames(tokens.as_slice(), &mut fixes, &mut diagnostics);
        fix::plan(&fixes, Applicability::Safe, &mut claimed, &mut selected);

        for index in &*selected {
            let fix = *fixes.get(*index).expect("a selected fix is recorded");

            for edit in fixes.edits_of(&fix) {
                if !held.push(*edit) {
                    break;
                }
            }
        }

        let _ = fix::apply(&source, &fixes, &held, &mut out);
    });
}

fn diagnostic_benches() {
    let mut diagnostics = Diagnostics::reserve(4_096, 1 << 16);

    measure("diagnostics-sort", 0, &mut || {
        diagnostics.clear();

        for index in (0..4_096_u32).rev() {
            let pushed = diagnostics.push(Diagnostic {
                code: "PR001",
                fix: fix::NONE,
                message: Message::Static("a row to sort"),
                related_count: 0,
                related_start: 0,
                rule: scylla::rule::NONE,
                severity: Severity::Warning,
                span: scylla::bounded::Span {
                    length: 1,
                    offset: index,
                },
            });

            assert!(pushed);
        }

        diagnostics.sort();
    });
}

fn specifier_resolve(specifier: &[u8], _from: FileID, store: &Store) -> u32 {
    store.find(hash_of(specifier))
}

fn project_benches() {
    let directory = root().join("tests/fixtures/project/chain");
    let mut sources = Vec::new();

    for index in 0..20_u32 {
        let path = directory.join(format!("m{index:02}.py"));

        sources.push(std::fs::read(&path).expect("the chain fixture is readable"));
    }

    let mut slots = [[0_u32; CLASS_COUNT]; Language::COUNT];

    slots[Language::Python.index()][Limits::class_of(8_192) as usize] = SLOT_COUNT;

    let limits = Limits {
        file_count_max: SLOT_COUNT,
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
    };

    let mut graph = Graph::reserve(EDGE_COUNT_MAX, SLOT_COUNT);
    let mut store = Store::reserve(&limits, Eviction::Reject);
    let bytes = sources.iter().map(Vec::len).sum::<usize>() * SLOT_COUNT as usize / sources.len();

    let keys: Vec<u64> = (0..SLOT_COUNT)
        .map(|slot| hash_of(format!("m{slot:02}").as_bytes()))
        .collect();

    measure("project-build", bytes, &mut || {
        store.clear();

        for slot in 0..SLOT_COUNT as usize {
            let source = &sources[slot % sources.len()];
            let index = store.insert(keys[slot], Language::Python, source);

            assert!(index != NONE);
        }

        assert!(graph.build(&store, &specifier_resolve));
    });

    store.clear();

    for slot in 0..SLOT_COUNT as usize {
        let source = &sources[slot % sources.len()];
        let index = store.insert(keys[slot], Language::Python, source);

        assert!(index != NONE);
    }

    assert!(graph.build(&store, &specifier_resolve));

    measure("project-query", bytes, &mut || {
        let mut seen = 0_u32;

        for file in store.files() {
            if graph.current(&store) {
                seen += 1;
            }

            seen += u32::try_from(graph.dependents_of(file).count()).expect("a bounded count");

            let _ = core::hint::black_box(target_of(&store, &graph, file, b"value"));
        }

        let _ = core::hint::black_box(seen);
    });
}

fn small_file_benches() {
    use scylla::syntax::go::classify::classify as go_classify;
    use scylla::syntax::go::kind::GoKind;
    use scylla::syntax::go::parse::build as go_parse;
    use scylla::syntax::python::classify::classify as python_classify;
    use scylla::syntax::python::kind::PythonKind;
    use scylla::syntax::python::parse::build as python_parse;
    use scylla::syntax::rust::classify::classify as rust_classify;
    use scylla::syntax::rust::kind::RustKind;
    use scylla::syntax::rust::parse::build as rust_parse;
    use scylla::syntax::typescript::kind::TypeScriptKind;

    let go = sources_of("go", "go");
    let python = sources_of("python", "py");
    let rust = sources_of("rust", "rs");
    let typescript = sources_of("typescript", "ts");
    let mut go_held = Syntax::<GoKind>::reserve();
    let mut python_held = Syntax::<PythonKind>::reserve();
    let mut rust_held = Syntax::<RustKind>::reserve();
    let mut typescript_held = Syntax::<TypeScriptKind>::reserve();

    measure(
        "shape-small-files-rust",
        rust.iter().map(Vec::len).sum(),
        &mut || {
            for source in &rust {
                let _ = rust_held.parse(&RUST, rust_classify, rust_parse, source);
            }
        },
    );

    measure(
        "shape-small-files-go",
        go.iter().map(Vec::len).sum(),
        &mut || {
            for source in &go {
                let _ = go_held.parse(&GO, go_classify, go_parse, source);
            }
        },
    );

    measure(
        "shape-small-files-python",
        python.iter().map(Vec::len).sum(),
        &mut || {
            for source in &python {
                let _ = python_held.parse(&PYTHON, python_classify, python_parse, source);
            }
        },
    );

    measure(
        "shape-small-files-typescript",
        typescript.iter().map(Vec::len).sum(),
        &mut || {
            for source in &typescript {
                let _ = typescript_held.parse(
                    &TYPESCRIPT,
                    typescript_classify,
                    typescript_parse,
                    source,
                );
            }
        },
    );
}
