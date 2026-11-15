const std = @import("std");
const assert = std.debug.assert;
const ArrayType = @import("../../stdx/bounded/array.zig").ArrayType;
const EventsType = @import("../../syntax/tree.zig").EventsType;
const Index = @import("../../text/line_index.zig").LineIndex;
const Kind = @import("../../syntax/python/kind.zig").Kind;
const Parser = @import("../../syntax/python/parse.zig").Parser;
const Span = @import("../../stdx/bounded/span.zig");
const Structure = @import("../../syntax/tree.zig").Structure;
const Tokens = @import("../../syntax/tokens.zig");
const TreeType = @import("../../syntax/tree.zig").TreeType;
const raw_of = @import("../../syntax/raw.zig").raw_of;
const edit = @import("edit.zig");
const imports = @import("imports.zig");
const lex = @import("../../syntax/python/lex.zig").lex;
const style = @import("../../syntax/python/style.zig");
const Deletion = edit.Deletion;
const Events = EventsType(Kind);
const Tree = TreeType(Kind);

const Fixture = struct {
    events: Events,
    index: Index,
    parser: Parser,
    raw: ArrayType(Kind),
    source: []const u8,
    tokens: Tokens,
    tree: Tree,

    fn create(gpa: std.mem.Allocator, source: []const u8) !*Fixture {
        assert(source.len <= std.math.maxInt(u32));

        const fixture = try gpa.create(Fixture);
        errdefer gpa.destroy(fixture);

        try fixture.events.init(gpa, event_count_max);
        errdefer fixture.events.deinit(gpa);

        fixture.index = try .init(gpa, line_count_max);
        errdefer fixture.index.deinit(gpa);

        fixture.raw = try .init(gpa, token_count_max);
        errdefer fixture.raw.deinit(gpa);

        fixture.tokens = try .init(gpa, token_count_max);
        errdefer fixture.tokens.deinit(gpa);

        fixture.tree = try .init(gpa, node_count_max, diagnostic_count_max);
        errdefer fixture.tree.deinit(gpa);

        fixture.source = source;

        try fixture.build();

        return fixture;
    }

    fn destroy(fixture: *Fixture, gpa: std.mem.Allocator) void {
        fixture.tree.deinit(gpa);
        fixture.tokens.deinit(gpa);
        fixture.raw.deinit(gpa);
        fixture.index.deinit(gpa);
        fixture.events.deinit(gpa);
        gpa.destroy(fixture);
    }

    fn build(fixture: *Fixture) !void {
        try lex(fixture.source, &fixture.tokens);
        try raw_of(Kind, fixture.tokens.slice(), &fixture.raw);

        const structure = fixture.parser.build(
            fixture.source,
            fixture.tokens.slice(),
            fixture.raw.const_slice(),
            &fixture.events,
            &fixture.tree,
        );

        try std.testing.expectEqual(Structure.complete, structure);
        try fixture.index.build(fixture.source);
    }

    fn first(fixture: *const Fixture, kind: Kind) ?u32 {
        assert(kind.is_node());

        return fixture.nth(kind, 0);
    }

    fn nth(fixture: *const Fixture, kind: Kind, position: u32) ?u32 {
        assert(kind.is_node());

        var seen: u32 = 0;

        for (fixture.tree.slice(), 0..) |node, index| {
            if (node.kind != kind) continue;

            if (seen == position) {
                assert(index < fixture.tree.slice().len);

                return @intCast(index);
            }

            seen += 1;
        }

        return null;
    }

    fn text(fixture: *const Fixture, span: Span) []const u8 {
        assert(span.end() <= fixture.source.len);

        return span.text(fixture.source);
    }

    fn deletion(fixture: *const Fixture, statement: u32) Deletion {
        assert(statement < std.math.maxInt(u32));

        return edit.statement_deletion(
            fixture.source,
            fixture.tokens.slice(),
            &fixture.tree,
            statement,
            &fixture.index,
        );
    }

    fn alias_removal(fixture: *const Fixture, statement: u32, position: u32) Deletion {
        assert(statement < std.math.maxInt(u32));
        assert(position < std.math.maxInt(u32));

        return edit.alias_removal(
            fixture.source,
            fixture.tokens.slice(),
            &fixture.tree,
            statement,
            position,
            &fixture.index,
        );
    }

    fn argument_removal(fixture: *const Fixture, call: u32, position: u32) []const u8 {
        assert(call < std.math.maxInt(u32));
        assert(position < std.math.maxInt(u32));

        const span = edit.argument_removal(fixture.tokens.slice(), &fixture.tree, call, position);
        return fixture.text(span);
    }

    fn expect_shown(
        fixture: *const Fixture,
        held: Deletion,
        replaced: bool,
        expected: []const u8,
    ) !void {
        if (held == .remove) assert(held.remove.end() <= fixture.source.len);
        if (held == .replace) assert(held.replace.end() <= fixture.source.len);

        const span = switch (held) {
            .remove => |span| span,
            .replace => |span| span,
        };

        try std.testing.expectEqual(replaced, held == .replace);
        try std.testing.expectEqualStrings(expected, fixture.text(span));
    }
};

