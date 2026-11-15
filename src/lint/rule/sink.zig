const std = @import("std");
const assert = std.debug.assert;
const bounded = @import("../../stdx/bounded.zig");
const CodeSet = @import("code_set.zig");
const Diagnostics = @import("../diagnostics.zig");
const FileID = @import("../../stdx/file_id.zig").FileID;
const Fixes = @import("../fixes.zig");
const LineIndex = @import("../../text/line_index.zig").LineIndex;
const Regions = @import("../suppress/regions.zig");
const Applicability = Fixes.Applicability;
const Diagnostic = Diagnostics.Diagnostic;
const Message = Diagnostics.Message;
const Severity = Diagnostics.Severity;
const Span = bounded.Span;
const rule_count_max = CodeSet.rule_count_max;

applicability: ?Applicability,
code: []const u8,
diagnostics: *Diagnostics,
file: FileID,
fix_failed: bool,
fixable: bool,
fixes: *Fixes,
lines: *const LineIndex,
rule_index: u32,
severity: Severity,
suppressions: *Regions,

const Sink = @This();

pub const Options = struct {
    applicability: ?Applicability,
    code: []const u8,
    diagnostics: *Diagnostics,
    file: FileID,
    fixable: bool,
    fixes: *Fixes,
    lines: *const LineIndex,
    rule_index: u32,
    severity: Severity,
    suppressions: *Regions,
};

pub fn init(options: *const Options) Sink {
    assert(options.code.len > 0);
    assert(options.rule_index < rule_count_max);

    return .{
        .applicability = options.applicability,
        .code = options.code,
        .diagnostics = options.diagnostics,
        .file = options.file,
        .fix_failed = false,
        .fixable = options.fixable,
        .fixes = options.fixes,
        .lines = options.lines,
        .rule_index = options.rule_index,
        .severity = options.severity,
        .suppressions = options.suppressions,
    };
}

pub fn code_of(sink: *const Sink) []const u8 {
    assert(sink.code.len > 0);
    assert(sink.rule_index < rule_count_max);

    return sink.code;
}

pub fn fix_begin(
    sink: *Sink,
    title: []const u8,
    applicability: Applicability,
    isolation: ?u32,
) void {
    assert(title.len > 0);
    assert(!sink.fixes.is_pending());
    if (isolation) |held| assert(held < std.math.maxInt(u32));

    sink.fixes.open(title, sink.applicability orelse applicability, isolation);
    sink.fix_failed = false;

    assert(sink.fixes.is_pending());
}

fn fix_begin_formatted(
    sink: *Sink,
    applicability: Applicability,
    isolation: ?u32,
    comptime format: []const u8,
    arguments: anytype,
) void {
    comptime assert(format.len > 0);
    assert(!sink.fixes.is_pending());
    if (isolation) |held| assert(held < std.math.maxInt(u32));
    comptime assert(@typeInfo(@TypeOf(arguments)) == .@"struct");

    const held = sink.applicability orelse applicability;

    sink.fixes.open_formatted(held, isolation, format, arguments);
    sink.fix_failed = false;
}

fn fix_discard(sink: *Sink) void {
    sink.fixes.discard();
    sink.fix_failed = false;

    assert(!sink.fixes.is_pending());
}

pub fn fix_edit(sink: *Sink, span: Span, replacement: []const u8) void {
    assert(sink.fixes.is_pending());
    assert(replacement.len <= std.math.maxInt(u32));
    assert(span.length <= std.math.maxInt(u32) - span.offset);

    sink.fixes.edit(span, replacement) catch |err| switch (err) {
        error.EditsExhausted, error.TargetExhausted, error.TextExhausted => {
            sink.fix_failed = true;
        },
    };
}

pub fn fix_edit_formatted(
    sink: *Sink,
    span: Span,
    comptime format: []const u8,
    arguments: anytype,
) void {
    comptime assert(format.len > 0);
    assert(sink.fixes.is_pending());
    assert(span.length <= std.math.maxInt(u32) - span.offset);
    comptime assert(@typeInfo(@TypeOf(arguments)) == .@"struct");

    sink.fixes.edit_formatted(span, format, arguments) catch |err| switch (err) {
        error.EditsExhausted, error.TargetExhausted, error.TextExhausted => {
            sink.fix_failed = true;
        },
    };
}

pub fn regions(sink: *const Sink) *const Regions {
    assert(sink.rule_index < rule_count_max);
    assert(sink.suppressions.count() <= sink.suppressions.capacity());

    return sink.suppressions;
}

