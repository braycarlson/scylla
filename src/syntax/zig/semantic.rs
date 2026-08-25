use crate::bounded::{BoundedVec, Span};
use crate::syntax::zig::kind::ZigKind;
use crate::syntax::{Fact, FactKind, Facts, name_hash};
use crate::token::Token;
use crate::tree::{NONE, Step, Structure, Tree, walk};

pub const SCOPE_DEPTH_MAX: u32 = 1 << 8;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum BindingKind {
    Capture,
    Const,
    Field,
    Function,
    Label,
    Parameter,
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
    Unresolved,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ScopeKind {
    Block,
    Container,
    Function,
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
    raw: &'run [ZigKind],
    semantic: &'run mut Semantic,
    source: &'run [u8],
    stack: [u32; SCOPE_DEPTH_MAX as usize],
    tokens: &'run [Token],
    tree: &'run Tree<ZigKind>,
}

struct Children<'run> {
    node: u32,
    tree: &'run Tree<ZigKind>,
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
    pub const fn namespace(self) -> Namespace {
        match self {
            Self::Label => Namespace::Label,
            Self::Capture
            | Self::Const
            | Self::Field
            | Self::Function
            | Self::Parameter
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
        raw: &[ZigKind],
        tree: &Tree<ZigKind>,
        universe: &[&[u8]],
    ) -> Structure {
        self.clear();

        let pushed = self.scopes.push(Scope {
            dynamic: false,
            kind: ScopeKind::Container,
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

        while scope != NONE && steps <= SCOPE_DEPTH_MAX {
            let bounded = self.binding_in(source, scope, name, reference);

            if bounded != NONE {
                return Resolution::Bound(bounded);
            }

            scope = self.scopes[scope as usize].parent;
            steps += 1;
        }

        if universe.contains(&name) {
            return Resolution::Builtin;
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

            if held.scope == scope
                && held.namespace == reference.namespace
                && held.from <= reference.name.offset
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

    fn kind_of(&self, node: u32) -> ZigKind {
        if node == NONE {
            return ZigKind::ErrorNode;
        }

        self.tree.at(node).kind
    }

    fn children(&self, node: u32) -> Children<'run> {
        Children {
            node: self.tree.at(node).child_first,
            tree: self.tree,
        }
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

    fn at(&self, position: u32) -> ZigKind {
        self.raw
            .get(position as usize)
            .copied()
            .unwrap_or(ZigKind::ErrorToken)
    }

    fn span_at(&self, position: u32) -> Span {
        self.tokens
            .get(position as usize)
            .map_or(Span::EMPTY, Token::span)
    }

    fn own_next(&self, node: u32, from: u32) -> u32 {
        let held = self.tree.at(node);
        let mut position = from;

        while position < held.token_end {
            let mut skipped = false;

            for child in self.children(node) {
                let inner = self.tree.at(child);

                if position >= inner.token_start && position < inner.token_end {
                    position = inner.token_end;
                    skipped = true;

                    break;
                }
            }

            if skipped {
                continue;
            }

            if self.at(position).is_trivia() {
                position += 1;

                continue;
            }

            return position;
        }

        NONE
    }

    const fn scope_kind_of(kind: ZigKind) -> Option<ScopeKind> {
        match Some(kind) {
            Some(ZigKind::ContainerDecl | ZigKind::ErrorSetDecl) => Some(ScopeKind::Container),
            Some(ZigKind::FnDecl | ZigKind::FnProto) => Some(ScopeKind::Function),
            Some(
                ZigKind::Block
                | ZigKind::Catch
                | ZigKind::Errdefer
                | ZigKind::For
                | ZigKind::If
                | ZigKind::SwitchCase
                | ZigKind::While,
            ) => Some(ScopeKind::Block),
            Some(_) | None => None,
        }
    }

    fn opens(&self, node: u32) -> Option<ScopeKind> {
        let kind = self.kind_of(node);

        if kind == ZigKind::FnProto && self.kind_of(self.parent_of(node)) == ZigKind::FnDecl {
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

    fn before(&mut self, node: u32, kind: ZigKind) {
        match Some(kind) {
            Some(ZigKind::ContainerField) => self.field(node),
            Some(ZigKind::FnDecl | ZigKind::FnProto) => self.function(node),
            Some(ZigKind::VarDecl) => self.variable(node),
            Some(_) | None => {}
        }
    }

    fn after(&mut self, node: u32, kind: ZigKind) {
        match Some(kind) {
            Some(ZigKind::Block) => self.label(node),
            Some(ZigKind::Break | ZigKind::Continue) => self.branch(node),
            Some(ZigKind::FnDecl | ZigKind::FnProto) => self.parameters(node),
            Some(ZigKind::IdentifierNode) => self.name(node),
            Some(
                ZigKind::Catch
                | ZigKind::Errdefer
                | ZigKind::For
                | ZigKind::If
                | ZigKind::SwitchCase
                | ZigKind::While,
            ) => self.captures(node),
            Some(_) | None => {}
        }
    }

    fn variable(&mut self, node: u32) {
        let keyword = self.keyword_of(node, ZigKind::ConstKeyword, ZigKind::VarKeyword);

        if keyword == NONE {
            return;
        }

        let held = self.own_next(node, keyword + 1);

        if held == NONE || self.at(held) != ZigKind::Identifier {
            return;
        }

        let kind = if self.at(keyword) == ZigKind::ConstKeyword {
            BindingKind::Const
        } else {
            BindingKind::Var
        };

        let name = self.span_at(held);
        let from = self.end_of(node);
        let binding = self.record_from(from, kind, name, node);

        self.imported(node, name, binding);
    }

    fn keyword_of(&self, node: u32, one: ZigKind, two: ZigKind) -> u32 {
        let mut position = self.tree.at(node).token_start;

        for _ in 0..STEP_MAX {
            position = self.own_next(node, position);

            if position == NONE {
                return NONE;
            }

            let held = self.at(position);

            if held == one || held == two {
                return position;
            }

            position += 1;
        }

        NONE
    }

    fn imported(&mut self, node: u32, name: Span, binding: u32) {
        let mut specifier = Span::EMPTY;

        for child in self.children(node) {
            if self.kind_of(child) != ZigKind::BuiltinCall {
                continue;
            }

            let held = self.tree.at(child).token_start;

            if self.text_of(self.span_at(held)) != b"@import" {
                continue;
            }

            for inner in self.children(child) {
                if self.kind_of(inner) != ZigKind::StringLiteral {
                    continue;
                }

                specifier = Self::quoted(self.span_of(inner));
            }
        }

        if specifier == Span::EMPTY {
            return;
        }

        self.fact(Fact {
            binding,
            kind: FactKind::ImportNamed,
            local: name,
            remote: specifier,
            specifier,
        });
    }

    fn quoted(held: Span) -> Span {
        if held.length < 2 {
            return held;
        }

        Span {
            length: held.length - 2,
            offset: held.offset + 1,
        }
    }

    fn function(&mut self, node: u32) {
        let signature = self.signature_of(node);

        if signature == NONE {
            return;
        }

        let keyword = self.keyword_of(signature, ZigKind::FnKeyword, ZigKind::FnKeyword);

        if keyword == NONE {
            return;
        }

        let held = self.own_next(signature, keyword + 1);

        if held == NONE || self.at(held) != ZigKind::Identifier {
            return;
        }

        let name = self.span_at(held);
        let from = self.end_of(node);

        let _ = self.record_from(from, BindingKind::Function, name, node);
    }

    fn signature_of(&self, node: u32) -> u32 {
        if self.kind_of(node) == ZigKind::FnDecl {
            return self.proto_of(node);
        }

        if self.kind_of(self.parent_of(node)) == ZigKind::FnDecl {
            return NONE;
        }

        node
    }

    fn parameters(&mut self, node: u32) {
        let held = self.signature_of(node);

        if held == NONE {
            return;
        }

        let mut position = self.tree.at(held).token_start;
        let mut depth = 0;

        for _ in 0..STEP_MAX {
            position = self.own_next(held, position);

            if position == NONE {
                return;
            }

            match Some(self.at(position)) {
                Some(ZigKind::ParenOpen) => depth += 1,
                Some(ZigKind::ParenClose) => depth -= 1,
                Some(ZigKind::Identifier) => {
                    let after = self.own_next(held, position + 1);

                    if depth == 1 && after != NONE && self.at(after) == ZigKind::Colon {
                        let name = self.span_at(position);

                        let _ = self.record_from(0, BindingKind::Parameter, name, held);
                    }
                }
                Some(_) | None => {}
            }

            position += 1;
        }
    }

    fn proto_of(&self, node: u32) -> u32 {
        for child in self.children(node) {
            if self.kind_of(child) == ZigKind::FnProto {
                return child;
            }
        }

        NONE
    }

    fn captures(&mut self, node: u32) {
        let mut position = self.tree.at(node).token_start;
        let mut open = NONE;
        let mut close = NONE;

        for _ in 0..STEP_MAX {
            position = self.own_next(node, position);

            if position == NONE {
                break;
            }

            if self.at(position) == ZigKind::Pipe {
                if open != NONE && close == NONE {
                    close = position;

                    break;
                }

                if open == NONE {
                    open = position;
                }
            }

            position += 1;
        }

        if open == NONE || close == NONE {
            return;
        }

        let from = self.span_at(close).offset + 1;
        let mut held = open + 1;

        while held < close {
            if self.at(held) == ZigKind::Identifier {
                let name = self.span_at(held);

                let _ = self.record_from(from, BindingKind::Capture, name, node);
            }

            held += 1;
        }
    }

    fn field(&mut self, node: u32) {
        let position = self.tree.at(node).token_start;

        if self.at(position) != ZigKind::Identifier {
            return;
        }

        let name = self.span_at(position);

        let _ = self.record_from(0, BindingKind::Field, name, node);
    }

    fn label(&mut self, node: u32) {
        let position = self.tree.at(node).token_start;

        if self.at(position) != ZigKind::Identifier {
            return;
        }

        if self.at(position + 1) != ZigKind::Colon {
            return;
        }

        let name = self.span_at(position);

        let _ = self.record_from(0, BindingKind::Label, name, node);
    }

    fn branch(&mut self, node: u32) {
        let mut position = self.tree.at(node).token_start;
        let mut colon = false;

        for _ in 0..STEP_MAX {
            position = self.own_next(node, position);

            if position == NONE {
                return;
            }

            if self.at(position) == ZigKind::Colon {
                colon = true;
                position += 1;

                continue;
            }

            if colon && self.at(position) == ZigKind::Identifier {
                let name = self.span_at(position);

                self.reference(Context::Load, name, Namespace::Label, node);

                return;
            }

            position += 1;
        }
    }

    fn name(&mut self, node: u32) {
        let parent = self.parent_of(node);

        if self.kind_of(parent) == ZigKind::ContainerField
            && self.tree.at(parent).token_start == self.tree.at(node).token_start
        {
            return;
        }

        let name = self.span_of(node);

        if self.text_of(name) == b"_" {
            return;
        }

        let context = if self.stores(node) {
            Context::Store
        } else {
            Context::Load
        };

        self.reference(context, name, Namespace::Value, node);
    }

    fn stores(&self, node: u32) -> bool {
        let parent = self.parent_of(node);

        if !Self::assigns(self.kind_of(parent)) {
            return false;
        }

        self.tree.at(parent).child_first == node
    }

    const fn assigns(kind: ZigKind) -> bool {
        matches!(
            kind,
            ZigKind::Assign
                | ZigKind::AssignAdd
                | ZigKind::AssignAddSat
                | ZigKind::AssignAddWrap
                | ZigKind::AssignBitAnd
                | ZigKind::AssignBitOr
                | ZigKind::AssignBitXor
                | ZigKind::AssignDestructure
                | ZigKind::AssignDiv
                | ZigKind::AssignMod
                | ZigKind::AssignMul
                | ZigKind::AssignMulSat
                | ZigKind::AssignMulWrap
                | ZigKind::AssignShl
                | ZigKind::AssignShlSat
                | ZigKind::AssignShr
                | ZigKind::AssignSub
                | ZigKind::AssignSubSat
                | ZigKind::AssignSubWrap
        )
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
        if self.text_of(name) == b"_" {
            return NONE;
        }

        let scope = self.scope();
        let held = self.semantic.scopes[scope as usize].kind;
        let opens = if held.is_ordered() { from } else { 0 };
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

const STEP_MAX: u32 = 1 << 12;

#[cfg(test)]
mod tests {
    use super::*;
    use crate::bounded::BoundedVec as Held;
    use crate::language::Lexer as _;
    use crate::lex::ZIG;
    use crate::syntax::zig::classify::classify;
    use crate::syntax::zig::parse;
    use crate::token::Tokens;
    use crate::tree::Events;

    const BLOCKS_BINDINGS: [&str; 9] = [
        "Function run scope 0 from 0",
        "Parameter one scope 1 from 0",
        "Const held scope 2 from 47",
        "Var kept scope 2 from 75",
        "Const held scope 3 from 109",
        "Const value scope 2 from 225",
        "Label blk scope 4 from 0",
        "Const inner scope 4 from 191",
        "Var index scope 2 from 252",
    ];

    const BLOCKS_FACTS: [&str; 0] = [];

    const BLOCKS_REFERENCES: [&str; 19] = [
        "usize Value Builtin scope 1",
        "usize Value Builtin scope 1",
        "one Value Bound(1) scope 2",
        "usize Value Builtin scope 2",
        "held Value Bound(2) scope 2",
        "kept Value Bound(3) scope 3",
        "kept Value Bound(3) scope 3 store",
        "held Value Bound(4) scope 3",
        "kept Value Bound(3) scope 4",
        "blk Label Bound(6) scope 4",
        "inner Value Bound(7) scope 4",
        "usize Value Builtin scope 2",
        "index Value Bound(8) scope 5",
        "value Value Bound(5) scope 5",
        "index Value Bound(8) scope 5 store",
        "kept Value Bound(3) scope 6 store",
        "index Value Bound(8) scope 6",
        "kept Value Bound(3) scope 2",
        "value Value Bound(5) scope 2",
    ];

    const BLOCKS_SCOPES: [&str; 7] = [
        "Container none",
        "Function under 0",
        "Block under 1",
        "Block under 2",
        "Block under 2",
        "Block under 2",
        "Block under 5",
    ];

    const CAPTURES_BINDINGS: [&str; 16] = [
        "Function maybe scope 0 from 0",
        "Parameter value scope 1 from 0",
        "Function risky scope 0 from 0",
        "Parameter value scope 3 from 0",
        "Function teardown scope 0 from 0",
        "Parameter value scope 5 from 0",
        "Function run scope 0 from 0",
        "Parameter items scope 7 from 0",
        "Parameter seed scope 7 from 0",
        "Var held scope 8 from 223",
        "Capture value scope 9 from 254",
        "Capture err scope 11 from 320",
        "Capture item scope 13 from 425",
        "Capture index scope 13 from 425",
        "Capture value scope 15 from 496",
        "Capture other scope 18 from 594",
    ];

    const CAPTURES_FACTS: [&str; 0] = [];

    const CAPTURES_REFERENCES: [&str; 36] = [
        "usize Value Builtin scope 1",
        "usize Value Builtin scope 1",
        "value Value Bound(1) scope 2",
        "usize Value Builtin scope 3",
        "usize Value Builtin scope 3",
        "value Value Bound(3) scope 4",
        "usize Value Builtin scope 5",
        "void Value Builtin scope 5",
        "value Value Bound(5) scope 6",
        "u8 Value Builtin scope 7",
        "usize Value Builtin scope 7",
        "usize Value Builtin scope 7",
        "seed Value Bound(8) scope 8",
        "maybe Value Bound(0) scope 9",
        "held Value Bound(9) scope 9",
        "held Value Bound(9) scope 10 store",
        "value Value Bound(10) scope 10",
        "held Value Bound(9) scope 8 store",
        "risky Value Bound(2) scope 11",
        "held Value Bound(9) scope 11",
        "teardown Value Bound(4) scope 12",
        "seed Value Bound(8) scope 12",
        "err Value Bound(11) scope 12",
        "items Value Bound(7) scope 13",
        "held Value Bound(9) scope 14 store",
        "item Value Bound(12) scope 14",
        "index Value Bound(13) scope 14",
        "maybe Value Bound(0) scope 15",
        "held Value Bound(9) scope 15",
        "held Value Bound(9) scope 16 store",
        "value Value Bound(14) scope 16",
        "held Value Bound(9) scope 8",
        "held Value Bound(9) scope 17 store",
        "held Value Bound(9) scope 18 store",
        "other Value Bound(15) scope 18",
        "held Value Bound(9) scope 8",
    ];

    const CAPTURES_SCOPES: [&str; 19] = [
        "Container none",
        "Function under 0",
        "Block under 1",
        "Function under 0",
        "Block under 3",
        "Function under 0",
        "Block under 5",
        "Function under 0",
        "Block under 7",
        "Block under 8",
        "Block under 9",
        "Block under 8",
        "Block under 11",
        "Block under 8",
        "Block under 13",
        "Block under 8",
        "Block under 15",
        "Block under 8",
        "Block under 8",
    ];

    const CONTAINERS_BINDINGS: [&str; 15] = [
        "Const Shade scope 0 from 0",
        "Field light scope 1 from 0",
        "Field dark scope 1 from 0",
        "Const Holder scope 0 from 0",
        "Field field scope 2 from 0",
        "Field shade scope 2 from 0",
        "Function build scope 2 from 0",
        "Parameter one scope 3 from 0",
        "Function read scope 2 from 0",
        "Parameter self scope 5 from 0",
        "Const Tagged scope 0 from 0",
        "Field light scope 7 from 0",
        "Field dark scope 7 from 0",
        "Const TOP scope 0 from 0",
        "Function top scope 0 from 0",
    ];

    const CONTAINERS_FACTS: [&str; 0] = [];

    const CONTAINERS_REFERENCES: [&str; 16] = [
        "usize Value Builtin scope 2",
        "Shade Value Bound(0) scope 2",
        "usize Value Builtin scope 3",
        "Holder Value Bound(3) scope 3",
        "Holder Value Bound(3) scope 4",
        "one Value Bound(7) scope 4",
        "Holder Value Bound(3) scope 5",
        "usize Value Builtin scope 5",
        "self Value Bound(9) scope 6",
        "TOP Value Bound(13) scope 6",
        "Shade Value Bound(0) scope 7",
        "usize Value Builtin scope 7",
        "usize Value Builtin scope 7",
        "usize Value Builtin scope 0",
        "usize Value Builtin scope 8",
        "TOP Value Bound(13) scope 9",
    ];

    const CONTAINERS_SCOPES: [&str; 10] = [
        "Container none",
        "Container under 0",
        "Container under 0",
        "Function under 2",
        "Block under 3",
        "Function under 2",
        "Block under 5",
        "Container under 0",
        "Function under 0",
        "Block under 8",
    ];

    const DEFERRED_BINDINGS: [&str; 7] = [
        "Function teardown scope 0 from 0",
        "Parameter value scope 1 from 0",
        "Function run scope 0 from 0",
        "Parameter seed scope 3 from 0",
        "Const held scope 4 from 100",
        "Const early scope 6 from 197",
        "Const one scope 7 from 278",
    ];

    const DEFERRED_FACTS: [&str; 0] = [];

    const DEFERRED_REFERENCES: [&str; 13] = [
        "usize Value Builtin scope 1",
        "void Value Builtin scope 1",
        "value Value Bound(1) scope 2",
        "usize Value Builtin scope 3",
        "usize Value Builtin scope 3",
        "seed Value Bound(3) scope 4",
        "teardown Value Bound(0) scope 4",
        "held Value Bound(4) scope 4",
        "teardown Value Bound(0) scope 5",
        "held Value Bound(4) scope 5",
        "early Value Bound(5) scope 6",
        "held Value Bound(4) scope 4",
        "one Value Bound(6) scope 7",
    ];

    const DEFERRED_SCOPES: [&str; 8] = [
        "Container none",
        "Function under 0",
        "Block under 1",
        "Function under 0",
        "Block under 3",
        "Block under 4",
        "Block under 4",
        "Block under 0",
    ];

    const IMPORTS_BINDINGS: [&str; 5] = [
        "Const std scope 0 from 0",
        "Const builtin scope 0 from 0",
        "Const mem scope 0 from 0",
        "Function run scope 0 from 0",
        "Parameter one scope 1 from 0",
    ];

    const IMPORTS_FACTS: [&str; 2] = ["ImportNamed std std", "ImportNamed builtin builtin"];

    const IMPORTS_REFERENCES: [&str; 6] = [
        "std Value Bound(0) scope 0",
        "u8 Value Builtin scope 1",
        "usize Value Builtin scope 1",
        "mem Value Bound(2) scope 2",
        "one Value Bound(4) scope 2",
        "builtin Value Bound(1) scope 2",
    ];

    const IMPORTS_SCOPES: [&str; 3] = ["Container none", "Function under 0", "Block under 1"];

    const EVERY_FIXTURE: [&str; 5] = [
        "blocks.zig",
        "captures.zig",
        "containers.zig",
        "deferred.zig",
        "imports.zig",
    ];

    const UNIVERSE: [&[u8]; 8] = [
        b"bool",
        b"false",
        b"null",
        b"true",
        b"u8",
        b"undefined",
        b"usize",
        b"void",
    ];

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
                .join("tests/fixtures/zig-semantic")
                .join(path);

            let source = std::fs::read(root).expect("the fixture is readable");

            Self::of(&source)
        }

        fn of(source: &[u8]) -> Self {
            let mut lexed = Tokens::reserve(1 << 14);
            let mut tokens = Tokens::reserve(1 << 14);
            let mut raw = Held::reserve(1 << 14);
            let mut events = Events::reserve(1 << 16);
            let mut tree = Tree::<ZigKind>::reserve(1 << 14, 1 << 8);
            let mut semantic = Semantic::reserve(1 << 10, 1 << 12, 1 << 10, 1 << 10);

            ZIG.lex(source, &mut lexed);

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
                    if held.parent == NONE {
                        return format!("{:?} none", held.kind);
                    }

                    format!("{:?} under {}", held.kind, held.parent)
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
    fn a_local_opens_at_the_end_of_the_statement_that_writes_it() {
        let fixture = Fixture::read("blocks.zig");

        assert_eq!(fixture.scopes(), rows(&BLOCKS_SCOPES));
        assert_eq!(fixture.bindings(), rows(&BLOCKS_BINDINGS));
        assert_eq!(fixture.references(), rows(&BLOCKS_REFERENCES));
        assert_eq!(fixture.facts(), rows(&BLOCKS_FACTS));
    }

    #[test]
    fn a_capture_names_its_payload_for_the_body_it_guards() {
        let fixture = Fixture::read("captures.zig");

        assert_eq!(fixture.scopes(), rows(&CAPTURES_SCOPES));
        assert_eq!(fixture.bindings(), rows(&CAPTURES_BINDINGS));
        assert_eq!(fixture.references(), rows(&CAPTURES_REFERENCES));
        assert_eq!(fixture.facts(), rows(&CAPTURES_FACTS));
    }

    #[test]
    fn a_container_declaration_is_read_from_anywhere_in_its_container() {
        let fixture = Fixture::read("containers.zig");

        assert_eq!(fixture.scopes(), rows(&CONTAINERS_SCOPES));
        assert_eq!(fixture.bindings(), rows(&CONTAINERS_BINDINGS));
        assert_eq!(fixture.references(), rows(&CONTAINERS_REFERENCES));
        assert_eq!(fixture.facts(), rows(&CONTAINERS_FACTS));
    }

    #[test]
    fn a_defer_body_reads_the_scope_that_holds_the_defer() {
        let fixture = Fixture::read("deferred.zig");

        assert_eq!(fixture.scopes(), rows(&DEFERRED_SCOPES));
        assert_eq!(fixture.bindings(), rows(&DEFERRED_BINDINGS));
        assert_eq!(fixture.references(), rows(&DEFERRED_REFERENCES));
        assert_eq!(fixture.facts(), rows(&DEFERRED_FACTS));
    }

    #[test]
    fn an_import_binds_through_the_constant_it_is_assigned_to() {
        let fixture = Fixture::read("imports.zig");

        assert_eq!(fixture.scopes(), rows(&IMPORTS_SCOPES));
        assert_eq!(fixture.bindings(), rows(&IMPORTS_BINDINGS));
        assert_eq!(fixture.references(), rows(&IMPORTS_REFERENCES));
        assert_eq!(fixture.facts(), rows(&IMPORTS_FACTS));
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
                .join("tests/fixtures/zig-semantic/containers.zig"),
        )
        .expect("the fixture is readable");

        let mut lexed = Tokens::reserve(1 << 14);
        let mut tokens = Tokens::reserve(1 << 14);
        let mut raw = Held::reserve(1 << 14);
        let mut events = Events::reserve(1 << 16);
        let mut tree = Tree::<ZigKind>::reserve(1 << 14, 1 << 8);
        let mut semantic = Semantic::reserve(2, 2, 2, 2);

        ZIG.lex(&source, &mut lexed);

        assert!(classify(&source, lexed.as_slice(), &mut tokens, &mut raw));

        parse::build(&source, tokens.as_slice(), &raw, &mut events, &mut tree);

        let outcome = semantic.build(&source, tokens.as_slice(), &raw, &tree, &UNIVERSE);

        assert_ne!(outcome, Structure::Complete);
    }

    #[test]
    fn a_bare_enum_field_is_a_declaration_and_not_also_a_reference_to_itself() {
        let fixture = Fixture::of(b"const Colour = enum { red, green };\n");

        assert_eq!(
            fixture
                .bindings()
                .iter()
                .filter(|row| row.starts_with("Field red "))
                .count(),
            1
        );

        assert!(
            !fixture
                .references()
                .iter()
                .any(|row| row.starts_with("red "))
        );
    }
}
