use crate::bounded::{BoundedVec, Span};
use crate::syntax::Category;
use crate::syntax::go::ast as go;
use crate::syntax::go::kind::GoKind;
use crate::syntax::javascript::ast as javascript;
use crate::syntax::javascript::kind::JavaScriptKind;
use crate::syntax::odin::ast as odin;
use crate::syntax::odin::kind::OdinKind;
use crate::syntax::python::ast as python;
use crate::syntax::python::kind::PythonKind;
use crate::syntax::rust::ast as rust;
use crate::syntax::rust::kind::RustKind;
use crate::syntax::typescript::ast as typescript;
use crate::syntax::typescript::kind::TypeScriptKind;
use crate::syntax::zig::ast as zig;
use crate::syntax::zig::kind::ZigKind;
use crate::token::{Punctuation, Token, TokenKind};
use crate::tree::NONE;

pub const CHILD_COUNT_MAX: u32 = 1 << 16;
pub const PARAMETER_COUNT_MAX: u32 = 1 << 8;
pub const SEGMENT_COUNT_MAX: u32 = 1 << 6;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Literal {
    Boolean,
    Bytes,
    Character,
    Nil,
    Number,
    Other,
    Regex,
    Template,
    Text,
}

#[derive(Clone, Copy, Debug)]
pub enum View<'run> {
    Go(go::View<'run>),
    JavaScript(javascript::View<'run>),
    Odin(odin::View<'run>),
    Python(python::View<'run>),
    Rust(rust::View<'run>),
    TypeScript(typescript::View<'run>),
    Zig(zig::View<'run>),
}

#[derive(Clone, Copy, Debug)]
pub struct Call<'run>(View<'run>);

#[derive(Clone, Copy, Debug)]
pub struct Constant<'run>(View<'run>);

#[derive(Clone, Copy, Debug)]
pub struct Container<'run>(View<'run>);

#[derive(Clone, Copy, Debug)]
pub struct Declaration<'run>(View<'run>);

#[derive(Clone, Copy, Debug)]
pub struct Field<'run>(View<'run>);

#[derive(Clone, Copy, Debug)]
pub struct Function<'run>(View<'run>);

#[derive(Clone, Copy, Debug)]
pub struct Import<'run>(View<'run>);

#[derive(Clone, Copy, Debug)]
pub struct Operation<'run>(View<'run>);

#[derive(Clone, Copy, Debug)]
pub struct Parameter<'run> {
    pub default: Option<View<'run>>,
    pub group: u32,
    pub name: Option<u32>,
    pub node: View<'run>,
    pub span: Span,
    pub type_of: Option<View<'run>>,
    pub type_span: Option<Span>,
}

#[derive(Clone, Copy, Debug)]
pub struct Statement<'run>(View<'run>);

pub struct Children<'run> {
    category: Option<Category>,
    inner: ChildrenInner<'run>,
    steps: u32,
}

pub struct Parameters<'run> {
    inner: ParametersInner<'run>,
    steps: u32,
}

