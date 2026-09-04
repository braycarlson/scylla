use crate::bounded::BoundedVec;

const NOT_VISITED: u32 = u32::MAX;

pub trait Topology {
    fn edge_count_of(&self, node: u32) -> u32;

    fn edge_target_of(&self, node: u32, ordinal: u32) -> Option<u32>;

    fn holds(&self, node: u32) -> bool;
}

pub trait Visitor {
    fn component(&mut self, members: &[u32], looping: bool) -> bool;
}

#[derive(Debug)]
pub struct Scratch {
    index: BoundedVec<u32>,
    low: BoundedVec<u32>,
    order: BoundedVec<u32>,
    pending: BoundedVec<u32>,
    resident: BoundedVec<bool>,
    stack: BoundedVec<u32>,
}

impl Scratch {
    pub fn reserve(node_count_max: u32) -> Self {
        assert!(node_count_max > 0);
        assert!(!crate::allocation::is_frozen());

        Self {
            index: BoundedVec::reserve(node_count_max),
            low: BoundedVec::reserve(node_count_max),
            order: BoundedVec::reserve(node_count_max),
            pending: BoundedVec::reserve(node_count_max),
            resident: BoundedVec::reserve(node_count_max),
            stack: BoundedVec::reserve(node_count_max),
        }
    }

    pub fn capacity(&self) -> u32 {
        self.index.capacity()
    }

    fn enter(&mut self, node: u32, counter: &mut u32) {
        assert_eq!(self.index[node as usize], NOT_VISITED);

        self.index[node as usize] = *counter;
        self.low[node as usize] = *counter;
        self.order[node as usize] = 0;
        self.resident[node as usize] = true;
        *counter += 1;

        self.pending.push_assert(node);
        self.stack.push_assert(node);
    }

    fn reset(&mut self, count: u32) {
        assert!(count <= self.capacity());

        self.index.clear();
        self.low.clear();
        self.order.clear();
        self.pending.clear();
        self.resident.clear();
        self.stack.clear();

        for _ in 0..count {
            self.index.push_assert(NOT_VISITED);
            self.low.push_assert(0);
            self.order.push_assert(0);
            self.resident.push_assert(false);
        }

        assert_eq!(self.index.count(), count);
    }
}

pub fn components<T, V>(
    node_count: u32,
    scratch: &mut Scratch,
    topology: &T,
    visitor: &mut V,
) -> bool
where
    T: Topology + ?Sized,
    V: Visitor + ?Sized,
{
    scratch.reset(node_count);

    let mut counter = 0;

    for root in 0..node_count {
        if scratch.index[root as usize] != NOT_VISITED || !topology.holds(root) {
            continue;
        }

        scratch.enter(root, &mut counter);

        if !walk(scratch, &mut counter, topology, visitor) {
            return false;
        }
    }

    true
}

fn walk<T, V>(scratch: &mut Scratch, counter: &mut u32, topology: &T, visitor: &mut V) -> bool
where
    T: Topology + ?Sized,
    V: Visitor + ?Sized,
{
    while let Some(current) = scratch.pending.last().copied() {
        let cursor = scratch.order[current as usize];

        if cursor < topology.edge_count_of(current) {
            scratch.order[current as usize] = cursor + 1;

            if let Some(next) = topology.edge_target_of(current, cursor)
                && topology.holds(next)
            {
                step(scratch, current, next, counter);
            }

            continue;
        }

        let _ = scratch.pending.pop();

        if scratch.low[current as usize] == scratch.index[current as usize]
            && !component_close(scratch, current, topology, visitor)
        {
            return false;
        }

        if let Some(parent) = scratch.pending.last().copied() {
            let low = scratch.low[parent as usize].min(scratch.low[current as usize]);

            scratch.low[parent as usize] = low;
        }
    }

    true
}

fn step(scratch: &mut Scratch, current: u32, next: u32, counter: &mut u32) {
    if next == current {
        return;
    }

    if scratch.index[next as usize] == NOT_VISITED {
        scratch.enter(next, counter);

        return;
    }

    if !scratch.resident[next as usize] {
        return;
    }

    let low = scratch.low[current as usize].min(scratch.index[next as usize]);

    scratch.low[current as usize] = low;
}

fn component_close<T, V>(scratch: &mut Scratch, root: u32, topology: &T, visitor: &mut V) -> bool
where
    T: Topology + ?Sized,
    V: Visitor + ?Sized,
{
    let count = scratch.stack.count();
    let mut position = count;

    while position > 0 {
        position -= 1;

        if scratch.stack[position as usize] == root {
            break;
        }
    }

    let members = count - position;

    assert!(members > 0);

    for offset in position..count {
        scratch.resident[scratch.stack[offset as usize] as usize] = false;
    }

    let looping = members > 1 || (topology.holds(root) && names_itself(root, topology));
    let held = visitor.component(&scratch.stack[position as usize..count as usize], looping);

    for _ in position..count {
        let _ = scratch.stack.pop();
    }

    held
}

