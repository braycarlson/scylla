use crate::bounded::Span;
use crate::syntax::typescript::kind::TypeScriptKind;
use crate::token::Token;
use crate::tree::{NONE, Tree};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Literal {
    Boolean,
    Null,
    Number,
    Regex,
    Template,
    Text,
    Undefined,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Member {
    Field,
    Getter,
    Method,
    Setter,
    StaticBlock,
}

#[derive(Clone, Copy, Debug)]
pub struct View<'run> {
    node: u32,
    raw: &'run [TypeScriptKind],
    tokens: &'run [Token],
    tree: &'run Tree<TypeScriptKind>,
}

#[derive(Clone, Copy, Debug)]
pub struct Call<'run>(View<'run>);

#[derive(Clone, Copy, Debug)]
pub struct ClassDeclaration<'run>(View<'run>);

#[derive(Clone, Copy, Debug)]
pub struct Constant<'run>(View<'run>);

#[derive(Clone, Copy, Debug)]
pub struct Declarator<'run>(View<'run>);

#[derive(Clone, Copy, Debug)]
pub struct Function<'run>(View<'run>);

#[derive(Clone, Copy, Debug)]
pub struct ImportStatement<'run>(View<'run>);

#[derive(Clone, Copy, Debug)]
pub struct MemberExpression<'run>(View<'run>);

#[derive(Clone, Copy, Debug)]
pub struct MethodDefinition<'run>(View<'run>);

#[derive(Clone, Copy, Debug)]
pub struct Operation<'run>(View<'run>);

#[derive(Clone, Copy, Debug)]
pub struct Pair<'run>(View<'run>);

#[derive(Clone, Copy, Debug)]
pub struct Statement<'run>(View<'run>);

#[derive(Clone, Debug)]
pub struct Children<'run> {
    current: u32,
    kind: Option<TypeScriptKind>,
    raw: &'run [TypeScriptKind],
    tokens: &'run [Token],
    tree: &'run Tree<TypeScriptKind>,
}

#[derive(Clone, Debug)]
pub struct Positions<'run> {
    child: u32,
    kind: Option<TypeScriptKind>,
    limit: u32,
    position: u32,
    raw: &'run [TypeScriptKind],
    tree: &'run Tree<TypeScriptKind>,
}

const CALLS: [TypeScriptKind; 2] = [
    TypeScriptKind::CallExpression,
    TypeScriptKind::NewExpression,
];

const CLASSES: [TypeScriptKind; 2] = [TypeScriptKind::Class, TypeScriptKind::ClassDeclaration];

const CONSTANTS: [TypeScriptKind; 8] = [
    TypeScriptKind::False,
    TypeScriptKind::Null,
    TypeScriptKind::NumberNode,
    TypeScriptKind::RegexNode,
    TypeScriptKind::StringNode,
    TypeScriptKind::TemplateString,
    TypeScriptKind::True,
    TypeScriptKind::Undefined,
];

const FUNCTIONS: [TypeScriptKind; 6] = [
    TypeScriptKind::ArrowFunction,
    TypeScriptKind::FunctionDeclaration,
    TypeScriptKind::FunctionExpression,
    TypeScriptKind::GeneratorFunction,
    TypeScriptKind::GeneratorFunctionDeclaration,
    TypeScriptKind::MethodDefinition,
];

const MEMBERS: [TypeScriptKind; 2] = [
    TypeScriptKind::MemberExpression,
    TypeScriptKind::SubscriptExpression,
];

const OPERATIONS: [TypeScriptKind; 6] = [
    TypeScriptKind::AssignmentExpression,
    TypeScriptKind::AugmentedAssignmentExpression,
    TypeScriptKind::BinaryExpression,
    TypeScriptKind::TernaryExpression,
    TypeScriptKind::UnaryExpression,
    TypeScriptKind::UpdateExpression,
];

const PAIRS: [TypeScriptKind; 2] = [TypeScriptKind::Pair, TypeScriptKind::PairPattern];

const STATEMENTS: [TypeScriptKind; 11] = [
    TypeScriptKind::DoStatement,
    TypeScriptKind::ForInStatement,
    TypeScriptKind::ForStatement,
    TypeScriptKind::IfStatement,
    TypeScriptKind::ReturnStatement,
    TypeScriptKind::SwitchStatement,
    TypeScriptKind::ThrowStatement,
    TypeScriptKind::TryStatement,
    TypeScriptKind::WhileStatement,
    TypeScriptKind::WithStatement,
    TypeScriptKind::LabeledStatement,
];

