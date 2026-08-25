#[path = "common/extraction.rs"]
mod common;

#[path = "common/residue.rs"]
mod residue;

use common::{Binding, Member, Object};
use scylla::bounded::{BoundedVec, Span};
use scylla::brackets::Pairs;
use scylla::language::Lexer as _;
use scylla::lex::JAVASCRIPT;
use scylla::markup::tree::{self, Tree};
use scylla::markup::view::{Element, View};
use scylla::markup::{self, MarkupKind, Tokens as MarkupTokens};
use scylla::mask;
use scylla::outline::javascript::{self, DeclarationKind, Outline, ScopeKind};
use scylla::token::Tokens;

const ERROR_COUNT_MAX: u32 = 1 << 10;
const HOLE_COUNT_MAX: u32 = 1 << 10;
const MARKUP_TOKEN_COUNT_MAX: u32 = 1 << 18;
const NODE_COUNT_MAX: u32 = 1 << 17;
const REGION_BYTES_MAX: usize = 1 << 20;
const ROW_COUNT_MAX: u32 = 1 << 12;
const SEGMENT_COUNT_MAX: u32 = 1 << 13;
const TOKEN_COUNT_MAX: u32 = 1 << 16;
const DATA_ATTRIBUTE: &[u8] = b"x-data";
const INIT_MEMBER: &[u8] = b"init";
const SCRIPT_ELEMENT: &[u8] = b"script";
const TYPE_ATTRIBUTE: &[u8] = b"type";

const JAVASCRIPT_TYPES: [&[u8]; 5] = [
    b"application/javascript",
    b"module",
    b"text/babel",
    b"text/ecmascript",
    b"text/javascript",
];

struct Region {
    holes: Vec<Span>,
    is_data: bool,
    span: Span,
}

struct Prepared {
    outline: Outline,
    pairs: Pairs,
    text: Vec<u8>,
    tokens: Vec<scylla::token::Token>,
}

#[test]
fn every_x_data_object_the_oracle_recorded_comes_back_member_for_member() {
    let residue = residue::residue("residue-extraction.json");
    let mut compared = 0;
    let mut skipped = 0;

    for case in &common::extractions("html") {
        if residue.contains(&case.name) {
            skipped += 1;

            continue;
        }

        let found = objects_of(&case.source);

        assert_eq!(
            found.len(),
            case.extraction.objects.len(),
            "{}: the object counts differ\n{found:#?}\n{:#?}",
            case.name,
            case.extraction.objects
        );

        for (index, (built, recorded)) in
            found.iter().zip(case.extraction.objects.iter()).enumerate()
        {
            assert_eq!(built, recorded, "{}: object {index} differs", case.name);

            compared += 1;
        }
    }

    assert_eq!(
        skipped,
        1,
        "the residue names a fixture the corpus does not carry"
    );

    assert_eq!(compared, 25, "the corpus lost its x-data objects");
}

#[test]
fn every_binding_the_oracle_recorded_comes_back_field_for_field() {
    let residue = residue::residue("residue-extraction.json");
    let mut compared = 0;

    for case in &common::extractions("html") {
        if residue.contains(&case.name) {
            continue;
        }

        let found = bindings_of(&case.source);

        assert_eq!(
            found.len(),
            case.extraction.bindings.len(),
            "{}: the binding counts differ\n{found:#?}\n{:#?}",
            case.name,
            case.extraction.bindings
        );

        for (index, (built, recorded)) in found
            .iter()
            .zip(case.extraction.bindings.iter())
            .enumerate()
        {
            assert_eq!(built, recorded, "{}: binding {index} differs", case.name);

            compared += 1;
        }
    }

    assert_eq!(compared, 13, "the corpus lost its bindings");
}

fn objects_of(source: &[u8]) -> Vec<Object> {
    let mut found = Vec::new();

    for region in regions(source) {
        if !region.is_data {
            continue;
        }

        let prepared = prepare(source, &region);

        let Some(object) = prepared.outline.objects().first().copied() else {
            continue;
        };

        let Some(members) = members_of(&prepared, &object, region.span.offset) else {
            continue;
        };

        found.push(Object {
            members,
            range: (
                region.span.offset + prepared.tokens[object.brace_open as usize].offset,
                region.span.offset + prepared.tokens[object.brace_close as usize].end(),
            ),
        });
    }

    found.sort_by_key(|object| object.range);

    found
}

fn members_of(
    prepared: &Prepared,
    object: &javascript::ObjectLiteral,
    base: u32,
) -> Option<Vec<Member>> {
    let mut found = Vec::new();

    for member in prepared.outline.members_of(object) {
        if member.is_spread || member.name == Span::EMPTY {
            return None;
        }

        let has_colon = !member.is_shorthand && !member.is_method;

        if has_colon && member.value_token_start >= member.value_token_end {
            return None;
        }

        let name = unquoted(&prepared.text, member.name);
        let is_function = member.is_method || holds_function(prepared, member);

        let kind = if name == INIT_MEMBER {
            "Init"
        } else if is_function {
            "Method"
        } else {
            "Property"
        };

        found.push(Member {
            has_await: is_function && member.has_await,
            is_async: is_function && member.is_async,
            kind: kind.to_owned(),
            name: String::from_utf8_lossy(name).into_owned(),
            range: (
                base + prepared.tokens[member.token_start as usize].offset,
                base + prepared.tokens[member.token_end as usize - 1].end(),
            ),
        });
    }

    Some(found)
}

