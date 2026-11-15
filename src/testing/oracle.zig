const std = @import("std");
const assert = std.debug.assert;

pub const Golden = struct {
    ast: std.ArrayList(Row),
    broken: bool,
    invalid: ?u32,
    rejected: ?u32,
    text: []const u8,

    pub fn deinit(held: *Golden, gpa: std.mem.Allocator) void {
        assert(held.ast.items.len <= held.text.len);
        assert(held.ast.items.len <= held.ast.capacity);

        held.ast.deinit(gpa);
        gpa.free(held.text);
        held.* = undefined;
    }
};

pub const Residue = struct {
    fixtures: std.ArrayList([]const u8),
    text: []const u8,

    pub fn contains(residue: *const Residue, name: []const u8) bool {
        assert(residue.fixtures.items.len <= residue.text.len);
        assert(name.len > 0);

        for (residue.fixtures.items) |held| {
            if (std.mem.eql(u8, held, name)) return true;
        }

        return false;
    }

    pub fn deinit(residue: *Residue, gpa: std.mem.Allocator) void {
        assert(residue.fixtures.items.len <= residue.text.len);
        assert(residue.fixtures.items.len <= residue.fixtures.capacity);

        residue.fixtures.deinit(gpa);
        gpa.free(residue.text);
        residue.* = undefined;
    }
};

pub const Row = struct {
    name: []const u8,
    offset: u32,
    end: u32,

    pub fn less_than(context: void, left: Row, right: Row) bool {
        _ = context;
        assert(left.name.len > 0);
        assert(right.name.len > 0);

        return left.order(right) == .lt;
    }

    pub fn order(left: Row, right: Row) std.math.Order {
        assert(left.name.len > 0);
        assert(right.name.len > 0);

        const by_name = std.mem.order(u8, left.name, right.name);
        if (by_name != .eq) return by_name;
        if (left.offset != right.offset) return std.math.order(left.offset, right.offset);
        return std.math.order(left.end, right.end);
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

const golden_bytes_max = 1 << 28;
const path_bytes_max = 4096;
const residue_bytes_max = 1 << 24;

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

    held.* = .{
        .ast = .empty,
        .broken = std.mem.find(u8, text, "\"broken\":true") != null,
        .invalid = offset_of(text, "\"invalid\":"),
        .rejected = offset_of(text, "\"rejected\":"),
        .text = text,
    };

    errdefer held.deinit(gpa);

    try rows(gpa, text, "\"ast\":[", &held.ast);

    assert(held.ast.items.len <= held.text.len);

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

fn rows(
    gpa: std.mem.Allocator,
    text: []const u8,
    key: []const u8,
    found: *std.ArrayList(Row),
) !void {
    assert(text.len <= std.math.maxInt(u32));
    assert(key.len <= std.math.maxInt(u32));

    const start = std.mem.find(u8, text, key) orelse return;
    var offset = start + key.len;

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

        const closed = offset < text.len and text[offset] == ']';

        if (closed) offset += 1;

        const separated = offset < text.len and text[offset] == ',';
        if (!separated) break;

        offset += 1;
    }
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

fn offset_of(text: []const u8, key: []const u8) ?u32 {
    assert(text.len <= std.math.maxInt(u32));
    assert(key.len <= std.math.maxInt(u32));

    const found = std.mem.find(u8, text, key) orelse return null;
    const start = found + key.len;

    assert(key.len > 0);

    assert(start <= text.len);

    if (start == text.len) return null;
    if (!std.ascii.isDigit(text[start])) return null;
    return number(text, start).value;
}

fn quoted(text: []const u8, from: usize) ?Quoted {
    assert(text.len <= std.math.maxInt(u32));
    assert(from < std.math.maxInt(u32));

    const open = std.mem.findScalarPos(u8, text, from, '"') orelse return null;
    const close = std.mem.findScalarPos(u8, text, open + 1, '"') orelse return null;

    assert(open >= from);
    assert(close > open);

    return .{ .text = text[open + 1 .. close], .after = close + 1 };
}

test "a golden reads its rows, its flags, and its offsets" {
    const text = "{\"ast\":[[\"root\",0,9],[\"fn_decl\",1,8]],\"invalid\":4,\"rejected\":null}";
    var found: std.ArrayList(Row) = .empty;
    defer found.deinit(std.testing.allocator);

    try rows(std.testing.allocator, text, "\"ast\":[", &found);

    try std.testing.expectEqual(@as(usize, 2), found.items.len);
    try std.testing.expectEqualStrings("fn_decl", found.items[1].name);
    try std.testing.expectEqual(@as(u32, 8), found.items[1].end);
    try std.testing.expectEqual(@as(?u32, 4), offset_of(text, "\"invalid\":"));
    try std.testing.expectEqual(@as(?u32, null), offset_of(text, "\"rejected\":"));
}
