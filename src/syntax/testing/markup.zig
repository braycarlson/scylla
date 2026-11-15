const std = @import("std");
const assert = std.debug.assert;
const corpus = @import("../../testing/corpus.zig");
const markup = @import("../markup.zig");
const RawTextTag = markup.Vocabulary.RawTextTag;

const Fixture = struct {
    errors: []const Row,
    name: []const u8,
    source: []const u8,
    tokens: []const Row,
    tree: []const Row,
};

const Fixtures = struct {
    arena: std.heap.ArenaAllocator,
    files: corpus.Files,
    items: []const Fixture,

    pub fn deinit(fixtures: *Fixtures, gpa: std.mem.Allocator) void {
        assert(fixtures.items.len == fixtures.files.slice().len);

        fixtures.files.deinit(gpa);
        fixtures.arena.deinit();
        fixtures.* = undefined;
    }
};

const Row = struct {
    name: []const u8,
    offset: u32,
    end: u32,
};

const Quoted = struct {
    text: []const u8,
    after: usize,
};

pub const raw_text_tags = [_]RawTextTag{
    .{ .body = .text, .end = "endverbatim", .name = "verbatim", .stage = .lexer },
};

const fixture_root = "tests/fixtures/templates";
const golden_bytes_max: u32 = 1 << 26;
const golden_root = "tests/fixtures/golden";
const path_bytes_max: u32 = 4096;
const residue_bytes_max: u32 = 1 << 24;
const source_bytes_max: u32 = 1 << 28;

pub const vocabulary: markup.Vocabulary = .{
    .dialect = .html,
    .end_prefix = null,
    .extends_tags = &.{},
    .intermediate_words = &.{},
    .only_word = null,
    .raw_text_tags = &raw_text_tags,
    .specifications = &.{},
    .template_imports = &.{},
};

pub fn fixtures_read(gpa: std.mem.Allocator) !Fixtures {
    var files = try corpus.collect(gpa, fixture_root, source_bytes_max, template_selected);
    errdefer files.deinit(gpa);

    if (files.slice().len == 0) {
        std.debug.print("no fixture templates under {s}\n", .{fixture_root});

        return error.FixturesMissing;
    }

    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();

    const allocator = arena.allocator();
    const items = try allocator.alloc(Fixture, files.slice().len);

    for (files.slice(), items) |file, *item| {
        item.* = try fixture_of(allocator, file);
    }

    assert(items.len == files.slice().len);

    return .{ .arena = arena, .files = files, .items = items };
}

pub fn template_selected(basename: []const u8) bool {
    assert(basename.len > 0);

    return std.mem.endsWith(u8, basename, ".html");
}

pub fn residue_read(arena: std.mem.Allocator, name: []const u8) !std.ArrayList([]const u8) {
    assert(name.len <= std.math.maxInt(u32));

    var path_buffer: [path_bytes_max]u8 = undefined;
    const path = try std.mem.print(&path_buffer, "tests/{s}", .{name});
    const limit: std.Io.Limit = .limited(residue_bytes_max);
    var names: std.ArrayList([]const u8) = .empty;

    const text = std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, arena, limit) catch |err| {
        switch (err) {
            error.FileNotFound => return names,
            else => return err,
        }
    };

    var offset: usize = 0;

    while (offset < text.len) {
        const key = quoted(text, offset) orelse break;

        offset = key.after;

        if (!std.mem.eql(u8, key.text, "fixture")) continue;

        const value = quoted(text, offset) orelse break;

        try names.append(arena, value.text);
        offset = value.after;
    }

    assert(offset <= text.len);

    return names;
}

fn quoted(text: []const u8, from: usize) ?Quoted {
    assert(text.len <= std.math.maxInt(u32));
    assert(from < std.math.maxInt(u32));

    const open = std.mem.findScalarPos(u8, text, from, '"') orelse return null;
    const close = std.mem.findScalarPos(u8, text, open + 1, '"') orelse return null;

    assert(open < close);

    return .{ .text = text[open + 1 .. close], .after = close + 1 };
}

fn fixture_of(arena: std.mem.Allocator, file: corpus.File) !Fixture {
    assert(std.mem.endsWith(u8, file.name, ".html"));

    var path_buffer: [path_bytes_max]u8 = undefined;
    const stem = file.name[0 .. file.name.len - ".html".len];
    const path = try std.mem.print(&path_buffer, "{s}/{s}.json", .{ golden_root, stem });
    const limit: std.Io.Limit = .limited(golden_bytes_max);
    const text = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, arena, limit);
    const value = try std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{});
    if (value != .object) return error.GoldenMalformed;

    const object = value.object;
    const errors = if (object.get("errors")) |held| try rows_of(arena, held) else &.{};
    const tokens = if (object.get("tokens")) |held| try rows_of(arena, held) else &.{};
    const tree = if (object.get("tree")) |held| try rows_of(arena, held) else &.{};

    return .{
        .errors = errors,
        .name = file.name,
        .source = file.source,
        .tokens = tokens,
        .tree = tree,
    };
}

fn rows_of(arena: std.mem.Allocator, value: std.json.Value) ![]const Row {
    if (value != .array) return error.GoldenMalformed;

    const rows = try arena.alloc(Row, value.array.items.len);

    for (value.array.items, rows) |item, *row| {
        if (item != .array) return error.GoldenMalformed;

        const fields = item.array.items;
        if (fields.len < 2) return error.GoldenMalformed;
        if (fields[0] != .string) return error.GoldenMalformed;

        const offset = try number_of(fields[1]);
        const end = if (fields.len > 2) try number_of(fields[2]) else offset;

        row.* = .{ .name = fields[0].string, .offset = offset, .end = end };
    }

    assert(rows.len == value.array.items.len);

    return rows;
}

fn number_of(value: std.json.Value) !u32 {
    if (value != .integer) return error.GoldenMalformed;
    return std.math.cast(u32, value.integer) orelse error.GoldenMalformed;
}