impl<'run> View<'run> {
    pub fn new(
        tree: &'run Tree<TypeScriptKind>,
        tokens: &'run [Token],
        raw: &'run [TypeScriptKind],
        node: u32,
    ) -> Self {
        assert!(node < tree.count());
        assert_eq!(tokens.len(), raw.len());

        Self {
            node,
            raw,
            tokens,
            tree,
        }
    }

    #[must_use]
    pub fn at(self, node: u32) -> Self {
        assert!(node < self.tree.count());

        Self { node, ..self }
    }

    pub fn index(self) -> u32 {
        self.node
    }

    pub fn token_start(self) -> u32 {
        self.tree.at(self.node).token_start
    }

    pub fn token_end(self) -> u32 {
        self.tree.at(self.node).token_end
    }

    pub fn kind(self) -> TypeScriptKind {
        self.tree.at(self.node).kind
    }

    pub fn span(self) -> Span {
        self.tree.at(self.node).span(self.tokens)
    }

    pub fn text(self, source: &'run [u8]) -> &'run [u8] {
        let span = self.span();

        assert!(span.end() as usize <= source.len());

        &source[span.range()]
    }

    pub fn parent(self) -> Option<Self> {
        let parent = self.tree.at(self.node).parent;

        if parent == NONE {
            return None;
        }

        Some(Self {
            node: parent,
            ..self
        })
    }

    pub fn children(self) -> Children<'run> {
        self.children_of_kind(None)
    }

    pub fn children_of(self, kind: TypeScriptKind) -> Children<'run> {
        self.children_of_kind(Some(kind))
    }

    fn children_of_kind(self, kind: Option<TypeScriptKind>) -> Children<'run> {
        Children {
            current: self.tree.at(self.node).child_first,
            kind,
            raw: self.raw,
            tokens: self.tokens,
            tree: self.tree,
        }
    }

    pub fn child_first(self) -> Option<Self> {
        self.children().next()
    }

    pub fn child_first_of(self, kind: TypeScriptKind) -> Option<Self> {
        self.children_of(kind).next()
    }

    pub fn child_at(self, index: u32) -> Option<Self> {
        self.children().nth(index as usize)
    }

    pub fn positions(self) -> Positions<'run> {
        self.positions_of_kind(None)
    }

    pub fn positions_of(self, kind: TypeScriptKind) -> Positions<'run> {
        self.positions_of_kind(Some(kind))
    }

    fn positions_of_kind(self, kind: Option<TypeScriptKind>) -> Positions<'run> {
        let node = self.tree.at(self.node);

        Positions {
            child: node.child_first,
            kind,
            limit: node.token_end,
            position: node.token_start,
            raw: self.raw,
            tree: self.tree,
        }
    }

    pub fn token_at(self, position: u32) -> Token {
        self.tokens[position as usize]
    }

    pub fn token_kind(self, position: u32) -> TypeScriptKind {
        self.raw[position as usize]
    }

    pub fn token_first(self, kind: TypeScriptKind) -> Option<u32> {
        self.positions_of(kind).next()
    }

    pub fn holds(self, kind: TypeScriptKind) -> bool {
        self.positions_of(kind).next().is_some()
    }

    fn cast(self, kinds: &[TypeScriptKind]) -> Option<Self> {
        if kinds.contains(&self.kind()) {
            return Some(self);
        }

        None
    }

    pub fn as_call(self) -> Option<Call<'run>> {
        self.cast(&CALLS).map(Call)
    }

    pub fn as_class(self) -> Option<ClassDeclaration<'run>> {
        self.cast(&CLASSES).map(ClassDeclaration)
    }

    pub fn as_constant(self) -> Option<Constant<'run>> {
        self.cast(&CONSTANTS).map(Constant)
    }

    pub fn as_declarator(self) -> Option<Declarator<'run>> {
        self.cast(&[TypeScriptKind::VariableDeclarator])
            .map(Declarator)
    }

    pub fn as_function(self) -> Option<Function<'run>> {
        self.cast(&FUNCTIONS).map(Function)
    }

    pub fn as_import(self) -> Option<ImportStatement<'run>> {
        self.cast(&[TypeScriptKind::ImportStatement])
            .map(ImportStatement)
    }

    pub fn as_member(self) -> Option<MemberExpression<'run>> {
        self.cast(&MEMBERS).map(MemberExpression)
    }

    pub fn as_method(self) -> Option<MethodDefinition<'run>> {
        self.cast(&[
            TypeScriptKind::ClassStaticBlock,
            TypeScriptKind::PublicFieldDefinition,
            TypeScriptKind::MethodDefinition,
        ])
        .map(MethodDefinition)
    }

    pub fn as_operation(self) -> Option<Operation<'run>> {
        self.cast(&OPERATIONS).map(Operation)
    }

    pub fn as_pair(self) -> Option<Pair<'run>> {
        self.cast(&PAIRS).map(Pair)
    }

    pub fn as_statement(self) -> Option<Statement<'run>> {
        self.cast(&STATEMENTS).map(Statement)
    }
}

