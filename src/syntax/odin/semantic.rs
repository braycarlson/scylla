use crate::bounded::{BoundedVec, Span, count_of};
use crate::syntax::odin::kind::OdinKind;
use crate::syntax::{Fact, FactKind, Facts, name_hash};
use crate::token::Token;
use crate::tree::{NONE, Step, Structure, Tree, walk};

pub const SCOPE_DEPTH_MAX: u32 = 1 << 8;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum BindingKind {
    Const,
    Field,
    Import,
    Label,
    Member,
    Parameter,
    Procedure,
    Result,
    Type,
    Var,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Context {
    Load,
    Store,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Namespace {
    Label,
    Value,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Resolution {
    Bound(u32),
    Builtin,
    Maybe,
    Unresolved,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ScopeKind {
    Block,
    File,
    Item,
    Procedure,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Binding {
    pub from: u32,
    pub kind: BindingKind,
    pub name: Span,
    pub name_hash: u32,
    pub namespace: Namespace,
    pub node: u32,
    pub previous: u32,
    pub scope: u32,
    pub scope_previous: u32,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Reference {
    pub context: Context,
    pub name: Span,
    pub namespace: Namespace,
    pub node: u32,
    pub resolution: Resolution,
    pub scope: u32,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Scope {
    pub dynamic: bool,
    pub kind: ScopeKind,
    pub node: u32,
    pub parent: u32,
}

#[derive(Debug)]
pub struct Semantic {
    bindings: BoundedVec<Binding>,
    facts: Facts,
    heads: BoundedVec<u32>,
    references: BoundedVec<Reference>,
    scopes: BoundedVec<Scope>,
}

struct Builder<'run> {
    depth: u32,
    outcome: Structure,
    raw: &'run [OdinKind],
    semantic: &'run mut Semantic,
    source: &'run [u8],
    stack: [u32; SCOPE_DEPTH_MAX as usize],
    tokens: &'run [Token],
    tree: &'run Tree<OdinKind>,
}

struct Children<'run> {
    node: u32,
    tree: &'run Tree<OdinKind>,
}

impl Iterator for Children<'_> {
    type Item = u32;

    fn next(&mut self) -> Option<u32> {
        if self.node == NONE {
            return None;
        }

        let held = self.node;

        self.node = self.tree.at(held).sibling_next;

        Some(held)
    }
}

impl BindingKind {
    pub const fn annotated(self) -> bool {
        matches!(self, Self::Field | Self::Parameter)
    }

    pub const fn hoists(self) -> bool {
        matches!(
            self,
            Self::Const
                | Self::Field
                | Self::Import
                | Self::Label
                | Self::Member
                | Self::Parameter
                | Self::Procedure
                | Self::Result
                | Self::Type
        )
    }

    pub const fn namespace(self) -> Namespace {
        match self {
            Self::Label => Namespace::Label,
            Self::Const
            | Self::Field
            | Self::Import
            | Self::Member
            | Self::Parameter
            | Self::Procedure
            | Self::Result
            | Self::Type
            | Self::Var => Namespace::Value,
        }
    }
}

impl ScopeKind {
    pub const fn is_ordered(self) -> bool {
        matches!(self, Self::Block | Self::Procedure)
    }
}

impl Semantic {
    pub fn reserve(
        binding_count_max: u32,
        reference_count_max: u32,
        scope_count_max: u32,
        fact_count_max: u32,
    ) -> Self {
        assert!(binding_count_max > 0);
        assert!(reference_count_max > 0);
        assert!(scope_count_max > 0);
        assert!(fact_count_max > 0);

        assert!(!crate::allocation::is_frozen());

        let mut heads = BoundedVec::reserve(bucket_count_of(binding_count_max));

        for _ in 0..heads.capacity() {
            heads.push_assert(NONE);
        }

        Self {
            bindings: BoundedVec::reserve(binding_count_max),
            facts: Facts::reserve(fact_count_max),
            heads,
            references: BoundedVec::reserve(reference_count_max),
            scopes: BoundedVec::reserve(scope_count_max),
        }
    }

    pub fn bindings(&self) -> &[Binding] {
        &self.bindings
    }

    pub fn bindings_of(&self, scope: u32) -> impl Iterator<Item = u32> {
        (0..self.bindings.count())
            .filter(move |index| self.bindings[*index as usize].scope == scope)
    }

    pub fn clear(&mut self) {
        for index in 0..self.heads.count() {
            self.heads[index as usize] = NONE;
        }

        self.bindings.clear();
        self.facts.clear();
        self.references.clear();
        self.scopes.clear();

        assert_eq!(self.count(), 0);
    }

    pub fn count(&self) -> u32 {
        self.bindings.count()
    }

    pub fn facts(&self) -> &[Fact] {
        self.facts.as_slice()
    }

    pub fn get(&self, index: u32) -> Option<&Binding> {
        if index == NONE {
            return None;
        }

        self.bindings.get(index as usize)
    }

    pub fn references(&self) -> &[Reference] {
        &self.references
    }

    pub fn references_of(&self, binding: u32) -> impl Iterator<Item = u32> {
        (0..self.references.count()).filter(move |index| {
            self.references[*index as usize].resolution == Resolution::Bound(binding)
        })
    }

    pub fn scopes(&self) -> &[Scope] {
        &self.scopes
    }

    pub fn build(
        &mut self,
        source: &[u8],
        tokens: &[Token],
        raw: &[OdinKind],
        tree: &Tree<OdinKind>,
        universe: &[&[u8]],
    ) -> Structure {
        self.clear();

        let pushed = self.scopes.push(Scope {
            dynamic: false,
            kind: ScopeKind::File,
            node: 0,
            parent: NONE,
        });

        assert!(pushed);

        let mut builder = Builder {
            depth: 0,
            outcome: Structure::Complete,
            raw,
            semantic: self,
            source,
            stack: [0; SCOPE_DEPTH_MAX as usize],
            tokens,
            tree,
        };

        builder.collect();

        let outcome = builder.outcome;

        self.resolve(source, universe);

        outcome
    }

    fn resolve(&mut self, source: &[u8], universe: &[&[u8]]) {
        for index in 0..self.references.count() {
            let held = self.references[index as usize];

            self.references[index as usize].resolution =
                self.resolution_of(source, &held, universe);
        }
    }

    fn resolution_of(
        &self,
        source: &[u8],
        reference: &Reference,
        universe: &[&[u8]],
    ) -> Resolution {
        let name = &source[reference.name.range()];
        let mut scope = reference.scope;
        let mut steps = 0;
        let mut used = false;

        while scope != NONE && steps <= SCOPE_DEPTH_MAX {
            let held = self.scopes[scope as usize];
            let bounded = self.binding_in(source, scope, name, reference);

            if bounded != NONE {
                return Resolution::Bound(bounded);
            }

            used = used || held.dynamic;
            scope = held.parent;
            steps += 1;
        }

        if universe.contains(&name) {
            return Resolution::Builtin;
        }

        if used {
            return Resolution::Maybe;
        }

        Resolution::Unresolved
    }

    fn bucket_of(&self, scope: u32, hash: u32) -> usize {
        let mixed = hash ^ scope.wrapping_mul(2_654_435_761);

        (mixed & (self.heads.count() - 1)) as usize
    }

    fn push_binding(&mut self, binding: Binding) -> bool {
        let index = self.bindings.count();
        let bucket = self.bucket_of(binding.scope, binding.name_hash);
        let mut held = binding;

        held.scope_previous = self.heads[bucket];

        if !self.bindings.push(held) {
            return false;
        }

        self.heads[bucket] = index;

        true
    }

    fn binding_in(&self, source: &[u8], scope: u32, name: &[u8], reference: &Reference) -> u32 {
        let hash = name_hash(name);
        let mut index = self.heads[self.bucket_of(scope, hash)];

        for _ in 0..=self.bindings.count() {
            if index == NONE {
                break;
            }

            let held = self.bindings[index as usize];

            let opened =
                held.from <= reference.name.offset || held.name.offset == reference.name.offset;

            if held.scope == scope
                && held.namespace == reference.namespace
                && opened
                && held.name_hash == hash
                && &source[held.name.range()] == name
            {
                return index;
            }

            index = held.scope_previous;
        }

        NONE
    }
}

impl<'run> Builder<'run> {
    fn collect(&mut self) {
        if self.tree.count() == 0 {
            return;
        }

        self.stack[0] = 0;
        self.depth = 1;

        for step in walk(self.tree) {
            match step {
                Step::Enter(node) => self.enter(node),
                Step::Leave(node) => self.leave(node),
            }
        }
    }

    fn scope(&self) -> u32 {
        assert!(self.depth > 0);

        self.stack[self.depth as usize - 1]
    }

    fn kind_of(&self, node: u32) -> OdinKind {
        if node == NONE {
            return OdinKind::ErrorNode;
        }

        self.tree.at(node).kind
    }

    fn children(&self, node: u32) -> Children<'run> {
        Children {
            node: self.tree.at(node).child_first,
            tree: self.tree,
        }
    }

    fn child_at(&self, node: u32, index: u32) -> u32 {
        self.children(node).nth(index as usize).unwrap_or(NONE)
    }

    fn child_of(&self, node: u32, kind: OdinKind) -> u32 {
        if node == NONE {
            return NONE;
        }

        for child in self.children(node) {
            if self.kind_of(child) == kind {
                return child;
            }
        }

        NONE
    }

    fn parent_of(&self, node: u32) -> u32 {
        if node == NONE {
            return NONE;
        }

        self.tree.at(node).parent
    }

    fn span_of(&self, node: u32) -> Span {
        self.tree.at(node).span(self.tokens)
    }

    fn end_of(&self, node: u32) -> u32 {
        let held = self.span_of(node);

        held.offset + held.length
    }

    fn text_of(&self, name: Span) -> &'run [u8] {
        &self.source[name.range()]
    }

    fn token_of(&self, node: u32, kind: OdinKind) -> u32 {
        let held = self.tree.at(node);
        let mut position = held.token_start;
        let mut child = held.child_first;

        while position < held.token_end {
            if child != NONE && position >= self.tree.at(child).token_start {
                position = position.max(self.tree.at(child).token_end);
                child = self.tree.at(child).sibling_next;

                continue;
            }

            if self.raw[position as usize] == kind {
                return position;
            }

            position += 1;
        }

        NONE
    }

    const fn scope_kind_of(kind: OdinKind) -> Option<ScopeKind> {
        match Some(kind) {
            Some(OdinKind::Procedure | OdinKind::ProcedureType) => Some(ScopeKind::Procedure),
            Some(
                OdinKind::BitFieldDeclaration
                | OdinKind::EnumDeclaration
                | OdinKind::StructDeclaration
                | OdinKind::UnionDeclaration,
            ) => Some(ScopeKind::Item),
            Some(
                OdinKind::Block
                | OdinKind::ForStatement
                | OdinKind::IfStatement
                | OdinKind::SwitchCase
                | OdinKind::SwitchStatement
                | OdinKind::WhenStatement,
            ) => Some(ScopeKind::Block),
            Some(_) | None => None,
        }
    }

    fn opens(&self, node: u32) -> Option<ScopeKind> {
        let kind = self.kind_of(node);

        if kind == OdinKind::Block && self.kind_of(self.parent_of(node)) == OdinKind::ForeignBlock {
            return None;
        }

        Self::scope_kind_of(kind)
    }

    fn enter(&mut self, node: u32) {
        let kind = self.kind_of(node);

        self.before(node, kind);

        if let Some(held) = self.opens(node) {
            self.open(node, held);
        }

        self.after(node, kind);
    }

    fn leave(&mut self, node: u32) {
        if self.opens(node).is_none() {
            return;
        }

        if self.depth > 1 {
            self.depth -= 1;
        }
    }

    fn open(&mut self, node: u32, kind: ScopeKind) {
        let parent = self.scope();
        let index = self.semantic.scopes.count();

        let pushed = self.semantic.scopes.push(Scope {
            dynamic: false,
            kind,
            node,
            parent,
        });

        if !pushed || self.depth >= SCOPE_DEPTH_MAX {
            self.outcome = Structure::TooDeep;

            return;
        }

        self.stack[self.depth as usize] = index;
        self.depth += 1;
    }

    fn before(&mut self, node: u32, kind: OdinKind) {
        match Some(kind) {
            Some(OdinKind::AssignmentStatement) => self.short(node),
            Some(OdinKind::BitFieldDeclaration | OdinKind::ConstTypeDeclaration) => {
                self.declaration(node, BindingKind::Type);
            }
            Some(OdinKind::ConstDeclaration) => self.declaration(node, BindingKind::Const),
            Some(OdinKind::EnumDeclaration) => self.declaration(node, BindingKind::Type),
            Some(OdinKind::ImportDeclaration) => self.import(node),
            Some(OdinKind::LabelStatement) => self.declaration(node, BindingKind::Label),
            Some(OdinKind::OverloadedProcedureDeclaration | OdinKind::ProcedureDeclaration) => {
                self.declaration(node, BindingKind::Procedure);
            }
            Some(OdinKind::StructDeclaration) => self.declaration(node, BindingKind::Type),
            Some(OdinKind::UnionDeclaration) => self.declaration(node, BindingKind::Type),
            Some(OdinKind::UsingStatement) => self.using(),
            Some(OdinKind::VarDeclaration | OdinKind::VariableDeclaration) => {
                self.variable(node);
            }
            Some(_) | None => {}
        }
    }

    fn after(&mut self, node: u32, kind: OdinKind) {
        match Some(kind) {
            Some(OdinKind::Field) => self.grouped(node, BindingKind::Field),
            Some(OdinKind::StructMember) => self.member(node),
            Some(OdinKind::EnumDeclaration) => self.members(node),
            Some(OdinKind::ForStatement) => self.iteration(node),
            Some(OdinKind::IdentifierNode) => self.name(node),
            Some(OdinKind::NamedType) => self.named(node),
            Some(OdinKind::Parameter) => self.grouped(node, BindingKind::Parameter),
            Some(_) | None => {}
        }
    }

    fn declaration(&mut self, node: u32, kind: BindingKind) {
        let held = self.child_of(node, OdinKind::IdentifierNode);

        if held == NONE {
            return;
        }

        let name = self.span_of(held);
        let from = if kind.hoists() && !kind.annotated() {
            0
        } else {
            self.end_of(node)
        };

        let _ = self.record_from(from, kind, name, held);
    }

    fn member(&mut self, node: u32) {
        if self.token_of(node, OdinKind::Colon) == NONE {
            return;
        }

        self.grouped(node, BindingKind::Field);
    }

    fn grouped(&mut self, node: u32, kind: BindingKind) {
        let assigned = self.token_of(node, OdinKind::Equal);
        let mut names = [NONE; NAME_COUNT_MAX];
        let mut count = 0;

        self.leading_names(node, &mut names, &mut count);

        let from = if kind.hoists() && !kind.annotated() {
            0
        } else {
            self.end_of(node)
        };

        for held in &names[..count] {
            if assigned != NONE && self.tree.at(*held).token_start > assigned {
                break;
            }

            let name = self.span_of(*held);

            let _ = self.record_from(from, kind, name, *held);
        }
    }

    fn members(&mut self, node: u32) {
        let named = self.child_of(node, OdinKind::IdentifierNode);

        for child in self.children(node) {
            if child == named || self.kind_of(child) != OdinKind::IdentifierNode {
                continue;
            }

            let name = self.span_of(child);

            let _ = self.record_from(0, BindingKind::Member, name, child);
        }
    }

    fn named(&mut self, node: u32) {
        let held = self.child_of(node, OdinKind::IdentifierNode);

        if held == NONE {
            return;
        }

        let name = self.span_of(held);

        let _ = self.record_from(0, BindingKind::Result, name, held);
    }

    fn variable(&mut self, node: u32) {
        let mut names = [NONE; NAME_COUNT_MAX];
        let mut count = 0;

        self.leading_names(node, &mut names, &mut count);

        let from = self.end_of(node);

        for held in &names[..count] {
            let name = self.span_of(*held);

            let _ = self.record_from(from, BindingKind::Var, name, *held);
        }
    }

    fn leading_names(&self, node: u32, out: &mut [u32; NAME_COUNT_MAX], count: &mut usize) {
        *count = 0;

        let mut child = self.tree.at(node).child_first;

        while child != NONE && self.kind_of(child) == OdinKind::Tag {
            child = self.tree.at(child).sibling_next;
        }

        while child != NONE && *count < NAME_COUNT_MAX {
            if self.kind_of(child) != OdinKind::IdentifierNode {
                return;
            }

            out[*count] = child;
            *count += 1;
            child = self.tree.at(child).sibling_next;
        }
    }

    fn short(&mut self, node: u32) {
        let declares = self.token_of(node, OdinKind::ColonEqual);

        if declares == NONE {
            return;
        }

        let from = self.end_of(node);

        for child in self.children(node) {
            if self.tree.at(child).token_start >= declares {
                break;
            }

            if self.kind_of(child) != OdinKind::IdentifierNode {
                continue;
            }

            let name = self.span_of(child);

            let _ = self.record_from(from, BindingKind::Var, name, child);
        }
    }

    fn iteration(&mut self, node: u32) {
        let held = self.token_of(node, OdinKind::InKeyword);

        if held == NONE {
            return;
        }

        let body = self.child_of(node, OdinKind::Block);

        let from = if body == NONE {
            self.end_of(node)
        } else {
            self.span_of(body).offset
        };

        for child in self.children(node) {
            if self.tree.at(child).token_start >= held {
                break;
            }

            if self.kind_of(child) != OdinKind::IdentifierNode {
                continue;
            }

            let name = self.span_of(child);

            let _ = self.record_from(from, BindingKind::Var, name, child);
        }
    }

    fn using(&mut self) {
        let scope = self.scope();

        self.semantic.scopes[scope as usize].dynamic = true;
    }

    fn import(&mut self, node: u32) {
        let specifier = self.specifier_of(node);

        if specifier == Span::EMPTY {
            return;
        }

        let held = self.child_of(node, OdinKind::IdentifierNode);

        let name = if held == NONE {
            self.package_of(specifier)
        } else {
            self.span_of(held)
        };

        let binding = self.record_from(0, BindingKind::Import, name, node);

        self.fact(Fact {
            binding,
            kind: FactKind::ImportNamed,
            local: name,
            remote: specifier,
            specifier,
        });
    }

    fn specifier_of(&self, node: u32) -> Span {
        let held = self.child_of(node, OdinKind::String);

        if held == NONE {
            return Span::EMPTY;
        }

        let inner = self.child_of(held, OdinKind::StringContent);

        if inner != NONE {
            return self.span_of(inner);
        }

        let quoted = self.span_of(held);

        if quoted.length < 2 {
            return Span::EMPTY;
        }

        Span {
            length: quoted.length - 2,
            offset: quoted.offset + 1,
        }
    }

    fn package_of(&self, specifier: Span) -> Span {
        let text = self.text_of(specifier);
        let mut start = 0;

        for (index, byte) in text.iter().enumerate() {
            if *byte == b':' || *byte == b'/' {
                start = index + 1;
            }
        }

        Span {
            length: specifier.length - count_of(start),
            offset: specifier.offset + count_of(start),
        }
    }

    fn name(&mut self, node: u32) {
        if self.declares(node) || self.selects(node) || self.decorates(node) {
            return;
        }

        let name = self.span_of(node);

        if self.text_of(name) == b"_" {
            return;
        }

        let namespace = if self.branches(node) {
            Namespace::Label
        } else {
            Namespace::Value
        };

        let context = if self.stores(node) {
            Context::Store
        } else {
            Context::Load
        };

        self.reference(context, name, namespace, node);
    }

    fn decorates(&self, node: u32) -> bool {
        let mut held = node;

        for _ in 0..STEP_MAX {
            if held == NONE {
                return false;
            }

            if matches!(
                self.kind_of(held),
                OdinKind::Attribute | OdinKind::Attributes | OdinKind::PackageDeclaration
            ) {
                return true;
            }

            held = self.parent_of(held);
        }

        false
    }

    fn branches(&self, node: u32) -> bool {
        matches!(
            self.kind_of(self.parent_of(node)),
            OdinKind::BreakStatement | OdinKind::ContinueStatement
        )
    }

    fn selects(&self, node: u32) -> bool {
        let parent = self.parent_of(node);
        let kind = self.kind_of(parent);

        if matches!(
            kind,
            OdinKind::MemberExpression | OdinKind::SelectorCallExpression
        ) {
            return self.child_at(parent, 0) != node;
        }

        if kind != OdinKind::CallExpression || self.child_at(parent, 0) != node {
            return false;
        }

        let held = self.parent_of(parent);

        if !matches!(
            self.kind_of(held),
            OdinKind::MemberExpression | OdinKind::SelectorCallExpression
        ) {
            return false;
        }

        self.child_at(held, 0) != parent
    }

    fn declares(&self, node: u32) -> bool {
        let parent = self.parent_of(node);
        let kind = self.kind_of(parent);

        if matches!(
            kind,
            OdinKind::BitFieldDeclaration
                | OdinKind::ConstDeclaration
                | OdinKind::ConstTypeDeclaration
                | OdinKind::EnumDeclaration
                | OdinKind::Field
                | OdinKind::ImportDeclaration
                | OdinKind::LabelStatement
                | OdinKind::NamedType
                | OdinKind::OverloadedProcedureDeclaration
                | OdinKind::Parameter
                | OdinKind::ProcedureDeclaration
                | OdinKind::StructDeclaration
                | OdinKind::StructField
                | OdinKind::UnionDeclaration
        ) {
            return self.declared_by(parent, node);
        }

        if matches!(
            kind,
            OdinKind::VarDeclaration | OdinKind::VariableDeclaration
        ) {
            let mut names = [NONE; NAME_COUNT_MAX];
            let mut count = 0;

            self.leading_names(parent, &mut names, &mut count);

            return names[..count].contains(&node);
        }

        if matches!(kind, OdinKind::AssignmentStatement | OdinKind::ForStatement) {
            let held = if kind == OdinKind::ForStatement {
                self.token_of(parent, OdinKind::InKeyword)
            } else {
                self.token_of(parent, OdinKind::ColonEqual)
            };

            return held != NONE && self.tree.at(node).token_start < held;
        }

        false
    }

    fn declared_by(&self, parent: u32, node: u32) -> bool {
        if self.kind_of(parent) == OdinKind::EnumDeclaration {
            return true;
        }

        if self.kind_of(parent) == OdinKind::OverloadedProcedureDeclaration {
            return self.child_at(parent, 0) == node;
        }

        self.child_of(parent, OdinKind::IdentifierNode) == node
    }

    fn stores(&self, node: u32) -> bool {
        let parent = self.parent_of(node);

        if !matches!(
            self.kind_of(parent),
            OdinKind::AssignmentStatement | OdinKind::UpdateStatement
        ) {
            return false;
        }

        self.child_at(parent, 0) == node
    }

    fn reference(&mut self, context: Context, name: Span, namespace: Namespace, node: u32) {
        let scope = self.scope();

        let recorded = self.semantic.references.push(Reference {
            context,
            name,
            namespace,
            node,
            resolution: Resolution::Unresolved,
            scope,
        });

        if !recorded && self.outcome == Structure::Complete {
            self.outcome = Structure::Truncated;
        }
    }

    fn fact(&mut self, held: Fact) {
        let recorded = self.semantic.facts.push(held);

        if !recorded && self.outcome == Structure::Complete {
            self.outcome = Structure::Truncated;
        }
    }

    fn record_from(&mut self, from: u32, kind: BindingKind, name: Span, node: u32) -> u32 {
        let scope = self.scope();

        self.record_within(scope, from, kind, name, node)
    }

    fn record_within(
        &mut self,
        scope: u32,
        from: u32,
        kind: BindingKind,
        name: Span,
        node: u32,
    ) -> u32 {
        if self.text_of(name) == b"_" {
            return NONE;
        }

        let Some(held) = self.semantic.scopes.get(scope as usize) else {
            return NONE;
        };

        let opens = if held.kind.is_ordered() || kind.annotated() {
            from
        } else {
            0
        };
        let previous = self.previous_of(scope, name, kind.namespace());
        let index = self.semantic.bindings.count();

        let recorded = self.semantic.push_binding(Binding {
            from: opens,
            kind,
            name,
            name_hash: name_hash(self.text_of(name)),
            namespace: kind.namespace(),
            node,
            previous,
            scope,
            scope_previous: NONE,
        });

        if !recorded {
            if self.outcome == Structure::Complete {
                self.outcome = Structure::Truncated;
            }

            return NONE;
        }

        index
    }

    fn previous_of(&self, scope: u32, name: Span, namespace: Namespace) -> u32 {
        let text = self.text_of(name);
        let hash = name_hash(text);
        let mut index = self.semantic.heads[self.semantic.bucket_of(scope, hash)];

        for _ in 0..=self.semantic.bindings.count() {
            if index == NONE {
                break;
            }

            let held = self.semantic.bindings[index as usize];

            if held.scope == scope
                && held.namespace == namespace
                && held.name_hash == hash
                && self.text_of(held.name) == text
            {
                return index;
            }

            index = held.scope_previous;
        }

        NONE
    }
}

const NAME_COUNT_MAX: usize = 1 << 6;

fn bucket_count_of(binding_count_max: u32) -> u32 {
    binding_count_max.next_power_of_two().max(16)
}

const STEP_MAX: u32 = 1 << 12;

#[cfg(test)]
mod tests {
    use super::*;
    use crate::bounded::BoundedVec as Held;
    use crate::language::Lexer as _;
    use crate::lex::ODIN;
    use crate::syntax::odin::classify::classify;
    use crate::syntax::odin::parse;
    use crate::token::Tokens;
    use crate::tree::Events;

    const DECLARATIONS_BINDINGS: [&str; 12] = [
        "Import fmt scope 0 from 0",
        "Import str scope 0 from 0",
        "Const TOP scope 0 from 0",
        "Type Shade scope 0 from 0",
        "Member Light scope 1 from 0",
        "Member Dark scope 1 from 0",
        "Type Holder scope 0 from 0",
        "Field field scope 2 from 135",
        "Field shade scope 2 from 150",
        "Procedure Handler scope 0 from 0",
        "Parameter one scope 3 from 179",
        "Procedure top scope 0 from 0",
    ];

    const DECLARATIONS_FACTS: [&str; 2] =
        ["ImportNamed fmt core:fmt", "ImportNamed str core:strings"];

    const DECLARATIONS_REFERENCES: [&str; 8] = [
        "int Value Builtin scope 2",
        "Shade Value Bound(3) scope 2",
        "int Value Builtin scope 3",
        "int Value Builtin scope 3",
        "int Value Builtin scope 4",
        "fmt Value Bound(0) scope 5",
        "str Value Bound(1) scope 5",
        "TOP Value Bound(2) scope 5",
    ];

    const DECLARATIONS_SCOPES: [&str; 6] = [
        "File none",
        "Item under 0",
        "Item under 0",
        "Procedure under 0",
        "Procedure under 0",
        "Block under 4",
    ];

    const FOREIGN_BINDINGS: [&str; 5] = [
        "Import c scope 0 from 0",
        "Import lib scope 0 from 0",
        "Procedure native scope 0 from 0",
        "Parameter one scope 1 from 140",
        "Procedure call scope 0 from 0",
    ];

    const FOREIGN_FACTS: [&str; 2] = ["ImportNamed c core:c", "ImportNamed lib system:lib"];

    const FOREIGN_REFERENCES: [&str; 5] = [
        "lib Value Bound(1) scope 0",
        "int Value Builtin scope 1",
        "int Value Builtin scope 1",
        "int Value Builtin scope 2",
        "native Value Bound(2) scope 3",
    ];

    const FOREIGN_SCOPES: [&str; 4] = [
        "File none",
        "Procedure under 0",
        "Procedure under 0",
        "Block under 2",
    ];

    const PROCEDURES_BINDINGS: [&str; 16] = [
        "Procedure build scope 0 from 0",
        "Parameter one scope 1 from 38",
        "Parameter two scope 1 from 51",
        "Result held scope 1 from 0",
        "Result ok scope 1 from 0",
        "Var kept scope 2 from 104",
        "Var total scope 2 from 122",
        "Var item scope 3 from 149",
        "Var index scope 3 from 149",
        "Var inner scope 6 from 204",
        "Label outer scope 2 from 0",
        "Procedure teardown scope 0 from 0",
        "Parameter one scope 12 from 390",
        "Procedure read scope 0 from 0",
        "Parameter one scope 14 from 418",
        "Procedure group scope 0 from 0",
    ];

    const PROCEDURES_FACTS: [&str; 0] = [];

    const PROCEDURES_REFERENCES: [&str; 29] = [
        "int Value Builtin scope 1",
        "string Value Builtin scope 1",
        "int Value Builtin scope 1",
        "bool Value Builtin scope 1",
        "held Value Bound(3) scope 2 store",
        "one Value Bound(1) scope 2",
        "two Value Bound(2) scope 2",
        "int Value Builtin scope 2",
        "one Value Bound(1) scope 2",
        "kept Value Bound(5) scope 3",
        "total Value Bound(6) scope 4 store",
        "index Value Bound(8) scope 4",
        "total Value Bound(6) scope 5",
        "total Value Bound(6) scope 6",
        "total Value Bound(6) scope 6 store",
        "inner Value Bound(9) scope 6",
        "total Value Bound(6) scope 7",
        "total Value Bound(6) scope 8 store",
        "total Value Bound(6) scope 9 store",
        "outer Label Bound(10) scope 11",
        "teardown Value Bound(11) scope 2",
        "total Value Bound(6) scope 2",
        "total Value Bound(6) scope 2",
        "int Value Builtin scope 12",
        "int Value Builtin scope 14",
        "int Value Builtin scope 14",
        "one Value Bound(14) scope 15",
        "build Value Bound(0) scope 0",
        "read Value Bound(13) scope 0",
    ];

    const PROCEDURES_SCOPES: [&str; 16] = [
        "File none",
        "Procedure under 0",
        "Block under 1",
        "Block under 2",
        "Block under 3",
        "Block under 2",
        "Block under 5",
        "Block under 2",
        "Block under 7",
        "Block under 7",
        "Block under 2",
        "Block under 10",
        "Procedure under 0",
        "Block under 12",
        "Procedure under 0",
        "Block under 14",
    ];

    const USING_BINDINGS: [&str; 6] = [
        "Type Holder scope 0 from 0",
        "Field field scope 1 from 46",
        "Procedure read scope 0 from 0",
        "Parameter self scope 2 from 76",
        "Procedure plain scope 0 from 0",
        "Parameter self scope 4 from 143",
    ];

    const USING_FACTS: [&str; 0] = [];

    const USING_REFERENCES: [&str; 8] = [
        "int Value Builtin scope 1",
        "Holder Value Bound(0) scope 2",
        "int Value Builtin scope 2",
        "self Value Bound(3) scope 3",
        "field Value Maybe scope 3",
        "Holder Value Bound(0) scope 4",
        "int Value Builtin scope 4",
        "missing Value Unresolved scope 5",
    ];

    const USING_SCOPES: [&str; 6] = [
        "File none",
        "Item under 0",
        "Procedure under 0",
        "Block under 2 using",
        "Procedure under 0",
        "Block under 4",
    ];

    const EVERY_FIXTURE: [&str; 4] = [
        "declarations.odin",
        "foreign.odin",
        "procedures.odin",
        "using.odin",
    ];

    const UNIVERSE: [&[u8]; 6] = [b"bool", b"false", b"int", b"nil", b"string", b"true"];

    struct Fixture {
        semantic: Semantic,
        source: Vec<u8>,
    }

    fn rows(held: &[&str]) -> Vec<String> {
        held.iter().map(|row| (*row).to_owned()).collect()
    }

    impl Fixture {
        fn read(path: &str) -> Self {
            let root = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"))
                .join("tests/fixtures/odin-semantic")
                .join(path);

            let source = std::fs::read(root).expect("the fixture is readable");

            Self::of(&source)
        }

        fn of(source: &[u8]) -> Self {
            let mut lexed = Tokens::reserve(1 << 14);
            let mut tokens = Tokens::reserve(1 << 14);
            let mut raw = Held::reserve(1 << 14);
            let mut events = Events::reserve(1 << 16);
            let mut tree = Tree::<OdinKind>::reserve(1 << 14, 1 << 8);
            let mut semantic = Semantic::reserve(1 << 10, 1 << 12, 1 << 10, 1 << 10);

            ODIN.lex(source, &mut lexed);

            assert!(classify(source, lexed.as_slice(), &mut tokens, &mut raw));

            parse::build(source, tokens.as_slice(), &raw, &mut events, &mut tree);

            assert_eq!(
                semantic.build(source, tokens.as_slice(), &raw, &tree, &UNIVERSE),
                Structure::Complete
            );

            Self {
                semantic,
                source: source.to_vec(),
            }
        }

        fn text_of(&self, name: Span) -> String {
            String::from_utf8_lossy(&self.source[name.range()]).into_owned()
        }

        fn scopes(&self) -> Vec<String> {
            self.semantic
                .scopes()
                .iter()
                .map(|held| {
                    let dynamic = if held.dynamic { " using" } else { "" };

                    if held.parent == NONE {
                        return format!("{:?} none{dynamic}", held.kind);
                    }

                    format!("{:?} under {}{dynamic}", held.kind, held.parent)
                })
                .collect()
        }

        fn bindings(&self) -> Vec<String> {
            self.semantic
                .bindings()
                .iter()
                .map(|held| {
                    format!(
                        "{:?} {} scope {} from {}",
                        held.kind,
                        self.text_of(held.name),
                        held.scope,
                        held.from
                    )
                })
                .collect()
        }

        fn references(&self) -> Vec<String> {
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

                    let stored = if held.context == Context::Store {
                        " store"
                    } else {
                        ""
                    };

                    format!(
                        "{} {:?} {bound} scope {}{stored}",
                        self.text_of(held.name),
                        held.namespace,
                        held.scope
                    )
                })
                .collect()
        }

        fn facts(&self) -> Vec<String> {
            self.semantic
                .facts()
                .iter()
                .map(|held| {
                    format!(
                        "{} {} {}",
                        held.kind.name(),
                        self.text_of(held.local),
                        self.text_of(held.specifier)
                    )
                })
                .collect()
        }
    }

    #[test]
    fn a_file_scope_declaration_is_read_from_anywhere_in_the_file() {
        let fixture = Fixture::read("declarations.odin");

        assert_eq!(fixture.scopes(), rows(&DECLARATIONS_SCOPES));
        assert_eq!(fixture.bindings(), rows(&DECLARATIONS_BINDINGS));
        assert_eq!(fixture.references(), rows(&DECLARATIONS_REFERENCES));
        assert_eq!(fixture.facts(), rows(&DECLARATIONS_FACTS));
    }

    #[test]
    fn a_foreign_block_binds_each_entry_into_the_file_that_holds_it() {
        let fixture = Fixture::read("foreign.odin");

        assert_eq!(fixture.scopes(), rows(&FOREIGN_SCOPES));
        assert_eq!(fixture.bindings(), rows(&FOREIGN_BINDINGS));
        assert_eq!(fixture.references(), rows(&FOREIGN_REFERENCES));
        assert_eq!(fixture.facts(), rows(&FOREIGN_FACTS));
    }

    #[test]
    fn a_procedure_names_its_parameters_its_results_and_its_locals() {
        let fixture = Fixture::read("procedures.odin");

        assert_eq!(fixture.scopes(), rows(&PROCEDURES_SCOPES));
        assert_eq!(fixture.bindings(), rows(&PROCEDURES_BINDINGS));
        assert_eq!(fixture.references(), rows(&PROCEDURES_REFERENCES));
        assert_eq!(fixture.facts(), rows(&PROCEDURES_FACTS));
    }

    #[test]
    fn a_using_leaves_an_unresolved_name_a_maybe_rather_than_a_mistake() {
        let fixture = Fixture::read("using.odin");

        assert_eq!(fixture.scopes(), rows(&USING_SCOPES));
        assert_eq!(fixture.bindings(), rows(&USING_BINDINGS));
        assert_eq!(fixture.references(), rows(&USING_REFERENCES));
        assert_eq!(fixture.facts(), rows(&USING_FACTS));
    }

    #[test]
    fn a_nested_constant_is_read_from_inside_its_own_body() {
        let source = b"package p\n\nouter :: proc() {\n\
            \tinner :: proc(a: int) -> bool {\n\t\treturn inner(a)\n\t}\n\n\tx := inner(1)\n}\n";
        let fixture = Fixture::of(source);

        let bound: Vec<&Reference> = fixture
            .semantic
            .references()
            .iter()
            .filter(|held| fixture.text_of(held.name) == "inner")
            .collect();

        assert_eq!(bound.len(), 2, "{:?}", fixture.references());

        for held in bound {
            assert!(
                matches!(held.resolution, Resolution::Bound(_)),
                "{:?}",
                fixture.references()
            );
        }
    }

    #[test]
    fn every_reference_resolves_into_a_scope_on_its_own_chain() {
        for name in EVERY_FIXTURE {
            let fixture = Fixture::read(name);

            for held in fixture.semantic.references() {
                let Resolution::Bound(index) = held.resolution else {
                    continue;
                };

                let binding = fixture.semantic.bindings()[index as usize];
                let mut scope = held.scope;
                let mut steps = 0;
                let mut walked = false;

                while scope != NONE && steps <= SCOPE_DEPTH_MAX {
                    if scope == binding.scope {
                        walked = true;

                        break;
                    }

                    scope = fixture.semantic.scopes()[scope as usize].parent;
                    steps += 1;
                }

                assert!(walked, "{name}: a reference resolves outside its own chain");
            }
        }
    }

    #[test]
    fn a_table_that_fills_reports_rather_than_grows() {
        let source = std::fs::read(
            std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"))
                .join("tests/fixtures/odin-semantic/procedures.odin"),
        )
        .expect("the fixture is readable");

        let mut lexed = Tokens::reserve(1 << 14);
        let mut tokens = Tokens::reserve(1 << 14);
        let mut raw = Held::reserve(1 << 14);
        let mut events = Events::reserve(1 << 16);
        let mut tree = Tree::<OdinKind>::reserve(1 << 14, 1 << 8);
        let mut semantic = Semantic::reserve(2, 2, 2, 2);

        ODIN.lex(&source, &mut lexed);

        assert!(classify(&source, lexed.as_slice(), &mut tokens, &mut raw));

        parse::build(&source, tokens.as_slice(), &raw, &mut events, &mut tree);

        let outcome = semantic.build(&source, tokens.as_slice(), &raw, &tree, &UNIVERSE);

        assert_ne!(outcome, Structure::Complete);
    }
}
