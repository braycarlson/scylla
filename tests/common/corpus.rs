#![allow(
    dead_code,
    reason = "each suite that includes this module reads the roots its oracle needs"
)]

use std::path::PathBuf;

const REQUIRED: &str = "SCYLLA_CORPUS_REQUIRED";

pub(crate) fn css() -> Option<PathBuf> {
    named("SCYLLA_CORPUS_CSS")
}

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

pub(crate) fn stride() -> usize {
    std::env::var("SCYLLA_CORPUS_STRIDE")
        .ok()
        .and_then(|held| held.parse().ok())
        .filter(|held| *held > 0)
        .unwrap_or(1)
}

pub(crate) fn ruff() -> Option<PathBuf> {
    named("SCYLLA_CORPUS_RUFF")
}

pub(crate) fn tsscope() -> Option<PathBuf> {
    named("SCYLLA_CORPUS_TSSCOPE")
}

pub(crate) fn markup() -> Option<PathBuf> {
    named("SCYLLA_CORPUS_MARKUP")
}

pub(crate) fn ols() -> Option<PathBuf> {
    named("SCYLLA_CORPUS_OLS")
}

pub(crate) fn scip() -> Option<PathBuf> {
    named("SCYLLA_CORPUS_SCIP")
}

pub(crate) fn zls() -> Option<PathBuf> {
    named("SCYLLA_CORPUS_ZLS")
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
