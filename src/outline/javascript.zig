const std = @import("std");
const assert = std.debug.assert;
const ArrayType = @import("../stdx/bounded/array.zig").ArrayType;
const Brackets = @import("../syntax/brackets.zig").Brackets;
const Span = @import("../stdx/bounded/span.zig");
const Token = @import("../syntax/token.zig");
const sort = @import("../stdx/sort.zig");
const stream = @import("../syntax/stream.zig");

pub const BraceKind = enum {
    block,
    none,
    object,
};

pub const DeclarationKind = enum {
    catch_parameter,
    class,
    @"const",
    function,
    let,
    parameter,
    @"var",
};

pub const ScopeKind = enum {
    block,
    function,
    program,
};

pub const Scope = struct {
    kind: ScopeKind,
    parent: ?u32,
    token_end: u32,
    token_start: u32,
};

pub const Declaration = struct {
    kind: DeclarationKind,
    name: Span,
    scope_token_end: u32,
    scope_token_start: u32,
    value_token_end: u32,
    value_token_start: u32,
};

pub const Member = struct {
    has_await: bool,
    is_async: bool,
    is_method: bool,
    is_shorthand: bool,
    is_spread: bool,
    name: Span,
    object: u32,
    token_end: u32,
    token_start: u32,
    value_token_end: u32,
    value_token_start: u32,
};

pub const ObjectLiteral = struct {
    brace_close: u32,
    brace_open: u32,
    member_count: u32,
    member_first: u32,
};

pub const Call = struct {
    callee_segment_count: u32,
    callee_segment_first: u32,
    paren_close: u32,
    paren_open: u32,
    scope: ?u32,
};

pub const Assigned = struct {
    name: Span,
};

pub const Statement = struct {
    scope: ?u32,
    token_end: u32,
    token_start: u32,
};

pub const Fate = struct {
    chained: bool,
    floating: bool,
};

pub const Limits = struct {
    row_count_max: u32,
    segment_count_max: u32,
    token_count_max: u32,
};

