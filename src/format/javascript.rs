use core::slice;

use crate::bounded::{Buffer, Span};
use crate::format::brace::{self, Policy};
use crate::format::mask::Terminators;
use crate::format::print::Options;
use crate::syntax::javascript::kind::JavaScriptKind as Kind;
use crate::token::Token;
use crate::tree::{Structure, Tree};

pub const POLICY: Policy = Policy {
    angle_calls: false,
    angle_objects: true,
    arm_bars: false,
    arm_empties: false,
    arm_flattens: false,
    arm_guards: false,
    arrow_after: &[],
    arrow_bodies: true,
    arrow_parens: true,
    assign_groups: true,
    assign_joins: false,
    assign_lines: true,
    assign_values: true,
    assign_wraps: false,
    chain_soles: false,
    chain_hugs: false,
    chain_joins: false,
    chain_groups: true,
    chain_width: 0,
    call_budgets: false,
    call_nests: false,
    call_width: 0,
    attribute_ends: false,
    attribute_joins: false,
    attribute_spans: false,
    attribute_width: 0,
    attribute_words: &[],
    bar_levels: false,
    binary_lines: true,
    binary_parts: true,
    binding_bases: &[],
    binding_codes: false,
    binding_leads: false,
    binder_words: &[b"const", b"let", b"var"],
    binding_words: &[],
    blank_edges: true,
    blank_max: 1,
    block_chains: false,
    block_joins: false,
    block_leads: &[],
    block_words: &[],
    body_owns: true,
    body_parts: true,
    body_words: &[b"=>", b"do", b"else", b"finally", b"try"],
    brace_bodies: false,
    brace_continues: true,
    brace_counts: false,
    brace_dedents: false,
    brace_hugs: false,
    brace_leads: false,
    brace_levels: true,
    brace_pairs: false,
    brace_parts: false,
    brace_remarks: false,
    brace_spaces: true,
    brace_spans: false,
    brace_words: &[],
    branch_joins: false,
    branch_width: 0,
    branch_words: &[],
    bracket_types: false,
    build_blocks: false,
    carriage_breaks: true,
    callee_marks: &[b"?", b"?."],
    callee_words: &[b"super", b"this"],
    cast_joins: false,
    cast_words: &[],
    clause_bases: false,
    clause_ends: false,
    clause_lines: true,
    clause_words: &[b"case", b"default"],
    close_hugs: false,
    colon_continues: true,
    comma_continues: true,
    comma_adds: true,
    comma_drops: true,
    comma_parts: false,
    compose_parts: true,
    construct_words: &[b"new"],
    continue_words: &[b"|", b"&"],
    convention_strings: false,
    define_joins: false,
    define_widths: false,
    define_words: &[],
    declare_lines: true,
    declaration_words: &[b"class"],
    declare_words: &[],
    dedent_words: &[],
    document_blocks: false,
    else_width: 0,
    empty_words: &[b"else", b"finally", b"for", b"if", b"switch", b"try"],
    end_words: &[],
    field_width: 0,
    follow_heads: &[],
    follow_words: &[b"catch", b"else", b"finally", b"while"],
    generic_levels: false,
    generic_nests: false,
    generic_parts: false,
    group_words: &[b"as", b"asserts", b"out", b"unique"],
    head_blocks: false,
    head_stops: &[],
    header_braces: false,
    header_extends: false,
    header_joins: false,
    header_levels: false,
    header_lines: false,
    header_parens: true,
    header_widths: false,
    header_words: &[b"for", b"if", b"while"],
    heritage_parts: true,
    hug_braces: false,
    hug_lambdas: false,
    hug_lasts: true,
    hug_soles: true,
    hug_words: &[],
    inline_layout: true,
    inline_remarks: true,
    item_words: &[],
    key_quotes: true,
    key_words: &[b"new"],
    keyword_gaps: true,
    label_lines: true,
    label_words: &[],
    lambda_flattens: false,
    lead_words: &[b"/*"],
    level_words: &[],
    lifetime_tight: false,
    link_levels: false,
    link_nests: false,
    link_spans: false,
    list_blanks: false,
    list_fills: false,
    list_groups: true,
    list_hugs: false,
    list_leads: &[b",", b"export", b"import"],
    list_mixes: 0,
    list_tight: &[],
    list_remarks: false,
    list_sorts: false,
    list_spreads: true,
    list_width: 0,
    list_words: &[b"export", b"import"],
    literal_joins: false,
    literal_width: 0,
    macro_bodies: false,
    macro_defines: false,
    macro_gaps: false,
    macro_indents: false,
    macro_spans: false,
    member_words: &[b"?."],
    nested_levels: false,
    number_forms: true,
    operand_joins: false,
    operand_levels: false,
    operand_words: &[b"import", b"super", b"this"],
    operator_words: &[b"&&", b"??", b"||"],
    order_words: &[],
    parameter_words: &[],
    pattern_frames: false,
    pattern_words: &[],
    postfix_words: &[],
    prefix_words: &[b"...", b"@"],
    printed_gaps: true,
    raise_hugged: false,
    remark_carries: false,
    remark_dedents: false,
    sentinel_colons: false,
    remark_gaps: false,
    remark_levels: false,
    remark_suffix: true,
    remark_tails: false,
    return_parens: true,
    rest_binds: true,
    remark_leads: false,
    root_joins: false,
    row_parts: false,
    signature_words: &[],
    skip_words: &[],
    slice_colons: false,
    sole_hugs: false,
    sole_joins: false,
    source_gaps: false,
    source_values: &[],
    source_words: &[],
    spaced_words: &[],
    span_levels: false,
    spread_blanks: true,
    tight_from_source: &[
        b"!",
        b"*",
        b"+",
        b"++",
        b"-",
        b"--",
        b"<",
        b"<<",
        b">",
        b"?",
    ],
    spec_depths: false,
    special_macros: &[],
    string_quotes: true,
    template_spans: true,
    template_units: true,
    ternary_colon: true,
    ternary_levels: true,
    ternary_parts: true,
    test_joins: true,
    tight_words: &[],
    type_leads: &[],
    type_words: &[],
    unary_words: &[b"!", b"-", b"+", b"~", b"..."],
    union_parts: true,
    value_cap: 0,
    value_columns: false,
    value_words: &[],
    variant_width: 0,
    verbatim_words: &[],
    units: false,
    width_lists: true,
};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Outcome {
    Complete,
    Overflow,
    Refusal,
}

