use scylla::bounded::Span;
use scylla::bounded::count_of;
use scylla::brackets::Pairs;
use scylla::language::Lexer as _;
use scylla::lex::JAVASCRIPT;
use scylla::outline::javascript::{self, BraceKind, DeclarationKind, Outline, ScopeKind};
use scylla::token::{Token, Tokens};

const ROW_COUNT_MAX: u32 = 1 << 12;
const SEGMENT_COUNT_MAX: u32 = 1 << 13;
const TOKEN_COUNT_MAX: u32 = 1 << 14;

struct Built {
    outline: Outline,
    source: Vec<u8>,
    tokens: Vec<Token>,
}

impl Built {
    fn new(source: &str) -> Self {
        let bytes = source.as_bytes().to_vec();
        let mut tokens = Tokens::reserve(TOKEN_COUNT_MAX);
        let mut pairs = Pairs::reserve(TOKEN_COUNT_MAX);
        let mut outline = Outline::reserve(ROW_COUNT_MAX, SEGMENT_COUNT_MAX, TOKEN_COUNT_MAX);

        JAVASCRIPT.lex(&bytes, &mut tokens);
        pairs.build(&bytes, tokens.as_slice());
        javascript::build(&bytes, tokens.as_slice(), &pairs, &mut outline);

        Self {
            outline,
            source: bytes,
            tokens: tokens.as_slice().to_vec(),
        }
    }

    fn callees(&self) -> Vec<String> {
        self.outline
            .calls()
            .iter()
            .map(|call| {
                self.join(
                    self.outline
                        .segments_of(call.callee_segment_first, call.callee_segment_count),
                )
            })
            .collect()
    }

    fn declarations(&self, kind: DeclarationKind) -> Vec<String> {
        self.outline
            .declarations()
            .iter()
            .filter(|declaration| declaration.kind == kind)
            .map(|declaration| self.text(declaration.name))
            .collect()
    }

    fn join(&self, segments: &[Span]) -> String {
        let parts: Vec<String> = segments.iter().map(|span| self.text(*span)).collect();

        parts.join(".")
    }

    fn text(&self, span: Span) -> String {
        String::from_utf8_lossy(&self.source[span.range()]).into_owned()
    }

    fn token_text(&self, index: u32) -> String {
        String::from_utf8_lossy(self.tokens[index as usize].text(&self.source)).into_owned()
    }
}

#[test]
fn a_brace_after_an_equals_is_an_object_and_a_function_body_is_a_block() {
    let built = Built::new("const state = { a: 1 };\nfunction run() { return 2; }\n");
    let mut objects = 0;
    let mut blocks = 0;

    for index in 0..count_of(built.tokens.len()) {
        match built.outline.brace_kind(index) {
            BraceKind::Object => objects += 1,
            BraceKind::Block => blocks += 1,
            BraceKind::None => {}
        }
    }

    assert_eq!(objects, 1);
    assert_eq!(blocks, 1);
}

#[test]
fn a_declaration_records_its_kind_and_its_name() {
    let source = "var a = 1;\nlet b = 2;\nconst c = 3;\nfunction d() {}\nclass E {}\n";
    let built = Built::new(source);

    assert_eq!(built.declarations(DeclarationKind::Var), ["a"]);
    assert_eq!(built.declarations(DeclarationKind::Let), ["b"]);
    assert_eq!(built.declarations(DeclarationKind::Const), ["c"]);
    assert_eq!(built.declarations(DeclarationKind::Function), ["d"]);
    assert_eq!(built.declarations(DeclarationKind::Class), ["E"]);
}

#[test]
fn several_declarators_on_one_keyword_each_bind() {
    let built = Built::new("let a = 1, b = 2, c;\n");

    assert_eq!(built.declarations(DeclarationKind::Let), ["a", "b", "c"]);
}

#[test]
fn a_function_binds_its_parameters() {
    let built = Built::new("function run(first, second) { return first; }\n");

    assert_eq!(
        built.declarations(DeclarationKind::Parameter),
        ["first", "second"]
    );
}

#[test]
fn an_arrow_binds_its_parameters_in_both_forms() {
    let bare = Built::new("const f = value => value + 1;\n");
    let parenthesized = Built::new("const f = (a, b) => a + b;\n");

    assert_eq!(bare.declarations(DeclarationKind::Parameter), ["value"]);

    assert_eq!(
        parenthesized.declarations(DeclarationKind::Parameter),
        ["a", "b"]
    );
}

#[test]
fn a_catch_clause_binds_its_parameter() {
    let built = Built::new("try { run(); } catch (error) { report(error); }\n");

    assert_eq!(
        built.declarations(DeclarationKind::CatchParameter),
        ["error"]
    );
}

#[test]
fn a_destructuring_pattern_binds_its_leaves() {
    let built = Built::new("const { first, second: renamed } = source;\n");
    let names = built.declarations(DeclarationKind::Const);

    assert!(names.contains(&"first".to_owned()), "{names:?}");
    assert!(names.contains(&"renamed".to_owned()), "{names:?}");
    assert!(!names.contains(&"second".to_owned()), "{names:?}");
}

#[test]
fn a_block_scoped_declaration_names_a_narrower_scope_than_a_var() {
    let source =
        "function run() {\n    var wide = 1;\n    if (x) {\n        let narrow = 2;\n    }\n}\n";

    let built = Built::new(source);

    let wide = built
        .outline
        .declarations()
        .iter()
        .find(|declaration| built.text(declaration.name) == "wide")
        .expect("var wide is declared");

    let narrow = built
        .outline
        .declarations()
        .iter()
        .find(|declaration| built.text(declaration.name) == "narrow")
        .expect("let narrow is declared");

    assert!(
        narrow.scope_token_end - narrow.scope_token_start
            < wide.scope_token_end - wide.scope_token_start
    );
}

