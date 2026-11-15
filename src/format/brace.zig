const std = @import("std");
const assert = std.debug.assert;
const ArrayType = @import("../stdx/bounded/array.zig").ArrayType;
const Buffer = @import("../stdx/bounded/buffer.zig");
const Span = @import("../stdx/bounded/span.zig");
const Token = @import("../syntax/token.zig");
const core = @import("brace/emitter.zig");
const edge = @import("brace/edge.zig");
const emit = @import("brace/emit.zig");
const ir = @import("ir.zig");
const items = @import("brace/items.zig");
const print = @import("print.zig");
const tern = @import("brace/tern.zig");
const text = @import("text.zig");
const walk = @import("walk.zig");
const Emitter = core.Emitter;

pub const Formatter = struct {
    angle: u32,
    arena: Buffer,
    bar: u32,
    brackets: walk.Brackets,
    breaks: walk.Breaks,
    closing: u32,
    comma: u32,
    document: ir.Document,
    hole: u32,
    join_stack: *core.JoinStack,
    memos: *core.Memos,
    opening: u32,
    return_colons: *tern.ReturnColons,
    semicolon: u32,
    shadow: print.Shadow,
    spaced: u32,
    spacing: u32,
    statements: *edge.StatementScratch,

    pub fn init(
        gpa: std.mem.Allocator,
        element_count_max: u32,
        arena_bytes_max: u32,
    ) std.mem.Allocator.Error!Formatter {
        assert(element_count_max > 0);
        assert(arena_bytes_max > 0);

        var document = try ir.Document.init(gpa, element_count_max, literal_count);
        errdefer document.deinit(gpa);

        var arena = try Buffer.init(gpa, arena_bytes_max);
        errdefer arena.deinit(gpa);

        var brackets = try walk.Brackets.init(gpa, element_count_max);
        errdefer brackets.deinit(gpa);

        var breaks = try walk.Breaks.init(gpa, element_count_max);
        errdefer breaks.deinit(gpa);

        var shadow = try print.Shadow.init(gpa, arena_bytes_max);
        errdefer shadow.deinit(gpa);

        const statements = try created(edge.StatementScratch, gpa);
        errdefer gpa.destroy(statements);

        const return_colons = try created(tern.ReturnColons, gpa);
        errdefer gpa.destroy(return_colons);

        const memos = try created(core.Memos, gpa);
        errdefer gpa.destroy(memos);

        const join_stack = try created(core.JoinStack, gpa);
        const angle = document.literal(core.angle_close);
        const bar = document.literal(core.bar_lead);
        const comma = document.literal(core.comma);
        const closing = document.literal(core.paren_close);
        const hole = document.literal(core.space_hole);
        const opening = document.literal(core.paren_open);
        const semicolon = document.literal(core.semicolon);
        const spaced = document.literal(core.spaced);
        const spacing = document.literal(core.paren_spaced);

        assert(angle == 0);
        assert(spacing == literal_count - 1);

        return .{
            .angle = angle,
            .arena = arena,
            .bar = bar,
            .brackets = brackets,
            .breaks = breaks,
            .closing = closing,
            .comma = comma,
            .document = document,
            .hole = hole,
            .join_stack = join_stack,
            .memos = memos,
            .opening = opening,
            .return_colons = return_colons,
            .semicolon = semicolon,
            .shadow = shadow,
            .spaced = spaced,
            .spacing = spacing,
            .statements = statements,
        };
    }

    pub fn deinit(formatter: *Formatter, gpa: std.mem.Allocator) void {
        assert(formatter.angle == 0);
        assert(formatter.spacing == literal_count - 1);
        assert(!formatter.statements.evaluating);
        assert(!formatter.join_stack.evaluating);

        gpa.destroy(formatter.join_stack);
        gpa.destroy(formatter.memos);
        gpa.destroy(formatter.return_colons);
        gpa.destroy(formatter.statements);
        formatter.shadow.deinit(gpa);
        formatter.breaks.deinit(gpa);
        formatter.brackets.deinit(gpa);
        formatter.arena.deinit(gpa);
        formatter.document.deinit(gpa);
        formatter.* = undefined;
    }

    pub fn format(formatter: *Formatter, input: *const Input, out: *Buffer) error{Overflow}!void {
        assert(input.source.len <= std.math.maxInt(u32));
        assert(input.tokens.len <= std.math.maxInt(u32));

        return formatter.formatting(input, out, null);
    }

    pub fn formatting(
        formatter: *Formatter,
        input: *const Input,
        out: *Buffer,
        lines: ?*ArrayType(u32),
    ) error{Overflow}!void {
        assert(input.source.len <= std.math.maxInt(u32));
        assert(input.tokens.len <= std.math.maxInt(u32));
        if (lines) |mapped| assert(mapped.capacity() > 0);

        formatter.arena.clear();
        formatter.document.clear();
        formatter.shadow.clear();
        formatter.statements.begin();
        formatter.return_colons.begin();
        formatter.memos.begin();

        try formatter.indexed(input);
        try formatter.emitting(input);

        const arena = formatter.arena.const_slice();

        try print.printing(&formatter.document, input.source, arena, input.options, out, lines);
    }

    fn indexed(formatter: *Formatter, input: *const Input) error{Overflow}!void {
        assert(input.source.len <= std.math.maxInt(u32));
        assert(input.tokens.len <= std.math.maxInt(u32));

        try formatter.breaks.build(input.source, input.policy.carriage_breaks);

        try formatter.brackets.build(
            input.source,
            input.tokens,
            input.roles,
            input.policy.angle_types,
        );
    }

    fn spans(formatter: *const Formatter) Spans {
        assert(formatter.angle == 0);
        assert(formatter.spacing == literal_count - 1);

        return .{
            .angle = formatter.document.literal_span(formatter.angle),
            .bar = formatter.document.literal_span(formatter.bar),
            .closing = formatter.document.literal_span(formatter.closing),
            .comma = formatter.document.literal_span(formatter.comma),
            .hole = formatter.document.literal_span(formatter.hole),
            .opening = formatter.document.literal_span(formatter.opening),
            .semicolon = formatter.document.literal_span(formatter.semicolon),
            .spaced = formatter.document.literal_span(formatter.spaced),
            .spacing = formatter.document.literal_span(formatter.spacing),
        };
    }

    fn emitting(formatter: *Formatter, input: *const Input) error{Overflow}!void {
        assert(input.tokens.len <= std.math.maxInt(u32));
        assert(formatter.document.count() == 0);
        assert(formatter.arena.empty());

        const literals = formatter.spans();

        formatter.document.set_suffixed(input.policy.comment_suffix);

        var emitter: Emitter = .{
            .angle = literals.angle,
            .arena = &formatter.arena,
            .bar = literals.bar,
            .brackets = &formatter.brackets,
            .breaks = &formatter.breaks,
            .closing = literals.closing,
            .comma = literals.comma,
            .count = @intCast(input.tokens.len),
            .document = &formatter.document,
            .gives = input.gives,
            .hole = literals.hole,
            .join_stack = formatter.join_stack,
            .lists = input.lists,
            .macros = input.macros,
            .marks = input.marks,
            .memos = formatter.memos,
            .opaques = input.opaques,
            .opening = literals.opening,
            .operand_ends = input.operand_ends,
            .operands = input.operands,
            .options = input.options,
            .origin = input.origin,
            .origins = input.origins,
            .policy = input.policy,
            .rebalances = input.nests,
            .return_colons = formatter.return_colons,
            .roles = input.roles,
            .semicolon = literals.semicolon,
            .shadow = &formatter.shadow,
            .source = input.source,
            .spaced = literals.spaced,
            .spacing = literals.spacing,
            .statements = formatter.statements,
            .structured = structured(input.roles),
            .tokens = input.tokens,
        };

        try emit.run(&emitter);
    }
};

