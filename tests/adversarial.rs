use core::sync::atomic::{AtomicU32, Ordering};
use std::fs;
use std::path::{Path, PathBuf};

use scylla::bounded::{BoundedVec, Random};
use scylla::language::Lexer;
use scylla::lex::{CSS, GO, JAVASCRIPT, ODIN, PYTHON, RUST, TYPESCRIPT, ZIG};
use scylla::markup::blocks::{self, BlockMap};
use scylla::markup::tree::{self as markup_tree, Tree as MarkupTree};
use scylla::markup::{self, Tokens as MarkupTokens};
use scylla::syntax::Structure;
use scylla::syntax::css::{classify::classify as css_classify, parse as css_parse};
use scylla::syntax::go::{classify::classify as go_classify, parse as go_parse};
use scylla::syntax::javascript::{
    classify::classify as javascript_classify,
    parse as javascript_parse,
};
use scylla::syntax::odin::{classify::classify as odin_classify, parse as odin_parse};
use scylla::syntax::python::{classify::classify as python_classify, parse as python_parse};
use scylla::syntax::rust::{classify::classify as rust_classify, parse as rust_parse};
use scylla::syntax::typescript::{
    classify::classify as typescript_classify,
    dialect::Dialect,
    kind::TypeScriptKind,
    parse as typescript_parse,
};
use scylla::syntax::zig::{classify::classify as zig_classify, parse as zig_parse};
use scylla::token::{Lex, Token, Tokens};
use scylla::tree::{Events, Kind, NONE, Node, Step, Tree, walk};
use scylla::trivia::{self, Gap};

const BLOCK_COUNT_MAX: u32 = 1 << 13;
const ERROR_COUNT_MAX: u32 = 1 << 10;
const EVENT_COUNT_MAX: u32 = 1 << 19;
const FLIP_BYTES: [u8; 8] = [0x00, b'\n', b'"', b'\'', b'\\', b'{', b'}', 0xFF];
const FLIP_OFFSET_COUNT_MAX: u32 = 32;
const FRAGMENT_COUNT_MAX: u32 = 8;
const MARKUP_NODE_COUNT_MAX: u32 = 1 << 17;
const MARKUP_TOKEN_COUNT_MAX: u32 = 1 << 18;
const NODE_COUNT_MAX: u32 = 1 << 16;
const PREFIX_COUNT_MAX: u32 = 64;
const RAW_COUNT_MAX: u32 = 1 << 16;
const ROUND_COUNT_DEFAULT: u32 = 256;
const SEED_FRAGMENT: u64 = 0x2C4F_1E77_A93B_D501;
const SEED_MUTATION: u64 = 0x7F19_4B2D_6E05_C3A7;
const SEED_SOUP: u64 = 0x0F1A_35C9_D827_B64D;
const SOUP_LENGTHS: [u32; 5] = [0, 1, 7, 64, 4_096];
const STRIDE: u64 = 0x9E37_79B9_7F4A_7C15;
const TOKEN_COUNT_MAX: u32 = 1 << 16;
static SKIPPED: AtomicU32 = AtomicU32::new(0);

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum Generator {
    Flip,
    Fragment,
    Mutation,
    Prefix,
    Soup,
}

type Build<K> = fn(&[u8], &[Token], &[K], &mut Events<K>, &mut Tree<K>) -> Structure;
type Classify<K> = fn(&[u8], &[Token], &mut Tokens, &mut BoundedVec<K>) -> bool;

struct Machine<K: Kind> {
    events: Events<K>,
    lexed: Tokens,
    raw: BoundedVec<K>,
    tokens: Tokens,
    tree: Tree<K>,
}

impl<K: Kind> Machine<K> {
    fn reserve() -> Self {
        Self {
            events: Events::reserve(EVENT_COUNT_MAX),
            lexed: Tokens::reserve(TOKEN_COUNT_MAX),
            raw: BoundedVec::reserve(RAW_COUNT_MAX),
            tokens: Tokens::reserve(TOKEN_COUNT_MAX),
            tree: Tree::reserve(NODE_COUNT_MAX, ERROR_COUNT_MAX),
        }
    }
}

