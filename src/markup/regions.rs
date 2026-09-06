use crate::bounded::{BoundedVec, Span};
use crate::markup::kind::MarkupKind;
use crate::markup::token::Token;
use crate::markup::tree::{NONE, Tree};
use crate::markup::view::{Element, View};

const JAVASCRIPT_SCRIPT_TYPES: [&[u8]; 5] = [
    b"application/ecmascript",
    b"application/javascript",
    b"module",
    b"text/ecmascript",
    b"text/javascript",
];

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum RegionKind<A> {
    Attribute(A),
    ScriptText,
    StyleAttribute,
    StyleText,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Region<A> {
    pub hole_count: u32,
    pub hole_first: u32,
    pub kind: RegionKind<A>,
    pub node: u32,
    pub span: Span,
}

impl<A> Region<A> {
    pub fn holes<'holes>(&self, table: &'holes [Span]) -> &'holes [Span] {
        let first = self.hole_first as usize;
        let end = first + self.hole_count as usize;

        table.get(first..end).unwrap_or(&[])
    }

    pub fn text<'source>(&self, source: &'source [u8]) -> &'source [u8] {
        source.get(self.span.range()).unwrap_or(&[])
    }
}

pub fn regions<A>(
    tree: &Tree,
    tokens: &[Token],
    source: &[u8],
    attribute_of: &impl Fn(&[u8]) -> Option<A>,
    out: &mut BoundedVec<Region<A>>,
    holes: &mut BoundedVec<Span>,
) -> bool
where
    A: Copy,
{
    out.clear();
    holes.clear();

    let mut room = true;

    for index in 0..tree.count() {
        let view = View::new(tree, tokens, index);

        match view.kind() {
            MarkupKind::Attribute => {
                room = attribute_region(view, source, attribute_of, out, holes) && room;
            }
            MarkupKind::Element => room = element_region(view, source, out, holes) && room,
            _ => {}
        }
    }

    out.sort_unstable_by_key(|region| (region.span.offset, region.span.end()));

    room
}

fn attribute_region<A>(
    view: View<'_, '_>,
    source: &[u8],
    attribute_of: &impl Fn(&[u8]) -> Option<A>,
    out: &mut BoundedVec<Region<A>>,
    holes: &mut BoundedVec<Span>,
) -> bool
where
    A: Copy,
{
    let Some(attribute) = view.as_attribute() else {
        return true;
    };

    let Some(token) = attribute.name_token() else {
        return true;
    };

    let name = view.token_at(token).text(source);

    let Some(value) = attribute.value() else {
        return true;
    };

    let kind = if name.eq_ignore_ascii_case(b"style") {
        RegionKind::StyleAttribute
    } else {
        let Some(tag) = attribute_of(name) else {
            return true;
        };

        RegionKind::Attribute(tag)
    };

    let span = value.inner_span();

    if span.length == 0 {
        return true;
    }

    let hole_first = holes.count();
    let room = value.template_holes(holes);

    let pushed = out.push(Region {
        hole_count: holes.count() - hole_first,
        hole_first,
        kind,
        node: value.view().index(),
        span,
    });

    pushed && room
}

fn element_region<A>(
    view: View<'_, '_>,
    source: &[u8],
    out: &mut BoundedVec<Region<A>>,
    holes: &mut BoundedVec<Span>,
) -> bool {
    let Some(element) = view.as_element() else {
        return true;
    };

    let kind = if element.name_equals_ignore_case(b"script", source) {
        if !is_javascript(element, source) {
            return true;
        }

        RegionKind::ScriptText
    } else if element.name_equals_ignore_case(b"style", source) {
        RegionKind::StyleText
    } else {
        return true;
    };

    let Some(span) = content_span(view) else {
        return true;
    };

    let hole_first = holes.count();
    let room = content_holes(view, holes);

    let pushed = out.push(Region {
        hole_count: holes.count() - hole_first,
        hole_first,
        kind,
        node: view.index(),
        span,
    });

    pushed && room
}

fn content_holes(view: View<'_, '_>, holes: &mut BoundedVec<Span>) -> bool {
    let mut room = true;

    for child in view.children() {
        if !matches!(
            child.kind(),
            MarkupKind::TemplateComment | MarkupKind::TemplateTag | MarkupKind::TemplateVariable
        ) {
            continue;
        }

        room = holes.push(child.span()) && room;
    }

    room
}

fn content_span(view: View<'_, '_>) -> Option<Span> {
    let mut start = NONE;
    let mut end = NONE;

    for child in view.children() {
        if matches!(child.kind(), MarkupKind::OpenTag | MarkupKind::CloseTag) {
            continue;
        }

        widen(&mut start, &mut end, child.span());
    }

    for index in view.direct_tokens() {
        widen(&mut start, &mut end, view.token_at(index).span());
    }

    if start == NONE || end == NONE || end < start {
        return None;
    }

    Some(Span::between(start, end))
}

fn widen(start: &mut u32, end: &mut u32, span: Span) {
    *start = (*start).min(span.offset);
    *end = if *end == NONE {
        span.end()
    } else {
        (*end).max(span.end())
    };
}

