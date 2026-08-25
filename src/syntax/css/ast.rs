use crate::bounded::Span;
use crate::syntax::css::kind::CSSKind;
use crate::token::Token;
use crate::tree::{NONE, Tree};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Literal {
    Colour,
    Dimension,
    Text,
    Word,
}

#[derive(Clone, Copy, Debug)]
pub struct View<'run> {
    node: u32,
    raw: &'run [CSSKind],
    tokens: &'run [Token],
    tree: &'run Tree<CSSKind>,
}

#[derive(Clone, Copy, Debug)]
pub struct Call<'run>(View<'run>);

#[derive(Clone, Copy, Debug)]
pub struct Declaration<'run>(View<'run>);

#[derive(Clone, Copy, Debug)]
pub struct Rule<'run>(View<'run>);

#[derive(Clone, Copy, Debug)]
pub struct Selector<'run>(View<'run>);

#[derive(Clone, Copy, Debug)]
pub struct Statement<'run>(View<'run>);

#[derive(Clone, Debug)]
pub struct Children<'run> {
    current: u32,
    kind: Option<CSSKind>,
    raw: &'run [CSSKind],
    tokens: &'run [Token],
    tree: &'run Tree<CSSKind>,
}

#[derive(Clone, Debug)]
pub struct Positions<'run> {
    child: u32,
    kind: Option<CSSKind>,
    limit: u32,
    position: u32,
    raw: &'run [CSSKind],
    tree: &'run Tree<CSSKind>,
}

const SELECTORS: [CSSKind; 12] = [
    CSSKind::AdjacentSiblingSelector,
    CSSKind::AttributeSelector,
    CSSKind::ChildSelector,
    CSSKind::ClassSelector,
    CSSKind::DescendantSelector,
    CSSKind::IdSelector,
    CSSKind::NamespaceSelector,
    CSSKind::NestingSelector,
    CSSKind::PseudoClassSelector,
    CSSKind::PseudoElementSelector,
    CSSKind::SiblingSelector,
    CSSKind::UniversalSelector,
];

const STATEMENTS: [CSSKind; 8] = [
    CSSKind::AtRule,
    CSSKind::CharsetStatement,
    CSSKind::ImportStatement,
    CSSKind::KeyframesStatement,
    CSSKind::MediaStatement,
    CSSKind::NamespaceStatement,
    CSSKind::PostcssStatement,
    CSSKind::SupportsStatement,
];

const VALUES: [CSSKind; 10] = [
    CSSKind::BinaryExpression,
    CSSKind::CallExpression,
    CSSKind::ColorValue,
    CSSKind::FloatValue,
    CSSKind::GridValue,
    CSSKind::Important,
    CSSKind::IntegerValue,
    CSSKind::ParenthesizedValue,
    CSSKind::PlainValue,
    CSSKind::StringValue,
];

impl<'run> View<'run> {
    pub fn new(
        tree: &'run Tree<CSSKind>,
        tokens: &'run [Token],
        raw: &'run [CSSKind],
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

    pub fn kind(self) -> CSSKind {
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

    pub fn children_of(self, kind: CSSKind) -> Children<'run> {
        self.children_of_kind(Some(kind))
    }

    fn children_of_kind(self, kind: Option<CSSKind>) -> Children<'run> {
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

    pub fn child_first_of(self, kind: CSSKind) -> Option<Self> {
        self.children_of(kind).next()
    }

    pub fn child_at(self, index: u32) -> Option<Self> {
        self.children().nth(index as usize)
    }

    pub fn positions(self) -> Positions<'run> {
        self.positions_of_kind(None)
    }