pub enum Names<'run> {
    Children(Children<'run>),
    Positions(Positions<'run>),
    Rust(rust::Children<'run>),
}

pub struct Positions<'run> {
    inner: PositionsInner<'run>,
    steps: u32,
}

enum ChildrenInner<'run> {
    Go(go::Children<'run>),
    JavaScript(javascript::Children<'run>),
    Odin(odin::Children<'run>),
    Python(python::Children<'run>),
    Rust(rust::Children<'run>),
    TypeScript(typescript::Children<'run>),
    Zig(zig::Children<'run>),
}

enum ParametersInner<'run> {
    Empty,
    Go {
        fields: go::Children<'run>,
        names: Option<(go::View<'run>, go::Children<'run>, u32)>,
    },
    JavaScript(javascript::Children<'run>),
    Odin {
        names: Option<(odin::View<'run>, odin::Children<'run>)>,
        parameters: odin::Children<'run>,
    },
    Python(python::Children<'run>),
    Rust(rust::Children<'run>),
    TypeScript(typescript::Children<'run>),
    Zig {
        close: u32,
        cursor: u32,
        prototype: zig::View<'run>,
    },
}

enum PositionsInner<'run> {
    Go(go::Positions<'run>),
    JavaScript(javascript::Positions<'run>),
    Odin(odin::Positions<'run>),
    Python(python::Positions<'run>),
    Rust(rust::Positions<'run>),
    TypeScript(typescript::Positions<'run>),
    Zig(zig::Positions<'run>),
}

macro_rules! each {
    ($held:expr, $view:ident => $body:expr) => {
        match $held {
            View::Go($view) => $body,
            View::JavaScript($view) => $body,
            View::Odin($view) => $body,
            View::Python($view) => $body,
            View::Rust($view) => $body,
            View::TypeScript($view) => $body,
            View::Zig($view) => $body,
        }
    };
}

macro_rules! lift_option {
    ($held:expr, $view:ident => $body:expr) => {
        match $held {
            View::Go($view) => $body.map(View::Go),
            View::JavaScript($view) => $body.map(View::JavaScript),
            View::Odin($view) => $body.map(View::Odin),
            View::Python($view) => $body.map(View::Python),
            View::Rust($view) => $body.map(View::Rust),
            View::TypeScript($view) => $body.map(View::TypeScript),
            View::Zig($view) => $body.map(View::Zig),
        }
    };
}

macro_rules! children_of {
    ($held:expr, $view:ident => $body:expr) => {
        match $held {
            View::Go($view) => ChildrenInner::Go($body),
            View::JavaScript($view) => ChildrenInner::JavaScript($body),
            View::Odin($view) => ChildrenInner::Odin($body),
            View::Python($view) => ChildrenInner::Python($body),
            View::Rust($view) => ChildrenInner::Rust($body),
            View::TypeScript($view) => ChildrenInner::TypeScript($body),
            View::Zig($view) => ChildrenInner::Zig($body),
        }
    };
}

impl<'run> View<'run> {
    pub fn category(self) -> Category {
        each!(self, held => held.kind().category())
    }

    pub fn children(self) -> Children<'run> {
        Children {
            category: None,
            inner: children_of!(self, held => held.children()),
            steps: 0,
        }
    }

    pub fn children_of(self, category: Category) -> Children<'run> {
        Children {
            category: Some(category),
            inner: children_of!(self, held => held.children()),
            steps: 0,
        }
    }

    pub fn child_first(self) -> Option<Self> {
        lift_option!(self, held => held.child_first())
    }

    pub fn child_first_of(self, category: Category) -> Option<Self> {
        self.children_of(category).next()
    }

    pub fn holds(self, category: Category) -> bool {
        self.child_first_of(category).is_some()
    }

    pub fn index(self) -> u32 {
        each!(self, held => held.index())
    }

    pub fn parent(self) -> Option<Self> {
        lift_option!(self, held => held.parent())
    }

    pub fn ancestor_of(self, category: Category) -> Option<Self> {
        let mut current = self.parent();

        for _ in 0..crate::tree::FRAME_DEPTH_MAX {
            let held = current?;

            if held.category() == category {
                return Some(held);
            }

            current = held.parent();
        }

        None
    }

    #[must_use]
    pub fn declaring_of(self) -> Self {
        let mut current = self;

        for _ in 0..crate::tree::FRAME_DEPTH_MAX {
            if current.category() != Category::Name {
                return current;
            }

            let Some(parent) = current.parent() else {
                return current;
            };

            current = parent;
        }

        current
    }

    pub fn name_token(self) -> Option<u32> {
        if let Some(declaration) = self.as_declaration() {
            return declaration.names().next();
        }

        if let Some(function) = self.as_function() {
            return function.name_token();
        }

        if let Some(field) = self.as_field() {
            return field.name_token();
        }

        if let Some(container) = self.as_container() {
            return container.name_token();
        }

        let mut name = self.child_first_of(Category::Name)?;

        for _ in 0..crate::tree::FRAME_DEPTH_MAX {
            let Some(inner) = name.child_first_of(Category::Name) else {
                break;
            };

            name = inner;
        }

        name.positions().next()
    }

    pub fn type_of(self) -> Option<Self> {
        if let Some(declaration) = self.as_declaration() {
            return declaration.type_of();
        }

        if let Some(field) = self.as_field() {
            return field.type_of();
        }

        if self.category() == Category::Declaration {
            return self.child_first_of(Category::Type);
        }

        if self.category() == Category::Parameter {
            return self
                .child_first_of(Category::Type)
                .or_else(|| self.child_first());
        }

        None
    }

    pub fn is_inside_parameters(self) -> bool {
        let held = self.parent().and_then(Self::parent);

        held.is_some_and(|outer| outer.category() == Category::Parameters)
    }

    pub fn declares_a_container(self) -> bool {
        self.as_declaration()
            .and_then(|declaration| declaration.value())
            .is_some_and(|value| value.category() == Category::Struct)
    }

    pub fn positions(self) -> Positions<'run> {
        let inner = match self {
            Self::Go(held) => PositionsInner::Go(held.positions()),
            Self::JavaScript(held) => PositionsInner::JavaScript(held.positions()),
            Self::Odin(held) => PositionsInner::Odin(held.positions()),
            Self::Python(held) => PositionsInner::Python(held.positions()),
            Self::Rust(held) => PositionsInner::Rust(held.positions()),
            Self::TypeScript(held) => PositionsInner::TypeScript(held.positions()),
            Self::Zig(held) => PositionsInner::Zig(held.positions()),
        };

        Positions { inner, steps: 0 }
    }

    pub fn span(self) -> Span {
        each!(self, held => held.span())
    }

    pub fn text(self, source: &'run [u8]) -> &'run [u8] {
        each!(self, held => held.text(source))
    }

    pub fn token_at(self, position: u32) -> Token {
        each!(self, held => held.token_at(position))
    }

    pub fn token_end(self) -> u32 {
        each!(self, held => held.token_end())
    }

    pub fn token_start(self) -> u32 {
        each!(self, held => held.token_start())
    }

    pub fn as_call(self) -> Option<Call<'run>> {
        (self.category() == Category::Call).then_some(Call(self))
    }

    pub fn as_constant(self) -> Option<Constant<'run>> {
        let held = match self {
            Self::Go(held) => held.kind() == GoKind::BasicLit,
            Self::JavaScript(held) => held.as_constant().is_some(),
            Self::Odin(held) => {
                matches!(
                    held.kind(),
                    OdinKind::Boolean
                        | OdinKind::Character
                        | OdinKind::Float
                        | OdinKind::Nil
                        | OdinKind::Number
                        | OdinKind::String
                )
            }
            Self::Python(held) => held.as_constant().is_some(),
            Self::Rust(held) => held.as_constant().is_some(),
            Self::TypeScript(held) => held.as_constant().is_some(),
            Self::Zig(held) => {
                matches!(
                    held.kind(),
                    ZigKind::CharLiteral
                        | ZigKind::NumberLiteral
                        | ZigKind::StringLiteral
                        | ZigKind::MultilineStringLiteral
                )
            }
        };

        held.then_some(Constant(self))
    }

    pub fn as_container(self) -> Option<Container<'run>> {
        let held = match self {
            Self::Go(held) => held.kind() == GoKind::TypeSpec,
            Self::JavaScript(held) => held.as_class().is_some(),
            Self::Odin(held) => held.as_container().is_some(),
            Self::Python(held) => held.as_class().is_some(),
            Self::Rust(held) => held.as_definition().is_some(),
            Self::TypeScript(held) => {
                held.as_class().is_some()
                    || matches!(
                        held.kind(),
                        TypeScriptKind::AbstractClassDeclaration
                            | TypeScriptKind::EnumDeclaration
                            | TypeScriptKind::InterfaceDeclaration
                    )
            }
            Self::Zig(held) => held.as_container().is_some(),
        };

        held.then_some(Container(self))
    }

    pub fn as_declaration(self) -> Option<Declaration<'run>> {
        let held = match self {
            Self::Go(held) => {
                held.kind() == GoKind::ValueSpec
                    || (held.kind() == GoKind::AssignStmt
                        && held.positions_of(GoKind::ColonEqual).next().is_some())
            }
            Self::JavaScript(held) => {
                held.as_declarator().is_some()
                    || matches!(
                        held.kind(),
                        JavaScriptKind::LexicalDeclaration | JavaScriptKind::VariableDeclaration
                    )
            }
            Self::Odin(held) => {
                (held.as_declaration().is_some() && held.kind() != OdinKind::ImportDeclaration)
                    || (held.kind() == OdinKind::AssignmentStatement
                        && held.positions_of(OdinKind::ColonEqual).next().is_some())
            }
            Self::Python(held) => {
                held.as_assign().is_some() && held.kind() != PythonKind::AugAssign
            }
            Self::Rust(held) => {
                matches!(
                    held.kind(),
                    RustKind::ItemConst | RustKind::ItemStatic | RustKind::Local
                )
            }
            Self::TypeScript(held) => {
                held.as_declarator().is_some()
                    || matches!(
                        held.kind(),
                        TypeScriptKind::LexicalDeclaration | TypeScriptKind::VariableDeclaration
                    )
            }
            Self::Zig(held) => held.as_declaration().is_some(),
        };

        held.then_some(Declaration(self))
    }

    pub fn as_field(self) -> Option<Field<'run>> {
        let held = match self {
            Self::Go(held) => held.as_field().is_some(),
            Self::JavaScript(held) => held.kind() == JavaScriptKind::FieldDefinition,
            Self::Odin(held) => held.as_field().is_some(),
            Self::Python(_) => false,
            Self::Rust(held) => held.as_field().is_some(),
            Self::TypeScript(held) => held.kind() == TypeScriptKind::PublicFieldDefinition,
            Self::Zig(held) => held.as_field().is_some(),
        };

        held.then_some(Field(self))
    }

    pub fn as_function(self) -> Option<Function<'run>> {
        let held = matches!(self.category(), Category::Function | Category::Lambda);

        held.then_some(Function(self))
    }

    pub fn as_import(self) -> Option<Import<'run>> {
        let held = match self {
            Self::Go(held) => held.kind() == GoKind::ImportSpec,
            Self::JavaScript(held) => held.as_import().is_some(),
            Self::Odin(held) => held.kind() == OdinKind::ImportDeclaration,
            Self::Python(held) => held.as_import().is_some(),
            Self::Rust(held) => held.as_use().is_some(),
            Self::TypeScript(held) => held.as_import().is_some(),
            Self::Zig(_) => false,
        };

        held.then_some(Import(self))
    }

    pub fn as_operation(self) -> Option<Operation<'run>> {
        let held = each!(self, held => held.as_operation().is_some());

        held.then_some(Operation(self))
    }

    pub fn as_statement(self) -> Option<Statement<'run>> {
        let held = each!(self, held => held.as_statement().is_some());

        held.then_some(Statement(self))
    }
}

impl<'run> Iterator for Children<'run> {
    type Item = View<'run>;

    fn next(&mut self) -> Option<View<'run>> {
        for _ in 0..CHILD_COUNT_MAX {
            self.steps += 1;

            assert!(self.steps <= CHILD_COUNT_MAX);

            let held = match &mut self.inner {
                ChildrenInner::Go(inner) => inner.next().map(View::Go),
                ChildrenInner::JavaScript(inner) => inner.next().map(View::JavaScript),
                ChildrenInner::Odin(inner) => inner.next().map(View::Odin),
                ChildrenInner::Python(inner) => inner.next().map(View::Python),
                ChildrenInner::Rust(inner) => inner.next().map(View::Rust),
                ChildrenInner::TypeScript(inner) => inner.next().map(View::TypeScript),
                ChildrenInner::Zig(inner) => inner.next().map(View::Zig),
            }?;

            match self.category {
                None => return Some(held),
                Some(wanted) => {
                    if held.category() == wanted {
                        return Some(held);
                    }
                }
            }
        }

        None
    }
}

impl Iterator for Names<'_> {
    type Item = u32;

    fn next(&mut self) -> Option<u32> {
        match self {
            Self::Children(children) => {
                for _ in 0..CHILD_COUNT_MAX {
                    let held = children.next()?;

                    if let Some(position) = name_position_of(held) {
                        return Some(position);
                    }
                }

                None
            }
            Self::Positions(positions) => positions.next(),
            Self::Rust(children) => {
                for _ in 0..CHILD_COUNT_MAX {
                    let held = children.next()?;

                    let name = if held.kind() == RustKind::Ident {
                        Some(held)
                    } else if held.kind() == RustKind::PatIdent {
                        held.children_of(RustKind::Ident).next()
                    } else {
                        None
                    };

                    if let Some(position) = name.and_then(|node| node.positions().next()) {
                        return Some(position);
                    }
                }

                None
            }
        }
    }
}

impl<'run> From<rust::Positions<'run>> for Positions<'run> {
    fn from(inner: rust::Positions<'run>) -> Self {
        Self {
            inner: PositionsInner::Rust(inner),
            steps: 0,
        }
    }
}

impl<'run> From<zig::Positions<'run>> for Positions<'run> {
    fn from(inner: zig::Positions<'run>) -> Self {
        Self {
            inner: PositionsInner::Zig(inner),
            steps: 0,
        }
    }
}

impl Iterator for Positions<'_> {
    type Item = u32;

    fn next(&mut self) -> Option<u32> {
        self.steps += 1;

        assert!(self.steps <= CHILD_COUNT_MAX);

        match &mut self.inner {
            PositionsInner::Go(inner) => inner.next(),
            PositionsInner::JavaScript(inner) => inner.next(),
            PositionsInner::Odin(inner) => inner.next(),
            PositionsInner::Python(inner) => inner.next(),
            PositionsInner::Rust(inner) => inner.next(),
            PositionsInner::TypeScript(inner) => inner.next(),
            PositionsInner::Zig(inner) => inner.next(),
        }
    }
}

