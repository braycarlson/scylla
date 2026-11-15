const std = @import("std");
const assert = std.debug.assert;
const bounded = @import("../stdx/bounded.zig");
const Buffer = bounded.Buffer;
const FileID = @import("../stdx/file_id.zig").FileID;
const Random = @import("../testing/random.zig");
const Span = bounded.Span;
const StaticAllocator = @import("../stdx/static_allocator.zig");

arena: Buffer,
items: bounded.ArrayType(Diagnostic),
overflowed: bool,
related: bounded.ArrayType(Related),

const Diagnostics = @This();

pub const Capacity = struct {
    related_count_max: u32,
    row_count_max: u32,
    text_bytes_max: u32,
};

pub const CapacityError = error{ RelatedExhausted, RowsExhausted };

pub const Severity = enum(u8) {
    hint,
    information,
    warning,
    @"error",

    pub fn azure_kind(severity: Severity) []const u8 {
        return switch (severity) {
            .@"error" => "error",
            .hint, .information, .warning => "warning",
        };
    }

    pub fn github_level(severity: Severity) []const u8 {
        return switch (severity) {
            .@"error" => "error",
            .hint, .information => "notice",
            .warning => "warning",
        };
    }

    pub fn gitlab_severity(severity: Severity) []const u8 {
        return switch (severity) {
            .@"error" => "major",
            .hint, .information => "info",
            .warning => "minor",
        };
    }

    pub fn lsp_code(severity: Severity) i64 {
        const code: i64 = switch (severity) {
            .@"error" => 1,
            .hint => 4,
            .information => 3,
            .warning => 2,
        };

        assert(code >= 1);
        assert(code <= 4);

        return code;
    }

    pub fn name(severity: Severity) []const u8 {
        const text: []const u8 = switch (severity) {
            .@"error" => "error",
            .hint => "hint",
            .information => "info",
            .warning => "warning",
        };

        assert(text.len > 0);

        return text;
    }

    pub fn of(text: []const u8) ?Severity {
        assert(text.len <= std.math.maxInt(u32));

        if (std.ascii.eqlIgnoreCase(text, "error")) return .@"error";
        if (std.ascii.eqlIgnoreCase(text, "warn")) return .warning;
        if (std.ascii.eqlIgnoreCase(text, "warning")) return .warning;
        if (std.ascii.eqlIgnoreCase(text, "info")) return .information;
        if (std.ascii.eqlIgnoreCase(text, "information")) return .information;
        if (std.ascii.eqlIgnoreCase(text, "hint")) return .hint;
        return null;
    }

    pub fn rank(severity: Severity) u8 {
        const value = @backingInt(severity);

        assert(value <= @backingInt(Severity.@"error"));

        return value;
    }

    pub fn rdjson_severity(severity: Severity) []const u8 {
        return switch (severity) {
            .@"error" => "ERROR",
            .hint, .information => "INFO",
            .warning => "WARNING",
        };
    }

    pub fn sarif_level(severity: Severity) []const u8 {
        return switch (severity) {
            .@"error" => "error",
            .hint, .information => "note",
            .warning => "warning",
        };
    }
};

pub const Message = union(enum) {
    arena: Span,
    static: []const u8,
};

pub const Diagnostic = struct {
    code: []const u8,
    fix: ?u32 = null,
    message: Message,
    related_count: u32 = 0,
    related_start: u32 = 0,
    rule: ?u32 = null,
    severity: Severity,
    span: Span,

    fn is_fixed(diagnostic: *const Diagnostic) bool {
        assert(diagnostic.code.len > 0);

        return diagnostic.fix != null;
    }
};

pub const Related = struct {
    file: FileID,
    message: Message,
    span: Span,
};

pub const message_unwritten = "the finding message did not fit";

pub fn init(gpa: std.mem.Allocator, sizes: Capacity) std.mem.Allocator.Error!Diagnostics {
    assert(sizes.related_count_max > 0);
    assert(sizes.row_count_max > 0);
    assert(sizes.text_bytes_max > 0);

    var arena = try Buffer.init(gpa, sizes.text_bytes_max);
    errdefer arena.deinit(gpa);

    var items = try bounded.ArrayType(Diagnostic).init(gpa, sizes.row_count_max);
    errdefer items.deinit(gpa);

    const related = try bounded.ArrayType(Related).init(gpa, sizes.related_count_max);
    return .{ .arena = arena, .items = items, .overflowed = false, .related = related };
}

