const std = @import("std");
const assert = std.debug.assert;
const Hygiene = @import("../testing/hygiene.zig");
const Source = Hygiene.Source;
const partitions = @import("../testing/partitions.zig").partitions;

const Found = struct {
    count: u32 = 0,
    lines: [found_count_max]u32 = undefined,

    fn add(found: *Found, line: u32) void {
        assert(line > 0);

        if (found.count < found_count_max) found.lines[found.count] = line;

        found.count += 1;
    }

    fn slice(found: *const Found) []const u32 {
        const stored = @min(found.count, found_count_max);

        assert(stored <= found.lines.len);

        return found.lines[0..stored];
    }
};

const options: Hygiene.Options = .{
    .banned = &.{
        "std.debug." ++ "assert(",
        "Self = " ++ "@This()",
        "== " ++ "error.",
        "!= " ++ "error.",
    },
    .layers = &.{
        .{ .imports = &.{}, .name = "testing" },
        .{ .imports = &.{"testing"}, .name = "stdx" },
        .{ .imports = &.{ "stdx", "testing" }, .name = "text" },
        .{ .imports = &.{ "stdx", "testing", "text" }, .name = "syntax" },
        .{ .imports = &.{ "stdx", "syntax", "testing", "text" }, .name = "format" },
        .{ .imports = &.{ "stdx", "syntax", "testing", "text" }, .name = "outline" },
        .{ .imports = &.{ "stdx", "testing", "text" }, .name = "platform" },
        .{ .imports = &.{ "platform", "stdx", "testing", "text" }, .name = "cli" },
        .{ .imports = &.{ "platform", "stdx", "testing", "text" }, .name = "lsp" },
        .{
            .imports = &.{ "cli", "platform", "stdx", "syntax", "testing", "text" },
            .name = "lint",
        },
        .{ .imports = &.{ "stdx", "syntax", "testing", "text" }, .name = "index" },
    },
    .entry_points = &.{
        "examples/parse.zig",
        "src/fuzz_tests.zig",
        "src/guard_probe.zig",
        "src/harness/format_tests.zig",
        "src/parity.zig",
        "src/unit_tests.zig",
    },
    .test_roots = &.{
        "src/harness/format_tests.zig",
        "src/unit_tests.zig",
    },
};

const found_count_max = 1_024;
const import_count_max = Hygiene.import_count_max;
const line_count_max = Hygiene.line_count_max;
const path_bytes_max = 512;
const source_bytes_max = Hygiene.source_bytes_max;
const test_name_bytes_max = 1_024;

comptime {
    assert(path_bytes_max + "test_".len + 20 <= test_name_bytes_max);
}

test "tidy" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var sources = try Hygiene.sources_read(gpa, io, options.source_directories);
    defer Hygiene.sources_free(gpa, &sources);

    var problems: u32 = 0;

    for (sources.items) |source| {
        problems += try Hygiene.file_check(gpa, source, &options);
        problems += try tree_check(gpa, source);
    }

    problems += try Hygiene.graph_check(gpa, sources.items, &options);
    problems += try Hygiene.layering_check(gpa, sources.items, &options);
    problems += partitions_check(sources.items);

    try std.testing.expectEqual(0, problems);
}

test "every category projection names each kind" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var sources = try Hygiene.sources_read(gpa, io, options.source_directories);
    defer Hygiene.sources_free(gpa, &sources);

    var checked: u32 = 0;
    var problems: u32 = 0;

    for (sources.items) |source| {
        if (!std.mem.endsWith(u8, source.path, "/kind.zig")) continue;

        checked += 1;
        problems += projection_check(source);
    }

    try std.testing.expect(checked > 0);
    try std.testing.expectEqual(0, problems);
}

test "a cleanup is followed by a blank line" {
    const source =
        \\fn spaced() void {
        \\    const first = acquire();
        \\    defer release(first);
        \\
        \\    use(first);
        \\}
        \\
        \\fn crowded() !void {
        \\    const first = acquire();
        \\    defer release(first);
        \\    const second = try acquire();
        \\    errdefer release(second);
        \\    use(second);
        \\}
        \\
        \\fn grouped() void {
        \\    defer if (ready()) {
        \\        release(0);
        \\    } else {
        \\        release(1);
        \\    };
        \\    errdefer release(2);
        \\    defer {
        \\        release(3);
        \\    }
        \\}
    ;

    const found = try found_in(source, cleanup_lines);

    try std.testing.expectEqualSlices(u32, &.{ 10, 12 }, found.slice());
}

