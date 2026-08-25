use std::fs;
use std::path::PathBuf;

use scylla::bounded::{BoundedVec, Buffer, Span};
use scylla::format::print::Options;
use scylla::format::typescript::{Formatter, Input, Outcome};
use scylla::language::Lexer as _;
use scylla::lex::TYPESCRIPT;
use scylla::syntax::typescript::classify::classify;
use scylla::syntax::typescript::dialect::Dialect;
use scylla::syntax::typescript::kind::TypeScriptKind;
use scylla::syntax::typescript::parse;
use scylla::token::Tokens;
use scylla::tree::{Events, Tree};

const ELEMENT_COUNT_MAX: u32 = 1 << 18;
const ERROR_COUNT_MAX: u32 = 1 << 12;
const EVENT_COUNT_MAX: u32 = 1 << 20;
const NODE_COUNT_MAX: u32 = 1 << 18;
const OUT_BYTES_MAX: u32 = 1 << 22;
const TOKEN_COUNT_MAX: u32 = 1 << 18;

struct Held {
    dialect: Dialect,
    events: Events<TypeScriptKind>,
    formatter: Formatter,
    lexed: Tokens,
    raw: BoundedVec<TypeScriptKind>,
    tokens: Tokens,
    tree: Tree<TypeScriptKind>,
}

impl Held {
    fn reserve() -> Self {
        Self {
            dialect: Dialect::Ts,
            events: Events::reserve(EVENT_COUNT_MAX),
            formatter: Formatter::reserve(ELEMENT_COUNT_MAX),
            lexed: Tokens::reserve(TOKEN_COUNT_MAX),
            raw: BoundedVec::reserve(TOKEN_COUNT_MAX),
            tokens: Tokens::reserve(TOKEN_COUNT_MAX),
            tree: Tree::reserve(NODE_COUNT_MAX, ERROR_COUNT_MAX),
        }
    }

    fn format(&mut self, source: &[u8], out: &mut Buffer) -> Outcome {
        self.lexed.clear();
        self.raw.clear();
        self.tokens.clear();

        TYPESCRIPT.lex(source, &mut self.lexed);

        if !classify(
            source,
            self.lexed.as_slice(),
            &mut self.tokens,
            &mut self.raw,
            self.dialect,
        ) {
            return Outcome::Overflow;
        }

        let outcome = parse::build(
            source,
            self.tokens.as_slice(),
            &self.raw,
            &mut self.events,
            &mut self.tree,
            self.dialect,
        );

        let input = Input {
            options: Options::DEFAULT,
            outcome,
            raw: &self.raw,
            source,
            tokens: self.tokens.as_slice(),
            tree: &self.tree,
        };

        self.formatter.format(&input, out)
    }

    fn range(&mut self, source: &[u8], lines: (u32, u32), out: &mut Buffer) -> Option<Span> {
        self.lexed.clear();
        self.raw.clear();
        self.tokens.clear();

        TYPESCRIPT.lex(source, &mut self.lexed);

        if !classify(
            source,
            self.lexed.as_slice(),
            &mut self.tokens,
            &mut self.raw,
            self.dialect,
        ) {
            return None;
        }

        let outcome = parse::build(
            source,
            self.tokens.as_slice(),
            &self.raw,
            &mut self.events,
            &mut self.tree,
            self.dialect,
        );

        let input = Input {
            options: Options::DEFAULT,
            outcome,
            raw: &self.raw,
            source,
            tokens: self.tokens.as_slice(),
            tree: &self.tree,
        };

        self.formatter.range(&input, lines, out)
    }

    fn kinds(&mut self, source: &[u8]) -> Vec<TypeScriptKind> {
        self.lexed.clear();
        self.raw.clear();
        self.tokens.clear();

        TYPESCRIPT.lex(source, &mut self.lexed);

        assert!(classify(
            source,
            self.lexed.as_slice(),
            &mut self.tokens,
            &mut self.raw,
            self.dialect
        ));

        self.raw
            .iter()
            .copied()
            .filter(|kind| !matches!(kind.name(), "Dedent" | "Indent" | "Newline"))
            .collect()
    }

    fn comments(&mut self, source: &[u8]) -> Vec<Vec<u8>> {
        self.lexed.clear();
        self.raw.clear();
        self.tokens.clear();

        TYPESCRIPT.lex(source, &mut self.lexed);

        assert!(classify(
            source,
            self.lexed.as_slice(),
            &mut self.tokens,
            &mut self.raw,
            self.dialect
        ));

        self.raw
            .iter()
            .enumerate()
            .filter(|(_, kind)| **kind == TypeScriptKind::Comment)
            .map(|(index, _)| {
                source[self.tokens.as_slice()[index].span().range()]
                    .trim_ascii_end()
                    .to_vec()
            })
            .collect()
    }
}