impl<'run> Call<'run> {
    pub const fn view(self) -> View<'run> {
        self.0
    }

    pub fn callee(self) -> Option<View<'run>> {
        match self.0 {
            View::Go(held) => held.as_call()?.callee().map(View::Go),
            View::JavaScript(held) => held.as_call()?.callee().map(View::JavaScript),
            View::Odin(held) => odin_call(held).child_first().map(View::Odin),
            View::Python(held) => held.as_call()?.callee().map(View::Python),
            View::Rust(held) => rust_callee(held).map(View::Rust),
            View::TypeScript(held) => held.as_call()?.callee().map(View::TypeScript),
            View::Zig(held) => held.as_call()?.callee().map(View::Zig),
        }
    }

    pub fn name_token(self) -> Option<u32> {
        match self.0 {
            View::Go(held) => held.as_call()?.name_token(),
            View::JavaScript(held) => javascript_call_name(held),
            View::Odin(held) => odin_call(held).as_call()?.name_token(),
            View::Python(held) => python_call_name(held),
            View::Rust(held) => rust_call_name(held),
            View::TypeScript(held) => typescript_call_name(held),
            View::Zig(held) => held.as_call()?.name_token(),
        }
    }

    pub fn receiver(self) -> Option<View<'run>> {
        match self.0 {
            View::Go(held) => {
                let callee = held.as_call()?.callee()?;

                (callee.kind() == GoKind::SelectorExpr)
                    .then(|| callee.child_first())
                    .flatten()
                    .map(View::Go)
            }
            View::JavaScript(held) => held
                .as_call()?
                .callee()?
                .as_member()?
                .object()
                .map(View::JavaScript),
            View::Odin(held) => odin_receiver(held).map(View::Odin),
            View::Python(held) => {
                let callee = held.as_call()?.callee()?;

                (callee.kind() == PythonKind::Attribute)
                    .then(|| callee.child_first())
                    .flatten()
                    .map(View::Python)
            }
            View::Rust(held) => (held.kind() == RustKind::ExprMethodCall)
                .then(|| held.child_first())
                .flatten()
                .map(View::Rust),
            View::TypeScript(held) => held
                .as_call()?
                .callee()?
                .as_member()?
                .object()
                .map(View::TypeScript),
            View::Zig(held) => {
                let callee = held.as_call()?.callee()?;

                (callee.kind() == ZigKind::FieldAccess)
                    .then(|| callee.child_first())
                    .flatten()
                    .map(View::Zig)
            }
        }
    }

    pub fn arguments(self) -> Children<'run> {
        let inner = match self.0 {
            View::Go(held) => ChildrenInner::Go(skip_first(held.children(), 1)),
            View::JavaScript(held) => ChildrenInner::JavaScript(
                held.child_first_of(JavaScriptKind::Arguments)
                    .unwrap_or(held)
                    .children(),
            ),
            View::Odin(held) => ChildrenInner::Odin(skip_first(odin_call(held).children(), 1)),
            View::Python(held) => ChildrenInner::Python(skip_first(held.children(), 1)),
            View::Rust(held) => ChildrenInner::Rust(rust_arguments(held)),
            View::TypeScript(held) => ChildrenInner::TypeScript(
                held.child_first_of(TypeScriptKind::Arguments)
                    .unwrap_or(held)
                    .children(),
            ),
            View::Zig(held) => {
                let skipped = u32::from(held.kind() == ZigKind::Call);

                ChildrenInner::Zig(skip_first(held.children(), skipped))
            }
        };

        Children {
            category: None,
            inner,
            steps: 0,
        }
    }
}

impl<'run> Constant<'run> {
    pub const fn view(self) -> View<'run> {
        self.0
    }

    pub fn literal_class(self, source: &[u8]) -> Literal {
        match self.0 {
            View::Go(held) => match go::literal_class(held.text(source)) {
                go::Literal::Number => Literal::Number,
                go::Literal::Rune => Literal::Character,
                go::Literal::Text => Literal::Text,
            },
            View::JavaScript(held) => held.as_constant().map_or(Literal::Other, |constant| {
                javascript_literal(constant.literal_class())
            }),
            View::Odin(held) => match odin::literal_class(held.text(source)) {
                odin::Literal::Character => Literal::Character,
                odin::Literal::Number => Literal::Number,
                odin::Literal::Raw | odin::Literal::Text => Literal::Text,
            },
            View::Python(held) => held.as_constant().map_or(Literal::Other, |constant| {
                match constant.literal_class() {
                    python::Literal::Boolean => Literal::Boolean,
                    python::Literal::Bytes => Literal::Bytes,
                    python::Literal::Ellipsis => Literal::Other,
                    python::Literal::None => Literal::Nil,
                    python::Literal::Number => Literal::Number,
                    python::Literal::Text => Literal::Text,
                }
            }),
            View::Rust(held) => {
                held.as_constant().map_or(Literal::Other, |constant| {
                    match constant.literal_class() {
                        rust::Literal::Boolean => Literal::Boolean,
                        rust::Literal::Byte | rust::Literal::Character => Literal::Character,
                        rust::Literal::ByteString | rust::Literal::CString => Literal::Bytes,
                        rust::Literal::Float | rust::Literal::Integer => Literal::Number,
                        rust::Literal::Text => Literal::Text,
                    }
                })
            }
            View::TypeScript(held) => held.as_constant().map_or(Literal::Other, |constant| {
                typescript_literal(constant.literal_class())
            }),
            View::Zig(held) => match zig::literal_class(held.text(source)) {
                zig::Literal::Character => Literal::Character,
                zig::Literal::Multiline | zig::Literal::Text => Literal::Text,
                zig::Literal::Number => Literal::Number,
            },
        }
    }
}

impl<'run> Container<'run> {
    pub const fn view(self) -> View<'run> {
        self.0
    }

    pub fn name_token(self) -> Option<u32> {
        match self.0 {
            View::Go(held) => held.children_of(GoKind::Ident).next()?.positions().next(),
            View::JavaScript(held) => held.as_class()?.name_token(),
            View::Odin(held) => held.as_container()?.name_token(),
            View::Python(held) => held.as_class()?.name_token(),
            View::Rust(held) => held.as_definition()?.name_token(),
            View::TypeScript(held) => typescript_container_name(held),
            View::Zig(held) => {
                let parent = held.parent()?;

                parent.as_declaration()?.name_token()
            }
        }
    }

    pub fn body(self) -> View<'run> {
        match self.0 {
            View::Go(held) => held
                .children()
                .find(|child| matches!(child.kind(), GoKind::InterfaceType | GoKind::StructType))
                .and_then(|child| child.child_first_of(GoKind::FieldList))
                .map_or(self.0, View::Go),
            View::JavaScript(held) => held
                .as_class()
                .and_then(javascript::ClassDeclaration::body)
                .map_or(self.0, View::JavaScript),
            View::Odin(_) | View::Zig(_) => self.0,
            View::Rust(held) => held
                .children()
                .find(|child| {
                    matches!(
                        child.kind(),
                        RustKind::FieldsNamed | RustKind::FieldsUnnamed
                    )
                })
                .map_or(self.0, View::Rust),
            View::Python(held) => held
                .as_class()
                .and_then(python::ClassDef::body)
                .map_or(self.0, View::Python),
            View::TypeScript(held) => typescript_body(held).map_or(self.0, View::TypeScript),
        }
    }

    pub fn fields(self) -> Children<'run> {
        let inner = match self.0 {
            View::Go(held) => {
                let body = held
                    .children()
                    .find(|child| {
                        matches!(child.kind(), GoKind::InterfaceType | GoKind::StructType)
                    })
                    .and_then(|child| child.child_first_of(GoKind::FieldList));

                ChildrenInner::Go(body.map_or_else(|| empty_go(held), go::View::children))
            }
            View::JavaScript(held) => ChildrenInner::JavaScript(
                held.as_class()
                    .and_then(javascript::ClassDeclaration::body)
                    .map_or_else(|| empty_javascript(held), javascript::View::children),
            ),
            View::Odin(held) => ChildrenInner::Odin(held.children_of(OdinKind::Field)),
            View::Python(held) => ChildrenInner::Python(empty_python(held)),
            View::Rust(held) => ChildrenInner::Rust(rust_fields(held)),
            View::TypeScript(held) => ChildrenInner::TypeScript(
                typescript_body(held)
                    .map_or_else(|| empty_typescript(held), typescript::View::children),
            ),
            View::Zig(held) => ChildrenInner::Zig(held.children_of(ZigKind::ContainerField)),
        };

        Children {
            category: Some(Category::Declaration),
            inner,
            steps: 0,
        }
    }

    pub fn members(self) -> Children<'run> {
        let inner = match self.0 {
            View::Go(held) => ChildrenInner::Go(empty_go(held)),
            View::JavaScript(held) => ChildrenInner::JavaScript(
                held.as_class()
                    .and_then(javascript::ClassDeclaration::body)
                    .map_or_else(|| empty_javascript(held), javascript::View::children),
            ),
            View::Odin(held) => ChildrenInner::Odin(empty_odin(held)),
            View::Python(held) => ChildrenInner::Python(
                held.as_class()
                    .and_then(python::ClassDef::body)
                    .map_or_else(|| empty_python(held), python::View::children),
            ),
            View::Rust(held) => ChildrenInner::Rust(held.children()),
            View::TypeScript(held) => ChildrenInner::TypeScript(
                typescript_body(held)
                    .map_or_else(|| empty_typescript(held), typescript::View::children),
            ),
            View::Zig(held) => ChildrenInner::Zig(held.children_of(ZigKind::FnDecl)),
        };

        Children {
            category: Some(Category::Function),
            inner,
            steps: 0,
        }
    }
}