#[test]
fn a_long_else_if_chain_reports_instead_of_overflowing() {
    const ARM_COUNT: u32 = 10_000;
    let mut rust = Vec::new();

    rust.extend_from_slice(b"fn held() {\n    if a {\n    }");

    for _ in 0..ARM_COUNT {
        rust.extend_from_slice(b" else if a {\n    }");
    }

    rust.extend_from_slice(b"\n}\n");

    let mut machine = Machine::<scylla::syntax::rust::kind::RustKind>::reserve();

    exercise(
        &mut machine,
        &RUST,
        rust_classify,
        rust_parse::build,
        &rust,
        "rust: else if chain",
    );

    let mut go = Vec::new();

    go.extend_from_slice(b"package held\n\nfunc held() {\n\tif a {\n\t}");

    for _ in 0..ARM_COUNT {
        go.extend_from_slice(b" else if a {\n\t}");
    }

    go.extend_from_slice(b"\n}\n");

    let mut held = Machine::<scylla::syntax::go::kind::GoKind>::reserve();

    exercise(
        &mut held,
        &GO,
        go_classify,
        go_parse::build,
        &go,
        "go: else if chain",
    );
}

#[test]
fn byte_soup_holds_every_invariant() {
    sweep(Generator::Soup);
}

#[test]
fn fragment_soup_holds_every_invariant() {
    sweep(Generator::Fragment);
}

#[test]
fn a_mutated_fixture_holds_every_invariant() {
    sweep(Generator::Mutation);
}

#[test]
fn every_truncated_prefix_of_a_fixture_holds_every_invariant() {
    sweep(Generator::Prefix);
}

#[test]
fn every_single_byte_change_to_a_fixture_holds_every_invariant() {
    sweep(Generator::Flip);
}

fn sweep(generator: Generator) {
    language(
        "css",
        &["css"],
        &CSS,
        css_classify,
        css_parse::build,
        generator,
    );

    language("go", &["go"], &GO, go_classify, go_parse::build, generator);

    language(
        "javascript",
        &["js"],
        &JAVASCRIPT,
        javascript_classify,
        javascript_parse::build,
        generator,
    );

    language(
        "odin",
        &["odin"],
        &ODIN,
        odin_classify,
        odin_parse::build,
        generator,
    );

    language(
        "python",
        &["py"],
        &PYTHON,
        python_classify,
        python_parse::build,
        generator,
    );

    language(
        "rust",
        &["rs"],
        &RUST,
        rust_classify,
        rust_parse::build,
        generator,
    );

    language(
        "typescript",
        &["ts"],
        &TYPESCRIPT,
        typescript_classify_ts,
        typescript_build_ts,
        generator,
    );

    language(
        "tsx",
        &["tsx"],
        &TYPESCRIPT,
        typescript_classify_tsx,
        typescript_build_tsx,
        generator,
    );

    language(
        "zig",
        &["zig"],
        &ZIG,
        zig_classify,
        zig_parse::build,
        generator,
    );

    template(generator);
}

fn typescript_classify_ts(
    source: &[u8],
    tokens: &[Token],
    out: &mut Tokens,
    raw: &mut BoundedVec<TypeScriptKind>,
) -> bool {
    typescript_classify(source, tokens, out, raw, Dialect::Ts)
}

fn typescript_classify_tsx(
    source: &[u8],
    tokens: &[Token],
    out: &mut Tokens,
    raw: &mut BoundedVec<TypeScriptKind>,
) -> bool {
    typescript_classify(source, tokens, out, raw, Dialect::Tsx)
}

fn typescript_build_ts(
    source: &[u8],
    tokens: &[Token],
    raw: &[TypeScriptKind],
    events: &mut Events<TypeScriptKind>,
    tree: &mut Tree<TypeScriptKind>,
) -> Structure {
    typescript_parse::build(source, tokens, raw, events, tree, Dialect::Ts)
}

fn typescript_build_tsx(
    source: &[u8],
    tokens: &[Token],
    raw: &[TypeScriptKind],
    events: &mut Events<TypeScriptKind>,
    tree: &mut Tree<TypeScriptKind>,
) -> Structure {
    typescript_parse::build(source, tokens, raw, events, tree, Dialect::Tsx)
}

fn language<K>(
    name: &str,
    extensions: &[&str],
    lexer: &dyn Lexer,
    classify: Classify<K>,
    build: Build<K>,
    generator: Generator,
) where
    K: Kind + core::fmt::Debug,
{
    let held = fixtures(extensions);

    assert!(!held.is_empty(), "{name} carries no fixtures");

    let mut machine = Machine::<K>::reserve();

    for (round, source) in inputs(generator, name, &held).iter().enumerate() {
        let label = format!("{name}: {generator:?} round {round}");

        exercise(&mut machine, lexer, classify, build, source, &label);
    }
}

