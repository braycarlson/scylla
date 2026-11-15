const std = @import("std");
const assert = std.debug.assert;
const ArrayType = @import("../stdx/bounded/array.zig").ArrayType;
const PythonKind = @import("../syntax/python/kind.zig").Kind;
const Brackets = @import("../syntax/brackets.zig").Brackets;
const Span = @import("../stdx/bounded/span.zig");
const Summary = @import("../syntax/summary.zig").Summary;
const Token = @import("../syntax/token.zig");
const Tree = @import("../syntax/tree.zig").TreeType(PythonKind);
const View = @import("../syntax/python/ast.zig").View;
const stream = @import("../syntax/stream.zig");
const summary = @import("../syntax/summary.zig");
const walk = @import("../syntax/tree.zig").walk;

pub const Argument = struct {
    name: Span,
    summary: Summary,
    value_token_end: u32,
    value_token_start: u32,
};

pub const Assignment = struct {
    annotation: Span,
    scope: ?u32,
    target: Span,
    target_is_simple: bool,
    value_token_end: u32,
    value_token_start: u32,
};

pub const Base = struct {
    class_definition: u32,
    summary: Summary,
};

pub const Call = struct {
    argument_count: u32,
    argument_first: u32,
    callee_segment_count: u32,
    callee_segment_first: u32,
    paren_close: u32,
    paren_open: u32,
    scope: ?u32,
};

pub const Decorator = struct {
    call: ?u32,
    definition: ?u32,
    segment_count: u32,
    segment_first: u32,
};

pub const Definition = struct {
    header: u32,
    kind: Kind,
    name: u32,
    parent: ?u32,
    token_end: u32,
    token_start: u32,

    pub const Kind = enum {
        function,
        @"struct",
    };
};

pub const Limits = struct {
    row_count_max: u32,
    segment_count_max: u32,
};

pub const Outline = struct {
    arguments: ArrayType(Argument),
    assignments: ArrayType(Assignment),
    bases: ArrayType(Base),
    calls: ArrayType(Call),
    decorators: ArrayType(Decorator),
    definitions: ArrayType(Definition),
    items: ArrayType(Summary),
    segments: ArrayType(Span),

    pub fn init(
        outline: *Outline,
        gpa: std.mem.Allocator,
        limits: Limits,
    ) std.mem.Allocator.Error!void {
        assert(limits.row_count_max > 0);
        assert(limits.segment_count_max > 0);

        const row_count_max = limits.row_count_max;
        const segment_count_max = limits.segment_count_max;

        outline.arguments = try .init(gpa, row_count_max);
        errdefer outline.arguments.deinit(gpa);

        outline.assignments = try .init(gpa, row_count_max);
        errdefer outline.assignments.deinit(gpa);

        outline.bases = try .init(gpa, row_count_max);
        errdefer outline.bases.deinit(gpa);

        outline.calls = try .init(gpa, row_count_max);
        errdefer outline.calls.deinit(gpa);

        outline.decorators = try .init(gpa, row_count_max);
        errdefer outline.decorators.deinit(gpa);

        outline.definitions = try .init(gpa, row_count_max);
        errdefer outline.definitions.deinit(gpa);

        outline.items = try .init(gpa, row_count_max);
        errdefer outline.items.deinit(gpa);

        outline.segments = try .init(gpa, segment_count_max);

        assert(outline.calls.empty());
        assert(outline.segments.capacity() == segment_count_max);
    }

    pub fn deinit(outline: *Outline, gpa: std.mem.Allocator) void {
        assert(outline.calls.count() <= outline.calls.capacity());
        assert(outline.segments.count() <= outline.segments.capacity());

        outline.segments.deinit(gpa);
        outline.items.deinit(gpa);
        outline.definitions.deinit(gpa);
        outline.decorators.deinit(gpa);
        outline.calls.deinit(gpa);
        outline.bases.deinit(gpa);
        outline.assignments.deinit(gpa);
        outline.arguments.deinit(gpa);
        outline.* = undefined;
    }

    pub fn clear(outline: *Outline) void {
        outline.arguments.clear();
        outline.assignments.clear();
        outline.bases.clear();
        outline.calls.clear();
        outline.decorators.clear();
        outline.definitions.clear();
        outline.items.clear();
        outline.segments.clear();

        assert(outline.calls.empty());
        assert(outline.segments.empty());
    }

    pub fn segments_of(outline: *const Outline, first: u32, count: u32) []const Span {
        assert(first <= outline.segments.count());
        assert(count <= outline.segments.count() - first);

        return outline.segments.const_slice()[first..][0..count];
    }
};

