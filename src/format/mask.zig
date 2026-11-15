const std = @import("std");
const assert = std.debug.assert;
const ArrayType = @import("../stdx/bounded/array.zig").ArrayType;
const Buffer = @import("../stdx/bounded/buffer.zig");
const Token = @import("../syntax/token.zig");
const TreeType = @import("../syntax/tree.zig").TreeType;
const arrow_body = @import("arrow_body.zig");
const body_walk = @import("body_walk.zig");
const brace = @import("brace.zig");
const cast = @import("cast.zig");
const following = walk.following;
const jump_wrap = @import("jump_wrap.zig");
const preceding = walk.preceding;
const solo = @import("solo.zig");
const tag = @import("tag.zig");
const walk = @import("walk.zig");
const written_after = walk.written_after;
const written_before = walk.written_before;

pub const Terminators = struct {
    added: ArrayType(u8),
    calls: ArrayType(u8),
    closes: ArrayType(u8),
    fresh: ArrayType(u32),
    labels: ArrayType(u8),
    lists: ArrayType(u8),
    marks: ArrayType(u16),
    moves: ArrayType(u8),
    nests: ArrayType(u32),
    opens: ArrayType(u8),
    origins: ArrayType(u32),
    roles: ArrayType(u16),
    source: Buffer,
    tokens: ArrayType(Token),

    pub fn init(
        gpa: std.mem.Allocator,
        element_count_max: u32,
        scratch_bytes_max: u32,
    ) std.mem.Allocator.Error!Terminators {
        assert(element_count_max > 0);
        assert(scratch_bytes_max > 0);

        var added = try ArrayType(u8).init(gpa, element_count_max);
        errdefer added.deinit(gpa);

        var calls = try ArrayType(u8).init(gpa, element_count_max);
        errdefer calls.deinit(gpa);

        var closes = try ArrayType(u8).init(gpa, element_count_max);
        errdefer closes.deinit(gpa);

        var fresh = try ArrayType(u32).init(gpa, element_count_max);
        errdefer fresh.deinit(gpa);

        var labels = try ArrayType(u8).init(gpa, element_count_max);
        errdefer labels.deinit(gpa);

        var lists = try ArrayType(u8).init(gpa, element_count_max);
        errdefer lists.deinit(gpa);

        var marks = try ArrayType(u16).init(gpa, element_count_max);
        errdefer marks.deinit(gpa);

        var moves = try ArrayType(u8).init(gpa, element_count_max);
        errdefer moves.deinit(gpa);

        var nests = try ArrayType(u32).init(gpa, element_count_max);
        errdefer nests.deinit(gpa);

        var opens = try ArrayType(u8).init(gpa, element_count_max);
        errdefer opens.deinit(gpa);

        var origins = try ArrayType(u32).init(gpa, element_count_max);
        errdefer origins.deinit(gpa);

        var roles = try ArrayType(u16).init(gpa, element_count_max);
        errdefer roles.deinit(gpa);

        var source = try Buffer.init(gpa, scratch_bytes_max);
        errdefer source.deinit(gpa);

        const tokens = try ArrayType(Token).init(gpa, element_count_max);

        return .{
            .added = added,
            .calls = calls,
            .closes = closes,
            .fresh = fresh,
            .labels = labels,
            .lists = lists,
            .marks = marks,
            .moves = moves,
            .nests = nests,
            .opens = opens,
            .origins = origins,
            .roles = roles,
            .source = source,
            .tokens = tokens,
        };
    }

    pub fn deinit(stream: *Terminators, gpa: std.mem.Allocator) void {
        assert(stream.marks.capacity() == stream.tokens.capacity());
        assert(stream.roles.capacity() == stream.tokens.capacity());

        stream.added.deinit(gpa);
        stream.calls.deinit(gpa);
        stream.closes.deinit(gpa);
        stream.fresh.deinit(gpa);
        stream.labels.deinit(gpa);
        stream.lists.deinit(gpa);
        stream.marks.deinit(gpa);
        stream.moves.deinit(gpa);
        stream.nests.deinit(gpa);
        stream.opens.deinit(gpa);
        stream.origins.deinit(gpa);
        stream.roles.deinit(gpa);
        stream.source.deinit(gpa);
        stream.tokens.deinit(gpa);
        stream.* = undefined;
    }

    pub fn added_slice(stream: *const Terminators) []const u8 {
        assert(stream.added.count() <= stream.added.capacity());
        assert(stream.added.capacity() == stream.tokens.capacity());

        return stream.added.const_slice();
    }

    pub fn labels_slice(stream: *const Terminators) []const u8 {
        assert(stream.labels.count() <= stream.labels.capacity());
        assert(stream.labels.capacity() == stream.tokens.capacity());

        return stream.labels.const_slice();
    }

    pub fn lists_slice(stream: *const Terminators) []const u8 {
        assert(stream.lists.count() <= stream.lists.capacity());
        assert(stream.lists.capacity() == stream.tokens.capacity());

        return stream.lists.const_slice();
    }

    pub fn nests_slice(stream: *const Terminators) []const u32 {
        assert(stream.nests.count() % 2 == 0);
        assert(stream.nests.capacity() == stream.tokens.capacity());

        return stream.nests.const_slice();
    }

    pub fn origins_slice(stream: *const Terminators) []const u32 {
        assert(stream.origins.count() <= stream.origins.capacity());
        assert(stream.origins.capacity() == stream.tokens.capacity());

        return stream.origins.const_slice();
    }

    pub fn roles_slice(stream: *const Terminators) []const u16 {
        assert(stream.roles.count() == stream.tokens.count());
        assert(stream.roles.capacity() == stream.tokens.capacity());

        return stream.roles.const_slice();
    }

    pub fn source_slice(stream: *const Terminators) []const u8 {
        assert(stream.source.count() <= stream.source.capacity());
        assert(stream.source.capacity() > 0);

        return stream.source.const_slice();
    }

    pub fn tokens_slice(stream: *const Terminators) []const Token {
        assert(stream.tokens.count() == stream.roles.count());
        assert(stream.tokens.count() <= stream.tokens.capacity());

        return stream.tokens.const_slice();
    }
};

pub const Chained = enum {
    call,
    member,
    none,
    optional,
    subscript,
    template,
};

pub const Heads = struct {
    bodied: bool,
    branch: bool,
    called: bool,
    decorated: bool,
    plain: bool,
    statement: bool,
};

pub const Holed = enum {
    hole,
    listed,
    plain,
};

pub const Initializer = enum {
    head,
    none,
    statement,
};

const Pairs = struct {
    calls: []u8,
    closes: []u8,
    opens: []u8,
};

pub const Patterned = enum {
    array,
    assigned,
    caught,
    defaulted,
    none,
    object,
    pair,
    parameter,
    parameters,
    rest,
};

const Range = struct {
    first: u32,
    last: u32,
};

const LoneRange = struct {
    start: u32,
    end: u32,
};

pub const Widths = struct {
    indent: u32,
    line: u32,
};

const Calling = struct {
    open: u32,
    separated: bool,
};

const Arm = struct {
    body: u32,
    node: u32,
    stop: u32,
};

const Strung = struct {
    kept: bool,
    spilled: bool,
};

const Marks = struct {
    flags: []u16,
    pairs: *const Pairs,
};

const Closure = struct {
    lambda: u32,
    called: bool,
    deep: bool,
};

const Wanted = struct {
    closes: bool,
    opens: bool,
    owed: bool,
};

const end_owed: u16 = 1 << 0;
const end_denied: u16 = 1 << 1;

const emitter_roles: u16 = brace.role_block | brace.role_lambda | brace.role_part |
    brace.role_span | brace.role_start | brace.role_tight;

const call_parens = true;
const callee_parens = true;
const callees_new = true;
const calls_after: u8 = 1 << 7;
const callee_wraps = true;
const nests_parens = true;
const loop_tests = true;
const loop_test_walk_max: u32 = 8;
const double_pairs = true;
const statement_parens = true;
const braced_heads = true;
const chain_heads = true;
const chain_head_max: u32 = 8;
const cast_chains = true;
const import_queries = true;
const paren_ancestors = true;
const comment_ends = true;
const statement_walk_max: u32 = 16;
const paren_drops: u16 = 1 << 2;
const rebalances = true;
const operator_runs = true;
const coalesce_parens = true;
const hole_ternaries = true;
const hole_walk_max: u32 = 64;
const hole_depth: u32 = 3;
const opened_types = true;
const comment_enclosed = true;
const lone_parens = true;
const comment_hoists = true;
const binary_hoists = true;
const assign_hoists = true;
const paren_comments = true;
const paren_suffixes = true;
const argued_suffixes = true;
const lone_drops = true;
const nested_comment_parens = true;
const paren_leads = true;
const leading_ampersands = true;
const separator_comments = true;
const comma_pulls = true;
const bracket_abuts = true;
const unary_abuts = true;
const paren_abuts = true;
const label_abuts = true;
const suppressed_statements = true;
const nested_parens = true;
const paren_nest_max: u32 = 8;
const unary_comments = true;
const arrow_pairs = true;
const initializer_parens = true;
const move_leads: u8 = 1;
const move_drops: u8 = 2;
const move_abuts: u8 = 3;
const move_trails: u8 = 4;
const move_closes: u8 = 5;
const move_pending: u8 = 6;
const move_opens: u8 = 7;
const move_separates: u8 = 8;
const move_bars: u8 = 9;
const move_hoists: u8 = 10;
const move_hoisted: u8 = 11;
const move_pulls: u8 = 12;
const move_breaks: u8 = 13;
const bar_leads = true;
const bar_comment_max: u32 = 16;
const separator_comment_max: u32 = 16;
const else_comments = true;
const hoist_walk_max: u32 = 4;
const jsx_opens: u16 = 1 << 7;
const type_nodes: u16 = 1 << 8;
const name_words: u16 = 1 << 5;
const operator_spaced: u16 = 1 << 6;
const operand_walk_max: u32 = 16;
const lambda_pairs = true;
const forced_scan_max: u32 = 4;
const lambda_pair_max: u32 = 256;
const block_opens: u16 = 1 << 3;
const block_closes: u16 = 1 << 4;
const block_drops: u16 = 1 << 5;
const arm_ends: u16 = 1 << 9;
const list_lines: u16 = 1 << 10;
const attribute_lines: u16 = 1 << 11;
const arm_argued = true;
const arm_arrows = true;
const arm_forces = true;
const pattern_depth_max: u32 = 32;
const pattern_walk_max: u32 = 64;
const optional_walk_max: u32 = 1_024;
const let_walk_max: u32 = 256;
const arm_lined = true;
const tab_columns = true;
const arm_inners = true;
const arm_lines = true;
const arm_semis = true;
const arm_jumps = [_][]const u8{ "break", "continue", "return", "yield" };
const body_ones = true;
const arm_ones = true;
const arm_jump_caps = true;
const arm_strings = true;
const arm_leads = true;
const arm_endings = true;
const list_item_max: u32 = 1 << 16;
const body_statements = true;
const body_fronts = true;
const body_tails = true;
const arm_margins = true;
const block_breaks = true;
const call_heads = true;
const call_cascades = true;
const brace_columns: u32 = 2;
const call_seats = true;
const call_args = true;
const call_soles = true;
const call_links: u32 = 2;
const brace_open = " {\n";
const mask_semicolon: u8 = 1;
const mask_close: u8 = 2;
const mask_open: u8 = 3;
const brace_close = "\n}";
pub const body_stack_max: u32 = 32;
const tail_scan_max: u32 = 256;
const tail_walk_max: u32 = 2;
const call_walk_max: u32 = 3;
const chain_walk_max: u32 = 6;
const skip_walk_max: u32 = 8;
const call_dotted = true;
const call_nested = true;
const paren_close = ")";
const paren_open = "(";
const semicolon = ";";
const logical_marks = [_][]const u8{ "&&", "??", "||" };
const declare_words = [_][]const u8{ "const", "let", "var" };

const cast_led_words = [_][]const u8{
    "await",
    "interface",
    "let",
    "module",
    "type",
    "using",
    "yield",
};

const assignment_operators = [_][]const u8{
    "=",
    "+=",
    "-=",
    "*=",
    "/=",
    "%=",
    "**=",
    "<<=",
    ">>=",
    ">>>=",
    "&=",
    "|=",
    "^=",
    "&&=",
    "||=",
    "??=",
    "++",
    "--",
};

const ascii_whitespace = " \t\n\r\x0c";
const none: u32 = std.math.maxInt(u32);

comptime {
    const flags = end_owed | end_denied | paren_drops | block_opens | block_closes | block_drops;
    const roles = jsx_opens | type_nodes | name_words | operator_spaced | arm_ends | list_lines;

    assert(@popCount(flags) == 6);
    assert(@popCount(roles) == 6);
    assert(flags & roles == name_words);
    assert(move_bars > move_separates);
    assert(move_hoists > move_bars);
    assert(move_hoisted > move_hoists);
    assert(move_pulls > move_hoisted);
    assert(calls_after & 0x7f == 0);
    assert(mask_open > mask_close);
}

fn SignsType(comptime Kind: type) type {
    assert(@hasDecl(Kind, "category"));
    assert(@hasDecl(Kind, "is_node"));

    return fn (Kind, Kind, []const u8, []const u8, bool) ?bool;
}

pub fn RulesType(comptime Kind: type) type {
    assert(@hasDecl(Kind, "category"));
    assert(@hasDecl(Kind, "is_node"));

    return struct {
        arrows: fn (Kind) bool,
        bodiless: fn (Kind) bool,
        bodies: fn (Kind) bool,
        braced: fn (Kind) bool,
        branches: fn (Kind) bool,
        calls: fn (Kind) bool,
        cases: fn (Kind) bool,
        casts: fn (Kind) bool,
        chains: fn (Kind) Chained,
        defaults: fn (Kind) bool,
        denies: fn (Kind, Kind) bool,
        drops: fn (Kind, Kind, ?Kind, Heads, bool) bool,
        holes: fn (Kind) Holed,
        imports: fn (Kind, Kind) bool,
        initializers: fn (Kind) Initializer,
        invokes: fn (Kind) bool,
        jsx: fn (Kind) tag.Jsx,
        jsx_wraps: fn (Kind) bool,
        jumps: fn (Kind, Kind) bool,
        labels: fn (Kind) bool,
        leads: fn (Kind) bool,
        links: fn (Kind) bool,
        lists: fn (Kind) bool,
        mixes: fn (Kind) bool,
        names: fn (Kind) bool,
        nests: fn ([]const u8, []const u8, bool) bool,
        opens: fn (Kind) bool,
        operators: fn (Kind) bool,
        owes: fn (Kind, Kind) bool,
        parameters: fn (Kind) bool,
        parens: fn (Kind) bool,
        passes: fn (Kind) bool,
        patterns: fn (Kind) Patterned,
        queries: fn (Kind) bool,
        signs: SignsType(Kind),
        soles: fn (Kind) bool,
        spans: fn (Kind, Kind, ?Kind) bool,
        statements: fn (Kind) bool,
        tests: fn (Kind, Kind) ?bool,
        unaries: fn (Kind) bool,
        updates: fn (Kind) bool,
        wraps: fn (Kind, Kind, ?Kind, bool) bool,
    };
}

pub fn TailsType(comptime Kind: type) type {
    assert(@hasDecl(Kind, "category"));
    assert(@hasDecl(Kind, "is_node"));

    return struct {
        argued: fn (Kind) bool,
        arms: fn (Kind) bool,
        attributes: fn (Kind, Kind, ?Kind) bool,
        bodies: fn (Kind) u32,
        bounds: fn (Kind) bool,
        call_width: u32,
        chained: fn (Kind) bool,
        compares: fn (Kind) bool,
        flattens: fn (Kind) bool,
        forces: fn (Kind) bool,
        items: fn (Kind) bool,
        keeps: fn (Kind) bool,
        lambda: fn (Kind) bool,
        lasts: fn (Kind) bool,
        lines: fn (Kind, Kind) bool,
        literal: u32,
        operands: fn (Kind) bool,
        owes: fn (Kind, Kind) bool,
        width: u32,
        wraps: fn (Kind) bool,
    };
}

fn PlacedType(comptime Kind: type) type {
    assert(@hasDecl(Kind, "category"));
    assert(@hasDecl(Kind, "is_node"));

    return struct {
        node: *const NodeType(Kind),
        inner: *const NodeType(Kind),
        above: *const NodeType(Kind),
    };
}

fn NodeType(comptime Kind: type) type {
    assert(@hasDecl(Kind, "category"));
    assert(@hasDecl(Kind, "is_node"));

    return TreeType(Kind).Node;
}

fn separated_already(tokens: []const Token, flags: []const u16, position: u32) bool {
    assert(position < tokens.len);
    assert(flags.len == tokens.len);

    if (separating(tokens[position])) return true;

    for (position + 1..tokens.len) |scan| {
        const token = tokens[scan];
        const skipped_token = token.kind == .newline or token.length == 0 or token.kind == .comment;
        if (skipped_token) continue;
        if (flags[scan] & block_drops != 0) return false;
        if (flags[scan] & paren_drops != 0) continue;
        return separating(token);
    }

    return false;
}

fn separating(token: Token) bool {
    assert(token.length <= std.math.maxInt(u32) - token.offset);

    const result = token.is_punctuation(.comma) or token.is_punctuation(.semicolon);

    if (result) assert(token.kind == .punctuation);

    return result;
}

pub fn terminated(
    comptime Kind: type,
    tree: *const TreeType(Kind),
    source: []const u8,
    tokens: []const Token,
    comptime rules: *const RulesType(Kind),
    stream: *Terminators,
) error{Overflow}!void {
    assert(source.len < std.math.maxInt(u32));
    assert(tokens.len < std.math.maxInt(u32));

    try terminated_reset(stream, @intCast(tokens.len));
    try terminated_marks(Kind, tree, source, tokens, rules, stream);

    var written: u32 = 0;

    for (0..tokens.len) |index| {
        try terminated_token(source, tokens, stream, @intCast(index), &written);
    }

    resolved(stream.nests.slice(), stream.fresh.const_slice());
    try stream.source.push(source[written..]);
    try labels_marked(Kind, tree, source, tokens, rules, stream);
    patterns_marked(Kind, tree, source, tokens, rules, stream);

    assert(stream.tokens.count() == stream.roles.count());
    assert(stream.nests.count() % 2 == 0);
}

fn labels_marked(
    comptime Kind: type,
    tree: *const TreeType(Kind),
    source: []const u8,
    tokens: []const Token,
    comptime rules: *const RulesType(Kind),
    stream: *Terminators,
) error{Overflow}!void {
    assert(source.len <= std.math.maxInt(u32));

    const nodes = tree.slice();
    const fresh = stream.fresh.const_slice();

    assert(fresh.len == tokens.len);
    assert(stream.labels.empty());

    for (0..stream.tokens.count()) |_| {
        try stream.labels.pushed(0);
    }

    const labels = stream.labels.slice();

    for (nodes) |*node| {
        if (!rules.labels(node.kind)) continue;
        if (node.child_first == none) continue;

        const colon = following(tokens, nodes[node.child_first].token_end) orelse continue;
        if (!text_equal(source, tokens[colon], ":")) continue;
        if (fresh[colon] == none) continue;

        labels[fresh[colon]] |= brace.mark_label;
    }

    assert(labels.len == stream.tokens.count());
}

fn patterns_marked(
    comptime Kind: type,
    tree: *const TreeType(Kind),
    source: []const u8,
    tokens: []const Token,
    comptime rules: *const RulesType(Kind),
    stream: *Terminators,
) void {
    assert(source.len <= std.math.maxInt(u32));

    const nodes = tree.slice();
    const fresh = stream.fresh.const_slice();
    const labels = stream.labels.slice();

    assert(fresh.len == tokens.len);
    assert(labels.len == stream.tokens.count());

    for (nodes, 0..) |*node, index| {
        if (rules.patterns(node.kind) != .object) continue;
        if (!pattern_expands(Kind, nodes, source, tokens, rules, @intCast(index))) continue;

        pattern_expanded(Kind, nodes, rules, fresh, labels, @intCast(index));
    }
}

fn pattern_expands(
    comptime Kind: type,
    nodes: []const NodeType(Kind),
    source: []const u8,
    tokens: []const Token,
    comptime rules: *const RulesType(Kind),
    index: u32,
) bool {
    assert(index < nodes.len);
    assert(source.len <= std.math.maxInt(u32));
    assert(tokens.len <= std.math.maxInt(u32));

    const node = &nodes[index];

    assert(rules.patterns(node.kind) == .object);

    if (node.parent == none) return false;
    if (pattern_parameter(Kind, nodes, rules, index)) return false;

    const assigned = pattern_assigned(Kind, nodes, source, tokens, rules, index);
    var child = node.child_first;

    for (0..list_item_max) |_| {
        if (child == none) return false;
        if (pattern_nests(Kind, nodes, rules, child, assigned)) return true;

        child = nodes[child].sibling_next;
    }

    return false;
}

fn pattern_parameter(
    comptime Kind: type,
    nodes: []const NodeType(Kind),
    comptime rules: *const RulesType(Kind),
    index: u32,
) bool {
    assert(nodes.len <= std.math.maxInt(u32));
    assert(index < nodes.len);

    const parent = nodes[index].parent;

    assert(parent != none);
    assert(parent < nodes.len);

    switch (rules.patterns(nodes[parent].kind)) {
        .caught, .parameter, .parameters => return true,
        .defaulted => {},
        else => return false,
    }

    if (nodes[parent].child_first != index) return false;

    const above = nodes[parent].parent;
    if (above == none) return false;
    return rules.patterns(nodes[above].kind) == .parameters;
}

fn pattern_assigned(
    comptime Kind: type,
    nodes: []const NodeType(Kind),
    source: []const u8,
    tokens: []const Token,
    comptime rules: *const RulesType(Kind),
    index: u32,
) bool {
    assert(source.len <= std.math.maxInt(u32));
    assert(tokens.len <= std.math.maxInt(u32));
    assert(index < nodes.len);

    var top = index;

    assert(rules.patterns(nodes[index].kind) == .object);

    for (0..pattern_walk_max) |_| {
        const parent = nodes[top].parent;
        if (parent == none) return false;

        switch (rules.patterns(nodes[parent].kind)) {
            .array, .defaulted, .object, .pair, .rest => top = parent,
            .assigned => return !pattern_declared(source, tokens, nodes[top].token_start),
            else => return false,
        }
    }

    return false;
}

fn pattern_declared(source: []const u8, tokens: []const Token, start: u32) bool {
    assert(start <= tokens.len);
    assert(tokens.len < none);
    assert(source.len <= std.math.maxInt(u32));

    const before = preceding(tokens, start) orelse return false;

    for (declare_words) |word| {
        if (text_equal(source, tokens[before], word)) return true;
    }

    return false;
}

fn pattern_nests(
    comptime Kind: type,
    nodes: []const NodeType(Kind),
    comptime rules: *const RulesType(Kind),
    child: u32,
    assigned: bool,
) bool {
    assert(child < nodes.len);
    assert(rules.patterns(nodes[nodes[child].parent].kind) == .object);

    if (rules.patterns(nodes[child].kind) != .pair) return false;

    const value = pattern_value(Kind, nodes, child) orelse return false;

    switch (rules.patterns(nodes[value].kind)) {
        .array, .object => return true,
        .defaulted => {},
        else => return false,
    }

    if (!assigned) return false;

    const left = nodes[value].child_first;
    if (left == none) return false;

    const held = rules.patterns(nodes[left].kind);
    return held == .array or held == .object;
}

fn pattern_value(comptime Kind: type, nodes: []const NodeType(Kind), pair: u32) ?u32 {
    assert(pair < nodes.len);

    var held = nodes[pair].child_first;
    if (held == none) return null;

    for (0..list_item_max) |_| {
        const next = nodes[held].sibling_next;

        assert(nodes[held].parent == pair);

        if (next == none) return held;

        held = next;
    }

    return null;
}

fn pattern_expanded(
    comptime Kind: type,
    nodes: []const NodeType(Kind),
    comptime rules: *const RulesType(Kind),
    fresh: []const u32,
    labels: []u8,
    index: u32,
) void {
    assert(fresh.len <= std.math.maxInt(u32));
    assert(labels.len <= std.math.maxInt(u32));
    assert(index < nodes.len);

    var held = index;

    assert(rules.patterns(nodes[index].kind) == .object);

    pattern_mark(Kind, nodes, fresh, labels, index);

    for (0..pattern_walk_max) |_| {
        const parent = nodes[held].parent;
        if (parent == none) return;

        switch (rules.patterns(nodes[parent].kind)) {
            .array, .object => pattern_mark(Kind, nodes, fresh, labels, parent),
            .defaulted, .pair, .rest => {},
            else => return,
        }

        held = parent;
    }
}

fn pattern_mark(
    comptime Kind: type,
    nodes: []const NodeType(Kind),
    fresh: []const u32,
    labels: []u8,
    index: u32,
) void {
    assert(nodes.len <= std.math.maxInt(u32));
    assert(index < nodes.len);

    const open = nodes[index].token_start;

    assert(open < fresh.len);

    if (fresh[open] == none) return;

    assert(fresh[open] < labels.len);

    labels[fresh[open]] |= brace.mark_expanded;
}

fn terminated_reset(stream: *Terminators, token_count: u32) error{Overflow}!void {
    assert(token_count < none);

    stream.calls.clear();
    stream.closes.clear();
    stream.fresh.clear();
    stream.labels.clear();
    stream.marks.clear();
    stream.moves.clear();
    stream.nests.clear();
    stream.opens.clear();
    stream.source.clear();
    stream.roles.clear();
    stream.tokens.clear();

    for (0..token_count) |_| {
        try stream.calls.pushed(0);
        try stream.closes.pushed(0);
        try stream.fresh.pushed(none);
        try stream.marks.pushed(0);
        try stream.moves.pushed(0);
        try stream.opens.pushed(0);
    }

    assert(stream.marks.count() == token_count);
    assert(stream.tokens.empty());
}

fn terminated_marks(
    comptime Kind: type,
    tree: *const TreeType(Kind),
    source: []const u8,
    tokens: []const Token,
    comptime rules: *const RulesType(Kind),
    stream: *Terminators,
) error{Overflow}!void {
    assert(source.len <= std.math.maxInt(u32));

    const flags = stream.marks.slice();
    const moves = stream.moves.slice();

    const pairs: Pairs = .{
        .calls = stream.calls.slice(),
        .closes = stream.closes.slice(),
        .opens = stream.opens.slice(),
    };

    assert(flags.len == tokens.len);
    assert(moves.len == tokens.len);

    ended(Kind, tree, source, tokens, rules, flags, &pairs);
    dropped(Kind, tree, source, tokens, rules, flags);
    unary_commented(Kind, tree, tokens, rules, flags, &pairs);
    arrow_paired(Kind, tree, source, tokens, rules, &pairs);
    initialized(Kind, tree, source, tokens, rules, flags, &pairs);

    if (rebalances) try rebalanced(Kind, tree, source, tokens, rules, flags, &stream.nests);

    separated(source, tokens, flags);
    typed(Kind, tree, source, tokens, flags);
    hoisted(Kind, tree, source, tokens, rules, moves);
    trailed(Kind, tree, source, tokens, rules, moves);
    assign_trailed(source, tokens, moves);
    closed(Kind, tree, source, tokens, rules, flags, moves);
    led(Kind, tree, source, tokens, rules, flags, moves);
    ampersanded(Kind, tree, source, tokens, moves);
    abutted(Kind, tree, source, tokens, rules, flags, moves);
    bracket_abutted(Kind, tree, source, tokens, rules, flags, moves);
    labeled(Kind, tree, source, tokens, rules, moves);
    updated(Kind, tree, source, tokens, rules, moves);
    comma_pulled(source, tokens, moves);
    separator_commented(source, tokens, moves);
    case_commented(Kind, tree, source, tokens, rules, moves);

    label_commented(Kind, tree, source, tokens, rules, moves);
    elsed(source, tokens, moves);
    else_hoisted(source, tokens, moves);

    bar_led(source, tokens, flags, moves);

    tag.marked(Kind, tree, source, tokens, rules.jsx, &.{
        .grouped = rules.parens,
        .wraps = rules.jsx_wraps,
    }, flags);

    suppressed(source, tokens, flags, moves, &pairs);
}

