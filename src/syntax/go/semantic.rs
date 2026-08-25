use crate::bounded::{BoundedVec, Span, count_of};
use crate::syntax::go::kind::GoKind;
use crate::syntax::{Fact, FactKind, Facts, name_hash};
use crate::token::Token;
use crate::tree::{NONE, Step, Structure, Tree, walk};

pub const SCOPE_DEPTH_MAX: u32 = 1 << 8;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum BindingKind {
    Const,
    Field,
    Function,
    Import,
    ImportBlank,
    ImportDot,
    Label,
    Method,
    Parameter,
    Receiver,
    Result,
    Short,
    Type,
    TypeParameter,
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
    Method,
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
    Function,
    Package,
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
    pending: [u32; SCOPE_DEPTH_MAX as usize],
    raw: &'run [GoKind],
    semantic: &'run mut Semantic,
    source: &'run [u8],
    stack: [u32; SCOPE_DEPTH_MAX as usize],
    tokens: &'run [Token],
    tree: &'run Tree<GoKind>,
}

struct Children<'run> {
    node: u32,
    tree: &'run Tree<GoKind>,
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
    pub const fn hoists(self) -> bool {
        matches!(
            self,
            Self::Const | Self::Function | Self::Method | Self::Type | Self::Var
        )
    }

    pub const fn imports(self) -> bool {
        matches!(self, Self::Import | Self::ImportBlank | Self::ImportDot)
    }

    pub const fn namespace(self) -> Namespace {
        match self {
            Self::Label => Namespace::Label,
            Self::Method => Namespace::Method,
            Self::Const
            | Self::Field
            | Self::Function
            | Self::Import
            | Self::ImportBlank
            | Self::ImportDot
            | Self::Parameter
            | Self::Receiver
            | Self::Result
            | Self::Short
            | Self::Type
            | Self::TypeParameter
            | Self::Var => Namespace::Value,
        }
    }
}