fn names_itself<T>(node: u32, topology: &T) -> bool
where
    T: Topology + ?Sized,
{
    for ordinal in 0..topology.edge_count_of(node) {
        if topology.edge_target_of(node, ordinal) == Some(node) {
            return true;
        }
    }

    false
}

#[cfg(test)]
mod tests {
    use super::*;

    struct Listed<'held> {
        edges: &'held [(u32, u32)],
    }

    struct Recorder {
        seen: Vec<(Vec<u32>, bool)>,
    }

    struct Stopping {
        seen: u32,
    }

    struct Unresolved {
        edge_count: u32,
    }

    struct Whole {
        seen: u32,
    }

    impl Topology for Listed<'_> {
        fn edge_count_of(&self, node: u32) -> u32 {
            crate::bounded::count_of(self.edges.iter().filter(|edge| edge.0 == node).count())
        }

        fn edge_target_of(&self, node: u32, ordinal: u32) -> Option<u32> {
            self.edges
                .iter()
                .filter(|edge| edge.0 == node)
                .nth(ordinal as usize)
                .map(|edge| edge.1)
        }

        fn holds(&self, _node: u32) -> bool {
            true
        }
    }

    impl Topology for Unresolved {
        fn edge_count_of(&self, _node: u32) -> u32 {
            self.edge_count
        }

        fn edge_target_of(&self, _node: u32, _ordinal: u32) -> Option<u32> {
            None
        }

        fn holds(&self, _node: u32) -> bool {
            true
        }
    }

    impl Visitor for Recorder {
        fn component(&mut self, members: &[u32], looping: bool) -> bool {
            let mut sorted = members.to_vec();

            sorted.sort_unstable();
            self.seen.push((sorted, looping));

            true
        }
    }

    impl Visitor for Stopping {
        fn component(&mut self, _members: &[u32], _looping: bool) -> bool {
            self.seen += 1;

            false
        }
    }

    impl Visitor for Whole {
        fn component(&mut self, _members: &[u32], looping: bool) -> bool {
            assert!(!looping);
            self.seen += 1;

            true
        }
    }

    fn walked(node_count: u32, edges: &[(u32, u32)]) -> Vec<(Vec<u32>, bool)> {
        let mut scratch = Scratch::reserve(node_count.max(1));
        let topology = Listed { edges };
        let mut recorder = Recorder { seen: Vec::new() };
        let held = components(node_count, &mut scratch, &topology, &mut recorder);

        assert!(held);

        recorder.seen
    }

    #[test]
    fn a_graph_without_a_cycle_loops_nowhere() {
        let seen = walked(3, &[(0, 1), (1, 2)]);

        assert_eq!(seen.len(), 3);
        assert!(seen.iter().all(|component| !component.1));
    }

    #[test]
    fn a_self_edge_loops_on_its_own() {
        let seen = walked(2, &[(0, 0), (0, 1)]);
        let looping: Vec<&(Vec<u32>, bool)> = seen.iter().filter(|held| held.1).collect();

        assert_eq!(looping.len(), 1);
        assert_eq!(looping[0].0, vec![0]);
    }

    #[test]
    fn a_cycle_of_three_loops_as_one_component() {
        let seen = walked(3, &[(0, 1), (1, 2), (2, 0)]);
        let looping: Vec<&(Vec<u32>, bool)> = seen.iter().filter(|held| held.1).collect();

        assert_eq!(looping.len(), 1);
        assert_eq!(looping[0].0, vec![0, 1, 2]);
    }

    #[test]
    fn an_unresolved_edge_reaches_nothing() {
        let mut scratch = Scratch::reserve(2);
        let topology = Unresolved { edge_count: 1 };
        let mut whole = Whole { seen: 0 };
        let held = components(2, &mut scratch, &topology, &mut whole);

        assert!(held);
        assert_eq!(whole.seen, 2);
    }

    #[test]
    fn a_visitor_that_stops_ends_the_walk() {
        let mut scratch = Scratch::reserve(4);
        let topology = Unresolved { edge_count: 0 };
        let mut stopping = Stopping { seen: 0 };
        let held = components(4, &mut scratch, &topology, &mut stopping);

        assert!(!held);
        assert_eq!(stopping.seen, 1);
    }
}