fn terminated_token(
    source: []const u8,
    tokens: []const Token,
    stream: *Terminators,
    position: u32,
    written: *u32,
) error{Overflow}!void {
    assert(tokens.len <= std.math.maxInt(u32));
    assert(position < tokens.len);

    const token = tokens[position];
    const mark = stream.marks.get(position);
    const shift = stream.moves.get(position);

    assert(written.* <= source.len);
    assert(stream.marks.count() == tokens.len);

    if (shift == move_hoisted) {
        const before = if (position > 0) tokens[position - 1].end() else 0;

        if (written.* < before) try stream.source.push(source[written.*..before]);

        written.* = token.end();

        return;
    }

    if (shift == move_drops) {
        try terminated_opens(source, token, stream, position, written);
        try stream.source.push(source[written.*..token.offset]);

        const moves = stream.moves.const_slice();

        written.* = lone_dropped(source, tokens, moves, position) orelse token.end();

        return;
    }

    const leads = shift == move_leads or shift == move_bars;
    const abuts = shift == move_abuts and position > 0;

    if (leads) try terminated_lead(source, tokens, stream, position, written);
    if (abuts) try terminated_abut(source, tokens, stream, position, written);
    if (shift == move_hoists) try terminated_hoists(source, tokens, stream, position, written);

    try terminated_opens(source, token, stream, position, written);
    try terminated_held(source, token, stream, position, written);

    try paired(source, token, written, stream, position);
    try terminated_shift(source, tokens, stream, position, written);

    if (shift == move_breaks) try terminated_breaks(source, token, stream, written);
    if (mark & end_owed == 0) return;
    if (mark & end_denied != 0) return;
    if (separated_already(tokens, stream.marks.const_slice(), position)) return;

    try separates(source, token, written, stream);
}

fn terminated_breaks(
    source: []const u8,
    token: Token,
    stream: *Terminators,
    written: *u32,
) error{Overflow}!void {
    assert(written.* <= token.end());
    assert(token.end() <= source.len);

    try stream.source.push(source[written.*..token.end()]);
    try stream.source.push("\n");
    written.* = token.end();
}

fn terminated_lead(
    source: []const u8,
    tokens: []const Token,
    stream: *Terminators,
    position: u32,
    written: *u32,
) error{Overflow}!void {
    assert(source.len <= std.math.maxInt(u32));
    assert(tokens.len <= std.math.maxInt(u32));
    assert(position < tokens.len);

    const moves = stream.moves.const_slice();
    const bars = moves[position] == move_bars;

    const found = if (bars)
        dropped_behind(tokens, moves, position)
    else
        lifted(tokens, moves, position);

    const operator = found orelse return error.Overflow;
    const role = roled(stream, operator);

    assert(operator < tokens.len);
    assert(moves[position] == move_leads or bars);

    try lifts(source, tokens[position], tokens[operator], role, written, stream);
}

fn terminated_hoists(
    source: []const u8,
    tokens: []const Token,
    stream: *Terminators,
    position: u32,
    written: *u32,
) error{Overflow}!void {
    assert(source.len <= std.math.maxInt(u32));

    const moves = stream.moves.const_slice();
    var colons: u32 = 0;

    assert(position < tokens.len);
    assert(moves[position] == move_hoists);

    try stream.source.push(source[written.*..tokens[position].offset]);
    written.* = tokens[position].offset;

    for (position + 1..tokens.len) |index| {
        const held = tokens[index];
        if (held.kind == .newline) continue;
        if (held.length == 0) continue;

        if (held.is_punctuation(.colon)) {
            colons += 1;

            if (colons > 1) break;

            continue;
        }

        if (held.kind != .comment) break;
        if (moves[index] != move_hoisted) break;

        try stream.source.push(held.text(source));

        const at = stream.source.count() - held.length;

        try held_pushed(stream, .{
            .kind = held.kind,
            .length = held.length,
            .offset = at,
        }, roled(stream, @intCast(index)));

        try stream.source.push("\n");
    }

    assert(colons <= 2);
}

fn terminated_abut(
    source: []const u8,
    tokens: []const Token,
    stream: *Terminators,
    position: u32,
    written: *u32,
) error{Overflow}!void {
    assert(position > 0);
    assert(position < tokens.len);
    assert(source.len <= std.math.maxInt(u32));

    const before = tokens[position - 1].end();
    if (written.* > before) return;

    try stream.source.push(source[written.*..before]);
    written.* = tokens[position].offset;
}

fn terminated_opens(
    source: []const u8,
    token: Token,
    stream: *Terminators,
    position: u32,
    written: *u32,
) error{Overflow}!void {
    assert(source.len <= std.math.maxInt(u32));
    assert(token.end() <= source.len);
    assert(position < none);

    const opens: u16 = if (opened_types) roled(stream, position) & brace.role_type else 0;

    assert(opens == 0 or opens == brace.role_type);
    assert(position < stream.opens.count());

    if (stream.moves.get(position) == move_opens) try opening(source, token, 0, written, stream);

    for (0..stream.opens.get(position)) |_| {
        try opening(source, token, opens, written, stream);
    }
}

fn terminated_held(
    source: []const u8,
    token: Token,
    stream: *Terminators,
    position: u32,
    written: *u32,
) error{Overflow}!void {
    assert(source.len <= std.math.maxInt(u32));
    assert(position < none);

    const mark = stream.marks.get(position);

    assert(written.* <= token.offset);
    assert(stream.fresh.get(position) == none);

    if (mark & paren_drops == 0) {
        const moved = stream.source.count() + (token.offset - written.*);
        const keyword = token.kind == .keyword;
        const named = keyword and (token.kind.keyword == .assert or mark & name_words != 0);

        const kept: Token = .{
            .kind = if (named) .identifier else token.kind,
            .length = token.length,
            .offset = moved,
        };

        try held_pushed(stream, kept, roled(stream, position));
        stream.fresh.slice()[position] = stream.tokens.count() - 1;

        return;
    }

    const lone = lone_line(source, token, written.*);

    try stream.source.push(source[written.*..lone.start]);
    written.* = lone.end;
}

fn terminated_shift(
    source: []const u8,
    tokens: []const Token,
    stream: *Terminators,
    position: u32,
    written: *u32,
) error{Overflow}!void {
    assert(source.len <= std.math.maxInt(u32));
    assert(tokens.len <= std.math.maxInt(u32));
    assert(position < tokens.len);

    const token = tokens[position];
    const moves = stream.moves.const_slice();
    const flags = stream.marks.const_slice();

    assert(moves.len == tokens.len);
    assert(flags.len == tokens.len);

    switch (moves[position]) {
        move_trails => {
            const operator = hoisted_operator(tokens, moves, position) orelse
                return error.Overflow;

            const role = roled(stream, operator);

            try trails(source, token, true, tokens[operator], role, written, stream);
        },
        move_separates => {
            const separator = separated_behind(tokens, moves, position) orelse
                return error.Overflow;

            const role = roled(stream, separator);

            try trails(source, token, false, tokens[separator], role, written, stream);
        },
        move_closes => try terminated_closes(source, tokens, stream, position, written),
        move_pulls => {
            const comma = hoisted_operator(tokens, moves, position) orelse
                return error.Overflow;

            const role = roled(stream, comma);

            try trails(source, token, false, tokens[comma], role, written, stream);
        },
        else => {},
    }
}

fn terminated_closes(
    source: []const u8,
    tokens: []const Token,
    stream: *Terminators,
    position: u32,
    written: *u32,
) error{Overflow}!void {
    assert(source.len <= std.math.maxInt(u32));
    assert(tokens.len <= std.math.maxInt(u32));
    assert(position < tokens.len);

    const token = tokens[position];
    const moves = stream.moves.const_slice();
    const flags = stream.marks.const_slice();

    assert(moves[position] == move_closes);
    assert(flags.len == tokens.len);

    for (position + 1..tokens.len) |scan| {
        const held = tokens[scan];
        if (held.kind == .comment) continue;
        if (moves[scan] != move_drops) break;
        if (!held.is_punctuation(.paren_close)) break;

        try trails(source, token, false, held, roled(stream, @intCast(scan)), written, stream);
    }
}

fn resolved(nests: []u32, fresh: []const u32) void {
    assert(nests.len % 2 == 0);
    assert(nests.len <= fresh.len);

    for (0..@divFloor(nests.len, 2)) |index| {
        const first = fresh[nests[index * 2]];
        const last = fresh[nests[index * 2 + 1]];
        const whole = first != none and last != none and first < last;

        nests[index * 2] = if (whole) first else none;
        nests[index * 2 + 1] = if (whole) last else none;
    }
}

pub fn rebalanced(
    comptime Kind: type,
    tree: *const TreeType(Kind),
    source: []const u8,
    tokens: []const Token,
    comptime rules: *const RulesType(Kind),
    flags: []const u16,
    nests: *ArrayType(u32),
) error{Overflow}!void {
    assert(source.len <= std.math.maxInt(u32));

    const nodes = tree.slice();

    assert(flags.len == tokens.len);
    assert(nests.empty());

    for (nodes) |*node| {
        if (!rules.parens(node.kind)) continue;
        if (node.parent == none) continue;
        if (node.child_first == none) continue;
        if (flags[node.token_start] & paren_drops == 0) continue;

        const pair = rebalanced_pair(Kind, nodes, source, tokens, rules, node) orelse continue;

        try nests.pushed(pair.first);
        try nests.pushed(pair.last);
    }
}

fn rebalanced_pair(
    comptime Kind: type,
    nodes: []const NodeType(Kind),
    source: []const u8,
    tokens: []const Token,
    comptime rules: *const RulesType(Kind),
    node: *const NodeType(Kind),
) ?Range {
    assert(nodes.len <= std.math.maxInt(u32));
    assert(source.len <= std.math.maxInt(u32));
    assert(tokens.len <= std.math.maxInt(u32));

    const parent = &nodes[node.parent];
    const inner = &nodes[node.child_first];

    assert(node.parent != none);
    assert(node.child_first != none);

    if (!rules.mixes(parent.kind)) return null;
    if (!rules.mixes(inner.kind)) return null;
    if (inner.child_first == none) return null;

    const left = &nodes[inner.child_first];
    if (!rules.mixes(left.kind)) return null;

    const above = operator_of(Kind, nodes, tokens, parent) orelse return null;
    const held = operator_of(Kind, nodes, tokens, inner) orelse return null;
    const first = operator_of(Kind, nodes, tokens, left) orelse return null;
    const text = operator_text(source, tokens, held);

    if (node.token_start < above) return null;
    if (!logical(text)) return null;
    if (!std.mem.eql(u8, operator_text(source, tokens, above), text)) return null;
    if (!std.mem.eql(u8, operator_text(source, tokens, first), text)) return null;
    return .{ .first = left.token_start, .last = held };
}

pub fn logical(text: []const u8) bool {
    assert(logical_marks.len == 3);
    assert(text.len <= std.math.maxInt(u32));

    for (logical_marks) |mark| {
        if (std.mem.eql(u8, text, mark)) return true;
    }

    return false;
}

fn suppressed(
    source: []const u8,
    tokens: []const Token,
    flags: []u16,
    moves: []u8,
    pairs: *const Pairs,
) void {
    assert(flags.len == tokens.len);
    assert(moves.len == tokens.len);
    assert(source.len <= std.math.maxInt(u32));

    if (!suppressed_statements) return;

    for (0..tokens.len) |position| {
        const range = suppressed_range(source, tokens, @intCast(position)) orelse continue;

        for (range.first..range.last + 1) |held| {
            flags[held] &= ~paren_drops;
            moves[held] = 0;
            pairs.opens[held] = 0;
            pairs.closes[held] = 0;
            pairs.calls[held] = 0;
        }
    }
}

fn suppressed_range(source: []const u8, tokens: []const Token, position: u32) ?Range {
    assert(position < tokens.len);

    const token = tokens[position];

    assert(token.end() <= source.len);

    if (token.kind != .comment) return null;

    const body = suppressed_body(token.text(source));
    if (!std.mem.startsWith(u8, body, "biome-ignore format")) return null;

    for (position + 1..tokens.len) |held| {
        const kind = tokens[held].kind;
        const blank = kind == .newline or kind == .comment or tokens[held].length == 0;
        if (blank) continue;
        return suppressed_scan(source, tokens, @intCast(held));
    }

    return null;
}

fn suppressed_body(text: []const u8) []const u8 {
    assert(text.len <= std.math.maxInt(u32));

    const opener = std.mem.startsWith(u8, text, "//") or std.mem.startsWith(u8, text, "/*");
    const body = if (opener) text[2..] else text;

    assert(body.len <= text.len);
    if (opener) assert(text.len >= 2);

    return std.mem.trimStart(u8, body, ascii_whitespace);
}

fn suppressed_scan(source: []const u8, tokens: []const Token, first: u32) ?Range {
    assert(source.len <= std.math.maxInt(u32));

    var depth: u32 = 0;
    var valued = false;

    assert(first < tokens.len);

    for (first..tokens.len) |scan| {
        const held = tokens[scan];

        const opens = walk.is_open(held.kind) or held.kind == .block_start or
            walk.substituting(source, held);

        const closes = walk.is_close(held.kind) or held.kind == .block_end;

        if (opens) {
            depth += 1;

            continue;
        }

        if (closes) {
            if (depth == 0) return null;

            depth -= 1;

            const parted_close = suppressed_parted(source, tokens, @intCast(scan));
            const ends = depth == 0 and held.kind == .block_end and parted_close and !valued;
            if (ends) return .{ .first = first, .last = @intCast(scan) };

            continue;
        }

        if (depth != 0) continue;
        if (held.is_punctuation(.semicolon)) return .{ .first = first, .last = @intCast(scan) };

        if (held.is_punctuation(.assign)) valued = true;
    }

    assert(depth <= tokens.len);

    return null;
}

fn suppressed_parted(source: []const u8, tokens: []const Token, scan: u32) bool {
    assert(scan < tokens.len);

    const held = tokens[scan];

    assert(held.end() <= source.len);

    for (tokens[scan + 1 ..]) |next| {
        if (next.length == 0) continue;
        if (next.kind == .comment) continue;
        return std.mem.findScalar(u8, source[held.end()..next.offset], '\n') != null;
    }

    return true;
}

fn roled(stream: *const Terminators, position: u32) u16 {
    assert(position < stream.marks.count());

    const mark = stream.marks.get(position);
    const result = jsx_role(mark) | spaced_role(mark) | tag.roles(mark) | type_role(mark);

    if (mark & jsx_opens != 0) assert(result & brace.role_jsx != 0);
    if (mark & type_nodes != 0) assert(result & brace.role_type != 0);

    return result;
}

fn jsx_role(mark: u16) u16 {
    comptime assert(@popCount(brace.role_jsx) == 1);

    if (mark & jsx_opens != 0) return brace.role_jsx;
    return 0;
}

fn type_role(mark: u16) u16 {
    comptime assert(@popCount(brace.role_type) == 1);

    if (mark & type_nodes != 0) return brace.role_type;
    return 0;
}

fn spaced_role(mark: u16) u16 {
    comptime assert(@popCount(brace.role_spaced) == 1);

    if (mark & operator_spaced != 0) return brace.role_spaced;
    return 0;
}

fn lone_line(source: []const u8, token: Token, written: u32) LoneRange {
    assert(written <= token.offset);

    const alone: LoneRange = .{ .start = token.offset, .end = token.end() };

    assert(token.end() <= source.len);

    if (!lone_parens) return alone;

    const gap = source[written..token.offset];
    const before = std.mem.findLastNone(u8, gap, " \t") orelse return alone;
    if (gap[before] != '\n') return alone;

    const rest = source[token.end()..];
    const after = std.mem.findNone(u8, rest, " \t\r") orelse return alone;
    if (rest[after] != '\n') return alone;

    return .{
        .start = written + @as(u32, @intCast(before)),
        .end = token.end() + @as(u32, @intCast(after)),
    };
}

fn held_pushed(stream: *Terminators, token: Token, role: u16) error{Overflow}!void {
    assert(stream.tokens.count() == stream.roles.count());
    assert(stream.tokens.count() < std.math.maxInt(u32));
    assert(token.length <= std.math.maxInt(u32) - token.offset);
    assert(role & emitter_roles == 0);

    try stream.tokens.pushed(token);
    try stream.roles.pushed(role);
}

fn opening(
    source: []const u8,
    token: Token,
    role: u16,
    written: *u32,
    stream: *Terminators,
) error{Overflow}!void {
    assert(written.* <= token.offset);
    assert(token.offset <= source.len);
    assert(role & emitter_roles == 0);

    try stream.source.push(source[written.*..token.offset]);
    try stream.source.push(paren_open);
    written.* = token.offset;

    const at = stream.source.count() - 1;

    try held_pushed(stream, .{
        .kind = .{ .punctuation = .paren_open },
        .length = 1,
        .offset = at,
    }, role);
}

fn closing(
    source: []const u8,
    token: Token,
    written: *u32,
    stream: *Terminators,
) error{Overflow}!void {
    assert(written.* <= token.end());
    assert(token.end() <= source.len);

    try stream.source.push(source[written.*..token.end()]);
    try stream.source.push(paren_close);
    written.* = token.end();

    const at = stream.source.count() - 1;

    try held_pushed(stream, .{
        .kind = .{ .punctuation = .paren_close },
        .length = 1,
        .offset = at,
    }, 0);
}

fn paired(
    source: []const u8,
    token: Token,
    written: *u32,
    stream: *Terminators,
    position: u32,
) error{Overflow}!void {
    assert(position < stream.calls.count());
    assert(position < stream.closes.count());

    const called = stream.calls.get(position);
    const counted = stream.closes.get(position);
    const calls = called & ~calls_after;
    const after = called & calls_after != 0;

    assert(calls < calls_after);
    assert(token.end() <= source.len);

    for (0..if (after) 0 else calls) |_| {
        try invoked(source, token, written, stream);
    }

    for (0..counted) |_| {
        try closing(source, token, written, stream);
    }

    for (0..if (after) calls else 0) |_| {
        try invoked(source, token, written, stream);
    }
}

fn invoked(
    source: []const u8,
    token: Token,
    written: *u32,
    stream: *Terminators,
) error{Overflow}!void {
    assert(written.* <= token.end());
    assert(token.end() <= source.len);

    try stream.source.push(source[written.*..token.end()]);
    try stream.source.push(paren_open);
    try stream.source.push(paren_close);
    written.* = token.end();

    const at = stream.source.count() - 2;

    try held_pushed(stream, .{
        .kind = .{ .punctuation = .paren_open },
        .length = 1,
        .offset = at,
    }, 0);

    try held_pushed(stream, .{
        .kind = .{ .punctuation = .paren_close },
        .length = 1,
        .offset = at + 1,
    }, 0);
}

fn lifts(
    source: []const u8,
    token: Token,
    operator: Token,
    role: u16,
    written: *u32,
    stream: *Terminators,
) error{Overflow}!void {
    assert(written.* <= token.offset);
    assert(operator.end() <= source.len);
    assert(role & emitter_roles == 0);

    try stream.source.push(source[written.*..token.offset]);
    try stream.source.push(operator.text(source));
    try stream.source.push(" ");
    written.* = token.offset;

    const at = stream.source.count() - operator.length - 1;

    try held_pushed(stream, .{
        .kind = operator.kind,
        .length = operator.length,
        .offset = at,
    }, role);
}

fn trails(
    source: []const u8,
    token: Token,
    space: bool,
    operator: Token,
    role: u16,
    written: *u32,
    stream: *Terminators,
) error{Overflow}!void {
    assert(token.end() <= source.len);
    assert(operator.end() <= source.len);
    assert(role & emitter_roles == 0);

    if (written.* < token.end()) {
        try stream.source.push(source[written.*..token.end()]);
        written.* = token.end();
    }

    if (space) try stream.source.push(" ");

    try stream.source.push(operator.text(source));

    const at = stream.source.count() - operator.length;

    try held_pushed(stream, .{
        .kind = operator.kind,
        .length = operator.length,
        .offset = at,
    }, role);
}

fn separates(
    source: []const u8,
    token: Token,
    written: *u32,
    stream: *Terminators,
) error{Overflow}!void {
    assert(written.* <= token.end());
    assert(token.end() <= source.len);

    try stream.source.push(source[written.*..token.end()]);
    try stream.source.push(semicolon);
    written.* = token.end();

    const at = stream.source.count() - 1;

    try held_pushed(stream, .{
        .kind = .{ .punctuation = .semicolon },
        .length = 1,
        .offset = at,
    }, 0);
}

fn trivial(tokens: []const Token, from: u32, to: u32) bool {
    if (from > to) return false;

    assert(from <= to);
    assert(to <= tokens.len);

    for (tokens[from..to]) |token| {
        const blank = token.kind == .comment or token.kind == .newline or token.length == 0;
        if (!blank) return false;
    }

    return true;
}

fn flag_set(flags: []u16, position: usize, bit: u16) void {
    assert(bit != 0);
    assert(@popCount(bit) == 1);
    assert(flags.len <= std.math.maxInt(u32));
    assert(position < std.math.maxInt(u32));

    if (position < flags.len) flags[position] |= bit;
}

fn text_equal(source: []const u8, token: Token, text: []const u8) bool {
    assert(token.end() <= source.len);
    assert(text.len > 0);

    return std.mem.eql(u8, token.text(source), text);
}

fn dropped(
    comptime Kind: type,
    tree: *const TreeType(Kind),
    source: []const u8,
    tokens: []const Token,
    comptime rules: *const RulesType(Kind),
    flags: []u16,
) void {
    assert(source.len <= std.math.maxInt(u32));

    const nodes = tree.slice();

    assert(flags.len == tokens.len);
    assert(nodes.len < none);

    for (nodes, 0..) |*node, index| {
        if (!rules.parens(node.kind)) continue;
        if (node.parent == none) continue;
        if (node.child_first == none) continue;
        if (node.token_end == 0) continue;
        if (node.token_end > tokens.len) continue;
        if (!dropped_loose(Kind, nodes, source, tokens, rules, @intCast(index))) continue;

        flags[node.token_start] |= paren_drops;

        flags[node.token_end - 1] |= paren_drops;

        if (solo.led(Kind, nodes, source, tokens, rules, node)) |bar| flags[bar] |= paren_drops;
    }
}

fn dropped_loose(
    comptime Kind: type,
    nodes: []const NodeType(Kind),
    source: []const u8,
    tokens: []const Token,
    comptime rules: *const RulesType(Kind),
    index: u32,
) bool {
    assert(nodes.len <= std.math.maxInt(u32));
    assert(source.len <= std.math.maxInt(u32));
    assert(tokens.len <= std.math.maxInt(u32));
    assert(index < nodes.len);

    const node = &nodes[index];
    const direct = &nodes[node.child_first];
    const inner = paren_core(Kind, nodes, rules, direct);
    const standing = solo.raised(Kind, nodes, rules, index);
    const above = &nodes[nodes[standing].parent];
    const parent = above.kind;
    const first = above.child_first == standing;
    const imported = import_queries and import_queried(Kind, nodes, rules, &inner);
    const ancestor: ?Kind = if (above.parent == none) null else nodes[above.parent].kind;
    const wraps = rules.wraps(inner.kind, parent, ancestor, first) and !imported;

    const jumped = rules.jumps(inner.kind, parent) and
        jump_commented(source, tokens, node.token_start + 1, inner.token_start);

    assert(node.child_first != none);
    assert(node.token_end > 0);

    if (wraps) return false;
    if (arrow_body.kept(Kind, nodes, source, tokens, rules, index)) return false;
    if (jumped) return false;
    if (hole_kept(Kind, nodes, rules, index)) return false;
    if (chain_kept(Kind, nodes, source, tokens, rules, index, &inner)) return false;
    if (cast_led_kept(Kind, nodes, source, tokens, rules, index, &inner)) return false;
    if (let_led_kept(Kind, nodes, source, tokens, rules, index, &inner)) return false;
    if (default_led_kept(Kind, source, tokens, rules, node, &inner)) return false;
    if (let_word_kept(Kind, nodes, source, tokens, rules, index, &inner)) return false;
    if (assertion_target_kept(Kind, source, tokens, node, &inner)) return false;
    if (coalescing(Kind, nodes, source, tokens, rules, &inner, parent)) return false;
    if (dropped_hole(Kind, nodes, source, tokens, rules, index, &inner)) return false;

    const moved = moved_head(Kind, nodes, source, tokens, rules, index) != null;

    if (!moved) {
        if (dropped_kept(Kind, nodes, source, tokens, rules, index, &inner)) return false;
    }

    const open = node.token_start;
    const close = node.token_end - 1;
    if (!plain_pair(Kind, source, tokens, open, close, direct)) return false;
    if (cast.leads(source, tokens, open)) return false;
    if (moved) return true;
    return dropped_headed(Kind, nodes, source, tokens, rules, index, &inner);
}

fn hole_kept(
    comptime Kind: type,
    nodes: []const NodeType(Kind),
    comptime rules: *const RulesType(Kind),
    index: u32,
) bool {
    assert(rules.parens(nodes[index].kind));

    var held = nodes[index].parent;
    var depth: u32 = 0;

    assert(held != none);

    for (0..hole_depth) |_| {
        if (held == none) return false;

        const holed = rules.holes(nodes[held].kind);
        depth += if (holed == .listed) 2 else 1;

        if (depth >= hole_depth) return depth == hole_depth and holed == .hole;

        held = nodes[held].parent;
    }

    return false;
}

fn chain_kept(
    comptime Kind: type,
    nodes: []const NodeType(Kind),
    source: []const u8,
    tokens: []const Token,
    comptime rules: *const RulesType(Kind),
    index: u32,
    inner: *const NodeType(Kind),
) bool {
    assert(nodes.len <= std.math.maxInt(u32));
    assert(source.len <= std.math.maxInt(u32));
    assert(tokens.len <= std.math.maxInt(u32));
    assert(index < nodes.len);

    const node = &nodes[index];
    const above = &nodes[node.parent];

    assert(node.parent != none);
    assert(rules.parens(node.kind));

    if (rules.calls(above.kind)) {
        if (above.child_first != index) return false;
    } else {
        switch (rules.chains(above.kind)) {
            .call => if (chain_tagged(Kind, nodes, rules, above)) return false,
            .member, .subscript => {},
            .none, .optional, .template => return false,
        }

        if (chain_optional(Kind, nodes, source, tokens, rules, above)) return false;
    }

    return chain_optional_spine(Kind, nodes, source, tokens, rules, inner);
}

fn chain_optional(
    comptime Kind: type,
    nodes: []const NodeType(Kind),
    source: []const u8,
    tokens: []const Token,
    comptime rules: *const RulesType(Kind),
    node: *const NodeType(Kind),
) bool {
    assert(nodes.len <= std.math.maxInt(u32));
    assert(source.len <= std.math.maxInt(u32));
    assert(tokens.len <= std.math.maxInt(u32));

    var child = node.child_first;

    assert(rules.chains(node.kind) != .none);
    assert(rules.chains(node.kind) != .optional);

    if (child == none) return false;

    if (rules.chains(node.kind) == .call) {
        const after = following(tokens, nodes[child].token_end) orelse return false;
        if (text_equal(source, tokens[after], "?.")) return true;
    }

    for (0..list_item_max) |_| {
        if (child == none) return false;
        if (rules.chains(nodes[child].kind) == .optional) return true;

        assert(nodes[child].sibling_next == none or nodes[child].sibling_next < nodes.len);

        child = nodes[child].sibling_next;
    }

    return false;
}