test "bitwise and arithmetic operators do not mix without parentheses" {
    const source =
        \\const confusing = 1 + value << 3;
        \\const grouped = 1 + (value << 3);
        \\const masked = (value & 0xff) - 1;
        \\const shifted = value >> 2 * 3;
        \\const plain = value * 2 + 1;
    ;

    const found = try found_in(source, precedence_lines);

    try std.testing.expectEqualSlices(u32, &.{ 1, 4 }, found.slice());
}

test "a type function name ends in Type" {
    const source =
        \\fn ListType(comptime T: type) type {
        \\    return []T;
        \\}
        \\
        \\fn List(comptime T: type) type {
        \\    return []T;
        \\}
        \\
        \\fn list_of(comptime T: type) type {
        \\    return []T;
        \\}
        \\
        \\fn length(items: []const u8) u32 {
        \\    return @intCast(items.len);
        \\}
        \\
        \\const Callback = *const fn (u32) void;
    ;

    const found = try found_in(source, type_name_lines);

    try std.testing.expectEqualSlices(u32, &.{ 5, 9 }, found.slice());
}

test "every test lands in exactly one test partition" {
    var buffer: [test_name_bytes_max]u8 = undefined;
    var anonymous: u32 = 0;
    const named = test_name_of(&buffer, "syntax.go.parse", "test \"a b\" {", &anonymous).?;

    try std.testing.expectEqualStrings("syntax.go.parse.test.a b", named);
    try std.testing.expectEqual(1, partition_count(named));

    const unnamed = test_name_of(&buffer, "format.stream", "test {", &anonymous).?;

    try std.testing.expectEqualStrings("format.stream.test_0", unnamed);
    try std.testing.expectEqual(1, partition_count(unnamed));
    try std.testing.expectEqual(1, anonymous);
    try std.testing.expectEqual(0, partition_count("nowhere.test.a"));
    try std.testing.expectEqual(2, partition_count("platform.watch.test.syntax.go. names"));
    const declaration = test_name_of(&buffer, "platform", "const a = 1;", &anonymous);

    try std.testing.expectEqual(null, declaration);
}

fn projection_check(source: Source) u32 {
    assert(std.mem.endsWith(u8, source.path, "/kind.zig"));

    var problems: u32 = 0;
    var number: u32 = 0;
    var reading = false;
    var lines = std.mem.splitScalar(u8, source.text, '\n');

    while (lines.next()) |line| {
        number += 1;

        assert(number <= line_count_max);

        const trimmed = std.mem.trimStart(u8, line, " ");
        const projection_head = "pub fn category(kind: Kind) Category {";
        const token_head = "pub fn token_kind(kind: Kind) Token.Kind {";
        const projection = std.mem.startsWith(u8, trimmed, projection_head);
        const projected = std.mem.startsWith(u8, trimmed, token_head);
        const table = std.mem.startsWith(u8, trimmed, "fn categories_of() ");
        const opens = projection or projected or table;

        if (opens) {
            reading = true;

            continue;
        }

        if (!reading) continue;

        const closed = std.mem.eql(u8, line, "    }") or std.mem.eql(u8, line, "}");

        if (closed) {
            reading = false;

            continue;
        }

        const wildcard = std.mem.startsWith(u8, trimmed, "else =>") or
            std.mem.find(u8, line, "initFill(") != null;

        if (wildcard) {
            std.debug.print("{s}:{d}: a category projection carries a wildcard\n", .{
                source.path,
                number,
            });

            problems += 1;
        }
    }

    if (reading) {
        std.debug.print("{s}: a category projection is left unclosed\n", .{source.path});

        problems += 1;
    }

    return problems;
}

fn tree_check(gpa: std.mem.Allocator, source: Source) !u32 {
    assert(source.path.len > 0);

    var ast = try std.zig.Ast.parse(gpa, source.text, .{ .mode = .zig, .recover = true });
    defer ast.deinit(gpa);

    var cleanup: Found = .{};
    var precedence: Found = .{};
    var type_names: Found = .{};

    cleanup_lines(&ast, &cleanup);
    precedence_lines(&ast, &precedence);
    type_name_lines(&ast, &type_names);

    var problems: u32 = 0;

    problems += found_report(source.path, &cleanup, "the cleanup is not followed by a blank line");
    problems += found_report(source.path, &precedence, "the operators mix bitwise and arithmetic");
    problems += found_report(source.path, &type_names, "the type function does not end in Type");

    return problems;
}

