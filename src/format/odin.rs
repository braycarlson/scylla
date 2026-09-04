use crate::bounded::{Buffer, Span};
use crate::format::brace::{self, Policy};
use crate::format::print::Options;
use crate::syntax::odin::kind::OdinKind as Kind;
use crate::token::Token;
use crate::tree::{Structure, Tree};

pub const POLICY: Policy = Policy {
    angle_calls: false,
    angle_objects: false,
    arm_empties: false,
    arm_flattens: false,
    arm_guards: false,
    arrow_after: &[],
    arrow_parens: false,
    assign_groups: false,
    assign_joins: false,
    assign_values: false,
    assign_wraps: false,
    chain_soles: false,
    chain_hugs: false,
    chain_joins: false,
    chain_groups: false,
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
    binary_parts: false,
    binding_bases: &[],
    binding_codes: false,
    binding_leads: false,
    binding_words: &[],
    blank_edges: false,
    blank_max: 1,
    block_chains: false,
    block_joins: false,
    block_leads: &[],
    block_words: &[],
    body_parts: false,
    body_words: &[],
    brace_continues: false,
    brace_counts: false,
    brace_dedents: false,
    brace_hugs: true,
    brace_leads: false,
    brace_levels: false,
    brace_pairs: false,
    brace_parts: false,
    brace_remarks: false,
    brace_spaces: false,
    brace_spans: false,
    brace_words: &[],
    branch_joins: false,
    branch_width: 0,
    branch_words: &[],
    bracket_types: true,
    build_blocks: false,
    carriage_breaks: false,
    callee_marks: &[],
    callee_words: &[],
    cast_words: &[b"auto_cast", b"cast", b"transmute"],
    clause_bases: false,
    clause_ends: false,
    clause_words: &[],
    close_hugs: false,
    colon_continues: false,
    comma_continues: false,
    comma_adds: false,
    comma_drops: false,
    construct_words: &[],
    continue_words: &[],
    convention_strings: true,
    define_joins: false,
    define_widths: false,
    define_words: &[],
    declaration_words: &[],
    declare_words: &[],
    dedent_words: &[b"case"],
    document_blocks: false,
    else_width: 0,
    empty_words: &[],
    end_words: &[],
    field_width: 0,
    follow_heads: &[],
    follow_words: &[],
    generic_levels: false,
    generic_nests: false,
    generic_parts: false,
    group_words: &[],
    head_blocks: false,
    head_stops: &[],
    header_braces: false,
    header_extends: false,
    header_joins: false,
    header_levels: false,
    header_parens: false,
    header_words: &[],
    heritage_parts: false,
    hug_braces: false,
    hug_lambdas: false,
    hug_lasts: false,
    hug_soles: false,
    hug_words: &[b"proc"],
    item_words: &[],
    key_quotes: false,
    key_words: &[],
    keyword_gaps: false,
    label_lines: true,
    label_words: &[],
    lambda_flattens: false,
    lead_words: &[],
    level_words: &[],
    lifetime_tight: false,
    link_levels: false,
    link_nests: false,
    link_spans: false,
    list_blanks: false,
    list_fills: false,
    list_groups: false,
    list_hugs: false,
    list_leads: &[],
    list_mixes: 0,
    list_tight: &[],
    list_remarks: false,
    list_sorts: false,
    list_spreads: false,
    list_width: 0,
    list_words: &[],
    literal_joins: false,
    literal_width: 0,
    macro_bodies: false,
    macro_defines: false,
    macro_gaps: false,
    macro_indents: false,
    macro_spans: false,
    member_words: &[],
    nested_levels: false,
    number_forms: false,
    operand_joins: false,
    operand_words: &[b"context"],
    operator_words: &[],
    order_words: &[],
    parameter_words: &[],
    pattern_frames: false,
    pattern_words: &[],
    postfix_words: &[b"^"],
    prefix_words: &[b"#", b"$", b"@"],
    raise_hugged: false,
    remark_carries: false,
    remark_dedents: false,
    sentinel_colons: false,
    remark_gaps: false,
    remark_levels: false,
    return_parens: false,
    rest_binds: false,
    remark_leads: false,
    root_joins: false,
    row_parts: false,
    signature_words: &[],
    skip_words: &[],
    slice_colons: true,
    sole_hugs: false,
    sole_joins: false,
    source_gaps: false,
    source_values: &[],
    source_words: &[],
    spaced_words: &[],
    span_levels: false,
    tight_from_source: &[b"->", b"/", b"::", b"^"],
    spec_depths: false,
    special_macros: &[],
    string_quotes: false,
    template_spans: false,
    template_units: false,
    ternary_colon: true,
    ternary_levels: false,
    tight_words: &[],
    type_leads: &[],
    type_words: &[],
    unary_words: &[b"!", b"&", b"-", b"..", b"..<", b"..="],
    union_parts: false,
    value_cap: 0,
    value_columns: false,
    value_words: &[],
    variant_width: 0,
    verbatim_words: &[],
    units: false,
    width_lists: false,
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

    if !brace::closed(input.source, input.tokens, true, true) {
        return true;
    }

    !brace::balanced(input.source, input.tokens)
}

impl Formatter {
    pub fn reserve(element_count_max: u32, scratch_bytes_max: u32) -> Self {
        Self {
            inner: brace::Formatter::reserve(element_count_max, scratch_bytes_max),
        }
    }

    #[must_use]
    pub fn format(&mut self, input: &Input<'_>, out: &mut Buffer) -> Outcome {
        assert_eq!(input.tokens.len(), input.raw.len());

        if broken(input) {
            return Outcome::Refusal;
        }

        let held = brace::Input {
            roles: &[],
            options: input.options,
            policy: POLICY,
            source: input.source,
            tokens: input.tokens,
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