pub fn deinit(diagnostics: *Diagnostics, gpa: std.mem.Allocator) void {
    assert(diagnostics.items.count() <= diagnostics.items.capacity());
    assert(diagnostics.related.count() <= diagnostics.related.capacity());

    diagnostics.arena.deinit(gpa);
    diagnostics.items.deinit(gpa);
    diagnostics.related.deinit(gpa);
    diagnostics.* = undefined;
}

fn at(diagnostics: *const Diagnostics, row_index: u32) Diagnostic {
    assert(row_index < diagnostics.items.count());

    return diagnostics.items.get(row_index);
}

pub fn attach(diagnostics: *Diagnostics, row_index: u32, fix_index: ?u32) void {
    assert(row_index < diagnostics.count());
    if (fix_index) |held| assert(held < std.math.maxInt(u32));

    diagnostics.items.slice()[row_index].fix = fix_index;

    assert(diagnostics.items.get(row_index).fix == fix_index);
}

pub fn capacity(diagnostics: *const Diagnostics) u32 {
    const held = diagnostics.items.capacity();

    assert(held > 0);
    assert(diagnostics.items.count() <= held);

    return held;
}

pub fn clear(diagnostics: *Diagnostics) void {
    diagnostics.arena.clear();
    diagnostics.items.clear();
    diagnostics.overflowed = false;

    diagnostics.related.clear();

    assert(diagnostics.count() == 0);
    assert(!diagnostics.is_overflowed());
}

pub fn count(diagnostics: *const Diagnostics) u32 {
    const held = diagnostics.items.count();

    assert(held <= diagnostics.items.capacity());
    assert(diagnostics.related.count() <= diagnostics.related.capacity());

    return held;
}

pub fn empty(diagnostics: *const Diagnostics) bool {
    assert(diagnostics.items.capacity() > 0);
    assert(diagnostics.items.count() <= diagnostics.items.capacity());

    return diagnostics.items.empty();
}

pub fn is_overflowed(diagnostics: *const Diagnostics) bool {
    assert(diagnostics.items.count() <= diagnostics.items.capacity());
    assert(diagnostics.related.count() <= diagnostics.related.capacity());

    return diagnostics.overflowed;
}

pub fn message_of(diagnostics: *const Diagnostics, diagnostic: *const Diagnostic) []const u8 {
    assert(diagnostic.code.len > 0);

    const text = diagnostics_message_text(diagnostics, diagnostic.message);

    if (diagnostic.message == .arena) assert(text.len <= diagnostics.arena.count());

    return text;
}

pub fn slice(diagnostics: *const Diagnostics) []const Diagnostic {
    const rows = diagnostics.items.const_slice();

    assert(rows.len <= diagnostics.items.capacity());
    if (rows.len > 0) assert(rows[0].code.len > 0);

    return rows;
}

pub fn push(diagnostics: *Diagnostics, diagnostic: Diagnostic) CapacityError!void {
    assert(diagnostic.code.len > 0);

    if (diagnostics.items.full()) {
        diagnostics.overflowed = true;

        return error.RowsExhausted;
    }

    const row_count_before = diagnostics.items.count();

    diagnostics.items.push(diagnostic);

    assert(diagnostics.items.count() == row_count_before + 1);
}

fn push_formatted(
    diagnostics: *Diagnostics,
    code: []const u8,
    severity: Severity,
    span: Span,
    fix_index: ?u32,
    comptime format: []const u8,
    arguments: anytype,
) CapacityError!void {
    assert(code.len > 0);
    if (fix_index) |held| assert(held < std.math.maxInt(u32));
    comptime assert(format.len > 0);
    comptime assert(@typeInfo(@TypeOf(arguments)) == .@"struct");

    try diagnostics.push_formatted_row(.{
        .code = code,
        .fix = fix_index,
        .message = .{ .static = "" },
        .related_count = 0,
        .related_start = 0,
        .rule = null,
        .severity = severity,
        .span = span,
    }, format, arguments);
}

