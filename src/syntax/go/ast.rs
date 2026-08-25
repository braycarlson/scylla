use crate::bounded::Span;
use crate::syntax::go::kind::GoKind;
use crate::token::Token;
use crate::tree::{NONE, Tree};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Literal {
    Number,
    Rune,
    Text,
}

#[derive(Clone, Copy, Debug)]
pub struct View<'run> {
    node: u32,
    raw: &'run [GoKind],
    tokens: &'run [Token],
    tree: &'run Tree<GoKind>,
}

#[derive(Clone, Copy, Debug)]
pub struct Call<'run>(View<'run>);

#[derive(Clone, Copy, Debug)]
pub struct Declaration<'run>(View<'run>);

#[derive(Clone, Copy, Debug)]
pub struct Field<'run>(View<'run>);

#[derive(Clone, Copy, Debug)]
pub struct Function<'run>(View<'run>);

#[derive(Clone, Copy, Debug)]
pub struct Operation<'run>(View<'run>);

#[derive(Clone, Copy, Debug)]
pub struct Specification<'run>(View<'run>);

#[derive(Clone, Copy, Debug)]
pub struct Statement<'run>(View<'run>);

#[derive(Clone, Debug)]
pub struct Children<'run> {
    current: u32,
    kind: Option<GoKind>,
    raw: &'run [GoKind],
    tokens: &'run [Token],
    tree: &'run Tree<GoKind>,
}

#[derive(Clone, Debug)]
pub struct Positions<'run> {
    child: u32,
    kind: Option<GoKind>,
    limit: u32,
    position: u32,
    raw: &'run [GoKind],
    tree: &'run Tree<GoKind>,
}

const FUNCTIONS: [GoKind; 2] = [GoKind::FuncDecl, GoKind::FuncLit];

const OPERATIONS: [GoKind; 4] = [
    GoKind::BinaryExpr,
    GoKind::KeyValueExpr,
    GoKind::StarExpr,
    GoKind::UnaryExpr,
];

const SPECIFICATIONS: [GoKind; 3] = [GoKind::ImportSpec, GoKind::TypeSpec, GoKind::ValueSpec];

const STATEMENTS: [GoKind; 8] = [
    GoKind::ForStmt,
    GoKind::IfStmt,
    GoKind::RangeStmt,
    GoKind::ReturnStmt,
    GoKind::SelectStmt,
    GoKind::SwitchStmt,
    GoKind::TypeSwitchStmt,
    GoKind::AssignStmt,
];

impl<'run> View<'run> {
    pub fn new(
        tree: &'run Tree<GoKind>,
        tokens: &'run [Token],
        raw: &'run [GoKind],
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

    pub fn kind(self) -> GoKind {
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

    pub fn children_of(self, kind: GoKind) -> Children<'run> {
        self.children_of_kind(Some(kind))
    }

    fn children_of_kind(self, kind: Option<GoKind>) -> Children<'run> {
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

    pub fn child_first_of(self, kind: GoKind) -> Option<Self> {
        self.children_of(kind).next()
    }

    pub fn child_at(self, index: u32) -> Option<Self> {
        self.children().nth(index as usize)
    }

    pub fn positions(self) -> Positions<'run> {
        self.positions_of_kind(None)
    }

    pub fn positions_of(self, kind: GoKind) -> Positions<'run> {
        self.positions_of_kind(Some(kind))
    }

    fn positions_of_kind(self, kind: Option<GoKind>) -> Positions<'run> {
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

    pub fn token_kind(self, position: u32) -> GoKind {
        self.raw[position as usize]
    }

    pub fn token_first(self, kind: GoKind) -> Option<u32> {
        self.positions_of(kind).next()
    }

    pub fn holds(self, kind: GoKind) -> bool {
        self.positions_of(kind).next().is_some()
    }

    fn cast(self, kinds: &[GoKind]) -> Option<Self> {
        if kinds.contains(&self.kind()) {
            return Some(self);
        }

        None
    }

    pub fn as_call(self) -> Option<Call<'run>> {
        self.cast(&[GoKind::CallExpr]).map(Call)
    }

    pub fn as_declaration(self) -> Option<Declaration<'run>> {
        self.cast(&[GoKind::GenDecl]).map(Declaration)
    }

    pub fn as_field(self) -> Option<Field<'run>> {
        self.cast(&[GoKind::Field]).map(Field)
    }

    pub fn as_function(self) -> Option<Function<'run>> {
        self.cast(&FUNCTIONS).map(Function)
    }

    pub fn as_operation(self) -> Option<Operation<'run>> {
        self.cast(&OPERATIONS).map(Operation)
    }

    pub fn as_specification(self) -> Option<Specification<'run>> {
        self.cast(&SPECIFICATIONS).map(Specification)
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
        let callee = self.callee()?;

        if callee.kind() == GoKind::SelectorExpr {
            let held = callee.children_of(GoKind::Ident).last()?;

            return held.positions().next();
        }

        callee.positions().next()
    }

    pub fn arguments(self) -> impl Iterator<Item = View<'run>> {
        self.0.children().skip(1)
    }
}

