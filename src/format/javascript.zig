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
            .policy = policy,
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
};

pub const policy: brace.Policy = .{
    .align_colons = false,
    .angle_calls = false,
    .angle_spreads = false,
    .angle_objects = true,
    .angle_types = false,
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
    .body_settles = true,
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
    .declaration_words = &.{"class"},
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
    .group_words = &.{"as"},
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
    .key_numbers = true,
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
    .list_leads = &.{ ",", "export", "import" },
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
    .operand_levels = true,
    .operand_words = &.{ "import", "super", "this" },
    .operator_words = &.{ "&&", "??", "||" },
    .order_words = &.{},
    .parameter_words = &.{},
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
    .spread_owns = true,
    .spread_values = true,
    .tight_from_source = &.{
        "!",
        "*",
        "+",
        "++",
        "-",
        "--",
        "<",
        "<<",
        ">",
        "?",
        "~",
    },
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
    .type_leads = &.{},
    .type_words = &.{},
    .unary_tight = false,
    .unary_words = &.{ "!", "++", "-", "--", "+", "~", "..." },
    .union_parts = true,
    .value_cap = 0,
    .value_columns = false,
    .value_words = &.{},
    .variant_width = 0,
    .verbatim_words = &.{},
    .units = false,
    .width_lists = true,
    .wrap_words = &.{ "&", "<", "<<", ">", ">>", ">>>", "^", "|" },
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
        .member_expression, .subscript_expression => true,
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

    return false;
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

    return false;
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

    return false;
}

