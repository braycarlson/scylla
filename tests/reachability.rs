use core::fmt::Write as _;
use std::fs;
use std::path::{Path, PathBuf};

use scylla::bounded::BoundedVec;
use scylla::language::Lexer;
use scylla::lex::{CSS, GO, JAVASCRIPT, ODIN, PYTHON, RUST, TYPESCRIPT, ZIG};
use scylla::markup::kind::{KIND_COUNT as MARKUP_KIND_COUNT, MarkupKind};
use scylla::markup::tree::{self as markup_tree, Tree as MarkupTree};
use scylla::markup::{self, Tokens as MarkupTokens};
use scylla::syntax::Structure;
use scylla::syntax::css::kind::{CSSKind, KIND_COUNT as CSS_KIND_COUNT};
use scylla::syntax::css::{classify::classify as css_classify, parse as css_parse};
use scylla::syntax::go::kind::{GoKind, KIND_COUNT as GO_KIND_COUNT};
use scylla::syntax::go::{classify::classify as go_classify, parse as go_parse};
use scylla::syntax::javascript::kind::{JavaScriptKind, KIND_COUNT as JAVASCRIPT_KIND_COUNT};
use scylla::syntax::javascript::{
    classify::classify as javascript_classify,
    parse as javascript_parse,
};
use scylla::syntax::odin::kind::{KIND_COUNT as ODIN_KIND_COUNT, OdinKind};
use scylla::syntax::odin::{classify::classify as odin_classify, parse as odin_parse};
use scylla::syntax::python::kind::{KIND_COUNT as PYTHON_KIND_COUNT, PythonKind};
use scylla::syntax::python::{classify::classify as python_classify, parse as python_parse};
use scylla::syntax::rust::kind::{KIND_COUNT as RUST_KIND_COUNT, RustKind};
use scylla::syntax::rust::{classify::classify as rust_classify, parse as rust_parse};
use scylla::syntax::typescript::kind::{KIND_COUNT as TYPESCRIPT_KIND_COUNT, TypeScriptKind};
use scylla::syntax::typescript::{
    classify::classify as typescript_classify,
    dialect::Dialect,
    parse as typescript_parse,
};
use scylla::syntax::zig::kind::{KIND_COUNT as ZIG_KIND_COUNT, ZigKind};
use scylla::syntax::zig::{classify::classify as zig_classify, parse as zig_parse};
use scylla::token::{Lex, Token, Tokens};
use scylla::tree::{Events, Kind, Tree};

const ERROR_COUNT_MAX: u32 = 1 << 10;
const EVENT_COUNT_MAX: u32 = 1 << 19;
const MARKUP_NODE_COUNT_MAX: u32 = 1 << 17;
const MARKUP_TOKEN_COUNT_MAX: u32 = 1 << 18;
const NODE_COUNT_MAX: u32 = 1 << 16;
const RAW_COUNT_MAX: u32 = 1 << 16;
const TOKEN_COUNT_MAX: u32 = 1 << 16;
const BROKEN_CSS: &[u8] = b"a { color: ` } ^ $ % ? <\n";
const BROKEN_GO: &[u8] = b"package p\n\nfunc () {\n\t$\n}\n";
const BROKEN_JAVASCRIPT: &[u8] = b"let held = ?\x01;\n";
const BROKEN_MARKUP: &[u8] = b"<p>held</span>\n";
const BROKEN_ODIN: &[u8] = b"package p\n\nheld := # asm ... => %%=\n";
const BROKEN_PYTHON: &[u8] = b"@held\n$\n";
const BROKEN_RUST: &[u8] = b"macro held() {}\n\nfn held() {\n    let held = ~`;\n}\n";
const BROKEN_TYPESCRIPT: &[u8] = b"let held = ?\x01;\n";
const BROKEN_ZIG: &[u8] = b"fn ( { $ }\n";

const UNREACHABLE_CSS: &[(&str, &str)] = &[
    (
        "Newline",
        "the lexer's whitespace_scan eats a line break before token_of sees one, so step_of never \
         maps TokenKind::Newline",
    ),
    (
        "comment",
        "reserved: css/parse.rs carries no site that wraps a comment token in a node",
    ),
    (
        "error_node",
        "reserved: css/parse.rs records a SyntaxError and recovers in place, wrapping no error \
         node",
    ),
    (
        "escape_sequence",
        "reserved: the Escape token stands on its own and css/parse.rs wraps nothing around it",
    ),
    (
        "js_comment",
        "reserved: css/classify.rs maps every comment to Comment and no site emits the JavaScript \
         form",
    ),
    (
        "string_content",
        "reserved: a string lexes to one Text token and css/parse.rs wraps it in string_value, \
         never in string_content",
    ),
];

