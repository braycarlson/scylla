const std = @import("std");
const assert = std.debug.assert;
const Language = @import("../language.zig").Language;

pub const Goal = enum {
    module,
    script,
};

pub const Grammar = struct {
    dialect: Dialect,
    goal: Goal,
};

pub const Dialect = enum {
    javascript,
    tsx,
    typescript,

    pub fn grammar(dialect: Dialect, goal: Goal) Grammar {
        const result: Grammar = .{ .dialect = dialect, .goal = goal };

        assert(result.dialect == dialect);
        assert(result.goal == goal);

        return result;
    }

    pub fn allows_jsx(dialect: Dialect) bool {
        const result = dialect != .typescript;

        if (result) assert(dialect == .javascript or dialect == .tsx);

        return result;
    }

    pub fn is_tsx(dialect: Dialect) bool {
        const result = dialect == .tsx;

        if (result) assert(dialect.typed());

        return result;
    }

    pub fn typed(dialect: Dialect) bool {
        const result = dialect != .javascript;

        if (result) assert(dialect == .typescript or dialect == .tsx);

        return result;
    }

    pub fn name(dialect: Dialect) []const u8 {
        const result: []const u8 = switch (dialect) {
            .javascript => "javascript",
            .tsx => "tsx",
            .typescript => "typescript",
        };

        assert(result.len > 0);

        return result;
    }

    pub fn of_extension(extension: []const u8) ?Dialect {
        assert(extension.len <= std.math.maxInt(u32));

        const language = Language.of_extension(extension) orelse return null;
        const marked = std.mem.eql(u8, extension, "tsx");

        if (marked) assert(language == .typescript);

        return switch (language) {
            .javascript => .javascript,
            .typescript => if (marked) .tsx else .typescript,
            else => null,
        };
    }

    pub fn of_language(language: Language) Dialect {
        assert(language == .javascript or language == .typescript);

        const result: Dialect = if (language == .javascript) .javascript else .typescript;

        assert(result.typed() == (language == .typescript));

        return result;
    }
};

test "a dialect reads its extension" {
    try std.testing.expectEqual(Dialect.typescript, Dialect.of_extension("ts").?);
    try std.testing.expectEqual(Dialect.typescript, Dialect.of_extension("mts").?);
    try std.testing.expectEqual(Dialect.tsx, Dialect.of_extension("tsx").?);
    try std.testing.expectEqual(Dialect.javascript, Dialect.of_extension("js").?);
    try std.testing.expectEqual(null, Dialect.of_extension("py"));
    try std.testing.expectEqualStrings("tsx", Dialect.tsx.name());
    try std.testing.expect(Dialect.of_language(.typescript).typed());
    try std.testing.expect(!Dialect.of_language(.javascript).typed());
    try std.testing.expect(Dialect.of_extension("tsx").?.is_tsx());
    try std.testing.expect(Dialect.javascript.allows_jsx());
    try std.testing.expect(!Dialect.typescript.allows_jsx());
}
