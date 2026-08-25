use crate::bounded::{BoundedVec, Span, count_of};
use crate::syntax::{CATEGORY_COUNT, Category};

pub const FRAME_DEPTH_MAX: u32 = 1_024;
pub const NONE: u32 = u32::MAX;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Structure {
    Complete,
    TooDeep,
    Truncated,
}

pub trait Kind: Copy + Eq {
    type Error: Copy;
    const ERROR: Self;

    fn category(self) -> Category;

    fn is_node(self) -> bool;

    fn is_token(self) -> bool;
}

pub trait Links {
    fn count(&self) -> u32;

    fn first_child_of(&self, node: u32) -> u32;

    fn next_sibling_of(&self, node: u32) -> u32;

    fn parent_of(&self, node: u32) -> u32;
}

pub trait Positioned: Copy {
    fn end(&self) -> u32;

    fn offset(&self) -> u32;
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Node<K> {
    pub child_first: u32,
    pub kind: K,
    pub parent: u32,
    pub sibling_next: u32,
    pub token_end: u32,
    pub token_start: u32,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Event<K> {
    Anchor { forward_parent: u32 },
    Finish,
    Layout { position: u32 },
    Start { forward_parent: u32, kind: K },
    Token { position: u32 },
    Tombstone,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Step {
    Enter(u32),
    Leave(u32),
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Checkpoint {
    index: u32,
}

impl Checkpoint {
    pub const NONE: Self = Self { index: NONE };

    pub const fn is_none(self) -> bool {
        self.index == NONE
    }
}

pub struct Tree<K: Kind> {
    errors: BoundedVec<K::Error>,
    nodes: BoundedVec<Node<K>>,
}

pub struct Events<K> {
    chain: [Option<K>; FRAME_DEPTH_MAX as usize],
    depth: u32,
    frames: [Frame; FRAME_DEPTH_MAX as usize],
    items: BoundedVec<Event<K>>,
    open: [u32; FRAME_DEPTH_MAX as usize],
    outcome: Structure,
}

pub struct Walk<'links, L> {
    entering: bool,
    links: &'links L,
    node: u32,
    root: u32,
    scan: u32,
    step_max: u32,
    steps: u32,
}

#[derive(Clone, Copy, Debug)]
struct Frame {
    last_child: u32,
    node: u32,
    token_start: u32,
}

impl Frame {
    const EMPTY: Self = Self {
        last_child: NONE,
        node: NONE,
        token_start: 0,
    };
}

struct Replay<'events, 'tree, K: Kind> {
    attributed: u32,
    depth: u32,
    events: &'events mut Events<K>,
    outcome: Structure,
    position: u32,
    tree: &'tree mut Tree<K>,
}

impl<K> Node<K> {
    pub fn span<T>(&self, tokens: &[T]) -> Span
    where
        T: Positioned,
    {
        assert!(self.token_start <= self.token_end);
        assert!(self.token_end as usize <= tokens.len());

        let offset = tokens
            .get(self.token_start as usize)
            .map_or_else(|| end_of(tokens), Positioned::offset);

        if self.token_end <= self.token_start {
            return Span { length: 0, offset };
        }

        let end = tokens[self.token_end as usize - 1].end();

        assert!(end >= offset);

        Span {
            length: end - offset,
            offset,
        }
    }
}

impl<K: Kind> Tree<K> {
    pub fn reserve(node_count_max: u32, error_count_max: u32) -> Self {
        assert!(node_count_max > 0);
        assert!(error_count_max > 0);

        assert!(!crate::allocation::is_frozen());

        Self {
            errors: BoundedVec::reserve(error_count_max),
            nodes: BoundedVec::reserve(node_count_max),
        }
    }

    pub fn as_slice(&self) -> &[Node<K>] {
        &self.nodes
    }

    pub fn at(&self, index: u32) -> Node<K> {
        assert!(index < self.count());

        self.nodes[index as usize]
    }

    pub fn clear(&mut self) {
        self.errors.clear();
        self.nodes.clear();

        assert_eq!(self.count(), 0);
    }

    pub fn count(&self) -> u32 {
        self.nodes.count()
    }

    pub fn errors(&self) -> &[K::Error] {
        &self.errors
    }

    #[must_use]
    pub fn push(&mut self, node: Node<K>) -> bool {
        self.nodes.push(node)
    }

    #[must_use]
    pub fn push_error(&mut self, error: K::Error) -> bool {
        self.errors.push(error)
    }

    pub fn set_child_first(&mut self, node: u32, child: u32) {
        assert!(node < self.count());

        self.nodes[node as usize].child_first = child;
    }

    pub fn set_sibling_next(&mut self, node: u32, sibling: u32) {
        assert!(node < self.count());

        self.nodes[node as usize].sibling_next = sibling;
    }

    pub fn set_token_end(&mut self, node: u32, token_end: u32) {
        assert!(node < self.count());

        self.nodes[node as usize].token_end = token_end;
    }
}

impl<K: Kind> Links for Tree<K> {
    fn count(&self) -> u32 {
        self.nodes.count()
    }

    fn first_child_of(&self, node: u32) -> u32 {
        self.at(node).child_first
    }

    fn next_sibling_of(&self, node: u32) -> u32 {
        self.at(node).sibling_next
    }

    fn parent_of(&self, node: u32) -> u32 {
        self.at(node).parent
    }
}

impl<K: Kind + core::fmt::Debug> core::fmt::Debug for Tree<K>
where
    K::Error: core::fmt::Debug,
{
    fn fmt(&self, formatter: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        formatter
            .debug_struct("Tree")
            .field("errors", &&*self.errors)
            .field("nodes", &&*self.nodes)
            .finish()
    }
}

impl<K: core::fmt::Debug> core::fmt::Debug for Events<K> {
    fn fmt(&self, formatter: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        formatter
            .debug_struct("Events")
            .field("depth", &self.depth)
            .field("items", &&*self.items)
            .field("outcome", &self.outcome)
            .finish_non_exhaustive()
    }
}

impl<K: Kind> Events<K> {
    pub fn reserve(event_count_max: u32) -> Self {
        assert!(event_count_max > 0);

        assert!(!crate::allocation::is_frozen());

        Self {
            chain: [None; FRAME_DEPTH_MAX as usize],
            depth: 0,
            frames: [Frame::EMPTY; FRAME_DEPTH_MAX as usize],
            items: BoundedVec::reserve(event_count_max),
            open: [NONE; FRAME_DEPTH_MAX as usize],
            outcome: Structure::Complete,
        }
    }

    pub fn as_slice(&self) -> &[Event<K>] {
        &self.items
    }

    pub fn clear(&mut self) {
        self.depth = 0;
        self.items.clear();
        self.outcome = Structure::Complete;

        assert_eq!(self.count(), 0);
    }

    pub fn count(&self) -> u32 {
        self.items.count()
    }

    pub fn depth(&self) -> u32 {
        self.depth
    }

    pub const fn outcome(&self) -> Structure {
        self.outcome
    }

    pub fn checkpoint(&mut self) -> Checkpoint {
        let index = self.count();

        let _ = self.record(Event::Anchor {
            forward_parent: NONE,
        });

        assert!(index <= self.count());

        Checkpoint { index }
    }

    pub fn start(&mut self, kind: K) {
        assert!(kind.is_node());

        let index = self.count();

        let recorded = self.record(Event::Start {
            forward_parent: NONE,
            kind,
        });

        self.open(if recorded { index } else { NONE });
    }

    pub fn start_at(&mut self, checkpoint: Checkpoint, kind: K) {
        assert!(kind.is_node());
        assert!(checkpoint.index < self.count());

        let index = self.count();

        let recorded = self.record(Event::Start {
            forward_parent: NONE,
            kind,
        });

        if recorded {
            self.chain(checkpoint.index, index);
        }

        self.open(if recorded { index } else { NONE });
    }

    pub fn token(&mut self, position: u32) {
        assert!(position != NONE);

        let _ = self.record(Event::Token { position });
    }

    pub fn layout(&mut self, position: u32) {
        assert!(position != NONE);

        let _ = self.record(Event::Layout { position });
    }

    pub fn finish(&mut self) {
        if self.depth == 0 {
            return;
        }

        self.depth -= 1;

        if self.open[self.depth as usize] == NONE {
            return;
        }

        let _ = self.record(Event::Finish);
    }

    pub fn abandon(&mut self) {
        if self.depth == 0 {
            return;
        }

        self.depth -= 1;

        let index = self.open[self.depth as usize];

        if index == NONE {
            return;
        }

        assert!(index < self.count());

        self.items[index as usize] = Event::Tombstone;
    }

    fn chain(&mut self, from: u32, to: u32) {
        assert!(from < to);

        let Some(onward) = forward_parent_of(self.items[from as usize]) else {
            return;
        };

        assert!(onward == NONE || onward < to);

        forward_parent_set(&mut self.items[to as usize], onward);
        forward_parent_set(&mut self.items[from as usize], to);
    }

    fn open(&mut self, index: u32) {
        if self.depth >= FRAME_DEPTH_MAX {
            self.outcome = Structure::TooDeep;

            return;
        }

        self.open[self.depth as usize] = index;
        self.depth += 1;
    }

    fn record(&mut self, event: Event<K>) -> bool {
        let recorded = self.items.push(event);

        if !recorded && self.outcome == Structure::Complete {
            self.outcome = Structure::Truncated;
        }

        recorded
    }
}

impl<L: Links> Walk<'_, L> {
    fn advance(&mut self, node: u32) {
        if self.root != NONE && node == self.root {
            self.node = NONE;

            return;
        }

        let parent = self.links.parent_of(node);

        if parent == NONE {
            self.node = self.root_next();
            self.entering = self.node != NONE;

            return;
        }

        let sibling = self.links.next_sibling_of(node);

        if sibling == NONE {
            self.entering = false;
            self.node = parent;

            return;
        }

        self.entering = true;
        self.node = sibling;
    }

    fn root_next(&mut self) -> u32 {
        let count = self.links.count();

        for _ in 0..count {
            if self.scan >= count {
                return NONE;
            }

            let candidate = self.scan;

            self.scan += 1;

            if self.links.parent_of(candidate) == NONE {
                return candidate;
            }
        }

        NONE
    }
}

impl<L: Links> Iterator for Walk<'_, L> {
    type Item = Step;

    fn next(&mut self) -> Option<Step> {
        if self.node == NONE {
            return None;
        }

        assert!(self.node < self.links.count());

        self.steps += 1;

        assert!(self.steps <= self.step_max);

        let node = self.node;

        if self.entering {
            let child = self.links.first_child_of(node);

            if child == NONE {
                self.entering = false;
            } else {
                self.node = child;
            }

            return Some(Step::Enter(node));
        }

        self.advance(node);

        Some(Step::Leave(node))
    }
}

impl<'events, 'tree, K: Kind> Replay<'events, 'tree, K> {
    fn new(events: &'events mut Events<K>, tree: &'tree mut Tree<K>) -> Self {
        let outcome = events.outcome();

        Self {
            attributed: 0,
            depth: 0,
            events,
            outcome,
            position: 0,
            tree,
        }
    }

