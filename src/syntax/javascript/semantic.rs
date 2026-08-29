use crate::bounded::{BoundedVec, Span, count_of};
use crate::syntax::javascript::kind::JavaScriptKind;
use crate::syntax::typescript::kind::TypeScriptKind;
use crate::syntax::{Fact, FactKind, Facts, name_hash};
use crate::token::Token;
use crate::tree::{Kind, NONE, Step, Structure, Tree, walk};

pub const PATTERN_DEPTH_MAX: u32 = 1 << 8;

#[derive(Clone, Copy, Debug, Eq, Hash, Ord, PartialEq, PartialOrd)]
pub enum Role {
    Ambient,
    Arguments,
    ArrayPattern,
    ArrowFunction,
    AssignmentExpression,
    AssignmentPattern,
    AsyncKeyword,
    AugmentedAssignment,
    CallExpression,
    CallSignature,
    CatchClause,
    Class,
    ClassBody,
    ClassDeclaration,
    ClassStaticBlock,
    Comma,
    Comment,
    ConstKeyword,
    Constant,
    DefaultKeyword,
    EnumBody,
    EnumDeclaration,
    Equal,
    ExportClause,
    ExportSpecifier,
    ExportStatement,
    ExpressionStatement,
    FieldDefinition,
    ForInStatement,
    ForStatement,
    FormalParameters,
    FunctionDeclaration,
    FunctionExpression,
    FunctionSignature,
    FunctionType,
    Identifier,
    IdentifierNode,
    ImportAlias,
    ImportClause,
    ImportRequire,
    ImportSpecifier,
    ImportStatement,
    IndexSignature,
    InferType,
    InterfaceDeclaration,
    JsxTag,
    LabeledStatement,
    LetKeyword,
    LexicalDeclaration,
    MemberExpression,
    MethodDefinition,
    MethodSignature,
    Modifier,
    NamedImports,
    Namespace,
    NamespaceExport,
    NamespaceImport,
    NestedType,
    ObjectAssignmentPattern,
    ObjectPattern,
    Other,
    Pair,
    PairPattern,
    Parameter,
    Program,
    PropertyIdentifier,
    RestPattern,
    SequenceExpression,
    ShorthandPatternName,
    ShorthandProperty,
    Star,
    StatementBlock,
    StatementIdentifier,
    StringNode,
    SwitchBody,
    TypeAliasDeclaration,
    TypeIdentifier,
    TypeParameter,
    TypeParameters,
    TypePredicate,
    TypeQuery,
    UpdateExpression,
    VarKeyword,
    VariableDeclaration,
    VariableDeclarator,
    WithStatement,
}

pub trait Kinds: Copy + Eq {
    fn role(self) -> Role;
}

static JAVASCRIPT_ROLES: [Role; crate::syntax::javascript::kind::KIND_COUNT as usize] = [
    Role::Other,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::AsyncKeyword,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::Comma,
    Role::Comment,
    Role::ConstKeyword,
    Role::Other,
    Role::Other,
    Role::DefaultKeyword,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::Equal,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::Identifier,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::LetKeyword,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::Star,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::VarKeyword,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::Arguments,
    Role::Other,
    Role::ArrayPattern,
    Role::ArrowFunction,
    Role::AssignmentExpression,
    Role::AssignmentPattern,
    Role::AugmentedAssignment,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::CallExpression,
    Role::CatchClause,
    Role::Class,
    Role::ClassBody,
    Role::ClassDeclaration,
    Role::Other,
    Role::ClassStaticBlock,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::ExportClause,
    Role::ExportSpecifier,
    Role::ExportStatement,
    Role::ExpressionStatement,
    Role::Other,
    Role::FieldDefinition,
    Role::Other,
    Role::ForInStatement,
    Role::ForStatement,
    Role::FormalParameters,
    Role::FunctionDeclaration,
    Role::FunctionExpression,
    Role::FunctionExpression,
    Role::FunctionDeclaration,
    Role::IdentifierNode,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::ImportClause,
    Role::ImportSpecifier,
    Role::ImportStatement,
    Role::Other,
    Role::JsxTag,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::JsxTag,
    Role::JsxTag,
    Role::Other,
    Role::LabeledStatement,
    Role::LexicalDeclaration,
    Role::MemberExpression,
    Role::Other,
    Role::MethodDefinition,
    Role::NamedImports,
    Role::NamespaceExport,
    Role::NamespaceImport,
    Role::Other,
    Role::Other,
    Role::Constant,
    Role::Other,
    Role::ObjectAssignmentPattern,
    Role::ObjectPattern,
    Role::Other,
    Role::Pair,
    Role::PairPattern,
    Role::Other,
    Role::Other,
    Role::Program,
    Role::PropertyIdentifier,
    Role::Constant,
    Role::RestPattern,
    Role::Other,
    Role::SequenceExpression,
    Role::ShorthandProperty,
    Role::ShorthandPatternName,
    Role::Other,
    Role::StatementBlock,
    Role::StatementIdentifier,
    Role::StringNode,
    Role::Other,
    Role::Other,
    Role::SwitchBody,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::Constant,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::UpdateExpression,
    Role::VariableDeclaration,
    Role::VariableDeclarator,
    Role::Other,
    Role::WithStatement,
    Role::Other,
];

impl Kinds for JavaScriptKind {
    fn role(self) -> Role {
        JAVASCRIPT_ROLES[self.to_u16() as usize]
    }
}

static TYPESCRIPT_ROLES: [Role; crate::syntax::typescript::kind::KIND_COUNT as usize] = [
    Role::Other,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::AsyncKeyword,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::Comma,
    Role::Comment,
    Role::ConstKeyword,
    Role::Other,
    Role::Other,
    Role::DefaultKeyword,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::Equal,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::Identifier,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::LetKeyword,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::Star,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::VarKeyword,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::ClassDeclaration,
    Role::MethodSignature,
    Role::Modifier,
    Role::Other,
    Role::Ambient,
    Role::Arguments,
    Role::Other,
    Role::ArrayPattern,
    Role::Other,
    Role::ArrowFunction,
    Role::Other,
    Role::TypePredicate,
    Role::Other,
    Role::AssignmentExpression,
    Role::AssignmentPattern,
    Role::AugmentedAssignment,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::CallExpression,
    Role::CallSignature,
    Role::CatchClause,
    Role::Class,
    Role::ClassBody,
    Role::ClassDeclaration,
    Role::Other,
    Role::ClassStaticBlock,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::CallSignature,
    Role::FunctionType,
    Role::Other,
    Role::Other,
    Role::Modifier,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::EnumBody,
    Role::EnumDeclaration,
    Role::Other,
    Role::Other,
    Role::ExportClause,
    Role::ExportSpecifier,
    Role::ExportStatement,
    Role::ExpressionStatement,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::ForInStatement,
    Role::ForStatement,
    Role::FormalParameters,
    Role::FunctionDeclaration,
    Role::FunctionExpression,
    Role::FunctionSignature,
    Role::FunctionType,
    Role::FunctionExpression,
    Role::FunctionDeclaration,
    Role::Other,
    Role::IdentifierNode,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::ImportAlias,
    Role::Other,
    Role::ImportClause,
    Role::ImportRequire,
    Role::ImportSpecifier,
    Role::ImportStatement,
    Role::IndexSignature,
    Role::Other,
    Role::InferType,
    Role::Other,
    Role::Other,
    Role::InterfaceDeclaration,
    Role::Namespace,
    Role::Other,
    Role::Other,
    Role::JsxTag,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::JsxTag,
    Role::JsxTag,
    Role::Other,
    Role::LabeledStatement,
    Role::LexicalDeclaration,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::MemberExpression,
    Role::Other,
    Role::MethodDefinition,
    Role::MethodSignature,
    Role::Namespace,
    Role::NamedImports,
    Role::NamespaceExport,
    Role::NamespaceImport,
    Role::MemberExpression,
    Role::NestedType,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::Constant,
    Role::Other,
    Role::ObjectAssignmentPattern,
    Role::ObjectPattern,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::Parameter,
    Role::Other,
    Role::Modifier,
    Role::Pair,
    Role::PairPattern,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::Program,
    Role::PropertyIdentifier,
    Role::Other,
    Role::FieldDefinition,
    Role::Other,
    Role::Constant,
    Role::Parameter,
    Role::RestPattern,
    Role::RestPattern,
    Role::Other,
    Role::Other,
    Role::SequenceExpression,
    Role::ShorthandProperty,
    Role::ShorthandPatternName,
    Role::Other,
    Role::StatementBlock,
    Role::StatementIdentifier,
    Role::StringNode,
    Role::Other,
    Role::Other,
    Role::SwitchBody,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::Constant,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::TypeAliasDeclaration,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::TypeIdentifier,
    Role::TypeParameter,
    Role::TypeParameters,
    Role::TypePredicate,
    Role::Other,
    Role::TypeQuery,
    Role::Other,
    Role::Other,
    Role::Other,
    Role::UpdateExpression,
    Role::VariableDeclaration,
    Role::VariableDeclarator,
    Role::Other,
    Role::WithStatement,
    Role::Other,
];

impl Kinds for TypeScriptKind {
    fn role(self) -> Role {
        TYPESCRIPT_ROLES[self.to_u16() as usize]
    }
}

