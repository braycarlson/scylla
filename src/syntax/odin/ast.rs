use crate::bounded::Span;
use crate::syntax::odin::expression::is_name;
use crate::syntax::odin::kind::OdinKind;
use crate::token::Token;
use crate::tree::{NONE, Tree};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Literal {
    Character,
    Number,
    Raw,
    Text,
}

#[derive(Clone, Copy, Debug)]
pub struct View<'run> {
    node: u32,
    raw: &'run [OdinKind],
    tokens: &'run [Token],
    tree: &'run Tree<OdinKind>,
}

#[derive(Clone, Copy, Debug)]
pub struct Call<'run>(View<'run>);

#[derive(Clone, Copy, Debug)]
pub struct Container<'run>(View<'run>);

#[derive(Clone, Copy, Debug)]
pub struct Declaration<'run>(View<'run>);

#[derive(Clone, Copy, Debug)]
pub struct Field<'run>(View<'run>);

#[derive(Clone, Copy, Debug)]
pub struct Function<'run>(View<'run>);

#[derive(Clone, Copy, Debug)]
pub struct Operation<'run>(View<'run>);

#[derive(Clone, Copy, Debug)]
pub struct Statement<'run>(View<'run>);

#[derive(Clone, Debug)]
pub struct Children<'run> {
    current: u32,
    kind: Option<OdinKind>,
    raw: &'run [OdinKind],
    tokens: &'run [Token],
    tree: &'run Tree<OdinKind>,
}

#[derive(Clone, Debug)]
pub struct Positions<'run> {
    child: u32,
    kind: Option<OdinKind>,
    limit: u32,
    position: u32,
    raw: &'run [OdinKind],
    tree: &'run Tree<OdinKind>,
}

const CALLS: [OdinKind; 1] = [OdinKind::CallExpression];

const KEYWORDS: [OdinKind; 4] = [
    OdinKind::BitFieldKeyword,
    OdinKind::EnumKeyword,
    OdinKind::StructKeyword,
    OdinKind::UnionKeyword,
];

const CONTAINERS: [OdinKind; 4] = [
    OdinKind::BitFieldDeclaration,
    OdinKind::EnumDeclaration,
    OdinKind::StructDeclaration,
    OdinKind::UnionDeclaration,
];

const DECLARATIONS: [OdinKind; 5] = [
    OdinKind::ConstDeclaration,
    OdinKind::ConstTypeDeclaration,
    OdinKind::ImportDeclaration,
    OdinKind::VarDeclaration,
    OdinKind::VariableDeclaration,
];

const FIELDS: [OdinKind; 3] = [
    OdinKind::Field,
    OdinKind::StructField,
    OdinKind::StructMember,
];

const FUNCTIONS: [OdinKind; 3] = [
    OdinKind::Procedure,
    OdinKind::ProcedureDeclaration,
    OdinKind::ProcedureType,
];

const OPERATIONS: [OdinKind; 8] = [
    OdinKind::Address,
    OdinKind::BinaryExpression,
    OdinKind::CastExpression,
    OdinKind::InExpression,
    OdinKind::OrReturnExpression,
    OdinKind::RangeExpression,
    OdinKind::TernaryExpression,
    OdinKind::UnaryExpression,
];

const STATEMENTS: [OdinKind; 8] = [
    OdinKind::Block,
    OdinKind::DeferStatement,
    OdinKind::ForStatement,
    OdinKind::IfStatement,
    OdinKind::LabelStatement,
    OdinKind::ReturnStatement,
    OdinKind::SwitchStatement,
    OdinKind::WhenStatement,
];

impl<'run> View<'run> {
    pub fn new(
        tree: &'run Tree<OdinKind>,
        tokens: &'run [Token],
        raw: &'run [OdinKind],
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

    pub fn kind(self) -> OdinKind {
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

    pub fn children_of(self, kind: OdinKind) -> Children<'run> {
        self.children_of_kind(Some(kind))
    }

    fn children_of_kind(self, kind: Option<OdinKind>) -> Children<'run> {
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

    pub fn child_first_of(self, kind: OdinKind) -> Option<Self> {
        self.children_of(kind).next()
    }

    pub fn child_at(self, index: u32) -> Option<Self> {
        self.children().nth(index as usize)
    }

    pub fn positions(self) -> Positions<'run> {
        self.positions_of_kind(None)
    }