const UNREACHABLE_GO: &[(&str, &str)] = &[
    (
        "BadDecl",
        "reserved: the kind mirrors go/ast's BadDecl and no site in go/parse.rs opens it",
    ),
    (
        "BadExpr",
        "reserved: the kind mirrors go/ast's BadExpr and no site in go/parse.rs opens it",
    ),
    (
        "BadStmt",
        "reserved: the kind mirrors go/ast's BadStmt and no site in go/parse.rs opens it",
    ),
    (
        "EmptyStmt",
        "reserved: go/parse.rs eats a bare semicolon as a terminator and opens no node for it",
    ),
    (
        "ErrorNode",
        "reserved: go/parse.rs names it only as the group kind of a frame variant that never \
         closes a group and as the kind of Frame::EMPTY",
    ),
];

const UNREACHABLE_JAVASCRIPT: &[(&str, &str)] = &[(
    "error_node",
    "reserved: javascript/parse.rs names it only as the group kind of a frame variant that never \
     closes a group and as the kind of Frame::EMPTY",
)];

const UNREACHABLE_MARKUP: &[(&str, &str)] = &[(
    "ErrorToken",
    "reserved: markup/lexer.rs pushes it only when step consumes no byte or the token table \
     truncates, and a source that lexes Complete does neither",
)];

const UNREACHABLE_ODIN: &[(&str, &str)] = &[
    (
        "block_comment",
        "reserved: odin/parse.rs carries no site that wraps a CommentBlock token in a node",
    ),
    (
        "comment",
        "reserved: odin/parse.rs carries no site that wraps a Comment token in a node",
    ),
    (
        "error_node",
        "reserved: odin/parse.rs names it only as the kind of Frame::EMPTY, which every frame \
         overwrites before it closes",
    ),
    (
        "escape_sequence",
        "reserved: a string lexes to one Text token and odin/parse.rs wraps nothing around its \
         escapes",
    ),
    (
        "field_identifier",
        "oracle-only: the tree-sitter-odin rule carries precedence -1, so a dotted name before a \
         brace always reduces to a member expression over a struct and the grammar itself never \
         opens the node",
    ),
    (
        "string_content",
        "reserved: a string lexes to one Text token, so the inner node odin/semantic.rs looks for \
         is never opened",
    ),
];

const UNREACHABLE_PYTHON: &[(&str, &str)] = &[(
    "StringFormat",
    "reserved: classify.rs routes every f-prefixed string through fstring::expand before \
     string_of can name it, and open_string names it only for a format string that carries no \
     quote byte, which a string token never is",
)];

const UNREACHABLE_RUST: &[(&str, &str)] = &[
    (
        "ErrorNode",
        "reserved: rust/parse.rs names it only as the group kind of a frame variant that never \
         closes a group and as the kind of Frame::EMPTY",
    ),
    (
        "ExprGroup",
        "reserved: the kind mirrors syn's ExprGroup, which stands for an invisible delimiter a \
         token stream carries and a source file cannot spell",
    ),
    (
        "TypeGroup",
        "reserved: the kind mirrors syn's TypeGroup, which stands for an invisible delimiter a \
         token stream carries and a source file cannot spell",
    ),
];

const UNREACHABLE_TYPESCRIPT: &[(&str, &str)] = &[(
    "error_node",
    "reserved: typescript/parse.rs names it only as the group kind of a frame variant that never \
     closes a group and as the kind of Frame::EMPTY",
)];

const UNREACHABLE_ZIG: &[(&str, &str)] = &[(
    "error_node",
    "reserved: zig/parse.rs names it only as the kind of Frame::EMPTY, which every frame \
     overwrites before it closes",
)];

type Build<K> = fn(&[u8], &[Token], &[K], &mut Events<K>, &mut Tree<K>) -> Structure;
type Classify<K> = fn(&[u8], &[Token], &mut Tokens, &mut BoundedVec<K>) -> bool;

struct Language<K: Kind> {
    broken: &'static [u8],
    build: Build<K>,
    classify: Classify<K>,
    error_token: K,
    extensions: &'static [&'static str],
    kind_count: u16,
    lexer: &'static dyn Lexer,
    name: &'static str,
    name_of: fn(K) -> &'static str,
    of_name: fn(&str) -> Option<K>,
    of_u16: fn(u16) -> Option<K>,
    to_u16: fn(K) -> u16,
    unreachable: &'static [(&'static str, &'static str)],
}

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