impl<'run> Declaration<'run> {
    pub fn view(self) -> View<'run> {
        self.0
    }

    pub fn keyword(self) -> Option<GoKind> {
        let position = self.0.positions().next()?;

        Some(self.0.token_kind(position))
    }

    pub fn specifications(self) -> Children<'run> {
        self.0.children()
    }
}

impl<'run> Field<'run> {
    pub fn view(self) -> View<'run> {
        self.0
    }

    pub fn names(self) -> impl Iterator<Item = View<'run>> {
        let held = self.0;
        let count = self.type_index();

        held.children().take(count)
    }

    fn type_index(self) -> usize {
        let count = self.0.children().count();

        if count == 0 {
            return 0;
        }

        if self.tag().is_some() {
            return count.saturating_sub(2);
        }

        count - 1
    }

    pub fn type_of(self) -> Option<View<'run>> {
        self.0.children().nth(self.type_index())
    }

    pub fn tag(self) -> Option<View<'run>> {
        let last = self.0.children().last()?;

        if last.kind() != GoKind::BasicLit {
            return None;
        }

        Some(last)
    }
}

impl<'run> Function<'run> {
    pub fn view(self) -> View<'run> {
        self.0
    }

    pub fn signature(self) -> Option<View<'run>> {
        self.0.child_first_of(GoKind::FuncType)
    }

    pub fn name_token(self) -> Option<u32> {
        let signature = self.signature()?;
        let held = signature.children_of(GoKind::Ident).next()?;

        held.positions().next()
    }

    pub fn receiver(self) -> Option<View<'run>> {
        let signature = self.signature()?;

        self.name_token()?;

        let first = signature.child_first()?;

        if first.kind() != GoKind::FieldList {
            return None;
        }

        if first.span().offset > signature.span().offset + 5 {
            return None;
        }

        Some(first)
    }

    pub fn parameters(self) -> impl Iterator<Item = View<'run>> {
        self.signature()
            .into_iter()
            .flat_map(|held| held.children_of(GoKind::FieldList))
    }

    pub fn body(self) -> Option<View<'run>> {
        self.0.child_first_of(GoKind::BlockStmt)
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

impl<'run> Specification<'run> {
    pub fn view(self) -> View<'run> {
        self.0
    }

    pub fn names(self) -> impl Iterator<Item = View<'run>> {
        let count = self.name_count();

        self.0
            .children()
            .take_while(|held| held.kind() == GoKind::Ident)
            .take(count)
    }

    pub fn path(self) -> Option<View<'run>> {
        self.0.child_first_of(GoKind::BasicLit)
    }

    pub fn values(self) -> impl Iterator<Item = View<'run>> {
        let assigned = self.assigned();

        self.0
            .children()
            .filter(move |held| held.token_start() > assigned)
    }

    fn assigned(self) -> u32 {
        self.0
            .positions_of(GoKind::Equal)
            .next()
            .unwrap_or(u32::MAX)
    }

    fn name_count(self) -> usize {
        let assigned = self.assigned();

        1 + self
            .0
            .positions_of(GoKind::Comma)
            .take_while(|position| *position < assigned)
            .count()
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
        self.0.children_of(GoKind::BlockStmt).last()
    }

    pub fn clauses(self) -> impl Iterator<Item = View<'run>> {
        self.body().into_iter().flat_map(View::children)
    }
}

