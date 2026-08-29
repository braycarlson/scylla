use crate::bounded::{BoundedVec, Span};
use crate::language::Lexer as _;
use crate::lex::PYTHON;
use crate::syntax::python::ast::{Alias, FunctionDef, View};
use crate::syntax::python::bind::{ScopeKind, Tables};
use crate::syntax::python::classify::classify;
use crate::syntax::python::kind::PythonKind;
use crate::syntax::python::parse;
use crate::syntax::python::stdlib::{self, PythonVersion};
use crate::syntax::{Fact, FactKind, Facts, name_hash};
use crate::token::{Lex, Token, Tokens};
use crate::tree::{Events, NONE, Step, Structure, Tree, walk, walk_from};

pub const ANNOTATION_DEPTH_MAX: u32 = 1 << 6;
pub const ATTRIBUTE_DEPTH_MAX: u32 = 1 << 6;
pub const BRANCH_DEPTH_MAX: u32 = 1 << 8;
pub const DECORATOR_DEPTH_MAX: u32 = 1 << 8;
pub const SEGMENT_COUNT_MAX: u32 = 1 << 6;
pub const SCOPE_DEPTH_MAX: u32 = 1 << 8;

fn scope_bucket_of(node: u32) -> u32 {
    node.wrapping_mul(2_654_435_761)
}

