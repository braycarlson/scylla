#[path = "common/floor.rs"]
mod floor;

use std::path::{Path, PathBuf};

const ERROR_COUNT_MAX: u32 = 1 << 10;
const EVENT_COUNT_MAX: u32 = 1 << 19;
const NODE_COUNT_MAX: u32 = 1 << 16;
const TOKEN_COUNT_MAX: u32 = 1 << 16;

struct Fixture {
    name: String,
    source: Vec<u8>,
}

fn fixtures(directory: &str, extension: &str) -> Vec<Fixture> {
    let root = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("tests/fixtures")
        .join(directory);

    let mut found = Vec::new();

    collect(&root, extension, &mut found);
    found.sort();

    assert!(!found.is_empty(), "no fixtures under {}", root.display());

    found
        .into_iter()
        .map(|path| Fixture {
            name: path
                .strip_prefix(&root)
                .expect("a collected fixture sits under its own directory")
                .to_string_lossy()
                .replace('\\', "/"),

            source: std::fs::read(&path).expect("a collected fixture is readable"),
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

                continue;
            }

            if path.extension().is_some_and(|held| held == extension) {
                out.push(path);
            }
        }
    }
}

mod dialect {
    use scylla::bounded::BoundedVec;
    use scylla::syntax::Structure;
    use scylla::syntax::typescript::classify::classify;
    use scylla::syntax::typescript::dialect::Dialect;
    use scylla::syntax::typescript::kind::TypeScriptKind;
    use scylla::syntax::typescript::parse;
    use scylla::token::{Token, Tokens};
    use scylla::tree::{Events, Tree};

    #[must_use]
    pub(crate) fn classify_ts(
        source: &[u8],
        tokens: &[Token],
        out: &mut Tokens,
        raw: &mut BoundedVec<TypeScriptKind>,
    ) -> bool {
        classify(source, tokens, out, raw, Dialect::Ts)
    }

    #[must_use]
    pub(crate) fn classify_tsx(
        source: &[u8],
        tokens: &[Token],
        out: &mut Tokens,
        raw: &mut BoundedVec<TypeScriptKind>,
    ) -> bool {
        classify(source, tokens, out, raw, Dialect::Tsx)
    }

    pub(crate) fn build_ts(
        source: &[u8],
        tokens: &[Token],
        raw: &[TypeScriptKind],
        events: &mut Events<TypeScriptKind>,
        tree: &mut Tree<TypeScriptKind>,
    ) -> Structure {
        parse::build(source, tokens, raw, events, tree, Dialect::Ts)
    }

    pub(crate) fn build_tsx(
        source: &[u8],
        tokens: &[Token],
        raw: &[TypeScriptKind],
        events: &mut Events<TypeScriptKind>,
        tree: &mut Tree<TypeScriptKind>,
    ) -> Structure {
        parse::build(source, tokens, raw, events, tree, Dialect::Tsx)
    }
}

fn windows(source: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(source.len() * 2);

    for byte in source {
        if *byte == b'\n' {
            out.push(b'\r');
        }

        out.push(*byte);
    }

    out
}