pub struct Input<'held> {
    pub options: Options,
    pub outcome: Structure,
    pub raw: &'held [Kind],
    pub source: &'held [u8],
    pub tokens: &'held [Token],
    pub tree: &'held Tree<Kind>,
}

#[derive(Debug)]
pub struct Formatter {
    inner: brace::Formatter,
    stream: Terminators,
}

fn broken(input: &Input<'_>) -> bool {
    if input.outcome != Structure::Complete || !input.tree.errors().is_empty() {
        return true;
    }

    if input.raw.contains(&Kind::ErrorToken) {
        return true;
    }

    if input
        .tree
        .as_slice()
        .iter()
        .any(|node| node.kind == Kind::ErrorNode)
    {
        return true;
    }

    let unclosed = input
        .tokens
        .iter()
        .zip(input.raw.iter())
        .any(|(token, kind)| {
            !content(*kind) && !brace::closed(input.source, slice::from_ref(token), false, false)
        });

    if unclosed {
        return true;
    }

    !brace::balanced(input.source, input.tokens)
}

fn content(kind: Kind) -> bool {
    matches!(kind, Kind::JsxChars | Kind::JsxEntity | Kind::TemplateChars)
}

const DROPS_PARENS: bool = true;

fn braced(parent: Kind) -> bool {
    parent == Kind::ArrowFunction
}

fn drops(inner: Kind, parent: Kind) -> bool {
    if !DROPS_PARENS {
        return false;
    }

    if matches!(
        inner,
        Kind::AssignmentExpression | Kind::AugmentedAssignmentExpression | Kind::SequenceExpression
    ) {
        return false;
    }

    if inner == Kind::TernaryExpression && parent == Kind::ArrowFunction {
        return false;
    }

    if inner == Kind::TernaryExpression && parent == Kind::TernaryExpression {
        return false;
    }

    matches!(
        parent,
        Kind::Arguments
            | Kind::Array
            | Kind::ArrowFunction
            | Kind::AssignmentExpression
            | Kind::AugmentedAssignmentExpression
            | Kind::ExportStatement
            | Kind::ForInStatement
            | Kind::Pair
            | Kind::ParenthesizedExpression
            | Kind::ReturnStatement
            | Kind::SwitchCase
            | Kind::TemplateSubstitution
            | Kind::TernaryExpression
            | Kind::ThrowStatement
            | Kind::VariableDeclarator
    )
}