    pub fn name_position(self) -> Option<u32> {
        self.positions()
            .find(|position| is_name(self.token_kind(*position)))
    }

    pub fn positions_of(self, kind: OdinKind) -> Positions<'run> {
        self.positions_of_kind(Some(kind))
    }

    fn positions_of_kind(self, kind: Option<OdinKind>) -> Positions<'run> {
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

    pub fn token_kind(self, position: u32) -> OdinKind {
        self.raw[position as usize]
    }

    pub fn token_first(self, kind: OdinKind) -> Option<u32> {
        self.positions_of(kind).next()
    }

    pub fn holds(self, kind: OdinKind) -> bool {
        self.positions_of(kind).next().is_some()
    }

    fn cast(self, kinds: &[OdinKind]) -> Option<Self> {
        if kinds.contains(&self.kind()) {
            return Some(self);
        }

        None
    }

    pub fn as_call(self) -> Option<Call<'run>> {
        self.cast(&CALLS).map(Call)
    }

    pub fn as_container(self) -> Option<Container<'run>> {
        self.cast(&CONTAINERS).map(Container)
    }

    pub fn as_declaration(self) -> Option<Declaration<'run>> {
        self.cast(&DECLARATIONS).map(Declaration)
    }

    pub fn as_field(self) -> Option<Field<'run>> {
        self.cast(&FIELDS).map(Field)
    }

    pub fn as_function(self) -> Option<Function<'run>> {
        self.cast(&FUNCTIONS).map(Function)
    }

    pub fn as_operation(self) -> Option<Operation<'run>> {
        self.cast(&OPERATIONS).map(Operation)
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

    pub fn name_token(self) -> Option<u32> {
        self.callee()?.name_position()
    }

    pub fn arguments(self) -> impl Iterator<Item = View<'run>> {
        self.0.children().skip(1)
    }
}

impl<'run> Container<'run> {
    pub fn view(self) -> View<'run> {
        self.0
    }

    pub fn keyword(self) -> Option<OdinKind> {
        self.0.positions().find_map(|position| {
            let kind = self.0.token_kind(position);

            KEYWORDS.contains(&kind).then_some(kind)
        })
    }

    pub fn name_token(self) -> Option<u32> {
        self.name()?.name_position()
    }

    fn name(self) -> Option<View<'run>> {
        self.0.child_first_of(OdinKind::IdentifierNode)
    }

    pub fn fields(self) -> Children<'run> {
        self.0.children_of(OdinKind::Field)
    }

    pub fn attributes(self) -> Option<View<'run>> {
        self.0.child_first_of(OdinKind::Attributes)
    }
}

impl<'run> Declaration<'run> {
    pub fn view(self) -> View<'run> {
        self.0
    }

    pub fn is_constant(self) -> bool {
        matches!(
            self.0.kind(),
            OdinKind::ConstDeclaration | OdinKind::ConstTypeDeclaration
        )
    }

    pub fn names(self) -> Children<'run> {
        self.0.children_of(OdinKind::IdentifierNode)
    }

    pub fn type_of(self) -> Option<View<'run>> {
        self.0.child_first_of(OdinKind::Type)
    }

    pub fn value(self) -> Option<View<'run>> {
        let held = self
            .0
            .token_first(OdinKind::ColonColon)
            .or_else(|| self.0.token_first(OdinKind::Equal))?;

        self.0
            .children()
            .find(|child| child.tree.at(child.node).token_start > held)
    }
}

impl<'run> Field<'run> {
    pub fn view(self) -> View<'run> {
        self.0
    }

    pub fn names(self) -> Children<'run> {
        self.0.children_of(OdinKind::IdentifierNode)
    }

    pub fn type_of(self) -> Option<View<'run>> {
        self.0.child_first_of(OdinKind::Type)
    }

    pub fn tag(self) -> Option<View<'run>> {
        self.0.child_first_of(OdinKind::String)
    }
}