impl<'run> Declaration<'run> {
    pub const fn view(self) -> View<'run> {
        self.0
    }

    pub fn names(self) -> Names<'run> {
        match self.0 {
            View::Go(held) => Names::Children(View::Go(held).children_of(Category::Name)),
            View::JavaScript(held) => Names::Children(
                held.as_declarator()
                    .and_then(javascript::Declarator::target)
                    .map_or_else(|| javascript_declared(held), javascript_names),
            ),
            View::Odin(held) => Names::Children(View::Odin(held).children_of(Category::Name)),
            View::Python(held) => Names::Children(python_names(held)),
            View::Rust(held) => rust_names(rust_declared(held)),
            View::TypeScript(held) => Names::Children(
                held.as_declarator()
                    .and_then(typescript::Declarator::target)
                    .map_or_else(|| typescript_declared(held), typescript_names),
            ),
            View::Zig(held) => Names::Positions(held.positions_of(ZigKind::Identifier).into()),
        }
    }

    pub fn name_token(self) -> Option<u32> {
        match self.0 {
            View::Go(held) => held.children_of(GoKind::Ident).next()?.positions().next(),
            View::JavaScript(held) => {
                let target = held.as_declarator()?.target()?;

                (target.kind() == JavaScriptKind::IdentifierNode)
                    .then(|| target.positions().next())
                    .flatten()
            }
            View::Odin(held) => odin_declared_name(held),
            View::Python(held) => {
                let target = held.as_assign()?.targets().next()?;

                (target.kind() == PythonKind::Name)
                    .then(|| target.positions().next())
                    .flatten()
            }
            View::Rust(held) => {
                let declared = rust_declared(held);

                matches!(declared.kind(), RustKind::Ident | RustKind::PatIdent)
                    .then(|| rust_names(declared).next())
                    .flatten()
            }
            View::TypeScript(held) => {
                let target = held.as_declarator()?.target()?;

                (target.kind() == TypeScriptKind::IdentifierNode)
                    .then(|| target.positions().next())
                    .flatten()
            }
            View::Zig(held) => held.as_declaration()?.name_token(),
        }
    }

    pub fn type_of(self) -> Option<View<'run>> {
        match self.0 {
            View::Go(held) => held
                .children()
                .find(|child| {
                    child.kind() != GoKind::Ident && child.kind().category() == Category::Type
                })
                .map(View::Go),
            View::JavaScript(_) => None,
            View::Odin(held) => held.as_declaration()?.type_of().map(View::Odin),
            View::Python(held) => held.as_assign()?.annotation().map(View::Python),
            View::Rust(held) => rust_declared_type(held).map(View::Rust),
            View::TypeScript(held) => held
                .children()
                .find(|child| child.kind() == TypeScriptKind::TypeAnnotation)
                .map(View::TypeScript),
            View::Zig(held) => held.as_declaration()?.type_of().map(View::Zig),
        }
    }

    pub fn value(self) -> Option<View<'run>> {
        match self.0 {
            View::Go(held) => go_declared_value(held).map(View::Go),
            View::JavaScript(held) => javascript_declarator(held)?.value().map(View::JavaScript),
            View::Odin(held) => odin_declared_value(held).map(View::Odin),
            View::Python(held) => held.as_assign()?.value().map(View::Python),
            View::Rust(held) => held
                .as_local()
                .and_then(rust::Local::value)
                .or_else(|| rust_item_value(held))
                .map(View::Rust),
            View::TypeScript(held) => typescript_declarator(held)?.value().map(View::TypeScript),
            View::Zig(held) => held.as_declaration()?.value().map(View::Zig),
        }
    }

    pub fn is_constant(self) -> bool {
        match self.0 {
            View::Go(held) => held
                .parent()
                .and_then(|parent| parent.as_declaration())
                .is_some_and(|parent| parent.keyword() == Some(GoKind::ConstKeyword)),
            View::JavaScript(held) => {
                held.positions_of(JavaScriptKind::ConstKeyword)
                    .next()
                    .is_some()
                    || held.parent().is_some_and(|parent| {
                        parent
                            .positions_of(JavaScriptKind::ConstKeyword)
                            .next()
                            .is_some()
                    })
            }
            View::Odin(held) => held
                .as_declaration()
                .is_some_and(odin::Declaration::is_constant),
            View::Python(_) => false,
            View::Rust(held) => held.kind() == RustKind::ItemConst,
            View::TypeScript(held) => {
                held.positions_of(TypeScriptKind::ConstKeyword)
                    .next()
                    .is_some()
                    || held.parent().is_some_and(|parent| {
                        parent
                            .positions_of(TypeScriptKind::ConstKeyword)
                            .next()
                            .is_some()
                    })
            }
            View::Zig(held) => held
                .as_declaration()
                .is_some_and(|declaration| !declaration.is_mutable()),
        }
    }

    pub fn is_mutable(self) -> bool {
        match self.0 {
            View::Rust(held) => {
                let mutable_static = held.kind() == RustKind::ItemStatic
                    && held.positions_of(RustKind::MutKeyword).next().is_some();

                let mutable_local = held.as_local().is_some()
                    && rust_declared(held)
                        .positions_of(RustKind::MutKeyword)
                        .next()
                        .is_some();

                mutable_static || mutable_local
            }
            View::Go(_)
            | View::JavaScript(_)
            | View::Odin(_)
            | View::Python(_)
            | View::TypeScript(_)
            | View::Zig(_) => !self.is_constant(),
        }
    }

    pub fn is_public(self) -> bool {
        match self.0 {
            View::Rust(held) => rust_is_public(held),
            View::Zig(held) => held
                .as_declaration()
                .is_some_and(zig::Declaration::is_public),
            View::Go(_)
            | View::JavaScript(_)
            | View::Odin(_)
            | View::Python(_)
            | View::TypeScript(_) => false,
        }
    }
}

impl<'run> Field<'run> {
    pub const fn view(self) -> View<'run> {
        self.0
    }

    pub fn name_token(self) -> Option<u32> {
        match self.0 {
            View::Go(held) => held.as_field()?.names().next()?.positions().next(),
            View::JavaScript(held) => held.child_first()?.positions().next(),
            View::Odin(held) => held.as_field()?.names().next()?.name_position(),
            View::Python(_) => None,
            View::Rust(held) => held.as_field()?.name_token(),
            View::TypeScript(held) => held.child_first()?.positions().next(),
            View::Zig(held) => held.as_field()?.name_token(),
        }
    }

    pub fn type_of(self) -> Option<View<'run>> {
        match self.0 {
            View::Go(held) => held.as_field()?.type_of().map(View::Go),
            View::JavaScript(_) | View::Python(_) => None,
            View::Odin(held) => held.as_field()?.type_of().map(View::Odin),
            View::Rust(held) => held.as_field()?.type_of().map(View::Rust),
            View::TypeScript(held) => held
                .children()
                .find(|child| child.kind() == TypeScriptKind::TypeAnnotation)
                .map(View::TypeScript),
            View::Zig(held) => held.as_field()?.type_of().map(View::Zig),
        }
    }

    pub fn value(self) -> Option<View<'run>> {
        match self.0 {
            View::JavaScript(held) => held
                .children()
                .last()
                .filter(|_| held.children().count() > 1)
                .map(View::JavaScript),
            View::TypeScript(held) => held
                .children()
                .last()
                .filter(|child| {
                    child.kind() != TypeScriptKind::TypeAnnotation && held.children().count() > 1
                })
                .map(View::TypeScript),
            View::Zig(held) => held.as_field()?.value().map(View::Zig),
            View::Go(_) | View::Odin(_) | View::Python(_) | View::Rust(_) => None,
        }
    }
}