fn related(
    sink: *Sink,
    file: FileID,
    span: Span,
    text: []const u8,
) Diagnostics.CapacityError!void {
    assert(text.len > 0);

    const row: Diagnostics.Related = .{
        .file = file,
        .message = .{ .static = text },
        .span = span,
    };

    try sink.diagnostics.push_related(row);
}

fn related_count(sink: *const Sink) u32 {
    const held = sink.diagnostics.related_count();

    assert(held <= sink.diagnostics.related.capacity());

    return held;
}

fn related_formatted(
    sink: *Sink,
    file: FileID,
    span: Span,
    comptime format: []const u8,
    arguments: anytype,
) Diagnostics.CapacityError!void {
    comptime assert(format.len > 0);
    assert(sink.code.len > 0);
    assert(span.length <= std.math.maxInt(u32) - span.offset);
    comptime assert(@typeInfo(@TypeOf(arguments)) == .@"struct");
    assert(@backingInt(file) != std.math.maxInt(u32));

    try sink.diagnostics.push_related_formatted(file, span, format, arguments);
}

pub fn report(sink: *Sink, span: Span, text: []const u8) void {
    assert(sink.code.len > 0);
    assert(text.len > 0);
    assert(span.length <= std.math.maxInt(u32) - span.offset);

    if (sink.suppression_claimed(span)) return;

    sink.diagnostics.push(sink.row_of(span, null, .{ .static = text })) catch |err| {
        switch (err) {
            error.RelatedExhausted, error.RowsExhausted => {
                assert(sink.diagnostics.is_overflowed());
            },
        }
    };
}

fn report_row(sink: *Sink, row: Diagnostic) Diagnostics.CapacityError!bool {
    assert(sink.code.len > 0);

    if (sink.suppression_claimed(row.span)) return false;

    try sink.diagnostics.push(sink.rowed(row));

    return true;
}

fn report_row_formatted(
    sink: *Sink,
    row: Diagnostic,
    comptime format: []const u8,
    arguments: anytype,
) Diagnostics.CapacityError!bool {
    comptime assert(format.len > 0);

    if (sink.suppression_claimed(row.span)) return false;
    comptime assert(@typeInfo(@TypeOf(arguments)) == .@"struct");

    try sink.diagnostics.push_formatted_row(sink.rowed(row), format, arguments);

    return true;
}

pub fn report_formatted(
    sink: *Sink,
    span: Span,
    comptime format: []const u8,
    arguments: anytype,
) void {
    comptime assert(format.len > 0);
    assert(sink.code.len > 0);
    assert(span.length <= std.math.maxInt(u32) - span.offset);
    comptime assert(@typeInfo(@TypeOf(arguments)) == .@"struct");

    if (sink.suppression_claimed(span)) return;

    const row = sink.rowed(sink.row_of(span, null, .{ .static = "" }));

    sink.pushed_formatted(row, format, arguments);
}

pub fn report_fixed(sink: *Sink, span: Span, text: []const u8) void {
    assert(sink.code.len > 0);
    assert(text.len > 0);
    assert(span.length <= std.math.maxInt(u32) - span.offset);

    if (sink.fix_suppressed(span)) return;

    const fix_index = sink.fix_closed();

    sink.diagnostics.push(sink.row_of(span, fix_index, .{ .static = text })) catch |err| {
        switch (err) {
            error.RelatedExhausted, error.RowsExhausted => {
                assert(sink.diagnostics.is_overflowed());
            },
        }
    };
}

pub fn report_fixed_formatted(
    sink: *Sink,
    span: Span,
    comptime format: []const u8,
    arguments: anytype,
) void {
    comptime assert(format.len > 0);
    assert(sink.code.len > 0);
    assert(span.length <= std.math.maxInt(u32) - span.offset);
    comptime assert(@typeInfo(@TypeOf(arguments)) == .@"struct");

    const row = sink.fixed_row(span, 0, 0) orelse return;

    sink.pushed_formatted(row, format, arguments);
}

fn report_fixed_related_formatted(
    sink: *Sink,
    span: Span,
    related_start: u32,
    comptime format: []const u8,
    arguments: anytype,
) void {
    comptime assert(format.len > 0);
    assert(span.length <= std.math.maxInt(u32) - span.offset);
    assert(related_start < std.math.maxInt(u32));
    comptime assert(@typeInfo(@TypeOf(arguments)) == .@"struct");

    const related_total = sink.related_count();
    const related_held = related_total -| related_start;

    assert(related_start <= related_total);

    const row = sink.fixed_row(span, related_start, related_held) orelse return;

    sink.pushed_formatted(row, format, arguments);
}

