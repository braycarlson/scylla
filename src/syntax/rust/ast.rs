use crate::bounded::Span;
use crate::syntax::rust::kind::RustKind;
use crate::token::Token;
use crate::tree::{NONE, Tree};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Literal {
    Boolean,
    Byte,
    ByteString,
    CString,
    Character,
    Float,
    Integer,
    Text,
}

#[derive(Clone, Copy, Debug)]
pub struct View<'run> {
    node: u32,
    raw: &'run [RustKind],
    tokens: &'run [Token],
    tree: &'run Tree<RustKind>,
}

#[derive(Clone, Copy, Debug)]
pub struct Call<'run>(View<'run>);

#[derive(Clone, Copy, Debug)]
pub struct Constant<'run>(View<'run>);

#[derive(Clone, Copy, Debug)]
pub struct Definition<'run>(View<'run>);

#[derive(Clone, Copy, Debug)]
pub struct Field<'run>(View<'run>);

#[derive(Clone, Copy, Debug)]
pub struct Function<'run>(View<'run>);

#[derive(Clone, Copy, Debug)]
pub struct Local<'run>(View<'run>);

#[derive(Clone, Copy, Debug)]
pub struct Operation<'run>(View<'run>);

#[derive(Clone, Copy, Debug)]
pub struct PathView<'run>(View<'run>);

#[derive(Clone, Copy, Debug)]
pub struct Statement<'run>(View<'run>);

#[derive(Clone, Copy, Debug)]
pub struct Use<'run>(View<'run>);

#[derive(Clone, Debug)]
pub struct Children<'run> {
    current: u32,
    kind: Option<RustKind>,
    raw: &'run [RustKind],
    tokens: &'run [Token],
    tree: &'run Tree<RustKind>,
}

#[derive(Clone, Debug)]
pub struct Positions<'run> {
    child: u32,
    kind: Option<RustKind>,
    limit: u32,
    position: u32,
    raw: &'run [RustKind],
    tree: &'run Tree<RustKind>,
}

const CALLS: [RustKind; 3] = [
    RustKind::ExprCall,
    RustKind::ExprMacro,
    RustKind::ExprMethodCall,
];

const CONSTANTS: [RustKind; 8] = [
    RustKind::LitBool,
    RustKind::LitByte,
    RustKind::LitByteStr,
    RustKind::LitCStr,
    RustKind::LitChar,
    RustKind::LitFloat,
    RustKind::LitInt,
    RustKind::LitStr,
];

const DEFINITIONS: [RustKind; 6] = [
    RustKind::ItemEnum,
    RustKind::ItemImpl,
    RustKind::ItemStruct,
    RustKind::ItemTrait,
    RustKind::ItemType,
    RustKind::ItemUnion,
];

const FIELDS: [RustKind; 2] = [RustKind::Field, RustKind::Variant];

const FUNCTIONS: [RustKind; 5] = [
    RustKind::ExprClosure,
    RustKind::ForeignItemFn,
    RustKind::ImplItemFn,
    RustKind::ItemFn,
    RustKind::TraitItemFn,
];

const OPERATIONS: [RustKind; 5] = [
    RustKind::ExprAssign,
    RustKind::ExprBinary,
    RustKind::ExprCast,
    RustKind::ExprRange,
    RustKind::ExprUnary,
];

const STATEMENTS: [RustKind; 6] = [
    RustKind::ExprForLoop,
    RustKind::ExprIf,
    RustKind::ExprLoop,
    RustKind::ExprMatch,
    RustKind::ExprUnsafe,
    RustKind::ExprWhile,
];

impl<'run> View<'run> {
    pub fn new(
        tree: &'run Tree<RustKind>,
        tokens: &'run [Token],
        raw: &'run [RustKind],
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

    pub fn token_end(self) -> u32 {
        self.tree.at(self.node).token_end
    }

    pub fn kind(self) -> RustKind {
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

    pub fn children_of(self, kind: RustKind) -> Children<'run> {
        self.children_of_kind(Some(kind))
    }

    fn children_of_kind(self, kind: Option<RustKind>) -> Children<'run> {
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

    pub fn child_first_of(self, kind: RustKind) -> Option<Self> {
        self.children_of(kind).next()
    }

    pub fn child_at(self, index: u32) -> Option<Self> {
        self.children().nth(index as usize)
    }

    pub fn positions(self) -> Positions<'run> {
        self.positions_of_kind(None)
    }