impl<'run> Function<'run> {
    pub fn view(self) -> View<'run> {
        self.0
    }

    pub fn signature(self) -> Option<View<'run>> {
        if self.0.kind() == OdinKind::ProcedureDeclaration {
            return self.0.child_first_of(OdinKind::Procedure);
        }

        Some(self.0)
    }

    pub fn name_token(self) -> Option<u32> {
        self.0
            .child_first_of(OdinKind::IdentifierNode)?
            .name_position()
    }

    pub fn parameters(self) -> Option<View<'run>> {
        self.signature()?.child_first_of(OdinKind::Parameters)
    }

    pub fn returns(self) -> Option<View<'run>> {
        self.signature()?.child_first_of(OdinKind::Type)
    }

    pub fn body(self) -> Option<View<'run>> {
        self.signature()?.child_first_of(OdinKind::Block)
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

impl<'run> Statement<'run> {
    pub fn view(self) -> View<'run> {
        self.0
    }

    pub fn header(self) -> Option<View<'run>> {
        self.0.child_first()
    }

    pub fn body(self) -> Option<View<'run>> {
        if self.0.kind() == OdinKind::Block {
            return Some(self.0);
        }

        self.0.children_of(OdinKind::Block).last()
    }

    pub fn statements(self) -> impl Iterator<Item = View<'run>> {
        self.body().into_iter().flat_map(View::children)
    }

    pub fn cases(self) -> Children<'run> {
        self.0.children_of(OdinKind::SwitchCase)
    }
}

