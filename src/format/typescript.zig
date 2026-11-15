const std = @import("std");
const assert = std.debug.assert;
const Buffer = @import("../stdx/bounded/buffer.zig");
const FormatterError = @import("formatters.zig").FormatterError;
pub const Kind = @import("../syntax/javascript/kind.zig").Kind;
const Options = @import("print.zig").Options;
const Span = @import("../stdx/bounded/span.zig");
const Structure = @import("../syntax/tree.zig").Structure;
const Terminators = @import("mask.zig").Terminators;
const Token = @import("../syntax/token.zig");
const Tree = @import("../syntax/tree.zig").TreeType(Kind);
const brace = @import("brace.zig");
const nested = @import("text.zig").nested;
const scan = @import("../text/scan.zig");
const tag = @import("tag.zig");
const walk = @import("walk.zig");

pub const Formatter = struct {
    inner: brace.Formatter,
    stream: Terminators,

    pub fn init(
        gpa: std.mem.Allocator,
        element_count_max: u32,
        scratch_bytes_max: u32,
    ) std.mem.Allocator.Error!Formatter {
        assert(element_count_max > 0);
        assert(scratch_bytes_max > 0);

        var inner = try brace.Formatter.init(gpa, element_count_max, scratch_bytes_max);
        errdefer inner.deinit(gpa);

        const stream = try Terminators.init(gpa, element_count_max, scratch_bytes_max);
        return .{ .inner = inner, .stream = stream };
    }

    pub fn deinit(formatter: *Formatter, gpa: std.mem.Allocator) void {
        assert(formatter.stream.tokens.capacity() > 0);
        assert(formatter.stream.source.capacity() > 0);

        formatter.stream.deinit(gpa);
        formatter.inner.deinit(gpa);
        formatter.* = undefined;
    }

    pub fn format(formatter: *Formatter, input: *const Input, out: *Buffer) FormatterError!void {
        assert(input.tokens.len == input.raw.len);
        assert(input.source.len <= std.math.maxInt(u32));

        if (broken(input)) return error.SourceInvalid;

        brace.terminated(
            Kind,
            input.tree,
            input.source,
            input.tokens,
            &rules,
            &formatter.stream,
        ) catch return error.OutputExhausted;

        const stream = &formatter.stream;

        const held: brace.Input = .{
            .added = &.{},
            .gives = &.{},
            .lists = &.{},
            .macros = &.{},
            .marks = stream.labels_slice(),
            .nests = stream.nests_slice(),
            .opaques = &.{},
            .operand_ends = &.{},
            .operands = &.{},
            .options = input.options,
            .origin = &.{},
            .origins = &.{},
            .policy = if (input.tsx) tsx_policy else policy,
            .roles = stream.roles_slice(),
            .source = stream.source_slice(),
            .tokens = stream.tokens_slice(),
        };

        formatter.inner.format(&held, out) catch return error.OutputExhausted;

        if (std.mem.startsWith(u8, input.source, scan.byte_order_mark)) {
            out.splice(.empty, scan.byte_order_mark) catch return error.OutputExhausted;
        }

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
    tsx: bool,
};

pub const policy: brace.Policy = .{
    .align_colons = false,
    .angle_calls = true,
    .angle_spreads = true,
    .angle_objects = true,
    .angle_types = true,
    .arm_bars = false,
    .arm_empties = false,
    .arm_flattens = false,
    .arm_guards = false,
    .arrow_after = &.{},
    .arrow_bodies = true,
    .arrow_commas = false,
    .arrow_parens = true,
    .asm_operands = false,
    .assign_groups = true,
    .assign_joins = false,
    .assign_lines = true,
    .assign_values = true,
    .assign_wraps = false,
    .chain_lets = false,
    .chain_simples = true,
    .chain_soles = false,
    .chain_hugs = false,
    .chain_joins = false,
    .chain_groups = true,
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
    .binary_lines = true,
    .binary_parts = true,
    .binding_bases = &.{},
    .binding_codes = false,
    .binding_leads = false,
    .binder_words = &.{ "const", "let", "var" },
    .binding_words = &.{},
    .blank_edges = true,
    .blank_max = 1,
    .block_chains = false,
    .block_joins = false,
    .block_leads = &.{},
    .block_words = &.{},
    .body_owns = true,
    .body_settles = false,
    .body_parts = true,
    .body_words = &.{ "=>", "do", "else", "finally", "try" },
    .brace_bodies = false,
    .brace_comments = false,
    .brace_continues = true,
    .brace_counts = false,
    .brace_dedents = false,
    .brace_hugs = false,
    .brace_leads = false,
    .brace_levels = true,
    .brace_pairs = false,
    .brace_parts = false,
    .brace_spaces = true,
    .brace_spans = false,
    .brace_words = &.{},
    .branch_joins = false,
    .branch_width = 0,
    .branch_words = &.{},
    .bracket_types = false,
    .build_blocks = false,
    .carriage_breaks = true,
    .callee_marks = &.{ "?", "?." },
    .callee_words = &.{ "function", "import", "super", "this" },
    .cast_joins = false,
    .cast_words = &.{},
    .clause_bases = false,
    .clause_ends = false,
    .clause_heads = &.{"if"},
    .clause_lines = true,
    .clause_values = &.{},
    .clause_words = &.{ "case", "default" },
    .close_hugs = false,
    .colon_continues = true,
    .comma_continues = true,
    .comma_adds = true,
    .comma_drops = true,
    .comma_joins = true,
    .comma_parts = false,
    .comment_carries = false,
    .comment_dedents = false,
    .comment_gaps = false,
    .comment_leads = false,
    .comment_levels = false,
    .comment_opens = true,
    .comment_spaces = true,
    .comment_suffix = true,
    .comment_tails = false,
    .compose_parts = true,
    .construct_words = &.{"new"},
    .continue_words = &.{ "|", "&" },
    .convention_strings = false,
    .dangling_blanks = true,
    .define_joins = false,
    .define_widths = false,
    .define_words = &.{},
    .declare_lines = true,
    .declaration_words = &.{ "class", "enum", "interface", "module", "namespace" },
    .declare_words = &.{},
    .decorators = true,
    .dedent_words = &.{},
    .document_blocks = false,
    .edge_blanks = false,
    .else_width = 0,
    .empty_follows = &.{"finally"},
    .empty_joins = false,
    .empty_semis = true,
    .empty_words = &.{ "else", "finally", "for", "if", "switch", "try" },
    .end_words = &.{},
    .field_width = 0,
    .fill_reserve = 0,
    .follow_heads = &.{},
    .follow_words = &.{ "catch", "else", "finally", "while" },
    .gap_words = &.{},
    .generic_levels = false,
    .generic_nests = false,
    .generic_parts = false,
    .group_words = &.{ "as", "asserts", "unique" },
    .head_blanks = false,
    .head_blocks = false,
    .head_stops = &.{ "catch", "do", "else", "finally", "try" },
    .header_braces = false,
    .header_extends = false,
    .header_joins = false,
    .header_levels = false,
    .header_lines = true,
    .header_parens = true,
    .header_widths = false,
    .header_words = &.{ "for", "if", "switch", "while" },
    .heritage_parts = true,
    .hole_spaces = true,
    .hug_braces = false,
    .hug_lambdas = false,
    .hug_lasts = true,
    .hug_soles = true,
    .hug_words = &.{},
    .index_continues = false,
    .inline_comments = true,
    .inline_layout = true,
    .item_words = &.{},
    .key_numbers = false,
    .key_quotes = true,
    .key_words = &.{"new"},
    .keyword_gaps = true,
    .label_lines = true,
    .label_words = &.{},
    .lambda_flattens = false,
    .lead_words = &.{"/*"},
    .level_words = &.{},
    .lifetime_tight = false,
    .link_levels = false,
    .link_nests = false,
    .link_spans = false,
    .list_blanks = false,
    .list_comments = false,
    .list_fills = false,
    .list_groups = true,
    .list_hugs = false,
    .list_leads = &.{ ",", "export", "import", "type" },
    .list_mixes = 0,
    .list_tight = &.{},
    .list_sorts = false,
    .list_spreads = true,
    .list_width = 0,
    .list_words = &.{ "export", "import" },
    .literal_joins = false,
    .literal_width = 0,
    .macro_bodies = false,
    .macro_defines = false,
    .macro_gaps = false,
    .macro_indents = false,
    .macro_spans = false,
    .member_words = &.{"?."},
    .nested_levels = false,
    .number_forms = true,
    .object_words = &.{"default"},
    .operand_joins = false,
    .operand_levels = false,
    .operand_words = &.{ "import", "super", "this" },
    .operator_words = &.{ "&&", "??", "||" },
    .order_words = &.{},
    .parameter_words = &.{ "override", "private", "protected", "public", "readonly" },
    .pattern_frames = false,
    .pattern_words = &.{},
    .postfix_words = &.{},
    .prefix_words = &.{ "...", "@" },
    .printed_gaps = true,
    .raise_hugged = false,
    .regex_flags = true,
    .sentinel_colons = false,
    .sequence_lines = true,
    .sequence_stops = &.{
        "abstract",
        "class",
        "declare",
        "enum",
        "export",
        "function",
        "import",
        "interface",
        "module",
        "namespace",
        "type",
    },
    .return_parens = true,
    .rest_binds = true,
    .root_joins = false,
    .row_parts = false,
    .sibling_levels = false,
    .signature_words = &.{},
    .skip_words = &.{},
    .slice_colons = false,
    .sole_hugs = false,
    .sole_joins = false,
    .source_gaps = false,
    .source_values = &.{},
    .source_words = &.{},
    .spaced_words = &.{},
    .span_levels = false,
    .spread_blanks = true,
    .spread_owns = false,
    .spread_values = true,
    .tight_from_source = &.{ "!", "*", "+", "++", "-", "--", "<", "<<", ">", "?", "~" },
    .spec_depths = false,
    .special_macros = &.{},
    .string_quotes = true,
    .template_spans = true,
    .template_units = true,
    .ternary_colon = true,
    .ternary_levels = true,
    .ternary_parts = true,
    .test_joins = true,
    .tight_words = &.{},
    .type_leads = &.{ "abstract", "declare", "export" },
    .type_words = &.{ "interface", "type" },
    .unary_tight = false,
    .unary_words = &.{ "!", "++", "-", "--", "+", "~", "..." },
    .union_parts = true,
    .value_cap = 0,
    .value_columns = false,
    .value_words = &.{"enum"},
    .variant_width = 0,
    .verbatim_words = &.{},
    .units = false,
    .width_lists = true,
    .wrap_words = &.{ "<<", ">>", ">>>", "^" },
};

const tsx_policy: brace.Policy = tsx: {
    var held = policy;

    held.arrow_commas = true;

    break :tsx held;
};

const rules: brace.RulesType(Kind) = .{
    .arrows = arrows,
    .bodiless = bodiless,
    .bodies = bodies,
    .braced = braced,
    .branches = branches,
    .calls = calls,
    .cases = cases,
    .casts = casts,
    .chains = chains,
    .defaults = defaults,
    .denies = denies,
    .drops = drops,
    .holes = holes,
    .imports = imports,
    .initializers = initializers,
    .invokes = invokes,
    .jsx = jsx,
    .jsx_wraps = jsx_wraps,
    .jumps = jumps,
    .labels = labels,
    .leads = opened,
    .links = links,
    .lists = lists,
    .mixes = mixes,
    .names = names,
    .nests = nests,
    .opens = opens,
    .operators = operators,
    .owes = owes,
    .parameters = parameters,
    .parens = parens,
    .passes = passes,
    .patterns = patterns,
    .queries = queries,
    .signs = signs,
    .soles = soles,
    .spans = spans,
    .statements = statements,
    .tests = tests,
    .unaries = unaries,
    .updates = updates,
    .wraps = wraps,
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

    if (broken_unclosed(input)) return true;
    return !brace.balanced(input.source, input.tokens);
}

fn broken_unclosed(input: *const Input) bool {
    assert(input.tokens.len == input.raw.len);
    assert(input.source.len <= std.math.maxInt(u32));

    for (input.raw, 0..) |kind, index| {
        if (content(kind)) continue;

        const token = input.tokens[index..][0..1];
        if (!brace.closed(input.source, token, false, false)) return true;
    }

    return false;
}

fn content(kind: Kind) bool {
    assert(kind.is_token());

    const result = switch (kind) {
        .jsx_chars, .jsx_entity, .template_chars => true,
        else => false,
    };

    if (result) assert(!kind.is_trivia());

    return result;
}

fn arrows(kind: Kind) bool {
    assert(kind.is_node());
    assert(kind != .error_node);

    return kind == .arrow_function;
}

fn bodies(kind: Kind) bool {
    assert(kind.is_node());
    assert(kind != .error_node);

    return kind == .arrow_function;
}

fn calls(kind: Kind) bool {
    assert(kind.is_node());
    assert(kind != .error_node);

    return kind == .new_expression;
}

fn invokes(kind: Kind) bool {
    assert(kind.is_node());
    assert(kind != .error_node);

    return kind == .call_expression;
}

fn jumps(inner: Kind, parent: Kind) bool {
    assert(inner.is_node());
    assert(parent.is_node());

    if (parent != .return_statement) {
        if (parent != .throw_statement) return false;
    }

    return switch (inner) {
        .binary_expression, .jsx_element, .jsx_self_closing_element, .sequence_expression => false,
        else => true,
    };
}

fn links(kind: Kind) bool {
    assert(kind.is_node());
    assert(kind != .error_node);

    return switch (kind) {
        .member_expression, .non_null_expression, .subscript_expression => true,
        else => false,
    };
}

fn parameters(kind: Kind) bool {
    assert(kind.is_node());
    assert(kind != .error_node);

    return kind == .formal_parameters;
}

fn cases(kind: Kind) bool {
    assert(kind.is_node());
    assert(kind != .error_node);

    return kind == .switch_case;
}

fn casts(kind: Kind) bool {
    assert(kind.is_node());
    assert(kind != .error_node);

    return casting(kind);
}

fn chains(kind: Kind) brace.Chained {
    assert(kind.is_node());
    assert(kind != .error_node);

    return switch (kind) {
        .call_expression => .call,
        .member_expression => .member,
        .optional_chain => .optional,
        .subscript_expression => .subscript,
        .template_string => .template,
        else => .none,
    };
}

fn defaults(kind: Kind) bool {
    assert(kind.is_node());
    assert(kind != .error_node);

    return kind == .type_assertion;
}

fn holes(kind: Kind) brace.Holed {
    assert(kind.is_node());
    assert(kind != .error_node);

    return switch (kind) {
        .template_substitution => .hole,
        .arguments, .array, .object, .template_string, .yield_expression => .listed,
        else => .plain,
    };
}

fn imports(query: Kind, head: Kind) bool {
    assert(query.is_node());
    assert(head.is_node());

    if (query != .type_query) return false;
    return head == .import_node;
}

fn initializers(kind: Kind) brace.Initializer {
    assert(kind.is_node());
    assert(kind != .error_node);

    return switch (kind) {
        .for_in_statement, .for_statement => .head,
        .abstract_class_declaration,
        .ambient_declaration,
        .break_statement,
        .class_declaration,
        .continue_statement,
        .debugger_statement,
        .do_statement,
        .empty_statement,
        .enum_declaration,
        .export_statement,
        .expression_statement,
        .function_declaration,
        .function_signature,
        .generator_function_declaration,
        .if_statement,
        .import_alias,
        .import_statement,
        .interface_declaration,
        .internal_module,
        .labeled_statement,
        .module,
        .return_statement,
        .statement_block,
        .switch_statement,
        .throw_statement,
        .try_statement,
        .type_alias_declaration,
        .while_statement,
        .with_statement,
        => .statement,
        else => .none,
    };
}

fn braced(parent: Kind) bool {
    assert(parent.is_node());
    assert(parent != .error_node);

    return parent == .arrow_function;
}

fn drops(inner: Kind, parent: Kind, head: ?Kind, heads: brace.Heads, first: bool) bool {
    assert(inner.is_node());
    assert(parent.is_node());
    if (head) |held| assert(held.is_node());

    if (parent == .decorator) return heads.decorated;
    if (opens(inner)) return true;

    if (typed_inner(inner)) {
        return condition_dropped(inner, parent, first, heads) orelse typed_dropped(inner, parent);
    }

    const object_bodied = inner == .object and heads.bodied;
    if (object_bodied) return false;

    const statement_opened = heads.statement and opened(inner);
    if (statement_opened) return false;

    switch (inner) {
        .assignment_expression, .augmented_assignment_expression => {
            return assign_dropped(parent, head);
        },
        .sequence_expression => return sequence_dropped(parent),
        .ternary_expression => {
            if (parent == .arrow_function) return true;
            if (parent == .ternary_expression) return !first;
        },
        else => {},
    }

    return drops_parent(inner, parent, head, heads, first);
}

fn drops_parent(inner: Kind, parent: Kind, head: ?Kind, heads: brace.Heads, first: bool) bool {
    assert(inner.is_node());
    assert(parent.is_node());
    if (head) |held| assert(held.is_node());

    if (parent == .expression_statement) {
        const call = inner == .call_expression and called(head);
        const plain = heads.plain and stated(inner);

        return call or plain;
    }

    if (parent == .binary_expression) {
        const shaped = switch (inner) {
            .arrow_function, .binary_expression, .ternary_expression => true,
            else => false,
        };

        return !shaped and !opens(inner);
    }

    if (parent == .non_null_expression) return valued(inner) or literal(inner);

    if (parent == .subscript_expression) {
        if (!first) return inner != .sequence_expression;
    }

    if (callee_dropped(inner, parent, heads, first)) |result| return result;

    switch (parent) {
        .await_expression,
        .member_expression,
        .spread_element,
        .subscript_expression,
        .unary_expression,
        => return operand_dropped(inner, parent),
        else => {},
    }

    if (parent == .type_assertion) return assertion_dropped(inner, parent);
    if (cast_chain_dropped(inner, parent, head, heads, first)) |result| return result;
    if (standalone_dropped(inner, parent, first)) |result| return result;
    return dropped(parent) or parent == .public_field_definition;
}

fn assign_dropped(parent: Kind, head: ?Kind) bool {
    assert(parent.is_node());
    assert(parent != .error_node);

    if (parent != .expression_statement) return false;
    if (head) |held| assert(held.is_node());

    const held = head orelse return true;

    assert(held.is_node());

    return switch (held) {
        .object_pattern, .object_assignment_pattern => false,
        else => true,
    };
}

fn callee_dropped(inner: Kind, parent: Kind, heads: brace.Heads, first: bool) ?bool {
    assert(inner.is_node());
    assert(parent.is_node());

    if (parent == .new_expression) {
        const linked = first and links(inner);
        if (linked) return !heads.called;

        if (first) {
            if (inner == .new_expression) return true;
        }
    }

    if (parent != .call_expression) return null;
    return valued(inner);
}

fn standalone_dropped(inner: Kind, parent: Kind, first: bool) ?bool {
    assert(inner.is_node());
    assert(parent.is_node());

    if (parent == .yield_expression) return true;

    if (first) {
        if (casting(parent)) return inner != .object and operand_dropped(inner, parent);
    }

    if (parent == .enum_assignment) return inner != .sequence_expression;
    return null;
}

fn assertion_dropped(inner: Kind, parent: Kind) bool {
    assert(inner.is_node());
    assert(parent == .type_assertion);

    if (inner == .type_assertion) return false;
    return operand_dropped(inner, parent) or inner == .await_expression;
}

fn operand_dropped(inner: Kind, parent: Kind) bool {
    assert(inner.is_node());
    assert(parent.is_node());

    const numbered = inner == .number_node and parent == .member_expression;
    const literate = literal(inner) or littered_node(inner);
    const littered = literate and !numbered;

    if (valued(inner)) return true;
    if (littered) return true;
    return inner == .non_null_expression;
}

fn condition_dropped(inner: Kind, parent: Kind, first: bool, heads: brace.Heads) ?bool {
    assert(inner.is_node());
    assert(parent.is_node());

    if (inner == .conditional_type) {
        const branched = parent == .conditional_type and heads.branch;
        if (branched) return true;
    }

    if (parent == .conditional_type) {
        const operand = switch (inner) {
            .conditional_type, .constructor_type, .function_type, .infer_type => false,
            else => true,
        };

        if (operand) return true;
    }

    const functional = switch (inner) {
        .constructor_type, .function_type => true,
        else => false,
    };

    if (!functional) return null;
    if (parent != .conditional_type) return null;
    return !first;
}

fn typed_dropped(inner: Kind, parent: Kind) bool {
    assert(inner.is_node());
    assert(parent.is_node());

    if (parent == .array_type) return typed_dropped_member(inner);
    if (parent == .intersection_type) return typed_dropped_member(inner);

    if (parent == .union_type) {
        return switch (inner) {
            .conditional_type,
            .constructor_type,
            .function_type,
            .infer_type,
            .intersection_type,
            .union_type,
            => false,
            else => true,
        };
    }

    return typed_loose(parent);
}

fn typed_dropped_member(inner: Kind) bool {
    assert(inner.is_node());
    assert(inner != .error_node);

    return switch (inner) {
        .array_type,
        .generic_type,
        .literal_type,
        .lookup_type,
        .nested_type_identifier,
        .object_type,
        .predefined_type,
        .template_literal_type,
        .this_type,
        .tuple_type,
        .type_identifier,
        => true,
        else => false,
    };
}

fn littered_node(inner: Kind) bool {
    assert(inner.is_node());
    assert(inner != .error_node);

    return switch (inner) {
        .number_node, .regex_node, .string_node => true,
        else => false,
    };
}

fn literal(inner: Kind) bool {
    assert(inner.is_node());
    assert(inner != .error_node);

    return switch (inner) {
        .false,
        .null,
        .number,
        .regex,
        .string,
        .this,
        .true,
        .undefined,
        => true,
        else => false,
    };
}

fn dropped(parent: Kind) bool {
    assert(parent.is_node());
    assert(parent != .error_node);

    return switch (parent) {
        .arguments,
        .array,
        .arrow_function,
        .assignment_expression,
        .augmented_assignment_expression,
        .export_statement,
        .for_in_statement,
        .pair,
        .parenthesized_expression,
        .return_statement,
        .sequence_expression,
        .switch_case,
        .template_substitution,
        .ternary_expression,
        .throw_statement,
        .variable_declarator,
        => true,
        else => false,
    };
}

fn valued(inner: Kind) bool {
    assert(inner.is_node());
    assert(inner != .error_node);

    return switch (inner) {
        .array,
        .call_expression,
        .class,
        .function_expression,
        .generator_function,
        .identifier_node,
        .member_expression,
        .new_expression,
        .object,
        .parenthesized_expression,
        .subscript_expression,
        .template_string,
        => true,
        else => false,
    };
}

fn cast_chain_dropped(
    inner: Kind,
    parent: Kind,
    head: ?Kind,
    heads: brace.Heads,
    first: bool,
) ?bool {
    assert(inner.is_node());
    assert(parent.is_node());

    if (!first) return null;
    if (!casting(parent)) return null;
    if (!casting(inner)) return null;
    if (head) |held| assert(held.is_node());

    const object_headed = if (head) |held| held == .object else false;
    if (!object_headed) return true;
    return !(heads.statement or heads.bodied);
}

fn type_spans(inner: Kind, parent: Kind) bool {
    assert(inner.is_node());
    assert(parent.is_node());

    if (typed_inner(inner)) {
        if (typed_loose(parent)) return true;
        if (typed_dropped(inner, parent)) return true;
    }

    if (inner != .conditional_type) return false;
    return parent == .conditional_type;
}

fn value_spans(inner: Kind, parent: Kind) bool {
    assert(inner.is_node());
    assert(parent.is_node());

    const chain = casting(parent) and casting(inner);
    if (chain) return true;
    if (parent != .arrow_function) return false;
    return inner == .binary_expression;
}

fn casting(kind: Kind) bool {
    assert(kind.is_node());
    assert(kind != .error_node);

    return switch (kind) {
        .as_expression, .satisfies_expression => true,
        else => false,
    };
}

fn stated_spans(inner: Kind) bool {
    assert(inner.is_node());
    assert(inner != .error_node);

    const assigned = switch (inner) {
        .assignment_expression, .augmented_assignment_expression => true,
        else => false,
    };

    return assigned or chained(inner);
}

fn call_spans(parent: Kind) bool {
    assert(parent.is_node());
    assert(parent != .error_node);

    return switch (parent) {
        .arguments, .arrow_function, .binary_expression => true,
        else => false,
    };
}

fn chained(inner: Kind) bool {
    assert(inner.is_node());
    assert(inner != .error_node);

    return switch (inner) {
        .call_expression,
        .member_expression,
        .new_expression,
        .non_null_expression,
        .subscript_expression,
        => true,
        else => false,
    };
}

fn stated(inner: Kind) bool {
    assert(inner.is_node());
    assert(inner != .error_node);

    return switch (inner) {
        .as_expression,
        .await_expression,
        .binary_expression,
        .call_expression,
        .identifier,
        .member_expression,
        .new_expression,
        .non_null_expression,
        .satisfies_expression,
        .subscript_expression,
        .ternary_expression,
        .unary_expression,
        => true,
        else => false,
    };
}

fn called(head: ?Kind) bool {
    if (head) |held| assert(held.is_node());

    const held = head orelse return false;

    assert(held.is_node());
    assert(held != .error_node);

    return switch (held) {
        .arrow_function, .class, .function_expression, .generator_function => true,
        else => false,
    };
}

fn soles(kind: Kind) bool {
    assert(kind.is_node());
    assert(kind != .error_node);

    return kind == .union_type or kind == .intersection_type;
}

fn spans(inner: Kind, parent: Kind, head: ?Kind) bool {
    assert(inner.is_node());
    assert(parent.is_node());

    if (opens(inner)) return true;
    if (type_spans(inner, parent)) return true;
    if (parent == .type_assertion) return true;
    if (parent == .parenthesized_expression) return true;
    if (value_spans(inner, parent)) return true;
    if (head) |held| assert(held.is_node());

    if (parent == .expression_statement) return called(head) or stated_spans(inner);

    const valued_parent = switch (parent) {
        .assignment_expression,
        .augmented_assignment_expression,
        .pair,
        .ternary_expression,
        .variable_declarator,
        .public_field_definition,
        => true,
        else => false,
    };

    if (valued_parent) return !opens(inner);

    switch (parent) {
        .return_statement, .switch_case, .throw_statement => return !opens(inner),
        else => {},
    }

    if (parent == .await_expression) {
        return switch (inner) {
            .call_expression, .member_expression => true,
            else => false,
        };
    }

    return spans_inner(inner, parent);
}

fn spans_inner(inner: Kind, parent: Kind) bool {
    assert(inner.is_node());
    assert(parent.is_node());

    if (parent == .arrow_function) {
        if (inner == .type_assertion) return true;
        if (inner == .ternary_expression) return true;
    }

    if (parent == .member_expression) {
        return switch (inner) {
            .class, .function_expression, .generator_function => true,
            else => false,
        };
    }

    if (parent == .binary_expression) {
        if (inner == .binary_expression) return true;
    }

    const calling = switch (inner) {
        .call_expression, .member_expression, .new_expression => true,
        else => false,
    };

    if (calling) {
        if (call_spans(parent)) return true;
    }

    if (parent == .arguments) return spans_argued(inner);

    return switch (inner) {
        .array, .object => true,
        else => false,
    };
}

fn spans_argued(inner: Kind) bool {
    assert(inner.is_node());
    assert(inner != .error_node);

    return switch (inner) {
        .arrow_function,
        .array,
        .class,
        .function_expression,
        .generator_function,
        .object,
        .ternary_expression,
        .binary_expression,
        .await_expression,
        => true,
        else => false,
    };
}

fn cast_wraps(parent: Kind, first: bool) bool {
    assert(parent.is_node());
    assert(parent != .error_node);

    switch (parent) {
        .call_expression,
        .member_expression,
        .new_expression,
        .non_null_expression,
        .subscript_expression,
        => return first,
        else => {},
    }

    if (first) {
        switch (parent) {
            .assignment_expression, .augmented_assignment_expression => return true,
            else => {},
        }
    }

    return switch (parent) {
        .await_expression,
        .binary_expression,
        .spread_element,
        .ternary_expression,
        .unary_expression,
        => true,
        else => false,
    };
}

fn assertion_wraps(parent: Kind, first: bool) bool {
    assert(parent.is_node());
    assert(parent != .error_node);

    const wrapped = switch (parent) {
        .as_expression,
        .await_expression,
        .satisfies_expression,
        .spread_element,
        .unary_expression,
        => true,
        else => false,
    };

    if (wrapped) return true;
    if (!first) return false;

    return switch (parent) {
        .call_expression,
        .member_expression,
        .new_expression,
        .non_null_expression,
        .subscript_expression,
        => true,
        else => false,
    };
}

fn wraps(inner: Kind, parent: Kind, ancestor: ?Kind, first: bool) bool {
    assert(inner.is_node());
    assert(parent.is_node());
    if (ancestor) |held| assert(held.is_node());

    const arrowed = if (ancestor) |held| held == .arrow_function else false;

    switch (inner) {
        .constructor_type, .function_type => {
            if (parent == .type_annotation) return arrowed;
        },
        .arrow_function, .function_expression, .generator_function => {
            if (!first) return false;

            return switch (parent) {
                .call_expression, .new_expression => true,
                .member_expression, .subscript_expression => inner == .arrow_function,
                else => false,
            };
        },
        .object => {
            if (casting(parent)) {
                if (arrowed) return first;
            }
        },
        .type_assertion => {
            if (parent == .type_assertion) return true;
            return assertion_wraps(parent, first);
        },
        .intersection_type => return parent == .union_type,
        .as_expression, .satisfies_expression => return cast_wraps(parent, first),
        else => {},
    }

    return wraps_value(inner, parent, ancestor, first);
}

fn wraps_value(inner: Kind, parent: Kind, ancestor: ?Kind, first: bool) bool {
    assert(inner.is_node());
    assert(parent.is_node());
    if (ancestor) |held| assert(held.is_node());

    switch (inner) {
        .binary_expression => return parent == .spread_element or (first and casting(parent)),
        .await_expression, .yield_expression => return wraps_awaited(parent, first),
        .assignment_expression, .augmented_assignment_expression => {
            return assigns(parent, ancestor);
        },
        .sequence_expression => return sequences(parent, ancestor),
        .type_query => {
            if (parent == .lookup_type) return first;
        },
        .ternary_expression => return parent == .spread_element,
        else => {},
    }

    return false;
}

fn wraps_awaited(parent: Kind, first: bool) bool {
    assert(parent.is_node());
    assert(parent != .error_node);

    return switch (parent) {
        .binary_expression,
        .unary_expression,
        .spread_element,
        .as_expression,
        .satisfies_expression,
        => true,
        .ternary_expression => first,
        else => false,
    };
}

fn opened(inner: Kind) bool {
    assert(inner.is_node());
    assert(inner != .error_node);

    return switch (inner) {
        .class, .function_expression, .generator_function, .object => true,
        else => false,
    };
}

fn sequence_dropped(parent: Kind) bool {
    assert(parent.is_node());
    assert(parent != .error_node);

    if (sequenced(parent)) return true;
    return parent == .parenthesized_expression;
}

fn sequenced(parent: Kind) bool {
    assert(parent.is_node());
    assert(parent != .error_node);

    return switch (parent) {
        .expression_statement,
        .for_statement,
        .return_statement,
        .sequence_expression,
        => true,
        else => false,
    };
}

fn sequences(parent: Kind, ancestor: ?Kind) bool {
    assert(parent.is_node());
    assert(parent != .error_node);
    if (ancestor) |held| assert(held.is_node());

    if (parent == .parenthesized_expression) return headed(ancestor);

    return switch (parent) {
        .arrow_function,
        .expression_statement,
        .for_statement,
        .return_statement,
        .sequence_expression,
        => false,
        else => true,
    };
}

fn assigns(parent: Kind, ancestor: ?Kind) bool {
    assert(parent.is_node());
    assert(parent != .error_node);
    if (ancestor) |held| assert(held.is_node());

    if (parent == .parenthesized_expression) return headed(ancestor);

    switch (parent) {
        .assignment_expression,
        .augmented_assignment_expression,
        .expression_statement,
        .for_statement,
        => return false,
        else => {},
    }

    if (parent != .sequence_expression) return true;

    const held = ancestor orelse return true;
    return held != .for_statement;
}

fn headed(ancestor: ?Kind) bool {
    if (ancestor) |held| assert(held.is_node());

    const held = ancestor orelse return false;

    assert(held.is_node());
    assert(held != .error_node);

    return switch (held) {
        .do_statement, .if_statement, .switch_statement, .while_statement => true,
        else => false,
    };
}

fn tests(inner: Kind, above: Kind) ?bool {
    assert(inner.is_node());
    assert(above.is_node());

    switch (inner) {
        .assignment_expression, .augmented_assignment_expression => {},
        else => return null,
    }

    return switch (above) {
        .for_statement => true,
        .sequence_expression => false,
        else => null,
    };
}

fn branches(kind: Kind) bool {
    assert(kind.is_node());
    assert(kind != .error_node);

    return switch (kind) {
        .conditional_type, .ternary_expression => true,
        else => false,
    };
}

fn statements(kind: Kind) bool {
    assert(kind.is_node());
    assert(kind != .error_node);

    return kind == .expression_statement;
}

fn labels(kind: Kind) bool {
    assert(kind.is_node());
    assert(kind != .error_node);

    return kind == .labeled_statement;
}

fn lists(kind: Kind) bool {
    assert(kind.is_node());
    assert(kind != .error_node);

    return kind == .object_type;
}

fn unaries(kind: Kind) bool {
    assert(kind.is_node());
    assert(kind != .error_node);

    return kind == .unary_expression;
}

fn updates(kind: Kind) bool {
    assert(kind.is_node());
    assert(kind != .error_node);

    return kind == .update_expression;
}

fn mixes(kind: Kind) bool {
    assert(kind.is_node());
    assert(kind != .error_node);

    return kind == .binary_expression;
}

fn passes(kind: Kind) bool {
    assert(kind.is_node());
    assert(kind != .error_node);

    return switch (kind) {
        .as_expression,
        .assignment_expression,
        .augmented_assignment_expression,
        .binary_expression,
        .call_expression,
        .member_expression,
        .new_expression,
        .non_null_expression,
        .optional_chain,
        .satisfies_expression,
        .sequence_expression,
        .subscript_expression,
        .template_string,
        .ternary_expression,
        => true,
        else => false,
    };
}

fn patterns(kind: Kind) brace.Patterned {
    assert(kind.is_node());
    assert(kind != .error_node);

    return switch (kind) {
        .array_pattern => .array,
        .assignment_expression, .for_in_statement => .assigned,
        .assignment_pattern => .defaulted,
        .catch_clause => .caught,
        .formal_parameters => .parameters,
        .object_pattern => .object,
        .optional_parameter, .required_parameter => .parameter,
        .pair_pattern => .pair,
        .rest_pattern => .rest,
        else => .none,
    };
}

fn queries(kind: Kind) bool {
    assert(kind.is_node());
    assert(kind != .error_node);

    return switch (kind) {
        .conditional_type, .ternary_expression => true,
        else => false,
    };
}

fn nests(above: []const u8, held: []const u8, right: bool) bool {
    assert(above.len > 0);
    assert(held.len > 0);

    return nested(above, held, right);
}

fn signs(inner: Kind, parent: Kind, held: []const u8, above: []const u8, first: bool) ?bool {
    assert(inner.is_node());
    assert(parent.is_node());

    _ = held;
    _ = above;
    _ = first;

    return null;
}

fn parens(kind: Kind) bool {
    assert(kind.is_node());
    assert(kind != .error_node);

    return switch (kind) {
        .parenthesized_expression, .parenthesized_type => true,
        else => false,
    };
}

fn typed_inner(inner: Kind) bool {
    assert(inner.is_node());
    assert(inner != .error_node);

    return switch (inner) {
        .array_type,
        .conditional_type,
        .constructor_type,
        .function_type,
        .generic_type,
        .index_type_query,
        .infer_type,
        .intersection_type,
        .literal_type,
        .lookup_type,
        .nested_type_identifier,
        .object_type,
        .optional_type,
        .predefined_type,
        .readonly_type,
        .rest_type,
        .template_literal_type,
        .this_type,
        .tuple_type,
        .type_identifier,
        .type_query,
        .union_type,
        => true,
        else => false,
    };
}

fn typed_loose(parent: Kind) bool {
    assert(parent.is_node());
    assert(parent != .error_node);

    return switch (parent) {
        .adding_type_annotation,
        .as_expression,
        .constraint,
        .default_type,
        .function_type,
        .omitting_type_annotation,
        .opting_type_annotation,
        .satisfies_expression,
        .type_alias_declaration,
        .type_annotation,
        .type_arguments,
        .type_predicate,
        .type_predicate_annotation,
        => true,
        else => false,
    };
}

fn names(kind: Kind) bool {
    assert(kind.is_node());
    assert(kind != .error_node);

    return switch (kind) {
        .identifier_node,
        .private_property_identifier,
        .property_identifier,
        .shorthand_property_identifier,
        .shorthand_property_identifier_pattern,
        .statement_identifier,
        .type_identifier,
        => true,
        else => false,
    };
}

fn jsx(kind: Kind) tag.Jsx {
    assert(kind.is_node());
    assert(kind != .error_node);

    return switch (kind) {
        .jsx_attribute => .attribute,
        .jsx_closing_element => .closing,
        .jsx_element => .element,
        .jsx_expression => .expression,
        .jsx_opening_element => .opening,
        .jsx_self_closing_element => .self_closing,
        .jsx_text => .text,
        else => .none,
    };
}

fn jsx_wraps(parent: Kind) bool {
    assert(parent.is_node());
    assert(parent != .error_node);

    return switch (parent) {
        .arguments, .array, .expression_statement => false,
        else => true,
    };
}

fn opens(kind: Kind) bool {
    assert(kind.is_node());
    assert(kind != .error_node);

    return switch (kind) {
        .jsx_element, .jsx_self_closing_element => true,
        else => false,
    };
}

fn operators(kind: Kind) bool {
    assert(kind.is_node());
    assert(kind != .error_node);

    return switch (kind) {
        .arrow_function,
        .assignment_expression,
        .augmented_assignment_expression,
        .binary_expression,
        .variable_declarator,
        => true,
        else => false,
    };
}

fn bodiless(kind: Kind) bool {
    assert(kind.is_node());

    return kind == .module;
}

fn denies(kind: Kind, parent: Kind) bool {
    assert(kind.is_node());
    assert(parent.is_node());

    if (kind == .statement_block) return parent == .ambient_declaration;

    switch (kind) {
        .class, .function_expression, .generator_function => {
            return parent == .export_statement;
        },
        else => {},
    }

    return switch (kind) {
        .abstract_class_declaration,
        .class_declaration,
        .enum_declaration,
        .function_declaration,
        .generator_function_declaration,
        .interface_declaration,
        .internal_module,
        .module,
        => true,
        else => false,
    };
}

fn owes(kind: Kind, parent: Kind) bool {
    assert(kind.is_node());
    assert(parent.is_node());

    switch (kind) {
        .abstract_method_signature,
        .call_signature,
        .construct_signature,
        .index_signature,
        .method_signature,
        .property_signature,
        .public_field_definition,
        => {
            return switch (parent) {
                .class_body, .interface_body, .object_type => true,
                else => false,
            };
        },
        else => {},
    }

    return switch (kind) {
        .break_statement,
        .continue_statement,
        .debugger_statement,
        .do_statement,
        .export_statement,
        .expression_statement,
        .function_signature,
        .import_statement,
        .lexical_declaration,
        .return_statement,
        .throw_statement,
        .type_alias_declaration,
        .variable_declaration,
        => true,
        else => false,
    };
}
