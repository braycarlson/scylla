const std = @import("std");
const assert = std.debug.assert;
const fuzzing = @import("fuzzing.zig");
const lex = @import("../lex.zig").lex;
const Language = @import("../language.zig").Language;
const Tokens = @import("../tokens.zig");

pub const LexHarness = struct {
    again: Tokens,
    tokens: Tokens,

    pub fn init(gpa: std.mem.Allocator, token_count_max: u32) std.mem.Allocator.Error!LexHarness {
        assert(token_count_max > 0);

        var tokens: Tokens = try .init(gpa, token_count_max);
        errdefer tokens.deinit(gpa);

        const again: Tokens = try .init(gpa, token_count_max);

        assert(tokens.count() == 0);
        assert(again.count() == 0);

        return .{ .again = again, .tokens = tokens };
    }

    pub fn deinit(harness: *LexHarness, gpa: std.mem.Allocator) void {
        harness.again.deinit(gpa);
        harness.tokens.deinit(gpa);
        harness.* = undefined;
    }

    pub fn capacity(harness: *const LexHarness) u32 {
        const held = harness.tokens.items.capacity();

        assert(harness.again.items.capacity() == held);

        return held;
    }

    pub fn check(harness: *LexHarness, language: Language, source: []const u8) void {
        assert(language.lexes());
        assert(source.len <= std.math.maxInt(u32));

        harness.tokens.clear();
        harness.again.clear();

        lex(.of(language), source, &harness.tokens) catch |err| switch (err) {
            error.Truncated => return,
        };

        fuzzing.tokens_check(source, harness.tokens.slice());
        lex(.of(language), source, &harness.again) catch unreachable;

        assert(fuzzing.tokens_equal(harness.tokens.slice(), harness.again.slice()));
    }
};

test LexHarness {
    var harness: LexHarness = try .init(std.testing.allocator, 64);
    defer harness.deinit(std.testing.allocator);

    harness.check(.zig, "const one = 1;\n");
    harness.check(.python, "one = 1\n");

    try std.testing.expectEqual(64, harness.capacity());
}

test "a lex harness holds every lexer to bounds and stability" {
    var harness: LexHarness = try .init(std.testing.allocator, 256);
    defer harness.deinit(std.testing.allocator);

    for (std.enums.values(Language)) |language| {
        if (!language.lexes()) continue;

        harness.check(language, "fn main() { return \"text\" // note\n}\n");
        harness.check(language, "\xff\u{e9}(");
    }
}