#[test]
fn an_object_literal_records_each_member() {
    let source = "const data = { count: 1, name, run() { return 1; }, ...rest };\n";
    let built = Built::new(source);

    assert_eq!(built.outline.objects().len(), 1);

    let object = built.outline.objects()[0];
    let members = built.outline.members_of(&object);

    assert_eq!(members.len(), 4);
    assert_eq!(built.text(members[0].name), "count");
    assert!(!members[0].is_shorthand);
    assert_eq!(built.text(members[1].name), "name");
    assert!(members[1].is_shorthand);
    assert_eq!(built.text(members[2].name), "run");
    assert!(members[2].is_method);
    assert!(members[3].is_spread);
}

#[test]
fn an_async_member_that_awaits_is_marked() {
    let source = "const data = { async load() { await fetch(url); }, plain() { return 1; } };\n";
    let built = Built::new(source);
    let object = built.outline.objects()[0];
    let members = built.outline.members_of(&object);

    assert_eq!(members.len(), 2);
    assert!(members[0].is_async);
    assert!(members[0].has_await);
    assert!(!members[1].is_async);
    assert!(!members[1].has_await);
}

#[test]
fn an_await_inside_a_nested_function_does_not_mark_the_member() {
    let source = "const data = { run() { return async () => { await go(); }; } };\n";
    let built = Built::new(source);
    let object = built.outline.objects()[0];
    let members = built.outline.members_of(&object);

    assert_eq!(members.len(), 1);
    assert!(!members[0].has_await);
}

#[test]
fn a_call_records_its_chain_and_a_new_records_its_keyword() {
    let built = Built::new("Alpine.directive('x-thing', handler);\nnew ViewGlue(root);\n");
    let callees = built.callees();

    assert!(
        callees.contains(&"Alpine.directive".to_owned()),
        "{callees:?}"
    );

    assert!(callees.contains(&"new.ViewGlue".to_owned()), "{callees:?}");
}

#[test]
fn a_call_names_the_scope_that_encloses_it() {
    let built = Built::new("function run() { inner(); }\n");

    let call = built
        .outline
        .calls()
        .iter()
        .find(|call| {
            built.join(
                built
                    .outline
                    .segments_of(call.callee_segment_first, call.callee_segment_count),
            ) == "inner"
        })
        .expect("the call is recorded");

    let scopes = built.outline.scopes();
    let mut index = call.scope;
    let mut kinds = Vec::new();

    while index != scylla::structure::NONE {
        kinds.push(scopes[index as usize].kind);
        index = scopes[index as usize].parent;
    }

    assert_eq!(
        kinds,
        [ScopeKind::Block, ScopeKind::Function, ScopeKind::Program]
    );
}

#[test]
fn a_reassigned_binding_is_recorded_and_a_member_write_is_not() {
    let built = Built::new("let a = 1;\na = 2;\na += 3;\na++;\nb.c = 4;\n");

    let names: Vec<String> = built
        .outline
        .assigned()
        .iter()
        .map(|assigned| built.text(assigned.name))
        .collect();

    assert_eq!(names, ["a", "a", "a", "a"]);
}

#[test]
fn a_statement_splits_at_a_semicolon_and_at_a_line_break() {
    let built = Built::new("run();\nother()\nthird();\n");

    assert_eq!(built.outline.statements().len(), 3);
}

#[test]
fn a_floating_call_is_separated_from_a_chained_one() {
    let built = Built::new("fetch(url);\nfetch(other).then(read);\nconst held = fetch(third);\n");
    let calls = built.outline.calls();

    let fates: Vec<(String, bool, bool)> = calls
        .iter()
        .map(|call| {
            let fate = javascript::chain_fate(
                call,
                &built.source,
                &built.tokens,
                built.outline.statements(),
            );

            (
                built.join(
                    built
                        .outline
                        .segments_of(call.callee_segment_first, call.callee_segment_count),
                ),
                fate.chained,
                fate.floating,
            )
        })
        .collect();

    let bare = fates
        .iter()
        .find(|(name, chained, _)| name == "fetch" && !*chained)
        .expect("a bare fetch is recorded");

    assert!(bare.2, "{fates:?}");

    let chained = fates
        .iter()
        .find(|(_, chained, _)| *chained)
        .expect("a chained fetch is recorded");

    assert!(!chained.2, "{fates:?}");

    let held = fates
        .iter()
        .filter(|(name, _, floating)| name == "fetch" && !*floating)
        .count();

    assert!(held >= 1, "{fates:?}");
}

#[test]
fn the_x_data_reading_walks_the_first_object_literal() {
    let built = Built::new("{ open: false, toggle() { this.open = !this.open; } }");

    let object = *built
        .outline
        .objects()
        .first()
        .expect("the region is one object literal");

    let members = built.outline.members_of(&object);

    let names: Vec<String> = members
        .iter()
        .map(|member| built.text(member.name))
        .collect();

    assert_eq!(names, ["open", "toggle"]);
    assert_eq!(built.token_text(object.brace_open), "{");
    assert_eq!(built.token_text(object.brace_close), "}");
}

#[test]
fn an_empty_source_records_only_the_program_scope() {
    let built = Built::new("");

    assert_eq!(built.outline.scopes().len(), 1);
    assert_eq!(built.outline.scopes()[0].kind, ScopeKind::Program);
    assert!(built.outline.calls().is_empty());
    assert!(built.outline.declarations().is_empty());
}
