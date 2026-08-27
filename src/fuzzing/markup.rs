use crate::fuzzing::parse::{links_hold, walk_holds};
use crate::markup::blocks::{self, BlockMap};
use crate::markup::tree::{self, Tree};
use crate::markup::{self, Token, Tokens};
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

        let outcome = markup::lex(source, &mut self.tokens);

        tiles(source, self.tokens.as_slice(), outcome);
        tree::build(source, self.tokens.as_slice(), &mut self.tree);

        blocks::build(
            source,
            self.tokens.as_slice(),
            &self.tree,
            &[],
            &[],
            &mut self.map,
        );

        links_hold(&self.tree);
        walk_holds(&self.tree);

        assert!(
            self.tree.errors().len() <= self.limits.error_count_max as usize,
            "the error table outgrew its capacity"
        );
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
