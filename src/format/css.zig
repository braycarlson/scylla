const std = @import("std");
const assert = std.debug.assert;
const ArrayType = @import("../stdx/bounded/array.zig").ArrayType;
const Buffer = @import("../stdx/bounded/buffer.zig");
const FormatterError = @import("formatters.zig").FormatterError;
pub const Kind = @import("../syntax/css/kind.zig").Kind;
const Options = @import("print.zig").Options;
const Span = @import("../stdx/bounded/span.zig");
const Structure = @import("../syntax/tree.zig").Structure;
const Token = @import("../syntax/token.zig");
const Tree = @import("../syntax/tree.zig").TreeType(Kind);
const brace = @import("brace.zig");
const padded = @import("text.zig").spaced;
const scan = @import("../text/scan.zig");
const walk = @import("walk.zig");

pub const Formatter = struct {
    inner: brace.Formatter,
    roles: ArrayType(u16),
    scratch: Buffer,
    staged: Buffer,

    pub fn init(
        gpa: std.mem.Allocator,
        element_count_max: u32,
        scratch_bytes_max: u32,
    ) std.mem.Allocator.Error!Formatter {
        assert(element_count_max > 0);
        assert(scratch_bytes_max > 0);

        var inner = try brace.Formatter.init(gpa, element_count_max, scratch_bytes_max);
        errdefer inner.deinit(gpa);

        var roles = try ArrayType(u16).init(gpa, element_count_max);
        errdefer roles.deinit(gpa);

        var scratch = try Buffer.init(gpa, scratch_bytes_max);
        errdefer scratch.deinit(gpa);

        const staged = try Buffer.init(gpa, scratch_bytes_max);

        return .{
            .inner = inner,
            .roles = roles,
            .scratch = scratch,
            .staged = staged,
        };
    }

    pub fn deinit(formatter: *Formatter, gpa: std.mem.Allocator) void {
        assert(formatter.scratch.capacity() == formatter.staged.capacity());
        assert(formatter.roles.count() <= formatter.roles.capacity());

        formatter.staged.deinit(gpa);
        formatter.scratch.deinit(gpa);
        formatter.roles.deinit(gpa);
        formatter.inner.deinit(gpa);
        formatter.* = undefined;
    }

    pub fn format(formatter: *Formatter, input: *const Input, out: *Buffer) FormatterError!void {
        assert(input.tokens.len == input.raw.len);
        assert(input.source.len <= std.math.maxInt(u32));

        if (broken(input)) return error.SourceInvalid;

        formatter.staging(input) catch return error.OutputExhausted;

        formatter.laying(input, out) catch {
            out.clear();

            return error.OutputExhausted;
        };

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

    fn staging(formatter: *Formatter, input: *const Input) error{Overflow}!void {
        assert(input.tokens.len == input.raw.len);
        assert(input.source.len <= std.math.maxInt(u32));

        try brace.marked(Kind, input.tree, input.tokens, &formatter.roles);

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
            .roles = formatter.roles.const_slice(),
            .source = input.source,
            .tokens = input.tokens,
        };

        try formatter.inner.format(&held, &formatter.scratch);

        formatter.staged.clear();

        try normalized(formatter.scratch.const_slice(), &formatter.staged);

        assert(formatter.roles.count() == input.tokens.len);
    }

    fn laying(formatter: *Formatter, input: *const Input, out: *Buffer) error{Overflow}!void {
        assert(input.source.len <= std.math.maxInt(u32));
        assert(input.options.line_width > 0);

        out.clear();

        try laid(formatter.staged.const_slice(), input.options, out);

        if (!std.mem.startsWith(u8, input.source, scan.byte_order_mark)) return;

        formatter.scratch.clear();

        try formatter.scratch.push(out.const_slice());

        out.clear();

        try bommed(input.source, formatter.scratch.const_slice(), input.options, out);
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

const Call = struct {
    args: []const u8,
    indent: u32,
    offset: u32,
    operated: bool,
    rest: []const u8,
    rider: []const u8,
    spill: ?Spill,
};

const Comment = struct {
    end: u32,
    gap: Gap,
    start: u32,
};

const Digits = struct {
    end: u32,
    fraction: u32,
    whole: u32,
};

const Gap = enum {
    empty,
    soft,
    space,
};

const Laying = struct {
    block: bool,
    comment_above: bool,
    listed: bool,
    opener: u32,
    valued: bool,

    fn advanced(laying: *Laying, line: []const u8, crossed_now: bool, tail: bool) void {
        assert(line.len <= std.math.maxInt(u32));

        const body = scan.trim_ascii(line);
        const spoken = !laying.block and body.len > 0;

        assert(body.len <= line.len);
        if (tail) assert(laying.block);

        if (spoken) {
            const comment_only = std.mem.startsWith(u8, body, "/*");

            laying.comment_above = comment_only and comments_lead(body) >= body.len;
        } else if (laying.block) {
            laying.comment_above = !tail;
        } else {}

        const plain = !laying.block and !crossed_now and body.len > 0;
        const lists = tail or (plain and !laying.comment_above);

        if (lists) laying.listed = std.mem.endsWith(u8, body, ",");

        const opens = !laying.block and crossed_now;

        if (opens) laying.opener = indent_of(line);
        if (spoken) laying.valued = values_onward(body, laying.valued);

        laying.block = crossed_now;
    }
};

const Marked = struct {
    comment_count: u32,
    flat: ?u32,
    literal: ?u32,
    selector: []const u8,
    selector_start: u32,
    tail: u32,
};

const Matched = union(enum) {
    nested: Pseudo,
    written,
};

const Nested = struct {
    found: Parens,
    indent: u32,
    part: []const u8,
};

const Parens = struct {
    close: u32,
    open: u32,
};

const Pseudo = struct {
    args: []const u8,
    level: u32,
    offset: u32,
    rest: []const u8,
    tail: u32,
};

const Reading = struct {
    block: bool,
    bracket: bool,
    depth: u32,
    urled: u32,
    valued: bool,

    fn tracked(reading: *Reading, byte: u8) void {
        switch (byte) {
            '(' => reading.depth += 1,
            '[' => {
                reading.bracket = true;
                reading.depth += 1;
            },
            ')', ']' => {
                reading.bracket = false;

                reading.depth -|= 1;

                if (reading.depth < reading.urled) reading.urled = 0;
            },
            ':' => {
                if (reading.depth == 0) reading.valued = true;
            },
            else => {},
        }

        assert(reading.urled <= reading.depth);
    }
};

const Selecting = struct {
    based: u32,
    indent: u32,
    led: bool,
    opened: u32,
    paired: bool,
    prefix: []const u8,
    seated: u32,
    shift: u32,
    tail: []const u8,
};

const Spill = struct {
    carried: u32,
    column: u32,
    indent: u32,
    level: u32,
    offset: u32,
    part: []const u8,
    split: bool,
    started: bool,
};

const Spread = struct {
    column: u32,
    spilt: bool,
};

const Step = union(enum) {
    advanced,
    finished,
    nested: Nested,
};

const Stop = struct {
    at: u32,
    comma: bool,
};

const Tally = struct {
    count: u32,
    size: u32,
};

const TailCode = struct {
    code: []const u8,
    prefix: []const u8,
};

const frame_depth_max: u32 = brace.nest_depth_max;
const layer_fill_max: u32 = 12;

const nth_words = [_][]const u8{
    "nth-child",
    "nth-col",
    "nth-last-child",
    "nth-last-col",
    "nth-last-of-type",
    "nth-of-type",
};

const rule_words = [_][]const u8{
    "charset",
    "color-profile",
    "container",
    "counter-style",
    "document",
    "font-face",
    "font-feature-values",
    "font-palette-values",
    "import",
    "keyframes",
    "layer",
    "media",
    "namespace",
    "page",
    "position-try",
    "property",
    "scope",
    "starting-style",
    "styleset",
    "supports",
    "view-transition",
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
    .blank_edges = true,
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
    .brace_hugs = false,
    .brace_leads = true,
    .brace_levels = false,
    .brace_pairs = false,
    .brace_parts = true,
    .brace_spaces = false,
    .brace_spans = false,
    .brace_words = &.{},
    .branch_joins = false,
    .branch_width = 0,
    .branch_words = &.{},
    .bracket_types = false,
    .build_blocks = false,
    .carriage_breaks = true,
    .callee_marks = &.{},
    .callee_words = &.{},
    .cast_joins = false,
    .cast_words = &.{},
    .clause_bases = false,
    .clause_ends = false,
    .clause_heads = &.{},
    .clause_lines = false,
    .clause_values = &.{},
    .clause_words = &.{},
    .close_hugs = false,
    .colon_continues = false,
    .comma_adds = false,
    .comma_continues = false,
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
    .convention_strings = false,
    .dangling_blanks = true,
    .define_joins = false,
    .define_widths = false,
    .define_words = &.{},
    .declare_lines = false,
    .declaration_words = &.{},
    .declare_words = &.{},
    .decorators = false,
    .dedent_words = &.{},
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
    .hug_words = &.{},
    .index_continues = false,
    .inline_comments = false,
    .inline_layout = false,
    .item_words = &.{},
    .key_numbers = false,
    .key_quotes = false,
    .key_words = &.{},
    .keyword_gaps = false,
    .label_lines = false,
    .label_words = &.{},
    .lambda_flattens = false,
    .lead_words = &.{"/**"},
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
    .operand_words = &.{},
    .operator_words = &.{},
    .order_words = &.{},
    .parameter_words = &.{},
    .pattern_frames = false,
    .pattern_words = &.{},
    .postfix_words = &.{},
    .prefix_words = &.{ "#", "$", "--", "@" },
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
    .source_gaps = true,
    .source_values = &.{
        "grid",
        "grid-template",
        "grid-template-areas",
        "grid-template-columns",
        "grid-template-rows",
    },
    .source_words = &.{},
    .spaced_words = &.{"/"},
    .span_levels = false,
    .spec_depths = false,
    .special_macros = &.{},
    .spread_blanks = false,
    .spread_owns = false,
    .spread_values = false,
    .string_quotes = false,
    .template_spans = false,
    .template_units = false,
    .ternary_colon = false,
    .ternary_levels = false,
    .ternary_parts = false,
    .test_joins = false,
    .tight_from_source = &.{ "*", "+", "-", ">", "~" },
    .tight_words = &.{},
    .type_leads = &.{},
    .type_words = &.{},
    .unary_tight = false,
    .unary_words = &.{"-"},
    .union_parts = false,
    .units = true,
    .width_lists = false,
    .wrap_words = &.{},
    .value_cap = 12,
    .value_columns = false,
    .value_words = &.{},
    .variant_width = 0,
    .verbatim_words = &.{"url"},
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

    if (!brace.closed(input.source, input.tokens, false, false)) return true;
    if (!brace.balanced(input.source, input.tokens)) return true;
    if (slashes_doubled(input)) return true;
    if (separated_value(input)) return true;
    return slash_led(input);
}

fn separated_value(input: *const Input) bool {
    assert(input.tokens.len == input.raw.len);
    assert(input.source.len <= std.math.maxInt(u32));

    for (input.tree.slice()) |node| {
        if (node.kind != .declaration) continue;

        assert(node.token_start <= node.token_end);
        assert(node.token_end <= input.raw.len);

        for (node.token_start..node.token_end) |position| {
            if (separates(input, @intCast(position), node.token_end)) return true;
        }
    }

    return false;
}

fn separates(input: *const Input, position: u32, end: u32) bool {
    assert(position < end);
    assert(end <= input.raw.len);

    return switch (input.raw[position]) {
        .brace_close, .brace_open => true,
        .semicolon => position + 1 < end and !within_url(input, position),
        else => false,
    };
}

fn slash_led(input: *const Input) bool {
    assert(input.tokens.len == input.raw.len);
    assert(input.source.len <= std.math.maxInt(u32));

    for (input.tree.slice()) |node| {
        if (node.kind != .plain_value) continue;
        if (node.token_start >= node.token_end) continue;
        if (input.raw[node.token_start] != .slash) continue;
        if (!within_url(input, node.token_start)) return true;
    }

    return false;
}

fn slashes_doubled(input: *const Input) bool {
    assert(input.tokens.len == input.raw.len);
    assert(input.source.len <= std.math.maxInt(u32));

    for (input.raw[0..input.raw.len -| 1], 0..) |kind, position| {
        if (kind != .slash) continue;
        if (input.raw[position + 1] != .slash) continue;
        if (input.tokens[position].end() != input.tokens[position + 1].offset) continue;
        if (!within_url(input, @intCast(position))) return true;
    }

    return false;
}

fn within_url(input: *const Input, position: u32) bool {
    assert(position < input.tokens.len);
    assert(input.tokens.len == input.raw.len);

    var node = innermost_of(input.tree, position) orelse return false;

    for (0..input.tree.count()) |_| {
        const held = input.tree.at(node);

        if (held.kind == .call_expression) {
            if (held.token_start < held.token_end) {
                const name = input.tokens[held.token_start].text(input.source);
                if (std.ascii.eqlIgnoreCase(name, "url")) return true;
            }
        }

        if (held.parent >= input.tree.count()) return false;

        node = held.parent;
    }

    return false;
}

fn innermost_of(tree: *const Tree, position: u32) ?u32 {
    if (tree.count() == 0) return null;
    assert(position < std.math.maxInt(u32));

    var node: u32 = 0;

    for (0..tree.count()) |_| {
        node = enclosing_child(tree, node, position) orelse break;
    }

    assert(node < tree.count());

    return node;
}

fn enclosing_child(tree: *const Tree, node: u32, position: u32) ?u32 {
    assert(node < tree.count());

    var child = tree.child_first_of(node);

    for (0..tree.count()) |_| {
        const held = child orelse return null;
        const span = tree.at(held);

        if (span.token_start <= position) {
            if (position < span.token_end) return held;
        }

        child = tree.sibling_next_of(held);
    }

    return null;
}

fn normalized(bytes: []const u8, out: *Buffer) error{Overflow}!void {
    assert(bytes.len <= std.math.maxInt(u32));
    assert(out.empty());

    var reading: Reading = .{
        .block = false,
        .bracket = false,
        .depth = 0,
        .urled = 0,
        .valued = false,
    };

    var carried = false;
    var chained = false;
    var joined = false;
    var offset: u32 = 0;
    var headed = false;
    var line_opened = false;
    var line_start: u32 = 0;
    var valued = false;

    while (offset < bytes.len) {
        const end = line_end(bytes, offset);
        const line = if (joined) trim_start(bytes[offset..end]) else bytes[offset..end];
        const opened = reading.block;
        const continued = !opened and continues_value(line, valued);
        const values = carried or continued or (!reading.block and declares(line));

        if (!joined) {
            headed = heads_a_rule(line);
            line_opened = opened;
            line_start = out.count();
            reading.bracket = false;
            reading.depth = 0;
            reading.urled = 0;
            reading.valued = headed or continued;
        }

        const kept_comma = opened or continued;
        const moved = if (kept_comma) null else moved_comma(line, bytes[end..], headed);

        try normalized_line(line, moved, values, &reading, out);

        const bare = joined and comments_only(line);
        const continues = if (bare) chained else carries(line, opened, bytes[end..], headed);
        const carrying = !reading.block and !continued and continues;
        const after = blank_after(bytes, end, carrying);
        const following = scan.trim_ascii(bytes[after..line_end(bytes, after)]);
        const joins = carrying and !std.mem.startsWith(u8, following, "}");
        const ended = !joins and !line_opened;

        if (ended) valued = values_onward(scan.trim_ascii(out.const_slice()[line_start..]), valued);

        try out.push(gap_of(joins, following));

        carried = joins and (values or moved != null);
        chained = carrying;
        joined = joins;
        offset = if (joins) after else end + 1;
    }

    assert(reading.urled <= reading.depth);
}

fn normalized_line(
    line: []const u8,
    moved: ?u32,
    values: bool,
    reading: *Reading,
    out: *Buffer,
) error{Overflow}!void {
    assert(line.len <= std.math.maxInt(u32));
    assert(reading.urled <= reading.depth);
    if (moved) |held| assert(held < std.math.maxInt(u32));

    const comma = moved orelse return lined(line, values, reading, out);

    assert(comma < line.len);

    try lined(trim_end(line[0..comma]), values, reading, out);

    if (!std.mem.endsWith(u8, out.const_slice(), " ")) try out.push(" ");

    try lined(trim_end(line[comment_at(line)..]), values, reading, out);
    try out.push(",");
}

fn lined(line: []const u8, values: bool, reading: *Reading, out: *Buffer) error{Overflow}!void {
    assert(line.len <= std.math.maxInt(u32));
    assert(reading.urled <= reading.depth);

    var offset: u32 = 0;

    while (offset < line.len) {
        if (reading.block) {
            const found = scan.find(line[offset..], "*/");
            const stop = if (found) |end| offset + end + 2 else extent(line);

            reading.block = found == null;

            try out.push(line[offset..stop]);

            offset = stop;

            continue;
        }

        const stop = try stepped(line, offset, values, reading, out);

        assert(stop > offset);

        offset = stop;
    }
}

fn stepped(
    line: []const u8,
    offset: u32,
    values: bool,
    reading: *Reading,
    out: *Buffer,
) error{Overflow}!u32 {
    assert(offset < line.len);
    assert(reading.urled <= reading.depth);

    const byte = line[offset];

    if (byte == '\\') {
        const stop = scan.escape_end(line, offset);

        try out.push(line[offset..stop]);

        return stop;
    }

    if (std.mem.startsWith(u8, line[offset..], "/*")) {
        reading.block = true;

        try out.push("/*");

        assert(offset + 2 <= line.len);

        return offset + 2;
    }

    if (is_quote(byte)) return quoted(line, offset, out);

    if (opens_a_url(line, offset)) {
        reading.depth += 1;
        reading.urled = reading.depth;

        try out.push("url(");

        assert(offset + 4 <= line.len);

        return offset + 4;
    }

    reading.tracked(byte);

    return stepped_selector(line, offset, values, reading, out);
}

fn stepped_selector(
    line: []const u8,
    offset: u32,
    values: bool,
    reading: *const Reading,
    out: *Buffer,
) error{Overflow}!u32 {
    assert(offset < line.len);
    assert(reading.urled <= reading.depth);

    const byte = line[offset];
    const ruling = byte == '@' and comments_or_blank(line[0..offset]);

    if (ruling) {
        const stop = try named_rule(line, offset, out);
        if (stop > offset) return stop;
    }

    const counting = !values and byte == '(' and counts(line, offset);

    if (counting) {
        try out.push("(");

        const returned = try counted_at(line, skipped(line, offset + 1), out);

        assert(returned < std.math.maxInt(u32));

        return returned;
    }

    const attributing = reading.bracket and byte == '=';

    if (attributing) {
        const stop = try attributed(line, offset, out);
        if (stop > offset) return stop;
    }

    const next = scan.byte_at(line, offset + 1);
    const assigns = next == '=';
    const signs = line[offset] == '+' and next != null and std.ascii.isDigit(next.?);
    const combines = combinator(line[offset .. offset + 1]) and !assigns and !signs;
    const joining = !values and reading.depth == 0 and combines;

    if (joining) {
        try out.push(lead_of(line, offset, out));
        try out.push(line[offset .. offset + 1]);
        try out.push(" ");

        const returned = skipped(line, offset + 1);

        assert(returned < std.math.maxInt(u32));

        return returned;
    }

    return stepped_value(line, offset, values, reading, out);
}

fn stepped_value(
    line: []const u8,
    offset: u32,
    values: bool,
    reading: *const Reading,
    out: *Buffer,
) error{Overflow}!u32 {
    assert(offset < line.len);
    assert(reading.urled <= reading.depth);

    const byte = line[offset];
    const reads = values and reading.valued and reading.urled == 0;

    if (reads) {
        const multiplies = byte == '*' and scan.byte_at(line, offset + 1) != '=';

        if (multiplies) {
            try out.push(lead_of(line, offset, out));
            try out.push("* ");

            const returned = skipped(line, offset + 1);

            assert(returned < std.math.maxInt(u32));

            return returned;
        }

        if (byte == '#') {
            const stop = try coloured(line, offset, out);
            if (stop > offset) return stop;
        }

        if (opens_a_number(line, offset)) return numbered(line, offset, out);
    }

    try out.push(line[offset .. offset + 1]);

    assert(offset + 1 <= line.len);

    return offset + 1;
}

fn lead_of(line: []const u8, offset: u32, out: *const Buffer) []const u8 {
    assert(offset < line.len);
    assert(line.len <= std.math.maxInt(u32));

    if (spaces_only(line[0..offset])) return "";
    if (line[offset - 1] == ' ') return "";
    if (std.mem.endsWith(u8, out.const_slice(), " ")) return "";
    return " ";
}

fn carries(line: []const u8, opened: bool, rest: []const u8, headed: bool) bool {
    assert(line.len <= std.math.maxInt(u32));
    assert(rest.len <= std.math.maxInt(u32));

    const at = comment_at(line);

    assert(at <= line.len);

    if (at >= line.len) return !opened and opens_onto_comment(line, rest, headed);

    var from: u32 = 0;

    if (opened) from = if (scan.find(line, "*/")) |end| end + 2 else extent(line);

    const body = scan.trim_ascii(line[@min(from, at)..at]);
    if (comments_lead(body) >= body.len) return false;

    return switch (body[body.len - 1]) {
        ';', '{', '}' => false,
        ',' => !selects(body, rest, headed),
        else => true,
    };
}

fn heads_a_rule(line: []const u8) bool {
    assert(line.len <= std.math.maxInt(u32));

    const body = scan.trim_ascii(line);
    const lead = comments_lead(body);

    assert(lead <= body.len);

    if (lead >= body.len) return false;
    return body[lead] == '@';
}

fn comments_or_blank(head: []const u8) bool {
    assert(head.len <= std.math.maxInt(u32));

    const body = scan.trim_ascii(head);

    assert(body.len <= head.len);

    return comments_lead(body) >= body.len;
}

fn comments_only(line: []const u8) bool {
    assert(line.len <= std.math.maxInt(u32));

    const body = scan.trim_ascii(line);

    assert(body.len <= line.len);

    if (body.len == 0) return false;
    return comments_lead(body) >= body.len;
}

fn opens_onto_comment(line: []const u8, rest: []const u8, headed: bool) bool {
    assert(line.len <= std.math.maxInt(u32));
    assert(rest.len <= std.math.maxInt(u32));

    const body = scan.trim_ascii(line);
    if (body.len == 0) return false;

    const opens = switch (body[body.len - 1]) {
        '(', ',', ':' => true,
        else => false,
    };

    if (!opens) return false;
    if (rest.len == 0) return false;

    assert(rest[0] == '\n');

    const following = scan.trim_ascii(rest[1..line_end(rest, 1)]);
    if (!std.mem.startsWith(u8, following, "/*")) return false;
    return !selects(body, rest, headed);
}

fn moved_comma(line: []const u8, rest: []const u8, headed: bool) ?u32 {
    assert(line.len <= std.math.maxInt(u32));
    assert(rest.len <= std.math.maxInt(u32));

    if (headed) return null;

    const at = comment_at(line);
    if (at >= line.len) return null;
    if (!std.mem.endsWith(u8, trim_end(line), "*/")) return null;

    const code = trim_end(line[0..at]);
    if (code.len == 0) return null;
    if (code[code.len - 1] != ',') return null;
    if (selects(scan.trim_ascii(code), rest, false)) return null;
    assert(code.len - 1 < std.math.maxInt(u32));

    return @intCast(code.len - 1);
}

fn selects(body: []const u8, rest: []const u8, headed: bool) bool {
    assert(body.len > 0);
    assert(rest.len <= std.math.maxInt(u32));

    if (headed) return false;
    if (body[0] == '@') return false;

    const opened = top_level_at(rest, '{') orelse return false;
    const stated = top_level_at(rest, ';') orelse rest.len;
    const closed = top_level_at(rest, '}') orelse rest.len;

    return opened < @min(stated, closed);
}

fn blank_after(bytes: []const u8, end: u32, carrying: bool) u32 {
    assert(end <= bytes.len);
    assert(bytes.len <= std.math.maxInt(u32));

    var after = @min(end + 1, extent(bytes));
    if (!carrying) return after;

    for (0..bytes.len) |_| {
        if (after >= bytes.len) break;

        const stop = line_end(bytes, after);
        if (scan.trim_ascii(bytes[after..stop]).len > 0) break;

        after = @min(stop + 1, extent(bytes));
    }

    assert(after <= bytes.len);

    return after;
}

fn gap_of(joins: bool, following: []const u8) []const u8 {
    assert(following.len <= std.math.maxInt(u32));

    if (!joins) return "\n";
    if (following.len == 0) return " ";

    assert(!scan.is_ascii_whitespace(following[0]));

    return switch (following[0]) {
        ')', ',', ';' => "",
        else => " ",
    };
}

fn declares(line: []const u8) bool {
    assert(line.len <= std.math.maxInt(u32));

    const body = scan.trim_ascii(line[0..comment_at(line)]);

    assert(body.len <= line.len);

    if (body.len == 0) return false;
    if (heads_a_rule(body)) return true;
    if (ends_selector(body)) return false;
    return colon_of(body) != null;
}

fn laid(bytes: []const u8, options: Options, out: *Buffer) error{Overflow}!void {
    assert(bytes.len <= std.math.maxInt(u32));
    assert(options.line_width > 0);

    var laying: Laying = .{
        .block = false,
        .comment_above = false,
        .listed = false,
        .opener = 0,
        .valued = false,
    };

    var offset: u32 = 0;

    while (offset < bytes.len) {
        const end = line_end(bytes, offset);
        const line = bytes[offset..end];
        const dropped = laying.listed and !laying.block and scan.trim_ascii(line).len == 0;

        offset = end + 1;

        if (dropped) continue;

        const crossed_now = crossing(line, laying.block);
        const tail = laying.block and !crossed_now and tail_code(line) != null;
        const verbatim = laying.block or crossed_now;

        if (tail) {
            try tail_written(line, laying.opener, options.line_width, out);
        } else if (verbatim) {
            try out.push(line);
        } else {
            try written(line, closes(bytes, end), &laying, options, out);
        }

        try out.push("\n");

        laying.advanced(line, crossed_now, tail);
    }
}

fn crossing(line: []const u8, block: bool) bool {
    assert(line.len <= std.math.maxInt(u32));

    var inside = block;
    var offset: u32 = 0;
    var quote: u8 = 0;

    while (offset < line.len) {
        if (inside) {
            const end = scan.find(line[offset..], "*/") orelse return true;

            inside = false;
            offset += end + 2;

            continue;
        }

        if (literal_end(line, offset, &quote)) |skip| {
            offset = skip;

            continue;
        }

        if (is_quote(line[offset])) {
            quote = line[offset];
            offset += 1;

            continue;
        }

        if (std.mem.startsWith(u8, line[offset..], "/*")) {
            inside = true;
            offset += 2;

            continue;
        }

        offset += 1;
    }

    assert(offset >= line.len);

    return inside;
}

fn closes(bytes: []const u8, end: u32) bool {
    assert(end <= bytes.len);
    assert(bytes.len <= std.math.maxInt(u32));

    var offset = end;

    while (offset < bytes.len) {
        const from = offset + 1;
        const stop = line_end(bytes, from);
        const line = scan.trim_ascii(bytes[from..stop]);
        if (line.len > 0) return line[0] == '}';

        offset = stop;
    }

    return false;
}

fn written(
    line: []const u8,
    closed: bool,
    laying: *const Laying,
    options: Options,
    out: *Buffer,
) error{Overflow}!void {
    assert(line.len <= std.math.maxInt(u32));
    assert(options.line_width > 0);

    const held = comment_at(line);
    const code = trim_end(line[0..held]);
    const comment = trim_end(line[held..]);

    if (scan.trim_ascii(code).len == 0) return out.push(trim_end(line));

    const valued = continues_value(line, laying.valued);
    const semi = closed and unterminated(code, valued);
    const carried: u32 = if (comment.len == 0) 0 else columns(comment) + 1;
    const ends = semi or std.mem.endsWith(u8, code, ";");
    const trailed = carried + @intFromBool(ends);
    const width = columns(code) + @intFromBool(semi) + carried;
    const wide = width > options.line_width;
    const moved = !valued and comment.len > 0 and std.mem.endsWith(u8, code, ",");
    const stripped = if (moved) trim_end(code[0 .. code.len - 1]) else code;
    const line_width = options.line_width;
    const nested = laying.listed and laying.comment_above;

    const wrote = if (valued)
        try kept_value(code, wide, line_width, out)
    else
        try wrapped(line, laying.comment_above, nested, wide, line_width, trailed, out);

    if (!wrote) try out.push(stripped);

    if (semi) {
        const closer: []const u8 = if (std.mem.endsWith(u8, code, ":")) " ;" else ";";

        try out.push(closer);
    }

    try tailed(comment, out);

    if (moved) try out.push(",");
}

fn unterminated(code: []const u8, valued: bool) bool {
    assert(code.len <= std.math.maxInt(u32));

    const body = scan.trim_ascii(code);

    assert(body.len <= code.len);

    if (body.len == 0) return false;

    const ended = switch (body[body.len - 1]) {
        ';', '{', '}' => true,
        else => false,
    };

    if (ended) return false;
    if (valued) return true;

    assert(body.len > 0);

    return colon_of(body) != null;
}

fn continues_value(line: []const u8, valued: bool) bool {
    assert(line.len <= std.math.maxInt(u32));

    if (!valued) return false;

    const body = scan.trim_ascii(line);

    assert(body.len <= line.len);

    if (body.len == 0) return false;
    return body[0] != '}';
}

fn values_onward(body: []const u8, valued: bool) bool {
    assert(body.len <= std.math.maxInt(u32));

    const code = trim_end(body[0..comment_at(body)]);

    assert(code.len <= body.len);

    if (code.len == 0) return valued;

    const ended = switch (code[code.len - 1]) {
        ';', '{', '}' => true,
        else => false,
    };

    if (ended) return false;
    if (valued) return true;
    return heads_a_value(body);
}

fn heads_a_value(body: []const u8) bool {
    assert(body.len <= std.math.maxInt(u32));

    if (body.len < 2) return false;
    if (body[body.len - 1] != ':') return false;

    for (body[0 .. body.len - 1]) |byte| {
        if (!worded(byte)) return false;
    }

    assert(body.len >= 2);

    return true;
}

fn kept_value(code: []const u8, wide: bool, width: u32, out: *Buffer) error{Overflow}!bool {
    assert(code.len > 0);
    assert(width > 0);

    if (!wide) return false;

    const indent = indent_of(code);
    const body = code[indent..];
    var column = indent;
    var offset: u32 = 0;

    try padded(out, indent);

    while (offset < body.len) {
        const stop = separator(body, offset, false) orelse extent(body);
        const part = body[offset..stop];

        if (offset > 0) {
            try out.push(" ");

            column += 1;
        }

        offset = skipped(body, stop);

        const split = try placed(part, indent, column, width, out);

        column = if (split) column_of(out) else column + columns(part);
    }

    assert(column >= indent);

    return true;
}

fn wrapped(
    line: []const u8,
    comment_above: bool,
    nested: bool,
    wide: bool,
    width: u32,
    trailed: u32,
    out: *Buffer,
) error{Overflow}!bool {
    assert(line.len <= std.math.maxInt(u32));
    assert(width > 0);
    assert(trailed < std.math.maxInt(u32));

    const at = comment_at(line);
    const code = trim_end(line[0..at]);
    const indent = indent_of(code);
    const body = code[indent..];
    if (body.len == 0) return false;
    if (body[0] == '@') return false;

    if (ends_selector(body)) {
        const moved = at < line.len and std.mem.endsWith(u8, body, ",");
        const wanted = wide or nested;
        if (!wanted) return false;

        try selectors(body, indent, comment_above, nested, moved, width, out);

        return true;
    }

    return declaration(body, indent, wide, width, trailed, out);
}

fn selectors(
    body: []const u8,
    indent: u32,
    comment_above: bool,
    nested: bool,
    moved: bool,
    width: u32,
    out: *Buffer,
) error{Overflow}!void {
    assert(body.len > 0);
    assert(width > 0);
    assert(indent < std.math.maxInt(u32));

    const dropped = body[0 .. body.len - 1];
    const braced = body[body.len - 1] == '{';
    const whole = if (braced) trim_end(dropped) else dropped;
    const cut = comments_lead(whole);
    const split = if (cut < whole.len) cut else 0;
    const prefix = trim_end(whole[0..split]);
    const head = whole[split..];
    const led = (comment_above or prefix.len > 0) and heads(head);
    const paired = led and pairs(head);
    const joined = nested and paired;
    const seated = column_of(out);
    const tail: []const u8 = if (braced) " {" else if (moved) "" else ",";

    if (joined) {
        if (seated == 0) try padded(out, indent);

        try prefixed(prefix, out);
        try out.push(head);
        try out.push(tail);

        return;
    }

    const based = if (nested) indent + 4 else indent;

    const selecting: Selecting = .{
        .based = based,
        .indent = indent,
        .led = led,
        .opened = if (paired) indent else based + 4,
        .paired = paired,
        .prefix = prefix,
        .seated = seated,
        .shift = if (prefix.len == 0) 0 else columns(prefix) + 1,
        .tail = tail,
    };

    try selector_parts(head, &selecting, width, out);
}

fn selector_parts(
    head: []const u8,
    selecting: *const Selecting,
    width: u32,
    out: *Buffer,
) error{Overflow}!void {
    assert(width > 0);
    assert(selecting.based >= selecting.indent);
    assert(head.len <= std.math.maxInt(u32));

    var initial = true;
    var offset: u32 = 0;

    while (offset < head.len) {
        const start = offset;
        const joins = initial and selecting.led and !selecting.paired;
        const stop = compound_led(head, start, joins);
        const part = head[start..stop];
        const inner = if (initial) selecting.based else selecting.indent + 4;
        const level = if (selecting.paired) selecting.indent else inner;
        const sat = initial and selecting.seated > 0;

        offset = skipped(head, stop);

        const carried: u32 = if (offset < head.len) 0 else extent(selecting.tail);

        if (!sat) try leading(initial, selecting.based, level, out);
        if (initial) try prefixed(selecting.prefix, out);

        const opening = if (initial) level + selecting.shift else level;
        const column = if (sat) selecting.seated + selecting.shift else opening;

        if (pseudo_at(part, column, carried, width)) |found| {
            try pseudoed(part, selecting.opened, found, carried, width, out);
        } else {
            try out.push(part);
        }

        initial = false;
    }

    try out.push(selecting.tail);
}

fn compound_led(head: []const u8, start: u32, joins: bool) u32 {
    assert(start < head.len);
    assert(head.len <= std.math.maxInt(u32));

    const stop = compound(head, start);
    if (!joins) return stop;

    const after = skipped(head, stop);
    if (after >= head.len) return stop;
    return compound(head, after);
}

fn compound(head: []const u8, from: u32) u32 {
    assert(from <= head.len);
    assert(head.len <= std.math.maxInt(u32));

    const stop = separator(head, from, false) orelse extent(head);
    if (!combinator(head[from..stop])) return stop;
    return separator(head, skipped(head, stop), false) orelse extent(head);
}

fn combinator(part: []const u8) bool {
    assert(part.len <= std.math.maxInt(u32));

    if (part.len != 1) return false;

    return switch (part[0]) {
        '+', '>', '~' => true,
        else => false,
    };
}

fn leading(initial: bool, indent: u32, level: u32, out: *Buffer) error{Overflow}!void {
    assert(indent < std.math.maxInt(u32));
    assert(level < std.math.maxInt(u32));

    const before = out.count();

    if (initial) return padded(out, indent);

    try out.push("\n");
    try padded(out, level);

    assert(out.count() == before + 1 + level);
}

fn pairs(head: []const u8) bool {
    assert(head.len <= std.math.maxInt(u32));

    const second = skipped(head, compound(head, 0));
    if (second >= head.len) return false;

    assert(second > 0);

    return compound(head, second) >= head.len;
}

fn heads(head: []const u8) bool {
    assert(head.len <= std.math.maxInt(u32));

    if (head.len == 0) return false;
    return head[0] == '.' or worded(head[0]);
}

fn prefixed(prefix: []const u8, out: *Buffer) error{Overflow}!void {
    assert(prefix.len <= std.math.maxInt(u32));

    if (prefix.len == 0) return;

    assert(!scan.is_ascii_whitespace(prefix[prefix.len - 1]));

    const before = out.count();

    try out.push(prefix);
    try out.push(" ");

    assert(out.count() == before + prefix.len + 1);
}

fn tail_code(line: []const u8) ?TailCode {
    assert(line.len <= std.math.maxInt(u32));

    const end = scan.find(line, "*/") orelse return null;
    const after = blank_end(line, end + 2);
    const lead = after + comments_lead(line[after..]);
    const code = trim_end(line[lead..]);
    if (!ends_selector(code)) return null;
    if (comment_at(code) < code.len) return null;

    assert(lead <= line.len);

    return .{ .code = code, .prefix = trim_end(line[0..lead]) };
}

fn tail_written(line: []const u8, indent: u32, width: u32, out: *Buffer) error{Overflow}!void {
    assert(width > 0);
    assert(line.len <= std.math.maxInt(u32));
    assert(indent < std.math.maxInt(u32));

    const found = tail_code(line) orelse return out.push(line);

    try out.push(found.prefix);
    try out.push(" ");

    if (columns(found.prefix) + 1 + columns(found.code) <= width) return out.push(found.code);

    try selectors(found.code, indent, true, false, false, width, out);
}

fn comments_lead(head: []const u8) u32 {
    assert(head.len <= std.math.maxInt(u32));

    var past: u32 = 0;

    for (0..head.len) |_| {
        const end = comment_end(head, past) orelse break;

        past = blank_end(head, end);
    }

    assert(past <= head.len);

    return past;
}

fn declaration(
    body: []const u8,
    indent: u32,
    wide: bool,
    width: u32,
    trailed: u32,
    out: *Buffer,
) error{Overflow}!bool {
    assert(body.len > 0);
    assert(width > 0);
    assert(indent < std.math.maxInt(u32));
    assert(trailed < std.math.maxInt(u32));

    const colon = colon_of(body) orelse return false;
    if (scan.word_in(policy.source_values, scan.trim_ascii(body[0..colon]))) return false;

    const held = body[skipped(body, colon + 1)..];
    if (held.len == 0) return false;

    const bang = bang_at(held);
    const value = if (bang) |at| trim_end(held[0..at]) else held;
    const tail = if (bang) |at| held[at..] else held[held.len..];
    const prop = body[0 .. colon + 1];

    if (value.len == 0) return false;

    if (separator(value, 0, true) != null) {
        const whole = !layers(value) or std.mem.startsWith(u8, body, "--");
        const declined = !wide and whole;
        if (declined) return false;

        try layered(prop, value, indent, whole, width, out);
        try tailed(tail, out);

        return true;
    }

    if (!wide) return false;

    const fills = try filled(prop, value, tail, indent, width, trailed, out);
    if (!fills) return false;

    try tailed(tail, out);

    return true;
}

fn colon_of(body: []const u8) ?u32 {
    assert(body.len <= std.math.maxInt(u32));

    var from: u32 = 0;

    while (from < body.len) {
        const found = from + (top_level_at(body[from..], ':') orelse return null);

        assert(found < body.len);
        assert(body[found] == ':');

        if (scan.byte_at(body, found + 1) != ':') return found;

        from = found + 2;
    }

    return null;
}

fn bang_at(value: []const u8) ?u32 {
    assert(value.len <= std.math.maxInt(u32));

    const found = top_level_at(value, '!') orelse return null;

    assert(found < value.len);
    assert(value[found] == '!');

    return found;
}

fn top_level_at(body: []const u8, wanted: u8) ?u32 {
    assert(body.len <= std.math.maxInt(u32));
    assert(!is_quote(wanted));

    var depth: u32 = 0;
    var held: u32 = 0;
    var quote: u8 = 0;

    while (held < body.len) {
        if (literal_end(body, held, &quote)) |end| {
            held = end;

            continue;
        }

        if (std.mem.startsWith(u8, body[held..], "/*")) {
            held = crossed(body, held);

            continue;
        }

        const byte = body[held];
        const found = depth == 0 and byte == wanted;
        if (found) return held;

        if (is_quote(byte)) quote = byte;

        depth = deepened(depth, byte);
        held += 1;
    }

    return null;
}

fn tailed(comment: []const u8, out: *Buffer) error{Overflow}!void {
    assert(comment.len <= std.math.maxInt(u32));

    if (comment.len == 0) return;

    assert(!scan.is_ascii_whitespace(comment[0]));

    const before = out.count();

    try out.push(" ");
    try out.push(comment);

    assert(out.count() == before + comment.len + 1);
}

fn layers(value: []const u8) bool {
    assert(value.len <= std.math.maxInt(u32));

    var offset: u32 = 0;

    while (offset < value.len) {
        const stop = separator(value, offset, true) orelse extent(value);
        const part = scan.trim_ascii(value[offset..stop]);
        if (separator(part, 0, false) != null) return true;

        offset = skipped(value, @min(stop + 1, extent(value)));
    }

    assert(offset >= value.len);

    return false;
}

fn tallied(value: []const u8) Tally {
    assert(value.len <= std.math.maxInt(u32));

    var tally: Tally = .{ .count = 0, .size = 0 };
    var offset: u32 = 0;

    while (offset < value.len) {
        const stop = separator(value, offset, true) orelse extent(value);
        const part = scan.trim_ascii(value[offset..stop]);
        var held: u32 = 0;

        while (held < part.len) {
            const end = separator(part, held, false) orelse extent(part);

            tally_piece(part[held..end], &tally);

            held = skipped(part, end);
        }

        offset = skipped(value, @min(stop + 1, extent(value)));
    }

    assert(tally.count <= tally.size);

    return tally;
}

fn tally_piece(piece: []const u8, tally: *Tally) void {
    assert(piece.len <= std.math.maxInt(u32));
    assert(tally.count <= tally.size);

    const code = if (scan.find(piece, "/*")) |at| trim_end(piece[0..at]) else piece;
    var start: u32 = 0;

    while (start < code.len) {
        const found = top_level_at(code[start..], '/');
        const stop = if (found) |at| start + at else extent(code);
        const length = stop - start;

        if (length > 1) {
            tally.count += 1;
            tally.size += length;
        }

        start = stop + 1;
    }
}

fn layered(
    prop: []const u8,
    value: []const u8,
    indent: u32,
    whole: bool,
    width: u32,
    out: *Buffer,
) error{Overflow}!void {
    assert(prop.len > 0);
    assert(value.len > 0);
    assert(indent < std.math.maxInt(u32));
    assert(width < std.math.maxInt(u32));

    try padded(out, indent);
    try out.push(prop);
    try out.push("\n");
    try padded(out, indent + 4);

    const tally = tallied(value);
    const capped = whole and tally.count > layer_fill_max and tally.size >= width;
    var column = indent + 4;
    var started = false;
    var offset: u32 = 0;
    var split = false;

    while (offset < value.len) {
        const stop = if (separator(value, offset, true)) |found| found + 1 else extent(value);
        const part = trim_end(value[offset..stop]);

        offset = skipped(value, stop);

        if (started) {
            const opens = !whole or split or column + 1 + measured(part) > width;
            const breaks = !capped and opens;

            if (breaks) {
                try out.push("\n");
                try padded(out, indent + 4);

                column = indent + 4;
            } else {
                try out.push(" ");

                column += 1;
            }
        }

        if (capped) {
            try out.push(part);

            column += measured(part);
            split = false;
        } else {
            const spreading = try spread(part, indent + 4, column, width, out);

            column = spreading.column;
            split = spreading.spilt;
        }

        started = true;
    }
}

fn spread(
    part: []const u8,
    indent: u32,
    column: u32,
    width: u32,
    out: *Buffer,
) error{Overflow}!Spread {
    assert(width > 0);
    assert(column >= indent);
    assert(part.len <= std.math.maxInt(u32));

    var held = column;
    var started = false;
    var offset: u32 = 0;
    var split = false;
    var spilt = false;

    while (offset < part.len) {
        const stop = separator(part, offset, false) orelse extent(part);
        const piece = part[offset..stop];

        offset = skipped(part, stop);

        if (started) {
            const breaks = split or held + 1 + measured(piece) > width;

            if (breaks) {
                try out.push("\n");
                try padded(out, indent);

                held = indent;
                spilt = true;
            } else {
                try out.push(" ");

                held += 1;
            }
        }

        split = try placed(piece, indent, held, width, out);
        spilt = spilt or split;
        held = if (split) indent + 2 else held + measured(piece);
        started = true;
    }

    return .{ .column = held, .spilt = spilt };
}

fn divides(value: []const u8) bool {
    assert(value.len <= std.math.maxInt(u32));

    var offset: u32 = 0;

    while (offset < value.len) {
        const stop = separator(value, offset, false) orelse extent(value);
        if (walk.text_is(value[offset..stop], "/")) return true;

        offset = skipped(value, stop);
    }

    assert(offset >= value.len);

    return false;
}

fn filled(
    prop: []const u8,
    value: []const u8,
    tail: []const u8,
    indent: u32,
    width: u32,
    trailed: u32,
    out: *Buffer,
) error{Overflow}!bool {
    assert(prop.len > 0);
    assert(value.len > 0);
    assert(tail.len <= std.math.maxInt(u32));
    assert(indent < std.math.maxInt(u32));
    assert(width < std.math.maxInt(u32));
    assert(trailed < std.math.maxInt(u32));

    const separated = separator(value, 0, false) != null;
    const fillable = separated or callable(value) != null;
    if (!fillable) return false;

    try padded(out, indent);
    try out.push(prop);

    const commented_width = if (tail.len == 0) trailed else trailed + measured(tail) + 1;
    const carried: u32 = if (separated) 0 else commented_width;
    const level = if (separated) indent + 4 else indent;
    const divided = divides(value);
    var column = indent + columns(prop);
    var started = false;
    var offset: u32 = 0;
    var split = false;

    while (offset < value.len) {
        const stop = separator(value, offset, false) orelse extent(value);
        const part = value[offset..stop];

        offset = skipped(value, stop);

        const held = if (offset < value.len) columns(part) else measured(part);
        const opens = if (started) split or column + 1 + held > width else divided;

        if (opens) {
            try out.push("\n");
            try padded(out, indent + 4);

            column = indent + 4;
        } else {
            try out.push(" ");

            column += 1;
        }

        split = try placed(part, level, column + carried, width, out);
        column = if (split) level + 2 else column + held;
        started = true;
    }

    return true;
}

fn placed(
    part: []const u8,
    level: u32,
    column: u32,
    width: u32,
    out: *Buffer,
) error{Overflow}!bool {
    assert(part.len > 0);
    assert(width > 0);
    assert(level < std.math.maxInt(u32));
    assert(column < std.math.maxInt(u32));

    const found = call_wanted(part, column, width) orelse {
        try out.push(part);

        return false;
    };

    try called(part, found, level, width, out);

    return true;
}

fn call_wanted(part: []const u8, column: u32, width: u32) ?Parens {
    assert(part.len <= std.math.maxInt(u32));
    assert(width > 0);
    assert(column <= std.math.maxInt(u32) - part.len);

    if (column + sized(part) <= width) return null;
    return callable(part);
}

fn called(
    part: []const u8,
    found: Parens,
    indent: u32,
    width: u32,
    out: *Buffer,
) error{Overflow}!void {
    assert(found.open < found.close);
    assert(found.close < part.len);
    assert(indent < std.math.maxInt(u32));
    assert(width < std.math.maxInt(u32));

    var calls: [frame_depth_max]Call = undefined;
    var depth: u32 = 1;

    calls[0] = try call_opened(part, found, indent, out);

    for (0..8 * part.len + 8) |_| {
        if (depth == 0) break;

        const step = try call_step(&calls[depth - 1], width, out);

        depth = try call_pushed(&calls, depth, step, out);
    }

    assert(depth == 0);
}

fn call_opened(part: []const u8, found: Parens, indent: u32, out: *Buffer) error{Overflow}!Call {
    assert(found.open < found.close);
    assert(found.close < part.len);
    assert(indent < std.math.maxInt(u32));

    try out.push(part[0 .. found.open + 1]);

    const args = part[found.open + 1 .. found.close];

    return .{
        .args = args,
        .indent = indent,
        .offset = 0,
        .operated = separator(args, 0, true) == null,
        .rest = part[found.close..],
        .rider = "",
        .spill = null,
    };
}

fn call_pushed(
    calls: *[frame_depth_max]Call,
    depth: u32,
    step: Step,
    out: *Buffer,
) error{Overflow}!u32 {
    assert(depth <= frame_depth_max);
    if (step == .finished) assert(depth > 0);

    switch (step) {
        .advanced => return depth,
        .finished => {
            assert(depth > 0);

            return depth - 1;
        },
        .nested => |nested| {
            if (depth == frame_depth_max) return error.Overflow;

            calls[depth] = try call_opened(nested.part, nested.found, nested.indent, out);

            assert(depth + 1 < std.math.maxInt(u32));

            return depth + 1;
        },
    }
}

fn call_step(call: *Call, width: u32, out: *Buffer) error{Overflow}!Step {
    assert(call.offset <= call.args.len);
    assert(width > 0);

    if (call.spill) |*spill| {
        if (spill.offset < spill.part.len) return spill_step(spill, width, out);

        call.spill = null;

        if (call.rider.len > 0) {
            try out.push(" ");
            try out.push(call.rider);
        }

        return .advanced;
    }

    if (call.offset < call.args.len) {
        try call_argument(call, out);

        return .advanced;
    }

    try out.push("\n");
    try padded(out, call.indent);
    try out.push(call.rest);

    return .finished;
}

fn call_argument(call: *Call, out: *Buffer) error{Overflow}!void {
    assert(call.offset < call.args.len);
    assert(call.spill == null);

    const args = call.args;

    const found = if (call.operated)
        operator(args, call.offset)
    else
        separator(args, call.offset, true);

    const stop = if (found) |at| at + 1 else extent(args);
    const piece = scan.trim_ascii(args[call.offset..stop]);
    const ridden = call.operated and found != null and piece.len > 0;
    const cut = if (ridden) piece.len - 1 else piece.len;
    const body = trim_end(piece[0..cut]);

    call.rider = piece[cut..];
    call.offset = skipped(args, stop);

    try out.push("\n");
    try padded(out, call.indent + 4);

    call.spill = spill_opened(body, call.indent + 4, columns(call.rider) + @intFromBool(ridden));
}

fn spill_opened(part: []const u8, indent: u32, carried: u32) Spill {
    assert(part.len <= std.math.maxInt(u32));
    assert(carried <= 2);
    assert(indent < std.math.maxInt(u32));

    const level = if (separator(part, 0, false) != null) indent + 4 else indent;

    return .{
        .carried = carried,
        .column = indent,
        .indent = indent,
        .level = level,
        .offset = 0,
        .part = part,
        .split = false,
        .started = false,
    };
}

fn spill_step(spill: *Spill, width: u32, out: *Buffer) error{Overflow}!Step {
    assert(spill.offset < spill.part.len);
    assert(width > 0);

    const part = spill.part;
    const stop = separator(part, spill.offset, false) orelse extent(part);
    const piece = part[spill.offset..stop];

    spill.offset = skipped(part, stop);

    const owed = if (spill.offset < part.len) 0 else spill.carried;

    if (spill.started) {
        const breaks = spill.split or spill.column + 1 + argued(piece) + owed > width;

        if (breaks) {
            try out.push("\n");
            try padded(out, spill.indent + 4);

            spill.column = spill.indent + 4;
        } else {
            try out.push(" ");

            spill.column += 1;
        }
    }

    const found = call_wanted(piece, spill.column + owed, width);

    spill.split = found != null;
    spill.column = if (found != null) spill.level + 2 else spill.column + measured(piece);
    spill.started = true;

    const parens = found orelse {
        try out.push(piece);

        return .advanced;
    };

    return .{ .nested = .{ .found = parens, .indent = spill.level, .part = piece } };
}

fn operator(body: []const u8, from: u32) ?u32 {
    assert(from <= body.len);
    assert(body.len <= std.math.maxInt(u32));

    var held = from;

    while (held < body.len) {
        const stop = separator(body, held, false) orelse return null;

        if (arithmetic(body[held..stop])) {
            assert(stop - 1 < std.math.maxInt(u32));

            return stop - 1;
        }

        held = skipped(body, stop);
    }

    return null;
}

fn arithmetic(part: []const u8) bool {
    assert(part.len <= std.math.maxInt(u32));

    if (part.len != 1) return false;

    return switch (part[0]) {
        '*', '+', '-', '/' => true,
        else => false,
    };
}

fn sized(part: []const u8) u32 {
    assert(part.len <= std.math.maxInt(u32));

    const width = columns(part);
    const ends = std.mem.endsWith(u8, part, ";") or std.mem.endsWith(u8, part, ",");
    const trailer: u32 = @intFromBool(ends);

    assert(width >= trailer);
    assert(width <= part.len);

    return width - trailer;
}

fn measured(part: []const u8) u32 {
    assert(part.len <= std.math.maxInt(u32));

    const held = if (scan.find(part, "/*")) |at| trim_end(part[0..at]) else part;
    const semi: u32 = @intFromBool(std.mem.endsWith(u8, held, ";"));
    const width = columns(held);

    assert(held.len <= part.len);
    assert(width >= semi);

    return width - semi;
}

fn argued(part: []const u8) u32 {
    assert(part.len <= std.math.maxInt(u32));

    const width = measured(part);
    const comma: u32 = @intFromBool(std.mem.endsWith(u8, part, ","));

    assert(width >= comma);
    assert(width <= part.len);

    return width - comma;
}

fn callable(part: []const u8) ?Parens {
    assert(part.len <= std.math.maxInt(u32));

    const open: u32 = @intCast(std.mem.findScalar(u8, part, '(') orelse return null);
    const unworded = open > 0 and !worded(part[open - 1]);
    if (unworded) return null;
    if (std.ascii.eqlIgnoreCase(part[0..open], "url")) return null;

    const close = closing(part, open) orelse return null;
    if (!closes_a_value(part[close + 1 ..])) return null;

    assert(open < close);

    return .{ .close = close, .open = open };
}

fn closing(part: []const u8, open: u32) ?u32 {
    assert(open < part.len);
    assert(part[open] == '(');

    var depth: u32 = 0;
    var held = open;
    var quote: u8 = 0;

    while (held < part.len) {
        if (literal_end(part, held, &quote)) |end| {
            held = end;

            continue;
        }

        if (std.mem.startsWith(u8, part[held..], "/*")) {
            held = crossed(part, held);

            continue;
        }

        const byte = part[held];
        const shut = byte == ')' or byte == ']';

        if (is_quote(byte)) quote = byte;

        depth = deepened(depth, byte);

        const done = shut and depth == 0;
        if (done) return held;

        held += 1;
    }

    return null;
}

fn closes_a_value(tail: []const u8) bool {
    assert(tail.len <= std.math.maxInt(u32));

    var held: u32 = 0;

    while (held < tail.len) {
        if (std.mem.startsWith(u8, tail[held..], "/*")) {
            held = crossed(tail, held);

            continue;
        }

        const byte = tail[held];
        const ends = byte == ',' or byte == ';' or scan.is_ascii_whitespace(byte);
        if (!ends) return false;

        held += 1;
    }

    assert(held >= tail.len);

    return true;
}

fn pseudo_open(head: []const u8, from: u32) ?u32 {
    assert(from <= head.len);
    assert(head.len <= std.math.maxInt(u32));

    var cursor = from;

    while (cursor < head.len) : (cursor += 1) {
        if (head[cursor] != '(') continue;

        const start = word_start(head, cursor);
        const pseudo = start > 0 and head[start - 1] == ':';
        if (pseudo) return cursor;
    }

    return null;
}

fn pseudo_at(head: []const u8, indent: u32, tail: u32, width: u32) ?Parens {
    assert(head.len <= std.math.maxInt(u32));
    assert(width > 0);
    assert(indent < std.math.maxInt(u32));
    assert(tail < std.math.maxInt(u32));

    var found: ?Parens = null;
    var offset: u32 = 0;

    while (offset < head.len) {
        const open = pseudo_open(head, offset) orelse break;
        const close = closing(head, open) orelse return null;
        const stop = if (pseudo_open(head, close + 1)) |after| after + 1 else extent(head);
        const carried = if (stop == head.len) tail else 0;

        found = .{ .close = close, .open = open };

        if (indent + columns(head[0..stop]) + carried > width) return found;

        offset = close + 1;
    }

    if (indent + columns(head) + tail <= width) return null;
    return found;
}

fn pseudoed(
    part: []const u8,
    level: u32,
    found: Parens,
    tail: u32,
    width: u32,
    out: *Buffer,
) error{Overflow}!void {
    assert(found.open < found.close);
    assert(found.close < part.len);
    assert(level < std.math.maxInt(u32));
    assert(tail < std.math.maxInt(u32));
    assert(width < std.math.maxInt(u32));

    var frames: [frame_depth_max]Pseudo = undefined;
    var depth: u32 = 1;

    frames[0] = try pseudo_opened(part, found, level, tail, out);

    for (0..8 * part.len + 8) |_| {
        if (depth == 0) break;

        depth = try pseudo_step(&frames, depth, width, out);
    }

    assert(depth == 0);
}

fn pseudo_opened(
    held: []const u8,
    found: Parens,
    level: u32,
    tail: u32,
    out: *Buffer,
) error{Overflow}!Pseudo {
    assert(found.open < found.close);
    assert(found.close < held.len);
    assert(level < std.math.maxInt(u32));
    assert(tail < std.math.maxInt(u32));

    try out.push(held[0 .. found.open + 1]);

    return .{
        .args = held[found.open + 1 .. found.close],
        .level = level,
        .offset = 0,
        .rest = held[found.close..],
        .tail = tail,
    };
}

fn pseudo_step(
    frames: *[frame_depth_max]Pseudo,
    depth: u32,
    width: u32,
    out: *Buffer,
) error{Overflow}!u32 {
    assert(depth > 0);
    assert(depth <= frame_depth_max);
    assert(width < std.math.maxInt(u32));

    const frame = &frames[depth - 1];

    if (frame.offset < frame.args.len) {
        switch (try pseudo_argument(frame, width, out)) {
            .written => return depth,
            .nested => |inner| {
                if (depth == frame_depth_max) return error.Overflow;

                frames[depth] = inner;

                assert(depth + 1 < std.math.maxInt(u32));

                return depth + 1;
            },
        }
    }

    try out.push("\n");
    try padded(out, frame.level);

    const after = pseudo_at(frame.rest, frame.level, frame.tail, width) orelse {
        try out.push(frame.rest);

        assert(depth - 1 < std.math.maxInt(u32));

        return depth - 1;
    };

    frame.* = try pseudo_opened(frame.rest, after, frame.level, frame.tail, out);

    return depth;
}

fn pseudo_argument(frame: *Pseudo, width: u32, out: *Buffer) error{Overflow}!Matched {
    assert(frame.offset < frame.args.len);
    assert(width > 0);

    const args = frame.args;
    const stop = if (separator(args, frame.offset, true)) |at| at + 1 else extent(args);
    const argument = args[frame.offset..stop];

    frame.offset = skipped(args, stop);

    try out.push("\n");

    return matched(argument, frame.level + 4, width, out);
}

fn matched(argument: []const u8, indent: u32, width: u32, out: *Buffer) error{Overflow}!Matched {
    assert(argument.len > 0);
    assert(width > 0);
    assert(indent < std.math.maxInt(u32));

    const held = scan.trim_ascii(argument);

    if (indent + columns(held) <= width) {
        try padded(out, indent);
        try out.push(held);

        return .written;
    }

    if (separator(held, 0, false) == null) {
        try padded(out, indent);

        const found = pseudo_at(held, indent, 0, width) orelse {
            try out.push(held);

            return .written;
        };

        return .{ .nested = try pseudo_opened(held, found, indent + 4, 0, out) };
    }

    var initial = true;
    var offset: u32 = 0;

    while (offset < held.len) {
        const start = offset;
        const stop = compound(held, start);

        offset = skipped(held, stop);

        try leading(initial, indent, indent + 4, out);
        try out.push(held[start..stop]);

        initial = false;
    }

    return .written;
}

fn separator(body: []const u8, from: u32, comma: bool) ?u32 {
    assert(from <= body.len);
    assert(body.len <= std.math.maxInt(u32));

    var depth: u32 = 0;
    var held = from;
    var quote: u8 = 0;

    while (held < body.len) {
        if (literal_end(body, held, &quote)) |end| {
            held = end;

            continue;
        }

        if (std.mem.startsWith(u8, body[held..], "/*")) {
            held = crossed(body, held);

            continue;
        }

        const byte = body[held];
        const splits = depth == 0 and splits_at(body, held, comma);
        if (splits) return held;

        if (is_quote(byte)) quote = byte;

        depth = deepened(depth, byte);
        held += 1;
    }

    return null;
}

fn splits_at(body: []const u8, held: u32, comma: bool) bool {
    assert(held < body.len);
    assert(body.len <= std.math.maxInt(u32));

    if (comma) return body[held] == ',';
    if (body[held] != ' ') return false;
    return !std.mem.startsWith(u8, body[skipped(body, held)..], "/*");
}

fn crossed(body: []const u8, from: u32) u32 {
    assert(from + 2 <= body.len);
    assert(std.mem.startsWith(u8, body[from..], "/*"));

    const end = scan.find(body[from + 2 ..], "*/") orelse return extent(body);
    assert(from + 4 + end < std.math.maxInt(u32));

    return from + 4 + end;
}

fn literal_end(bytes: []const u8, held: u32, quote: *u8) ?u32 {
    assert(held < bytes.len);
    if (quote.* != 0) assert(is_quote(quote.*));

    const byte = bytes[held];

    if (quote.* != 0) {
        if (byte == quote.*) quote.* = 0;

        const step: u32 = if (byte == '\\') 2 else 1;
        assert(held + step <= bytes.len + 1);

        return held + step;
    }

    if (byte == '\\') return scan.escape_end(bytes, held);
    return null;
}

fn deepened(depth: u32, byte: u8) u32 {
    assert(depth < std.math.maxInt(u32));

    const held: u32 = switch (byte) {
        '(', '[' => depth + 1,
        ')', ']' => depth -| 1,
        else => depth,
    };

    assert(held + 1 >= depth);
    assert(held <= depth + 1);

    return held;
}

fn comment_at(line: []const u8) u32 {
    assert(line.len <= std.math.maxInt(u32));

    var held: u32 = 0;
    var quote: u8 = 0;

    while (held < line.len) {
        if (literal_end(line, held, &quote)) |skip| {
            held = skip;

            continue;
        }

        if (is_quote(line[held])) {
            quote = line[held];
            held += 1;

            continue;
        }

        if (!std.mem.startsWith(u8, line[held..], "/*")) {
            held += 1;

            continue;
        }

        const end = scan.find(line[held + 2 ..], "*/") orelse return held;
        const stop = held + 4 + end;
        if (vacant(line[stop..])) return held;

        held = stop;
    }

    assert(held >= line.len);

    return extent(line);
}

fn quoted(line: []const u8, from: u32, out: *Buffer) error{Overflow}!u32 {
    assert(from < line.len);
    assert(is_quote(line[from]));

    const quote = line[from];
    var held = from + 1;

    while (held < line.len) {
        if (line[held] == '\\') {
            held += 2;

            continue;
        }

        if (line[held] == quote) break;

        held += 1;
    }

    if (held >= line.len) {
        try out.push(line[from..]);

        return extent(line);
    }

    const body = line[from + 1 .. held];
    const plain = quote == '\'' and !holds(body, '"');

    if (!plain) {
        try out.push(line[from .. held + 1]);

        assert(held + 1 <= line.len);

        return held + 1;
    }

    try out.push("\"");
    try unescaped(body, out);
    try out.push("\"");

    assert(held + 1 <= line.len);

    return held + 1;
}

fn holds(body: []const u8, byte: u8) bool {
    assert(body.len <= std.math.maxInt(u32));
    assert(byte != '\\');

    var held: u32 = 0;

    while (held < body.len) {
        if (body[held] == '\\') {
            held += 2;

            continue;
        }

        if (body[held] == byte) return true;

        held += 1;
    }

    return false;
}

fn unescaped(body: []const u8, out: *Buffer) error{Overflow}!void {
    assert(body.len <= std.math.maxInt(u32));

    const before = out.count();
    var held: u32 = 0;

    while (held < body.len) {
        const escaped = body[held] == '\\' and scan.byte_at(body, held + 1) == '\'';

        if (escaped) {
            try out.push("'");

            held += 2;

            continue;
        }

        try out.push_byte(body[held]);

        held += 1;
    }

    assert(out.count() - before <= body.len);
}

fn coloured(line: []const u8, from: u32, out: *Buffer) error{Overflow}!u32 {
    assert(from < line.len);
    assert(line[from] == '#');

    var held = from + 1;

    while (held < line.len) : (held += 1) {
        if (!std.ascii.isHex(line[held])) break;
    }

    const hex_valid = switch (held - from - 1) {
        3, 4, 6, 8 => true,
        else => false,
    };

    if (!hex_valid) return from;
    if (worded_at(line, held)) return from;

    try out.push("#");
    try lowered(line[from + 1 .. held], out);

    assert(held <= line.len);

    return held;
}

fn digits(line: []const u8, from: u32) Digits {
    assert(from <= line.len);
    assert(line.len <= std.math.maxInt(u32));

    const whole = digit_end(line, from);
    const dotted = scan.byte_at(line, whole) == '.' and digit_at(line, whole + 1);
    const fraction = if (dotted) digit_end(line, whole + 1) else whole;
    const end = exponent_end(line, fraction);

    assert(whole <= fraction);
    assert(fraction <= end);

    return .{ .end = end, .fraction = fraction, .whole = whole };
}

fn exponent_end(line: []const u8, fraction: u32) u32 {
    assert(fraction <= line.len);
    assert(line.len <= std.math.maxInt(u32));

    const marker = scan.byte_at(line, fraction) orelse return fraction;
    if (std.ascii.toLower(marker) != 'e') return fraction;

    var probe = fraction + 1;

    if (signed_at(line, probe)) probe += 1;
    if (!digit_at(line, probe)) return fraction;
    return digit_end(line, probe);
}

fn digit_end(line: []const u8, from: u32) u32 {
    assert(from <= line.len);

    var held = from;

    while (held < line.len) : (held += 1) {
        if (!std.ascii.isDigit(line[held])) break;
    }

    assert(held >= from);
    if (held < line.len) assert(!std.ascii.isDigit(line[held]));

    return held;
}

fn numbered(line: []const u8, from: u32, out: *Buffer) error{Overflow}!u32 {
    assert(from < line.len);
    assert(line.len <= std.math.maxInt(u32));

    const found = digits(line, from);

    if (found.whole == from) try out.push("0");

    try out.push(line[from..found.whole]);
    try out.push(trailing(line[found.whole..found.fraction]));
    try lowered(line[found.fraction..found.end], out);

    return united(line, found.end, out);
}

fn trailing(fraction: []const u8) []const u8 {
    assert(fraction.len <= std.math.maxInt(u32));

    var held: u32 = extent(fraction);

    while (held > 0) : (held -= 1) {
        if (fraction[held - 1] != '0') break;
    }

    if (held <= 1) return "";

    assert(fraction[0] == '.');

    return fraction[0..held];
}

fn united(line: []const u8, from: u32, out: *Buffer) error{Overflow}!u32 {
    assert(from <= line.len);
    assert(line.len <= std.math.maxInt(u32));

    var held = from;

    while (held < line.len) : (held += 1) {
        if (!std.ascii.isAlphabetic(line[held])) break;
    }

    const unit = line[from..held];
    const kept = walk.text_is(unit, "Q") or worded_at(line, held);

    if (kept) {
        try out.push(unit);
    } else {
        try lowered(unit, out);
    }

    return held;
}

fn counts(line: []const u8, open: u32) bool {
    assert(open < line.len);
    assert(line[open] == '(');

    const start = word_start(line, open);
    if (start == 0) return false;
    if (line[start - 1] != ':') return false;

    for (nth_words) |word| {
        if (std.ascii.eqlIgnoreCase(line[start..open], word)) return true;
    }

    return false;
}

fn counted_at(line: []const u8, from: u32, out: *Buffer) error{Overflow}!u32 {
    assert(from <= line.len);
    assert(line.len <= std.math.maxInt(u32));

    var step = from;

    if (signed_at(line, step)) step += 1;

    step = digit_end(line, step);

    const letter = scan.byte_at(line, step) orelse return from;
    if (std.ascii.toLower(letter) != 'n') return from;

    try out.push(line[from..step]);
    try out.push("n");

    const sign = skipped(line, step + 1);

    if (!signed_at(line, sign)) {
        assert(step + 1 < std.math.maxInt(u32));

        return step + 1;
    }

    const offset = skipped(line, sign + 1);

    if (!digit_at(line, offset)) {
        assert(step + 1 < std.math.maxInt(u32));

        return step + 1;
    }

    try out.push(" ");
    try out.push(line[sign .. sign + 1]);
    try out.push(" ");

    assert(offset <= line.len);

    return offset;
}

fn ruled(name: []const u8) bool {
    assert(name.len <= std.math.maxInt(u32));

    if (rule_word(name)) return true;
    if (name.len == 0) return false;
    if (name[0] != '-') return false;

    const rest = name[1..];
    const at = std.mem.findScalar(u8, rest, '-') orelse return false;

    assert(at < rest.len);

    return rule_word(rest[at + 1 ..]);
}

fn rule_word(name: []const u8) bool {
    assert(name.len <= std.math.maxInt(u32));

    for (rule_words) |word| {
        if (std.ascii.eqlIgnoreCase(name, word)) return true;
    }

    return false;
}

fn named_rule(line: []const u8, from: u32, out: *Buffer) error{Overflow}!u32 {
    assert(from < line.len);
    assert(line[from] == '@');

    var stop = from + 1;

    while (stop < line.len) : (stop += 1) {
        if (!worded(line[stop])) break;
    }

    if (!ruled(line[from + 1 .. stop])) return from;

    try lowered(line[from..stop], out);

    assert(stop <= line.len);

    return stop;
}

fn attributed(line: []const u8, offset: u32, out: *Buffer) error{Overflow}!u32 {
    assert(offset < line.len);
    assert(line[offset] == '=');

    const start = offset + 1;
    const opener = scan.byte_at(line, start) orelse 0;

    if (is_quote(opener)) {
        try out.push("=");

        return modified(line, try quoted(line, start, out), out);
    }

    var stop = start;

    while (stop < line.len) {
        const byte = line[stop];
        if (byte == ']') break;
        if (byte == ' ') break;

        stop = if (byte == '\\') scan.escape_end(line, stop) else stop + 1;
    }

    if (stop == start) return offset;
    if (!identified(line[start..stop])) return offset;

    try out.push("=\"");
    try out.push(line[start..stop]);
    try out.push("\"");

    return modified(line, stop, out);
}

fn identified(value: []const u8) bool {
    assert(value.len > 0);
    assert(value.len <= std.math.maxInt(u32));

    const dashed = std.mem.startsWith(u8, value, "--");
    var offset: u32 = if (dashed) 2 else @intFromBool(value[0] == '-');

    if (!dashed) {
        if (!name_starts(value, offset)) return false;
    }

    while (offset < value.len) {
        const byte = value[offset];

        if (byte == '\\') {
            offset = scan.escape_end(value, offset);

            continue;
        }

        if (!worded(byte)) {
            if (byte < 0x80) return false;
        }

        offset += 1;
    }

    assert(offset == value.len);

    return true;
}

fn name_starts(value: []const u8, at: u32) bool {
    assert(value.len <= std.math.maxInt(u32));
    assert(at < std.math.maxInt(u32));

    const byte = scan.byte_at(value, at) orelse return false;
    if (byte == '\\') return scan.escape_end(value, at) > at + 1;
    return std.ascii.isAlphabetic(byte) or byte == '_' or byte >= 0x80;
}

fn modified(line: []const u8, from: u32, out: *Buffer) error{Overflow}!u32 {
    assert(from <= line.len);
    assert(line.len <= std.math.maxInt(u32));

    const at = skipped(line, from);
    const letter = scan.byte_at(line, at) orelse return from;

    const flag = switch (letter) {
        'I', 'S', 'i', 's' => true,
        else => false,
    };

    if (!flag) return from;
    if (scan.byte_at(line, skipped(line, at + 1)) != ']') return from;

    try out.push(" ");
    try out.push_byte(std.ascii.toLower(letter));

    assert(at + 1 <= line.len);

    return at + 1;
}

fn opens_a_number(line: []const u8, held: u32) bool {
    assert(held < line.len);
    assert(line.len <= std.math.maxInt(u32));

    const byte = line[held];
    const dotted = byte == '.' and digit_at(line, held + 1);
    const opens = std.ascii.isDigit(byte) or dotted;
    if (!opens) return false;
    if (held == 0) return true;

    const before = line[held - 1];
    if (before == '.') return false;
    if (!worded(before)) return true;
    if (before != '-') return false;
    if (held < 2) return true;
    return !worded(line[held - 2]);
}

fn opens_a_url(line: []const u8, held: u32) bool {
    assert(held < line.len);
    assert(line.len <= std.math.maxInt(u32));

    if (held + 4 > line.len) return false;
    if (!std.ascii.eqlIgnoreCase(line[held .. held + 3], "url")) return false;
    if (line[held + 3] != '(') return false;
    if (held == 0) return true;
    return !worded(line[held - 1]);
}

fn bommed(
    source: []const u8,
    laid_text: []const u8,
    options: Options,
    out: *Buffer,
) error{Overflow}!void {
    assert(std.mem.startsWith(u8, source, scan.byte_order_mark));
    assert(out.empty());
    assert(laid_text.len <= std.math.maxInt(u32));
    assert(options.line_width > 0);

    try out.push(scan.byte_order_mark);

    const head = marked(source, laid_text) orelse return out.push(laid_text);
    const indent = marked_indent(source, &head, options) orelse return out.push(laid_text);
    const literal_spaced = head.literal != null;

    if (literal_spaced) try padded(out, indent);

    var read: u32 = scan.byte_order_mark.len;
    var wrote: u32 = 0;

    for (0..head.comment_count) |index| {
        const comment = comment_from(source, read, head.literal) orelse return error.Overflow;
        const end = comment_end(laid_text, wrote) orelse return error.Overflow;
        const start = blank_end(laid_text, wrote);

        try commented(laid_text[start..end], indent, out);

        if (literal_spaced) {
            try gapped(comment.gap, indent, out);
        } else if (index + 1 < head.comment_count) {
            try out.push(" ");
        } else {}

        read = comment.end;
        wrote = end;
    }

    if (head.flat == null) {
        try out.push(head.selector);
    } else {
        try parted(head.selector, indent, head.tail, options.line_width, out);
    }

    try out.push(laid_text[head.selector_start + head.selector.len ..]);
}

fn marked(source: []const u8, laid_text: []const u8) ?Marked {
    assert(std.mem.startsWith(u8, source, scan.byte_order_mark));
    assert(laid_text.len <= std.math.maxInt(u32));

    const rest: u32 = scan.byte_order_mark.len;
    var lead = blank_end(source, rest);
    var comment_count: u32 = 0;

    for (0..source.len) |_| {
        const end = comment_end(source, lead) orelse break;

        lead = blank_end(source, end);
        comment_count += 1;
    }

    if (lead == rest) return null;
    if (lead >= source.len) return null;
    if (source[lead] == '@') return null;

    const literal = literal_at(source, rest, lead);
    var past: u32 = 0;

    for (0..comment_count) |_| {
        past = comment_end(laid_text, past) orelse return null;
    }

    const start = blank_end(laid_text, past);
    const stop = selector_stop(laid_text, start) orelse return null;
    const selector = trim_end(laid_text[start..stop.at]);

    return .{
        .comment_count = comment_count,
        .flat = flat_width(selector),
        .literal = literal,
        .selector = selector,
        .selector_start = start,
        .tail = if (stop.comma) 1 else 2,
    };
}

fn marked_indent(source: []const u8, head: *const Marked, options: Options) ?u32 {
    assert(std.mem.startsWith(u8, source, scan.byte_order_mark));
    assert(head.tail > 0);
    assert(options.line_width > 0);

    const literal_spaced = head.literal != null;
    var forced = head.flat == null;
    var wide = (head.flat orelse 0) + head.tail + @intFromBool(literal_spaced);
    var from: u32 = scan.byte_order_mark.len;

    for (0..head.comment_count) |_| {
        const comment = comment_from(source, from, head.literal) orelse return null;
        const text = source[comment.start..comment.end];
        const multiline = std.mem.findScalar(u8, text, '\n') != null;

        forced = forced or multiline or comment.gap == .empty;
        wide += columns(text) + 1;
        from = comment.end;
    }

    const breaks = forced or wide - @intFromBool(!literal_spaced) > options.line_width;
    return if (breaks) options.indent_width else 0;
}

fn comment_from(source: []const u8, from: u32, literal: ?u32) ?Comment {
    assert(from <= source.len);
    assert(source.len <= std.math.maxInt(u32));
    if (literal) |held| assert(held < std.math.maxInt(u32));

    const start = blank_end(source, from);
    const end = comment_end(source, from) orelse return null;
    const following = blank_end(source, end);
    const inside = if (literal) |at| at >= end and at < following else false;
    const after: u32 = if (inside) 0 else breaks_in(source[end..following]);

    const gap: Gap = switch (after) {
        0 => .space,
        1 => .soft,
        else => .empty,
    };

    assert(start < end);

    return .{ .end = end, .gap = gap, .start = start };
}

fn comment_end(bytes: []const u8, from: u32) ?u32 {
    assert(from <= bytes.len);
    assert(bytes.len <= std.math.maxInt(u32));

    const start = blank_end(bytes, from);
    if (!std.mem.startsWith(u8, bytes[start..], "/*")) return null;

    const end = scan.find(bytes[start + 2 ..], "*/") orelse return null;

    assert(std.mem.endsWith(u8, bytes[0 .. start + 4 + end], "*/"));

    return start + 4 + end;
}

fn literal_at(source: []const u8, from: u32, lead: u32) ?u32 {
    assert(lead < source.len);
    assert(from <= lead);

    var held = from;

    for (0..source.len) |_| {
        if (held >= lead) return null;
        if (scan.is_ascii_whitespace(source[held])) return held;

        held = comment_end(source, held) orelse return null;
    }

    return null;
}

fn breaks_in(bytes: []const u8) u32 {
    assert(bytes.len <= std.math.maxInt(u32));

    var found: u32 = 0;

    for (bytes) |byte| {
        if (byte == '\n') found += 1;
    }

    assert(found <= bytes.len);

    return found;
}

fn blank_end(bytes: []const u8, from: u32) u32 {
    assert(from <= bytes.len);

    var held = from;

    while (held < bytes.len) : (held += 1) {
        if (!scan.is_ascii_whitespace(bytes[held])) break;
    }

    assert(held >= from);
    if (held < bytes.len) assert(!scan.is_ascii_whitespace(bytes[held]));

    return held;
}

fn selector_stop(bytes: []const u8, from: u32) ?Stop {
    assert(from <= bytes.len);
    assert(bytes.len <= std.math.maxInt(u32));

    var depth: u32 = 0;
    var held = from;
    var quote: u8 = 0;

    while (held < bytes.len) {
        if (literal_end(bytes, held, &quote)) |end| {
            held = end;

            continue;
        }

        if (std.mem.startsWith(u8, bytes[held..], "/*")) {
            held = crossed(bytes, held);

            continue;
        }

        const byte = bytes[held];
        const comma = depth == 0 and byte == ',';
        const opens = depth == 0 and byte == '{';

        if (comma) return .{ .at = held, .comma = true };
        if (opens) return .{ .at = held, .comma = false };

        if (is_quote(byte)) quote = byte;

        depth = deepened(depth, byte);
        held += 1;
    }

    return null;
}

fn documented(comment: []const u8) bool {
    assert(comment.len <= std.math.maxInt(u32));

    var lines = std.mem.splitScalar(u8, comment, '\n');
    if (!std.mem.startsWith(u8, lines.first(), "/**")) return false;
    if (std.mem.findScalar(u8, comment, '\n') == null) return false;

    for (0..comment.len) |_| {
        const line = lines.next() orelse break;
        if (!std.mem.startsWith(u8, trim_start(line), "*")) return false;
    }

    assert(comment.len > 3);

    return true;
}

fn commented(comment: []const u8, indent: u32, out: *Buffer) error{Overflow}!void {
    assert(comment.len <= std.math.maxInt(u32));
    assert(std.mem.startsWith(u8, comment, "/*"));
    assert(indent < std.math.maxInt(u32));

    if (indent == 0) return out.push(comment);
    if (!documented(comment)) return out.push(comment);

    var lines = std.mem.splitScalar(u8, comment, '\n');

    try out.push(trim_end(lines.first()));

    for (0..comment.len) |_| {
        const line = lines.next() orelse break;

        try out.push("\n");
        try padded(out, indent + 1);
        try out.push(scan.trim_ascii(line));
    }
}

fn gapped(gap: Gap, indent: u32, out: *Buffer) error{Overflow}!void {
    assert(indent < std.math.maxInt(u32));

    const before = out.count();

    switch (gap) {
        .space => try out.push(" "),
        .soft => {
            if (indent == 0) return out.push(" ");

            try out.push("\n");
            try padded(out, indent);
        },
        .empty => {
            try out.push("\n\n");
            try padded(out, indent);
        },
    }

    assert(out.count() > before);
}

fn part_end(selector: []const u8, from: u32) ?u32 {
    assert(from <= selector.len);
    assert(selector.len <= std.math.maxInt(u32));

    var depth: u32 = 0;
    var held = from;
    var quote: u8 = 0;

    while (held < selector.len) {
        if (literal_end(selector, held, &quote)) |end| {
            held = end;

            continue;
        }

        if (std.mem.startsWith(u8, selector[held..], "/*")) {
            held = crossed(selector, held);

            continue;
        }

        const byte = selector[held];
        const inner_break = depth > 0 and byte == '\n';
        const spacing = byte == ' ' or byte == '\n';
        const ends = depth == 0 and spacing;

        if (inner_break) return null;
        if (ends) return held;

        if (is_quote(byte)) quote = byte;

        depth = deepened(depth, byte);
        held += 1;
    }

    return extent(selector);
}

fn flat_width(selector: []const u8) ?u32 {
    assert(selector.len <= std.math.maxInt(u32));

    var held: u32 = 0;
    var wide: u32 = 0;

    for (0..selector.len + 1) |_| {
        const stop = part_end(selector, held) orelse return null;

        wide += columns(selector[held..stop]);

        if (stop >= selector.len) break;

        wide += 1;
        held = blank_end(selector, stop);
    }

    assert(wide <= selector.len);

    return wide;
}

fn unit_end(selector: []const u8, from: u32) ?u32 {
    assert(from <= selector.len);
    assert(selector.len <= std.math.maxInt(u32));

    const stop = part_end(selector, from) orelse return null;
    if (stop >= selector.len) return stop;
    if (!combinator(selector[from..stop])) return stop;
    return part_end(selector, blank_end(selector, stop));
}

fn column_of(out: *const Buffer) u32 {
    const bytes = out.const_slice();
    const start: u32 = if (std.mem.findScalarLast(u8, bytes, '\n')) |at| @intCast(at + 1) else 0;
    const line = bytes[start..];
    const mark: u32 = @intFromBool(std.mem.startsWith(u8, line, scan.byte_order_mark));
    const width = columns(line);

    assert(start <= bytes.len);
    assert(width >= mark);

    return width - mark;
}

fn parted(
    selector: []const u8,
    indent: u32,
    tail: u32,
    width: u32,
    out: *Buffer,
) error{Overflow}!void {
    assert(selector.len <= std.math.maxInt(u32));
    assert(width > 0);
    assert(indent < std.math.maxInt(u32));
    assert(tail < std.math.maxInt(u32));

    var held: u32 = 0;

    for (0..selector.len + 1) |_| {
        const stop = unit_end(selector, held) orelse return error.Overflow;
        const unit = selector[held..stop];
        const carried = if (stop >= selector.len) tail else 0;

        if (held > 0) try unit_lead(indent, out);

        const spot = if (indent > 0) pseudo_at(unit, column_of(out), carried, width) else null;

        if (spot) |found| {
            try pseudoed(unit, indent, found, carried, width, out);
        } else {
            try out.push(unit);
        }

        if (stop >= selector.len) break;

        held = blank_end(selector, stop);
    }
}

fn unit_lead(indent: u32, out: *Buffer) error{Overflow}!void {
    assert(!out.empty());
    assert(indent < std.math.maxInt(u32));

    const before = out.count();

    if (indent == 0) return out.push(" ");

    try out.push("\n");
    try padded(out, indent);

    assert(out.count() == before + 1 + indent);
}

fn columns(bytes: []const u8) u32 {
    assert(bytes.len <= std.math.maxInt(u32));

    var found: u32 = 0;

    for (bytes) |byte| {
        if (byte & 0xC0 != 0x80) found += 1;
    }

    assert(found <= bytes.len);

    return found;
}

fn indent_of(line: []const u8) u32 {
    assert(line.len <= std.math.maxInt(u32));

    var held: u32 = 0;

    while (held < line.len) : (held += 1) {
        if (line[held] != ' ') break;
    }

    assert(held <= line.len);
    if (held < line.len) assert(line[held] != ' ');

    return held;
}

fn lowered(bytes: []const u8, out: *Buffer) error{Overflow}!void {
    assert(bytes.len <= std.math.maxInt(u32));

    const before = out.count();

    for (bytes) |byte| {
        try out.push_byte(std.ascii.toLower(byte));
    }

    assert(out.count() == before + bytes.len);
}

fn line_end(bytes: []const u8, offset: u32) u32 {
    assert(offset <= bytes.len);

    const found = std.mem.findScalarPos(u8, bytes, offset, '\n') orelse bytes.len;
    const end: u32 = @intCast(found);

    assert(end >= offset);
    if (end < bytes.len) assert(bytes[end] == '\n');

    return end;
}

fn skipped(bytes: []const u8, offset: u32) u32 {
    assert(offset <= bytes.len);

    var held = offset;

    while (held < bytes.len) : (held += 1) {
        if (bytes[held] != ' ') break;
    }

    assert(held >= offset);
    if (held < bytes.len) assert(bytes[held] != ' ');

    return held;
}

fn worded(byte: u8) bool {
    if (byte < '-') return false;

    return std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '-';
}

fn worded_at(bytes: []const u8, at: u32) bool {
    assert(bytes.len <= std.math.maxInt(u32));
    assert(at < std.math.maxInt(u32));

    const byte = scan.byte_at(bytes, at) orelse return false;

    assert(at < bytes.len);

    return worded(byte);
}

fn digit_at(bytes: []const u8, at: u32) bool {
    assert(bytes.len <= std.math.maxInt(u32));
    assert(at < std.math.maxInt(u32));

    const byte = scan.byte_at(bytes, at) orelse return false;

    assert(at < bytes.len);

    return std.ascii.isDigit(byte);
}

fn signed_at(bytes: []const u8, at: u32) bool {
    assert(bytes.len <= std.math.maxInt(u32));
    assert(at < std.math.maxInt(u32));

    const byte = scan.byte_at(bytes, at) orelse return false;

    assert(at < bytes.len);

    return byte == '+' or byte == '-';
}

fn is_quote(byte: u8) bool {
    return byte == '"' or byte == '\'';
}

fn ends_selector(body: []const u8) bool {
    assert(body.len <= std.math.maxInt(u32));

    return std.mem.endsWith(u8, body, "{") or std.mem.endsWith(u8, body, ",");
}

fn spaces_only(bytes: []const u8) bool {
    assert(bytes.len <= std.math.maxInt(u32));

    for (bytes) |byte| {
        if (byte != ' ') return false;
    }

    return true;
}

fn vacant(bytes: []const u8) bool {
    assert(bytes.len <= std.math.maxInt(u32));

    for (bytes) |byte| {
        if (!scan.is_ascii_whitespace(byte)) return false;
    }

    return true;
}

fn extent(bytes: []const u8) u32 {
    assert(bytes.len <= std.math.maxInt(u32));

    return @intCast(bytes.len);
}

fn trim_end(bytes: []const u8) []const u8 {
    assert(bytes.len <= std.math.maxInt(u32));

    const trimmed = std.mem.trimEnd(u8, bytes, scan.ascii_whitespace);

    assert(trimmed.len <= bytes.len);
    if (trimmed.len > 0) assert(!scan.is_ascii_whitespace(trimmed[trimmed.len - 1]));

    return trimmed;
}

fn trim_start(bytes: []const u8) []const u8 {
    assert(bytes.len <= std.math.maxInt(u32));

    const trimmed = std.mem.trimStart(u8, bytes, scan.ascii_whitespace);

    assert(trimmed.len <= bytes.len);
    if (trimmed.len > 0) assert(!scan.is_ascii_whitespace(trimmed[0]));

    return trimmed;
}

fn word_start(bytes: []const u8, end: u32) u32 {
    assert(end <= bytes.len);

    var start = end;

    while (start > 0) : (start -= 1) {
        if (!worded(bytes[start - 1])) break;
    }

    assert(start <= end);

    return start;
}
