const std = @import("std");
const assert = std.debug.assert;
const Buffer = @import("../../stdx/bounded/buffer.zig");
const Policy = @import("../policy.zig").Policy;
const Span = @import("../../stdx/bounded/span.zig");
const Token = @import("../../syntax/token.zig");
const brace = @import("../brace.zig");
const edge = @import("edge.zig");
const ir = @import("../ir.zig");
const join = @import("join.zig");
const jsx = @import("jsx.zig");
const print = @import("../print.zig");
const tern = @import("tern.zig");
const unite = @import("unite.zig");
const walk = @import("../walk.zig");

pub const Emitter = struct {
    angle: Span,
    angle_owed: u32 = 0,
    angled: u32 = 0,
    angles: [angle_depth_max]Angle = @splat(Angle.empty),
    arena: *Buffer,
    arrow_chain: ArrowChain = ArrowChain.empty,
    arrow_head: u32 = std.math.maxInt(u32),
    arrowed: bool = false,
    asm_aligned: ?u32 = null,
    asm_given: ?u32 = null,
    assign_groups: [assign_depth_max]?u32 = @splat(0),
    assign_hug: bool = false,
    assigned: [assign_depth_max]Assigned = @splat(Assigned.empty),
    assigns: u32 = 0,
    bar: Span,
    bar_aligned: ?u32 = null,
    based: u32 = 0,
    binders: [binder_depth_max]Binder = @splat(Binder.empty),
    bindings: [binding_depth_max]Binding = @splat(Binding.empty),
    bound: u32 = 0,
    bound_base: u32 = 0,
    bound_depth: u32 = 0,
    bound_ring: ?Line = null,
    brackets: *const walk.Brackets,
    branched: u32 = 0,
    branches: [branch_depth_max]Branch = @splat(Branch.empty),
    breaks: *const walk.Breaks,
    broken: u32 = 0,
    broken_led: u32 = 0,
    broken_line: u32 = 0,
    broken_low: u32 = 0,
    broken_serials: [broken_serial_max]?u32 = @splat(0),
    chain_ends: [wrap_depth_max]u32 = @splat(0),
    chain_owed: u32 = 0,
    chained: bool = false,
    claused: bool = false,
    claused_body: bool = false,
    claused_depth: u32 = 0,
    closed: Frame = Frame.empty,
    closing: Span,
    comma: Span,
    comment_after: ?u32 = null,
    comment_broke: ?u32 = null,
    comment_moved: ?CommentMoved = null,
    comment_owed: ?u32 = null,
    commented: bool = false,
    constraint_owed: ?u32 = null,
    constructed: u32 = 0,
    constructs: [brace.nest_depth_max]u32 = @splat(0),
    continued: bool = false,
    count: u32,
    declared: ?u32 = null,
    decorated: ?u32 = null,
    dedents: [assign_depth_max]Dedent = @splat(Dedent.empty),
    depth: u32 = 0,
    document: *ir.Document,
    gives: []const u32,
    glued: bool = false,
    guards: [wrap_depth_max]Guard = @splat(Guard.empty),
    hole: Span,
    indent: u32 = 0,
    intersect_group: ?IntersectGroup = null,
    join_stack: *JoinStack,
    jsx: [jsx_depth_max]jsx.Tag = @splat(jsx.Tag.empty),
    jsx_aligned: u32 = std.math.maxInt(u32),
    jsx_commented: u32 = std.math.maxInt(u32),
    jsxed: u32 = 0,
    leds: [line_level_max]u32 = @splat(0),
    levels: u32 = 0,
    line_before: u32 = 0,
    line_first: u32 = 0,
    line_start: bool = true,
    lined: u32 = 0,
    lines: [line_level_max]Line = @splat(Line.empty),
    listed: u32 = 0,
    lists: []const u8,
    macros: []const u32,
    marks: []const u8,
    memos: *Memos,
    nest: [brace.nest_depth_max]Frame = @splat(Frame.empty),
    opaques: []const u32,
    opening: Span,
    operand_ends: []const u32,
    operands: []const u32,
    options: print.Options,
    origin: []const u8,
    origins: []const u32,
    owed: u32 = 0,
    owing: u32 = 0,
    owns: u32 = 0,
    policy: Policy,
    previous: ?u32 = null,
    printed: u32 = 0,
    rebalances: []const u32,
    resume_at: u32 = 0,
    return_colons: *tern.ReturnColons,
    roles: []const u16,
    semicolon: Span,
    shadow: *print.Shadow,
    shared: u32 = std.math.maxInt(u32),
    soled: u32 = 0,
    soleds: [wrap_depth_max]u32 = @splat(0),
    source: []const u8,
    spaced: Span,
    spacing: Span,
    starting: bool = true,
    statements: *edge.StatementScratch,
    structured: bool,
    suppress_space: bool = false,
    test_aligned: ?u32 = null,
    tokens: []const Token,
    type_ended: u32 = 0,
    type_ends: [type_end_max]u32 = @splat(0),
    typed: bool = false,
    union_grouped: u32 = 0,
    union_groups: [unite.union_group_max]UnionGroup = @splat(UnionGroup.empty),
    union_stopped: u32 = 0,
    union_stops: [union_align_max]u32 = @splat(0),
    voided: u32 = 0,
    wrapped: [wrap_depth_max]Wrapped = @splat(Wrapped.empty),
    wraps_aligned: [wrap_depth_max]u32 = @splat(0),
    wraps_armed: [wrap_depth_max]bool = @splat(true),
    wraps_assigned: [wrap_depth_max]bool = @splat(false),
    wraps_ended: ?u32 = null,
    wraps_heavy: [wrap_depth_max]u32 = @splat(0),
    wraps_indent: [wrap_depth_max]u32 = @splat(0),
    wraps_nested: [wrap_depth_max]u8 = @splat(nest_none),
    wraps_owed: u32 = 0,
    wraps_severed: [wrap_depth_max]bool = @splat(false),
    wraps_width: [wrap_depth_max]u32 = @splat(0),
};

