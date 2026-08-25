#[path = "common/golden.rs"]
mod common;

#[path = "common/residue.rs"]
mod residue;

use scylla::markup::tree::{self, Step, Structure, Tree};
use scylla::markup::{self, MarkupKind, NONE, Node, Token, Tokens};

const ERROR_COUNT_MAX: u32 = 1 << 10;
const NODE_COUNT_MAX: u32 = 1 << 17;
const TOKEN_COUNT_MAX: u32 = 1 << 18;

#[test]
fn every_fixture_builds_the_node_walk_the_oracle_recorded() {
    let mut tokens = Tokens::reserve(TOKEN_COUNT_MAX);
    let mut built = Tree::reserve(NODE_COUNT_MAX, ERROR_COUNT_MAX);
    let residue = residue::residue("residue.json");
    let mut classified = 0;

    for fixture in &common::fixtures() {
        markup::lex(&fixture.source, &mut tokens);

        let outcome = tree::build(&fixture.source, tokens.as_slice(), &mut built);

        assert_eq!(outcome, Structure::Complete, "{}", fixture.name);

        let walk = built.as_slice();
        let recorded = &fixture.golden.tree;

        if residue.contains(&fixture.name) {
            classified += 1;

            continue;
        }

        assert_eq!(
            walk.len(),
            recorded.len(),
            "{}: the node counts differ",
            fixture.name
        );

        for (index, (node, row)) in walk.iter().zip(recorded.iter()).enumerate() {
            let span = node.span(tokens.as_slice());

            assert_eq!(
                node.kind,
                MarkupKind::of_name(&row.0).expect("the oracle names a kind the library carries"),
                "{}: node {index} differs in kind",
                fixture.name
            );

            assert_eq!(
                span.offset,
                row.1,
                "{}: node {index} ({}) differs in start",
                fixture.name,
                row.0,
            );

            assert_eq!(
                span.end(),
                row.2,
                "{}: node {index} ({}) differs in end",
                fixture.name,
                row.0
            );
        }
    }

    assert_eq!(
        classified,
        residue.len(),
        "tests/residue.json names a fixture the corpus does not carry"
    );
}

#[test]
fn every_fixture_records_the_errors_the_oracle_recorded() {
    let mut tokens = Tokens::reserve(TOKEN_COUNT_MAX);
    let mut built = Tree::reserve(NODE_COUNT_MAX, ERROR_COUNT_MAX);
    let residue = residue::residue("residue.json");

    for fixture in &common::fixtures() {
        if residue.contains(&fixture.name) {
            continue;
        }

        markup::lex(&fixture.source, &mut tokens);
        tree::build(&fixture.source, tokens.as_slice(), &mut built);

        let recorded = &fixture.golden.errors;
        let found = built.errors();

        assert_eq!(
            found.len(),
            recorded.len(),
            "{}: the error counts differ",
            fixture.name
        );

        for (index, (error, row)) in found.iter().zip(recorded.iter()).enumerate() {
            assert_eq!(
                error.kind.name(),
                row.0,
                "{}: error {index} differs in kind",
                fixture.name
            );

            assert_eq!(
                error.span.offset,
                row.1,
                "{}: error {index} differs in offset",
                fixture.name
            );
        }
    }
}

#[test]
fn every_fixture_walks_the_order_the_links_describe() {
    let mut tokens = Tokens::reserve(TOKEN_COUNT_MAX);
    let mut built = Tree::reserve(NODE_COUNT_MAX, ERROR_COUNT_MAX);

    for fixture in &common::fixtures() {
        markup::lex(&fixture.source, &mut tokens);
        tree::build(&fixture.source, tokens.as_slice(), &mut built);

        let walked: Vec<Step> = tree::walk(&built).collect();

        assert_eq!(walked, reference_order(&built), "{}", fixture.name);
        assert_eq!(walked.len(), 2 * built.count() as usize, "{}", fixture.name);

        for node in 0..built.count() {
            let subtree: Vec<Step> = tree::walk_from(&built, node).collect();

            let enter = walked
                .iter()
                .position(|step| *step == Step::Enter(node))
                .expect("the full walk enters every node");

            let leave = walked
                .iter()
                .position(|step| *step == Step::Leave(node))
                .expect("the full walk leaves every node");

            assert_eq!(subtree, walked[enter..=leave], "{}", fixture.name);
        }
    }
}

