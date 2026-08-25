use scylla::bounded::Span;
use scylla::brackets::Pairs;
use scylla::language::Lexer as _;
use scylla::lex::PYTHON;
use scylla::outline::python::{self, Outline};
use scylla::structure::{self, DEPTH_MAX, NONE, Node, Nodes, Shape};
use scylla::summary::Summary;
use scylla::token::{Token, Tokens};

const NODE_COUNT_MAX: u32 = 1 << 10;
const ROW_COUNT_MAX: u32 = 1 << 12;
const SEGMENT_COUNT_MAX: u32 = 1 << 13;
const TOKEN_COUNT_MAX: u32 = 1 << 14;

struct Built {
    nodes: Vec<Node>,
    outline: Outline,
    source: Vec<u8>,
    tokens: Vec<Token>,
}

impl Built {
    fn new(source: &str) -> Self {
        let bytes = source.as_bytes().to_vec();
        let mut tokens = Tokens::reserve(TOKEN_COUNT_MAX);
        let mut pairs = Pairs::reserve(TOKEN_COUNT_MAX);
        let mut nodes = Nodes::reserve(NODE_COUNT_MAX);
        let mut outline = Outline::reserve(ROW_COUNT_MAX, SEGMENT_COUNT_MAX);

        PYTHON.lex(&bytes, &mut tokens);
        pairs.build(&bytes, tokens.as_slice());

        structure::build(
            tokens.as_slice(),
            &bytes,
            &mut nodes,
            Shape::PYTHON,
            DEPTH_MAX,
        );

        python::build(
            &bytes,
            tokens.as_slice(),
            &pairs,
            nodes.as_slice(),
            &mut outline,
        );

        Self {
            nodes: nodes.as_slice().to_vec(),
            outline,
            source: bytes,
            tokens: tokens.as_slice().to_vec(),
        }
    }

    fn callee(&self, index: usize) -> String {
        let call = self.outline.calls()[index];

        self.join(
            self.outline
                .segments_of(call.callee_segment_first, call.callee_segment_count),
        )
    }

    fn callees(&self) -> Vec<String> {
        (0..self.outline.calls().len())
            .map(|index| self.callee(index))
            .collect()
    }

    fn value_text(&self, start: u32, end: u32) -> String {
        let mut written = String::new();

        for index in start..end {
            let token = self.tokens[index as usize];

            if matches!(
                token.kind,
                scylla::token::TokenKind::Comment | scylla::token::TokenKind::Newline
            ) {
                continue;
            }

            written.push_str(&String::from_utf8_lossy(token.text(&self.source)));
        }

        written
    }

    fn join(&self, segments: &[Span]) -> String {
        let parts: Vec<String> = segments.iter().map(|span| self.text(*span)).collect();

        parts.join(".")
    }

    fn name_of(&self, node: u32) -> String {
        let token = self.nodes[node as usize].name;

        self.text(self.tokens[token as usize].span())
    }

    fn text(&self, span: Span) -> String {
        String::from_utf8_lossy(&self.source[span.range()]).into_owned()
    }
}

#[test]
fn a_call_records_its_callee_and_its_arguments() {
    let built = Built::new("register(name=\"widget\", template=\"a.html\", takes_context=True)\n");

    assert_eq!(built.callees(), ["register"]);

    let call = built.outline.calls()[0];

    let arguments = &built.outline.arguments()
        [call.argument_first as usize..(call.argument_first + call.argument_count) as usize];

    assert_eq!(arguments.len(), 3);

    let names: Vec<String> = arguments
        .iter()
        .map(|argument| built.text(argument.name))
        .collect();

    assert_eq!(names, ["name", "template", "takes_context"]);

    let Summary::Literal { content } = arguments[0].summary else {
        panic!("{:?}", arguments[0].summary);
    };

    assert_eq!(built.text(content), "widget");
    assert!(matches!(arguments[2].summary, Summary::Literal { .. }));
}