    pub fn positions_of(self, kind: RustKind) -> Positions<'run> {
        self.positions_of_kind(Some(kind))
    }

    fn positions_of_kind(self, kind: Option<RustKind>) -> Positions<'run> {
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

    pub fn token_kind(self, position: u32) -> RustKind {
        self.raw[position as usize]
    }

    pub fn token_first(self, kind: RustKind) -> Option<u32> {
        self.positions_of(kind).next()
    }

    pub fn token_start(self) -> u32 {
        self.tree.at(self.node).token_start
    }

    pub fn holds(self, kind: RustKind) -> bool {
        self.positions_of(kind).next().is_some()
    }

    fn cast(self, kinds: &[RustKind]) -> Option<Self> {
        if kinds.contains(&self.kind()) {
            return Some(self);
        }

        None
    }

    pub fn as_call(self) -> Option<Call<'run>> {
        self.cast(&CALLS).map(Call)
    }

    pub fn as_constant(self) -> Option<Constant<'run>> {
        self.cast(&CONSTANTS).map(Constant)
    }

    pub fn as_definition(self) -> Option<Definition<'run>> {
        self.cast(&DEFINITIONS).map(Definition)
    }

    pub fn as_field(self) -> Option<Field<'run>> {
        self.cast(&FIELDS).map(Field)
    }

    pub fn as_function(self) -> Option<Function<'run>> {
        self.cast(&FUNCTIONS).map(Function)
    }

    pub fn as_local(self) -> Option<Local<'run>> {
        self.cast(&[RustKind::Local]).map(Local)
    }

    pub fn as_operation(self) -> Option<Operation<'run>> {
        self.cast(&OPERATIONS).map(Operation)
    }

    pub fn as_path(self) -> Option<PathView<'run>> {
        self.cast(&[RustKind::Path]).map(PathView)
    }

    pub fn as_statement(self) -> Option<Statement<'run>> {
        self.cast(&STATEMENTS).map(Statement)
    }

    pub fn as_use(self) -> Option<Use<'run>> {
        self.cast(&[RustKind::ItemUse]).map(Use)
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
        if self.0.kind() == RustKind::ExprMethodCall {
            let held = self.0.children_of(RustKind::Ident).next()?;

            return held.positions().next();
        }

        let callee = self.callee()?;
        let path = callee.children_of(RustKind::Path).next()?;
        let segment = path.children_of(RustKind::PathSegment).last()?;
        let held = segment.children_of(RustKind::Ident).next()?;

        held.positions().next()
    }

    pub fn arguments(self) -> impl Iterator<Item = View<'run>> {
        let held = self.0;
        let first = u32::from(held.kind() != RustKind::ExprMacro);

        held.children().skip(first as usize)
    }
}

impl<'run> Constant<'run> {
    pub fn view(self) -> View<'run> {
        self.0
    }

    pub fn literal_class(self) -> Literal {
        let kind = self.0.kind();

        if kind == RustKind::LitBool {
            return Literal::Boolean;
        }

        if kind == RustKind::LitByte {
            return Literal::Byte;
        }

        if kind == RustKind::LitByteStr {
            return Literal::ByteString;
        }

        if kind == RustKind::LitCStr {
            return Literal::CString;
        }

        if kind == RustKind::LitChar {
            return Literal::Character;
        }

        if kind == RustKind::LitFloat {
            return Literal::Float;
        }

        if kind == RustKind::LitInt {
            return Literal::Integer;
        }

        Literal::Text
    }
}

impl<'run> Definition<'run> {
    pub fn view(self) -> View<'run> {
        self.0
    }

    pub fn name_token(self) -> Option<u32> {
        let held = self.0.children_of(RustKind::Ident).next()?;

        held.positions().next()
    }

    pub fn generics(self) -> Option<View<'run>> {
        self.0.child_first_of(RustKind::Generics)
    }

    pub fn where_clause(self) -> Option<View<'run>> {
        self.0.child_first_of(RustKind::WhereClause)
    }

    pub fn fields(self) -> impl Iterator<Item = View<'run>> {
        self.0
            .children()
            .filter(|held| matches!(held.kind(), RustKind::FieldsNamed | RustKind::FieldsUnnamed))
            .flat_map(View::children)
    }

    pub fn variants(self) -> Children<'run> {
        self.0.children_of(RustKind::Variant)
    }

    pub fn members(self) -> impl Iterator<Item = View<'run>> {
        self.0.children().filter(|held| {
            matches!(
                held.kind(),
                RustKind::ImplItemConst
                    | RustKind::ImplItemFn
                    | RustKind::ImplItemType
                    | RustKind::TraitItemConst
                    | RustKind::TraitItemFn
                    | RustKind::TraitItemType
            )
        })
    }
}

