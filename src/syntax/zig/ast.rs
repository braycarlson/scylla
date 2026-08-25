use crate::bounded::Span;
use crate::syntax::zig::kind::ZigKind;
use crate::token::Token;
use crate::tree::{NONE, Tree};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Literal {
    Character,
    Multiline,
    Number,
    Text,
}

#[derive(Clone, Copy, Debug)]
pub struct View<'run> {
    node: u32,
    raw: &'run [ZigKind],
    tokens: &'run [Token],
    tree: &'run Tree<ZigKind>,
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
    kind: Option<ZigKind>,
    raw: &'run [ZigKind],
    tokens: &'run [Token],
    tree: &'run Tree<ZigKind>,
}

#[derive(Clone, Debug)]
pub struct Positions<'run> {
    child: u32,
    kind: Option<ZigKind>,
    limit: u32,
    position: u32,
    raw: &'run [ZigKind],
    tree: &'run Tree<ZigKind>,
}

const CALLS: [ZigKind; 2] = [ZigKind::BuiltinCall, ZigKind::Call];
const CONTAINERS: [ZigKind; 2] = [ZigKind::ContainerDecl, ZigKind::TaggedUnion];
const FUNCTIONS: [ZigKind; 2] = [ZigKind::FnDecl, ZigKind::FnProto];

const OPERATIONS: [ZigKind; 8] = [
    ZigKind::AddressOf,
    ZigKind::BitNot,
    ZigKind::BoolNot,
    ZigKind::Catch,
    ZigKind::Negation,
    ZigKind::Orelse,
    ZigKind::Try,
    ZigKind::UnwrapOptional,
];

const STATEMENTS: [ZigKind; 8] = [
    ZigKind::Block,
    ZigKind::Defer,
    ZigKind::Errdefer,
    ZigKind::For,
    ZigKind::If,
    ZigKind::Switch,
    ZigKind::TestDecl,
    ZigKind::While,
];

impl<'run> View<'run> {
    pub fn new(
        tree: &'run Tree<ZigKind>,
        tokens: &'run [Token],
        raw: &'run [ZigKind],
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

    pub fn kind(self) -> ZigKind {
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

    pub fn children_of(self, kind: ZigKind) -> Children<'run> {
        self.children_of_kind(Some(kind))
    }

    fn children_of_kind(self, kind: Option<ZigKind>) -> Children<'run> {
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

    pub fn child_first_of(self, kind: ZigKind) -> Option<Self> {
        self.children_of(kind).next()
    }

    pub fn child_at(self, index: u32) -> Option<Self> {
        self.children().nth(index as usize)
    }

    pub fn positions(self) -> Positions<'run> {
        self.positions_of_kind(None)
    }

    pub fn positions_of(self, kind: ZigKind) -> Positions<'run> {
        self.positions_of_kind(Some(kind))
    }

    fn positions_of_kind(self, kind: Option<ZigKind>) -> Positions<'run> {
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

    pub fn token_kind(self, position: u32) -> ZigKind {
        self.raw[position as usize]
    }

    pub fn token_first(self, kind: ZigKind) -> Option<u32> {
        self.positions_of(kind).next()
    }

    pub fn holds(self, kind: ZigKind) -> bool {
        self.positions_of(kind).next().is_some()
    }

    fn cast(self, kinds: &[ZigKind]) -> Option<Self> {
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
        self.cast(&[ZigKind::VarDecl]).map(Declaration)
    }

    pub fn as_field(self) -> Option<Field<'run>> {
        self.cast(&[ZigKind::ContainerField]).map(Field)
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
        if self.0.kind() == ZigKind::BuiltinCall {
            return None;
        }

        self.0.child_first()
    }

    pub fn name_token(self) -> Option<u32> {
        if self.0.kind() == ZigKind::BuiltinCall {
            return self.0.token_first(ZigKind::Builtin);
        }

        let callee = self.callee()?;

        if callee.kind() == ZigKind::FieldAccess {
            return callee.positions_of(ZigKind::Identifier).last();
        }

        callee.positions_of(ZigKind::Identifier).next()
    }

    pub fn arguments(self) -> impl Iterator<Item = View<'run>> {
        let skipped = usize::from(self.0.kind() == ZigKind::Call);

        self.0.children().skip(skipped)
    }
}

impl<'run> Container<'run> {
    pub fn view(self) -> View<'run> {
        self.0
    }

    pub fn keyword(self) -> Option<ZigKind> {
        let position = self.0.positions().next()?;

        Some(self.0.token_kind(position))
    }

    pub fn is_tagged(self) -> bool {
        self.0.kind() == ZigKind::TaggedUnion
    }

    pub fn fields(self) -> Children<'run> {
        self.0.children_of(ZigKind::ContainerField)
    }

    pub fn declarations(self) -> Children<'run> {
        self.0.children_of(ZigKind::VarDecl)
    }

    pub fn functions(self) -> Children<'run> {
        self.0.children_of(ZigKind::FnDecl)
    }
}