fn chain_tagged(
    comptime Kind: type,
    nodes: []const NodeType(Kind),
    comptime rules: *const RulesType(Kind),
    node: *const NodeType(Kind),
) bool {
    assert(nodes.len <= std.math.maxInt(u32));

    var child = node.child_first;
    var last: u32 = none;

    assert(rules.chains(node.kind) == .call);

    for (0..list_item_max) |_| {
        if (child == none) break;

        last = child;
        child = nodes[child].sibling_next;
    }

    if (last == none) return false;

    assert(last < nodes.len);

    return rules.chains(nodes[last].kind) == .template;
}

fn chain_optional_spine(
    comptime Kind: type,
    nodes: []const NodeType(Kind),
    source: []const u8,
    tokens: []const Token,
    comptime rules: *const RulesType(Kind),
    inner: *const NodeType(Kind),
) bool {
    assert(nodes.len <= std.math.maxInt(u32));
    assert(source.len <= std.math.maxInt(u32));
    assert(tokens.len <= std.math.maxInt(u32));

    var held = inner.*;

    assert(held.token_start <= held.token_end);

    for (0..optional_walk_max) |_| {
        switch (rules.chains(held.kind)) {
            .call, .member, .subscript => {},
            .none, .optional, .template => return false,
        }

        if (chain_optional(Kind, nodes, source, tokens, rules, &held)) return true;
        if (held.child_first == none) return false;

        assert(held.child_first < nodes.len);

        held = nodes[held.child_first];
    }

    return false;
}

fn cast_led_kept(
    comptime Kind: type,
    nodes: []const NodeType(Kind),
    source: []const u8,
    tokens: []const Token,
    comptime rules: *const RulesType(Kind),
    index: u32,
    inner: *const NodeType(Kind),
) bool {
    assert(nodes.len <= std.math.maxInt(u32));
    assert(index < nodes.len);

    const node = &nodes[index];

    assert(node.parent != none);
    assert(rules.parens(node.kind));

    if (!rules.casts(nodes[node.parent].kind)) return false;
    if (nodes[node.parent].child_first != index) return false;
    if (inner.token_end != inner.token_start + 1) return false;
    if (!cast_led_word(source, tokens[inner.token_start])) return false;

    var held = node.parent;

    for (0..statement_walk_max) |_| {
        const parent = nodes[held].parent;
        if (parent == none) return false;
        if (rules.statements(nodes[parent].kind)) return true;
        if (nodes[parent].child_first != held) return false;

        const cast_link = rules.casts(nodes[parent].kind) or rules.parens(nodes[parent].kind);
        if (!cast_link) return false;

        held = parent;
    }

    return false;
}

fn default_led_kept(
    comptime Kind: type,
    source: []const u8,
    tokens: []const Token,
    comptime rules: *const RulesType(Kind),
    node: *const NodeType(Kind),
    inner: *const NodeType(Kind),
) bool {
    const open = node.token_start;

    assert(open < tokens.len);
    assert(inner.token_start < tokens.len);

    if (open == 0) return false;
    if (!text_equal(source, tokens[open - 1], "default")) return false;
    if (rules.defaults(inner.kind)) return true;

    const lead = inner.token_start;
    if (text_equal(source, tokens[lead], "function")) return true;
    if (text_equal(source, tokens[lead], "class")) return true;
    if (!text_equal(source, tokens[lead], "async")) return false;
    if (lead + 1 >= tokens.len) return false;
    return text_equal(source, tokens[lead + 1], "function");
}

fn let_word_kept(
    comptime Kind: type,
    nodes: []const NodeType(Kind),
    source: []const u8,
    tokens: []const Token,
    comptime rules: *const RulesType(Kind),
    index: u32,
    inner: *const NodeType(Kind),
) bool {
    assert(nodes.len <= std.math.maxInt(u32));
    assert(index < nodes.len);

    const node = &nodes[index];
    const lead = inner.token_start;

    assert(lead < tokens.len);
    assert(node.token_end > 0);

    if (!text_equal(source, tokens[lead], "let")) return false;
    if (for_headed(source, tokens, node.token_start)) return true;

    if (inner.token_end == lead + 1) {
        const after = following(tokens, node.token_end) orelse return false;
        return text_equal(source, tokens[after], "of");
    }

    const next = following(tokens, lead + 1) orelse return false;
    if (!text_equal(source, tokens[next], "[")) return false;
    return statement_leading(Kind, nodes, rules, index);
}

fn for_headed(source: []const u8, tokens: []const Token, open: u32) bool {
    assert(open < tokens.len);
    assert(tokens[open].is_punctuation(.paren_open));

    const head = preceding(tokens, open) orelse return false;
    if (!tokens[head].is_punctuation(.paren_open)) return false;

    const word = preceding(tokens, head) orelse return false;
    if (text_equal(source, tokens[word], "for")) return true;
    return text_equal(source, tokens[word], "await");
}

fn assertion_target_kept(
    comptime Kind: type,
    source: []const u8,
    tokens: []const Token,
    node: *const NodeType(Kind),
    inner: *const NodeType(Kind),
) bool {
    const after = node.token_end;

    assert(after > 0);
    assert(inner.token_start < tokens.len);

    if (!text_equal(source, tokens[inner.token_start], "<")) return false;
    if (after >= tokens.len) return false;

    const text = tokens[after].text(source);

    for (assignment_operators) |operator| {
        if (std.mem.eql(u8, text, operator)) return true;
    }

    return false;
}

fn let_led_kept(
    comptime Kind: type,
    nodes: []const NodeType(Kind),
    source: []const u8,
    tokens: []const Token,
    comptime rules: *const RulesType(Kind),
    index: u32,
    inner: *const NodeType(Kind),
) bool {
    assert(nodes.len <= std.math.maxInt(u32));
    assert(index < nodes.len);

    const node = &nodes[index];
    const above = &nodes[node.parent];

    assert(node.parent != none);
    assert(rules.parens(node.kind));

    if (above.child_first != index) return false;
    if (inner.token_end != inner.token_start + 1) return false;
    if (!text_equal(source, tokens[inner.token_start], "let")) return false;

    const subscripted = switch (rules.chains(above.kind)) {
        .subscript => true,
        .call, .member => false,
        .none, .optional, .template => return false,
    };

    const head = let_led_head(Kind, nodes, rules, node.parent) orelse return false;
    const first = nodes[head].child_first;
    if (first == none) return false;
    if (!let_led_first(tokens, nodes[first].token_start, node.token_start)) return false;
    if (rules.statements(nodes[head].kind)) return subscripted;
    if (rules.initializers(nodes[head].kind) != .head) return false;
    if (subscripted) return true;

    const after = following(tokens, nodes[first].token_end) orelse return false;
    return text_equal(source, tokens[after], "of");
}

fn let_led_first(tokens: []const Token, from: u32, to: u32) bool {
    assert(to < tokens.len);
    assert(tokens[to].is_punctuation(.paren_open));

    if (from > to) return false;

    for (from..to) |scan| {
        const kind = tokens[scan].kind;
        const blank = kind == .comment or kind == .newline or tokens[scan].length == 0;
        if (blank) continue;
        if (!tokens[scan].is_punctuation(.paren_open)) return false;
    }

    return true;
}

fn let_led_head(
    comptime Kind: type,
    nodes: []const NodeType(Kind),
    comptime rules: *const RulesType(Kind),
    start: u32,
) ?u32 {
    assert(start < nodes.len);

    var held = start;

    assert(!rules.parens(nodes[start].kind));

    for (0..let_walk_max) |_| {
        const parent = nodes[held].parent;
        if (parent == none) return null;
        if (rules.initializers(nodes[parent].kind) != .none) return parent;

        held = parent;
    }

    return null;
}

fn cast_led_word(source: []const u8, token: Token) bool {
    assert(token.end() <= source.len);
    assert(cast_led_words.len > 0);

    for (cast_led_words) |word| {
        if (text_equal(source, token, word)) return true;
    }

    return false;
}

fn moved_head(
    comptime Kind: type,
    nodes: []const NodeType(Kind),
    source: []const u8,
    tokens: []const Token,
    comptime rules: *const RulesType(Kind),
    index: u32,
) ?u32 {
    assert(index < nodes.len);
    assert(source.len <= std.math.maxInt(u32));
    assert(tokens.len <= std.math.maxInt(u32));

    const node = &nodes[index];

    assert(rules.parens(node.kind));

    if (node.parent == none) return null;
    if (node.child_first == none) return null;

    if (rules.arrows(nodes[node.parent].kind)) {
        if (node.sibling_next == none) {
            if (!nodes[node.child_first].kind.is_node()) return null;
            if (!arrow_body.passes(Kind, rules, nodes[node.child_first].kind)) return null;
            return arrow_body.led(Kind, nodes, source, tokens, rules, node.child_first);
        }
    }

    if (!statement_leading(Kind, nodes, rules, index)) return null;

    var held = node.child_first;
    if (!nodes[held].kind.is_node()) return null;
    if (!rules.passes(nodes[held].kind)) return null;

    for (0..statement_walk_max) |_| {
        const head = nodes[held].child_first;
        if (head == none) return null;
        if (!nodes[head].kind.is_node()) return null;
        if (rules.leads(nodes[head].kind)) return head;
        if (!rules.passes(nodes[head].kind)) return null;

        held = head;
    }

    return null;
}

fn statement_leading(
    comptime Kind: type,
    nodes: []const NodeType(Kind),
    comptime rules: *const RulesType(Kind),
    index: u32,
) bool {
    assert(index < nodes.len);
    assert(rules.parens(nodes[index].kind));

    var held = index;

    for (0..statement_walk_max) |_| {
        const parent = nodes[held].parent;
        if (parent == none) return false;
        if (nodes[parent].child_first != held) return false;
        if (rules.statements(nodes[parent].kind)) return true;
        if (!rules.passes(nodes[parent].kind)) return false;

        held = parent;
    }

    return false;
}

fn moved_wrapped(
    comptime Kind: type,
    nodes: []const NodeType(Kind),
    source: []const u8,
    tokens: []const Token,
    comptime rules: *const RulesType(Kind),
    index: u32,
) bool {
    assert(index < nodes.len);
    assert(source.len <= std.math.maxInt(u32));
    assert(tokens.len <= std.math.maxInt(u32));

    const node = &nodes[index];

    assert(node.token_start <= node.token_end);

    if (!node.kind.is_node()) return false;
    if (!rules.leads(node.kind)) return false;

    var held = index;

    for (0..statement_walk_max) |_| {
        const parent = nodes[held].parent;
        if (parent == none) return false;
        if (nodes[parent].child_first != held) return false;

        if (rules.parens(nodes[parent].kind)) {
            if (held == index) return false;
            if (moved_head(Kind, nodes, source, tokens, rules, parent) != index) return false;
            return dropped_loose(Kind, nodes, source, tokens, rules, parent);
        }

        if (!rules.passes(nodes[parent].kind)) return false;

        held = parent;
    }

    return false;
}

fn dropped_hole(
    comptime Kind: type,
    nodes: []const NodeType(Kind),
    source: []const u8,
    tokens: []const Token,
    comptime rules: *const RulesType(Kind),
    index: u32,
    inner: *const NodeType(Kind),
) bool {
    assert(nodes.len <= std.math.maxInt(u32));
    assert(source.len <= std.math.maxInt(u32));
    assert(tokens.len <= std.math.maxInt(u32));
    assert(index < nodes.len);

    const node = &nodes[index];

    assert(node.parent != none);
    assert(inner.token_start <= inner.token_end);

    if (!hole_ternaries) return false;
    if (!rules.branches(inner.kind)) return false;
    if (!hole_seated(Kind, nodes, rules, index, &nodes[node.parent])) return false;
    return hole_flat(Kind, nodes, source, tokens, node.parent);
}

fn dropped_kept(
    comptime Kind: type,
    nodes: []const NodeType(Kind),
    source: []const u8,
    tokens: []const Token,
    comptime rules: *const RulesType(Kind),
    index: u32,
    inner: *const NodeType(Kind),
) bool {
    assert(nodes.len <= std.math.maxInt(u32));
    assert(source.len <= std.math.maxInt(u32));
    assert(tokens.len <= std.math.maxInt(u32));
    assert(index < nodes.len);

    const node = &nodes[index];
    const standing = solo.raised(Kind, nodes, rules, index);
    const above = &nodes[nodes[standing].parent];
    const first = above.child_first == standing;
    const head: ?Kind = if (inner.child_first == none) null else nodes[inner.child_first].kind;
    const imported = import_queries and import_queried(Kind, nodes, rules, inner);
    var heads = heads_of(Kind, nodes, rules, above, standing);

    assert(node.parent != none);
    assert(above.child_first != none);

    heads.plain = plain_lead(Kind, source, tokens, inner);
    heads.called = callees_new and chain_called(Kind, nodes, rules, inner);
    heads.decorated = decorator_plain(Kind, source, tokens, &nodes[node.child_first]);

    const pair: PlacedType(Kind) = .{ .node = node, .inner = inner, .above = above };
    const placed = pair_placed(Kind, nodes, source, tokens, rules, &pair, first);
    if (placed) |kept| return kept;
    if (imported) return false;
    if (rules.drops(inner.kind, above.kind, head, heads, first)) return false;
    return !nested(Kind, nodes, source, tokens, rules, node, inner);
}

fn dropped_headed(
    comptime Kind: type,
    nodes: []const NodeType(Kind),
    source: []const u8,
    tokens: []const Token,
    comptime rules: *const RulesType(Kind),
    index: u32,
    inner: *const NodeType(Kind),
) bool {
    assert(nodes.len <= std.math.maxInt(u32));
    assert(source.len <= std.math.maxInt(u32));
    assert(tokens.len <= std.math.maxInt(u32));
    assert(index < nodes.len);

    const node = &nodes[index];
    const open = node.token_start;
    const close = node.token_end - 1;
    const parent = nodes[node.parent].kind;
    const chained = if (chain_heads) chain_head(Kind, nodes, rules, inner) else inner.child_first;

    const head_wraps = braced_heads and chained != none and
        wrapped(Kind, nodes, rules, chained, &nodes[chained]);

    const head: ?Kind = if (inner.child_first == none) null else nodes[inner.child_first].kind;

    const brace_led = rules.braced(parent) and !head_wraps and
        text_equal(source, tokens[inner.token_start], "{");

    assert(open < close);
    assert(close < tokens.len);

    if (brace_led) return false;

    const comment_led = led_commented(source, tokens, open, close);
    const comment_closed = closed_commented(source, tokens, open, close);
    const lined_from = if (comment_led) inner.token_start else open;
    const lined_to = if (comment_closed) inner.token_end - 1 else close;
    const span = source[tokens[lined_from].offset..tokens[lined_to].end()];
    const lined_span = std.mem.findScalar(u8, span, '\n') != null;

    const kept = lined_span and !(chain_heads and head_wraps) and
        !rules.spans(inner.kind, parent, head);

    return !kept;
}

fn signed(
    comptime Kind: type,
    nodes: []const NodeType(Kind),
    source: []const u8,
    tokens: []const Token,
    comptime rules: *const RulesType(Kind),
    pair: *const PlacedType(Kind),
    first: bool,
) ?bool {
    assert(nodes.len <= std.math.maxInt(u32));
    assert(source.len <= std.math.maxInt(u32));
    assert(tokens.len <= std.math.maxInt(u32));

    const inner = pair.inner;
    const above = pair.above;

    if (inner.token_end <= inner.token_start) return null;
    if (above.token_end <= above.token_start) return null;

    const operator = signed_operator(Kind, nodes, tokens, rules, above) orelse return null;
    const lead = tokens[inner.token_start].text(source);
    const text = operator_text(source, tokens, operator);

    assert(inner.token_start < tokens.len);
    assert(operator < tokens.len);

    return rules.signs(inner.kind, above.kind, lead, text, first);
}

fn signed_operator(
    comptime Kind: type,
    nodes: []const NodeType(Kind),
    tokens: []const Token,
    comptime rules: *const RulesType(Kind),
    above: *const NodeType(Kind),
) ?u32 {
    assert(above.token_start < above.token_end);
    assert(above.token_end <= tokens.len);
    assert(nodes.len <= std.math.maxInt(u32));

    if (rules.unaries(above.kind)) return above.token_start;
    if (rules.mixes(above.kind)) return operator_of(Kind, nodes, tokens, above);
    return null;
}

fn plain_lead(
    comptime Kind: type,
    source: []const u8,
    tokens: []const Token,
    inner: *const NodeType(Kind),
) bool {
    if (inner.token_end <= inner.token_start) return false;
    assert(source.len <= std.math.maxInt(u32));
    assert(tokens.len <= std.math.maxInt(u32));

    const text = tokens[inner.token_start].text(source);
    const leads = [_][]const u8{ "async", "class", "function", "let", "{" };

    assert(inner.token_start < tokens.len);

    assert(text.len == tokens[inner.token_start].length);

    for (leads) |lead| {
        if (std.mem.eql(u8, text, lead)) return false;
    }

    return true;
}

fn decorator_plain(
    comptime Kind: type,
    source: []const u8,
    tokens: []const Token,
    inner: *const NodeType(Kind),
) bool {
    assert(source.len <= std.math.maxInt(u32));

    const start = inner.token_start;
    const end = inner.token_end;

    assert(start <= end);
    assert(end <= tokens.len);

    if (end <= start) return false;
    if (tokens[start].kind != .identifier) return false;

    var at = start + 1;
    const dotted_next = at + 1 < end and text_equal(source, tokens[at], ".");

    if (dotted_next) {
        const name = tokens[at + 1];

        const named = name.kind == .identifier or name.kind == .keyword or
            std.mem.startsWith(u8, name.text(source), "#");

        if (!named) return false;

        at += 2;
    }

    if (at == end) return true;
    if (!tokens[at].is_punctuation(.paren_open)) return false;
    return decorator_argued(tokens, at, end);
}

fn decorator_argued(tokens: []const Token, open: u32, end: u32) bool {
    var depth: u32 = 0;

    assert(open < end);
    assert(end <= tokens.len);

    for (open..end) |scan| {
        const token = tokens[scan];

        if (walk.is_open(token.kind)) depth += 1;

        if (walk.is_close(token.kind)) {
            if (depth == 0) return false;

            depth -= 1;

            if (depth == 0) return scan + 1 == end;
        }
    }

    return false;
}

fn plain_pair(
    comptime Kind: type,
    source: []const u8,
    tokens: []const Token,
    open: u32,
    close: u32,
    inner: *const NodeType(Kind),
) bool {
    assert(open < close);
    assert(close < tokens.len);

    if (!trivial(tokens, open + 1, inner.token_start)) return false;
    if (!trivial(tokens, inner.token_end, close)) return false;
    if (!text_equal(source, tokens[open], "(")) return false;
    return text_equal(source, tokens[close], ")");
}

fn paren_core(
    comptime Kind: type,
    nodes: []const NodeType(Kind),
    comptime rules: *const RulesType(Kind),
    node: *const NodeType(Kind),
) NodeType(Kind) {
    assert(nodes.len <= std.math.maxInt(u32));

    var core = node.*;

    for (0..paren_nest_max) |_| {
        if (!nested_parens) break;

        if (!rules.parens(core.kind)) {
            if (!solo.holds(Kind, nodes, rules, &core)) break;
        }

        if (core.child_first == none) break;

        assert(core.child_first < nodes.len);

        core = nodes[core.child_first];
    }

    assert(core.token_start <= core.token_end);

    return core;
}

fn operator_text(source: []const u8, tokens: []const Token, at: u32) []const u8 {
    assert(at < tokens.len);
    assert(tokens[at].end() <= source.len);

    if (!operator_runs) return tokens[at].text(source);

    var last = at;

    for (at + 1..tokens.len) |index| {
        const next = tokens[index];

        if (!text_equal(source, tokens[last], ">")) break;
        if (!text_equal(source, next, ">")) break;
        if (tokens[last].end() != next.offset) break;

        last += 1;
    }

    return source[tokens[at].offset..tokens[last].end()];
}

fn nested_operand(
    comptime Kind: type,
    nodes: []const NodeType(Kind),
    source: []const u8,
    tokens: []const Token,
    comptime rules: *const RulesType(Kind),
    node: *const NodeType(Kind),
) bool {
    if (!rules.mixes(node.kind)) return false;
    if (node.parent == none) return false;
    if (node.token_end == 0) return false;
    assert(nodes.len <= std.math.maxInt(u32));
    assert(source.len <= std.math.maxInt(u32));
    assert(tokens.len <= std.math.maxInt(u32));

    const parent = &nodes[node.parent];
    if (!rules.mixes(parent.kind)) return false;

    const above = operator_of(Kind, nodes, tokens, parent) orelse return false;
    const held = operator_of(Kind, nodes, tokens, node) orelse return false;
    const outer = operator_text(source, tokens, above);

    assert(above < tokens.len);
    assert(held < tokens.len);

    return !rules.nests(outer, operator_text(source, tokens, held), node.token_start > above);
}

fn hole_ternary(
    comptime Kind: type,
    nodes: []const NodeType(Kind),
    source: []const u8,
    tokens: []const Token,
    comptime rules: *const RulesType(Kind),
    index: u32,
    node: *const NodeType(Kind),
) bool {
    assert(index < nodes.len);
    assert(node.token_start <= node.token_end);

    if (!rules.branches(node.kind)) return false;
    if (node.parent == none) return false;
    if (node.token_end == 0) return false;
    if (!hole_seated(Kind, nodes, rules, index, &nodes[node.parent])) return false;
    assert(source.len <= std.math.maxInt(u32));
    assert(tokens.len <= std.math.maxInt(u32));

    return hole_flat(Kind, nodes, source, tokens, node.parent);
}

fn hole_seated(
    comptime Kind: type,
    nodes: []const NodeType(Kind),
    comptime rules: *const RulesType(Kind),
    at: u32,
    parent: *const NodeType(Kind),
) bool {
    assert(at < nodes.len);

    const body = rules.arrows(parent.kind) and child_last(Kind, nodes, parent) == at;

    assert(parent.child_first != none);

    if (body) return true;
    if (!rules.branches(parent.kind)) return false;

    const second = nodes[parent.child_first].sibling_next;
    if (second != at) return false;

    const third = nodes[second].sibling_next;
    if (third == none) return false;
    return nodes[third].sibling_next == none;
}

fn hole_flat(
    comptime Kind: type,
    nodes: []const NodeType(Kind),
    source: []const u8,
    tokens: []const Token,
    from: u32,
) bool {
    assert(source.len <= std.math.maxInt(u32));
    assert(from == none or from < nodes.len);

    var above = from;

    assert(tokens.len < none);

    for (0..hole_walk_max) |_| {
        if (above == none) return false;

        const held = &nodes[above];
        const holed = held.token_end > 0 and text_equal(source, tokens[held.token_start], "${");
        if (holed) return !spans_lines(source, tokens, held.token_start, held.token_end);

        above = held.parent;
    }

    return false;
}

fn parted_after(
    comptime Kind: type,
    source: []const u8,
    tokens: []const Token,
    node: *const NodeType(Kind),
) bool {
    if (node.token_end == 0) return false;
    if (node.token_end > tokens.len) return false;

    const end = tokens[node.token_end - 1].end();

    assert(end <= source.len);
    assert(node.token_end <= tokens.len);

    for (tokens[node.token_end..]) |token| {
        if (token.kind == .newline) continue;
        if (token.length == 0) continue;
        return std.mem.findScalar(u8, source[end..token.offset], '\n') != null;
    }

    return false;
}

fn nested(
    comptime Kind: type,
    nodes: []const NodeType(Kind),
    source: []const u8,
    tokens: []const Token,
    comptime rules: *const RulesType(Kind),
    node: *const NodeType(Kind),
    inner: *const NodeType(Kind),
) bool {
    if (!rules.mixes(inner.kind)) return false;
    if (node.parent == none) return false;
    assert(nodes.len <= std.math.maxInt(u32));
    assert(source.len <= std.math.maxInt(u32));
    assert(tokens.len <= std.math.maxInt(u32));

    const parent = &nodes[node.parent];
    if (!rules.mixes(parent.kind)) return false;

    const above = operator_of(Kind, nodes, tokens, parent) orelse return false;
    const held = operator_of(Kind, nodes, tokens, inner) orelse return false;
    const outer = operator_text(source, tokens, above);

    assert(above < tokens.len);
    assert(held < tokens.len);

    return rules.nests(outer, operator_text(source, tokens, held), node.token_start > above);
}

fn chain_head(
    comptime Kind: type,
    nodes: []const NodeType(Kind),
    comptime rules: *const RulesType(Kind),
    node: *const NodeType(Kind),
) u32 {
    var head = node.child_first;

    assert(head == none or head < nodes.len);

    for (0..chain_head_max) |_| {
        if (head == none) break;
        if (rules.parens(node.kind)) break;
        if (!chained_kinds(Kind, rules, nodes[head].kind, node.kind)) break;

        head = nodes[head].child_first;
    }

    assert(head == none or head < nodes.len);

    return head;
}

fn chained_kinds(
    comptime Kind: type,
    comptime rules: *const RulesType(Kind),
    inner: Kind,
    outer: Kind,
) bool {
    assert(inner.is_node());
    assert(outer.is_node());

    const result = inner == outer or (cast_chains and rules.casts(inner) and rules.casts(outer));

    if (inner == outer) assert(result);
    if (!result) assert(inner != outer);

    return result;
}

fn called_bare(
    comptime Kind: type,
    nodes: []const NodeType(Kind),
    source: []const u8,
    tokens: []const Token,
    node: *const NodeType(Kind),
) bool {
    assert(node.token_end > 0);
    assert(node.child_first == none or node.child_first < nodes.len);
    assert(source.len <= std.math.maxInt(u32));

    if (node.child_first != none) {
        const callee = &nodes[node.child_first];

        const parenthesized = callee_parens and callee.sibling_next == none and
            callee.token_end == node.token_end;

        if (parenthesized) return true;
    }

    const last = node.token_end - 1;
    if (last >= tokens.len) return false;
    return !text_equal(source, tokens[last], ")");
}

fn ended(
    comptime Kind: type,
    tree: *const TreeType(Kind),
    source: []const u8,
    tokens: []const Token,
    comptime rules: *const RulesType(Kind),
    flags: []u16,
    pairs: *const Pairs,
) void {
    assert(source.len <= std.math.maxInt(u32));
    assert(flags.len == tokens.len);

    const nodes = tree.slice();
    const marks: Marks = .{ .flags = flags, .pairs = pairs };

    assert(pairs.opens.len == tokens.len);

    for (0..nodes.len) |index| {
        ended_node(Kind, nodes, source, tokens, rules, @intCast(index), &marks);
    }
}

fn ended_node(
    comptime Kind: type,
    nodes: []const NodeType(Kind),
    source: []const u8,
    tokens: []const Token,
    comptime rules: *const RulesType(Kind),
    index: u32,
    marks: *const Marks,
) void {
    assert(nodes.len <= std.math.maxInt(u32));
    assert(source.len <= std.math.maxInt(u32));
    assert(tokens.len <= std.math.maxInt(u32));
    assert(index < nodes.len);

    const node = &nodes[index];
    const pairs = marks.pairs;

    const wrapping = (wrapped(Kind, nodes, rules, index, node) or
        moved_wrapped(Kind, nodes, source, tokens, rules, index) or
        default_wrapped(Kind, nodes, source, tokens, rules, node) or
        jump_wrap.led(Kind, nodes, source, tokens, rules, index)) and
        !lone_separated(Kind, nodes, source, tokens, node);

    const asied = wrapping and rules.bodies(node.kind) and
        parted_after(Kind, source, tokens, node);

    assert(node.token_start <= node.token_end);
    assert(pairs.closes.len == tokens.len);

    if (asied) flag_set(marks.flags, node.token_end - 1, end_owed);

    const counted = (wrapping and !asied) or
        ended_paren(Kind, nodes, source, tokens, rules, index);

    if (counted) {
        const fits = node.token_end > 0 and node.token_start < pairs.opens.len and
            node.token_end - 1 < pairs.closes.len;

        if (!fits) return;

        pairs.opens[cast.opened(source, tokens, node.token_start)] += 1;
        pairs.closes[node.token_end - 1] += 1;
    }

    ended_marks(Kind, nodes, source, tokens, rules, index, marks);
}