pub const Frame = struct {
    aligned: bool,
    bodied: bool,
    casts: bool,
    claused: Claused,
    close: u32,
    grouped: ?u32,
    held: u32,
    holed: bool,
    hugged: u32,
    indents: bool,
    index: bool,
    inset: u32,
    inside: bool,
    joined: bool,
    kind: Token.Kind,
    level: u32,
    lists: bool,
    membered: bool,
    open: u32,
    parted: bool,
    returned: bool,
    seated: u32,
    sequenced: ?u32,
    spread: ?Spread,
    valued: Valued,

    pub const empty: Frame = .{
        .aligned = false,
        .bodied = false,
        .casts = false,
        .claused = Claused.empty,
        .close = 0,
        .grouped = null,
        .held = 0,
        .holed = false,
        .hugged = 0,
        .indents = false,
        .index = false,
        .inset = 0,
        .inside = false,
        .joined = false,
        .kind = .block_start,
        .level = 0,
        .lists = false,
        .membered = false,
        .open = 0,
        .parted = false,
        .returned = false,
        .seated = 0,
        .sequenced = null,
        .spread = null,
        .valued = Valued.empty,
    };
};

pub const Spread = enum {
    chain,
    clauses,
    fill,
    members,
};

pub const Wrap = enum {
    argued,
    bodied,
    chained,
    guarded,
    hugged,
    linked,
    membered,
    nested,
    paired,
    parens,
    tagged,
    tagging,
    ternary,
    valued,
};

pub const Angle = struct {
    close: u32,
    depth: u32,
    nest: u32,
    open: u32,
    commas: bool,
    trailed: bool,
    headed: bool,

    pub const empty: Angle = .{
        .close = 0,
        .depth = 0,
        .nest = 0,
        .open = 0,
        .commas = false,
        .trailed = false,
        .headed = false,
    };
};

pub const ArrowChain = struct {
    tail: u32,
    close: u32,
    end: u32,
    depth: u32,
    expand: bool,

    pub const empty: ArrowChain = .{
        .tail = std.math.maxInt(u32),
        .close = std.math.maxInt(u32),
        .end = std.math.maxInt(u32),
        .depth = 0,
        .expand = false,
    };
};

const Assigned = struct {
    equals: u32,
    close: u32,

    pub const empty: Assigned = .{ .equals = 0, .close = 0 };
};

const Binder = struct {
    stop: u32,
    depth: u32,
    start: u32,
    valued: bool,

    pub const empty: Binder = .{ .stop = 0, .depth = 0, .start = 0, .valued = false };
};

pub const Binding = struct {
    tier: u32,
    level: u32,

    pub const empty: Binding = .{ .tier = 0, .level = 0 };
};

const Branch = struct {
    level: u32,
    depth: u32,
    word: u32,

    pub const empty: Branch = .{ .level = 0, .depth = 0, .word = 0 };
};

const Claused = struct {
    held: bool,
    depth: u32,
    bodied: bool,

    pub const empty: Claused = .{ .held = false, .depth = 0, .bodied = false };
};