fn is_javascript(element: Element<'_, '_>, source: &[u8]) -> bool {
    for attribute in element.attributes() {
        let Some(token) = attribute.name_token() else {
            continue;
        };

        let name = attribute.view().token_at(token).text(source);

        if !name.eq_ignore_ascii_case(b"type") {
            continue;
        }

        let Some(value) = attribute.value() else {
            return true;
        };

        let mut text = value.text_tokens();

        let Some(first) = text.next() else {
            return true;
        };

        if text.next().is_some() {
            return true;
        }

        let held = value.view().token_at(first).text(source).trim_ascii();

        return JAVASCRIPT_SCRIPT_TYPES
            .iter()
            .any(|known| known.eq_ignore_ascii_case(held));
    }

    true
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::markup::{self, Tokens};
    use crate::tree::Structure;

    #[derive(Clone, Copy, Debug, Eq, PartialEq)]
    enum Tag {
        Data,
        On,
    }

    fn tag_of(name: &[u8]) -> Option<Tag> {
        if name == b"x-data" {
            return Some(Tag::Data);
        }

        if name.starts_with(b"@") || name.starts_with(b"x-on:") {
            return Some(Tag::On);
        }

        None
    }

    struct Found {
        holes: BoundedVec<Span>,
        regions: BoundedVec<Region<Tag>>,
    }

    impl Found {
        fn holes_of(&self, index: usize) -> usize {
            self.regions[index].holes(&self.holes).len()
        }

        fn text_of<'source>(&self, index: usize, source: &'source [u8]) -> &'source [u8] {
            self.regions[index].text(source)
        }
    }

    fn found(source: &[u8]) -> Found {
        let mut tokens = Tokens::reserve(1 << 12);
        let mut tree = Tree::reserve(1 << 12, 1 << 6);

        markup::lex(source, &mut tokens);

        assert_eq!(
            markup::tree::build(source, tokens.as_slice(), &mut tree),
            Structure::Complete
        );

        let mut held = Found {
            holes: BoundedVec::reserve(1 << 8),
            regions: BoundedVec::reserve(1 << 6),
        };

        let room = regions(
            &tree,
            tokens.as_slice(),
            source,
            &tag_of,
            &mut held.regions,
            &mut held.holes,
        );

        assert!(room);

        held
    }

    #[test]
    fn a_tagged_attribute_value_is_a_region() {
        let source = b"<div x-data=\"{ open: false }\"></div>";
        let held = found(source);

        assert_eq!(held.regions.len(), 1);
        assert_eq!(held.regions[0].kind, RegionKind::Attribute(Tag::Data));
        assert_eq!(held.text_of(0, source), b"{ open: false }");
    }

    #[test]
    fn the_quotes_stay_outside_the_region() {
        let source = b"<button @click=\"save()\"></button>";
        let held = found(source);

        assert_eq!(held.regions[0].kind, RegionKind::Attribute(Tag::On));
        assert_eq!(held.text_of(0, source), b"save()");
    }

    #[test]
    fn a_template_hole_inside_a_value_is_recorded() {
        let held = found(b"<div x-data=\"{ n: {{ count }} }\"></div>");

        assert_eq!(held.regions.len(), 1);
        assert_eq!(held.holes_of(0), 1);
    }

    #[test]
    fn a_script_body_carries_its_holes() {
        let source = b"<script>const n = {{ count }};</script>";
        let held = found(source);

        assert_eq!(held.regions.len(), 1);
        assert_eq!(held.regions[0].kind, RegionKind::ScriptText);
        assert_eq!(held.text_of(0, source), b"const n = {{ count }};");
        assert_eq!(held.holes_of(0), 1);
    }

    #[test]
    fn a_script_that_carries_data_is_skipped() {
        let held = found(b"<script type=\"application/json\">{\"a\": 1}</script>");

        assert!(held.regions.is_empty());
    }

    #[test]
    fn a_module_script_is_kept() {
        let held = found(b"<script type=\"module\">export const a = 1;</script>");

        assert_eq!(held.regions.len(), 1);
    }

    #[test]
    fn a_style_element_precedes_a_style_attribute() {
        let held = found(b"<style>.a { color: red; }</style><div style=\"color: red\"></div>");

        assert_eq!(held.regions.len(), 2);
        assert_eq!(held.regions[0].kind, RegionKind::StyleText);
        assert_eq!(held.regions[1].kind, RegionKind::StyleAttribute);
    }

    #[test]
    fn a_plain_attribute_is_not_a_region() {
        let held = found(b"<a href=\"/x\" class=\"btn\">go</a>");

        assert!(held.regions.is_empty());
    }

    #[test]
    fn an_attribute_the_caller_declines_is_not_a_region() {
        let held = found(b"<div x-ref=\"rowHost\" x-transition:enter=\"fade-in\"></div>");

        assert!(held.regions.is_empty());
    }

    #[test]
    fn an_empty_value_is_not_a_region() {
        let held = found(b"<div x-data=\"\"></div>");

        assert!(held.regions.is_empty());
    }
}