fn found_report(path: []const u8, found: *const Found, problem: []const u8) u32 {
    assert(path.len > 0);
    assert(problem.len > 0);

    for (found.slice()) |line| std.debug.print("{s}:{d}: {s}\n", .{ path, line, problem });

    return found.count;
}

fn cleanup_lines(ast: *const std.zig.Ast, found: *Found) void {
    const tags = ast.tokens.items(.tag);

    assert(tags.len > 0);
    assert(tags[tags.len - 1] == .eof);

    for (tags, 0..) |tag, index| {
        const cleanup = tag == .keyword_defer or tag == .keyword_errdefer;
        if (!cleanup) continue;

        const end = cleanup_end(tags, index) orelse continue;
        const next = end + 1;

        const closed = switch (tags[next]) {
            .eof, .keyword_defer, .keyword_errdefer, .r_brace => true,
            else => false,
        };

        if (closed) continue;

        const between = ast.source[ast.tokenStart(@intCast(end))..ast.tokenStart(@intCast(next))];
        if (std.mem.count(u8, between, "\n") > 1) continue;

        found.add(@intCast(ast.tokenLocation(0, @intCast(end)).line + 1));
    }
}

fn cleanup_end(tags: []const std.zig.Token.Tag, cleanup: usize) ?usize {
    assert(cleanup + 1 < tags.len);
    assert(tags[tags.len - 1] == .eof);

    var depth: u32 = 0;

    for (tags[cleanup + 1 ..], cleanup + 1..) |tag, index| {
        switch (tag) {
            .l_brace, .l_bracket, .l_paren => depth += 1,
            .r_brace, .r_bracket, .r_paren => {
                if (depth == 0) return null;

                depth -= 1;
            },
            .eof => return null,
            else => {},
        }

        if (depth > 0) continue;

        switch (tag) {
            .semicolon => return index,
            .r_brace => switch (tags[index + 1]) {
                .keyword_else => continue,
                .semicolon => {
                    assert(index + 1 < tags.len);

                    return index + 1;
                },
                else => return index,
            },
            else => {},
        }
    }

    unreachable;
}

fn precedence_lines(ast: *const std.zig.Ast, found: *Found) void {
    assert(ast.nodes.len > 0);

    for (0..ast.nodes.len) |index| {
        const node: std.zig.Ast.Node.Index = @fromBackingInt(@intCast(index));
        const tag = ast.nodeTag(node);
        const operator = is_bitwise(tag) or is_arithmetic(tag);
        if (!operator) continue;

        const left, const right = ast.nodeData(node).node_and_node;

        for ([_]std.zig.Ast.Node.Index{ left, right }) |child| {
            if (!operators_mix(tag, ast.nodeTag(child))) continue;

            found.add(@intCast(ast.tokenLocation(0, ast.firstToken(node)).line + 1));
        }
    }
}

fn operators_mix(parent: std.zig.Ast.Node.Tag, child: std.zig.Ast.Node.Tag) bool {
    if (parent == .root) return false;
    if (child == .root) return false;
    if (is_bitwise(parent)) return is_arithmetic(child);
    if (is_arithmetic(parent)) return is_bitwise(child);
    return false;
}

fn is_bitwise(tag: std.zig.Ast.Node.Tag) bool {
    if (tag == .root) return false;

    return switch (tag) {
        .bit_and, .bit_or, .bit_xor, .shl, .shl_sat, .shr => true,
        else => false,
    };
}

fn is_arithmetic(tag: std.zig.Ast.Node.Tag) bool {
    if (tag == .root) return false;

    return switch (tag) {
        .add, .add_sat, .add_wrap, .div, .mod => true,
        .mul, .mul_sat, .mul_wrap, .sub, .sub_sat, .sub_wrap => true,
        else => false,
    };
}