impl<'run> Declaration<'run> {
    pub fn view(self) -> View<'run> {
        self.0
    }

    pub fn is_mutable(self) -> bool {
        self.0.holds(ZigKind::VarKeyword)
    }

    pub fn is_public(self) -> bool {
        self.0.holds(ZigKind::PubKeyword)
    }

    pub fn name_token(self) -> Option<u32> {
        self.0.token_first(ZigKind::Identifier)
    }

    pub fn type_of(self) -> Option<View<'run>> {
        let held = self.0.token_first(ZigKind::Colon)?;

        self.0.children().find(|child| {
            child.tree.at(child.node).token_start > held
                && child.tree.at(child.node).token_end <= self.value_start()
        })
    }

    fn value_start(self) -> u32 {
        self.0
            .token_first(ZigKind::Equal)
            .unwrap_or_else(|| self.0.tree.at(self.0.node).token_end)
    }

    pub fn value(self) -> Option<View<'run>> {
        let held = self.0.token_first(ZigKind::Equal)?;

        self.0
            .children()
            .find(|child| child.tree.at(child.node).token_start > held)
    }
}

impl<'run> Field<'run> {
    pub fn view(self) -> View<'run> {
        self.0
    }

    pub fn name_token(self) -> Option<u32> {
        self.0.token_first(ZigKind::Identifier)
    }

    pub fn is_named(self) -> bool {
        self.0.holds(ZigKind::Colon)
    }

    pub fn type_of(self) -> Option<View<'run>> {
        self.0.child_first()
    }

    pub fn value(self) -> Option<View<'run>> {
        let held = self.0.token_first(ZigKind::Equal)?;

        self.0
            .children()
            .find(|child| child.tree.at(child.node).token_start > held)
    }
}

impl<'run> Function<'run> {
    pub fn view(self) -> View<'run> {
        self.0
    }

    pub fn prototype(self) -> Option<View<'run>> {
        if self.0.kind() == ZigKind::FnProto {
            return Some(self.0);
        }

        self.0.child_first_of(ZigKind::FnProto)
    }

    pub fn name_token(self) -> Option<u32> {
        self.prototype()?.token_first(ZigKind::Identifier)
    }

    pub fn is_public(self) -> bool {
        self.prototype()
            .is_some_and(|held| held.holds(ZigKind::PubKeyword))
    }

    pub fn is_extern(self) -> bool {
        self.prototype()
            .is_some_and(|held| held.holds(ZigKind::ExternKeyword))
    }

    pub fn parameters(self) -> impl Iterator<Item = View<'run>> {
        let prototype = self.prototype();
        let closing = prototype.and_then(|held| held.token_first(ZigKind::ParenClose));

        prototype.into_iter().flat_map(move |held| {
            held.children().filter(move |child| {
                closing.is_some_and(|stop| child.tree.at(child.node).token_end <= stop)
            })
        })
    }

    pub fn returns(self) -> Option<View<'run>> {
        let prototype = self.prototype()?;
        let closing = prototype.token_first(ZigKind::ParenClose)?;

        prototype
            .children()
            .find(|child| child.tree.at(child.node).token_start > closing)
    }

    pub fn body(self) -> Option<View<'run>> {
        self.0.child_first_of(ZigKind::Block)
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
        self.0.children_of(ZigKind::Block).last()
    }

    pub fn statements(self) -> impl Iterator<Item = View<'run>> {
        if self.0.kind() == ZigKind::Block {
            return Children {
                current: self.0.tree.at(self.0.node).child_first,
                kind: None,
                raw: self.0.raw,
                tokens: self.0.tokens,
                tree: self.0.tree,
            };
        }

        self.body().map_or(
            Children {
                current: NONE,
                kind: None,
                raw: self.0.raw,
                tokens: self.0.tokens,
                tree: self.0.tree,
            },
            View::children,
        )
    }

    pub fn cases(self) -> Children<'run> {
        self.0.children_of(ZigKind::SwitchCase)
    }
}

