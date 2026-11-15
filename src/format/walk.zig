const std = @import("std");
const assert = std.debug.assert;
const ArrayType = @import("../stdx/bounded/array.zig").ArrayType;
const Span = @import("../stdx/bounded/span.zig");
const Token = @import("../syntax/token.zig");
const line_break_width = @import("../text/scan.zig").line_break_width;
const role_spaced = @import("brace.zig").role_spaced;
pub const MarkRange = struct { first: u32, last: u32 };
pub const LineRange = struct { first: u32, last: u32 };

pub const Brackets = struct {
    angles: ArrayType(u32),
    blocks: ArrayType(u32),
    closes: ArrayType(u32),
    held: ArrayType(u32),
    identifiers: ArrayType(u32),
    nested: ArrayType(Angle),
    opens: ArrayType(u32),
    skipped: ArrayType(u32),
    substitutions: ArrayType(u32),

    pub fn init(gpa: std.mem.Allocator, element_count_max: u32) std.mem.Allocator.Error!Brackets {
        assert(element_count_max > 0);
        assert(element_count_max < std.math.maxInt(u32));

        var angles: ArrayType(u32) = try .init(gpa, element_count_max);
        errdefer angles.deinit(gpa);

        var blocks: ArrayType(u32) = try .init(gpa, element_count_max);
        errdefer blocks.deinit(gpa);

        var closes: ArrayType(u32) = try .init(gpa, element_count_max);
        errdefer closes.deinit(gpa);

        var held: ArrayType(u32) = try .init(gpa, element_count_max);
        errdefer held.deinit(gpa);

        var identifiers: ArrayType(u32) = try .init(gpa, element_count_max);
        errdefer identifiers.deinit(gpa);

        var nested: ArrayType(Angle) = try .init(gpa, element_count_max);
        errdefer nested.deinit(gpa);

        var opens: ArrayType(u32) = try .init(gpa, element_count_max);
        errdefer opens.deinit(gpa);

        var skipped: ArrayType(u32) = try .init(gpa, element_count_max + 1);
        errdefer skipped.deinit(gpa);

        const substitutions: ArrayType(u32) = try .init(gpa, element_count_max + 1);

        return .{
            .angles = angles,
            .blocks = blocks,
            .closes = closes,
            .held = held,
            .identifiers = identifiers,
            .nested = nested,
            .opens = opens,
            .skipped = skipped,
            .substitutions = substitutions,
        };
    }

    pub fn deinit(brackets: *Brackets, gpa: std.mem.Allocator) void {
        assert(brackets.skipped.capacity() == brackets.opens.capacity() + 1);
        assert(brackets.substitutions.capacity() == brackets.skipped.capacity());

        brackets.angles.deinit(gpa);
        brackets.blocks.deinit(gpa);
        brackets.closes.deinit(gpa);
        brackets.held.deinit(gpa);
        brackets.identifiers.deinit(gpa);
        brackets.nested.deinit(gpa);
        brackets.opens.deinit(gpa);
        brackets.skipped.deinit(gpa);
        brackets.substitutions.deinit(gpa);
        brackets.* = undefined;
    }

    pub fn angles_at(brackets: *const Brackets, position: u32) u32 {
        assert(brackets.angles.count() <= brackets.angles.capacity());
        assert(brackets.angles.capacity() + 1 == brackets.skipped.capacity());
        assert(position < none);

        if (position < brackets.angles.count()) return brackets.angles.get(position);
        return 0;
    }

    pub fn block_after(brackets: *const Brackets, position: u32) ?u32 {
        assert(position < none);

        const block = linked_at(&brackets.blocks, position);

        if (block) |held| assert(held >= position);
        if (block) |held| assert(held < brackets.blocks.count());

        return block;
    }

    pub fn build(
        brackets: *Brackets,
        source: []const u8,
        tokens: []const Token,
        roles: []const u16,
        angles: bool,
    ) error{Overflow}!void {
        assert(source.len <= std.math.maxInt(u32));
        assert(tokens.len < std.math.maxInt(u32));
        assert(roles.len <= std.math.maxInt(u32));

        brackets.closes.clear();
        brackets.opens.clear();

        for (tokens) |_| {
            try brackets.closes.pushed(none);
            try brackets.opens.pushed(none);
        }

        const opens = [_]Token.Kind{
            .block_start,
            .{ .punctuation = .bracket_open },
            .{ .punctuation = .paren_open },
        };

        for (opens) |open| {
            try brackets.matched(source, tokens, open);
        }

        try brackets.blocked(source, tokens);
        try brackets.angled(source, tokens, roles, angles);
        try brackets.counted(source, tokens);
        try brackets.identified(tokens);

        assert(brackets.closes.count() == tokens.len);
        assert(brackets.identifiers.count() == tokens.len);
    }

    pub fn close_of(brackets: *const Brackets, position: u32) ?u32 {
        assert(position < none);

        const close = linked_at(&brackets.closes, position);

        if (close) |held| assert(held > position);
        if (close) |held| assert(brackets.opens.get(held) == position);

        return close;
    }

    pub fn identifier_open_of(brackets: *const Brackets, position: u32) ?u32 {
        assert(brackets.identifiers.count() == brackets.opens.count());
        assert(position < none);

        const open = linked_at(&brackets.identifiers, position);

        if (open) |held| assert(held < position);

        return open;
    }

    pub fn open_of(brackets: *const Brackets, position: u32) ?u32 {
        assert(position < none);

        const open = linked_at(&brackets.opens, position);

        if (open) |held| assert(held < position);
        if (open) |held| assert(brackets.closes.get(held) == position);

        return open;
    }

    pub fn stepped(brackets: *const Brackets, from: u32, to: u32) u32 {
        assert(from <= to);
        assert(to < brackets.skipped.count());

        const skipped = brackets.skipped.const_slice();

        assert(skipped[to] - skipped[from] <= to - from);

        return (to - from) - (skipped[to] - skipped[from]);
    }

    pub fn substituted(brackets: *const Brackets, from: u32, to: u32) bool {
        assert(from <= to);
        assert(to < brackets.substitutions.count());

        const substitutions = brackets.substitutions.const_slice();
        return substitutions[to] > substitutions[from];
    }

    fn matched(
        brackets: *Brackets,
        source: []const u8,
        tokens: []const Token,
        open: Token.Kind,
    ) error{Overflow}!void {
        assert(is_open(open));
        assert(brackets.closes.count() == tokens.len);
        assert(source.len <= std.math.maxInt(u32));

        const close = closed_by(open);
        const closes = brackets.closes.slice();
        const opens = brackets.opens.slice();

        brackets.held.clear();

        for (tokens, 0..) |token, index| {
            const position: u32 = @intCast(index);
            const substitutes = open == .block_start and substituting(source, token);
            const opening = token.kind.eql(open) or substitutes;

            if (opening) {
                try brackets.held.pushed(position);

                continue;
            }

            if (!token.kind.eql(close)) continue;

            if (brackets.held.pop()) |held| {
                closes[held] = position;
                opens[position] = held;
            }
        }
    }

    fn blocked(
        brackets: *Brackets,
        source: []const u8,
        tokens: []const Token,
    ) error{Overflow}!void {
        assert(tokens.len < std.math.maxInt(u32));
        assert(source.len <= std.math.maxInt(u32));

        brackets.blocks.clear();

        for (tokens) |_| {
            try brackets.blocks.pushed(none);
        }

        const blocks = brackets.blocks.slice();
        var next: u32 = none;

        for (0..tokens.len) |step| {
            const position: u32 = @intCast(tokens.len - 1 - step);
            const token = tokens[position];
            const bounds = token.kind == .block_start or token.kind == .block_end;
            const blocks_here = bounds or substituting(source, token);

            if (blocks_here) next = position;

            blocks[position] = next;
        }

        assert(blocks.len == tokens.len);
    }

    fn angled(
        brackets: *Brackets,
        source: []const u8,
        tokens: []const Token,
        roles: []const u16,
        angles: bool,
    ) error{Overflow}!void {
        assert(tokens.len < std.math.maxInt(u32));
        assert(source.len <= std.math.maxInt(u32));
        assert(roles.len <= std.math.maxInt(u32));

        brackets.angles.clear();
        brackets.nested.clear();

        var held: Angle = .empty;

        for (tokens, 0..) |token, index| {
            const resets = angle_blocks and token.is_punctuation(.semicolon);

            if (resets) held = .empty;

            try brackets.angles.pushed(held.depth);

            if (!angles) continue;

            const spaced = index < roles.len and roles[index] & role_spaced != 0;

            try brackets.angled_token(source, token, spaced, &held);
        }

        assert(brackets.angles.count() == tokens.len);
    }

    fn angled_token(
        brackets: *Brackets,
        source: []const u8,
        token: Token,
        spaced: bool,
        held: *Angle,
    ) error{Overflow}!void {
        assert(token.end() <= source.len);

        const block_start = angle_blocks and token.kind == .block_start;
        const opening = is_open(token.kind) or substituting(source, token) or block_start;

        if (opening) {
            try brackets.nested.pushed(held.*);

            held.* = .empty;

            return;
        }

        const block_end = angle_blocks and token.kind == .block_end;
        const closing = is_close(token.kind) or block_end;

        if (closing) {
            held.* = if (brackets.nested.pop()) |outer| outer.joined(held.sealed()) else .empty;

            return;
        }

        const operator = angle_operators and spaced;
        const chunk = angle_chunks and token.kind == .string;

        if (operator) return;
        if (chunk) return;

        angled_text(held, token.text(source));

        assert(held.depth >= held.total);
    }

    fn counted(
        brackets: *Brackets,
        source: []const u8,
        tokens: []const Token,
    ) error{Overflow}!void {
        assert(tokens.len < std.math.maxInt(u32));
        assert(source.len <= std.math.maxInt(u32));

        brackets.skipped.clear();
        brackets.substitutions.clear();

        var skipped: u32 = 0;
        var substitutions: u32 = 0;

        for (tokens) |token| {
            try brackets.skipped.pushed(skipped);
            try brackets.substitutions.pushed(substitutions);

            const skips = token.kind == .newline or token.length == 0;

            skipped += @intFromBool(skips);
            substitutions += @intFromBool(substituting(source, token));
        }

        try brackets.skipped.pushed(skipped);
        try brackets.substitutions.pushed(substitutions);

        assert(skipped <= tokens.len);
        assert(brackets.skipped.count() == tokens.len + 1);
    }

    fn identified(brackets: *Brackets, tokens: []const Token) error{Overflow}!void {
        assert(tokens.len < std.math.maxInt(u32));

        brackets.held.clear();
        brackets.identifiers.clear();

        for (tokens) |_| {
            try brackets.identifiers.pushed(none);
        }

        const identifiers = brackets.identifiers.slice();

        for (tokens, 0..) |token, index| {
            if (token.is_punctuation(.paren_open)) {
                try brackets.held.pushed(@intCast(index));

                continue;
            }

            if (token.kind != .identifier) continue;

            if (brackets.held.pop()) |held| identifiers[index] = held;
        }

        assert(identifiers.len == tokens.len);
    }
};