const Builder = struct {
    outline: *Outline,
    pairs: *const Brackets,
    source: []const u8,
    tokens: []const Token,

    fn build_definitions(builder: *Builder, root: View) void {
        assert(root.index() < root.node_count());

        const recorded = &builder.outline.definitions;
        var open: [definition_depth_max]Open = undefined;
        var depth: u32 = 0;
        var walker = walk(Tree, root.tree);

        assert(recorded.empty());

        for (0..2 * root.tree.count() + 1) |_| {
            const step = walker.next() orelse break;

            switch (step) {
                .enter => |node| {
                    const parent = if (depth == 0) null else open[depth - 1].definition;
                    const definition = definition_of(root.at(node), parent) orelse continue;

                    if (recorded.full()) continue;
                    if (depth == definition_depth_max) continue;

                    open[depth] = .{ .definition = recorded.count(), .node = node };
                    depth += 1;

                    recorded.push(definition);
                },
                .leave => |node| {
                    if (depth == 0) continue;
                    if (open[depth - 1].node != node) continue;

                    depth -= 1;
                },
            }
        }

        assert(depth == 0);
        assert(walker.node == null);
    }

    fn build_calls(builder: *Builder) void {
        var scopes: Scopes = .init(builder.definitions());
        var index: u32 = 0;

        while (index < builder.count()) {
            if (!builder.is_name(index)) {
                index += 1;

                continue;
            }

            if (builder.is_dotted_tail(index)) {
                index += 1;

                continue;
            }

            const chain = builder.chain_end(index);
            const open = chain + 1;

            const close = builder.call_close(open) orelse {
                index = chain + 1;

                continue;
            };

            scopes.advance(index);

            const scope = scopes.current();
            const callee = builder.push_segments(index, chain);
            const arguments = builder.build_arguments(open, close);

            if (!builder.outline.calls.full()) {
                builder.outline.calls.push(.{
                    .argument_count = arguments.count,
                    .argument_first = arguments.first,
                    .callee_segment_count = callee.count,
                    .callee_segment_first = callee.first,
                    .paren_close = close,
                    .paren_open = open,
                    .scope = scope,
                });
            }

            assert(open > index);

            index = open + 1;
        }
    }

    fn call_close(builder: *const Builder, open: u32) ?u32 {
        assert(open > 0);

        if (open >= builder.count()) return null;
        if (!builder.tokens[open].is_punctuation(.paren_open)) return null;

        const close = builder.pairs.partner_of(open) orelse return null;

        assert(close > open);

        return close;
    }

    fn push_segments(builder: *Builder, first: u32, last: u32) Rows {
        assert(first <= last);
        assert(last < builder.count());

        const segments = &builder.outline.segments;
        const segment_first = segments.count();
        var segment_count: u32 = 0;
        var segment = first;

        while (segment <= last) : (segment += 2) {
            if (!builder.is_name(segment)) continue;
            if (segments.full()) continue;

            segments.push(builder.tokens[segment].span());
            segment_count += 1;
        }

        assert(segment_first + segment_count == segments.count());

        return .{ .count = segment_count, .first = segment_first };
    }

    fn build_arguments(builder: *Builder, open: u32, close: u32) Rows {
        assert(open < close);
        assert(close < builder.count());

        const arguments = &builder.outline.arguments;
        const argument_first = arguments.count();
        const depth = builder.pairs.depth_of(open) + 1;
        var argument_count: u32 = 0;
        var start = open + 1;
        var index = open + 1;

        while (index <= close) : (index += 1) {
            if (!builder.splits(index, close, depth)) continue;

            if (builder.significant_next(start, index) != null) {
                const argument = builder.read_argument(start, index);

                if (!arguments.full()) {
                    arguments.push(argument);
                    argument_count += 1;
                }
            }

            start = index + 1;
        }

        assert(argument_first + argument_count == arguments.count());

        return .{ .count = argument_count, .first = argument_first };
    }

    fn read_argument(builder: *Builder, start: u32, end: u32) Argument {
        assert(start < end);
        assert(end <= builder.count());

        var name: Span = .empty;
        var value = start;

        if (builder.named_of(start, end)) |named| {
            name = builder.tokens[named.name].span();
            value = named.equals + 1;
        }

        const read = builder.summarize(value, end);

        assert(value <= end);

        return .{
            .name = name,
            .summary = read,
            .value_token_end = end,
            .value_token_start = value,
        };
    }

    fn named_of(builder: *const Builder, start: u32, end: u32) ?Named {
        assert(start < end);
        assert(end <= builder.count());

        const name = builder.significant_next(start, end) orelse return null;
        if (!builder.is_name(name)) return null;

        const equals = builder.significant_next(name + 1, end) orelse return null;
        if (!builder.tokens[equals].is_punctuation(.assign)) return null;
        if (builder.chain_end(name) != name) return null;

        assert(equals > name);

        return .{ .equals = equals, .name = name };
    }

    fn summarize(builder: *Builder, start: u32, end: u32) Summary {
        assert(start <= end);
        assert(end <= builder.count());

        return summary.read(builder.source, builder.tokens, builder.pairs, .{
            .token_end = end,
            .token_start = start,
        }, .{
            .items = &builder.outline.items,
            .segments = &builder.outline.segments,
        });
    }

    fn build_statements(builder: *Builder) void {
        var scopes: Scopes = .init(builder.definitions());
        var start: u32 = 0;
        var index: u32 = 0;

        while (index <= builder.count()) : (index += 1) {
            if (index < builder.count()) {
                if (!builder.statement_ends(start, index)) continue;
            }

            if (builder.significant_next(start, index) != null) {
                scopes.advance(start);

                const scope = scopes.current();

                builder.read_statement(start, index, scope);
            }

            start = index + 1;
        }

        assert(start == builder.count() + 1);
    }

    fn statement_ends(builder: *const Builder, start: u32, index: u32) bool {
        assert(start <= index);
        assert(index < builder.count());

        return switch (builder.tokens[index].kind) {
            .block_end, .block_start => true,
            .newline => builder.pairs.depth_of(index) == 0,
            .punctuation => |punctuation| ends: {
                if (punctuation != .colon) break :ends false;
                if (builder.pairs.depth_of(index) != 0) break :ends false;

                break :ends !builder.annotates(start, index);
            },
            .comment, .identifier, .keyword, .number, .string => false,
        };
    }

    fn annotates(builder: *const Builder, start: u32, colon: u32) bool {
        assert(start <= colon);
        assert(builder.tokens[colon].is_punctuation(.colon));

        const first = builder.significant_next(start, colon) orelse return false;
        if (!builder.is_name(first)) return false;
        if (builder.tokens[first].kind == .keyword) return false;
        return builder.significant_next(builder.chain_end(first) + 1, colon) == null;
    }

    fn read_statement(builder: *Builder, start: u32, end: u32, scope: ?u32) void {
        assert(start < end);
        assert(end <= builder.count());
        if (scope) |held| assert(held < builder.definitions().len);

        const first = builder.significant_next(start, end) orelse return;

        if (std.mem.eql(u8, builder.text(first), decorator_prefix)) {
            builder.read_decorator(first + 1, end);

            return;
        }

        if (!builder.is_name(first)) return;

        const chain = builder.chain_end(first);
        const after = builder.significant_next(chain + 1, end) orelse return;
        const colon = builder.tokens[after].is_punctuation(.colon);

        if (!colon) {
            if (!builder.tokens[after].is_punctuation(.assign)) return;
        }

        const equals = if (colon) builder.assign_after(after + 1, end) else after;
        var annotation: Span = .empty;

        if (colon) annotation = builder.run_between(after + 1, equals orelse end);

        const head = builder.tokens[first];
        const tail = builder.tokens[chain];

        if (builder.outline.assignments.full()) return;

        builder.outline.assignments.push(.{
            .annotation = annotation,
            .scope = scope,
            .target = Span.between(head.offset, tail.end()),
            .target_is_simple = chain == first,
            .value_token_end = end,
            .value_token_start = if (equals) |held| held + 1 else end,
        });
    }

    fn assign_after(builder: *const Builder, start: u32, end: u32) ?u32 {
        assert(start <= end);
        assert(end <= builder.count());

        var index = start;

        while (index < end) {
            if (builder.tokens[index].is_punctuation(.assign)) return index;

            const partner = builder.pairs.partner_of(index) orelse index;
            const skips = partner > index and partner < end;

            index = if (skips) partner + 1 else index + 1;
        }

        return null;
    }

    fn run_between(builder: *const Builder, start: u32, end: u32) Span {
        assert(start <= end);
        assert(end <= builder.count());

        const first = builder.significant_next(start, end) orelse return .empty;
        var last = first;
        var index = first;

        while (index < end) : (index += 1) {
            if (builder.is_significant(index)) last = index;
        }

        assert(last >= first);

        return Span.between(builder.tokens[first].offset, builder.tokens[last].end());
    }

    fn read_decorator(builder: *Builder, start: u32, end: u32) void {
        assert(start <= end);
        assert(end <= builder.count());

        const first = builder.significant_next(start, end) orelse return;
        if (!builder.is_name(first)) return;

        const chain = builder.chain_end(first);
        const segments = builder.push_segments(first, chain);
        const open = builder.significant_next(chain + 1, end);
        var call: ?u32 = null;

        if (open) |held| {
            if (builder.tokens[held].is_punctuation(.paren_open)) call = builder.call_at(held);
        }

        if (builder.outline.decorators.full()) return;

        builder.outline.decorators.push(.{
            .call = call,
            .definition = builder.definition_after(end),
            .segment_count = segments.count,
            .segment_first = segments.first,
        });
    }

    fn call_at(builder: *const Builder, open: u32) ?u32 {
        assert(open < builder.count());
        assert(builder.tokens[open].is_punctuation(.paren_open));

        for (builder.outline.calls.const_slice(), 0..) |call, index| {
            if (call.paren_open == open) {
                assert(index < builder.outline.calls.count());

                return @intCast(index);
            }
        }

        return null;
    }

    fn definition_after(builder: *const Builder, token: u32) ?u32 {
        assert(token <= builder.count());

        for (builder.definitions(), 0..) |definition, index| {
            if (definition.token_start >= token) {
                assert(index < builder.definitions().len);

                return @intCast(index);
            }
        }

        return null;
    }

    fn build_bases(builder: *Builder) void {
        const definition_count = builder.outline.definitions.count();

        for (0..definition_count) |index| {
            builder.read_bases(@intCast(index));
        }

        assert(builder.outline.bases.count() <= builder.outline.bases.capacity());
    }

    fn read_bases(builder: *Builder, definition: u32) void {
        assert(definition < builder.outline.definitions.count());

        const held = builder.outline.definitions.get(definition);
        if (held.kind != .@"struct") return;

        const name = held.name;
        const end = @min(held.token_end, builder.count());
        const after = builder.significant_next(name + 1, end) orelse return;
        if (!builder.tokens[after].is_punctuation(.paren_open)) return;

        const close = builder.pairs.partner_of(after) orelse return;
        const depth = builder.pairs.depth_of(after) + 1;
        var start = after + 1;
        var index = after + 1;

        assert(close > after);

        while (index <= close) : (index += 1) {
            if (!builder.splits(index, close, depth)) continue;

            if (builder.significant_next(start, index) != null) {
                const base = builder.summarize(start, index);

                if (!builder.outline.bases.full()) {
                    builder.outline.bases.push(.{
                        .class_definition = definition,
                        .summary = base,
                    });
                }
            }

            start = index + 1;
        }
    }

    fn splits(builder: *const Builder, index: u32, close: u32, depth: u32) bool {
        assert(index <= close);
        assert(depth > 0);

        if (index == close) return true;
        if (!builder.tokens[index].is_punctuation(.comma)) return false;
        return builder.pairs.depth_of(index) == depth;
    }

    fn chain_end(builder: *const Builder, first: u32) u32 {
        assert(first < builder.count());

        var last = first;

        while (last + 2 < builder.count()) : (last += 2) {
            if (!builder.tokens[last + 1].is_punctuation(.dot)) break;
            if (!builder.is_name(last + 2)) break;
        }

        assert(last >= first);
        assert(last < builder.count());

        return last;
    }

    fn is_dotted_tail(builder: *const Builder, index: u32) bool {
        assert(index < builder.count());

        if (index < 2) return false;
        if (!builder.tokens[index - 1].is_punctuation(.dot)) return false;
        return builder.is_name(index - 2);
    }

    fn is_name(builder: *const Builder, index: u32) bool {
        assert(builder.tokens.len <= std.math.maxInt(u32));

        if (index >= builder.count()) return false;

        return switch (builder.tokens[index].kind) {
            .identifier, .keyword => true,
            .block_end, .block_start, .comment, .newline, .number, .punctuation, .string => false,
        };
    }

    fn is_significant(builder: *const Builder, index: u32) bool {
        assert(index < builder.count());

        return Token.is_significant(builder.tokens[index].kind);
    }

    fn significant_next(builder: *const Builder, from: u32, end: u32) ?u32 {
        assert(from < none);
        assert(end < none);

        return stream.significant_next(builder.tokens, from, end);
    }

    fn text(builder: *const Builder, index: u32) []const u8 {
        assert(index < builder.count());

        return builder.tokens[index].text(builder.source);
    }

    fn definitions(builder: *const Builder) []const Definition {
        return builder.outline.definitions.const_slice();
    }

    fn count(builder: *const Builder) u32 {
        assert(builder.tokens.len <= std.math.maxInt(u32));

        return @intCast(builder.tokens.len);
    }
};