#[test]
fn a_positional_argument_carries_an_empty_name() {
    let built = Built::new("path(\"admin/\", admin.site.urls, name=\"admin\")\n");
    let call = built.outline.calls()[0];

    let arguments = &built.outline.arguments()
        [call.argument_first as usize..(call.argument_first + call.argument_count) as usize];

    assert_eq!(arguments.len(), 3);
    assert_eq!(arguments[0].name, Span::EMPTY);
    assert_eq!(arguments[1].name, Span::EMPTY);
    assert_eq!(built.text(arguments[2].name), "name");

    let Summary::Literal { content } = arguments[2].summary else {
        panic!("{:?}", arguments[2].summary);
    };

    assert_eq!(built.text(content), "admin");

    let Summary::DottedName {
        segment_count,
        segment_first,
    } = arguments[1].summary
    else {
        panic!("{:?}", arguments[1].summary);
    };

    assert_eq!(
        built.join(built.outline.segments_of(segment_first, segment_count)),
        "admin.site.urls"
    );
}

#[test]
fn a_dotted_callee_records_every_segment() {
    let built = Built::new("value = django.db.models.CharField(max_length=10)\n");

    assert_eq!(built.callees(), ["django.db.models.CharField"]);
}

#[test]
fn a_nested_call_is_recorded_alongside_the_outer_one() {
    let built = Built::new("outer(inner(1), other.thing(2))\n");
    let mut callees = built.callees();

    callees.sort();

    assert_eq!(callees, ["inner", "other.thing", "outer"]);
}

#[test]
fn a_call_names_the_definition_that_encloses_it() {
    let source = "class Widget:\n    def render(self):\n        return build(self)\n";
    let built = Built::new(source);

    let call = built
        .outline
        .calls()
        .iter()
        .find(|call| {
            built.join(
                built
                    .outline
                    .segments_of(call.callee_segment_first, call.callee_segment_count),
            ) == "build"
        })
        .expect("the call is recorded");

    assert_ne!(call.scope, NONE);
    assert_eq!(built.name_of(call.scope), "render");
}

#[test]
fn an_assignment_records_its_target_and_its_value() {
    let source =
        "class Widget:\n    name = models.CharField(max_length=10)\n    label = \"plain\"\n";

    let built = Built::new(source);

    let targets: Vec<String> = built
        .outline
        .assignments()
        .iter()
        .map(|assignment| built.text(assignment.target))
        .collect();

    assert_eq!(targets, ["name", "label"]);

    for assignment in built.outline.assignments() {
        assert!(assignment.target_is_simple);
        assert_ne!(assignment.scope, NONE);
        assert_eq!(built.name_of(assignment.scope), "Widget");
    }
}

#[test]
fn an_annotated_assignment_records_its_target_its_annotation_and_its_value() {
    let built = Built::new("count: int = 5\n");
    let assignment = built.outline.assignments()[0];

    assert_eq!(built.outline.assignments().len(), 1);
    assert_eq!(built.text(assignment.target), "count");
    assert_eq!(built.text(assignment.annotation), "int");
    assert!(assignment.target_is_simple);

    assert_eq!(
        built.value_text(assignment.value_token_start, assignment.value_token_end),
        "5"
    );
}

#[test]
fn a_bare_annotation_declares_a_name_and_binds_nothing() {
    let source = "class Row:\n    name: str\n    count: int = 0\n";
    let built = Built::new(source);

    let targets: Vec<String> = built
        .outline
        .assignments()
        .iter()
        .map(|assignment| built.text(assignment.target))
        .collect();

    assert_eq!(targets, ["name", "count"]);

    let bare = built.outline.assignments()[0];

    assert_eq!(built.text(bare.annotation), "str");

    assert_eq!(
        bare.value_token_start,
        bare.value_token_end,
        "a bare annotation binds nothing"
    );

    let bound = built.outline.assignments()[1];

    assert!(bound.value_token_start < bound.value_token_end);
}

#[test]
fn an_annotation_carrying_an_equals_does_not_swallow_the_assignment() {
    let built = Built::new("field: Annotated[int, Field(default=1)] = 2\n");
    let assignment = built.outline.assignments()[0];

    assert_eq!(built.text(assignment.target), "field");

    assert_eq!(
        built.text(assignment.annotation),
        "Annotated[int, Field(default=1)]"
    );

    assert_eq!(
        built.value_text(assignment.value_token_start, assignment.value_token_end),
        "2"
    );
}

