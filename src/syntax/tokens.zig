const std = @import("std");
const assert = std.debug.assert;
const ArrayType = @import("../stdx/bounded/array.zig").ArrayType;
const SourceType = @import("language.zig").SourceType;
const Token = @import("token.zig");
const lexer = @import("lex.zig");

items: ArrayType(Token),
end_previous: u32,

const Tokens = @This();
pub const CapacityError = error{Truncated};

pub fn init(gpa: std.mem.Allocator, token_count_max: u32) std.mem.Allocator.Error!Tokens {
    assert(token_count_max > 0);

    const items: ArrayType(Token) = try .init(gpa, token_count_max);

    assert(items.capacity() == token_count_max);
    assert(items.empty());

    return .{ .items = items, .end_previous = 0 };
}

pub fn deinit(tokens: *Tokens, gpa: std.mem.Allocator) void {
    if (tokens.items.empty()) assert(tokens.end_previous == 0);

    tokens.items.deinit(gpa);
    tokens.* = undefined;
}

pub fn clear(tokens: *Tokens) void {
    if (tokens.items.empty()) assert(tokens.end_previous == 0);

    tokens.items.clear();
    tokens.end_previous = 0;

    assert(tokens.items.empty());
}

pub fn count(tokens: *const Tokens) u32 {
    const held = tokens.items.count();

    if (held == 0) assert(tokens.end_previous == 0);

    return held;
}

pub fn last(tokens: *const Tokens) ?Token {
    const held = tokens.items.const_slice();

    if (held.len == 0) {
        assert(tokens.end_previous == 0);

        return null;
    }

    assert(held[held.len - 1].end() == tokens.end_previous);

    return held[held.len - 1];
}

pub fn layout_drop(tokens: *Tokens) void {
    const held = tokens.items.slice();
    var kept: u32 = 0;

    for (held) |token| {
        switch (token.kind) {
            .block_end, .block_start, .newline => continue,
            else => {},
        }

        held[kept] = token;
        kept += 1;
    }

    assert(kept <= held.len);

    tokens.items.truncate(kept);
    tokens.end_previous = if (kept == 0) 0 else held[kept - 1].end();

    if (kept > 0) assert(tokens.last().?.end() == tokens.end_previous);
}

pub fn lex(tokens: *Tokens, source_type: SourceType, source: []const u8) CapacityError!void {
    assert(source_type.language.lexes());
    assert(source.len <= std.math.maxInt(u32));

    tokens.clear();

    try lexer.lex(source_type, source, tokens);

    assert(tokens.end_previous <= source.len);
}

pub fn push(tokens: *Tokens, source: []const u8, token: Token) CapacityError!void {
    assert(source.len <= std.math.maxInt(u32));
    assert(token.end() <= source.len);

    if (token.length == 0) {
        switch (token.kind) {
            .block_end, .block_start, .newline => {},
            else => unreachable,
        }
    }

    assert(token.offset >= tokens.end_previous);

    if (tokens.items.full()) return error.Truncated;

    const token_count_before = tokens.items.count();

    tokens.items.push(token);
    tokens.end_previous = token.end();

    assert(tokens.items.count() == token_count_before + 1);
}

pub fn slice(tokens: *const Tokens) []const Token {
    const held = tokens.items.const_slice();

    if (held.len > 0) assert(held[held.len - 1].end() == tokens.end_previous);

    return held;
}

test "a push past the reservation truncates and keeps what was pushed" {
    var tokens: Tokens = try .init(std.testing.allocator, 2);
    defer tokens.deinit(std.testing.allocator);

    const source = "a b c";

    try tokens.push(source, .{ .offset = 0, .length = 1, .kind = .identifier });
    try tokens.push(source, .{ .offset = 2, .length = 1, .kind = .identifier });

    const pushed = tokens.push(source, .{ .offset = 4, .length = 1, .kind = .identifier });

    try std.testing.expectError(error.Truncated, pushed);
    try std.testing.expectEqual(2, tokens.count());
    try std.testing.expectEqual(3, tokens.end_previous);
}

test "a cleared list starts again from the first byte" {
    var tokens: Tokens = try .init(std.testing.allocator, 4);
    defer tokens.deinit(std.testing.allocator);

    const source = "ab";

    try tokens.push(source, .{ .offset = 1, .length = 1, .kind = .identifier });
    tokens.clear();
    try tokens.push(source, .{ .offset = 0, .length = 0, .kind = .newline });

    try std.testing.expectEqual(1, tokens.count());
    try std.testing.expectEqual(0, tokens.last().?.end());
}

test "a dropped layout keeps every other token in order" {
    var tokens: Tokens = try .init(std.testing.allocator, 8);
    defer tokens.deinit(std.testing.allocator);

    const source = "\n  a\n";

    try tokens.push(source, .{ .offset = 1, .length = 0, .kind = .block_start });
    try tokens.push(source, .{ .offset = 3, .length = 1, .kind = .identifier });
    try tokens.push(source, .{ .offset = 4, .length = 1, .kind = .newline });
    try tokens.push(source, .{ .offset = 5, .length = 0, .kind = .block_end });
    tokens.layout_drop();

    try std.testing.expectEqual(1, tokens.count());
    try std.testing.expectEqual(4, tokens.end_previous);
    try std.testing.expectEqual(3, tokens.last().?.offset);

    tokens.clear();
    try tokens.push(source, .{ .offset = 0, .length = 1, .kind = .newline });
    tokens.layout_drop();

    try std.testing.expectEqual(0, tokens.count());
    try std.testing.expectEqual(0, tokens.end_previous);
}

test Tokens {
    const gpa = std.testing.allocator;
    const source = "const one = 1;\n";
    var tokens: Tokens = try .init(gpa, 16);
    defer tokens.deinit(gpa);

    try tokens.lex(.of(.zig), source);

    const held = tokens.slice();

    try std.testing.expectEqualStrings("const", held[0].text(source));
    try std.testing.expectEqualStrings("one", held[1].text(source));
    try std.testing.expect(held[2].is_punctuation(.assign));

    var small: Tokens = try .init(gpa, 2);
    defer small.deinit(gpa);

    try std.testing.expectError(error.Truncated, small.lex(.of(.zig), source));
}