    fn close(&mut self) {
        if self.depth == 0 {
            return;
        }

        self.depth -= 1;

        let frame = self.events.frames[self.depth as usize];

        if frame.node == NONE {
            return;
        }

        self.tree
            .set_token_end(frame.node, self.attributed.max(frame.token_start));
    }

    fn link(&mut self, index: u32) {
        assert!(self.depth > 0);

        let parent = self.depth as usize - 1;
        let last = self.events.frames[parent].last_child;

        if last == NONE {
            let node = self.events.frames[parent].node;

            if node != NONE {
                self.tree.set_child_first(node, index);
            }
        } else {
            self.tree.set_sibling_next(last, index);
        }

        self.events.frames[parent].last_child = index;
    }

    fn open(&mut self, kind: K) {
        assert!(kind.is_node());

        if self.depth >= FRAME_DEPTH_MAX {
            self.outcome = Structure::TooDeep;

            return;
        }

        let parent = if self.depth == 0 {
            NONE
        } else {
            self.events.frames[self.depth as usize - 1].node
        };

        let index = self.tree.count();

        let pushed = self.tree.push(Node {
            child_first: NONE,
            kind,
            parent,
            sibling_next: NONE,
            token_end: NONE,
            token_start: self.position,
        });

        if !pushed {
            if self.outcome == Structure::Complete {
                self.outcome = Structure::Truncated;
            }

            self.events.frames[self.depth as usize] = Frame {
                last_child: NONE,
                node: NONE,
                token_start: self.position,
            };

            self.depth += 1;

            return;
        }

        if self.depth > 0 {
            self.link(index);
        }

        self.events.frames[self.depth as usize] = Frame {
            last_child: NONE,
            node: index,
            token_start: self.position,
        };

        self.depth += 1;
    }