struct Seen {
    held: Vec<bool>,
}

impl Seen {
    fn reserve(kind_count: u16) -> Self {
        assert!(kind_count > 0, "a kind enum carries at least one kind");

        Self {
            held: vec![false; kind_count as usize],
        }
    }

    fn holds(&self, discriminant: u16) -> bool {
        assert!(
            (discriminant as usize) < self.held.len(),
            "{discriminant} names a kind"
        );

        self.held[discriminant as usize]
    }

    fn mark(&mut self, discriminant: u16) {
        assert!(
            (discriminant as usize) < self.held.len(),
            "{discriminant} names a kind"
        );

        self.held[discriminant as usize] = true;
    }

    fn unreached(&self) -> Vec<u16> {
        let mut found = Vec::new();

        for (index, held) in self.held.iter().enumerate() {
            if !held {
                found.push(u16::try_from(index).expect("a kind count fits in u16"));
            }
        }

        found
    }
}

fn css() -> Language<CSSKind> {
    Language {
        broken: BROKEN_CSS,
        build: css_parse::build,
        classify: css_classify,
        error_token: CSSKind::ErrorToken,
        extensions: &["css"],
        kind_count: CSS_KIND_COUNT,
        lexer: &CSS,
        name: "css",
        name_of: CSSKind::name,
        of_name: CSSKind::of_name,
        of_u16: CSSKind::of_u16,
        to_u16: CSSKind::to_u16,
        unreachable: UNREACHABLE_CSS,
    }
}

fn go() -> Language<GoKind> {
    Language {
        broken: BROKEN_GO,
        build: go_parse::build,
        classify: go_classify,
        error_token: GoKind::ErrorToken,
        extensions: &["go"],
        kind_count: GO_KIND_COUNT,
        lexer: &GO,
        name: "go",
        name_of: GoKind::name,
        of_name: GoKind::of_name,
        of_u16: GoKind::of_u16,
        to_u16: GoKind::to_u16,
        unreachable: UNREACHABLE_GO,
    }
}

fn javascript() -> Language<JavaScriptKind> {
    Language {
        broken: BROKEN_JAVASCRIPT,
        build: javascript_parse::build,
        classify: javascript_classify,
        error_token: JavaScriptKind::ErrorToken,
        extensions: &["cjs", "js", "jsx", "mjs"],
        kind_count: JAVASCRIPT_KIND_COUNT,
        lexer: &JAVASCRIPT,
        name: "javascript",
        name_of: JavaScriptKind::name,
        of_name: JavaScriptKind::of_name,
        of_u16: JavaScriptKind::of_u16,
        to_u16: JavaScriptKind::to_u16,
        unreachable: UNREACHABLE_JAVASCRIPT,
    }
}

fn odin() -> Language<OdinKind> {
    Language {
        broken: BROKEN_ODIN,
        build: odin_parse::build,
        classify: odin_classify,
        error_token: OdinKind::ErrorToken,
        extensions: &["odin"],
        kind_count: ODIN_KIND_COUNT,
        lexer: &ODIN,
        name: "odin",
        name_of: OdinKind::name,
        of_name: OdinKind::of_name,
        of_u16: OdinKind::of_u16,
        to_u16: OdinKind::to_u16,
        unreachable: UNREACHABLE_ODIN,
    }
}

fn python() -> Language<PythonKind> {
    Language {
        broken: BROKEN_PYTHON,
        build: python_parse::build,
        classify: python_classify,
        error_token: PythonKind::ErrorToken,
        extensions: &["py"],
        kind_count: PYTHON_KIND_COUNT,
        lexer: &PYTHON,
        name: "python",
        name_of: PythonKind::name,
        of_name: PythonKind::of_name,
        of_u16: PythonKind::of_u16,
        to_u16: PythonKind::to_u16,
        unreachable: UNREACHABLE_PYTHON,
    }
}

fn rust() -> Language<RustKind> {
    Language {
        broken: BROKEN_RUST,
        build: rust_parse::build,
        classify: rust_classify,
        error_token: RustKind::ErrorToken,
        extensions: &["rs"],
        kind_count: RUST_KIND_COUNT,
        lexer: &RUST,
        name: "rust",
        name_of: RustKind::name,
        of_name: RustKind::of_name,
        of_u16: RustKind::of_u16,
        to_u16: RustKind::to_u16,
        unreachable: UNREACHABLE_RUST,
    }
}