fn fixtures() -> Vec<(String, Vec<u8>)> {
    let root = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/typescript");
    let mut found = Vec::new();

    for entry in fs::read_dir(&root).expect("the fixture directory is readable") {
        let path = entry.expect("the entry is readable").path();

        let held = path
            .extension()
            .and_then(|extension| extension.to_str())
            .and_then(Dialect::of_extension);

        if held.is_none() {
            continue;
        }

        let name = path
            .file_name()
            .expect("the fixture has a name")
            .to_string_lossy()
            .into_owned();

        let source = fs::read(&path).expect("the fixture is readable");

        found.push((name, source));
    }

    found.sort_by(|left, right| left.0.cmp(&right.0));

    assert!(found.len() > 4);

    found
}

#[test]
fn formatting_formatted_output_changes_nothing() {
    let mut first = Buffer::reserve(OUT_BYTES_MAX);
    let mut held = Held::reserve();
    let mut second = Buffer::reserve(OUT_BYTES_MAX);

    for (name, source) in fixtures() {
        held.dialect = dialect_of(&name);

        if held.format(&source, &mut first) != Outcome::Complete {
            continue;
        }

        let once = first.as_bytes().to_vec();

        assert_eq!(held.format(&once, &mut second), Outcome::Complete, "{name}");

        assert_eq!(
            String::from_utf8_lossy(second.as_bytes()),
            String::from_utf8_lossy(&once),
            "{name} is not idempotent"
        );
    }
}

#[test]
fn formatting_keeps_every_token_it_was_given() {
    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    for (name, source) in fixtures() {
        held.dialect = dialect_of(&name);

        if held.format(&source, &mut out) != Outcome::Complete {
            continue;
        }

        let formatted = out.as_bytes().to_vec();
        let before = held.kinds(&source);
        let after = held.kinds(&formatted);

        assert_eq!(before, after, "{name} lost or gained a token");
    }
}

#[test]
fn formatting_keeps_every_comment_it_was_given() {
    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    for (name, source) in fixtures() {
        held.dialect = dialect_of(&name);

        if held.format(&source, &mut out) != Outcome::Complete {
            continue;
        }

        let formatted = out.as_bytes().to_vec();

        assert_eq!(
            held.comments(&source),
            held.comments(&formatted),
            "{name} lost a comment"
        );
    }
}

#[test]
fn a_dump_writes_the_formatted_fixtures() {
    let Ok(root) = std::env::var("SCYLLA_FORMAT_DUMP") else {
        return;
    };

    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    for (name, source) in fixtures() {
        held.dialect = dialect_of(&name);

        if held.format(&source, &mut out) != Outcome::Complete {
            continue;
        }

        fs::write(PathBuf::from(&root).join(name), out.as_bytes())
            .expect("the dump directory is writable");
    }
}

#[path = "common/oracle.rs"]
mod oracle;

const EVERY_CATEGORY: [&str; 4] = [
    "biome-line-breaking",
    "biome-literal-normalisation",
    "biome-template-literals",
    "jsx-refused",
];

#[test]
fn every_tsx_fixture_is_formatted_or_refused_by_its_own_row() {
    let carried = oracle::residue_of("residue-format-typescript.json", &EVERY_CATEGORY);
    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);
    let mut refused = 0;

    for (name, source) in fixtures() {
        held.dialect = dialect_of(&name);

        if !held.dialect.is_tsx() {
            continue;
        }

        let outcome = held.format(&source, &mut out);

        if outcome == Outcome::Complete {
            continue;
        }

        assert_eq!(outcome, Outcome::Refusal, "{name}");

        assert!(
            carried.contains(&name),
            "{name} is refused and no residue row names it"
        );

        refused += 1;
    }

    assert_eq!(refused, 6, "the tsx fixtures are not walked");
}