fn default_wrapped(
    comptime Kind: type,
    nodes: []const NodeType(Kind),
    source: []const u8,
    tokens: []const Token,
    comptime rules: *const RulesType(Kind),
    node: *const NodeType(Kind),
) bool {
    assert(node.token_start <= node.token_end);
    assert(nodes.len < none);

    if (node.parent == none) return false;
    if (node.token_start >= tokens.len) return false;
    if (!rules.defaults(node.kind)) return false;
    if (rules.parens(nodes[node.parent].kind)) return false;

    const word = preceding(tokens, node.token_start) orelse return false;
    if (!text_equal(source, tokens[word], "default")) return false;

    const exported = preceding(tokens, word) orelse return false;
    return text_equal(source, tokens[exported], "export");
}

fn ended_paren(
    comptime Kind: type,
    nodes: []const NodeType(Kind),
    source: []const u8,
    tokens: []const Token,
    comptime rules: *const RulesType(Kind),
    index: u32,
) bool {
    assert(index < nodes.len);
    assert(source.len <= std.math.maxInt(u32));
    assert(tokens.len <= std.math.maxInt(u32));

    const node = &nodes[index];

    assert(node.token_start <= node.token_end);

    const nests = nests_parens and nested_operand(Kind, nodes, source, tokens, rules, node);
    if (nests) return true;
    if (loop_tested(Kind, nodes, tokens, rules, node.kind, node) orelse false) return true;

    const hole = hole_ternaries and hole_ternary(Kind, nodes, source, tokens, rules, index, node);
    if (hole) return true;
    if (mixed(Kind, nodes, source, tokens, rules, node)) return true;
    return coalesced(Kind, nodes, source, tokens, rules, node);
}

fn ended_marks(
    comptime Kind: type,
    nodes: []const NodeType(Kind),
    source: []const u8,
    tokens: []const Token,
    comptime rules: *const RulesType(Kind),
    index: u32,
    marks: *const Marks,
) void {
    assert(nodes.len <= std.math.maxInt(u32));
    assert(source.len <= std.math.maxInt(u32));
    assert(tokens.len <= std.math.maxInt(u32));
    assert(index < nodes.len);

    const node = &nodes[index];
    const flags = marks.flags;
    const calls = marks.pairs.calls;

    const bare = call_parens and rules.calls(node.kind) and node.token_end > 0 and
        called_bare(Kind, nodes, source, tokens, node);

    const call_fits = bare and node.token_end - 1 < calls.len;

    assert(calls.len == tokens.len);
    assert(flags.len == tokens.len);

    if (call_fits) {
        const call_at = &calls[node.token_end - 1];

        call_at.* = (call_at.* + 1) | callee_flags(Kind, nodes, rules, node);
    }

    if (rules.opens(node.kind)) flag_set(flags, node.token_start, jsx_opens);

    if (rules.names(node.kind)) {
        for (node.token_start..node.token_end) |position| {
            flag_set(flags, position, name_words);
        }
    }

    if (rules.operators(node.kind)) operated(Kind, nodes, tokens, node, flags);
    if (rules.queries(node.kind)) queried(Kind, nodes, tokens, node, flags);
    if (node.token_end == 0) return;
    if (node.token_end > tokens.len) return;

    const parent = if (node.parent == none) node.kind else nodes[node.parent].kind;
    const listed = node.parent != none and rules.lists(parent) and node.sibling_next == none;
    const bodiless = rules.bodiless(node.kind) and tokens[node.token_end - 1].kind != .block_end;

    if (bodiless) {
        flag_set(flags, node.token_end - 1, end_owed);

        return;
    }

    const mark = ended_mark(Kind, rules, node.kind, parent, listed) orelse return;

    flag_set(flags, node.token_end - 1, mark);
}

fn ended_mark(
    comptime Kind: type,
    comptime rules: *const RulesType(Kind),
    kind: Kind,
    parent: Kind,
    listed: bool,
) ?u16 {
    assert(kind.is_node());
    assert(parent.is_node());

    if (rules.denies(kind, parent)) return end_denied;
    if (!rules.owes(kind, parent)) return null;
    if (listed) return null;

    assert(rules.owes(kind, parent));

    assert(!rules.denies(kind, parent));

    return end_owed;
}

fn separated(source: []const u8, tokens: []const Token, flags: []u16) void {
    assert(flags.len == tokens.len);
    assert(source.len < none);

    if (!comment_ends) return;

    for (tokens, 0..) |token, position| {
        if (!token.is_punctuation(.semicolon)) continue;
        if (flags[position] & paren_drops != 0) continue;

        const held = separated_held(source, tokens, flags, @intCast(position)) orelse continue;

        flags[position] |= paren_drops;

        flags[held - 1] |= end_owed;
    }
}

fn separated_held(
    source: []const u8,
    tokens: []const Token,
    flags: []const u16,
    position: u32,
) ?u32 {
    assert(source.len <= std.math.maxInt(u32));
    assert(position < tokens.len);

    var enclosed = false;
    var held = position;
    var stood = false;

    assert(flags.len == tokens.len);

    for (0..position) |_| {
        const before = tokens[held - 1];
        const drops_before = flags[held - 1] & paren_drops != 0;
        const skips = before.length == 0 or before.kind == .newline or drops_before;

        if (skips) {
            const closes = comment_enclosed and walk.is_close(before.kind) and drops_before;

            enclosed = enclosed or closes;
            held -= 1;

            continue;
        }

        if (before.kind != .comment) break;
        if (!stands(source, tokens, held - 1, enclosed)) break;

        held -= 1;
        stood = true;
    }

    if (!stood) return null;
    if (held == 0) return null;
    return held;
}

fn stands(source: []const u8, tokens: []const Token, position: u32, enclosed: bool) bool {
    assert(source.len <= std.math.maxInt(u32));
    assert(position < tokens.len);

    const token = tokens[position];
    const lined_comment = !enclosed and std.mem.startsWith(u8, token.text(source), "//");

    assert(token.kind == .comment);

    if (lined_comment) return true;

    var held = position;

    for (0..position) |_| {
        const before = tokens[held - 1];
        const skips = before.length == 0 or before.kind == .newline;

        if (skips) {
            held -= 1;

            continue;
        }

        return std.mem.findScalar(u8, source[before.end()..token.offset], '\n') != null;
    }

    return false;
}

fn operator_of(
    comptime Kind: type,
    nodes: []const NodeType(Kind),
    tokens: []const Token,
    node: *const NodeType(Kind),
) ?u32 {
    if (node.child_first == none) return null;
    assert(tokens.len <= std.math.maxInt(u32));
    if (node.child_first != none) assert(node.child_first < nodes.len);

    const start = nodes[node.child_first].token_end;
    const stop = @min(node.token_end, tokens.len);

    assert(node.child_first < nodes.len);

    assert(stop <= tokens.len);

    if (start >= stop) return null;

    for (start..stop) |scan| {
        if (tokens[scan].kind != .comment) {
            assert(scan < stop);

            return @intCast(scan);
        }
    }

    return null;
}

fn mixed(
    comptime Kind: type,
    nodes: []const NodeType(Kind),
    source: []const u8,
    tokens: []const Token,
    comptime rules: *const RulesType(Kind),
    node: *const NodeType(Kind),
) bool {
    if (!rules.mixes(node.kind)) return false;
    if (node.parent == none) return false;
    if (node.token_end == 0) return false;
    assert(nodes.len <= std.math.maxInt(u32));
    assert(source.len <= std.math.maxInt(u32));
    assert(tokens.len <= std.math.maxInt(u32));

    const parent = &nodes[node.parent];
    if (!rules.mixes(parent.kind)) return false;

    const inner = operator_of(Kind, nodes, tokens, node) orelse return false;
    const outer = operator_of(Kind, nodes, tokens, parent) orelse return false;
    const held = tokens[inner].text(source);
    const above = tokens[outer].text(source);

    assert(inner < tokens.len);
    assert(outer < tokens.len);

    return logical(held) and logical(above) and !std.mem.eql(u8, held, above);
}

fn coalescing(
    comptime Kind: type,
    nodes: []const NodeType(Kind),
    source: []const u8,
    tokens: []const Token,
    comptime rules: *const RulesType(Kind),
    inner: *const NodeType(Kind),
    parent: Kind,
) bool {
    assert(inner.token_start <= inner.token_end);
    assert(tokens.len < none);

    if (!coalesce_parens) return false;
    if (!rules.mixes(inner.kind)) return false;
    if (!rules.branches(parent)) return false;
    assert(nodes.len <= std.math.maxInt(u32));
    assert(source.len <= std.math.maxInt(u32));

    const held = operator_of(Kind, nodes, tokens, inner) orelse return false;
    return text_equal(source, tokens[held], "??");
}

fn coalesced(
    comptime Kind: type,
    nodes: []const NodeType(Kind),
    source: []const u8,
    tokens: []const Token,
    comptime rules: *const RulesType(Kind),
    node: *const NodeType(Kind),
) bool {
    assert(node.token_start <= node.token_end);
    assert(tokens.len < none);

    if (!coalesce_parens) return false;
    if (!rules.mixes(node.kind)) return false;
    if (node.parent == none) return false;
    if (node.token_end == 0) return false;
    if (!rules.branches(nodes[node.parent].kind)) return false;
    assert(source.len <= std.math.maxInt(u32));

    const inner = operator_of(Kind, nodes, tokens, node) orelse return false;
    return text_equal(source, tokens[inner], "??");
}

fn heads_a_statement(
    comptime Kind: type,
    nodes: []const NodeType(Kind),
    comptime rules: *const RulesType(Kind),
    index: u32,
    body: bool,
) bool {
    assert(index < nodes.len);

    var held = index;

    assert(nodes.len < none);

    for (0..statement_walk_max) |_| {
        const node = &nodes[held];
        if (node.parent == none) return false;

        const parent = &nodes[node.parent];
        if (rules.statements(parent.kind)) return parent.child_first == held;

        const arrowed = body and rules.arrows(parent.kind);
        if (arrowed) return node.sibling_next == none and parent.child_first != held;
        if (parent.child_first != held) return false;
        if (!rules.passes(parent.kind)) return false;

        held = node.parent;
    }

    return false;
}

fn pair_placed(
    comptime Kind: type,
    nodes: []const NodeType(Kind),
    source: []const u8,
    tokens: []const Token,
    comptime rules: *const RulesType(Kind),
    pair: *const PlacedType(Kind),
    first: bool,
) ?bool {
    assert(nodes.len <= std.math.maxInt(u32));
    assert(source.len <= std.math.maxInt(u32));
    assert(tokens.len <= std.math.maxInt(u32));

    const above = pair.above;

    const doubled = double_pairs and rules.parens(above.kind) and
        !header_paren(source, tokens, above.token_start);

    assert(pair.node.parent != none);
    assert(above.token_start <= pair.node.token_start);

    if (doubled) return false;
    if (loop_tested(Kind, nodes, tokens, rules, pair.inner.kind, pair.node)) |tested| return tested;
    return signed(Kind, nodes, source, tokens, rules, pair, first);
}

fn loop_tested(
    comptime Kind: type,
    nodes: []const NodeType(Kind),
    tokens: []const Token,
    comptime rules: *const RulesType(Kind),
    kind: Kind,
    node: *const NodeType(Kind),
) ?bool {
    assert(kind.is_node());

    var at = node.parent;

    assert(at == none or at < nodes.len);
    assert(tokens.len < none);

    if (!loop_tests) return null;

    for (0..loop_test_walk_max) |_| {
        if (at == none) return null;

        const above = &nodes[at];
        const tests = rules.tests(kind, above.kind) orelse return null;
        if (tests) return loop_clause(Kind, tokens, above, node) == 1;

        at = above.parent;
    }

    return null;
}

fn loop_clause(
    comptime Kind: type,
    tokens: []const Token,
    header: *const NodeType(Kind),
    node: *const NodeType(Kind),
) u32 {
    assert(tokens.len <= std.math.maxInt(u32));

    var count: u32 = 0;
    var depth: u32 = 0;

    assert(header.token_start <= header.token_end);
    assert(node.token_start <= node.token_end);

    if (header.token_start >= node.token_start) return 0;

    for (header.token_start..node.token_start) |position| {
        if (position >= tokens.len) break;

        const token = tokens[position];

        const opens = token.kind == .block_start or token.is_punctuation(.bracket_open) or
            token.is_punctuation(.paren_open);

        const closes = token.kind == .block_end or token.is_punctuation(.bracket_close) or
            token.is_punctuation(.paren_close);

        const clause = token.is_punctuation(.semicolon) and depth == 1;

        if (opens) depth += 1;
        if (closes) depth -|= 1;
        if (clause) count += 1;
    }

    return count;
}

fn lone_separated(
    comptime Kind: type,
    nodes: []const NodeType(Kind),
    source: []const u8,
    tokens: []const Token,
    node: *const NodeType(Kind),
) bool {
    assert(node.token_start <= node.token_end);
    assert(nodes.len < none);

    if (node.child_first == none) return false;
    if (nodes[node.child_first].sibling_next != none) return false;
    if (node.token_start >= tokens.len) return false;
    assert(source.len <= std.math.maxInt(u32));

    const lead = tokens[node.token_start].text(source);
    return std.mem.eql(u8, lead, "&") or std.mem.eql(u8, lead, "|");
}

fn wrapped(
    comptime Kind: type,
    nodes: []const NodeType(Kind),
    comptime rules: *const RulesType(Kind),
    index: u32,
    node: *const NodeType(Kind),
) bool {
    if (node.parent == none) return false;
    if (node.token_end == 0) return false;
    assert(index < none);
    assert(index < nodes.len);

    const imported = import_queries and import_queried(Kind, nodes, rules, node);
    if (imported) return false;

    const standing = solo.raised(Kind, nodes, rules, index);
    const first = nodes[nodes[standing].parent].child_first == standing;
    const at = wrapped_chain(Kind, nodes, rules, nodes[standing].parent, first);
    const parent = &nodes[at];
    const above = wrapped_above(Kind, nodes, rules, parent);
    const ancestor: ?Kind = if (above == none) null else nodes[above].kind;

    const callee = callees_new and first and rules.calls(parent.kind) and
        rules.links(node.kind) and chain_called(Kind, nodes, rules, node);

    assert(index < nodes.len);

    assert(at < nodes.len);

    if (callee) return true;
    return rules.wraps(node.kind, parent.kind, ancestor, first);
}

fn wrapped_chain(
    comptime Kind: type,
    nodes: []const NodeType(Kind),
    comptime rules: *const RulesType(Kind),
    from: u32,
    first: bool,
) u32 {
    assert(from < nodes.len);

    var at = from;

    assert(nodes.len < none);

    for (0..chain_head_max) |_| {
        const outer = nodes[at].parent;

        if (!chain_heads) break;
        if (!first) break;
        if (outer == none) break;
        if (rules.parens(nodes[at].kind)) break;
        if (!chained_kinds(Kind, rules, nodes[at].kind, nodes[outer].kind)) break;
        if (nodes[outer].child_first != at) break;

        at = outer;
    }

    return at;
}

fn wrapped_above(
    comptime Kind: type,
    nodes: []const NodeType(Kind),
    comptime rules: *const RulesType(Kind),
    node: *const NodeType(Kind),
) u32 {
    const above = node.parent;

    assert(above == none or above < nodes.len);
    assert(node.child_first != none);

    if (!paren_ancestors) return above;
    if (above == none) return above;
    if (rules.parens(node.kind)) return above;
    if (!rules.parens(nodes[above].kind)) return above;
    if (nodes[above].parent == none) return above;
    return nodes[above].parent;
}

fn callee_flags(
    comptime Kind: type,
    nodes: []const NodeType(Kind),
    comptime rules: *const RulesType(Kind),
    node: *const NodeType(Kind),
) u8 {
    assert(nodes.len < none);

    const called = (callees_new and callee_called(Kind, nodes, rules, node)) or
        (callee_wraps and callee_wrapped(Kind, nodes, rules, node));

    assert(node.token_start <= node.token_end);

    return if (called) calls_after else 0;
}

fn callee_wrapped(
    comptime Kind: type,
    nodes: []const NodeType(Kind),
    comptime rules: *const RulesType(Kind),
    node: *const NodeType(Kind),
) bool {
    if (node.child_first == none) return false;

    assert(node.child_first < nodes.len);
    assert(nodes[node.child_first].parent != none);

    return wrapped(Kind, nodes, rules, node.child_first, &nodes[node.child_first]);
}

fn callee_called(
    comptime Kind: type,
    nodes: []const NodeType(Kind),
    comptime rules: *const RulesType(Kind),
    node: *const NodeType(Kind),
) bool {
    if (node.child_first == none) return false;
    if (node.child_first != none) assert(node.child_first < nodes.len);

    const callee = &nodes[node.child_first];

    assert(node.child_first < nodes.len);

    assert(callee.parent != none);

    return rules.links(callee.kind) and chain_called(Kind, nodes, rules, callee);
}

fn chain_called(
    comptime Kind: type,
    nodes: []const NodeType(Kind),
    comptime rules: *const RulesType(Kind),
    inner: *const NodeType(Kind),
) bool {
    var held = inner.*;

    assert(inner.child_first == none or inner.child_first < nodes.len);
    assert(nodes.len < none);

    for (0..operand_walk_max) |_| {
        if (held.child_first == none) return false;

        const linking = rules.links(held.kind) or rules.parens(held.kind);
        if (!linking) return false;

        held = nodes[held.child_first];

        if (rules.invokes(held.kind)) return true;
    }

    return false;
}

fn import_queried(
    comptime Kind: type,
    nodes: []const NodeType(Kind),
    comptime rules: *const RulesType(Kind),
    node: *const NodeType(Kind),
) bool {
    var child = node.child_first;

    assert(child == none or child < nodes.len);
    assert(nodes.len < none);

    for (0..operand_walk_max) |_| {
        if (child == none) return false;

        const held = &nodes[child];

        const imports = held.child_first != none and
            rules.imports(node.kind, nodes[held.child_first].kind);

        if (imports) return true;

        child = held.sibling_next;
    }

    return false;
}

fn queried(
    comptime Kind: type,
    nodes: []const NodeType(Kind),
    tokens: []const Token,
    node: *const NodeType(Kind),
    flags: []u16,
) void {
    var child = node.child_first;

    assert(child == none or child < nodes.len);
    assert(flags.len == tokens.len);

    for (0..operand_walk_max) |_| {
        const next = if (child == none) none else nodes[child].sibling_next;
        if (next == none) return;

        spaced(tokens, nodes[child].token_end, nodes[next].token_start, flags);
        child = next;
    }
}

fn spaced(tokens: []const Token, from: u32, to: u32, flags: []u16) void {
    assert(flags.len == tokens.len);
    assert(from < none);
    assert(to < none);

    const stop = @min(to, tokens.len);

    assert(stop <= tokens.len);

    if (from >= stop) return;

    for (from..stop) |position| {
        if (tokens[position].kind == .comment) continue;

        flag_set(flags, position, operator_spaced);
    }
}

fn operated(
    comptime Kind: type,
    nodes: []const NodeType(Kind),
    tokens: []const Token,
    node: *const NodeType(Kind),
    flags: []u16,
) void {
    var before: u32 = none;
    var last = node.child_first;

    assert(last == none or last < nodes.len);
    assert(flags.len == tokens.len);

    for (0..operand_walk_max) |_| {
        if (last == none) break;
        if (nodes[last].sibling_next == none) break;

        before = last;
        last = nodes[last].sibling_next;
    }

    if (before == none) return;
    if (last == none) return;

    spaced(tokens, nodes[before].token_end, nodes[last].token_start, flags);
}

fn typed(
    comptime Kind: type,
    tree: *const TreeType(Kind),
    source: []const u8,
    tokens: []const Token,
    flags: []u16,
) void {
    assert(source.len <= std.math.maxInt(u32));
    assert(tokens.len <= std.math.maxInt(u32));

    const nodes = tree.slice();

    assert(tree.count() < none);
    assert(flags.len < none);

    for (nodes) |*node| {
        if (node.kind.category() != .type) {
            if (!import_typed(Kind, nodes, source, tokens, node)) continue;
        }

        flag_set(flags, node.token_start, type_nodes);
    }
}

fn import_typed(
    comptime Kind: type,
    nodes: []const NodeType(Kind),
    source: []const u8,
    tokens: []const Token,
    node: *const NodeType(Kind),
) bool {
    if (node.parent == none) return false;
    if (nodes[node.parent].kind.category() != .type) return false;
    if (node.token_start >= tokens.len) return false;
    assert(source.len <= std.math.maxInt(u32));

    return text_equal(source, tokens[node.token_start], "import");
}

fn grouping_close(source: []const u8, tokens: []const Token, close: u32) bool {
    assert(close < tokens.len);
    assert(tokens[close].end() <= source.len);

    if (!tokens[close].is_punctuation(.paren_close)) return false;
    if (close == 0) return true;

    const open = grouping_open(tokens, close) orelse return false;
    var before = open;

    for (0..open) |_| {
        before -= 1;

        const token = tokens[before];
        const blank = token.kind == .newline or token.length == 0 or token.kind == .comment;
        if (blank) continue;

        const operand = token.kind == .identifier or token.is_punctuation(.paren_close) or
            token.is_punctuation(.bracket_close) or std.mem.endsWith(u8, token.text(source), ">");

        return !operand;
    }

    return true;
}

fn grouping_open(tokens: []const Token, close: u32) ?u32 {
    assert(close > 0);

    var depth: u32 = 0;
    var scan = close;

    assert(tokens[close].is_punctuation(.paren_close));

    for (0..close) |_| {
        const token = tokens[scan];

        if (token.is_punctuation(.paren_close)) depth += 1;

        if (token.is_punctuation(.paren_open)) {
            depth -= 1;

            if (depth == 0) return scan;
        }

        scan -= 1;
    }

    return null;
}

fn hoisted(
    comptime Kind: type,
    tree: *const TreeType(Kind),
    source: []const u8,
    tokens: []const Token,
    comptime rules: *const RulesType(Kind),
    moves: []u8,
) void {
    assert(source.len <= std.math.maxInt(u32));

    const nodes = tree.slice();

    assert(moves.len == tokens.len);
    assert(nodes.len < none);

    if (!comment_hoists) return;

    for (nodes) |*node| {
        if (!rules.branches(node.kind)) continue;
        if (node.child_first == none) continue;

        var child = node.child_first;

        for (0..hoist_walk_max) |_| {
            const next = nodes[child].sibling_next;
            if (next == none) break;

            hoisted_gap(source, tokens, moves, nodes[child].token_end, nodes[next].token_start);
            child = next;
        }
    }
}

fn hoisted_gap(source: []const u8, tokens: []const Token, moves: []u8, from: u32, to: u32) void {
    assert(moves.len == tokens.len);
    assert(from <= tokens.len);
    assert(source.len <= std.math.maxInt(u32));
    assert(to < none);

    const operator = conditional_operator(source, tokens, from, to) orelse return;
    const first = comment_leading(source, tokens, from, operator) orelse return;
    if (!trivial(tokens, first, operator)) return;

    moves[first] = move_leads;
    moves[operator] = move_drops;
}

fn trailed(
    comptime Kind: type,
    tree: *const TreeType(Kind),
    source: []const u8,
    tokens: []const Token,
    comptime rules: *const RulesType(Kind),
    moves: []u8,
) void {
    assert(source.len <= std.math.maxInt(u32));

    const nodes = tree.slice();

    assert(moves.len == tokens.len);
    assert(nodes.len < none);

    if (!binary_hoists) return;

    for (nodes) |*node| {
        if (!rules.mixes(node.kind)) continue;
        if (node.child_first == none) continue;

        trailed_node(Kind, nodes, source, tokens, node, moves);
    }
}

fn trailed_node(
    comptime Kind: type,
    nodes: []const NodeType(Kind),
    source: []const u8,
    tokens: []const Token,
    node: *const NodeType(Kind),
    moves: []u8,
) void {
    assert(nodes.len <= std.math.maxInt(u32));
    assert(source.len <= std.math.maxInt(u32));

    const left = node.child_first;
    const right = nodes[left].sibling_next;

    assert(left != none);
    assert(moves.len == tokens.len);

    if (right == none) return;
    if (nodes[right].sibling_next != none) return;

    const from = nodes[left].token_end;
    const to = nodes[right].token_start;

    if (from == 0) return;
    if (from > to) return;
    if (to > tokens.len) return;

    const anchor = from - 1;
    const operator = coded(tokens, from, to) orelse return;
    const blank = tokens[anchor].kind == .comment or tokens[anchor].kind == .newline;
    if (blank) return;
    if (moves[anchor] != 0) return;
    if (moves[operator] != 0) return;
    if (comment_leading(source, tokens, from, operator) == null) return;

    moves[anchor] = move_trails;
    moves[operator] = move_drops;
}

fn coded(tokens: []const Token, from: u32, to: u32) ?u32 {
    assert(tokens.len < none);
    assert(to < none);

    const stop = @min(to, tokens.len);

    assert(stop <= tokens.len);

    if (from >= stop) return null;

    for (from..stop) |scan| {
        const token = tokens[scan];
        const blank = token.kind == .comment or token.kind == .newline or token.length == 0;

        if (!blank) {
            assert(scan < stop);

            return @intCast(scan);
        }
    }

    return null;
}

fn coded_before(tokens: []const Token, position: u32) ?u32 {
    assert(position <= tokens.len);

    var scan = position;

    assert(tokens.len < none);

    for (0..position) |_| {
        scan -= 1;

        const token = tokens[scan];
        const blank = token.kind == .comment or token.kind == .newline or token.length == 0;
        if (!blank) return scan;
    }

    return null;
}

fn assign_trailed(source: []const u8, tokens: []const Token, moves: []u8) void {
    assert(moves.len == tokens.len);
    assert(source.len < none);

    if (!assign_hoists) return;
    if (tokens.len == 0) return;

    for (1..tokens.len) |index| {
        const position: u32 = @intCast(index);
        const token = tokens[position];
        if (!token.is_punctuation(.assign)) continue;
        if (!text_equal(source, token, "=")) continue;
        if (moves[position] != 0) continue;

        const anchor = coded_before(tokens, position) orelse continue;
        if (moves[anchor] != 0) continue;
        if (comment_leading(source, tokens, anchor + 1, position) == null) continue;

        moves[anchor] = move_trails;
        moves[position] = move_drops;
    }
}

fn suffixed(source: []const u8, tokens: []const Token, anchor: u32, close: u32) bool {
    assert(source.len <= std.math.maxInt(u32));
    assert(close < tokens.len);
    assert(anchor < close);

    const ends_block = tokens[anchor].kind == .block_end;
    const unargued = ends_block and argued_body(source, tokens, anchor, close) == null;

    if (!paren_suffixes) return false;
    if (unargued) return false;

    const comment = suffixed_comment(tokens, anchor, close) orelse return false;
    const token = tokens[comment];
    if (token.kind != .comment) return false;
    if (!std.mem.startsWith(u8, token.text(source), "//")) return false;
    return std.mem.findScalar(u8, source[tokens[anchor].end()..token.offset], '\n') == null;
}

fn suffixed_comment(tokens: []const Token, anchor: u32, close: u32) ?u32 {
    var found: ?u32 = null;

    assert(anchor < close);
    assert(close < tokens.len);

    for (anchor + 1..close) |held| {
        if (tokens[held].kind == .newline) continue;
        if (tokens[held].length == 0) continue;
        if (found != null) return null;

        found = @intCast(held);
    }

    return found;
}