impl<'run> Field<'run> {
    pub fn view(self) -> View<'run> {
        self.0
    }

    pub fn name_token(self) -> Option<u32> {
        let held = self.0.children_of(RustKind::Ident).next()?;

        held.positions().next()
    }

    pub fn attributes(self) -> Children<'run> {
        self.0.children_of(RustKind::Attribute)
    }

    pub fn type_of(self) -> Option<View<'run>> {
        self.0
            .children()
            .find(|held| held.kind().name().starts_with("Type"))
    }
}

impl<'run> Function<'run> {
    pub fn view(self) -> View<'run> {
        self.0
    }

    pub fn signature(self) -> Option<View<'run>> {
        self.0.child_first_of(RustKind::Signature)
    }

    pub fn is_async(self) -> bool {
        self.holds(RustKind::AsyncKeyword)
    }

    pub fn is_const(self) -> bool {
        self.holds(RustKind::ConstKeyword)
    }

    pub fn is_unsafe(self) -> bool {
        self.holds(RustKind::UnsafeKeyword)
    }

    fn holds(self, kind: RustKind) -> bool {
        self.signature()
            .is_some_and(|held| held.positions_of(kind).next().is_some())
    }

    pub fn name_token(self) -> Option<u32> {
        let signature = self.signature()?;
        let held = signature.children_of(RustKind::Ident).next()?;

        held.positions().next()
    }

    pub fn parameters(self) -> impl Iterator<Item = View<'run>> {
        self.signature().into_iter().flat_map(|held| {
            held.children()
                .filter(|child| matches!(child.kind(), RustKind::PatType | RustKind::Receiver))
        })
    }

    pub fn body(self) -> Option<View<'run>> {
        self.0.child_first_of(RustKind::Block)
    }

    pub fn attributes(self) -> Children<'run> {
        self.0.children_of(RustKind::Attribute)
    }
}

impl<'run> Local<'run> {
    pub fn view(self) -> View<'run> {
        self.0
    }

    pub fn target(self) -> Option<View<'run>> {
        self.0
            .children()
            .find(|held| held.kind() != RustKind::Attribute)
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

impl<'run> PathView<'run> {
    pub fn view(self) -> View<'run> {
        self.0
    }

    pub fn segments(self) -> Children<'run> {
        self.0.children_of(RustKind::PathSegment)
    }

    pub fn is_rooted(self) -> bool {
        self.0.positions_of(RustKind::ColonColon).next() == Some(self.0.token_start())
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
        self.0.children_of(RustKind::Block).next()
    }

    pub fn arms(self) -> Children<'run> {
        self.0.children_of(RustKind::Arm)
    }
}

