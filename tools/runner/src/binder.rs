use scylla::token::Token;
use scylla::tree::{Kind, Tree};

use crate::analyzer::Bound;

pub trait Binder<K: Kind> {
    fn bind(&mut self, source: &[u8], tokens: &[Token], raw: &[K], tree: &Tree<K>) -> Bound;
}

pub struct Python {
    tables: scylla::syntax::python::bind::Tables,
}

impl Python {
    pub fn reserve() -> Self {
        Self {
            tables: scylla::syntax::python::bind::Tables::reserve(
                SCOPE_COUNT_MAX,
                BINDING_COUNT_MAX,
                REFERENCE_COUNT_MAX,
                SEGMENT_COUNT_MAX,
            ),
        }
    }
}

const BINDING_COUNT_MAX: u32 = 1 << 18;
const REFERENCE_COUNT_MAX: u32 = 1 << 18;
const SCOPE_COUNT_MAX: u32 = 1 << 16;
const SEGMENT_COUNT_MAX: u32 = 1 << 16;

impl Binder<scylla::syntax::python::kind::PythonKind> for Python {
    fn bind(
        &mut self,
        source: &[u8],
        tokens: &[Token],
        raw: &[scylla::syntax::python::kind::PythonKind],
        tree: &Tree<scylla::syntax::python::kind::PythonKind>,
    ) -> Bound {
        use scylla::syntax::python::bind::{bind, Limit, Outcome};

        let held = bind(source, tokens, raw, tree, &mut self.tables);

        Bound {
            complete: held == Outcome::Complete,
            limit: match held {
                Outcome::Complete => "none",
                Outcome::Full(Limit::Bindings) => "bindings",
                Outcome::Full(Limit::Imports) => "imports",
                Outcome::Full(Limit::Jobs) => "jobs",
                Outcome::Full(Limit::References) => "references",
                Outcome::Full(Limit::Scopes) => "scopes",
                Outcome::Full(Limit::Segments) => "segments",
            },
        }
    }
}