pub const Breaks = struct {
    buckets: ArrayType(u32),
    held: ArrayType(u32),
    leads: ArrayType(u32),
    plain: ArrayType(u32),

    pub fn init(gpa: std.mem.Allocator, element_count_max: u32) std.mem.Allocator.Error!Breaks {
        assert(element_count_max > 0);
        assert(element_count_max < std.math.maxInt(u32));

        var buckets: ArrayType(u32) = try .init(gpa, element_count_max);
        errdefer buckets.deinit(gpa);

        var held: ArrayType(u32) = try .init(gpa, element_count_max);
        errdefer held.deinit(gpa);

        var leads: ArrayType(u32) = try .init(gpa, element_count_max);
        errdefer leads.deinit(gpa);

        const plain: ArrayType(u32) = try .init(gpa, element_count_max);
        return .{ .buckets = buckets, .held = held, .leads = leads, .plain = plain };
    }

    pub fn deinit(breaks: *Breaks, gpa: std.mem.Allocator) void {
        assert(breaks.held.count() == breaks.leads.count());
        assert(breaks.buckets.capacity() == breaks.plain.capacity());

        breaks.buckets.deinit(gpa);
        breaks.held.deinit(gpa);
        breaks.leads.deinit(gpa);
        breaks.plain.deinit(gpa);
        breaks.* = undefined;
    }

    pub fn build(breaks: *Breaks, source: []const u8, carriage: bool) error{Overflow}!void {
        assert(source.len < std.math.maxInt(u32));

        breaks.held.clear();
        breaks.leads.clear();
        breaks.plain.clear();

        const stop: u32 = @intCast(source.len);
        var offset: u32 = 0;

        while (offset < stop) {
            if (source[offset] == '\\') {
                const escaped = try breaks.build_escaped(source, offset, carriage);

                if (escaped > offset) {
                    offset = escaped;

                    continue;
                }
            }

            const width = line_break_width(source, offset);
            const counts = width > 0 and (carriage or source[offset] == '\n' or width == 2);

            if (counts) {
                try breaks.plain.pushed(offset);

                offset += width;

                continue;
            }

            offset += 1;
        }

        assert(breaks.held.count() == breaks.leads.count());

        try breaks.bucketed(source);
    }

    pub fn counted(breaks: *const Breaks, from: u32, to: u32) u32 {
        assert(from <= to);
        assert(breaks.held.count() == breaks.leads.count());

        const plain = breaks.plain.const_slice();
        const start = breaks.plain_from(from);
        var stop = start;

        while (stop < plain.len) : (stop += 1) {
            if (stop - start == near_break_max) break;
            if (plain[stop] >= to) break;
        }

        if (stop - start == near_break_max) stop = @max(breaks.plain_from(to), stop);

        const held = breaks.held.const_slice();
        const first = partition_point(held, from);
        const owed = first < held.len and held[first] < to and breaks.leads.get(first) < from;
        const found = stop - start;

        assert(found <= plain.len);

        return found + @intFromBool(owed);
    }

    fn build_escaped(
        breaks: *Breaks,
        source: []const u8,
        offset: u32,
        carriage: bool,
    ) error{Overflow}!u32 {
        assert(offset < source.len);
        assert(source[offset] == '\\');

        var cursor = offset + 1;

        while (cursor < source.len) : (cursor += 1) {
            const blank = source[cursor] == ' ' or source[cursor] == '\t';
            if (!blank) break;
        }

        const width = line_break_width(source, cursor);
        if (width == 0) return offset;

        const counts = carriage or source[cursor] == '\n' or width == 2;

        if (counts) {
            try breaks.held.pushed(cursor);
            try breaks.leads.pushed(offset);
        }

        assert(cursor + width > offset);

        return cursor + width;
    }

    fn bucketed(breaks: *Breaks, source: []const u8) error{Overflow}!void {
        assert(source.len < std.math.maxInt(u32));

        breaks.buckets.clear();

        const plain = breaks.plain.const_slice();
        const bucket_count = (@as(u32, @intCast(source.len)) >> bucket_shift) + 1;
        var index: u32 = 0;

        for (0..bucket_count) |bucket| {
            const floor = @as(u32, @intCast(bucket)) << bucket_shift;

            while (index < plain.len) : (index += 1) {
                if (plain[index] >= floor) break;
            }

            try breaks.buckets.pushed(index);
        }

        assert(breaks.buckets.count() == bucket_count);
    }

    fn plain_from(breaks: *const Breaks, offset: u32) u32 {
        assert(breaks.buckets.count() > 0);
        assert(offset < none);

        const plain = breaks.plain.const_slice();
        const bucket = @min(offset >> bucket_shift, breaks.buckets.count() - 1);
        var index = breaks.buckets.get(bucket);

        while (index < plain.len) : (index += 1) {
            if (plain[index] >= offset) break;
        }

        assert(index <= plain.len);

        return index;
    }
};

const Angle = struct {
    depth: u32,
    drop: u32,
    total: i64,

    const empty: Angle = .{ .depth = 0, .drop = 0, .total = 0 };

    fn closed(angle: *Angle, width: u32) void {
        assert(width > 0);

        angle.depth -|= width;
        angle.total -= width;
        angle.drop = @max(angle.drop, below(angle.total));

        assert(angle.depth >= angle.total);
        assert(angle.drop >= -angle.total);
    }

    fn joined(angle: Angle, inner: Angle) Angle {
        assert(angle.drop >= -angle.total);
        assert(inner.drop >= -inner.total);

        const reached = @as(i64, @max(angle.depth, inner.drop)) + inner.total;

        assert(reached >= 0);
        assert(reached <= std.math.maxInt(u32));

        const total = angle.total + inner.total;

        return .{
            .depth = @intCast(reached),
            .drop = @max(angle.drop, below(total)),
            .total = total,
        };
    }

    fn opened(angle: *Angle) void {
        assert(angle.depth >= angle.total);

        angle.depth += 1;
        angle.total += 1;

        assert(angle.depth > 0);
    }

    fn sealed(angle: Angle) Angle {
        assert(angle.depth >= angle.total);
        assert(angle.drop >= -angle.total);

        if (!angle_brackets) return angle;
        if (angle.total <= 0) return angle;
        return .{ .depth = 0, .drop = angle.drop, .total = 0 };
    }

    fn below(total: i64) u32 {
        assert(total < none);

        const result = std.math.cast(u32, -total) orelse 0;

        if (total >= 0) assert(result == 0);

        return result;
    }
};