impl<'run> Use<'run> {
    pub fn view(self) -> View<'run> {
        self.0
    }

    pub fn tree(self) -> Option<View<'run>> {
        self.0
            .children()
            .find(|held| held.kind() != RustKind::Attribute)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::bounded::BoundedVec;
    use crate::language::Lexer as _;
    use crate::lex::RUST;
    use crate::syntax::rust::classify::classify;
    use crate::syntax::rust::parse;
    use crate::token::Tokens as CodeTokens;
    use crate::tree::Events;

    struct Fixture {
        raw: BoundedVec<RustKind>,
        tokens: CodeTokens,
        tree: Tree<RustKind>,
    }

    impl Fixture {
        fn of(source: &[u8]) -> Self {
            let mut lexed = CodeTokens::reserve(4_096);
            let mut tokens = CodeTokens::reserve(4_096);
            let mut raw = BoundedVec::reserve(4_096);
            let mut events = Events::reserve(0x4000);
            let mut tree = Tree::reserve(4_096, 64);

            RUST.lex(source, &mut lexed);

            assert!(classify(source, lexed.as_slice(), &mut tokens, &mut raw));

            parse::build(source, tokens.as_slice(), &raw, &mut events, &mut tree);

            Self { raw, tokens, tree }
        }

        fn view(&self, node: u32) -> View<'_> {
            View::new(&self.tree, self.tokens.as_slice(), &self.raw, node)
        }

        fn first(&self, kind: RustKind) -> View<'_> {
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
        const SOURCE: &[u8] = b"pub async unsafe fn run(one: u32, two: &str) -> u32 { one }\n";
        let fixture = Fixture::of(SOURCE);

        let held = fixture
            .first(RustKind::ItemFn)
            .as_function()
            .expect("a function casts");

        assert!(held.is_async());
        assert!(held.is_unsafe());
        assert!(!held.is_const());
        assert_eq!(held.parameters().count(), 2);
        assert_eq!(held.body().expect("a body").kind(), RustKind::Block);

        let position = held.name_token().expect("a name");

        assert_eq!(
            held.view().token_at(position).text(SOURCE),
            b"run".as_slice()
        );
    }

    #[test]
    fn a_struct_reads_its_name_and_its_fields() {
        const SOURCE: &[u8] = b"pub struct Widget<T> { pub one: u32, two: T }\n";
        let fixture = Fixture::of(SOURCE);

        let held = fixture
            .first(RustKind::ItemStruct)
            .as_definition()
            .expect("a definition casts");

        assert_eq!(held.fields().count(), 2);
        assert!(held.generics().is_some());

        let position = held.name_token().expect("a name");

        assert_eq!(
            held.view().token_at(position).text(SOURCE),
            b"Widget".as_slice()
        );
    }

    #[test]
    fn an_impl_reads_its_members() {
        const SOURCE: &[u8] = b"impl Widget { const ONE: u32 = 1; fn run(&self) {} }\n";
        let fixture = Fixture::of(SOURCE);

        let held = fixture
            .first(RustKind::ItemImpl)
            .as_definition()
            .expect("a definition casts");

        assert_eq!(held.members().count(), 2);
    }

    #[test]
    fn a_call_reads_its_callee_and_its_arguments() {
        const SOURCE: &[u8] = b"fn run() { helper(one, two); }\n";
        let fixture = Fixture::of(SOURCE);

        let held = fixture
            .first(RustKind::ExprCall)
            .as_call()
            .expect("a call casts");

        assert_eq!(held.arguments().count(), 2);

        let position = held.name_token().expect("a name");

        assert_eq!(
            held.view().token_at(position).text(SOURCE),
            b"helper".as_slice()
        );
    }

    #[test]
    fn a_method_call_names_itself() {
        const SOURCE: &[u8] = b"fn run() { value.method(one); }\n";
        let fixture = Fixture::of(SOURCE);

        let held = fixture
            .first(RustKind::ExprMethodCall)
            .as_call()
            .expect("a call casts");

        let position = held.name_token().expect("a name");

        assert_eq!(
            held.view().token_at(position).text(SOURCE),
            b"method".as_slice()
        );
    }

    #[test]
    fn a_local_reads_its_target_and_its_value() {
        const SOURCE: &[u8] = b"fn run() { let one: u32 = 1; }\n";
        let fixture = Fixture::of(SOURCE);

        let held = fixture
            .first(RustKind::Local)
            .as_local()
            .expect("a local casts");

        assert_eq!(held.target().expect("a target").kind(), RustKind::PatType);
        assert_eq!(held.value().expect("a value").text(SOURCE), b"1".as_slice());
    }

    #[test]
    fn a_constant_reads_its_class() {
        const SOURCE: &[u8] = b"const ONE: f32 = 1.5;\n";
        let fixture = Fixture::of(SOURCE);

        let held = fixture
            .first(RustKind::LitFloat)
            .as_constant()
            .expect("a constant casts");

        assert_eq!(held.literal_class(), Literal::Float);
    }

    #[test]
    fn a_path_reads_its_segments() {
        const SOURCE: &[u8] = b"fn run() { ::std::mem::drop(one); }\n";
        let fixture = Fixture::of(SOURCE);

        let held = fixture
            .first(RustKind::Path)
            .as_path()
            .expect("a path casts");

        assert_eq!(held.segments().count(), 3);
        assert!(held.is_rooted());
    }

    #[test]
    fn a_match_reads_its_arms() {
        const SOURCE: &[u8] = b"fn run() { match one { 1 => 2, _ => 3 } }\n";
        let fixture = Fixture::of(SOURCE);

        let held = fixture
            .first(RustKind::ExprMatch)
            .as_statement()
            .expect("a statement casts");

        assert_eq!(held.arms().count(), 2);
    }

    #[test]
    fn a_use_reads_its_tree() {
        const SOURCE: &[u8] = b"use std::collections::HashMap;\n";
        let fixture = Fixture::of(SOURCE);

        let held = fixture
            .first(RustKind::ItemUse)
            .as_use()
            .expect("a use casts");

        assert_eq!(held.tree().expect("a tree").kind(), RustKind::UsePath);
    }

    #[test]
    fn an_operation_reads_its_operands() {
        const SOURCE: &[u8] = b"fn run() { let held = one + two; }\n";
        let fixture = Fixture::of(SOURCE);

        let held = fixture
            .first(RustKind::ExprBinary)
            .as_operation()
            .expect("an operation casts");

        assert_eq!(held.operands().count(), 2);
        assert_eq!(held.operator_tokens().count(), 1);
    }
}