macro_rules! relations {
    (
        $module:ident,
        $lexer:path,
        $classify:path,
        $parse:path,
        $kind:ty,
        $directory:literal,
        $extension:literal,
        $note:literal,
        $carriage_returns_read_differently:expr,
        $floor:ident
    ) => {
        mod $module {
            use super::{ERROR_COUNT_MAX, EVENT_COUNT_MAX, NODE_COUNT_MAX, TOKEN_COUNT_MAX};
            use super::{fixtures, floor, windows};

            use scylla::bounded::BoundedVec;
            use scylla::language::Lexer as _;
            use scylla::syntax::Category;
            use scylla::token::Tokens;
            use scylla::tree::{Events, Index, Tree};

            struct Walk {
                kinds: Vec<&'static str>,
                spans: Vec<(u32, u32)>,
                tokens: usize,
            }

            fn walk(source: &[u8]) -> Walk {
                let mut lexed = Tokens::reserve(TOKEN_COUNT_MAX);
                let mut tokens = Tokens::reserve(TOKEN_COUNT_MAX);
                let mut raw = BoundedVec::<$kind>::reserve(TOKEN_COUNT_MAX);
                let mut events = Events::reserve(EVENT_COUNT_MAX);
                let mut tree = Tree::<$kind>::reserve(NODE_COUNT_MAX, ERROR_COUNT_MAX);

                $lexer.lex(source, &mut lexed);

                assert!($classify(source, lexed.as_slice(), &mut tokens, &mut raw));

                $parse(source, tokens.as_slice(), &raw, &mut events, &mut tree);

                let held = tokens.as_slice();

                Walk {
                    kinds: tree
                        .as_slice()
                        .iter()
                        .map(|node| node.kind.name())
                        .collect(),
                    spans: tree
                        .as_slice()
                        .iter()
                        .map(|node| {
                            let span = node.span(held);

                            (span.offset, span.length)
                        })
                        .collect(),
                    tokens: held.len(),
                }
            }

            #[test]
            fn a_comment_at_the_head_shifts_the_spans_and_adds_no_node() {
                let width = u32::try_from($note.len()).expect("the note is short");
                let mut compared = 0;

                for fixture in &fixtures($directory, $extension) {
                    let plain = walk(&fixture.source);
                    let mut noted = Vec::with_capacity(fixture.source.len() + $note.len());

                    noted.extend_from_slice($note);
                    noted.extend_from_slice(&fixture.source);

                    let carried = walk(&noted);

                    assert_eq!(
                        plain.kinds,
                        carried.kinds,
                        "{}: the note changed the node kinds",
                        fixture.name
                    );

                    assert!(
                        carried.tokens <= plain.tokens + 2,
                        "{}: the note added {} tokens",
                        fixture.name,
                        carried.tokens - plain.tokens
                    );

                    for (index, (before, after)) in plain
                        .spans
                        .iter()
                        .zip(carried.spans.iter())
                        .enumerate()
                        .skip(1)
                    {
                        assert_eq!(
                            (before.0 + width, before.1),
                            *after,
                            "{}: node {index} did not shift behind the note",
                            fixture.name
                        );
                    }

                    compared += 1;
                }

                assert!(
                    compared >= floor::$floor.every,
                    "the fixtures went uncompared: {compared} compared, floor {}",
                    floor::$floor.every
                );
            }

            #[test]
            fn a_category_bucket_holds_ascending_positions_in_bounds() {
                let mut compared = 0;

                for fixture in &fixtures($directory, $extension) {
                    let mut lexed = Tokens::reserve(TOKEN_COUNT_MAX);
                    let mut tokens = Tokens::reserve(TOKEN_COUNT_MAX);
                    let mut raw = BoundedVec::<$kind>::reserve(TOKEN_COUNT_MAX);
                    let mut events = Events::reserve(EVENT_COUNT_MAX);
                    let mut tree = Tree::<$kind>::reserve(NODE_COUNT_MAX, ERROR_COUNT_MAX);
                    let mut index = Index::<$kind>::reserve(NODE_COUNT_MAX);

                    $lexer.lex(&fixture.source, &mut lexed);

                    assert!($classify(
                        &fixture.source,
                        lexed.as_slice(),
                        &mut tokens,
                        &mut raw
                    ));

                    $parse(
                        &fixture.source,
                        tokens.as_slice(),
                        &raw,
                        &mut events,
                        &mut tree,
                    );

                    index.build(&tree);

                    assert_eq!(
                        index.count(),
                        tree.count(),
                        "{}: the index lost a node",
                        fixture.name
                    );

                    let mut held = 0;

                    for category in Category::all() {
                        let bucket = index.of(*category);
                        let mut previous = None;

                        for position in bucket {
                            assert!(
                                *position < tree.count(),
                                "{}: {} sits past the tree",
                                fixture.name,
                                position
                            );

                            assert_eq!(
                                tree.at(*position).kind.category(),
                                *category,
                                "{}: node {} sits in the wrong bucket",
                                fixture.name,
                                position
                            );

                            assert!(
                                previous.is_none_or(|last| last < *position),
                                "{}: the {} bucket runs backwards",
                                fixture.name,
                                category.name()
                            );

                            previous = Some(*position);
                        }

                        held += bucket.len();
                    }

                    assert_eq!(
                        held,
                        tree.count() as usize,
                        "{}: the buckets do not cover the tree",
                        fixture.name
                    );

                    compared += 1;
                }

                assert!(
                    compared >= floor::$floor.every,
                    "the fixtures went uncompared: {compared} compared, floor {}",
                    floor::$floor.every
                );
            }

            #[test]
            fn windows_line_endings_change_no_node_kind() {
                let mut compared = 0;
                let skipped: &[&str] = $carriage_returns_read_differently;

                for fixture in &fixtures($directory, $extension) {
                    if fixture.source.contains(&b'\r') || skipped.contains(&fixture.name.as_str()) {
                        continue;
                    }

                    let plain = walk(&fixture.source);
                    let carried = walk(&windows(&fixture.source));

                    assert_eq!(
                        plain.kinds,
                        carried.kinds,
                        "{}: the carriage returns changed the node kinds",
                        fixture.name
                    );

                    compared += 1;
                }

                assert!(
                    compared >= floor::$floor.window,
                    "the fixtures went uncompared: {compared} compared, floor {}",
                    floor::$floor.window
                );
            }
        }
    };
}

