use crate::bounded::Span;
use crate::project::graph::Graph;
use crate::project::store::{FileID, NONE, Store};
use crate::project::view::Node;
use crate::syntax::{Fact, FactKind};

pub const CHAIN_MAX: u32 = 16;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Target {
    Binding(Node),
    Maybe,
    Missing,
    Unresolved,
}

pub fn target_of<'run>(
    store: &'run Store,
    graph: &Graph,
    file: FileID,
    name: &'run [u8],
) -> Target {
    assert!(!name.is_empty());

    let mut current = file;
    let mut wanted = name;
    let mut steps = 0;

    while steps <= CHAIN_MAX {
        let Some((index, fact)) = forward_of(store, current, wanted) else {
            return landing_of(store, current, wanted);
        };

        let edge = edge_of(graph, current, index);

        if edge == NONE {
            return Target::Unresolved;
        }

        wanted = renamed_of(store, current, fact, wanted);
        current = FileID::of(edge);
        steps += 1;
    }

    Target::Maybe
}

fn forward_of(store: &Store, file: FileID, name: &[u8]) -> Option<(u32, Fact)> {
    let source = store.source_of(file);

    for (index, fact) in store.facts_of(file).iter().enumerate() {
        if fact.specifier == Span::EMPTY {
            continue;
        }

        if fact.local == Span::EMPTY {
            continue;
        }

        if &source[fact.local.range()] != name {
            continue;
        }

        return Some((u32::try_from(index).expect("a fact row fits in u32"), *fact));
    }

    None
}

fn renamed_of<'run>(
    store: &'run Store,
    file: FileID,
    fact: Fact,
    wanted: &'run [u8],
) -> &'run [u8] {
    if fact.remote == Span::EMPTY {
        return wanted;
    }

    &store.source_of(file)[fact.remote.range()]
}

fn edge_of(graph: &Graph, file: FileID, fact: u32) -> u32 {
    for edge in graph.edges_of(file) {
        if edge.fact != fact {
            continue;
        }

        if !edge.resolved {
            return NONE;
        }

        return edge.to;
    }

    NONE
}

fn landing_of(store: &Store, file: FileID, name: &[u8]) -> Target {
    let node = store.declaration_of(file, name);

    if node != NONE {
        return Target::Binding(Node::new(file, node));
    }

    if stars(store, file) {
        return Target::Maybe;
    }

    Target::Missing
}

fn stars(store: &Store, file: FileID) -> bool {
    store.facts_of(file).iter().any(|fact| {
        matches!(fact.kind, FactKind::ExportAll | FactKind::ImportNamespace)
            && fact.local == Span::EMPTY
    })
}