fn argued_body(source: []const u8, tokens: []const Token, anchor: u32, close: u32) ?u32 {
    assert(anchor < tokens.len);
    assert(close < tokens.len);

    if (!argued_suffixes) return null;
    if (tokens[anchor].kind != .block_end) return null;
    assert(source.len <= std.math.maxInt(u32));

    const brace_at = argued_brace(source, tokens, anchor) orelse return null;
    if (tokens[brace_at].kind != .block_start) return null;

    const open = written_before(tokens, brace_at) orelse return null;
    if (!tokens[open].is_punctuation(.paren_open)) return null;

    const arrow = written_before(tokens, open) orelse return null;
    if (!text_equal(source, tokens[arrow], "=>")) return null;

    const call = written_after(tokens, close) orelse return null;
    if (!tokens[call].is_punctuation(.paren_close)) return null;
    return call;
}

fn argued_brace(source: []const u8, tokens: []const Token, anchor: u32) ?u32 {
    assert(source.len <= std.math.maxInt(u32));
    assert(anchor < tokens.len);

    var depth: u32 = 0;
    var scan = anchor;

    assert(tokens[anchor].kind == .block_end);

    for (0..anchor + 1) |_| {
        const token = tokens[scan];
        const opens = token.kind == .block_start or walk.substituting(source, token);

        if (token.kind == .block_end) depth += 1;

        if (opens) {
            if (depth == 0) return null;

            depth -= 1;

            if (depth == 0) return scan;
        }

        if (scan == 0) return null;

        scan -= 1;
    }

    return null;
}

fn lone_dropped(source: []const u8, tokens: []const Token, moves: []const u8, position: u32) ?u32 {
    assert(source.len <= std.math.maxInt(u32));
    assert(position < tokens.len);

    var scan = position;

    assert(moves.len == tokens.len);

    if (!lone_drops) return null;

    for (0..position) |_| {
        const before = scan - 1;
        const token = tokens[before];

        if (token.length > 0) {
            const gap = source[token.end()..tokens[scan].offset];
            if (std.mem.findScalar(u8, gap, '\n') != null) break;
            if (moves[before] != move_drops) return null;
        }

        scan = before;
    }

    const end = tokens[position].end();
    const rest = source[end..];
    const after = std.mem.findNone(u8, rest, " \t\r") orelse return null;
    if (rest[after] != '\n') return null;
    assert(end + @as(u32, @intCast(after)) + 1 <= source.len);

    return end + @as(u32, @intCast(after)) + 1;
}

fn closed(
    comptime Kind: type,
    tree: *const TreeType(Kind),
    source: []const u8,
    tokens: []const Token,
    comptime rules: *const RulesType(Kind),
    flags: []const u16,
    moves: []u8,
) void {
    assert(source.len <= std.math.maxInt(u32));

    const nodes = tree.slice();

    assert(flags.len == tokens.len);
    assert(moves.len == tokens.len);

    if (!paren_comments) return;

    for (nodes) |*node| {
        if (!rules.parens(node.kind)) continue;
        if (node.token_end < node.token_start + 3) continue;
        if (unary_comment(Kind, nodes, tokens, rules, node) != null) continue;

        const open = node.token_start;
        const close = node.token_end - 1;

        if (!tokens[open].is_punctuation(.paren_open)) continue;
        if (!tokens[close].is_punctuation(.paren_close)) continue;
        if (flags[open] & (paren_drops | type_nodes) != 0) continue;
        if (flags[close] & paren_drops != 0) continue;
        if (moves[close] != 0) continue;

        if (!header_paren(source, tokens, open)) moves[close] = move_pending;
    }

    if (tokens.len == 0) return;

    for (1..tokens.len) |close| {
        if (moves[close] != move_pending) continue;

        moves[close] = 0;

        closed_pending(source, tokens, flags, moves, @intCast(close));
    }
}

fn closed_pending(
    source: []const u8,
    tokens: []const Token,
    flags: []const u16,
    moves: []u8,
    close: u32,
) void {
    assert(source.len <= std.math.maxInt(u32));
    assert(flags.len <= std.math.maxInt(u32));
    assert(moves.len <= std.math.maxInt(u32));
    assert(close > 0);

    var anchor = close - 1;
    var inside = false;
    var commented = false;

    assert(close < tokens.len);

    for (0..close) |_| {
        if (anchor == 0) break;

        const token = tokens[anchor];
        const comment = token.kind == .comment;
        const drop_close = moves[anchor] == move_drops and token.is_punctuation(.paren_close);
        const held = comment or drop_close;
        if (!held) break;

        commented = commented or comment;
        inside = inside or !comment;
        anchor -= 1;
    }

    if (!commented) return;

    const nested_inside = nested_comment_parens and inside;
    if (nested_inside) return;
    if (closed_skips(source, tokens, flags, moves, anchor, close)) return;

    moves[anchor] = move_closes;
    moves[close] = move_drops;

    if (argued_body(source, tokens, anchor, close)) |call| moves[call] = move_drops;
}

fn closed_commented(source: []const u8, tokens: []const Token, open: u32, close: u32) bool {
    assert(open < close);
    assert(close < tokens.len);

    if (!paren_comments) return false;
    if (header_paren(source, tokens, open)) return false;
    if (asserted_after(source, tokens, close)) return false;

    var anchor = close - 1;

    for (0..close) |_| {
        if (anchor <= open) return false;
        if (tokens[anchor].kind != .comment) break;

        anchor -= 1;
    }

    const token = tokens[anchor];

    if (anchor + 1 == close) return false;
    if (token.kind == .newline) return false;
    if (token.length == 0) return false;

    const gap = source[token.end()..tokens[close].offset];
    if (std.mem.findScalar(u8, gap, '\n') == null) return true;
    return suffixed(source, tokens, anchor, close);
}

fn asserted_after(source: []const u8, tokens: []const Token, close: u32) bool {
    assert(close < tokens.len);
    assert(tokens.len < none);

    const after = written_after(tokens, close) orelse return false;
    if (text_equal(source, tokens[after], "as")) return true;
    return text_equal(source, tokens[after], "satisfies");
}

fn closed_skips(
    source: []const u8,
    tokens: []const Token,
    flags: []const u16,
    moves: []const u8,
    anchor: u32,
    close: u32,
) bool {
    assert(source.len <= std.math.maxInt(u32));
    assert(close < tokens.len);
    assert(flags.len <= std.math.maxInt(u32));
    assert(moves.len <= std.math.maxInt(u32));
    assert(anchor < close);

    const token = tokens[anchor];
    const grouped = nested_comment_parens and closed_grouped(source, tokens, flags, anchor, close);

    if (grouped) return true;
    if (asserted_after(source, tokens, close)) return true;
    if (token.kind == .comment) return true;
    if (token.kind == .newline) return true;
    if (token.is_punctuation(.paren_open)) return true;
    if (token.length == 0) return true;

    const settled = moves[anchor] == 0 or moves[anchor] == move_closes;
    if (!settled) return true;

    const gap = source[token.end()..tokens[close].offset];
    if (std.mem.findScalar(u8, gap, '\n') == null) return false;
    return !suffixed(source, tokens, anchor, close);
}

fn closed_grouped(
    source: []const u8,
    tokens: []const Token,
    flags: []const u16,
    anchor: u32,
    close: u32,
) bool {
    assert(anchor < close);
    assert(flags.len == tokens.len);
    assert(source.len <= std.math.maxInt(u32));

    for (tokens[anchor + 1 .. close]) |held| {
        const block = held.kind != .comment or std.mem.startsWith(u8, held.text(source), "/*");
        if (!block) return false;
    }

    if (flags[anchor] & paren_drops != 0) return false;
    return grouping_close(source, tokens, anchor);
}

fn arrow_paired(
    comptime Kind: type,
    tree: *const TreeType(Kind),
    source: []const u8,
    tokens: []const Token,
    comptime rules: *const RulesType(Kind),
    pairs: *const Pairs,
) void {
    assert(pairs.opens.len == tokens.len);
    assert(pairs.closes.len == tokens.len);
    assert(source.len <= std.math.maxInt(u32));

    if (!arrow_pairs) return;

    for (tree.slice()) |*node| {
        if (!rules.arrows(node.kind)) continue;
        if (node.token_end > tokens.len) continue;

        const head = arrow_head(source, tokens, node.token_start, node.token_end) orelse continue;
        if (pairs.opens[head] != 0) continue;
        if (pairs.closes[head] != 0) continue;

        pairs.opens[head] += 1;
        pairs.closes[head] += 1;
    }
}

fn initialized(
    comptime Kind: type,
    tree: *const TreeType(Kind),
    source: []const u8,
    tokens: []const Token,
    comptime rules: *const RulesType(Kind),
    flags: []u16,
    pairs: *const Pairs,
) void {
    assert(source.len <= std.math.maxInt(u32));

    const nodes = tree.slice();

    assert(flags.len == tokens.len);
    assert(pairs.opens.len == tokens.len);

    if (!initializer_parens) return;

    for (nodes, 0..) |*node, index| {
        if (!rules.mixes(node.kind)) continue;
        if (node.token_end == 0) continue;
        if (node.token_end > tokens.len) continue;
        if (!operated_in(Kind, nodes, source, tokens, node)) continue;
        if (!initializer_held(Kind, nodes, rules, @intCast(index))) continue;

        const above = &nodes[node.parent];

        if (rules.parens(above.kind)) {
            flags[above.token_start] &= ~paren_drops;

            flags[above.token_end - 1] &= ~paren_drops;

            continue;
        }

        if (pairs.opens[node.token_start] == std.math.maxInt(u8)) continue;
        if (pairs.closes[node.token_end - 1] == std.math.maxInt(u8)) continue;

        pairs.opens[node.token_start] += 1;

        pairs.closes[node.token_end - 1] += 1;
    }
}

fn operated_in(
    comptime Kind: type,
    nodes: []const NodeType(Kind),
    source: []const u8,
    tokens: []const Token,
    node: *const NodeType(Kind),
) bool {
    assert(node.token_start <= node.token_end);
    assert(node.token_end <= tokens.len);

    if (node.child_first == none) return false;
    assert(nodes.len <= std.math.maxInt(u32));
    assert(source.len <= std.math.maxInt(u32));

    const left = &nodes[node.child_first];
    const operator = coded(tokens, left.token_end, node.token_end) orelse return false;

    return text_equal(source, tokens[operator], "in");
}

fn initializer_held(
    comptime Kind: type,
    nodes: []const NodeType(Kind),
    comptime rules: *const RulesType(Kind),
    index: u32,
) bool {
    assert(index < nodes.len);

    var child = index;

    assert(nodes.len < none);

    for (0..nodes.len) |_| {
        const at = nodes[child].parent;
        if (at == none) return false;

        switch (rules.initializers(nodes[at].kind)) {
            .head => return nodes[at].child_first == child,
            .none => {},
            .statement => return false,
        }

        child = at;
    }

    return false;
}

fn arrow_head(source: []const u8, tokens: []const Token, start: u32, end: u32) ?u32 {
    assert(source.len <= std.math.maxInt(u32));
    assert(start <= end);
    assert(tokens.len <= std.math.maxInt(u32));

    const count: u32 = @intCast(tokens.len);
    var head = coded(tokens, start, count) orelse return null;
    var after = coded(tokens, head + 1, count) orelse return null;
    const asynced = text_equal(source, tokens[head], "async") and tokens[after].kind == .identifier;

    assert(end <= tokens.len);

    if (asynced) {
        head = after;
        after = coded(tokens, head + 1, count) orelse return null;
    }

    const worded = tokens[head].kind == .identifier or tokens[head].kind == .keyword;
    const bare = worded and text_equal(source, tokens[after], "=>") and after < end;

    return if (bare) head else null;
}

fn unary_commented(
    comptime Kind: type,
    tree: *const TreeType(Kind),
    tokens: []const Token,
    comptime rules: *const RulesType(Kind),
    flags: []u16,
    pairs: *const Pairs,
) void {
    const nodes = tree.slice();

    assert(flags.len == tokens.len);
    assert(pairs.opens.len == tokens.len);

    if (!unary_comments) return;

    const marks: Marks = .{ .flags = flags, .pairs = pairs };

    for (nodes, 0..) |*node, index| {
        const inner = unary_comment(Kind, nodes, tokens, rules, node) orelse continue;

        flags[node.token_start] &= ~paren_drops;

        flags[node.token_end - 1] &= ~paren_drops;
        unary_commented_operand(Kind, nodes, tokens, rules, @intCast(index), &inner, &marks);
    }
}

fn unary_commented_operand(
    comptime Kind: type,
    nodes: []const NodeType(Kind),
    tokens: []const Token,
    comptime rules: *const RulesType(Kind),
    pair: u32,
    inner: *const NodeType(Kind),
    marks: *const Marks,
) void {
    assert(nodes.len <= std.math.maxInt(u32));
    assert(tokens.len <= std.math.maxInt(u32));
    assert(pair < nodes.len);

    const unary = nodes[pair].parent;
    const flags = marks.flags;
    const pairs = marks.pairs;
    const owned = paren_held(Kind, nodes, tokens, rules, inner);
    const operand = owned orelse inner.*;
    const needed = operand_paired(Kind, nodes, rules, unary, pair, &operand);

    assert(unary < pair);
    assert(inner.token_end > inner.token_start);

    if (owned != null) {
        const from = inner.token_start;
        const to = inner.token_end - 1;

        if (needed) {
            flags[from] &= ~paren_drops;
            flags[to] &= ~paren_drops;

            return;
        }

        flags[from] |= paren_drops;
        flags[to] |= paren_drops;

        return;
    }

    if (!needed) return;

    pairs.opens[operand.token_start] += 1;

    pairs.closes[operand.token_end - 1] += 1;
}

fn paren_held(
    comptime Kind: type,
    nodes: []const NodeType(Kind),
    tokens: []const Token,
    comptime rules: *const RulesType(Kind),
    node: *const NodeType(Kind),
) ?NodeType(Kind) {
    if (!rules.parens(node.kind)) return null;
    if (node.child_first == none) return null;
    if (node.token_end < node.token_start + 3) return null;
    assert(nodes.len <= std.math.maxInt(u32));

    const inner = nodes[node.child_first];
    const open = node.token_start;
    const close = node.token_end - 1;

    assert(close < tokens.len);
    assert(open + 2 <= close);

    if (!tokens[open].is_punctuation(.paren_open)) return null;
    if (!tokens[close].is_punctuation(.paren_close)) return null;
    if (inner.token_start <= open) return null;
    if (inner.token_end > close) return null;
    if (!paren_blank(tokens, open + 1, inner.token_start)) return null;
    if (!paren_blank(tokens, inner.token_end, close)) return null;
    return inner;
}

fn paren_blank(tokens: []const Token, from: u32, to: u32) bool {
    assert(to <= tokens.len);
    assert(tokens.len < none);

    if (from >= to) return true;

    for (tokens[from..to]) |token| {
        const blank = token.kind == .newline or token.length == 0;
        if (!blank) return false;
    }

    return true;
}

fn paren_commented(tokens: []const Token, from: u32, to: u32) bool {
    assert(to <= tokens.len);
    assert(tokens.len < none);

    if (from >= to) return false;

    for (tokens[from..to]) |token| {
        if (token.kind == .comment) return true;
    }

    return false;
}

pub fn jump_commented(source: []const u8, tokens: []const Token, from: u32, to: u32) bool {
    assert(to < tokens.len);
    assert(tokens.len < none);

    if (from >= to) return false;
    assert(source.len <= std.math.maxInt(u32));

    for (tokens[from..to], from..) |token, position| {
        if (token.kind != .comment) continue;

        const next = tokens[position + 1];
        const prior = tokens[position - 1];

        assert(token.end() <= next.offset);

        if (std.mem.findScalar(u8, token.text(source), '\n') != null) return true;
        if (std.mem.findScalar(u8, source[token.end()..next.offset], '\n') != null) return true;
        if (std.mem.findScalar(u8, source[prior.end()..token.offset], '\n') != null) return true;
    }

    return false;
}

fn operand_paired(
    comptime Kind: type,
    nodes: []const NodeType(Kind),
    comptime rules: *const RulesType(Kind),
    unary: u32,
    pair: u32,
    operand: *const NodeType(Kind),
) bool {
    assert(unary < nodes.len);
    assert(pair < nodes.len);

    const above = &nodes[unary];
    const ancestor: ?Kind = if (above.parent == none) null else nodes[above.parent].kind;
    const first = above.child_first == pair;
    const head: ?Kind = if (operand.child_first == none) null else nodes[operand.child_first].kind;
    const heads = heads_of(Kind, nodes, rules, above, pair);

    if (rules.wraps(operand.kind, above.kind, ancestor, first)) return true;
    return !rules.drops(operand.kind, above.kind, head, heads, first);
}

fn unary_comment(
    comptime Kind: type,
    nodes: []const NodeType(Kind),
    tokens: []const Token,
    comptime rules: *const RulesType(Kind),
    node: *const NodeType(Kind),
) ?NodeType(Kind) {
    if (!unary_comments) return null;
    if (!rules.parens(node.kind)) return null;
    if (node.parent == none) return null;
    if (node.child_first == none) return null;
    if (node.token_end < node.token_start + 3) return null;
    if (!rules.unaries(nodes[node.parent].kind)) return null;

    const inner = nodes[node.child_first];
    const open = node.token_start;
    const close = node.token_end - 1;

    assert(close < tokens.len);
    assert(open + 2 <= close);

    if (!tokens[open].is_punctuation(.paren_open)) return null;
    if (!tokens[close].is_punctuation(.paren_close)) return null;
    if (inner.token_start <= open) return null;
    if (inner.token_end > close) return null;
    if (inner.token_end <= inner.token_start) return null;

    const commented = paren_commented(tokens, open + 1, inner.token_start) or
        paren_commented(tokens, inner.token_end, close);

    return if (commented) inner else null;
}

fn heads_of(
    comptime Kind: type,
    nodes: []const NodeType(Kind),
    comptime rules: *const RulesType(Kind),
    above: *const NodeType(Kind),
    index: u32,
) Heads {
    assert(index < nodes.len);
    assert(above.child_first != none);

    return .{
        .bodied = statement_parens and heads_a_statement(Kind, nodes, rules, index, true),
        .branch = branch_child(Kind, nodes, above, index),
        .called = false,
        .decorated = false,
        .plain = false,
        .statement = statement_parens and heads_a_statement(Kind, nodes, rules, index, false),
    };
}

fn branch_child(
    comptime Kind: type,
    nodes: []const NodeType(Kind),
    above: *const NodeType(Kind),
    index: u32,
) bool {
    assert(index < nodes.len);
    assert(above.child_first == none or above.child_first < nodes.len);

    if (above.child_first == none) return false;
    if (above.child_first == index) return false;
    return nodes[above.child_first].sibling_next != index;
}

fn header_paren(source: []const u8, tokens: []const Token, open: u32) bool {
    assert(source.len <= std.math.maxInt(u32));
    assert(open < none);
    assert(tokens.len <= std.math.maxInt(u32));

    const head = coded_before(tokens, open) orelse return false;
    const text = tokens[head].text(source);
    const headers = [_][]const u8{ "if", "switch", "while", "with" };

    assert(head < open);

    assert(open < tokens.len);

    for (headers) |header| {
        if (std.mem.eql(u8, text, header)) return true;
    }

    return false;
}

fn led(
    comptime Kind: type,
    tree: *const TreeType(Kind),
    source: []const u8,
    tokens: []const Token,
    comptime rules: *const RulesType(Kind),
    flags: []const u16,
    moves: []u8,
) void {
    assert(flags.len == tokens.len);
    assert(moves.len == tokens.len);
    assert(source.len <= std.math.maxInt(u32));

    if (!paren_leads) return;

    const nodes = tree.slice();

    for (nodes) |*node| {
        if (!rules.parens(node.kind)) continue;
        if (node.token_end < node.token_start + 3) continue;
        if (unary_comment(Kind, nodes, tokens, rules, node) != null) continue;

        if (led_jumps(Kind, nodes, rules, node)) {
            jump_broken(source, tokens, flags, moves, node.token_start);

            continue;
        }

        led_pair(source, tokens, flags, moves, node.token_start, node.token_end - 1);
    }
}

fn led_jumps(
    comptime Kind: type,
    nodes: []const NodeType(Kind),
    comptime rules: *const RulesType(Kind),
    node: *const NodeType(Kind),
) bool {
    assert(rules.parens(node.kind));
    assert(nodes.len < none);

    if (node.parent == none) return false;
    if (node.child_first == none) return false;

    const inner = paren_core(Kind, nodes, rules, &nodes[node.child_first]);
    return rules.jumps(inner.kind, nodes[node.parent].kind);
}

fn jump_broken(
    source: []const u8,
    tokens: []const Token,
    flags: []const u16,
    moves: []u8,
    open: u32,
) void {
    assert(open + 1 < tokens.len);
    assert(moves.len == tokens.len);
    assert(source.len <= std.math.maxInt(u32));
    assert(flags.len <= std.math.maxInt(u32));

    if (!tokens[open].is_punctuation(.paren_open)) return;
    if (flags[open] & paren_drops != 0) return;
    if (moves[open] != 0) return;

    const next = tokens[open + 1];
    if (next.kind != .comment) return;
    if (std.mem.findScalar(u8, source[tokens[open].end()..next.offset], '\n') != null) return;

    moves[open] = move_breaks;
}

fn led_pair(
    source: []const u8,
    tokens: []const Token,
    flags: []const u16,
    moves: []u8,
    open: u32,
    close: u32,
) void {
    assert(open + 2 <= close);
    assert(close < tokens.len);
    assert(source.len <= std.math.maxInt(u32));
    assert(flags.len <= std.math.maxInt(u32));
    assert(moves.len <= std.math.maxInt(u32));

    if (!tokens[open].is_punctuation(.paren_open)) return;
    if (!tokens[close].is_punctuation(.paren_close)) return;
    if (flags[open] & (paren_drops | type_nodes) != 0) return;
    if (flags[close] & paren_drops != 0) return;
    if (moves[open] != 0) return;
    if (header_paren(source, tokens, open)) return;
    if (cast.leads(source, tokens, open)) return;

    const head = coded(tokens, open + 1, close) orelse return;
    const gap = source[tokens[open].end()..tokens[head].offset];

    if (!paren_commented(tokens, open + 1, head)) return;
    if (std.mem.findScalar(u8, gap, '\n') == null) return;
    if (moves[head] != 0) return;
    if (cast_led_head(source, tokens, head)) return;

    moves[open] = move_drops;
    moves[head] = move_opens;
}

fn led_commented(source: []const u8, tokens: []const Token, open: u32, close: u32) bool {
    assert(open < close);
    assert(close < tokens.len);

    if (!paren_leads) return false;
    if (header_paren(source, tokens, open)) return false;
    if (cast.leads(source, tokens, open)) return false;

    const head = coded(tokens, open + 1, close) orelse return false;
    const gap = source[tokens[open].end()..tokens[head].offset];

    if (!paren_commented(tokens, open + 1, head)) return false;
    if (std.mem.findScalar(u8, gap, '\n') == null) return false;
    return !cast_led_head(source, tokens, head);
}

fn cast_led_head(source: []const u8, tokens: []const Token, head: u32) bool {
    assert(head > 0);
    assert(head < tokens.len);

    if (!tokens[head].is_punctuation(.paren_open)) return false;
    assert(source.len <= std.math.maxInt(u32));

    return cast.leads(source, tokens, head);
}

fn ampersanded(
    comptime Kind: type,
    tree: *const TreeType(Kind),
    source: []const u8,
    tokens: []const Token,
    moves: []u8,
) void {
    assert(moves.len == tokens.len);
    assert(source.len < none);

    if (!leading_ampersands) return;

    for (tree.slice()) |*node| {
        if (node.kind.category() != .type) continue;
        if (node.token_end <= node.token_start + 1) continue;
        if (node.token_start >= tokens.len) continue;
        if (!text_equal(source, tokens[node.token_start], "&")) continue;
        if (moves[node.token_start] != 0) continue;

        moves[node.token_start] = move_drops;
    }
}

fn abutted(
    comptime Kind: type,
    tree: *const TreeType(Kind),
    source: []const u8,
    tokens: []const Token,
    comptime rules: *const RulesType(Kind),
    flags: []const u16,
    moves: []u8,
) void {
    assert(flags.len == tokens.len);
    assert(moves.len == tokens.len);
    assert(source.len <= std.math.maxInt(u32));

    if (!unary_abuts) return;

    for (tree.slice()) |*node| {
        if (!rules.unaries(node.kind)) continue;
        if (node.token_end <= node.token_start + 1) continue;

        abutted_node(source, tokens, flags, moves, node.token_start, node.token_end);
    }
}

fn abutted_node(
    source: []const u8,
    tokens: []const Token,
    flags: []const u16,
    moves: []u8,
    start: u32,
    end: u32,
) void {
    assert(source.len <= std.math.maxInt(u32));
    assert(flags.len == tokens.len);
    assert(moves.len <= std.math.maxInt(u32));
    assert(start + 1 < end);

    const operator = tokens[start];
    var at = start + 1;

    for (0..end) |_| {
        if (!paren_abuts) break;
        if (at + 1 >= end) break;
        if (flags[at] & paren_drops == 0) break;
        if (!tokens[at].is_punctuation(.paren_open)) break;

        at += 1;
    }

    const pair = at > start + 1;
    const before = if (pair) tokens[at - 1] else operator;
    const operand = tokens[at];
    const text = operator.text(source);
    const gap = source[before.end()..operand.offset];

    if (!abutted_unary(text)) return;
    if (gap.len == 0) return;
    if (std.mem.findNone(u8, gap, " \t") != null) return;
    if (operand.kind == .comment) return;
    if (operand.kind == .newline) return;

    const signs = !walk.text_is(text, "!") and !walk.text_is(text, "~");
    const repeated = signs and operand.length > 0 and operand.text(source)[0] == text[0];
    const free = moves[at] == 0 or !pair;

    if (repeated) return;

    if (free) moves[at] = move_abuts;
}

fn bracket_abutted(
    comptime Kind: type,
    tree: *const TreeType(Kind),
    source: []const u8,
    tokens: []const Token,
    comptime rules: *const RulesType(Kind),
    flags: []const u16,
    moves: []u8,
) void {
    assert(source.len <= std.math.maxInt(u32));

    const nodes = tree.slice();

    assert(flags.len == tokens.len);
    assert(moves.len == tokens.len);
    assert(nodes.len < none);

    if (!bracket_abuts) return;

    for (nodes) |*node| {
        const open = bracket_of(Kind, nodes, tokens, rules, node) orelse continue;
        const anchor = coded_before(tokens, open) orelse continue;

        if (moves[open] != 0) continue;
        if (flags[anchor] & end_owed != 0) continue;

        if (bracket_parted(source, tokens, open)) {
            moves[open] = move_abuts;

            continue;
        }

        if (!tokens[open].is_punctuation(.paren_open)) continue;
        if (rules.parameters(node.kind)) continue;
        if (anchor + 1 == open) continue;
        if (!unmoved(moves, anchor, open)) continue;

        moves[anchor] = move_pulls;
        moves[open] = move_drops;
    }
}

fn bracket_of(
    comptime Kind: type,
    nodes: []const NodeType(Kind),
    tokens: []const Token,
    comptime rules: *const RulesType(Kind),
    node: *const NodeType(Kind),
) ?u32 {
    assert(nodes.len <= std.math.maxInt(u32));
    assert(tokens.len <= std.math.maxInt(u32));

    if (rules.parameters(node.kind)) return parameters_open(Kind, nodes, tokens, node);
    if (node.child_first == none) return null;

    const head = nodes[node.child_first];

    assert(head.token_end <= tokens.len);

    if (rules.links(node.kind)) {
        if (head.token_end >= tokens.len) return null;
        if (!tokens[head.token_end].is_punctuation(.bracket_open)) return null;
        return head.token_end;
    }

    if (!rules.invokes(node.kind)) {
        if (!rules.calls(node.kind)) return null;
    }

    var child = node.child_first;

    for (0..nodes.len) |_| {
        const next = nodes[child].sibling_next;
        if (next == none) break;

        child = next;
    }

    const start = nodes[child].token_start;

    if (child == node.child_first) return null;
    if (start >= tokens.len) return null;
    if (!tokens[start].is_punctuation(.paren_open)) return null;
    return start;
}

