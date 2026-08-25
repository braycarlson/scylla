use scylla::bounded::{BoundedVec, Span};
use scylla::markup::tree::{self, Tree};
use scylla::markup::view::{Attribute, KeywordArgument, View};
use scylla::markup::{self, MarkupKind, Tokens};

const ERROR_COUNT_MAX: u32 = 1 << 10;
const NODE_COUNT_MAX: u32 = 1 << 12;
const TOKEN_COUNT_MAX: u32 = 1 << 14;

struct Built {
    source: Vec<u8>,
    tokens: Tokens,
    tree: Tree,
}

impl Built {
    fn new(source: &str) -> Self {
        let mut tokens = Tokens::reserve(TOKEN_COUNT_MAX);
        let mut tree = Tree::reserve(NODE_COUNT_MAX, ERROR_COUNT_MAX);
        let bytes = source.as_bytes().to_vec();

        markup::lex(&bytes, &mut tokens);
        tree::build(&bytes, tokens.as_slice(), &mut tree);

        Self {
            source: bytes,
            tokens,
            tree,
        }
    }

    fn first(&self, kind: MarkupKind) -> View<'_, '_> {
        for index in 0..self.tree.count() {
            if self.tree.at(index).kind == kind {
                return View::new(&self.tree, self.tokens.as_slice(), index);
            }
        }

        panic!("the source carries no {}", kind.name());
    }

    fn span_text(&self, span: Span) -> String {
        String::from_utf8_lossy(&self.source[span.range()]).into_owned()
    }

    fn token_text(&self, index: u32) -> String {
        String::from_utf8_lossy(self.tokens.as_slice()[index as usize].text(&self.source))
            .into_owned()
    }
}

#[test]
fn an_element_names_itself_and_lists_its_attributes() {
    let built = Built::new("<DIV id=\"one\" class='two' hidden>body</div>");

    let element = built
        .first(MarkupKind::Element)
        .as_element()
        .expect("the first node is an element");

    assert!(element.name_equals_ignore_case(b"div", &built.source));
    assert!(!element.name_equals_ignore_case(b"span", &built.source));

    let names: Vec<String> = element
        .attributes()
        .filter_map(Attribute::name_token)
        .map(|token| built.token_text(token))
        .collect();

    assert_eq!(names, ["id", "class", "hidden"]);
}

#[test]
fn an_attribute_value_strips_its_quotes() {
    let built = Built::new("<div id=\"one\">");

    let element = built
        .first(MarkupKind::Element)
        .as_element()
        .expect("the first node is an element");

    let attribute = element.attributes().next().expect("id is an attribute");
    let value = attribute.value().expect("id carries a value");

    assert!(value.is_quoted());
    assert_eq!(built.span_text(value.inner_span()), "one");
}

#[test]
fn a_bare_attribute_value_keeps_its_whole_span() {
    let built = Built::new("<div id=one>");

    let element = built
        .first(MarkupKind::Element)
        .as_element()
        .expect("the first node is an element");

    let attribute = element.attributes().next().expect("id is an attribute");
    let value = attribute.value().expect("id carries a value");

    assert!(!value.is_quoted());
    assert_eq!(built.span_text(value.inner_span()), "one");
}

#[test]
fn an_attribute_value_reports_its_template_holes() {
    let built = Built::new("<div class=\"a {{ name }} b {% if x %} c\">");

    let element = built
        .first(MarkupKind::Element)
        .as_element()
        .expect("the first node is an element");

    let attribute = element.attributes().next().expect("class is an attribute");
    let value = attribute.value().expect("class carries a value");
    let mut holes = BoundedVec::reserve(8);

    assert!(value.template_holes(&mut holes));
    assert_eq!(holes.len(), 2);
    assert_eq!(built.span_text(holes[0]), "{{ name }}");
    assert_eq!(built.span_text(holes[1]), "{% if x %}");

    let text: Vec<String> = value
        .text_tokens()
        .map(|token| built.token_text(token))
        .collect();

    assert_eq!(text, ["a ", " b ", " c"]);
}

