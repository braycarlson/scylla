use crate::bounded::{BoundedVec, Span, count_of};
use crate::graph::{self, Scratch};
use crate::project::store::{FileID, NONE, Store};

pub const DEPTH_MAX: u32 = 1 << 16;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Edge {
    pub fact: u32,
    pub from: FileID,
    pub resolved: bool,
    pub to: u32,
}

struct Ordering<'held> {
    cycles: &'held mut BoundedVec<FileID>,
    lengths: &'held mut BoundedVec<u32>,
    order: &'held mut BoundedVec<FileID>,
}

struct Resident<'held> {
    counts: &'held [u32],
    edges: &'held [Edge],
    starts: &'held [u32],
    store: &'held Store,
}

pub struct Graph {
    counts: BoundedVec<u32>,
    cycles: BoundedVec<FileID>,
    edges: BoundedVec<Edge>,
    file_count_max: u32,
    generations: BoundedVec<u32>,
    lengths: BoundedVec<u32>,
    moves: u64,
    order: BoundedVec<FileID>,
    scratch: Scratch,
    starts: BoundedVec<u32>,
}

impl Graph {
    pub fn reserve(edge_count_max: u32, file_count_max: u32) -> Self {
        assert!(edge_count_max > 0);
        assert!(file_count_max > 0);
        assert!(file_count_max <= DEPTH_MAX);

        assert!(!crate::allocation::is_frozen());

        let mut graph = Self {
            counts: BoundedVec::reserve(file_count_max),
            cycles: BoundedVec::reserve(file_count_max),
            generations: BoundedVec::reserve(file_count_max),
            edges: BoundedVec::reserve(edge_count_max),
            file_count_max,
            lengths: BoundedVec::reserve(file_count_max),
            moves: u64::MAX,
            order: BoundedVec::reserve(file_count_max),
            scratch: Scratch::reserve(file_count_max),
            starts: BoundedVec::reserve(file_count_max),
        };

        for _ in 0..file_count_max {
            graph.counts.push_assert(0);
            graph.generations.push_assert(NONE);
            graph.starts.push_assert(0);
        }

        assert_eq!(graph.counts.count(), file_count_max);
        assert_eq!(graph.starts.count(), file_count_max);

        graph
    }

    pub fn build(&mut self, store: &Store, resolve: fn(&[u8], FileID, &Store) -> u32) -> bool {
        self.clear();

        self.moves = store.moves();

        for file in store.files() {
            self.generations[file.index() as usize] = store.generation_of(file);

            if !self.edges_read(store, file, resolve) {
                self.clear();

                return false;
            }
        }

        if !self.order_read(store) {
            self.clear();

            return false;
        }

        assert!(self.order.count() <= self.file_count_max);

        true
    }

    pub fn clear(&mut self) {
        self.moves = u64::MAX;
        self.cycles.clear();
        self.edges.clear();
        self.lengths.clear();
        self.order.clear();

        for index in 0..self.file_count_max as usize {
            self.counts[index] = 0;
            self.generations[index] = NONE;
            self.starts[index] = 0;
        }

        assert_eq!(self.edges.count(), 0);
        assert_eq!(self.order.count(), 0);
    }

    pub fn count(&self) -> u32 {
        self.edges.count()
    }

    pub fn current(&self, store: &Store) -> bool {
        if self.moves == store.moves() {
            return true;
        }

        for index in 0..self.file_count_max {
            let held = self.generations[index as usize];

            if held == NONE {
                continue;
            }

            let file = FileID::of(index);

            if !store.resident(file) || store.generation_of(file) != held {
                return false;
            }
        }

        true
    }

    pub fn generation_of(&self, file: FileID) -> u32 {
        let index = file.index() as usize;

        assert!(index < self.file_count_max as usize);

        self.generations[index]
    }

    pub fn cycles(&self) -> impl Iterator<Item = &[FileID]> {
        let mut offset = 0_usize;

        self.lengths.iter().map(move |length| {
            let start = offset;
            let end = start + *length as usize;

            offset = end;

            &self.cycles[start..end]
        })
    }

    pub fn dependents_of(&self, file: FileID) -> impl Iterator<Item = FileID> {
        let target = file.index();

        self.edges
            .iter()
            .enumerate()
            .filter(move |(index, edge)| {
                if edge.to != target {
                    return false;
                }

                let start = self.starts[edge.from.index() as usize] as usize;

                !self.edges[start..*index]
                    .iter()
                    .any(|held| held.to == target && held.from == edge.from)
            })
            .map(|(_, edge)| edge.from)
    }