fn template(generator: Generator) {
    let held = fixtures(&["html"]);

    assert!(!held.is_empty(), "the template tree carries no fixtures");

    let mut map = BlockMap::reserve(BLOCK_COUNT_MAX);
    let mut tokens = MarkupTokens::reserve(MARKUP_TOKEN_COUNT_MAX);
    let mut tree = MarkupTree::reserve(MARKUP_NODE_COUNT_MAX, ERROR_COUNT_MAX);

    for (round, source) in inputs(generator, "markup", &held).iter().enumerate() {
        let label = format!("markup: {generator:?} round {round}");
        let outcome = markup::lex(source, &mut tokens);

        tiles(source, tokens.as_slice(), outcome, &label);
        markup_tree::build(source, tokens.as_slice(), &mut tree);
        blocks::build(source, tokens.as_slice(), &tree, &[], &[], &mut map);
        links_hold(&tree, &label);

        let walked = walk(&tree).count();

        assert_eq!(walked, 2 * tree.count() as usize, "{label}");
        assert!(tree.errors().len() <= ERROR_COUNT_MAX as usize, "{label}");
    }
}

fn exercise<K>(
    machine: &mut Machine<K>,
    lexer: &dyn Lexer,
    classify: Classify<K>,
    build: Build<K>,
    source: &[u8],
    label: &str,
) where
    K: Kind + core::fmt::Debug,
{
    machine.lexed.clear();
    lexer.lex(source, &mut machine.lexed);

    if !classify(
        source,
        machine.lexed.as_slice(),
        &mut machine.tokens,
        &mut machine.raw,
    ) {
        overflowed(machine, lexer, classify, source, label);

        return;
    }

    assert_eq!(
        machine.tokens.as_slice().len(),
        machine.raw.len(),
        "{label}: the classified stream and the kind table differ in length"
    );

    machine.tree.clear();

    let outcome = build(
        source,
        machine.tokens.as_slice(),
        &machine.raw,
        &mut machine.events,
        &mut machine.tree,
    );

    assert!(
        matches!(
            outcome,
            Structure::Complete | Structure::TooDeep | Structure::Truncated
        ),
        "{label}"
    );

    spans_hold(&machine.tree, machine.tokens.as_slice(), source, label);
    links_hold(&machine.tree, label);

    let walked = walk(&machine.tree).count();

    assert_eq!(
        walked,
        2 * machine.tree.count() as usize,
        "{label}: the walk and the node count disagree"
    );

    for step in walk(&machine.tree) {
        match step {
            Step::Enter(node) | Step::Leave(node) => {
                assert!(node < machine.tree.count(), "{label}");
            }
        }
    }

    assert!(
        machine.tree.errors().len() <= ERROR_COUNT_MAX as usize,
        "{label}: the error table outgrew its capacity"
    );

    repeats(machine, lexer, classify, build, source, label, outcome);
}

fn overflowed<K>(
    machine: &mut Machine<K>,
    lexer: &dyn Lexer,
    classify: Classify<K>,
    source: &[u8],
    label: &str,
) where
    K: Kind + core::fmt::Debug,
{
    let length = u32::try_from(source.len()).expect("a generated source fits in u32");
    let held: Vec<Token> = machine.tokens.as_slice().to_vec();
    let consumed = held.last().map_or(0, |token| token.end());

    assert!(
        consumed <= length,
        "{label}: an overflowed stream runs past the source"
    );

    for (index, token) in held.iter().enumerate() {
        assert!(
            token.end() <= length,
            "{label}: token {index} of an overflowed stream runs past the source"
        );
    }

    let mut covered = 0;
    let mut end_previous = 0;

    for (count, Gap { span, token }) in trivia::gaps(consumed, &held).enumerate() {
        assert!(
            span.offset >= end_previous,
            "{label}: an overflowed stream runs its gaps backwards"
        );

        assert_eq!(
            u64::from(token),
            count as u64,
            "{label}: an overflowed stream numbers its gaps out of order"
        );

        covered += span.length;
        end_previous = span.end();
    }

    for token in &held {
        covered += token.length;
    }

    assert_eq!(
        covered, consumed,
        "{label}: the tokens and the gaps do not tile the consumed prefix"
    );

    machine.lexed.clear();
    lexer.lex(source, &mut machine.lexed);

    assert!(
        !classify(
            source,
            machine.lexed.as_slice(),
            &mut machine.tokens,
            &mut machine.raw
        ),
        "{label}: a second run of an overflowed classification does not overflow"
    );

    let repeated = machine
        .tokens
        .as_slice()
        .last()
        .map_or(0, |token| token.end());

    assert_eq!(
        repeated, consumed,
        "{label}: a second run overflows at another byte"
    );

    skipped(label);
}