fn typescript_ts() -> Language<TypeScriptKind> {
    Language {
        broken: BROKEN_TYPESCRIPT,
        build: typescript_build_ts,
        classify: typescript_classify_ts,
        error_token: TypeScriptKind::ErrorToken,
        extensions: &["cts", "mts", "ts"],
        kind_count: TYPESCRIPT_KIND_COUNT,
        lexer: &TYPESCRIPT,
        name: "typescript",
        name_of: TypeScriptKind::name,
        of_name: TypeScriptKind::of_name,
        of_u16: TypeScriptKind::of_u16,
        to_u16: TypeScriptKind::to_u16,
        unreachable: UNREACHABLE_TYPESCRIPT,
    }
}

fn typescript_tsx() -> Language<TypeScriptKind> {
    Language {
        broken: BROKEN_TYPESCRIPT,
        build: typescript_build_tsx,
        classify: typescript_classify_tsx,
        error_token: TypeScriptKind::ErrorToken,
        extensions: &["tsx"],
        kind_count: TYPESCRIPT_KIND_COUNT,
        lexer: &TYPESCRIPT,
        name: "tsx",
        name_of: TypeScriptKind::name,
        of_name: TypeScriptKind::of_name,
        of_u16: TypeScriptKind::of_u16,
        to_u16: TypeScriptKind::to_u16,
        unreachable: UNREACHABLE_TYPESCRIPT,
    }
}

