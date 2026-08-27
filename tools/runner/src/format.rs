use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

use scylla::bounded::Buffer;
use scylla::format::print::Options;
use scylla::syntax::Structure;
use scylla::token::{Token, TokenKind, Tokens};
use scylla::tree::{Kind, Tree};

use crate::blob::blob_of;
use crate::oracle::Version;

const CACHE_COUNT_MAX: usize = 1 << 12;
const OUT_BYTES_MAX: u32 = 1 << 24;

pub struct Print<'run, K: Kind> {
    pub outcome: Structure,
    pub raw: &'run [K],
    pub source: &'run [u8],
    pub tokens: &'run [Token],
    pub tree: &'run Tree<K>,
}

pub trait Printer<K: Kind> {
    fn print(&mut self, held: &Print<'_, K>, out: &mut Buffer) -> bool;
}

pub trait Reference {
    fn identifier(&self) -> &'static str;
    fn print(&mut self, source: &[u8]) -> Option<Vec<u8>>;
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Shape {
    Stdout,
    InPlace,
    Stream,
}

pub struct Subprocess {
    arguments: Vec<String>,
    cache: HashMap<String, Option<Vec<u8>>>,
    extension: &'static str,
    identifier: &'static str,
    program: PathBuf,
    scratch: PathBuf,
    shape: Shape,
}

impl Subprocess {
    pub fn of(
        identifier: &'static str,
        program: PathBuf,
        arguments: &[&str],
        extension: &'static str,
        shape: Shape,
        version: &Version<'_>,
    ) -> Result<Self, String> {
        version.enforce(identifier)?;

        Ok(Self {
            arguments: arguments.iter().map(|held| (*held).to_owned()).collect(),
            cache: HashMap::new(),
            extension,
            identifier,
            program,
            scratch: std::env::temp_dir().join(format!("scylla-format-{identifier}")),
            shape,
        })
    }

    fn run(&self, source: &[u8]) -> Option<Vec<u8>> {
        if self.shape == Shape::Stream {
            return self.streamed(source);
        }

        let _ = std::fs::remove_dir_all(&self.scratch);

        std::fs::create_dir_all(&self.scratch).ok()?;

        let target = self.scratch.join(format!("input.{}", self.extension));

        std::fs::write(&target, source).ok()?;

        let outcome = Command::new(&self.program)
            .args(&self.arguments)
            .arg(&target)
            .output()
            .ok()?;

        if !outcome.status.success() {
            return None;
        }

        if self.shape == Shape::InPlace {
            return std::fs::read(&target).ok();
        }

        Some(outcome.stdout)
    }

    fn streamed(&self, source: &[u8]) -> Option<Vec<u8>> {
        use std::io::Write as _;

        let mut child = Command::new(&self.program)
            .args(&self.arguments)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .ok()?;

        child.stdin.take()?.write_all(source).ok()?;

        let outcome = child.wait_with_output().ok()?;

        if !outcome.status.success() {
            return None;
        }

        Some(outcome.stdout)
    }
}

impl Reference for Subprocess {
    fn identifier(&self) -> &'static str {
        self.identifier
    }

