const std = @import("std");
const assert = std.debug.assert;
const Span = @import("../stdx/bounded/span.zig");
const camel_of = @import("category.zig").camel_of;

pub const Diagnostic = struct {
    expected: ?u16,
    found: ?u16,
    kind: Kind,
    span: Span,

    pub const Kind = enum(u8) {
        depth_exceeded,
        expected_block,
        expected_colon,
        expected_equal,
        expected_expression,
        expected_identifier,
        expected_import,
        expected_in,
        expected_type,
        unexpected_dedent,
        unexpected_indent,
        unexpected_token,
        unmatched_bracket,

        pub fn is_indentation(kind: Kind) bool {
            return switch (kind) {
                .expected_block, .unexpected_dedent, .unexpected_indent => true,
                .depth_exceeded,
                .expected_colon,
                .expected_equal,
                .expected_expression,
                .expected_identifier,
                .expected_import,
                .expected_in,
                .expected_type,
                .unexpected_token,
                .unmatched_bracket,
                => false,
            };
        }

        pub fn message(kind: Kind) []const u8 {
            const text: []const u8 = switch (kind) {
                .depth_exceeded => "Nesting too deep",
                .expected_block => "Expected an indented block",
                .expected_colon => "Expected ':'",
                .expected_equal => "Expected '='",
                .expected_expression => "Expected an expression",
                .expected_identifier => "Expected an identifier",
                .expected_import => "Expected 'import'",
                .expected_in => "Expected 'in'",
                .expected_type => "Expected a type",
                .unexpected_dedent => "Unindent does not match any outer indentation level",
                .unexpected_indent => "Unexpected indentation",
                .unexpected_token => "Unexpected token",
                .unmatched_bracket => "Unmatched closing bracket",
            };

            assert(text.len > 0);
            assert(std.ascii.isUpper(text[0]));
            assert(text[text.len - 1] != '.');

            return text;
        }

        pub fn name(kind: Kind) []const u8 {
            const text: []const u8 = switch (kind) {
                inline else => |tag| comptime camel_of(@tagName(tag)),
            };

            assert(text.len > 0);
            assert(std.ascii.isUpper(text[0]));

            return text;
        }
    };

    pub fn expected_kind(held: Diagnostic, comptime Grammar: type) ?Grammar {
        assert(held.span.length <= std.math.maxInt(u32) - held.span.offset);

        const code = held.expected orelse return null;
        const kind = Grammar.of_u16(code).?;

        assert(kind.is_token());

        return kind;
    }

    pub fn found_kind(held: Diagnostic, comptime Grammar: type) ?Grammar {
        assert(held.span.length <= std.math.maxInt(u32) - held.span.offset);

        const code = held.found orelse return null;
        const kind = Grammar.of_u16(code).?;

        assert(kind.is_token());

        return kind;
    }

    pub const Names = struct {
        expected: ?[]const u8 = null,
        found: ?[]const u8 = null,
    };

    pub fn message_write(
        held: Diagnostic,
        out: *std.Io.Writer,
        names: Names,
    ) std.Io.Writer.Error!void {
        if (names.expected != null) assert(held.expected != null);
        if (names.found != null) assert(held.found != null);

        const expected = if (held.kind == .unexpected_token) names.expected else null;

        if (expected) |name| {
            try out.print("Expected {s}", .{name});
        } else {
            try out.writeAll(held.kind.message());
        }

        if (held.found == null) return out.writeAll(", found end of file");

        if (names.found) |name| try out.print(", found {s}", .{name});
    }
};

comptime {
    assert(@sizeOf(Diagnostic) == 20);
    assert(@typeInfo(Diagnostic.Kind).@"enum".field_names.len == 13);
}

test "a syntax error renders what it expected and what it found" {
    var buffer: [64]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buffer);

    const colon: Diagnostic = .{
        .expected = 3,
        .found = 5,
        .kind = .expected_colon,
        .span = .empty,
    };

    const brace: Diagnostic = .{
        .expected = 3,
        .found = 5,
        .kind = .unexpected_token,
        .span = .empty,
    };

    const ended: Diagnostic = .{
        .expected = null,
        .found = null,
        .kind = .expected_expression,
        .span = .empty,
    };

    try colon.message_write(&out, .{ .expected = "colon", .found = "newline" });
    try std.testing.expectEqualStrings("Expected ':', found newline", out.buffered());

    out = .fixed(&buffer);

    try brace.message_write(&out, .{ .expected = "brace_open", .found = "identifier" });
    try std.testing.expectEqualStrings("Expected brace_open, found identifier", out.buffered());

    out = .fixed(&buffer);

    try ended.message_write(&out, .{});
    try std.testing.expectEqualStrings("Expected an expression, found end of file", out.buffered());
}

test "a syntax error kind names itself and carries a message" {
    try std.testing.expectEqualStrings("DepthExceeded", Diagnostic.Kind.depth_exceeded.name());
    try std.testing.expectEqualStrings("UnexpectedToken", Diagnostic.Kind.unexpected_token.name());
    try std.testing.expectEqualStrings("Expected ':'", Diagnostic.Kind.expected_colon.message());

    try std.testing.expectEqualStrings(
        "Unmatched closing bracket",
        Diagnostic.Kind.unmatched_bracket.message(),
    );
}
