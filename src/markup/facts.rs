use crate::bounded::Span;
use crate::markup::kind::MarkupKind;
use crate::markup::token::Token;
use crate::markup::tree::Tree;
use crate::markup::view::{TemplateTag, View, unquote};
use crate::syntax::{Fact, FactKind, Facts};
use crate::tree::{NONE, Step, Structure, walk};

const NAMES: [&[u8]; 2] = [b"extends", b"include"];

pub fn build(source: &[u8], tokens: &[Token], tree: &Tree, facts: &mut Facts) -> Structure {
    facts.clear();

    assert_eq!(facts.count(), 0);

    let mut outcome = Structure::Complete;

    for step in walk(tree) {
        let Step::Enter(node) = step else {
            continue;
        };

        let view = View::new(tree, tokens, node);

        let Some(tag) = view.as_template_tag() else {
            continue;
        };

        if !names_a_template(tag, view, source) {
            continue;
        }

        let pushed = facts.push(Fact {
            binding: NONE,
            kind: FactKind::ImportSideEffect,
            local: view.span(),
            remote: Span::EMPTY,
            specifier: specifier_of(tag, view, source).unwrap_or(Span::EMPTY),
        });

        if !pushed {
            outcome = Structure::Truncated;
        }
    }

    outcome
}

fn names_a_template(tag: TemplateTag<'_, '_>, view: View<'_, '_>, source: &[u8]) -> bool {
    let Some(index) = tag.name_token() else {
        return false;
    };

    let text = view.token_at(index).text(source);

    NAMES.contains(&text)
}

fn specifier_of(tag: TemplateTag<'_, '_>, view: View<'_, '_>, source: &[u8]) -> Option<Span> {
    for index in tag.argument_tokens() {
        let token = view.token_at(index);

        if token.kind != MarkupKind::String {
            continue;
        }

        return unquote(token, source);
    }

    None
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::markup::{self, Tokens};
    use crate::syntax::Facts;

    fn built(source: &[u8]) -> (Facts, Structure) {
        let mut tokens = Tokens::reserve(1 << 12);
        let mut tree = Tree::reserve(1 << 12, 1 << 6);
        let mut facts = Facts::reserve(1 << 6);

        markup::lex(source, &mut tokens);

        let structure = markup::tree::build(source, tokens.as_slice(), &mut tree);

        assert_eq!(structure, Structure::Complete);

        let outcome = build(source, tokens.as_slice(), &tree, &mut facts);

        (facts, outcome)
    }

    #[test]
    fn a_literal_extends_spans_its_whole_tag() {
        const SOURCE: &[u8] = b"{% extends 'base.html' %}\n<p>hello</p>\n";

        let (facts, outcome) = built(SOURCE);
        let fact = facts.as_slice()[0];

        assert_eq!(outcome, Structure::Complete);
        assert_eq!(facts.count(), 1);
        assert_eq!(&SOURCE[fact.local.range()], b"{% extends 'base.html' %}");
        assert_eq!(&SOURCE[fact.specifier.range()], b"base.html");
    }

    #[test]
    fn an_include_spans_its_whole_tag() {
        const SOURCE: &[u8] = b"<div>{% include \"parts/card.html\" %}</div>\n";

        let (facts, _) = built(SOURCE);
        let fact = facts.as_slice()[0];

        assert_eq!(facts.count(), 1);

        assert_eq!(
            &SOURCE[fact.local.range()],
            b"{% include \"parts/card.html\" %}"
        );

        assert_eq!(&SOURCE[fact.specifier.range()], b"parts/card.html");
    }

    #[test]
    fn a_dynamic_target_keeps_its_tag_and_names_no_specifier() {
        const SOURCE: &[u8] = b"{% extends parent %}\n<p>hello</p>\n";

        let (facts, _) = built(SOURCE);
        let fact = facts.as_slice()[0];

        assert_eq!(facts.count(), 1);
        assert_eq!(&SOURCE[fact.local.range()], b"{% extends parent %}");
        assert_eq!(fact.specifier, Span::EMPTY);
    }

    #[test]
    fn a_tag_that_names_no_template_is_no_fact() {
        const SOURCE: &[u8] = b"{% block body %}{% endblock %}\n{% load static %}\n";

        let (facts, _) = built(SOURCE);

        assert_eq!(facts.count(), 0);
    }
}