impl ScopeKind {
    pub const fn is_ordered(self) -> bool {
        matches!(self, Self::Block | Self::Function)
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
        raw: &[GoKind],
        tree: &Tree<GoKind>,
        universe: &[&[u8]],
    ) -> Structure {
        self.clear();

        let pushed = self.scopes.push(Scope {
            dynamic: false,
            kind: ScopeKind::Package,
            node: 0,
            parent: NONE,
        });

        assert!(pushed);

        let held = self.scopes.push(Scope {
            dynamic: false,
            kind: ScopeKind::File,
            node: 0,
            parent: 0,
        });

        assert!(held);

        let mut builder = Builder {
            depth: 0,
            outcome: Structure::Complete,
            pending: [NONE; SCOPE_DEPTH_MAX as usize],
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
        let mut dotted = false;

        while scope != NONE && steps <= SCOPE_DEPTH_MAX {
            let held = self.scopes[scope as usize];
            let bounded = if held.kind.is_ordered() {
                self.binding_before(source, scope, name, reference)
            } else {
                self.binding_in(source, scope, name, reference.namespace)
            };

            if bounded != NONE {
                return Resolution::Bound(bounded);
            }

            dotted = dotted || held.dynamic;
            scope = held.parent;
            steps += 1;
        }

        if universe.contains(&name) {
            return Resolution::Builtin;
        }

        if dotted {
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

    fn binding_in(&self, source: &[u8], scope: u32, name: &[u8], namespace: Namespace) -> u32 {
        let hash = name_hash(name);
        let mut index = self.heads[self.bucket_of(scope, hash)];

        for _ in 0..=self.bindings.count() {
            if index == NONE {
                break;
            }

            let held = self.bindings[index as usize];

            if held.scope == scope
                && held.name_hash == hash
                && held.namespace == namespace
                && &source[held.name.range()] == name
            {
                return index;
            }

            index = held.scope_previous;
        }

        NONE
    }

    fn binding_before(&self, source: &[u8], scope: u32, name: &[u8], reference: &Reference) -> u32 {
        let hash = name_hash(name);
        let mut index = self.heads[self.bucket_of(scope, hash)];

        for _ in 0..=self.bindings.count() {
            if index == NONE {
                break;
            }

            let held = self.bindings[index as usize];
            let written = held.name.offset == reference.name.offset;

            let visible =
                held.namespace != Namespace::Value || held.from <= reference.name.offset || written;

            if held.scope == scope
                && held.namespace == reference.namespace
                && visible
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

        self.stack[0] = 1;
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

    fn kind_of(&self, node: u32) -> GoKind {
        if node == NONE {
            return GoKind::ErrorNode;
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

    fn holds(&self, node: u32, kind: GoKind) -> bool {
        let held = self.tree.at(node);

        for position in held.token_start..held.token_end {
            if self.raw[position as usize] == kind {
                return true;
            }
        }

        false
    }

    fn significant(&self, from: u32) -> u32 {
        let mut position = from;

        while position < count_of(self.raw.len()) && self.raw[position as usize].is_trivia() {
            position += 1;
        }

        position
    }

    fn leading_names(&self, node: u32, out: &mut [u32; NAME_COUNT_MAX], count: &mut usize) {
        *count = 0;

        let mut child = self.tree.at(node).child_first;

        while child != NONE && *count < NAME_COUNT_MAX {
            if self.kind_of(child) != GoKind::Ident {
                return;
            }

            out[*count] = child;
            *count += 1;

            let after = self.significant(self.tree.at(child).token_end);

            let comma = self
                .raw
                .get(after as usize)
                .copied()
                .is_some_and(|held| held == GoKind::Comma);

            child = self.tree.at(child).sibling_next;

            if !comma {
                break;
            }
        }

        if child == NONE {
            *count = 0;
        }
    }

    const fn scope_kind_of(kind: GoKind) -> Option<ScopeKind> {
        match Some(kind) {
            Some(GoKind::FuncDecl | GoKind::FuncLit) => Some(ScopeKind::Function),
            Some(GoKind::TypeSpec) => Some(ScopeKind::Function),
            Some(
                GoKind::BlockStmt
                | GoKind::CaseClause
                | GoKind::CommClause
                | GoKind::ForStmt
                | GoKind::IfStmt
                | GoKind::RangeStmt
                | GoKind::SelectStmt
                | GoKind::SwitchStmt
                | GoKind::TypeSwitchStmt,
            ) => Some(ScopeKind::Block),
            Some(_) | None => None,
        }
    }

    fn opens(&self, node: u32) -> Option<ScopeKind> {
        Self::scope_kind_of(self.kind_of(node))
    }

    fn is_body(&self, node: u32) -> bool {
        if self.kind_of(node) != GoKind::BlockStmt {
            return false;
        }

        let parent = self.kind_of(self.tree.at(node).parent);

        matches!(parent, GoKind::FuncDecl | GoKind::FuncLit)
    }

    fn enter(&mut self, node: u32) {
        let kind = self.kind_of(node);

        self.before(node, kind);

        if let Some(held) = self.opens(node) {
            let written = if self.is_body(node) {
                self.pending[self.depth as usize - 1]
            } else {
                NONE
            };

            if written == NONE {
                self.open(node, held);
            } else {
                self.push(written);
            }

            self.opened(node, kind);
        }

        self.name(node, kind);
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
        let index = self.scope_under(parent, node, kind);

        if index == NONE {
            return;
        }

        self.push(index);
    }

    fn scope_under(&mut self, parent: u32, node: u32, kind: ScopeKind) -> u32 {
        let index = self.semantic.scopes.count();

        let pushed = self.semantic.scopes.push(Scope {
            dynamic: false,
            kind,
            node,
            parent,
        });

        if !pushed {
            self.outcome = Structure::TooDeep;

            return NONE;
        }

        index
    }

    fn push(&mut self, index: u32) {
        if self.depth >= SCOPE_DEPTH_MAX {
            self.outcome = Structure::TooDeep;

            return;
        }

        self.stack[self.depth as usize] = index;
        self.pending[self.depth as usize] = NONE;
        self.depth += 1;
    }

    fn opened(&mut self, node: u32, kind: GoKind) {
        if matches!(kind, GoKind::FuncDecl | GoKind::FuncLit) {
            let body = self.body(node);

            if kind == GoKind::FuncDecl {
                self.receiver(node, body);
            }

            self.signature(node, body);
        }

        if kind == GoKind::RangeStmt {
            self.range(node);
        }

        if kind == GoKind::TypeSwitchStmt {
            self.guard(node);
        }

        if kind == GoKind::TypeSpec {
            self.type_parameters(node);
        }
    }

    fn before(&mut self, node: u32, kind: GoKind) {
        match Some(kind) {
            Some(GoKind::AssignStmt) => {
                let from = self.end_of(node);

                self.short(node, from);
            }
            Some(GoKind::FuncType) => self.function_type(node),
            Some(GoKind::FuncDecl) => self.function(node),
            Some(GoKind::ImportSpec) => self.import(node),
            Some(GoKind::LabeledStmt) => self.label(node),
            Some(GoKind::TypeSpec) => self.type_spec(node),
            Some(GoKind::ValueSpec) => self.value_spec(node),
            Some(_) | None => {}
        }
    }

    fn body(&mut self, node: u32) -> u32 {
        let parent = self.scope();
        let mut held = NONE;

        for child in self.children(node) {
            if self.kind_of(child) == GoKind::BlockStmt {
                held = child;

                break;
            }
        }

        let index = self.scope_under(parent, held, ScopeKind::Function);

        if index != NONE && held != NONE {
            assert!(self.depth > 0);

            self.pending[self.depth as usize - 1] = index;
        }

        index
    }

    fn signature_of(&self, node: u32) -> u32 {
        for child in self.children(node) {
            if self.kind_of(child) == GoKind::FuncType {
                return child;
            }
        }

        NONE
    }

    fn named_by(&self, signature: u32) -> u32 {
        if signature == NONE {
            return NONE;
        }

        for child in self.children(signature) {
            if self.kind_of(child) == GoKind::Ident {
                return child;
            }
        }

        NONE
    }

    fn function(&mut self, node: u32) {
        let signature = self.signature_of(node);
        let held = self.named_by(signature);

        if held == NONE {
            return;
        }

        let kind = if self.receiver_of(signature) == NONE {
            BindingKind::Function
        } else {
            BindingKind::Method
        };

        let name = self.span_of(held);

        let _ = self.record_in(0, kind, name, held);
    }

    fn receiver_of(&self, signature: u32) -> u32 {
        if signature == NONE {
            return NONE;
        }

        for child in self.children(signature) {
            if self.kind_of(child) == GoKind::Ident {
                return NONE;
            }

            if self.kind_of(child) == GoKind::FieldList {
                return child;
            }
        }

        NONE
    }

    fn receiver(&mut self, node: u32, body: u32) {
        let signature = self.signature_of(node);
        let held = self.receiver_of(signature);

        if held == NONE {
            return;
        }

        self.field_list_in(body, held, BindingKind::Receiver);
        self.receiver_parameters(held);
    }

    fn receiver_parameters(&mut self, node: u32) {
        let mut stack = [NONE; NAME_COUNT_MAX];
        let mut depth = 1;

        stack[0] = node;

        for _ in 0..STEP_MAX {
            if depth == 0 {
                return;
            }

            depth -= 1;

            let held = stack[depth];

            if matches!(
                self.kind_of(held),
                GoKind::IndexExpr | GoKind::IndexListExpr
            ) {
                let mut first = true;

                for child in self.children(held) {
                    if first {
                        first = false;

                        continue;
                    }

                    if self.kind_of(child) != GoKind::Ident {
                        continue;
                    }

                    let name = self.span_of(child);

                    let _ = self.record(BindingKind::TypeParameter, name, child);
                }

                continue;
            }

            for child in self.children(held) {
                if depth >= NAME_COUNT_MAX {
                    return;
                }

                stack[depth] = child;
                depth += 1;
            }
        }
    }

    fn function_type(&mut self, node: u32) {
        let parent = self.tree.at(node).parent;

        if matches!(self.kind_of(parent), GoKind::FuncDecl | GoKind::FuncLit) {
            return;
        }

        let held = self.scope();
        let scope = self.scope_under(held, node, ScopeKind::Function);
        let mut parameters = false;

        for child in self.children(node) {
            if self.kind_of(child) != GoKind::FieldList {
                continue;
            }

            if self.opens_with(child, GoKind::BracketOpen) {
                self.field_list_in(scope, child, BindingKind::TypeParameter);

                continue;
            }

            let kind = if parameters {
                BindingKind::Result
            } else {
                BindingKind::Parameter
            };

            parameters = true;

            self.field_list_in(scope, child, kind);
        }
    }

    fn signature(&mut self, node: u32, body: u32) {
        let signature = self.signature_of(node);

        if signature == NONE {
            return;
        }

        let named = self.named_by(signature);
        let mut seen = named == NONE;
        let mut parameters = false;

        for child in self.children(signature) {
            if child == named {
                seen = true;

                continue;
            }

            if !seen || self.kind_of(child) != GoKind::FieldList {
                continue;
            }

            if self.opens_with(child, GoKind::BracketOpen) {
                self.field_list(child, BindingKind::TypeParameter);

                continue;
            }

            let kind = if parameters {
                BindingKind::Result
            } else {
                BindingKind::Parameter
            };

            parameters = true;

            self.field_list_in(body, child, kind);
        }
    }

    fn opens_with(&self, node: u32, kind: GoKind) -> bool {
        let held = self.tree.at(node);
        let position = self.significant(held.token_start);

        self.raw.get(position as usize).copied() == Some(kind)
    }

    fn field_list(&mut self, node: u32, kind: BindingKind) {
        let scope = self.scope();

        self.field_list_in(scope, node, kind);
    }

    fn field_list_in(&mut self, scope: u32, node: u32, kind: BindingKind) {
        if scope == NONE {
            return;
        }

        for child in self.children(node) {
            if self.kind_of(child) != GoKind::Field {
                continue;
            }

            let mut names = [NONE; NAME_COUNT_MAX];
            let mut count = 0;

            self.leading_names(child, &mut names, &mut count);

            for held in &names[..count] {
                let name = self.span_of(*held);

                let _ = self.record_in(scope, kind, name, *held);
            }
        }
    }

    fn value_spec(&mut self, node: u32) {
        let parent = self.tree.at(node).parent;

        let kind = if self.holds(parent, GoKind::ConstKeyword) {
            BindingKind::Const
        } else {
            BindingKind::Var
        };

        let from = self.end_of(node);
        let mut names = [NONE; NAME_COUNT_MAX];
        let mut count = 0;

        self.leading_names(node, &mut names, &mut count);

        if count == 0 {
            let held = self.child_at(node, 0);

            if self.kind_of(held) == GoKind::Ident {
                let name = self.span_of(held);

                let _ = self.record_from(from, kind, name, held);
            }

            return;
        }

        for held in &names[..count] {
            let name = self.span_of(*held);

            let _ = self.record_from(from, kind, name, *held);
        }
    }

    fn type_spec(&mut self, node: u32) {
        let held = self.child_at(node, 0);

        if self.kind_of(held) != GoKind::Ident {
            return;
        }

        let name = self.span_of(held);

        let _ = self.record(BindingKind::Type, name, held);
    }

    fn type_parameters(&mut self, node: u32) {
        let parameters = self.child_at(node, 1);

        if self.kind_of(parameters) == GoKind::FieldList {
            self.field_list(parameters, BindingKind::TypeParameter);
        }
    }

    fn short(&mut self, node: u32, from: u32) {
        let declares = self.token_of(node, GoKind::ColonEqual);

        if declares == NONE {
            return;
        }

        for child in self.children(node) {
            if self.tree.at(child).token_start >= declares {
                break;
            }

            if self.kind_of(child) != GoKind::Ident {
                continue;
            }

            let name = self.span_of(child);

            if self.declared(name) {
                continue;
            }

            let _ = self.record_from(from, BindingKind::Short, name, child);
        }
    }

    fn range(&mut self, node: u32) {
        let mut from = self.end_of(node);

        for child in self.children(node) {
            if self.kind_of(child) == GoKind::BlockStmt {
                from = self.span_of(child).offset;

                break;
            }
        }

        self.short(node, from);
    }

    fn token_of(&self, node: u32, kind: GoKind) -> u32 {
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

    fn guard(&mut self, node: u32) {
        for child in self.children(node) {
            if self.kind_of(child) != GoKind::AssignStmt {
                continue;
            }

            let held = self.child_at(child, 0);

            if self.kind_of(held) != GoKind::Ident {
                continue;
            }

            let name = self.span_of(held);
            let from = self.end_of(child);

            let _ = self.record_from(from, BindingKind::Short, name, held);
        }
    }

    fn label(&mut self, node: u32) {
        let held = self.child_at(node, 0);

        if self.kind_of(held) != GoKind::Ident {
            return;
        }

        let name = self.span_of(held);

        let _ = self.record(BindingKind::Label, name, held);
    }

    fn import(&mut self, node: u32) {
        let held = self.child_at(node, 0);
        let named = self.kind_of(held) == GoKind::Ident;
        let specifier = self.specifier_of(node);

        let name = if named {
            self.span_of(held)
        } else {
            self.package_of(specifier)
        };

        let text = self.text_of(name);

        let kind = if text == b"_" {
            BindingKind::ImportBlank
        } else if text == b"." {
            BindingKind::ImportDot
        } else {
            BindingKind::Import
        };

        if kind == BindingKind::ImportDot {
            let scope = self.scope();

            self.semantic.scopes[scope as usize].dynamic = true;
        }

        let binding = if kind == BindingKind::Import {
            self.record_in(1, kind, name, node)
        } else {
            NONE
        };

        let recorded = self.semantic.facts.push(Fact {
            binding,
            kind: FactKind::ImportNamed,
            local: name,
            remote: specifier,
            specifier,
        });

        if !recorded && self.outcome == Structure::Complete {
            self.outcome = Structure::Truncated;
        }
    }

    fn specifier_of(&self, node: u32) -> Span {
        for child in self.children(node) {
            if self.kind_of(child) != GoKind::BasicLit {
                continue;
            }

            let held = self.span_of(child);

            if held.length < 2 {
                return held;
            }

            return Span {
                length: held.length - 2,
                offset: held.offset + 1,
            };
        }

        Span::EMPTY
    }

    fn package_of(&self, specifier: Span) -> Span {
        let text = self.text_of(specifier);
        let mut start = 0;

        for (index, byte) in text.iter().enumerate() {
            if *byte == b'/' {
                start = index + 1;
            }
        }

        Span {
            length: specifier.length - count_of(start),
            offset: specifier.offset + count_of(start),
        }
    }

    fn declared(&self, name: Span) -> bool {
        let scope = self.scope();
        let text = self.text_of(name);

        self.semantic
            .binding_in(self.source, scope, text, Namespace::Value)
            != NONE
    }

    fn name(&mut self, node: u32, kind: GoKind) {
        if kind != GoKind::Ident {
            return;
        }

        let name = self.span_of(node);
        let text = self.text_of(name);

        if text == b"_" || !self.reads(node) {
            return;
        }

        let namespace = if self.labelled(node) {
            Namespace::Label
        } else {
            Namespace::Value
        };

        let scope = self.scope();

        let recorded = self.semantic.references.push(Reference {
            context: Context::Load,
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

    fn labelled(&self, node: u32) -> bool {
        let parent = self.tree.at(node).parent;

        self.kind_of(parent) == GoKind::BranchStmt
    }

    fn reads(&self, node: u32) -> bool {
        let parent = self.tree.at(node).parent;
        let kind = self.kind_of(parent);

        if kind == GoKind::File {
            return false;
        }

        if kind == GoKind::FuncType {
            return self.named_by(parent) != node;
        }

        if kind == GoKind::SelectorExpr {
            return self.child_at(parent, 0) == node;
        }

        if kind == GoKind::KeyValueExpr {
            return self.child_at(parent, 0) != node;
        }

        if matches!(
            kind,
            GoKind::Field | GoKind::ImportSpec | GoKind::LabeledStmt | GoKind::TypeSpec
        ) {
            return !self.declares(parent, node);
        }

        if kind == GoKind::ValueSpec {
            return !self.declares(parent, node);
        }

        if matches!(kind, GoKind::AssignStmt | GoKind::RangeStmt) {
            if !self.declares(parent, node) {
                return true;
            }

            return self.declared(self.span_of(node));
        }

        true
    }

    fn declares(&self, parent: u32, node: u32) -> bool {
        let kind = self.kind_of(parent);

        if matches!(kind, GoKind::LabeledStmt | GoKind::TypeSpec) {
            return self.child_at(parent, 0) == node;
        }

        if kind == GoKind::ImportSpec {
            return self.child_at(parent, 0) == node;
        }

        if matches!(kind, GoKind::AssignStmt | GoKind::RangeStmt) {
            let declares = self.token_of(parent, GoKind::ColonEqual);

            return declares != NONE && self.tree.at(node).token_start < declares;
        }

        let mut names = [NONE; NAME_COUNT_MAX];
        let mut count = 0;

        self.leading_names(parent, &mut names, &mut count);

        if count == 0 && kind == GoKind::ValueSpec {
            return self.child_at(parent, 0) == node;
        }

        names[..count].contains(&node)
    }

    fn record(&mut self, kind: BindingKind, name: Span, node: u32) -> u32 {
        self.record_from(name.offset, kind, name, node)
    }

    fn record_from(&mut self, from: u32, kind: BindingKind, name: Span, node: u32) -> u32 {
        let held = self.scope();
        let scope = if held == 1 && kind.hoists() { 0 } else { held };

        self.record_within(scope, from, kind, name, node)
    }

    fn record_in(&mut self, scope: u32, kind: BindingKind, name: Span, node: u32) -> u32 {
        self.record_within(scope, name.offset, kind, name, node)
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

        let opens = if kind == BindingKind::TypeParameter {
            0
        } else {
            from
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

fn bucket_count_of(binding_count_max: u32) -> u32 {
    binding_count_max.next_power_of_two().max(16)
}

const NAME_COUNT_MAX: usize = 1 << 6;
const STEP_MAX: u32 = 1 << 12;

#[cfg(test)]
mod tests {
    use super::*;
    use crate::bounded::BoundedVec as Held;
    use crate::language::Lexer as _;
    use crate::lex::GO;
    use crate::syntax::go::classify::classify;
    use crate::syntax::go::parse;
    use crate::token::Tokens;
    use crate::tree::Events;

    const UNIVERSE: [&[u8]; 12] = [
        b"any",
        b"append",
        b"bool",
        b"error",
        b"false",
        b"int",
        b"len",
        b"make",
        b"nil",
        b"panic",
        b"string",
        b"true",
    ];

    struct Fixture {
        semantic: Semantic,
        source: Vec<u8>,
    }

    impl Fixture {
        fn of(source: &[u8]) -> Self {
            let mut lexed = Tokens::reserve(1 << 14);
            let mut tokens = Tokens::reserve(1 << 14);
            let mut raw = Held::reserve(1 << 14);
            let mut events = Events::reserve(1 << 16);
            let mut tree = Tree::<GoKind>::reserve(1 << 14, 1 << 8);
            let mut semantic = Semantic::reserve(1 << 10, 1 << 12, 1 << 10, 1 << 10);

            GO.lex(source, &mut lexed);

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
    }

    #[test]
    fn a_short_declaration_reads_the_name_that_stood_before_it_inside_its_own_right_hand_side() {
        let fixture = Fixture::of(
            b"package p\n\ntype key struct{}\n\nfunc run() {\n\tkey := make(key)\n\t_ = key\n}\n",
        );

        let references = fixture.references();

        assert!(
            references
                .iter()
                .any(|row| row == "key Value Bound(0) scope 4")
        );

        assert!(
            references
                .iter()
                .any(|row| row == "key Value Bound(2) scope 4")
        );
    }

    #[test]
    fn a_short_declaration_of_a_name_the_scope_already_holds_reads_it_as_well_as_writes_it() {
        let fixture = Fixture::of(
            b"package p\n\nfunc run() (int, int) {\n\tone, two := 1, 2\n\
             \tone, three := 3, 4\n\treturn two + three - one\n}\n",
        );

        assert_eq!(
            fixture
                .bindings()
                .iter()
                .filter(|row| row.starts_with("Short one "))
                .count(),
            1
        );

        assert_eq!(
            fixture
                .references()
                .iter()
                .filter(|row| row.starts_with("one Value Bound(1) "))
                .count(),
            3
        );
    }

    #[test]
    fn a_type_parameter_is_read_by_the_sibling_that_is_written_before_the_word_declaring_it() {
        let fixture = Fixture::of(
            b"package p\n\nfunc run[Map ~map[K]V, K comparable, V any](held Map) {\n\
             \t_ = held\n}\n",
        );

        let bindings = fixture.bindings();

        assert!(
            bindings
                .iter()
                .any(|row| row.starts_with("TypeParameter K ") && row.ends_with(" from 0"))
        );

        assert!(
            fixture
                .references()
                .iter()
                .any(|row| row.starts_with("K Value Bound("))
        );
    }

    #[test]
    fn a_dot_import_leaves_an_unresolved_name_a_maybe_rather_than_a_mistake() {
        let fixture = Fixture::of(
            b"package p\n\nimport (\n\t. \"math\"\n)\n\nfunc run() float64 {\n\treturn Pi\n}\n",
        );

        assert!(fixture.semantic.scopes().iter().any(|held| held.dynamic));

        assert!(
            fixture
                .references()
                .iter()
                .any(|row| row.starts_with("Pi Value Maybe "))
        );
    }

    #[test]
    fn a_parameter_and_a_result_bind_in_the_body_rather_than_in_the_signature() {
        let fixture = Fixture::of(
            b"package p\n\nfunc run(one int) (two int) {\n\ttwo = one\n\n\treturn two\n}\n",
        );

        assert_eq!(
            fixture.bindings(),
            vec![
                "Function run scope 0 from 16".to_owned(),
                "Parameter one scope 3 from 20".to_owned(),
                "Result two scope 3 from 30".to_owned(),
            ]
        );

        assert!(
            fixture
                .references()
                .iter()
                .any(|row| row == "one Value Bound(1) scope 3")
        );
    }

    #[test]
    fn a_method_takes_a_space_of_its_own_and_leaves_the_universe_where_it_was() {
        let fixture = Fixture::of(
            b"package p\n\ntype Directive struct{}\n\nfunc (d Directive) string() string {\n\
             \treturn \"a\"\n}\n\nfunc use() string {\n\treturn string(nil)\n}\n",
        );

        assert!(
            fixture
                .bindings()
                .iter()
                .any(|row| row.starts_with("Method string scope 0 "))
        );

        assert!(
            fixture
                .references()
                .iter()
                .all(|row| !row.starts_with("string") || row.contains("Builtin"))
        );
    }
}
