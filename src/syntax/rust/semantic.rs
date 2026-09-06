use crate::bounded::{BoundedVec, Span};
use crate::syntax::rust::kind::RustKind;
use crate::syntax::{Category, Fact, FactKind, Facts, name_hash};
use crate::token::Token;
use crate::tree::{NONE, Step, Structure, Tree, walk};

pub const SCOPE_DEPTH_MAX: u32 = 1 << 8;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum BindingKind {
    AssociatedConst,
    AssociatedFunction,
    AssociatedType,
    Const,
    ConstParameter,
    Enum,
    Field,
    Function,
    Import,
    Label,
    Lifetime,
    Local,
    Macro,
    Module,
    Parameter,
    Static,
    Struct,
    Trait,
    TraitAlias,
    TypeAlias,
    TypeParameter,
    Union,
    Variant,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Context {
    Load,
    Store,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Namespace {
    Label,
    Lifetime,
    Macro,
    Type,
    Value,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Resolution {
    Bound(u32),
    Builtin,
    External,
    Maybe,
    Unresolved,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ScopeKind {
    Block,
    Function,
    Item,
    Module,
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
    pub generic: bool,
    pub name: Span,
    pub namespace: Namespace,
    pub node: u32,
    pub qualified: bool,
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
    raw: &'run [RustKind],
    semantic: &'run mut Semantic,
    source: &'run [u8],
    stack: [u32; SCOPE_DEPTH_MAX as usize],
    tokens: &'run [Token],
    tree: &'run Tree<RustKind>,
}

struct Children<'run> {
    node: u32,
    tree: &'run Tree<RustKind>,
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
        !matches!(self, Self::Local | Self::Macro)
    }

    pub const fn namespace(self) -> Namespace {
        match self {
            Self::Label => Namespace::Label,
            Self::Lifetime => Namespace::Lifetime,
            Self::Macro => Namespace::Macro,
            Self::AssociatedType
            | Self::Enum
            | Self::Module
            | Self::Trait
            | Self::TraitAlias
            | Self::TypeAlias
            | Self::TypeParameter => Namespace::Type,
            Self::AssociatedConst
            | Self::AssociatedFunction
            | Self::Const
            | Self::ConstParameter
            | Self::Field
            | Self::Function
            | Self::Import
            | Self::Local
            | Self::Parameter
            | Self::Static
            | Self::Struct
            | Self::Union
            | Self::Variant => Namespace::Value,
        }
    }

    pub fn opens(self, wanted: Namespace) -> bool {
        match self {
            Self::Import => matches!(
                wanted,
                Namespace::Macro | Namespace::Type | Namespace::Value
            ),
            Self::Struct | Self::Union => matches!(wanted, Namespace::Type | Namespace::Value),
            Self::AssociatedConst | Self::AssociatedFunction | Self::AssociatedType => false,
            Self::Const
            | Self::ConstParameter
            | Self::Enum
            | Self::Field
            | Self::Function
            | Self::Label
            | Self::Lifetime
            | Self::Local
            | Self::Macro
            | Self::Module
            | Self::Parameter
            | Self::Static
            | Self::Trait
            | Self::TraitAlias
            | Self::TypeAlias
            | Self::TypeParameter
            | Self::Variant => self.namespace() == wanted,
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
        raw: &[RustKind],
        tree: &Tree<RustKind>,
        universe: &[&[u8]],
    ) -> Structure {
        self.clear();

        let pushed = self.scopes.push(Scope {
            dynamic: false,
            kind: ScopeKind::Module,
            node: 0,
            parent: NONE,
        });

        assert!(pushed);

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
        let (bounded, glob) = self.placed(source, reference, reference.namespace);

        if bounded != NONE {
            return Resolution::Bound(bounded);
        }

        if reference.generic && reference.namespace != Namespace::Macro {
            let (held, _) = self.placed(source, reference, Namespace::Value);

            if held != NONE {
                return Resolution::Bound(held);
            }
        }

        if universe.contains(&name) {
            return Resolution::Builtin;
        }

        if reference.qualified {
            return Resolution::External;
        }

        if glob {
            return Resolution::Maybe;
        }

        Resolution::Unresolved
    }

    fn placed(&self, source: &[u8], reference: &Reference, wanted: Namespace) -> (u32, bool) {
        let name = &source[reference.name.range()];
        let mut scope = reference.scope;
        let mut steps = 0;
        let mut glob = false;

        while scope != NONE && steps <= SCOPE_DEPTH_MAX {
            let held = self.scopes[scope as usize];
            let bounded = self.binding_in(source, scope, name, wanted, reference);

            if bounded != NONE {
                return (bounded, glob);
            }

            glob = glob || held.dynamic;
            scope = held.parent;
            steps += 1;
        }

        (NONE, glob)
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

    fn binding_in(
        &self,
        source: &[u8],
        scope: u32,
        name: &[u8],
        wanted: Namespace,
        reference: &Reference,
    ) -> u32 {
        let hash = name_hash(name);
        let mut index = self.heads[self.bucket_of(scope, hash)];

        for _ in 0..=self.bindings.count() {
            if index == NONE {
                break;
            }

            let held = self.bindings[index as usize];

            if held.scope == scope
                && held.kind.opens(wanted)
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

    fn kind_of(&self, node: u32) -> RustKind {
        if node == NONE {
            return RustKind::ErrorNode;
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

    fn child_of(&self, node: u32, kind: RustKind) -> u32 {
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

    fn holds(&self, node: u32, kind: RustKind) -> bool {
        let held = self.tree.at(node);

        for position in held.token_start..held.token_end {
            if self.raw[position as usize] == kind {
                return true;
            }
        }

        false
    }

    const fn scope_kind_of(kind: RustKind) -> Option<ScopeKind> {
        match Some(kind) {
            Some(RustKind::ItemMod) => Some(ScopeKind::Module),
            Some(
                RustKind::ExprClosure
                | RustKind::ForeignItemFn
                | RustKind::ImplItemFn
                | RustKind::ItemFn
                | RustKind::TraitItemFn,
            ) => Some(ScopeKind::Function),
            Some(
                RustKind::ItemEnum
                | RustKind::ItemImpl
                | RustKind::ItemStruct
                | RustKind::ItemTrait
                | RustKind::ItemTraitAlias
                | RustKind::ItemType
                | RustKind::ItemUnion,
            ) => Some(ScopeKind::Item),
            Some(
                RustKind::Arm
                | RustKind::Block
                | RustKind::ExprForLoop
                | RustKind::ExprIf
                | RustKind::ExprLoop
                | RustKind::ExprWhile,
            ) => Some(ScopeKind::Block),
            Some(_) | None => None,
        }
    }

    fn opens(&self, node: u32) -> Option<ScopeKind> {
        Self::scope_kind_of(self.kind_of(node))
    }

    fn enter(&mut self, node: u32) {
        let kind = self.kind_of(node);

        self.before(node, kind);

        if let Some(held) = self.opens(node) {
            let written = self.written_of(node, kind);

            if written == NONE {
                self.open(node, held);
            } else {
                self.push(written);
            }
        }

        self.after(node, kind);
    }

    fn written_of(&mut self, node: u32, kind: RustKind) -> u32 {
        if kind != RustKind::Block {
            return NONE;
        }

        let parent = self.parent_of(node);

        if !matches!(
            self.kind_of(parent),
            RustKind::ExprForLoop | RustKind::ExprIf | RustKind::ExprWhile
        ) {
            return NONE;
        }

        if self.child_of(parent, RustKind::Block) != node {
            return NONE;
        }

        assert!(self.depth > 0);

        let held = self.pending[self.depth as usize - 1];

        self.pending[self.depth as usize - 1] = NONE;

        held
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

    fn before(&mut self, node: u32, kind: RustKind) {
        match Some(kind) {
            Some(RustKind::ItemConst) => self.item(node, BindingKind::Const),
            Some(RustKind::ItemEnum) => self.item(node, BindingKind::Enum),
            Some(RustKind::ItemExternCrate) => self.extern_crate(node),
            Some(RustKind::ItemFn) => self.item(node, BindingKind::Function),
            Some(RustKind::ItemMacro) => self.macro_rules(node),
            Some(RustKind::ItemMod) => self.item(node, BindingKind::Module),
            Some(RustKind::ItemStatic) => self.item(node, BindingKind::Static),
            Some(RustKind::ItemStruct) => self.item(node, BindingKind::Struct),
            Some(RustKind::ItemTrait) => self.item(node, BindingKind::Trait),
            Some(RustKind::ItemTraitAlias) => self.item(node, BindingKind::TraitAlias),
            Some(RustKind::ItemType) => self.item(node, BindingKind::TypeAlias),
            Some(RustKind::ItemUnion) => self.item(node, BindingKind::Union),
            Some(RustKind::ImplItemConst) => self.item(node, BindingKind::AssociatedConst),
            Some(RustKind::ImplItemFn) => self.item(node, BindingKind::AssociatedFunction),
            Some(RustKind::ImplItemType) => self.item(node, BindingKind::AssociatedType),
            Some(RustKind::TraitItemConst) => self.item(node, BindingKind::AssociatedConst),
            Some(RustKind::TraitItemFn) => self.item(node, BindingKind::AssociatedFunction),
            Some(RustKind::TraitItemType) => self.item(node, BindingKind::AssociatedType),
            Some(RustKind::ForeignItemFn) => self.item(node, BindingKind::Function),
            Some(RustKind::ForeignItemStatic) => self.item(node, BindingKind::Static),
            Some(RustKind::ForeignItemType) => self.item(node, BindingKind::TypeAlias),
            Some(RustKind::ConstParam) => self.item(node, BindingKind::ConstParameter),
            Some(RustKind::Field) => self.item(node, BindingKind::Field),
            Some(RustKind::TypeParam) => self.item(node, BindingKind::TypeParameter),
            Some(RustKind::Variant) => self.item(node, BindingKind::Variant),
            Some(RustKind::Label) => self.tick(node, BindingKind::Label),
            Some(RustKind::LifetimeParam) => self.tick(node, BindingKind::Lifetime),
            Some(RustKind::PatIdent) => self.pattern(node),
            Some(RustKind::Receiver) => self.receiver(node),
            Some(RustKind::UseGlob) => self.glob(node),
            Some(RustKind::UseName | RustKind::UseRename) => self.import(node, kind),
            Some(_) | None => {}
        }
    }

    fn after(&mut self, node: u32, kind: RustKind) {
        if matches!(
            kind,
            RustKind::ExprForLoop | RustKind::ExprIf | RustKind::ExprWhile
        ) {
            self.guarded(node);

            return;
        }

        if kind == RustKind::Lifetime {
            self.lifetime(node);

            return;
        }

        if kind == RustKind::Ident {
            self.name(node);
        }
    }

    fn guarded(&mut self, node: u32) {
        let body = self.child_of(node, RustKind::Block);

        if body == NONE {
            return;
        }

        let parent = self.scope();
        let index = self.scope_under(parent, body, ScopeKind::Block);

        if index == NONE {
            return;
        }

        assert!(self.depth > 0);

        self.pending[self.depth as usize - 1] = index;
    }

    fn item(&mut self, node: u32, kind: BindingKind) {
        let held = self.named_by(node);

        if held == NONE {
            return;
        }

        let name = self.span_of(held);

        let _ = self.record(kind, name, held);
    }

    fn named_by(&self, node: u32) -> u32 {
        let signature = self.child_of(node, RustKind::Signature);

        if signature != NONE {
            return self.child_of(signature, RustKind::Ident);
        }

        self.child_of(node, RustKind::Ident)
    }

    fn macro_rules(&mut self, node: u32) {
        let held = self.child_of(self.child_of(node, RustKind::Macro), RustKind::Ident);

        if held == NONE {
            return;
        }

        let name = self.span_of(held);

        let from = if self.holds(node, RustKind::MacroKeyword) {
            0
        } else {
            self.end_of(node)
        };

        let _ = self.record_from(from, BindingKind::Macro, name, held);
    }

    fn extern_crate(&mut self, node: u32) {
        let held = self.child_at(node, 0);

        if self.kind_of(held) != RustKind::Ident {
            return;
        }

        let mut name = self.span_of(held);
        let renamed = self.child_at(node, 1);

        if self.kind_of(renamed) == RustKind::Ident {
            name = self.span_of(renamed);
        }

        let binding = self.record(BindingKind::Import, name, held);
        let specifier = self.span_of(held);

        self.fact(Fact {
            binding,
            kind: FactKind::ImportNamed,
            local: name,
            remote: specifier,
            specifier,
        });
    }

    fn import(&mut self, node: u32, kind: RustKind) {
        let first = self.child_at(node, 0);

        if self.kind_of(first) != RustKind::Ident {
            return;
        }

        let remote = self.span_of(first);
        let mut held = first;

        if kind == RustKind::UseRename {
            held = self.child_at(node, 1);

            if self.kind_of(held) != RustKind::Ident {
                return;
            }
        }

        let name = self.span_of(held);
        let binding = self.record(BindingKind::Import, name, held);
        let specifier = self.prefix_of(node);

        self.fact(Fact {
            binding,
            kind: self.import_kind(node),
            local: name,
            remote,
            specifier,
        });
    }

    fn glob(&mut self, node: u32) {
        let scope = self.scope();

        self.semantic.scopes[scope as usize].dynamic = true;

        let specifier = self.prefix_of(node);

        self.fact(Fact {
            binding: NONE,
            kind: FactKind::ImportNamespace,
            local: Span::EMPTY,
            remote: Span::EMPTY,
            specifier,
        });
    }

    fn import_kind(&self, node: u32) -> FactKind {
        let held = self.item_of(node);

        if held != NONE && self.holds(held, RustKind::PubKeyword) {
            return FactKind::Reexport;
        }

        FactKind::ImportNamed
    }

    fn item_of(&self, node: u32) -> u32 {
        let mut held = self.parent_of(node);

        for _ in 0..STEP_MAX {
            if held == NONE {
                return NONE;
            }

            if self.kind_of(held) == RustKind::ItemUse {
                return held;
            }

            held = self.parent_of(held);
        }

        NONE
    }

    fn prefix_of(&self, node: u32) -> Span {
        let mut held = self.parent_of(node);
        let mut first = NONE;
        let mut last = NONE;

        for _ in 0..STEP_MAX {
            if held == NONE {
                break;
            }

            let kind = self.kind_of(held);

            match kind {
                RustKind::UsePath => {
                    let named = self.child_of(held, RustKind::Ident);

                    if named == NONE {
                        break;
                    }

                    if last == NONE {
                        last = named;
                    }

                    first = named;
                }
                RustKind::UseGroup => {}
                _ => break,
            }

            held = self.parent_of(held);
        }

        if first == NONE || last == NONE {
            return Span::EMPTY;
        }

        let start = self.span_of(first).offset;
        let end = self.end_of(last);

        Span {
            length: end - start,
            offset: start,
        }
    }

    fn tick(&mut self, node: u32, kind: BindingKind) {
        let held = self.child_of(node, RustKind::Lifetime);

        if held == NONE {
            return;
        }

        let name = self.span_of(held);

        let _ = self.record(kind, name, held);
    }

    fn receiver(&mut self, node: u32) {
        let held = self.self_of(node);

        if held == NONE {
            return;
        }

        let name = self.span_of(held);

        let _ = self.record(BindingKind::Parameter, name, held);
    }

    fn self_of(&self, node: u32) -> u32 {
        let mut stack = [NONE; DESCENT_MAX];
        let mut depth = 1;

        stack[0] = node;

        for _ in 0..STEP_MAX {
            if depth == 0 {
                return NONE;
            }

            depth -= 1;

            let held = stack[depth];

            if self.kind_of(held) == RustKind::Ident && self.text_of(self.span_of(held)) == b"self"
            {
                return held;
            }

            for child in self.children(held) {
                if depth >= DESCENT_MAX {
                    return NONE;
                }

                stack[depth] = child;
                depth += 1;
            }
        }

        NONE
    }

    fn pattern(&mut self, node: u32) {
        let held = self.child_of(node, RustKind::Ident);

        if held == NONE {
            return;
        }

        let name = self.span_of(held);

        if self.constant(name) && self.children(node).count() == 1 {
            self.reference(Context::Load, name, Namespace::Value, held, false, false);

            return;
        }

        let binder = self.binder_of(node);
        let kind = self.kind_of(binder);

        if matches!(
            kind,
            RustKind::ExprClosure
                | RustKind::ForeignItemFn
                | RustKind::ImplItemFn
                | RustKind::ItemFn
                | RustKind::Signature
                | RustKind::TraitItemFn
        ) {
            let _ = self.record(BindingKind::Parameter, name, held);

            return;
        }

        if kind == RustKind::ExprLet {
            let _ = self.record_from(self.end_of(binder), BindingKind::Local, name, held);

            return;
        }

        if kind == RustKind::ExprForLoop {
            assert!(self.depth > 0);

            let scope = self.pending[self.depth as usize - 1];

            if scope != NONE {
                let _ = self.record_within(scope, name.offset, BindingKind::Local, name, held);

                return;
            }
        }

        let from = self.opening_of(binder, kind);

        let _ = self.record_from(from, BindingKind::Local, name, held);
    }

    fn constant(&self, name: Span) -> bool {
        let text = self.text_of(name);

        text.first().is_some_and(u8::is_ascii_uppercase)
    }

    fn binder_of(&self, node: u32) -> u32 {
        let mut held = self.parent_of(node);

        for _ in 0..STEP_MAX {
            if held == NONE {
                return NONE;
            }

            if matches!(
                self.kind_of(held),
                RustKind::Arm
                    | RustKind::ExprClosure
                    | RustKind::ExprForLoop
                    | RustKind::ExprLet
                    | RustKind::ForeignItemFn
                    | RustKind::ImplItemFn
                    | RustKind::ItemFn
                    | RustKind::Local
                    | RustKind::Signature
                    | RustKind::TraitItemFn
            ) {
                return held;
            }

            held = self.parent_of(held);
        }

        NONE
    }

    fn opening_of(&self, binder: u32, kind: RustKind) -> u32 {
        if kind == RustKind::Arm {
            return self.end_of(self.child_at(binder, 0));
        }

        if kind == RustKind::ExprForLoop {
            let body = self.child_of(binder, RustKind::Block);

            if body != NONE {
                return self.span_of(body).offset;
            }
        }

        if binder == NONE {
            return 0;
        }

        self.end_of(binder)
    }

    fn lifetime(&mut self, node: u32) {
        let parent = self.kind_of(self.parent_of(node));

        if matches!(parent, RustKind::Label | RustKind::LifetimeParam) {
            return;
        }

        let namespace = if matches!(parent, RustKind::ExprBreak | RustKind::ExprContinue) {
            Namespace::Label
        } else {
            Namespace::Lifetime
        };

        let name = self.span_of(node);

        self.reference(Context::Load, name, namespace, node, false, false);
    }

    fn name(&mut self, node: u32) {
        let parent = self.parent_of(node);
        let kind = self.kind_of(parent);

        if kind == RustKind::UsePath {
            self.rooted(node, parent);

            return;
        }

        if kind != RustKind::PathSegment {
            return;
        }

        if self.child_at(parent, 0) != node {
            return;
        }

        let path = self.parent_of(parent);

        if self.child_of(path, RustKind::PathSegment) != parent {
            return;
        }

        if self.decorates(path) || self.receives(path) {
            return;
        }

        let owner = self.parent_of(path);
        let held = self.kind_of(owner);

        if held == RustKind::Macro && self.kind_of(self.parent_of(owner)) == RustKind::ItemMacro {
            return;
        }

        let namespace = Self::namespace_of(held);
        let qualified = self.segments_of(path) > 1;

        let context = if self.stores(owner) {
            Context::Store
        } else {
            Context::Load
        };

        let name = self.span_of(node);

        self.reference(
            context,
            name,
            namespace,
            node,
            qualified,
            self.generic(path),
        );
    }

    fn generic(&self, path: u32) -> bool {
        let mut held = self.parent_of(path);

        for _ in 0..STEP_MAX {
            if held == NONE {
                return false;
            }

            let kind = self.kind_of(held);

            if kind == RustKind::TypePath
                && matches!(
                    self.kind_of(self.parent_of(held)),
                    RustKind::PathSegment | RustKind::TypePath
                )
            {
                return true;
            }

            match kind.category() {
                Category::Name | Category::Type => held = self.parent_of(held),
                Category::Call => return true,
                _ => return false,
            }
        }

        false
    }

    fn rooted(&mut self, node: u32, parent: u32) {
        if self.child_of(parent, RustKind::Ident) != node {
            return;
        }

        if self.kind_of(self.parent_of(parent)) != RustKind::ItemUse {
            return;
        }

        let name = self.span_of(node);

        self.reference(Context::Load, name, Namespace::Type, node, true, false);
    }

    const fn namespace_of(kind: RustKind) -> Namespace {
        match Some(kind) {
            Some(RustKind::Macro) => Namespace::Macro,
            Some(
                RustKind::Constraint
                | RustKind::ExprStruct
                | RustKind::ItemImpl
                | RustKind::PatStruct
                | RustKind::TraitBound
                | RustKind::TypePath,
            ) => Namespace::Type,
            Some(_) | None => Namespace::Value,
        }
    }

    fn receives(&self, node: u32) -> bool {
        let mut held = node;

        for _ in 0..STEP_MAX {
            if held == NONE {
                return false;
            }

            if self.kind_of(held) == RustKind::Receiver {
                return true;
            }

            held = self.parent_of(held);
        }

        false
    }

    fn decorates(&self, node: u32) -> bool {
        let mut held = node;

        for _ in 0..STEP_MAX {
            if held == NONE {
                return false;
            }

            if matches!(
                self.kind_of(held),
                RustKind::Attribute | RustKind::VisRestricted
            ) {
                return true;
            }

            held = self.parent_of(held);
        }

        false
    }

    fn segments_of(&self, path: u32) -> u32 {
        let mut found = 0;

        for child in self.children(path) {
            if self.kind_of(child) == RustKind::PathSegment {
                found += 1;
            }
        }

        found
    }

    fn stores(&self, node: u32) -> bool {
        if self.kind_of(node) != RustKind::ExprPath {
            return false;
        }

        let parent = self.parent_of(node);

        if self.kind_of(parent) != RustKind::ExprAssign {
            return false;
        }

        self.child_at(parent, 0) == node
    }

    fn reference(
        &mut self,
        context: Context,
        name: Span,
        namespace: Namespace,
        node: u32,
        qualified: bool,
        generic: bool,
    ) {
        if self.text_of(name) == b"_" {
            return;
        }

        let scope = self.scope();

        let recorded = self.semantic.references.push(Reference {
            context,
            generic,
            name,
            namespace,
            node,
            qualified,
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

    fn record(&mut self, kind: BindingKind, name: Span, node: u32) -> u32 {
        self.record_from(name.offset, kind, name, node)
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

        let opens = if kind.hoists() { 0 } else { from };
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

const DESCENT_MAX: usize = 1 << 6;

fn bucket_count_of(binding_count_max: u32) -> u32 {
    binding_count_max.next_power_of_two().max(16)
}

const STEP_MAX: u32 = 1 << 12;

#[cfg(test)]
mod tests {
    use super::*;
    use crate::bounded::BoundedVec as Held;
    use crate::language::Lexer as _;
    use crate::lex::RUST;
    use crate::syntax::rust::classify::classify;
    use crate::syntax::rust::parse;
    use crate::token::Tokens;
    use crate::tree::Events;

    const UNIVERSE: [&[u8]; 14] = [
        b"None",
        b"Option",
        b"Self",
        b"Some",
        b"bool",
        b"false",
        b"len",
        b"size_of",
        b"speak",
        b"str",
        b"swap",
        b"true",
        b"u8",
        b"usize",
    ];

    const GENERICS_BINDINGS: [&str; 25] = [
        "Struct Holder scope 0 from 0",
        "TypeParameter T scope 1 from 0",
        "Field field scope 1 from 0",
        "Struct Other scope 0 from 0",
        "TypeParameter T scope 2 from 0",
        "Field field scope 2 from 0",
        "TypeParameter T scope 3 from 0",
        "AssociatedFunction new scope 3 from 0",
        "Parameter field scope 4 from 0",
        "Trait Speak scope 0 from 0",
        "Lifetime 'a scope 6 from 0",
        "TypeParameter T scope 6 from 0",
        "AssociatedFunction speak scope 6 from 0",
        "Parameter self scope 7 from 0",
        "Parameter held scope 7 from 0",
        "Function work scope 0 from 0",
        "Lifetime 'a scope 8 from 0",
        "TypeParameter T scope 8 from 0",
        "ConstParameter N scope 8 from 0",
        "Parameter one scope 8 from 0",
        "Parameter two scope 8 from 0",
        "Local held scope 9 from 317",
        "TypeAlias Pair scope 0 from 0",
        "Lifetime 'a scope 10 from 0",
        "TypeParameter T scope 10 from 0",
    ];

    const GENERICS_FACTS: [&str; 0] = [];

    const GENERICS_REFERENCES: [&str; 27] = [
        "T Type Bound(1) scope 1",
        "T Type Bound(4) scope 2",
        "Holder Type Bound(0) scope 3",
        "T Type Bound(6) scope 3",
        "T Type Bound(6) scope 4",
        "Self Type Builtin scope 4",
        "Holder Type Bound(0) scope 5",
        "field Value Bound(8) scope 5",
        "'a Lifetime Bound(10) scope 7",
        "'a Lifetime Bound(10) scope 7",
        "T Type Bound(11) scope 7",
        "T Type Bound(11) scope 7",
        "Speak Type Bound(9) scope 8",
        "'a Lifetime Bound(16) scope 8",
        "usize Type Builtin scope 8",
        "usize Type Builtin scope 8",
        "T Type Bound(17) scope 8",
        "'a Lifetime Bound(16) scope 8",
        "str Type Builtin scope 8",
        "usize Type Builtin scope 8",
        "N Value Bound(18) scope 9",
        "one Value Bound(19) scope 9",
        "held Value Bound(21) scope 9",
        "two Value Bound(20) scope 9",
        "'a Lifetime Bound(23) scope 10",
        "T Type Bound(24) scope 10",
        "T Type Bound(24) scope 10",
    ];

    const GENERICS_SCOPES: [&str; 11] = [
        "Module none",
        "Item under 0",
        "Item under 0",
        "Item under 0",
        "Function under 3",
        "Block under 4",
        "Item under 0",
        "Function under 6",
        "Function under 0",
        "Block under 8",
        "Item under 0",
    ];

    const ITEMS_BINDINGS: [&str; 25] = [
        "Const TOP scope 0 from 0",
        "Static NAME scope 0 from 0",
        "Struct Holder scope 0 from 0",
        "Field field scope 1 from 0",
        "Struct Wrapper scope 0 from 0",
        "Enum Shade scope 0 from 0",
        "Variant Light scope 3 from 0",
        "Variant Dark scope 3 from 0",
        "Union Bits scope 0 from 0",
        "Field one scope 4 from 0",
        "Trait Speak scope 0 from 0",
        "AssociatedConst LOUD scope 5 from 0",
        "AssociatedType Out scope 5 from 0",
        "AssociatedFunction speak scope 5 from 0",
        "Parameter self scope 6 from 0",
        "AssociatedConst LOUD scope 7 from 0",
        "AssociatedType Out scope 7 from 0",
        "AssociatedFunction speak scope 7 from 0",
        "Parameter self scope 8 from 0",
        "TypeAlias Alias scope 0 from 0",
        "Module inner scope 0 from 0",
        "Const SIZE scope 11 from 0",
        "Function size scope 11 from 0",
        "Const SIZE scope 0 from 0",
        "Function build scope 0 from 0",
    ];

    const ITEMS_FACTS: [&str; 0] = [];

    const ITEMS_REFERENCES: [&str; 23] = [
        "usize Type Builtin scope 0",
        "SIZE Value Bound(23) scope 0",
        "str Type Builtin scope 0",
        "usize Type Builtin scope 1",
        "usize Type Builtin scope 2",
        "u8 Type Builtin scope 3",
        "u8 Type Builtin scope 4",
        "bool Type Builtin scope 5",
        "Self Type Builtin scope 6",
        "Speak Type Bound(10) scope 7",
        "Holder Type Bound(2) scope 7",
        "bool Type Builtin scope 7",
        "usize Type Builtin scope 7",
        "Self Type Builtin scope 8",
        "self Value Bound(18) scope 9",
        "Holder Type Bound(2) scope 10",
        "usize Type Builtin scope 11",
        "usize Type Builtin scope 12",
        "SIZE Value Bound(21) scope 13",
        "usize Type Builtin scope 0",
        "Wrapper Type Bound(4) scope 14",
        "Wrapper Value Bound(4) scope 15",
        "TOP Value Bound(0) scope 15",
    ];

    const ITEMS_SCOPES: [&str; 16] = [
        "Module none",
        "Item under 0",
        "Item under 0",
        "Item under 0",
        "Item under 0",
        "Item under 0",
        "Function under 5",
        "Item under 0",
        "Function under 7",
        "Block under 8",
        "Item under 0",
        "Module under 0",
        "Function under 11",
        "Block under 12",
        "Function under 0",
        "Block under 14",
    ];

    const LABELS_BINDINGS: [&str; 6] = [
        "Function run scope 0 from 0",
        "Parameter limit scope 1 from 0",
        "Local held scope 2 from 53",
        "Label 'outer scope 3 from 0",
        "Label 'inner scope 5 from 0",
        "Local item scope 8 from 127",
    ];

    const LABELS_FACTS: [&str; 0] = [];

    const LABELS_REFERENCES: [&str; 11] = [
        "usize Type Builtin scope 1",
        "usize Type Builtin scope 1",
        "held Value Bound(2) scope 5",
        "limit Value Bound(1) scope 5",
        "limit Value Bound(1) scope 7",
        "item Value Bound(5) scope 9",
        "'outer Label Bound(3) scope 10",
        "item Value Bound(5) scope 11",
        "'inner Label Bound(4) scope 12",
        "held Value Bound(2) scope 6",
        "held Value Bound(2) scope 2",
    ];

    const LABELS_SCOPES: [&str; 13] = [
        "Module none",
        "Function under 0",
        "Block under 1",
        "Block under 2",
        "Block under 3",
        "Block under 4",
        "Block under 5",
        "Block under 6",
        "Block under 7",
        "Block under 8",
        "Block under 9",
        "Block under 8",
        "Block under 11",
    ];

    const LOCALS_BINDINGS: [&str; 24] = [
        "Function run scope 0 from 0",
        "Parameter one scope 1 from 0",
        "Parameter two scope 1 from 0",
        "Local held scope 2 from 61",
        "Local held scope 2 from 88",
        "Local left scope 2 from 125",
        "Local right scope 2 from 125",
        "Local left scope 3 from 158",
        "Function shadow scope 0 from 0",
        "Local held scope 5 from 230",
        "Local held scope 5 from 251",
        "Function guarded scope 0 from 0",
        "Parameter value scope 6 from 0",
        "Local found scope 7 from 368",
        "Local inner scope 9 from 400",
        "Local one scope 11 from 475",
        "Function walked scope 0 from 0",
        "Parameter items scope 13 from 0",
        "Local total scope 14 from 572",
        "Local item scope 16 from 582",
        "Function closed scope 0 from 0",
        "Parameter one scope 17 from 0",
        "Local held scope 18 from 717",
        "Parameter two scope 19 from 0",
    ];

    const LOCALS_FACTS: [&str; 0] = [];

    const LOCALS_REFERENCES: [&str; 38] = [
        "usize Type Builtin scope 1",
        "usize Type Builtin scope 1",
        "usize Type Builtin scope 1",
        "one Value Bound(1) scope 2",
        "held Value Bound(3) scope 2",
        "two Value Bound(2) scope 2",
        "held Value Bound(4) scope 2",
        "one Value Bound(1) scope 2",
        "right Value Bound(6) scope 3",
        "left Value Bound(7) scope 3",
        "usize Type Builtin scope 4",
        "held Value Bound(9) scope 5",
        "held Value Bound(10) scope 5",
        "Option Type Builtin scope 6",
        "usize Type Builtin scope 6",
        "usize Type Builtin scope 6",
        "Some Value Builtin scope 7",
        "value Value Bound(12) scope 7",
        "Some Value Builtin scope 9",
        "value Value Bound(12) scope 9",
        "inner Value Bound(14) scope 10",
        "found Value Bound(13) scope 10",
        "value Value Bound(12) scope 7",
        "Some Value Builtin scope 11",
        "one Value Bound(15) scope 11",
        "None Value Builtin scope 12",
        "usize Type Builtin scope 13",
        "usize Type Builtin scope 13",
        "items Value Bound(17) scope 15",
        "total Value Bound(18) scope 16",
        "item Value Bound(19) scope 16",
        "total Value Bound(18) scope 14",
        "usize Type Builtin scope 17",
        "usize Type Builtin scope 17",
        "usize Type Builtin scope 19",
        "one Value Bound(21) scope 19",
        "two Value Bound(23) scope 19",
        "held Value Bound(22) scope 18",
    ];

    const LOCALS_SCOPES: [&str; 20] = [
        "Module none",
        "Function under 0",
        "Block under 1",
        "Block under 2",
        "Function under 0",
        "Block under 4",
        "Function under 0",
        "Block under 6",
        "Block under 7",
        "Block under 7",
        "Block under 9",
        "Block under 7",
        "Block under 7",
        "Function under 0",
        "Block under 13",
        "Block under 14",
        "Block under 15",
        "Function under 0",
        "Block under 17",
        "Function under 18",
    ];

    const MACROS_BINDINGS: [&str; 4] = [
        "Macro shout scope 0 from 51",
        "Function run scope 0 from 0",
        "Function early scope 0 from 0",
        "Macro whisper scope 0 from 182",
    ];

    const MACROS_FACTS: [&str; 0] = [];

    const MACROS_REFERENCES: [&str; 4] = [
        "usize Type Builtin scope 1",
        "shout Macro Bound(0) scope 2",
        "usize Type Builtin scope 3",
        "whisper Macro Unresolved scope 4",
    ];

    const MACROS_SCOPES: [&str; 5] = [
        "Module none",
        "Function under 0",
        "Block under 1",
        "Function under 0",
        "Block under 3",
    ];

    const PATHS_BINDINGS: [&str; 7] = [
        "Struct Holder scope 0 from 0",
        "Field field scope 1 from 0",
        "Function run scope 0 from 0",
        "Local held scope 3 from 92",
        "Function reach scope 0 from 0",
        "Function stored scope 0 from 0",
        "Parameter held scope 6 from 0",
    ];

    const PATHS_FACTS: [&str; 0] = [];

    const PATHS_REFERENCES: [&str; 14] = [
        "usize Type Builtin scope 1",
        "usize Type Builtin scope 2",
        "Holder Type Bound(0) scope 3",
        "held Value Bound(3) scope 3",
        "usize Type Builtin scope 4",
        "crate Value External scope 5",
        "super Value External scope 5",
        "std Value External scope 5",
        "usize Type Builtin scope 5",
        "missing Value Unresolved scope 5",
        "usize Type Builtin scope 6",
        "usize Type Builtin scope 6",
        "held Value Bound(6) scope 7 store",
        "held Value Bound(6) scope 7",
    ];

    const PATHS_SCOPES: [&str; 8] = [
        "Module none",
        "Item under 0",
        "Function under 0",
        "Block under 2",
        "Function under 0",
        "Block under 4",
        "Function under 0",
        "Block under 6",
    ];

    const USES_BINDINGS: [&str; 15] = [
        "Import HashMap scope 0 from 0",
        "Import Load scope 0 from 0",
        "Import Write scope 0 from 0",
        "Import swap scope 0 from 0",
        "Import Held scope 0 from 0",
        "Import Kept scope 0 from 0",
        "Import serde scope 0 from 0",
        "Module inner scope 0 from 0",
        "Struct Held scope 1 from 0",
        "Struct Kept scope 1 from 0",
        "Function run scope 0 from 0",
        "Parameter map scope 4 from 0",
        "Parameter sink scope 4 from 0",
        "Parameter held scope 4 from 0",
        "Function maybe scope 0 from 0",
    ];

    const USES_FACTS: [&str; 8] = [
        "ImportNamed HashMap HashMap std::collections",
        "ImportNamed Load Read std::io",
        "ImportNamed Write Write std::io",
        "ImportNamespace . . std::fmt",
        "Reexport swap swap std::mem",
        "ImportNamed Held Held crate::inner",
        "ImportNamed Kept Kept self::inner",
        "ImportNamed serde serde serde",
    ];

    const USES_REFERENCES: [&str; 16] = [
        "std Type External scope 0",
        "std Type External scope 0",
        "std Type External scope 0",
        "std Type External scope 0",
        "crate Type External scope 0",
        "self Type External scope 0",
        "HashMap Type Bound(0) scope 4",
        "Write Type Bound(2) scope 4",
        "Held Type Bound(4) scope 4",
        "Load Type Bound(1) scope 4",
        "swap Value Bound(3) scope 5",
        "map Value Bound(11) scope 5",
        "sink Value Bound(12) scope 5",
        "Kept Value Bound(5) scope 5",
        "usize Type Builtin scope 6",
        "unknown Value Maybe scope 7",
    ];

    const USES_SCOPES: [&str; 8] = [
        "Module none glob",
        "Module under 0",
        "Item under 1",
        "Item under 1",
        "Function under 0",
        "Block under 4",
        "Function under 0",
        "Block under 6",
    ];

    const EVERY_FIXTURE: [&str; 7] = [
        "generics.rs",
        "items.rs",
        "labels.rs",
        "locals.rs",
        "macros.rs",
        "paths.rs",
        "uses.rs",
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
                .join("tests/fixtures/rust-semantic")
                .join(path);

            let source = std::fs::read(root).expect("the fixture is readable");

            Self::of(&source)
        }

        fn of(source: &[u8]) -> Self {
            let mut lexed = Tokens::reserve(1 << 14);
            let mut tokens = Tokens::reserve(1 << 14);
            let mut raw = Held::reserve(1 << 14);
            let mut events = Events::reserve(1 << 16);
            let mut tree = Tree::<RustKind>::reserve(1 << 14, 1 << 8);
            let mut semantic = Semantic::reserve(1 << 10, 1 << 12, 1 << 10, 1 << 10);

            RUST.lex(source, &mut lexed);

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
                    let dynamic = if held.dynamic { " glob" } else { "" };

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
                        Resolution::External => "External".to_owned(),
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
                        "{} {} {} {}",
                        held.kind.name(),
                        self.field_of(held.local),
                        self.field_of(held.remote),
                        self.field_of(held.specifier),
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
    }

    #[test]
    fn a_generic_names_its_parameters_for_itself_and_no_sibling() {
        let fixture = Fixture::read("generics.rs");

        assert_eq!(fixture.scopes(), rows(&GENERICS_SCOPES));
        assert_eq!(fixture.bindings(), rows(&GENERICS_BINDINGS));
        assert_eq!(fixture.references(), rows(&GENERICS_REFERENCES));
        assert_eq!(fixture.facts(), rows(&GENERICS_FACTS));
    }

    #[test]
    fn an_item_is_read_from_anywhere_in_the_block_that_holds_it() {
        let fixture = Fixture::read("items.rs");

        assert_eq!(fixture.scopes(), rows(&ITEMS_SCOPES));
        assert_eq!(fixture.bindings(), rows(&ITEMS_BINDINGS));
        assert_eq!(fixture.references(), rows(&ITEMS_REFERENCES));
        assert_eq!(fixture.facts(), rows(&ITEMS_FACTS));
    }

    #[test]
    fn a_label_is_read_inside_the_loop_that_writes_it() {
        let fixture = Fixture::read("labels.rs");

        assert_eq!(fixture.scopes(), rows(&LABELS_SCOPES));
        assert_eq!(fixture.bindings(), rows(&LABELS_BINDINGS));
        assert_eq!(fixture.references(), rows(&LABELS_REFERENCES));
        assert_eq!(fixture.facts(), rows(&LABELS_FACTS));
    }

    #[test]
    fn a_local_opens_at_the_end_of_the_statement_that_writes_it() {
        let fixture = Fixture::read("locals.rs");

        assert_eq!(fixture.scopes(), rows(&LOCALS_SCOPES));
        assert_eq!(fixture.bindings(), rows(&LOCALS_BINDINGS));
        assert_eq!(fixture.references(), rows(&LOCALS_REFERENCES));
        assert_eq!(fixture.facts(), rows(&LOCALS_FACTS));
    }

    #[test]
    fn a_macro_is_read_below_its_definition_and_nowhere_above_it() {
        let fixture = Fixture::read("macros.rs");

        assert_eq!(fixture.scopes(), rows(&MACROS_SCOPES));
        assert_eq!(fixture.bindings(), rows(&MACROS_BINDINGS));
        assert_eq!(fixture.references(), rows(&MACROS_REFERENCES));
        assert_eq!(fixture.facts(), rows(&MACROS_FACTS));
    }

    #[test]
    fn a_first_segment_this_file_does_not_declare_names_another_crate() {
        let fixture = Fixture::read("paths.rs");

        assert_eq!(fixture.scopes(), rows(&PATHS_SCOPES));
        assert_eq!(fixture.bindings(), rows(&PATHS_BINDINGS));
        assert_eq!(fixture.references(), rows(&PATHS_REFERENCES));
        assert_eq!(fixture.facts(), rows(&PATHS_FACTS));
    }

    #[test]
    fn a_use_tree_binds_its_last_segment_and_records_the_path_it_came_from() {
        let fixture = Fixture::read("uses.rs");

        assert_eq!(fixture.scopes(), rows(&USES_SCOPES));
        assert_eq!(fixture.bindings(), rows(&USES_BINDINGS));
        assert_eq!(fixture.references(), rows(&USES_REFERENCES));
        assert_eq!(fixture.facts(), rows(&USES_FACTS));
    }

    #[test]
    fn a_bare_call_reads_past_an_associated_item_of_the_same_name() {
        let source = b"fn helper(a: u32) -> u32 { a }\n\nstruct S;\n\n\
            impl S {\n    fn helper(&self, a: u32) -> u32 {\n        helper(a)\n    }\n}\n";
        let fixture = Fixture::of(source);

        let held = fixture
            .semantic
            .references()
            .iter()
            .find(|reference| {
                fixture.text_of(reference.name) == "helper"
                    && reference.namespace == Namespace::Value
            })
            .expect("the call is a reference");

        let Resolution::Bound(index) = held.resolution else {
            panic!("{:?}", fixture.references());
        };

        assert_eq!(
            fixture.semantic.bindings()[index as usize].kind,
            BindingKind::Function,
            "{:?}",
            fixture.references()
        );
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
                .join("tests/fixtures/rust-semantic/items.rs"),
        )
        .expect("the fixture is readable");

        let mut lexed = Tokens::reserve(1 << 14);
        let mut tokens = Tokens::reserve(1 << 14);
        let mut raw = Held::reserve(1 << 14);
        let mut events = Events::reserve(1 << 16);
        let mut tree = Tree::<RustKind>::reserve(1 << 14, 1 << 8);
        let mut semantic = Semantic::reserve(4, 4, 4, 4);

        RUST.lex(&source, &mut lexed);

        assert!(classify(&source, lexed.as_slice(), &mut tokens, &mut raw));

        parse::build(&source, tokens.as_slice(), &raw, &mut events, &mut tree);

        let outcome = semantic.build(&source, tokens.as_slice(), &raw, &tree, &UNIVERSE);

        assert_ne!(outcome, Structure::Complete);
    }
}