relations!(
    css,
    scylla::lex::CSS,
    scylla::syntax::css::classify::classify,
    scylla::syntax::css::parse::build,
    scylla::syntax::css::kind::CSSKind,
    "css",
    "css",
    b"/* relation */\n",
    &[],
    RELATION_CSS
);

relations!(
    go,
    scylla::lex::GO,
    scylla::syntax::go::classify::classify,
    scylla::syntax::go::parse::build,
    scylla::syntax::go::kind::GoKind,
    "go",
    "go",
    b"// relation\n",
    &[],
    RELATION_GO
);

relations!(
    javascript,
    scylla::lex::JAVASCRIPT,
    scylla::syntax::javascript::classify::classify,
    scylla::syntax::javascript::parse::build,
    scylla::syntax::javascript::kind::JavaScriptKind,
    "javascript",
    "js",
    b"// relation\n",
    &["jsx_text.js"],
    RELATION_JAVASCRIPT
);

relations!(
    odin,
    scylla::lex::ODIN,
    scylla::syntax::odin::classify::classify,
    scylla::syntax::odin::parse::build,
    scylla::syntax::odin::kind::OdinKind,
    "odin",
    "odin",
    b"// relation\n",
    &[],
    RELATION_ODIN
);

relations!(
    python,
    scylla::lex::PYTHON,
    scylla::syntax::python::classify::classify,
    scylla::syntax::python::parse::build,
    scylla::syntax::python::kind::PythonKind,
    "python",
    "py",
    b"# relation\n",
    &[],
    RELATION_PYTHON
);

relations!(
    rust,
    scylla::lex::RUST,
    scylla::syntax::rust::classify::classify,
    scylla::syntax::rust::parse::build,
    scylla::syntax::rust::kind::RustKind,
    "rust",
    "rs",
    b"// relation\n",
    &[],
    RELATION_RUST
);

relations!(
    typescript,
    scylla::lex::TYPESCRIPT,
    crate::dialect::classify_ts,
    crate::dialect::build_ts,
    scylla::syntax::typescript::kind::TypeScriptKind,
    "typescript",
    "ts",
    b"// relation\n",
    &[],
    RELATION_TYPESCRIPT
);

relations!(
    zig,
    scylla::lex::ZIG,
    scylla::syntax::zig::classify::classify,
    scylla::syntax::zig::parse::build,
    scylla::syntax::zig::kind::ZigKind,
    "zig",
    "zig",
    b"// relation\n",
    &[],
    RELATION_ZIG
);

relations!(
    tsx,
    scylla::lex::TYPESCRIPT,
    crate::dialect::classify_tsx,
    crate::dialect::build_tsx,
    scylla::syntax::typescript::kind::TypeScriptKind,
    "typescript",
    "tsx",
    b"// relation\n",
    &["tsx_text.tsx"],
    RELATION_TSX
);