fn parameters_open(
    comptime Kind: type,
    nodes: []const NodeType(Kind),
    tokens: []const Token,
    node: *const NodeType(Kind),
) ?u32 {
    const start = node.token_start;

    assert(node.token_start <= node.token_end);
    assert(node.token_end <= tokens.len);

    if (node.parent == none) return null;
    if (start >= tokens.len) return null;
    if (!tokens[start].is_punctuation(.paren_open)) return null;
    if (nodes[node.parent].token_start >= start) return null;
    return start;
}

fn bracket_parted(source: []const u8, tokens: []const Token, open: u32) bool {
    assert(open < tokens.len);
    assert(source.len < none);

    if (open == 0) return false;

    const before = tokens[open - 1];
    if (before.length == 0) return false;
    if (before.kind == .comment) return false;
    if (before.kind == .newline) return false;

    const gap = source[before.end()..tokens[open].offset];
    if (std.mem.findScalar(u8, gap, '\n') == null) return false;
    return std.mem.findNone(u8, gap, ascii_whitespace) == null;
}

fn abutted_unary(text: []const u8) bool {
    const unaries = [_][]const u8{ "!", "+", "-", "~" };

    assert(unaries.len == 4);
    assert(text.len < none);

    for (unaries) |unary| {
        if (std.mem.eql(u8, text, unary)) return true;
    }

    return false;
}

fn labeled(
    comptime Kind: type,
    tree: *const TreeType(Kind),
    source: []const u8,
    tokens: []const Token,
    comptime rules: *const RulesType(Kind),
    moves: []u8,
) void {
    assert(source.len <= std.math.maxInt(u32));

    const nodes = tree.slice();

    assert(moves.len == tokens.len);
    assert(nodes.len < none);

    if (!label_abuts) return;

    for (nodes) |*node| {
        if (!rules.labels(node.kind)) continue;
        if (node.child_first == none) continue;

        const body = nodes[node.child_first].sibling_next;
        if (body == none) continue;

        const start = nodes[body].token_start;
        if (start == 0) continue;
        if (start >= tokens.len) continue;

        const colon = tokens[start - 1];
        const gap = source[colon.end()..tokens[start].offset];

        if (!text_equal(source, colon, ":")) continue;
        if (std.mem.findScalar(u8, gap, '\n') == null) continue;
        if (std.mem.findNone(u8, gap, ascii_whitespace) != null) continue;

        moves[start] = move_abuts;
    }
}

fn updated(
    comptime Kind: type,
    tree: *const TreeType(Kind),
    source: []const u8,
    tokens: []const Token,
    comptime rules: *const RulesType(Kind),
    moves: []u8,
) void {
    assert(source.len <= std.math.maxInt(u32));

    const nodes = tree.slice();

    assert(moves.len == tokens.len);
    assert(nodes.len < none);

    for (nodes) |*node| {
        if (!rules.updates(node.kind)) continue;
        if (node.token_end > tokens.len) continue;
        if (node.token_end < node.token_start + 2) continue;

        const first = node.token_start;
        const last = node.token_end - 1;
        const abutted_at = if (update_operator(source, tokens[first])) first + 1 else last;

        if (abutted_at == last) {
            if (!update_operator(source, tokens[last])) continue;
        }

        if (tokens[abutted_at - 1].kind == .comment) continue;
        if (tokens[abutted_at].kind == .comment) continue;
        if (moves[abutted_at] != 0) continue;

        moves[abutted_at] = move_abuts;
    }
}

fn update_operator(source: []const u8, token: Token) bool {
    assert(token.end() <= source.len);

    if (token.kind != .punctuation) return false;
    return text_equal(source, token, "++") or text_equal(source, token, "--");
}

fn conditional_operator(source: []const u8, tokens: []const Token, from: u32, to: u32) ?u32 {
    if (from > to) return null;
    if (to > tokens.len) return null;

    assert(from <= to);
    assert(to <= tokens.len);
    assert(source.len <= std.math.maxInt(u32));

    for (from..to) |scan| {
        const token = tokens[scan];
        if (token.kind == .comment) continue;

        const text = token.text(source);
        const conditional = walk.text_is(text, "?") or walk.text_is(text, ":");

        if (conditional) {
            assert(scan < to);

            return @intCast(scan);
        }
    }

    return null;
}

fn comment_leading(source: []const u8, tokens: []const Token, from: u32, operator: u32) ?u32 {
    if (from == 0) return null;
    if (from > operator) return null;
    assert(operator <= tokens.len);

    const start = tokens[from - 1].end();

    assert(operator <= tokens.len);

    assert(start <= source.len);

    for (from..operator) |scan| {
        const token = tokens[scan];
        if (token.kind != .comment) continue;

        if (parted(source, start, token.offset)) {
            assert(scan < operator);

            return @intCast(scan);
        }
    }

    return null;
}

fn parted(source: []const u8, from: u32, to: u32) bool {
    assert(from <= to);
    assert(to <= source.len);

    return std.mem.findScalar(u8, source[from..to], '\n') != null;
}

fn separated_behind(tokens: []const Token, moves: []const u8, position: u32) ?u32 {
    assert(position < tokens.len);

    var scan = position;

    assert(moves.len == tokens.len);

    for (0..position) |_| {
        scan -= 1;

        if (moves[scan] == move_drops) return scan;
        if (tokens[scan].kind == .comment) continue;
        if (tokens[scan].length != 0) return null;
    }

    return null;
}

fn case_commented(
    comptime Kind: type,
    tree: *const TreeType(Kind),
    source: []const u8,
    tokens: []const Token,
    comptime rules: *const RulesType(Kind),
    moves: []u8,
) void {
    const nodes = tree.slice();

    assert(moves.len == tokens.len);
    assert(source.len < none);

    if (!separator_comments) return;

    for (nodes) |*node| {
        if (!rules.cases(node.kind)) continue;
        if (node.child_first == none) continue;

        const value = &nodes[node.child_first];
        if (value.sibling_next == none) continue;
        if (value.token_end == 0) continue;
        if (value.token_end > tokens.len) continue;

        const colon = written_after(tokens, value.token_end - 1) orelse continue;
        if (!tokens[colon].is_punctuation(.colon)) continue;
        if (moves[colon] != 0) continue;

        const last = case_comment_run(source, tokens, moves, colon) orelse continue;

        moves[colon] = move_drops;
        moves[last] = move_separates;
    }
}

fn label_commented(
    comptime Kind: type,
    tree: *const TreeType(Kind),
    source: []const u8,
    tokens: []const Token,
    comptime rules: *const RulesType(Kind),
    moves: []u8,
) void {
    const nodes = tree.slice();

    assert(moves.len == tokens.len);
    assert(source.len < none);

    if (!separator_comments) return;

    for (nodes) |*node| {
        if (!rules.labels(node.kind)) continue;
        if (node.child_first == none) continue;

        const label = &nodes[node.child_first];
        const body = label.sibling_next;
        if (body == none) continue;
        if (label.token_end == 0) continue;
        if (label.token_start >= tokens.len) continue;
        if (label.token_end > tokens.len) continue;
        if (nodes[body].token_start >= tokens.len) continue;

        label_commented_node(source, tokens, moves, label.token_start, nodes[body].token_start);
    }
}

fn label_commented_node(
    source: []const u8,
    tokens: []const Token,
    moves: []u8,
    label: u32,
    start: u32,
) void {
    assert(label < start);
    assert(start < tokens.len);
    assert(source.len <= std.math.maxInt(u32));
    assert(moves.len <= std.math.maxInt(u32));

    const colon = written_after(tokens, label) orelse return;
    const first = written_after(tokens, colon) orelse return;

    if (!tokens[colon].is_punctuation(.colon)) return;
    if (first >= start) return;
    if (tokens[first].kind != .comment) return;
    if (moves[label] != 0) return;
    if (moves[colon] != 0) return;
    if (moves[start] != 0) return;

    if (label_trailed(source, tokens, moves, colon, start)) |held| {
        moves[colon] = move_drops;
        moves[held] = move_separates;

        return;
    }

    for (first..start) |index| {
        const token = tokens[index];
        if (token.kind == .newline) continue;
        if (token.length == 0) continue;
        if (token.kind != .comment) return;
        if (moves[index] != 0) return;
    }

    for (first..start) |index| {
        if (tokens[index].kind == .comment) moves[index] = move_hoisted;
    }

    moves[label] = move_hoists;
    moves[start] = move_abuts;
}

fn label_trailed(
    source: []const u8,
    tokens: []const Token,
    moves: []const u8,
    colon: u32,
    start: u32,
) ?u32 {
    assert(source.len <= std.math.maxInt(u32));
    assert(moves.len <= std.math.maxInt(u32));
    assert(colon < start);

    var last: ?u32 = null;
    var held = colon;

    assert(start < tokens.len);

    for (0..tokens.len) |_| {
        const scan = written_after(tokens, held) orelse return null;
        if (scan == start) break;

        const token = tokens[scan];
        if (token.kind != .comment) return null;
        if (!std.mem.startsWith(u8, token.text(source), "/*")) return null;
        if (moves[scan] != 0) return null;
        if (parted(source, tokens[held].end(), token.offset)) return null;

        last = scan;
        held = scan;
    }

    const found = last orelse return null;
    if (parted(source, tokens[found].end(), tokens[start].offset)) return null;
    return found;
}

fn case_comment_run(source: []const u8, tokens: []const Token, moves: []const u8, colon: u32) ?u32 {
    assert(source.len <= std.math.maxInt(u32));
    assert(colon < tokens.len);

    var last: ?u32 = null;
    var held = colon;

    assert(moves.len == tokens.len);

    for (0..tokens.len) |_| {
        const scan = written_after(tokens, held) orelse break;
        const token = tokens[scan];
        if (token.kind != .comment) break;
        if (!std.mem.startsWith(u8, token.text(source), "/*")) break;
        if (moves[scan] != 0) return null;
        if (parted(source, tokens[held].end(), token.offset)) break;

        last = scan;
        held = scan;
    }

    const found = last orelse return null;
    const after = written_after(tokens, found) orelse return found;
    if (!parted(source, tokens[found].end(), tokens[after].offset)) return null;
    return found;
}

fn comma_pulled(source: []const u8, tokens: []const Token, moves: []u8) void {
    assert(moves.len == tokens.len);
    assert(source.len < none);

    if (!comma_pulls) return;

    for (tokens, 0..) |comma, index| {
        const position: u32 = @intCast(index);

        if (!comma.is_punctuation(.comma)) continue;
        if (moves[position] != 0) continue;

        const anchor = comma_anchor(source, tokens, position) orelse continue;
        if (!unmoved(moves, anchor, position)) continue;

        moves[anchor] = move_pulls;
        moves[position] = move_drops;
    }
}

fn comma_anchor(source: []const u8, tokens: []const Token, comma: u32) ?u32 {
    assert(source.len <= std.math.maxInt(u32));
    assert(comma < std.math.maxInt(u32));
    assert(tokens.len <= std.math.maxInt(u32));

    const code = coded_before(tokens, comma) orelse return null;
    const start = tokens[code].end();
    var anchor = code;

    assert(code < comma);

    assert(comma < tokens.len);

    if (walk.is_open(tokens[code].kind)) return null;
    if (tokens[code].is_punctuation(.comma)) return null;

    for (code + 1..comma) |scan| {
        const token = tokens[scan];
        if (token.kind != .comment) continue;
        if (std.mem.startsWith(u8, token.text(source), "//")) return anchor;
        if (parted(source, start, token.offset)) return anchor;

        anchor = @intCast(scan);
    }

    if (anchor == code) return null;
    if (!parted(source, tokens[anchor].end(), tokens[comma].offset)) return null;
    return anchor;
}

fn unmoved(moves: []const u8, from: u32, to: u32) bool {
    assert(from < to);
    assert(to < moves.len);

    for (moves[from .. to + 1]) |move| {
        if (move != 0) return false;
    }

    return true;
}

fn separator_commented(source: []const u8, tokens: []const Token, moves: []u8) void {
    assert(moves.len == tokens.len);
    assert(source.len < none);

    if (!separator_comments) return;

    for (tokens, 0..) |comma, index| {
        const position: u32 = @intCast(index);

        if (!comma.is_punctuation(.comma)) continue;
        if (moves[position] != 0) continue;

        const comment = separator_comment_run(source, tokens, moves, position) orelse continue;

        moves[position] = move_drops;
        moves[comment] = move_separates;
    }
}

fn separator_comment_run(
    source: []const u8,
    tokens: []const Token,
    moves: []const u8,
    comma: u32,
) ?u32 {
    assert(source.len <= std.math.maxInt(u32));
    assert(comma < tokens.len);

    var last: ?u32 = null;
    var held = comma;

    assert(moves.len == tokens.len);

    for (0..separator_comment_max) |_| {
        const scan = separator_coded(tokens, held + 1) orelse break;
        const token = tokens[scan];
        if (token.kind != .comment) break;
        if (!std.mem.startsWith(u8, token.text(source), "/*")) break;
        if (moves[scan] != 0) return null;
        if (parted(source, tokens[held].end(), token.offset)) break;

        last = scan;
        held = scan;
    }

    const found = last orelse return null;
    const after = separator_coded(tokens, found + 1) orelse return found;
    const next = tokens[after];
    if (parted(source, tokens[found].end(), next.offset)) return found;
    if (next.kind == .comment) return found;
    if (walk.is_close(next.kind)) return found;
    return null;
}

fn separator_coded(tokens: []const Token, from: u32) ?u32 {
    assert(from <= tokens.len);
    assert(tokens.len < none);

    for (from..tokens.len) |scan| {
        if (tokens[scan].length != 0) {
            assert(scan < tokens.len);

            return @intCast(scan);
        }
    }

    return null;
}

fn else_hoisted(source: []const u8, tokens: []const Token, moves: []u8) void {
    assert(moves.len == tokens.len);
    assert(source.len < none);

    for (tokens, 0..) |token, index| {
        const position: u32 = @intCast(index);

        if (!text_equal(source, token, "else")) continue;

        const first = written_after(tokens, position) orelse continue;
        const start = following(tokens, position + 1) orelse continue;
        if (first >= start) continue;
        if (tokens[start].kind == .block_start) continue;
        if (tokens[start].is_punctuation(.semicolon)) continue;
        if (text_equal(source, tokens[start], "if")) continue;
        if (moves[position] != 0) continue;
        if (moves[start] != 0) continue;
        if (!else_lined(source, tokens, moves, first, start)) continue;

        for (first..start) |held| {
            if (tokens[held].kind == .comment) moves[held] = move_hoisted;
        }

        moves[position] = move_hoists;
        moves[start] = move_abuts;
    }
}

fn else_lined(
    source: []const u8,
    tokens: []const Token,
    moves: []const u8,
    first: u32,
    start: u32,
) bool {
    assert(first < start);
    assert(start < tokens.len);
    assert(source.len <= std.math.maxInt(u32));
    assert(moves.len <= std.math.maxInt(u32));

    for (first..start) |held| {
        const token = tokens[held];
        if (token.kind == .newline) continue;
        if (token.length == 0) continue;
        if (token.kind != .comment) return false;
        if (!std.mem.startsWith(u8, token.text(source), "//")) return false;
        if (moves[held] != 0) return false;
    }

    return true;
}

fn elsed(source: []const u8, tokens: []const Token, moves: []u8) void {
    assert(moves.len == tokens.len);
    assert(source.len < none);

    if (!else_comments) return;

    for (tokens, 0..) |token, index| {
        const position: u32 = @intCast(index);

        if (!text_equal(source, token, "else")) continue;

        if (moves[position] != 0) continue;

        elsed_body(source, tokens, moves, position);
    }
}

fn elsed_body(source: []const u8, tokens: []const Token, moves: []u8, position: u32) void {
    assert(source.len <= std.math.maxInt(u32));
    assert(position < tokens.len);

    const before = written_before(tokens, position);
    const ends_block = if (before) |held| tokens[held].kind == .block_end else false;
    var commented = false;
    var scan = position + 1;

    assert(moves[position] == 0);

    for (position + 1..tokens.len) |_| {
        const held = tokens[scan];
        const blank = held.kind == .newline or held.length == 0;

        if (blank) {
            scan += 1;

            continue;
        }

        if (held.kind != .comment) break;
        if (!std.mem.startsWith(u8, held.text(source), "/*")) break;

        commented = true;
        scan += 1;
    }

    if (scan >= tokens.len) return;

    const next = tokens[scan];
    const body = next.kind == .block_start or text_equal(source, next, "if");

    if (!ends_block) return;
    if (!commented) return;
    if (!body) return;
    if (moves[scan] != 0) return;

    moves[position] = move_drops;
    moves[scan] = move_leads;
}

fn bar_led(source: []const u8, tokens: []const Token, flags: []const u16, moves: []u8) void {
    assert(flags.len == tokens.len);
    assert(moves.len == tokens.len);
    assert(source.len <= std.math.maxInt(u32));

    if (!bar_leads) return;

    for (tokens, 0..) |bar, index| {
        const position: u32 = @intCast(index);

        if (!text_equal(source, bar, "|")) continue;
        if (moves[position] != 0) continue;

        bar_led_member(source, tokens, flags, moves, position);
    }
}

fn bar_led_member(
    source: []const u8,
    tokens: []const Token,
    flags: []const u16,
    moves: []u8,
    position: u32,
) void {
    assert(source.len <= std.math.maxInt(u32));
    assert(position < tokens.len);
    assert(flags.len <= std.math.maxInt(u32));

    const bar = tokens[position];
    var commented = false;
    var scan = position + 1;

    assert(moves[position] == 0);

    for (0..bar_comment_max) |_| {
        if (scan >= tokens.len) break;

        const held = tokens[scan];
        const blank = held.kind == .newline or held.length == 0;

        if (blank) {
            scan += 1;

            continue;
        }

        if (held.kind != .comment) break;

        const joined = !commented and !parted(source, bar.end(), held.offset);
        if (joined) break;

        commented = true;
        scan += 1;
    }

    if (scan >= tokens.len) return;

    const member = tokens[scan];

    const membered = member.kind != .comment and moves[scan] == 0 and
        flags[scan] & type_nodes != 0;

    if (!commented) return;
    if (!membered) return;

    moves[position] = move_drops;
    moves[scan] = move_bars;
}

fn lifted(tokens: []const Token, moves: []const u8, position: u32) ?u32 {
    assert(position < tokens.len);
    assert(moves.len == tokens.len);

    return hoisted_operator(tokens, moves, position) orelse
        dropped_behind(tokens, moves, position);
}

fn dropped_behind(tokens: []const Token, moves: []const u8, position: u32) ?u32 {
    assert(position < tokens.len);

    var scan = position;

    assert(moves.len == tokens.len);

    for (0..position) |_| {
        scan -= 1;

        if (moves[scan] == move_drops) return scan;

        const token = tokens[scan];
        const blank = token.kind == .comment or token.kind == .newline or token.length == 0;
        if (!blank) return null;
    }

    return null;
}

fn hoisted_operator(tokens: []const Token, moves: []const u8, position: u32) ?u32 {
    assert(position < tokens.len);
    assert(moves.len == tokens.len);

    for (position + 1..tokens.len) |scan| {
        if (moves[scan] == move_drops) {
            assert(scan <= tokens.len);

            return @intCast(scan);
        }

        const token = tokens[scan];
        const blank = token.kind == .comment or token.kind == .newline or token.length == 0;
        if (!blank) return null;
    }

    return null;
}

pub fn marked(
    comptime Kind: type,
    tree: *const TreeType(Kind),
    tokens: []const Token,
    roles: *ArrayType(u16),
) error{Overflow}!void {
    assert(tokens.len < none);
    assert(tree.count() < none);

    roles.clear();

    for (0..tokens.len) |_| {
        try roles.pushed(0);
    }

    const held = roles.slice();

    for (tree.slice()) |*node| {
        if (node.token_start >= held.len) continue;

        held[node.token_start] |= brace.role_start;

        if (node.kind.category() == .block) held[node.token_start] |= brace.role_block;
        if (node.kind.category() == .lambda) held[node.token_start] |= brace.role_lambda;
    }

    assert(roles.count() == tokens.len);
}

fn spans_lines(source: []const u8, tokens: []const Token, from: u32, to: u32) bool {
    assert(tokens.len <= std.math.maxInt(u32));
    assert(to < none);

    const stop = @min(to, tokens.len);

    assert(stop <= tokens.len);
    assert(source.len < none);

    if (from >= stop) return false;

    const head = tokens[from].offset;
    const tail = @min(tokens[stop - 1].end(), @as(u32, @intCast(source.len)));
    if (head >= tail) return false;
    return parted(source, head, tail);
}

fn calling(source: []const u8, tokens: []const Token, at: u32) ?Calling {
    assert(at <= tokens.len);

    var depth: u32 = 0;
    var scan = at;
    var commas = false;

    assert(source.len < none);

    for (0..tail_scan_max) |_| {
        if (scan == 0) return null;

        scan -= 1;

        const text = tokens[scan].text(source);

        if (text_closes(text)) {
            depth += 1;

            continue;
        }

        if (text_opens(text)) {
            if (depth == 0) return .{ .open = scan, .separated = commas };

            depth -= 1;

            continue;
        }

        const comma = depth == 0 and walk.text_is(text, ",");

        if (comma) commas = true;
    }

    return null;
}

fn text_opens(text: []const u8) bool {
    assert(text.len < none);

    if (text.len != 1) return false;
    return text[0] == '(' or text[0] == '[' or text[0] == '{';
}

fn text_closes(text: []const u8) bool {
    assert(text.len < none);

    if (text.len != 1) return false;
    return text[0] == ')' or text[0] == ']' or text[0] == '}';
}

fn dotted_item(source: []const u8, tokens: []const Token, open: u32) u32 {
    var depth: u32 = 0;
    var links: u32 = 0;

    assert(open < tokens.len);
    assert(source.len < none);

    for (open + 1..tokens.len) |scan| {
        const text = tokens[scan].text(source);

        if (text_opens(text)) {
            depth += 1;

            continue;
        }

        if (text_closes(text)) {
            if (depth == 0) return links;

            depth -= 1;

            continue;
        }

        const dot = depth == 0 and walk.text_is(text, ".");

        if (dot) links += 1;
    }

    return links;
}

fn capping(source: []const u8, tokens: []const Token, open: u32, commas: bool, deep: bool) bool {
    const decided = commas or !deep;

    assert(open < tokens.len);
    assert(source.len < none);

    if (decided) return commas;
    if (open + 1 >= tokens.len) return true;

    const text = tokens[open + 1].text(source);
    const piped = walk.text_is(text, "|") or walk.text_is(text, "||");

    return !piped and !walk.text_is(text, "move");
}

fn headed(source: []const u8, tokens: []const Token, from: u32, to: u32) u32 {
    assert(tokens.len <= std.math.maxInt(u32));
    assert(from < none);
    assert(to < none);

    const stop: u32 = @min(to, @as(u32, @intCast(tokens.len)));

    assert(stop <= tokens.len);
    assert(source.len < none);

    if (from >= stop) return stop;

    for (from..stop) |scan| {
        if (text_opens(tokens[scan].text(source))) {
            assert(scan + 1 <= source.len);

            return @intCast(scan + 1);
        }
    }

    return stop;
}

fn closed_after(tokens: []const Token, from: u32, stop: u32) bool {
    assert(stop <= tokens.len);
    assert(from < none);

    if (from + 1 >= stop) return true;

    for (from + 1..stop) |scan| {
        const token = tokens[scan];
        if (token.length == 0) continue;
        if (token.kind == .newline) continue;

        return token.kind == .block_end or token.is_punctuation(.bracket_close) or
            token.is_punctuation(.paren_close);
    }

    return true;
}

pub fn spelled(source: []const u8, tokens: []const Token, from: u32, stop: u32) u32 {
    assert(from < none);

    var held: u32 = 0;
    var before: ?u32 = null;
    var commas = false;

    assert(stop <= tokens.len);
    assert(source.len < none);

    if (from >= stop) return 0;

    for (from..stop) |scan| {
        const token = tokens[scan];
        const comma = token.is_punctuation(.comma) and closed_after(tokens, @intCast(scan), stop);
        const skips = token.length == 0 or token.kind == .newline or comma;

        if (skips) {
            commas = commas or comma;

            continue;
        }

        const opens = token.is_punctuation(.paren_open) or token.is_punctuation(.bracket_open) or
            token.kind == .block_start;

        const banged = if (before) |at| tokens[at].is_punctuation(.bang) and opens else false;
        const spaced_before = if (before) |at| tokens[at].end() < token.offset else false;
        const gapped = if (commas) token.kind == .block_end else !banged and spaced_before;

        held += @intFromBool(gapped) + walk.columns(source, token.offset, token.end());
        before = @intCast(scan);
        commas = false;
    }

    return held;
}

pub fn argued(tokens: []const Token, source: []const u8, from: u32, stop: u32) u32 {
    assert(stop <= tokens.len);
    assert(source.len < none);
    assert(from < none);

    if (from >= stop) return from;

    for (from..stop) |scan| {
        const text = tokens[scan].text(source);
        const opens = walk.text_is(text, "(") or walk.text_is(text, "{");

        if (opens) {
            assert(scan < stop);

            return @intCast(scan);
        }
    }

    return from;
}

pub fn soled(tokens: []const Token, source: []const u8, open: u32, stop: u32) bool {
    var depth: u32 = 0;
    var lambda = false;
    var before: ?u32 = null;

    assert(open < tokens.len);
    assert(stop <= tokens.len);

    if (!text_equal(source, tokens[open], "(")) return false;
    if (open >= stop) return false;

    for (open..stop) |scan| {
        const token = tokens[scan];
        const kind = token.kind;
        const opens = if (before) |at| !walk.ends_operand(tokens[at].kind) else true;

        if (std.mem.findScalar(u8, token.text(source), '\n') != null) return false;
        if (kind == .block_start) return false;

        const opening_kind = walk.is_open(kind);
        const closing_kind = !opening_kind and walk.is_close(kind);
        const other = !opening_kind and !closing_kind and depth == 1;
        const piped = other and text_equal(source, token, "|") and (lambda or opens);

        const listed = other and !piped and !lambda and token.is_punctuation(.comma) and
            soled_more(tokens, @intCast(scan + 1), stop);

        if (opening_kind) depth += 1;

        if (closing_kind) {
            depth -|= 1;

            if (depth == 0) return true;
        }

        if (piped) lambda = !lambda;
        if (listed) return false;

        const coded_token = token.length > 0 and kind != .newline and kind != .comment;

        if (coded_token) before = @intCast(scan);
    }

    return false;
}

fn soled_more(tokens: []const Token, from: u32, stop: u32) bool {
    assert(stop <= tokens.len);
    assert(from <= stop);

    for (tokens[from..stop]) |held| {
        const open = held.length > 0 and !walk.is_close(held.kind);
        if (open) return true;
    }

    return false;
}