fn pushed_formatted(
    sink: *Sink,
    row: Diagnostic,
    comptime format: []const u8,
    arguments: anytype,
) void {
    comptime assert(format.len > 0);
    comptime assert(@typeInfo(@TypeOf(arguments)) == .@"struct");
    assert(row.span.length <= std.math.maxInt(u32) - row.span.offset);

    sink.diagnostics.push_formatted_row(row, format, arguments) catch |err| switch (err) {
        error.RelatedExhausted, error.RowsExhausted => assert(sink.diagnostics.is_overflowed()),
    };
}

fn row_of(sink: *const Sink, span: Span, fix_index: ?u32, message: Message) Diagnostic {
    assert(sink.code.len > 0);
    assert(sink.rule_index < rule_count_max);
    assert(span.length <= std.math.maxInt(u32) - span.offset);
    if (fix_index) |held| assert(held < std.math.maxInt(u32));

    if (message == .arena) assert(message.arena.length <=
        std.math.maxInt(u32) - message.arena.offset);

    return .{
        .code = sink.code,
        .fix = fix_index,
        .message = message,
        .related_count = 0,
        .related_start = 0,
        .rule = sink.rule_index,
        .severity = sink.severity,
        .span = span,
    };
}

fn fixed_row(sink: *Sink, span: Span, related_start: u32, related_count_held: u32) ?Diagnostic {
    assert(related_start + related_count_held <= sink.related_count());

    if (sink.fix_suppressed(span)) return null;

    var row = sink.row_of(span, sink.fix_closed(), .{ .static = "" });

    row.related_count = related_count_held;
    row.related_start = related_start;

    return row;
}

fn rowed(sink: *const Sink, row: Diagnostic) Diagnostic {
    assert(row.span.length <= std.math.maxInt(u32) - row.span.offset);

    var held = row;

    assert(sink.code.len > 0);

    held.code = sink.code;
    held.rule = sink.rule_index;

    if (sink.severity.rank() < row.severity.rank()) held.severity = sink.severity;

    assert(held.severity.rank() <= sink.severity.rank());

    return held;
}

fn fix_closed(sink: *Sink) ?u32 {
    defer assert(!sink.fixes.is_pending());

    if (sink.fixable) {
        if (!sink.fix_failed) return sink.fixes.close();
    }

    sink.fixes.discard();

    return null;
}

fn fix_suppressed(sink: *Sink, span: Span) bool {
    if (!sink.suppression_claimed(span)) return false;

    sink.fixes.discard();

    assert(!sink.fixes.is_pending());

    return true;
}

fn suppression_claimed(sink: *Sink, span: Span) bool {
    assert(span.length <= std.math.maxInt(u32) - span.offset);

    const line = sink.lines.line_of(span.offset);

    assert(line < sink.lines.count());
    assert(sink.rule_index < rule_count_max);

    return sink.suppressions.claim(.{ .line = line, .rule_index = sink.rule_index });
}

const TestTables = struct {
    diagnostics: Diagnostics,
    fixes: Fixes,
    index: LineIndex,
    suppressions: Regions,

    fn init(source: []const u8) !TestTables {
        assert(source.len <= std.math.maxInt(u32));

        const gpa = std.testing.allocator;

        var tables: TestTables = .{
            .diagnostics = try Diagnostics.init(gpa, .{
                .related_count_max = 8,
                .row_count_max = 8,
                .text_bytes_max = 1 << 10,
            }),
            .fixes = try Fixes.init(gpa, .{
                .edit_count_max = 4,
                .fix_count_max = 4,
                .text_bytes_max = 1 << 10,
            }),
            .index = try LineIndex.init(gpa, 8),
            .suppressions = try Regions.init(gpa, 4),
        };

        try tables.index.build(source);

        return tables;
    }

    fn deinit(tables: *TestTables) void {
        const gpa = std.testing.allocator;

        tables.diagnostics.deinit(gpa);
        tables.fixes.deinit(gpa);
        tables.index.deinit(gpa);
        tables.suppressions.deinit(gpa);
    }

    fn options(tables: *TestTables, applicability: ?Applicability, fixable: bool) Options {
        return .{
            .applicability = applicability,
            .code = "TS001",
            .diagnostics = &tables.diagnostics,
            .file = FileID.of(0),
            .fixable = fixable,
            .fixes = &tables.fixes,
            .lines = &tables.index,
            .rule_index = 0,
            .severity = .warning,
            .suppressions = &tables.suppressions,
        };
    }
};