    fn open_chain(&mut self, kind: Option<K>, forward_parent: u32) {
        let mut count = 0_usize;
        let mut next = forward_parent;

        while next != NONE && count < FRAME_DEPTH_MAX as usize {
            let event = self.events.items[next as usize];

            self.events.items[next as usize] = Event::Tombstone;

            match event {
                Event::Anchor {
                    forward_parent: onward,
                } => next = onward,
                Event::Start {
                    forward_parent: onward,
                    kind: wrapper,
                } => {
                    self.events.chain[count] = Some(wrapper);
                    count += 1;
                    next = onward;
                }
                Event::Finish | Event::Layout { .. } | Event::Token { .. } | Event::Tombstone => {
                    break;
                }
            }
        }

        if next != NONE {
            self.outcome = Structure::TooDeep;
        }

        for index in 0..count {
            let Some(wrapper) = self.events.chain[index] else {
                continue;
            };

            self.open(wrapper);
        }

        if let Some(first) = kind {
            self.open(first);
        }
    }

    fn run(&mut self) -> Structure {
        let count = self.events.count();

        for index in 0..count {
            match self.events.items[index as usize] {
                Event::Anchor { forward_parent } => self.open_chain(None, forward_parent),
                Event::Finish => self.close(),
                Event::Start {
                    forward_parent,
                    kind: wrapper,
                } => self.open_chain(Some(wrapper), forward_parent),
                Event::Layout { position } => self.skip(position),
                Event::Token { position } => self.advance(position),
                Event::Tombstone => {}
            }
        }

        while self.depth > 0 {
            self.close();
        }

        self.outcome
    }