    pub fn edges_of(&self, file: FileID) -> &[Edge] {
        let index = file.index() as usize;

        assert!(index < self.file_count_max as usize);

        let start = self.starts[index] as usize;
        let end = start + self.counts[index] as usize;

        assert!(end <= self.edges.len());

        &self.edges[start..end]
    }

    pub fn order(&self) -> &[FileID] {
        &self.order
    }

    fn edges_read(
        &mut self,
        store: &Store,
        file: FileID,
        resolve: fn(&[u8], FileID, &Store) -> u32,
    ) -> bool {
        let index = file.index() as usize;
        let start = self.edges.count();
        let source = store.source_of(file);

        self.starts[index] = start;

        for (position, fact) in store.facts_of(file).iter().enumerate() {
            if fact.specifier == Span::EMPTY {
                continue;
            }

            let to = resolve(&source[fact.specifier.range()], file, store);

            let pushed = self.edges.push(Edge {
                fact: count_of(position),
                from: file,
                resolved: to != NONE,
                to,
            });

            if !pushed {
                return false;
            }
        }

        self.counts[index] = self.edges.count() - start;

        assert_eq!(self.starts[index] + self.counts[index], self.edges.count());

        true
    }

    fn order_read(&mut self, store: &Store) -> bool {
        let Self {
            counts,
            cycles,
            edges,
            file_count_max,
            lengths,
            order,
            scratch,
            starts,
            ..
        } = self;

        let resident = Resident {
            counts,
            edges,
            starts,
            store,
        };

        let mut ordering = Ordering {
            cycles,
            lengths,
            order,
        };

        graph::components(*file_count_max, scratch, &resident, &mut ordering)
    }
}

impl graph::Topology for Resident<'_> {
    fn edge_count_of(&self, node: u32) -> u32 {
        self.counts[node as usize]
    }

    fn edge_target_of(&self, node: u32, ordinal: u32) -> Option<u32> {
        let edge = self.edges[(self.starts[node as usize] + ordinal) as usize];

        if !edge.resolved {
            return None;
        }

        Some(edge.to)
    }

    fn holds(&self, node: u32) -> bool {
        self.store.resident(FileID::of(node))
    }
}

