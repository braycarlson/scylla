use std::fs;
use std::path::{Path, PathBuf};

use scylla::bounded::{Buffer, Bytes as _, count_of};
use scylla::language::Lexer;
use scylla::lex::{CSS, GO, JAVASCRIPT, ODIN, PYTHON, RUST, TYPESCRIPT, ZIG};
use scylla::token::{Lex, Token, Tokens};
use scylla::trivia;

const SOURCE_BYTES_MAX: u32 = 1 << 22;
const TOKEN_BUDGET_SMALL: u32 = 64;
const TOKEN_COUNT_MAX: u32 = 1 << 20;

struct Language {
    directories: &'static [&'static str],
    extensions: &'static [&'static [u8]],
    lexer: &'static dyn Lexer,
}

struct Fixture {
    name: String,
    source: Vec<u8>,
}

static LANGUAGES: [Language; 8] = [
    Language {
        directories: &["css"],
        extensions: &[b"css"],
        lexer: &CSS,
    },
    Language {
        directories: &["go"],
        extensions: &[b"go"],
        lexer: &GO,
    },
    Language {
        directories: &["javascript"],
        extensions: &[b"cjs", b"js", b"jsx", b"mjs"],
        lexer: &JAVASCRIPT,
    },
    Language {
        directories: &["odin"],
        extensions: &[b"odin"],
        lexer: &ODIN,
    },
    Language {
        directories: &["python"],
        extensions: &[b"py"],
        lexer: &PYTHON,
    },
    Language {
        directories: &["rust"],
        extensions: &[b"rs"],
        lexer: &RUST,
    },
    Language {
        directories: &["typescript"],
        extensions: &[b"cts", b"mts", b"ts", b"tsx"],
        lexer: &TYPESCRIPT,
    },
    Language {
        directories: &["zig"],
        extensions: &[b"zig"],
        lexer: &ZIG,
    },
];

#[test]
fn every_fixture_is_tiled_by_its_tokens_and_gaps() {
    let mut buffer = Buffer::reserve(SOURCE_BYTES_MAX);
    let mut tokens = Tokens::reserve(TOKEN_COUNT_MAX);
    let mut compared = 0;

    for language in &LANGUAGES {
        let found = fixtures(language);

        assert!(
            !found.is_empty(),
            "{} carries no fixtures",
            language.lexer.identifier()
        );

        for fixture in &found {
            tokens.clear();

            let outcome = language.lexer.lex(&fixture.source, &mut tokens);

            assert_eq!(
                outcome,
                Lex::Complete,
                "{}: {} truncates at {TOKEN_COUNT_MAX} tokens",
                language.lexer.identifier(),
                fixture.name
            );

            tiles(
                &fixture.source,
                tokens.as_slice(),
                outcome,
                &mut buffer,
                &format!("{}: {}", language.lexer.identifier(), fixture.name),
            );

            compared += 1;
        }
    }

    assert!(compared > 32, "the fixture tree lost its sources");
}

#[test]
fn every_corpus_file_is_tiled_by_its_tokens_and_gaps() {
    let Ok(root) = std::env::var("SCYLLA_CORPUS") else {
        return;
    };

    let held = PathBuf::from(root);
    let mut buffer = Buffer::reserve(SOURCE_BYTES_MAX);
    let mut tokens = Tokens::reserve(TOKEN_COUNT_MAX);
    let mut compared = 0;

    for language in &LANGUAGES {
        let mut found = Vec::new();

        collect(&held, &held, language.lexer.extensions(), &mut found);
        found.sort_by(|left, right| left.name.cmp(&right.name));

        for fixture in &found {
            if fixture.source.len() > SOURCE_BYTES_MAX as usize {
                continue;
            }

            tokens.clear();

            let outcome = language.lexer.lex(&fixture.source, &mut tokens);

            tiles(
                &fixture.source,
                tokens.as_slice(),
                outcome,
                &mut buffer,
                &format!("{}: {}", language.lexer.identifier(), fixture.name),
            );

            compared += 1;
        }
    }

    assert!(compared > 2_000, "SCYLLA_CORPUS lost its sources");
}

#[test]
fn a_truncated_lex_is_tiled_over_the_prefix_it_consumed() {
    let mut buffer = Buffer::reserve(SOURCE_BYTES_MAX);
    let mut tokens = Tokens::reserve(TOKEN_BUDGET_SMALL);
    let mut truncated = 0;

    for language in &LANGUAGES {
        for fixture in &fixtures(language) {
            tokens.clear();

            let outcome = language.lexer.lex(&fixture.source, &mut tokens);

            if outcome == Lex::Complete {
                continue;
            }

            let name = format!("{}: {}", language.lexer.identifier(), fixture.name);

            assert_eq!(
                tokens.as_slice().len(),
                TOKEN_BUDGET_SMALL as usize,
                "{name}: a truncated lex leaves its budget unspent"
            );

            tiles(
                &fixture.source,
                tokens.as_slice(),
                outcome,
                &mut buffer,
                &name,
            );

            truncated += 1;
        }
    }

    assert!(
        truncated > 0,
        "no fixture outgrows {TOKEN_BUDGET_SMALL} tokens"
    );
}

fn tiles(source: &[u8], tokens: &[Token], outcome: Lex, buffer: &mut Buffer, name: &str) {
    let count = count_of(tokens.len());
    let mut end_previous = 0;

    for (position, token) in tokens.iter().enumerate() {
        assert!(
            token.offset >= end_previous,
            "{name}: token {position} opens before token {} closes",
            position.saturating_sub(1)
        );

        assert!(
            token.end() as usize <= source.len(),
            "{name}: token {position} closes past the source"
        );

        end_previous = token.end();
    }

    let length = match outcome {
        Lex::Complete => count_of(source.len()),
        Lex::Truncated => end_previous,
    };

    assert!(length as usize <= source.len());

    buffer.clear();

    for gap in trivia::gaps(length, tokens) {
        assert!(
            buffer.push_bytes(&source[gap.span.range()]),
            "{name}: the gap before token {} outgrows the buffer",
            gap.token
        );

        if gap.token == count {
            continue;
        }

        let token = tokens[gap.token as usize];

        assert!(
            buffer.push_bytes(&source[token.span().range()]),
            "{name}: token {} outgrows the buffer",
            gap.token
        );
    }

    assert_eq!(
        buffer.as_bytes(),
        &source[..length as usize],
        "{name}: the tokens and gaps do not tile the source"
    );
}

fn fixtures(language: &Language) -> Vec<Fixture> {
    let mut found = Vec::new();

    for directory in language.directories {
        let root = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("tests/fixtures")
            .join(directory);

        assert!(root.is_dir(), "tests/fixtures/{directory} is missing");

        collect(&root, &root, language.extensions, &mut found);
    }

    found.sort_by(|left, right| left.name.cmp(&right.name));

    found
}

fn collect(root: &Path, base: &Path, extensions: &[&[u8]], found: &mut Vec<Fixture>) {
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

        if !extensions.contains(&extension.as_bytes()) {
            continue;
        }

        let Ok(source) = fs::read(&path) else {
            continue;
        };

        let name = path
            .strip_prefix(base)
            .unwrap_or(&path)
            .to_string_lossy()
            .replace('\\', "/");

        found.push(Fixture { name, source });
    }
}