const diagnostic_count_max: u32 = 1 << 8;
const event_count_max: u32 = 1 << 16;
const line_count_max: u32 = 1 << 12;
const node_count_max: u32 = 1 << 14;
const token_count_max: u32 = 1 << 14;

fn expect_deletion(
    source: []const u8,
    kind: Kind,
    position: u32,
    replaced: bool,
    expected: []const u8,
) !void {
    assert(source.len <= std.math.maxInt(u32));
    assert(position < std.math.maxInt(u32));
    assert(expected.len <= std.math.maxInt(u32));
    assert(kind.is_node());

    const fixture = try Fixture.create(std.testing.allocator, source);
    defer fixture.destroy(std.testing.allocator);

    const statement = fixture.nth(kind, position).?;

    try fixture.expect_shown(fixture.deletion(statement), replaced, expected);
}

test "the only statement of a block is replaced rather than removed" {
    try expect_deletion("def read():\n    value = 1\n", .assign, 0, true, "value = 1");
}

test "a statement that owns its line takes the whole line with it" {
    const source = "def read():\n    value = 1\n    return 2\n";

    try expect_deletion(source, .assign, 0, false, "    value = 1\n");
}

test "a statement with a trailing comment still takes the whole line" {
    const source = "def read():\n    value = 1  # keep\n    return 2\n";

    try expect_deletion(source, .assign, 0, false, "    value = 1  # keep\n");
}

test "a statement after a semicolon leaves the semicolon standing" {
    const source = "def read():\n    a = 1; b = 2\n    return a\n";

    try expect_deletion(source, .assign, 1, false, "b = 2");
}

test "a statement between two semicolons takes the one after it" {
    try expect_deletion("x = 1; import os; y = 2\n", .import, 0, false, "import os; ");
}

test "the only statement of an inline block is replaced" {
    try expect_deletion("if x: value = 1\n", .assign, 0, true, "value = 1");
}

test "a statement on a carriage return line feed line takes both bytes" {
    try expect_deletion("import os\r\nvalue = 1\r\n", .import, 0, false, "import os\r\n");
}

test "a statement before a semicolon takes the semicolon after it" {
    const source = "def read():\n    a = 1; b = 2\n    return b\n";

    try expect_deletion(source, .assign, 0, false, "a = 1; ");
}

test "a statement spanning several lines takes every one of them" {
    const source = "def read():\n    value = [\n        1,\n    ]\n    return 2\n";
    const fixture = try Fixture.create(std.testing.allocator, source);
    defer fixture.destroy(std.testing.allocator);

    const statement = fixture.first(.assign).?;
    const held = fixture.deletion(statement);

    try std.testing.expect(held != .replace);
    try fixture.expect_shown(held, false, "    value = [\n        1,\n    ]\n");
}

test "removing a leading alias takes the comma after it" {
    const fixture = try Fixture.create(std.testing.allocator, "import os, sys\n");
    defer fixture.destroy(std.testing.allocator);

    const statement = fixture.first(.import).?;

    try fixture.expect_shown(fixture.alias_removal(statement, 0), false, "os, ");
}