fn initializers(kind: Kind) brace.Initializer {
    assert(kind.is_node());
    assert(kind != .error_node);

    return switch (kind) {
        .for_in_statement, .for_statement => .head,
        .break_statement,
        .class_declaration,
        .continue_statement,
        .debugger_statement,
        .do_statement,
        .empty_statement,
        .export_statement,
        .expression_statement,
        .function_declaration,
        .generator_function_declaration,
        .if_statement,
        .import_statement,
        .labeled_statement,
        .return_statement,
        .statement_block,
        .switch_statement,
        .throw_statement,
        .try_statement,
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

fn drops(inner: Kind, parent: Kind, head: ?Kind, heads: brace.Heads, first: bool) bool {
    assert(inner.is_node());
    assert(parent.is_node());
    if (head) |held| assert(held.is_node());

    if (parent == .decorator) return heads.decorated;
    if (opens(inner)) return true;

    const bodied = inner == .object and heads.bodied;
    if (bodied) return false;

    const stated = heads.statement and opened(inner);
    if (stated) return false;

    switch (inner) {
        .assignment_expression, .augmented_assignment_expression => {
            return assign_dropped(parent, head, first);
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
        if (inner != .call_expression) return false;
        return called(head);
    }

    if (parent == .binary_expression) {
        const operand = switch (inner) {
            .arrow_function, .binary_expression, .ternary_expression => true,
            else => false,
        };

        if (operand) return false;
        return !opens(inner);
    }

    if (parent == .subscript_expression) {
        if (!first) return inner != .sequence_expression;
    }

    switch (parent) {
        .await_expression,
        .member_expression,
        .spread_element,
        .subscript_expression,
        .unary_expression,
        => return operand_dropped(inner, parent),
        else => {},
    }

    return callee_dropped(inner, parent, heads, first) orelse drops_dropped(parent);
}

fn drops_dropped(parent: Kind) bool {
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

fn assign_dropped(parent: Kind, head: ?Kind, first: bool) bool {
    assert(parent.is_node());
    assert(parent != .error_node);
    if (head) |held| assert(held.is_node());

    const chained = switch (parent) {
        .assignment_expression, .augmented_assignment_expression => !first,
        else => false,
    };

    if (chained) return true;
    if (parent != .expression_statement) return false;

    const held = head orelse return true;

    assert(held.is_node());

    return switch (held) {
        .object_pattern, .object_assignment_pattern => false,
        else => true,
    };
}

fn operand_dropped(inner: Kind, parent: Kind) bool {
    assert(inner.is_node());
    assert(parent.is_node());

    const linked = switch (parent) {
        .member_expression, .subscript_expression => true,
        else => false,
    };

    const numbered = inner == .number_node and linked;

    if (valued(inner)) return true;
    if (!literal(inner)) return false;
    return !numbered;
}

fn literal(inner: Kind) bool {
    assert(inner.is_node());
    assert(inner != .error_node);

    return switch (inner) {
        .array,
        .false,
        .meta_property,
        .null,
        .number_node,
        .regex_node,
        .string_node,
        .super,
        .this,
        .true,
        .undefined,
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

    return false;
}

fn spans(inner: Kind, parent: Kind, head: ?Kind) bool {
    assert(inner.is_node());
    assert(parent.is_node());

    if (opens(inner)) return true;
    if (parent == .parenthesized_expression) return true;
    if (head) |held| assert(held.is_node());

    switch (parent) {
        .expression_statement => {
            if (called(head)) return true;

            return switch (inner) {
                .assignment_expression, .augmented_assignment_expression => true,
                else => false,
            };
        },
        .assignment_expression,
        .augmented_assignment_expression,
        .pair,
        .ternary_expression,
        .variable_declarator,
        => return !opens(inner),
        .return_statement, .switch_case, .throw_statement => return !opens(inner),
        else => {},
    }

    if (parent == .binary_expression) {
        if (inner == .binary_expression) return true;
    }

    if (parent == .member_expression) {
        return switch (inner) {
            .array, .class, .function_expression, .generator_function, .object => true,
            else => false,
        };
    }

    const listed = parent == .arguments or parent == .array;

    if (listed) {
        return switch (inner) {
            .arrow_function,
            .array,
            .class,
            .function_expression,
            .generator_function,
            .object,
            => true,
            else => false,
        };
    }

    return switch (inner) {
        .array, .object => true,
        else => false,
    };
}

fn wraps(inner: Kind, parent: Kind, ancestor: ?Kind, first: bool) bool {
    assert(inner.is_node());
    assert(parent.is_node());
    if (ancestor) |held| assert(held.is_node());

    switch (inner) {
        .arrow_function, .function_expression, .generator_function => {
            if (!first) return false;

            return switch (parent) {
                .call_expression, .new_expression => true,
                .member_expression, .subscript_expression => inner == .arrow_function,
                else => false,
            };
        },
        .await_expression, .yield_expression => return wraps_awaited(parent, first),
        .assignment_expression, .augmented_assignment_expression => {
            return assigns(parent, ancestor);
        },
        .binary_expression => return parent == .spread_element,
        .sequence_expression => return sequences(parent, ancestor),
        .ternary_expression => return parent == .spread_element,
        .number_node => {
            if (!first) return false;

            return switch (parent) {
                .member_expression, .subscript_expression => true,
                else => false,
            };
        },
        else => return false,
    }
}

fn wraps_awaited(parent: Kind, first: bool) bool {
    assert(parent.is_node());
    assert(parent != .error_node);

    return switch (parent) {
        .binary_expression, .spread_element, .unary_expression => true,
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
        .expression_statement, .for_statement, .return_statement, .sequence_expression => true,
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

    if (parent == .sequence_expression) {
        const held = ancestor orelse return true;
        return held != .for_statement;
    }

    return true;
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

    return kind == .ternary_expression;
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

    return false;
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
        .assignment_expression,
        .augmented_assignment_expression,
        .binary_expression,
        .call_expression,
        .member_expression,
        .new_expression,
        .optional_chain,
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
        .pair_pattern => .pair,
        .rest_pattern => .rest,
        else => .none,
    };
}

fn queries(kind: Kind) bool {
    assert(kind.is_node());
    assert(kind != .error_node);

    return kind == .ternary_expression;
}

fn nests(above: []const u8, held: []const u8, right: bool) bool {
    assert(above.len > 0);
    assert(held.len > 0);

    return nested(above, held, right);
}

fn signs(inner: Kind, parent: Kind, held: []const u8, above: []const u8, first: bool) ?bool {
    assert(inner.is_node());
    assert(parent.is_node());
    assert(held.len <= std.math.maxInt(u32));
    assert(above.len <= std.math.maxInt(u32));

    switch (inner) {
        .unary_expression, .update_expression => {},
        else => return null,
    }

    if (parent == .unary_expression) return signs_doubled(above, held);
    if (parent != .binary_expression) return null;

    const relation = walk.text_is(above, "in") or walk.text_is(above, "instanceof");
    const tested = inner == .unary_expression and relation;

    if (!first) return false;
    return walk.text_is(above, "**") or tested;
}

fn signs_doubled(above: []const u8, held: []const u8) bool {
    assert(above.len > 0);
    assert(held.len > 0);

    if (walk.text_is(above, "+")) {
        return walk.text_is(held, "+") or walk.text_is(held, "++");
    }

    if (walk.text_is(above, "-")) {
        return walk.text_is(held, "-") or walk.text_is(held, "--");
    }

    return false;
}

fn parens(kind: Kind) bool {
    assert(kind.is_node());
    assert(kind != .error_node);

    return kind == .parenthesized_expression;
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

    return switch (kind) {
        .class, .function_expression, .generator_function => parent == .export_statement,
        .class_declaration, .function_declaration, .generator_function_declaration => true,
        else => false,
    };
}

fn owes(kind: Kind, parent: Kind) bool {
    assert(kind.is_node());
    assert(parent.is_node());

    if (kind == .field_definition) return parent == .class_body;

    return switch (kind) {
        .break_statement,
        .continue_statement,
        .debugger_statement,
        .do_statement,
        .export_statement,
        .expression_statement,
        .import_statement,
        .lexical_declaration,
        .return_statement,
        .throw_statement,
        .variable_declaration,
        => true,
        else => false,
    };
}
