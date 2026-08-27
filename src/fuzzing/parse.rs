use crate::bounded::{BoundedVec, count_of};
use crate::language::Lexer;
use crate::syntax::Structure;
use crate::token::{Token, Tokens};
use crate::tree::{Events, Kind, NONE, Step, Tree, walk};
use crate::trivia::{self, Gap};

pub type Build<K> = fn(&[u8], &[Token], &[K], &mut Events<K>, &mut Tree<K>) -> Structure;
pub type Classify<K> = fn(&[u8], &[Token], &mut Tokens, &mut BoundedVec<K>) -> bool;

#[expect(
    clippy::struct_field_names,
    reason = "the `_max` postfix is the big-endian convention naming the bound each field carries"
)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Limits {
    pub error_count_max: u32,
    pub event_count_max: u32,
    pub node_count_max: u32,
    pub token_count_max: u32,
}

pub const LIMITS_DEFAULT: Limits = Limits {
    error_count_max: 1 << 10,
    event_count_max: 1 << 19,
    node_count_max: 1 << 16,
    token_count_max: 1 << 16,
};

pub struct ParseHarness<K: Kind> {
    events: Events<K>,
    events_again: Events<K>,
    lexed: Tokens,
    limits: Limits,
    raw: BoundedVec<K>,
    raw_again: BoundedVec<K>,
    tokens: Tokens,
    tokens_again: Tokens,
    tree: Tree<K>,
    tree_again: Tree<K>,
}

impl<K: Kind + core::fmt::Debug> ParseHarness<K> {
    pub fn reserve(limits: &Limits) -> Self {
        assert!(limits.node_count_max > 0);
        assert!(limits.token_count_max > 0);
        assert!(!crate::allocation::is_frozen());

        Self {
            events: Events::reserve(limits.event_count_max),
            events_again: Events::reserve(limits.event_count_max),
            lexed: Tokens::reserve(limits.token_count_max),
            limits: *limits,
            raw: BoundedVec::reserve(limits.token_count_max),
            raw_again: BoundedVec::reserve(limits.token_count_max),
            tokens: Tokens::reserve(limits.token_count_max),
            tokens_again: Tokens::reserve(limits.token_count_max),
            tree: Tree::reserve(limits.node_count_max, limits.error_count_max),
            tree_again: Tree::reserve(limits.node_count_max, limits.error_count_max),
        }
    }

    pub fn check(
        &mut self,
        lexer: &dyn Lexer,
        classify: Classify<K>,
        build: Build<K>,
        source: &[u8],
    ) {
        assert!(self.limits.token_count_max > 0);

        if u32::try_from(source.len()).is_err() {
            return;
        }

        self.lexed.clear();
        lexer.lex(source, &mut self.lexed);

        if !classify(
            source,
            self.lexed.as_slice(),
            &mut self.tokens,
            &mut self.raw,
        ) {
            self.overflowed(lexer, classify, source);

            return;
        }

        assert_eq!(
            self.tokens.as_slice().len(),
            self.raw.len(),
            "the classified stream and the kind table differ in length"
        );

        self.tree.clear();

        let outcome = build(
            source,
            self.tokens.as_slice(),
            &self.raw,
            &mut self.events,
            &mut self.tree,
        );

        assert!(matches!(
            outcome,
            Structure::Complete | Structure::TooDeep | Structure::Truncated
        ));

        spans_hold(&self.tree, self.tokens.as_slice(), source);
        links_hold(&self.tree);
        walk_holds(&self.tree);

        assert!(
            self.tree.errors().len() <= self.limits.error_count_max as usize,
            "the error table outgrew its capacity"
        );

        self.repeats(lexer, classify, build, source, outcome);
    }

    fn overflowed(&mut self, lexer: &dyn Lexer, classify: Classify<K>, source: &[u8]) {
        let length = count_of(source.len());
        let consumed = self.tokens.as_slice().last().map_or(0, Token::end);

        assert!(
            consumed <= length,
            "an overflowed stream runs past the source"
        );

        for (index, token) in self.tokens.as_slice().iter().enumerate() {
            assert!(
                token.end() <= length,
                "token {index} of an overflowed stream runs past the source"
            );
        }

        let mut covered = 0;
        let mut end_previous = 0;

        for (count, Gap { span, token }) in
            trivia::gaps(consumed, self.tokens.as_slice()).enumerate()
        {
            assert!(
                span.offset >= end_previous,
                "an overflowed stream runs its gaps backwards"
            );

            assert_eq!(
                u64::from(token),
                count as u64,
                "an overflowed stream numbers its gaps out of order"
            );

            covered += span.length;
            end_previous = span.end();
        }

        for token in self.tokens.as_slice() {
            covered += token.length;
        }

        assert_eq!(
            covered, consumed,
            "the tokens and the gaps do not tile the consumed prefix"
        );

        self.lexed.clear();
        lexer.lex(source, &mut self.lexed);

        assert!(
            !classify(
                source,
                self.lexed.as_slice(),
                &mut self.tokens_again,
                &mut self.raw_again
            ),
            "a second run of an overflowed classification does not overflow"
        );

        let repeated = self.tokens_again.as_slice().last().map_or(0, Token::end);

        assert_eq!(repeated, consumed, "a second run overflows at another byte");
    }

    fn repeats(
        &mut self,
        lexer: &dyn Lexer,
        classify: Classify<K>,
        build: Build<K>,
        source: &[u8],
        outcome: Structure,
    ) {
        self.lexed.clear();
        lexer.lex(source, &mut self.lexed);

        assert!(classify(
            source,
            self.lexed.as_slice(),
            &mut self.tokens_again,
            &mut self.raw_again
        ));

        self.tree_again.clear();

        let repeated = build(
            source,
            self.tokens_again.as_slice(),
            &self.raw_again,
            &mut self.events_again,
            &mut self.tree_again,
        );

        assert_eq!(repeated, outcome, "a second run differs");

        assert!(
            self.events.as_slice() == self.events_again.as_slice(),
            "a second run records other events"
        );

        assert!(
            self.tree.as_slice() == self.tree_again.as_slice(),
            "a second run builds another tree"
        );
    }
}

pub fn links_hold<K>(tree: &Tree<K>)
where
    K: Kind,
{
    let count = tree.count();

    for index in 0..count {
        let node = tree.at(index);

        assert!(
            node.child_first == NONE || node.child_first < count,
            "node {index} names a child out of bounds"
        );

        assert!(
            node.parent == NONE || node.parent < count,
            "node {index} names a parent out of bounds"
        );

        assert!(
            node.sibling_next == NONE || node.sibling_next < count,
            "node {index} names a sibling out of bounds"
        );
    }
}

pub fn spans_hold<K>(tree: &Tree<K>, tokens: &[Token], source: &[u8])
where
    K: Kind,
{
    let count = tree.count();

    for index in 0..count {
        let node = tree.at(index);

        assert!(
            node.token_start <= node.token_end,
            "node {index} closes before it opens"
        );

        assert!(
            node.token_end as usize <= tokens.len(),
            "node {index} names a token out of bounds"
        );

        let span = node.span(tokens);

        assert!(
            span.end() as usize <= source.len(),
            "node {index} spans past the source"
        );
    }
}

pub fn walk_holds<K>(tree: &Tree<K>)
where
    K: Kind,
{
    let walked = walk(tree).count();

    assert_eq!(
        walked,
        2 * tree.count() as usize,
        "the walk and the node count disagree"
    );

    for step in walk(tree) {
        match step {
            Step::Enter(node) | Step::Leave(node) => {
                assert!(node < tree.count(), "the walk names a node out of bounds");
            }
        }
    }
}