    fn advance(&mut self, position: u32) {
        assert!(position != NONE);
        assert!(position >= self.position);

        self.position = position + 1;
        self.attributed = self.position;
    }

    fn skip(&mut self, position: u32) {
        assert!(position != NONE);
        assert!(position >= self.position);

        self.position = position + 1;
    }
}

pub struct Index<K> {
    kind: core::marker::PhantomData<K>,
    positions: BoundedVec<u32>,
    starts: [u32; CATEGORY_COUNT + 1],
}

impl<K: Kind> Index<K> {
    pub fn reserve(node_count_max: u32) -> Self {
        assert!(node_count_max > 0);

        assert!(!crate::allocation::is_frozen());

        Self {
            kind: core::marker::PhantomData,
            positions: BoundedVec::reserve(node_count_max),
            starts: [0; CATEGORY_COUNT + 1],
        }
    }

    pub fn build(&mut self, tree: &Tree<K>) {
        assert!(tree.count() <= self.positions.capacity());

        self.clear();

        let mut counts = [0_u32; CATEGORY_COUNT];

        for node in tree.as_slice() {
            counts[node.kind.category().index()] += 1;
        }

        let mut running = 0_u32;

        for (slot, count) in counts.iter().enumerate() {
            self.starts[slot] = running;
            running += *count;
        }

        self.starts[CATEGORY_COUNT] = running;

        assert_eq!(running, tree.count());

        for _ in 0..tree.count() {
            self.positions.push_assert(NONE);
        }

        let mut cursors = self.starts;

        for (position, node) in tree.as_slice().iter().enumerate() {
            let slot = node.kind.category().index();
            let at = cursors[slot];

            assert!(at < self.starts[slot + 1]);

            self.positions[at as usize] = count_of(position);
            cursors[slot] = at + 1;
        }

        assert_eq!(self.count(), tree.count());
    }