test "removing a trailing alias takes the comma before it" {
    const fixture = try Fixture.create(std.testing.allocator, "import os, sys\n");
    defer fixture.destroy(std.testing.allocator);

    const statement = fixture.first(.import).?;

    try fixture.expect_shown(fixture.alias_removal(statement, 1), false, ", sys");
}

test "removing the only alias removes the statement" {
    const fixture = try Fixture.create(std.testing.allocator, "import os\nvalue = 1\n");
    defer fixture.destroy(std.testing.allocator);

    const statement = fixture.first(.import).?;

    try fixture.expect_shown(fixture.alias_removal(statement, 0), false, "import os\n");
}

test "removing an argument takes the comma on the side it has one" {
    const fixture = try Fixture.create(std.testing.allocator, "read(first, second, third)\n");
    defer fixture.destroy(std.testing.allocator);

    const call = fixture.first(.call).?;

    try std.testing.expectEqualStrings("first, ", fixture.argument_removal(call, 0));
    try std.testing.expectEqualStrings("second, ", fixture.argument_removal(call, 1));
    try std.testing.expectEqualStrings(", third", fixture.argument_removal(call, 2));
}

test "removing the only argument takes the argument alone" {
    const fixture = try Fixture.create(std.testing.allocator, "read(first)\n");
    defer fixture.destroy(std.testing.allocator);

    const call = fixture.first(.call).?;

    try std.testing.expectEqualStrings("first", fixture.argument_removal(call, 0));
}

test "a replacement fits up to the width and not past it" {
    const fixture = try Fixture.create(std.testing.allocator, "value = read()\n");
    defer fixture.destroy(std.testing.allocator);

    const span: Span = .{ .offset = 8, .length = 6 };

    try std.testing.expect(edit.fits(fixture.source, &fixture.index, span, 6, 14, 4));
    try std.testing.expect(!edit.fits(fixture.source, &fixture.index, span, 7, 14, 4));
}

test "a tab counts the width a caller gives it" {
    const fixture = try Fixture.create(std.testing.allocator, "def read():\n\tvalue = 1\n");
    defer fixture.destroy(std.testing.allocator);

    const span: Span = .{ .offset = 21, .length = 1 };

    try std.testing.expectEqualStrings("1", fixture.text(span));
    try std.testing.expect(edit.fits(fixture.source, &fixture.index, span, 1, 13, 4));
    try std.testing.expect(!edit.fits(fixture.source, &fixture.index, span, 1, 12, 4));
}

test "a replacement that would fuse with a keyword asks for a space" {
    const fixture = try Fixture.create(std.testing.allocator, "def read():\n    return(1)\n");
    defer fixture.destroy(std.testing.allocator);

    const span: Span = .{ .offset = 22, .length = 3 };
    const expected: edit.Padding = .{ .after = false, .before = true };

    try std.testing.expectEqualStrings("(1)", fixture.text(span));
    try std.testing.expectEqual(expected, edit.padding(fixture.source, span, "1"));
}

test "a replacement that would fuse with a number asks for a space after" {
    const fixture = try Fixture.create(std.testing.allocator, "value = 1 if read else 2\n");
    defer fixture.destroy(std.testing.allocator);

    const span: Span = .{ .offset = 8, .length = 1 };
    const seam: Span = .{ .offset = 9, .length = 1 };
    const neither: edit.Padding = .{ .after = false, .before = false };
    const both: edit.Padding = .{ .after = true, .before = true };

    try std.testing.expectEqualStrings("1", fixture.text(span));
    try std.testing.expectEqual(neither, edit.padding(fixture.source, span, "1"));
    try std.testing.expectEqual(both, edit.padding(fixture.source, seam, "x"));
}

test "a byte of a multi byte character counts as a word byte" {
    const source = "caf\u{e9}";
    const span: Span = .{ .offset = 5, .length = 0 };
    const expected: edit.Padding = .{ .after = false, .before = true };

    try std.testing.expectEqual(expected, edit.padding(source, span, "x"));
}

test "a replacement between punctuation asks for nothing" {
    const fixture = try Fixture.create(std.testing.allocator, "value = (1)\n");
    defer fixture.destroy(std.testing.allocator);

    const span: Span = .{ .offset = 9, .length = 1 };
    const expected: edit.Padding = .{ .after = false, .before = false };

    try std.testing.expectEqual(expected, edit.padding(fixture.source, span, "2"));
}

