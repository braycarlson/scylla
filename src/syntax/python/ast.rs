use crate::bounded::{BoundedVec, Span};
use crate::syntax::python::kind::PythonKind;
use crate::syntax::python::literal;
use crate::token::Token;
use crate::tree::{NONE, Tree};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Literal {
    Boolean,
    Bytes,
    Ellipsis,
    None,
    Number,
    Text,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Parameter {
    Keyword,
    KeywordRest,
    Positional,
    PositionalOnly,
    PositionalRest,
}

#[derive(Clone, Copy, Debug)]
pub struct View<'run> {
    node: u32,
    raw: &'run [PythonKind],
    tokens: &'run [Token],
    tree: &'run Tree<PythonKind>,
}

#[derive(Clone, Copy, Debug)]
pub struct Alias<'run>(View<'run>);

#[derive(Clone, Copy, Debug)]
pub struct Arg<'run>(View<'run>);

#[derive(Clone, Copy, Debug)]
pub struct Assign<'run>(View<'run>);

#[derive(Clone, Copy, Debug)]
pub struct Call<'run>(View<'run>);

#[derive(Clone, Copy, Debug)]
pub struct ClassDef<'run>(View<'run>);

#[derive(Clone, Copy, Debug)]
pub struct Constant<'run>(View<'run>);

#[derive(Clone, Copy, Debug)]
pub struct FunctionDef<'run>(View<'run>);

#[derive(Clone, Copy, Debug)]
pub struct Import<'run>(View<'run>);

#[derive(Clone, Copy, Debug)]
pub struct Keyword<'run>(View<'run>);

#[derive(Clone, Copy, Debug)]
pub struct Operation<'run>(View<'run>);

#[derive(Clone, Copy, Debug)]
pub struct Statement<'run>(View<'run>);

#[derive(Clone, Debug)]
pub struct Children<'run> {
    current: u32,
    kind: Option<PythonKind>,
    raw: &'run [PythonKind],
    tokens: &'run [Token],
    tree: &'run Tree<PythonKind>,
}

#[derive(Clone, Debug)]
pub struct Positions<'run> {
    child: u32,
    kind: Option<PythonKind>,
    limit: u32,
    position: u32,
    raw: &'run [PythonKind],
    tree: &'run Tree<PythonKind>,
}

const DEFINITIONS: [PythonKind; 2] = [PythonKind::AsyncFunctionDef, PythonKind::FunctionDef];
const IMPORTS: [PythonKind; 2] = [PythonKind::Import, PythonKind::ImportFrom];

const OPERATIONS: [PythonKind; 4] = [
    PythonKind::BinOp,
    PythonKind::BoolOp,
    PythonKind::Compare,
    PythonKind::UnaryOp,
];

const STATEMENTS: [PythonKind; 12] = [
    PythonKind::AsyncFor,
    PythonKind::AsyncWith,
    PythonKind::Delete,
    PythonKind::For,
    PythonKind::If,
    PythonKind::Match,
    PythonKind::Raise,
    PythonKind::Return,
    PythonKind::Try,
    PythonKind::TryStar,
    PythonKind::While,
    PythonKind::With,
];

const TARGETS: [PythonKind; 3] = [
    PythonKind::AnnAssign,
    PythonKind::Assign,
    PythonKind::AugAssign,
];

impl<'run> View<'run> {
    pub fn new(
        tree: &'run Tree<PythonKind>,
        tokens: &'run [Token],
        raw: &'run [PythonKind],
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

    pub fn tree(self) -> &'run Tree<PythonKind> {
        self.tree
    }

    pub fn kind(self) -> PythonKind {
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

    pub fn children_of(self, kind: PythonKind) -> Children<'run> {
        self.children_of_kind(Some(kind))
    }

    fn children_of_kind(self, kind: Option<PythonKind>) -> Children<'run> {
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

    pub fn child_first_of(self, kind: PythonKind) -> Option<Self> {
        self.children_of(kind).next()
    }

    pub fn child_at(self, index: u32) -> Option<Self> {
        self.children().nth(index as usize)
    }