pub const Outline = struct {
    assigned: ArrayType(Assigned),
    braces: ArrayType(BraceKind),
    by_start: ArrayType(u32),
    calls: ArrayType(Call),
    declarations: ArrayType(Declaration),
    members: ArrayType(Member),
    objects: ArrayType(ObjectLiteral),
    scopes: ArrayType(Scope),
    segments: ArrayType(Span),
    statements: ArrayType(Statement),

    pub fn init(
        outline: *Outline,
        gpa: std.mem.Allocator,
        limits: Limits,
    ) std.mem.Allocator.Error!void {
        assert(limits.row_count_max > 0);
        assert(limits.segment_count_max > 0);
        assert(limits.token_count_max > 0);

        outline.assigned = try .init(gpa, limits.row_count_max);
        errdefer outline.assigned.deinit(gpa);

        outline.braces = try .init(gpa, limits.token_count_max);
        errdefer outline.braces.deinit(gpa);

        outline.by_start = try .init(gpa, limits.row_count_max);
        errdefer outline.by_start.deinit(gpa);

        outline.calls = try .init(gpa, limits.row_count_max);
        errdefer outline.calls.deinit(gpa);

        outline.declarations = try .init(gpa, limits.row_count_max);
        errdefer outline.declarations.deinit(gpa);

        outline.members = try .init(gpa, limits.row_count_max);
        errdefer outline.members.deinit(gpa);

        outline.objects = try .init(gpa, limits.row_count_max);
        errdefer outline.objects.deinit(gpa);

        outline.scopes = try .init(gpa, limits.row_count_max);
        errdefer outline.scopes.deinit(gpa);

        outline.segments = try .init(gpa, limits.segment_count_max);
        errdefer outline.segments.deinit(gpa);

        outline.statements = try .init(gpa, limits.row_count_max);

        assert(outline.scopes.empty());
        assert(outline.braces.capacity() == limits.token_count_max);
    }

    pub fn deinit(outline: *Outline, gpa: std.mem.Allocator) void {
        assert(outline.scopes.count() <= outline.scopes.capacity());
        assert(outline.braces.count() <= outline.braces.capacity());

        outline.statements.deinit(gpa);
        outline.segments.deinit(gpa);
        outline.scopes.deinit(gpa);
        outline.objects.deinit(gpa);
        outline.members.deinit(gpa);
        outline.declarations.deinit(gpa);
        outline.calls.deinit(gpa);
        outline.by_start.deinit(gpa);
        outline.braces.deinit(gpa);
        outline.assigned.deinit(gpa);
        outline.* = undefined;
    }

    pub fn brace_kind(outline: *const Outline, token: u32) BraceKind {
        assert(token < outline.braces.count());

        const kind = outline.braces.get(token);

        if (kind != .none) assert(outline.scopes.count() > 0);

        return kind;
    }

    pub fn clear(outline: *Outline) void {
        outline.assigned.clear();
        outline.braces.clear();
        outline.by_start.clear();
        outline.calls.clear();
        outline.declarations.clear();
        outline.members.clear();
        outline.objects.clear();
        outline.scopes.clear();
        outline.segments.clear();
        outline.statements.clear();

        assert(outline.scopes.empty());
        assert(outline.braces.empty());
    }

    pub fn members_of(outline: *const Outline, object: ObjectLiteral) []const Member {
        assert(object.member_first <= outline.members.count());
        assert(object.member_count <= outline.members.count() - object.member_first);

        return outline.members.const_slice()[object.member_first..][0..object.member_count];
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

    fn build_braces(builder: *Builder) void {
        assert(builder.outline.braces.empty());

        for (0..builder.count()) |position| {
            builder.outline.braces.push(builder.brace_kind_of(@intCast(position)));
        }

        assert(builder.outline.braces.count() == builder.count());
    }

    fn brace_kind_of(builder: *const Builder, index: u32) BraceKind {
        assert(index < builder.count());

        if (!builder.opens_brace(index)) return .none;

        const object = builder.brace_is_object(index);

        assert(builder.tokens[index].length == 1);

        return if (object) .object else .block;
    }

    fn brace_is_object(builder: *const Builder, index: u32) bool {
        assert(builder.opens_brace(index));

        const previous = builder.significant_previous(index) orelse {
            return builder.brace_holds_members(index);
        };

        if (builder.is_function_body(index)) return false;

        const token = builder.tokens[previous];
        if (token.is_keyword(.@"return")) return true;

        assert(previous < index);

        return switch (token.kind) {
            .identifier, .keyword, .number, .string => false,
            .punctuation => |punctuation| switch (punctuation) {
                .assign, .assign_declare, .bracket_open, .colon, .comma, .paren_open => true,
                .other => !std.mem.eql(u8, builder.text(previous), "}"),
                else => false,
            },
            .block_end, .block_start, .comment, .newline => false,
        };
    }

    fn brace_holds_members(builder: *const Builder, brace: u32) bool {
        assert(brace < builder.count());

        var first = builder.significant_next(brace + 1) orelse return false;
        if (std.mem.eql(u8, builder.text(first), "}")) return true;
        if (std.mem.eql(u8, builder.text(first), "...")) return true;

        if (std.mem.eql(u8, builder.text(first), "async")) {
            if (builder.significant_next(first + 1)) |after| first = after;
        }

        switch (builder.tokens[first].kind) {
            .identifier, .string => {},
            else => return false,
        }

        const next = builder.significant_next(first + 1) orelse return false;
        const after = builder.tokens[next];

        assert(next > first);

        if (after.is_punctuation(.colon)) return true;
        if (after.is_punctuation(.comma)) return true;
        if (after.is_punctuation(.paren_open)) return true;
        return std.mem.eql(u8, builder.text(next), "}");
    }

    fn is_function_body(builder: *const Builder, brace: u32) bool {
        assert(brace < builder.count());

        const previous = builder.significant_previous(brace) orelse return false;
        if (std.mem.eql(u8, builder.text(previous), "=>")) return true;
        if (!builder.tokens[previous].is_punctuation(.paren_close)) return false;

        const open = builder.pairs.partner_of(previous) orelse return false;
        const before = builder.significant_previous(open) orelse return false;

        assert(open < previous);

        return !contains(&header_words, builder.text(before));
    }

    fn build_scopes(builder: *Builder) void {
        assert(builder.outline.scopes.empty());

        builder.outline.scopes.push(.{
            .kind = .program,
            .parent = null,
            .token_end = builder.count(),
            .token_start = 0,
        });

        var stack: Stack = .{ .depth = 1, .indexes = @splat(0) };

        for (0..builder.count()) |position| {
            builder.scope_open(@intCast(position), &stack);
        }

        assert(stack.depth >= 1);

        builder.build_arrow_scopes();
    }

    fn open_at(builder: *const Builder, stack: *Stack, start: u32) u32 {
        assert(stack.depth <= scope_stack_max);

        for (0..scope_stack_max) |_| {
            if (stack.depth <= 1) break;

            const held = builder.outline.scopes.get(stack.indexes[stack.depth - 1]);
            const covers = held.token_end > start and held.token_start <= start;
            if (covers) break;

            stack.depth -= 1;
        }

        assert(stack.depth >= 1);

        return stack.indexes[stack.depth - 1];
    }

    fn scope_open(builder: *Builder, index: u32, stack: *Stack) void {
        assert(index < builder.count());

        if (!builder.opens_brace(index)) return;

        const end = if (builder.pairs.partner_of(index)) |close| close + 1 else builder.count();
        const function_body = builder.is_function_body(index);

        assert(end > index);

        if (!function_body) {
            if (builder.outline.braces.get(index) != .block) return;
        }

        const start = builder.scope_start(index, function_body);
        const parent = builder.open_at(stack, start);
        const held = builder.outline.scopes.count();
        const scopes = &builder.outline.scopes;

        assert(start <= index);

        if (scopes.full()) return;

        scopes.push(.{
            .kind = if (function_body) .function else .block,
            .parent = parent,
            .token_end = end,
            .token_start = start,
        });

        stack.push(held);

        if (!function_body) return;
        if (scopes.full()) return;

        const body = scopes.count();

        scopes.push(.{ .kind = .block, .parent = held, .token_end = end, .token_start = index });
        stack.push(body);
    }

    fn scope_start(builder: *const Builder, brace: u32, function_body: bool) u32 {
        assert(brace < builder.count());
        assert(builder.opens_brace(brace));

        if (function_body) return builder.function_start(brace);
        return builder.block_start(brace);
    }

    fn build_arrow_scopes(builder: *Builder) void {
        assert(builder.outline.scopes.count() >= 1);

        for (0..builder.count()) |position| {
            const index: u32 = @intCast(position);
            if (!std.mem.eql(u8, builder.text(index), "=>")) continue;

            if (builder.significant_next(index + 1)) |body| {
                if (builder.opens_brace(body)) continue;
            }

            const start = builder.arrow_start(index);
            const end = builder.expression_end(index + 1);
            const parent = builder.scope_covering(start);

            assert(start <= index);
            assert(end > index);

            if (builder.outline.scopes.full()) continue;

            builder.outline.scopes.push(.{
                .kind = .function,
                .parent = parent,
                .token_end = end,
                .token_start = start,
            });
        }
    }

    fn arrow_start(builder: *const Builder, arrow: u32) u32 {
        assert(arrow < builder.count());

        const previous = builder.significant_previous(arrow) orelse return arrow;

        if (builder.tokens[previous].is_punctuation(.paren_close)) {
            if (builder.pairs.partner_of(previous)) |open| return open;
        }

        assert(previous < arrow);

        return previous;
    }

    fn block_start(builder: *const Builder, brace: u32) u32 {
        assert(brace < builder.count());

        const previous = builder.significant_previous(brace) orelse return brace;
        if (!builder.tokens[previous].is_punctuation(.paren_close)) return brace;

        const open = builder.pairs.partner_of(previous) orelse return brace;
        const before = builder.significant_previous(open) orelse return brace;

        assert(before < open);

        if (contains(&header_words, builder.text(before))) return before;
        return brace;
    }

    fn function_start(builder: *const Builder, brace: u32) u32 {
        assert(brace < builder.count());

        const previous = builder.significant_previous(brace) orelse return brace;
        if (std.mem.eql(u8, builder.text(previous), "=>")) return builder.arrow_start(previous);

        const open = builder.pairs.partner_of(previous) orelse return brace;
        const start = builder.header_start(open);

        assert(start <= open);

        return start;
    }

    fn header_start(builder: *const Builder, open: u32) u32 {
        assert(open < builder.count());

        var start = open;

        for (0..open) |_| {
            const previous = builder.significant_previous(start) orelse break;
            if (!builder.extends_header(previous)) break;

            start = previous;
        }

        assert(start <= open);

        return start;
    }

    fn extends_header(builder: *const Builder, index: u32) bool {
        assert(index < builder.count());
        assert(builder.is_significant(index));

        const token = builder.tokens[index];

        switch (token.kind) {
            .identifier, .number, .string => return true,
            else => {},
        }

        if (token.is_keyword(.function)) return true;

        const text_held = builder.text(index);
        return contains(&.{ "async", "get", "set", "*" }, text_held);
    }

    fn expression_end(builder: *const Builder, from: u32) u32 {
        assert(from <= builder.count());

        const depth = if (from < builder.count()) builder.pairs.depth_of(from) else 0;
        var index = from;

        while (index < builder.count()) : (index += 1) {
            const here = builder.pairs.depth_of(index);
            if (here < depth) return index;
            if (here > depth) continue;

            const token = builder.tokens[index];
            if (token.is_punctuation(.comma)) return index;
            if (token.is_punctuation(.semicolon)) return index;

            if (builder.ends_line(index)) {
                assert(index + 1 <= builder.count());

                return index + 1;
            }
        }

        assert(index == builder.count());

        return builder.count();
    }

    fn expression_run(builder: *const Builder, from: u32, depth: u32) u32 {
        assert(from <= builder.count());

        var index = from;

        while (index < builder.count()) : (index += 1) {
            const here = builder.pairs.depth_of(index);
            if (here < depth) return index;
            if (here > depth) continue;
            if (builder.tokens[index].is_punctuation(.semicolon)) return index;

            if (builder.ends_line(index)) {
                assert(index + 1 <= builder.count());

                return index + 1;
            }
        }

        assert(index == builder.count());

        return builder.count();
    }

    fn ends_line(builder: *const Builder, index: u32) bool {
        assert(index < builder.count());
        assert(builder.tokens[index].end() <= builder.source.len);

        if (!builder.breaks_line(index)) return false;
        return !builder.continues_expression(index + 1);
    }

    fn continues_expression(builder: *const Builder, from: u32) bool {
        assert(from <= builder.count());

        const next = builder.significant_next(from) orelse return false;
        const token = builder.tokens[next];

        assert(next >= from);

        switch (token.kind) {
            .punctuation => |punctuation| switch (punctuation) {
                .dot,
                .comma,
                .colon,
                .paren_close,
                .bracket_close,
                .assign,
                .equal,
                .not_equal,
                .ampersand_double,
                .bar_double,
                .arrow,
                .star,
                .slash,
                => return true,
                else => {},
            },
            else => {},
        }

        return contains(&continuation_words, builder.text(next));
    }

    fn scope_covering(builder: *const Builder, token: u32) ?u32 {
        assert(token < builder.count());

        const scope = builder.narrowest(token, false);

        if (scope) |index| assert(index < builder.outline.scopes.count());

        return scope;
    }

    fn scope_of(builder: *const Builder, token: u32, functions_only: bool) ?u32 {
        assert(token < builder.count());

        const scope = builder.narrowest(token, functions_only);

        if (scope) |index| {
            if (functions_only) assert(builder.outline.scopes.get(index).kind != .block);
        }

        return scope;
    }

    fn narrowest(builder: *const Builder, token: u32, functions_only: bool) ?u32 {
        assert(token < std.math.maxInt(u32));

        const scopes = builder.outline.scopes.const_slice();

        assert(scopes.len > 0);

        if (builder.outline.by_start.count() == scopes.len) {
            return builder.indexed(token, functions_only);
        }

        var found: ?u32 = null;
        var width: u32 = std.math.maxInt(u32);
        var position = scopes.len;

        while (position > 0) {
            position -= 1;

            const scope = scopes[position];
            if (scope.token_start > token) continue;
            if (scope.token_end <= token) continue;

            if (functions_only) {
                if (scope.kind == .block) continue;
            }

            const span = scope.token_end - scope.token_start;

            if (span < width) {
                found = @intCast(position);
                width = span;
            }
        }

        if (found) |index| assert(scopes[index].token_start <= token);

        return found;
    }

    fn indexed(builder: *const Builder, token: u32, functions_only: bool) ?u32 {
        const scopes = builder.outline.scopes.const_slice();
        const by_start = builder.outline.by_start.const_slice();

        assert(by_start.len == scopes.len);
        assert(token < builder.count());

        const above = std.sort.partitionPoint(u32, by_start, Starts{
            .scopes = scopes,
            .token = token,
        }, Starts.at_or_before);

        if (above == 0) return null;

        var scope: ?u32 = by_start[above - 1];

        for (0..scopes.len + 1) |_| {
            const index = scope orelse return null;
            const held = scopes[index];
            const covers = held.token_start <= token and held.token_end > token;

            if (covers) {
                if (!functions_only) return index;
                if (held.kind != .block) return index;
            }

            scope = held.parent;
        }

        return null;
    }

    fn index_scopes(builder: *Builder) void {
        const scopes = builder.outline.scopes.const_slice();
        const by_start = &builder.outline.by_start;

        by_start.clear();

        for (0..scopes.len) |index| {
            by_start.push(@intCast(index));
        }

        sort.unstable(u32, by_start.slice(), @TypeOf(scopes), scopes, scope_precedes);

        const head = scopes[by_start.get(0)];

        assert(by_start.count() == scopes.len);
        assert(head.token_start == scopes[0].token_start);
        assert(head.token_end == scopes[0].token_end);
    }

    fn push_declaration(builder: *Builder, kind: DeclarationKind, name: u32, value: Value) void {
        assert(name < builder.count());
        assert(value.token_start <= value.token_end);

        const block_scoped = kind != .@"var" and kind != .function;
        const scope = builder.scope_of(name, !block_scoped);

        const held: Scope = if (scope) |index| builder.outline.scopes.get(index) else .{
            .kind = .program,
            .parent = null,
            .token_end = builder.count(),
            .token_start = 0,
        };

        assert(held.token_start <= name);
        assert(name < held.token_end);

        if (builder.outline.declarations.full()) return;

        builder.outline.declarations.push(.{
            .kind = kind,
            .name = builder.tokens[name].span(),
            .scope_token_end = held.token_end,
            .scope_token_start = held.token_start,
            .value_token_end = value.token_end,
            .value_token_start = value.token_start,
        });
    }

    fn build_declarations(builder: *Builder) void {
        assert(builder.outline.by_start.count() == builder.outline.scopes.count());

        var index: u32 = 0;

        while (index < builder.count()) {
            const token = builder.tokens[index];

            switch (token.kind) {
                .keyword => |keyword| switch (keyword) {
                    .constant => {
                        index = builder.read_declarators(index, .@"const");

                        continue;
                    },
                    .mutable => {
                        const var_like = std.mem.eql(u8, builder.text(index), "var");

                        index = builder.read_declarators(index, if (var_like) .@"var" else .let);

                        continue;
                    },
                    .function => builder.read_function(index),
                    .@"struct" => builder.read_class(index),
                    .except => builder.read_catch(index),
                    else => {},
                },
                else => {},
            }

            index += 1;
        }

        assert(index == builder.count());

        builder.read_arrow_parameters();
        builder.read_parameters();
    }

    fn read_class(builder: *Builder, keyword: u32) void {
        assert(keyword < builder.count());
        assert(builder.tokens[keyword].is_keyword(.@"struct"));

        const name = builder.significant_next(keyword + 1) orelse return;
        if (builder.tokens[name].kind != .identifier) return;

        builder.push_declaration(.class, name, .{ .token_end = name, .token_start = name });
    }

    fn read_parameters(builder: *Builder) void {
        assert(builder.outline.braces.count() == builder.count());

        for (0..builder.count()) |position| {
            const index: u32 = @intCast(position);
            if (!builder.opens_brace(index)) continue;
            if (!builder.is_function_body(index)) continue;

            const previous = builder.significant_previous(index) orelse continue;
            if (!builder.tokens[previous].is_punctuation(.paren_close)) continue;

            const open = builder.pairs.partner_of(previous) orelse continue;

            assert(open < previous);

            builder.read_pattern(open + 1, previous, .parameter);
        }
    }

    fn read_arrow_parameters(builder: *Builder) void {
        assert(builder.outline.braces.count() == builder.count());

        for (0..builder.count()) |position| {
            const index: u32 = @intCast(position);
            if (!std.mem.eql(u8, builder.text(index), "=>")) continue;

            const previous = builder.significant_previous(index) orelse continue;

            if (builder.tokens[previous].kind == .identifier) {
                builder.push_declaration(.parameter, previous, .{
                    .token_end = previous,
                    .token_start = previous,
                });

                continue;
            }

            if (!builder.tokens[previous].is_punctuation(.paren_close)) continue;

            const open = builder.pairs.partner_of(previous) orelse continue;

            assert(open < previous);

            builder.read_pattern(open + 1, previous, .parameter);
        }
    }

    fn read_catch(builder: *Builder, index: u32) void {
        assert(index < builder.count());

        const open = builder.significant_next(index + 1) orelse return;
        if (!builder.tokens[open].is_punctuation(.paren_open)) return;

        const close = builder.pairs.partner_of(open) orelse return;

        assert(close > open);

        builder.read_pattern(open + 1, close, .catch_parameter);
    }

    fn read_declarators(builder: *Builder, keyword: u32, kind: DeclarationKind) u32 {
        assert(keyword < builder.count());

        const depth = builder.pairs.depth_of(keyword);
        const end = builder.expression_run(keyword + 1, depth);
        const resume_at = @max(end, keyword + 1);
        var start = builder.significant_next(keyword + 1) orelse return resume_at;
        var index = start;

        while (index <= end) : (index += 1) {
            const splits = index == end or builder.splits_at(index, depth);
            if (!splits) continue;

            builder.read_declarator(start, index, kind);

            start = index + 1;
        }

        assert(resume_at > keyword);

        return resume_at;
    }

    fn splits_at(builder: *const Builder, index: u32, depth: u32) bool {
        assert(index < builder.count());
        assert(depth <= index);

        if (!builder.tokens[index].is_punctuation(.comma)) return false;
        return builder.pairs.depth_of(index) == depth;
    }

    fn read_declarator(builder: *Builder, start: u32, end: u32, kind: DeclarationKind) void {
        assert(start <= end);
        assert(end <= builder.count());

        const first = builder.significant_next(start) orelse return;
        if (first >= end) return;

        const depth = builder.pairs.depth_of(first);
        var assign = first;

        while (assign < end) : (assign += 1) {
            if (!builder.tokens[assign].is_punctuation(.assign)) continue;
            if (builder.pairs.depth_of(assign) == depth) break;
        }

        const value_start = if (assign < end) assign + 1 else end;
        const value: Value = .{ .token_end = end, .token_start = value_start };

        if (builder.tokens[first].kind == .identifier) {
            builder.push_declaration(kind, first, value);

            return;
        }

        builder.read_pattern(first, @min(assign, end), kind);
    }

    fn read_pattern(builder: *Builder, start: u32, end: u32, kind: DeclarationKind) void {
        assert(start <= end);
        assert(end <= builder.count());

        const bound = @min(end, start +| pattern_nodes_max);
        var index = start;

        while (index < bound) {
            if (builder.tokens[index].kind != .identifier) {
                index += 1;

                continue;
            }

            if (builder.significant_next(index + 1)) |next| {
                if (next < bound) {
                    if (builder.tokens[next].is_punctuation(.colon)) {
                        index += 1;

                        continue;
                    }
                }
            }

            builder.push_declaration(kind, index, .{ .token_end = index, .token_start = index });

            index += 1;

            while (index < bound) : (index += 1) {
                const token = builder.tokens[index];
                if (token.is_punctuation(.comma)) break;
                if (Brackets.classify(builder.source, token) != null) break;
            }
        }
    }

    fn read_function(builder: *Builder, keyword: u32) void {
        assert(keyword < builder.count());
        assert(builder.tokens[keyword].is_keyword(.function));

        const name = builder.significant_next(keyword + 1) orelse return;
        if (builder.tokens[name].is_punctuation(.paren_open)) return;
        if (builder.tokens[name].kind != .identifier) return;

        builder.push_declaration(.function, name, .{ .token_end = name, .token_start = name });
    }

    fn build_objects(builder: *Builder) void {
        assert(builder.outline.braces.count() == builder.count());

        for (0..builder.count()) |position| {
            const index: u32 = @intCast(position);
            if (builder.outline.braces.get(index) != .object) continue;

            const close = builder.pairs.partner_of(index) orelse continue;
            const object = builder.outline.objects.count();
            const member_first = builder.outline.members.count();
            const member_count = builder.read_members(object, index, close);

            assert(close > index);
            assert(member_first + member_count == builder.outline.members.count());

            if (builder.outline.objects.full()) continue;

            builder.outline.objects.push(.{
                .brace_close = close,
                .brace_open = index,
                .member_count = member_count,
                .member_first = member_first,
            });
        }
    }

    fn read_members(builder: *Builder, object: u32, open: u32, close: u32) u32 {
        assert(open < close);
        assert(close < builder.count());
        assert(object < std.math.maxInt(u32));

        const members = &builder.outline.members;
        const member_first = members.count();
        const depth = builder.pairs.depth_of(open) + 1;
        var member_count: u32 = 0;
        var start = open + 1;
        var index = open + 1;

        while (index <= close) : (index += 1) {
            const splits = index == close or builder.splits_at(index, depth);
            if (!splits) continue;

            if (builder.significant_next(start)) |first| {
                if (first < index) {
                    const member = builder.read_member(object, start, index);

                    if (!members.full()) {
                        members.push(member);
                        member_count += 1;
                    }
                }
            }

            start = index + 1;
        }

        assert(member_first + member_count == members.count());

        return member_count;
    }

    fn read_member(builder: *const Builder, object: u32, start: u32, end: u32) Member {
        assert(start < end);
        assert(end <= builder.count());
        assert(object < std.math.maxInt(u32));

        var first = builder.significant_next(start);
        var is_async = false;
        const is_spread = builder.text_is(first, "...");

        if (builder.text_is(first, "async")) {
            if (builder.significant_next(first.? + 1)) |after| {
                if (after < end) {
                    is_async = true;
                    first = after;
                }
            }
        }

        const colon = builder.member_colon(first, end);
        const is_method = colon == null and builder.paren_follows(first, end);
        const value = builder.member_value(first, colon, end);
        const head = builder.significant_next(start);
        const tail = builder.significant_last(start, end);

        assert(value.token_start <= value.token_end);

        return .{
            .has_await = builder.has_await(value.token_start, value.token_end),
            .is_async = is_async,
            .is_method = is_method,
            .is_shorthand = colon == null and !is_method and !is_spread,
            .is_spread = is_spread,
            .name = if (is_spread) .empty else builder.member_name(first, end),
            .object = object,
            .token_end = if (tail) |held| held + 1 else end,
            .token_start = head orelse start,
            .value_token_end = value.token_end,
            .value_token_start = value.token_start,
        };
    }

    fn member_name(builder: *const Builder, first: ?u32, end: u32) Span {
        assert(end <= builder.count());

        if (first) |held| assert(held < builder.count());

        const index = first orelse return .empty;
        if (index >= end) return .empty;
        if (builder.is_name(index)) return builder.tokens[index].span();
        if (builder.tokens[index].kind == .string) return builder.tokens[index].span();
        return .empty;
    }

    fn member_value(builder: *const Builder, first: ?u32, colon: ?u32, end: u32) Value {
        assert(end <= builder.count());
        if (first) |held| assert(held < builder.count());
        if (colon) |held| assert(held < end);

        if (colon) |held| {
            return .{ .token_end = end, .token_start = held + 1 };
        }

        const start = if (first) |held| @min(held, end) else end;
        return .{ .token_end = end, .token_start = start };
    }

    fn paren_follows(builder: *const Builder, first: ?u32, end: u32) bool {
        assert(end <= builder.count());

        if (first) |held| assert(held < builder.count());

        const index = first orelse return false;
        const after = builder.significant_next(index + 1) orelse return false;
        if (after >= end) return false;
        return builder.tokens[after].is_punctuation(.paren_open);
    }

    fn member_colon(builder: *const Builder, first: ?u32, end: u32) ?u32 {
        assert(end <= builder.count());
        if (first) |held| assert(held < builder.count());

        const index = first orelse return null;
        const next = builder.significant_next(index + 1) orelse return null;
        if (next >= end) return null;
        if (!builder.tokens[next].is_punctuation(.colon)) return null;

        assert(next > index);

        return next;
    }

    fn has_await(builder: *const Builder, start: u32, end: u32) bool {
        assert(start <= end);
        assert(end <= builder.count());

        var index = start;

        while (index < end) : (index += 1) {
            if (!std.mem.eql(u8, builder.text(index), "await")) continue;
            if (builder.function_depth(index, start, end) < 2) return true;
        }

        return false;
    }

    fn function_depth(builder: *const Builder, token: u32, start: u32, end: u32) u32 {
        assert(start <= token);
        assert(token < end);

        var depth: u32 = 0;

        for (builder.outline.scopes.const_slice()) |scope| {
            if (scope.kind != .function) continue;
            if (scope.token_start > token) continue;
            if (token >= scope.token_end) continue;
            if (scope.token_start < start) continue;
            if (scope.token_end > end) continue;

            depth += 1;
        }

        assert(depth <= builder.outline.scopes.count());

        return depth;
    }

    fn build_calls(builder: *Builder) void {
        assert(builder.outline.by_start.count() == builder.outline.scopes.count());

        var index: u32 = 0;

        while (index < builder.count()) {
            const callee = builder.callee_at(index) orelse {
                index += 1;

                continue;
            };

            const open = callee.chain + 1;

            const close = builder.call_close(open) orelse {
                index = callee.chain + 1;

                continue;
            };

            builder.push_call(callee, open, close);

            assert(open > index);

            index = open + 1;
        }
    }

    fn callee_at(builder: *const Builder, index: u32) ?Callee {
        assert(index < builder.count());

        if (!builder.is_name(index)) return null;
        if (builder.is_dotted_tail(index)) return null;

        const is_new = std.mem.eql(u8, builder.text(index), "new");
        var head = index;
        if (is_new) head = builder.significant_next(index + 1) orelse return null;
        if (!builder.is_name(head)) return null;

        const chain = builder.chain_end(head);

        assert(chain >= head);

        return .{ .chain = chain, .head = head, .is_new = is_new, .keyword = index };
    }

    fn call_close(builder: *const Builder, open: u32) ?u32 {
        assert(open > 0);

        if (open >= builder.count()) return null;
        if (!builder.tokens[open].is_punctuation(.paren_open)) return null;

        const close = builder.pairs.partner_of(open) orelse return null;

        assert(close > open);

        return close;
    }

    fn push_call(builder: *Builder, callee: Callee, open: u32, close: u32) void {
        assert(callee.chain < open);
        assert(open < close);

        const segments = &builder.outline.segments;
        const segment_first = segments.count();
        var segment_count: u32 = 0;

        if (callee.is_new) {
            if (!segments.full()) {
                segments.push(builder.tokens[callee.keyword].span());
                segment_count += 1;
            }
        }

        var segment = callee.head;

        while (segment <= callee.chain) : (segment += 2) {
            if (!builder.is_name(segment)) continue;
            if (segments.full()) continue;

            segments.push(builder.tokens[segment].span());
            segment_count += 1;
        }

        const scope = builder.scope_of(open, false);

        assert(segment_first + segment_count == segments.count());

        if (builder.outline.calls.full()) return;

        builder.outline.calls.push(.{
            .callee_segment_count = segment_count,
            .callee_segment_first = segment_first,
            .paren_close = close,
            .paren_open = open,
            .scope = scope,
        });
    }

    fn build_statements(builder: *Builder) void {
        assert(builder.outline.statements.empty());

        var levels: Levels = .{ .count = 0, .depths = @splat(0), .starts = @splat(0) };

        for (0..builder.count()) |position| {
            const index: u32 = @intCast(position);
            const token = builder.tokens[index];

            if (token.kind == .block_start) {
                builder.statement_open(&levels, index);

                continue;
            }

            if (token.kind == .block_end) {
                builder.statement_close(&levels, index);

                continue;
            }

            if (builder.pairs.depth_of(index) != levels.depths[levels.count]) continue;

            const terminates = token.is_punctuation(.semicolon);

            if (!terminates) {
                if (!builder.ends_line(index)) continue;
            }

            const end = if (terminates) index else index + 1;

            builder.push_statement(levels.starts[levels.count], end);
            levels.starts[levels.count] = index + 1;
        }

        while (levels.count > 0) : (levels.count -= 1) {
            builder.push_statement(levels.starts[levels.count], builder.count());
        }

        assert(levels.count == 0);

        builder.push_statement(levels.starts[0], builder.count());
    }

    fn statement_open(builder: *Builder, levels: *Levels, index: u32) void {
        assert(index < builder.count());
        assert(levels.count < scope_stack_max);

        const depth = builder.pairs.depth_of(index);
        const level = levels.count;

        if (depth == levels.depths[level]) {
            if (builder.outline.braces.get(index) == .block) {
                builder.push_statement(levels.starts[level], index);
                levels.starts[level] = index + 1;
            }
        }

        if (level + 1 >= scope_stack_max) return;

        levels.count = level + 1;

        levels.depths[level + 1] = depth + 1;
        levels.starts[level + 1] = index + 1;
    }

    fn statement_close(builder: *Builder, levels: *Levels, index: u32) void {
        assert(index < builder.count());
        assert(levels.count < scope_stack_max);

        const depth = builder.pairs.depth_of(index);

        if (levels.count > 0) {
            if (levels.depths[levels.count] == depth + 1) {
                builder.push_statement(levels.starts[levels.count], index);
                levels.count -= 1;
            }
        }

        const level = levels.count;
        if (depth != levels.depths[level]) return;

        const reopens = if (builder.pairs.partner_of(index)) |open|
            levels.starts[level] == open + 1
        else
            false;

        if (!reopens) builder.push_statement(levels.starts[level], index);

        levels.starts[level] = index + 1;
    }

    fn push_statement(builder: *Builder, start: u32, end: u32) void {
        assert(start <= builder.count());
        assert(end <= builder.count());

        const first = builder.significant_next(start) orelse return;
        if (first >= end) return;

        const scope = builder.scope_of(first, false);

        if (scope) |index| assert(index < builder.outline.scopes.count());

        if (builder.outline.statements.full()) return;

        builder.outline.statements.push(.{
            .scope = scope,
            .token_end = end,
            .token_start = first,
        });
    }

    fn build_assigned(builder: *Builder) void {
        assert(builder.outline.assigned.empty());

        for (0..builder.count()) |position| {
            const index: u32 = @intCast(position);

            const writes = builder.tokens[index].is_punctuation(.assign) or
                builder.is_compound_assign(index) or builder.is_update(index);

            if (!writes) continue;

            const target = builder.significant_previous(index) orelse continue;
            if (builder.tokens[target].kind != .identifier) continue;

            if (builder.significant_previous(target)) |before| {
                if (builder.tokens[before].is_punctuation(.dot)) continue;
            }

            if (builder.outline.assigned.full()) continue;

            builder.outline.assigned.push(.{ .name = builder.tokens[target].span() });
        }

        assert(builder.outline.assigned.count() <= builder.count());
    }

    fn is_compound_assign(builder: *const Builder, index: u32) bool {
        assert(index < builder.count());

        if (!builder.tokens[index].is_punctuation(.other)) return false;

        const text_held = builder.text(index);
        if (text_held.len < 2) return false;
        if (!std.mem.endsWith(u8, text_held, "=")) return false;
        return !contains(&.{ "==", "=>", "===" }, text_held);
    }

    fn is_update(builder: *const Builder, index: u32) bool {
        assert(index < builder.count());

        if (!builder.tokens[index].is_punctuation(.other)) return false;
        return contains(&.{ "++", "--" }, builder.text(index));
    }

    fn breaks_line(builder: *const Builder, index: u32) bool {
        assert(index < builder.count());

        if (index + 1 >= builder.count()) return true;

        const start = builder.tokens[index].end();
        const end = builder.tokens[index + 1].offset;

        assert(start <= end);

        return std.mem.findScalar(u8, builder.source[start..end], '\n') != null;
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

    fn opens_brace(builder: *const Builder, index: u32) bool {
        assert(index < builder.count());

        const classified = Brackets.classify(builder.source, builder.tokens[index]) orelse {
            return false;
        };

        if (!classified.opens) return false;
        return classified.bracket == .brace;
    }

    fn significant_last(builder: *const Builder, from: u32, end: u32) ?u32 {
        assert(from <= end);

        var index = @min(end, builder.count());

        while (index > from) {
            index -= 1;

            if (builder.is_significant(index)) return index;
        }

        assert(index <= from);

        return null;
    }

    fn significant_next(builder: *const Builder, from: u32) ?u32 {
        assert(from < std.math.maxInt(u32));

        return stream.significant_next(builder.tokens, from, builder.count());
    }

    fn significant_previous(builder: *const Builder, before: u32) ?u32 {
        assert(before < std.math.maxInt(u32));

        return stream.significant_previous(builder.tokens, before);
    }

    fn text(builder: *const Builder, index: u32) []const u8 {
        assert(builder.tokens.len <= std.math.maxInt(u32));
        assert(index < builder.tokens.len);

        if (index >= builder.count()) return "";
        return builder.tokens[index].text(builder.source);
    }

    fn text_is(builder: *const Builder, index: ?u32, word: []const u8) bool {
        assert(word.len > 0);

        if (index == null) return false;

        const held = index.?;
        return std.mem.eql(u8, builder.text(held), word);
    }

    fn count(builder: *const Builder) u32 {
        assert(builder.tokens.len <= std.math.maxInt(u32));

        return @intCast(builder.tokens.len);
    }
};

const Callee = struct {
    chain: u32,
    head: u32,
    is_new: bool,
    keyword: u32,
};

const Levels = struct {
    count: u32,
    depths: [scope_stack_max]u32,
    starts: [scope_stack_max]u32,
};

const Stack = struct {
    depth: u32,
    indexes: [scope_stack_max]u32,

    fn push(stack: *Stack, index: u32) void {
        assert(stack.depth >= 1);
        assert(stack.depth <= scope_stack_max);
        assert(index < std.math.maxInt(u32));

        if (stack.depth == scope_stack_max) return;

        stack.indexes[stack.depth] = index;
        stack.depth += 1;
    }
};

const Starts = struct {
    scopes: []const Scope,
    token: u32,

    fn at_or_before(starts: Starts, index: u32) bool {
        assert(index < starts.scopes.len);

        return starts.scopes[index].token_start <= starts.token;
    }
};

const Value = struct {
    token_end: u32,
    token_start: u32,
};

pub const pattern_nodes_max: u32 = 1_024;
const chain_links = [_][]const u8{ "catch", "finally", "then" };
const continuation_words = [_][]const u8{ "+", "-", "?", "=>", "%", "else", "catch", "finally" };
const header_words = [_][]const u8{ "catch", "for", "if", "switch", "while", "with" };
const scope_stack_max: u32 = 1 << 8;

comptime {
    assert(pattern_nodes_max > 0);
    assert(scope_stack_max > 1);
}

pub fn build(
    source: []const u8,
    tokens: []const Token,
    pairs: *const Brackets,
    outline: *Outline,
) void {
    assert(source.len <= std.math.maxInt(u32));
    assert(pairs.count() == tokens.len);

    outline.clear();

    var builder: Builder = .{
        .outline = outline,
        .pairs = pairs,
        .source = source,
        .tokens = tokens,
    };

    builder.build_braces();
    builder.build_scopes();
    builder.index_scopes();
    builder.build_declarations();
    builder.build_objects();
    builder.build_calls();
    builder.build_statements();
    builder.build_assigned();

    assert(outline.braces.count() == tokens.len);
    assert(outline.by_start.count() == outline.scopes.count());
}

pub fn chain_fate(
    call: *const Call,
    source: []const u8,
    tokens: []const Token,
    statements: []const Statement,
) Fate {
    assert(call.paren_close <= tokens.len);
    assert(call.paren_open <= call.paren_close);
    assert(source.len <= std.math.maxInt(u32));
    assert(statements.len <= std.math.maxInt(u32));

    const statement = innermost_statement(call, statements) orelse {
        return .{ .chained = false, .floating = false };
    };

    var index = call.paren_close + 1;
    var chained = false;

    while (index < statement.token_end) {
        const token = tokens[index];

        switch (token.kind) {
            .comment, .newline => {
                index += 1;

                continue;
            },
            else => {},
        }

        if (!token.is_punctuation(.dot)) break;

        const name = index + 1;
        if (name >= statement.token_end) break;

        if (contains(&chain_links, tokens[name].text(source))) chained = true;

        index = name + 1;
    }

    const leads = !leading_tokens(statement, call, tokens, source);
    return .{ .chained = chained, .floating = leads and !chained };
}

fn innermost_statement(call: *const Call, statements: []const Statement) ?Statement {
    assert(call.paren_open <= call.paren_close);
    assert(statements.len <= std.math.maxInt(u32));

    var found: ?Statement = null;

    for (statements) |statement| {
        if (statement.token_start > call.paren_open) continue;
        if (call.paren_open >= statement.token_end) continue;

        if (found) |held| {
            const width = statement.token_end - statement.token_start;
            if (width >= held.token_end - held.token_start) continue;
        }

        found = statement;
    }

    if (found) |held| assert(held.token_start <= call.paren_open);

    return found;
}

fn leading_tokens(
    statement: Statement,
    call: *const Call,
    tokens: []const Token,
    source: []const u8,
) bool {
    assert(statement.token_start <= call.paren_open);
    assert(call.paren_open < tokens.len);
    assert(source.len <= std.math.maxInt(u32));

    var index = statement.token_start;

    while (index < call.paren_open) : (index += 1) {
        const token = tokens[index];

        switch (token.kind) {
            .comment, .newline, .identifier => continue,
            .punctuation => |punctuation| if (punctuation == .dot) continue,
            else => {},
        }

        if (contains(&.{ "new", "super", "this" }, token.text(source))) continue;
        return true;
    }

    return false;
}

fn contains(words: []const []const u8, text: []const u8) bool {
    assert(words.len > 0);
    assert(text.len <= std.math.maxInt(u32));

    for (words) |word| assert(word.len > 0);

    for (words) |word| {
        if (std.mem.eql(u8, word, text)) return true;
    }

    return false;
}

fn scope_precedes(scopes: []const Scope, left: u32, right: u32) bool {
    assert(left < scopes.len);
    assert(right < scopes.len);

    const first = scopes[left];
    const second = scopes[right];
    if (first.token_start != second.token_start) return first.token_start < second.token_start;
    return first.token_end > second.token_end;
}