const CommentMoved = struct {
    comment: u32,
    open: u32,
};

const Dedent = struct {
    dedent: u32,
    depth: u32,
    equals: u32,

    pub const empty: Dedent = .{ .dedent = 0, .depth = 0, .equals = 0 };
};

const Guard = struct {
    index: u32,
    depth: u32,

    pub const empty: Guard = .{ .index = 0, .depth = 0 };
};

const IntersectGroup = struct {
    stop: u32,
    depth: u32,
    angles: u32,
    indented: bool,
    lined: bool,
};

pub const JoinStack = struct {
    evaluating: bool,
    frames: [join.frame_max]join.Frame,

    pub fn init(stack: *JoinStack) void {
        stack.evaluating = false;

        assert(!stack.evaluating);
        assert(stack.frames.len == join.frame_max);
    }
};

pub const Line = struct {
    start: u32,
    level: u32,

    pub const empty: Line = .{ .start = 0, .level = 0 };
};

const LinedEntry = struct {
    line_first: u32,
    lined: u32,
    memo: MemoEntry,
    newest: Line,
    printed: u32,
};

pub const Memo = enum {
    argument_end,
    bodied_brace,
    braced_head,
    branched_last,
    calling,
    calling_named,
    capped_link,
    classed_head,
    comparing,
    declared_word,
    defined,
    derive_added,
    element_count,
    enclosing_open,
    fields_wide,
    flat_width,
    headed,
    header_width,
    hugged_admitted,
    lambda_hung_list,
    leads_a_block,
    listed,
    listed_admitted,
    listed_count,
    macroed,
    paren_grouped,
    probed,
    sequence_paren,
    sequence_signed,
    statement_head,
    statement_word,
    streamed,
    ternary_within,
    trailed_comma,
    tupled_sole,
    union_arrowed,
    union_open,
    union_tuple_grouping,
    union_typed,
    valued_brace,
    welded,
    wrapping_operator,

    fn boolean(memo: Memo) bool {
        return switch (memo) {
            .argument_end,
            .braced_head,
            .declared_word,
            .element_count,
            .enclosing_open,
            .flat_width,
            .header_width,
            .lambda_hung_list,
            .listed_count,
            .statement_head,
            .statement_word,
            .union_open,
            .union_tuple_grouping,
            => false,
            .bodied_brace,
            .branched_last,
            .calling,
            .calling_named,
            .capped_link,
            .classed_head,
            .comparing,
            .defined,
            .derive_added,
            .fields_wide,
            .headed,
            .hugged_admitted,
            .leads_a_block,
            .listed,
            .listed_admitted,
            .macroed,
            .paren_grouped,
            .probed,
            .sequence_paren,
            .sequence_signed,
            .streamed,
            .ternary_within,
            .trailed_comma,
            .tupled_sole,
            .union_arrowed,
            .union_typed,
            .valued_brace,
            .welded,
            .wrapping_operator,
            => true,
        };
    }

    fn contextual(memo: Memo) bool {
        return switch (memo) {
            .bodied_brace,
            .calling,
            .calling_named,
            .classed_head,
            .declared_word,
            .defined,
            .headed,
            .hugged_admitted,
            .listed,
            .listed_admitted,
            .paren_grouped,
            .probed,
            .sequence_paren,
            .sequence_signed,
            .statement_head,
            .statement_word,
            .ternary_within,
            .trailed_comma,
            .tupled_sole,
            .union_arrowed,
            .union_open,
            .union_tuple_grouping,
            .union_typed,
            .wrapping_operator,
            => true,
            .argument_end,
            .braced_head,
            .branched_last,
            .capped_link,
            .comparing,
            .derive_added,
            .element_count,
            .enclosing_open,
            .fields_wide,
            .flat_width,
            .header_width,
            .lambda_hung_list,
            .leads_a_block,
            .listed_count,
            .macroed,
            .streamed,
            .valued_brace,
            .welded,
            => false,
        };
    }
};

const MemoContext = struct {
    depth: u32,
    top: u32,
    typed: bool,

    const none: MemoContext = .{ .depth = 0, .top = memo_none, .typed = false };
};

const MemoEntry = struct {
    answer: u32,
    argument: u32,
    depth: u32,
    generation: u32,
    position: u32,
    top: u32,
    typed: bool,
};