impl<'run> Function<'run> {
    pub const fn view(self) -> View<'run> {
        self.0
    }

    pub fn name_token(self) -> Option<u32> {
        let typed = match self.0 {
            View::Go(held) => held.as_function().and_then(go::Function::name_token),
            View::JavaScript(held) => held
                .as_function()
                .and_then(javascript::Function::name_token),
            View::Odin(held) => odin_function_name(held),
            View::Python(held) => held.as_function().and_then(python::FunctionDef::name_token),
            View::Rust(held) => held.as_function().and_then(rust::Function::name_token),
            View::TypeScript(held) => held
                .as_function()
                .and_then(typescript::Function::name_token),
            View::Zig(held) => held.as_function().and_then(zig::Function::name_token),
        };

        typed.or_else(|| {
            let name = self.0.child_first_of(Category::Name)?;

            name.positions().next()
        })
    }

    pub fn parameters(self) -> Parameters<'run> {
        let inner = match self.0 {
            View::Go(held) => go_parameters(held),
            View::JavaScript(held) => held
                .child_first_of(JavaScriptKind::FormalParameters)
                .map_or(ParametersInner::Empty, |node| {
                    ParametersInner::JavaScript(node.children())
                }),
            View::Odin(held) => held
                .as_function()
                .and_then(odin::Function::parameters)
                .map_or(ParametersInner::Empty, |node| ParametersInner::Odin {
                    names: None,
                    parameters: node.children(),
                }),
            View::Python(held) => held
                .child_first_of(PythonKind::Arguments)
                .map_or(ParametersInner::Empty, |node| {
                    ParametersInner::Python(node.children_of(PythonKind::Arg))
                }),
            View::Rust(held) => held
                .as_function()
                .and_then(rust::Function::signature)
                .map_or(ParametersInner::Empty, |node| {
                    ParametersInner::Rust(node.children())
                }),
            View::TypeScript(held) => held
                .child_first_of(TypeScriptKind::FormalParameters)
                .map_or(ParametersInner::Empty, |node| {
                    ParametersInner::TypeScript(node.children())
                }),
            View::Zig(held) => zig_parameters(held),
        };

        Parameters { inner, steps: 0 }
    }

    pub fn parameters_span(self) -> Option<Span> {
        let holder = match self.0 {
            View::Python(held) => (held.kind() == PythonKind::Lambda)
                .then_some(self.0)
                .or_else(|| self.0.child_first_of(Category::Parameters)),
            View::Go(_) => self
                .0
                .child_first_of(Category::Parameters)
                .and_then(|signature| {
                    let skipped = usize::from(self.receiver().is_some());

                    signature
                        .children_of(Category::Parameters)
                        .filter(|held| is_parenthesised(*held))
                        .nth(skipped)
                }),
            View::Odin(held) => held
                .as_function()
                .and_then(odin::Function::parameters)
                .map(View::Odin),
            View::JavaScript(_) | View::Rust(_) | View::TypeScript(_) | View::Zig(_) => self
                .0
                .children_of(Category::Parameters)
                .find(|held| is_parenthesised(*held))
                .or_else(|| self.0.child_first_of(Category::Parameters)),
        }?;

        let mut open = None;
        let mut close = None;

        for position in holder.positions() {
            let kind = holder.token_at(position).kind;

            if kind == TokenKind::Punctuation(Punctuation::ParenOpen) && open.is_none() {
                open = Some(position);
            }

            if kind == TokenKind::Punctuation(Punctuation::ParenClose) {
                close = Some(position);
            }
        }

        let first = holder.token_at(open?);
        let last = holder.token_at(close?);

        assert!(last.end() >= first.offset);

        Some(Span {
            length: last.end() - first.offset,
            offset: first.offset,
        })
    }

    pub fn parameter_nodes(self) -> Children<'run> {
        self.0
            .children_of(Category::Parameters)
            .find(|held| is_parenthesised(*held))
            .or_else(|| self.0.child_first_of(Category::Parameters))
            .map_or_else(
                || self.0.children_of(Category::Parameter),
                |held| held.children_of(Category::Parameter),
            )
    }

    pub fn body(self) -> Option<View<'run>> {
        let typed = match self.0 {
            View::Go(held) => held
                .as_function()
                .and_then(go::Function::body)
                .map(View::Go),
            View::JavaScript(held) => held
                .as_function()
                .and_then(javascript::Function::body)
                .map(View::JavaScript),
            View::Odin(held) => held
                .as_function()
                .and_then(odin::Function::body)
                .map(View::Odin),
            View::Python(held) => held
                .as_function()
                .and_then(python::FunctionDef::body)
                .or_else(|| {
                    (held.kind() == PythonKind::Lambda)
                        .then(|| held.children().last())
                        .flatten()
                })
                .map(View::Python),
            View::Rust(held) => held
                .as_function()
                .and_then(rust::Function::body)
                .map(View::Rust),
            View::TypeScript(held) => held
                .as_function()
                .and_then(typescript::Function::body)
                .map(View::TypeScript),
            View::Zig(held) => held
                .as_function()
                .and_then(zig::Function::body)
                .map(View::Zig),
        };

        typed.or_else(|| self.0.children_of(Category::Block).last())
    }

    pub fn returns(self) -> Option<View<'run>> {
        match self.0 {
            View::Go(held) => {
                let signature = held.as_function()?.signature()?;
                let lists = signature.children_of(GoKind::FieldList).count();
                let expected = 1 + usize::from(held.as_function()?.receiver().is_some());

                (lists > expected)
                    .then(|| signature.children_of(GoKind::FieldList).last())
                    .flatten()
                    .map(View::Go)
            }
            View::JavaScript(_) => None,
            View::Odin(held) => held.as_function()?.returns().map(View::Odin),
            View::Python(held) => held.as_function()?.returns_annotation().map(View::Python),
            View::Rust(held) => {
                let signature = held.as_function()?.signature()?;
                let arrow = signature.positions_of(RustKind::RArrow).next()?;

                signature
                    .children()
                    .find(|child| child.token_start() > arrow)
                    .map(View::Rust)
            }
            View::TypeScript(held) => held
                .children()
                .find(|child| child.kind() == TypeScriptKind::TypeAnnotation)
                .map(View::TypeScript),
            View::Zig(held) => held.as_function()?.returns().map(View::Zig),
        }
    }

    pub fn receiver(self) -> Option<View<'run>> {
        match self.0 {
            View::Go(held) => held.as_function()?.receiver().map(View::Go),
            View::Rust(held) => held
                .as_function()?
                .signature()?
                .child_first_of(RustKind::Receiver)
                .map(View::Rust),
            View::JavaScript(_)
            | View::Odin(_)
            | View::Python(_)
            | View::TypeScript(_)
            | View::Zig(_) => None,
        }
    }

    pub fn returns_span(self) -> Option<Span> {
        let node = self.returns()?;
        let mut span = node.span();

        let View::Zig(held) = self.0 else {
            return Some(span);
        };

        let prototype = held.as_function().and_then(zig::Function::prototype)?;
        let close = prototype.token_first(ZigKind::ParenClose)?;

        for position in prototype.positions() {
            if position <= close || position >= node.token_start() {
                continue;
            }

            let marker = matches!(
                prototype.token_kind(position),
                ZigKind::Bang | ZigKind::Question
            );

            if !marker {
                continue;
            }

            let token = prototype.token_at(position);

            if token.offset < span.offset {
                span = Span {
                    length: span.end() - token.offset,
                    offset: token.offset,
                };
            }
        }

        Some(span)
    }

    pub fn is_async(self) -> bool {
        match self.0 {
            View::JavaScript(held) => held
                .as_function()
                .is_some_and(javascript::Function::is_async),
            View::Python(held) => held
                .as_function()
                .is_some_and(python::FunctionDef::is_async),
            View::Rust(held) => held.as_function().is_some_and(rust::Function::is_async),
            View::TypeScript(held) => held
                .as_function()
                .is_some_and(typescript::Function::is_async),
            View::Go(_) | View::Odin(_) | View::Zig(_) => false,
        }
    }

    pub fn is_public(self) -> bool {
        match self.0 {
            View::Rust(held) => rust_is_public(held),
            View::Zig(held) => held.as_function().is_some_and(zig::Function::is_public),
            View::Go(_)
            | View::JavaScript(_)
            | View::Odin(_)
            | View::Python(_)
            | View::TypeScript(_) => false,
        }
    }

    pub fn is_anonymous(self) -> bool {
        self.0.category() == Category::Lambda || self.name_token().is_none()
    }
}

impl<'run> Import<'run> {
    pub const fn view(self) -> View<'run> {
        self.0
    }

    pub fn segments(self, out: &mut BoundedVec<Span>) -> bool {
        out.clear();

        match self.0 {
            View::Go(held) => {
                let Some(path) = held.as_specification().and_then(|node| node.path()) else {
                    return true;
                };

                out.push(path.span())
            }
            View::JavaScript(held) => held
                .as_import()
                .and_then(javascript::ImportStatement::source)
                .is_none_or(|node| out.push(node.span())),
            View::Odin(held) => held
                .children_of(OdinKind::String)
                .next()
                .is_none_or(|node| out.push(node.span())),
            View::Python(held) => python_import_segments(held, out),
            View::Rust(held) => rust_use_segments(held, out),
            View::TypeScript(held) => held
                .as_import()
                .and_then(typescript::ImportStatement::source)
                .is_none_or(|node| out.push(node.span())),
            View::Zig(_) => true,
        }
    }

    pub fn is_wildcard(self) -> bool {
        match self.0 {
            View::Go(held) => held.positions_of(GoKind::Dot).next().is_some(),
            View::Python(held) => held.positions_of(PythonKind::Star).next().is_some(),
            View::Rust(held) => {
                held.positions_of(RustKind::Star).next().is_some() || rust_use_glob(held)
            }
            View::JavaScript(held) => held.positions_of(JavaScriptKind::Star).next().is_some(),
            View::TypeScript(held) => held.positions_of(TypeScriptKind::Star).next().is_some(),
            View::Odin(_) | View::Zig(_) => false,
        }
    }
}

impl<'run> Operation<'run> {
    pub const fn view(self) -> View<'run> {
        self.0
    }

    pub fn operands(self) -> Children<'run> {
        self.0.children()
    }

    pub fn operator_tokens(self) -> Positions<'run> {
        self.0.positions()
    }
}