pub fn push_formatted_row(
    diagnostics: *Diagnostics,
    row: Diagnostic,
    comptime format: []const u8,
    arguments: anytype,
) CapacityError!void {
    comptime assert(format.len > 0);
    assert(row.code.len > 0);
    comptime assert(@typeInfo(@TypeOf(arguments)) == .@"struct");

    var held = row;

    if (arena_written(&diagnostics.arena, format, arguments)) |span| {
        held.message = .{ .arena = span };
    } else {
        held.message = .{ .static = message_unwritten };
    }

    try diagnostics.push(held);
}

pub fn push_related(diagnostics: *Diagnostics, related: Related) CapacityError!void {
    if (related.message == .arena) assert(related.message.arena.end() <= diagnostics.arena.count());

    if (diagnostics.related.full()) {
        diagnostics.overflowed = true;

        return error.RelatedExhausted;
    }

    const related_count_before = diagnostics.related.count();

    diagnostics.related.push(related);

    assert(diagnostics.related.count() == related_count_before + 1);
}

pub fn push_related_formatted(
    diagnostics: *Diagnostics,
    file: FileID,
    span: Span,
    comptime format: []const u8,
    arguments: anytype,
) CapacityError!void {
    comptime assert(format.len > 0);
    comptime assert(@typeInfo(@TypeOf(arguments)) == .@"struct");

    var message: Message = .{ .static = message_unwritten };

    if (arena_written(&diagnostics.arena, format, arguments)) |held| {
        message = .{ .arena = held };
    }

    if (message == .arena) assert(message.arena.end() <= diagnostics.arena.count());

    try diagnostics.push_related(.{ .file = file, .message = message, .span = span });
}

pub fn related_count(diagnostics: *const Diagnostics) u32 {
    const held = diagnostics.related.count();

    assert(held <= diagnostics.related.capacity());

    return held;
}

pub fn related_message_of(diagnostics: *const Diagnostics, related: *const Related) []const u8 {
    const text = diagnostics_message_text(diagnostics, related.message);

    if (related.message == .arena) assert(text.len <= diagnostics.arena.count());

    return text;
}

pub fn related_of(diagnostics: *const Diagnostics, diagnostic: *const Diagnostic) []const Related {
    const start: u64 = diagnostic.related_start;
    const stop: u64 = start + diagnostic.related_count;

    assert(stop <= diagnostics.related.count());

    const rows = diagnostics.related.const_slice()[@intCast(start)..@intCast(stop)];

    assert(rows.len == diagnostic.related_count);

    return rows;
}

fn retain(
    diagnostics: *Diagnostics,
    context: anytype,
    comptime keep: fn (@TypeOf(context), *const Diagnostic) bool,
) void {
    comptime assert(@typeInfo(@TypeOf(context)) == .pointer or @TypeOf(context) == void);

    const rows = diagnostics.items.slice();
    var written: u32 = 0;

    for (rows) |held| {
        if (!keep(context, &held)) continue;

        rows[written] = held;
        written += 1;
    }

    assert(written <= rows.len);

    diagnostics.items.truncate(written);
}

pub fn sort(diagnostics: *Diagnostics) void {
    const rows = diagnostics.items.slice();

    assert(rows.len <= diagnostics.items.capacity());

    std.sort.block(Diagnostic, rows, {}, diagnostics_sort_less);

    if (rows.len < 2) return;

    for (rows[1..], 0..) |held, row_index| {
        assert(!diagnostics_sort_less({}, held, rows[row_index]));
    }
}

fn diagnostics_sort_less(context: void, left: Diagnostic, right: Diagnostic) bool {
    _ = context;

    assert(left.code.len > 0);
    assert(right.code.len > 0);

    if (left.span.offset != right.span.offset) return left.span.offset < right.span.offset;
    return std.mem.order(u8, left.code, right.code) == .lt;
}

fn diagnostics_message_text(diagnostics: *const Diagnostics, message: Message) []const u8 {
    if (message == .arena) assert(message.arena.end() <= diagnostics.arena.count());

    switch (message) {
        .arena => |span| {
            assert(span.end() <= diagnostics.arena.count());

            return span.text(diagnostics.arena.const_slice());
        },
        .static => |text| return text,
    }
}