impl graph::Visitor for Ordering<'_> {
    fn component(&mut self, members: &[u32], looping: bool) -> bool {
        let first = self.order.count();

        for member in members.iter().rev() {
            if !self.order.push(FileID::of(*member)) {
                return false;
            }
        }

        self.order[first as usize..].sort_unstable();

        if !looping {
            return true;
        }

        for index in first..self.order.count() {
            if !self.cycles.push(self.order[index as usize]) {
                return false;
            }
        }

        self.lengths.push(count_of(members.len()))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::language::Language;
    use crate::project::store::{CLASS_COUNT, Eviction, Limits, hash_of};
    use crate::syntax::front;

    fn limits_of(file_count_max: u32) -> Limits {
        let mut slots = [[0_u32; CLASS_COUNT]; Language::COUNT];

        slots[Language::Python.index()][Limits::class_of(1_024) as usize] = file_count_max;

        Limits {
            file_count_max,
            front: front::Limits {
                binding_count_max: 128,
                error_count_max: 32,
                event_count_max: 2_048,
                export_count_max: 128,
                fact_count_max: 128,
                node_count_max: 1_024,
                reference_count_max: 128,
                scope_count_max: 32,
                segment_count_max: 128,
                token_count_max: 512,
            },
            line_count_max: 128,
            slots,
            source_bytes_max: 1_024,
        }
    }

    fn resolve(specifier: &[u8], _from: FileID, store: &Store) -> u32 {
        store.find(hash_of(specifier))
    }

    fn store_of(files: &[(&[u8], &[u8])]) -> Store {
        let limits = limits_of(count_of(files.len()));
        let mut store = Store::reserve(&limits, Eviction::Reject);

        for (name, source) in files {
            let index = store.insert(hash_of(name), Language::Python, source);

            assert!(index != NONE);
        }

        store
    }

    fn names_of(store: &Store, files: &[FileID]) -> Vec<Vec<u8>> {
        files
            .iter()
            .map(|held| store.source_of(*held).to_vec())
            .collect()
    }

    #[test]
    fn a_linear_chain_orders_dependencies_first() {
        let store = store_of(&[
            (b"a", b"import b\n"),
            (b"b", b"import c\n"),
            (b"c", b"x = 1\n"),
        ]);

        let mut graph = Graph::reserve(16, 3);

        assert!(graph.build(&store, resolve));
        assert_eq!(graph.count(), 2);

        assert_eq!(
            names_of(&store, graph.order()),
            vec![
                b"x = 1\n".to_vec(),
                b"import c\n".to_vec(),
                b"import b\n".to_vec()
            ]
        );

        assert_eq!(graph.cycles().count(), 0);
    }

    #[test]
    fn a_diamond_orders_the_shared_dependency_first() {
        let store = store_of(&[
            (b"a", b"import b\nimport c\n"),
            (b"b", b"import d\n"),
            (b"c", b"import d\n"),
            (b"d", b"x = 1\n"),
        ]);

        let mut graph = Graph::reserve(16, 4);

        assert!(graph.build(&store, resolve));
        assert_eq!(graph.count(), 4);

        let order = graph.order();
        let sources = names_of(&store, order);

        assert_eq!(order.len(), 4);
        assert_eq!(sources[0], b"x = 1\n".to_vec());
        assert_eq!(sources[3], b"import b\nimport c\n".to_vec());
        assert_eq!(graph.cycles().count(), 0);
        assert_eq!(graph.dependents_of(FileID::of(3)).count(), 2);
        assert_eq!(graph.dependents_of(FileID::of(0)).count(), 0);
    }

    #[test]
    fn a_two_file_cycle_is_one_component() {
        let store = store_of(&[(b"a", b"import b\n"), (b"b", b"import a\n")]);
        let mut graph = Graph::reserve(16, 2);

        assert!(graph.build(&store, resolve));

        let found: Vec<Vec<FileID>> = graph.cycles().map(<[FileID]>::to_vec).collect();

        assert_eq!(found.len(), 1);
        assert_eq!(found[0], vec![FileID::of(0), FileID::of(1)]);
        assert_eq!(graph.order().len(), 2);
    }

    #[test]
    fn a_self_import_is_a_cycle_of_one() {
        let store = store_of(&[(b"a", b"import a\n"), (b"b", b"x = 1\n")]);
        let mut graph = Graph::reserve(16, 2);

        assert!(graph.build(&store, resolve));

        let found: Vec<Vec<FileID>> = graph.cycles().map(<[FileID]>::to_vec).collect();

        assert_eq!(found.len(), 1);
        assert_eq!(found[0], vec![FileID::of(0)]);
    }

    #[test]
    fn an_unresolved_specifier_keeps_its_edge() {
        let store = store_of(&[(b"a", b"import missing\n")]);
        let mut graph = Graph::reserve(16, 1);

        assert!(graph.build(&store, resolve));

        let edges = graph.edges_of(FileID::of(0));

        assert_eq!(edges.len(), 1);
        assert!(!edges[0].resolved);
        assert_eq!(edges[0].to, NONE);
        assert_eq!(edges[0].from, FileID::of(0));
        assert_eq!(graph.order().len(), 1);
    }

    #[test]
    fn a_file_nobody_imports_still_reaches_the_order() {
        let store = store_of(&[
            (b"a", b"import b\n"),
            (b"b", b"x = 1\n"),
            (b"c", b"y = 2\n"),
        ]);

        let mut graph = Graph::reserve(16, 3);

        assert!(graph.build(&store, resolve));
        assert_eq!(graph.order().len(), 3);
        assert_eq!(graph.edges_of(FileID::of(2)).len(), 0);
        assert_eq!(graph.dependents_of(FileID::of(2)).count(), 0);
    }

    #[test]
    fn an_overflowing_edge_table_clears_the_graph() {
        let store = store_of(&[
            (b"a", b"import b\nimport c\n"),
            (b"b", b"x = 1\n"),
            (b"c", b"y = 2\n"),
        ]);

        let mut graph = Graph::reserve(1, 3);

        assert!(!graph.build(&store, resolve));
        assert_eq!(graph.count(), 0);
        assert_eq!(graph.order().len(), 0);
        assert_eq!(graph.cycles().count(), 0);
        assert_eq!(graph.edges_of(FileID::of(0)).len(), 0);
    }
}