const angle_blocks = true;
const angle_brackets = true;
const angle_chunks = true;
const angle_operators = true;
const angle_tags = true;

const bracket_closes = [_]Token.Kind{
    .block_end,
    .{ .punctuation = .bracket_close },
    .{ .punctuation = .paren_close },
};

const bracket_opens = [_]Token.Kind{
    .block_start,
    .{ .punctuation = .bracket_open },
    .{ .punctuation = .paren_open },
};

const bucket_shift: u5 = 6;
const khmer_beyyal: u32 = 0x17D8;
const near_break_max: u32 = 8;
const none: u32 = std.math.maxInt(u32);
const simple_words = [_][]const u8{ "!", "&", "*", "-", ".", "?", "[", "]", "as", "mut", "self" };

pub const mark_ranges = [_]MarkRange{
    .{ .first = 0x00AD, .last = 0x00AD },
    .{ .first = 0x0300, .last = 0x036F },
    .{ .first = 0x0483, .last = 0x0489 },
    .{ .first = 0x0591, .last = 0x05BD },
    .{ .first = 0x05BF, .last = 0x05BF },
    .{ .first = 0x05C1, .last = 0x05C2 },
    .{ .first = 0x05C4, .last = 0x05C5 },
    .{ .first = 0x05C7, .last = 0x05C7 },
    .{ .first = 0x0605, .last = 0x0605 },
    .{ .first = 0x0610, .last = 0x061A },
    .{ .first = 0x061C, .last = 0x061C },
    .{ .first = 0x064B, .last = 0x065F },
    .{ .first = 0x0670, .last = 0x0670 },
    .{ .first = 0x06D6, .last = 0x06DC },
    .{ .first = 0x06DF, .last = 0x06E4 },
    .{ .first = 0x06E7, .last = 0x06E8 },
    .{ .first = 0x06EA, .last = 0x06ED },
    .{ .first = 0x070F, .last = 0x070F },
    .{ .first = 0x0711, .last = 0x0711 },
    .{ .first = 0x0730, .last = 0x074A },
    .{ .first = 0x07A6, .last = 0x07B0 },
    .{ .first = 0x07EB, .last = 0x07F3 },
    .{ .first = 0x07FD, .last = 0x07FD },
    .{ .first = 0x0816, .last = 0x0819 },
    .{ .first = 0x081B, .last = 0x0823 },
    .{ .first = 0x0825, .last = 0x0827 },
    .{ .first = 0x0829, .last = 0x082D },
    .{ .first = 0x0859, .last = 0x085B },
    .{ .first = 0x0890, .last = 0x0891 },
    .{ .first = 0x0898, .last = 0x089F },
    .{ .first = 0x08CA, .last = 0x0902 },
    .{ .first = 0x093A, .last = 0x093A },
    .{ .first = 0x093C, .last = 0x093C },
    .{ .first = 0x0941, .last = 0x0948 },
    .{ .first = 0x094D, .last = 0x094D },
    .{ .first = 0x0951, .last = 0x0957 },
    .{ .first = 0x0962, .last = 0x0963 },
    .{ .first = 0x0981, .last = 0x0981 },
    .{ .first = 0x09BC, .last = 0x09BC },
    .{ .first = 0x09BE, .last = 0x09BE },
    .{ .first = 0x09C1, .last = 0x09C4 },
    .{ .first = 0x09CD, .last = 0x09CD },
    .{ .first = 0x09D7, .last = 0x09D7 },
    .{ .first = 0x09E2, .last = 0x09E3 },
    .{ .first = 0x09FE, .last = 0x09FE },
    .{ .first = 0x0A01, .last = 0x0A02 },
    .{ .first = 0x0A3C, .last = 0x0A3C },
    .{ .first = 0x0A41, .last = 0x0A42 },
    .{ .first = 0x0A47, .last = 0x0A48 },
    .{ .first = 0x0A4B, .last = 0x0A4D },
    .{ .first = 0x0A51, .last = 0x0A51 },
    .{ .first = 0x0A70, .last = 0x0A71 },
    .{ .first = 0x0A75, .last = 0x0A75 },
    .{ .first = 0x0A81, .last = 0x0A82 },
    .{ .first = 0x0ABC, .last = 0x0ABC },
    .{ .first = 0x0AC1, .last = 0x0AC5 },
    .{ .first = 0x0AC7, .last = 0x0AC8 },
    .{ .first = 0x0ACD, .last = 0x0ACD },
    .{ .first = 0x0AE2, .last = 0x0AE3 },
    .{ .first = 0x0AFA, .last = 0x0AFF },
    .{ .first = 0x0B01, .last = 0x0B01 },
    .{ .first = 0x0B3C, .last = 0x0B3C },
    .{ .first = 0x0B3E, .last = 0x0B3F },
    .{ .first = 0x0B41, .last = 0x0B44 },
    .{ .first = 0x0B4D, .last = 0x0B4D },
    .{ .first = 0x0B55, .last = 0x0B57 },
    .{ .first = 0x0B62, .last = 0x0B63 },
    .{ .first = 0x0B82, .last = 0x0B82 },
    .{ .first = 0x0BBE, .last = 0x0BBE },
    .{ .first = 0x0BC0, .last = 0x0BC0 },
    .{ .first = 0x0BCD, .last = 0x0BCD },
    .{ .first = 0x0BD7, .last = 0x0BD7 },
    .{ .first = 0x0C00, .last = 0x0C00 },
    .{ .first = 0x0C04, .last = 0x0C04 },
    .{ .first = 0x0C3C, .last = 0x0C3C },
    .{ .first = 0x0C3E, .last = 0x0C40 },
    .{ .first = 0x0C46, .last = 0x0C48 },
    .{ .first = 0x0C4A, .last = 0x0C4D },
    .{ .first = 0x0C55, .last = 0x0C56 },
    .{ .first = 0x0C62, .last = 0x0C63 },
    .{ .first = 0x0C81, .last = 0x0C81 },
    .{ .first = 0x0CBC, .last = 0x0CBC },
    .{ .first = 0x0CBF, .last = 0x0CC0 },
    .{ .first = 0x0CC2, .last = 0x0CC2 },
    .{ .first = 0x0CC6, .last = 0x0CC8 },
    .{ .first = 0x0CCA, .last = 0x0CCD },
    .{ .first = 0x0CD5, .last = 0x0CD6 },
    .{ .first = 0x0CE2, .last = 0x0CE3 },
    .{ .first = 0x0D00, .last = 0x0D01 },
    .{ .first = 0x0D3B, .last = 0x0D3C },
    .{ .first = 0x0D3E, .last = 0x0D3E },
    .{ .first = 0x0D41, .last = 0x0D44 },
    .{ .first = 0x0D4D, .last = 0x0D4E },
    .{ .first = 0x0D57, .last = 0x0D57 },
    .{ .first = 0x0D62, .last = 0x0D63 },
    .{ .first = 0x0D81, .last = 0x0D81 },
    .{ .first = 0x0DCA, .last = 0x0DCA },
    .{ .first = 0x0DCF, .last = 0x0DCF },
    .{ .first = 0x0DD2, .last = 0x0DD4 },
    .{ .first = 0x0DD6, .last = 0x0DD6 },
    .{ .first = 0x0DDF, .last = 0x0DDF },
    .{ .first = 0x0E31, .last = 0x0E31 },
    .{ .first = 0x0E34, .last = 0x0E3A },
    .{ .first = 0x0E47, .last = 0x0E4E },
    .{ .first = 0x0EB1, .last = 0x0EB1 },
    .{ .first = 0x0EB4, .last = 0x0EBC },
    .{ .first = 0x0EC8, .last = 0x0ECE },
    .{ .first = 0x0F18, .last = 0x0F19 },
    .{ .first = 0x0F35, .last = 0x0F35 },
    .{ .first = 0x0F37, .last = 0x0F37 },
    .{ .first = 0x0F39, .last = 0x0F39 },
    .{ .first = 0x0F71, .last = 0x0F7E },
    .{ .first = 0x0F80, .last = 0x0F84 },
    .{ .first = 0x0F86, .last = 0x0F87 },
    .{ .first = 0x0F8D, .last = 0x0F97 },
    .{ .first = 0x0F99, .last = 0x0FBC },
    .{ .first = 0x0FC6, .last = 0x0FC6 },
    .{ .first = 0x102D, .last = 0x1030 },
    .{ .first = 0x1032, .last = 0x1037 },
    .{ .first = 0x1039, .last = 0x103A },
    .{ .first = 0x103D, .last = 0x103E },
    .{ .first = 0x1058, .last = 0x1059 },
    .{ .first = 0x105E, .last = 0x1060 },
    .{ .first = 0x1071, .last = 0x1074 },
    .{ .first = 0x1082, .last = 0x1082 },
    .{ .first = 0x1085, .last = 0x1086 },
    .{ .first = 0x108D, .last = 0x108D },
    .{ .first = 0x109D, .last = 0x109D },
    .{ .first = 0x1160, .last = 0x11FF },
    .{ .first = 0x135D, .last = 0x135F },
    .{ .first = 0x1712, .last = 0x1714 },
    .{ .first = 0x1732, .last = 0x1733 },
    .{ .first = 0x1752, .last = 0x1753 },
    .{ .first = 0x1772, .last = 0x1773 },
    .{ .first = 0x17B4, .last = 0x17B5 },
    .{ .first = 0x17B7, .last = 0x17BD },
    .{ .first = 0x17C6, .last = 0x17C6 },
    .{ .first = 0x17C9, .last = 0x17D3 },
    .{ .first = 0x17DD, .last = 0x17DD },
    .{ .first = 0x180B, .last = 0x180F },
    .{ .first = 0x1885, .last = 0x1886 },
    .{ .first = 0x18A9, .last = 0x18A9 },
    .{ .first = 0x1920, .last = 0x1922 },
    .{ .first = 0x1927, .last = 0x1928 },
    .{ .first = 0x1932, .last = 0x1932 },
    .{ .first = 0x1939, .last = 0x193B },
    .{ .first = 0x1A17, .last = 0x1A18 },
    .{ .first = 0x1A1B, .last = 0x1A1B },
    .{ .first = 0x1A56, .last = 0x1A56 },
    .{ .first = 0x1A58, .last = 0x1A5E },
    .{ .first = 0x1A60, .last = 0x1A60 },
    .{ .first = 0x1A62, .last = 0x1A62 },
    .{ .first = 0x1A65, .last = 0x1A6C },
    .{ .first = 0x1A73, .last = 0x1A7C },
    .{ .first = 0x1A7F, .last = 0x1A7F },
    .{ .first = 0x1AB0, .last = 0x1ACE },
    .{ .first = 0x1B00, .last = 0x1B03 },
    .{ .first = 0x1B34, .last = 0x1B3D },
    .{ .first = 0x1B42, .last = 0x1B43 },
    .{ .first = 0x1B6B, .last = 0x1B73 },
    .{ .first = 0x1B80, .last = 0x1B81 },
    .{ .first = 0x1BA2, .last = 0x1BA5 },
    .{ .first = 0x1BA8, .last = 0x1BA9 },
    .{ .first = 0x1BAB, .last = 0x1BAD },
    .{ .first = 0x1BE6, .last = 0x1BE6 },
    .{ .first = 0x1BE8, .last = 0x1BE9 },
    .{ .first = 0x1BED, .last = 0x1BED },
    .{ .first = 0x1BEF, .last = 0x1BF1 },
    .{ .first = 0x1C2C, .last = 0x1C33 },
    .{ .first = 0x1C36, .last = 0x1C37 },
    .{ .first = 0x1CD0, .last = 0x1CD2 },
    .{ .first = 0x1CD4, .last = 0x1CE0 },
    .{ .first = 0x1CE2, .last = 0x1CE8 },
    .{ .first = 0x1CED, .last = 0x1CED },
    .{ .first = 0x1CF4, .last = 0x1CF4 },
    .{ .first = 0x1CF8, .last = 0x1CF9 },
    .{ .first = 0x1DC0, .last = 0x1DFF },
    .{ .first = 0x200B, .last = 0x200F },
    .{ .first = 0x202A, .last = 0x202E },
    .{ .first = 0x2060, .last = 0x206F },
    .{ .first = 0x20D0, .last = 0x20F0 },
    .{ .first = 0x2CEF, .last = 0x2CF1 },
    .{ .first = 0x2DE0, .last = 0x2DFF },
    .{ .first = 0x302A, .last = 0x302F },
    .{ .first = 0x3099, .last = 0x309A },
    .{ .first = 0x3164, .last = 0x3164 },
    .{ .first = 0xA66F, .last = 0xA672 },
    .{ .first = 0xA674, .last = 0xA67D },
    .{ .first = 0xA69E, .last = 0xA69F },
    .{ .first = 0xA6F0, .last = 0xA6F1 },
    .{ .first = 0xA802, .last = 0xA802 },
    .{ .first = 0xA806, .last = 0xA806 },
    .{ .first = 0xA80B, .last = 0xA80B },
    .{ .first = 0xA825, .last = 0xA826 },
    .{ .first = 0xA82C, .last = 0xA82C },
    .{ .first = 0xA8C4, .last = 0xA8C5 },
    .{ .first = 0xA8E0, .last = 0xA8F1 },
    .{ .first = 0xA8FA, .last = 0xA8FA },
    .{ .first = 0xA8FF, .last = 0xA8FF },
    .{ .first = 0xA926, .last = 0xA92D },
    .{ .first = 0xA947, .last = 0xA951 },
    .{ .first = 0xA980, .last = 0xA982 },
    .{ .first = 0xA9B3, .last = 0xA9B3 },
    .{ .first = 0xA9B6, .last = 0xA9B9 },
    .{ .first = 0xA9BC, .last = 0xA9BD },
    .{ .first = 0xA9E5, .last = 0xA9E5 },
    .{ .first = 0xAA29, .last = 0xAA2E },
    .{ .first = 0xAA31, .last = 0xAA32 },
    .{ .first = 0xAA35, .last = 0xAA36 },
    .{ .first = 0xAA43, .last = 0xAA43 },
    .{ .first = 0xAA4C, .last = 0xAA4C },
    .{ .first = 0xAA7C, .last = 0xAA7C },
    .{ .first = 0xAAB0, .last = 0xAAB0 },
    .{ .first = 0xAAB2, .last = 0xAAB4 },
    .{ .first = 0xAAB7, .last = 0xAAB8 },
    .{ .first = 0xAABE, .last = 0xAABF },
    .{ .first = 0xAAC1, .last = 0xAAC1 },
    .{ .first = 0xAAEC, .last = 0xAAED },
    .{ .first = 0xAAF6, .last = 0xAAF6 },
    .{ .first = 0xABE5, .last = 0xABE5 },
    .{ .first = 0xABE8, .last = 0xABE8 },
    .{ .first = 0xABED, .last = 0xABED },
    .{ .first = 0xD7B0, .last = 0xD7C6 },
    .{ .first = 0xD7CB, .last = 0xD7FB },
    .{ .first = 0xFB1E, .last = 0xFB1E },
    .{ .first = 0xFE00, .last = 0xFE0F },
    .{ .first = 0xFE20, .last = 0xFE2F },
    .{ .first = 0xFEFF, .last = 0xFEFF },
    .{ .first = 0xFF9E, .last = 0xFFA0 },
    .{ .first = 0xFFF0, .last = 0xFFF8 },
    .{ .first = 0x101FD, .last = 0x101FD },
    .{ .first = 0x102E0, .last = 0x102E0 },
    .{ .first = 0x10376, .last = 0x1037A },
    .{ .first = 0x10A01, .last = 0x10A03 },
    .{ .first = 0x10A05, .last = 0x10A06 },
    .{ .first = 0x10A0C, .last = 0x10A0F },
    .{ .first = 0x10A38, .last = 0x10A3A },
    .{ .first = 0x10A3F, .last = 0x10A3F },
    .{ .first = 0x10AE5, .last = 0x10AE6 },
    .{ .first = 0x10D24, .last = 0x10D27 },
    .{ .first = 0x10EAB, .last = 0x10EAC },
    .{ .first = 0x10EFD, .last = 0x10EFF },
    .{ .first = 0x10F46, .last = 0x10F50 },
    .{ .first = 0x10F82, .last = 0x10F85 },
    .{ .first = 0x11001, .last = 0x11001 },
    .{ .first = 0x11038, .last = 0x11046 },
    .{ .first = 0x11070, .last = 0x11070 },
    .{ .first = 0x11073, .last = 0x11074 },
    .{ .first = 0x1107F, .last = 0x11081 },
    .{ .first = 0x110B3, .last = 0x110B6 },
    .{ .first = 0x110B9, .last = 0x110BA },
    .{ .first = 0x110C2, .last = 0x110C2 },
    .{ .first = 0x11100, .last = 0x11102 },
    .{ .first = 0x11127, .last = 0x1112B },
    .{ .first = 0x1112D, .last = 0x11134 },
    .{ .first = 0x11173, .last = 0x11173 },
    .{ .first = 0x11180, .last = 0x11181 },
    .{ .first = 0x111B6, .last = 0x111BE },
    .{ .first = 0x111C2, .last = 0x111C3 },
    .{ .first = 0x111C9, .last = 0x111CC },
    .{ .first = 0x111CF, .last = 0x111CF },
    .{ .first = 0x1122F, .last = 0x11231 },
    .{ .first = 0x11234, .last = 0x11234 },
    .{ .first = 0x11236, .last = 0x11237 },
    .{ .first = 0x1123E, .last = 0x1123E },
    .{ .first = 0x11241, .last = 0x11241 },
    .{ .first = 0x112DF, .last = 0x112DF },
    .{ .first = 0x112E3, .last = 0x112EA },
    .{ .first = 0x11300, .last = 0x11301 },
    .{ .first = 0x1133B, .last = 0x1133C },
    .{ .first = 0x1133E, .last = 0x1133E },
    .{ .first = 0x11340, .last = 0x11340 },
    .{ .first = 0x11357, .last = 0x11357 },
    .{ .first = 0x11366, .last = 0x1136C },
    .{ .first = 0x11370, .last = 0x11374 },
    .{ .first = 0x11438, .last = 0x1143F },
    .{ .first = 0x11442, .last = 0x11444 },
    .{ .first = 0x11446, .last = 0x11446 },
    .{ .first = 0x1145E, .last = 0x1145E },
    .{ .first = 0x114B0, .last = 0x114B0 },
    .{ .first = 0x114B3, .last = 0x114B8 },
    .{ .first = 0x114BA, .last = 0x114BA },
    .{ .first = 0x114BD, .last = 0x114BD },
    .{ .first = 0x114BF, .last = 0x114C0 },
    .{ .first = 0x114C2, .last = 0x114C3 },
    .{ .first = 0x115AF, .last = 0x115AF },
    .{ .first = 0x115B2, .last = 0x115B5 },
    .{ .first = 0x115BC, .last = 0x115BD },
    .{ .first = 0x115BF, .last = 0x115C0 },
    .{ .first = 0x115DC, .last = 0x115DD },
    .{ .first = 0x11633, .last = 0x1163A },
    .{ .first = 0x1163D, .last = 0x1163D },
    .{ .first = 0x1163F, .last = 0x11640 },
    .{ .first = 0x116AB, .last = 0x116AB },
    .{ .first = 0x116AD, .last = 0x116AD },
    .{ .first = 0x116B0, .last = 0x116B5 },
    .{ .first = 0x116B7, .last = 0x116B7 },
    .{ .first = 0x1171D, .last = 0x1171F },
    .{ .first = 0x11722, .last = 0x11725 },
    .{ .first = 0x11727, .last = 0x1172B },
    .{ .first = 0x1182F, .last = 0x11837 },
    .{ .first = 0x11839, .last = 0x1183A },
    .{ .first = 0x11930, .last = 0x11930 },
    .{ .first = 0x1193B, .last = 0x1193C },
    .{ .first = 0x1193E, .last = 0x1193F },
    .{ .first = 0x11941, .last = 0x11941 },
    .{ .first = 0x11943, .last = 0x11943 },
    .{ .first = 0x119D4, .last = 0x119D7 },
    .{ .first = 0x119DA, .last = 0x119DB },
    .{ .first = 0x119E0, .last = 0x119E0 },
    .{ .first = 0x11A01, .last = 0x11A0A },
    .{ .first = 0x11A33, .last = 0x11A38 },
    .{ .first = 0x11A3A, .last = 0x11A3E },
    .{ .first = 0x11A47, .last = 0x11A47 },
    .{ .first = 0x11A51, .last = 0x11A56 },
    .{ .first = 0x11A59, .last = 0x11A5B },
    .{ .first = 0x11A84, .last = 0x11A96 },
    .{ .first = 0x11A98, .last = 0x11A99 },
    .{ .first = 0x11C30, .last = 0x11C36 },
    .{ .first = 0x11C38, .last = 0x11C3D },
    .{ .first = 0x11C3F, .last = 0x11C3F },
    .{ .first = 0x11C92, .last = 0x11CA7 },
    .{ .first = 0x11CAA, .last = 0x11CB0 },
    .{ .first = 0x11CB2, .last = 0x11CB3 },
    .{ .first = 0x11CB5, .last = 0x11CB6 },
    .{ .first = 0x11D31, .last = 0x11D36 },
    .{ .first = 0x11D3A, .last = 0x11D3A },
    .{ .first = 0x11D3C, .last = 0x11D3D },
    .{ .first = 0x11D3F, .last = 0x11D47 },
    .{ .first = 0x11D90, .last = 0x11D91 },
    .{ .first = 0x11D95, .last = 0x11D95 },
    .{ .first = 0x11D97, .last = 0x11D97 },
    .{ .first = 0x11EF3, .last = 0x11EF4 },
    .{ .first = 0x11F00, .last = 0x11F02 },
    .{ .first = 0x11F36, .last = 0x11F3A },
    .{ .first = 0x11F40, .last = 0x11F40 },
    .{ .first = 0x11F42, .last = 0x11F42 },
    .{ .first = 0x13440, .last = 0x13440 },
    .{ .first = 0x13447, .last = 0x13455 },
    .{ .first = 0x16AF0, .last = 0x16AF4 },
    .{ .first = 0x16B30, .last = 0x16B36 },
    .{ .first = 0x16F4F, .last = 0x16F4F },
    .{ .first = 0x16F8F, .last = 0x16F92 },
    .{ .first = 0x16FE4, .last = 0x16FE4 },
    .{ .first = 0x1BC9D, .last = 0x1BC9E },
    .{ .first = 0x1BCA0, .last = 0x1BCA3 },
    .{ .first = 0x1CF00, .last = 0x1CF2D },
    .{ .first = 0x1CF30, .last = 0x1CF46 },
    .{ .first = 0x1D165, .last = 0x1D165 },
    .{ .first = 0x1D167, .last = 0x1D169 },
    .{ .first = 0x1D16E, .last = 0x1D182 },
    .{ .first = 0x1D185, .last = 0x1D18B },
    .{ .first = 0x1D1AA, .last = 0x1D1AD },
    .{ .first = 0x1D242, .last = 0x1D244 },
    .{ .first = 0x1DA00, .last = 0x1DA36 },
    .{ .first = 0x1DA3B, .last = 0x1DA6C },
    .{ .first = 0x1DA75, .last = 0x1DA75 },
    .{ .first = 0x1DA84, .last = 0x1DA84 },
    .{ .first = 0x1DA9B, .last = 0x1DA9F },
    .{ .first = 0x1DAA1, .last = 0x1DAAF },
    .{ .first = 0x1E000, .last = 0x1E006 },
    .{ .first = 0x1E008, .last = 0x1E018 },
    .{ .first = 0x1E01B, .last = 0x1E021 },
    .{ .first = 0x1E023, .last = 0x1E024 },
    .{ .first = 0x1E026, .last = 0x1E02A },
    .{ .first = 0x1E08F, .last = 0x1E08F },
    .{ .first = 0x1E130, .last = 0x1E136 },
    .{ .first = 0x1E2AE, .last = 0x1E2AE },
    .{ .first = 0x1E2EC, .last = 0x1E2EF },
    .{ .first = 0x1E4EC, .last = 0x1E4EF },
    .{ .first = 0x1E8D0, .last = 0x1E8D6 },
    .{ .first = 0x1E944, .last = 0x1E94A },
    .{ .first = 0xE0000, .last = 0xE0FFF },
};