pub fn literal_class(text: &[u8]) -> Literal {
    match text.first() {
        Some(b'\'') => Literal::Rune,
        Some(b'"' | b'`') => Literal::Text,
        _ => Literal::Number,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::bounded::BoundedVec;
    use crate::language::Lexer as _;
    use crate::lex::GO;
    use crate::syntax::go::classify::classify;
    use crate::syntax::go::parse;
    use crate::token::Tokens as CodeTokens;
    use crate::tree::Events;

    struct Fixture {
        raw: BoundedVec<GoKind>,
        tokens: CodeTokens,
        tree: Tree<GoKind>,
    }

    impl Fixture {
        fn of(source: &[u8]) -> Self {
            let mut lexed = CodeTokens::reserve(4_096);
            let mut tokens = CodeTokens::reserve(4_096);
            let mut raw = BoundedVec::reserve(4_096);
            let mut events = Events::reserve(0x4000);
            let mut tree = Tree::reserve(4_096, 64);

            GO.lex(source, &mut lexed);

            assert!(classify(source, lexed.as_slice(), &mut tokens, &mut raw));

            parse::build(source, tokens.as_slice(), &raw, &mut events, &mut tree);

            Self { raw, tokens, tree }
        }

        fn view(&self, node: u32) -> View<'_> {
            View::new(&self.tree, self.tokens.as_slice(), &self.raw, node)
        }

        fn first(&self, kind: GoKind) -> View<'_> {
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
    fn a_function_reads_its_name_parameters_and_body() {
        const SOURCE: &[u8] =
            b"package held\n\nfunc run(one int, two string) int {\n\treturn one\n}\n";

        let fixture = Fixture::of(SOURCE);

        let held = fixture
            .first(GoKind::FuncDecl)
            .as_function()
            .expect("a function casts");

        assert!(held.receiver().is_none());
        assert_eq!(held.body().expect("a body").kind(), GoKind::BlockStmt);

        let position = held.name_token().expect("a name");

        assert_eq!(
            held.view().token_at(position).text(SOURCE),
            b"run".as_slice()
        );
    }

    #[test]
    fn a_method_reads_its_receiver() {
        const SOURCE: &[u8] = b"package held\n\nfunc (h *Held) run() {}\n";
        let fixture = Fixture::of(SOURCE);

        let held = fixture
            .first(GoKind::FuncDecl)
            .as_function()
            .expect("a function casts");

        assert_eq!(
            held.receiver().expect("a receiver").text(SOURCE),
            b"(h *Held)".as_slice()
        );
    }

    #[test]
    fn a_declaration_reads_its_specifications() {
        const SOURCE: &[u8] = b"package held\n\nvar one, two = 1, 2\n";
        let fixture = Fixture::of(SOURCE);

        let held = fixture
            .first(GoKind::GenDecl)
            .as_declaration()
            .expect("a declaration casts");

        assert_eq!(held.keyword(), Some(GoKind::VarKeyword));
        assert_eq!(held.specifications().count(), 1);

        let specification = held
            .specifications()
            .next()
            .expect("a specification")
            .as_specification()
            .expect("a specification casts");

        assert_eq!(specification.names().count(), 2);
        assert_eq!(specification.values().count(), 2);
    }

    #[test]
    fn a_field_reads_its_names_and_its_type() {
        const SOURCE: &[u8] = b"package held\n\ntype Held struct {\n\tone, two int `tag`\n}\n";
        let fixture = Fixture::of(SOURCE);

        let held = fixture
            .first(GoKind::Field)
            .as_field()
            .expect("a field casts");

        assert_eq!(held.names().count(), 2);

        assert_eq!(
            held.type_of().expect("a type").text(SOURCE),
            b"int".as_slice()
        );

        assert_eq!(held.tag().expect("a tag").text(SOURCE), b"`tag`".as_slice());
    }

    #[test]
    fn a_call_reads_its_callee_and_its_arguments() {
        const SOURCE: &[u8] = b"package held\n\nfunc run() {\n\tfmt.Println(one, two)\n}\n";
        let fixture = Fixture::of(SOURCE);

        let held = fixture
            .first(GoKind::CallExpr)
            .as_call()
            .expect("a call casts");

        assert_eq!(held.arguments().count(), 2);

        let position = held.name_token().expect("a name");

        assert_eq!(
            held.view().token_at(position).text(SOURCE),
            b"Println".as_slice()
        );
    }

    #[test]
    fn a_statement_reads_its_header_and_its_body() {
        const SOURCE: &[u8] = b"package held\n\nfunc run() {\n\tif one {\n\t\ttwo()\n\t}\n}\n";
        let fixture = Fixture::of(SOURCE);

        let held = fixture
            .first(GoKind::IfStmt)
            .as_statement()
            .expect("a statement casts");

        assert_eq!(held.header().expect("a header").text(SOURCE), b"one");
        assert_eq!(held.body().expect("a body").kind(), GoKind::BlockStmt);
    }

    #[test]
    fn a_switch_reads_its_clauses() {
        const SOURCE: &[u8] =
            b"package held\n\nfunc run(one int) {\n\tswitch one {\n\tcase 1:\n\tdefault:\n\t}\n}\n";

        let fixture = Fixture::of(SOURCE);

        let held = fixture
            .first(GoKind::SwitchStmt)
            .as_statement()
            .expect("a statement casts");

        assert_eq!(held.clauses().count(), 2);
    }

    #[test]
    fn an_operation_reads_its_operands() {
        const SOURCE: &[u8] = b"package held\n\nfunc run() {\n\tone := two + three\n}\n";
        let fixture = Fixture::of(SOURCE);

        let held = fixture
            .first(GoKind::BinaryExpr)
            .as_operation()
            .expect("an operation casts");

        assert_eq!(held.operands().count(), 2);
        assert_eq!(held.operator_tokens().count(), 1);
    }

    #[test]
    fn a_literal_names_its_class() {
        assert_eq!(literal_class(b"1"), Literal::Number);
        assert_eq!(literal_class(b"'c'"), Literal::Rune);
        assert_eq!(literal_class(b"\"held\""), Literal::Text);
        assert_eq!(literal_class(b"`held`"), Literal::Text);
    }
}