fn reference_order(built: &Tree) -> Vec<Step> {
    let mut order = Vec::new();
    let mut stack = Vec::new();

    for node in (0..built.count()).rev() {
        if built.at(node).parent == NONE {
            stack.push(Step::Enter(node));
        }
    }

    while let Some(step) = stack.pop() {
        order.push(step);

        let Step::Enter(node) = step else {
            continue;
        };

        stack.push(Step::Leave(node));

        let mut children = Vec::new();
        let mut child = built.at(node).child_first;

        while child != NONE {
            children.push(child);
            child = built.at(child).sibling_next;
        }

        for last in children.into_iter().rev() {
            stack.push(Step::Enter(last));
        }
    }

    order
}

#[test]
fn a_parent_covers_its_children_and_siblings_never_overlap() {
    let mut tokens = Tokens::reserve(TOKEN_COUNT_MAX);
    let mut built = Tree::reserve(NODE_COUNT_MAX, ERROR_COUNT_MAX);

    for fixture in &common::fixtures() {
        markup::lex(&fixture.source, &mut tokens);
        tree::build(&fixture.source, tokens.as_slice(), &mut built);

        invariants_hold(&built, tokens.as_slice(), &fixture.name);
    }
}

#[test]
fn byte_soup_builds_a_tree_that_holds_its_invariants() {
    let mut random = scylla::bounded::Random::new(0x0DDB_1A9F_4C1D_9CF3);
    let mut tokens = Tokens::reserve(TOKEN_COUNT_MAX);
    let mut built = Tree::reserve(NODE_COUNT_MAX, ERROR_COUNT_MAX);
    let alphabet = b"<>/=\"'{}%#|:,. \n\t-!pdivlitroption";

    for case in 0..512 {
        let length = random.below(256) as usize;
        let mut source = Vec::with_capacity(length);

        for _ in 0..length {
            let index = random.below(u32::try_from(alphabet.len()).expect("the alphabet is small"))
                as usize;

            source.push(alphabet[index]);
        }

        markup::lex(&source, &mut tokens);
        tree::build(&source, tokens.as_slice(), &mut built);
        invariants_hold(&built, tokens.as_slice(), &format!("soup {case}"));
    }
}

#[test]
fn a_starved_node_budget_truncates_rather_than_overrunning() {
    let fixture = common::fixtures()
        .into_iter()
        .max_by_key(|fixture| fixture.golden.tree.len())
        .expect("the corpus is not empty");

    let mut tokens = Tokens::reserve(TOKEN_COUNT_MAX);
    let mut starved = Tree::reserve(4, ERROR_COUNT_MAX);

    markup::lex(&fixture.source, &mut tokens);

    assert_eq!(
        tree::build(&fixture.source, tokens.as_slice(), &mut starved),
        Structure::Truncated
    );

    assert!(starved.count() <= 4);
}

fn invariants_hold(built: &Tree, tokens: &[Token], name: &str) {
    let walk = built.as_slice();

    for (position, node) in walk.iter().enumerate() {
        let index = u32::try_from(position).expect("the tree is bounded");
        let span = node.span(tokens);

        assert!(
            node.token_start <= node.token_end,
            "{name}: node {index} runs backwards"
        );

        assert!(
            node.token_end as usize <= tokens.len(),
            "{name}: node {index} ends past the stream"
        );

        if node.parent != NONE {
            let parent = walk[node.parent as usize];
            let outer = parent.span(tokens);

            assert!(
                outer.offset <= span.offset,
                "{name}: node {index} starts before its parent"
            );
            assert!(
                span.end() <= outer.end(),
                "{name}: node {index} ends after its parent"
            );

            assert!(
                node.parent < index,
                "{name}: node {index} names a parent that comes after it"
            );
        }

        children_are_disjoint(walk, node, tokens, name, index);
    }
}

fn children_are_disjoint(walk: &[Node], node: &Node, tokens: &[Token], name: &str, index: u32) {
    let mut child = node.child_first;
    let mut end_previous = 0;
    let mut seen = 0;

    while child != NONE {
        assert!(
            seen <= walk.len(),
            "{name}: node {index} has a sibling cycle"
        );

        let found = walk[child as usize];
        let span = found.span(tokens);

        assert_eq!(
            found.parent,
            index,
            "{name}: node {child} is not its parent's child"
        );

        assert!(
            span.offset >= end_previous,
            "{name}: node {child} overlaps the sibling before it"
        );

        end_previous = span.end();
        child = found.sibling_next;
        seen += 1;
    }
}