fn arena_written(arena: *Buffer, comptime format: []const u8, arguments: anytype) ?Span {
    comptime assert(format.len > 0);
    comptime assert(@typeInfo(@TypeOf(arguments)) == .@"struct");

    const offset = arena.count();

    assert(offset <= arena.capacity());

    arena.print(format, arguments) catch |err| switch (err) {
        error.Overflow => return null,
    };

    const length = arena.flatten(offset);

    assert(arena.count() == offset + length);

    return .{ .offset = offset, .length = length };
}

const test_capacity: Capacity = .{
    .related_count_max = 8,
    .row_count_max = 8,
    .text_bytes_max = 1 << 12,
};

fn test_related_row(offset: u32) Related {
    assert(offset < std.math.maxInt(u32));

    return .{
        .file = FileID.of(0),
        .message = .{ .static = "declared here" },
        .span = .{ .length = 1, .offset = offset },
    };
}

fn test_row(code: []const u8, offset: u32, fix_index: ?u32) Diagnostic {
    assert(code.len <= std.math.maxInt(u32));
    assert(offset < std.math.maxInt(u32));
    if (fix_index) |held| assert(held < std.math.maxInt(u32));

    return .{
        .code = code,
        .fix = fix_index,
        .message = .{ .static = "a recorded finding" },
        .related_count = 0,
        .related_start = 0,
        .rule = null,
        .severity = .warning,
        .span = .{ .length = 1, .offset = offset },
    };
}

fn test_even_offset(context: void, held: *const Diagnostic) bool {
    _ = context;

    return held.span.offset % 2 == 0;
}

test Diagnostics {
    const gpa = std.testing.allocator;

    var diagnostics: Diagnostics = try .init(gpa, .{
        .related_count_max = 4,
        .row_count_max = 4,
        .text_bytes_max = 256,
    });

    defer diagnostics.deinit(gpa);

    try diagnostics.push(.{
        .code = "TS002",
        .message = .{ .static = "the loop has no bound" },
        .severity = .warning,
        .span = .{ .length = 5, .offset = 12 },
    });

    const row: Diagnostic = .{
        .code = "TS001",
        .message = .{ .static = "" },
        .severity = .@"error",
        .span = .{ .length = 3, .offset = 0 },
    };

    try diagnostics.push_formatted_row(row, "the function takes {d} parameters", .{9});

    diagnostics.sort();

    const rows = diagnostics.slice();

    try std.testing.expectEqual(@as(u32, 2), diagnostics.count());
    try std.testing.expectEqualStrings("TS001", rows[0].code);

    try std.testing.expectEqualStrings(
        "the function takes 9 parameters",
        diagnostics.message_of(&rows[0]),
    );

    try std.testing.expectEqualStrings("the loop has no bound", diagnostics.message_of(&rows[1]));
    try std.testing.expect(!diagnostics.is_overflowed());
}

test "every severity maps to each vocabulary" {
    try std.testing.expectEqualStrings("warning", Severity.hint.azure_kind());
    try std.testing.expectEqualStrings("notice", Severity.information.github_level());
    try std.testing.expectEqualStrings("minor", Severity.warning.gitlab_severity());
    try std.testing.expectEqualStrings("ERROR", Severity.@"error".rdjson_severity());
    try std.testing.expectEqualStrings("note", Severity.hint.sarif_level());
}

test "a diagnostic owns the related rows it names" {
    const gpa = std.testing.allocator;
    var diagnostics = try Diagnostics.init(gpa, test_capacity);
    defer diagnostics.deinit(gpa);

    try std.testing.expectEqual(@as(u32, 0), diagnostics.related_count());
    try diagnostics.push_related(test_related_row(4));
    try diagnostics.push_related(test_related_row(8));

    var row = test_row("TS001", 0, null);

    row.related_count = 2;
    row.related_start = 0;

    try diagnostics.push(row);

    const held = diagnostics.at(0);
    const related = diagnostics.related_of(&held);

    try std.testing.expectEqual(@as(usize, 2), related.len);
    try std.testing.expectEqual(@as(u32, 4), related[0].span.offset);
    try std.testing.expectEqual(@as(u32, 8), related[1].span.offset);

    try std.testing.expectEqualStrings(
        "declared here",
        diagnostics.related_message_of(&related[0]),
    );
}