pub const Input = struct {
    added: []const u8,
    gives: []const u32,
    lists: []const u8,
    macros: []const u32,
    marks: []const u8,
    nests: []const u32,
    opaques: []const u32,
    operand_ends: []const u32,
    operands: []const u32,
    options: print.Options,
    origin: []const u8,
    origins: []const u32,
    policy: Policy,
    roles: []const u16,
    source: []const u8,
    tokens: []const Token,
};

const Spans = struct {
    angle: Span,
    bar: Span,
    closing: Span,
    comma: Span,
    hole: Span,
    opening: Span,
    semicolon: Span,
    spaced: Span,
    spacing: Span,
};

pub const Chained = @import("mask.zig").Chained;
pub const Heads = @import("mask.zig").Heads;
pub const Holed = @import("mask.zig").Holed;
pub const Initializer = @import("mask.zig").Initializer;
pub const Patterned = @import("mask.zig").Patterned;
pub const Policy = @import("policy.zig").Policy;
pub const RulesType = @import("mask.zig").RulesType;
pub const TailsType = @import("mask.zig").TailsType;
pub const Widths = @import("mask.zig").Widths;
pub const balanced = text.balanced;
pub const closed = text.closed;
pub const is_close = walk.is_close;
pub const is_open = walk.is_open;
pub const item_break = items.item_break;
pub const item_commas = items.item_commas;
pub const item_edges = items.item_edges;
pub const item_flat = items.item_flat;
pub const item_glued = items.item_glued;
pub const item_inline = items.item_inline;
pub const item_join = items.item_join;
pub const item_lines = items.item_lines;
pub const item_spaced = items.item_spaced;
const jsx_spans: bool = false;
pub const jsx_spans_off: bool = !jsx_spans;
pub const mark_expanded: u8 = 1 << 7;
pub const mark_flush: u8 = 1 << 5;
pub const mark_label: u8 = 1 << 6;
pub const mark_packed: u8 = 1 << 4;
pub const mark_steps: u8 = 0x0f;
pub const marked = @import("mask.zig").marked;
pub const nest_depth_max: u32 = 128;
pub const ranked = text.ranked;
pub const operand_held: u32 = 1 << 31;
pub const operand_none: u32 = std.math.maxInt(u32);
pub const role_block: u16 = 1 << 0;
pub const role_jsx: u16 = 1 << 7;
pub const role_jsx_child: u16 = 1 << 14;
pub const role_jsx_hole: u16 = 1 << 10;
pub const role_jsx_tag: u16 = 1 << 9;
pub const role_jsx_text: u16 = 1 << 11;
pub const role_jsx_tight: u16 = 1 << 13;
pub const role_jsx_wide: u16 = 1 << 12;
pub const role_jsx_wrap: u16 = 1 << 15;
pub const role_lambda: u16 = 1 << 2;
pub const role_part: u16 = 1 << 6;
pub const role_spaced: u16 = 1 << 4;
pub const role_span: u16 = 1 << 5;
pub const role_start: u16 = 1 << 1;
pub const role_tight: u16 = 1 << 3;
pub const role_type: u16 = 1 << 8;
pub const span_of = walk.span_of;
pub const substituting = walk.substituting;
pub const tailed = @import("mask.zig").tailed;
pub const terminated = @import("mask.zig").terminated;
pub const versioned = text.versioned;
const literal_count: u32 = 9;

fn created(comptime Scratch: type, gpa: std.mem.Allocator) error{OutOfMemory}!*Scratch {
    comptime assert(@hasDecl(Scratch, "init"));

    const scratch = try gpa.create(Scratch);

    scratch.init();

    return scratch;
}

fn structured(roles: []const u16) bool {
    assert(roles.len <= std.math.maxInt(u32));

    for (roles) |held| {
        if (held & core.structure_roles != 0) return true;
    }

    return false;
}