fn zig() -> Language<ZigKind> {
    Language {
        broken: BROKEN_ZIG,
        build: zig_parse::build,
        classify: zig_classify,
        error_token: ZigKind::ErrorToken,
        extensions: &["zig"],
        kind_count: ZIG_KIND_COUNT,
        lexer: &ZIG,
        name: "zig",
        name_of: ZigKind::name,
        of_name: ZigKind::of_name,
        of_u16: ZigKind::of_u16,
        to_u16: ZigKind::to_u16,
        unreachable: UNREACHABLE_ZIG,
    }
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

fn gather<K>(language: &Language<K>, seen: &mut Seen)
where
    K: Kind,
{
    let found = fixtures(language.extensions);

    assert!(!found.is_empty(), "{} carries no fixtures", language.name);

    let mut machine = Machine::<K>::reserve();

    for (label, source) in &found {
        run(language, &mut machine, source, label, seen);

        assert!(
            machine.tree.errors().is_empty(),
            "{}: {label} does not parse cleanly",
            language.name
        );
    }

    let label = format!("{}: the broken source", language.name);

    run(language, &mut machine, language.broken, &label, seen);
}

fn run<K>(
    language: &Language<K>,
    machine: &mut Machine<K>,
    source: &[u8],
    label: &str,
    seen: &mut Seen,
) where
    K: Kind,
{
    machine.lexed.clear();

    let lexed = language.lexer.lex(source, &mut machine.lexed);

    assert_eq!(lexed, Lex::Complete, "{label} outgrows the token table");

    assert!(
        (language.classify)(
            source,
            machine.lexed.as_slice(),
            &mut machine.tokens,
            &mut machine.raw
        ),
        "{label} outgrows the classified stream"
    );

    machine.tree.clear();

    let built = (language.build)(
        source,
        machine.tokens.as_slice(),
        &machine.raw,
        &mut machine.events,
        &mut machine.tree,
    );

    assert_eq!(built, Structure::Complete, "{label} does not build whole");

    for kind in machine.raw.iter() {
        seen.mark((language.to_u16)(*kind));
    }

    for node in machine.tree.as_slice() {
        seen.mark((language.to_u16)(node.kind));
    }
}

fn judge<K>(language: &Language<K>, seen: &Seen)
where
    K: Kind,
{
    for (name, reason) in language.unreachable {
        let kind = (language.of_name)(name)
            .unwrap_or_else(|| panic!("{name} is allow-listed and is not a kind"));

        assert!(
            !reason.is_empty(),
            "{name} is allow-listed and carries no reason"
        );

        assert!(
            !seen.holds((language.to_u16)(kind)),
            "{name} is allow-listed and reached: drop the entry"
        );
    }

    let unreached: Vec<u16> = seen
        .unreached()
        .into_iter()
        .filter(|discriminant| !allow_lists(language, *discriminant))
        .collect();

    assert!(unreached.is_empty(), "{}", report(language, &unreached));

    assert_eq!(
        seen.held.iter().filter(|held| **held).count() + language.unreachable.len(),
        language.kind_count as usize,
        "{}: the seen set and the allow-list do not cover the kind enum",
        language.name
    );
}

fn allow_lists<K>(language: &Language<K>, discriminant: u16) -> bool
where
    K: Kind,
{
    for (name, _) in language.unreachable {
        let kind = (language.of_name)(name)
            .unwrap_or_else(|| panic!("{name} is allow-listed and is not a kind"));

        if (language.to_u16)(kind) == discriminant {
            return true;
        }
    }

    false
}

fn report<K>(language: &Language<K>, unreached: &[u16]) -> String
where
    K: Kind,
{
    let mut found = format!(
        "{}: {} of {} kinds are reached by no fixture\n",
        language.name,
        unreached.len(),
        language.kind_count
    );

    for discriminant in unreached {
        let kind = (language.of_u16)(*discriminant)
            .unwrap_or_else(|| panic!("{discriminant} names a kind"));

        writeln!(found, "    {} ({discriminant})", (language.name_of)(kind))
            .expect("a string takes a line");
    }

    found
}

fn gather_markup(seen: &mut Seen) {
    let found = fixtures(&["html"]);

    assert!(!found.is_empty(), "markup carries no fixtures");

    let mut tokens = MarkupTokens::reserve(MARKUP_TOKEN_COUNT_MAX);
    let mut tree = MarkupTree::reserve(MARKUP_NODE_COUNT_MAX, ERROR_COUNT_MAX);

    for (label, source) in &found {
        run_markup(source, label, &mut tokens, &mut tree, seen);
    }

    run_markup(
        BROKEN_MARKUP,
        "markup: the broken source",
        &mut tokens,
        &mut tree,
        seen,
    );
}

fn run_markup(
    source: &[u8],
    label: &str,
    tokens: &mut MarkupTokens,
    tree: &mut MarkupTree,
    seen: &mut Seen,
) {
    tokens.clear();

    let lexed = markup::lex(source, tokens);

    assert_eq!(lexed, Lex::Complete, "{label} outgrows the token table");

    tree.clear();

    let built = markup_tree::build(source, tokens.as_slice(), tree);

    assert_eq!(built, Structure::Complete, "{label} does not build whole");

    for token in tokens.as_slice() {
        seen.mark(token.kind.to_u16());
    }

    for node in tree.as_slice() {
        seen.mark(node.kind.to_u16());
    }
}

fn judge_markup(seen: &Seen) {
    for (name, reason) in UNREACHABLE_MARKUP {
        let kind = MarkupKind::of_name(name)
            .unwrap_or_else(|| panic!("{name} is allow-listed and is not a kind"));

        assert!(
            !reason.is_empty(),
            "{name} is allow-listed and carries no reason"
        );

        assert!(
            !seen.holds(kind.to_u16()),
            "{name} is allow-listed and reached: drop the entry"
        );
    }

    let allowed: Vec<u16> = UNREACHABLE_MARKUP
        .iter()
        .map(|(name, _)| {
            MarkupKind::of_name(name)
                .unwrap_or_else(|| panic!("{name} is allow-listed and is not a kind"))
                .to_u16()
        })
        .collect();

    let unreached: Vec<u16> = seen
        .unreached()
        .into_iter()
        .filter(|discriminant| !allowed.contains(discriminant))
        .collect();

    let mut found = format!(
        "markup: {} of {MARKUP_KIND_COUNT} kinds are reached by no fixture\n",
        unreached.len()
    );

    for discriminant in &unreached {
        let kind = MarkupKind::of_u16(*discriminant)
            .unwrap_or_else(|| panic!("{discriminant} names a kind"));

        writeln!(found, "    {} ({discriminant})", kind.name()).expect("a string takes a line");
    }

    assert!(unreached.is_empty(), "{found}");

    assert_eq!(
        seen.held.iter().filter(|held| **held).count() + UNREACHABLE_MARKUP.len(),
        MARKUP_KIND_COUNT as usize,
        "markup: the seen set and the allow-list do not cover the kind enum"
    );
}

fn fixtures(extensions: &[&str]) -> Vec<(String, Vec<u8>)> {
    let root = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures");
    let mut found = Vec::new();

    collect(&root, extensions, &mut found);
    found.sort();

    found
}

fn collect(root: &Path, extensions: &[&str], found: &mut Vec<(String, Vec<u8>)>) {
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

        found.push((path.display().to_string(), source));
    }
}

#[test]
fn every_css_kind_is_reached_by_a_fixture() {
    let language = css();
    let mut seen = Seen::reserve(language.kind_count);

    gather(&language, &mut seen);
    judge(&language, &seen);
}