impl<'run> Statement<'run> {
    pub const fn view(self) -> View<'run> {
        self.0
    }

    pub fn header(self) -> Option<View<'run>> {
        match self.0 {
            View::Go(held) => held.as_statement()?.header().map(View::Go),
            View::JavaScript(held) => held.as_statement()?.header().map(View::JavaScript),
            View::Odin(held) => held.as_statement()?.header().map(View::Odin),
            View::Python(held) => held.as_statement()?.header().map(View::Python),
            View::Rust(held) => held.as_statement()?.header().map(View::Rust),
            View::TypeScript(held) => held.as_statement()?.header().map(View::TypeScript),
            View::Zig(held) => held.as_statement()?.header().map(View::Zig),
        }
    }

    pub fn body(self) -> Option<View<'run>> {
        match self.0 {
            View::Go(held) => held.as_statement()?.body().map(View::Go),
            View::JavaScript(held) => held.as_statement()?.body().map(View::JavaScript),
            View::Odin(held) => held.as_statement()?.body().map(View::Odin),
            View::Python(held) => held.as_statement()?.body().map(View::Python),
            View::Rust(held) => held.as_statement()?.body().map(View::Rust),
            View::TypeScript(held) => held.as_statement()?.body().map(View::TypeScript),
            View::Zig(held) => held.as_statement()?.body().map(View::Zig),
        }
    }

    pub fn clauses(self) -> Clauses<'run> {
        let header = self.header().map(View::index);
        let body = self.body().map(View::index);
        let cases = self.0.category() == Category::Match;

        let holder = match self.0 {
            View::JavaScript(held) => held
                .child_first_of(JavaScriptKind::SwitchBody)
                .map_or(self.0, View::JavaScript),
            View::TypeScript(held) => held
                .child_first_of(TypeScriptKind::SwitchBody)
                .map_or(self.0, View::TypeScript),
            View::Go(_) | View::Odin(_) | View::Python(_) | View::Rust(_) | View::Zig(_) => {
                if cases {
                    self.body().unwrap_or(self.0)
                } else {
                    self.0
                }
            }
        };

        let inside_body = holder.index() != self.0.index();

        Clauses {
            body: if inside_body { None } else { body },
            children: holder.children(),
            header: if inside_body { None } else { header },
        }
    }
}

pub struct Clauses<'run> {
    body: Option<u32>,
    children: Children<'run>,
    header: Option<u32>,
}

impl<'run> Iterator for Clauses<'run> {
    type Item = View<'run>;

    fn next(&mut self) -> Option<View<'run>> {
        for _ in 0..CHILD_COUNT_MAX {
            let held = self.children.next()?;
            let index = held.index();

            if Some(index) == self.body || Some(index) == self.header {
                continue;
            }

            if matches!(
                held.category(),
                Category::Block | Category::Branch | Category::Except
            ) {
                return Some(held);
            }
        }

        None
    }
}

impl<'run> Iterator for Parameters<'run> {
    type Item = Parameter<'run>;

    fn next(&mut self) -> Option<Parameter<'run>> {
        self.steps += 1;

        assert!(self.steps <= PARAMETER_COUNT_MAX + 1);

        match &mut self.inner {
            ParametersInner::Empty => None,
            ParametersInner::Go { fields, names } => go_parameter_next(fields, names),
            ParametersInner::JavaScript(children) => {
                children.next().map(|held| javascript_parameter(held))
            }
            ParametersInner::Odin { names, parameters } => odin_parameter_next(parameters, names),
            ParametersInner::Python(children) => children.next().map(python_parameter),
            ParametersInner::Rust(children) => {
                for _ in 0..PARAMETER_COUNT_MAX {
                    let held = children.next()?;

                    if matches!(held.kind(), RustKind::PatType | RustKind::Receiver) {
                        return Some(rust_parameter(held));
                    }
                }

                None
            }
            ParametersInner::TypeScript(children) => {
                children.next().map(|held| typescript_parameter(held))
            }
            ParametersInner::Zig {
                close,
                cursor,
                prototype,
            } => zig_parameter_next(*prototype, cursor, *close),
        }
    }
}

fn is_parenthesised(held: View<'_>) -> bool {
    held.positions().any(|position| {
        held.token_at(position).kind == TokenKind::Punctuation(Punctuation::ParenOpen)
    })
}

fn name_position_of(held: View<'_>) -> Option<u32> {
    if held.category() == Category::Name {
        if let Some(position) = held.positions().next() {
            return Some(position);
        }
    }

    let name = held.child_first_of(Category::Name)?;

    name.positions().next()
}

fn skip_first<I>(mut children: I, count: u32) -> I
where
    I: Iterator,
{
    for _ in 0..count {
        if children.next().is_none() {
            break;
        }
    }

    children
}