fn skipped(label: &str) {
    use std::io::Write as _;

    let count = SKIPPED.fetch_add(1, Ordering::Relaxed) + 1;

    let Ok(path) = std::env::var("SCYLLA_REPORT") else {
        return;
    };

    let Ok(mut file) = fs::OpenOptions::new().append(true).create(true).open(path) else {
        return;
    };

    let _ = writeln!(file, "{label}: classify overflowed, {count} skipped so far");
}

fn repeats<K>(
    machine: &mut Machine<K>,
    lexer: &dyn Lexer,
    classify: Classify<K>,
    build: Build<K>,
    source: &[u8],
    label: &str,
    outcome: Structure,
) where
    K: Kind + core::fmt::Debug,
{
    let events: Vec<_> = machine.events.as_slice().to_vec();
    let nodes: Vec<Node<K>> = machine.tree.as_slice().to_vec();

    machine.lexed.clear();
    lexer.lex(source, &mut machine.lexed);

    assert!(classify(
        source,
        machine.lexed.as_slice(),
        &mut machine.tokens,
        &mut machine.raw
    ));

    machine.tree.clear();

    let repeated = build(
        source,
        machine.tokens.as_slice(),
        &machine.raw,
        &mut machine.events,
        &mut machine.tree,
    );

    assert_eq!(repeated, outcome, "{label}: a second run differs");

    assert!(
        machine.events.as_slice() == &*events,
        "{label}: a second run records other events"
    );

    assert!(
        machine.tree.as_slice() == &*nodes,
        "{label}: a second run builds another tree"
    );
}

fn links_hold<K>(tree: &Tree<K>, label: &str)
where
    K: Kind,
{
    let count = tree.count();

    for index in 0..count {
        let node = tree.at(index);

        assert!(
            node.child_first == NONE || node.child_first < count,
            "{label}: node {index} names a child out of bounds"
        );

        assert!(
            node.parent == NONE || node.parent < count,
            "{label}: node {index} names a parent out of bounds"
        );

        assert!(
            node.sibling_next == NONE || node.sibling_next < count,
            "{label}: node {index} names a sibling out of bounds"
        );
    }
}

fn spans_hold<K>(tree: &Tree<K>, tokens: &[Token], source: &[u8], label: &str)
where
    K: Kind,
{
    let count = tree.count();

    for index in 0..count {
        let node = tree.at(index);

        assert!(
            node.token_start <= node.token_end,
            "{label}: node {index} closes before it opens"
        );

        assert!(
            node.token_end as usize <= tokens.len(),
            "{label}: node {index} names a token out of bounds"
        );

        let span = node.span(tokens);

        assert!(
            span.end() as usize <= source.len(),
            "{label}: node {index} spans past the source"
        );
    }
}

fn tiles(source: &[u8], tokens: &[markup::Token], outcome: Lex, label: &str) {
    let mut end_previous = 0;

    for (index, token) in tokens.iter().enumerate() {
        assert_eq!(
            token.offset, end_previous,
            "{label}: token {index} leaves a gap or overlaps"
        );

        assert!(token.length > 0, "{label}: token {index} covers no byte");

        end_previous = token.end();
    }

    assert!(
        end_previous as usize <= source.len(),
        "{label}: the stream runs past the source"
    );

    if outcome == Lex::Complete {
        assert_eq!(
            end_previous as usize,
            source.len(),
            "{label}: the stream stops short of the source end"
        );
    }
}

fn inputs(generator: Generator, name: &str, held: &[Vec<u8>]) -> Vec<Vec<u8>> {
    if generator == Generator::Flip {
        return flips(held);
    }

    if generator == Generator::Prefix {
        return prefixes(held);
    }

    let seed = seed_of(generator, name);
    let mut random = Random::new(seed);
    let rounds = rounds();
    let mut found = Vec::with_capacity(rounds as usize);

    for _ in 0..rounds {
        let source = match generator {
            Generator::Fragment => fragment(&mut random, held),
            Generator::Mutation => mutation(&mut random, held),
            Generator::Soup => soup(&mut random),
            Generator::Flip | Generator::Prefix => {
                unreachable!("a deterministic sweep builds its own inputs")
            }
        };

        found.push(source);
    }

    found
}