pub const wide_ranges = [_]MarkRange{
    .{ .first = 0x1100, .last = 0x115F },
    .{ .first = 0x17A4, .last = 0x17A4 },
    .{ .first = 0x231A, .last = 0x231B },
    .{ .first = 0x2329, .last = 0x232A },
    .{ .first = 0x23E9, .last = 0x23EC },
    .{ .first = 0x23F0, .last = 0x23F0 },
    .{ .first = 0x23F3, .last = 0x23F3 },
    .{ .first = 0x25FD, .last = 0x25FE },
    .{ .first = 0x2614, .last = 0x2615 },
    .{ .first = 0x2648, .last = 0x2653 },
    .{ .first = 0x267F, .last = 0x267F },
    .{ .first = 0x2693, .last = 0x2693 },
    .{ .first = 0x26A1, .last = 0x26A1 },
    .{ .first = 0x26AA, .last = 0x26AB },
    .{ .first = 0x26BD, .last = 0x26BE },
    .{ .first = 0x26C4, .last = 0x26C5 },
    .{ .first = 0x26CE, .last = 0x26CE },
    .{ .first = 0x26D4, .last = 0x26D4 },
    .{ .first = 0x26EA, .last = 0x26EA },
    .{ .first = 0x26F2, .last = 0x26F3 },
    .{ .first = 0x26F5, .last = 0x26F5 },
    .{ .first = 0x26FA, .last = 0x26FA },
    .{ .first = 0x26FD, .last = 0x26FD },
    .{ .first = 0x2705, .last = 0x2705 },
    .{ .first = 0x270A, .last = 0x270B },
    .{ .first = 0x2728, .last = 0x2728 },
    .{ .first = 0x274C, .last = 0x274C },
    .{ .first = 0x274E, .last = 0x274E },
    .{ .first = 0x2753, .last = 0x2755 },
    .{ .first = 0x2757, .last = 0x2757 },
    .{ .first = 0x2795, .last = 0x2797 },
    .{ .first = 0x27B0, .last = 0x27B0 },
    .{ .first = 0x27BF, .last = 0x27BF },
    .{ .first = 0x2B1B, .last = 0x2B1C },
    .{ .first = 0x2B50, .last = 0x2B50 },
    .{ .first = 0x2B55, .last = 0x2B55 },
    .{ .first = 0x2E80, .last = 0x2E99 },
    .{ .first = 0x2E9B, .last = 0x2EF3 },
    .{ .first = 0x2F00, .last = 0x2FD5 },
    .{ .first = 0x2FF0, .last = 0x3029 },
    .{ .first = 0x3030, .last = 0x303E },
    .{ .first = 0x3041, .last = 0x3096 },
    .{ .first = 0x309B, .last = 0x30FF },
    .{ .first = 0x3105, .last = 0x312F },
    .{ .first = 0x3131, .last = 0x3163 },
    .{ .first = 0x3165, .last = 0x318E },
    .{ .first = 0x3190, .last = 0x31E3 },
    .{ .first = 0x31EF, .last = 0x321E },
    .{ .first = 0x3220, .last = 0x3247 },
    .{ .first = 0x3250, .last = 0x4DBF },
    .{ .first = 0x4E00, .last = 0xA48C },
    .{ .first = 0xA490, .last = 0xA4C6 },
    .{ .first = 0xA960, .last = 0xA97C },
    .{ .first = 0xAC00, .last = 0xD7A3 },
    .{ .first = 0xF900, .last = 0xFAFF },
    .{ .first = 0xFE10, .last = 0xFE19 },
    .{ .first = 0xFE30, .last = 0xFE52 },
    .{ .first = 0xFE54, .last = 0xFE66 },
    .{ .first = 0xFE68, .last = 0xFE6B },
    .{ .first = 0xFF01, .last = 0xFF60 },
    .{ .first = 0xFFE0, .last = 0xFFE6 },
    .{ .first = 0x16FE0, .last = 0x16FE3 },
    .{ .first = 0x16FF0, .last = 0x16FF1 },
    .{ .first = 0x17000, .last = 0x187F7 },
    .{ .first = 0x18800, .last = 0x18CD5 },
    .{ .first = 0x18D00, .last = 0x18D08 },
    .{ .first = 0x1AFF0, .last = 0x1AFF3 },
    .{ .first = 0x1AFF5, .last = 0x1AFFB },
    .{ .first = 0x1AFFD, .last = 0x1AFFE },
    .{ .first = 0x1B000, .last = 0x1B122 },
    .{ .first = 0x1B132, .last = 0x1B132 },
    .{ .first = 0x1B150, .last = 0x1B152 },
    .{ .first = 0x1B155, .last = 0x1B155 },
    .{ .first = 0x1B164, .last = 0x1B167 },
    .{ .first = 0x1B170, .last = 0x1B2FB },
    .{ .first = 0x1F004, .last = 0x1F004 },
    .{ .first = 0x1F0CF, .last = 0x1F0CF },
    .{ .first = 0x1F18E, .last = 0x1F18E },
    .{ .first = 0x1F191, .last = 0x1F19A },
    .{ .first = 0x1F200, .last = 0x1F202 },
    .{ .first = 0x1F210, .last = 0x1F23B },
    .{ .first = 0x1F240, .last = 0x1F248 },
    .{ .first = 0x1F250, .last = 0x1F251 },
    .{ .first = 0x1F260, .last = 0x1F265 },
    .{ .first = 0x1F300, .last = 0x1F320 },
    .{ .first = 0x1F32D, .last = 0x1F335 },
    .{ .first = 0x1F337, .last = 0x1F37C },
    .{ .first = 0x1F37E, .last = 0x1F393 },
    .{ .first = 0x1F3A0, .last = 0x1F3CA },
    .{ .first = 0x1F3CF, .last = 0x1F3D3 },
    .{ .first = 0x1F3E0, .last = 0x1F3F0 },
    .{ .first = 0x1F3F4, .last = 0x1F3F4 },
    .{ .first = 0x1F3F8, .last = 0x1F43E },
    .{ .first = 0x1F440, .last = 0x1F440 },
    .{ .first = 0x1F442, .last = 0x1F4FC },
    .{ .first = 0x1F4FF, .last = 0x1F53D },
    .{ .first = 0x1F54B, .last = 0x1F54E },
    .{ .first = 0x1F550, .last = 0x1F567 },
    .{ .first = 0x1F57A, .last = 0x1F57A },
    .{ .first = 0x1F595, .last = 0x1F596 },
    .{ .first = 0x1F5A4, .last = 0x1F5A4 },
    .{ .first = 0x1F5FB, .last = 0x1F64F },
    .{ .first = 0x1F680, .last = 0x1F6C5 },
    .{ .first = 0x1F6CC, .last = 0x1F6CC },
    .{ .first = 0x1F6D0, .last = 0x1F6D2 },
    .{ .first = 0x1F6D5, .last = 0x1F6D7 },
    .{ .first = 0x1F6DC, .last = 0x1F6DF },
    .{ .first = 0x1F6EB, .last = 0x1F6EC },
    .{ .first = 0x1F6F4, .last = 0x1F6FC },
    .{ .first = 0x1F7E0, .last = 0x1F7EB },
    .{ .first = 0x1F7F0, .last = 0x1F7F0 },
    .{ .first = 0x1F90C, .last = 0x1F93A },
    .{ .first = 0x1F93C, .last = 0x1F945 },
    .{ .first = 0x1F947, .last = 0x1F9FF },
    .{ .first = 0x1FA70, .last = 0x1FA7C },
    .{ .first = 0x1FA80, .last = 0x1FA88 },
    .{ .first = 0x1FA90, .last = 0x1FABD },
    .{ .first = 0x1FABF, .last = 0x1FAC5 },
    .{ .first = 0x1FACE, .last = 0x1FADB },
    .{ .first = 0x1FAE0, .last = 0x1FAE8 },
    .{ .first = 0x1FAF0, .last = 0x1FAF8 },
    .{ .first = 0x20000, .last = 0x2FFFD },
    .{ .first = 0x30000, .last = 0x3FFFD },
};

