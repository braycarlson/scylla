const std = @import("std");
const assert = std.debug.assert;
const oracle = @import("oracle.zig");
const Residue = oracle.Residue;
const Row = oracle.Row;

pub const Golden = struct {
    ast: std.ArrayList(Row),
    scopes: std.ArrayList(Scope),
    text: []const u8,

    pub fn deinit(held: *Golden, gpa: std.mem.Allocator) void {
        assert(held.ast.items.len <= held.text.len);
        assert(held.scopes.items.len <= held.text.len);

        held.scopes.deinit(gpa);
        held.ast.deinit(gpa);
        gpa.free(held.text);
        held.* = undefined;
    }
};

pub const Scope = struct {
    kind: []const u8,
    name: []const u8,
    line: u32,
    symbols: []const u8,

    pub fn less_than(context: void, left: Scope, right: Scope) bool {
        _ = context;

        assert(left.kind.len > 0);
        assert(right.kind.len > 0);

        return left.order(right) == .lt;
    }

    pub fn order(left: Scope, right: Scope) std.math.Order {
        assert(left.kind.len <= std.math.maxInt(u32));
        assert(right.kind.len <= std.math.maxInt(u32));

        const by_kind = std.mem.order(u8, left.kind, right.kind);
        const by_name = std.mem.order(u8, left.name, right.name);

        if (by_kind != .eq) return by_kind;
        if (by_name != .eq) return by_name;
        if (left.line != right.line) return std.math.order(left.line, right.line);
        return std.mem.order(u8, left.symbols, right.symbols);
    }
};

const Number = struct {
    value: u32,
    after: usize,
};

const Quoted = struct {
    text: []const u8,
    after: usize,
};

const ast_key = "\"ast\":[";
const golden_bytes_max = 1 << 28;
const path_bytes_max = 4096;
const residue_bytes_max = 1 << 24;
const scopes_key = "\"scopes\":[";

pub fn residue_of(
    gpa: std.mem.Allocator,
    name: []const u8,
    categories: []const []const u8,
) !Residue {
    assert(name.len > 0);

    var path_buffer: [path_bytes_max]u8 = undefined;
    const path = try std.mem.print(&path_buffer, "tests/{s}", .{name});

    assert(categories.len > 0);

    const text = read(gpa, path, residue_bytes_max) catch |err| switch (err) {
        error.FileNotFound => return .{ .fixtures = .empty, .text = &.{} },
        else => return err,
    };

    var residue: Residue = .{ .fixtures = .empty, .text = text };
    errdefer residue.deinit(gpa);

    var offset: usize = 0;
    var fixture: []const u8 = "";

    while (offset < text.len) {
        const key = quoted(text, offset) orelse break;
        const value = quoted(text, key.after) orelse break;

        assert(value.after > offset);

        offset = value.after;

        if (std.mem.eql(u8, key.text, "fixture")) {
            fixture = value.text;
        } else if (std.mem.eql(u8, key.text, "category")) {
            if (category_matches(categories, value.text)) {
                try residue.fixtures.append(gpa, fixture);
            }
        } else {}
    }

    assert(residue.fixtures.items.len <= text.len);

    return residue;
}

pub fn golden(
    gpa: std.mem.Allocator,
    root: []const u8,
    name: []const u8,
    held: *Golden,
) !bool {
    assert(root.len > 0);
    assert(name.len > 0);

    var path_buffer: [path_bytes_max]u8 = undefined;
    const path = try std.mem.print(&path_buffer, "{s}/{s}.json", .{ root, name });

    const text = read(gpa, path, golden_bytes_max) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };

    const ast_start = std.mem.find(u8, text, ast_key);
    const scopes_start = std.mem.find(u8, text, scopes_key);

    held.* = .{ .ast = .empty, .scopes = .empty, .text = text };
    errdefer held.deinit(gpa);

    if (ast_start) |start| try rows(gpa, text, start + ast_key.len, &held.ast);
    if (scopes_start) |start| try scopes(gpa, text, start + scopes_key.len, &held.scopes);

    assert(held.ast.items.len <= text.len);
    assert(held.scopes.items.len <= text.len);

    return true;
}

fn read(gpa: std.mem.Allocator, path: []const u8, limit: u32) ![]u8 {
    assert(path.len > 0);
    assert(limit < std.math.maxInt(u32));

    const text = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        path,
        gpa,
        .limited(limit),
    );

    assert(text.len < limit);

    return text;
}

fn category_matches(categories: []const []const u8, category: []const u8) bool {
    assert(categories.len > 0);
    assert(categories[0].len > 0);
    assert(category.len <= std.math.maxInt(u32));

    for (categories) |held| {
        if (std.mem.eql(u8, held, category)) return true;
    }

    return false;
}

