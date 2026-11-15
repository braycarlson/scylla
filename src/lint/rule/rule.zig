const std = @import("std");
const assert = std.debug.assert;
const Applicability = @import("../fixes.zig").Applicability;
const Severity = @import("../diagnostics.zig").Severity;

citations: []const Citation,
code: []const u8,
default_on: bool,
description: []const u8,
explanation: []const u8,
fix_title: []const u8,
fixable: Fixable,
group: Group,
name: []const u8,
severity: Severity,
summary: []const u8,
url: []const u8,

const Rule = @This();

pub const Citation = struct {
    standard: []const u8,
    text: []const u8,
};

pub const Fixable = enum {
    always,
    never,
    sometimes,

    fn applicability(fixable: Fixable) Applicability {
        const result: Applicability = switch (fixable) {
            .always, .sometimes => .safe,
            .never => .display_only,
        };

        if (fixable.is_offered()) assert(result == .safe);

        return result;
    }

    fn is_offered(fixable: Fixable) bool {
        return switch (fixable) {
            .always, .sometimes => true,
            .never => false,
        };
    }

    fn name(fixable: Fixable) []const u8 {
        const text: []const u8 = switch (fixable) {
            .always => "always",
            .never => "never",
            .sometimes => "sometimes",
        };

        assert(text.len > 0);

        return text;
    }
};

pub const Group = enum {
    deprecated,
    preview,
    removed,
    stable,

    pub fn name(group: Group) []const u8 {
        const text: []const u8 = switch (group) {
            .deprecated => "deprecated",
            .preview => "preview",
            .removed => "removed",
            .stable => "stable",
        };

        assert(text.len > 0);

        return text;
    }
};

pub const code_text_bytes_max: u32 = 8;
pub const name_bytes_max: u32 = 64;

comptime {
    assert(code_text_bytes_max <= std.math.maxInt(u8));
    assert(code_text_bytes_max < name_bytes_max);
}

pub fn is_preview(held: *const Rule) bool {
    assert(held.code.len > 0);
    assert(held.name.len > 0);

    return held.group == .preview;
}

test Rule {
    const held: Rule = .{
        .citations = &.{.{ .standard = "TigerStyle", .text = "Put a limit on everything." }},
        .code = "TS002",
        .default_on = true,
        .description = "Checks for a loop without a bound.",
        .explanation = "",
        .fix_title = "",
        .fixable = .never,
        .group = .preview,
        .name = "bounded-loops",
        .severity = .warning,
        .summary = "Checks for a loop without a bound.",
        .url = "",
    };

    try std.testing.expect(held.is_preview());
    try std.testing.expectEqualStrings("preview", held.group.name());
    try std.testing.expect(held.code.len <= code_text_bytes_max);
}

test "each fixable names itself" {
    try std.testing.expectEqualStrings("always", Fixable.always.name());
    try std.testing.expectEqualStrings("never", Fixable.never.name());
    try std.testing.expectEqualStrings("sometimes", Fixable.sometimes.name());
    try std.testing.expectEqualStrings("preview", Group.preview.name());
    try std.testing.expectEqual(Applicability.safe, Fixable.sometimes.applicability());
    try std.testing.expectEqual(Applicability.display_only, Fixable.never.applicability());
}
