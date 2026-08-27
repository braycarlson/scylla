#![allow(
    dead_code,
    reason = "each suite that includes this module reads the roots its oracle needs"
)]

use std::path::PathBuf;

const REQUIRED: &str = "SCYLLA_CORPUS_REQUIRED";

pub(crate) fn golden() -> Option<PathBuf> {
    named("SCYLLA_CORPUS_GOLDEN")
}

pub(crate) fn gotypes() -> Option<PathBuf> {
    named("SCYLLA_CORPUS_GOTYPES")
}

pub(crate) fn oxlint() -> Option<PathBuf> {
    named("SCYLLA_CORPUS_OXLINT")
}

pub(crate) fn required() -> bool {
    std::env::var_os(REQUIRED).is_some()
}

pub(crate) fn root() -> Option<PathBuf> {
    named("SCYLLA_CORPUS")
}

pub(crate) fn ruff() -> Option<PathBuf> {
    named("SCYLLA_CORPUS_RUFF")
}

fn named(variable: &str) -> Option<PathBuf> {
    let Some(value) = std::env::var_os(variable) else {
        assert!(
            !required(),
            "{REQUIRED} is set and {variable} is not: a green run would read no corpus"
        );

        return None;
    };

    let path = PathBuf::from(value);

    assert!(
        path.is_dir(),
        "{variable} names `{}`, which is not a directory",
        path.display()
    );

    Some(path)
}
