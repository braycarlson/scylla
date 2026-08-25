#[cfg(test)]
mod frozen;

pub mod allocation;
pub mod bounded;
pub mod brackets;
pub mod diagnostic;
pub mod fix;
pub mod format;
#[cfg(feature = "fuzzing")]
pub mod fuzzing;
pub mod graph;
pub mod language;
pub mod lex;
pub mod lines;
pub mod log;
pub mod markup;
pub mod mask;
pub mod outline;
pub mod parallel;
pub mod pool;
pub mod project;
pub mod rule;
pub mod scan;
pub mod structure;
pub mod summary;
pub mod suppress;
pub mod syntax;
pub mod token;
pub mod tree;
pub mod trivia;

#[cfg(test)]
#[global_allocator]
static GUARD: allocation::GuardAllocator = allocation::GuardAllocator;