    fn print(&mut self, source: &[u8]) -> Option<Vec<u8>> {
        let blob = blob_of(source);

        if let Some(held) = self.cache.get(&blob) {
            return held.clone();
        }

        let printed = self.run(source);

        if self.cache.len() >= CACHE_COUNT_MAX {
            self.cache.clear();
        }

        self.cache.insert(blob, printed.clone());

        printed
    }
}

pub fn buffer() -> Buffer {
    Buffer::reserve(OUT_BYTES_MAX)
}

pub fn parting(ours: &[u8], theirs: &[u8]) -> (u32, String, String) {
    let mut offset = 0;

    while offset < ours.len() && offset < theirs.len() && ours[offset] == theirs[offset] {
        offset += 1;
    }

    let held = u32::try_from(offset).unwrap_or(u32::MAX);

    (held, window(ours, offset), window(theirs, offset))
}

fn window(held: &[u8], offset: usize) -> String {
    let start = offset.saturating_sub(12);
    let end = (offset + 12).min(held.len());

    if start >= end {
        return String::new();
    }

    let mut out = String::new();
    let mut blank = false;

    for byte in &held[start..end] {
        if byte.is_ascii_whitespace() {
            blank = true;

            continue;
        }

        if blank && !out.is_empty() {
            out.push(' ');
        }

        blank = false;
        out.push(char::from(*byte));
    }

    out
}

pub fn words(
    lexer: &'static dyn scylla::language::Lexer,
    source: &[u8],
    regroups: bool,
) -> Vec<String> {
    let mut held = Tokens::reserve(1 << 21);

    lexer.lex(source, &mut held);

    let held: Vec<String> = held
        .as_slice()
        .iter()
        .filter(|token| {
            !matches!(
                token.kind,
                TokenKind::BlockEnd
                    | TokenKind::BlockStart
                    | TokenKind::Comment
                    | TokenKind::Newline
            ) && token.length > 0
        })
        .map(|token| {
            if token.kind == TokenKind::String {
                return "<string>".to_owned();
            }

            String::from_utf8_lossy(token.text(source)).into_owned()
        })
        .collect::<Vec<String>>();

    if regroups {
        return ungrouped(held);
    }

    held
}

fn ungrouped(held: Vec<String>) -> Vec<String> {
    let mut found = Vec::with_capacity(held.len());

    for (index, word) in held.iter().enumerate() {
        let trailing = word == ","
            && held
                .get(index + 1)
                .is_some_and(|next| matches!(next.as_str(), ")" | "]" | "}"));

        if trailing || word == "(" || word == ")" {
            continue;
        }

        found.push(word.clone());
    }

    found
}

pub fn options_of(tabs: bool, indent_width: u32) -> Options {
    Options {
        indent_width,
        tabs,
        ..Options::DEFAULT
    }
}

pub fn program_of(named: &str, fallback: &Path) -> PathBuf {
    std::env::var_os(named).map_or_else(|| fallback.to_path_buf(), PathBuf::from)
}

#[cfg(test)]
mod tests {
    use super::{parting, words};

    #[test]
    fn two_printings_part_at_the_first_byte_that_differs() {
        let (offset, ours, theirs) = parting(b"var named[] string\n", b"var named []string\n");

        assert_eq!(offset, 9);
        assert_eq!(ours, "var named[] string");
        assert_eq!(theirs, "var named []string");
    }

    #[test]
    fn two_identical_printings_part_at_the_end() {
        let (offset, ours, theirs) = parting(b"held\n", b"held\n");

        assert_eq!(offset, 5);
        assert_eq!(ours, theirs);
    }

    #[test]
    fn a_split_word_reads_as_two() {
        let held = words(
            &scylla::lex::ZIG,
            b"var typed: anyframe->u32 = undefined;\n",
            false,
        );
        let split = words(
            &scylla::lex::ZIG,
            b"var typed: anyframe - > u32 = undefined;\n",
            false,
        );

        assert_ne!(held, split);
        assert!(held.contains(&"->".to_owned()));
        assert!(split.contains(&"-".to_owned()));
    }

    #[test]
    fn a_string_reads_as_a_string_whatever_its_bytes() {
        let single = words(&scylla::lex::PYTHON, b"held = 'one'\n", false);
        let double = words(&scylla::lex::PYTHON, b"held = \"one\"\n", false);

        assert_eq!(single, double);
        assert!(single.contains(&"<string>".to_owned()));
    }

    #[test]
    fn a_regrouping_formatter_drops_the_parentheses_from_the_comparison() {
        let bare = words(&scylla::lex::PYTHON, b"held = one + two\n", true);
        let grouped = words(&scylla::lex::PYTHON, b"held = (one + two)\n", true);

        assert_eq!(bare, grouped);
        assert_ne!(
            words(&scylla::lex::PYTHON, b"held = one + two\n", false),
            words(&scylla::lex::PYTHON, b"held = (one + two)\n", false)
        );
    }
}
