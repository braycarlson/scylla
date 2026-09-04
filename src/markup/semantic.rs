use crate::bounded::{BoundedVec, Span};
use crate::markup::kind::MarkupKind;
use crate::markup::token::Token;
use crate::markup::tree::Tree;
use crate::markup::view::View;
use crate::syntax::name_hash;
use crate::tree::{NONE, Step, Structure, walk};

const FRAGMENT: [&[u8]; 3] = [b"href", b"usemap", b"xlink:href"];

const LISTED: [&[u8]; 9] = [
    b"aria-activedescendant",
    b"aria-controls",
    b"aria-describedby",
    b"aria-details",
    b"aria-errormessage",
    b"aria-flowto",
    b"aria-labelledby",
    b"aria-owns",
    b"headers",
];

const SINGULAR: [&[u8]; 3] = [b"for", b"form", b"list"];

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum DefinitionKind {
    Id,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum UseKind {
    Id,
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
    heads: BoundedVec<u32>,
    uses: BoundedVec<Use>,
}

struct Builder<'run> {
    outcome: Structure,
    semantic: &'run mut Semantic,
    source: &'run [u8],
    tokens: &'run [Token],
    tree: &'run Tree,
}

fn bucket_count_of(definition_count_max: u32) -> u32 {
    definition_count_max.next_power_of_two().max(16)
}

impl DefinitionKind {
    pub const fn reads(self, kind: UseKind) -> bool {
        matches!((self, kind), (Self::Id, UseKind::Id))
    }
}

impl Semantic {
    pub fn reserve(definition_count_max: u32, use_count_max: u32) -> Self {
        assert!(definition_count_max > 0);
        assert!(use_count_max > 0);

        assert!(!crate::allocation::is_frozen());

        let mut heads = BoundedVec::reserve(bucket_count_of(definition_count_max));

        for _ in 0..heads.capacity() {
            heads.push_assert(NONE);
        }

        Self {
            definitions: BoundedVec::reserve(definition_count_max),
            heads,
            uses: BoundedVec::reserve(use_count_max),
        }
    }

    pub fn clear(&mut self) {
        for index in 0..self.heads.count() {
            self.heads[index as usize] = NONE;
        }

        self.definitions.clear();
        self.uses.clear();

        assert_eq!(self.count(), 0);
    }

    pub fn count(&self) -> u32 {
        self.definitions.count()
    }

    pub fn definitions(&self) -> &[Definition] {
        &self.definitions
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

    pub fn build(&mut self, source: &[u8], tokens: &[Token], tree: &Tree) -> Structure {
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

impl Builder<'_> {
    fn collect(&mut self) {
        if self.tree.count() == 0 {
            return;
        }

        for step in walk(self.tree) {
            let Step::Enter(node) = step else {
                continue;
            };

            if self.tree.at(node).kind == MarkupKind::Attribute {
                self.attribute(node);
            }
        }
    }

    fn attribute(&mut self, node: u32) {
        let view = View::new(self.tree, self.tokens, node);
        let Some(attribute) = view.as_attribute() else {
            return;
        };

        let Some(index) = attribute.name_token() else {
            return;
        };

        let Some(value) = attribute.value() else {
            return;
        };

        if value
            .view()
            .children()
            .any(|child| !matches!(child.kind(), MarkupKind::Quote))
        {
            return;
        }

        let name = view.token_at(index).text(self.source);
        let span = value.inner_span();

        if equals_ignore_case(name, b"id") {
            self.definition(span, node);

            return;
        }

        if LISTED.iter().any(|wanted| equals_ignore_case(name, wanted)) {
            for word in words(self.source, span) {
                self.use_of(word, node);
            }

            return;
        }

        if SINGULAR
            .iter()
            .any(|wanted| equals_ignore_case(name, wanted))
            && span.length > 0
            && words(self.source, span).count() == 1
        {
            self.use_of(span, node);

            return;
        }

        if FRAGMENT
            .iter()
            .any(|wanted| equals_ignore_case(name, wanted))
            && span.length > 1
            && self.source[span.offset as usize] == b'#'
        {
            self.use_of(
                Span {
                    length: span.length - 1,
                    offset: span.offset + 1,
                },
                node,
            );
        }
    }

    fn definition(&mut self, name: Span, node: u32) {
        let pushed = self.semantic.push_definition(Definition {
            kind: DefinitionKind::Id,
            name,
            name_hash: name_hash(&self.source[name.range()]),
            name_previous: NONE,
            node,
        });

        if !pushed {
            self.outcome = Structure::Truncated;
        }
    }

    fn use_of(&mut self, name: Span, node: u32) {
        if name.length == 0 {
            return;
        }

        let pushed = self.semantic.uses.push(Use {
            count: 0,
            definition: NONE,
            kind: UseKind::Id,
            name,
            node,
        });

        if !pushed {
            self.outcome = Structure::Truncated;
        }
    }
}

fn equals_ignore_case(held: &[u8], wanted: &[u8]) -> bool {
    held.len() == wanted.len()
        && held
            .iter()
            .zip(wanted.iter())
            .all(|(left, right)| left.to_ascii_lowercase() == *right)
}

fn words(source: &[u8], span: Span) -> impl Iterator<Item = Span> + use<'_> {
    let end = span.end();
    let mut offset = span.offset;

    core::iter::from_fn(move || {
        while offset < end && source[offset as usize].is_ascii_whitespace() {
            offset += 1;
        }

        if offset >= end {
            return None;
        }

        let from = offset;

        while offset < end && !source[offset as usize].is_ascii_whitespace() {
            offset += 1;
        }

        Some(Span {
            length: offset - from,
            offset: from,
        })
    })
}