fn holds_function(prepared: &Prepared, member: &javascript::Member) -> bool {
    for scope in prepared.outline.scopes() {
        if scope.kind != ScopeKind::Function {
            continue;
        }

        if scope.token_start == member.value_token_start
            && scope.token_end <= member.value_token_end
        {
            return true;
        }
    }

    false
}

fn bindings_of(source: &[u8]) -> Vec<Binding> {
    let mut found = Vec::new();

    for region in &regions(source) {
        let prepared = prepare(source, region);
        let base = region.span.offset;

        for declaration in prepared.outline.declarations() {
            let kind = binding_kind(declaration.kind);
            let scope = scope_range(&prepared, declaration, region);

            found.push(Binding {
                initializer: chain_of(&prepared, declaration),
                kind: kind.to_owned(),
                name: String::from_utf8_lossy(&prepared.text[declaration.name.range()])
                    .into_owned(),
                name_range: (
                    base + declaration.name.offset,
                    base + declaration.name.end(),
                ),
                scope_range: scope,
            });
        }
    }

    found.sort_by_key(|binding| binding.name_range);

    found
}

fn scope_range(
    prepared: &Prepared,
    declaration: &javascript::Declaration,
    region: &Region,
) -> (u32, u32) {
    let base = region.span.offset;

    if declaration.scope_token_start == 0
        && declaration.scope_token_end as usize >= prepared.tokens.len()
        && !prepared.tokens.is_empty()
    {
        return (base + prepared.tokens[0].offset, region.span.end());
    }

    let first = prepared.tokens[declaration.scope_token_start as usize].offset;
    let last = prepared.tokens[declaration.scope_token_end as usize - 1].end();

    (base + first, base + last)
}

fn chain_of(prepared: &Prepared, declaration: &javascript::Declaration) -> Vec<String> {
    let start = declaration.value_token_start;
    let end = declaration.value_token_end;

    if start >= end {
        return Vec::new();
    }

    let mut segments = Vec::new();
    let mut index = start;

    while index < end {
        let token = prepared.tokens[index as usize];

        if token.kind != scylla::token::TokenKind::Identifier {
            return Vec::new();
        }

        segments.push(String::from_utf8_lossy(token.text(&prepared.text)).into_owned());

        let dot = index + 1;

        if dot >= end {
            return segments;
        }

        if prepared.tokens[dot as usize].is_punctuation(scylla::token::Punctuation::Dot) {
            index = dot + 1;

            continue;
        }

        if prepared.tokens[dot as usize].is_punctuation(scylla::token::Punctuation::ParenOpen)
            && prepared.pairs.partner_of(dot) == end - 1
        {
            return segments;
        }

        return Vec::new();
    }

    segments
}

const fn binding_kind(kind: DeclarationKind) -> &'static str {
    match kind {
        DeclarationKind::CatchParameter => "CatchParameter",
        DeclarationKind::Class => "Class",
        DeclarationKind::Const => "Const",
        DeclarationKind::Function => "Function",
        DeclarationKind::Let => "Let",
        DeclarationKind::Parameter => "Parameter",
        DeclarationKind::Var => "Var",
    }
}

fn prepare(source: &[u8], region: &Region) -> Prepared {
    let mut text = vec![0_u8; region.span.length as usize + 1];
    let written = mask::write(source, region.span, &region.holes, &mut text) as usize;

    text.truncate(written);

    let mut tokens = Tokens::reserve(TOKEN_COUNT_MAX);
    let mut pairs = Pairs::reserve(TOKEN_COUNT_MAX);
    let mut outline = Outline::reserve(ROW_COUNT_MAX, SEGMENT_COUNT_MAX, TOKEN_COUNT_MAX);

    JAVASCRIPT.lex(&text, &mut tokens);
    pairs.build(&text, tokens.as_slice());
    javascript::build(&text, tokens.as_slice(), &pairs, &mut outline);

    Prepared {
        outline,
        pairs,
        tokens: tokens.as_slice().to_vec(),
        text,
    }
}