fn bucket_count_of(binding_count_max: u32) -> u32 {
    binding_count_max.next_power_of_two().max(16)
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum BindingKind {
    Annotation,
    Assignment,
    Augmented,
    ClassDefinition,
    ComprehensionVariable,
    Deletion,
    ExceptVariable,
    FunctionDefinition,
    FutureImport,
    Global,
    Import,
    ImportFrom,
    ImportStar,
    LoopVariable,
    MatchCapture,
    Named,
    Nonlocal,
    Parameter,
    SubmoduleImport,
    TypeAlias,
    TypeParameter,
    WithVariable,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Context {
    Delete,
    Load,
    Store,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Qualified {
    Builtin,
    Local(u32),
    Relative(u32),
    Resolved,
    Unresolved,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Resolution {
    Bound(u32),
    Builtin,
    Maybe,
    Unresolved,
}

#[derive(Debug)]
pub struct AnnotationScratch {
    events: Events<PythonKind>,
    lexed: Tokens,
    raw: BoundedVec<PythonKind>,
    tokens: Tokens,
    tree: Tree<PythonKind>,
}

impl AnnotationScratch {
    pub fn reserve(token_count_max: u32, node_count_max: u32) -> Self {
        assert!(token_count_max > 0);
        assert!(node_count_max > 0);

        assert!(!crate::allocation::is_frozen());

        Self {
            events: Events::reserve(node_count_max * 4),
            lexed: Tokens::reserve(token_count_max),
            raw: BoundedVec::reserve(token_count_max),
            tokens: Tokens::reserve(token_count_max),
            tree: Tree::reserve(node_count_max, ANNOTATION_DEPTH_MAX),
        }
    }

    fn clear(&mut self) {
        self.lexed.clear();
        self.raw.clear();
        self.tokens.clear();
        self.tree.clear();
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Branch {
    pub node: u32,
    pub parent: u32,
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct BindingFlags {
    pub alias: bool,
    pub deleted: bool,
    pub export_explicit: bool,
    pub overload: bool,
    pub private: bool,
    pub shadowed: bool,
    pub type_checking: bool,
    pub unpacked: bool,
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct ReferenceFlags {
    pub annotation: bool,
    pub deferred: bool,
    pub type_checking: bool,
    pub typing_only: bool,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Binding {
    pub branch: u32,
    pub declared: Option<BindingKind>,
    pub flags: BindingFlags,
    pub kind: BindingKind,
    pub name: Span,
    pub name_hash: u32,
    pub node: u32,
    pub previous: u32,
    pub reference_count: u32,
    pub scope: u32,
    pub scope_previous: u32,
    pub visible: u32,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Scope {
    pub kind: ScopeKind,
    pub node: u32,
    pub parent: u32,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Reference {
    pub branch: u32,
    pub context: Context,
    pub flags: ReferenceFlags,
    pub name: Span,
    pub name_hash: u32,
    pub node: u32,
    pub resolution: Resolution,
    pub scope: u32,
}

#[derive(Debug)]
pub struct Semantic {
    bindings: BoundedVec<Binding>,
    branches: BoundedVec<Branch>,
    exports: BoundedVec<Span>,
    facts: Facts,
    heads: BoundedVec<u32>,
    offsets: BoundedVec<u32>,
    ordered: BoundedVec<u32>,
    references: BoundedVec<Reference>,
    scope_heads: BoundedVec<u32>,
    scopes: BoundedVec<Scope>,
    stars: BoundedVec<u32>,
}

#[derive(Clone, Copy, Debug)]
pub struct SemanticInput<'file> {
    pub builtins: &'file [&'file [u8]],
    pub raw: &'file [PythonKind],
    pub scopes: &'file Tables,
    pub source: &'file [u8],
    pub tokens: &'file [Token],
    pub tree: &'file Tree<PythonKind>,
    pub version: PythonVersion,
}

struct Builder<'run> {
    annotation_root: u32,
    annotation_scratch: &'run mut AnnotationScratch,
    branch_depth: u32,
    branch_stack: [u32; BRANCH_DEPTH_MAX as usize],
    decorator_run: [bool; DECORATOR_DEPTH_MAX as usize],
    depth: u32,
    future_annotations: bool,
    outcome: Structure,
    overload_pending: bool,
    raw: &'run [PythonKind],
    semantic: &'run mut Semantic,
    source: &'run [u8],
    stack: [u32; SCOPE_DEPTH_MAX as usize],
    tokens: &'run [Token],
    tree: &'run Tree<PythonKind>,
    tree_depth: u32,
    type_checking_block: u32,
    type_definition_root: u32,
}

impl BindingKind {
    pub const fn binds(self) -> bool {
        !matches!(
            self,
            Self::Annotation | Self::Deletion | Self::Global | Self::Nonlocal
        )
    }

    pub const fn answers(self) -> bool {
        !matches!(self, Self::Annotation | Self::Global | Self::Nonlocal)
    }

    pub const fn defines(self) -> bool {
        matches!(self, Self::ClassDefinition | Self::FunctionDefinition)
    }

    pub const fn imports(self) -> bool {
        matches!(
            self,
            Self::FutureImport
                | Self::Import
                | Self::ImportFrom
                | Self::ImportStar
                | Self::SubmoduleImport
        )
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct Reach {
    classed: bool,
    deferred: bool,
    offset: u32,
    whole: bool,
}

impl Reach {
    const EVERY: Self = Self {
        classed: false,
        deferred: true,
        offset: 0,
        whole: true,
    };
}

fn reachable(held: Binding, reach: Reach) -> bool {
    if held.kind == BindingKind::Deletion && !reach.deferred {
        return held.visible <= reach.offset;
    }

    if reach.whole || reach.deferred {
        return true;
    }

    !(reach.classed || held.kind.defines() || held.kind == BindingKind::Assignment)
        || held.visible <= reach.offset
}

impl Semantic {
    pub fn reserve(
        binding_count_max: u32,
        reference_count_max: u32,
        export_count_max: u32,
    ) -> Self {
        assert!(binding_count_max > 0);
        assert!(reference_count_max > 0);
        assert!(export_count_max > 0);

        assert!(!crate::allocation::is_frozen());

        let mut heads = BoundedVec::reserve(bucket_count_of(binding_count_max));

        for _ in 0..heads.capacity() {
            heads.push_assert(NONE);
        }

        let mut scope_heads = BoundedVec::reserve(bucket_count_of(binding_count_max));

        for _ in 0..scope_heads.capacity() {
            scope_heads.push_assert(NONE);
        }

        Self {
            bindings: BoundedVec::reserve(binding_count_max),
            branches: BoundedVec::reserve(binding_count_max),
            exports: BoundedVec::reserve(export_count_max),
            facts: Facts::reserve(binding_count_max),
            heads,
            offsets: BoundedVec::reserve(bucket_count_of(binding_count_max)),
            ordered: BoundedVec::reserve(binding_count_max),
            references: BoundedVec::reserve(reference_count_max),
            scope_heads,
            scopes: BoundedVec::reserve(binding_count_max),
            stars: BoundedVec::reserve(binding_count_max),
        }
    }

    pub fn bindings(&self) -> &[Binding] {
        &self.bindings
    }

    pub fn bindings_of(&self, scope: u32) -> impl Iterator<Item = u32> {
        (0..self.bindings.count())
            .filter(move |index| self.bindings[*index as usize].scope == scope)
    }

    pub fn binding_newest(&self, source: &[u8], scope: u32, name: &[u8]) -> u32 {
        let hash = name_hash(name);
        let mut index = self.heads[self.bucket_of(scope, hash)];

        for _ in 0..=self.bindings.count() {
            if index == NONE {
                break;
            }

            let held = self.bindings[index as usize];

            if held.scope == scope && held.name_hash == hash && &source[held.name.range()] == name {
                return index;
            }

            index = held.scope_previous;
        }

        NONE
    }

    pub fn branches(&self) -> &[Branch] {
        &self.branches
    }

    pub fn branch_within(&self, branch: u32, ancestor: u32) -> bool {
        assert!(branch == NONE || branch < self.branches.count());
        assert!(ancestor == NONE || ancestor < self.branches.count());

        let mut held = branch;

        for _ in 0..=BRANCH_DEPTH_MAX {
            if held == ancestor {
                return true;
            }

            if held == NONE {
                return false;
            }

            held = self.branches[held as usize].parent;
        }

        false
    }

    pub fn chain_used(&self, source: &[u8], binding: u32) -> bool {
        let Some(held) = self.get(binding) else {
            return false;
        };

        let name = &source[held.name.range()];
        let mut index = self.binding_newest(source, held.scope, name);

        for _ in 0..=self.bindings.count() {
            if index == NONE {
                break;
            }

            if self.is_used(index) {
                return true;
            }

            index = self.bindings[index as usize].previous;
        }

        false
    }

    pub fn is_used(&self, binding: u32) -> bool {
        self.get(binding)
            .is_some_and(|held| held.reference_count > 0)
    }

    pub fn same_branch(&self, left: u32, right: u32) -> bool {
        assert!(left < self.branches.count());
        assert!(right < self.branches.count());

        left == right
    }

    pub fn build(
        &mut self,
        input: &SemanticInput<'_>,
        scratch: &mut AnnotationScratch,
    ) -> Structure {
        let &SemanticInput {
            builtins,
            raw,
            scopes,
            source,
            tokens,
            tree,
            version,
        } = input;

        self.clear();
        self.seed(scopes);

        self.branches.push_assert(Branch {
            node: NONE,
            parent: NONE,
        });

        let mut builder = Builder {
            annotation_root: NONE,
            annotation_scratch: scratch,
            branch_depth: 0,
            branch_stack: [0; BRANCH_DEPTH_MAX as usize],
            decorator_run: [false; DECORATOR_DEPTH_MAX as usize],
            depth: 0,
            future_annotations: false,
            outcome: Structure::Complete,
            overload_pending: false,
            raw,
            semantic: self,
            source,
            stack: [0; SCOPE_DEPTH_MAX as usize],
            tokens,
            tree,
            tree_depth: 0,
            type_checking_block: NONE,
            type_definition_root: NONE,
        };

        builder.collect();

        let outcome = builder.outcome;

        self.resolve(source, builtins, version);

        outcome
    }

    fn seed(&mut self, scopes: &Tables) {
        for index in 0..scopes.scopes.count() {
            let held = scopes.scopes[index as usize];

            let pushed = self.scopes.push(Scope {
                kind: held.kind,
                node: held.node,
                parent: held.parent,
            });

            assert!(pushed || self.scopes.is_full());

            if pushed {
                self.remember_scope(index, held.node);
            }
        }
    }

    fn remember_scope(&mut self, index: u32, node: u32) {
        if index == 0 {
            return;
        }

        let mask = self.scope_heads.count() - 1;
        let mut bucket = scope_bucket_of(node) & mask;

        for _ in 0..=mask {
            let held = self.scope_heads[bucket as usize];

            if held == NONE {
                self.scope_heads[bucket as usize] = index;

                return;
            }

            if self.scopes[held as usize].node == node {
                return;
            }

            bucket = (bucket + 1) & mask;
        }
    }

    fn scope_of(&self, node: u32) -> u32 {
        let mask = self.scope_heads.count() - 1;
        let mut bucket = scope_bucket_of(node) & mask;

        for _ in 0..=mask {
            let held = self.scope_heads[bucket as usize];

            if held == NONE {
                return NONE;
            }

            if self.scopes[held as usize].node == node {
                return held;
            }

            bucket = (bucket + 1) & mask;
        }

        NONE
    }

    pub fn scopes(&self) -> &[Scope] {
        &self.scopes
    }

    pub fn clear(&mut self) {
        for index in 0..self.heads.count() {
            self.heads[index as usize] = NONE;
        }

        for index in 0..self.scope_heads.count() {
            self.scope_heads[index as usize] = NONE;
        }

        self.bindings.clear();
        self.branches.clear();
        self.exports.clear();
        self.facts.clear();
        self.offsets.clear();
        self.ordered.clear();
        self.references.clear();
        self.scopes.clear();
        self.stars.clear();

        assert_eq!(self.count(), 0);
    }

    pub fn count(&self) -> u32 {
        self.bindings.count()
    }

    pub fn facts(&self) -> &[Fact] {
        self.facts.as_slice()
    }

    pub fn exports(&self) -> impl Iterator<Item = Span> {
        self.exports.iter().copied()
    }

    pub fn get(&self, index: u32) -> Option<&Binding> {
        if index == NONE {
            return None;
        }

        self.bindings.get(index as usize)
    }

    pub fn matches(
        &self,
        source: &[u8],
        view: View<'_>,
        module: &[u8],
        member: &[u8],
        out: &mut BoundedVec<Span>,
    ) -> bool {
        assert!(!member.is_empty());
        assert!(!module.is_empty());

        let qualified = self.qualified_name_of(source, view, out);
        let count = out.count();

        if count == 0 {
            return false;
        }

        let head = (count - 1) as usize;

        if &source[out[head].range()] != member {
            return false;
        }

        let segments = &out[..head];

        match qualified {
            Qualified::Builtin => segments.is_empty() && module == b"builtins",
            Qualified::Resolved => {
                Self::path_is(source, segments, module)
                    || module == b"typing" && Self::path_is(source, segments, b"typing_extensions")
            }
            Qualified::Local(_) | Qualified::Relative(_) | Qualified::Unresolved => false,
        }
    }

    fn path_is(source: &[u8], segments: &[Span], path: &[u8]) -> bool {
        assert!(segments.len() <= ATTRIBUTE_DEPTH_MAX as usize);

        let mut rest = path;

        for (index, span) in segments.iter().enumerate() {
            if index > 0 {
                let Some(tail) = rest.strip_prefix(b".") else {
                    return false;
                };

                rest = tail;
            }

            let Some(tail) = rest.strip_prefix(&source[span.range()]) else {
                return false;
            };

            rest = tail;
        }

        rest.is_empty()
    }

    pub fn qualified_name_of(
        &self,
        source: &[u8],
        view: View<'_>,
        out: &mut BoundedVec<Span>,
    ) -> Qualified {
        out.clear();

        let mut chain = [Span::EMPTY; ATTRIBUTE_DEPTH_MAX as usize];
        let mut depth = 0;
        let mut held = view;

        while held.kind() == PythonKind::Attribute {
            if depth == ATTRIBUTE_DEPTH_MAX {
                return Qualified::Unresolved;
            }

            let mut found = None;

            for position in held.positions_of(PythonKind::Identifier) {
                found = Some(position);
            }

            let Some(position) = found else {
                return Qualified::Unresolved;
            };

            chain[depth as usize] = held.token_at(position).span();
            depth += 1;

            let Some(next) = held.child_first() else {
                return Qualified::Unresolved;
            };

            held = next;
        }

        if held.kind() != PythonKind::Name {
            return Qualified::Unresolved;
        }

        let reference = self.reference_at(held.index());

        if reference == NONE {
            return Qualified::Unresolved;
        }

        let resolution = self.references[reference as usize].resolution;
        let outcome = self.head_of(source, held, resolution, out);

        if outcome == Qualified::Unresolved {
            out.clear();

            return outcome;
        }

        for index in (0..depth).rev() {
            if !out.push(chain[index as usize]) {
                out.clear();

                return Qualified::Unresolved;
            }
        }

        outcome
    }

    fn head_of(
        &self,
        source: &[u8],
        head: View<'_>,
        resolution: Resolution,
        out: &mut BoundedVec<Span>,
    ) -> Qualified {
        let binding = match resolution {
            Resolution::Builtin => {
                if out.push(head.span()) {
                    return Qualified::Builtin;
                }

                return Qualified::Unresolved;
            }
            Resolution::Bound(index) => index,
            Resolution::Maybe | Resolution::Unresolved => return Qualified::Unresolved,
        };

        let bound = self.bindings[binding as usize];

        if !bound.kind.imports() {
            if out.push(head.span()) {
                return Qualified::Local(binding);
            }

            return Qualified::Unresolved;
        }

        let alias = head.at(bound.node);

        if matches!(
            bound.kind,
            BindingKind::Import | BindingKind::SubmoduleImport
        ) {
            let Some(cast) = alias.as_alias() else {
                return Qualified::Unresolved;
            };

            if !cast.name_segments(out) {
                return Qualified::Unresolved;
            }

            if cast.asname_token().is_none() {
                out.truncate(1);
            }

            return Qualified::Resolved;
        }

        Self::remote_of(source, alias, out)
    }

    fn remote_of(source: &[u8], alias: View<'_>, out: &mut BoundedVec<Span>) -> Qualified {
        let Some(statement) = alias.parent() else {
            return Qualified::Unresolved;
        };

        let Some(cast) = statement.as_import() else {
            return Qualified::Unresolved;
        };

        if !cast.module_segments(out) {
            return Qualified::Unresolved;
        }

        let Some(position) = alias.positions_of(PythonKind::Identifier).next() else {
            return Qualified::Unresolved;
        };

        if !out.push(alias.token_at(position).span()) {
            return Qualified::Unresolved;
        }

        assert!(!source.is_empty());

        let level = cast.level();

        if level > 0 {
            return Qualified::Relative(level);
        }

        Qualified::Resolved
    }

    pub fn reference_at(&self, node: u32) -> u32 {
        let mut low = 0;
        let mut high = self.references.count();

        while low < high {
            let middle = low + (high - low) / 2;
            let held = self.references[middle as usize].node;

            if held < node {
                low = middle + 1;
            } else {
                high = middle;
            }
        }

        if low < self.references.count() && self.references[low as usize].node == node {
            return low;
        }

        NONE
    }

    pub fn references(&self) -> &[Reference] {
        &self.references
    }

    pub fn references_of(&self, binding: u32) -> impl Iterator<Item = u32> {
        (0..self.references.count()).filter(move |index| {
            self.references[*index as usize].resolution == Resolution::Bound(binding)
        })
    }

    pub fn star_in(&self, scope: u32) -> bool {
        self.stars.contains(&scope)
    }

    fn resolve(&mut self, source: &[u8], builtins: &[&[u8]], version: PythonVersion) {
        debug_assert!(
            self.references
                .iter()
                .zip(self.references.iter().skip(1))
                .all(|(left, right)| left.node <= right.node),
            "`reference_at` binary-searches the table, so the walk must push it in order"
        );

        self.order_bindings();

        for index in 0..self.references.count() {
            let held = self.references[index as usize];
            let resolution = self.resolution_of(source, &held, builtins, version);

            self.references[index as usize].resolution = resolution;

            if let Resolution::Bound(binding) = resolution {
                self.bindings[binding as usize].reference_count += 1;
            }
        }

        self.mark_exports(source);
    }

    fn mark_exports(&mut self, source: &[u8]) {
        if self.exports.count() == 0 {
            return;
        }

        for index in 0..self.bindings.count() {
            let held = self.bindings[index as usize];

            if held.scope != 0 {
                continue;
            }

            let name = &source[held.name.range()];

            let exported = self
                .exports
                .iter()
                .any(|span| &source[span.range()] == name);

            self.bindings[index as usize].flags.export_explicit = exported;
        }
    }

    fn node_at(&self, index: u32) -> u32 {
        self.bindings[index as usize].node
    }

    fn order_bindings(&mut self) {
        self.offsets.clear();
        self.ordered.clear();

        for _ in 0..self.offsets.capacity() {
            self.offsets.push_assert(0);
        }

        for index in 0..self.bindings.count() {
            let held = self.bindings[index as usize];
            let bucket = self.bucket_of(held.scope, held.name_hash);

            self.offsets[bucket] += 1;
        }

        let mut running = 0;

        for bucket in 0..self.offsets.count() {
            let count = self.offsets[bucket as usize];

            self.offsets[bucket as usize] = running;
            running += count;
        }

        for _ in 0..self.bindings.count() {
            self.ordered.push_assert(NONE);
        }

        for index in 0..self.bindings.count() {
            let held = self.bindings[index as usize];
            let bucket = self.bucket_of(held.scope, held.name_hash);
            let slot = self.offsets[bucket] as usize;

            self.ordered[slot] = index;
            self.offsets[bucket] += 1;
        }

        self.order_repair();
    }

    fn order_repair(&mut self) {
        for bucket in 0..self.offsets.count() {
            let end = self.offsets[bucket as usize] as usize;

            let start = if bucket == 0 {
                0
            } else {
                self.offsets[bucket as usize - 1] as usize
            };

            for right in start + 1..end {
                let moved = self.ordered[right];
                let node = self.node_at(moved);
                let mut left = right;

                while left > start && self.node_at(self.ordered[left - 1]) > node {
                    self.ordered[left] = self.ordered[left - 1];
                    left -= 1;
                }

                self.ordered[left] = moved;
            }
        }
    }

    fn resolution_of(
        &self,
        source: &[u8],
        reference: &Reference,
        builtins: &[&[u8]],
        version: PythonVersion,
    ) -> Resolution {
        let name = &source[reference.name.range()];
        let hash = name_hash(name);
        let start = self.redirect_of(source, reference, name, hash);

        let redirected = start != reference.scope;
        let mut scope = start;
        let mut steps = 0;
        let mut maybe = false;
        let mut deferred = redirected;

        while scope != NONE && steps <= SCOPE_DEPTH_MAX {
            let held = self.scopes[scope as usize];
            let visible = scope == start || held.kind != ScopeKind::Class;

            if visible {
                let immediate = reference.flags.annotation && !reference.flags.deferred;

                let positional = (scope == start || immediate)
                    && held.kind != ScopeKind::Comprehension
                    && !reference.flags.deferred
                    && !redirected;

                let reach = Reach {
                    classed: held.kind == ScopeKind::Class,
                    deferred,
                    offset: reference.name.offset,
                    whole: !positional,
                };

                let bounded = if positional {
                    self.binding_before(source, scope, name, hash, reference.node, reach)
                } else {
                    self.binding_at(source, scope, name, hash, reach)
                };

                if bounded != NONE {
                    return Resolution::Bound(bounded);
                }
            }

            maybe = maybe || self.star_in(scope);
            deferred = deferred || matches!(held.kind, ScopeKind::Function | ScopeKind::Lambda);
            scope = held.parent;
            steps += 1;
        }

        if builtins.contains(&name) || stdlib::is_builtin(name, version) {
            return Resolution::Builtin;
        }

        if maybe {
            return Resolution::Maybe;
        }

        Resolution::Unresolved
    }

    fn redirect_of(&self, source: &[u8], reference: &Reference, name: &[u8], hash: u32) -> u32 {
        let declared = self.declaration_in(source, reference.scope, name, hash);

        let Some(kind) = declared else {
            return reference.scope;
        };

        if kind == BindingKind::Global {
            return 0;
        }

        let mut scope = self.scopes[reference.scope as usize].parent;
        let mut steps = 0;

        while scope != NONE && steps <= SCOPE_DEPTH_MAX {
            let held = self.scopes[scope as usize];

            if held.kind == ScopeKind::Function
                && self.binding_at(source, scope, name, hash, Reach::EVERY) != NONE
            {
                return scope;
            }

            scope = held.parent;
            steps += 1;
        }

        reference.scope
    }

    fn declaration_in(
        &self,
        source: &[u8],
        scope: u32,
        name: &[u8],
        hash: u32,
    ) -> Option<BindingKind> {
        let mut index = self.heads[self.bucket_of(scope, hash)];

        for _ in 0..=self.bindings.count() {
            if index == NONE {
                break;
            }

            let held = self.bindings[index as usize];

            if held.scope == scope && held.name_hash == hash && &source[held.name.range()] == name {
                return held.declared;
            }

            index = held.scope_previous;
        }

        None
    }

    fn binding_at(&self, source: &[u8], scope: u32, name: &[u8], hash: u32, reach: Reach) -> u32 {
        let mut index = self.heads[self.bucket_of(scope, hash)];

        for _ in 0..=self.bindings.count() {
            if index == NONE {
                break;
            }

            let held = self.bindings[index as usize];

            if held.scope == scope
                && held.name_hash == hash
                && held.kind.answers()
                && reachable(held, reach)
                && &source[held.name.range()] == name
            {
                return index;
            }

            index = held.scope_previous;
        }

        NONE
    }

    fn binding_before(
        &self,
        source: &[u8],
        scope: u32,
        name: &[u8],
        hash: u32,
        node: u32,
        reach: Reach,
    ) -> u32 {
        if self.offsets.count() == 0 {
            return self.binding_before_chained(source, scope, name, hash, node, reach);
        }

        let bucket = self.bucket_of(scope, hash);
        let end = self.offsets[bucket] as usize;

        let start = if bucket == 0 {
            0
        } else {
            self.offsets[bucket - 1] as usize
        };

        let mut low = start;
        let mut high = end;

        while low < high {
            let middle = low + (high - low) / 2;

            if self.node_at(self.ordered[middle]) <= node {
                low = middle + 1;
            } else {
                high = middle;
            }
        }

        let mut position = low;

        while position > start {
            position -= 1;

            let index = self.ordered[position];
            let held = self.bindings[index as usize];

            let eligible = held.scope == scope
                && held.name_hash == hash
                && reachable(held, reach)
                && held.kind.answers();

            if eligible && &source[held.name.range()] == name {
                return index;
            }
        }

        NONE
    }

    fn binding_before_chained(
        &self,
        source: &[u8],
        scope: u32,
        name: &[u8],
        hash: u32,
        node: u32,
        reach: Reach,
    ) -> u32 {
        let mut index = self.heads[self.bucket_of(scope, hash)];

        for _ in 0..=self.bindings.count() {
            if index == NONE {
                break;
            }

            let held = self.bindings[index as usize];

            let eligible = held.scope == scope
                && held.node <= node
                && held.name_hash == hash
                && reachable(held, reach)
                && held.kind.answers();

            if eligible && &source[held.name.range()] == name {
                return index;
            }

            index = held.scope_previous;
        }

        NONE
    }

    fn push_binding(&mut self, binding: Binding) -> bool {
        let index = self.bindings.count();
        let bucket = self.bucket_of(binding.scope, binding.name_hash);
        let mut held = binding;

        held.scope_previous = self.heads[bucket];

        held.declared = if held.previous == NONE {
            None
        } else {
            self.bindings[held.previous as usize].declared
        };

        if held.declared.is_none()
            && matches!(held.kind, BindingKind::Global | BindingKind::Nonlocal)
        {
            held.declared = Some(held.kind);
        }

        if !self.bindings.push(held) {
            return false;
        }

        if held.previous != NONE {
            let earlier = held.previous as usize;

            self.bindings[earlier].flags.shadowed =
                self.bindings[earlier].flags.shadowed || held.kind.binds();
            self.bindings[earlier].flags.deleted =
                self.bindings[earlier].flags.deleted || held.kind == BindingKind::Deletion;
        }

        self.heads[bucket] = index;

        true
    }

    fn bucket_of(&self, scope: u32, hash: u32) -> usize {
        let mixed = hash ^ scope.wrapping_mul(2_654_435_761);

        (mixed & (self.heads.count() - 1)) as usize
    }

    fn push_reference(&mut self, reference: Reference) -> bool {
        self.references.push(reference)
    }
}

impl<'run> Builder<'run> {
    fn collect(&mut self) {
        if self.tree.count() == 0 {
            return;
        }

        self.branch_stack[0] = 0;
        self.branch_depth = 1;
        self.stack[0] = 0;
        self.depth = 1;

        for step in walk(self.tree) {
            match step {
                Step::Enter(node) => {
                    self.overload_pending = self.tree_depth < DECORATOR_DEPTH_MAX
                        && self.decorator_run[self.tree_depth as usize];

                    self.decorator_note(node);
                    self.enter(node);

                    self.tree_depth += 1;

                    if self.tree_depth < DECORATOR_DEPTH_MAX {
                        self.decorator_run[self.tree_depth as usize] = false;
                    }
                }
                Step::Leave(node) => {
                    assert!(self.tree_depth > 0);

                    self.tree_depth -= 1;
                    self.leave(node);
                }
            }
        }
    }

    fn decorator_note(&mut self, node: u32) {
        if self.tree_depth >= DECORATOR_DEPTH_MAX {
            return;
        }

        let slot = self.tree_depth as usize;

        if self.kind_of(node) != PythonKind::Decorator {
            self.decorator_run[slot] = false;

            return;
        }

        let span = self.tree.at(node).span(self.tokens);
        let named = self.source[span.range()].ends_with(b"overload");

        self.decorator_run[slot] = self.decorator_run[slot] || named;
    }

    fn branch(&self) -> u32 {
        assert!(self.branch_depth > 0);
        assert!(self.branch_depth <= BRANCH_DEPTH_MAX);

        self.branch_stack[self.branch_depth as usize - 1]
    }

    fn scope(&self) -> u32 {
        assert!(self.depth > 0);

        self.stack[self.depth as usize - 1]
    }

    fn reading_scope(&self, node: u32) -> u32 {
        let scope = self.scope();
        let held = self.semantic.scopes[scope as usize];

        if matches!(held.kind, ScopeKind::Type | ScopeKind::TypeAlias) || held.parent == NONE {
            return scope;
        }

        if !self.reads_outside(node) {
            return scope;
        }

        held.parent
    }

    fn reads_outside(&self, node: u32) -> bool {
        let mut previous = NONE;
        let mut held = node;

        for _ in 0..self.tree.count() {
            let parent = self.tree.at(held).parent;

            if parent == NONE {
                return false;
            }

            let kind = self.kind_of(parent);

            if !Self::opens_a_scope(kind) {
                previous = held;
                held = parent;

                continue;
            }

            if matches!(kind, PythonKind::AsyncFunctionDef | PythonKind::FunctionDef) {
                return self.kind_of(held) != PythonKind::Block;
            }

            if !matches!(
                kind,
                PythonKind::DictComp
                    | PythonKind::GeneratorExp
                    | PythonKind::ListComp
                    | PythonKind::SetComp
            ) {
                return false;
            }

            return self.kind_of(held) == PythonKind::Comprehension
                && self.first_clause(parent) == held
                && self.iterable_of(held) == previous;
        }

        false
    }

    fn first_clause(&self, node: u32) -> u32 {
        match self.view(node).child_first_of(PythonKind::Comprehension) {
            None => NONE,
            Some(held) => held.index(),
        }
    }

    fn iterable_of(&self, node: u32) -> u32 {
        let held = self.tree.at(node).child_first;

        if held == NONE {
            return NONE;
        }

        self.tree.at(held).sibling_next
    }

    fn view(&self, node: u32) -> View<'run> {
        View::new(self.tree, self.tokens, self.raw, node)
    }

    fn kind_of(&self, node: u32) -> PythonKind {
        self.tree.at(node).kind
    }

    fn name_of(&self, node: u32) -> Span {
        self.view(node).span()
    }

    fn text_of(&self, name: Span) -> &'run [u8] {
        &self.source[name.range()]
    }

    fn scope_at(&self, node: u32) -> u32 {
        self.semantic.scope_of(node)
    }

    fn opens_a_scope(kind: PythonKind) -> bool {
        matches!(
            kind,
            PythonKind::AsyncFunctionDef
                | PythonKind::ClassDef
                | PythonKind::DictComp
                | PythonKind::FunctionDef
                | PythonKind::GeneratorExp
                | PythonKind::Lambda
                | PythonKind::ListComp
                | PythonKind::SetComp
                | PythonKind::TypeAlias
        )
    }

    fn enter(&mut self, node: u32) {
        let kind = self.kind_of(node);

        if self.opens_a_branch(node, kind) {
            self.branch_open(node);
        }

        if self.type_checking_block == NONE && self.guards_type_checking(node, kind) {
            self.type_checking_block = node;
        }

        if self.annotation_root == NONE && self.annotates(node) {
            self.annotation_root = node;
        }

        if self.type_definition_root == NONE && self.defines_a_type(node, kind) {
            self.type_definition_root = node;
        }

        if self.type_root() != NONE && kind == PythonKind::Constant {
            self.annotation_string(node);
        }

        self.statement(node, kind);

        let parameters = self.type_params_of(node, kind);

        if parameters != NONE {
            self.open(parameters);
            self.type_parameters(node);
        }

        if Self::opens_a_scope(kind) && kind != PythonKind::ClassDef {
            self.open(node);
            self.opened(node, kind);
        }

        if self.bodies_a_class(node, kind) {
            let held = self.tree.at(node).parent;

            self.open(held);
            self.opened(held, PythonKind::ClassDef);
        }
    }

    fn bodies_a_class(&self, node: u32, kind: PythonKind) -> bool {
        if kind != PythonKind::Block {
            return false;
        }

        let parent = self.tree.at(node).parent;

        parent != NONE && self.kind_of(parent) == PythonKind::ClassDef
    }

    fn type_params_of(&self, node: u32, kind: PythonKind) -> u32 {
        if !matches!(
            kind,
            PythonKind::AsyncFunctionDef
                | PythonKind::ClassDef
                | PythonKind::FunctionDef
                | PythonKind::TypeAlias
        ) {
            return NONE;
        }

        match self.view(node).child_first_of(PythonKind::TypeParams) {
            None => NONE,
            Some(held) => held.index(),
        }
    }

    fn leave(&mut self, node: u32) {
        let kind = self.kind_of(node);

        if kind == PythonKind::ExceptHandler {
            self.unhandled(node);
        }

        if self.annotation_root == node {
            self.annotation_root = NONE;
        }

        if self.type_checking_block == node {
            self.type_checking_block = NONE;
        }

        if self.type_definition_root == node {
            self.type_definition_root = NONE;
        }

        if self.opens_a_branch(node, kind) && self.branch_depth > 1 {
            let top = self.branch();

            if self.semantic.branches[top as usize].node == node {
                self.branch_depth -= 1;
            }
        }

        if Self::opens_a_scope(kind) && kind != PythonKind::ClassDef && self.depth > 1 {
            self.depth -= 1;
        }

        if self.bodies_a_class(node, kind) && self.depth > 1 {
            self.depth -= 1;
        }

        if self.type_params_of(node, kind) != NONE && self.depth > 1 {
            self.depth -= 1;
        }
    }

    fn opens_a_branch(&self, node: u32, kind: PythonKind) -> bool {
        if matches!(
            kind,
            PythonKind::ExceptHandler
                | PythonKind::FinallyClause
                | PythonKind::MatchCase
                | PythonKind::Try
                | PythonKind::TryStar
        ) {
            return true;
        }

        if !matches!(kind, PythonKind::Block | PythonKind::ElseClause) {
            return false;
        }

        let parent = self.tree.at(node).parent;

        if parent == NONE {
            return false;
        }

        self.kind_of(parent) == PythonKind::If
    }

    fn branch_open(&mut self, node: u32) {
        let parent = self.branch();

        if self.branch_depth >= BRANCH_DEPTH_MAX {
            self.outcome = Structure::TooDeep;

            return;
        }

        let index = self.semantic.branches.count();

        if !self.semantic.branches.push(Branch { node, parent }) {
            self.outcome = Structure::TooDeep;

            return;
        }

        self.branch_stack[self.branch_depth as usize] = index;
        self.branch_depth += 1;
    }

    fn guards_type_checking(&self, node: u32, kind: PythonKind) -> bool {
        if kind != PythonKind::Block {
            return false;
        }

        let parent = self.tree.at(node).parent;

        if parent == NONE || self.kind_of(parent) != PythonKind::If {
            return false;
        }

        let Some(condition) = self.view(parent).child_first() else {
            return false;
        };

        if condition.kind() == PythonKind::Attribute {
            return condition.text(self.source).ends_with(b".TYPE_CHECKING");
        }

        if condition.kind() == PythonKind::Name {
            return condition.text(self.source) == b"TYPE_CHECKING";
        }

        false
    }

    fn annotation_string(&mut self, node: u32) {
        let held = self.view(node);

        let Some(constant) = held.as_constant() else {
            return;
        };

        if held.positions().count() != 1 {
            return;
        }

        let Some(position) = held.positions().next() else {
            return;
        };

        if held.token_kind(position) != PythonKind::StringPlain {
            return;
        }

        let token = held.token_at(position).span();
        let content = constant.content_span(self.source);

        if content.offset <= token.offset {
            return;
        }

        let prefix = &self.source[token.offset as usize..content.offset as usize];

        let lettered = prefix
            .iter()
            .any(|byte| matches!(byte.to_ascii_lowercase(), b'b' | b'f' | b't' | b'u'));

        if lettered {
            return;
        }

        let text = &self.source[content.range()];

        if text
            .iter()
            .any(|byte| matches!(*byte, b'\n' | b'\r' | b'\\'))
        {
            return;
        }

        if self.inside_literal(node) {
            return;
        }

        self.annotation_names(node, content);
    }

    fn inside_literal(&self, node: u32) -> bool {
        let mut held = self.tree.at(node).parent;

        for _ in 0..=ATTRIBUTE_DEPTH_MAX {
            if held == NONE {
                return false;
            }

            if self.kind_of(held) == PythonKind::Subscript {
                let target = self.view(held).child_first();

                if target.is_some_and(|found| found.text(self.source).ends_with(b"Literal")) {
                    return true;
                }
            }

            if held == self.type_root() {
                return false;
            }

            held = self.tree.at(held).parent;
        }

        false
    }

    fn annotation_names(&mut self, node: u32, content: Span) {
        let mut found = [Span::EMPTY; ANNOTATION_DEPTH_MAX as usize];
        let count = self.annotation_parse(content, &mut found);
        let branch = self.branch();
        let scope = self.reading_scope(node);
        let type_checking = self.type_checking_block != NONE;

        for index in 0..count {
            let name = found[index as usize];

            let recorded = self.semantic.push_reference(Reference {
                branch,
                context: Context::Load,
                flags: ReferenceFlags {
                    annotation: true,
                    deferred: true,
                    type_checking,
                    typing_only: true,
                },
                name,
                name_hash: name_hash(self.text_of(name)),
                node,
                resolution: Resolution::Unresolved,
                scope,
            });

            if !recorded && self.outcome == Structure::Complete {
                self.outcome = Structure::Truncated;
            }
        }
    }

    fn annotation_parse(&mut self, content: Span, found: &mut [Span]) -> u32 {
        assert_eq!(found.len(), ANNOTATION_DEPTH_MAX as usize);

        let text = &self.source[content.range()];
        let scratch = &mut *self.annotation_scratch;

        scratch.clear();

        if PYTHON.lex(text, &mut scratch.lexed) != Lex::Complete {
            return 0;
        }

        if !classify(
            text,
            scratch.lexed.as_slice(),
            &mut scratch.tokens,
            &mut scratch.raw,
        ) {
            return 0;
        }

        let built = parse::build(
            text,
            scratch.tokens.as_slice(),
            &scratch.raw,
            &mut scratch.events,
            &mut scratch.tree,
        );

        if built != Structure::Complete || !scratch.tree.errors().is_empty() {
            return 0;
        }

        let tokens = scratch.tokens.as_slice();
        let mut count = 0;

        for step in walk(&scratch.tree) {
            let Step::Enter(inner) = step else {
                continue;
            };

            if scratch.tree.at(inner).kind != PythonKind::Name {
                continue;
            }

            if count == ANNOTATION_DEPTH_MAX {
                return 0;
            }

            let span = scratch.tree.at(inner).span(tokens);

            found[count as usize] = Span {
                length: span.length,
                offset: span.offset + content.offset,
            };

            count += 1;
        }

        count
    }

    fn type_root(&self) -> u32 {
        if self.annotation_root != NONE {
            return self.annotation_root;
        }

        self.type_definition_root
    }

    fn defines_a_type(&self, node: u32, kind: PythonKind) -> bool {
        if kind == PythonKind::Arguments {
            return false;
        }

        let parent = self.tree.at(node).parent;

        if parent == NONE {
            return false;
        }

        let held = self.view(parent);

        if self.kind_of(parent) == PythonKind::AnnAssign {
            if held.child_at(2).map(View::index) != Some(node) {
                return false;
            }

            let Some(annotation) = held.child_at(1) else {
                return false;
            };

            if !annotation.text(self.source).ends_with(b"TypeAlias") {
                return false;
            }

            return self.names(annotation, b"typing", b"TypeAlias");
        }

        if self.kind_of(parent) != PythonKind::Call {
            return false;
        }

        if held.child_at(1).map(View::index) != Some(node) {
            return false;
        }

        let Some(callee) = held.child_first() else {
            return false;
        };

        if !callee.text(self.source).ends_with(b"cast") {
            return false;
        }

        self.names(callee, b"typing", b"cast")
    }

    fn names(&self, view: View<'run>, module: &[u8], member: &[u8]) -> bool {
        if view.kind() == PythonKind::Name {
            if view.text(self.source) != member {
                return false;
            }

            return self.imported_from(self.bound(view.span()), module);
        }

        if view.kind() != PythonKind::Attribute {
            return false;
        }

        let mut found = None;

        for position in view.positions_of(PythonKind::Identifier) {
            found = Some(position);
        }

        let Some(position) = found else {
            return false;
        };

        if self.text_of(view.token_at(position).span()) != member {
            return false;
        }

        let Some(head) = view.child_first() else {
            return false;
        };

        if head.kind() != PythonKind::Name {
            return false;
        }

        self.module_named(self.bound(head.span()), module)
    }

    fn bound(&self, name: Span) -> u32 {
        let reference = Reference {
            branch: 0,
            context: Context::Load,
            flags: ReferenceFlags::default(),
            name,
            name_hash: name_hash(self.text_of(name)),
            node: NONE,
            resolution: Resolution::Unresolved,
            scope: self.scope(),
        };

        let resolution =
            self.semantic
                .resolution_of(self.source, &reference, &[], PythonVersion::Py38);

        match resolution {
            Resolution::Bound(index) => index,
            Resolution::Builtin | Resolution::Maybe | Resolution::Unresolved => NONE,
        }
    }

    fn imported_from(&self, binding: u32, module: &[u8]) -> bool {
        let Some(held) = self.semantic.get(binding) else {
            return false;
        };

        if held.kind != BindingKind::ImportFrom {
            return false;
        }

        let Some(statement) = self.view(held.node).parent() else {
            return false;
        };

        let span = Self::between(
            statement,
            PythonKind::FromKeyword,
            PythonKind::ImportKeyword,
        );

        Self::forwards(self.text_of(span), module)
    }

    fn module_named(&self, binding: u32, module: &[u8]) -> bool {
        let Some(held) = self.semantic.get(binding) else {
            return false;
        };

        if !matches!(
            held.kind,
            BindingKind::Import | BindingKind::SubmoduleImport
        ) {
            return false;
        }

        let span = Self::upto(self.view(held.node), PythonKind::AsKeyword);

        Self::forwards(self.text_of(span), module)
    }

    fn forwards(text: &[u8], module: &[u8]) -> bool {
        text == module || module == b"typing" && text == b"typing_extensions"
    }

    fn annotates(&self, node: u32) -> bool {
        let parent = self.tree.at(node).parent;

        if parent == NONE {
            return false;
        }

        let held = self.view(parent);
        let kind = self.kind_of(parent);

        if kind == PythonKind::AnnAssign {
            return held.child_at(1).map(View::index) == Some(node);
        }

        if kind == PythonKind::Arg {
            return held.child_first().map(View::index) == Some(node);
        }

        if !matches!(kind, PythonKind::AsyncFunctionDef | PythonKind::FunctionDef) {
            return false;
        }

        held.as_function()
            .and_then(FunctionDef::returns_annotation)
            .map(View::index)
            == Some(node)
    }

    fn open(&mut self, node: u32) {
        let mut scope = self.scope_at(node);

        if scope == NONE {
            scope = self.append(node);
        }

        if scope == NONE || self.depth >= SCOPE_DEPTH_MAX {
            self.outcome = Structure::TooDeep;

            return;
        }

        self.semantic.scopes[scope as usize].parent = self.scope();
        self.stack[self.depth as usize] = scope;
        self.depth += 1;
    }

    fn append(&mut self, node: u32) -> u32 {
        let index = self.semantic.scopes.count();
        let parent = self.scope();

        let pushed = self.semantic.scopes.push(Scope {
            kind: ScopeKind::Comprehension,
            node,
            parent,
        });

        if !pushed {
            return NONE;
        }

        self.semantic.remember_scope(index, node);

        index
    }

    fn opened(&mut self, node: u32, kind: PythonKind) {
        if matches!(
            kind,
            PythonKind::AsyncFunctionDef | PythonKind::FunctionDef | PythonKind::Lambda
        ) {
            self.parameters(node);
        }
    }

    fn statement(&mut self, node: u32, kind: PythonKind) {
        match Some(kind) {
            Some(PythonKind::AsyncFunctionDef | PythonKind::FunctionDef) => {
                self.definition(node, BindingKind::FunctionDefinition);
            }
            Some(PythonKind::ClassDef) => self.definition(node, BindingKind::ClassDefinition),
            Some(PythonKind::ExceptHandler) => self.handler(node),
            Some(PythonKind::Global) => self.declaration(node, BindingKind::Global),
            Some(PythonKind::Import) => self.import(node, BindingKind::Import),
            Some(PythonKind::ImportFrom) => self.import_from(node),
            Some(PythonKind::MatchAs | PythonKind::MatchMapping | PythonKind::MatchStar) => {
                self.capture(node);
            }
            Some(PythonKind::Name) => self.name(node),
            Some(PythonKind::Nonlocal) => self.declaration(node, BindingKind::Nonlocal),
            Some(PythonKind::TypeAlias) => self.alias(node),
            Some(PythonKind::Assign | PythonKind::AugAssign) => self.exported(node),
            Some(_) | None => {}
        }
    }

    fn definition(&mut self, node: u32, kind: BindingKind) {
        let held = self.view(node);

        let Some(position) = held.token_first(PythonKind::Identifier) else {
            return;
        };

        let name = held.token_at(position).span();

        let flags = BindingFlags {
            overload: self.overloaded(node),
            ..BindingFlags::default()
        };

        self.record_with(kind, name, node, flags);
    }

    fn overloaded(&self, node: u32) -> bool {
        if self.tree_depth < DECORATOR_DEPTH_MAX {
            return self.overload_pending;
        }

        let parent = self.tree.at(node).parent;

        if parent == NONE {
            return false;
        }

        let mut child = self.tree.at(parent).child_first;
        let mut decorated = false;
        let mut steps = 0;

        while child != NONE && child != node && steps <= self.tree.count() {
            let held = self.tree.at(child);

            if held.kind == PythonKind::Decorator {
                let span = held.span(self.tokens);

                decorated = decorated || self.source[span.range()].ends_with(b"overload");
            } else {
                decorated = false;
            }

            child = held.sibling_next;
            steps += 1;
        }

        decorated
    }

    fn parameters(&mut self, node: u32) {
        let view = self.view(node);
        let held = view.child_first_of(PythonKind::Arguments).unwrap_or(view);

        for child in held.children() {
            if child.kind() != PythonKind::Arg {
                continue;
            }

            let Some(position) = child.token_first(PythonKind::Identifier) else {
                continue;
            };

            let name = child.token_at(position).span();

            self.record(BindingKind::Parameter, name, child.index());
        }
    }

    fn type_parameters(&mut self, node: u32) {
        let held = self.view(node);

        let Some(parameters) = held.child_first_of(PythonKind::TypeParams) else {
            return;
        };

        for child in parameters.children() {
            if !matches!(
                child.kind(),
                PythonKind::ParamSpec | PythonKind::TypeVar | PythonKind::TypeVarTuple
            ) {
                continue;
            }

            let Some(position) = child.token_first(PythonKind::Identifier) else {
                continue;
            };

            let name = child.token_at(position).span();

            self.record(BindingKind::TypeParameter, name, child.index());
        }
    }

    fn handler(&mut self, node: u32) {
        let Some(name) = self.handler_name(node) else {
            return;
        };

        self.record(BindingKind::ExceptVariable, name, node);
    }

    fn handler_name(&self, node: u32) -> Option<Span> {
        let held = self.view(node);
        let mut found = None;

        for position in held.positions_of(PythonKind::Identifier) {
            found = Some(position);
        }

        Some(held.token_at(found?).span())
    }

    fn unhandled(&mut self, node: u32) {
        let Some(name) = self.handler_name(node) else {
            return;
        };

        let after = self.after_of(node);

        self.record_visible(
            BindingKind::Deletion,
            name,
            after,
            BindingFlags::default(),
            self.view(node).span().end(),
        );
    }

    fn after_of(&self, node: u32) -> u32 {
        let mut found = node;

        for step in walk_from(self.tree, node) {
            if let Step::Enter(held) = step {
                found = found.max(held);
            }
        }

        found + 1
    }

    fn declaration(&mut self, node: u32, kind: BindingKind) {
        let held = self.view(node);

        for position in held.positions_of(PythonKind::Identifier) {
            let name = held.token_at(position).span();

            self.record(kind, name, node);
        }
    }

    fn import(&mut self, node: u32, kind: BindingKind) {
        let held = self.view(node);

        for child in held.children_of(PythonKind::Alias) {
            let Some(name) = Self::alias_name(child) else {
                continue;
            };

            let module = Self::upto(child, PythonKind::AsKeyword);

            let flags = BindingFlags {
                alias: self.reexports(child, module),
                ..BindingFlags::default()
            };

            let bound = if Self::submodule(child) {
                BindingKind::SubmoduleImport
            } else {
                kind
            };

            self.record_with(bound, name, child.index(), flags);
            self.fact(FactKind::ImportNamed, name, module, module);
        }
    }

    fn upto(held: View<'run>, close: PythonKind) -> Span {
        let mut first = Span::EMPTY;
        let mut last = Span::EMPTY;

        for position in held.positions() {
            if held.token_kind(position) == close {
                break;
            }

            let span = held.token_at(position).span();

            if first == Span::EMPTY {
                first = span;
            }

            last = span;
        }

        if first == Span::EMPTY {
            return Span::EMPTY;
        }

        Span {
            length: last.end() - first.offset,
            offset: first.offset,
        }
    }

    fn between(held: View<'run>, open: PythonKind, close: PythonKind) -> Span {
        let mut started = false;
        let mut first = Span::EMPTY;
        let mut last = Span::EMPTY;

        for position in held.positions() {
            let kind = held.token_kind(position);

            if kind == close {
                break;
            }

            if kind == open {
                started = true;

                continue;
            }

            if !started {
                continue;
            }

            let span = held.token_at(position).span();

            if first == Span::EMPTY {
                first = span;
            }

            last = span;
        }

        if first == Span::EMPTY {
            return Span::EMPTY;
        }

        Span {
            length: last.end() - first.offset,
            offset: first.offset,
        }
    }

    fn fact(&mut self, kind: FactKind, local: Span, remote: Span, specifier: Span) {
        let binding = self.binding_at(local);

        let recorded = self.semantic.facts.push(Fact {
            binding,
            kind,
            local,
            remote,
            specifier,
        });

        if !recorded && self.outcome == Structure::Complete {
            self.outcome = Structure::Truncated;
        }
    }

    fn binding_at(&self, local: Span) -> u32 {
        if local == Span::EMPTY {
            return NONE;
        }

        self.semantic
            .binding_newest(self.source, 0, self.text_of(local))
    }

    fn import_from(&mut self, node: u32) {
        let held = self.view(node);
        let future = self.future_import(node);
        let module = Self::between(held, PythonKind::FromKeyword, PythonKind::ImportKeyword);

        for child in held.children_of(PythonKind::Alias) {
            if child.text(self.source) == b"*" {
                let name = child.span();
                let scope = self.scope();

                self.record(BindingKind::ImportStar, name, child.index());
                self.fact(FactKind::ImportNamespace, Span::EMPTY, Span::EMPTY, module);

                if !self.semantic.stars.contains(&scope) {
                    let _ = self.semantic.stars.push(scope);
                }

                continue;
            }

            let Some(name) = Self::alias_name(child) else {
                continue;
            };

            let kind = if future {
                BindingKind::FutureImport
            } else {
                BindingKind::ImportFrom
            };

            if future && self.text_of(name) == b"annotations" {
                self.future_annotations = true;
            }

            let remote = Self::upto(child, PythonKind::AsKeyword);

            let flags = BindingFlags {
                alias: self.reexports(child, remote),
                ..BindingFlags::default()
            };

            self.record_with(kind, name, child.index(), flags);
            self.fact(FactKind::ImportNamed, name, remote, module);
        }
    }

    fn future_import(&self, node: u32) -> bool {
        let held = self.view(node);

        let Some(position) = held.positions_of(PythonKind::Identifier).next() else {
            return false;
        };

        held.token_at(position).text(self.source) == b"__future__"
    }

    fn submodule(alias: View<'run>) -> bool {
        if alias.as_alias().and_then(Alias::asname_token).is_some() {
            return false;
        }

        alias.positions_of(PythonKind::Identifier).count() > 1
    }

    fn reexports(&self, alias: View<'run>, remote: Span) -> bool {
        let Some(position) = alias.as_alias().and_then(Alias::asname_token) else {
            return false;
        };

        if remote == Span::EMPTY {
            return false;
        }

        self.text_of(alias.token_at(position).span()) == self.text_of(remote)
    }

    fn alias_name(alias: View<'run>) -> Option<Span> {
        let mut found = None;

        for position in alias.positions_of(PythonKind::Identifier) {
            if found.is_none() {
                found = Some(alias.token_at(position).span());
            }
        }

        let Some(position) = alias.as_alias().and_then(|held| held.asname_token()) else {
            return found;
        };

        Some(alias.token_at(position).span())
    }

    fn capture(&mut self, node: u32) {
        let held = self.view(node);

        for position in held.positions_of(PythonKind::Identifier) {
            let name = held.token_at(position).span();

            self.record(BindingKind::MatchCapture, name, node);
        }
    }

    fn alias(&mut self, node: u32) {
        let held = self.view(node);

        let Some(name) = held.child_first_of(PythonKind::Name) else {
            return;
        };

        self.record(BindingKind::TypeAlias, name.span(), node);
    }

    fn name(&mut self, node: u32) {
        let name = self.name_of(node);
        let (context, kind, unpacked) = self.context_of(node);

        match kind {
            None => {}
            Some(BindingKind::Deletion) if self.conditional(node) => {}
            Some(held) => {
                let flags = BindingFlags {
                    unpacked: unpacked && held == BindingKind::Assignment,
                    ..BindingFlags::default()
                };

                self.record_with(held, name, node, flags);
            }
        }

        if context == Context::Store && kind.is_some() {
            return;
        }

        let annotation = self.annotation_root != NONE;
        let type_checking = self.type_checking_block != NONE;
        let branch = self.branch();
        let scope = self.reading_scope(node);

        let recorded = self.semantic.push_reference(Reference {
            branch,
            context,
            flags: ReferenceFlags {
                annotation,
                deferred: annotation && self.future_annotations,
                type_checking,
                typing_only: annotation && self.future_annotations || type_checking,
            },
            name,
            name_hash: name_hash(self.text_of(name)),
            node,
            resolution: Resolution::Unresolved,
            scope,
        });

        if !recorded && self.outcome == Structure::Complete {
            self.outcome = Structure::Truncated;
        }
    }

    fn conditional(&self, node: u32) -> bool {
        let mut held = self.tree.at(node).parent;

        for _ in 0..=self.tree.count() {
            if held == NONE {
                return false;
            }

            let kind = self.kind_of(held);

            if matches!(
                kind,
                PythonKind::AsyncFunctionDef
                    | PythonKind::ClassDef
                    | PythonKind::FunctionDef
                    | PythonKind::Lambda
                    | PythonKind::Module
            ) {
                return false;
            }

            if matches!(
                kind,
                PythonKind::ExceptHandler
                    | PythonKind::If
                    | PythonKind::MatchCase
                    | PythonKind::While
            ) {
                return true;
            }

            let parent = self.tree.at(held).parent;

            if kind == PythonKind::ElseClause
                && parent != NONE
                && self.kind_of(parent) == PythonKind::Try
            {
                return true;
            }

            held = parent;
        }

        false
    }

    fn context_of(&self, node: u32) -> (Context, Option<BindingKind>, bool) {
        let mut child = node;
        let mut parent = self.tree.at(child).parent;
        let mut steps = 0;
        let mut unpacked = false;

        while parent != NONE && steps <= SCOPE_DEPTH_MAX {
            let kind = self.kind_of(parent);

            if !matches!(
                kind,
                PythonKind::List
                    | PythonKind::Parenthesized
                    | PythonKind::Starred
                    | PythonKind::Tuple
            ) {
                let (context, binding) = self.context_in(parent, child, kind);

                return (context, binding, unpacked);
            }

            unpacked = unpacked || matches!(kind, PythonKind::List | PythonKind::Tuple);
            child = parent;
            parent = self.tree.at(parent).parent;
            steps += 1;
        }

        (Context::Load, None, unpacked)
    }

    fn context_in(
        &self,
        parent: u32,
        child: u32,
        kind: PythonKind,
    ) -> (Context, Option<BindingKind>) {
        let held = self.view(parent);

        let position = held
            .children()
            .position(|found| found.index() == child)
            .unwrap_or(usize::MAX);

        let count = held.children().count();

        if kind == PythonKind::Delete {
            return (Context::Delete, Some(BindingKind::Deletion));
        }

        if kind == PythonKind::Assign && position + 1 < count {
            return (Context::Store, Some(BindingKind::Assignment));
        }

        if kind == PythonKind::AnnAssign && position == 0 {
            let annotated = count < 3;

            let target = if annotated {
                BindingKind::Annotation
            } else {
                BindingKind::Assignment
            };

            return (Context::Store, Some(target));
        }

        if position > 0 && kind == PythonKind::WithItem {
            return (Context::Store, Some(BindingKind::WithVariable));
        }

        if position != 0 {
            return (Context::Load, None);
        }

        if kind == PythonKind::AugAssign {
            return (Context::Store, Some(BindingKind::Augmented));
        }

        if matches!(kind, PythonKind::AsyncFor | PythonKind::For) {
            return (Context::Store, Some(BindingKind::LoopVariable));
        }

        if kind == PythonKind::Comprehension {
            return (Context::Store, Some(BindingKind::ComprehensionVariable));
        }

        if kind == PythonKind::NamedExpr {
            return (Context::Store, Some(BindingKind::Named));
        }

        (Context::Load, None)
    }

    fn exported(&mut self, node: u32) {
        if self.scope() != 0 {
            return;
        }

        let held = self.view(node);

        let Some(target) = held.child_first() else {
            return;
        };

        if target.kind() != PythonKind::Name || target.text(self.source) != b"__all__" {
            return;
        }

        for child in held.children() {
            if !matches!(child.kind(), PythonKind::List | PythonKind::Tuple) {
                continue;
            }

            for item in child.children() {
                if item.kind() != PythonKind::Constant {
                    continue;
                }

                let Some(constant) = item.as_constant() else {
                    continue;
                };

                let span = constant.content_span(self.source);

                if !self.semantic.exports.push(span) && self.outcome == Structure::Complete {
                    self.outcome = Structure::Truncated;
                }

                self.fact(FactKind::ExportNamed, span, span, Span::EMPTY);
            }
        }
    }

    fn visible_from(&self, node: u32) -> u32 {
        if node == NONE || node >= self.tree.count() {
            return 0;
        }

        let mut held = node;

        for _ in 0..=self.tree.count() {
            let parent = self.tree.at(held).parent;

            if parent == NONE
                || parent >= self.tree.count()
                || matches!(self.kind_of(parent), PythonKind::Block | PythonKind::Module)
            {
                break;
            }

            if self.view(parent).child_first_of(PythonKind::Block).is_some() {
                break;
            }

            held = parent;
        }

        let deferred = matches!(
            self.kind_of(held),
            PythonKind::AsyncFunctionDef | PythonKind::FunctionDef
        );

        match self.view(held).child_first_of(PythonKind::Block) {
            Some(body) if deferred => body.span().offset,
            Some(_) | None => self.view(held).span().end(),
        }
    }

    fn record(&mut self, kind: BindingKind, name: Span, node: u32) {
        self.record_with(kind, name, node, BindingFlags::default());
    }

    fn record_with(&mut self, kind: BindingKind, name: Span, node: u32, flags: BindingFlags) {
        self.record_visible(kind, name, node, flags, self.visible_from(node));
    }

    fn record_visible(
        &mut self,
        kind: BindingKind,
        name: Span,
        node: u32,
        flags: BindingFlags,
        visible: u32,
    ) {
        let scope = self.target_of(kind, name);
        let previous = self.previous_of(scope, name);

        let held = BindingFlags {
            private: self.text_of(name).first() == Some(&b'_'),
            type_checking: self.type_checking_block != NONE,
            ..flags
        };

        let recorded = self.semantic.push_binding(Binding {
            branch: self.branch(),
            declared: None,
            flags: held,
            kind,
            name,
            name_hash: name_hash(self.text_of(name)),
            node,
            previous,
            reference_count: 0,
            scope,
            scope_previous: NONE,
            visible,
        });

        if !recorded && self.outcome == Structure::Complete {
            self.outcome = Structure::Truncated;
        }
    }

    fn target_of(&self, kind: BindingKind, name: Span) -> u32 {
        if matches!(kind, BindingKind::Global | BindingKind::Nonlocal) {
            return self.scope();
        }

        let held = if kind == BindingKind::Named {
            self.containing()
        } else {
            self.scope()
        };

        let reference = Reference {
            branch: self.branch(),
            context: Context::Store,
            flags: ReferenceFlags::default(),
            name,
            name_hash: name_hash(self.text_of(name)),
            node: 0,
            resolution: Resolution::Unresolved,
            scope: held,
        };

        self.semantic.redirect_of(
            self.source,
            &reference,
            self.text_of(name),
            reference.name_hash,
        )
    }

    fn containing(&self) -> u32 {
        let mut scope = self.scope();
        let mut steps = 0;

        while steps <= SCOPE_DEPTH_MAX {
            let held = self.semantic.scopes[scope as usize];

            if held.kind != ScopeKind::Comprehension || held.parent == NONE {
                return scope;
            }

            scope = held.parent;
            steps += 1;
        }

        scope
    }

    fn previous_of(&self, scope: u32, name: Span) -> u32 {
        let text = self.text_of(name);
        let hash = name_hash(text);
        let mut index = self.semantic.heads[self.semantic.bucket_of(scope, hash)];

        for _ in 0..=self.semantic.bindings.count() {
            if index == NONE {
                break;
            }

            let held = self.semantic.bindings[index as usize];

            if held.scope == scope && held.name_hash == hash && self.text_of(held.name) == text {
                return index;
            }

            index = held.scope_previous;
        }

        NONE
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::syntax::python::bind::{Outcome as BindOutcome, bind};

    const BUILTINS: [&[u8]; 6] = [b"len", b"list", b"print", b"str", b"sum", b"tuple"];

    struct Fixture {
        raw: BoundedVec<PythonKind>,
        semantic: Semantic,
        source: Vec<u8>,
        tokens: Tokens,
        tree: Tree<PythonKind>,
    }

    impl Fixture {
        fn of(source: &[u8]) -> Self {
            let mut lexed = Tokens::reserve(1 << 14);
            let mut tokens = Tokens::reserve(1 << 14);
            let mut raw = BoundedVec::reserve(1 << 14);
            let mut events = Events::reserve(1 << 16);
            let mut tree = Tree::<PythonKind>::reserve(1 << 14, 1 << 8);
            let mut tables = Tables::reserve(1 << 8, 1 << 10, 1 << 12, 1 << 10);
            let mut semantic = Semantic::reserve(1 << 10, 1 << 12, 1 << 8);
            let mut scratch = AnnotationScratch::reserve(1 << 8, 1 << 8);

            PYTHON.lex(source, &mut lexed);

            assert!(classify(source, lexed.as_slice(), &mut tokens, &mut raw));

            parse::build(source, tokens.as_slice(), &raw, &mut events, &mut tree);

            assert_eq!(
                bind(source, tokens.as_slice(), &raw, &tree, &mut tables),
                BindOutcome::Complete
            );

            assert_eq!(
                semantic.build(
                    &SemanticInput {
                        builtins: &BUILTINS,
                        raw: &raw,
                        scopes: &tables,
                        source,
                        tokens: tokens.as_slice(),
                        tree: &tree,
                        version: PythonVersion::Py310,
                    },
                    &mut scratch,
                ),
                Structure::Complete
            );

            Self {
                raw,
                semantic,
                source: source.to_vec(),
                tokens,
                tree,
            }
        }

        fn last_read(&self, name: &str) -> View<'_> {
            let held = View::new(&self.tree, self.tokens.as_slice(), &self.raw, 0);
            let mut found = None;

            for node in 0..self.tree.count() {
                let kind = self.tree.at(node).kind;

                if !matches!(kind, PythonKind::Attribute | PythonKind::Name) {
                    continue;
                }

                if held.at(node).text(&self.source) == name.as_bytes() {
                    found = Some(node);
                }
            }

            held.at(found.expect("the fixture holds the read"))
        }

        fn segments(&self, out: &BoundedVec<Span>) -> Vec<String> {
            out.iter().map(|span| self.text_of(*span)).collect()
        }

        fn outcome(source: &[u8]) -> Structure {
            let mut lexed = Tokens::reserve(1 << 16);
            let mut tokens = Tokens::reserve(1 << 16);
            let mut raw = BoundedVec::reserve(1 << 16);
            let mut events = Events::reserve(1 << 18);
            let mut tree = Tree::<PythonKind>::reserve(1 << 16, 1 << 11);
            let mut tables = Tables::reserve(1 << 10, 1 << 12, 1 << 14, 1 << 12);
            let mut semantic = Semantic::reserve(1 << 12, 1 << 14, 1 << 8);
            let mut scratch = AnnotationScratch::reserve(1 << 8, 1 << 8);

            PYTHON.lex(source, &mut lexed);

            assert!(classify(source, lexed.as_slice(), &mut tokens, &mut raw));

            parse::build(source, tokens.as_slice(), &raw, &mut events, &mut tree);

            assert_eq!(
                bind(source, tokens.as_slice(), &raw, &tree, &mut tables),
                BindOutcome::Complete
            );

            semantic.build(
                &SemanticInput {
                    builtins: &BUILTINS,
                    raw: &raw,
                    scopes: &tables,
                    source,
                    tokens: tokens.as_slice(),
                    tree: &tree,
                    version: PythonVersion::Py310,
                },
                &mut scratch,
            )
        }

        fn read(path: &str) -> Self {
            let root = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"))
                .join("tests/fixtures/python-semantic")
                .join(path);

            Self::of(&std::fs::read(root).expect("the fixture is readable"))
        }

        fn text_of(&self, name: Span) -> String {
            String::from_utf8_lossy(&self.source[name.range()]).into_owned()
        }

        fn facts(&self) -> Vec<String> {
            self.semantic
                .facts()
                .iter()
                .map(|fact| {
                    format!(
                        "{} {} {} {}",
                        fact.kind.name(),
                        self.field_of(fact.local),
                        self.field_of(fact.remote),
                        self.field_of(fact.specifier),
                    )
                })
                .collect()
        }

        fn field_of(&self, name: Span) -> String {
            if name == Span::EMPTY {
                return ".".to_owned();
            }

            self.text_of(name)
        }

        fn bindings(&self) -> Vec<String> {
            self.semantic
                .bindings()
                .iter()
                .map(|held| {
                    format!(
                        "{:?} {} scope {}",
                        held.kind,
                        self.text_of(held.name),
                        held.scope
                    )
                })
                .collect()
        }

        fn resolutions(&self) -> Vec<String> {
            self.semantic
                .references()
                .iter()
                .map(|held| {
                    let bound = match held.resolution {
                        Resolution::Bound(index) => format!("Bound({index})"),
                        Resolution::Builtin => "Builtin".to_owned(),
                        Resolution::Maybe => "Maybe".to_owned(),
                        Resolution::Unresolved => "Unresolved".to_owned(),
                    };

                    format!("{} {bound} scope {}", self.text_of(held.name), held.scope)
                })
                .collect()
        }

        fn exports(&self) -> Vec<String> {
            self.semantic
                .exports()
                .map(|span| String::from_utf8_lossy(&self.source[span.range()]).into_owned())
                .collect()
        }
    }

    const BUILTINS_BINDINGS: [&str; 2] = ["Assignment value scope 0", "Assignment text scope 0"];

    const BUILTINS_RESOLUTIONS: [&str; 7] = [
        "len Builtin scope 0",
        "str Builtin scope 0",
        "value Bound(0) scope 0",
        "print Builtin scope 0",
        "text Bound(1) scope 0",
        "missing Unresolved scope 0",
        "value Bound(0) scope 0",
    ];

    const CLASS_SCOPE_BINDINGS: [&str; 6] = [
        "Assignment field scope 0",
        "ClassDefinition Holder scope 0",
        "Assignment field scope 1",
        "Assignment other scope 1",
        "FunctionDefinition read scope 1",
        "Parameter self scope 2",
    ];

    const CLASS_SCOPE_RESOLUTIONS: [&str; 2] = ["field Bound(2) scope 1", "field Bound(0) scope 2"];

    const COMPREHENSIONS_BINDINGS: [&str; 7] = [
        "Assignment items scope 0",
        "Assignment squares scope 0",
        "ComprehensionVariable item scope 2",
        "Assignment pairs scope 0",
        "ComprehensionVariable key scope 3",
        "Assignment total scope 0",
        "ComprehensionVariable value scope 1",
    ];

    const COMPREHENSIONS_RESOLUTIONS: [&str; 10] = [
        "item Bound(2) scope 2",
        "item Bound(2) scope 2",
        "items Bound(0) scope 0",
        "key Bound(4) scope 3",
        "key Bound(4) scope 3",
        "items Bound(0) scope 0",
        "sum Builtin scope 0",
        "value Bound(6) scope 1",
        "items Bound(0) scope 0",
        "item Unresolved scope 0",
    ];

    const CONDITIONAL_BINDINGS: [&str; 3] = [
        "Import os scope 0",
        "Assignment handle scope 0",
        "Assignment handle scope 0",
    ];

    const CONDITIONAL_RESOLUTIONS: [&str; 3] = [
        "os Bound(0) scope 0",
        "print Builtin scope 0",
        "handle Bound(2) scope 0",
    ];

    const DELETION_BINDINGS: [&str; 8] = [
        "Assignment value scope 0",
        "Deletion value scope 0",
        "FunctionDefinition run scope 0",
        "Assignment held scope 1",
        "Deletion held scope 1",
        "FunctionDefinition caught scope 0",
        "ExceptVariable error scope 2",
        "Deletion error scope 2",
    ];

    const DELETION_RESOLUTIONS: [&str; 9] = [
        "value Bound(0) scope 0",
        "print Builtin scope 0",
        "value Bound(1) scope 0",
        "held Bound(3) scope 1",
        "held Bound(4) scope 1",
        "ValueError Builtin scope 2",
        "print Builtin scope 2",
        "error Bound(6) scope 2",
        "error Bound(7) scope 2",
    ];

    const EXPORTS_BINDINGS: [&str; 5] = [
        "Assignment __all__ scope 0",
        "Augmented __all__ scope 0",
        "FunctionDefinition first scope 0",
        "FunctionDefinition second scope 0",
        "FunctionDefinition third scope 0",
    ];

    const EXPORTS_RESOLUTIONS: [&str; 0] = [];

    const FACTS_BINDINGS: [&str; 8] = [
        "Import os scope 0",
        "Import held scope 0",
        "ImportFrom OrderedDict scope 0",
        "ImportFrom queue scope 0",
        "ImportFrom sibling scope 0",
        "ImportFrom thing scope 0",
        "ImportStar * scope 0",
        "Assignment __all__ scope 0",
    ];

    const FACTS_RESOLUTIONS: [&str; 0] = [];

    const GLOBALS_BINDINGS: [&str; 5] = [
        "Assignment counter scope 0",
        "FunctionDefinition bump scope 0",
        "Global counter scope 1",
        "Assignment counter scope 0",
        "FunctionDefinition read scope 0",
    ];

    const GLOBALS_RESOLUTIONS: [&str; 2] = ["counter Bound(3) scope 1", "counter Bound(3) scope 2"];

    const NONLOCAL_BINDINGS: [&str; 9] = [
        "FunctionDefinition outer scope 0",
        "Assignment held scope 1",
        "FunctionDefinition inner scope 1",
        "Nonlocal held scope 2",
        "Assignment held scope 1",
        "FunctionDefinition bare scope 0",
        "FunctionDefinition inner scope 3",
        "Nonlocal missing scope 4",
        "Assignment missing scope 4",
    ];

    const NONLOCAL_RESOLUTIONS: [&str; 3] = [
        "inner Bound(2) scope 1",
        "held Bound(4) scope 1",
        "inner Bound(6) scope 3",
    ];

    const PARAMETERS_BINDINGS: [&str; 9] = [
        "FunctionDefinition run scope 0",
        "Parameter first scope 1",
        "Parameter second scope 1",
        "Parameter rest scope 1",
        "Parameter keyword scope 1",
        "Parameter extra scope 1",
        "Assignment lam scope 0",
        "Parameter left scope 2",
        "Parameter right scope 2",
    ];

    const PARAMETERS_RESOLUTIONS: [&str; 7] = [
        "first Bound(1) scope 1",
        "second Bound(2) scope 1",
        "rest Bound(3) scope 1",
        "keyword Bound(4) scope 1",
        "extra Bound(5) scope 1",
        "left Bound(7) scope 2",
        "right Bound(8) scope 2",
    ];

    const REDEFINITION_BINDINGS: [&str; 6] = [
        "Import os scope 0",
        "Import os scope 0",
        "Assignment value scope 0",
        "Assignment value scope 0",
        "FunctionDefinition run scope 0",
        "FunctionDefinition run scope 0",
    ];

    const REDEFINITION_RESOLUTIONS: [&str; 0] = [];

    const SHADOWING_BINDINGS: [&str; 5] = [
        "Assignment value scope 0",
        "FunctionDefinition outer scope 0",
        "Assignment value scope 1",
        "FunctionDefinition inner scope 1",
        "FunctionDefinition reader scope 0",
    ];

    const SHADOWING_RESOLUTIONS: [&str; 3] = [
        "value Bound(2) scope 2",
        "inner Bound(3) scope 1",
        "value Bound(0) scope 3",
    ];

    const STAR_BINDINGS: [&str; 1] = ["ImportStar * scope 0"];

    const STAR_RESOLUTIONS: [&str; 4] = [
        "print Builtin scope 0",
        "join Maybe scope 0",
        "print Builtin scope 0",
        "missing_name Maybe scope 0",
    ];

    const TYPE_PARAMS_BINDINGS: [&str; 9] = [
        "TypeAlias Alias scope 0",
        "TypeParameter T scope 1",
        "FunctionDefinition run scope 0",
        "TypeParameter T scope 3",
        "Parameter value scope 4",
        "ClassDefinition Holder scope 0",
        "TypeParameter T scope 5",
        "FunctionDefinition read scope 6",
        "Parameter self scope 7",
    ];

    const TYPE_PARAMS_RESOLUTIONS: [&str; 8] = [
        "Alias Bound(0) scope 2",
        "list Builtin scope 2",
        "T Bound(1) scope 2",
        "T Bound(3) scope 3",
        "T Bound(3) scope 3",
        "value Bound(4) scope 4",
        "T Bound(6) scope 6",
        "self Bound(8) scope 7",
    ];

    const UNUSED_BINDINGS: [&str; 5] = [
        "Import os scope 0",
        "Import system scope 0",
        "FunctionDefinition run scope 0",
        "Assignment held scope 1",
        "Assignment other scope 1",
    ];

    const UNUSED_RESOLUTIONS: [&str; 1] = ["other Bound(4) scope 1"];

    const WALRUS_BINDINGS: [&str; 6] = [
        "Assignment items scope 0",
        "Assignment found scope 0",
        "ComprehensionVariable value scope 2",
        "Named total scope 0",
        "FunctionDefinition run scope 0",
        "Named held scope 1",
    ];

    const WALRUS_RESOLUTIONS: [&str; 8] = [
        "total Bound(3) scope 2",
        "items Bound(0) scope 0",
        "value Bound(2) scope 2",
        "print Builtin scope 0",
        "total Bound(3) scope 0",
        "len Builtin scope 1",
        "items Bound(0) scope 1",
        "held Bound(5) scope 1",
    ];

    const FACTS_FACTS: [&str; 10] = [
        "ImportNamed os os os",
        "ImportNamed held os.path os.path",
        "ImportNamed OrderedDict OrderedDict collections",
        "ImportNamed queue deque collections",
        "ImportNamed sibling sibling .",
        "ImportNamed thing thing ..package.module",
        "ImportNamespace . . json",
        "ExportNamed os os .",
        "ExportNamed held held .",
        "ExportNamed thing thing .",
    ];

    fn rows(held: &[&str]) -> Vec<String> {
        held.iter().map(|row| (*row).to_owned()).collect()
    }

    #[test]
    fn a_load_without_a_binding_is_unresolved_or_a_builtin() {
        let fixture = Fixture::read("builtins.py");

        assert_eq!(fixture.bindings(), rows(&BUILTINS_BINDINGS));
        assert_eq!(fixture.resolutions(), rows(&BUILTINS_RESOLUTIONS));

        assert!(!fixture.semantic.star_in(0));
    }

    #[test]
    fn a_class_scope_is_invisible_to_a_function_inside_it() {
        let fixture = Fixture::read("class_scope.py");

        assert_eq!(fixture.bindings(), rows(&CLASS_SCOPE_BINDINGS));
        assert_eq!(fixture.resolutions(), rows(&CLASS_SCOPE_RESOLUTIONS));
    }

    #[test]
    fn a_comprehension_keeps_its_iteration_variable() {
        let fixture = Fixture::read("comprehensions.py");

        assert_eq!(fixture.bindings(), rows(&COMPREHENSIONS_BINDINGS));
        assert_eq!(fixture.resolutions(), rows(&COMPREHENSIONS_RESOLUTIONS));
    }

    #[test]
    fn a_conditional_binding_reads_as_the_last_one() {
        let fixture = Fixture::read("conditional.py");

        assert_eq!(fixture.bindings(), rows(&CONDITIONAL_BINDINGS));
        assert_eq!(fixture.resolutions(), rows(&CONDITIONAL_RESOLUTIONS));
    }

    #[test]
    fn a_deletion_binds_and_a_handler_name_is_gone_below_the_block_that_caught_it() {
        let fixture = Fixture::read("deletion.py");

        assert_eq!(fixture.bindings(), rows(&DELETION_BINDINGS));
        assert_eq!(fixture.resolutions(), rows(&DELETION_RESOLUTIONS));
    }

    #[test]
    fn an_all_assignment_records_its_exports() {
        let fixture = Fixture::read("exports.py");

        assert_eq!(fixture.bindings(), rows(&EXPORTS_BINDINGS));
        assert_eq!(fixture.resolutions(), rows(&EXPORTS_RESOLUTIONS));

        assert_eq!(fixture.exports(), vec!["first", "second", "third"]);
    }

    #[test]
    fn the_module_facts_name_every_import_form_and_every_export() {
        let fixture = Fixture::read("facts.py");

        assert_eq!(fixture.bindings(), rows(&FACTS_BINDINGS));
        assert_eq!(fixture.resolutions(), rows(&FACTS_RESOLUTIONS));

        assert_eq!(fixture.facts(), rows(&FACTS_FACTS));
    }

    #[test]
    fn a_global_declaration_redirects_to_the_module_scope() {
        let fixture = Fixture::read("globals.py");

        assert_eq!(fixture.bindings(), rows(&GLOBALS_BINDINGS));
        assert_eq!(fixture.resolutions(), rows(&GLOBALS_RESOLUTIONS));
    }

    #[test]
    fn a_nonlocal_declaration_redirects_to_the_enclosing_function() {
        let fixture = Fixture::read("nonlocal.py");

        assert_eq!(fixture.bindings(), rows(&NONLOCAL_BINDINGS));
        assert_eq!(fixture.resolutions(), rows(&NONLOCAL_RESOLUTIONS));
    }

    #[test]
    fn a_parameter_binds_in_the_scope_it_opens() {
        let fixture = Fixture::read("parameters.py");

        assert_eq!(fixture.bindings(), rows(&PARAMETERS_BINDINGS));
        assert_eq!(fixture.resolutions(), rows(&PARAMETERS_RESOLUTIONS));
    }

    #[test]
    fn a_redefinition_chains_to_the_binding_it_shadows() {
        let fixture = Fixture::read("redefinition.py");

        assert_eq!(fixture.bindings(), rows(&REDEFINITION_BINDINGS));
        assert_eq!(fixture.resolutions(), rows(&REDEFINITION_RESOLUTIONS));

        let previous: Vec<u32> = fixture
            .semantic
            .bindings()
            .iter()
            .map(|held| held.previous)
            .collect();

        assert_eq!(previous, vec![NONE, 0, NONE, 2, NONE, 4]);
    }

    #[test]
    fn a_load_walks_local_then_enclosing_then_module_then_builtins() {
        let fixture = Fixture::read("shadowing.py");

        assert_eq!(fixture.bindings(), rows(&SHADOWING_BINDINGS));
        assert_eq!(fixture.resolutions(), rows(&SHADOWING_RESOLUTIONS));
    }

    #[test]
    fn a_star_import_degrades_a_failed_load_to_maybe() {
        let fixture = Fixture::read("star.py");

        assert_eq!(fixture.bindings(), rows(&STAR_BINDINGS));
        assert_eq!(fixture.resolutions(), rows(&STAR_RESOLUTIONS));

        assert!(fixture.semantic.star_in(0));
    }

    #[test]
    fn a_type_parameter_binds_beside_its_definition() {
        let fixture = Fixture::read("type_params.py");

        assert_eq!(fixture.bindings(), rows(&TYPE_PARAMS_BINDINGS));
        assert_eq!(fixture.resolutions(), rows(&TYPE_PARAMS_RESOLUTIONS));
    }

    #[test]
    fn an_import_binds_its_alias_and_a_load_reads_it() {
        let fixture = Fixture::read("unused.py");

        assert_eq!(fixture.bindings(), rows(&UNUSED_BINDINGS));
        assert_eq!(fixture.resolutions(), rows(&UNUSED_RESOLUTIONS));

        assert_eq!(fixture.semantic.references_of(0).count(), 0);
        assert_eq!(fixture.semantic.references_of(4).count(), 1);
        assert_eq!(fixture.semantic.bindings_of(1).count(), 2);
    }

    #[test]
    fn a_walrus_inside_a_comprehension_binds_in_the_containing_scope() {
        let fixture = Fixture::read("walrus.py");

        assert_eq!(fixture.bindings(), rows(&WALRUS_BINDINGS));
        assert_eq!(fixture.resolutions(), rows(&WALRUS_RESOLUTIONS));
    }

    #[test]
    fn an_except_name_binds_the_handler_variable() {
        let fixture =
            Fixture::of(b"try:\n    pass\nexcept ValueError as error:\n    print(error)\n");

        assert_eq!(
            fixture.bindings(),
            rows(&["ExceptVariable error scope 0", "Deletion error scope 0"])
        );

        assert_eq!(
            fixture.resolutions(),
            rows(&[
                "ValueError Builtin scope 0",
                "print Builtin scope 0",
                "error Bound(0) scope 0",
            ])
        );
    }

    #[test]
    fn every_python_specifier_slices_back_to_the_text_the_source_wrote() {
        let fixture = Fixture::read("facts.py");
        let mut compared = 0;

        for fact in fixture.semantic.facts() {
            if fact.specifier == Span::EMPTY {
                continue;
            }

            let held = fixture.text_of(fact.specifier);

            assert_eq!(
                String::from_utf8_lossy(&fixture.source[fact.specifier.range()]),
                held,
                "the specifier does not slice back"
            );

            assert!(!held.is_empty());

            compared += 1;
        }

        assert!(compared > 5);
    }

    #[test]
    fn a_future_import_reads_as_its_own_kind() {
        let fixture = Fixture::of(b"from __future__ import annotations\n");

        assert_eq!(
            fixture.bindings(),
            rows(&["FutureImport annotations scope 0"])
        );
    }

    #[test]
    fn a_binding_in_an_if_body_and_one_after_it_sit_on_different_branches() {
        let fixture = Fixture::of(b"if value:\n    left = 1\nright = 2\n");
        let bindings = fixture.semantic.bindings();

        assert_eq!(bindings.len(), 2);
        assert_ne!(bindings[0].branch, bindings[1].branch);

        assert!(
            !fixture
                .semantic
                .same_branch(bindings[0].branch, bindings[1].branch)
        );

        assert!(fixture.semantic.branch_within(bindings[0].branch, 0));
    }

    #[test]
    fn a_loop_body_opens_no_branch_of_its_own() {
        let fixture = Fixture::of(b"for item in value:\n    left = 1\nright = 2\n");
        let bindings = fixture.semantic.bindings();

        let held = bindings
            .iter()
            .filter(|row| row.kind != BindingKind::LoopVariable)
            .map(|row| row.branch)
            .collect::<Vec<u32>>();

        assert_eq!(held, vec![0, 0]);
    }

    #[test]
    fn the_else_of_a_try_shares_the_arm_its_body_stands_on() {
        let source = b"try:\n    left = 1\nexcept Exception:\n    pass\nelse:\n    right = 2\n";
        let fixture = Fixture::of(source);
        let bindings = fixture.semantic.bindings();

        assert_eq!(bindings.len(), 2);

        assert!(
            fixture
                .semantic
                .same_branch(bindings[0].branch, bindings[1].branch)
        );
    }

    #[test]
    fn an_elif_body_is_its_own_branch() {
        let fixture = Fixture::of(b"if value:\n    held = 1\nelif other:\n    held = 2\n");
        let bindings = fixture.semantic.bindings();

        assert_eq!(bindings.len(), 2);

        assert!(
            !fixture
                .semantic
                .same_branch(bindings[0].branch, bindings[1].branch)
        );
    }

    #[test]
    fn two_bindings_in_one_block_share_a_branch() {
        let fixture = Fixture::of(b"if value:\n    left = 1\n    right = 2\n");
        let bindings = fixture.semantic.bindings();

        assert_eq!(bindings.len(), 2);
        assert_eq!(bindings[0].branch, bindings[1].branch);

        assert!(
            fixture
                .semantic
                .same_branch(bindings[0].branch, bindings[1].branch)
        );
    }

    #[test]
    fn a_branch_within_its_own_ancestor_reads_true() {
        let fixture = Fixture::of(b"if value:\n    if other:\n        held = 1\nlast = 2\n");
        let bindings = fixture.semantic.bindings();

        assert_eq!(bindings.len(), 2);

        let inner = bindings[0].branch;

        assert!(fixture.semantic.branch_within(inner, 0));
        assert!(fixture.semantic.branch_within(inner, inner));
        assert!(!fixture.semantic.branch_within(0, inner));
        assert_eq!(bindings[1].branch, 0);
    }

    #[test]
    fn an_import_as_itself_is_an_alias() {
        let fixture =
            Fixture::of(b"import os as os\nfrom held import name as name\nimport io as f\n");

        let bindings = fixture.semantic.bindings();

        assert_eq!(bindings.len(), 3);
        assert!(bindings[0].flags.alias);
        assert!(bindings[1].flags.alias);
        assert!(!bindings[2].flags.alias);
    }

    #[test]
    fn a_dotted_import_renamed_to_its_last_segment_is_not_an_alias() {
        let fixture = Fixture::of(b"import os.path as path\n");
        let bindings = fixture.semantic.bindings();

        assert_eq!(bindings.len(), 1);
        assert!(!bindings[0].flags.alias);
    }

    #[test]
    fn a_tuple_target_is_unpacked() {
        let fixture = Fixture::of(b"left, right = 1, 2\nheld = 3\n");
        let bindings = fixture.semantic.bindings();

        assert_eq!(bindings.len(), 3);
        assert!(bindings[0].flags.unpacked);
        assert!(bindings[1].flags.unpacked);
        assert!(!bindings[2].flags.unpacked);
    }

    #[test]
    fn an_overload_decorator_flags_the_definition() {
        let mut source = Vec::from(b"from typing import overload\n\n\n");

        source.extend_from_slice(b"@overload\ndef read(value): ...\n");
        source.extend_from_slice(b"def read(value): ...\n");

        let fixture = Fixture::of(&source);
        let bindings = fixture.semantic.bindings();

        let decorated = bindings
            .iter()
            .filter(|held| held.kind == BindingKind::FunctionDefinition)
            .map(|held| held.flags.overload)
            .collect::<Vec<bool>>();

        assert_eq!(decorated, vec![true, false]);
    }

    #[test]
    fn a_deletion_flags_the_binding_it_removes() {
        let fixture = Fixture::of(b"held = 1\ndel held\n");
        let bindings = fixture.semantic.bindings();

        assert_eq!(bindings.len(), 2);
        assert!(bindings[0].flags.deleted);
        assert!(!bindings[0].flags.shadowed);
    }

    #[test]
    fn a_redefinition_flags_the_binding_it_shadows() {
        let fixture = Fixture::of(b"held = 1\nheld = 2\n");
        let bindings = fixture.semantic.bindings();

        assert_eq!(bindings.len(), 2);
        assert!(bindings[0].flags.shadowed);
        assert!(!bindings[1].flags.shadowed);
    }

    #[test]
    fn a_name_in_dunder_all_is_an_explicit_export() {
        let fixture = Fixture::of(b"__all__ = [\"read\"]\n\n\ndef read(): ...\ndef write(): ...\n");
        let bindings = fixture.semantic.bindings();

        let exported = bindings
            .iter()
            .filter(|held| held.kind == BindingKind::FunctionDefinition)
            .map(|held| held.flags.export_explicit)
            .collect::<Vec<bool>>();

        assert_eq!(exported, vec![true, false]);
    }

    #[test]
    fn a_type_checking_block_flags_its_bindings_and_references() {
        let mut source = Vec::from(b"from typing import TYPE_CHECKING\n\n");

        source.extend_from_slice(b"if TYPE_CHECKING:\n    import os\n\n    held = os\n");

        let fixture = Fixture::of(&source);

        let guarded = fixture
            .semantic
            .bindings()
            .iter()
            .filter(|held| held.flags.type_checking)
            .count();

        assert_eq!(guarded, 2);

        let read = fixture
            .semantic
            .references()
            .iter()
            .find(|held| fixture.text_of(held.name) == "os")
            .copied()
            .expect("the assignment reads the guarded import");

        assert!(read.flags.type_checking);
        assert!(read.flags.typing_only);
    }

    #[test]
    fn a_future_annotations_import_makes_annotations_typing_only() {
        let source =
            b"from __future__ import annotations\n\nimport os\n\n\ndef read(value: os): ...\n";

        let fixture = Fixture::of(source);

        let annotated = fixture
            .semantic
            .references()
            .iter()
            .find(|held| fixture.text_of(held.name) == "os")
            .copied()
            .expect("the annotation reads the import");

        assert!(annotated.flags.annotation);
        assert!(annotated.flags.typing_only);
        assert!(!annotated.flags.type_checking);
    }

    #[test]
    fn a_reference_counts_toward_its_binding() {
        let fixture = Fixture::of(b"held = 1\nprint(held)\nprint(held)\n");
        let bindings = fixture.semantic.bindings();

        assert_eq!(bindings[0].reference_count, 2);
        assert!(fixture.semantic.is_used(0));
        assert!(fixture.semantic.chain_used(&fixture.source, 0));
    }

    #[test]
    fn the_branch_stack_overflow_reads_too_deep() {
        let links = BRANCH_DEPTH_MAX;
        let mut source = Vec::from(b"if value:\n    held = 1\n");

        for _ in 0..links {
            source.extend_from_slice(b"elif value:\n    held = 1\n");
        }

        assert!(links * 2 > BRANCH_DEPTH_MAX);
        assert_eq!(Fixture::outcome(&source), Structure::TooDeep);
    }

    #[test]
    fn an_elif_chain_inside_the_branch_bound_builds() {
        let links = BRANCH_DEPTH_MAX / 4;
        let mut source = Vec::from(b"if value:\n    held = 1\n");

        for _ in 0..links {
            source.extend_from_slice(b"elif value:\n    held = 1\n");
        }

        assert!(links * 2 + 1 < BRANCH_DEPTH_MAX);
        assert_eq!(Fixture::outcome(&source), Structure::Complete);
    }

    #[test]
    fn a_string_in_a_typing_cast_reads_the_import_it_names() {
        let mut source = Vec::from(b"from typing import cast\n");

        source.extend_from_slice(b"from decimal import Decimal\n\n");
        source.extend_from_slice(b"print(cast(\"Decimal\", value))\n");

        let fixture = Fixture::of(&source);

        let held = fixture
            .semantic
            .bindings()
            .iter()
            .find(|row| fixture.text_of(row.name) == "Decimal")
            .copied()
            .expect("the fixture imports the name");

        assert_eq!(held.reference_count, 1);
    }

    #[test]
    fn a_string_in_a_dotted_cast_reads_the_import_it_names() {
        let mut source = Vec::from(b"import typing\n");

        source.extend_from_slice(b"from decimal import Decimal\n\n");
        source.extend_from_slice(b"print(typing.cast(\"Decimal\", value))\n");

        let fixture = Fixture::of(&source);

        let held = fixture
            .semantic
            .bindings()
            .iter()
            .find(|row| fixture.text_of(row.name) == "Decimal")
            .copied()
            .expect("the fixture imports the name");

        assert_eq!(held.reference_count, 1);
    }

    #[test]
    fn a_string_in_a_type_alias_value_reads_the_import_it_names() {
        let mut source = Vec::from(b"from typing import Any, Callable, TypeAlias\n");

        source.extend_from_slice(b"from decimal import Decimal\n\n");
        source.extend_from_slice(b"Hook: TypeAlias = Callable[[\"Decimal\"], Any]\n");

        let fixture = Fixture::of(&source);

        let held = fixture
            .semantic
            .bindings()
            .iter()
            .find(|row| fixture.text_of(row.name) == "Decimal")
            .copied()
            .expect("the fixture imports the name");

        assert_eq!(held.reference_count, 1);
    }

    #[test]
    fn a_cast_that_names_something_else_leaves_its_string_alone() {
        let source = b"from decimal import cast\n\nprint(cast(\"Decimal\", value))\n";
        let fixture = Fixture::of(source);

        let invented = fixture
            .semantic
            .references()
            .iter()
            .any(|row| fixture.text_of(row.name) == "Decimal");

        assert!(!invented);
    }

    #[test]
    fn a_string_annotation_reads_a_name_bound_after_it() {
        let mut source = Vec::from(b"def read(held: \"Decimal\"): ...\n\n\n");

        source.extend_from_slice(b"from decimal import Decimal\n");

        let fixture = Fixture::of(&source);

        let held = fixture
            .semantic
            .bindings()
            .iter()
            .find(|row| fixture.text_of(row.name) == "Decimal")
            .copied()
            .expect("the fixture imports the name");

        assert_eq!(held.reference_count, 1);
    }

    #[test]
    fn a_plain_annotation_reads_no_name_bound_after_it() {
        let mut source = Vec::from(b"def read(held: Decimal): ...\n\n\n");

        source.extend_from_slice(b"from decimal import Decimal\n");

        let fixture = Fixture::of(&source);

        let held = fixture
            .semantic
            .bindings()
            .iter()
            .find(|row| fixture.text_of(row.name) == "Decimal")
            .copied()
            .expect("the fixture imports the name");

        assert_eq!(held.reference_count, 0);
    }

    #[test]
    fn a_qualified_name_reads_an_import_through_its_attribute_chain() {
        let fixture = Fixture::read("qualified.py");
        let mut out = BoundedVec::reserve(ATTRIBUTE_DEPTH_MAX + SEGMENT_COUNT_MAX);
        let held = fixture.last_read("os.path.join");

        let outcome = fixture
            .semantic
            .qualified_name_of(&fixture.source, held, &mut out);

        assert_eq!(outcome, Qualified::Resolved);
        assert_eq!(fixture.segments(&out), rows(&["os", "path", "join"]));
    }

    #[test]
    fn a_qualified_name_reads_through_an_import_alias() {
        let fixture = Fixture::read("qualified.py");
        let mut out = BoundedVec::reserve(ATTRIBUTE_DEPTH_MAX + SEGMENT_COUNT_MAX);
        let held = fixture.last_read("np.array");

        let outcome = fixture
            .semantic
            .qualified_name_of(&fixture.source, held, &mut out);

        assert_eq!(outcome, Qualified::Resolved);
        assert_eq!(fixture.segments(&out), rows(&["numpy", "array"]));
    }

    #[test]
    fn a_qualified_name_reads_a_from_import_as_its_module_and_its_remote_name() {
        let fixture = Fixture::read("qualified.py");
        let mut out = BoundedVec::reserve(ATTRIBUTE_DEPTH_MAX + SEGMENT_COUNT_MAX);
        let held = fixture.last_read("OD.fromkeys");

        let outcome = fixture
            .semantic
            .qualified_name_of(&fixture.source, held, &mut out);

        assert_eq!(outcome, Qualified::Resolved);

        assert_eq!(
            fixture.segments(&out),
            rows(&["collections", "OrderedDict", "fromkeys"])
        );
    }

    #[test]
    fn a_relative_import_reads_its_level_and_keeps_its_segments() {
        let fixture = Fixture::read("qualified.py");
        let mut out = BoundedVec::reserve(ATTRIBUTE_DEPTH_MAX + SEGMENT_COUNT_MAX);
        let held = fixture.last_read("sibling.value");

        let outcome = fixture
            .semantic
            .qualified_name_of(&fixture.source, held, &mut out);

        assert_eq!(outcome, Qualified::Relative(1));
        assert_eq!(fixture.segments(&out), rows(&["sibling", "value"]));

        let deeper = fixture.last_read("thing.value");

        let nested = fixture
            .semantic
            .qualified_name_of(&fixture.source, deeper, &mut out);

        assert_eq!(nested, Qualified::Relative(2));
        assert_eq!(fixture.segments(&out), rows(&["pkg", "thing", "value"]));
    }

    #[test]
    fn a_local_definition_and_a_builtin_read_apart_from_an_import() {
        let fixture = Fixture::read("qualified.py");
        let mut out = BoundedVec::reserve(ATTRIBUTE_DEPTH_MAX + SEGMENT_COUNT_MAX);
        let held = fixture.last_read("local.__doc__");

        let outcome = fixture
            .semantic
            .qualified_name_of(&fixture.source, held, &mut out);

        assert!(matches!(outcome, Qualified::Local(_)));
        assert_eq!(fixture.segments(&out), rows(&["local", "__doc__"]));

        let builtin = fixture.last_read("len.__doc__");

        let read = fixture
            .semantic
            .qualified_name_of(&fixture.source, builtin, &mut out);

        assert_eq!(read, Qualified::Builtin);
        assert_eq!(fixture.segments(&out), rows(&["len", "__doc__"]));
    }

    #[test]
    fn a_match_reads_a_module_member_and_accepts_the_forward_port() {
        let source = b"from typing import TYPE_CHECKING\n\nprint(TYPE_CHECKING)\n";
        let fixture = Fixture::of(source);
        let mut out = BoundedVec::reserve(ATTRIBUTE_DEPTH_MAX + SEGMENT_COUNT_MAX);
        let held = fixture.last_read("TYPE_CHECKING");

        assert!(fixture.semantic.matches(
            &fixture.source,
            held,
            b"typing",
            b"TYPE_CHECKING",
            &mut out
        ));

        assert!(!fixture.semantic.matches(
            &fixture.source,
            held,
            b"os",
            b"TYPE_CHECKING",
            &mut out
        ));

        let ported = Fixture::of(b"from typing_extensions import Self\n\nprint(Self)\n");
        let read = ported.last_read("Self");

        assert!(
            ported
                .semantic
                .matches(&ported.source, read, b"typing", b"Self", &mut out)
        );
    }

    #[test]
    fn a_reference_reads_back_from_the_node_that_made_it() {
        let fixture = Fixture::of(b"held = 1\nprint(held)\n");
        let read = fixture.last_read("held");
        let index = fixture.semantic.reference_at(read.index());

        assert_ne!(index, NONE);

        assert_eq!(
            fixture.semantic.references()[index as usize].node,
            read.index()
        );

        assert_eq!(fixture.semantic.reference_at(read.index() + 1_000), NONE);
    }

    #[test]
    fn a_name_in_a_string_annotation_reads_the_import_it_names() {
        let fixture = Fixture::read("string_annotations.py");

        let unused = fixture
            .semantic
            .bindings()
            .iter()
            .filter(|held| held.kind.imports() && held.reference_count == 0)
            .map(|held| fixture.text_of(held.name))
            .collect::<Vec<String>>();

        assert!(fixture.semantic.bindings().len() > 4);
        assert_eq!(unused, rows(&[]));
    }

    #[test]
    fn a_reference_a_string_annotation_made_is_typing_only() {
        let mut source = Vec::from(b"import json\n\n\n");

        source.extend_from_slice(b"def read(held: \"json.JSONDecoder\"): ...\n");

        let fixture = Fixture::of(&source);

        let held = fixture
            .semantic
            .references()
            .iter()
            .find(|row| fixture.text_of(row.name) == "json")
            .copied()
            .expect("the string annotation reads the import");

        assert!(held.flags.annotation);
        assert!(held.flags.typing_only);
        assert!(matches!(held.resolution, Resolution::Bound(_)));
    }

    #[test]
    fn a_string_annotation_a_re_lex_cannot_place_back_is_left_opaque() {
        let head = b"import json\n\n\n";
        let mut newline = Vec::from(head);
        let mut bytes = Vec::from(head);
        let mut joined = Vec::from(head);

        newline.extend_from_slice(b"def read(held: \"json.\\nJSONDecoder\"): ...\n");
        bytes.extend_from_slice(b"def read(held: b\"json\"): ...\n");
        joined.extend_from_slice(b"def read(held: \"js\" \"on\"): ...\n");

        assert!(!Fixture::of(&newline).semantic.is_used(0));
        assert!(!Fixture::of(&bytes).semantic.is_used(0));
        assert!(!Fixture::of(&joined).semantic.is_used(0));
    }

    #[test]
    fn a_string_inside_a_literal_subscript_is_a_value_and_not_a_type() {
        let mut source = Vec::from(b"import typing\n\n\n");

        source.extend_from_slice(b"def read(held: typing.Literal[\"adhoc\"]): ...\n");

        let fixture = Fixture::of(&source);

        let invented = fixture
            .semantic
            .references()
            .iter()
            .any(|row| fixture.text_of(row.name) == "adhoc");

        assert!(!invented);
    }

    #[test]
    fn a_type_parameter_is_read_by_the_annotations_of_the_definition_that_declares_it() {
        let fixture = Fixture::of(b"def read[T](value: T) -> T:\n    return value\n");

        let reads = fixture
            .semantic
            .references()
            .iter()
            .filter(|held| fixture.text_of(held.name) == "T")
            .map(|held| held.resolution)
            .collect::<Vec<Resolution>>();

        assert_eq!(reads.len(), 2);
        assert!(reads.iter().all(|held| *held == Resolution::Bound(1)));

        assert_eq!(
            fixture.semantic.bindings()[1].kind,
            BindingKind::TypeParameter
        );
    }

    #[test]
    fn a_class_base_reads_the_type_parameter_the_class_declares() {
        let fixture = Fixture::of(b"class Holder[T](Base[T]):\n    pass\n");

        let read = fixture
            .semantic
            .references()
            .iter()
            .find(|held| fixture.text_of(held.name) == "T")
            .copied()
            .expect("the base reads the type parameter");

        assert_eq!(read.resolution, Resolution::Bound(1));

        assert_eq!(
            fixture.semantic.bindings()[1].kind,
            BindingKind::TypeParameter
        );
    }

    #[test]
    fn a_type_alias_leaves_its_parameter_unbound_in_the_scope_that_follows_it() {
        let fixture = Fixture::of(b"type Alias[T] = list[T]\n\nprint(T)\n");

        let outside = fixture
            .semantic
            .references()
            .iter()
            .filter(|held| fixture.text_of(held.name) == "T")
            .map(|held| held.resolution)
            .collect::<Vec<Resolution>>();

        assert_eq!(outside, vec![Resolution::Bound(1), Resolution::Unresolved]);
    }

    #[test]
    fn a_binding_kind_reports_whether_it_binds() {
        assert!(BindingKind::Assignment.binds());
        assert!(!BindingKind::Annotation.binds());
        assert!(!BindingKind::Deletion.binds());
        assert!(!BindingKind::Global.binds());
        assert!(!BindingKind::Nonlocal.binds());
        assert!(BindingKind::Import.imports());
        assert!(BindingKind::ImportStar.imports());
        assert!(!BindingKind::Assignment.imports());
    }

    #[test]
    fn a_model_runs_on_a_frozen_thread() {
        let source = b"import os\n\n\ndef run(value):\n    return os.path.join(value)\n";
        let mut lexed = Tokens::reserve(1 << 12);
        let mut tokens = Tokens::reserve(1 << 12);
        let mut raw = BoundedVec::reserve(1 << 12);
        let mut events = Events::reserve(1 << 14);
        let mut tree = Tree::<PythonKind>::reserve(1 << 12, 1 << 8);
        let mut tables = Tables::reserve(1 << 8, 1 << 10, 1 << 10, 1 << 10);
        let mut semantic = Semantic::reserve(1 << 10, 1 << 10, 1 << 8);
        let mut scratch = AnnotationScratch::reserve(1 << 8, 1 << 8);
        let _scope = crate::allocation::freeze_scope();

        PYTHON.lex(source, &mut lexed);

        assert!(classify(source, lexed.as_slice(), &mut tokens, &mut raw));

        parse::build(source, tokens.as_slice(), &raw, &mut events, &mut tree);

        assert_eq!(
            bind(source, tokens.as_slice(), &raw, &tree, &mut tables),
            BindOutcome::Complete
        );

        assert_eq!(
            semantic.build(
                &SemanticInput {
                    builtins: &BUILTINS,
                    raw: &raw,
                    scopes: &tables,
                    source,
                    tokens: tokens.as_slice(),
                    tree: &tree,
                    version: PythonVersion::Py310,
                },
                &mut scratch,
            ),
            Structure::Complete
        );

        assert_eq!(semantic.count(), 3);
    }
}