#[test]
fn a_template_tag_names_itself_and_splits_its_arguments() {
    let built = Built::new("{% include 'partial.html' with title=\"Hello\" only %}");

    let tag = built
        .first(MarkupKind::TemplateTag)
        .as_template_tag()
        .expect("the first node is a tag");

    assert!(tag.is_closed());

    assert_eq!(
        built.token_text(tag.name_token().expect("the tag has a name")),
        "include"
    );

    let mut strings = BoundedVec::reserve(8);

    assert!(tag.string_arguments(&built.source, &mut strings));
    assert_eq!(strings.len(), 2);
    assert_eq!(built.span_text(strings[0]), "partial.html");
    assert_eq!(built.span_text(strings[1]), "Hello");

    let mut keywords: BoundedVec<KeywordArgument> = BoundedVec::reserve(8);

    assert!(tag.keyword_arguments(&built.source, &mut keywords));
    assert_eq!(keywords.len(), 1);
    assert_eq!(built.token_text(keywords[0].name_token), "title");
    assert_eq!(built.span_text(keywords[0].value), "Hello");
}

#[test]
fn an_unterminated_template_tag_is_not_closed() {
    let built = Built::new("{% include 'partial.html'");

    let tag = built
        .first(MarkupKind::TemplateTag)
        .as_template_tag()
        .expect("the first node is a tag");

    assert!(!tag.is_closed());
}

#[test]
fn a_template_variable_separates_its_expression_from_its_filters() {
    let built = Built::new("{{ user.profile.name|title|default:\"none\" }}");

    let variable = built
        .first(MarkupKind::TemplateVariable)
        .as_template_variable()
        .expect("the first node is a variable");

    let expression: Vec<String> = variable
        .expression_tokens()
        .map(|token| built.token_text(token))
        .collect();

    assert_eq!(expression, ["user", ".", "profile", ".", "name"]);

    let filters: Vec<String> = variable
        .filter_names()
        .map(|token| built.token_text(token))
        .collect();

    assert_eq!(filters, ["title", "default"]);
}

#[test]
fn a_variable_without_filters_carries_its_whole_expression() {
    let built = Built::new("{{ value }}");

    let variable = built
        .first(MarkupKind::TemplateVariable)
        .as_template_variable()
        .expect("the first node is a variable");

    let expression: Vec<String> = variable
        .expression_tokens()
        .map(|token| built.token_text(token))
        .collect();

    assert_eq!(expression, ["value"]);
    assert_eq!(variable.filter_names().count(), 0);
}

#[test]
fn a_script_element_reports_its_raw_text() {
    let built = Built::new("<script>var a = 1;</script>");

    let element = built
        .first(MarkupKind::Element)
        .as_element()
        .expect("the first node is an element");

    let raw: Vec<String> = element
        .raw_text_tokens()
        .map(|token| built.token_text(token))
        .collect();

    assert_eq!(raw, ["var a = 1;"]);
}

#[test]
fn a_style_element_reports_its_raw_text() {
    let built = Built::new("<style>a { b: c }</style>");

    let element = built
        .first(MarkupKind::Element)
        .as_element()
        .expect("the first node is an element");

    let raw: Vec<String> = element
        .raw_text_tokens()
        .map(|token| built.token_text(token))
        .collect();

    assert_eq!(raw, ["a { b: c }"]);
}

#[test]
fn a_direct_token_walk_skips_the_tokens_a_child_node_owns() {
    let built = Built::new("<div class=\"{{ name }}\">");

    let open = built
        .first(MarkupKind::Element)
        .as_element()
        .expect("the first node is an element")
        .open_tag()
        .expect("the element has an open tag");

    let direct: Vec<String> = open
        .direct_tokens()
        .map(|token| built.token_text(token))
        .collect();

    assert_eq!(direct, ["<", "div", " ", ">"]);
}

#[test]
fn an_unquoted_string_argument_keeps_its_span() {
    let built = Built::new("{% url name %}");

    let tag = built
        .first(MarkupKind::TemplateTag)
        .as_template_tag()
        .expect("the first node is a tag");

    let mut strings = BoundedVec::reserve(8);

    assert!(tag.string_arguments(&built.source, &mut strings));
    assert_eq!(strings.len(), 0);

    let arguments: Vec<String> = tag
        .argument_tokens()
        .map(|token| built.token_text(token))
        .collect();

    assert_eq!(arguments, ["name"]);
}
