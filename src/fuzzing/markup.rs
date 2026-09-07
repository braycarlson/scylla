use crate::fuzzing::parse::{links_hold, walk_holds};
use crate::markup::blocks::{self, BlockMap, TagSpecification};
use crate::markup::tree::{self, Tree};
use crate::markup::{self, RawTextTag, Token, Tokens};
use crate::token::Lex;

#[expect(
    clippy::struct_field_names,
    reason = "the `_max` postfix is the big-endian convention naming the bound each field carries"
)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Limits {
    pub block_count_max: u32,
    pub error_count_max: u32,
    pub node_count_max: u32,
    pub token_count_max: u32,
}

pub const LIMITS_DEFAULT: Limits = Limits {
    block_count_max: 1 << 13,
    error_count_max: 1 << 10,
    node_count_max: 1 << 17,
    token_count_max: 1 << 18,
};

const END_PREFIX: &[u8] = b"end";
const INTERMEDIATE_WORDS: [&[u8]; 2] = [b"else", b"empty"];
const RAW_TEXT_TAGS: [RawTextTag<'static>; 1] = [(b"raw", b"endraw")];

const SPECIFICATIONS: [TagSpecification; 2] = [
    TagSpecification {
        intermediates: &[b"empty"],
        name: b"for",
    },
    TagSpecification {
        intermediates: &[b"else"],
        name: b"if",
    },
];

pub struct MarkupHarness {
    limits: Limits,
    map: BlockMap,
    tokens: Tokens,
    tree: Tree,
}

impl MarkupHarness {
    pub fn reserve(limits: &Limits) -> Self {
        assert!(limits.node_count_max > 0);
        assert!(limits.token_count_max > 0);
        assert!(!crate::allocation::is_frozen());

        Self {
            limits: *limits,
            map: BlockMap::reserve(limits.block_count_max),
            tokens: Tokens::reserve(limits.token_count_max),
            tree: Tree::reserve(limits.node_count_max, limits.error_count_max),
        }
    }

    pub fn check(&mut self, source: &[u8]) {
        assert!(self.limits.token_count_max > 0);

        if u32::try_from(source.len()).is_err() {
            return;
        }

        let outcome = markup::lex_with(source, &mut self.tokens, &RAW_TEXT_TAGS);

        tiles(source, self.tokens.as_slice(), outcome);
        tree::build(source, self.tokens.as_slice(), &mut self.tree);

        blocks::build(
            source,
            self.tokens.as_slice(),
            &self.tree,
            &SPECIFICATIONS,
            &INTERMEDIATE_WORDS,
            END_PREFIX,
            &mut self.map,
        );

        links_hold(&self.tree);
        walk_holds(&self.tree);
        nodes_hold(&self.tree, self.tokens.as_slice(), source);
        blocks_hold(&self.map, source);

        assert!(
            self.tree.errors().len() <= self.limits.error_count_max as usize,
            "the error table outgrew its capacity"
        );

        for error in self.tree.errors() {
            assert!(
                error.span.end() as usize <= source.len(),
                "an error reaches past the input"
            );

            assert!(
                error.name.end() as usize <= source.len(),
                "an error names a span past the input"
            );
        }
    }
}

fn blocks_hold(map: &BlockMap, source: &[u8]) {
    let end = u32::try_from(source.len()).expect("the source was bounded before pairing");
    let mut previous = (0_u32, 0_u32);

    for (index, block) in map.blocks().iter().enumerate() {
        let key = (block.span.offset, block.span.end());

        assert!(
            block.span.end() <= end,
            "block {index} reaches past the file it was paired in"
        );

        assert!(key >= previous, "block {index} is out of order");
        assert!(block.open.span.end() <= end, "block {index} opens past the input");

        assert!(
            block.close.is_none() || block.close.span.end() <= end,
            "block {index} closes past the input"
        );

        assert!(
            block.open.span.offset == block.span.offset,
            "block {index} does not start at its opener"
        );

        assert!(
            map.intermediates_of(block).len() == block.intermediate_count as usize,
            "block {index} names intermediates it does not hold"
        );

        previous = key;
    }

    for tag in map.tags() {
        assert!(tag.span.end() <= end, "a tag reaches past the input");
    }
}

fn nodes_hold(tree: &Tree, tokens: &[Token], source: &[u8]) {
    let end = u32::try_from(source.len()).expect("the source was bounded before building");

    for index in 0..tree.count() {
        let node = tree.at(index);

        assert!(
            node.token_start <= node.token_end,
            "node {index} runs backwards"
        );

        assert!(
            node.token_end as usize <= tokens.len(),
            "node {index} ends past the stream"
        );

        let span = node.span(tokens);

        assert!(span.end() <= end, "node {index} reaches past the input");

        if node.parent != crate::tree::NONE {
            let outer = tree.at(node.parent).span(tokens);

            assert!(
                outer.offset <= span.offset && span.end() <= outer.end(),
                "node {index} escapes its parent"
            );
        }
    }
}

fn tiles(source: &[u8], tokens: &[Token], outcome: Lex) {
    let mut end_previous = 0;

    for (index, token) in tokens.iter().enumerate() {
        assert_eq!(
            token.offset, end_previous,
            "token {index} leaves a gap or overlaps"
        );

        assert!(token.length > 0, "token {index} covers no byte");

        end_previous = token.end();
    }

    assert!(
        end_previous as usize <= source.len(),
        "the stream runs past the source"
    );

    if outcome == Lex::Complete {
        assert_eq!(
            end_previous as usize,
            source.len(),
            "the stream stops short of the source end"
        );
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_harness_accepts_a_paired_template() {
        let mut harness = MarkupHarness::reserve(&Limits {
            block_count_max: 1 << 6,
            error_count_max: 1 << 4,
            node_count_max: 1 << 10,
            token_count_max: 1 << 10,
        });

        harness.check(b"{% if a %}<p>{% raw %}{{ x }}{% endraw %}</p>{% else %}b{% endif %}<div>");
        harness.check(b"{% endif %}{% for %}<!-- ");
        harness.check(b"");
    }
}