pub const SCOPE_DEPTH_MAX: u32 = 1 << 8;
pub const PARAMETER_NONE: u8 = u8::MAX;
pub const PARAMETER_MAX: u8 = u8::MAX - 1;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum BindingKind {
    CatchParameter,
    Class,
    Const,
    Enum,
    EnumMember,
    Function,
    Import,
    ImportDefault,
    ImportNamespace,
    ImportType,
    Interface,
    Let,
    Namespace,
    Parameter,
    ParameterProperty,
    Signature,
    TypeAlias,
    TypeParameter,
    Var,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Context {
    Load,
    Store,
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub enum ModuleKind {
    Module,
    #[default]
    Script,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Namespace {
    Any,
    Type,
    Value,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum Target {
    Bind { kind: BindingKind, zone: u32 },
    Export,
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
    Ambient,
    Block,
    Catch,
    Class,
    Function,
    Global,
    Module,
    With,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Binding {
    pub dead_zone_end: u32,
    pub hoisted: bool,
    pub kind: BindingKind,
    pub name: Span,
    pub name_hash: u32,
    pub namespace: Namespace,
    pub node: u32,
    pub parameter: u8,
    pub previous: u32,
    pub scope: u32,
    pub scope_previous: u32,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Reference {
    pub context: Context,
    pub dead_zone: bool,
    pub name: Span,
    pub namespace: Namespace,
    pub node: u32,
    pub positional: bool,
    pub resolution: Resolution,
    pub scope: u32,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Scope {
    pub arrow: bool,
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
    module: ModuleKind,
    references: BoundedVec<Reference>,
    scopes: BoundedVec<Scope>,
}

struct Builder<'run, K>
where
    K: Kind + Kinds,
{
    depth: u32,
    outcome: Structure,
    parameter: u8,
    raw: &'run [K],
    semantic: &'run mut Semantic,
    source: &'run [u8],
    stack: [u32; SCOPE_DEPTH_MAX as usize],
    tokens: &'run [Token],
    tree: &'run Tree<K>,
}

impl BindingKind {
    pub const fn namespace(self) -> Namespace {
        match self {
            Self::ImportType | Self::Interface | Self::TypeAlias | Self::TypeParameter => {
                Namespace::Type
            }
            Self::CatchParameter
            | Self::Class
            | Self::Const
            | Self::Enum
            | Self::EnumMember
            | Self::Function
            | Self::Import
            | Self::ImportDefault
            | Self::ImportNamespace
            | Self::Let
            | Self::Namespace
            | Self::Parameter
            | Self::ParameterProperty
            | Self::Signature
            | Self::Var => Namespace::Value,
        }
    }

    pub const fn binds_in(self, namespace: Namespace) -> bool {
        match self {
            Self::Class
            | Self::Enum
            | Self::Import
            | Self::ImportDefault
            | Self::ImportNamespace
            | Self::Namespace => true,
            Self::ImportType | Self::Interface | Self::TypeAlias | Self::TypeParameter => {
                matches!(namespace, Namespace::Any | Namespace::Type)
            }
            Self::CatchParameter
            | Self::Const
            | Self::EnumMember
            | Self::Function
            | Self::Let
            | Self::Parameter
            | Self::ParameterProperty
            | Self::Signature
            | Self::Var => matches!(namespace, Namespace::Any | Namespace::Value),
        }
    }

    pub const fn hoists(self) -> bool {
        matches!(self, Self::Function | Self::Signature | Self::Var)
    }

    pub const fn imports(self) -> bool {
        matches!(
            self,
            Self::Import | Self::ImportDefault | Self::ImportNamespace | Self::ImportType
        )
    }

    pub const fn zones(self) -> bool {
        matches!(self, Self::Class | Self::Const | Self::Let)
    }
}

impl ScopeKind {
    pub const fn holds_a_function(self) -> bool {
        matches!(self, Self::Ambient | Self::Function | Self::Global | Self::Module)
    }

    pub const fn is_root(self) -> bool {
        matches!(self, Self::Global | Self::Module)
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
            module: ModuleKind::Script,
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
        self.module = ModuleKind::Script;
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

    pub const fn module(&self) -> ModuleKind {
        self.module
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

    pub fn function_scope_of(&self, from: u32) -> u32 {
        let mut scope = from;
        let mut steps = 0;

        while scope != NONE && steps <= SCOPE_DEPTH_MAX {
            let held = self.scopes[scope as usize];

            if held.kind.holds_a_function() && !held.arrow {
                return scope;
            }

            scope = held.parent;
            steps += 1;
        }

        NONE
    }

    pub fn dynamic_in(&self, scope: u32) -> bool {
        scope != NONE && self.scopes[scope as usize].dynamic
    }

    pub fn build<K>(
        &mut self,
        source: &[u8],
        tokens: &[Token],
        raw: &[K],
        tree: &Tree<K>,
        module: Option<ModuleKind>,
        globals: &[&[u8]],
    ) -> Structure
    where
        K: Kind + Kinds,
    {
        self.clear();

        let held = module.unwrap_or_else(|| module_of(tree));

        self.module = held;

        let pushed = self.scopes.push(Scope {
            arrow: false,
            dynamic: false,
            kind: match held {
                ModuleKind::Module => ScopeKind::Module,
                ModuleKind::Script => ScopeKind::Global,
            },
            node: 0,
            parent: NONE,
        });

        assert!(pushed);

        let mut builder = Builder {
            depth: 0,
            outcome: Structure::Complete,
            parameter: PARAMETER_NONE,
            raw,
            semantic: self,
            source,
            stack: [0; SCOPE_DEPTH_MAX as usize],
            tokens,
            tree,
        };

        builder.collect();

        let outcome = builder.outcome;

        self.resolve(source, globals);

        outcome
    }

    fn resolve(&mut self, source: &[u8], globals: &[&[u8]]) {
        for index in 0..self.references.count() {
            let held = self.references[index as usize];
            let resolution = self.resolution_of(source, &held);
            let dead_zone = self.zoned(&held, resolution);

            self.references[index as usize].dead_zone = dead_zone;

            self.references[index as usize].resolution = if resolution == Resolution::Unresolved {
                self.fallback_of(source, &held, globals)
            } else {
                resolution
            };
        }
    }

    fn fallback_of(&self, source: &[u8], reference: &Reference, globals: &[&[u8]]) -> Resolution {
        let name = &source[reference.name.range()];

        if globals.contains(&name) {
            return Resolution::Builtin;
        }

        if self.dynamic_above(reference.scope) {
            return Resolution::Maybe;
        }

        Resolution::Unresolved
    }

    fn dynamic_above(&self, from: u32) -> bool {
        let mut scope = from;
        let mut steps = 0;

        while scope != NONE && steps <= SCOPE_DEPTH_MAX {
            if self.scopes[scope as usize].dynamic {
                return true;
            }

            scope = self.scopes[scope as usize].parent;
            steps += 1;
        }

        false
    }

    fn zoned(&self, reference: &Reference, resolution: Resolution) -> bool {
        let Resolution::Bound(index) = resolution else {
            return false;
        };

        let held = self.bindings[index as usize];

        held.dead_zone_end != NONE && reference.name.offset < held.dead_zone_end
    }

    fn resolution_of(&self, source: &[u8], reference: &Reference) -> Resolution {
        let name = &source[reference.name.range()];
        let mut scope = reference.scope;
        let mut steps = 0;

        while scope != NONE && steps <= SCOPE_DEPTH_MAX {
            let held = self.scopes[scope as usize];
            let bounded = if reference.positional && scope == reference.scope {
                self.binding_before(source, scope, name, reference.node, reference.namespace)
            } else {
                self.binding_in(source, scope, name, reference.namespace)
            };

            if bounded != NONE {
                return Resolution::Bound(bounded);
            }

            scope = held.parent;
            steps += 1;
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
                && held.kind.binds_in(namespace)
                && held.name_hash == hash
                && &source[held.name.range()] == name
            {
                return index;
            }

            index = held.scope_previous;
        }

        NONE
    }

    fn binding_root(&self, source: &[u8], name: &[u8]) -> u32 {
        let hash = name_hash(name);
        let mut index = self.heads[self.bucket_of(0, hash)];

        for _ in 0..=self.bindings.count() {
            if index == NONE {
                break;
            }

            let held = self.bindings[index as usize];

            if held.scope == 0 && held.name_hash == hash && &source[held.name.range()] == name {
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
        node: u32,
        namespace: Namespace,
    ) -> u32 {
        let hash = name_hash(name);
        let mut index = self.heads[self.bucket_of(scope, hash)];

        for _ in 0..=self.bindings.count() {
            if index == NONE {
                break;
            }

            let held = self.bindings[index as usize];

            if held.scope == scope
                && held.node <= node
                && held.kind.binds_in(namespace)
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

const fn signs(role: Role) -> bool {
    matches!(
        role,
        Role::CallSignature | Role::FunctionSignature | Role::FunctionType | Role::MethodSignature
    )
}

fn bucket_count_of(binding_count_max: u32) -> u32 {
    binding_count_max.next_power_of_two().max(16)
}

fn module_of<K>(tree: &Tree<K>) -> ModuleKind
where
    K: Kind + Kinds,
{
    for (index, node) in tree.as_slice().iter().enumerate() {
        if index == 0 || node.parent != 0 {
            continue;
        }

        if matches!(
            node.kind.role(),
            Role::ExportStatement | Role::ImportStatement
        ) {
            return ModuleKind::Module;
        }
    }

    ModuleKind::Script
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum Standing {
    Bound,
    Load,
    Skip,
    Store,
}

struct Children<'run, K>
where
    K: Kind,
{
    node: u32,
    tree: &'run Tree<K>,
}

impl<K> Iterator for Children<'_, K>
where
    K: Kind,
{
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

impl<'run, K> Builder<'run, K>
where
    K: Kind + Kinds,
{
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

    fn role_of(&self, node: u32) -> Role {
        if node == NONE {
            return Role::Other;
        }

        self.tree.at(node).kind.role()
    }

    fn steps(&self) -> u32 {
        self.tree.count().saturating_mul(2).saturating_add(1)
    }

    fn children(&self, node: u32) -> Children<'run, K> {
        Children {
            node: self.tree.at(node).child_first,
            tree: self.tree,
        }
    }

    fn child_at(&self, node: u32, index: u32) -> u32 {
        self.children(node).nth(index as usize).unwrap_or(NONE)
    }

    fn position_of(&self, parent: u32, child: u32) -> u32 {
        for (index, held) in self.children(parent).enumerate() {
            if held == child {
                return count_of(index);
            }
        }

        NONE
    }

    fn span_of(&self, node: u32) -> Span {
        self.tree.at(node).span(self.tokens)
    }

    fn text_of(&self, name: Span) -> &'run [u8] {
        &self.source[name.range()]
    }

    fn word_at(&self, node: u32, index: u32) -> &'run [u8] {
        let held = self.tree.at(node);
        let mut seen = 0;

        for position in held.token_start..held.token_end {
            if self.raw[position as usize].role() == Role::Comment {
                continue;
            }

            if seen == index {
                return self.tokens[position as usize].text(self.source);
            }

            seen += 1;
        }

        b""
    }

    fn typed_import(&self, node: u32) -> bool {
        self.word_at(node, 1) == b"type" && self.word_at(node, 2) != b"from"
    }

    fn typed_specifier(&self, node: u32) -> bool {
        if self.word_at(node, 0) != b"type" {
            return false;
        }

        if self.word_at(node, 1).is_empty() {
            return false;
        }

        !(self.word_at(node, 1) == b"as" && self.word_at(node, 3).is_empty())
    }

    fn holds_token(&self, node: u32, role: Role, word: &[u8]) -> bool {
        let held = self.tree.at(node);

        for position in held.token_start..held.token_end {
            if self.raw[position as usize].role() != role {
                continue;
            }

            if word.is_empty() || self.tokens[position as usize].text(self.source) == word {
                return true;
            }
        }

        false
    }

    fn scope_kind_of(role: Role) -> Option<ScopeKind> {
        match Some(role) {
            Some(
                Role::ArrowFunction
                | Role::CallSignature
                | Role::ClassStaticBlock
                | Role::FunctionDeclaration
                | Role::FunctionExpression
                | Role::FunctionSignature
                | Role::FunctionType
                | Role::MethodDefinition
                | Role::MethodSignature
                | Role::Namespace,
            ) => Some(ScopeKind::Function),
            Some(Role::CatchClause) => Some(ScopeKind::Catch),
            Some(Role::Class | Role::ClassDeclaration) => Some(ScopeKind::Class),
            Some(
                Role::EnumDeclaration
                | Role::ForInStatement
                | Role::ForStatement
                | Role::InterfaceDeclaration
                | Role::StatementBlock
                | Role::SwitchBody
                | Role::TypeAliasDeclaration,
            ) => Some(ScopeKind::Block),
            Some(Role::WithStatement) => Some(ScopeKind::With),
            Some(_) | None => None,
        }
    }

    fn scope_kind_at(&self, node: u32, role: Role) -> Option<ScopeKind> {
        let kind = Self::scope_kind_of(role)?;
        let parent = self.role_of(self.tree.at(node).parent);

        if role == Role::Namespace && parent == Role::Ambient {
            return Some(ScopeKind::Ambient);
        }

        if role == Role::StatementBlock && parent == Role::Ambient {
            return None;
        }

        Some(kind)
    }

    fn enter(&mut self, node: u32) {
        let role = self.role_of(node);

        self.before(node, role);

        if let Some(kind) = self.scope_kind_at(node, role) {
            self.open(node, kind, role == Role::ArrowFunction);
            self.opened(node, role);
        }

        self.name(node, role);
    }

    fn leave(&mut self, node: u32) {
        let role = self.role_of(node);

        if role == Role::ExportStatement {
            self.export(node);
        }

        if Self::scope_kind_of(role).is_none() {
            return;
        }

        if self.depth > 1 {
            self.depth -= 1;
        }
    }

    fn open(&mut self, node: u32, kind: ScopeKind, arrow: bool) {
        let parent = self.scope();
        let index = self.semantic.scopes.count();

        let pushed = self.semantic.scopes.push(Scope {
            arrow,
            dynamic: kind == ScopeKind::With,
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

    fn opened(&mut self, node: u32, role: Role) {
        if role == Role::ArrowFunction {
            self.arrow_parameter(node);
        }

        if role == Role::CatchClause {
            self.catch_parameter(node);
        }

        if role == Role::EnumDeclaration {
            self.members(node);
        }

        if role == Role::ForInStatement {
            self.iteration(node);
        }

        if matches!(role, Role::Class | Role::FunctionExpression) {
            self.own_name(node, role);
        }

        if matches!(
            role,
            Role::ArrowFunction
                | Role::CallSignature
                | Role::Class
                | Role::ClassDeclaration
                | Role::FunctionDeclaration
                | Role::FunctionExpression
                | Role::FunctionSignature
                | Role::FunctionType
                | Role::InterfaceDeclaration
                | Role::MethodDefinition
                | Role::MethodSignature
                | Role::TypeAliasDeclaration
        ) {
            self.type_parameters(node);
        }
    }

    fn own_name(&mut self, node: u32, role: Role) {
        let Some(name) = self.name_token_of(node) else {
            return;
        };

        let kind = if role == Role::Class {
            BindingKind::Class
        } else {
            BindingKind::Function
        };

        self.record(kind, name, node, NONE);
    }

    fn name_token_of(&self, node: u32) -> Option<Span> {
        let mut held = node;

        for _ in 0..=self.tree.count() {
            let mut nested = NONE;

            for child in self.children(held) {
                if matches!(
                    self.role_of(child),
                    Role::IdentifierNode | Role::TypeIdentifier
                ) {
                    return Some(self.span_of(child));
                }

                if nested == NONE && self.role_of(child) == Role::MemberExpression {
                    nested = child;
                }
            }

            if nested == NONE {
                return None;
            }

            held = nested;
        }

        None
    }

    fn type_parameters(&mut self, node: u32) {
        for child in self.children(node) {
            if self.role_of(child) != Role::TypeParameters {
                continue;
            }

            for held in self.children(child) {
                if self.role_of(held) != Role::TypeParameter {
                    continue;
                }

                let Some(name) = self.name_token_of(held) else {
                    continue;
                };

                self.record(BindingKind::TypeParameter, name, held, NONE);
            }
        }
    }

    fn before(&mut self, node: u32, role: Role) {
        match Some(role) {
            Some(Role::CallExpression) => self.dynamic(node),
            Some(Role::ClassDeclaration) => self.declaration(node, BindingKind::Class),
            Some(Role::EnumDeclaration) => self.declaration(node, BindingKind::Enum),
            Some(Role::FormalParameters) => self.parameters(node),
            Some(Role::FunctionDeclaration) => self.declaration(node, BindingKind::Function),
            Some(Role::FunctionSignature) => self.declaration(node, BindingKind::Signature),
            Some(Role::ImportAlias | Role::ImportRequire) => self.import_equals(node),
            Some(Role::ImportStatement) => self.import(node),
            Some(Role::InferType) => self.infer(node),
            Some(Role::InterfaceDeclaration) => self.declaration(node, BindingKind::Interface),
            Some(Role::LexicalDeclaration) => self.lexical(node),
            Some(Role::Namespace) => self.declaration(node, BindingKind::Namespace),
            Some(Role::TypeAliasDeclaration) => self.declaration(node, BindingKind::TypeAlias),
            Some(Role::VariableDeclaration) => self.variable(node),
            Some(_) | None => {}
        }
    }

    fn declaration(&mut self, node: u32, kind: BindingKind) {
        let Some(name) = self.name_token_of(node) else {
            return;
        };

        let zone = if kind.zones() {
            self.span_of(node).end()
        } else {
            NONE
        };

        self.record(kind, name, node, zone);
    }

    fn lexical(&mut self, node: u32) {
        let kind = if self.holds_token(node, Role::ConstKeyword, b"") || self.resource(node) {
            BindingKind::Const
        } else {
            BindingKind::Let
        };

        for child in self.children(node) {
            if self.role_of(child) != Role::VariableDeclarator {
                continue;
            }

            let zone = self.span_of(child).end();
            let target = self.child_at(child, 0);

            self.pattern(target, Target::Bind { kind, zone });
        }
    }

    fn resource(&self, node: u32) -> bool {
        let span = self.span_of(node);
        let from = span.offset as usize;
        let end = span.end() as usize;
        let text = self.source.get(from..end).unwrap_or_default();
        let head = text.strip_prefix(b"await".as_slice()).unwrap_or(text);

        head.trim_ascii_start().starts_with(b"using")
    }

    fn variable(&mut self, node: u32) {
        for child in self.children(node) {
            if self.role_of(child) != Role::VariableDeclarator {
                continue;
            }

            let target = self.child_at(child, 0);

            self.pattern(
                target,
                Target::Bind {
                    kind: BindingKind::Var,
                    zone: NONE,
                },
            );
        }
    }

    fn parameters(&mut self, node: u32) {
        if signs(self.role_of(self.tree.at(node).parent)) {
            return;
        }

        let mut position = 0;

        for child in self.children(node) {
            let role = self.role_of(child);

            let target = if role == Role::Parameter {
                self.parameter_target(child)
            } else {
                child
            };

            let kind = if self.declares_a_field(child) {
                BindingKind::ParameterProperty
            } else {
                BindingKind::Parameter
            };

            self.parameter = position;

            self.pattern(target, Target::Bind { kind, zone: NONE });

            position = position.saturating_add(1).min(PARAMETER_MAX);
        }

        self.parameter = PARAMETER_NONE;
    }

    fn parameter_target(&self, node: u32) -> u32 {
        for child in self.children(node) {
            if self.role_of(child) != Role::Modifier {
                return child;
            }
        }

        NONE
    }

    fn declares_a_field(&self, node: u32) -> bool {
        let target = self.parameter_target(node);
        let held = self.tree.at(node);

        let stop = if target == NONE {
            held.token_end
        } else {
            self.tree.at(target).token_start
        };

        for position in held.token_start..stop {
            if self.raw[position as usize].role() == Role::Comment {
                continue;
            }

            if matches!(
                self.tokens[position as usize].text(self.source),
                b"private" | b"protected" | b"public" | b"readonly"
            ) {
                return true;
            }
        }

        false
    }

    fn import_equals(&mut self, node: u32) {
        let Some(name) = self.name_token_of(node) else {
            return;
        };

        self.record(BindingKind::Import, name, node, NONE);

        let specifier = self.specifier_of(node);

        if specifier == Span::EMPTY {
            return;
        }

        self.fact(FactKind::ImportNamespace, name, Span::EMPTY, specifier);
    }

    fn infer(&mut self, node: u32) {
        let Some(name) = self.name_token_of(node) else {
            return;
        };

        let scope = self.conditional_scope();

        self.record_in(scope, BindingKind::TypeParameter, name, node, NONE);
    }

    fn conditional_scope(&self) -> u32 {
        let mut scope = self.scope();
        let mut steps = 0;

        while steps <= SCOPE_DEPTH_MAX {
            let held = self.semantic.scopes[scope as usize];

            if held.parent == NONE || !signs(self.role_of(held.node)) {
                return scope;
            }

            scope = held.parent;
            steps += 1;
        }

        scope
    }

    fn arrow_parameter(&mut self, node: u32) {
        let target = self.child_at(node, 0);

        if self.role_of(target) != Role::IdentifierNode {
            return;
        }

        let name = self.span_of(target);

        self.parameter = 0;

        self.record(BindingKind::Parameter, name, target, NONE);

        self.parameter = PARAMETER_NONE;
    }

    fn members(&mut self, node: u32) {
        let Some(body) = self.children(node).last() else {
            return;
        };

        if self.role_of(body) != Role::EnumBody {
            return;
        }

        for member in self.children(body) {
            let named = if self.role_of(member) == Role::PropertyIdentifier {
                member
            } else {
                match self.children(member).next() {
                    Some(first) if self.role_of(first) == Role::PropertyIdentifier => first,
                    Some(_) | None => continue,
                }
            };

            self.record(BindingKind::EnumMember, self.span_of(named), named, NONE);
        }
    }

    fn iteration(&mut self, node: u32) {
        let target = self.child_at(node, 0);

        let Some(kind) = self.iteration_kind(node, target) else {
            return;
        };

        self.pattern(target, Target::Bind { kind, zone: NONE });
    }

    fn iteration_kind(&self, node: u32, target: u32) -> Option<BindingKind> {
        if target == NONE {
            return None;
        }

        let held = self.tree.at(node);
        let limit = self.tree.at(target).token_start;

        for position in held.token_start..limit {
            match Some(self.raw[position as usize].role()) {
                Some(Role::ConstKeyword) => return Some(BindingKind::Const),
                Some(Role::LetKeyword) => return Some(BindingKind::Let),
                Some(Role::VarKeyword) => return Some(BindingKind::Var),
                Some(Role::Identifier)
                    if self.tokens[position as usize].text(self.source) == b"using" =>
                {
                    return Some(BindingKind::Const);
                }
                Some(_) | None => {}
            }
        }

        None
    }

    fn catch_parameter(&mut self, node: u32) {
        let target = self.child_at(node, 0);

        if matches!(self.role_of(target), Role::StatementBlock | Role::Other) {
            return;
        }

        self.pattern(
            target,
            Target::Bind {
                kind: BindingKind::CatchParameter,
                zone: NONE,
            },
        );
    }

    fn bound(&mut self, node: u32, target: Target) {
        let name = self.span_of(node);

        match target {
            Target::Bind { kind, zone } => self.record(kind, name, node, zone),
            Target::Export => self.fact(FactKind::ExportNamed, name, name, Span::EMPTY),
        }
    }

    fn pattern(&mut self, node: u32, target: Target) {
        if node == NONE {
            return;
        }

        let mut stack = [(NONE, NONE); PATTERN_DEPTH_MAX as usize];
        let mut depth = 1;

        stack[0] = (node, self.tree.at(node).sibling_next);

        for _ in 0..self.steps() {
            if depth == 0 {
                return;
            }

            depth -= 1;

            let (held, stop) = stack[depth];
            let following = self.tree.at(held).sibling_next;

            if following != NONE && following != stop {
                stack[depth] = (following, stop);
                depth += 1;
            }

            let role = self.role_of(held);

            if matches!(role, Role::IdentifierNode | Role::ShorthandPatternName) {
                self.bound(held, target);

                continue;
            }

            let inner = match Some(role) {
                Some(Role::ArrayPattern | Role::ObjectPattern) => None,
                Some(
                    Role::AssignmentPattern
                    | Role::ObjectAssignmentPattern
                    | Role::Parameter
                    | Role::RestPattern,
                ) => Some(0),
                Some(Role::PairPattern) => Some(1),
                Some(_) | None => continue,
            };

            if depth >= PATTERN_DEPTH_MAX as usize {
                self.outcome = Structure::TooDeep;

                return;
            }

            let Some(index) = inner else {
                let child = self.tree.at(held).child_first;

                if child != NONE {
                    stack[depth] = (child, NONE);
                    depth += 1;
                }

                continue;
            };

            let child = self.child_at(held, index);

            if child == NONE {
                continue;
            }

            stack[depth] = (child, self.tree.at(child).sibling_next);
            depth += 1;
        }

        self.outcome = Structure::TooDeep;
    }

    fn import(&mut self, node: u32) {
        let typed = self.typed_import(node);
        let specifier = self.specifier_of(node);
        let mut clauses = 0;

        for child in self.children(node) {
            if self.role_of(child) != Role::ImportClause {
                continue;
            }

            clauses += 1;

            for held in self.children(child) {
                self.import_of(held, typed);
                self.import_fact(held, typed, specifier);
            }
        }

        if clauses == 0 && specifier != Span::EMPTY {
            self.fact(
                FactKind::ImportSideEffect,
                Span::EMPTY,
                Span::EMPTY,
                specifier,
            );
        }
    }

    fn import_fact(&mut self, node: u32, typed: bool, specifier: Span) {
        match Some(self.role_of(node)) {
            Some(Role::IdentifierNode) => {
                let local = self.span_of(node);

                self.fact(FactKind::ImportDefault, local, Span::EMPTY, specifier);
            }
            Some(Role::NamespaceImport) => {
                let local = self.name_token_of(node).unwrap_or(Span::EMPTY);

                self.fact(FactKind::ImportNamespace, local, Span::EMPTY, specifier);
            }
            Some(Role::NamedImports) => {
                for held in self.children(node) {
                    if self.role_of(held) != Role::ImportSpecifier {
                        continue;
                    }

                    self.import_specifier(held, typed, specifier);
                }
            }
            Some(_) | None => {}
        }
    }

    fn import_specifier(&mut self, node: u32, typed: bool, specifier: Span) {
        let held = typed || self.typed_specifier(node);

        let kind = if held {
            FactKind::ImportType
        } else {
            FactKind::ImportNamed
        };

        let mut remote = Span::EMPTY;
        let mut local = Span::EMPTY;

        for child in self.children(node) {
            if !matches!(
                self.role_of(child),
                Role::IdentifierNode | Role::StringNode | Role::TypeIdentifier
            ) {
                continue;
            }

            let found = self.span_of(child);

            if remote == Span::EMPTY {
                remote = found;
            }

            local = found;
        }

        self.fact(kind, local, remote, specifier);
    }

    fn specifier_of(&self, node: u32) -> Span {
        for child in self.children(node) {
            if self.role_of(child) != Role::StringNode {
                continue;
            }

            let held = self.span_of(child);

            if held.length < 2 {
                return held;
            }

            let opens = self.source.get(held.offset as usize);

            if !matches!(opens, Some(b'"' | b'\'' | b'`')) {
                return held;
            }

            return Span {
                length: held.length - 2,
                offset: held.offset + 1,
            };
        }

        Span::EMPTY
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

        self.semantic.binding_root(self.source, self.text_of(local))
    }

    fn export(&mut self, node: u32) {
        let specifier = self.specifier_of(node);
        let mut named = false;

        for child in self.children(node) {
            named = self.export_of(child, specifier) || named;
        }

        if named {
            return;
        }

        if self.holds_token(node, Role::DefaultKeyword, b"") {
            let local = self.name_token_of(node).unwrap_or(Span::EMPTY);

            self.fact(FactKind::ExportDefault, local, Span::EMPTY, Span::EMPTY);

            return;
        }

        if specifier != Span::EMPTY {
            self.fact(FactKind::ExportAll, Span::EMPTY, Span::EMPTY, specifier);
        }
    }

    fn export_of(&mut self, node: u32, specifier: Span) -> bool {
        if self.role_of(node) == Role::Ambient {
            let mut named = false;

            for child in self.children(node) {
                named = self.export_of(child, specifier) || named;
            }

            return named;
        }

        match Some(self.role_of(node)) {
            Some(Role::ExportClause) => {
                for held in self.children(node) {
                    if self.role_of(held) != Role::ExportSpecifier {
                        continue;
                    }

                    self.export_specifier(held, specifier);
                }

                true
            }
            Some(Role::NamespaceExport) => {
                let local = self.name_token_of(node).unwrap_or(Span::EMPTY);

                self.fact(FactKind::ExportAll, local, Span::EMPTY, specifier);

                true
            }
            Some(
                Role::ClassDeclaration
                | Role::EnumDeclaration
                | Role::FunctionDeclaration
                | Role::ImportAlias
                | Role::ImportRequire
                | Role::InterfaceDeclaration
                | Role::Namespace
                | Role::TypeAliasDeclaration,
            ) => {
                let local = self.name_token_of(node).unwrap_or(Span::EMPTY);

                self.fact(FactKind::ExportNamed, local, local, Span::EMPTY);

                true
            }
            Some(Role::LexicalDeclaration | Role::VariableDeclaration) => {
                self.export_declaration(node);

                true
            }
            Some(_) | None => false,
        }
    }

    fn export_declaration(&mut self, node: u32) {
        for child in self.children(node) {
            if self.role_of(child) != Role::VariableDeclarator {
                continue;
            }

            let target = self.child_at(child, 0);

            self.pattern(target, Target::Export);
        }
    }

    fn export_specifier(&mut self, node: u32, specifier: Span) {
        let mut first = Span::EMPTY;
        let mut last = Span::EMPTY;

        for child in self.children(node) {
            if !matches!(
                self.role_of(child),
                Role::IdentifierNode | Role::StringNode | Role::TypeIdentifier
            ) {
                continue;
            }

            let held = self.span_of(child);

            if first == Span::EMPTY {
                first = held;
            }

            last = held;
        }

        if specifier == Span::EMPTY {
            self.fact(FactKind::ExportNamed, first, last, Span::EMPTY);

            return;
        }

        self.fact(FactKind::Reexport, last, first, specifier);
    }

    fn import_of(&mut self, node: u32, typed: bool) {
        match Some(self.role_of(node)) {
            Some(Role::IdentifierNode) => {
                let name = self.span_of(node);
                let kind = if typed {
                    BindingKind::ImportType
                } else {
                    BindingKind::ImportDefault
                };

                self.record(kind, name, node, NONE);
            }
            Some(Role::NamespaceImport) => {
                let Some(name) = self.name_token_of(node) else {
                    return;
                };

                let kind = if typed {
                    BindingKind::ImportType
                } else {
                    BindingKind::ImportNamespace
                };

                self.record(kind, name, node, NONE);
            }
            Some(Role::NamedImports) => {
                for held in self.children(node) {
                    if self.role_of(held) != Role::ImportSpecifier {
                        continue;
                    }

                    self.specifier(held, typed);
                }
            }
            Some(_) | None => {}
        }
    }

    fn specifier(&mut self, node: u32, typed: bool) {
        let held = typed || self.typed_specifier(node);

        let kind = if held {
            BindingKind::ImportType
        } else {
            BindingKind::Import
        };

        let mut name = None;

        for child in self.children(node) {
            if matches!(
                self.role_of(child),
                Role::IdentifierNode | Role::TypeIdentifier
            ) {
                name = Some(self.span_of(child));
            }
        }

        let Some(found) = name else {
            return;
        };

        self.record(kind, found, node, NONE);
    }

    fn dynamic(&mut self, node: u32) {
        let callee = self.child_at(node, 0);

        if self.role_of(callee) != Role::IdentifierNode {
            return;
        }

        let name = self.text_of(self.span_of(callee));

        if name == b"eval" {
            self.flag();

            return;
        }

        if name != b"require" {
            return;
        }

        let arguments = self.child_at(node, 1);

        if self.role_of(arguments) != Role::Arguments {
            return;
        }

        let first = self.child_at(arguments, 0);

        if first == NONE {
            return;
        }

        if self.role_of(first) != Role::StringNode {
            self.flag();

            return;
        }

        let specifier = self.specifier_of(arguments);
        let local = self.required_by(node);

        let kind = if local == Span::EMPTY {
            FactKind::ImportSideEffect
        } else {
            FactKind::ImportDefault
        };

        self.fact(kind, local, Span::EMPTY, specifier);
    }

    fn required_by(&self, node: u32) -> Span {
        let parent = self.tree.at(node).parent;

        if self.role_of(parent) != Role::VariableDeclarator {
            return Span::EMPTY;
        }

        let target = self.child_at(parent, 0);

        if self.role_of(target) != Role::IdentifierNode {
            return Span::EMPTY;
        }

        self.span_of(target)
    }

    fn flag(&mut self) {
        let scope = self.scope();

        self.semantic.scopes[scope as usize].dynamic = true;
    }

    fn name(&mut self, node: u32, role: Role) {
        if !matches!(
            role,
            Role::IdentifierNode | Role::ShorthandProperty | Role::TypeIdentifier
        ) {
            return;
        }

        let standing = self.standing_of(node);

        if matches!(standing, Standing::Bound | Standing::Skip) {
            return;
        }

        let name = self.span_of(node);
        let namespace = self.namespace_at(node, role);
        let scope = self.scope();

        let context = if standing == Standing::Store {
            Context::Store
        } else {
            Context::Load
        };

        let recorded = self.semantic.references.push(Reference {
            context,
            dead_zone: false,
            name,
            namespace,
            node,
            positional: self.positional_at(node),
            resolution: Resolution::Unresolved,
            scope,
        });

        if !recorded && self.outcome == Structure::Complete {
            self.outcome = Structure::Truncated;
        }
    }

    fn namespace_at(&self, node: u32, role: Role) -> Namespace {
        let parent = self.role_of(self.tree.at(node).parent);

        if parent == Role::ExportSpecifier {
            return Namespace::Any;
        }

        if self.queried(node) {
            return Namespace::Any;
        }

        if role == Role::TypeIdentifier || self.nested_type(node) {
            return Namespace::Type;
        }

        Namespace::Value
    }

    fn nested_type(&self, node: u32) -> bool {
        let mut held = self.tree.at(node).parent;
        let mut steps = 0;

        while held != NONE && steps <= SCOPE_DEPTH_MAX {
            let role = self.role_of(held);

            if role == Role::NestedType {
                return true;
            }

            if role != Role::MemberExpression {
                return false;
            }

            held = self.tree.at(held).parent;
            steps += 1;
        }

        false
    }

    fn queried(&self, node: u32) -> bool {
        let mut held = self.tree.at(node).parent;
        let mut steps = 0;

        while held != NONE && steps <= SCOPE_DEPTH_MAX {
            let role = self.role_of(held);

            if role == Role::TypeQuery {
                return true;
            }

            if !matches!(role, Role::MemberExpression | Role::NestedType) {
                return false;
            }

            held = self.tree.at(held).parent;
            steps += 1;
        }

        false
    }

    fn positional_at(&self, node: u32) -> bool {
        let mut held = self.tree.at(node).parent;
        let mut steps = 0;

        while held != NONE && steps <= SCOPE_DEPTH_MAX {
            let role = self.role_of(held);

            if role == Role::FormalParameters {
                return true;
            }

            if Self::scope_kind_of(role).is_some() {
                return false;
            }

            held = self.tree.at(held).parent;
            steps += 1;
        }

        false
    }

    fn intrinsic(&self, node: u32) -> bool {
        let name = self.text_of(self.span_of(node));

        let Some(first) = name.first() else {
            return false;
        };

        first.is_ascii_lowercase() || name.contains(&b'-')
    }

    fn standing_of(&self, node: u32) -> Standing {
        let mut child = node;
        let mut parent = self.tree.at(child).parent;
        let mut steps = 0;

        while parent != NONE && steps <= SCOPE_DEPTH_MAX {
            let role = self.role_of(parent);
            let position = self.position_of(parent, child);

            if role == Role::ExportStatement {
                return self.reexports(parent);
            }

            if role == Role::JsxTag {
                if self.intrinsic(child) {
                    return Standing::Skip;
                }

                return Standing::Load;
            }

            if role == Role::ForInStatement && position == 0 {
                let target = self.child_at(parent, 0);

                if self.iteration_kind(parent, target).is_some() {
                    return Standing::Bound;
                }

                return Standing::Load;
            }

            if role == Role::Parameter {
                if child == self.parameter_target(parent) {
                    return Standing::Bound;
                }

                return Standing::Load;
            }

            if role == Role::MemberExpression
                && position == 0
                && self.role_of(self.tree.at(parent).parent) == Role::Namespace
            {
                return Standing::Bound;
            }

            if let Some(held) = Self::standing_in(role, position) {
                return held;
            }

            child = parent;
            parent = self.tree.at(parent).parent;
            steps += 1;
        }

        Standing::Load
    }

    fn standing_declared(role: Role, position: u32) -> Option<Standing> {
        match Some(role) {
            Some(Role::FormalParameters | Role::Parameter) => Some(Standing::Bound),
            Some(
                Role::CatchClause
                | Role::Class
                | Role::ClassDeclaration
                | Role::EnumDeclaration
                | Role::FunctionDeclaration
                | Role::FunctionExpression
                | Role::FunctionSignature
                | Role::InferType
                | Role::InterfaceDeclaration
                | Role::Namespace
                | Role::TypeAliasDeclaration
                | Role::TypeParameter
                | Role::VariableDeclarator,
            ) => {
                if position == 0 {
                    Some(Standing::Bound)
                } else {
                    Some(Standing::Load)
                }
            }
            Some(Role::ImportAlias | Role::ImportRequire) => {
                if position == 0 {
                    Some(Standing::Bound)
                } else {
                    Some(Standing::Load)
                }
            }
            Some(
                Role::ImportClause
                | Role::ImportSpecifier
                | Role::NamedImports
                | Role::NamespaceImport,
            ) => Some(Standing::Bound),
            Some(_) | None => None,
        }
    }

    fn reexports(&self, node: u32) -> Standing {
        for child in self.children(node) {
            if self.role_of(child) == Role::StringNode {
                return Standing::Skip;
            }
        }

        Standing::Load
    }

    fn standing_in(role: Role, position: u32) -> Option<Standing> {
        if let Some(held) = Self::standing_declared(role, position) {
            return Some(held);
        }

        match Some(role) {
            Some(Role::ArrayPattern | Role::ObjectPattern | Role::RestPattern) => None,
            Some(Role::AssignmentPattern | Role::ObjectAssignmentPattern) => {
                if position == 0 {
                    None
                } else {
                    Some(Standing::Load)
                }
            }
            Some(Role::PairPattern) => {
                if position == 1 {
                    None
                } else {
                    Some(Standing::Skip)
                }
            }
            Some(Role::ExportClause) => None,
            Some(Role::ExportSpecifier) => {
                if position == 0 {
                    None
                } else {
                    Some(Standing::Skip)
                }
            }
            Some(Role::IndexSignature | Role::TypePredicate) => {
                if position == 0 {
                    Some(Standing::Skip)
                } else {
                    Some(Standing::Load)
                }
            }
            Some(Role::NestedType) => {
                if position == 0 {
                    None
                } else {
                    Some(Standing::Skip)
                }
            }
            Some(Role::NamespaceExport) => Some(Standing::Skip),
            Some(Role::MemberExpression | Role::Pair) => Some(Standing::Load),
            Some(Role::AssignmentExpression) => {
                if position == 0 {
                    Some(Standing::Store)
                } else {
                    Some(Standing::Load)
                }
            }
            Some(Role::AugmentedAssignment | Role::UpdateExpression) => Some(Standing::Load),
            Some(Role::ArrowFunction) => {
                if position == 0 {
                    Some(Standing::Bound)
                } else {
                    Some(Standing::Load)
                }
            }
            Some(Role::LabeledStatement) => Some(Standing::Skip),
            Some(_) | None => Some(Standing::Load),
        }
    }

    fn target_of(&self, kind: BindingKind) -> u32 {
        if !kind.hoists() {
            return self.scope();
        }

        let mut scope = self.scope();
        let mut steps = 0;

        while steps <= SCOPE_DEPTH_MAX {
            let held = self.semantic.scopes[scope as usize];

            if held.kind.holds_a_function() || held.parent == NONE {
                return scope;
            }

            scope = held.parent;
            steps += 1;
        }

        scope
    }

    fn record(&mut self, kind: BindingKind, name: Span, node: u32, dead_zone_end: u32) {
        let scope = self.target_of(kind);

        self.record_in(scope, kind, name, node, dead_zone_end);
    }

    fn record_in(
        &mut self,
        scope: u32,
        kind: BindingKind,
        name: Span,
        node: u32,
        dead_zone_end: u32,
    ) {
        let previous = self.previous_of(scope, self.text_of(name), kind);

        let recorded = self.semantic.push_binding(Binding {
            dead_zone_end,
            hoisted: kind.hoists(),
            kind,
            name,
            name_hash: name_hash(self.text_of(name)),
            namespace: kind.namespace(),
            node,
            parameter: self.parameter,
            previous,
            scope,
            scope_previous: NONE,
        });

        if !recorded && self.outcome == Structure::Complete {
            self.outcome = Structure::Truncated;
        }
    }

    fn previous_of(&self, scope: u32, name: &[u8], kind: BindingKind) -> u32 {
        let hash = name_hash(name);
        let mut index = self.semantic.heads[self.semantic.bucket_of(scope, hash)];
        let mut found = NONE;

        for _ in 0..=self.semantic.bindings.count() {
            if index == NONE {
                break;
            }

            let held = self.semantic.bindings[index as usize];

            if held.scope == scope
                && held.name_hash == hash
                && &self.source[held.name.range()] == name
            {
                found = index;

                break;
            }

            index = held.scope_previous;
        }

        if found == NONE {
            return NONE;
        }

        let held = self.semantic.bindings[found as usize];

        if kind == BindingKind::Var && held.kind == BindingKind::Var {
            return NONE;
        }

        found
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::bounded::BoundedVec as Held;
    use crate::language::Lexer as _;
    use crate::lex::{JAVASCRIPT, TYPESCRIPT};
    use crate::syntax::javascript::classify::classify;
    use crate::syntax::javascript::parse;
    use crate::syntax::typescript::classify::classify as typescript_classify;
    use crate::syntax::typescript::dialect::Dialect;
    use crate::syntax::typescript::parse as typescript_parse;
    use crate::token::Tokens;
    use crate::tree::Events;

    const GLOBALS: [&[u8]; 4] = [b"console", b"eval", b"require", b"undefined"];

    struct Fixture {
        semantic: Semantic,
        source: Vec<u8>,
    }

    impl Fixture {
        fn of(source: &[u8], module: Option<ModuleKind>) -> Self {
            let mut lexed = Tokens::reserve(1 << 14);
            let mut tokens = Tokens::reserve(1 << 14);
            let mut raw = Held::reserve(1 << 14);
            let mut events = Events::reserve(1 << 16);
            let mut tree = Tree::<JavaScriptKind>::reserve(1 << 14, 1 << 8);
            let mut semantic = Semantic::reserve(1 << 10, 1 << 12, 1 << 10, 1 << 10);

            JAVASCRIPT.lex(source, &mut lexed);

            assert!(classify(source, lexed.as_slice(), &mut tokens, &mut raw));

            parse::build(source, tokens.as_slice(), &raw, &mut events, &mut tree);

            assert_eq!(
                semantic.build(source, tokens.as_slice(), &raw, &tree, module, &GLOBALS),
                Structure::Complete
            );

            Self {
                semantic,
                source: source.to_vec(),
            }
        }

        fn typescript(source: &[u8]) -> Self {
            Self::dialect(source, Dialect::Ts)
        }

        fn tsx(source: &[u8]) -> Self {
            Self::dialect(source, Dialect::Tsx)
        }

        fn dialect(source: &[u8], dialect: Dialect) -> Self {
            let mut lexed = Tokens::reserve(1 << 14);
            let mut tokens = Tokens::reserve(1 << 14);
            let mut raw = Held::reserve(1 << 14);
            let mut events = Events::reserve(1 << 16);
            let mut tree = Tree::<TypeScriptKind>::reserve(1 << 14, 1 << 8);
            let mut semantic = Semantic::reserve(1 << 10, 1 << 12, 1 << 10, 1 << 10);

            TYPESCRIPT.lex(source, &mut lexed);

            assert!(typescript_classify(
                source,
                lexed.as_slice(),
                &mut tokens,
                &mut raw,
                dialect
            ));

            typescript_parse::build(
                source,
                tokens.as_slice(),
                &raw,
                &mut events,
                &mut tree,
                dialect,
            );

            assert_eq!(
                semantic.build(source, tokens.as_slice(), &raw, &tree, None, &GLOBALS),
                Structure::Complete
            );

            Self {
                semantic,
                source: source.to_vec(),
            }
        }

        fn read(path: &str) -> Self {
            Self::of(&read_of("tests/fixtures/javascript-semantic", path), None)
        }

        fn read_typescript(path: &str) -> Self {
            Self::typescript(&read_of("tests/fixtures/typescript-semantic", path))
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

        fn bindings(&self) -> Vec<(BindingKind, String, u32)> {
            self.semantic
                .bindings()
                .iter()
                .map(|held| (held.kind, self.text_of(held.name), held.scope))
                .collect()
        }

        fn scopes(&self) -> Vec<(ScopeKind, u32)> {
            self.semantic
                .scopes()
                .iter()
                .map(|held| (held.kind, held.parent))
                .collect()
        }

        fn references(&self) -> Vec<(String, Resolution)> {
            self.semantic
                .references()
                .iter()
                .map(|held| (self.text_of(held.name), held.resolution))
                .collect()
        }

        fn resolution_of(&self, name: &str, nth: usize) -> Resolution {
            self.semantic
                .references()
                .iter()
                .filter(|held| self.text_of(held.name) == name)
                .nth(nth)
                .map_or(Resolution::Unresolved, |held| held.resolution)
        }

        fn reference_of(&self, name: &str, nth: usize) -> Reference {
            *self
                .semantic
                .references()
                .iter()
                .filter(|held| self.text_of(held.name) == name)
                .nth(nth)
                .expect("the fixture writes the name the test names")
        }

        fn binding_at(&self, name: &str, nth: usize) -> (u32, Binding) {
            let mut seen = 0;

            for index in 0..self.semantic.count() {
                let held = self.semantic.bindings()[index as usize];

                if self.text_of(held.name) != name {
                    continue;
                }

                if seen == nth {
                    return (index, held);
                }

                seen += 1;
            }

            panic!("the fixture writes no binding named {name}");
        }
    }

    fn read_of(directory: &str, path: &str) -> Vec<u8> {
        let root = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join(directory)
            .join(path);

        std::fs::read(root).expect("the fixture is readable")
    }

    #[test]
    fn the_scope_chain_runs_block_then_function_then_the_root() {
        let fixture = Fixture::read("chain.js");

        assert_eq!(
            fixture.scopes(),
            vec![
                (ScopeKind::Global, NONE),
                (ScopeKind::Function, 0),
                (ScopeKind::Block, 1),
                (ScopeKind::Block, 2),
            ]
        );

        assert_eq!(fixture.resolution_of("outer", 0), Resolution::Bound(0));
        assert_eq!(fixture.resolution_of("held", 0), Resolution::Bound(2));
        assert_eq!(fixture.resolution_of("inner", 0), Resolution::Bound(3));
    }

    #[test]
    fn a_function_declaration_hoists_and_an_expression_names_only_itself() {
        let fixture = Fixture::read("functions.js");
        let (index, held) = fixture.binding_at("call", 0);

        assert_eq!(held.kind, BindingKind::Function);
        assert!(held.hoisted);
        assert_eq!(held.scope, 0);
        assert_eq!(fixture.resolution_of("call", 0), Resolution::Bound(index));

        let (named, expression) = fixture.binding_at("named", 0);

        assert_ne!(expression.scope, 0);
        assert_eq!(fixture.resolution_of("named", 0), Resolution::Unresolved);
        assert_eq!(fixture.resolution_of("named", 1), Resolution::Bound(named));
    }

    #[test]
    fn a_var_climbs_past_a_block_and_merges_with_the_var_before_it() {
        let fixture = Fixture::read("var.js");
        let (_, first) = fixture.binding_at("held", 0);
        let (_, second) = fixture.binding_at("held", 1);

        assert_eq!(first.scope, second.scope);
        assert!(first.hoisted);
        assert!(second.hoisted);
        assert_eq!(second.previous, NONE);

        assert_eq!(
            fixture.semantic.scopes()[first.scope as usize].kind,
            ScopeKind::Function
        );

        let (climbed, _) = fixture.binding_at("inner", 0);

        assert_eq!(
            fixture.resolution_of("inner", 0),
            Resolution::Bound(climbed)
        );
    }

    #[test]
    fn a_lexical_binding_carries_a_dead_zone_and_a_redeclaration_chains() {
        let fixture = Fixture::read("lexical.js");
        let (first, early) = fixture.binding_at("late", 0);
        let (_, second) = fixture.binding_at("late", 1);

        assert_ne!(early.dead_zone_end, NONE);
        assert_eq!(second.previous, first);

        let held = fixture.reference_of("late", 0);

        assert!(held.dead_zone);
        assert!(matches!(held.resolution, Resolution::Bound(_)));

        let (shape, _) = fixture.binding_at("Shape", 0);
        let (_, redeclared) = fixture.binding_at("Shape", 1);

        assert_eq!(redeclared.previous, shape);
        assert_ne!(redeclared.dead_zone_end, NONE);
    }

    #[test]
    fn a_parameter_binds_in_the_function_and_a_default_reads_only_the_ones_before_it() {
        let fixture = Fixture::read("parameters.js");
        let (first, held) = fixture.binding_at("first", 0);

        assert_eq!(held.kind, BindingKind::Parameter);

        assert_eq!(
            fixture.semantic.scopes()[held.scope as usize].kind,
            ScopeKind::Function
        );

        assert_eq!(fixture.resolution_of("first", 0), Resolution::Bound(first));
        assert_eq!(fixture.resolution_of("body", 0), Resolution::Unresolved);
    }

    #[test]
    fn a_catch_parameter_binds_in_its_own_scope_and_a_var_climbs_past_it() {
        let fixture = Fixture::read("catch.js");
        let (index, held) = fixture.binding_at("held", 0);

        assert_eq!(held.kind, BindingKind::CatchParameter);

        assert_eq!(
            fixture.semantic.scopes()[held.scope as usize].kind,
            ScopeKind::Catch
        );

        assert_eq!(fixture.resolution_of("held", 0), Resolution::Bound(index));

        let (climbed, var) = fixture.binding_at("climbed", 0);

        assert_eq!(
            fixture.semantic.scopes()[var.scope as usize].kind,
            ScopeKind::Function
        );

        assert_eq!(
            fixture.resolution_of("climbed", 0),
            Resolution::Bound(climbed)
        );
    }

    #[test]
    fn a_method_name_is_a_property_and_a_class_expression_names_itself() {
        let fixture = Fixture::read("classes.js");
        let names: Vec<String> = fixture.bindings().into_iter().map(|held| held.1).collect();

        assert!(!names.contains(&"area".to_owned()));
        assert!(!names.contains(&"other".to_owned()));

        let (index, held) = fixture.binding_at("Named", 0);

        assert_eq!(
            fixture.semantic.scopes()[held.scope as usize].kind,
            ScopeKind::Class
        );

        assert_eq!(fixture.resolution_of("Named", 0), Resolution::Bound(index));
        assert_eq!(fixture.resolution_of("Named", 1), Resolution::Unresolved);
    }

    #[test]
    fn an_arrow_owns_no_arguments_and_reads_the_function_around_it() {
        let fixture = Fixture::read("arrows.js");
        let held = fixture.reference_of("arguments", 0);
        let arrow = fixture.semantic.scopes()[held.scope as usize];

        assert!(arrow.arrow);
        assert_eq!(arrow.kind, ScopeKind::Function);

        let owner = fixture.semantic.function_scope_of(held.scope);

        assert_ne!(owner, held.scope);
        assert!(!fixture.semantic.scopes()[owner as usize].arrow);
    }

    #[test]
    fn a_with_statement_and_an_eval_call_degrade_a_failed_load_to_maybe() {
        let fixture = Fixture::read("dynamic.js");

        assert_eq!(fixture.resolution_of("missing", 0), Resolution::Maybe);
        assert_eq!(fixture.resolution_of("absent", 0), Resolution::Maybe);

        assert_eq!(
            fixture.resolution_of("elsewhere", 0),
            Resolution::Unresolved
        );
    }

    #[test]
    fn an_export_reads_its_local_and_a_reexport_reads_none() {
        let fixture = Fixture::read("exports.js");
        let (index, _) = fixture.binding_at("local", 0);
        let held = fixture.references();

        assert_eq!(
            held,
            vec![
                ("local".to_owned(), Resolution::Bound(index)),
                ("local".to_owned(), Resolution::Bound(index)),
            ]
        );

        assert_eq!(fixture.semantic.module(), ModuleKind::Module);
    }

    #[test]
    fn an_import_binds_each_clause_by_its_form() {
        let fixture = Fixture::read("imports.js");

        assert_eq!(
            fixture.bindings(),
            vec![
                (BindingKind::ImportDefault, "fallback".to_owned(), 0),
                (BindingKind::ImportNamespace, "space".to_owned(), 0),
                (BindingKind::Import, "named".to_owned(), 0),
                (BindingKind::Import, "renamed".to_owned(), 0),
                (BindingKind::Const, "held".to_owned(), 0),
            ]
        );
    }

    #[test]
    fn the_module_kind_falls_out_of_the_syntax_and_the_caller_can_override_it() {
        let script = Fixture::of(b"var held = 1;\n", None);

        assert_eq!(script.semantic.module(), ModuleKind::Script);
        assert_eq!(script.scopes()[0].0, ScopeKind::Global);

        let module = Fixture::of(b"var held = 1;\n", Some(ModuleKind::Module));

        assert_eq!(module.semantic.module(), ModuleKind::Module);
        assert_eq!(module.scopes()[0].0, ScopeKind::Module);
    }

    #[test]
    fn the_module_facts_name_every_form_the_source_writes() {
        let fixture = Fixture::read("facts.js");

        assert_eq!(
            fixture.facts(),
            vec![
                "ImportDefault fallback . ./one",
                "ImportNamespace space . two",
                "ImportNamed named named ./three/four",
                "ImportNamed renamed aliased ./three/four",
                "ImportSideEffect . . ./side-effect",
                "ImportDefault required . ./five",
                "ImportSideEffect . . ./six",
                "ExportNamed first first .",
                "ExportNamed second second .",
                "ExportNamed Third Third .",
                "ExportNamed first first .",
                "ExportNamed second alias .",
                "ExportDefault first . .",
                "ExportAll . . ./seven",
                "ExportAll bundle . ./eight",
                "Reexport remote remote ./nine",
                "Reexport renamedRemote other ./nine",
            ]
        );
    }

    #[test]
    fn every_javascript_specifier_slices_back_to_the_text_the_source_wrote() {
        let fixture = Fixture::read("facts.js");
        let mut compared = 0;

        for fact in fixture.semantic.facts() {
            if fact.specifier == Span::EMPTY {
                continue;
            }

            let held = fixture.text_of(fact.specifier);
            let quoted = format!("\"{held}\"");

            assert!(
                fixture
                    .source
                    .windows(quoted.len())
                    .any(|window| window == quoted.as_bytes()),
                "the source writes no specifier {held}"
            );

            compared += 1;
        }

        assert!(compared > 6);
    }

    #[test]
    fn a_binding_a_fact_names_carries_the_name_the_fact_carries() {
        let fixture = Fixture::read("facts.js");
        let mut compared = 0;

        for fact in fixture.semantic.facts() {
            if fact.binding == NONE {
                continue;
            }

            let held = fixture.semantic.get(fact.binding).expect("the row exists");

            assert_eq!(fixture.text_of(held.name), fixture.text_of(fact.local));

            compared += 1;
        }

        assert!(compared > 6);
    }

    #[test]
    fn a_declaration_merge_chains_both_bindings() {
        let fixture = Fixture::read_typescript("merges.ts");
        let (first, _) = fixture.binding_at("Shape", 0);
        let (_, second) = fixture.binding_at("Shape", 1);

        assert_eq!(second.previous, first);

        let (widget, class) = fixture.binding_at("Widget", 0);
        let (_, interface) = fixture.binding_at("Widget", 1);

        assert_eq!(class.kind, BindingKind::Class);
        assert_eq!(interface.kind, BindingKind::Interface);
        assert_eq!(interface.previous, widget);

        let (overload, function) = fixture.binding_at("overload", 0);
        let (_, namespace) = fixture.binding_at("overload", 1);

        assert_eq!(function.kind, BindingKind::Function);
        assert_eq!(namespace.kind, BindingKind::Namespace);
        assert_eq!(namespace.previous, overload);
    }

    #[test]
    fn a_type_only_declaration_binds_in_the_type_space_alone() {
        let fixture = Fixture::read_typescript("namespaces.ts");
        let (alias, held) = fixture.binding_at("Alias", 0);

        assert_eq!(held.namespace, Namespace::Type);
        assert!(!held.kind.binds_in(Namespace::Value));
        assert_eq!(fixture.resolution_of("Alias", 0), Resolution::Bound(alias));

        let (colour, colours) = fixture.binding_at("Colour", 0);

        assert!(colours.kind.binds_in(Namespace::Type));
        assert!(colours.kind.binds_in(Namespace::Value));

        assert_eq!(
            fixture.resolution_of("Colour", 0),
            Resolution::Bound(colour)
        );

        assert_eq!(
            fixture.resolution_of("Colour", 1),
            Resolution::Bound(colour)
        );

        let (_, remote) = fixture.binding_at("Remote", 0);

        assert_eq!(remote.kind, BindingKind::ImportType);
        assert!(!remote.kind.binds_in(Namespace::Value));
    }

    #[test]
    fn a_type_parameter_binds_beside_the_declaration_that_opens_it() {
        let fixture = Fixture::read_typescript("generics.ts");
        let (held, parameter) = fixture.binding_at("Held", 0);

        assert_eq!(parameter.kind, BindingKind::TypeParameter);

        assert_eq!(
            fixture.semantic.scopes()[parameter.scope as usize].kind,
            ScopeKind::Function
        );

        assert_eq!(fixture.resolution_of("Held", 0), Resolution::Bound(held));
        assert_eq!(fixture.resolution_of("Held", 2), Resolution::Unresolved);

        let (inner, _) = fixture.binding_at("Inner", 0);

        assert_eq!(fixture.resolution_of("Inner", 0), Resolution::Bound(inner));
    }

    #[test]
    fn a_variance_modifier_leaves_a_type_parameter_its_own_name() {
        let fixture = Fixture::typescript(b"interface O<out Shape, in A, const B> {}\n");

        assert_eq!(
            fixture.bindings(),
            vec![
                (BindingKind::Interface, "O".to_owned(), 0),
                (BindingKind::TypeParameter, "Shape".to_owned(), 1),
                (BindingKind::TypeParameter, "A".to_owned(), 1),
                (BindingKind::TypeParameter, "B".to_owned(), 1),
            ]
        );
    }

    #[test]
    fn a_type_parameter_may_itself_be_named_out() {
        let fixture = Fixture::typescript(b"type Q<out> = out;\n");
        let (held, parameter) = fixture.binding_at("out", 0);

        assert_eq!(parameter.kind, BindingKind::TypeParameter);
        assert_eq!(fixture.resolution_of("out", 0), Resolution::Bound(held));
    }

    #[test]
    fn a_signature_names_its_parameters_and_declares_none() {
        let mut source = Vec::from(b"type F = (k: string) => void;\n".as_slice());

        source.extend_from_slice(b"interface I { m(k: number): void; (k: number): void }\n");
        source.extend_from_slice(b"declare function h(k: number): void;\n");

        let fixture = Fixture::typescript(&source);

        assert!(
            !fixture
                .bindings()
                .iter()
                .any(|(kind, _, _)| *kind == BindingKind::Parameter)
        );
    }

    #[test]
    fn a_parameter_carrying_a_member_modifier_declares_a_field() {
        let fixture =
            Fixture::typescript(b"class C { constructor(readonly cfg: T, private x: U) {} }\n");

        let (_, cfg) = fixture.binding_at("cfg", 0);
        let (_, x) = fixture.binding_at("x", 0);

        assert_eq!(cfg.kind, BindingKind::ParameterProperty);
        assert_eq!(x.kind, BindingKind::ParameterProperty);
    }

    #[test]
    fn a_pattern_binds_its_names_in_the_order_the_source_writes_them() {
        let fixture = Fixture::of(b"function f([first, second], { third }) {}\n", None);

        assert_eq!(
            fixture.bindings(),
            vec![
                (BindingKind::Function, "f".to_owned(), 0),
                (BindingKind::Parameter, "first".to_owned(), 1),
                (BindingKind::Parameter, "second".to_owned(), 1),
                (BindingKind::Parameter, "third".to_owned(), 1),
            ]
        );
    }

    #[test]
    fn a_parameter_carries_the_position_it_stands_at() {
        let fixture = Fixture::of(b"function f(first, [second, third]) {}\n", None);

        assert_eq!(fixture.binding_at("first", 0).1.parameter, 0);
        assert_eq!(fixture.binding_at("second", 0).1.parameter, 1);
        assert_eq!(fixture.binding_at("third", 0).1.parameter, 1);
        assert_eq!(fixture.binding_at("f", 0).1.parameter, PARAMETER_NONE);
    }

    #[test]
    fn a_built_in_jsx_tag_looks_for_no_declaration() {
        let mut source = Vec::from(b"import Comp from \"m\";\n".as_slice());

        source.extend_from_slice(b"const held = <div><Comp /><foo-bar /></div>;\n");

        let fixture = Fixture::tsx(&source);
        let (comp, _) = fixture.binding_at("Comp", 0);

        assert_eq!(
            fixture.references(),
            vec![("Comp".to_owned(), Resolution::Bound(comp))]
        );
    }

    #[test]
    fn a_jsx_component_reads_at_its_opening_and_its_closing_tag() {
        let fixture = Fixture::tsx(b"const held = <Ns.T>text</Ns.T>;\n");

        assert_eq!(
            fixture.references(),
            vec![
                ("Ns".to_owned(), Resolution::Unresolved),
                ("Ns".to_owned(), Resolution::Unresolved),
            ]
        );
    }

    #[test]
    fn an_inline_type_specifier_types_only_its_own_import() {
        let fixture = Fixture::typescript(b"import { type A, b, type C, d } from \"m\";\n");

        assert_eq!(
            fixture.bindings(),
            vec![
                (BindingKind::ImportType, "A".to_owned(), 0),
                (BindingKind::Import, "b".to_owned(), 0),
                (BindingKind::ImportType, "C".to_owned(), 0),
                (BindingKind::Import, "d".to_owned(), 0),
            ]
        );
    }

    #[test]
    fn an_import_named_type_is_not_a_type_only_import() {
        let fixture =
            Fixture::typescript(b"import type from \"m\";\nimport { type as held } from \"m\";\n");

        assert_eq!(
            fixture.bindings(),
            vec![
                (BindingKind::ImportDefault, "type".to_owned(), 0),
                (BindingKind::Import, "held".to_owned(), 0),
            ]
        );
    }

    #[test]
    fn an_import_equals_binds_the_name_it_writes() {
        let mut source = Vec::from(b"import held = require(\"m\");\n".as_slice());

        source.extend_from_slice(b"import alias = A.B;\n");

        let fixture = Fixture::typescript(&source);

        assert_eq!(
            fixture.bindings(),
            vec![
                (BindingKind::Import, "held".to_owned(), 0),
                (BindingKind::Import, "alias".to_owned(), 0),
            ]
        );

        assert_eq!(fixture.facts(), vec!["ImportNamespace held . m".to_owned()]);
    }

    #[test]
    fn an_exported_pattern_hands_out_every_name_it_binds() {
        let fixture = Fixture::of(b"export const { first, second: [third] } = held;\n", None);

        assert_eq!(
            fixture.facts(),
            vec![
                "ExportNamed first first .".to_owned(),
                "ExportNamed third third .".to_owned(),
            ]
        );
    }

    #[test]
    fn an_export_clause_reaches_either_space_and_names_no_alias() {
        let mut source = Vec::from(b"interface Held {}\n".as_slice());

        source.extend_from_slice(b"export { Held, Held as other };\n");

        let fixture = Fixture::typescript(&source);
        let (held, _) = fixture.binding_at("Held", 0);

        assert_eq!(
            fixture.references(),
            vec![
                ("Held".to_owned(), Resolution::Bound(held)),
                ("Held".to_owned(), Resolution::Bound(held)),
            ]
        );
    }

    #[test]
    fn an_infer_binds_for_the_conditional_type_that_holds_it() {
        let fixture =
            Fixture::typescript(b"type J<T> = T extends (k: infer Held) => void ? Held : never;\n");

        let (held, binding) = fixture.binding_at("Held", 0);

        assert_eq!(binding.kind, BindingKind::TypeParameter);
        assert_eq!(fixture.resolution_of("Held", 0), Resolution::Bound(held));
    }

    #[test]
    fn a_type_predicate_and_an_index_signature_name_nothing_in_scope() {
        let mut source = Vec::from(b"type P = (k: unknown) => k is string;\n".as_slice());

        source.extend_from_slice(b"interface I { [key: string]: unknown }\n");

        let fixture = Fixture::typescript(&source);

        assert_eq!(fixture.references(), Vec::new());
    }

    #[test]
    fn a_dotted_type_name_reads_only_its_qualifier() {
        let mut source = Vec::from(b"import type { Ns } from \"m\";\n".as_slice());

        source.extend_from_slice(b"type A = Ns.Props;\n");

        let fixture = Fixture::typescript(&source);
        let (ns, _) = fixture.binding_at("Ns", 0);

        assert_eq!(
            fixture.references(),
            vec![("Ns".to_owned(), Resolution::Bound(ns))]
        );
    }

    #[test]
    fn a_typeof_in_the_type_space_reaches_a_type_only_import() {
        let mut source = Vec::from(b"import type { held } from \"m\";\n".as_slice());

        source.extend_from_slice(b"type A = typeof held;\n");

        let fixture = Fixture::typescript(&source);
        let (binding, _) = fixture.binding_at("held", 0);

        assert_eq!(fixture.resolution_of("held", 0), Resolution::Bound(binding));
        assert_eq!(fixture.reference_of("held", 0).namespace, Namespace::Any);
    }

    #[test]
    fn an_ambient_module_opens_a_scope_of_its_own() {
        let fixture =
            Fixture::typescript(b"declare module \"m\" { interface Held { a: number } }\n");

        let (_, binding) = fixture.binding_at("Held", 0);
        let scopes = fixture.scopes();
        let parent = scopes[binding.scope as usize].1;

        assert_eq!(scopes[binding.scope as usize].0, ScopeKind::Block);
        assert_eq!(scopes[parent as usize].0, ScopeKind::Ambient);
    }

    #[test]
    fn a_namespace_written_without_declare_opens_a_function_scope() {
        let fixture = Fixture::typescript(b"namespace M { interface Held { a: number } }\n");
        let (_, binding) = fixture.binding_at("Held", 0);
        let scopes = fixture.scopes();
        let parent = scopes[binding.scope as usize].1;

        assert_eq!(scopes[binding.scope as usize].0, ScopeKind::Block);
        assert_eq!(scopes[parent as usize].0, ScopeKind::Function);
    }
}