fn stated(tokens: []const Token, from: u32, stop: u32) bool {
    var blocks: [body_stack_max]bool = @splat(false);
    var depth: u32 = 0;

    assert(stop <= tokens.len);
    assert(from < none);

    for (tokens[from..stop]) |token| {
        const opens = token.kind == .block_start or token.is_punctuation(.bracket_open) or
            token.is_punctuation(.paren_open);

        const closes = token.kind == .block_end or token.is_punctuation(.bracket_close) or
            token.is_punctuation(.paren_close);

        if (opens) {
            if (depth == body_stack_max) return false;

            blocks[depth] = token.kind == .block_start;
            depth += 1;

            continue;
        }

        if (closes) {
            depth -|= 1;

            continue;
        }

        const statement = token.is_punctuation(.semicolon) and depth > 0 and blocks[depth - 1];
        if (statement) return true;
    }

    return false;
}

fn flat_sole(tokens: []const Token, open: u32, stop: u32) bool {
    assert(stop <= tokens.len);
    assert(open < none);

    if (open + 1 >= stop) return false;

    for (tokens[open + 1 .. stop]) |token| {
        if (walk.is_open(token.kind)) return false;
        if (token.kind == .block_start) return false;
        if (walk.is_close(token.kind)) return true;
    }

    return false;
}

pub fn linked(tokens: []const Token, from: u32, stop: u32) u32 {
    var depth: u32 = 0;
    var found: u32 = 0;

    assert(stop <= tokens.len);
    assert(from < none);

    if (from >= stop) return 0;

    for (tokens[from..stop]) |token| {
        const opens = token.kind == .block_start or token.is_punctuation(.paren_open);
        const closes = token.kind == .block_end or token.is_punctuation(.paren_close);

        if (opens) {
            depth += 1;

            continue;
        }

        if (closes) {
            depth -|= 1;

            continue;
        }

        const dot = depth == 0 and token.is_punctuation(.dot);

        if (dot) found += 1;
    }

    return found;
}

pub fn overflows(
    comptime Kind: type,
    nodes: []const NodeType(Kind),
    source: []const u8,
    tokens: []const Token,
    comptime rules: *const TailsType(Kind),
    closure: Closure,
    body: *const NodeType(Kind),
) bool {
    assert(tokens.len <= std.math.maxInt(u32));
    assert(closure.lambda <= body.token_start);

    const end: u32 = @min(body.token_end, @as(u32, @intCast(tokens.len)));
    const lambda = closure.lambda;

    assert(end <= tokens.len);
    assert(lambda <= body.token_start);

    if (body.token_start >= end) return false;
    if (body_walk.brokens(Kind, nodes, source, tokens, rules, body)) return true;

    const wide = rules.wraps(body.kind) and overflows_wide(Kind, source, tokens, rules, body, end);
    if (wide) return true;
    if (!closure.called) return false;

    const stop = if (rules.wraps(body.kind))
        end
    else
        headed(source, tokens, body.token_start, body.token_end);

    const start = body.token_start;
    return overflows_called(source, tokens, rules.call_width, lambda, start, closure.deep, stop);
}

fn overflows_wide(
    comptime Kind: type,
    source: []const u8,
    tokens: []const Token,
    comptime rules: *const TailsType(Kind),
    body: *const NodeType(Kind),
    end: u32,
) bool {
    assert(source.len <= std.math.maxInt(u32));
    assert(end <= tokens.len);

    const argues = rules.argued(body.kind);
    const head = if (argues) argued(tokens, source, body.token_start, end) else body.token_start;
    const chained = rules.chained(body.kind) and linked(tokens, body.token_start, end) < 2;
    const width = rules.bodies(body.kind);
    const ones = body_ones and argues and soled(tokens, source, head, end);
    const parenthesized = !argues and parenthesized_body(source, tokens, body.token_start, end);
    const inside = call_args and (argues or parenthesized) and head < end and end > 0;
    const from = if (inside) head + 1 else head;
    const stop = if (inside) end - 1 else end;

    assert(body.token_start < end);

    if (width == 0) return false;
    if (chained) return false;
    if (ones) return false;
    return spelled(source, tokens, from, stop) > width;
}

fn parenthesized_body(source: []const u8, tokens: []const Token, start: u32, end: u32) bool {
    assert(start < end);
    assert(end <= tokens.len);

    if (!text_equal(source, tokens[start], "(")) return false;

    var depth: u32 = 0;

    for (start..end) |scan| {
        const kind = tokens[scan].kind;

        if (walk.is_open(kind)) depth += 1;
        if (!walk.is_close(kind)) continue;

        depth -|= 1;

        if (depth == 0) return scan + 1 == end;
    }

    return false;
}

fn overflows_called(
    source: []const u8,
    tokens: []const Token,
    call_width: u32,
    lambda: u32,
    start: u32,
    deep: bool,
    stop: u32,
) bool {
    assert(source.len <= std.math.maxInt(u32));
    assert(call_width < none);
    assert(lambda <= start);

    var scan = lambda;

    assert(stop <= tokens.len);

    for (0..call_walk_max) |_| {
        const call = calling(source, tokens, scan) orelse return false;

        const horizontal = !call_heads or
            head_columns(source, tokens, call.open, start) <= call_width;

        const sole = call_soles and !call.separated and
            dotted_item(source, tokens, call.open) >= call_links;

        const capped = capping(source, tokens, call.open, call.separated, deep) and horizontal and
            !sole and !spans_lines(source, tokens, call.open, lambda) and
            spelled(source, tokens, call.open + 1, stop) > call_width;

        if (capped) return true;
        if (!deep) break;

        scan = call.open;
    }

    return cascaded(source, tokens, call_width, lambda, stop);
}

fn cascaded(
    source: []const u8,
    tokens: []const Token,
    call_width: u32,
    lambda: u32,
    stop: u32,
) bool {
    assert(lambda <= tokens.len);
    assert(stop <= tokens.len);

    if (!call_cascades) return false;
    assert(source.len <= std.math.maxInt(u32));

    const call = calling(source, tokens, lambda) orelse return false;
    if (call.separated) return false;
    if (!text_equal(source, tokens[call.open], "(")) return false;

    const inner = call.open;
    var narrow: u32 = 0;
    var step = inner;

    for (0..call_walk_max) |_| {
        const outer = calling(source, tokens, step) orelse break;
        if (outer.separated) break;
        if (!text_equal(source, tokens[outer.open], "(")) break;
        if (callee_width(source, tokens, outer.open) == 0) break;
        if (!callee_led(source, tokens, step, outer.open)) break;

        const dots = call_dotted and dotted(source, tokens, step);
        if (dots) break;

        narrow += callee_width(source, tokens, step) + brace_columns;
        step = outer.open;
    }

    if (narrow == 0) return false;
    return spelled(source, tokens, inner + 1, stop) + narrow > call_width;
}

fn dotted(source: []const u8, tokens: []const Token, open: u32) bool {
    assert(open < tokens.len);

    var scan = open;

    assert(source.len < none);

    for (0..open) |_| {
        const token = tokens[scan - 1];
        const blank = token.kind == .newline or token.length == 0;

        if (blank) {
            scan -= 1;

            continue;
        }

        if (!callee_part(source, token)) return text_equal(source, token, ".");

        scan -= 1;
    }

    return false;
}

fn callee_led(source: []const u8, tokens: []const Token, open: u32, outer: u32) bool {
    assert(source.len <= std.math.maxInt(u32));
    assert(outer < open);

    var scan = open;

    assert(open < tokens.len);

    for (0..open) |_| {
        if (scan == 0) return false;

        const token = tokens[scan - 1];
        const blank = token.kind == .newline or token.length == 0;

        if (blank) {
            scan -= 1;

            continue;
        }

        if (!callee_part(source, token)) return scan - 1 == outer;

        scan -= 1;
    }

    return false;
}

fn callee_part(source: []const u8, token: Token) bool {
    assert(token.end() <= source.len);

    const text = token.text(source);

    assert(text.len == token.length);

    if (token.kind == .identifier) return true;

    return walk.text_is(text, "::") or walk.text_is(text, "!") or
        walk.text_is(text, ":");
}

fn callee_width(source: []const u8, tokens: []const Token, open: u32) u32 {
    assert(open < tokens.len);

    var scan = open;
    var width: u32 = 0;

    assert(source.len < none);

    for (0..open) |_| {
        const token = tokens[scan - 1];
        const blank = token.kind == .newline or token.length == 0;

        if (blank) {
            scan -= 1;

            continue;
        }

        if (!callee_part(source, token)) break;

        width += walk.columns(source, token.offset, token.end());
        scan -= 1;
    }

    return width;
}

fn head_columns(source: []const u8, tokens: []const Token, open: u32, body: u32) u32 {
    assert(source.len <= std.math.maxInt(u32));
    assert(open < tokens.len);
    assert(body <= tokens.len);

    const opened: u32 = if (braced_head(tokens, body)) 0 else brace_columns;
    const returned = spelled(source, tokens, open + 1, body) + opened;

    assert(returned < std.math.maxInt(u32));

    return returned;
}

fn braced_head(tokens: []const Token, body: u32) bool {
    assert(body <= tokens.len);

    var scan = body;

    assert(tokens.len < none);

    for (0..body) |_| {
        scan -= 1;

        const token = tokens[scan];
        if (token.length == 0) continue;
        if (token.kind == .newline) continue;
        return token.kind == .block_start;
    }

    return false;
}

fn child_last(comptime Kind: type, nodes: []const NodeType(Kind), node: *const NodeType(Kind)) u32 {
    var held = node.child_first;

    assert(held == none or held < nodes.len);
    assert(nodes.len < none);

    for (0..nodes.len) |_| {
        if (held == none) break;
        if (nodes[held].sibling_next == none) break;

        held = nodes[held].sibling_next;
    }

    return held;
}

fn bodied(
    comptime Kind: type,
    tree: *const TreeType(Kind),
    source: []const u8,
    tokens: []const Token,
    comptime rules: *const TailsType(Kind),
    flags: []u16,
) void {
    assert(source.len <= std.math.maxInt(u32));

    const nodes = tree.slice();

    assert(flags.len == tokens.len);
    assert(nodes.len < none);

    for (nodes) |*node| {
        if (!rules.lambda(node.kind)) continue;

        const held = child_last(Kind, nodes, node);
        if (held == none) continue;

        const body = &nodes[held];
        const called = !(lambda_pairs and paired_lambda(Kind, nodes, rules, node));
        const lambda = node.token_start;

        if (body.token_start == node.token_start) continue;

        const forced = forced_body(Kind, nodes, source, tokens, rules, node, body);

        if (!forced) {
            if (!rules.wraps(body.kind)) continue;

            const closure: Closure = .{ .lambda = lambda, .called = called, .deep = false };
            if (!overflows(Kind, nodes, source, tokens, rules, closure, body)) continue;
        }

        if (body.token_start == 0) continue;

        const stop: u32 = @min(body.token_end, @as(u32, @intCast(tokens.len)));

        flag_set(flags, body.token_start - 1, block_opens);
        flag_set(flags, stop - 1, block_closes);
    }
}

fn forced_body(
    comptime Kind: type,
    nodes: []const NodeType(Kind),
    source: []const u8,
    tokens: []const Token,
    comptime rules: *const TailsType(Kind),
    node: *const NodeType(Kind),
    body: *const NodeType(Kind),
) bool {
    assert(body.token_start >= node.token_start);
    assert(body.token_end <= node.token_end);

    if (!rules.forces(body.kind)) return false;
    if (body.child_first == none) return false;
    assert(nodes.len <= std.math.maxInt(u32));
    assert(source.len <= std.math.maxInt(u32));
    assert(tokens.len <= std.math.maxInt(u32));

    const word = forced_word(source, tokens, body) orelse return false;
    if (walk.text_is(word, "if")) return !forced_single(Kind, nodes, source, tokens, rules, body);

    const held = child_last(Kind, nodes, body);
    if (held == none) return false;
    if (!forced_filled(Kind, nodes, tokens, &nodes[held])) return false;
    if (!walk.text_is(word, "loop")) return true;
    return forced_last(Kind, nodes, rules, node);
}

fn forced_word(source: []const u8, tokens: []const Token, body: anytype) ?[]const u8 {
    assert(source.len <= std.math.maxInt(u32));
    assert(tokens.len <= std.math.maxInt(u32));
    assert(body.token_start <= body.token_end);

    const stop: u32 = @min(body.token_end, @as(u32, @intCast(tokens.len)));
    const words = comptime [_][]const u8{ "for", "if", "loop", "while" };

    assert(stop <= tokens.len);

    for (body.token_start..@min(stop, body.token_start + forced_scan_max)) |scan| {
        const text = tokens[scan].text(source);

        inline for (words) |word| {
            if (walk.text_is(text, word)) return text;
        }
    }

    return null;
}

fn forced_last(
    comptime Kind: type,
    nodes: []const NodeType(Kind),
    comptime rules: *const TailsType(Kind),
    node: *const NodeType(Kind),
) bool {
    assert(nodes.len < none);

    if (node.parent == none) return false;

    const parent = &nodes[node.parent];
    if (!rules.lasts(parent.kind)) return false;
    return &nodes[child_last(Kind, nodes, parent)] == node;
}

fn forced_filled(
    comptime Kind: type,
    nodes: []const NodeType(Kind),
    tokens: []const Token,
    block: *const NodeType(Kind),
) bool {
    assert(nodes.len < none);
    assert(block.token_start <= block.token_end);

    if (block.child_first != none) return true;
    assert(tokens.len <= std.math.maxInt(u32));

    const stop: u32 = @min(block.token_end, @as(u32, @intCast(tokens.len)));

    for (block.token_start..stop) |scan| {
        if (tokens[scan].kind == .comment) return true;
    }

    return false;
}

fn forced_single(
    comptime Kind: type,
    nodes: []const NodeType(Kind),
    source: []const u8,
    tokens: []const Token,
    comptime rules: *const TailsType(Kind),
    body: *const NodeType(Kind),
) bool {
    assert(body.child_first != none);
    assert(nodes.len < none);

    const then = nodes[body.child_first].sibling_next;
    if (then == none) return false;

    const other = nodes[then].sibling_next;
    if (other == none) return false;
    if (nodes[other].kind == body.kind) return false;
    if (!forced_simple(Kind, nodes, source, tokens, &nodes[then])) return false;
    if (!forced_simple(Kind, nodes, source, tokens, &nodes[other])) return false;

    const stop: u32 = @min(body.token_end, @as(u32, @intCast(tokens.len)));
    return spelled(source, tokens, body.token_start, stop) <= rules.width;
}

fn forced_simple(
    comptime Kind: type,
    nodes: []const NodeType(Kind),
    source: []const u8,
    tokens: []const Token,
    node: *const NodeType(Kind),
) bool {
    assert(nodes.len <= std.math.maxInt(u32));
    assert(source.len <= std.math.maxInt(u32));
    assert(tokens.len <= std.math.maxInt(u32));

    var block = node;

    for (0..forced_scan_max) |_| {
        const child = block.child_first;
        if (child == none) return false;

        const inner = &nodes[child];
        const same = inner.token_start == block.token_start and inner.token_end == block.token_end;
        if (!same) break;

        block = inner;
    }

    const first = block.child_first;
    if (first == none) return false;
    if (nodes[first].sibling_next != none) return false;

    const stop: u32 = @min(block.token_end, @as(u32, @intCast(tokens.len)));

    for (block.token_start..stop) |scan| {
        const token = tokens[scan];
        if (token.kind == .comment) return false;
        if (token.is_punctuation(.semicolon)) return false;
    }

    return walk.text_is(tokens[block.token_start].text(source), "{");
}

fn paired_lambda(
    comptime Kind: type,
    nodes: []const NodeType(Kind),
    comptime rules: *const TailsType(Kind),
    node: *const NodeType(Kind),
) bool {
    if (node.parent == none) return false;
    if (node.parent != none) assert(node.parent < nodes.len);

    const parent = &nodes[node.parent];
    var lambdas: u32 = 0;
    var child = parent.child_first;

    assert(node.parent < nodes.len);

    assert(child != none);

    const grouped = rules.argued(parent.kind) or rules.chained(parent.kind);
    if (!grouped) return false;

    for (0..lambda_pair_max) |_| {
        if (child == none) break;

        lambdas += @intFromBool(rules.lambda(nodes[child].kind));
        child = nodes[child].sibling_next;
    }

    return lambdas > 1;
}

fn skipped(
    comptime Kind: type,
    nodes: []const NodeType(Kind),
    source: []const u8,
    tokens: []const Token,
    node: *const NodeType(Kind),
) bool {
    assert(nodes.len <= std.math.maxInt(u32));
    assert(source.len <= std.math.maxInt(u32));

    var held = node;

    assert(node.token_start <= node.token_end);
    assert(tokens.len < none);

    for (0..skip_walk_max) |_| {
        const start = held.token_start;

        const inside = start + 4 < tokens.len and text_equal(source, tokens[start], "#") and
            text_equal(source, tokens[start + 2], "rustfmt") and
            text_equal(source, tokens[start + 4], "skip");

        const before = start >= 4 and text_equal(source, tokens[start - 1], "]") and
            text_equal(source, tokens[start - 2], "skip") and
            text_equal(source, tokens[start - 3], "::") and
            text_equal(source, tokens[start - 4], "rustfmt");

        if (inside) return true;
        if (before) return true;
        if (held.parent == none) return false;

        held = &nodes[held.parent];
    }

    return false;
}

fn inner_of(
    comptime Kind: type,
    nodes: []const NodeType(Kind),
    node: *const NodeType(Kind),
) *const NodeType(Kind) {
    var held = node;

    assert(node.token_start <= node.token_end);
    assert(nodes.len < none);

    for (0..tail_walk_max) |_| {
        const child = held.child_first;
        if (child == none) return held;

        const inner = &nodes[child];
        const covered = inner.token_start >= held.token_start and inner.token_end <= held.token_end;
        const narrower = inner.token_start > held.token_start or inner.token_end < held.token_end;
        const inside = covered and narrower;

        if (inner.sibling_next != none) return held;
        if (!inside) return held;

        held = inner;
    }

    return held;
}

fn operand_of(
    comptime Kind: type,
    nodes: []const NodeType(Kind),
    comptime rules: *const TailsType(Kind),
    node: *const NodeType(Kind),
) *const NodeType(Kind) {
    assert(nodes.len < none);

    var held = inner_of(Kind, nodes, node);

    assert(node.token_start <= node.token_end);

    for (0..tail_walk_max) |_| {
        if (!rules.operands(held.kind)) return held;
        if (held.child_first == none) return held;

        held = inner_of(Kind, nodes, &nodes[held.child_first]);
    }

    return held;
}

fn bodied_head(source: []const u8, tokens: []const Token, position: u32) bool {
    assert(position < tokens.len);

    const token = tokens[position];

    const heads = [_][]const u8{
        "async",
        "const",
        "for",
        "if",
        "loop",
        "match",
        "try",
        "unsafe",
        "while",
    };

    assert(token.end() <= source.len);

    if (token.kind == .block_start) return true;

    for (heads) |head| {
        if (std.mem.eql(u8, token.text(source), head)) return true;
    }

    return false;
}

fn pattern_flat(
    source: []const u8,
    tokens: []const Token,
    from: u32,
    arrow: u32,
    call: u32,
    literal: u32,
) bool {
    var opens: [pattern_depth_max]u32 = @splat(0);
    var depth: u32 = 0;

    assert(from < tokens.len);
    assert(arrow <= tokens.len);

    if (text_equal(source, tokens[from], "#")) return false;
    if (from >= arrow) return true;

    for (from..arrow) |index| {
        const scan: u32 = @intCast(index);
        const kind = tokens[scan].kind;
        const opening_kind = walk.is_open(kind) or kind == .block_start;
        const closing_kind = walk.is_close(kind) or kind == .block_end;

        if (opening_kind) {
            if (depth == pattern_depth_max) return false;

            opens[depth] = scan;
            depth += 1;

            continue;
        }

        if (closing_kind) {
            if (depth == 0) return false;

            depth -= 1;

            const open = opens[depth];
            const cap = if (tokens[open].kind == .block_start) literal else call;
            if (spelled(source, tokens, open + 1, scan) > cap) return false;

            continue;
        }

        const piped = depth == 0 and text_equal(source, tokens[scan], "|");
        if (piped) return false;
    }

    return depth == 0;
}

fn arm_arrow(
    source: []const u8,
    tokens: []const Token,
    start: u32,
    arrow: u32,
    lead: u32,
    flattens: bool,
    width: u32,
) u32 {
    assert(start <= arrow);
    assert(arrow < tokens.len);
    assert(source.len <= std.math.maxInt(u32));
    assert(lead < none);
    assert(width < none);

    if (!flattens) {
        const returned = column_of(source, tokens, arrow, width) + 3;

        assert(returned < std.math.maxInt(u32));

        return returned;
    }

    const returned = lead + spelled(source, tokens, start, arrow) + 4;

    assert(returned < std.math.maxInt(u32));

    return returned;
}

fn armed(
    comptime Kind: type,
    tree: *const TreeType(Kind),
    source: []const u8,
    tokens: []const Token,
    comptime rules: *const TailsType(Kind),
    widths: Widths,
    flags: []u16,
) void {
    assert(source.len <= std.math.maxInt(u32));
    assert(widths.line > 0);

    const nodes = tree.slice();

    assert(flags.len == tokens.len);
    assert(nodes.len < none);

    for (0..nodes.len) |index| {
        const position: u32 = @intCast(index);
        const arm = arm_body(Kind, nodes, source, tokens, rules, widths, position) orelse continue;
        const start = nodes[arm.body].token_start;

        if (armed_node(Kind, nodes, source, tokens, rules, widths, arm)) {
            arm_marks(source, tokens, start, arm.stop, flags);
        }
    }
}

fn armed_node(
    comptime Kind: type,
    nodes: []const NodeType(Kind),
    source: []const u8,
    tokens: []const Token,
    comptime rules: *const TailsType(Kind),
    widths: Widths,
    arm: Arm,
) bool {
    assert(nodes.len <= std.math.maxInt(u32));
    assert(source.len <= std.math.maxInt(u32));
    assert(arm.stop <= tokens.len);
    assert(widths.line > 0);

    const node = &nodes[arm.node];
    const body = &nodes[arm.body];
    const start = body.token_start;
    const strung = arm_strung(source, tokens, start, arm.stop);
    const forced = strung.spilled or arm_forced(source, tokens, start);

    assert(start > node.token_start);

    if (forced) return true;
    if (bodied_head(source, tokens, start)) return false;

    const lead = arm_lead(source, tokens, node.token_start, widths.indent);

    const flattens = arm_arrows and
        pattern_flat(source, tokens, node.token_start, start - 1, rules.call_width, rules.literal);

    const arrow = arm_arrow(
        source,
        tokens,
        node.token_start,
        start - 1,
        lead,
        flattens,
        widths.indent,
    );

    const margin: u32 = @intFromBool(arm_margins);
    const spread = spelled(source, tokens, start, arm.stop);
    const jumping = arm_jump_caps and arm_jump(source, tokens[start]);

    if (arrow + spread + margin <= widths.line) {
        return jumping and body_walk.capped_parts(Kind, nodes, source, tokens, rules, body);
    }

    const next = lead + widths.indent + spread + margin;
    const seats = arm_lines and (next <= widths.line or strung.kept);

    const overlong = arm_lined and !seats and !arm_bracketed(tokens, start, arm.stop) and
        lined_of(source, tokens, node.token_start, widths.indent) > widths.line;

    if (overlong) return false;

    const fits = next <= widths.line and
        !body_walk.capped_parts(Kind, nodes, source, tokens, rules, body);

    return armed_wide(Kind, nodes, source, tokens, rules, arm, fits);
}

fn armed_wide(
    comptime Kind: type,
    nodes: []const NodeType(Kind),
    source: []const u8,
    tokens: []const Token,
    comptime rules: *const TailsType(Kind),
    arm: Arm,
    fits: bool,
) bool {
    assert(nodes.len <= std.math.maxInt(u32));
    assert(source.len <= std.math.maxInt(u32));
    assert(tokens.len <= std.math.maxInt(u32));
    assert(arm.body < nodes.len);

    const body = &nodes[arm.body];
    const stop = arm.stop;
    const jumped = arm_inners and arm_jump(source, tokens[body.token_start]);
    const inner = if (jumped) body else operand_of(Kind, nodes, rules, body);
    const width = rules.bodies(inner.kind);
    const chained = rules.chained(inner.kind) and linked(tokens, body.token_start, stop) < 2;
    const argues = arm_argued and rules.argued(inner.kind);
    const capped = if (argues) argued(tokens, source, body.token_start, stop) else body.token_start;

    const uncapped = body_walk.sole_flat(
        Kind,
        nodes,
        source,
        tokens,
        rules,
        inner,
        .{ .open = capped, .stop = stop },
    );

    const ones = arm_ones and soled(tokens, source, capped, stop) and
        (flat_sole(tokens, capped, stop) or uncapped);

    const over = width > 0 and !chained and !ones and spelled(source, tokens, capped, stop) > width;
    const lined_arm = !over and fits;
    const flat = !lined_arm and rules.flattens(inner.kind);

    assert(body.token_start < stop);
    assert(stop <= tokens.len);

    return !flat;
}

fn arm_jump(source: []const u8, token: Token) bool {
    assert(token.end() <= source.len);

    const text = token.text(source);

    assert(arm_jumps.len == 4);

    for (arm_jumps) |jump| {
        if (std.mem.eql(u8, text, jump)) return true;
    }

    return false;
}

fn arm_body(
    comptime Kind: type,
    nodes: []const NodeType(Kind),
    source: []const u8,
    tokens: []const Token,
    comptime rules: *const TailsType(Kind),
    widths: Widths,
    index: u32,
) ?Arm {
    assert(nodes.len <= std.math.maxInt(u32));
    assert(tokens.len <= std.math.maxInt(u32));
    assert(index < nodes.len);

    const node = &nodes[index];
    if (!rules.arms(node.kind)) return null;
    if (widths.line == 0) return null;

    const held = child_last(Kind, nodes, node);
    if (held == none) return null;

    const body = &nodes[held];
    const stop: u32 = @min(body.token_end, @as(u32, @intCast(tokens.len)));

    assert(held < nodes.len);
    assert(stop <= tokens.len);

    if (body.token_start >= stop) return null;
    if (body.token_start == node.token_start) return null;
    if (comment_within(tokens, node.token_start, node.token_end)) return null;
    if (skipped(Kind, nodes, source, tokens, node)) return null;
    return .{ .body = held, .node = index, .stop = stop };
}

fn arm_strung(source: []const u8, tokens: []const Token, start: u32, stop: u32) Strung {
    assert(start < stop);
    assert(stop <= tokens.len);
    assert(source.len <= std.math.maxInt(u32));

    if (!arm_strings) return .{ .kept = false, .spilled = false };
    if (!lone_string(source, tokens, start, stop)) return .{ .kept = false, .spilled = false };

    const token = tokens[start];

    return .{
        .kept = string_kept(source, token),
        .spilled = std.mem.findScalar(u8, token.text(source), '\n') != null,
    };
}

fn lone_string(source: []const u8, tokens: []const Token, start: u32, stop: u32) bool {
    assert(source.len <= std.math.maxInt(u32));
    assert(start < tokens.len);

    const token = tokens[start];
    const text = token.text(source);

    assert(stop <= tokens.len);

    if (start + 1 != stop) return false;
    if (token.kind != .string) return false;
    if (text.len == 0) return false;
    return text[0] == '"' or text[0] == 'b' or text[0] == 'c' or text[0] == 'r';
}

fn string_kept(source: []const u8, token: Token) bool {
    assert(token.end() <= source.len);

    const text = token.text(source);

    assert(text.len == token.length);

    if (text.len == 0) return false;
    if (text[0] == '"') return std.mem.findScalar(u8, text, '\n') == null;
    return text[0] == 'r';
}

fn arm_lead(source: []const u8, tokens: []const Token, start: u32, indent: u32) u32 {
    assert(source.len < none);
    assert(start < tokens.len);
    assert(indent < none);

    const line_first = !arm_leads or line_led(source, tokens, start);
    const returned = leading_of(source, tokens, start, indent) + if (line_first) 0 else indent;

    assert(returned < std.math.maxInt(u32));

    return returned;
}