    pub fn positions(self) -> Positions<'run> {
        self.positions_of_kind(None)
    }

    pub fn positions_of(self, kind: PythonKind) -> Positions<'run> {
        self.positions_of_kind(Some(kind))
    }

    fn positions_of_kind(self, kind: Option<PythonKind>) -> Positions<'run> {
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

    pub fn token_kind(self, position: u32) -> PythonKind {
        self.raw[position as usize]
    }

    pub fn token_first(self, kind: PythonKind) -> Option<u32> {
        self.positions_of(kind).next()
    }

    fn cast(self, kinds: &[PythonKind]) -> Option<Self> {
        if kinds.contains(&self.kind()) {
            return Some(self);
        }

        None
    }

    pub fn as_alias(self) -> Option<Alias<'run>> {
        self.cast(&[PythonKind::Alias]).map(Alias)
    }

    pub fn as_argument(self) -> Option<Arg<'run>> {
        self.cast(&[PythonKind::Arg]).map(Arg)
    }

    pub fn as_assign(self) -> Option<Assign<'run>> {
        self.cast(&TARGETS).map(Assign)
    }

    pub fn as_call(self) -> Option<Call<'run>> {
        self.cast(&[PythonKind::Call]).map(Call)
    }

    pub fn as_class(self) -> Option<ClassDef<'run>> {
        self.cast(&[PythonKind::ClassDef]).map(ClassDef)
    }

    pub fn as_constant(self) -> Option<Constant<'run>> {
        self.cast(&[PythonKind::Constant]).map(Constant)
    }

    pub fn as_function(self) -> Option<FunctionDef<'run>> {
        self.cast(&DEFINITIONS).map(FunctionDef)
    }

    pub fn as_import(self) -> Option<Import<'run>> {
        self.cast(&IMPORTS).map(Import)
    }

    pub fn as_keyword(self) -> Option<Keyword<'run>> {
        self.cast(&[PythonKind::Keyword]).map(Keyword)
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

impl<'run> Alias<'run> {
    pub fn view(self) -> View<'run> {
        self.0
    }

    pub fn asname_token(self) -> Option<u32> {
        let mut found = None;
        let mut seen = false;

        for position in self.0.positions() {
            if seen {
                return Some(position);
            }

            if self.0.token_kind(position) == PythonKind::AsKeyword {
                seen = true;
            }

            found = None;
        }

        found
    }

    pub fn name_segments(self, out: &mut BoundedVec<Span>) -> bool {
        for position in self.0.positions_of(PythonKind::Identifier) {
            if self.0.token_kind(position) != PythonKind::Identifier {
                continue;
            }

            if self.asname_token().is_some_and(|asname| position >= asname) {
                break;
            }

            if !out.push(self.0.token_at(position).span()) {
                return false;
            }
        }

        true
    }
}

impl<'run> Arg<'run> {
    pub fn view(self) -> View<'run> {
        self.0
    }

    pub fn name_token(self) -> Option<u32> {
        self.0.token_first(PythonKind::Identifier)
    }

    pub fn annotation(self) -> Option<View<'run>> {
        self.0.child_first()
    }

    pub fn default(self) -> Option<View<'run>> {
        let sibling = self.0.tree.at(self.0.node).sibling_next;

        if sibling == NONE {
            return None;
        }

        let held = self.0.at(sibling);

        if held.kind() == PythonKind::Arg {
            return None;
        }

        Some(held)
    }
}

impl<'run> Assign<'run> {
    pub fn view(self) -> View<'run> {
        self.0
    }

    pub fn kind(self) -> PythonKind {
        self.0.kind()
    }

    pub fn operator_token(self) -> Option<u32> {
        self.0.positions().next()
    }

    pub fn targets(self) -> impl Iterator<Item = View<'run>> {
        let held = self.0;

        let count = if held.kind() == PythonKind::Assign {
            held.children().count().saturating_sub(1)
        } else {
            1
        };

        held.children().take(count)
    }

    pub fn value(self) -> Option<View<'run>> {
        if self.0.kind() == PythonKind::AnnAssign && self.0.children().count() < 3 {
            return None;
        }

        self.0.children().last()
    }

    pub fn annotation(self) -> Option<View<'run>> {
        if self.0.kind() != PythonKind::AnnAssign {
            return None;
        }

        self.0.child_at(1)
    }
}

impl<'run> Call<'run> {
    pub fn view(self) -> View<'run> {
        self.0
    }

    pub fn callee(self) -> Option<View<'run>> {
        self.0.child_first()
    }

    pub fn arguments(self) -> impl Iterator<Item = View<'run>> {
        self.0
            .children()
            .skip(1)
            .filter(|held| held.kind() != PythonKind::Keyword)
    }

    pub fn keywords(self) -> impl Iterator<Item = Keyword<'run>> {
        self.0.children_of(PythonKind::Keyword).map(Keyword)
    }
}