    pub fn clear(&mut self) {
        self.positions.clear();
        self.starts = [0; CATEGORY_COUNT + 1];

        assert_eq!(self.count(), 0);
    }

    pub fn count(&self) -> u32 {
        self.positions.count()
    }

    pub fn of(&self, category: Category) -> &[u32] {
        let slot = category.index();
        let start = self.starts[slot] as usize;
        let end = self.starts[slot + 1] as usize;

        assert!(start <= end);
        assert!(end <= self.positions.count() as usize);

        &self.positions[start..end]
    }
}

fn end_of<T>(tokens: &[T]) -> u32
where
    T: Positioned,
{
    tokens.last().map_or(0, Positioned::end)
}

fn forward_parent_set<K>(event: &mut Event<K>, value: u32) {
    match event {
        Event::Anchor { forward_parent } | Event::Start { forward_parent, .. } => {
            *forward_parent = value;
        }
        Event::Finish | Event::Layout { .. } | Event::Token { .. } | Event::Tombstone => {
            unreachable!()
        }
    }
}

fn forward_parent_of<K>(event: Event<K>) -> Option<u32>
where
    K: Copy,
{
    match event {
        Event::Anchor { forward_parent } | Event::Start { forward_parent, .. } => {
            Some(forward_parent)
        }
        Event::Finish | Event::Layout { .. } | Event::Token { .. } | Event::Tombstone => None,
    }
}

pub fn replay<K>(events: &mut Events<K>, tree: &mut Tree<K>) -> Structure
where
    K: Kind,
{
    assert_eq!(tree.count(), 0);

    let mut machine = Replay::new(events, tree);
    let outcome = machine.run();

    assert!(tree.count() <= events.count());

    outcome
}

pub fn walk<L>(links: &L) -> Walk<'_, L>
where
    L: Links,
{
    let count = links.count();

    Walk {
        entering: count > 0,
        links,
        node: if count > 0 { 0 } else { NONE },
        root: NONE,
        scan: 1,
        step_max: step_max_of(count),
        steps: 0,
    }
}

pub fn walk_from<L>(links: &L, node: u32) -> Walk<'_, L>
where
    L: Links,
{
    let count = links.count();

    assert!(node < count);

    Walk {
        entering: true,
        links,
        node,
        root: node,
        scan: count,
        step_max: step_max_of(count),
        steps: 0,
    }
}

fn step_max_of(count: u32) -> u32 {
    assert!(count <= (NONE - 1) / 2);

    2 * count + 1
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::bounded::count_of;

    #[derive(Clone, Copy, Debug, Eq, PartialEq)]
    enum TestKind {
        Attribute,
        BinOp,
        Error,
        Name,
        Word,
    }

    #[derive(Clone, Copy, Debug, Eq, PartialEq)]
    struct Spot {
        length: u32,
        offset: u32,
    }

    impl Kind for TestKind {
        type Error = u32;
        const ERROR: Self = Self::Error;

        fn category(self) -> Category {
            match self {
                Self::Attribute => Category::Attribute,
                Self::BinOp => Category::Expression,
                Self::Error => Category::Other,
                Self::Name => Category::Name,
                Self::Word => Category::Value,
            }
        }

        fn is_node(self) -> bool {
            !matches!(self, Self::Word)
        }

        fn is_token(self) -> bool {
            matches!(self, Self::Word)
        }
    }

    impl Positioned for Spot {
        fn end(&self) -> u32 {
            self.offset + self.length
        }

        fn offset(&self) -> u32 {
            self.offset
        }
    }

    fn spots(count: u32) -> Vec<Spot> {
        (0..count)
            .map(|index| Spot {
                length: 1,
                offset: index,
            })
            .collect()
    }

    #[test]
    fn a_flat_start_and_finish_replays_in_preorder() {
        let mut events = Events::<TestKind>::reserve(32);
        let mut tree = Tree::<TestKind>::reserve(32, 4);

        events.start(TestKind::BinOp);
        events.token(0);
        events.start(TestKind::Name);
        events.token(1);
        events.finish();
        events.finish();

        assert!(TestKind::Word.is_token());
        assert!(!TestKind::Word.is_node());
        assert_eq!(replay(&mut events, &mut tree), Structure::Complete);
        assert_eq!(tree.count(), 2);

        let outer = tree.at(0);
        let inner = tree.at(1);

        assert_eq!(outer.kind, TestKind::BinOp);
        assert_eq!(outer.parent, NONE);
        assert_eq!(outer.child_first, 1);
        assert_eq!(outer.token_start, 0);
        assert_eq!(outer.token_end, 2);
        assert_eq!(inner.kind, TestKind::Name);
        assert_eq!(inner.parent, 0);
        assert_eq!(inner.child_first, NONE);
        assert_eq!(inner.sibling_next, NONE);
        assert_eq!(inner.token_start, 1);
        assert_eq!(inner.token_end, 2);

        assert_eq!(
            outer.span(&spots(2)),
            Span {
                length: 2,
                offset: 0
            }
        );
    }

    #[test]
    fn a_chain_of_checkpoints_wraps_outermost_last() {
        let mut events = Events::<TestKind>::reserve(32);
        let mut tree = Tree::<TestKind>::reserve(32, 4);
        let checkpoint = events.checkpoint();

        events.start(TestKind::Name);
        events.token(0);
        events.finish();

        events.start_at(checkpoint, TestKind::Attribute);
        events.token(1);
        events.token(2);
        events.finish();

        events.start_at(checkpoint, TestKind::Attribute);
        events.token(3);
        events.token(4);
        events.finish();

        assert_eq!(replay(&mut events, &mut tree), Structure::Complete);
        assert_eq!(tree.count(), 3);

        let outer = tree.at(0);
        let inner = tree.at(1);
        let name = tree.at(2);

        assert_eq!(outer.kind, TestKind::Attribute);
        assert_eq!(outer.parent, NONE);
        assert_eq!(outer.child_first, 1);
        assert_eq!(outer.token_start, 0);
        assert_eq!(outer.token_end, 5);
        assert_eq!(inner.kind, TestKind::Attribute);
        assert_eq!(inner.parent, 0);
        assert_eq!(inner.child_first, 2);
        assert_eq!(inner.token_start, 0);
        assert_eq!(inner.token_end, 3);
        assert_eq!(name.kind, TestKind::Name);
        assert_eq!(name.parent, 1);
        assert_eq!(name.token_end, 1);
    }

    #[test]
    fn an_abandoned_start_leaves_its_tokens_to_the_parent() {
        let mut events = Events::<TestKind>::reserve(32);
        let mut tree = Tree::<TestKind>::reserve(32, 4);

        events.start(TestKind::BinOp);
        events.token(0);
        events.start(TestKind::Name);
        events.token(1);
        events.abandon();
        events.token(2);
        events.finish();

        assert_eq!(replay(&mut events, &mut tree), Structure::Complete);
        assert_eq!(tree.count(), 1);

        let only = tree.at(0);

        assert_eq!(only.kind, TestKind::BinOp);
        assert_eq!(only.child_first, NONE);
        assert_eq!(only.token_start, 0);
        assert_eq!(only.token_end, 3);
    }

    #[test]
    fn siblings_link_in_order_and_stay_disjoint() {
        let mut events = Events::<TestKind>::reserve(32);
        let mut tree = Tree::<TestKind>::reserve(32, 4);

        events.start(TestKind::BinOp);

        for position in 0..3_u32 {
            events.start(TestKind::Name);
            events.token(position);
            events.finish();
        }

        events.finish();

        assert_eq!(replay(&mut events, &mut tree), Structure::Complete);
        assert_eq!(tree.count(), 4);
        assert_eq!(tree.at(0).child_first, 1);
        assert_eq!(tree.at(1).sibling_next, 2);
        assert_eq!(tree.at(2).sibling_next, 3);
        assert_eq!(tree.at(3).sibling_next, NONE);

        for index in 1..4_u32 {
            let node = tree.at(index);

            assert_eq!(node.parent, 0);
            assert_eq!(node.token_start, index - 1);
            assert_eq!(node.token_end, index);
        }
    }

    #[test]
    fn a_starved_tree_truncates() {
        let mut events = Events::<TestKind>::reserve(32);
        let mut tree = Tree::<TestKind>::reserve(1, 4);

        events.start(TestKind::BinOp);
        events.start(TestKind::Name);
        events.token(0);
        events.finish();
        events.finish();

        assert_eq!(replay(&mut events, &mut tree), Structure::Truncated);
        assert_eq!(tree.count(), 1);
    }

    #[test]
    fn a_starved_event_buffer_truncates() {
        let mut events = Events::<TestKind>::reserve(2);
        let mut tree = Tree::<TestKind>::reserve(32, 4);

        events.start(TestKind::BinOp);
        events.token(0);
        events.token(1);
        events.finish();

        assert_eq!(events.outcome(), Structure::Truncated);
        assert_eq!(replay(&mut events, &mut tree), Structure::Truncated);
    }

    #[test]
    fn a_replay_repeats_itself_after_a_clear() {
        let mut events = Events::<TestKind>::reserve(32);
        let mut tree = Tree::<TestKind>::reserve(32, 4);

        events.start(TestKind::BinOp);
        events.token(0);
        events.finish();

        let _ = replay(&mut events, &mut tree);
        let first: Vec<Node<TestKind>> = tree.as_slice().to_vec();

        tree.clear();
        events.clear();
        events.start(TestKind::BinOp);
        events.token(0);
        events.finish();

        let _ = replay(&mut events, &mut tree);

        assert_eq!(tree.as_slice(), first);
        assert_eq!(events.depth(), 0);
    }

    fn nested() -> Tree<TestKind> {
        let mut events = Events::<TestKind>::reserve(64);
        let mut tree = Tree::<TestKind>::reserve(64, 4);

        events.start(TestKind::BinOp);
        events.token(0);
        events.start(TestKind::Name);
        events.token(1);
        events.finish();
        events.start(TestKind::Attribute);
        events.start(TestKind::Name);
        events.token(2);
        events.finish();
        events.finish();
        events.finish();

        assert_eq!(replay(&mut events, &mut tree), Structure::Complete);

        tree
    }

    fn forest() -> Tree<TestKind> {
        let mut events = Events::<TestKind>::reserve(64);
        let mut tree = Tree::<TestKind>::reserve(64, 4);

        for position in 0..3_u32 {
            events.start(TestKind::BinOp);
            events.start(TestKind::Name);
            events.token(position);
            events.finish();
            events.finish();
        }

        assert_eq!(replay(&mut events, &mut tree), Structure::Complete);

        tree
    }

    fn leave_positions(tree: &Tree<TestKind>) -> Vec<u32> {
        let mut positions = vec![NONE; tree.count() as usize];

        for (position, step) in walk(tree).enumerate() {
            if let Step::Leave(node) = step {
                positions[node as usize] = count_of(position);
            }
        }

        positions
    }

    #[test]
    fn every_node_enters_once_and_leaves_once() {
        let tree = nested();
        let mut entered = vec![0_u32; tree.count() as usize];
        let mut left = vec![0_u32; tree.count() as usize];

        for step in walk(&tree) {
            match step {
                Step::Enter(node) => entered[node as usize] += 1,
                Step::Leave(node) => left[node as usize] += 1,
            }
        }

        assert_eq!(tree.count(), 4);
        assert_eq!(entered, vec![1_u32; tree.count() as usize]);
        assert_eq!(left, vec![1_u32; tree.count() as usize]);
    }

    #[test]
    fn the_enter_order_is_index_order() {
        let tree = nested();

        let entered: Vec<u32> = walk(&tree)
            .filter_map(|step| match step {
                Step::Enter(node) => Some(node),
                Step::Leave(_) => None,
            })
            .collect();

        assert_eq!(entered, vec![0, 1, 2, 3]);
    }

    #[test]
    fn a_parent_leaves_after_its_last_child() {
        let tree = nested();
        let positions = leave_positions(&tree);

        for node in 0..tree.count() {
            let mut child = tree.at(node).child_first;

            while child != NONE {
                assert!(positions[child as usize] < positions[node as usize]);

                child = tree.at(child).sibling_next;
            }
        }
    }

    #[test]
    fn a_subtree_walk_stays_inside_the_subtree() {
        let tree = nested();
        let visited: Vec<Step> = walk_from(&tree, 2).collect();

        assert_eq!(
            visited,
            vec![
                Step::Enter(2),
                Step::Enter(3),
                Step::Leave(3),
                Step::Leave(2)
            ]
        );
    }

    #[test]
    fn an_empty_tree_walks_to_nothing() {
        let tree = Tree::<TestKind>::reserve(4, 2);

        assert_eq!(tree.count(), 0);
        assert_eq!(walk(&tree).count(), 0);
    }

    #[test]
    fn a_lone_node_enters_and_leaves() {
        let mut events = Events::<TestKind>::reserve(8);
        let mut tree = Tree::<TestKind>::reserve(8, 2);

        events.start(TestKind::Name);
        events.token(0);
        events.finish();

        assert_eq!(replay(&mut events, &mut tree), Structure::Complete);

        let visited: Vec<Step> = walk(&tree).collect();

        assert_eq!(visited, vec![Step::Enter(0), Step::Leave(0)]);
    }

    #[test]
    fn a_forest_walks_every_root() {
        let tree = forest();

        let entered: Vec<u32> = walk(&tree)
            .filter_map(|step| match step {
                Step::Enter(node) => Some(node),
                Step::Leave(_) => None,
            })
            .collect();

        assert_eq!(tree.count(), 6);
        assert_eq!(entered, vec![0, 1, 2, 3, 4, 5]);
        assert_eq!(walk(&tree).count(), 12);
    }

    #[test]
    fn an_error_row_records_and_reads_back() {
        let mut tree = Tree::<TestKind>::reserve(4, 2);

        assert!(tree.push_error(7));
        assert!(tree.push_error(9));
        assert!(!tree.push_error(11));
        assert_eq!(tree.errors(), &[7, 9]);

        tree.clear();

        assert!(tree.errors().is_empty());
    }
}