    pub fn positions_of(self, kind: CSSKind) -> Positions<'run> {
        self.positions_of_kind(Some(kind))
    }

    fn positions_of_kind(self, kind: Option<CSSKind>) -> Positions<'run> {
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

    pub fn token_kind(self, position: u32) -> CSSKind {
        self.raw[position as usize]
    }

    pub fn token_first(self, kind: CSSKind) -> Option<u32> {
        self.positions_of(kind).next()
    }

    pub fn holds(self, kind: CSSKind) -> bool {
        self.positions_of(kind).next().is_some()
    }

    fn cast(self, kinds: &[CSSKind]) -> Option<Self> {
        if kinds.contains(&self.kind()) {
            return Some(self);
        }

        None
    }

    pub fn as_call(self) -> Option<Call<'run>> {
        self.cast(&[CSSKind::CallExpression]).map(Call)
    }

    pub fn as_declaration(self) -> Option<Declaration<'run>> {
        self.cast(&[CSSKind::Declaration]).map(Declaration)
    }

    pub fn as_rule(self) -> Option<Rule<'run>> {
        self.cast(&[CSSKind::RuleSet]).map(Rule)
    }

    pub fn as_selector(self) -> Option<Selector<'run>> {
        self.cast(&SELECTORS).map(Selector)
    }

    pub fn as_statement(self) -> Option<Statement<'run>> {
        self.cast(&STATEMENTS).map(Statement)
    }

    pub fn is_value(self) -> bool {
        VALUES.contains(&self.kind())
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

    pub fn name(self) -> Option<View<'run>> {
        self.0.child_first_of(CSSKind::FunctionName)
    }

    pub fn arguments(self) -> impl Iterator<Item = View<'run>> {
        self.0
            .children_of(CSSKind::Arguments)
            .flat_map(View::children)
    }
}

impl<'run> Declaration<'run> {
    pub fn view(self) -> View<'run> {
        self.0
    }

    pub fn property(self) -> Option<View<'run>> {
        self.0.child_first_of(CSSKind::PropertyName)
    }

    pub fn values(self) -> impl Iterator<Item = View<'run>> {
        self.0.children().filter(|held| held.is_value())
    }

    pub fn is_important(self) -> bool {
        self.0.children_of(CSSKind::Important).next().is_some()
    }
}

impl<'run> Rule<'run> {
    pub fn view(self) -> View<'run> {
        self.0
    }

    pub fn selectors(self) -> impl Iterator<Item = View<'run>> {
        self.0
            .children_of(CSSKind::Selectors)
            .flat_map(View::children)
    }

    pub fn body(self) -> Option<View<'run>> {
        self.0.child_first_of(CSSKind::Block)
    }

    pub fn declarations(self) -> impl Iterator<Item = View<'run>> {
        self.body()
            .into_iter()
            .flat_map(|held| held.children_of(CSSKind::Declaration))
    }
}

impl<'run> Selector<'run> {
    pub fn view(self) -> View<'run> {
        self.0
    }

    pub fn parts(self) -> Children<'run> {
        self.0.children()
    }

    pub fn name(self) -> Option<View<'run>> {
        let held = self.0;

        match Some(held.kind()) {
            Some(CSSKind::ClassSelector | CSSKind::PseudoClassSelector) => {
                held.children_of(CSSKind::ClassName).last()
            }
            Some(CSSKind::IdSelector) => held.child_first_of(CSSKind::IdName),
            Some(CSSKind::AttributeSelector) => held.child_first_of(CSSKind::AttributeName),
            Some(CSSKind::PseudoElementSelector) => held.children_of(CSSKind::TagName).last(),
            Some(_) | None => None,
        }
    }
}

impl<'run> Statement<'run> {
    pub fn view(self) -> View<'run> {
        self.0
    }

    pub fn keyword(self) -> Option<View<'run>> {
        self.0.child_first_of(CSSKind::AtKeyword)
    }

    pub fn queries(self) -> impl Iterator<Item = View<'run>> {
        self.0.children().filter(|held| {
            matches!(
                held.kind(),
                CSSKind::BinaryQuery
                    | CSSKind::FeatureQuery
                    | CSSKind::KeywordQuery
                    | CSSKind::ParenthesizedQuery
                    | CSSKind::SelectorQuery
                    | CSSKind::UnaryQuery
            )
        })
    }

    pub fn body(self) -> Option<View<'run>> {
        self.0
            .children()
            .find(|held| matches!(held.kind(), CSSKind::Block | CSSKind::KeyframeBlockList))
    }
}

