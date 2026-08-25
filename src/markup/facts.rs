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

        let Some(specifier) = specifier_of(tag, view, source) else {
            continue;
        };

        let pushed = facts.push(Fact {
            binding: NONE,
            kind: FactKind::ImportSideEffect,
            local: Span::EMPTY,
            remote: Span::EMPTY,
            specifier,
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
