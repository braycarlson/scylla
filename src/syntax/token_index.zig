const std = @import("std");
const assert = std.debug.assert;
const ArrayType = @import("../stdx/bounded/array.zig").ArrayType;
const Token = @import("token.zig");

positions: ArrayType(u32),
comment_count: u32,

const TokenIndex = @This();

pub fn init(gpa: std.mem.Allocator, token_count_max: u32) std.mem.Allocator.Error!TokenIndex {
    assert(token_count_max > 0);

    const positions: ArrayType(u32) = try .init(gpa, token_count_max);

    assert(positions.empty());

    return .{ .positions = positions, .comment_count = 0 };
}

pub fn deinit(index: *TokenIndex, gpa: std.mem.Allocator) void {
    assert(index.comment_count <= index.positions.count());

    index.positions.deinit(gpa);
    index.* = undefined;
}

pub fn build(index: *TokenIndex, tokens: []const Token) void {
    assert(tokens.len <= index.positions.capacity());

    index.positions.clear();

    for (tokens, 0..) |token, position| {
        if (token.kind == .comment) index.positions.push(@intCast(position));
    }

    index.comment_count = index.positions.count();

    for (tokens, 0..) |token, position| {
        if (token.kind == .identifier) index.positions.push(@intCast(position));
    }

    assert(index.comment_count <= index.positions.count());
    assert(index.positions.count() <= tokens.len);
}

pub fn comments(index: *const TokenIndex) []const u32 {
    assert(index.comment_count <= index.positions.count());

    const held = index.positions.const_slice()[0..index.comment_count];

    if (held.len > 1) assert(held[0] < held[held.len - 1]);

    return held;
}

pub fn identifiers(index: *const TokenIndex) []const u32 {
    assert(index.comment_count <= index.positions.count());

    const held = index.positions.const_slice()[index.comment_count..];

    if (held.len > 1) assert(held[0] < held[held.len - 1]);

    return held;
}

test TokenIndex {
    const gpa = std.testing.allocator;

    const tokens = [_]Token{
        .{ .offset = 0, .length = 3, .kind = .identifier },
        .{ .offset = 4, .length = 6, .kind = .comment },
    };

    var index: TokenIndex = try .init(gpa, tokens.len);
    defer index.deinit(gpa);

    index.build(&tokens);

    try std.testing.expectEqualSlices(u32, &.{1}, index.comments());
    try std.testing.expectEqualSlices(u32, &.{0}, index.identifiers());
}

test "an index lists the comments and then the identifiers by position" {
    const tokens = [_]Token{
        .{ .offset = 0, .length = 1, .kind = .identifier },
        .{ .offset = 2, .length = 4, .kind = .comment },
        .{ .offset = 7, .length = 1, .kind = .number },
        .{ .offset = 9, .length = 1, .kind = .identifier },
        .{ .offset = 11, .length = 3, .kind = .comment },
    };

    var index: TokenIndex = try .init(std.testing.allocator, tokens.len);
    defer index.deinit(std.testing.allocator);

    index.build(&tokens);

    try std.testing.expectEqualSlices(u32, &.{ 1, 4 }, index.comments());
    try std.testing.expectEqualSlices(u32, &.{ 0, 3 }, index.identifiers());

    index.build(tokens[2..3]);

    try std.testing.expectEqual(0, index.comments().len);
    try std.testing.expectEqual(0, index.identifiers().len);
}