pub fn literal_class(text: &[u8]) -> Literal {
    match text.first() {
        Some(b'#') => Literal::Colour,
        Some(b'"' | b'\'') => Literal::Text,
        Some(byte) if byte.is_ascii_digit() || matches!(byte, b'+' | b'-' | b'.') => {
            Literal::Dimension
        }
        _ => Literal::Word,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::bounded::BoundedVec;
    use crate::language::Lexer as _;
    use crate::lex::CSS;
    use crate::syntax::css::classify::classify;
    use crate::syntax::css::parse;
    use crate::token::Tokens as CodeTokens;
    use crate::tree::Events;

    struct Fixture {
        raw: BoundedVec<CSSKind>,
        tokens: CodeTokens,
        tree: Tree<CSSKind>,
    }

    impl Fixture {
        fn of(source: &[u8]) -> Self {
            let mut lexed = CodeTokens::reserve(4_096);
            let mut tokens = CodeTokens::reserve(4_096);
            let mut raw = BoundedVec::reserve(4_096);
            let mut events = Events::reserve(0x4000);
            let mut tree = Tree::reserve(4_096, 64);

            CSS.lex(source, &mut lexed);

            assert!(classify(source, lexed.as_slice(), &mut tokens, &mut raw));

            parse::build(source, tokens.as_slice(), &raw, &mut events, &mut tree);

            Self { raw, tokens, tree }
        }

        fn view(&self, node: u32) -> View<'_> {
            View::new(&self.tree, self.tokens.as_slice(), &self.raw, node)
        }

        fn first(&self, kind: CSSKind) -> View<'_> {
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
    fn a_rule_reads_its_selectors_and_its_declarations() {
        const SOURCE: &[u8] = b".card, #main {\n    color: red;\n    width: 10px;\n}\n";
        let fixture = Fixture::of(SOURCE);

        let held = fixture
            .first(CSSKind::RuleSet)
            .as_rule()
            .expect("a rule casts");

        assert_eq!(held.selectors().count(), 2);
        assert_eq!(held.declarations().count(), 2);
        assert_eq!(held.body().expect("a body").kind(), CSSKind::Block);
    }

    #[test]
    fn a_declaration_reads_its_property_and_its_values() {
        const SOURCE: &[u8] = b"a { background: url(x.png) no-repeat !important; }\n";
        let fixture = Fixture::of(SOURCE);

        let held = fixture
            .first(CSSKind::Declaration)
            .as_declaration()
            .expect("a declaration casts");

        assert_eq!(
            held.property().expect("a property").text(SOURCE),
            b"background".as_slice()
        );

        assert_eq!(held.values().count(), 3);
        assert!(held.is_important());
    }

    #[test]
    fn a_call_reads_its_name_and_its_arguments() {
        const SOURCE: &[u8] = b"a { width: calc(100% - 2px); }\n";
        let fixture = Fixture::of(SOURCE);

        let held = fixture
            .first(CSSKind::CallExpression)
            .as_call()
            .expect("a call casts");

        assert_eq!(
            held.name().expect("a name").text(SOURCE),
            b"calc".as_slice()
        );

        assert_eq!(held.arguments().count(), 1);
    }

    #[test]
    fn a_selector_reads_the_name_its_mark_carries() {
        const SOURCE: &[u8] = b"a.card:hover > #main[data-x] {}\n";
        let fixture = Fixture::of(SOURCE);

        assert_eq!(
            fixture
                .first(CSSKind::ClassSelector)
                .as_selector()
                .expect("a selector casts")
                .name()
                .expect("a name")
                .text(SOURCE),
            b"card".as_slice()
        );

        assert_eq!(
            fixture
                .first(CSSKind::IdSelector)
                .as_selector()
                .expect("a selector casts")
                .name()
                .expect("a name")
                .text(SOURCE),
            b"main".as_slice()
        );
    }

    #[test]
    fn a_statement_reads_its_queries_and_its_body() {
        const SOURCE: &[u8] = b"@media screen and (min-width: 100px) { a { b: c } }\n";
        let fixture = Fixture::of(SOURCE);

        let held = fixture
            .first(CSSKind::MediaStatement)
            .as_statement()
            .expect("a statement casts");

        assert_eq!(held.queries().count(), 1);
        assert_eq!(held.body().expect("a body").kind(), CSSKind::Block);
    }

    #[test]
    fn a_literal_names_its_class() {
        assert_eq!(literal_class(b"#fff"), Literal::Colour);
        assert_eq!(literal_class(b"\"held\""), Literal::Text);
        assert_eq!(literal_class(b"10px"), Literal::Dimension);
        assert_eq!(literal_class(b"red"), Literal::Word);
    }
}