impl<'run> ClassDef<'run> {
    pub fn view(self) -> View<'run> {
        self.0
    }

    pub fn name_token(self) -> Option<u32> {
        self.0.token_first(PythonKind::Identifier)
    }

    pub fn bases(self) -> impl Iterator<Item = View<'run>> {
        self.0.children().filter(|held| {
            !matches!(
                held.kind(),
                PythonKind::Block | PythonKind::Keyword | PythonKind::TypeParams
            )
        })
    }

    pub fn keywords(self) -> impl Iterator<Item = Keyword<'run>> {
        self.0.children_of(PythonKind::Keyword).map(Keyword)
    }

    pub fn decorators(self) -> impl Iterator<Item = View<'run>> {
        decorators_of(self.0)
    }

    pub fn type_params(self) -> Option<View<'run>> {
        self.0.child_first_of(PythonKind::TypeParams)
    }

    pub fn body(self) -> Option<View<'run>> {
        self.0.child_first_of(PythonKind::Block)
    }
}

impl<'run> Constant<'run> {
    pub fn view(self) -> View<'run> {
        self.0
    }

    pub fn literal_class(self) -> Literal {
        let node = self.0.tree.at(self.0.node);

        if node.token_end <= node.token_start {
            return Literal::Text;
        }

        let kind = self.0.token_kind(node.token_start);

        if kind == PythonKind::Ellipsis {
            return Literal::Ellipsis;
        }

        if matches!(kind, PythonKind::FalseKeyword | PythonKind::TrueKeyword) {
            return Literal::Boolean;
        }

        if kind == PythonKind::NoneKeyword {
            return Literal::None;
        }

        if kind == PythonKind::StringBytes {
            return Literal::Bytes;
        }

        if matches!(
            kind,
            PythonKind::NumberBinary
                | PythonKind::NumberComplex
                | PythonKind::NumberFloat
                | PythonKind::NumberHexadecimal
                | PythonKind::NumberInteger
                | PythonKind::NumberOctal
        ) {
            return Literal::Number;
        }

        Literal::Text
    }

    pub fn pieces(self) -> impl Iterator<Item = u32> + 'run {
        let held = self.0;

        held.positions().filter(move |position| {
            matches!(
                held.token_kind(*position),
                PythonKind::StringBytes | PythonKind::StringFormat | PythonKind::StringPlain
            )
        })
    }

    pub fn content_span(self, source: &[u8]) -> Span {
        let node = self.0.tree.at(self.0.node);

        if node.token_end <= node.token_start {
            return self.0.span();
        }

        let token = self.0.token_at(node.token_start);

        let Some(shape) = literal::shape_of(token.text(source), token.offset) else {
            return self.0.span();
        };

        shape.content
    }
}

impl<'run> FunctionDef<'run> {
    pub fn view(self) -> View<'run> {
        self.0
    }

    pub fn is_async(self) -> bool {
        self.0.kind() == PythonKind::AsyncFunctionDef
    }

    pub fn name_token(self) -> Option<u32> {
        self.0.token_first(PythonKind::Identifier)
    }

    pub fn parameters(self) -> impl Iterator<Item = Arg<'run>> {
        self.0
            .child_first_of(PythonKind::Arguments)
            .into_iter()
            .flat_map(|held| held.children_of(PythonKind::Arg))
            .map(Arg)
    }

    pub fn parameter_class(self, argument: Arg<'run>) -> Parameter {
        let Some(arguments) = self.0.child_first_of(PythonKind::Arguments) else {
            return Parameter::Positional;
        };

        let start = arguments.tree.at(argument.0.node).token_start;
        let mut found = Parameter::Positional;
        let mut slash = false;

        for position in arguments.positions() {
            if position >= start {
                break;
            }

            let kind = arguments.token_kind(position);

            match kind {
                PythonKind::Slash => slash = true,
                PythonKind::Star => found = Parameter::PositionalRest,
                PythonKind::StarStar => found = Parameter::KeywordRest,
                _ => {}
            }
        }

        if found == Parameter::PositionalRest && !self.is_rest(argument, PythonKind::Star) {
            return Parameter::Keyword;
        }

        if found == Parameter::Positional && slash {
            return Parameter::Positional;
        }

        if found == Parameter::Positional && self.positional_only(argument) {
            return Parameter::PositionalOnly;
        }

        found
    }

    fn positional_only(self, argument: Arg<'run>) -> bool {
        let Some(arguments) = self.0.child_first_of(PythonKind::Arguments) else {
            return false;
        };

        let start = arguments.tree.at(argument.0.node).token_start;

        arguments
            .positions_of(PythonKind::Slash)
            .any(|position| position > start)
    }

    fn is_rest(self, argument: Arg<'run>, marker: PythonKind) -> bool {
        let Some(arguments) = self.0.child_first_of(PythonKind::Arguments) else {
            return false;
        };

        let start = arguments.tree.at(argument.0.node).token_start;

        arguments
            .positions_of(marker)
            .any(|position| position + 1 == start)
    }

    pub fn returns_annotation(self) -> Option<View<'run>> {
        let mut found = None;

        for held in self.0.children() {
            if matches!(
                held.kind(),
                PythonKind::Arguments | PythonKind::Block | PythonKind::TypeParams
            ) {
                continue;
            }

            found = Some(held);
        }

        found
    }

    pub fn type_params(self) -> Option<View<'run>> {
        self.0.child_first_of(PythonKind::TypeParams)
    }

    pub fn decorators(self) -> impl Iterator<Item = View<'run>> {
        decorators_of(self.0)
    }

    pub fn body(self) -> Option<View<'run>> {
        self.0.child_first_of(PythonKind::Block)
    }
}