pub fn literal_class(text: &[u8]) -> Literal {
    match text.first() {
        Some(b'\'') => Literal::Character,
        Some(b'"') => Literal::Text,
        Some(b'\\') => Literal::Multiline,
        _ => Literal::Number,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::bounded::BoundedVec;
    use crate::language::Lexer as _;
    use crate::lex::ZIG;
    use crate::syntax::zig::classify::classify;
    use crate::syntax::zig::parse;
    use crate::token::Tokens as CodeTokens;
    use crate::tree::Events;

    struct Fixture {
        raw: BoundedVec<ZigKind>,
        tokens: CodeTokens,
        tree: Tree<ZigKind>,
    }

    impl Fixture {
        fn of(source: &[u8]) -> Self {
            let mut lexed = CodeTokens::reserve(4_096);
            let mut tokens = CodeTokens::reserve(4_096);
            let mut raw = BoundedVec::reserve(4_096);
            let mut events = Events::reserve(0x4000);
            let mut tree = Tree::reserve(4_096, 64);

            ZIG.lex(source, &mut lexed);

            assert!(classify(source, lexed.as_slice(), &mut tokens, &mut raw));

            parse::build(source, tokens.as_slice(), &raw, &mut events, &mut tree);

            Self { raw, tokens, tree }
        }

        fn view(&self, node: u32) -> View<'_> {
            View::new(&self.tree, self.tokens.as_slice(), &self.raw, node)
        }

        fn first(&self, kind: ZigKind) -> View<'_> {
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
        const SOURCE: &[u8] = b"pub fn run(one: u32, two: []const u8) u32 {\n    return one;\n}\n";
        let fixture = Fixture::of(SOURCE);

        let held = fixture
            .first(ZigKind::FnDecl)
            .as_function()
            .expect("a function casts");

        assert!(held.is_public());
        assert!(!held.is_extern());
        assert_eq!(held.parameters().count(), 2);

        assert_eq!(
            held.returns().expect("a return type").text(SOURCE),
            b"u32".as_slice()
        );

        assert_eq!(held.body().expect("a body").kind(), ZigKind::Block);

        let position = held.name_token().expect("a name");

        assert_eq!(
            held.view().token_at(position).text(SOURCE),
            b"run".as_slice()
        );
    }

    #[test]
    fn a_declaration_reads_its_type_and_its_value() {
        const SOURCE: &[u8] = b"pub var held: u32 = 1;\n";
        let fixture = Fixture::of(SOURCE);

        let held = fixture
            .first(ZigKind::VarDecl)
            .as_declaration()
            .expect("a declaration casts");

        assert!(held.is_mutable());
        assert!(held.is_public());

        assert_eq!(
            held.type_of().expect("a type").text(SOURCE),
            b"u32".as_slice()
        );

        assert_eq!(held.value().expect("a value").text(SOURCE), b"1".as_slice());

        let position = held.name_token().expect("a name");

        assert_eq!(
            held.view().token_at(position).text(SOURCE),
            b"held".as_slice()
        );
    }

    #[test]
    fn a_container_reads_its_fields_and_its_functions() {
        const SOURCE: &[u8] =
            b"const Held = struct {\n    one: u32 = 0,\n    fn run() void {}\n};\n";

        let fixture = Fixture::of(SOURCE);

        let held = fixture
            .first(ZigKind::ContainerDecl)
            .as_container()
            .expect("a container casts");

        assert!(!held.is_tagged());
        assert_eq!(held.keyword(), Some(ZigKind::StructKeyword));
        assert_eq!(held.fields().count(), 1);
        assert_eq!(held.functions().count(), 1);

        let field = held
            .fields()
            .next()
            .expect("a field")
            .as_field()
            .expect("a field casts");

        assert!(field.is_named());

        assert_eq!(
            field.type_of().expect("a type").text(SOURCE),
            b"u32".as_slice()
        );

        assert_eq!(
            field.value().expect("a value").text(SOURCE),
            b"0".as_slice()
        );
    }

    #[test]
    fn a_call_reads_its_callee_and_its_arguments() {
        const SOURCE: &[u8] = b"fn run() void {\n    std.debug.print(one, two);\n}\n";
        let fixture = Fixture::of(SOURCE);

        let held = fixture
            .first(ZigKind::Call)
            .as_call()
            .expect("a call casts");

        assert_eq!(held.arguments().count(), 2);

        let position = held.name_token().expect("a name");

        assert_eq!(
            held.view().token_at(position).text(SOURCE),
            b"print".as_slice()
        );
    }

    #[test]
    fn a_builtin_call_names_itself() {
        const SOURCE: &[u8] = b"const held = @import(\"std\");\n";
        let fixture = Fixture::of(SOURCE);

        let held = fixture
            .first(ZigKind::BuiltinCall)
            .as_call()
            .expect("a call casts");

        assert!(held.callee().is_none());
        assert_eq!(held.arguments().count(), 1);

        let position = held.name_token().expect("a name");

        assert_eq!(
            held.view().token_at(position).text(SOURCE),
            b"@import".as_slice()
        );
    }

    #[test]
    fn a_statement_reads_its_body_and_its_cases() {
        const SOURCE: &[u8] =
            b"fn run(one: u32) void {\nswitch (one) {\n0 => {},\nelse => {},\n}\n}\n";

        let fixture = Fixture::of(SOURCE);

        let held = fixture
            .first(ZigKind::Switch)
            .as_statement()
            .expect("a statement casts");

        assert_eq!(held.cases().count(), 2);
        assert_eq!(held.header().expect("a header").text(SOURCE), b"one");
    }

    #[test]
    fn a_block_reads_its_statements() {
        const SOURCE: &[u8] = b"fn run() void {\n    one();\n    two();\n}\n";
        let fixture = Fixture::of(SOURCE);

        let held = fixture
            .first(ZigKind::Block)
            .as_statement()
            .expect("a statement casts");

        assert_eq!(held.statements().count(), 2);
    }

    #[test]
    fn an_operation_reads_its_operands() {
        const SOURCE: &[u8] =
            b"fn run() void {\n    const held = one orelse two;\n    _ = held;\n}\n";

        let fixture = Fixture::of(SOURCE);

        let held = fixture
            .first(ZigKind::Orelse)
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
        assert_eq!(literal_class(b"\\\\held"), Literal::Multiline);
    }
}