test "a formatted row keeps the related run it named" {
    const gpa = std.testing.allocator;
    var diagnostics = try Diagnostics.init(gpa, test_capacity);
    defer diagnostics.deinit(gpa);

    try diagnostics.push_related(test_related_row(4));

    var row = test_row("TS001", 0, null);

    row.related_count = 1;
    row.related_start = 0;

    try diagnostics.push_formatted_row(row, "names {s}", .{"one"});

    const held = diagnostics.at(0);

    try std.testing.expectEqualStrings("names one", diagnostics.message_of(&held));
    try std.testing.expectEqual(@as(usize, 1), diagnostics.related_of(&held).len);
}

test "a diagnostic naming no related row reads none" {
    const gpa = std.testing.allocator;
    var diagnostics = try Diagnostics.init(gpa, test_capacity);
    defer diagnostics.deinit(gpa);

    try diagnostics.push(test_row("TS001", 0, null));

    const held = diagnostics.at(0);

    try std.testing.expectEqual(@as(usize, 0), diagnostics.related_of(&held).len);
}

test "a formatted related row writes into the arena" {
    const gpa = std.testing.allocator;
    var diagnostics = try Diagnostics.init(gpa, test_capacity);
    defer diagnostics.deinit(gpa);

    const span: Span = .{ .length = 1, .offset = 0 };

    try diagnostics.push_related_formatted(FileID.of(0), span, "bound at line {d}", .{12});

    var row = test_row("TS001", 0, null);

    row.related_count = 1;
    row.related_start = 0;

    const related = diagnostics.related_of(&row);

    try std.testing.expectEqualStrings(
        "bound at line 12",
        diagnostics.related_message_of(&related[0]),
    );
}

test "a related table that fills says so" {
    const gpa = std.testing.allocator;

    var diagnostics = try Diagnostics.init(gpa, .{
        .related_count_max = 1,
        .row_count_max = 8,
        .text_bytes_max = 1 << 12,
    });

    defer diagnostics.deinit(gpa);

    try diagnostics.push_related(test_related_row(4));

    try std.testing.expectError(
        error.RelatedExhausted,
        diagnostics.push_related(test_related_row(8)),
    );

    try std.testing.expect(diagnostics.is_overflowed());
    try std.testing.expectEqual(@as(u32, 1), diagnostics.related_count());
}

test "a cleared table forgets its related rows" {
    const gpa = std.testing.allocator;
    var diagnostics = try Diagnostics.init(gpa, test_capacity);
    defer diagnostics.deinit(gpa);

    try diagnostics.push_related(test_related_row(4));

    diagnostics.clear();

    try std.testing.expectEqual(@as(u32, 0), diagnostics.related_count());
}

test "a retained table keeps the rows the test names" {
    const gpa = std.testing.allocator;
    var diagnostics = try Diagnostics.init(gpa, test_capacity);
    defer diagnostics.deinit(gpa);

    for (0..4) |offset| try diagnostics.push(test_row("TS001", @intCast(offset), null));

    diagnostics.retain({}, test_even_offset);

    try std.testing.expectEqual(@as(u32, 2), diagnostics.count());
    try std.testing.expectEqual(@as(u32, 0), diagnostics.at(0).span.offset);
    try std.testing.expectEqual(@as(u32, 2), diagnostics.at(1).span.offset);
}

test "a push stops at the reserved count" {
    const gpa = std.testing.allocator;

    var diagnostics = try Diagnostics.init(gpa, .{
        .related_count_max = 2,
        .row_count_max = 2,
        .text_bytes_max = 1 << 12,
    });

    defer diagnostics.deinit(gpa);

    try std.testing.expectEqual(@as(u32, 2), diagnostics.capacity());
    try diagnostics.push(test_row("TS001", 0, null));
    try diagnostics.push(test_row("TS002", 4, 1));

    try std.testing.expectError(
        error.RowsExhausted,
        diagnostics.push(test_row("TS003", 8, null)),
    );

    try std.testing.expectEqual(@as(u32, 2), diagnostics.count());
    try std.testing.expect(diagnostics.is_overflowed());

    diagnostics.clear();

    try std.testing.expectEqual(@as(u32, 0), diagnostics.count());
    try diagnostics.push(test_row("TS003", 8, null));
}