fn prefixes(held: &[Vec<u8>]) -> Vec<Vec<u8>> {
    let mut found = Vec::new();

    for source in held {
        let length = count_of(source.len());
        let stride = (length / PREFIX_COUNT_MAX).max(1);
        let mut offset = 0;

        while offset < length {
            found.push(source[..offset as usize].to_vec());
            offset += stride;
        }

        found.push(source.clone());
    }

    found
}

fn flips(held: &[Vec<u8>]) -> Vec<Vec<u8>> {
    let mut found = Vec::new();

    for source in held {
        let length = count_of(source.len());

        if length == 0 {
            continue;
        }

        let stride = (length / FLIP_OFFSET_COUNT_MAX).max(1);
        let mut offset = 0;

        while offset < length {
            for byte in FLIP_BYTES {
                if source[offset as usize] == byte {
                    continue;
                }

                let mut flipped = source.clone();

                flipped[offset as usize] = byte;
                found.push(flipped);
            }

            offset += stride;
        }
    }

    found
}

fn fragment(random: &mut Random, held: &[Vec<u8>]) -> Vec<u8> {
    let count = random.below(FRAGMENT_COUNT_MAX) + 1;
    let mut found = Vec::new();

    for _ in 0..count {
        let source = &held[random.below(count_of(held.len())) as usize];

        if source.is_empty() {
            continue;
        }

        let start = random.below(count_of(source.len()));
        let end = start + random.below(count_of(source.len()) - start + 1);

        found.extend_from_slice(&source[start as usize..end as usize]);
    }

    found
}

fn mutation(random: &mut Random, held: &[Vec<u8>]) -> Vec<u8> {
    let mut found = held[random.below(count_of(held.len())) as usize].clone();

    if found.is_empty() {
        return found;
    }

    let length = count_of(found.len());
    let offset = random.below(length);

    match random.below(4) {
        0 => found[offset as usize] ^= 1 << random.below(8),
        1 => {
            let end = offset + random.below(length - offset + 1);

            found.drain(offset as usize..end as usize);
        }
        2 => {
            let end = offset + random.below(length - offset + 1);
            let copied = found[offset as usize..end as usize].to_vec();

            found.splice(offset as usize..offset as usize, copied);
        }
        _ => found.truncate(offset as usize),
    }

    found
}

fn soup(random: &mut Random) -> Vec<u8> {
    let length = SOUP_LENGTHS[random.below(count_of(SOUP_LENGTHS.len())) as usize];
    let mut found = Vec::with_capacity(length as usize);

    for _ in 0..length {
        found.push(u8::try_from(random.below(256)).expect("a byte fits in u8"));
    }

    found
}

fn seed_of(generator: Generator, name: &str) -> u64 {
    let base = match generator {
        Generator::Fragment => SEED_FRAGMENT,
        Generator::Mutation => SEED_MUTATION,
        Generator::Soup => SEED_SOUP,
        Generator::Flip | Generator::Prefix => {
            unreachable!("a deterministic sweep draws no randomness")
        }
    };

    let mut stride = 0_u64;

    for byte in name.as_bytes() {
        stride = stride.wrapping_mul(STRIDE).wrapping_add(u64::from(*byte));
    }

    (base ^ stride) | 1
}

fn rounds() -> u32 {
    let Ok(held) = std::env::var("SCYLLA_ADVERSARIAL") else {
        return ROUND_COUNT_DEFAULT;
    };

    held.parse()
        .expect("SCYLLA_ADVERSARIAL names a round count")
}

fn count_of(length: usize) -> u32 {
    u32::try_from(length).expect("a bounded length fits in u32")
}

fn fixtures(extensions: &[&str]) -> Vec<Vec<u8>> {
    let root = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures");
    let mut found = Vec::new();

    collect(&root, extensions, &mut found);
    found.sort();

    found
}

fn collect(root: &Path, extensions: &[&str], found: &mut Vec<Vec<u8>>) {
    let Ok(entries) = fs::read_dir(root) else {
        return;
    };

    let mut stack: Vec<PathBuf> = entries
        .filter_map(|entry| Some(entry.ok()?.path()))
        .collect();

    while let Some(path) = stack.pop() {
        if path.is_dir() {
            let Ok(nested) = fs::read_dir(&path) else {
                continue;
            };

            stack.extend(nested.filter_map(|entry| Some(entry.ok()?.path())));

            continue;
        }

        let Some(extension) = path.extension().and_then(|held| held.to_str()) else {
            continue;
        };

        if !extensions.contains(&extension) {
            continue;
        }

        let Ok(source) = fs::read(&path) else {
            continue;
        };

        found.push(source);
    }
}