fn regions(source: &[u8]) -> Vec<Region> {
    assert!(source.len() <= REGION_BYTES_MAX);

    let mut tokens = MarkupTokens::reserve(MARKUP_TOKEN_COUNT_MAX);
    let mut built = Tree::reserve(NODE_COUNT_MAX, ERROR_COUNT_MAX);

    markup::lex(source, &mut tokens);
    tree::build(source, tokens.as_slice(), &mut built);

    let mut found = Vec::new();

    for index in 0..built.count() {
        let view = View::new(&built, tokens.as_slice(), index);

        match view.kind() {
            MarkupKind::Attribute => push_attribute(source, view, &mut found),
            MarkupKind::Element => push_element(source, view, &mut found),
            MarkupKind::AngleClose
            | MarkupKind::AngleOpen
            | MarkupKind::AngleOpenSlash
            | MarkupKind::AttributeName
            | MarkupKind::AttributeText
            | MarkupKind::AttributeValue
            | MarkupKind::CloseTag
            | MarkupKind::Colon
            | MarkupKind::Comma
            | MarkupKind::CommentClose
            | MarkupKind::CommentOpen
            | MarkupKind::CommentText
            | MarkupKind::Doctype
            | MarkupKind::DoctypeText
            | MarkupKind::Document
            | MarkupKind::Dot
            | MarkupKind::ElementName
            | MarkupKind::Equals
            | MarkupKind::ErrorNode
            | MarkupKind::ErrorToken
            | MarkupKind::Filter
            | MarkupKind::FilterChain
            | MarkupKind::HTMLComment
            | MarkupKind::HTMLCommentClose
            | MarkupKind::HTMLCommentOpen
            | MarkupKind::Identifier
            | MarkupKind::Number
            | MarkupKind::OpenTag
            | MarkupKind::Pipe
            | MarkupKind::Quote
            | MarkupKind::ScriptText
            | MarkupKind::SlashAngleClose
            | MarkupKind::String
            | MarkupKind::StyleText
            | MarkupKind::TagClose
            | MarkupKind::TagName
            | MarkupKind::TagOpen
            | MarkupKind::TemplateComment
            | MarkupKind::TemplateTag
            | MarkupKind::TemplateVariable
            | MarkupKind::Text
            | MarkupKind::VariableClose
            | MarkupKind::VariableOpen
            | MarkupKind::VerbatimText
            | MarkupKind::Whitespace => {}
        }
    }

    found.sort_by_key(|region| (region.span.offset, region.span.end()));

    found
}

fn push_attribute(source: &[u8], view: View<'_, '_>, out: &mut Vec<Region>) {
    let Some(attribute) = view.as_attribute() else {
        return;
    };

    let Some(name) = attribute.name_token() else {
        return;
    };

    if !view
        .token_at(name)
        .text(source)
        .eq_ignore_ascii_case(DATA_ATTRIBUTE)
    {
        return;
    }

    let Some(value) = attribute.value() else {
        return;
    };

    let span = value.inner_span();

    if span.length == 0 {
        return;
    }

    let mut holes = BoundedVec::reserve(HOLE_COUNT_MAX);

    value.template_holes(&mut holes);

    out.push(Region {
        holes: holes.to_vec(),
        is_data: true,
        span,
    });
}

fn push_element(source: &[u8], view: View<'_, '_>, out: &mut Vec<Region>) {
    let Some(element) = view.as_element() else {
        return;
    };

    if !element.name_equals_ignore_case(SCRIPT_ELEMENT, source) {
        return;
    }

    if !is_javascript(source, element) {
        return;
    }

    let mut first = None;
    let mut last = None;
    let mut holes = Vec::new();

    for token in view.direct_tokens() {
        let span = view.token_at(token).span();

        if first.is_none() {
            first = Some(span.offset);
        }

        last = Some(span.end());
    }

    for child in view.children() {
        if matches!(child.kind(), MarkupKind::OpenTag | MarkupKind::CloseTag) {
            continue;
        }

        let span = child.span();

        if first.is_none_or(|held| span.offset < held) {
            first = Some(span.offset);
        }

        if last.is_none_or(|held| span.end() > held) {
            last = Some(span.end());
        }

        if matches!(
            child.kind(),
            MarkupKind::TemplateComment | MarkupKind::TemplateTag | MarkupKind::TemplateVariable
        ) {
            holes.push(span);
        }
    }

    let (Some(start), Some(end)) = (first, last) else {
        return;
    };

    out.push(Region {
        holes,
        is_data: false,
        span: Span {
            length: end - start,
            offset: start,
        },
    });
}

fn is_javascript(source: &[u8], element: Element<'_, '_>) -> bool {
    for attribute in element.attributes() {
        let Some(name) = attribute.name_token() else {
            continue;
        };

        if !element
            .view()
            .token_at(name)
            .text(source)
            .eq_ignore_ascii_case(TYPE_ATTRIBUTE)
        {
            continue;
        }

        let Some(value) = attribute.value() else {
            return false;
        };

        let text = &source[value.inner_span().range()];

        return JAVASCRIPT_TYPES
            .iter()
            .any(|known| text.trim_ascii().eq_ignore_ascii_case(known));
    }

    true
}

fn unquoted(source: &[u8], span: Span) -> &[u8] {
    let text = &source[span.range()];

    let Some(&quote) = text.first() else {
        return text;
    };

    if quote != b'"' && quote != b'\'' {
        return text;
    }

    if text.len() < 2 || text[text.len() - 1] != quote {
        return text;
    }

    &text[1..text.len() - 1]
}
