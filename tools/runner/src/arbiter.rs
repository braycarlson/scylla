use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::process::Command;

use crate::blob::blob_of;
use crate::oracle::Version;

const CACHE_COUNT_MAX: usize = 1 << 12;

const CONTEXT: [&str; 4] = [
    "Empty directory that contains no .odin files",
    "Path does not exist",
    "Unknown library collection",
    "Use of reserved package name",
];

pub trait Arbiter {
    fn accepts(&mut self, source: &[u8]) -> Option<bool>;
    fn identifier(&self) -> &'static str;
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Reading {
    Status,
    Syntax,
    Word,
}

pub struct Setup<'run> {
    pub arguments: &'run [&'run str],
    pub environment: &'run [(&'run str, &'run str)],
    pub extension: &'static str,
    pub identifier: &'static str,
    pub program: PathBuf,
    pub reading: Reading,
    pub version: Option<&'run Version<'run>>,
}

pub struct Program {
    arguments: Vec<String>,
    cache: HashMap<String, Option<bool>>,
    environment: Vec<(String, String)>,
    extension: &'static str,
    identifier: &'static str,
    program: PathBuf,
    reading: Reading,
    scratch: PathBuf,
}

impl Program {
    pub fn of(held: Setup<'_>) -> Result<Self, String> {
        if let Some(version) = held.version {
            version.enforce(held.identifier)?;
        }

        if !held.program.is_file() && held.program.components().count() > 1 {
            return Err(format!(
                "the {} arbiter is not built at {}",
                held.identifier,
                held.program.display()
            ));
        }

        let scratch = std::env::temp_dir().join(format!(
            "scylla-arbiter-{}-{}",
            held.identifier,
            std::process::id()
        ));

        Ok(Self {
            arguments: held
                .arguments
                .iter()
                .map(|held| (*held).to_owned())
                .collect(),
            cache: HashMap::new(),
            environment: held
                .environment
                .iter()
                .map(|(name, value)| ((*name).to_owned(), (*value).to_owned()))
                .collect(),
            extension: held.extension,
            identifier: held.identifier,
            program: held.program,
            reading: held.reading,
            scratch,
        })
    }

    fn run(&self, source: &[u8]) -> Option<bool> {
        let _ = std::fs::remove_dir_all(&self.scratch);

        std::fs::create_dir_all(&self.scratch).ok()?;

        let target = self.scratch.join(format!("input.{}", self.extension));

        std::fs::write(&target, source).ok()?;

        let outcome = Command::new(&self.program)
            .args(&self.arguments)
            .arg(&target)
            .envs(self.environment.iter().cloned())
            .current_dir(&self.scratch)
            .output()
            .ok()?;

        match self.reading {
            Reading::Status => Some(outcome.status.success()),
            Reading::Syntax => Some(!faulted(&outcome.stderr, &target)),
            Reading::Word => worded(&outcome.stdout),
        }
    }
}

impl Arbiter for Program {
    fn accepts(&mut self, source: &[u8]) -> Option<bool> {
        let blob = blob_of(source);

        if let Some(held) = self.cache.get(&blob) {
            return *held;
        }

        let held = self.run(source);

        if self.cache.len() >= CACHE_COUNT_MAX {
            self.cache.clear();
        }

        self.cache.insert(blob, held);

        held
    }

    fn identifier(&self) -> &'static str {
        self.identifier
    }
}

fn faulted(stderr: &[u8], target: &Path) -> bool {
    let text = String::from_utf8_lossy(stderr);
    let name = target.to_string_lossy();

    text.lines()
        .filter(|line| line.contains("Syntax Error") && line.contains(name.as_ref()))
        .any(|line| !CONTEXT.iter().any(|held| line.contains(held)))
}

fn worded(stdout: &[u8]) -> Option<bool> {
    let text = String::from_utf8_lossy(stdout);
    let first = text.split_whitespace().next()?;

    match first {
        "accepts" => Some(true),
        "rejects" => Some(false),
        _ => None,
    }
}