test "a sort orders by offset then code" {
    const gpa = std.testing.allocator;
    var diagnostics = try Diagnostics.init(gpa, test_capacity);
    defer diagnostics.deinit(gpa);

    try diagnostics.push(test_row("TS009", 12, null));
    try diagnostics.push(test_row("TS002", 4, null));
    try diagnostics.push(test_row("TS001", 4, null));
    try diagnostics.push(test_row("TS005", 0, null));

    diagnostics.sort();

    const offsets = [_]u32{ 0, 4, 4, 12 };
    const codes = [_][]const u8{ "TS005", "TS001", "TS002", "TS009" };

    try std.testing.expectEqual(@as(u32, 4), diagnostics.count());

    for (diagnostics.slice(), offsets, codes) |held, offset, code| {
        try std.testing.expectEqual(offset, held.span.offset);
        try std.testing.expectEqualStrings(code, held.code);
    }
}

test "a sort keeps the order a tie arrived in" {
    const gpa = std.testing.allocator;
    var diagnostics = try Diagnostics.init(gpa, test_capacity);
    defer diagnostics.deinit(gpa);

    try diagnostics.push(test_row("TS001", 4, 2));
    try diagnostics.push(test_row("TS001", 4, 0));
    try diagnostics.push(test_row("TS001", 4, 1));
    try diagnostics.push(test_row("TS001", 0, 9));

    diagnostics.sort();

    const fixes = [_]u32{ 9, 2, 0, 1 };

    try std.testing.expectEqual(@as(u32, 4), diagnostics.count());

    for (diagnostics.slice(), fixes) |held, fix_index| {
        try std.testing.expectEqual(fix_index, held.fix);
    }
}

test "a fix index reads back as a fixed row" {
    const fixed = test_row("TS001", 0, 4);
    const bare = test_row("TS001", 0, null);

    try std.testing.expect(fixed.is_fixed());
    try std.testing.expect(!bare.is_fixed());
    try std.testing.expectEqualStrings("error", Severity.@"error".name());
    try std.testing.expectEqualStrings("hint", Severity.hint.name());
    try std.testing.expectEqualStrings("info", Severity.information.name());
    try std.testing.expectEqual(@as(?Severity, .warning), Severity.of("WARN"));
    try std.testing.expectEqual(@as(?Severity, .information), Severity.of("information"));
    try std.testing.expectEqual(@as(?Severity, null), Severity.of("loud"));
    try std.testing.expectEqual(@as(i64, 1), Severity.@"error".lsp_code());
    try std.testing.expectEqual(@as(i64, 2), Severity.warning.lsp_code());
    try std.testing.expectEqual(@as(i64, 3), Severity.information.lsp_code());
    try std.testing.expectEqual(@as(i64, 4), Severity.hint.lsp_code());
    try std.testing.expect(Severity.@"error".rank() > Severity.warning.rank());
    try std.testing.expect(Severity.hint.rank() < Severity.information.rank());
    try std.testing.expectEqualStrings("warning", Severity.warning.name());
}

test "a sort runs on a frozen thread" {
    var static_allocator = StaticAllocator.init(std.testing.allocator);
    defer static_allocator.deinit();

    const gpa = static_allocator.allocator();

    var diagnostics = try Diagnostics.init(gpa, .{
        .related_count_max = 64,
        .row_count_max = 64,
        .text_bytes_max = 1 << 12,
    });

    defer diagnostics.deinit(gpa);

    var random = Random.init(0x51E1_9C43_7B0D_A2F5);

    static_allocator.transition_from_init_to_static();
    defer static_allocator.transition_from_static_to_deinit();

    for (0..64) |_| try diagnostics.push(test_row("TS001", random.below(1_000), null));

    diagnostics.sort();

    var offset_previous: u32 = 0;

    for (diagnostics.slice()) |held| {
        try std.testing.expect(held.span.offset >= offset_previous);

        offset_previous = held.span.offset;
    }
}