impl<'run> Iterator for Children<'run> {
    type Item = View<'run>;

    fn next(&mut self) -> Option<View<'run>> {
        while self.current != NONE {
            let node = self.tree.at(self.current);
            let found = View {
                node: self.current,
                raw: self.raw,
                tokens: self.tokens,
                tree: self.tree,
            };

            self.current = node.sibling_next;

            if self.kind.is_none_or(|kind| kind == node.kind) {
                return Some(found);
            }
        }

        None
    }
}

impl Iterator for Positions<'_> {
    type Item = u32;

    fn next(&mut self) -> Option<u32> {
        while self.position < self.limit {
            if self.child != NONE {
                let held = self.tree.at(self.child);

                if held.token_start <= self.position && held.token_end > self.position {
                    self.position = held.token_end;
                    self.child = held.sibling_next;

                    continue;
                }

                if held.token_end <= self.position {
                    self.child = held.sibling_next;

                    continue;
                }
            }

            let position = self.position;

            self.position += 1;

            if self
                .kind
                .is_none_or(|kind| self.raw[position as usize] == kind)
            {
                return Some(position);
            }
        }

        None
    }
}

impl<'run> Call<'run> {
    pub fn view(self) -> View<'run> {
        self.0
    }

    pub fn callee(self) -> Option<View<'run>> {
        self.0.child_first()
    }

    pub fn is_optional(self) -> bool {
        self.0
            .child_first_of(TypeScriptKind::OptionalChain)
            .is_some()
    }

    pub fn arguments(self) -> impl Iterator<Item = View<'run>> {
        self.0
            .child_first_of(TypeScriptKind::Arguments)
            .into_iter()
            .flat_map(View::children)
    }
}

impl<'run> ClassDeclaration<'run> {
    pub fn view(self) -> View<'run> {
        self.0
    }

    pub fn name_token(self) -> Option<u32> {
        let held = self.0.child_first_of(TypeScriptKind::IdentifierNode)?;

        held.positions().next()
    }

    pub fn heritage(self) -> Option<View<'run>> {
        self.0
            .child_first_of(TypeScriptKind::ClassHeritage)
            .and_then(|held| held.child_first_of(TypeScriptKind::ExtendsClause))
            .and_then(View::child_first)
    }

    pub fn body(self) -> Option<View<'run>> {
        self.0.child_first_of(TypeScriptKind::ClassBody)
    }

    pub fn members(self) -> impl Iterator<Item = View<'run>> {
        self.body().into_iter().flat_map(View::children)
    }
}

impl<'run> Constant<'run> {
    pub fn view(self) -> View<'run> {
        self.0
    }

    pub fn literal_class(self) -> Literal {
        let kind = self.0.kind();

        if matches!(kind, TypeScriptKind::False | TypeScriptKind::True) {
            return Literal::Boolean;
        }

        if kind == TypeScriptKind::Null {
            return Literal::Null;
        }

        if kind == TypeScriptKind::NumberNode {
            return Literal::Number;
        }

        if kind == TypeScriptKind::RegexNode {
            return Literal::Regex;
        }

        if kind == TypeScriptKind::TemplateString {
            return Literal::Template;
        }

        if kind == TypeScriptKind::Undefined {
            return Literal::Undefined;
        }

        Literal::Text
    }

    pub fn content_span(self) -> Span {
        let span = self.0.span();

        if !matches!(
            self.literal_class(),
            Literal::Regex | Literal::Template | Literal::Text
        ) {
            return span;
        }

        if span.length < 2 {
            return span;
        }

        Span {
            length: span.length - 2,
            offset: span.offset + 1,
        }
    }
}