fn scopes(
    gpa: std.mem.Allocator,
    text: []u8,
    start: usize,
    found: *std.ArrayList(Scope),
) !void {
    assert(start < std.math.maxInt(u32));

    var offset = start;

    assert(found.items.len == 0);
    assert(offset <= text.len);

    while (offset < text.len) {
        if (text[offset] != '[') break;

        const kind = quoted(text, offset) orelse break;
        const name = quoted(text, kind.after) orelse break;
        const line = number(text, name.after);
        const symbols = quoted(text, line.after) orelse break;

        try found.append(gpa, .{
            .kind = kind.text,
            .name = name.text,
            .line = line.value,
            .symbols = symbols.text,
        });

        assert(symbols.after > offset);

        offset = symbols.after;
        offset = separated(text, offset) orelse break;
    }
}

fn rows(
    gpa: std.mem.Allocator,
    text: []u8,
    start: usize,
    found: *std.ArrayList(Row),
) !void {
    assert(start < std.math.maxInt(u32));

    var offset = start;

    assert(found.items.len == 0);
    assert(offset <= text.len);

    while (offset < text.len) {
        if (text[offset] != '[') break;

        const name = quoted(text, offset) orelse break;
        const first = number(text, name.after);
        const second = number(text, first.after);

        try found.append(gpa, .{ .name = name.text, .offset = first.value, .end = second.value });

        assert(second.after > offset);

        offset = second.after;
        offset = separated(text, offset) orelse break;
    }
}

fn separated(text: []const u8, from: usize) ?usize {
    assert(from <= text.len);

    var offset = from;
    const closed = offset < text.len and text[offset] == ']';

    if (closed) offset += 1;

    const comma = offset < text.len and text[offset] == ',';
    if (!comma) return null;

    assert(offset < text.len);
    assert(text[offset] == ',');

    return offset + 1;
}

fn number(text: []const u8, from: usize) Number {
    assert(from <= text.len);

    var offset = from;
    var value: u32 = 0;

    while (offset < text.len) : (offset += 1) {
        if (std.ascii.isDigit(text[offset])) break;
    }

    while (offset < text.len) : (offset += 1) {
        if (!std.ascii.isDigit(text[offset])) break;

        value = value * 10 + (text[offset] - '0');
    }

    assert(offset >= from);
    assert(offset <= text.len);

    return .{ .value = value, .after = offset };
}

fn quoted(text: []u8, from: usize) ?Quoted {
    assert(text.len <= std.math.maxInt(u32));
    assert(from < std.math.maxInt(u32));

    const open = std.mem.findScalarPos(u8, text, from, '"') orelse return null;
    var read_at: usize = open + 1;
    var write_at: usize = open + 1;

    assert(open >= from);

    while (read_at < text.len) {
        const byte = text[read_at];

        assert(write_at <= read_at);

        read_at += 1;

        if (byte == '"') return .{ .text = text[open + 1 .. write_at], .after = read_at };

        const escaped = byte == '\\' and read_at < text.len;

        if (escaped) {
            text[write_at] = text[read_at];
            write_at += 1;
            read_at += 1;

            continue;
        }

        text[write_at] = byte;
        write_at += 1;
    }

    return null;
}

test "a golden reads its rows and its scopes" {
    const gpa = std.testing.allocator;

    const source = "{\"ast\":[[\"Module\",0,9],[\"Name\",1,8]],\"scopes\":" ++
        "[[\"module\",\"top\",0,\"a:gl\"],[\"class\",\"C\\\"\",2,\"b:l\"]]}";

    const text = try gpa.dupe(u8, source);
    defer gpa.free(text);

    var found: std.ArrayList(Row) = .empty;
    defer found.deinit(gpa);

    var held: std.ArrayList(Scope) = .empty;
    defer held.deinit(gpa);

    try scopes(gpa, text, std.mem.find(u8, text, scopes_key).? + scopes_key.len, &held);
    try rows(gpa, text, ast_key.len + 1, &found);

    try std.testing.expectEqual(@as(usize, 2), found.items.len);
    try std.testing.expectEqualStrings("Name", found.items[1].name);
    try std.testing.expectEqual(@as(u32, 8), found.items[1].end);
    try std.testing.expectEqual(@as(usize, 2), held.items.len);
    try std.testing.expectEqualStrings("C\"", held.items[1].name);
    try std.testing.expectEqualStrings("b:l", held.items[1].symbols);
    try std.testing.expectEqual(@as(u32, 2), held.items[1].line);
}