const Named = struct {
    equals: u32,
    name: u32,
};

const Open = struct {
    definition: u32,
    node: u32,
};

const Rows = struct {
    count: u32,
    first: u32,
};

const Scopes = struct {
    definitions: []const Definition,
    depth: u32,
    next: u32,
    stack: [scope_depth_max]u32,

    fn init(definitions: []const Definition) Scopes {
        assert(definitions.len <= std.math.maxInt(u32));

        if (definitions.len > 0) assert(definitions[0].parent == null);

        return .{
            .definitions = definitions,
            .depth = 0,
            .next = 0,
            .stack = @splat(none),
        };
    }

    fn advance(scopes: *Scopes, token: u32) void {
        assert(scopes.next <= scopes.definitions.len);

        while (scopes.next < scopes.definitions.len) : (scopes.next += 1) {
            if (scopes.definitions[scopes.next].token_start > token) break;

            if (scopes.depth < scope_depth_max) {
                scopes.stack[scopes.depth] = scopes.next;
                scopes.depth += 1;
            }
        }

        while (scopes.depth > 0) {
            const index = scopes.stack[scopes.depth - 1];
            if (scopes.definitions[index].token_end > token) break;

            scopes.depth -= 1;
        }

        assert(scopes.depth <= scope_depth_max);
        assert(scopes.depth <= scopes.next);
    }

    fn current(scopes: *const Scopes) ?u32 {
        assert(scopes.depth <= scope_depth_max);

        if (scopes.depth == 0) return null;

        const index = scopes.stack[scopes.depth - 1];

        assert(index < scopes.definitions.len);

        return index;
    }
};