pub fn literal_class(text: &[u8]) -> Literal {
    match text.first() {
        Some(b'\'') => Literal::Character,
        Some(b'"') => Literal::Text,
        Some(b'`') => Literal::Raw,
        _ => Literal::Number,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::bounded::BoundedVec;
    use crate::language::Lexer as _;
    use crate::lex::ODIN;
    use crate::syntax::odin::classify::classify;
    use crate::syntax::odin::parse;
    use crate::token::Tokens as CodeTokens;
    use crate::tree::Events;

    struct Fixture {
        raw: BoundedVec<OdinKind>,
        tokens: CodeTokens,
        tree: Tree<OdinKind>,
    }

    impl Fixture {
        fn of(source: &[u8]) -> Self {
            let mut lexed = CodeTokens::reserve(4_096);
            let mut tokens = CodeTokens::reserve(4_096);
            let mut raw = BoundedVec::reserve(4_096);
            let mut events = Events::reserve(0x4000);
            let mut tree = Tree::reserve(4_096, 64);

            ODIN.lex(source, &mut lexed);

            assert!(classify(source, lexed.as_slice(), &mut tokens, &mut raw));

            parse::build(source, tokens.as_slice(), &raw, &mut events, &mut tree);

            Self { raw, tokens, tree }
        }

        fn view(&self, node: u32) -> View<'_> {
            View::new(&self.tree, self.tokens.as_slice(), &self.raw, node)
        }

        fn first(&self, kind: OdinKind) -> View<'_> {
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
    fn a_procedure_reads_its_name_parameters_and_body() {
        const SOURCE: &[u8] =
            b"package held\n\nrun :: proc(one: int, two: string) -> int {\n\treturn one\n}\n";

        let fixture = Fixture::of(SOURCE);

        let held = fixture
            .first(OdinKind::ProcedureDeclaration)
            .as_function()
            .expect("a procedure casts");

        assert_eq!(
            held.parameters().expect("a parameter list").text(SOURCE),
            b"(one: int, two: string)".as_slice()
        );

        assert_eq!(
            held.returns().expect("a return type").text(SOURCE),
            b"int".as_slice()
        );

        assert_eq!(held.body().expect("a body").kind(), OdinKind::Block);

        let position = held.name_token().expect("a name");

        assert_eq!(
            held.view().token_at(position).text(SOURCE),
            b"run".as_slice()
        );
    }

    #[test]
    fn a_declaration_reads_its_names_and_its_value() {
        const SOURCE: &[u8] = b"package held\n\nMAX :: 10\n";
        let fixture = Fixture::of(SOURCE);

        let held = fixture
            .first(OdinKind::ConstDeclaration)
            .as_declaration()
            .expect("a declaration casts");

        assert!(held.is_constant());
        assert_eq!(held.names().count(), 1);

        assert_eq!(
            held.value().expect("a value").text(SOURCE),
            b"10".as_slice()
        );
    }

    #[test]
    fn a_variable_declaration_reads_its_type() {
        const SOURCE: &[u8] = b"package held\n\ncounter: int = 0\n";
        let fixture = Fixture::of(SOURCE);

        let held = fixture
            .first(OdinKind::VarDeclaration)
            .as_declaration()
            .expect("a declaration casts");

        assert!(!held.is_constant());

        assert_eq!(
            held.type_of().expect("a type").text(SOURCE),
            b"int".as_slice()
        );
    }

    #[test]
    fn a_container_reads_its_fields() {
        const SOURCE: &[u8] = b"package held\n\nPoint :: struct {\n\tx: int,\n\ty: int,\n}\n";
        let fixture = Fixture::of(SOURCE);

        let held = fixture
            .first(OdinKind::StructDeclaration)
            .as_container()
            .expect("a container casts");

        assert_eq!(held.keyword(), Some(OdinKind::StructKeyword));
        assert_eq!(held.fields().count(), 2);

        let field = held
            .fields()
            .next()
            .expect("a field")
            .as_field()
            .expect("a field casts");

        assert_eq!(field.names().count(), 1);

        assert_eq!(
            field.type_of().expect("a type").text(SOURCE),
            b"int".as_slice()
        );
    }

    #[test]
    fn a_call_reads_its_arguments() {
        const SOURCE: &[u8] = b"package held\n\nrun :: proc() {\n\tprintln(one, two)\n}\n";
        let fixture = Fixture::of(SOURCE);

        let held = fixture
            .first(OdinKind::CallExpression)
            .as_call()
            .expect("a call casts");

        assert_eq!(held.arguments().count(), 2);

        let position = held.name_token().expect("a name");

        assert_eq!(
            held.view().token_at(position).text(SOURCE),
            b"println".as_slice()
        );
    }

    #[test]
    fn a_statement_reads_its_body_and_its_cases() {
        const SOURCE: &[u8] =
            b"package held\n\nrun :: proc(one: int) {\nswitch one {\ncase 0:\ncase:\n}\n}\n";

        let fixture = Fixture::of(SOURCE);

        let held = fixture
            .first(OdinKind::SwitchStatement)
            .as_statement()
            .expect("a statement casts");

        assert_eq!(held.cases().count(), 2);
        assert_eq!(held.header().expect("a header").text(SOURCE), b"one");
    }

    #[test]
    fn a_block_reads_its_statements() {
        const SOURCE: &[u8] = b"package held\n\nrun :: proc() {\n\tone()\n\ttwo()\n}\n";
        let fixture = Fixture::of(SOURCE);

        let held = fixture
            .first(OdinKind::Block)
            .as_statement()
            .expect("a statement casts");

        assert_eq!(held.statements().count(), 2);
    }

    #[test]
    fn an_operation_reads_its_operands() {
        const SOURCE: &[u8] = b"package held\n\nrun :: proc() {\n\theld := one + two\n}\n";
        let fixture = Fixture::of(SOURCE);

        let held = fixture
            .first(OdinKind::BinaryExpression)
            .as_operation()
            .expect("an operation casts");

        assert_eq!(held.operands().count(), 2);
        assert_eq!(held.operator_tokens().count(), 1);
    }

    #[test]
    fn a_literal_names_its_class() {
        assert_eq!(literal_class(b"1"), Literal::Number);
        assert_eq!(literal_class(b"'c'"), Literal::Character);
        assert_eq!(literal_class(b"\"held\""), Literal::Text);
        assert_eq!(literal_class(b"`held`"), Literal::Raw);
    }
}
