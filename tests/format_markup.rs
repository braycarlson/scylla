#[path = "common/corpus.rs"]
mod corpus;
#[path = "common/floor.rs"]
mod floor;

use std::fs;
use std::path::PathBuf;

use scylla::bounded::Buffer;
use scylla::format::markup::{Formatter, Input, Outcome};
use scylla::format::print::Options;
use scylla::lines;
use scylla::markup::blocks::{self, BlockMap, TagSpecification};
use scylla::markup::tree::{self, Tree};
use scylla::markup::{self, MarkupKind, Tokens};

const ELEMENT_COUNT_MAX: u32 = 1 << 18;
const ERROR_COUNT_MAX: u32 = 1 << 12;
const LINE_COUNT_MAX: u32 = 1 << 16;
const NODE_COUNT_MAX: u32 = 1 << 17;
const OUT_BYTES_MAX: u32 = 1 << 22;

const SPECIFICATIONS: &[TagSpecification] = &[
    TagSpecification {
        intermediates: &[b"empty"],
        name: b"for",
    },
    TagSpecification {
        intermediates: &[b"elif", b"else"],
        name: b"if",
    },
    TagSpecification {
        intermediates: &[b"else"],
        name: b"ifequal",
    },
    TagSpecification {
        intermediates: &[b"else"],
        name: b"ifnotequal",
    },
    TagSpecification {
        intermediates: &[b"plural"],
        name: b"blocktranslate",
    },
];

const TAG_COUNT_MAX: u32 = 1 << 14;
const TOKEN_COUNT_MAX: u32 = 1 << 18;
const WORDS: &[&[u8]] = &[b"elif", b"else", b"empty", b"plural"];

struct Held {
    formatter: Formatter,
    index: lines::Index,
    map: BlockMap,
    tokens: Tokens,
    tree: Tree,
}

impl Held {
    fn reserve() -> Self {
        Self {
            formatter: Formatter::reserve(ELEMENT_COUNT_MAX, LINE_COUNT_MAX, OUT_BYTES_MAX),
            index: lines::Index::reserve(LINE_COUNT_MAX),
            map: BlockMap::reserve(TAG_COUNT_MAX),
            tokens: Tokens::reserve(TOKEN_COUNT_MAX),
            tree: Tree::reserve(NODE_COUNT_MAX, ERROR_COUNT_MAX),
        }
    }

    fn format(&mut self, source: &[u8], out: &mut Buffer) -> Outcome {
        self.tokens.clear();

        if !self.index.build(source) {
            return Outcome::Overflow;
        }

        markup::lex(source, &mut self.tokens);
        tree::build(source, self.tokens.as_slice(), &mut self.tree);

        blocks::build(
            source,
            self.tokens.as_slice(),
            &self.tree,
            SPECIFICATIONS,
            WORDS,
            &mut self.map,
        );

        let input = Input {
            index: &self.index,
            map: &self.map,
            options: Options::DEFAULT,
            source,
            tokens: self.tokens.as_slice(),
            tree: &self.tree,
        };

        self.formatter.format(&input, out)
    }

    fn kinds(&mut self, source: &[u8]) -> Vec<(MarkupKind, Vec<u8>)> {
        self.tokens.clear();

        markup::lex(source, &mut self.tokens);

        self.tokens
            .as_slice()
            .iter()
            .filter(|token| token.kind != MarkupKind::Whitespace)
            .map(|token| {
                (
                    token.kind,
                    token
                        .text(source)
                        .iter()
                        .filter(|byte| !byte.is_ascii_whitespace())
                        .copied()
                        .collect::<Vec<u8>>(),
                )
            })
            .filter(|(kind, bytes)| *kind != MarkupKind::Text || !bytes.is_empty())
            .collect()
    }

    fn comments(&mut self, source: &[u8]) -> Vec<Vec<u8>> {
        self.tokens.clear();

        markup::lex(source, &mut self.tokens);

        self.tokens
            .as_slice()
            .iter()
            .filter(|token| {
                matches!(
                    token.kind,
                    MarkupKind::CommentText | MarkupKind::HTMLCommentOpen
                )
            })
            .map(|token| token.text(source).trim_ascii().to_vec())
            .collect()
    }
}

fn fixtures() -> Vec<(String, Vec<u8>)> {
    let root = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/templates");
    let mut found = Vec::new();
    let mut pending = vec![root.clone()];

    while let Some(directory) = pending.pop() {
        for entry in fs::read_dir(&directory).expect("the fixture directory is readable") {
            let path = entry.expect("the entry is readable").path();

            if path.is_dir() {
                pending.push(path);

                continue;
            }

            if path.extension().is_none_or(|extension| extension != "html") {
                continue;
            }

            let name = path
                .strip_prefix(&root)
                .expect("the fixture sits under the root")
                .to_string_lossy()
                .into_owned();

            let source = fs::read(&path).expect("the fixture is readable");

            found.push((name, source));
        }
    }

    found.sort_by(|left, right| left.0.cmp(&right.0));

    assert!(found.len() > 300);

    found
}