impl<'run> Declarator<'run> {
    pub fn view(self) -> View<'run> {
        self.0
    }

    pub fn target(self) -> Option<View<'run>> {
        self.0.child_first()
    }

    pub fn value(self) -> Option<View<'run>> {
        self.0
            .children()
            .skip(1)
            .find(|held| held.kind() != TypeScriptKind::TypeAnnotation)
    }
}

impl<'run> Function<'run> {
    pub fn view(self) -> View<'run> {
        self.0
    }

    pub fn is_async(self) -> bool {
        self.0.holds(TypeScriptKind::AsyncKeyword)
    }

    pub fn is_generator(self) -> bool {
        matches!(
            self.0.kind(),
            TypeScriptKind::GeneratorFunction | TypeScriptKind::GeneratorFunctionDeclaration
        ) || self.0.holds(TypeScriptKind::Star)
    }

    pub fn name_token(self) -> Option<u32> {
        let held = self.0.children().find(|held| {
            matches!(
                held.kind(),
                TypeScriptKind::IdentifierNode
                    | TypeScriptKind::PrivatePropertyIdentifier
                    | TypeScriptKind::PropertyIdentifier
            )
        })?;

        held.positions().next()
    }

    pub fn parameters(self) -> impl Iterator<Item = View<'run>> {
        self.0
            .child_first_of(TypeScriptKind::FormalParameters)
            .into_iter()
            .flat_map(View::children)
    }

    pub fn body(self) -> Option<View<'run>> {
        self.0.children().last()
    }
}

impl<'run> ImportStatement<'run> {
    pub fn view(self) -> View<'run> {
        self.0
    }

    pub fn source(self) -> Option<View<'run>> {
        self.0.child_first_of(TypeScriptKind::StringNode)
    }

    pub fn clause(self) -> Option<View<'run>> {
        self.0.child_first_of(TypeScriptKind::ImportClause)
    }

    pub fn specifiers(self) -> impl Iterator<Item = View<'run>> {
        self.clause()
            .into_iter()
            .flat_map(View::children)
            .flat_map(|held| {
                let named = held.kind() == TypeScriptKind::NamedImports;

                named
                    .then(|| held.children())
                    .into_iter()
                    .flatten()
                    .chain((!named).then_some(held))
            })
    }
}

impl<'run> MemberExpression<'run> {
    pub fn view(self) -> View<'run> {
        self.0
    }

    pub fn object(self) -> Option<View<'run>> {
        self.0.child_first()
    }

    pub fn property(self) -> Option<View<'run>> {
        self.0.children().last()
    }

    pub fn is_optional(self) -> bool {
        self.0
            .children_of(TypeScriptKind::OptionalChain)
            .next()
            .is_some()
    }
}

impl<'run> MethodDefinition<'run> {
    pub fn view(self) -> View<'run> {
        self.0
    }

    pub fn member_class(self) -> Member {
        if self.0.kind() == TypeScriptKind::ClassStaticBlock {
            return Member::StaticBlock;
        }

        if self.0.kind() == TypeScriptKind::PublicFieldDefinition {
            return Member::Field;
        }

        if self.names(b"get") {
            return Member::Getter;
        }

        if self.names(b"set") {
            return Member::Setter;
        }

        Member::Method
    }

    fn names(self, word: &[u8]) -> bool {
        let Some(position) = self.0.positions_of(TypeScriptKind::Identifier).next() else {
            return false;
        };

        self.0.token_at(position).length as usize == word.len()
    }

    pub fn is_static(self) -> bool {
        self.0.holds(TypeScriptKind::StaticKeyword)
    }

    pub fn key(self) -> Option<View<'run>> {
        self.0.child_first()
    }

    pub fn value(self) -> Option<View<'run>> {
        self.0.children().last()
    }
}