impl<'run> Import<'run> {
    pub fn view(self) -> View<'run> {
        self.0
    }

    pub fn aliases(self) -> impl Iterator<Item = Alias<'run>> {
        self.0.children_of(PythonKind::Alias).map(Alias)
    }

    pub fn level(self) -> u32 {
        let mut found = 0;

        for position in self.0.positions() {
            let kind = self.0.token_kind(position);

            match kind {
                PythonKind::Dot => found += 1,
                PythonKind::Ellipsis => found += 3,
                PythonKind::FromKeyword => {}
                _ => break,
            }
        }

        found
    }

    pub fn module_segments(self, out: &mut BoundedVec<Span>) -> bool {
        if self.0.kind() != PythonKind::ImportFrom {
            return true;
        }

        for position in self.0.positions() {
            let kind = self.0.token_kind(position);

            if kind == PythonKind::ImportKeyword {
                break;
            }

            if kind != PythonKind::Identifier {
                continue;
            }

            if !out.push(self.0.token_at(position).span()) {
                return false;
            }
        }

        true
    }
}

impl<'run> Keyword<'run> {
    pub fn view(self) -> View<'run> {
        self.0
    }

    pub fn name_token(self) -> Option<u32> {
        self.0.token_first(PythonKind::Identifier)
    }

    pub fn value(self) -> Option<View<'run>> {
        self.0.child_first()
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
        self.0.children().find(|held| {
            !matches!(
                held.kind(),
                PythonKind::Block
                    | PythonKind::ElseClause
                    | PythonKind::ExceptHandler
                    | PythonKind::FinallyClause
                    | PythonKind::MatchCase
                    | PythonKind::WithItem
            )
        })
    }

    pub fn body(self) -> Option<View<'run>> {
        self.0.child_first_of(PythonKind::Block)
    }

    pub fn else_clause(self) -> Option<View<'run>> {
        self.0.child_first_of(PythonKind::ElseClause)
    }

    pub fn finally_clause(self) -> Option<View<'run>> {
        self.0.child_first_of(PythonKind::FinallyClause)
    }

    pub fn handlers(self) -> Children<'run> {
        self.0.children_of(PythonKind::ExceptHandler)
    }

    pub fn items(self) -> Children<'run> {
        self.0.children_of(PythonKind::WithItem)
    }

    pub fn cases(self) -> Children<'run> {
        self.0.children_of(PythonKind::MatchCase)
    }
}

