use crate::bounded::{BoundedVec, Span};
use crate::syntax::css::kind::CSSKind;
use crate::syntax::{Fact, FactKind, Facts, name_hash};
use crate::token::Token;
use crate::tree::{NONE, Step, Structure, Tree, walk};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum DefinitionKind {
    Class,
    CustomProperty,
    FontFamily,
    Id,
    Keyframes,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum UseKind {
    CustomProperty,
    FontFamily,
    Keyframes,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Definition {
    pub kind: DefinitionKind,
    pub name: Span,
    pub name_hash: u32,
    pub name_previous: u32,
    pub node: u32,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Use {
    pub count: u32,
    pub definition: u32,
    pub kind: UseKind,
    pub name: Span,
    pub node: u32,
}

#[derive(Debug)]
pub struct Semantic {
    definitions: BoundedVec<Definition>,
    facts: Facts,
    heads: BoundedVec<u32>,
    uses: BoundedVec<Use>,
}

fn bucket_count_of(definition_count_max: u32) -> u32 {
    definition_count_max.next_power_of_two().max(16)
}

struct Builder<'run> {
    outcome: Structure,
    semantic: &'run mut Semantic,
    source: &'run [u8],
    tokens: &'run [Token],
    tree: &'run Tree<CSSKind>,
}

struct Children<'run> {
    node: u32,
    tree: &'run Tree<CSSKind>,
}

impl Iterator for Children<'_> {
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

impl DefinitionKind {
    pub const fn reads(self, kind: UseKind) -> bool {
        matches!(
            (self, kind),
            (Self::CustomProperty, UseKind::CustomProperty)
                | (Self::FontFamily, UseKind::FontFamily)
                | (Self::Keyframes, UseKind::Keyframes)
        )
    }
}

impl Semantic {
    pub fn reserve(definition_count_max: u32, use_count_max: u32, fact_count_max: u32) -> Self {
        assert!(definition_count_max > 0);
        assert!(use_count_max > 0);
        assert!(fact_count_max > 0);

        assert!(!crate::allocation::is_frozen());

        let mut heads = BoundedVec::reserve(bucket_count_of(definition_count_max));

        for _ in 0..heads.capacity() {
            heads.push_assert(NONE);
        }

        Self {
            definitions: BoundedVec::reserve(definition_count_max),
            facts: Facts::reserve(fact_count_max),
            heads,
            uses: BoundedVec::reserve(use_count_max),
        }
    }

    pub fn clear(&mut self) {
        for index in 0..self.heads.count() {
            self.heads[index as usize] = NONE;
        }

        self.definitions.clear();
        self.facts.clear();
        self.uses.clear();

        assert_eq!(self.count(), 0);
    }

    pub fn count(&self) -> u32 {
        self.definitions.count()
    }

    pub fn definitions(&self) -> &[Definition] {
        &self.definitions
    }

    pub fn facts(&self) -> &[Fact] {
        self.facts.as_slice()
    }

    pub fn get(&self, index: u32) -> Option<&Definition> {
        if index == NONE {
            return None;
        }

        self.definitions.get(index as usize)
    }

    pub fn uses(&self) -> &[Use] {
        &self.uses
    }

    pub fn uses_of(&self, index: u32) -> impl Iterator<Item = u32> {
        (0..self.uses.count()).filter(move |held| self.uses[*held as usize].definition == index)
    }

    pub fn build(
        &mut self,
        source: &[u8],
        tokens: &[Token],
        _raw: &[CSSKind],
        tree: &Tree<CSSKind>,
    ) -> Structure {
        self.clear();

        let mut builder = Builder {
            outcome: Structure::Complete,
            semantic: self,
            source,
            tokens,
            tree,
        };

        builder.collect();

        let outcome = builder.outcome;

        self.resolve(source);

        outcome
    }

    fn bucket_of(&self, hash: u32) -> usize {
        (hash & (self.heads.count() - 1)) as usize
    }

    fn push_definition(&mut self, definition: Definition) -> bool {
        if definition.name.length == 0 {
            return true;
        }

        let index = self.definitions.count();
        let bucket = self.bucket_of(definition.name_hash);
        let mut held = definition;

        held.name_previous = self.heads[bucket];

        if !self.definitions.push(held) {
            return false;
        }

        self.heads[bucket] = index;

        true
    }

    fn resolve(&mut self, source: &[u8]) {
        for index in 0..self.uses.count() {
            let held = self.uses[index as usize];
            let name = &source[held.name.range()];
            let hash = name_hash(name);
            let mut position = self.heads[self.bucket_of(hash)];
            let mut found = NONE;
            let mut count = 0;

            for _ in 0..=self.definitions.count() {
                if position == NONE {
                    break;
                }

                let definition = self.definitions[position as usize];

                if definition.name_hash == hash
                    && definition.kind.reads(held.kind)
                    && &source[definition.name.range()] == name
                {
                    found = position;
                    count += 1;
                }

                position = definition.name_previous;
            }

            self.uses[index as usize].count = count;
            self.uses[index as usize].definition = found;
        }
    }
}

impl<'run> Builder<'run> {
    fn collect(&mut self) {
        if self.tree.count() == 0 {
            return;
        }

        for step in walk(self.tree) {
            let Step::Enter(node) = step else {
                continue;
            };

            self.enter(node);
        }
    }

    fn kind_of(&self, node: u32) -> CSSKind {
        if node == NONE {
            return CSSKind::ErrorNode;
        }

        self.tree.at(node).kind
    }

    fn children(&self, node: u32) -> Children<'run> {
        Children {
            node: self.tree.at(node).child_first,
            tree: self.tree,
        }
    }

    fn child_of(&self, node: u32, kind: CSSKind) -> u32 {
        if node == NONE {
            return NONE;
        }

        for child in self.children(node) {
            if self.kind_of(child) == kind {
                return child;
            }
        }

        NONE
    }

    fn parent_of(&self, node: u32) -> u32 {
        if node == NONE {
            return NONE;
        }

        self.tree.at(node).parent
    }

    fn span_of(&self, node: u32) -> Span {
        self.tree.at(node).span(self.tokens)
    }

    fn text_of(&self, name: Span) -> &'run [u8] {
        &self.source[name.range()]
    }

    fn unquoted(&self, node: u32) -> Span {
        let held = self.span_of(node);

        if self.kind_of(node) != CSSKind::StringValue || held.length < 2 {
            return held;
        }

        Span {
            length: held.length - 2,
            offset: held.offset + 1,
        }
    }

    fn enter(&mut self, node: u32) {
        match Some(self.kind_of(node)) {
            Some(CSSKind::CallExpression) => self.call(node),
            Some(CSSKind::ClassName) => self.class(node),
            Some(CSSKind::Declaration) => self.declaration(node),
            Some(CSSKind::IdName) => self.identifier(node),
            Some(CSSKind::ImportStatement) => self.import(node),
            Some(CSSKind::KeyframesName) => self.keyframes(node),
            Some(_) | None => {}
        }
    }

    fn class(&mut self, node: u32) {
        if self.kind_of(self.parent_of(node)) != CSSKind::ClassSelector {
            return;
        }

        let name = self.span_of(node);

        self.define(DefinitionKind::Class, name, node);
    }

    fn identifier(&mut self, node: u32) {
        if self.kind_of(self.parent_of(node)) != CSSKind::IdSelector {
            return;
        }

        let name = self.span_of(node);

        self.define(DefinitionKind::Id, name, node);
    }

    fn keyframes(&mut self, node: u32) {
        let name = self.span_of(node);

        self.define(DefinitionKind::Keyframes, name, node);
    }

    fn declaration(&mut self, node: u32) {
        let held = self.child_of(node, CSSKind::PropertyName);

        if held == NONE {
            return;
        }

        let property = self.text_of(self.span_of(held));

        if property.starts_with(b"--") {
            let name = self.span_of(held);

            self.define(DefinitionKind::CustomProperty, name, held);

            return;
        }

        if property == b"font-family" {
            self.family(node, held);

            return;
        }

        if property == b"animation-name" {
            self.values(node, held, UseKind::Keyframes);
        }
    }

    fn family(&mut self, node: u32, property: u32) {
        if self.faced(node) {
            for child in self.children(node) {
                if child == property || !self.names(child) {
                    continue;
                }

                let name = self.unquoted(child);

                self.define(DefinitionKind::FontFamily, name, child);
            }

            return;
        }

        self.values(node, property, UseKind::FontFamily);
    }

    fn faced(&self, node: u32) -> bool {
        let block = self.parent_of(node);
        let rule = self.parent_of(block);

        if self.kind_of(rule) != CSSKind::AtRule {
            return false;
        }

        let keyword = self.child_of(rule, CSSKind::AtKeyword);

        keyword != NONE && self.text_of(self.span_of(keyword)) == b"@font-face"
    }

    fn names(&self, node: u32) -> bool {
        matches!(
            self.kind_of(node),
            CSSKind::PlainValue | CSSKind::StringValue
        )
    }

    fn values(&mut self, node: u32, property: u32, kind: UseKind) {
        for child in self.children(node) {
            if child == property || !self.names(child) {
                continue;
            }

            let name = self.unquoted(child);

            self.read(kind, name, child);
        }
    }

    fn call(&mut self, node: u32) {
        let held = self.child_of(node, CSSKind::FunctionName);

        if held == NONE || self.text_of(self.span_of(held)) != b"var" {
            return;
        }

        let arguments = self.child_of(node, CSSKind::Arguments);

        if arguments == NONE {
            return;
        }

        for child in self.children(arguments) {
            if self.kind_of(child) != CSSKind::PlainValue {
                continue;
            }

            let name = self.span_of(child);

            if !self.text_of(name).starts_with(b"--") {
                continue;
            }

            self.read(UseKind::CustomProperty, name, child);

            return;
        }
    }

    fn import(&mut self, node: u32) {
        let specifier = self.specifier_of(node);

        if specifier == Span::EMPTY {
            return;
        }

        let recorded = self.semantic.facts.push(Fact {
            binding: NONE,
            kind: FactKind::ImportSideEffect,
            local: Span::EMPTY,
            remote: Span::EMPTY,
            specifier,
        });

        if !recorded && self.outcome == Structure::Complete {
            self.outcome = Structure::Truncated;
        }
    }

    fn specifier_of(&self, node: u32) -> Span {
        let held = self.child_of(node, CSSKind::StringValue);

        if held != NONE {
            return self.unquoted(held);
        }

        let call = self.child_of(node, CSSKind::CallExpression);
        let arguments = self.child_of(call, CSSKind::Arguments);

        if arguments == NONE {
            return Span::EMPTY;
        }

        for child in self.children(arguments) {
            if self.names(child) {
                return self.unquoted(child);
            }
        }

        Span::EMPTY
    }

    fn define(&mut self, kind: DefinitionKind, name: Span, node: u32) {
        let recorded = self.semantic.push_definition(Definition {
            kind,
            name,
            name_hash: name_hash(&self.source[name.range()]),
            name_previous: NONE,
            node,
        });

        if !recorded && self.outcome == Structure::Complete {
            self.outcome = Structure::Truncated;
        }
    }

    fn read(&mut self, kind: UseKind, name: Span, node: u32) {
        let recorded = self.semantic.uses.push(Use {
            count: 0,
            definition: NONE,
            kind,
            name,
            node,
        });

        if !recorded && self.outcome == Structure::Complete {
            self.outcome = Structure::Truncated;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::bounded::BoundedVec as Held;
    use crate::language::Lexer as _;
    use crate::lex::CSS;
    use crate::syntax::css::classify::classify;
    use crate::syntax::css::parse;
    use crate::token::Tokens;
    use crate::tree::Events;

    const EVERY_FIXTURE: [&str; 4] = [
        "fonts.css",
        "keyframes.css",
        "properties.css",
        "selectors.css",
    ];

    struct Fixture {
        semantic: Semantic,
        source: Vec<u8>,
    }

    fn rows(held: &[&str]) -> Vec<String> {
        held.iter().map(|row| (*row).to_owned()).collect()
    }

    impl Fixture {
        fn read(path: &str) -> Self {
            let root = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"))
                .join("tests/fixtures/css-semantic")
                .join(path);

            let source = std::fs::read(root).expect("the fixture is readable");

            Self::of(&source)
        }

        fn of(source: &[u8]) -> Self {
            let mut lexed = Tokens::reserve(1 << 14);
            let mut tokens = Tokens::reserve(1 << 14);
            let mut raw = Held::reserve(1 << 14);
            let mut events = Events::reserve(1 << 16);
            let mut tree = Tree::<CSSKind>::reserve(1 << 14, 1 << 8);
            let mut semantic = Semantic::reserve(1 << 10, 1 << 10, 1 << 10);

            CSS.lex(source, &mut lexed);

            assert!(classify(source, lexed.as_slice(), &mut tokens, &mut raw));

            parse::build(source, tokens.as_slice(), &raw, &mut events, &mut tree);

            assert_eq!(
                semantic.build(source, tokens.as_slice(), &raw, &tree),
                Structure::Complete
            );

            Self {
                semantic,
                source: source.to_vec(),
            }
        }

        fn text_of(&self, name: Span) -> String {
            String::from_utf8_lossy(&self.source[name.range()]).into_owned()
        }

        fn definitions(&self) -> Vec<String> {
            self.semantic
                .definitions()
                .iter()
                .map(|held| format!("{:?} {}", held.kind, self.text_of(held.name)))
                .collect()
        }

        fn uses(&self) -> Vec<String> {
            self.semantic
                .uses()
                .iter()
                .map(|held| {
                    if held.definition == NONE {
                        return format!("{} {:?} none", self.text_of(held.name), held.kind);
                    }

                    format!(
                        "{} {:?} reads {} of {}",
                        self.text_of(held.name),
                        held.kind,
                        held.definition,
                        held.count
                    )
                })
                .collect()
        }

        fn facts(&self) -> Vec<String> {
            self.semantic
                .facts()
                .iter()
                .map(|held| format!("{} {}", held.kind.name(), self.text_of(held.specifier)))
                .collect()
        }
    }

    #[test]
    fn a_font_face_defines_a_family_and_a_rule_reads_one() {
        let fixture = Fixture::read("fonts.css");

        assert_eq!(
            fixture.definitions(),
            rows(&["FontFamily Scylla", "Class card"])
        );

        assert_eq!(
            fixture.uses(),
            rows(&["Scylla FontFamily reads 0 of 1", "serif FontFamily none"])
        );

        assert_eq!(fixture.facts(), rows(&[]));
    }

    #[test]
    fn a_keyframes_statement_defines_a_name_an_animation_name_reads() {
        let fixture = Fixture::read("keyframes.css");

        assert_eq!(
            fixture.definitions(),
            rows(&["Keyframes slide", "Class card", "Class panel"])
        );

        assert_eq!(
            fixture.uses(),
            rows(&["slide Keyframes reads 0 of 1", "missing Keyframes none"])
        );

        assert_eq!(fixture.facts(), rows(&[]));
    }

    #[test]
    fn a_custom_property_use_reads_every_declaration_of_its_name() {
        let fixture = Fixture::read("properties.css");

        assert_eq!(
            fixture.definitions(),
            rows(&[
                "CustomProperty --brand",
                "CustomProperty --space",
                "Class card",
                "CustomProperty --brand"
            ])
        );

        assert_eq!(
            fixture.uses(),
            rows(&[
                "--brand CustomProperty reads 0 of 2",
                "--space CustomProperty reads 1 of 1",
                "--missing CustomProperty none"
            ])
        );

        assert_eq!(fixture.facts(), rows(&[]));
    }

    #[test]
    fn a_selector_defines_each_class_and_id_it_names_and_no_pseudo_class() {
        let fixture = Fixture::read("selectors.css");

        assert_eq!(
            fixture.definitions(),
            rows(&[
                "Class card",
                "Class inner",
                "Id main",
                "Class card",
                "Id footer"
            ])
        );

        assert_eq!(fixture.uses(), rows(&[]));

        assert_eq!(
            fixture.facts(),
            rows(&["ImportSideEffect reset.css", "ImportSideEffect theme.css"])
        );
    }

    #[test]
    fn every_use_that_names_a_definition_names_one_it_can_read() {
        for name in EVERY_FIXTURE {
            let fixture = Fixture::read(name);

            for held in fixture.semantic.uses() {
                if held.definition == NONE {
                    assert_eq!(held.count, 0, "{name}");

                    continue;
                }

                let definition = fixture.semantic.definitions()[held.definition as usize];

                assert!(definition.kind.reads(held.kind), "{name}");

                assert_eq!(
                    fixture.text_of(definition.name),
                    fixture.text_of(held.name),
                    "{name}"
                );

                assert!(held.count > 0, "{name}");
            }
        }
    }

    #[test]
    fn a_table_that_fills_reports_rather_than_grows() {
        let source = std::fs::read(
            std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"))
                .join("tests/fixtures/css-semantic/selectors.css"),
        )
        .expect("the fixture is readable");

        let mut lexed = Tokens::reserve(1 << 14);
        let mut tokens = Tokens::reserve(1 << 14);
        let mut raw = Held::reserve(1 << 14);
        let mut events = Events::reserve(1 << 16);
        let mut tree = Tree::<CSSKind>::reserve(1 << 14, 1 << 8);
        let mut semantic = Semantic::reserve(2, 2, 1);

        CSS.lex(&source, &mut lexed);

        assert!(classify(&source, lexed.as_slice(), &mut tokens, &mut raw));

        parse::build(&source, tokens.as_slice(), &raw, &mut events, &mut tree);

        let outcome = semantic.build(&source, tokens.as_slice(), &raw, &tree);

        assert_ne!(outcome, Structure::Complete);
    }
}