test "a tab indented file reads as tab indented" {
    const source = "def read():\n\tvalue = 1\n\treturn value\n";
    const fixture = try Fixture.create(std.testing.allocator, source);
    defer fixture.destroy(std.testing.allocator);

    const found = style.detect(fixture.source, fixture.tokens.slice());

    try std.testing.expect(found.indent_tabs);
    try std.testing.expectEqual(1, found.indent_width);
    try std.testing.expectEqual(.line_feed, found.line_ending);
    try std.testing.expectEqual(.double, found.quote);
}

test "a two space file with single quotes reads as both" {
    const fixture = try Fixture.create(std.testing.allocator, "def read():\r\n  return 'text'\r\n");
    defer fixture.destroy(std.testing.allocator);

    const found = style.detect(fixture.source, fixture.tokens.slice());

    try std.testing.expect(!found.indent_tabs);
    try std.testing.expectEqual(2, found.indent_width);
    try std.testing.expectEqual(.carriage_return_line_feed, found.line_ending);
    try std.testing.expectEqual(.single, found.quote);
}

test "a file with no block at all reads as four spaces" {
    const fixture = try Fixture.create(std.testing.allocator, "value = 1\n");
    defer fixture.destroy(std.testing.allocator);

    const found = style.detect(fixture.source, fixture.tokens.slice());

    try std.testing.expect(!found.indent_tabs);
    try std.testing.expectEqual(4, found.indent_width);
    try std.testing.expectEqual(0, found.indent.length);
}

test "a mixed indent is kept byte for byte" {
    const fixture = try Fixture.create(std.testing.allocator, "def read():\n  \tvalue = 1\n");
    defer fixture.destroy(std.testing.allocator);

    const found = style.detect(fixture.source, fixture.tokens.slice());

    try std.testing.expect(!found.indent_tabs);
    try std.testing.expectEqual(3, found.indent_width);
    try std.testing.expectEqualStrings("  \t", fixture.text(found.indent));
}

test "an empty file reads as the defaults" {
    const found = style.detect("", &.{});

    try std.testing.expect(!found.indent_tabs);
    try std.testing.expectEqual(4, found.indent_width);
    try std.testing.expectEqual(.line_feed, found.line_ending);
    try std.testing.expectEqual(.double, found.quote);
}

test "a comment only file reads as the defaults with its own ending" {
    const fixture = try Fixture.create(std.testing.allocator, "# only a comment\r\n");
    defer fixture.destroy(std.testing.allocator);

    const found = style.detect(fixture.source, fixture.tokens.slice());

    try std.testing.expect(!found.indent_tabs);
    try std.testing.expectEqual(4, found.indent_width);
    try std.testing.expectEqual(.carriage_return_line_feed, found.line_ending);
    try std.testing.expectEqual(.double, found.quote);
}

fn expect_insertion(source: []const u8, leading: u32, offset: u32) !void {
    assert(source.len <= std.math.maxInt(u32));

    const fixture = try Fixture.create(std.testing.allocator, source);
    defer fixture.destroy(std.testing.allocator);

    const held = imports.insertion_point(fixture.tokens.slice(), &fixture.tree, &fixture.index);

    try std.testing.expectEqual(leading, held.leading);
    try std.testing.expectEqual(offset, held.offset);
}

test "an import goes under the last import of the first block" {
    try expect_insertion("\"doc\"\n\nimport os\nimport sys\n\nvalue = 1\n", 0, 28);
}

test "an import goes under the docstring when the file has no import" {
    try expect_insertion("\"doc\"\n\nvalue = 1\n", 1, 6);
}

test "an import goes to the head of a file with neither" {
    try expect_insertion("value = 1\n", 0, 0);
}

test "the raw kinds stay beside the tokens the tree indexes" {
    const fixture = try Fixture.create(std.testing.allocator, "value = 1\n");
    defer fixture.destroy(std.testing.allocator);

    try std.testing.expectEqual(fixture.tokens.slice().len, fixture.raw.count());
}
