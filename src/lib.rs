#[cfg(test)]
mod frozen;

pub mod allocation;
pub mod arguments;
pub mod bounded;
pub mod brackets;
pub mod config;
pub mod diagnostic;
pub mod fix;
pub mod format;
#[cfg(feature = "fuzzing")]
pub mod fuzzing;
pub mod glob;
pub mod graph;
pub mod json;
pub mod language;
pub mod lex;
pub mod lines;
pub mod log;
pub mod markup;
pub mod mask;
pub mod outline;
pub mod parallel;
pub mod path;
pub mod pool;
pub mod project;
pub mod rule;
pub mod scan;
pub mod structure;
pub mod summary;
pub mod suppress;
pub mod syntax;
pub mod token;
pub mod toml;
pub mod transport;
pub mod tree;
pub mod trivia;
pub mod walk;
pub mod watch;

#[cfg(test)]
#[global_allocator]
static GUARD: allocation::GuardAllocator = allocation::GuardAllocator;