fn type_name_lines(ast: *const std.zig.Ast, found: *Found) void {
    assert(ast.nodes.len > 0);

    for (0..ast.nodes.len) |index| {
        const node: std.zig.Ast.Node.Index = @fromBackingInt(@intCast(index));
        if (ast.nodeTag(node) != .fn_decl) continue;

        var buffer: [1]std.zig.Ast.Node.Index = undefined;

        const prototype = ast.fullFnProto(&buffer, ast.nodeData(node).node_and_node[0]) orelse {
            continue;
        };

        const name_token = prototype.name_token orelse continue;
        const name = ast.tokenSlice(name_token);
        const typed = Hygiene.returns_a_type(ast, node) or std.ascii.isUpper(name[0]);
        if (!typed) continue;
        if (type_named(name)) continue;

        found.add(@intCast(ast.tokenLocation(0, name_token).line + 1));
    }
}

fn type_named(name: []const u8) bool {
    assert(name.len > 0);

    if (!std.ascii.isUpper(name[0])) return false;
    return std.mem.endsWith(u8, name, "Type");
}

fn found_in(source: [:0]const u8, comptime find: fn (*const std.zig.Ast, *Found) void) !Found {
    assert(source.len <= source_bytes_max);

    const gpa = std.testing.allocator;
    var ast = try std.zig.Ast.parse(gpa, source, .{ .mode = .zig, .recover = true });
    defer ast.deinit(gpa);

    var found: Found = .{};

    assert(ast.errors.len == 0);

    find(&ast, &found);

    return found;
}

fn partitions_check(sources: []const Source) u32 {
    assert(sources.len <= std.math.maxInt(u32));

    var problems: u32 = 0;

    for (sources) |source| {
        if (!std.mem.startsWith(u8, source.path, "src/")) continue;
        if (!Hygiene.declares_tests(source.text)) continue;

        problems += partitions_of(source);
    }

    return problems;
}

fn partitions_of(source: Source) u32 {
    assert(std.mem.endsWith(u8, source.path, ".zig"));

    var namespace_buffer: [path_bytes_max]u8 = undefined;
    const namespace = namespace_of(&namespace_buffer, source.path);
    var lines = std.mem.splitScalar(u8, source.text, '\n');
    var number: u32 = 0;
    var anonymous: u32 = 0;
    var problems: u32 = 0;

    while (lines.next()) |line| {
        number += 1;

        assert(number <= line_count_max);

        var name_buffer: [test_name_bytes_max]u8 = undefined;
        const declared = std.mem.trimStart(u8, line, " ");
        const name = test_name_of(&name_buffer, namespace, declared, &anonymous) orelse continue;
        const count = partition_count(name);
        if (count == 1) continue;

        std.debug.print("{s}:{d}: the test lands in {d} test partitions\n", .{
            source.path,
            number,
            count,
        });

        problems += 1;
    }

    return problems;
}

fn namespace_of(buffer: *[path_bytes_max]u8, path: []const u8) []const u8 {
    assert(path.len <= std.math.maxInt(u32));

    const relative = path["src/".len .. path.len - ".zig".len];

    assert(relative.len <= buffer.len);

    @memcpy(buffer[0..relative.len], relative);
    std.mem.replaceScalar(u8, buffer[0..relative.len], '/', '.');

    return buffer[0..relative.len];
}

fn test_name_of(
    buffer: *[test_name_bytes_max]u8,
    namespace: []const u8,
    declared: []const u8,
    anonymous: *u32,
) ?[]const u8 {
    if (!std.mem.startsWith(u8, declared, "test ")) return null;
    assert(namespace.len <= std.math.maxInt(u32));

    const rest = std.mem.trimStart(u8, declared["test ".len..], " ");

    if (std.mem.startsWith(u8, rest, "{")) {
        defer anonymous.* += 1;

        return std.mem.print(buffer, "{s}.test_{d}", .{ namespace, anonymous.* }) catch unreachable;
    }

    if (std.mem.startsWith(u8, rest, "\"")) {
        const end = std.mem.findScalarPos(u8, rest, 1, '"') orelse return null;
        const description = rest[1..end];

        return std.mem.print(buffer, "{s}.test.{s}", .{ namespace, description }) catch null;
    }

    const end = std.mem.findAny(u8, rest, " {") orelse return null;
    return std.mem.print(buffer, "{s}.decltest.{s}", .{ namespace, rest[0..end] }) catch null;
}

fn partition_count(name: []const u8) u32 {
    assert(name.len <= std.math.maxInt(u32));

    var count: u32 = 0;

    for (partitions) |partition| {
        for (partition.filters) |filter| {
            if (std.mem.find(u8, name, filter) == null) continue;

            count += 1;

            break;
        }
    }

    assert(count <= partitions.len);

    return count;
}