#[test]
fn every_go_kind_is_reached_by_a_fixture() {
    let language = go();
    let mut seen = Seen::reserve(language.kind_count);

    gather(&language, &mut seen);
    judge(&language, &seen);
}

#[test]
fn every_javascript_kind_is_reached_by_a_fixture() {
    let language = javascript();
    let mut seen = Seen::reserve(language.kind_count);

    gather(&language, &mut seen);
    judge(&language, &seen);
}

#[test]
fn every_markup_kind_is_reached_by_a_fixture() {
    let mut seen = Seen::reserve(MARKUP_KIND_COUNT);

    gather_markup(&mut seen);
    judge_markup(&seen);
}

#[test]
fn every_odin_kind_is_reached_by_a_fixture() {
    let language = odin();
    let mut seen = Seen::reserve(language.kind_count);

    gather(&language, &mut seen);
    judge(&language, &seen);
}

#[test]
fn every_python_kind_is_reached_by_a_fixture() {
    let language = python();
    let mut seen = Seen::reserve(language.kind_count);

    gather(&language, &mut seen);
    judge(&language, &seen);
}

#[test]
fn every_rust_kind_is_reached_by_a_fixture() {
    let language = rust();
    let mut seen = Seen::reserve(language.kind_count);

    gather(&language, &mut seen);
    judge(&language, &seen);
}

#[test]
fn every_typescript_kind_is_reached_by_a_fixture() {
    let ts = typescript_ts();
    let tsx = typescript_tsx();
    let mut seen = Seen::reserve(ts.kind_count);

    gather(&ts, &mut seen);
    gather(&tsx, &mut seen);
    judge(&ts, &seen);
}

#[test]
fn every_zig_kind_is_reached_by_a_fixture() {
    let language = zig();
    let mut seen = Seen::reserve(language.kind_count);

    gather(&language, &mut seen);
    judge(&language, &seen);
}

#[test]
fn a_broken_source_reaches_both_error_kinds() {
    let mut missing = Vec::new();

    broken(&css(), &mut missing);
    broken(&go(), &mut missing);
    broken(&javascript(), &mut missing);
    broken(&odin(), &mut missing);
    broken(&python(), &mut missing);
    broken(&rust(), &mut missing);
    broken(&typescript_ts(), &mut missing);
    broken(&typescript_tsx(), &mut missing);
    broken(&zig(), &mut missing);
    broken_markup(&mut missing);

    assert!(missing.is_empty(), "{}", missing.join("\n"));
}

fn broken<K>(language: &Language<K>, missing: &mut Vec<String>)
where
    K: Kind,
{
    let mut machine = Machine::<K>::reserve();
    let mut seen = Seen::reserve(language.kind_count);
    let label = format!("{}: the broken source", language.name);

    run(language, &mut machine, language.broken, &label, &mut seen);

    assert!(
        !machine.tree.errors().is_empty(),
        "{label} parses cleanly and proves no error kind"
    );

    for kind in [K::ERROR, language.error_token] {
        let discriminant = (language.to_u16)(kind);

        if seen.holds(discriminant) || allow_lists(language, discriminant) {
            continue;
        }

        missing.push(format!(
            "{label} does not reach {}",
            (language.name_of)(kind)
        ));
    }
}

fn broken_markup(missing: &mut Vec<String>) {
    let mut seen = Seen::reserve(MARKUP_KIND_COUNT);
    let mut tokens = MarkupTokens::reserve(MARKUP_TOKEN_COUNT_MAX);
    let mut tree = MarkupTree::reserve(MARKUP_NODE_COUNT_MAX, ERROR_COUNT_MAX);

    run_markup(
        BROKEN_MARKUP,
        "markup: the broken source",
        &mut tokens,
        &mut tree,
        &mut seen,
    );

    for kind in [MarkupKind::ErrorNode, MarkupKind::ErrorToken] {
        let allowed = UNREACHABLE_MARKUP
            .iter()
            .any(|(name, _)| *name == kind.name());

        if seen.holds(kind.to_u16()) || allowed {
            continue;
        }

        missing.push(format!(
            "markup: the broken source does not reach {}",
            kind.name()
        ));
    }
}

#[test]
fn the_seen_set_reports_in_discriminant_order() {
    let mut seen = Seen::reserve(5);

    seen.mark(1);
    seen.mark(3);

    assert_eq!(seen.unreached(), vec![0, 2, 4]);
}