fn empty_go(held: go::View<'_>) -> go::Children<'_> {
    held.children_of(GoKind::ErrorNode)
}

fn empty_javascript(held: javascript::View<'_>) -> javascript::Children<'_> {
    held.children_of(JavaScriptKind::ErrorNode)
}

fn empty_odin(held: odin::View<'_>) -> odin::Children<'_> {
    held.children_of(OdinKind::ErrorNode)
}

fn empty_python(held: python::View<'_>) -> python::Children<'_> {
    held.children_of(PythonKind::ErrorNode)
}

fn empty_typescript(held: typescript::View<'_>) -> typescript::Children<'_> {
    held.children_of(TypeScriptKind::ErrorNode)
}

fn go_declared_value(held: go::View<'_>) -> Option<go::View<'_>> {
    if let Some(specification) = held.as_specification() {
        return specification.values().next();
    }

    let assigned = held.positions_of(GoKind::ColonEqual).next()?;

    held.children().find(|child| child.token_start() > assigned)
}

fn odin_declared_name(held: odin::View<'_>) -> Option<u32> {
    if let Some(declaration) = held.as_declaration() {
        return declaration.names().next()?.name_position();
    }

    let assigned = held.positions_of(OdinKind::ColonEqual).next()?;

    held.children()
        .find(|child| child.token_start() < assigned)?
        .name_position()
}

fn odin_declared_value(held: odin::View<'_>) -> Option<odin::View<'_>> {
    if let Some(declaration) = held.as_declaration() {
        return declaration.value();
    }

    let assigned = held.positions_of(OdinKind::ColonEqual).next()?;

    held.children().find(|child| child.token_start() > assigned)
}

fn go_parameters(held: go::View<'_>) -> ParametersInner<'_> {
    let Some(function) = held.as_function() else {
        return ParametersInner::Empty;
    };

    let Some(signature) = function.signature() else {
        return ParametersInner::Empty;
    };

    let skipped = usize::from(function.receiver().is_some());

    let Some(list) = signature
        .children_of(GoKind::FieldList)
        .filter(|list| list.positions_of(GoKind::ParenOpen).next().is_some())
        .nth(skipped)
    else {
        return ParametersInner::Empty;
    };

    ParametersInner::Go {
        fields: list.children_of(GoKind::Field),
        names: None,
    }
}

fn go_parameter_next<'run>(
    fields: &mut go::Children<'run>,
    names: &mut Option<(go::View<'run>, go::Children<'run>, u32)>,
) -> Option<Parameter<'run>> {
    for _ in 0..PARAMETER_COUNT_MAX {
        if let Some((owner, held, remaining)) = names {
            let field = *owner;

            if *remaining > 0 {
                *remaining -= 1;

                let name = held.next()?;

                let type_of = field.as_field().and_then(go::Field::type_of).map(View::Go);

                return Some(Parameter {
                    group: (View::Go(field)).index(),
                    default: None,
                    name: name.positions().next(),
                    node: View::Go(field),
                    span: (View::Go(field)).span(),
                    type_of,
                    type_span: type_of.map(View::span),
                });
            }

            *names = None;
        }

        let field = fields.next()?;

        let Some(wrapped) = field.as_field() else {
            continue;
        };

        let count = u32::try_from(wrapped.names().count()).unwrap_or(PARAMETER_COUNT_MAX);

        if count == 0 {
            let type_of = wrapped.type_of().map(View::Go);

            return Some(Parameter {
                group: (View::Go(field)).index(),
                default: None,
                name: None,
                node: View::Go(field),
                span: (View::Go(field)).span(),
                type_of,
                type_span: type_of.map(View::span),
            });
        }

        *names = Some((field, field.children(), count));
    }

    None
}

fn javascript_parameter(held: javascript::View<'_>) -> Parameter<'_> {
    let kind = held.kind();

    let nested = matches!(
        kind,
        JavaScriptKind::AssignmentPattern | JavaScriptKind::RestPattern
    );

    let name = if nested {
        held.child_first()
            .filter(|child| child.kind() == JavaScriptKind::IdentifierNode)
            .and_then(|child| child.positions().next())
    } else if kind == JavaScriptKind::IdentifierNode {
        held.positions().next()
    } else {
        None
    };

    let default = if kind == JavaScriptKind::AssignmentPattern {
        held.child_at(1)
    } else {
        None
    };

    Parameter {
        group: (View::JavaScript(held)).index(),
        default: default.map(View::JavaScript),
        name,
        node: View::JavaScript(held),
        span: (View::JavaScript(held)).span(),
        type_of: None,
        type_span: None,
    }
}

fn typescript_parameter(held: typescript::View<'_>) -> Parameter<'_> {
    let pattern = held
        .children()
        .find(|child| {
            !matches!(
                child.kind(),
                TypeScriptKind::AccessibilityModifier
                    | TypeScriptKind::Decorator
                    | TypeScriptKind::TypeAnnotation
            )
        })
        .unwrap_or(held);

    let nested = matches!(
        pattern.kind(),
        TypeScriptKind::AssignmentPattern | TypeScriptKind::RestPattern
    );

    let name = if nested {
        pattern
            .child_first()
            .filter(|child| child.kind() == TypeScriptKind::IdentifierNode)
            .and_then(|child| child.positions().next())
    } else if pattern.kind() == TypeScriptKind::IdentifierNode {
        pattern.positions().next()
    } else {
        None
    };

    let default = if pattern.kind() == TypeScriptKind::AssignmentPattern {
        pattern.child_at(1)
    } else {
        held.children().last().filter(|child| {
            held.positions_of(TypeScriptKind::Equal).next().is_some()
                && child.index() != pattern.index()
        })
    };

    let type_of = held
        .children()
        .find(|child| child.kind() == TypeScriptKind::TypeAnnotation)
        .and_then(typescript::View::child_first)
        .map(View::TypeScript);

    Parameter {
        group: (View::TypeScript(held)).index(),
        default: default.map(View::TypeScript),
        name,
        node: View::TypeScript(held),
        span: (View::TypeScript(held)).span(),
        type_of,
        type_span: type_of.map(View::span),
    }
}

fn odin_parameter_next<'run>(
    parameters: &mut odin::Children<'run>,
    names: &mut Option<(odin::View<'run>, odin::Children<'run>)>,
) -> Option<Parameter<'run>> {
    for _ in 0..PARAMETER_COUNT_MAX {
        if let Some((owner, held)) = names {
            let parameter = *owner;

            if let Some(name) = held.next() {
                let type_of = parameter.child_first_of(OdinKind::Type).map(View::Odin);

                return Some(Parameter {
                    group: (View::Odin(parameter)).index(),
                    default: odin_default(parameter),
                    name: name.name_position(),
                    node: View::Odin(parameter),
                    span: (View::Odin(parameter)).span(),
                    type_of,
                    type_span: type_of.map(View::span),
                });
            }

            *names = None;
        }

        let parameter = parameters.next()?;

        if !matches!(
            parameter.kind(),
            OdinKind::DefaultParameter | OdinKind::Parameter
        ) {
            continue;
        }

        if parameter
            .children_of(OdinKind::IdentifierNode)
            .next()
            .is_none()
        {
            let type_of = parameter.child_first_of(OdinKind::Type).map(View::Odin);

            return Some(Parameter {
                group: (View::Odin(parameter)).index(),
                default: None,
                name: None,
                node: View::Odin(parameter),
                span: (View::Odin(parameter)).span(),
                type_of,
                type_span: type_of.map(View::span),
            });
        }

        *names = Some((parameter, parameter.children_of(OdinKind::IdentifierNode)));
    }

    None
}

fn odin_default(parameter: odin::View<'_>) -> Option<View<'_>> {
    let equal = parameter
        .token_first(OdinKind::ColonEqual)
        .or_else(|| parameter.token_first(OdinKind::Equal))?;

    parameter
        .children()
        .find(|child| child.token_start() > equal)
        .map(View::Odin)
}

fn python_parameter(held: python::View<'_>) -> Parameter<'_> {
    let argument = held.as_argument();

    let type_of = argument.and_then(python::Arg::annotation).map(View::Python);

    Parameter {
        group: (View::Python(held)).index(),
        default: argument.and_then(python::Arg::default).map(View::Python),
        name: argument.and_then(python::Arg::name_token),
        node: View::Python(held),
        span: (View::Python(held)).span(),
        type_of,
        type_span: type_of.map(View::span),
    }
}

fn rust_parameter(held: rust::View<'_>) -> Parameter<'_> {
    if held.kind() == RustKind::Receiver {
        let name = (held.token_start()..held.token_end())
            .rev()
            .find(|position| {
                matches!(
                    held.token_kind(*position),
                    RustKind::Ident | RustKind::SelfLower
                )
            });

        return Parameter {
            group: (View::Rust(held)).index(),
            default: None,
            name,
            node: View::Rust(held),
            span: (View::Rust(held)).span(),
            type_of: None,
            type_span: None,
        };
    }

    let pattern = held
        .children()
        .find(|child| child.kind() != RustKind::Attribute);

    let name = pattern.and_then(|candidate| {
        if candidate.kind() != RustKind::PatIdent {
            return None;
        }

        let ident = candidate.children_of(RustKind::Ident).next()?;

        ident.positions().next()
    });

    let type_of = held
        .children()
        .find(|child| child.kind().category() == Category::Type)
        .map(View::Rust);

    let whole = View::Rust(held).span();
    let offset = pattern.map_or(whole.offset, |candidate| candidate.span().offset);

    assert!(offset >= whole.offset);
    assert!(offset <= whole.end());

    Parameter {
        default: None,
        group: held.index(),
        name,
        node: View::Rust(held),
        span: Span {
            length: whole.end() - offset,
            offset,
        },
        type_of,
        type_span: type_of.map(View::span),
    }
}

fn zig_parameters(held: zig::View<'_>) -> ParametersInner<'_> {
    let Some(prototype) = held.as_function().and_then(zig::Function::prototype) else {
        return ParametersInner::Empty;
    };

    let Some(open) = prototype.token_first(ZigKind::ParenOpen) else {
        return ParametersInner::Empty;
    };

    let close = prototype.token_first(ZigKind::ParenClose).unwrap_or(NONE);

    ParametersInner::Zig {
        close,
        cursor: open + 1,
        prototype,
    }
}

fn zig_parameter_next<'run>(
    prototype: zig::View<'run>,
    cursor: &mut u32,
    close: u32,
) -> Option<Parameter<'run>> {
    if *cursor >= close {
        return None;
    }

    let start = *cursor;
    let end = zig_parameter_end(prototype, start, close);

    *cursor = end + 1;

    let name = zig_parameter_name(prototype, start, end);

    let type_of = prototype
        .children()
        .find(|child| child.token_start() >= start && child.token_start() < end)
        .map(View::Zig);

    if name.is_none() && type_of.is_none() && end == close {
        return None;
    }

    let anytype = (start..end).find(|position| {
        matches!(
            prototype.token_kind(*position),
            ZigKind::AnytypeKeyword | ZigKind::DotDotDot
        )
    });

    let type_span = type_of
        .map(View::span)
        .or_else(|| anytype.map(|position| prototype.token_at(position).span()));

    Some(Parameter {
        default: None,
        group: name.unwrap_or(start),
        name,
        node: type_of.unwrap_or(View::Zig(prototype)),
        span: zig_parameter_span(prototype, name, type_span),
        type_of,
        type_span,
    })
}

fn zig_parameter_end(prototype: zig::View<'_>, start: u32, close: u32) -> u32 {
    for position in prototype.positions() {
        if position <= start {
            continue;
        }

        if position >= close {
            break;
        }

        if prototype.token_kind(position) == ZigKind::Comma {
            return position;
        }
    }

    close
}

fn zig_parameter_name(prototype: zig::View<'_>, start: u32, end: u32) -> Option<u32> {
    let mut name = None;

    for position in prototype.positions() {
        if position < start || position >= end {
            continue;
        }

        let named = prototype.token_kind(position) == ZigKind::Identifier
            && prototype.token_kind(position + 1) == ZigKind::Colon;

        if named {
            name = Some(position);
        }
    }

    name
}

fn javascript_declared(held: javascript::View<'_>) -> Children<'_> {
    if matches!(
        held.kind(),
        JavaScriptKind::LexicalDeclaration | JavaScriptKind::VariableDeclaration
    ) {
        return View::JavaScript(held).children_of(Category::Declaration);
    }

    View::JavaScript(held).children_of(Category::Name)
}

fn typescript_declared(held: typescript::View<'_>) -> Children<'_> {
    if matches!(
        held.kind(),
        TypeScriptKind::LexicalDeclaration | TypeScriptKind::VariableDeclaration
    ) {
        return View::TypeScript(held).children_of(Category::Declaration);
    }

    View::TypeScript(held).children_of(Category::Name)
}

fn javascript_declarator(held: javascript::View<'_>) -> Option<javascript::Declarator<'_>> {
    if let Some(declarator) = held.as_declarator() {
        return Some(declarator);
    }

    held.children_of(JavaScriptKind::VariableDeclarator)
        .next()
        .and_then(javascript::View::as_declarator)
}

fn typescript_declarator(held: typescript::View<'_>) -> Option<typescript::Declarator<'_>> {
    if let Some(declarator) = held.as_declarator() {
        return Some(declarator);
    }

    held.children_of(TypeScriptKind::VariableDeclarator)
        .next()
        .and_then(typescript::View::as_declarator)
}

fn javascript_names(target: javascript::View<'_>) -> Children<'_> {
    if target.kind() == JavaScriptKind::IdentifierNode {
        return View::JavaScript(target.parent().unwrap_or(target)).children_of(Category::Name);
    }

    View::JavaScript(target).children_of(Category::Name)
}

fn typescript_names(target: typescript::View<'_>) -> Children<'_> {
    if target.kind() == TypeScriptKind::IdentifierNode {
        return View::TypeScript(target.parent().unwrap_or(target)).children_of(Category::Name);
    }

    View::TypeScript(target).children_of(Category::Name)
}

fn python_names(held: python::View<'_>) -> Children<'_> {
    let Some(target) = held.as_assign().and_then(|assign| assign.targets().next()) else {
        return View::Python(held).children_of(Category::Name);
    };

    if target.kind() == PythonKind::Name {
        return View::Python(held).children_of(Category::Name);
    }

    if matches!(target.kind(), PythonKind::List | PythonKind::Tuple) {
        return View::Python(target).children_of(Category::Name);
    }

    View::Python(target).children_of(Category::Parameters)
}

fn zig_parameter_span(
    prototype: zig::View<'_>,
    name: Option<u32>,
    type_span: Option<Span>,
) -> Span {
    let start = name.map_or_else(
        || type_span.unwrap_or_else(|| View::Zig(prototype).span()),
        |position| prototype.token_at(position).span(),
    );

    let end = type_span
        .map_or_else(|| start.end(), Span::end)
        .max(start.end());

    assert!(end >= start.offset);

    Span {
        length: end - start.offset,
        offset: start.offset,
    }
}

fn javascript_call_name(held: javascript::View<'_>) -> Option<u32> {
    let callee = held.as_call()?.callee()?;

    if let Some(member) = callee.as_member() {
        return member.property()?.positions().next();
    }

    callee.positions().next()
}

fn typescript_call_name(held: typescript::View<'_>) -> Option<u32> {
    let callee = held.as_call()?.callee()?;

    if let Some(member) = callee.as_member() {
        return member.property()?.positions().next();
    }

    callee.positions().next()
}

fn python_call_name(held: python::View<'_>) -> Option<u32> {
    let callee = held.as_call()?.callee()?;

    if callee.kind() == PythonKind::Attribute {
        return callee.positions_of(PythonKind::Identifier).last();
    }

    callee.positions().next()
}

fn javascript_literal(held: javascript::Literal) -> Literal {
    match held {
        javascript::Literal::Boolean => Literal::Boolean,
        javascript::Literal::Null | javascript::Literal::Undefined => Literal::Nil,
        javascript::Literal::Number => Literal::Number,
        javascript::Literal::Regex => Literal::Regex,
        javascript::Literal::Template => Literal::Template,
        javascript::Literal::Text => Literal::Text,
    }
}

fn typescript_literal(held: typescript::Literal) -> Literal {
    match held {
        typescript::Literal::Boolean => Literal::Boolean,
        typescript::Literal::Null | typescript::Literal::Undefined => Literal::Nil,
        typescript::Literal::Number => Literal::Number,
        typescript::Literal::Regex => Literal::Regex,
        typescript::Literal::Template => Literal::Template,
        typescript::Literal::Text => Literal::Text,
    }
}

fn typescript_container_name(held: typescript::View<'_>) -> Option<u32> {
    if let Some(class) = held.as_class() {
        return class.name_token();
    }

    held.child_first_of(TypeScriptKind::IdentifierNode)?
        .positions()
        .next()
}

fn typescript_body(held: typescript::View<'_>) -> Option<typescript::View<'_>> {
    if let Some(class) = held.as_class() {
        return class.body();
    }

    held.children().last()
}

fn odin_call(held: odin::View<'_>) -> odin::View<'_> {
    if held.kind() == OdinKind::SelectorCallExpression {
        return held
            .children_of(OdinKind::CallExpression)
            .next()
            .unwrap_or(held);
    }

    held
}

fn odin_receiver(held: odin::View<'_>) -> Option<odin::View<'_>> {
    if held.kind() == OdinKind::SelectorCallExpression {
        return held.child_first();
    }

    let parent = held.parent()?;

    (parent.kind() == OdinKind::MemberExpression)
        .then(|| parent.child_first())
        .flatten()
}

fn odin_function_name(held: odin::View<'_>) -> Option<u32> {
    if held.kind() == OdinKind::Procedure {
        let parent = held.parent()?;

        return parent
            .children_of(OdinKind::IdentifierNode)
            .next()?
            .name_position();
    }

    held.as_function()?.name_token()
}

fn rust_arguments(held: rust::View<'_>) -> rust::Children<'_> {
    if held.kind() == RustKind::ExprMethodCall {
        return skip_first(held.children(), 2);
    }

    if held.kind() == RustKind::ExprCall {
        return skip_first(held.children(), 1);
    }

    rust_macro(held).map_or_else(|| skip_first(held.children(), 1), rust::View::children)
}

fn rust_macro(held: rust::View<'_>) -> Option<rust::View<'_>> {
    if held.kind() == RustKind::Macro {
        return Some(held);
    }

    held.children_of(RustKind::Macro).next()
}

fn rust_callee(held: rust::View<'_>) -> Option<rust::View<'_>> {
    if let Some(call) = held.as_call() {
        return call.callee();
    }

    rust_macro(held)?.children_of(RustKind::Path).next()
}

fn rust_call_name(held: rust::View<'_>) -> Option<u32> {
    if let Some(call) = held.as_call() {
        return call.name_token();
    }

    let path = rust_macro(held)?.children_of(RustKind::Path).next()?;
    let segment = path.children_of(RustKind::PathSegment).last()?;

    segment
        .children_of(RustKind::Ident)
        .next()?
        .positions()
        .next()
}

fn rust_fields(held: rust::View<'_>) -> rust::Children<'_> {
    held.children()
        .find(|child| {
            matches!(
                child.kind(),
                RustKind::FieldsNamed | RustKind::FieldsUnnamed
            )
        })
        .map_or_else(|| held.children_of(RustKind::Variant), rust::View::children)
}

fn rust_declared(held: rust::View<'_>) -> rust::View<'_> {
    held.as_local()
        .and_then(rust::Local::target)
        .map_or(held, |target| {
            if target.kind() == RustKind::PatType {
                target.child_first().unwrap_or(target)
            } else {
                target
            }
        })
}

fn rust_names(declared: rust::View<'_>) -> Names<'_> {
    if declared.kind() == RustKind::PatIdent {
        let name = declared
            .children_of(RustKind::Ident)
            .next()
            .unwrap_or(declared);

        return Names::Positions(name.positions().into());
    }

    Names::Rust(declared.children())
}

fn rust_declared_type(held: rust::View<'_>) -> Option<rust::View<'_>> {
    if let Some(local) = held.as_local() {
        let target = local.target()?;

        return (target.kind() == RustKind::PatType)
            .then(|| target.children().nth(1))
            .flatten();
    }

    held.children()
        .find(|child| child.kind().name().starts_with("Type"))
}

fn rust_item_value(held: rust::View<'_>) -> Option<rust::View<'_>> {
    if !matches!(held.kind(), RustKind::ItemConst | RustKind::ItemStatic) {
        return None;
    }

    let equal = held.positions_of(RustKind::Equal).next()?;

    held.children().find(|child| child.token_start() > equal)
}

fn rust_use_glob(held: rust::View<'_>) -> bool {
    let mut found = false;
    let mut pending = [NONE; SEGMENT_COUNT_MAX as usize];
    let mut count = 0_usize;

    pending[0] = held.index();
    count += 1;

    for _ in 0..CHILD_COUNT_MAX {
        if count == 0 {
            break;
        }

        count -= 1;

        let current = held.at(pending[count]);

        if current.kind() == RustKind::UseGlob {
            found = true;

            break;
        }

        for child in current.children() {
            if count < pending.len() {
                pending[count] = child.index();
                count += 1;
            }
        }
    }

    found
}

fn rust_use_segments(held: rust::View<'_>, out: &mut BoundedVec<Span>) -> bool {
    let Some(mut current) = held.as_use().and_then(rust::Use::tree) else {
        return true;
    };

    for _ in 0..SEGMENT_COUNT_MAX {
        let named = matches!(
            current.kind(),
            RustKind::UseName | RustKind::UsePath | RustKind::UseRename
        );

        if !named {
            return true;
        }

        let Some(name) = current.children_of(RustKind::Ident).next() else {
            return true;
        };

        if !out.push(name.span()) {
            return false;
        }

        let Some(next) = current
            .children()
            .find(|child| child.kind() != RustKind::Ident)
        else {
            return true;
        };

        current = next;
    }

    true
}

fn rust_is_public(held: rust::View<'_>) -> bool {
    held.positions_of(RustKind::PubKeyword).next().is_some()
        || held.children_of(RustKind::VisRestricted).next().is_some()
}

fn python_import_segments(held: python::View<'_>, out: &mut BoundedVec<Span>) -> bool {
    let Some(import) = held.as_import() else {
        return true;
    };

    if held.kind() == PythonKind::ImportFrom {
        return import.module_segments(out);
    }

    let Some(alias) = import.aliases().next() else {
        return true;
    };

    alias.name_segments(out)
}