comptime {
    for (bracket_closes, bracket_opens) |close, open| {
        assert(is_close(close));
        assert(!is_open(close));
        assert(is_open(open));
        assert(!is_close(open));
        assert(punctuated(close));
        assert(punctuated(open));
        assert(closed_by(open).eql(close));
        assert(opened_by(close).eql(open));
    }
}

comptime {
    @setEvalBranchQuota(10_000);

    assert(mark_ranges.len == 373);
    assert(wide_ranges.len == 123);

    for ([_][]const MarkRange{ &mark_ranges, &wide_ranges }) |ranges| {
        for (ranges[1..], ranges[0 .. ranges.len - 1]) |range, range_previous| {
            assert(range.first <= range.last);
            assert(range_previous.last < range.first);
        }
    }
}

pub fn following(tokens: []const Token, from: u32) ?u32 {
    assert(tokens.len < none);
    assert(from <= none);

    if (from >= tokens.len) return null;

    for (from..tokens.len) |scan| {
        const kind = tokens[scan].kind;
        const coded_token = kind != .comment and kind != .newline;

        if (coded_token) {
            assert(scan < tokens.len);

            return @intCast(scan);
        }
    }

    return null;
}

pub fn preceding(tokens: []const Token, before: u32) ?u32 {
    assert(tokens.len < none);
    if (before == 0) return null;

    var scan: u32 = @min(before, @as(u32, @intCast(tokens.len)));

    assert(scan <= tokens.len);

    for (0..scan) |_| {
        scan -= 1;

        const kind = tokens[scan].kind;
        const coded_token = kind != .comment and kind != .newline;
        if (coded_token) return scan;
    }

    return null;
}

