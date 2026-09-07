use crate::bounded::Span;
use crate::markup::kind::MarkupKind;
use crate::markup::token::Token;
use crate::markup::tree::Tree;
use crate::markup::view::{TemplateTag, View, unquote};
use crate::syntax::{Fact, FactKind, Facts};
use crate::tree::{NONE, Step, Structure, walk};

pub fn build(
    source: &[u8],
    tokens: &[Token],
    tree: &Tree,
    facts: &mut Facts,
    names: &[&[u8]],
    extends: &[&[u8]],
    only_word: &[u8],
) -> Structure {
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

        if !names_a_template(tag, view, source, names) {
            continue;
        }

        let kind = if names_a_template(tag, view, source, extends) {
            FactKind::Extends
        } else {
            FactKind::Include {
                only: names_only(tag, view, source, only_word),
            }
        };

        let pushed = facts.push(Fact {
            binding: NONE,
            kind,
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

fn names_a_template(
    tag: TemplateTag<'_, '_>,
    view: View<'_, '_>,
    source: &[u8],
    names: &[&[u8]],
) -> bool {
    let Some(index) = tag.name_token() else {
        return false;
    };

    let text = view.token_at(index).text(source);

    names.contains(&text)
}

fn names_only(tag: TemplateTag<'_, '_>, view: View<'_, '_>, source: &[u8], word: &[u8]) -> bool {
    if word.is_empty() {
        return false;
    }

    let mut found = false;
    let mut pending = false;

    for index in tag.argument_tokens() {
        let token = view.token_at(index);

        if pending && token.kind == MarkupKind::Equals {
            pending = false;

            continue;
        }

        found = found || pending;
        pending = token.kind == MarkupKind::Identifier && token.text(source) == word;
    }

    found || pending
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

    const EXTENDS: [&[u8]; 1] = [b"extends"];
    const ONLY: &[u8] = b"only";
    const TEMPLATE_IMPORTS: [&[u8]; 2] = [b"extends", b"include"];

    fn built(source: &[u8]) -> (Facts, Structure) {
        let mut tokens = Tokens::reserve(1 << 12);
        let mut tree = Tree::reserve(1 << 12, 1 << 6);
        let mut facts = Facts::reserve(1 << 6);

        markup::lex(source, &mut tokens);

        let structure = markup::tree::build(source, tokens.as_slice(), &mut tree);

        assert_eq!(structure, Structure::Complete);

        let outcome = build(
            source,
            tokens.as_slice(),
            &tree,
            &mut facts,
            &TEMPLATE_IMPORTS,
            &EXTENDS,
            ONLY,
        );

        (facts, outcome)
    }

    #[test]
    fn a_literal_extends_spans_its_whole_tag() {
        const SOURCE: &[u8] = b"{% extends 'base.html' %}\n<p>hello</p>\n";

        let (facts, outcome) = built(SOURCE);
        let fact = facts.as_slice()[0];

        assert_eq!(outcome, Structure::Complete);
        assert_eq!(facts.count(), 1);
        assert_eq!(fact.kind, FactKind::Extends);
        assert_eq!(&SOURCE[fact.local.range()], b"{% extends 'base.html' %}");
        assert_eq!(&SOURCE[fact.specifier.range()], b"base.html");
    }

    #[test]
    fn an_include_spans_its_whole_tag() {
        const SOURCE: &[u8] = b"<div>{% include \"parts/card.html\" %}</div>\n";

        let (facts, _) = built(SOURCE);
        let fact = facts.as_slice()[0];

        assert_eq!(facts.count(), 1);
        assert_eq!(fact.kind, FactKind::Include { only: false });

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
    fn an_include_with_the_only_word_says_so() {
        const SOURCE: &[u8] =
            b"{% include 'a.html' with x=1 only %}{% include 'b.html' with only=1 %}\n";

        let (facts, _) = built(SOURCE);
        let held = facts.as_slice();

        assert_eq!(held.len(), 2);
        assert_eq!(held[0].kind, FactKind::Include { only: true });
        assert_eq!(held[1].kind, FactKind::Include { only: false });
    }

    #[test]
    fn a_tag_that_names_no_template_is_no_fact() {
        const SOURCE: &[u8] = b"{% block body %}{% endblock %}\n{% load static %}\n";

        let (facts, _) = built(SOURCE);

        assert_eq!(facts.count(), 0);
    }
}