test Sink {
    var tables = try TestTables.init("while (true) {}\n");
    defer tables.deinit();

    const options = tables.options(null, true);
    var sink: Sink = .init(&options);

    sink.fix_begin("Bound the loop", .safe, null);
    sink.fix_edit(.{ .offset = 7, .length = 4 }, "index < count");
    sink.report_fixed(.{ .offset = 0, .length = 5 }, "the loop has no bound");
    sink.report_formatted(.{ .offset = 13, .length = 2 }, "the body is {s}", .{"empty"});

    const rows = tables.diagnostics.slice();
    const body = tables.diagnostics.message_of(&rows[1]);

    try std.testing.expectEqual(@as(usize, 2), rows.len);
    try std.testing.expectEqualStrings("TS001", rows[0].code);
    try std.testing.expectEqual(@as(?u32, 0), rows[0].fix);
    try std.testing.expectEqualStrings("the body is empty", body);
    try std.testing.expectEqualStrings("TS001", sink.code_of());
    try std.testing.expectEqual(@as(u32, 0), sink.regions().count());
}

test "a sink settles a formatted fix and carries related rows on a fixed row" {
    var tables = try TestTables.init("let value = 1;\n");
    defer tables.deinit();

    const options = tables.options(.unsafe, true);
    var sink = Sink.init(&options);
    const related_start = sink.related_count();

    try sink.related(FileID.of(1), .{ .offset = 4, .length = 5 }, "declared here");

    sink.fix_begin_formatted(.safe, null, "Rename `{s}`", .{"value"});
    sink.fix_edit_formatted(.{ .offset = 4, .length = 5 }, "{s}_{d}", .{ "held", 2 });

    sink.report_fixed_related_formatted(
        .{ .offset = 0, .length = 3 },
        related_start,
        "`{s}` is renamed",
        .{"value"},
    );

    sink.fix_begin("Drop it", .safe, null);
    sink.fix_edit(.{ .offset = 0, .length = 3 }, "");
    sink.fix_discard();
    sink.report_fixed(.{ .offset = 0, .length = 3 }, "the fix was discarded");

    const first = tables.diagnostics.slice()[0];
    const second = tables.diagnostics.slice()[1];
    const held = tables.fixes.fix_of(&first).?;

    try std.testing.expectEqual(Applicability.unsafe, held.applicability);
    try std.testing.expectEqualStrings("Rename `value`", tables.fixes.title_of(&held));
    try std.testing.expectEqual(@as(usize, 1), tables.fixes.edits_of(&held).len);

    try std.testing.expectEqualStrings(
        "held_2",
        tables.fixes.replacement_of(&tables.fixes.edits_of(&held)[0]),
    );

    try std.testing.expectEqualStrings("`value` is renamed", tables.diagnostics.message_of(&first));
    try std.testing.expectEqual(related_start, first.related_start);
    try std.testing.expectEqual(@as(u32, 1), first.related_count);
    try std.testing.expectEqual(@as(usize, 1), tables.diagnostics.related_of(&first).len);
    try std.testing.expectEqual(null, second.fix);
    try std.testing.expectEqual(@as(u32, 1), tables.fixes.count());
}

test "a sink carries related rows and ranks a row below its own severity" {
    var tables = try TestTables.init("let value = 1;\n");
    defer tables.deinit();

    const options = tables.options(null, false);
    var sink = Sink.init(&options);
    const related_start = sink.related_count();

    try sink.related(FileID.of(1), .{ .offset = 4, .length = 5 }, "declared here");
    const used: Span = .{ .offset = 12, .length = 1 };

    try sink.related_formatted(FileID.of(1), used, "used {d} times", .{2});

    const row: Diagnostic = .{
        .code = "",
        .fix = null,
        .message = .{ .static = "a row with related rows" },
        .related_count = sink.related_count() - related_start,
        .related_start = related_start,
        .rule = null,
        .severity = .@"error",
        .span = .{ .offset = 0, .length = 3 },
    };

    try std.testing.expect(try sink.report_row(row));

    var hinted = row;

    hinted.severity = .hint;

    try std.testing.expect(try sink.report_row_formatted(hinted, "formatted {s}", .{"row"}));

    const first = tables.diagnostics.slice()[0];
    const second = tables.diagnostics.slice()[1];

    try std.testing.expectEqualStrings("TS001", first.code);
    try std.testing.expectEqual(@as(u32, 0), first.rule);
    try std.testing.expectEqual(Severity.warning, first.severity);
    try std.testing.expectEqual(@as(u32, 2), first.related_count);
    try std.testing.expectEqual(@as(usize, 2), tables.diagnostics.related_of(&first).len);
    try std.testing.expectEqual(Severity.hint, second.severity);
    try std.testing.expectEqualStrings("formatted row", tables.diagnostics.message_of(&second));
}
