const std = @import("std");
const assert = std.debug.assert;
const Buffer = @import("../stdx/bounded/buffer.zig");
const FormatterError = @import("formatters.zig").FormatterError;
pub const Kind = @import("../syntax/odin/kind.zig").Kind;
const Options = @import("print.zig").Options;
const Span = @import("../stdx/bounded/span.zig");
const Structure = @import("../syntax/tree.zig").Structure;
const Token = @import("../syntax/token.zig");
const Tree = @import("../syntax/tree.zig").TreeType(Kind);
const brace = @import("brace.zig");
const walk = @import("walk.zig");

pub const Formatter = struct {
    inner: brace.Formatter,

    pub fn init(
        gpa: std.mem.Allocator,
        element_count_max: u32,
        scratch_bytes_max: u32,
    ) std.mem.Allocator.Error!Formatter {
        assert(element_count_max > 0);
        assert(scratch_bytes_max > 0);

        const inner = try brace.Formatter.init(gpa, element_count_max, scratch_bytes_max);
        return .{ .inner = inner };
    }

    pub fn deinit(formatter: *Formatter, gpa: std.mem.Allocator) void {
        assert(formatter.inner.angle == 0);
        assert(formatter.inner.spacing > formatter.inner.angle);

        formatter.inner.deinit(gpa);
        formatter.* = undefined;
    }

    pub fn format(formatter: *Formatter, input: *const Input, out: *Buffer) FormatterError!void {
        assert(input.tokens.len == input.raw.len);
        assert(input.source.len <= std.math.maxInt(u32));

        if (broken(input)) return error.SourceInvalid;

        const held: brace.Input = .{
            .added = &.{},
            .gives = &.{},
            .lists = &.{},
            .macros = &.{},
            .marks = &.{},
            .nests = &.{},
            .opaques = &.{},
            .operand_ends = &.{},
            .operands = &.{},
            .options = input.options,
            .origin = &.{},
            .origins = &.{},
            .policy = policy,
            .roles = &.{},
            .source = input.source,
            .tokens = input.tokens,
        };

        formatter.inner.format(&held, out) catch return error.OutputExhausted;

        assert(out.count() <= out.capacity());
    }

    pub fn range(
        formatter: *Formatter,
        input: *const Input,
        lines: walk.LineRange,
        out: *Buffer,
    ) FormatterError!Span {
        assert(lines.first <= lines.last);
        assert(input.tokens.len == input.raw.len);

        try formatter.format(input, out);

        return brace.span_of(out.const_slice(), lines) orelse error.SourceInvalid;
    }
};

pub const Input = struct {
    options: Options,
    outcome: Structure,
    raw: []const Kind,
    source: []const u8,
    tokens: []const Token,
    tree: *const Tree,
};