fn line_led(source: []const u8, tokens: []const Token, position: u32) bool {
    assert(source.len <= std.math.maxInt(u32));
    assert(tokens.len <= std.math.maxInt(u32));
    assert(position < tokens.len);

    const offset = tokens[position].offset;
    const head = line_head(source, offset);

    assert(head <= offset);
    assert(offset <= source.len);

    return std.mem.findNone(u8, source[head..offset], " \t") == null;
}

fn line_head(source: []const u8, offset: u32) u32 {
    assert(offset <= source.len);
    assert(source.len < none);

    const before = std.mem.findScalarLast(u8, source[0..offset], '\n') orelse return 0;
    assert(before + 1 <= source.len);

    return @intCast(before + 1);
}

fn arm_bracketed(tokens: []const Token, start: u32, stop: u32) bool {
    assert(start < stop);
    assert(stop <= tokens.len);

    for (start..stop - 1) |index| {
        const kind = tokens[index].kind;
        const next = tokens[index + 1].kind;

        if (!walk.is_open(kind)) {
            if (kind != .block_start) continue;
        }

        if (walk.is_close(next)) continue;
        if (next == .block_end) continue;
        return true;
    }

    return false;
}

fn arm_forced(source: []const u8, tokens: []const Token, start: u32) bool {
    assert(source.len <= std.math.maxInt(u32));
    assert(start < tokens.len);

    const text = tokens[start].text(source);

    assert(text.len == tokens[start].length);

    if (!arm_forces) return false;

    return walk.text_is(text, "for") or walk.text_is(text, "if") or
        walk.text_is(text, "while");
}

fn arm_marks(source: []const u8, tokens: []const Token, start: u32, stop: u32, flags: []u16) void {
    assert(stop > 0);
    assert(flags.len == tokens.len);
    assert(source.len <= std.math.maxInt(u32));
    assert(start < tokens.len);

    if (start == 0) return;

    flag_set(flags, start - 1, block_opens);
    flag_set(flags, stop - 1, block_closes);

    const semi = arm_semis and arm_jump(source, tokens[start]);
    const comma = stop < tokens.len and tokens[stop].is_punctuation(.comma);

    if (semi) flag_set(flags, stop - 1, end_owed);
    if (comma) flag_set(flags, stop, block_drops);
}

fn trailing(source: []const u8, tokens: []const Token, stop: u32, skip: u32) u32 {
    var held: u32 = 0;

    assert(stop <= tokens.len);
    assert(source.len < none);

    for (stop..tokens.len) |scan| {
        const token = tokens[scan];
        const blank = token.length == 0 or token.kind == .newline or scan == skip;
        if (blank) continue;

        const text = token.text(source);
        const ends = walk.text_is(text, ",") or walk.text_is(text, ";");

        const tail = ends or walk.text_is(text, ")") or walk.text_is(text, "]") or
            walk.text_is(text, "?");

        if (!tail) return held;

        held += @intFromBool(walk.text_is(text, "?")) +
            walk.columns(source, token.offset, token.end());

        if (ends) return held;
    }

    return held;
}

fn dropped_body(
    comptime Kind: type,
    tree: *const TreeType(Kind),
    source: []const u8,
    tokens: []const Token,
    comptime rules: *const TailsType(Kind),
    widths: Widths,
    flags: []u16,
) void {
    assert(source.len <= std.math.maxInt(u32));
    assert(widths.line > 0);

    const nodes = tree.slice();

    assert(flags.len == tokens.len);
    assert(nodes.len < none);

    for (nodes) |*node| {
        if (!rules.lambda(node.kind)) continue;

        const block = dropped_body_block(Kind, nodes, source, tokens, rules, widths, node) orelse
            continue;

        flag_set(flags, block.token_start, block_drops);
        flag_set(flags, block.token_end - 1, block_drops);
    }
}

fn dropped_body_block(
    comptime Kind: type,
    nodes: []const NodeType(Kind),
    source: []const u8,
    tokens: []const Token,
    comptime rules: *const TailsType(Kind),
    widths: Widths,
    node: *const NodeType(Kind),
) ?*const NodeType(Kind) {
    assert(nodes.len <= std.math.maxInt(u32));
    assert(source.len <= std.math.maxInt(u32));
    assert(tokens.len <= std.math.maxInt(u32));
    assert(widths.line > 0);

    const block = blocked(Kind, nodes, source, tokens, node) orelse return null;
    const expr = &nodes[block.child_first];
    const called = !(lambda_pairs and paired_lambda(Kind, nodes, rules, node));
    const lambda = node.token_start;

    assert(block.child_first != none);
    assert(block.token_end > 0);

    if (rules.forces(expr.kind)) return null;
    if (rules.keeps(expr.kind)) return null;

    const closure: Closure = .{ .lambda = lambda, .called = called, .deep = call_nested };
    if (overflows(Kind, nodes, source, tokens, rules, closure, expr)) return null;

    const stop: u32 = @min(expr.token_end, @as(u32, @intCast(tokens.len)));
    const under = seated(Kind, nodes, source, tokens, rules, widths, node);
    const spread = under + spelled(source, tokens, node.token_start, stop);

    const flat = under + spelled(source, tokens, node.token_start, block.token_start) + 1 +
        spelled(source, tokens, expr.token_start, stop) +
        trailing(source, tokens, stop, block.token_end -| 1);

    const measured = if (body_tails) flat else spread;
    const wraps = rules.wraps(expr.kind);
    const long = wraps and measured > widths.line;
    const statements = body_statements and wraps and stated(tokens, expr.token_start, stop);

    if (long) return null;
    if (statements) return null;

    const front = under +
        spelled(source, tokens, node.token_start, fronted(Kind, tokens, expr, stop));

    const fronts = body_fronts and !wraps and front > widths.line;
    return if (fronts) null else block;
}

fn fronted(comptime Kind: type, tokens: []const Token, expr: *const NodeType(Kind), stop: u32) u32 {
    var depth: u32 = 0;

    assert(stop <= tokens.len);
    assert(expr.token_start <= expr.token_end);

    if (expr.token_start >= stop) return stop;

    for (expr.token_start..stop) |scan| {
        const kind = tokens[scan].kind;
        const opened = kind == .block_start and depth == 0;

        if (opened) {
            assert(scan + 1 <= tokens.len);

            return @intCast(scan + 1);
        }

        if (walk.is_open(kind)) {
            depth += 1;

            continue;
        }

        if (walk.is_close(kind)) depth -|= 1;
    }

    return stop;
}

fn columned_at(source: []const u8, head: u32, stop: u32, width: u32) u32 {
    assert(source.len <= std.math.maxInt(u32));
    assert(head < none);
    assert(stop < none);
    assert(width < none);

    const limit: u32 = @min(stop, @as(u32, @intCast(source.len)));
    const end = @max(head, limit);
    var total: u32 = 0;
    var run = head;

    assert(limit <= source.len);
    assert(end >= head);

    if (!tab_columns) return walk.columns(source, head, stop);

    for (head..end) |scan| {
        if (source[scan] != '\t') continue;

        total += walk.columns(source, run, @intCast(scan)) + width;
        run = @intCast(scan + 1);
    }

    const returned = total + walk.columns(source, run, end);

    assert(returned < std.math.maxInt(u32));

    return returned;
}

fn lined_of(source: []const u8, tokens: []const Token, position: u32, width: u32) u32 {
    assert(source.len <= std.math.maxInt(u32));
    assert(tokens.len <= std.math.maxInt(u32));
    assert(position < tokens.len);
    assert(width < none);

    const offset = tokens[position].offset;
    const head = line_head(source, offset);
    const after = std.mem.findScalarPos(u8, source, offset, '\n');
    const stop: u32 = @intCast(after orelse source.len);

    assert(head <= offset);
    assert(stop <= source.len);

    return columned_at(source, head, stop, width);
}

fn leading_of(source: []const u8, tokens: []const Token, position: u32, width: u32) u32 {
    assert(source.len <= std.math.maxInt(u32));
    assert(tokens.len <= std.math.maxInt(u32));
    assert(position < tokens.len);
    assert(width < none);

    const head = line_head(source, tokens[position].offset);
    const indent = std.mem.findNone(u8, source[head..], " \t") orelse source.len - head;
    const stop: u32 = head + @as(u32, @intCast(indent));

    assert(head <= tokens[position].offset);
    assert(stop <= source.len);

    return columned_at(source, head, stop, width);
}

fn linked_at(source: []const u8, tokens: []const Token, from: u32, to: u32) u32 {
    assert(from < none);

    var depth: u32 = 0;
    var held = from;

    assert(to <= tokens.len);
    assert(source.len < none);

    if (from >= to) return from;

    for (from..to) |scan| {
        const text = tokens[scan].text(source);

        if (text_opens(text)) {
            depth += 1;

            continue;
        }

        if (text_closes(text)) {
            depth -|= 1;

            continue;
        }

        const dot = depth == 0 and walk.text_is(text, ".");

        if (dot) held = @intCast(scan);
    }

    return held;
}

fn seated(
    comptime Kind: type,
    nodes: []const NodeType(Kind),
    source: []const u8,
    tokens: []const Token,
    comptime rules: *const TailsType(Kind),
    widths: Widths,
    node: *const NodeType(Kind),
) u32 {
    assert(source.len <= std.math.maxInt(u32));
    assert(widths.line > 0);

    var found: ?u32 = null;
    var held = node;

    assert(node.token_start < tokens.len);
    assert(nodes.len < none);

    for (0..chain_walk_max) |_| {
        if (held.parent == none) break;

        const parent = held.parent;

        held = &nodes[parent];

        if (rules.chained(held.kind)) found = parent;
    }

    const chain = found orelse {
        const seat = parted_seat(Kind, nodes, source, tokens, rules, widths, node);
        return seat orelse column_of(source, tokens, node.token_start, widths.indent);
    };

    return seated_chain(Kind, source, tokens, rules, widths, node, &nodes[chain]);
}

fn seated_chain(
    comptime Kind: type,
    source: []const u8,
    tokens: []const Token,
    comptime rules: *const TailsType(Kind),
    widths: Widths,
    node: *const NodeType(Kind),
    chain: *const NodeType(Kind),
) u32 {
    assert(source.len <= std.math.maxInt(u32));
    assert(tokens.len <= std.math.maxInt(u32));
    assert(widths.line > 0);

    const stop: u32 = @min(chain.token_end, @as(u32, @intCast(tokens.len)));
    const width = rules.bodies(chain.kind);
    const room = widths.line -| column_of(source, tokens, chain.token_start, widths.indent);
    const links = width > 0 and linked(tokens, chain.token_start, stop) >= 2;
    const budget = if (links) @min(room, width) else room;

    assert(chain.token_start <= node.token_start);
    assert(stop <= tokens.len);

    if (spelled(source, tokens, chain.token_start, stop) <= budget) {
        return column_of(source, tokens, node.token_start, widths.indent);
    }

    const dot = linked_at(source, tokens, chain.token_start, node.token_start);

    const seat = leading_of(source, tokens, chain.token_start, widths.indent) + widths.indent +
        spelled(source, tokens, dot, node.token_start);

    assert(seat >= widths.indent);

    return seat;
}

fn parted_seat(
    comptime Kind: type,
    nodes: []const NodeType(Kind),
    source: []const u8,
    tokens: []const Token,
    comptime rules: *const TailsType(Kind),
    widths: Widths,
    node: *const NodeType(Kind),
) ?u32 {
    assert(node.token_start < tokens.len);
    assert(nodes.len < none);

    if (!call_seats) return null;
    assert(source.len <= std.math.maxInt(u32));
    assert(widths.line > 0);

    const held = child_last(Kind, nodes, node);
    if (held == none) return null;

    const body = &nodes[held];
    const call = calling(source, tokens, node.token_start) orelse return null;
    if (head_columns(source, tokens, call.open, body.token_start) <= rules.call_width) return null;
    const returned = leading_of(source, tokens, call.open, widths.indent) + widths.indent;

    assert(returned < std.math.maxInt(u32));

    return returned;
}

fn column_of(source: []const u8, tokens: []const Token, position: u32, width: u32) u32 {
    assert(source.len <= std.math.maxInt(u32));
    assert(position < tokens.len);
    assert(width < none);

    const offset = tokens[position].offset;
    const head = line_head(source, offset);

    assert(head <= offset);

    return columned_at(source, head, offset, width);
}

fn comment_within(tokens: []const Token, from: u32, to: u32) bool {
    assert(tokens.len <= std.math.maxInt(u32));
    assert(from <= to);

    const stop: u32 = @min(to, @as(u32, @intCast(tokens.len)));

    assert(stop <= tokens.len);

    if (stop -| from > tail_scan_max) return true;

    for (tokens[from..stop]) |token| {
        if (token.kind == .comment) return true;
    }

    return false;
}

fn blocked(
    comptime Kind: type,
    nodes: []const NodeType(Kind),
    source: []const u8,
    tokens: []const Token,
    node: *const NodeType(Kind),
) ?*const NodeType(Kind) {
    assert(nodes.len <= std.math.maxInt(u32));
    assert(source.len <= std.math.maxInt(u32));

    const held = child_last(Kind, nodes, node);
    if (held == none) return null;

    var block = &nodes[held];
    if (block.token_start <= node.token_start) return null;
    if (block.token_end > tokens.len) return null;

    const bar = tokens[block.token_start - 1].text(source);
    const barred = walk.text_is(bar, "|") or walk.text_is(bar, "||");

    assert(block.token_start > 0);
    assert(block.token_end <= tokens.len);

    if (!barred) return null;

    for (0..tail_walk_max) |_| {
        if (block.child_first == none) return null;

        const child = &nodes[block.child_first];
        const same = child.token_start == block.token_start and child.token_end == block.token_end;

        if (child.sibling_next != none) return null;

        if (same) {
            block = child;

            continue;
        }

        if (child.token_start != block.token_start + 1) return null;
        if (child.token_end + 1 != block.token_end) return null;
        if (tokens[child.token_end - 1].is_punctuation(.semicolon)) return null;

        const braced = tokens[block.token_start].kind == .block_start and
            tokens[block.token_end - 1].kind == .block_end and
            !comment_within(tokens, block.token_start, block.token_end);

        return if (braced) block else null;
    }

    return null;
}

fn bounded(
    comptime Kind: type,
    nodes: []const NodeType(Kind),
    source: []const u8,
    tokens: []const Token,
    comptime rules: *const TailsType(Kind),
    block: *const NodeType(Kind),
) bool {
    assert(source.len <= std.math.maxInt(u32));
    assert(tokens.len <= std.math.maxInt(u32));

    var held = block;

    assert(block.token_start <= block.token_end);
    assert(nodes.len < none);

    if (rules.width == 0) return false;

    for (0..tail_walk_max) |_| {
        if (held.parent == none) return false;

        held = &nodes[held.parent];

        if (!rules.bounds(held.kind)) continue;

        const stop: u32 = @min(held.token_end, @as(u32, @intCast(tokens.len)));
        if (held.token_start >= stop) return false;

        const from = tokens[held.token_start].offset;
        const to = tokens[stop - 1].end();

        return walk.columns(source, from, to) > rules.width;
    }

    return false;
}

pub fn tails(
    comptime Kind: type,
    tree: *const TreeType(Kind),
    source: []const u8,
    tokens: []const Token,
    comptime rules: *const TailsType(Kind),
    flags: []u16,
) void {
    assert(source.len <= std.math.maxInt(u32));

    const nodes = tree.slice();

    assert(flags.len == tokens.len);
    assert(nodes.len < none);

    for (nodes) |*node| {
        if (node.token_end == 0) continue;
        if (node.token_end > tokens.len) continue;
        if (node.parent == none) continue;

        const parent = &nodes[node.parent];
        if (!rules.owes(node.kind, parent.kind)) continue;

        const spans = spans_lines(source, tokens, parent.token_start, parent.token_end) or
            bounded(Kind, nodes, source, tokens, rules, parent);

        if (!spans) continue;

        flag_set(flags, node.token_end - 1, end_owed);
    }
}

fn arm_ended(
    comptime Kind: type,
    tree: *const TreeType(Kind),
    source: []const u8,
    tokens: []const Token,
    comptime rules: *const TailsType(Kind),
    flags: []u16,
) void {
    assert(source.len <= std.math.maxInt(u32));

    const nodes = tree.slice();

    assert(flags.len == tokens.len);
    assert(nodes.len < none);

    if (!arm_endings) return;

    for (nodes) |*node| {
        if (!rules.arms(node.kind)) continue;
        if (skipped(Kind, nodes, source, tokens, node)) continue;

        const ending = arm_ending(tokens, flags, node.token_start, node.token_end) orelse continue;

        flag_set(flags, ending, arm_ends);
    }
}

fn arm_ending(tokens: []const Token, flags: []const u16, start: u32, end: u32) ?u32 {
    assert(flags.len == tokens.len);
    assert(start <= end);

    var last: u32 = @min(end, @as(u32, @intCast(tokens.len)));

    for (0..last) |_| {
        if (last <= start) break;

        const kind = tokens[last - 1].kind;
        const blank = kind == .comment or kind == .newline;
        if (!blank) break;

        last -= 1;
    }

    if (last == 0) return null;

    const final = last - 1;
    const dropped_comma = tokens[final].is_punctuation(.comma) and flags[final] & block_drops != 0;
    if (!dropped_comma) return final;
    if (final == 0) return null;
    assert(final - 1 < std.math.maxInt(u32));

    return final - 1;
}

fn lined(
    comptime Kind: type,
    tree: *const TreeType(Kind),
    source: []const u8,
    tokens: []const Token,
    comptime rules: *const TailsType(Kind),
    flags: []u16,
) void {
    assert(source.len <= std.math.maxInt(u32));

    const nodes = tree.slice();

    assert(flags.len == tokens.len);
    assert(nodes.len < none);

    for (nodes) |*node| {
        if (node.parent == none) continue;
        if (!rules.lines(node.kind, nodes[node.parent].kind)) continue;
        if (skipped(Kind, nodes, source, tokens, node)) continue;

        lined_items(Kind, nodes, tokens, rules, node, flags);
    }
}

fn lined_items(
    comptime Kind: type,
    nodes: []const NodeType(Kind),
    tokens: []const Token,
    comptime rules: *const TailsType(Kind),
    node: *const NodeType(Kind),
    flags: []u16,
) void {
    var child = node.child_first;
    var first: u32 = none;

    assert(child == none or child < nodes.len);
    assert(flags.len == tokens.len);

    for (0..list_item_max) |_| {
        if (child == none) break;

        const item = &nodes[child];

        child = item.sibling_next;

        if (!rules.items(item.kind)) continue;

        if (first == none) first = item.token_start;

        const comma = following(tokens, item.token_end) orelse continue;

        if (tokens[comma].is_punctuation(.comma)) flags[comma] |= arm_ends;
    }

    const open = preceding(tokens, first) orelse return;

    if (tokens[open].kind == .block_start) flags[open] |= list_lines;
}

fn dropping(
    source: []const u8,
    tokens: []const Token,
    position: u32,
    out: *Buffer,
    written: *u32,
) error{Overflow}!void {
    assert(position < tokens.len);

    const token = tokens[position];
    const opens = token.kind == .block_start;
    const head = if (opens) token.offset else tokens[position - 1].end();

    assert(written.* <= source.len);

    if (head > written.*) try out.push(source[written.*..head]);

    written.* = @max(token.end(), written.*);

    if (!opens) return;

    const bytes = out.const_slice();
    const spaced_end = bytes.len > 0 and bytes[bytes.len - 1] == ' ';

    if (!spaced_end) try out.push(" ");
    if (position + 1 >= tokens.len) return;

    written.* = @max(tokens[position + 1].offset, written.*);
}

fn compared(
    comptime Kind: type,
    tree: *const TreeType(Kind),
    source: []const u8,
    tokens: []const Token,
    comptime rules: *const TailsType(Kind),
    flags: []u16,
) void {
    assert(source.len <= std.math.maxInt(u32));

    const nodes = tree.slice();

    assert(flags.len == tokens.len);
    assert(nodes.len < none);

    for (nodes) |*node| {
        if (!rules.compares(node.kind)) continue;

        compared_node(Kind, nodes, source, tokens, node, flags);
    }
}

fn compared_node(
    comptime Kind: type,
    nodes: []const NodeType(Kind),
    source: []const u8,
    tokens: []const Token,
    node: *const NodeType(Kind),
    flags: []u16,
) void {
    assert(source.len <= std.math.maxInt(u32));

    var before: u32 = none;
    var last = node.child_first;

    assert(last == none or last < nodes.len);
    assert(flags.len == tokens.len);

    for (0..operand_walk_max) |_| {
        if (last == none) break;
        if (nodes[last].sibling_next == none) break;

        before = last;
        last = nodes[last].sibling_next;
    }

    if (before == none) return;
    if (last == none) return;

    const from = nodes[before].token_end;
    const to: u32 = @min(nodes[last].token_start, @as(u32, @intCast(tokens.len)));
    if (from >= to) return;

    for (from..to) |position| {
        const text = tokens[position].text(source);
        const angle = walk.text_is(text, "<") or walk.text_is(text, ">");

        if (angle) flag_set(flags, position, operator_spaced);
    }
}

fn masked(
    comptime Kind: type,
    tree: *const TreeType(Kind),
    source: []const u8,
    tokens: []const Token,
    comptime rules: *const TailsType(Kind),
    widths: Widths,
    flags: []u16,
) void {
    assert(flags.len == tokens.len);
    assert(source.len < none);
    assert(widths.line > 0);

    tails(Kind, tree, source, tokens, rules, flags);
    bodied(Kind, tree, source, tokens, rules, flags);
    dropped_body(Kind, tree, source, tokens, rules, widths, flags);
    armed(Kind, tree, source, tokens, rules, widths, flags);
    compared(Kind, tree, source, tokens, rules, flags);
    arm_ended(Kind, tree, source, tokens, rules, flags);
    lined(Kind, tree, source, tokens, rules, flags);
    attribute_lined(Kind, tree, source, tokens, rules, flags);
}

fn attribute_lined(
    comptime Kind: type,
    tree: *const TreeType(Kind),
    source: []const u8,
    tokens: []const Token,
    comptime rules: *const TailsType(Kind),
    flags: []u16,
) void {
    assert(source.len <= std.math.maxInt(u32));

    const nodes = tree.slice();

    assert(flags.len == tokens.len);
    assert(nodes.len < none);

    for (nodes) |*node| {
        if (node.parent == none) continue;

        const enclosing = &nodes[node.parent];
        const grand: ?Kind = if (enclosing.parent == none) null else nodes[enclosing.parent].kind;
        if (!rules.attributes(node.kind, enclosing.kind, grand)) continue;
        if (skipped(Kind, nodes, source, tokens, node)) continue;

        const close = preceding(tokens, node.token_end) orelse continue;
        if (close < node.token_start) continue;
        if (!tokens[close].is_punctuation(.bracket_close)) continue;

        flag_set(flags, close, attribute_lines);
    }
}

fn listed_code(mark: u16) u8 {
    const ends = mark & arm_ends != 0 and mark & block_closes == 0;

    comptime assert(brace.item_break != 0);
    comptime assert(brace.item_edges & brace.item_commas == 0);

    if (ends) return brace.item_break;
    if (mark & attribute_lines != 0) return brace.item_break;
    if (mark & list_lines != 0) return brace.item_edges | brace.item_commas;
    return 0;
}

pub fn tailed(
    comptime Kind: type,
    tree: *const TreeType(Kind),
    source: []const u8,
    tokens: []const Token,
    comptime rules: *const TailsType(Kind),
    widths: Widths,
    stream: *Terminators,
) error{Overflow}!void {
    assert(source.len < std.math.maxInt(u32));
    assert(tokens.len < std.math.maxInt(u32));
    assert(widths.line > 0);

    try tailed_reset(stream, @intCast(tokens.len));
    masked(Kind, tree, source, tokens, rules, widths, stream.marks.slice());

    var written: u32 = 0;

    for (0..tokens.len) |index| {
        try tailed_token(source, tokens, stream, @intCast(index), &written);
    }

    try stream.source.push(source[written..]);

    assert(stream.tokens.count() == stream.roles.count());
    assert(stream.origins.count() == stream.tokens.count());
}

fn tailed_reset(stream: *Terminators, token_count: u32) error{Overflow}!void {
    assert(token_count < none);

    stream.added.clear();
    stream.lists.clear();
    stream.origins.clear();
    stream.marks.clear();
    stream.source.clear();
    stream.roles.clear();
    stream.tokens.clear();

    for (0..token_count) |_| {
        try stream.marks.pushed(0);
    }

    assert(stream.marks.count() == token_count);
    assert(stream.tokens.empty());
}

fn tailed_token(
    source: []const u8,
    tokens: []const Token,
    stream: *Terminators,
    position: u32,
    written: *u32,
) error{Overflow}!void {
    assert(tokens.len <= std.math.maxInt(u32));
    assert(position < tokens.len);

    const token = tokens[position];
    const flags = stream.marks.const_slice();
    const mark = flags[position];

    assert(flags.len == tokens.len);
    assert(written.* <= source.len);

    if (mark & block_drops != 0) return dropping(source, tokens, position, &stream.source, written);

    const moved = stream.source.count() + (token.offset - written.*);
    const asserts = token.kind == .keyword and token.kind.keyword == .assert;

    try stream.tokens.pushed(.{
        .kind = if (asserts) .identifier else token.kind,
        .length = token.length,
        .offset = moved,
    });

    try stream.added.pushed(0);
    try stream.lists.pushed(listed_code(mark));
    try stream.origins.pushed(token.offset);
    try stream.roles.pushed(spaced_role(mark));

    const wanted: Wanted = .{
        .closes = mark & block_closes != 0,
        .opens = mark & block_opens != 0,
        .owed = mark & end_owed != 0 and !separated_already(tokens, flags, position),
    };

    try adding(source, token, mark & arm_ends != 0, wanted, stream, written);
}

fn adding(
    source: []const u8,
    token: Token,
    ends: bool,
    wanted: Wanted,
    stream: *Terminators,
    written: *u32,
) error{Overflow}!void {
    const writes = wanted.owed or wanted.closes or wanted.opens;

    assert(written.* <= token.end());
    assert(token.end() <= source.len);

    if (!writes) return;

    try stream.source.push(source[written.*..token.end()]);
    written.* = token.end();

    if (wanted.owed) {
        try adding_mark(stream, semicolon, 1, .{ .punctuation = .semicolon }, mask_semicolon, ends);
    }

    if (wanted.closes) try adding_mark(stream, brace_close, 1, .block_end, mask_close, ends);
    if (wanted.opens) try adding_mark(stream, brace_open, 2, .block_start, mask_open, ends);

    const breaks = block_breaks and wanted.opens;

    if (breaks) written.* = blanked(source, written.*);
}

fn adding_mark(
    stream: *Terminators,
    text: []const u8,
    back: u32,
    kind: Token.Kind,
    code: u8,
    ends: bool,
) error{Overflow}!void {
    assert(back <= text.len);
    assert(code >= mask_semicolon);

    try stream.source.push(text);

    const at = stream.source.count() - back;
    const breaks = ends and code == mask_close;
    const listed: u8 = if (breaks) brace.item_break else 0;

    try stream.tokens.pushed(.{ .kind = kind, .length = 1, .offset = at });
    try stream.added.pushed(code);
    try stream.lists.pushed(listed);
    try stream.origins.pushed(none);
    try stream.roles.pushed(0);
}

fn blanked(source: []const u8, from: u32) u32 {
    assert(from <= source.len);
    assert(source.len < none);

    const rest = source[from..];
    const after = std.mem.findNone(u8, rest, " \t\r") orelse return from;
    if (rest[after] != '\n') return from;
    assert(from + @as(u32, @intCast(after)) + 1 <= source.len);

    return from + @as(u32, @intCast(after)) + 1;
}
