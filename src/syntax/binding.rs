use crate::bounded::Span;
use crate::syntax::go::semantic as go;
use crate::syntax::javascript::semantic as javascript;
use crate::syntax::odin::semantic as odin;
use crate::syntax::python::bind::ScopeKind as PythonScopeKind;
use crate::syntax::python::semantic as python;
use crate::syntax::rust::semantic as rust;
use crate::syntax::zig::semantic as zig;

pub const REFERENCE_COUNT_MAX: u32 = 1 << 20;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum BindingClass {
    Constant,
    Field,
    Function,
    Import,
    Local,
    Method,
    Other,
    Parameter,
    Type,
    Variant,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ScopeClass {
    Block,
    Function,
    Module,
    Other,
    Type,
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
pub struct Binding {
    pub class: BindingClass,
    pub name: Span,
    pub node: u32,
    pub scope: u32,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Reference {
    pub is_store: bool,
    pub name: Span,
    pub node: u32,
    pub resolution: Resolution,
    pub scope: u32,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Scope {
    pub class: ScopeClass,
    pub node: u32,
    pub parent: u32,
}

#[derive(Clone, Copy)]
pub enum Bindings<'run> {
    Empty,
    Go(&'run go::Semantic),
    JavaScript(&'run javascript::Semantic),
    Odin(&'run odin::Semantic),
    Python(&'run python::Semantic),
    Rust(&'run rust::Semantic),
    Zig(&'run zig::Semantic),
}

macro_rules! each {
    ($held:expr, $semantic:ident => $body:expr, $empty:expr) => {
        match $held {
            Bindings::Empty => $empty,
            Bindings::Go($semantic) => $body,
            Bindings::JavaScript($semantic) => $body,
            Bindings::Odin($semantic) => $body,
            Bindings::Python($semantic) => $body,
            Bindings::Rust($semantic) => $body,
            Bindings::Zig($semantic) => $body,
        }
    };
}

impl Bindings<'_> {
    pub fn count(&self) -> u32 {
        each!(self, semantic => semantic.count(), 0)
    }

    pub fn at(&self, index: u32) -> Option<Binding> {
        assert!(index < self.count());

        match self {
            Self::Empty => None,
            Self::Go(semantic) => semantic.get(index).map(go_binding),
            Self::JavaScript(semantic) => semantic.get(index).map(javascript_binding),
            Self::Odin(semantic) => semantic.get(index).map(odin_binding),
            Self::Python(semantic) => semantic.get(index).map(python_binding),
            Self::Rust(semantic) => semantic.get(index).map(rust_binding),
            Self::Zig(semantic) => semantic.get(index).map(zig_binding),
        }
    }

    pub fn bindings_of(&self, scope: u32, mut visit: impl FnMut(u32)) {
        assert!(scope < self.scope_count());

        let mut steps = 0_u32;

        each!(
            self,
            semantic => {
                for binding in semantic.bindings_of(scope) {
                    steps += 1;

                    assert!(steps <= REFERENCE_COUNT_MAX);

                    visit(binding);
                }
            },
            ()
        );
    }

    pub fn reference_count(&self) -> u32 {
        each!(self, semantic => u32::try_from(semantic.references().len()).unwrap_or(u32::MAX), 0)
    }

    pub fn reference_at(&self, index: u32) -> Option<Reference> {
        assert!(index < self.reference_count());

        match self {
            Self::Empty => None,
            Self::Go(semantic) => semantic.references().get(index as usize).map(go_reference),
            Self::JavaScript(semantic) => semantic
                .references()
                .get(index as usize)
                .map(javascript_reference),
            Self::Odin(semantic) => semantic
                .references()
                .get(index as usize)
                .map(odin_reference),
            Self::Python(semantic) => semantic
                .references()
                .get(index as usize)
                .map(python_reference),
            Self::Rust(semantic) => semantic
                .references()
                .get(index as usize)
                .map(rust_reference),
            Self::Zig(semantic) => semantic.references().get(index as usize).map(zig_reference),
        }
    }

    pub fn references_of(&self, binding: u32, mut visit: impl FnMut(Reference)) {
        assert!(binding < self.count());

        let mut steps = 0_u32;

        match self {
            Self::Empty => {}
            Self::Go(semantic) => {
                for index in semantic.references_of(binding) {
                    steps += 1;

                    assert!(steps <= REFERENCE_COUNT_MAX);

                    visit(go_reference(&semantic.references()[index as usize]));
                }
            }
            Self::JavaScript(semantic) => {
                for index in semantic.references_of(binding) {
                    steps += 1;

                    assert!(steps <= REFERENCE_COUNT_MAX);

                    visit(javascript_reference(&semantic.references()[index as usize]));
                }
            }
            Self::Odin(semantic) => {
                for index in semantic.references_of(binding) {
                    steps += 1;

                    assert!(steps <= REFERENCE_COUNT_MAX);

                    visit(odin_reference(&semantic.references()[index as usize]));
                }
            }
            Self::Python(semantic) => {
                for index in semantic.references_of(binding) {
                    steps += 1;

                    assert!(steps <= REFERENCE_COUNT_MAX);

                    visit(python_reference(&semantic.references()[index as usize]));
                }
            }
            Self::Rust(semantic) => {
                for index in semantic.references_of(binding) {
                    steps += 1;

                    assert!(steps <= REFERENCE_COUNT_MAX);

                    visit(rust_reference(&semantic.references()[index as usize]));
                }
            }
            Self::Zig(semantic) => {
                for index in semantic.references_of(binding) {
                    steps += 1;

                    assert!(steps <= REFERENCE_COUNT_MAX);

                    visit(zig_reference(&semantic.references()[index as usize]));
                }
            }
        }
    }

    pub fn scope_count(&self) -> u32 {
        each!(self, semantic => u32::try_from(semantic.scopes().len()).unwrap_or(u32::MAX), 0)
    }

    pub fn scope_at(&self, index: u32) -> Option<Scope> {
        assert!(index < self.scope_count());

        match self {
            Self::Empty => None,
            Self::Go(semantic) => semantic.scopes().get(index as usize).map(|scope| Scope {
                class: go_scope_class(scope.kind),
                node: scope.node,
                parent: scope.parent,
            }),
            Self::JavaScript(semantic) => {
                semantic.scopes().get(index as usize).map(|scope| Scope {
                    class: javascript_scope_class(scope.kind),
                    node: scope.node,
                    parent: scope.parent,
                })
            }
            Self::Odin(semantic) => semantic.scopes().get(index as usize).map(|scope| Scope {
                class: odin_scope_class(scope.kind),
                node: scope.node,
                parent: scope.parent,
            }),
            Self::Python(semantic) => semantic.scopes().get(index as usize).map(|scope| Scope {
                class: python_scope_class(scope.kind),
                node: scope.node,
                parent: scope.parent,
            }),
            Self::Rust(semantic) => semantic.scopes().get(index as usize).map(|scope| Scope {
                class: rust_scope_class(scope.kind),
                node: scope.node,
                parent: scope.parent,
            }),
            Self::Zig(semantic) => semantic.scopes().get(index as usize).map(|scope| Scope {
                class: zig_scope_class(scope.kind),
                node: scope.node,
                parent: scope.parent,
            }),
        }
    }
}

fn go_binding(held: &go::Binding) -> Binding {
    let class = match held.kind {
        go::BindingKind::Const => BindingClass::Constant,
        go::BindingKind::Field => BindingClass::Field,
        go::BindingKind::Function => BindingClass::Function,
        go::BindingKind::Import | go::BindingKind::ImportBlank | go::BindingKind::ImportDot => {
            BindingClass::Import
        }
        go::BindingKind::Label => BindingClass::Other,
        go::BindingKind::Method => BindingClass::Method,
        go::BindingKind::Parameter | go::BindingKind::Receiver => BindingClass::Parameter,
        go::BindingKind::Result | go::BindingKind::Short | go::BindingKind::Var => {
            BindingClass::Local
        }
        go::BindingKind::Type | go::BindingKind::TypeParameter => BindingClass::Type,
    };

    Binding {
        class,
        name: held.name,
        node: held.node,
        scope: held.scope,
    }
}

fn javascript_binding(held: &javascript::Binding) -> Binding {
    let class = match held.kind {
        javascript::BindingKind::CatchParameter | javascript::BindingKind::Parameter => {
            BindingClass::Parameter
        }
        javascript::BindingKind::Class
        | javascript::BindingKind::Enum
        | javascript::BindingKind::Interface
        | javascript::BindingKind::TypeAlias
        | javascript::BindingKind::TypeParameter => BindingClass::Type,
        javascript::BindingKind::Const => BindingClass::Constant,
        javascript::BindingKind::EnumMember => BindingClass::Variant,
        javascript::BindingKind::Function | javascript::BindingKind::Signature => {
            BindingClass::Function
        }
        javascript::BindingKind::Import
        | javascript::BindingKind::ImportDefault
        | javascript::BindingKind::ImportNamespace
        | javascript::BindingKind::ImportType => BindingClass::Import,
        javascript::BindingKind::Let | javascript::BindingKind::Var => BindingClass::Local,
        javascript::BindingKind::Namespace => BindingClass::Other,
        javascript::BindingKind::ParameterProperty => BindingClass::Field,
    };

    Binding {
        class,
        name: held.name,
        node: held.node,
        scope: held.scope,
    }
}

fn odin_binding(held: &odin::Binding) -> Binding {
    let class = match held.kind {
        odin::BindingKind::Const => BindingClass::Constant,
        odin::BindingKind::Field | odin::BindingKind::Member => BindingClass::Field,
        odin::BindingKind::Import => BindingClass::Import,
        odin::BindingKind::Label => BindingClass::Other,
        odin::BindingKind::Parameter => BindingClass::Parameter,
        odin::BindingKind::Procedure => BindingClass::Function,
        odin::BindingKind::Result | odin::BindingKind::Var => BindingClass::Local,
        odin::BindingKind::Type => BindingClass::Type,
    };

    Binding {
        class,
        name: held.name,
        node: held.node,
        scope: held.scope,
    }
}

fn python_binding(held: &python::Binding) -> Binding {
    let class = match held.kind {
        python::BindingKind::Annotation
        | python::BindingKind::Assignment
        | python::BindingKind::Augmented
        | python::BindingKind::ComprehensionVariable
        | python::BindingKind::ExceptVariable
        | python::BindingKind::LoopVariable
        | python::BindingKind::MatchCapture
        | python::BindingKind::Named
        | python::BindingKind::WithVariable => BindingClass::Local,
        python::BindingKind::ClassDefinition
        | python::BindingKind::TypeAlias
        | python::BindingKind::TypeParameter => BindingClass::Type,
        python::BindingKind::Deletion
        | python::BindingKind::Global
        | python::BindingKind::Nonlocal => BindingClass::Other,
        python::BindingKind::FunctionDefinition => BindingClass::Function,
        python::BindingKind::FutureImport
        | python::BindingKind::Import
        | python::BindingKind::ImportFrom
        | python::BindingKind::ImportStar
        | python::BindingKind::SubmoduleImport => BindingClass::Import,
        python::BindingKind::Parameter => BindingClass::Parameter,
    };

    Binding {
        class,
        name: held.name,
        node: held.node,
        scope: held.scope,
    }
}

fn rust_binding(held: &rust::Binding) -> Binding {
    let class = match held.kind {
        rust::BindingKind::AssociatedConst
        | rust::BindingKind::Const
        | rust::BindingKind::Static => BindingClass::Constant,
        rust::BindingKind::AssociatedFunction => BindingClass::Method,
        rust::BindingKind::AssociatedType
        | rust::BindingKind::ConstParameter
        | rust::BindingKind::Enum
        | rust::BindingKind::Struct
        | rust::BindingKind::Trait
        | rust::BindingKind::TraitAlias
        | rust::BindingKind::TypeAlias
        | rust::BindingKind::TypeParameter
        | rust::BindingKind::Union => BindingClass::Type,
        rust::BindingKind::Field => BindingClass::Field,
        rust::BindingKind::Variant => BindingClass::Variant,
        rust::BindingKind::Function => BindingClass::Function,
        rust::BindingKind::Import => BindingClass::Import,
        rust::BindingKind::Label
        | rust::BindingKind::Lifetime
        | rust::BindingKind::Macro
        | rust::BindingKind::Module => BindingClass::Other,
        rust::BindingKind::Local => BindingClass::Local,
        rust::BindingKind::Parameter => BindingClass::Parameter,
    };

    Binding {
        class,
        name: held.name,
        node: held.node,
        scope: held.scope,
    }
}

fn zig_binding(held: &zig::Binding) -> Binding {
    let class = match held.kind {
        zig::BindingKind::Capture | zig::BindingKind::Var => BindingClass::Local,
        zig::BindingKind::Const => BindingClass::Constant,
        zig::BindingKind::Field => BindingClass::Field,
        zig::BindingKind::Function => BindingClass::Function,
        zig::BindingKind::Label => BindingClass::Other,
        zig::BindingKind::Parameter => BindingClass::Parameter,
    };

    Binding {
        class,
        name: held.name,
        node: held.node,
        scope: held.scope,
    }
}

fn go_reference(held: &go::Reference) -> Reference {
    Reference {
        is_store: held.context == go::Context::Store,
        name: held.name,
        node: held.node,
        resolution: match held.resolution {
            go::Resolution::Bound(binding) => Resolution::Bound(binding),
            go::Resolution::Builtin => Resolution::Builtin,
            go::Resolution::Maybe => Resolution::Maybe,
            go::Resolution::Unresolved => Resolution::Unresolved,
        },
        scope: held.scope,
    }
}

fn javascript_reference(held: &javascript::Reference) -> Reference {
    Reference {
        is_store: held.context == javascript::Context::Store,
        name: held.name,
        node: held.node,
        resolution: match held.resolution {
            javascript::Resolution::Bound(binding) => Resolution::Bound(binding),
            javascript::Resolution::Builtin => Resolution::Builtin,
            javascript::Resolution::Maybe => Resolution::Maybe,
            javascript::Resolution::Unresolved => Resolution::Unresolved,
        },
        scope: held.scope,
    }
}

fn odin_reference(held: &odin::Reference) -> Reference {
    Reference {
        is_store: held.context == odin::Context::Store,
        name: held.name,
        node: held.node,
        resolution: match held.resolution {
            odin::Resolution::Bound(binding) => Resolution::Bound(binding),
            odin::Resolution::Builtin => Resolution::Builtin,
            odin::Resolution::Maybe => Resolution::Maybe,
            odin::Resolution::Unresolved => Resolution::Unresolved,
        },
        scope: held.scope,
    }
}

fn python_reference(held: &python::Reference) -> Reference {
    Reference {
        is_store: matches!(
            held.context,
            python::Context::Delete | python::Context::Store
        ),
        name: held.name,
        node: held.node,
        resolution: match held.resolution {
            python::Resolution::Bound(binding) => Resolution::Bound(binding),
            python::Resolution::Builtin => Resolution::Builtin,
            python::Resolution::Maybe => Resolution::Maybe,
            python::Resolution::Unresolved => Resolution::Unresolved,
        },
        scope: held.scope,
    }
}

fn rust_reference(held: &rust::Reference) -> Reference {
    Reference {
        is_store: held.context == rust::Context::Store,
        name: held.name,
        node: held.node,
        resolution: match held.resolution {
            rust::Resolution::Bound(binding) => Resolution::Bound(binding),
            rust::Resolution::Builtin => Resolution::Builtin,
            rust::Resolution::External => Resolution::External,
            rust::Resolution::Maybe => Resolution::Maybe,
            rust::Resolution::Unresolved => Resolution::Unresolved,
        },
        scope: held.scope,
    }
}

fn zig_reference(held: &zig::Reference) -> Reference {
    Reference {
        is_store: held.context == zig::Context::Store,
        name: held.name,
        node: held.node,
        resolution: match held.resolution {
            zig::Resolution::Bound(binding) => Resolution::Bound(binding),
            zig::Resolution::Builtin => Resolution::Builtin,
            zig::Resolution::Unresolved => Resolution::Unresolved,
        },
        scope: held.scope,
    }
}

fn go_scope_class(kind: go::ScopeKind) -> ScopeClass {
    match kind {
        go::ScopeKind::Block => ScopeClass::Block,
        go::ScopeKind::File | go::ScopeKind::Package => ScopeClass::Module,
        go::ScopeKind::Function => ScopeClass::Function,
    }
}

fn javascript_scope_class(kind: javascript::ScopeKind) -> ScopeClass {
    match kind {
        javascript::ScopeKind::Block
        | javascript::ScopeKind::Catch
        | javascript::ScopeKind::With => ScopeClass::Block,

        javascript::ScopeKind::Class => ScopeClass::Type,
        javascript::ScopeKind::Function => ScopeClass::Function,

        javascript::ScopeKind::Ambient
        | javascript::ScopeKind::Global
        | javascript::ScopeKind::Module => ScopeClass::Module,
    }
}

fn odin_scope_class(kind: odin::ScopeKind) -> ScopeClass {
    match kind {
        odin::ScopeKind::Block => ScopeClass::Block,
        odin::ScopeKind::File => ScopeClass::Module,
        odin::ScopeKind::Item => ScopeClass::Other,
        odin::ScopeKind::Procedure => ScopeClass::Function,
    }
}

fn rust_scope_class(kind: rust::ScopeKind) -> ScopeClass {
    match kind {
        rust::ScopeKind::Block => ScopeClass::Block,
        rust::ScopeKind::Function => ScopeClass::Function,
        rust::ScopeKind::Item => ScopeClass::Other,
        rust::ScopeKind::Module => ScopeClass::Module,
    }
}

fn zig_scope_class(kind: zig::ScopeKind) -> ScopeClass {
    match kind {
        zig::ScopeKind::Block => ScopeClass::Block,
        zig::ScopeKind::Container => ScopeClass::Type,
        zig::ScopeKind::Function => ScopeClass::Function,
    }
}

fn python_scope_class(kind: PythonScopeKind) -> ScopeClass {
    match kind {
        PythonScopeKind::Class => ScopeClass::Type,
        PythonScopeKind::Comprehension => ScopeClass::Block,
        PythonScopeKind::Function | PythonScopeKind::Lambda => ScopeClass::Function,
        PythonScopeKind::Module => ScopeClass::Module,
        PythonScopeKind::Type | PythonScopeKind::TypeAlias | PythonScopeKind::TypeVariable => {
            ScopeClass::Other
        }
    }
}