#[test]
fn an_unannotated_assignment_carries_no_annotation() {
    let built = Built::new("name = \"plain\"\n");

    assert_eq!(built.outline.assignments()[0].annotation, Span::EMPTY);
}

#[test]
fn a_dotted_assignment_target_is_not_simple() {
    let built = Built::new("self.value = 1\n");
    let assignment = built.outline.assignments()[0];

    assert_eq!(built.text(assignment.target), "self.value");
    assert!(!assignment.target_is_simple);
}

#[test]
fn an_assignment_inside_brackets_is_not_split_by_its_newlines() {
    let built = Built::new("choices = [\n    (\"a\", \"A\"),\n    (\"b\", \"B\"),\n]\n");

    assert_eq!(built.outline.assignments().len(), 1);
    assert_eq!(built.text(built.outline.assignments()[0].target), "choices");
}

#[test]
fn a_decorator_records_its_segments_and_the_definition_below_it() {
    let source = "@register.filter(name=\"pretty\")\ndef pretty(value):\n    return value\n";
    let built = Built::new(source);

    assert_eq!(built.outline.decorators().len(), 1);

    let decorator = built.outline.decorators()[0];

    assert_eq!(
        built.join(
            built
                .outline
                .segments_of(decorator.segment_first, decorator.segment_count)
        ),
        "register.filter"
    );

    assert_ne!(decorator.call, NONE);
    assert_ne!(decorator.definition, NONE);
    assert_eq!(built.name_of(decorator.definition), "pretty");
}

#[test]
fn a_bare_decorator_records_no_call() {
    let built = Built::new("@property\ndef value(self):\n    return 1\n");
    let decorator = built.outline.decorators()[0];

    assert_eq!(decorator.call, NONE);

    assert_eq!(
        built.join(
            built
                .outline
                .segments_of(decorator.segment_first, decorator.segment_count)
        ),
        "property"
    );
}

#[test]
fn a_class_records_each_of_its_bases() {
    let source = "class Widget(models.Model, Mixin):\n    pass\n";
    let built = Built::new(source);

    assert_eq!(built.outline.bases().len(), 2);

    let names: Vec<String> = built
        .outline
        .bases()
        .iter()
        .map(|base| match base.summary {
            Summary::DottedName {
                segment_count,
                segment_first,
            } => built.join(built.outline.segments_of(segment_first, segment_count)),

            other @ (Summary::Call { .. }
            | Summary::Dynamic
            | Summary::Literal { .. }
            | Summary::Sequence { .. }) => format!("{other:?}"),
        })
        .collect();

    assert_eq!(names, ["models.Model", "Mixin"]);

    for base in built.outline.bases() {
        assert_eq!(built.name_of(base.class_definition), "Widget");
    }
}

#[test]
fn a_class_without_bases_records_none() {
    let built = Built::new("class Widget:\n    pass\n");

    assert!(built.outline.bases().is_empty());
}

#[test]
fn a_second_build_over_the_same_outline_replaces_the_first() {
    let first = Built::new("a(1)\n");
    let second = Built::new("a(1)\nb(2)\n");

    assert_eq!(first.outline.calls().len(), 1);
    assert_eq!(second.outline.calls().len(), 2);
}

#[test]
fn a_body_on_the_header_line_still_names_its_scope() {
    let built = Built::new("class Row:\n    def name(self): return render(self)\n");

    let call = (0..built.outline.calls().len())
        .find(|index| built.callee(*index) == "render")
        .map(|index| built.outline.calls()[index])
        .expect("the body holds a call");

    assert_ne!(call.scope, NONE);

    assert_eq!(
        built.name_of(call.scope),
        "name",
        "a body written on its header line is still the function's own scope"
    );
}

#[test]
fn an_empty_source_records_nothing() {
    let built = Built::new("");

    assert!(built.outline.calls().is_empty());
    assert!(built.outline.assignments().is_empty());
    assert!(built.outline.bases().is_empty());
    assert!(built.outline.decorators().is_empty());
}
