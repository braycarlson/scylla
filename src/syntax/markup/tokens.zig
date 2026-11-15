const std = @import("std");
const assert = std.debug.assert;
const ArrayType = @import("../../stdx/bounded/array.zig").ArrayType;
const Kind = @import("kind.zig").Kind;
const Span = @import("../../stdx/bounded/span.zig");
const Token = @import("token.zig").Token;

pub const Tokens = struct {
    end_previous: u32,
    items: ArrayType(Token),

    pub const CapacityError = error{Overflow};

    pub fn init(gpa: std.mem.Allocator, token_count_max: u32) std.mem.Allocator.Error!Tokens {
        assert(token_count_max > 0);

        const items: ArrayType(Token) = try .init(gpa, token_count_max);

        assert(items.capacity() == token_count_max);
        assert(items.empty());

        return .{ .end_previous = 0, .items = items };
    }

    pub fn deinit(tokens: *Tokens, gpa: std.mem.Allocator) void {
        if (tokens.items.empty()) assert(tokens.end_previous == 0);

        tokens.items.deinit(gpa);
        tokens.* = undefined;
    }

    pub fn capacity(tokens: *const Tokens) u32 {
        const held = tokens.items.capacity();

        assert(held > 0);
        assert(tokens.items.count() <= held);

        return held;
    }

    pub fn clear(tokens: *Tokens) void {
        tokens.items.clear();
        tokens.end_previous = 0;

        assert(tokens.items.empty());
        assert(tokens.count() == 0);
    }

    pub fn count(tokens: *const Tokens) u32 {
        const held = tokens.items.count();

        if (held == 0) assert(tokens.end_previous == 0);

        return held;
    }

    fn full(tokens: *const Tokens) bool {
        assert(tokens.items.count() <= tokens.items.capacity());

        return tokens.items.full();
    }

    pub fn push(tokens: *Tokens, kind: Kind, span: Span) CapacityError!void {
        assert(kind.is_token());
        assert(span.length > 0);
        assert(span.offset == tokens.end_previous);

        if (tokens.full()) return error.Overflow;

        tokens.items.push(.{ .kind = kind, .length = span.length, .offset = span.offset });
        tokens.end_previous = span.end();

        assert(tokens.items.count() > 0);
    }

    pub fn slice(tokens: *const Tokens) []const Token {
        const held = tokens.items.const_slice();

        if (held.len > 0) assert(held[held.len - 1].end() == tokens.end_previous);

        return held;
    }
};