impl<'run> Operation<'run> {
    pub fn view(self) -> View<'run> {
        self.0
    }

    pub fn operands(self) -> Children<'run> {
        self.0.children()
    }

    pub fn operator_tokens(self) -> Positions<'run> {
        self.0.positions()
    }
}

impl<'run> Pair<'run> {
    pub fn view(self) -> View<'run> {
        self.0
    }

    pub fn key(self) -> Option<View<'run>> {
        self.0.child_first()
    }

    pub fn value(self) -> Option<View<'run>> {
        self.0.children().last()
    }
}

impl<'run> Statement<'run> {
    pub fn view(self) -> View<'run> {
        self.0
    }

    pub fn header(self) -> Option<View<'run>> {
        self.0
            .child_first_of(TypeScriptKind::ParenthesizedExpression)
            .or_else(|| self.0.child_first())
    }

    pub fn body(self) -> Option<View<'run>> {
        self.0
            .children()
            .find(|held| held.kind() == TypeScriptKind::StatementBlock)
    }

    pub fn else_clause(self) -> Option<View<'run>> {
        self.0.child_first_of(TypeScriptKind::ElseClause)
    }

    pub fn finally_clause(self) -> Option<View<'run>> {
        self.0.child_first_of(TypeScriptKind::FinallyClause)
    }

    pub fn handlers(self) -> Children<'run> {
        self.0.children_of(TypeScriptKind::CatchClause)
    }

    pub fn cases(self) -> impl Iterator<Item = View<'run>> {
        self.0
            .child_first_of(TypeScriptKind::SwitchBody)
            .into_iter()
            .flat_map(View::children)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::bounded::BoundedVec;
    use crate::language::Lexer as _;
    use crate::lex::JAVASCRIPT;
    use crate::syntax::typescript::classify::classify;
    use crate::syntax::typescript::dialect::Dialect;
    use crate::syntax::typescript::parse;
    use crate::token::Tokens as CodeTokens;
    use crate::tree::Events;

    struct Fixture {
        raw: BoundedVec<TypeScriptKind>,
        tokens: CodeTokens,
        tree: Tree<TypeScriptKind>,
    }

    impl Fixture {
        fn of(source: &[u8]) -> Self {
            let mut lexed = CodeTokens::reserve(4_096);
            let mut tokens = CodeTokens::reserve(4_096);
            let mut raw = BoundedVec::reserve(4_096);
            let mut events = Events::reserve(0x4000);
            let mut tree = Tree::reserve(4_096, 64);

            JAVASCRIPT.lex(source, &mut lexed);

            assert!(classify(
                source,
                lexed.as_slice(),
                &mut tokens,
                &mut raw,
                Dialect::Ts
            ));

            parse::build(
                source,
                tokens.as_slice(),
                &raw,
                &mut events,
                &mut tree,
                Dialect::Ts,
            );

            Self { raw, tokens, tree }
        }

        fn view(&self, node: u32) -> View<'_> {
            View::new(&self.tree, self.tokens.as_slice(), &self.raw, node)
        }

        fn first(&self, kind: TypeScriptKind) -> View<'_> {
            let index = self
                .tree
                .as_slice()
                .iter()
                .position(|node| node.kind == kind)
                .unwrap_or_else(|| panic!("{} is in the tree", kind.name()));

            self.view(u32::try_from(index).expect("a tree fits in u32"))
        }
    }

    #[test]
    fn a_call_reads_its_callee_and_its_arguments() {
        let source = b"handler(one, two);\n";
        let fixture = Fixture::of(source);

        let call = fixture
            .first(TypeScriptKind::CallExpression)
            .as_call()
            .expect("a call casts");

        assert_eq!(
            call.callee().expect("a callee").text(source),
            b"handler".as_slice()
        );

        assert_eq!(call.arguments().count(), 2);
        assert!(!call.is_optional());
    }

    #[test]
    fn a_function_reads_its_name_parameters_and_body() {
        let source = b"async function* run(one, two) { return one; }\n";
        let fixture = Fixture::of(source);

        let held = fixture
            .first(TypeScriptKind::GeneratorFunctionDeclaration)
            .as_function()
            .expect("a function casts");

        assert!(held.is_async());
        assert!(held.is_generator());
        assert_eq!(held.parameters().count(), 2);

        assert_eq!(
            held.body().expect("a body").kind(),
            TypeScriptKind::StatementBlock
        );

        let position = held.name_token().expect("a name");

        assert_eq!(
            held.view().token_at(position).text(source),
            b"run".as_slice()
        );
    }

    #[test]
    fn a_class_reads_its_heritage_and_its_members() {
        let source = b"class Widget extends Base { static run() {} field = 1; }\n";
        let fixture = Fixture::of(source);

        let held = fixture
            .first(TypeScriptKind::ClassDeclaration)
            .as_class()
            .expect("a class casts");

        assert_eq!(
            held.heritage().expect("a heritage").text(source),
            b"Base".as_slice()
        );

        assert_eq!(held.members().count(), 2);

        let method = held
            .members()
            .next()
            .expect("a member")
            .as_method()
            .expect("a method casts");

        assert!(method.is_static());
        assert_eq!(method.member_class(), Member::Method);
    }

    #[test]
    fn a_member_expression_reads_its_object_and_its_property() {
        let source = b"target?.field;\n";
        let fixture = Fixture::of(source);

        let held = fixture
            .first(TypeScriptKind::MemberExpression)
            .as_member()
            .expect("a member casts");

        assert!(held.is_optional());

        assert_eq!(
            held.object().expect("an object").text(source),
            b"target".as_slice()
        );

        assert_eq!(
            held.property().expect("a property").text(source),
            b"field".as_slice()
        );
    }

    #[test]
    fn a_declarator_reads_its_target_and_its_value() {
        let source = b"const one = 1;\n";
        let fixture = Fixture::of(source);

        let held = fixture
            .first(TypeScriptKind::VariableDeclarator)
            .as_declarator()
            .expect("a declarator casts");

        assert_eq!(
            held.target().expect("a target").text(source),
            b"one".as_slice()
        );

        assert_eq!(held.value().expect("a value").text(source), b"1".as_slice());
    }

    #[test]
    fn an_import_reads_its_source_and_its_specifiers() {
        let source = b"import one, { two as three } from \"module\";\n";
        let fixture = Fixture::of(source);

        let held = fixture
            .first(TypeScriptKind::ImportStatement)
            .as_import()
            .expect("an import casts");

        assert_eq!(
            held.source().expect("a source").text(source),
            b"\"module\"".as_slice()
        );

        assert_eq!(held.specifiers().count(), 2);
    }

    #[test]
    fn a_constant_reads_its_class_and_its_content() {
        let source = b"const text = \"body\";\n";
        let fixture = Fixture::of(source);

        let held = fixture
            .first(TypeScriptKind::StringNode)
            .as_constant()
            .expect("a constant casts");

        assert_eq!(held.literal_class(), Literal::Text);
        assert_eq!(&source[held.content_span().range()], b"body".as_slice());
    }

    #[test]
    fn a_pair_reads_its_key_and_its_value() {
        const SOURCE: &[u8] = b"const held = { one: 1 };\n";
        let fixture = Fixture::of(SOURCE);

        let held = fixture
            .first(TypeScriptKind::Pair)
            .as_pair()
            .expect("a pair casts");

        assert_eq!(held.key().expect("a key").text(SOURCE), b"one".as_slice());
        assert_eq!(held.value().expect("a value").text(SOURCE), b"1".as_slice());
    }

    #[test]
    fn a_statement_reads_its_header_and_its_body() {
        const SOURCE: &[u8] = b"if (one) { two(); } else { three(); }\n";
        let fixture = Fixture::of(SOURCE);

        let held = fixture
            .first(TypeScriptKind::IfStatement)
            .as_statement()
            .expect("a statement casts");

        assert_eq!(held.header().expect("a header").text(SOURCE), b"(one)");

        assert_eq!(
            held.body().expect("a body").kind(),
            TypeScriptKind::StatementBlock
        );

        assert!(held.else_clause().is_some());
    }

    #[test]
    fn an_operation_reads_its_operands_and_its_operators() {
        const SOURCE: &[u8] = b"const held = one + two;\n";
        let fixture = Fixture::of(SOURCE);

        let held = fixture
            .first(TypeScriptKind::BinaryExpression)
            .as_operation()
            .expect("an operation casts");

        assert_eq!(held.operands().count(), 2);
        assert_eq!(held.operator_tokens().count(), 1);
    }
}