const decorator_prefix = "@";
const definition_depth_max: u32 = 64;
const none = std.math.maxInt(u32);
const scope_depth_max: u32 = 64;

comptime {
    assert(scope_depth_max > 0);
    assert(scope_depth_max < none);
    assert(definition_depth_max >= scope_depth_max);
}

fn definition_of(view: View, parent: ?u32) ?Definition {
    assert(view.index() < view.node_count());
    if (parent) |held| assert(held < std.math.maxInt(u32));

    const kind: Definition.Kind = switch (view.kind()) {
        .class_def => .@"struct",
        .async_function_def, .function_def => .function,
        else => return null,
    };

    const header_kind: PythonKind = if (kind == .@"struct") .class_keyword else .def_keyword;
    const header = view.token_first(header_kind) orelse return null;
    const name = view.token_first(.identifier) orelse return null;
    const body = view.child_first_of(.block) orelse return null;

    assert(header < name);
    assert(name < body.token_start());
    assert(body.token_start() <= body.token_end());

    return .{
        .header = header,
        .kind = kind,
        .name = name,
        .parent = parent,
        .token_end = body.token_end(),
        .token_start = body.token_start(),
    };
}

pub fn build(source: []const u8, pairs: *const Brackets, root: View, outline: *Outline) void {
    assert(root.parent() == null);

    const tokens = root.tokens;

    assert(source.len <= std.math.maxInt(u32));
    assert(pairs.count() == tokens.len);

    outline.clear();

    var builder: Builder = .{
        .outline = outline,
        .pairs = pairs,
        .source = source,
        .tokens = tokens,
    };

    builder.build_definitions(root);
    builder.build_calls();
    builder.build_statements();
    builder.build_bases();

    assert(outline.arguments.count() <= outline.arguments.capacity());
    assert(outline.segments.count() <= outline.segments.capacity());
}

test "a scope stack follows the definitions that cover a token" {
    const definitions = [_]Definition{
        .{
            .header = 0,
            .kind = .@"struct",
            .name = 0,
            .parent = null,
            .token_end = 9,
            .token_start = 1,
        },
        .{
            .header = 2,
            .kind = .function,
            .name = 2,
            .parent = 0,
            .token_end = 6,
            .token_start = 3,
        },
    };

    var scopes: Scopes = .init(&definitions);

    scopes.advance(0);

    try std.testing.expectEqual(null, scopes.current());

    scopes.advance(4);

    try std.testing.expectEqual(1, scopes.current());

    scopes.advance(7);

    try std.testing.expectEqual(0, scopes.current());

    scopes.advance(10);

    try std.testing.expectEqual(null, scopes.current());
}