pub const policy: brace.Policy = .{
    .align_colons = false,
    .angle_calls = false,
    .angle_spreads = false,
    .angle_objects = false,
    .angle_types = false,
    .arm_bars = false,
    .arm_empties = false,
    .arm_flattens = false,
    .arm_guards = false,
    .arrow_after = &.{},
    .arrow_bodies = false,
    .arrow_commas = false,
    .arrow_parens = false,
    .asm_operands = false,
    .assign_groups = false,
    .assign_joins = false,
    .assign_lines = false,
    .assign_values = false,
    .assign_wraps = false,
    .chain_lets = false,
    .chain_simples = false,
    .chain_soles = false,
    .chain_hugs = false,
    .chain_joins = false,
    .chain_groups = false,
    .chain_width = 0,
    .call_budgets = false,
    .call_nests = false,
    .call_width = 0,
    .attribute_ends = false,
    .attribute_joins = false,
    .attribute_spans = false,
    .attribute_width = 0,
    .attribute_words = &.{},
    .bar_aligns = false,
    .bar_levels = false,
    .binary_lines = false,
    .binary_parts = false,
    .binding_bases = &.{},
    .binding_codes = false,
    .binding_leads = false,
    .binder_words = &.{},
    .binding_words = &.{},
    .blank_edges = false,
    .blank_max = 1,
    .block_chains = false,
    .block_joins = false,
    .block_leads = &.{},
    .block_words = &.{},
    .body_owns = false,
    .body_settles = false,
    .body_parts = false,
    .body_words = &.{},
    .brace_bodies = false,
    .brace_comments = false,
    .brace_continues = false,
    .brace_counts = false,
    .brace_dedents = false,
    .brace_hugs = true,
    .brace_leads = false,
    .brace_levels = false,
    .brace_pairs = false,
    .brace_parts = false,
    .brace_spaces = false,
    .brace_spans = false,
    .brace_words = &.{},
    .branch_joins = false,
    .branch_width = 0,
    .branch_words = &.{},
    .bracket_types = true,
    .build_blocks = false,
    .carriage_breaks = false,
    .callee_marks = &.{},
    .callee_words = &.{},
    .cast_joins = false,
    .cast_words = &.{ "auto_cast", "cast", "transmute" },
    .clause_bases = false,
    .clause_ends = false,
    .clause_heads = &.{},
    .clause_lines = false,
    .clause_values = &.{},
    .clause_words = &.{},
    .close_hugs = false,
    .colon_continues = false,
    .comma_continues = false,
    .comma_adds = false,
    .comma_drops = false,
    .comma_joins = false,
    .comma_parts = false,
    .comment_carries = false,
    .comment_dedents = false,
    .comment_gaps = false,
    .comment_leads = false,
    .comment_levels = false,
    .comment_opens = false,
    .comment_spaces = false,
    .comment_suffix = false,
    .comment_tails = false,
    .compose_parts = false,
    .construct_words = &.{},
    .continue_words = &.{},
    .convention_strings = true,
    .dangling_blanks = false,
    .define_joins = false,
    .define_widths = false,
    .define_words = &.{},
    .declare_lines = false,
    .declaration_words = &.{},
    .declare_words = &.{},
    .decorators = false,
    .dedent_words = &.{"case"},
    .document_blocks = false,
    .edge_blanks = false,
    .else_width = 0,
    .empty_follows = &.{},
    .empty_joins = false,
    .empty_semis = false,
    .empty_words = &.{},
    .end_words = &.{},
    .field_width = 0,
    .fill_reserve = 1,
    .follow_heads = &.{},
    .follow_words = &.{},
    .gap_words = &.{},
    .generic_levels = false,
    .generic_nests = false,
    .generic_parts = false,
    .group_words = &.{},
    .head_blanks = false,
    .head_blocks = false,
    .head_stops = &.{},
    .header_braces = false,
    .header_extends = false,
    .header_joins = false,
    .header_levels = false,
    .header_lines = false,
    .header_parens = false,
    .header_widths = false,
    .header_words = &.{},
    .heritage_parts = false,
    .hole_spaces = false,
    .hug_braces = false,
    .hug_lambdas = false,
    .hug_lasts = false,
    .hug_soles = false,
    .hug_words = &.{"proc"},
    .index_continues = false,
    .inline_comments = false,
    .inline_layout = false,
    .item_words = &.{},
    .key_numbers = false,
    .key_quotes = false,
    .key_words = &.{},
    .keyword_gaps = false,
    .label_lines = true,
    .label_words = &.{},
    .lambda_flattens = false,
    .lead_words = &.{},
    .level_words = &.{},
    .lifetime_tight = false,
    .link_levels = false,
    .link_nests = false,
    .link_spans = false,
    .list_blanks = false,
    .list_comments = false,
    .list_fills = false,
    .list_groups = false,
    .list_hugs = false,
    .list_leads = &.{},
    .list_mixes = 0,
    .list_tight = &.{},
    .list_sorts = false,
    .list_spreads = false,
    .list_width = 0,
    .list_words = &.{},
    .literal_joins = false,
    .literal_width = 0,
    .macro_bodies = false,
    .macro_defines = false,
    .macro_gaps = false,
    .macro_indents = false,
    .macro_spans = false,
    .member_words = &.{},
    .nested_levels = false,
    .number_forms = false,
    .object_words = &.{},
    .operand_joins = false,
    .operand_levels = false,
    .operand_words = &.{"context"},
    .operator_words = &.{},
    .order_words = &.{},
    .parameter_words = &.{},
    .pattern_frames = false,
    .pattern_words = &.{},
    .postfix_words = &.{"^"},
    .prefix_words = &.{ "#", "$", "@" },
    .printed_gaps = false,
    .raise_hugged = false,
    .regex_flags = false,
    .sentinel_colons = false,
    .sequence_lines = false,
    .sequence_stops = &.{},
    .return_parens = false,
    .rest_binds = false,
    .root_joins = false,
    .row_parts = false,
    .sibling_levels = false,
    .signature_words = &.{},
    .skip_words = &.{},
    .slice_colons = true,
    .sole_hugs = false,
    .sole_joins = false,
    .source_gaps = false,
    .source_values = &.{},
    .source_words = &.{},
    .spaced_words = &.{},
    .span_levels = false,
    .spread_blanks = false,
    .spread_owns = false,
    .spread_values = false,
    .tight_from_source = &.{ "->", "/", "::", "^" },
    .spec_depths = false,
    .special_macros = &.{},
    .string_quotes = false,
    .template_spans = false,
    .template_units = false,
    .ternary_colon = true,
    .ternary_levels = false,
    .ternary_parts = false,
    .test_joins = false,
    .tight_words = &.{},
    .type_leads = &.{},
    .type_words = &.{},
    .unary_tight = false,
    .unary_words = &.{ "!", "&", "-", "..", "..<", "..=" },
    .union_parts = false,
    .value_cap = 0,
    .value_columns = false,
    .value_words = &.{},
    .variant_width = 0,
    .verbatim_words = &.{},
    .units = false,
    .width_lists = false,
    .wrap_words = &.{},
};

fn broken(input: *const Input) bool {
    assert(input.tokens.len == input.raw.len);
    assert(input.source.len <= std.math.maxInt(u32));

    if (input.outcome != .complete) return true;
    if (input.tree.diagnostic_slice().len > 0) return true;

    for (input.raw) |kind| {
        if (kind == .error_token) return true;
    }

    for (input.tree.slice()) |node| {
        if (node.kind == .error_node) return true;
    }

    if (!brace.closed(input.source, input.tokens, true, true)) return true;
    return !brace.balanced(input.source, input.tokens);
}