fn spans(kind: Kind) -> bool {
    matches!(kind, Kind::Array | Kind::Object)
}

fn wraps(inner: Kind, parent: Kind) -> bool {
    matches!(inner, Kind::FunctionExpression | Kind::GeneratorFunction)
        && matches!(parent, Kind::CallExpression | Kind::NewExpression)
}

fn queries(kind: Kind) -> bool {
    kind == Kind::TernaryExpression
}

fn parens(kind: Kind) -> bool {
    kind == Kind::ParenthesizedExpression
}

fn names(kind: Kind) -> bool {
    matches!(
        kind,
        Kind::IdentifierNode
            | Kind::PrivatePropertyIdentifier
            | Kind::PropertyIdentifier
            | Kind::ShorthandPropertyIdentifier
            | Kind::ShorthandPropertyIdentifierPattern
            | Kind::StatementIdentifier
    )
}

fn opens(kind: Kind) -> bool {
    matches!(kind, Kind::JsxElement | Kind::JsxSelfClosingElement)
}

fn operators(kind: Kind) -> bool {
    matches!(
        kind,
        Kind::ArrowFunction
            | Kind::AssignmentExpression
            | Kind::AugmentedAssignmentExpression
            | Kind::BinaryExpression
            | Kind::VariableDeclarator
    )
}

fn denies(kind: Kind, parent: Kind) -> bool {
    if matches!(
        kind,
        Kind::Class | Kind::FunctionExpression | Kind::GeneratorFunction
    ) {
        return parent == Kind::ExportStatement;
    }

    matches!(
        kind,
        Kind::ClassDeclaration | Kind::FunctionDeclaration | Kind::GeneratorFunctionDeclaration
    )
}

fn owes(kind: Kind, parent: Kind) -> bool {
    if kind == Kind::FieldDefinition {
        return parent == Kind::ClassBody;
    }

    matches!(
        kind,
        Kind::BreakStatement
            | Kind::ContinueStatement
            | Kind::DebuggerStatement
            | Kind::DoStatement
            | Kind::ExportStatement
            | Kind::ExpressionStatement
            | Kind::ImportStatement
            | Kind::LexicalDeclaration
            | Kind::ReturnStatement
            | Kind::ThrowStatement
            | Kind::VariableDeclaration
    )
}

impl Formatter {
    pub fn reserve(element_count_max: u32, scratch_bytes_max: u32) -> Self {
        Self {
            inner: brace::Formatter::reserve(element_count_max, scratch_bytes_max),
            stream: Terminators::reserve(element_count_max, scratch_bytes_max),
        }
    }

    #[must_use]
    pub fn format(&mut self, input: &Input<'_>, out: &mut Buffer) -> Outcome {
        assert_eq!(input.tokens.len(), input.raw.len());

        if broken(input) {
            return Outcome::Refusal;
        }

        let rules = brace::Rules {
            braced,
            denies,
            drops,
            names,
            opens,
            operators,
            owes,
            parens,
            queries,
            spans,
            wraps,
        };

        if !brace::terminated(
            input.tree,
            input.source,
            input.tokens,
            rules,
            &mut self.stream,
        ) {
            return Outcome::Overflow;
        }

        let held = brace::Input {
            added: &[],
            origin: &[],
            origins: &[],
            gives: &[],
            macros: &[],
            roles: self.stream.roles(),
            options: input.options,
            policy: POLICY,
            source: self.stream.source(),
            tokens: self.stream.tokens(),
        };

        if !self.inner.format(&held, out) {
            return Outcome::Overflow;
        }

        Outcome::Complete
    }

    #[must_use]
    pub fn range(
        &mut self,
        input: &Input<'_>,
        lines: (u32, u32),
        out: &mut Buffer,
    ) -> Option<Span> {
        if self.format(input, out) != Outcome::Complete {
            return None;
        }

        brace::span_of(out.as_bytes(), lines)
    }
}