#[test]
fn the_formatted_output_matches_the_oracle_modulo_residue() {
    let carried = oracle::residue_of("residue-format-typescript.json", &EVERY_CATEGORY);
    let root =
        PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/golden-biome-typescript");
    let mut compared = 0;
    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    for (name, source) in fixtures() {
        held.dialect = dialect_of(&name);

        if carried.contains(&name) {
            continue;
        }

        assert_eq!(
            held.format(&source, &mut out),
            Outcome::Complete,
            "{name} is refused and no residue row names it"
        );

        let golden = fs::read(root.join(&name)).expect("the golden is dumped");

        assert_eq!(
            String::from_utf8_lossy(out.as_bytes()),
            String::from_utf8_lossy(&golden),
            "{name} diverges from biome and no residue row names it"
        );

        compared += 1;
    }

    assert!(compared > 0, "every fixture is residue");
}

#[test]
fn every_residue_row_names_a_fixture_that_diverges() {
    let carried = oracle::residue_of("residue-format-typescript.json", &EVERY_CATEGORY);
    let root =
        PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/golden-biome-typescript");
    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    for name in &carried {
        let source = fs::read(
            PathBuf::from(env!("CARGO_MANIFEST_DIR"))
                .join("tests/fixtures/typescript")
                .join(name),
        )
        .expect("the residue row names a fixture");

        held.dialect = dialect_of(name);

        if held.format(&source, &mut out) != Outcome::Complete {
            continue;
        }

        let golden = fs::read(root.join(name)).expect("the golden is dumped");

        assert_ne!(
            out.as_bytes(),
            golden.as_slice(),
            "{name} matches biome and needs no residue row"
        );
    }
}

#[test]
fn a_file_that_does_not_parse_is_refused() {
    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(b"function f( {\n", &mut out), Outcome::Refusal);
    assert!(out.is_empty());
}

#[test]
fn a_range_reads_back_the_lines_it_names() {
    let source: &[u8] = b"function f(): void {\nlet x=1;\n}\n";
    let mut held = Held::reserve();
    let mut whole = Buffer::reserve(OUT_BYTES_MAX);
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(source, &mut whole), Outcome::Complete);

    let formatted = whole.as_bytes().to_vec();

    let span = held
        .range(source, (1, 2), &mut out)
        .expect("the range is formatted");

    assert_eq!(out.as_bytes(), formatted);
    assert_eq!(&out.as_bytes()[span.range()], lines_of(&formatted, 1, 2));
}

#[test]
fn the_three_relations_hold_over_the_corpus() {
    let Ok(root) = std::env::var("SCYLLA_CORPUS") else {
        return;
    };

    let mut first = Buffer::reserve(OUT_BYTES_MAX);
    let mut held = Held::reserve();
    let mut pending = vec![PathBuf::from(root)];
    let mut second = Buffer::reserve(OUT_BYTES_MAX);

    while let Some(directory) = pending.pop() {
        let Ok(entries) = fs::read_dir(&directory) else {
            continue;
        };

        for entry in entries {
            let path = entry.expect("the entry is readable").path();

            if path.is_dir() {
                pending.push(path);

                continue;
            }

            if path.extension().is_none_or(|extension| extension != "ts") {
                continue;
            }

            let Ok(source) = fs::read(&path) else {
                continue;
            };

            if held.format(&source, &mut first) != Outcome::Complete {
                continue;
            }

            let once = first.as_bytes().to_vec();
            let before = held.kinds(&source);
            let after = held.kinds(&once);

            assert_eq!(before.len(), after.len(), "{} lost a token", path.display());
            assert_eq!(before, after, "{} lost a token", path.display());

            assert_eq!(
                String::from_utf8_lossy(&held.comments(&source).concat()),
                String::from_utf8_lossy(&held.comments(&once).concat()),
                "{} lost a comment",
                path.display()
            );

            assert_eq!(
                held.format(&once, &mut second),
                Outcome::Complete,
                "{}",
                path.display()
            );

            assert_eq!(
                String::from_utf8_lossy(second.as_bytes()),
                String::from_utf8_lossy(&once),
                "{} is not idempotent",
                path.display()
            );
        }
    }
}

fn lines_of(bytes: &[u8], first: u32, last: u32) -> &[u8] {
    let mut line = 0;
    let mut start = 0;
    let mut end = bytes.len();

    for (offset, byte) in bytes.iter().enumerate() {
        if *byte != b'\n' {
            continue;
        }

        line += 1;

        if line == first {
            start = offset + 1;
        }

        if line == last + 1 {
            end = offset + 1;

            break;
        }
    }

    &bytes[start..end]
}

fn dialect_of(name: &str) -> Dialect {
    let extension = name.rsplit('.').next().unwrap_or("ts");

    Dialect::of_extension(extension).expect("the fixture is TypeScript")
}