pub fn written_before(tokens: []const Token, position: u32) ?u32 {
    assert(position < tokens.len);

    var scan = position;

    assert(tokens.len < none);

    for (0..position) |_| {
        scan -= 1;

        const token = tokens[scan];
        const coded_token = token.kind != .newline and token.length > 0;
        if (coded_token) return scan;
    }

    return null;
}

pub fn written_after(tokens: []const Token, position: u32) ?u32 {
    assert(position < tokens.len);
    assert(tokens.len < none);

    for (position + 1..tokens.len) |scan| {
        const token = tokens[scan];
        const coded_token = token.kind != .newline and token.length > 0;

        if (coded_token) {
            assert(scan <= tokens.len);

            return @intCast(scan);
        }
    }

    return null;
}

pub fn punctuated(kind: Token.Kind) bool {
    if (kind == .comment) return false;

    const result = switch (kind) {
        .block_end, .block_start, .punctuation => true,
        .comment, .identifier, .keyword, .newline, .number, .string => false,
    };

    if (result) assert(Token.is_significant(kind));
    if (result) assert(kind != .identifier);

    return result;
}

pub fn substituting(source: []const u8, token: Token) bool {
    assert(token.end() <= source.len);

    if (token.kind != .string) return false;
    if (token.length != 2) return false;

    const result = source[token.offset] == '$' and source[token.offset + 1] == '{';

    if (result) assert(text_is(token.text(source), "${"));

    return result;
}