fn decorators_of(view: View<'_>) -> impl Iterator<Item = View<'_>> {
    let index = view.node;

    view.parent()
        .into_iter()
        .flat_map(View::children)
        .take_while(move |held| held.node < index)
        .filter(|held| held.kind() == PythonKind::Decorator)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::bounded::BoundedVec;
    use crate::language::Lexer as _;
    use crate::lex::PYTHON;
    use crate::syntax::python::classify::classify;
    use crate::syntax::python::parse;
    use crate::token::Tokens as CodeTokens;
    use crate::tree::Events;

    struct Fixture {
        raw: BoundedVec<PythonKind>,
        tokens: CodeTokens,
        tree: Tree<PythonKind>,
    }

    impl Fixture {
        fn of(source: &[u8]) -> Self {
            let mut lexed = CodeTokens::reserve(4_096);

            PYTHON.lex(source, &mut lexed);

            let mut tokens = CodeTokens::reserve(4_096);
            let mut raw = BoundedVec::reserve(4_096);

            assert!(classify(source, lexed.as_slice(), &mut tokens, &mut raw));

            let mut events = Events::reserve(0x4000);
            let mut tree = Tree::reserve(4_096, 64);

            parse::build(source, tokens.as_slice(), &raw, &mut events, &mut tree);

            Self { raw, tokens, tree }
        }

        fn root(&self) -> View<'_> {
            View::new(&self.tree, self.tokens.as_slice(), &self.raw, 0)
        }

        fn first(&self, kind: PythonKind) -> View<'_> {
            let mut stack = vec![self.root()];

            while let Some(view) = stack.pop() {
                if view.kind() == kind {
                    return view;
                }

                let mut children: Vec<View<'_>> = Vec::new();

                children.extend(view.children());
                children.reverse();
                stack.extend(children);
            }

            panic!("the tree holds no {}", kind.name());
        }
    }

    #[test]
    fn a_function_view_reads_its_name_parameters_and_body() {
        let source = b"@decorated\ndef greet(name: str, count=1) -> bool:\n    return True\n";
        let held = Fixture::of(source);
        let view = held.first(PythonKind::FunctionDef);
        let function = view.as_function().expect("the node is a definition");

        assert!(!function.is_async());

        assert_eq!(
            view.token_at(function.name_token().expect("a name"))
                .text(source),
            b"greet"
        );

        let names: Vec<&[u8]> = function
            .parameters()
            .map(|argument| {
                view.token_at(argument.name_token().expect("a name"))
                    .text(source)
            })
            .collect();

        assert_eq!(names, vec![&b"name"[..], &b"count"[..]]);

        let annotated = function.parameters().next().expect("a parameter");

        assert_eq!(
            annotated.annotation().expect("an annotation").text(source),
            b"str"
        );

        assert_eq!(
            function
                .returns_annotation()
                .expect("a return annotation")
                .text(source),
            b"bool"
        );

        assert_eq!(function.decorators().count(), 1);
        assert_eq!(function.body().expect("a body").children().count(), 1);
    }

    #[test]
    fn a_class_view_reads_its_bases_and_keywords() {
        let source = b"class Held(Base, metaclass=Meta):\n    pass\n";
        let held = Fixture::of(source);
        let view = held.first(PythonKind::ClassDef);
        let class = view.as_class().expect("the node is a class");

        assert_eq!(
            view.token_at(class.name_token().expect("a name"))
                .text(source),
            b"Held"
        );

        assert_eq!(class.bases().count(), 1);
        assert_eq!(class.keywords().count(), 1);

        let keyword = class.keywords().next().expect("a keyword");

        assert_eq!(
            view.token_at(keyword.name_token().expect("a name"))
                .text(source),
            b"metaclass"
        );

        assert_eq!(keyword.value().expect("a value").text(source), b"Meta");
        assert!(class.body().is_some());
    }

    #[test]
    fn a_call_view_separates_arguments_from_keywords() {
        let source = b"send(first, second, key=1)\n";
        let held = Fixture::of(source);
        let view = held.first(PythonKind::Call);
        let call = view.as_call().expect("the node is a call");

        assert_eq!(call.callee().expect("a callee").text(source), b"send");
        assert_eq!(call.arguments().count(), 2);
        assert_eq!(call.keywords().count(), 1);
    }

    #[test]
    fn an_assignment_view_separates_its_targets_from_its_value() {
        let source = b"first = second = 3\n";
        let held = Fixture::of(source);
        let view = held.first(PythonKind::Assign);
        let assign = view.as_assign().expect("the node is an assignment");

        assert_eq!(assign.targets().count(), 2);
        assert_eq!(assign.value().expect("a value").text(source), b"3");
        assert!(assign.annotation().is_none());
    }

    #[test]
    fn an_annotated_assignment_view_reads_its_annotation() {
        let source = b"count: int = 3\n";
        let held = Fixture::of(source);
        let view = held.first(PythonKind::AnnAssign);
        let assign = view.as_assign().expect("the node is an assignment");

        assert_eq!(assign.targets().count(), 1);

        assert_eq!(
            assign.annotation().expect("an annotation").text(source),
            b"int"
        );

        assert_eq!(assign.value().expect("a value").text(source), b"3");
    }

    #[test]
    fn an_import_view_reads_its_level_and_segments() {
        let source = b"from ..deep.module import thing as other\n";
        let held = Fixture::of(source);
        let view = held.first(PythonKind::ImportFrom);
        let import = view.as_import().expect("the node is an import");

        assert_eq!(import.level(), 2);

        let mut segments = BoundedVec::reserve(8);

        assert!(import.module_segments(&mut segments));
        assert_eq!(segments.count(), 2);

        let named: Vec<&[u8]> = segments.iter().map(|span| &source[span.range()]).collect();

        assert_eq!(named, vec![&b"deep"[..], &b"module"[..]]);

        let alias = import.aliases().next().expect("an alias");

        assert_eq!(
            view.token_at(alias.asname_token().expect("an asname"))
                .text(source),
            b"other"
        );

        let mut parts = BoundedVec::reserve(8);

        assert!(alias.name_segments(&mut parts));
        assert_eq!(parts.count(), 1);

        let read: Vec<&[u8]> = parts.iter().map(|span| &source[span.range()]).collect();

        assert_eq!(read, vec![&b"thing"[..]]);
    }

    #[test]
    fn a_constant_view_names_its_literal_class_and_content() {
        let source = b"held = rb'''bytes'''\n";
        let held = Fixture::of(source);
        let view = held.first(PythonKind::Constant);
        let constant = view.as_constant().expect("the node is a constant");

        assert_eq!(constant.literal_class(), Literal::Bytes);
        assert_eq!(&source[constant.content_span(source).range()], b"bytes");
    }

    #[test]
    fn a_statement_view_reads_its_clauses() {
        let source =
            b"try:\n    pass\nexcept ValueError:\n    pass\nelse:\n    pass\nfinally:\n    pass\n";

        let held = Fixture::of(source);
        let view = held.first(PythonKind::Try);
        let statement = view.as_statement().expect("the node is a statement");

        assert_eq!(statement.handlers().count(), 1);
        assert!(statement.else_clause().is_some());
        assert!(statement.finally_clause().is_some());
        assert!(statement.body().is_some());
    }

    #[test]
    fn an_operation_view_reads_its_operands_and_operators() {
        let source = b"held = first < second <= third\n";
        let fixture = Fixture::of(source);
        let view = fixture.first(PythonKind::Compare);
        let operation = view.as_operation().expect("the node is an operation");

        assert_eq!(operation.operands().count(), 3);
        assert_eq!(operation.operator_tokens().count(), 2);
    }

    #[test]
    fn a_parameter_view_reads_the_default_the_signature_wrote_beside_it() {
        let source = b"def held(first, second: int = 3, *, third=len):\n    pass\n";
        let fixture = Fixture::of(source);
        let view = fixture.first(PythonKind::FunctionDef);
        let function = view.as_function().expect("the node is a definition");

        let defaults: Vec<Option<String>> = function
            .parameters()
            .map(|argument| {
                argument
                    .default()
                    .map(|held| String::from_utf8_lossy(held.text(source)).into_owned())
            })
            .collect();

        assert_eq!(
            defaults,
            vec![None, Some("3".to_owned()), Some("len".to_owned())]
        );
    }

    #[test]
    fn a_parameter_view_names_its_class() {
        let source = b"def held(first, second, /, third, *rest, fourth, **extra):\n    pass\n";
        let fixture = Fixture::of(source);
        let view = fixture.first(PythonKind::FunctionDef);
        let function = view.as_function().expect("the node is a definition");

        let classes: Vec<Parameter> = function
            .parameters()
            .map(|argument| function.parameter_class(argument))
            .collect();

        assert_eq!(
            classes,
            vec![
                Parameter::PositionalOnly,
                Parameter::PositionalOnly,
                Parameter::Positional,
                Parameter::PositionalRest,
                Parameter::Keyword,
                Parameter::KeywordRest,
            ]
        );
    }

    #[test]
    fn a_cast_to_the_wrong_view_returns_nothing() {
        let source = b"held = 1\n";
        let fixture = Fixture::of(source);
        let view = fixture.first(PythonKind::Constant);

        assert!(view.as_call().is_none());
        assert!(view.as_function().is_none());
        assert!(view.as_constant().is_some());
        assert_eq!(view.parent().expect("a parent").kind(), PythonKind::Assign);
    }
}