fn corpus_files() -> Vec<(String, Vec<u8>)> {
    let Some(root) = corpus::root() else {
        return Vec::new();
    };

    let mut found = Vec::new();
    let mut pending = vec![root.clone()];

    while let Some(directory) = pending.pop() {
        let Ok(entries) = fs::read_dir(&directory) else {
            continue;
        };

        for entry in entries.flatten() {
            let path = entry.path();
            let Ok(held) = fs::metadata(&path) else {
                continue;
            };

            if held.is_dir() {
                pending.push(path);

                continue;
            }

            if path.extension().is_none_or(|extension| extension != "html") {
                continue;
            }

            let Ok(source) = fs::read(&path) else {
                continue;
            };

            found.push((
                path.strip_prefix(&root)
                    .unwrap_or(&path)
                    .to_string_lossy()
                    .into_owned(),
                source,
            ));
        }
    }

    found.sort();

    found
}

#[test]
fn the_three_relations_hold_over_the_corpus() {
    let found = corpus_files();

    if found.is_empty() {
        return;
    }

    let mut first = Buffer::reserve(OUT_BYTES_MAX);
    let mut held = Held::reserve();
    let mut second = Buffer::reserve(OUT_BYTES_MAX);
    let mut compared = 0;

    for (name, source) in &found {
        if held.format(source, &mut first) != Outcome::Complete {
            continue;
        }

        let once = first.as_bytes().to_vec();

        assert_eq!(held.kinds(source), held.kinds(&once), "{name} lost a token");

        assert_eq!(
            held.comments(source),
            held.comments(&once),
            "{name} lost a comment"
        );

        assert_eq!(
            held.format(&once, &mut second),
            Outcome::Complete,
            "{name} refuses its own output"
        );

        assert_eq!(
            String::from_utf8_lossy(second.as_bytes()),
            String::from_utf8_lossy(&once),
            "{name} is not idempotent"
        );

        compared += 1;
    }

    assert!(
        compared >= floor::CORPUS_FORMAT_MARKUP,
        "{compared} corpus templates formatted, floor {}",
        floor::CORPUS_FORMAT_MARKUP
    );
}

#[test]
fn formatting_formatted_output_changes_nothing() {
    let mut first = Buffer::reserve(OUT_BYTES_MAX);
    let mut held = Held::reserve();
    let mut second = Buffer::reserve(OUT_BYTES_MAX);

    for (name, source) in fixtures() {
        if held.format(&source, &mut first) != Outcome::Complete {
            continue;
        }

        let once = first.as_bytes().to_vec();

        assert_eq!(
            held.format(&once, &mut second),
            Outcome::Complete,
            "{name} refuses its own output"
        );

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
        if held.format(&source, &mut out) != Outcome::Complete {
            continue;
        }

        let formatted = out.as_bytes().to_vec();
        let before = held.comments(&source);
        let after = held.comments(&formatted);

        assert_eq!(before, after, "{name} lost a comment");
    }
}

#[test]
fn a_file_that_does_not_parse_is_refused() {
    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    assert_eq!(held.format(b"<div>\n", &mut out), Outcome::Refusal);
    assert!(out.is_empty());
    assert_eq!(held.format(b"{{ a \n", &mut out), Outcome::Refusal);
    assert!(out.is_empty());
}

#[test]
fn a_range_reads_back_the_lines_it_names() {
    let source: &[u8] = b"<div>\n<p>a</p>\n</div>\n";
    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);

    held.tokens.clear();

    assert!(held.index.build(source));

    markup::lex(source, &mut held.tokens);
    tree::build(source, held.tokens.as_slice(), &mut held.tree);

    blocks::build(
        source,
        held.tokens.as_slice(),
        &held.tree,
        SPECIFICATIONS,
        WORDS,
        &mut held.map,
    );

    let input = Input {
        index: &held.index,
        map: &held.map,
        options: Options::DEFAULT,
        source,
        tokens: held.tokens.as_slice(),
        tree: &held.tree,
    };

    let span = held
        .formatter
        .range(&input, (1, 1), &mut out)
        .expect("the range is formatted");

    assert_eq!(out.as_bytes(), b"<div>\n    <p>a</p>\n</div>\n");
    assert_eq!(&out.as_bytes()[span.range()], b"    <p>a</p>\n");
}

#[test]
fn the_refusal_set_holds_its_count() {
    let mut held = Held::reserve();
    let mut out = Buffer::reserve(OUT_BYTES_MAX);
    let mut refused = 0;

    for (_, source) in fixtures() {
        if held.format(&source, &mut out) != Outcome::Refusal {
            continue;
        }

        refused += 1;
    }

    assert_eq!(refused, 24, "the refusal set moved");
}