pub inline fn text_eql(left: []const u8, right: []const u8) bool {
    if (left.len != right.len) return false;
    if (left.len == 0) return true;
    if (left[0] != right[0]) return false;
    return std.mem.eql(u8, left, right);
}

pub inline fn text_is(text: []const u8, comptime literal: []const u8) bool {
    if (text.len != literal.len) return false;

    inline for (literal, 0..) |byte, at| {
        if (text[at] != byte) return false;
    }

    return true;
}

pub fn simple_word(token: Token, source: []const u8) bool {
    assert(token.end() <= source.len);

    const kinded = switch (token.kind) {
        .identifier, .newline, .number, .string => true,
        .block_end, .block_start, .comment, .keyword, .punctuation => false,
    };

    if (kinded) return true;

    const text = token.text(source);

    for (simple_words) |word| {
        if (text_eql(text, word)) return true;
    }

    assert(token.kind != .identifier);

    return false;
}

pub fn columns(source: []const u8, from: u32, to: u32) u32 {
    assert(source.len <= std.math.maxInt(u32));
    assert(from < none);
    assert(to < none);

    const stop = @min(to, @as(u32, @intCast(source.len)));
    const start = @min(from, stop);

    const ascii = for (source[start..stop]) |byte| {
        if (byte >= 0x80) break false;
    } else true;

    if (ascii) {
        assert(stop - start <= source.len);

        return stop - start;
    }

    assert(start == from);

    var held: u32 = 0;
    var position = from;

    while (position < stop) : (position += 1) {
        if (source[position] & 0xC0 == 0x80) continue;

        held += point_columns(point_at(source, position));
    }

    assert(@as(u64, held) <= 2 * @as(u64, stop - start));

    return held;
}

pub fn point_columns(point: u32) u32 {
    assert(point <= 0x1F_FFFF);

    if (point < 0x80) return 1;
    if (ranged(&mark_ranges, point)) return 0;
    if (point == khmer_beyyal) return 3;
    if (ranged(&wide_ranges, point)) return 2;
    return 1;
}

fn ranged(ranges: []const MarkRange, point: u32) bool {
    assert(ranges.len > 0);
    assert(ranges.len <= std.math.maxInt(u32));

    var low: u32 = 0;
    var high: u32 = @intCast(ranges.len);

    for (0..ranges.len + 1) |_| {
        if (low >= high) return false;

        const middle = low + (high - low) / 2;
        const range = ranges[middle];

        if (point < range.first) {
            high = middle;
        } else if (point > range.last) {
            low = middle + 1;
        } else {
            return true;
        }
    }

    return false;
}

pub fn is_close(kind: Token.Kind) bool {
    if (kind == .comment) return false;

    return switch (kind) {
        .block_end => true,
        .punctuation => |punctuation| punctuation == .bracket_close or punctuation == .paren_close,
        .block_start, .comment, .identifier, .keyword, .newline, .number, .string => false,
    };
}

pub fn is_open(kind: Token.Kind) bool {
    if (kind == .comment) return false;

    return switch (kind) {
        .block_start => true,
        .punctuation => |punctuation| punctuation == .bracket_open or punctuation == .paren_open,
        .block_end, .comment, .identifier, .keyword, .newline, .number, .string => false,
    };
}

fn closed_by(open: Token.Kind) Token.Kind {
    assert(is_open(open));

    const result: Token.Kind = switch (open) {
        .block_start => .block_end,
        .punctuation => |punctuation| switch (punctuation) {
            .bracket_open => .{ .punctuation = .bracket_close },
            else => .{ .punctuation = .paren_close },
        },
        .block_end,
        .comment,
        .identifier,
        .keyword,
        .newline,
        .number,
        .string,
        => .{ .punctuation = .paren_close },
    };

    assert(punctuated(result));
    if (open == .block_start) assert(result == .block_end);

    return result;
}

pub fn opened_by(close: Token.Kind) Token.Kind {
    const result: Token.Kind = switch (close) {
        .block_end => .block_start,
        .punctuation => |punctuation| switch (punctuation) {
            .bracket_close => .{ .punctuation = .bracket_open },
            else => .{ .punctuation = .paren_open },
        },
        .block_start,
        .comment,
        .identifier,
        .keyword,
        .newline,
        .number,
        .string,
        => .{ .punctuation = .paren_open },
    };

    assert(punctuated(result));
    if (close == .block_end) assert(result == .block_start);

    return result;
}

pub fn ends_operand(kind: Token.Kind) bool {
    if (kind == .comment) return false;

    const result = switch (kind) {
        .identifier, .number, .string => true,
        .punctuation => |punctuation| punctuation == .bracket_close or punctuation == .paren_close,
        .block_end, .block_start, .comment, .keyword, .newline => false,
    };

    if (result) assert(!is_open(kind));
    if (result) assert(Token.is_significant(kind));

    return result;
}

pub fn span_of(bytes: []const u8, lines: LineRange) ?Span {
    assert(lines.first <= lines.last);
    assert(bytes.len <= std.math.maxInt(u32));

    var line: u32 = 0;
    var offset: u32 = 0;
    var start: ?u32 = null;
    var end: u32 = @intCast(bytes.len);

    for (bytes, 0..) |byte, position| {
        const starts = line == lines.first and start == null;

        if (starts) start = offset;

        if (line == lines.last + 1) {
            end = offset;

            break;
        }

        if (byte == '\n') {
            line += 1;
            offset = @intCast(position + 1);
        }
    }

    const starts = line == lines.first and start == null;

    if (starts) start = offset;

    const first = start orelse return null;

    assert(end >= first);

    return .{ .offset = first, .length = end - first };
}

fn point_at(source: []const u8, position: u32) u32 {
    assert(position < source.len);

    const lead = source[position];

    const length: u32 = switch (lead) {
        0xC0...0xDF => 2,
        0xE0...0xEF => 3,
        0xF0...0xF7 => 4,
        else => 1,
    };

    if (length == 1) return lead;
    if (source.len - position < length) return 0;

    const mask = @as(u8, 0xFF) >> @intCast(length + 1);
    var point: u32 = lead & mask;

    for (source[position + 1 ..][0 .. length - 1]) |byte| {
        point = (point << 6) | (byte & 0x3F);
    }

    assert(point <= 0x1F_FFFF);
    assert(point >> @intCast(5 * length + 1) == 0);

    return point;
}

fn angled_text(held: *Angle, text: []const u8) void {
    assert(held.depth >= held.total);
    assert(text.len <= std.math.maxInt(u32));

    const opening = text_is(text, "<") or (angle_tags and text_is(text, "</"));
    if (opening) return held.opened();

    const tag_closes = angle_tags and text_is(text, "/>");
    if (tag_closes) return held.closed(1);
    if (text.len == 0) return;

    for (text) |byte| {
        if (byte != '>') return;
    }

    held.closed(@intCast(text.len));

    assert(held.drop >= -held.total);
}