pub const Memos = struct {
    entries: [memo_count][memo_entry_count]MemoEntry,
    generation: u32,
    lined: [memo_entry_count]LinedEntry,

    pub fn init(memos: *Memos) void {
        memos.generation = 1;

        for (&memos.entries) |*table| {
            for (table) |*entry| entry.generation = 0;
        }

        for (&memos.lined) |*entry| entry.memo.generation = 0;

        assert(memos.generation > 0);
        assert(memos.entries[0][0].generation != memos.generation);
    }

    pub fn begin(memos: *Memos) void {
        assert(memos.generation > 0);
        assert(memos.generation < std.math.maxInt(u32));

        memos.generation += 1;
    }
};

const UnionGroup = struct {
    stop: u32,
    depth: u32,
    angles: u32,
    indented: bool,
    head: u32,
    declared: bool,

    pub const empty: UnionGroup = .{
        .stop = 0,
        .depth = 0,
        .angles = 0,
        .indented = false,
        .head = 0,
        .declared = false,
    };
};

pub const Valued = struct {
    keyed: u32,
    shut: u32,
    end: u32,

    pub const empty: Valued = .{ .keyed = 0, .shut = 0, .end = 0 };
};

pub const Wrapped = struct {
    close: u32,
    wrap: Wrap,
    depth: u32,
    floor: u32,
    start: u32,

    pub const empty: Wrapped = .{ .close = 0, .wrap = .parens, .depth = 0, .floor = 0, .start = 0 };
};

pub const access_words: [3][]const u8 = .{ "private", "protected", "public" };
pub const accessor_words: [2][]const u8 = .{ "get", "set" };
pub const angle_close: []const u8 = ">";
pub const angle_depth_max: u32 = 32;
pub const angle_scan_max: u32 = 256;

pub const arm_operands: [10][]const u8 = .{
    "await",
    "delete",
    "false",
    "in",
    "instanceof",
    "new",
    "null",
    "super",
    "this",
    "typeof",
};

pub const assign_depth_max: u32 = 8;
pub const bar_lead: []const u8 = "| ";
pub const binder_depth_max: u32 = 8;
pub const binding_depth_max: u32 = 16;
pub const body_stops: []const []const u8 = &.{ "<", "=", "=>", ":", ";", ",", "|" };
pub const body_values: []const []const u8 = &.{ "async", "const", "gen", "move", "try", "unsafe" };

pub const body_words: []const []const u8 = &.{
    "enum",
    "fn",
    "impl",
    "loop",
    "match",
    "mod",
    "struct",
    "trait",
    "union",
};

pub const branch_depth_max: u32 = 16;
pub const broken_serial_max: u32 = 256;
pub const case_sole_scan_max: u32 = 64;
pub const class_words: []const []const u8 = &.{"class"};
pub const comma: []const u8 = ",";
pub const declare_heads: []const []const u8 = &.{ "class", "function" };
pub const define_head_max: u32 = 1024;
pub const define_scan_max: u32 = 512;
pub const foreign_words: []const []const u8 = &.{"extern"};
pub const head_scan_max: u32 = 1024;
pub const jsx_depth_max: u32 = 64;
pub const jump_words: []const []const u8 = &.{ "break", "continue", "return" };
pub const line_closers: []const u8 = "()]}?>,";
pub const line_level_max: u32 = 256;
pub const list_item_max: u32 = 128;

pub const macro_groups: []const struct { []const u8, u32 } = &.{
    .{ "assert", 1 },
    .{ "assert_eq", 2 },
    .{ "assert_ne", 2 },
    .{ "debug", 0 },
    .{ "debug_assert", 1 },
    .{ "debug_assert_eq", 2 },
    .{ "debug_assert_ne", 2 },
    .{ "eprint", 0 },
    .{ "eprintln", 0 },
    .{ "error", 0 },
    .{ "format", 0 },
    .{ "format_args", 0 },
    .{ "info", 0 },
    .{ "panic", 0 },
    .{ "print", 0 },
    .{ "println", 0 },
    .{ "trace", 0 },
    .{ "unreachable", 0 },
    .{ "warn", 0 },
    .{ "write", 1 },
    .{ "writeln", 1 },
};

const memo_count: u32 = @typeInfo(Memo).@"enum".field_names.len;
const memo_entry_count: u32 = 1 << 12;
pub const memo_none: u32 = std.math.maxInt(u32);
pub const module_words: []const []const u8 = &.{ "extern", "mod" };
pub const nest_bare: u8 = 4;
pub const nest_chain: u8 = 1;
pub const nest_flat: u8 = 3;
pub const nest_none: u8 = 0;
pub const nest_right: u8 = 2;
pub const order_run_max: u32 = 8;
pub const paren_close: []const u8 = ")";
pub const paren_open: []const u8 = "(";
pub const paren_spaced: []const u8 = " (";
pub const semicolon: []const u8 = ";";
pub const shadow_back_max: u32 = 256;
pub const space_hole: []const u8 = "{\" \"}";
pub const spaced: []const u8 = " ";

pub const structure_roles: u16 = brace.role_block | brace.role_lambda | brace.role_part |
    brace.role_span | brace.role_start;

pub const type_end_max: u32 = 16;
pub const type_scan_max: u32 = 64;
pub const union_align_max: u32 = 8;
pub const wrap_depth_max: u32 = 16;

comptime {
    assert(binding_depth_max > 0);
    assert(line_level_max > 0);
    assert(std.math.isPowerOfTwo(memo_entry_count));
}

pub fn memo_found(emitter: *const Emitter, memo: Memo, position: u32, argument: u32) ?u32 {
    assert(position < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);
    assert(argument < std.math.maxInt(u32));

    const memos = emitter.memos;
    const entry = &memos.entries[@backingInt(memo)][memo_slot(position, argument)];
    if (entry.generation != memos.generation) return null;
    if (entry.position != position) return null;
    if (entry.argument != argument) return null;

    const context = memo_context(emitter, memo);
    if (entry.depth != context.depth) return null;
    if (entry.top != context.top) return null;
    if (entry.typed != context.typed) return null;
    return entry.answer;
}

pub fn memo_store(
    emitter: *const Emitter,
    memo: Memo,
    position: u32,
    argument: u32,
    answer: u32,
) void {
    assert(position < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);
    assert(argument < std.math.maxInt(u32));
    if (memo.boolean()) assert(answer <= 1);

    const memos = emitter.memos;
    const context = memo_context(emitter, memo);

    memos.entries[@backingInt(memo)][memo_slot(position, argument)] = .{
        .answer = answer,
        .argument = argument,
        .depth = context.depth,
        .generation = memos.generation,
        .position = position,
        .top = context.top,
        .typed = context.typed,
    };
}

fn memo_context(emitter: *const Emitter, memo: Memo) MemoContext {
    assert(emitter.depth <= brace.nest_depth_max);

    if (!memo.contextual()) return MemoContext.none;
    return .{ .depth = emitter.depth, .top = memo_top(emitter), .typed = emitter.typed };
}

pub fn lined_found(emitter: *const Emitter, position: u32) ?u32 {
    assert(position < emitter.count);
    assert(emitter.lined < line_level_max);

    const entry = &emitter.memos.lined[memo_slot(position, 0)];
    if (entry.memo.generation != emitter.memos.generation) return null;
    if (entry.memo.position != position) return null;
    if (entry.memo.depth != emitter.depth) return null;
    if (entry.memo.top != memo_top(emitter)) return null;
    if (entry.memo.typed != emitter.typed) return null;
    if (entry.printed != emitter.printed) return null;
    if (entry.line_first != emitter.line_first) return null;
    if (entry.lined != emitter.lined) return null;
    if (!std.meta.eql(entry.newest, lined_newest(emitter))) return null;
    return entry.memo.answer;
}

pub fn lined_store(emitter: *const Emitter, position: u32, answer: u32) void {
    assert(position < emitter.count);
    assert(emitter.lined < line_level_max);
    assert(answer == memo_none or answer <= emitter.count);

    emitter.memos.lined[memo_slot(position, 0)] = .{
        .line_first = emitter.line_first,
        .lined = emitter.lined,
        .memo = .{
            .answer = answer,
            .argument = 0,
            .depth = emitter.depth,
            .generation = emitter.memos.generation,
            .position = position,
            .top = memo_top(emitter),
            .typed = emitter.typed,
        },
        .newest = lined_newest(emitter),
        .printed = emitter.printed,
    };
}

fn lined_newest(emitter: *const Emitter) Line {
    assert(emitter.lined < line_level_max);

    return emitter.lines[(emitter.lined + line_level_max - 1) % line_level_max];
}

fn memo_slot(position: u32, argument: u32) u32 {
    const slot = (position +% argument) & (memo_entry_count - 1);

    assert(slot < memo_entry_count);

    return slot;
}

fn memo_top(emitter: *const Emitter) u32 {
    assert(emitter.depth <= brace.nest_depth_max);

    if (emitter.depth == 0) return memo_none;

    const top = emitter.nest[emitter.depth - 1].open;

    assert(top < emitter.count);

    return top;
}