fn linked_at(array: *const ArrayType(u32), position: u32) ?u32 {
    assert(array.count() <= array.capacity());
    assert(position < none);

    if (position < array.count()) {
        const link = array.get(position);
        if (link == none) return null;
        return link;
    }

    return null;
}

fn partition_point(offsets: []const u32, from: u32) u32 {
    assert(offsets.len < std.math.maxInt(u32));

    var low: u32 = 0;
    var high: u32 = @intCast(offsets.len);

    while (low < high) {
        const middle = low + @divFloor(high - low, 2);

        if (offsets[middle] < from) {
            low = middle + 1;
        } else {
            high = middle;
        }
    }

    if (low < offsets.len) assert(offsets[low] >= from);
    if (low > 0) assert(offsets[low - 1] < from);

    return low;
}

test "a bracket build pairs every open with its close" {
    var lexed = try Lexed.init(.javascript, "f(a[b], {c});");
    defer lexed.deinit();

    const tokens = lexed.tokens.slice();
    var roles: [16]u16 = @splat(0);
    var brackets: Brackets = try .init(std.testing.allocator, 16);
    defer brackets.deinit(std.testing.allocator);

    try brackets.build(lexed.source, tokens, roles[0..tokens.len], true);

    try std.testing.expectEqual(@as(usize, 12), tokens.len);
    try std.testing.expectEqual(@as(?u32, 10), brackets.close_of(1));
    try std.testing.expectEqual(@as(?u32, 1), brackets.open_of(10));
    try std.testing.expectEqual(@as(?u32, 5), brackets.close_of(3));
    try std.testing.expectEqual(@as(?u32, 9), brackets.close_of(7));
    try std.testing.expectEqual(@as(?u32, null), brackets.close_of(0));
    try std.testing.expectEqual(@as(?u32, 7), brackets.block_after(0));
    try std.testing.expectEqual(@as(?u32, 9), brackets.block_after(8));
    try std.testing.expectEqual(@as(?u32, null), brackets.block_after(10));
    try std.testing.expectEqual(@as(?u32, 1), brackets.identifier_open_of(2));
    try std.testing.expectEqual(@as(?u32, null), brackets.identifier_open_of(4));
    try std.testing.expectEqual(@as(u32, 5), brackets.stepped(0, 5));
    try std.testing.expect(!brackets.substituted(0, 11));
}

test "a bracket build tracks the depth of angle brackets" {
    var lexed = try Lexed.init(.typescript, "f<T>(x);");
    defer lexed.deinit();

    const tokens = lexed.tokens.slice();
    var roles: [16]u16 = @splat(0);
    var brackets: Brackets = try .init(std.testing.allocator, 16);
    defer brackets.deinit(std.testing.allocator);

    try brackets.build(lexed.source, tokens, roles[0..tokens.len], true);

    try std.testing.expectEqual(@as(u32, 0), brackets.angles_at(1));
    try std.testing.expectEqual(@as(u32, 1), brackets.angles_at(2));
    try std.testing.expectEqual(@as(u32, 1), brackets.angles_at(3));
    try std.testing.expectEqual(@as(u32, 0), brackets.angles_at(4));
    try std.testing.expectEqual(@as(u32, 0), brackets.angles_at(64));

    try brackets.build(lexed.source, tokens, roles[0..tokens.len], false);

    try std.testing.expectEqual(@as(u32, 0), brackets.angles_at(2));
}

test "a bracket build past its reservation reports the overflow" {
    var lexed = try Lexed.init(.javascript, "f(a, b, c);");
    defer lexed.deinit();

    var brackets: Brackets = try .init(std.testing.allocator, 4);
    defer brackets.deinit(std.testing.allocator);

    const tokens = lexed.tokens.slice();

    try std.testing.expectError(error.Overflow, brackets.build(lexed.source, tokens, &.{}, true));
}

test "columns count a wide code point twice and a combining mark not at all" {
    try std.testing.expectEqual(@as(u32, 2), columns("a\u{301}b", 0, 4));
    try std.testing.expectEqual(@as(u32, 4), columns("\u{65E5}\u{672C}", 0, 6));
    try std.testing.expectEqual(@as(u32, 3), columns("hello", 1, 4));
    try std.testing.expectEqual(@as(u32, 1), columns("abc", 2, 10));
    try std.testing.expectEqual(@as(u32, 0), columns("abc", 3, 1));
    try std.testing.expectEqual(@as(u32, 1), columns("\u{E9}", 0, 2));
    try std.testing.expectEqual(@as(u32, 4), columns("\xE9ph", 0, 3));
}

test "columns follow the width table rustfmt measures with" {
    try std.testing.expectEqual(@as(u32, 2), columns("\u{274C}", 0, 3));
    try std.testing.expectEqual(@as(u32, 1), columns("\u{26A0}\u{FE0F}", 0, 6));
    try std.testing.expectEqual(@as(u32, 1), columns("\u{1F441}", 0, 4));
    try std.testing.expectEqual(@as(u32, 2), columns("\u{16FE0}", 0, 4));
    try std.testing.expectEqual(@as(u32, 3), columns("\u{17D8}", 0, 3));
    try std.testing.expectEqual(@as(u32, 0), columns("\u{200D}", 0, 3));
    try std.testing.expectEqual(@as(u32, 1), columns("\u{85}", 0, 2));
}

test "a line range spans its lines and their breaks" {
    const bytes = "ab\ncd\nef";
    const first: LineRange = .{ .first = 0, .last = 0 };
    const second: LineRange = .{ .first = 1, .last = 1 };
    const rest: LineRange = .{ .first = 1, .last = 4 };

    try std.testing.expectEqual(Span{ .offset = 3, .length = 3 }, span_of(bytes, second).?);
    try std.testing.expectEqual(Span{ .offset = 0, .length = 3 }, span_of(bytes, first).?);
    try std.testing.expectEqual(Span{ .offset = 3, .length = 5 }, span_of(bytes, rest).?);
    try std.testing.expectEqual(Span{ .offset = 3, .length = 0 }, span_of("ab\n", second).?);
    try std.testing.expectEqual(@as(?Span, null), span_of("ab", second));
}

test "breaks count the line breaks between two offsets" {
    const source = "a\nb\\\nc\r\nd";
    var breaks: Breaks = try .init(std.testing.allocator, 16);
    defer breaks.deinit(std.testing.allocator);

    try breaks.build(source, false);

    try std.testing.expectEqual(@as(u32, 2), breaks.counted(0, 9));
    try std.testing.expectEqual(@as(u32, 2), breaks.counted(4, 9));
    try std.testing.expectEqual(@as(u32, 0), breaks.counted(5, 6));

    try breaks.build("a\rb\rc", false);

    try std.testing.expectEqual(@as(u32, 0), breaks.counted(0, 5));

    try breaks.build("a\rb\rc", true);

    try std.testing.expectEqual(@as(u32, 2), breaks.counted(0, 5));
}

test "the kind predicates agree on brackets" {
    const paren_open: Token.Kind = .{ .punctuation = .paren_open };
    const bracket_close: Token.Kind = .{ .punctuation = .bracket_close };

    try std.testing.expect(is_open(paren_open));
    try std.testing.expect(is_open(.block_start));
    try std.testing.expect(!is_open(bracket_close));
    try std.testing.expect(is_close(bracket_close));
    try std.testing.expect(is_close(.block_end));
    try std.testing.expect(!is_close(.identifier));
    try std.testing.expect(closed_by(.block_start).eql(.block_end));
    try std.testing.expect(opened_by(bracket_close).eql(.{ .punctuation = .bracket_open }));
    try std.testing.expect(ends_operand(bracket_close));
    try std.testing.expect(!ends_operand(paren_open));
    try std.testing.expect(punctuated(.{ .punctuation = .comma }));
    try std.testing.expect(!punctuated(.string));
}

test "simple words and substitutions read the token text" {
    const source = "${ as + x";
    const substitution: Token = .{ .offset = 0, .length = 2, .kind = .string };
    const word: Token = .{ .offset = 3, .length = 2, .kind = .{ .keyword = .other } };
    const plus: Token = .{ .offset = 6, .length = 1, .kind = .{ .punctuation = .other } };
    const name: Token = .{ .offset = 8, .length = 1, .kind = .identifier };

    try std.testing.expect(substituting(source, substitution));
    try std.testing.expect(!substituting(source, name));
    try std.testing.expect(simple_word(word, source));
    try std.testing.expect(!simple_word(plus, source));
    try std.testing.expect(simple_word(name, source));
}

const Lexed = @import("../syntax/testing/lexed.zig").Lexed;
