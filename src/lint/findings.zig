const std = @import("std");
const assert = std.debug.assert;
const bounded = @import("../stdx/bounded.zig");
const Diagnostics = @import("diagnostics.zig");
const FileID = @import("../stdx/file_id.zig").FileID;
const Diagnostic = Diagnostics.Diagnostic;
const Related = Diagnostics.Related;

files: bounded.ArrayType(Diagnostics),
order: bounded.ArrayType(FileID),

const Findings = @This();

pub const Capacity = struct {
    file_count_max: u32,
    related_count_max: u32,
    row_count_max: u32,
    text_bytes_max: u32,
};

pub const CapacityError = Diagnostics.CapacityError;

pub const Finding = struct {
    file: FileID,
    row: Diagnostic,
};

pub const Iterator = struct {
    at: u32,
    held: *const Findings,
    remaining: u32,
    row: u32,

    pub fn next(walk: *Iterator) ?Finding {
        assert(walk.remaining <= walk.held.count());

        if (walk.remaining == 0) return null;

        const file_count_max = walk.held.files.count();

        for (0..file_count_max + 1) |_| {
            if (walk.at >= walk.held.order.count()) return null;

            const file = walk.held.order.get(walk.at);
            const held = walk.held.of(file);

            if (walk.row >= held.count()) {
                walk.at += 1;
                walk.row = 0;

                continue;
            }

            const row = held.items.get(walk.row);

            walk.row += 1;
            walk.remaining -= 1;

            return .{ .file = file, .row = row };
        }

        unreachable;
    }
};

pub fn init(gpa: std.mem.Allocator, capacity: Capacity) std.mem.Allocator.Error!Findings {
    assert(capacity.file_count_max > 0);
    assert(capacity.row_count_max > 0);
    assert(capacity.text_bytes_max > 0);

    var files = try bounded.ArrayType(Diagnostics).init(gpa, capacity.file_count_max);
    errdefer findings_files_free(&files, gpa);

    for (0..capacity.file_count_max) |_| {
        files.push(try Diagnostics.init(gpa, .{
            .related_count_max = capacity.related_count_max,
            .row_count_max = capacity.row_count_max,
            .text_bytes_max = capacity.text_bytes_max,
        }));
    }

    assert(files.count() == capacity.file_count_max);

    const order = try bounded.ArrayType(FileID).init(gpa, capacity.file_count_max);
    return .{ .files = files, .order = order };
}

pub fn deinit(findings: *Findings, gpa: std.mem.Allocator) void {
    assert(findings.order.count() <= findings.files.count());

    findings_files_free(&findings.files, gpa);
    findings.order.deinit(gpa);
    findings.* = undefined;
}

pub fn clear(findings: *Findings) void {
    for (findings.files.slice()) |*held| held.clear();

    findings.order.clear();

    assert(findings.empty());
    assert(findings.order.empty());
}

pub fn count(findings: *const Findings) u32 {
    var found: u32 = 0;

    assert(findings.files.count() > 0);

    for (findings.files.const_slice()) |*held| found +|= held.count();

    if (found == 0) assert(findings.empty());

    return found;
}

pub fn detach(findings: *Findings, file: FileID, row_index: u32) void {
    assert(@backingInt(file) != std.math.maxInt(u32));

    const held = findings.of_mut(file);

    assert(row_index < held.count());
    assert(held.count() <= held.capacity());

    held.attach(row_index, null);
}

pub fn empty(findings: *const Findings) bool {
    assert(findings.files.count() > 0);
    assert(findings.order.count() <= findings.files.count());

    for (findings.files.const_slice()) |*held| {
        if (!held.empty()) return false;
    }

    return true;
}

pub fn file_count(findings: *const Findings) u32 {
    const value = findings.files.count();

    assert(value > 0);

    return value;
}

pub fn is_overflowed(findings: *const Findings) bool {
    assert(findings.files.count() > 0);
    assert(findings.order.count() <= findings.files.count());

    for (findings.files.const_slice()) |*held| {
        if (held.is_overflowed()) return true;
    }

    return false;
}

pub fn iterator(findings: *const Findings) Iterator {
    assert(findings.order.count() <= findings.files.count());

    return .{ .at = 0, .held = findings, .remaining = findings.count(), .row = 0 };
}

pub fn message_of(findings: *const Findings, finding: *const Finding) []const u8 {
    assert(finding.row.code.len > 0);
    assert(finding.file.index() < findings.files.count());

    return findings.of(finding.file).message_of(&finding.row);
}

pub fn of(findings: *const Findings, file: FileID) *const Diagnostics {
    assert(@backingInt(file) != std.math.maxInt(u32));

    const file_index = file.index();

    assert(file_index < findings.files.count());

    return &findings.files.const_slice()[file_index];
}

pub fn of_mut(findings: *Findings, file: FileID) *Diagnostics {
    assert(@backingInt(file) != std.math.maxInt(u32));

    const file_index = file.index();

    assert(file_index < findings.files.count());

    return &findings.files.slice()[file_index];
}

pub fn order_slice(findings: *const Findings) []const FileID {
    assert(findings.order.count() <= findings.files.count());

    return findings.order.const_slice();
}

pub fn push(findings: *Findings, file: FileID, row: Diagnostic) CapacityError!void {
    assert(row.code.len > 0);
    assert(file.index() < findings.files.count());

    try findings.of_mut(file).push(row);
}

pub fn push_formatted(
    findings: *Findings,
    file: FileID,
    row: Diagnostic,
    comptime format: []const u8,
    arguments: anytype,
) CapacityError!void {
    comptime assert(format.len > 0);
    assert(row.code.len > 0);
    comptime assert(@typeInfo(@TypeOf(arguments)) == .@"struct");
    assert(@backingInt(file) != std.math.maxInt(u32));

    try findings.of_mut(file).push_formatted_row(row, format, arguments);
}

pub fn push_related(findings: *Findings, file: FileID, related: Related) CapacityError!void {
    assert(file.index() < findings.files.count());
    assert(related.span.length <= std.math.maxInt(u32) - related.span.offset);
    assert(findings.order.count() <= findings.files.count());

    try findings.of_mut(file).push_related(related);
}

pub fn push_related_formatted(
    findings: *Findings,
    file: FileID,
    related: Related,
    comptime format: []const u8,
    arguments: anytype,
) CapacityError!void {
    comptime assert(format.len > 0);
    comptime assert(@typeInfo(@TypeOf(arguments)) == .@"struct");
    assert(@backingInt(file) != std.math.maxInt(u32));

    const held = findings.of_mut(file);

    assert(held.related_count() <= held.related.capacity());

    try held.push_related_formatted(related.file, related.span, format, arguments);
}

pub fn related_count(findings: *const Findings, file: FileID) u32 {
    assert(file.index() < findings.files.count());

    const held = findings.of(file).related_count();

    return held;
}

pub fn related_message_of(
    findings: *const Findings,
    finding: *const Finding,
    related: *const Related,
) []const u8 {
    assert(finding.row.code.len > 0);
    assert(finding.file.index() < findings.files.count());

    return findings.of(finding.file).related_message_of(related);
}

pub fn related_of(findings: *const Findings, finding: *const Finding) []const Related {
    const rows = findings.of(finding.file).related_of(&finding.row);

    assert(rows.len == finding.row.related_count);

    return rows;
}

fn sort(
    findings: *Findings,
    context: anytype,
    comptime compare: fn (@TypeOf(context), FileID, FileID) std.math.Order,
) void {
    comptime assert(@typeInfo(@TypeOf(context)) == .pointer or @TypeOf(context) == void);

    findings.order.clear();

    for (findings.files.slice(), 0..) |*held, file_index| {
        if (held.empty()) continue;

        held.sort();
        findings.order.push(FileID.of(@intCast(file_index)));
    }

    const Context = @TypeOf(context);

    std.sort.block(FileID, findings.order.slice(), context, struct {
        fn less_than(held: Context, left: FileID, right: FileID) bool {
            comptime assert(@typeInfo(@TypeOf(held)) == .pointer or @TypeOf(held) == void);
            assert(@backingInt(left) != std.math.maxInt(u32));
            assert(@backingInt(right) != std.math.maxInt(u32));

            return compare(held, left, right) == .lt;
        }
    }.less_than);

    assert(findings.order.count() <= findings.files.count());
}

fn findings_files_free(files: *bounded.ArrayType(Diagnostics), gpa: std.mem.Allocator) void {
    assert(files.count() <= files.capacity());

    for (files.slice()) |*held| held.deinit(gpa);

    files.deinit(gpa);
}

fn path_order(left: []const u8, right: []const u8) std.math.Order {
    assert(left.len <= std.math.maxInt(u32));
    assert(right.len <= std.math.maxInt(u32));

    const length = @min(left.len, right.len);

    assert(length <= left.len);
    assert(length <= right.len);

    for (left[0..length], right[0..length]) |left_byte, right_byte| {
        const left_folded: u8 = if (left_byte == '/') 0 else left_byte;
        const right_folded: u8 = if (right_byte == '/') 0 else right_byte;
        if (left_folded != right_folded) return std.math.order(left_folded, right_folded);
    }

    return std.math.order(left.len, right.len);
}

fn shared(row_count: u32, file_count_held: u32) u32 {
    assert(file_count_held > 0);
    assert(row_count < std.math.maxInt(u32));

    const result = @max(row_count / file_count_held, 1);

    assert(result >= 1);

    return result;
}

const test_capacity: Capacity = .{
    .file_count_max = 3,
    .related_count_max = 4,
    .row_count_max = 4,
    .text_bytes_max = 1 << 10,
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

fn test_path_compare(paths: *const [3][]const u8, left: FileID, right: FileID) std.math.Order {
    assert(@backingInt(left) != std.math.maxInt(u32));
    assert(@backingInt(right) != std.math.maxInt(u32));

    return path_order(paths[left.index()], paths[right.index()]);
}

fn test_equal_compare(context: void, left: FileID, right: FileID) std.math.Order {
    _ = context;
    _ = left;
    _ = right;

    return .eq;
}

test "a findings table walks its files in the sorted order" {
    const gpa = std.testing.allocator;
    var findings = try Findings.init(gpa, test_capacity);
    defer findings.deinit(gpa);

    const paths = [3][]const u8{ "b/z.rs", "a/y.rs", "a-x.rs" };

    try findings.push(FileID.of(0), test_row("TS002", 8, null));
    try findings.push(FileID.of(0), test_row("TS001", 2, null));
    try findings.push(FileID.of(2), test_row("TS003", 0, null));
    try std.testing.expectEqual(@as(u32, 3), findings.count());
    try std.testing.expect(!findings.empty());
    try std.testing.expect(!findings.is_overflowed());

    findings.sort(&paths, test_path_compare);

    const order = [_]FileID{ FileID.of(2), FileID.of(0) };

    try std.testing.expectEqualSlices(FileID, &order, findings.order_slice());

    const walked = [_][2]u32{ .{ 2, 0 }, .{ 0, 2 }, .{ 0, 8 } };
    var walk = findings.iterator();

    for (walked) |expected| {
        const finding = walk.next().?;

        try std.testing.expectEqual(expected[0], finding.file.index());
        try std.testing.expectEqual(expected[1], finding.row.span.offset);
    }

    try std.testing.expectEqual(@as(u32, 0), walk.remaining);

    const walked_past = walk.next();

    try std.testing.expect(walked_past == null);

    var again = findings.iterator();
    const first = again.next().?;

    try std.testing.expectEqualStrings("a recorded finding", findings.message_of(&first));
    try std.testing.expectEqual(@as(usize, 0), findings.related_of(&first).len);

    findings.clear();

    try std.testing.expect(findings.empty());
    try std.testing.expectEqual(@as(u32, 0), findings.count());
}

test "a findings table carries related rows and detaches a fix" {
    const gpa = std.testing.allocator;

    var findings = try Findings.init(gpa, .{
        .file_count_max = 2,
        .related_count_max = 4,
        .row_count_max = 4,
        .text_bytes_max = 1 << 10,
    });

    defer findings.deinit(gpa);

    const file = FileID.of(1);

    try findings.push_related(file, test_related_row(4));
    try findings.push_related_formatted(file, test_related_row(8), "bound at {d}", .{8});
    try std.testing.expectEqual(@as(u32, 2), findings.related_count(file));
    try std.testing.expectEqual(@as(u32, 0), findings.related_count(FileID.of(0)));

    var row = test_row("TS001", 0, 3);

    row.related_count = 2;
    row.related_start = 0;

    try findings.push_formatted(file, row, "names {s}", .{"two"});

    findings.sort({}, test_equal_compare);

    var walk = findings.iterator();
    const finding = walk.next().?;
    const related = findings.related_of(&finding);

    try std.testing.expectEqual(@as(usize, 2), related.len);
    try std.testing.expectEqualStrings("names two", findings.message_of(&finding));

    try std.testing.expectEqualStrings(
        "bound at 8",
        findings.related_message_of(&finding, &related[1]),
    );

    try std.testing.expect(finding.row.fix != null);

    findings.detach(file, 0);

    var again = findings.iterator();
    const detached = again.next().?;

    try std.testing.expect(detached.row.fix == null);
    try std.testing.expectEqual(@as(u32, 2), findings.file_count());
}

test "a findings table reads the last file it holds" {
    const gpa = std.testing.allocator;

    var findings = try Findings.init(gpa, .{
        .file_count_max = 1,
        .related_count_max = 2,
        .row_count_max = 2,
        .text_bytes_max = 1 << 10,
    });

    defer findings.deinit(gpa);

    const last = FileID.of(0);

    try findings.push(last, test_row("TS001", 0, null));
    try findings.push(last, test_row("TS002", 1, null));
    try findings.push_related(last, test_related_row(0));
    try std.testing.expectEqual(@as(u32, 1), findings.file_count());
    try std.testing.expectEqual(@as(u32, 2), findings.of(last).count());
    try std.testing.expectEqual(@as(u32, 1), findings.of_mut(last).related_count());

    const refused = findings.push(last, test_row("TS003", 2, null));

    try std.testing.expectError(error.RowsExhausted, refused);
    try std.testing.expect(findings.is_overflowed());
}

test "a path order sorts a separator before every byte" {
    try std.testing.expectEqual(std.math.Order.lt, path_order("a/b.rs", "a-b.rs"));
    try std.testing.expectEqual(std.math.Order.eq, path_order("a.rs", "a.rs"));
    try std.testing.expectEqual(std.math.Order.gt, path_order("b", "a"));
    try std.testing.expectEqual(@as(u32, 2), shared(10, 4));
    try std.testing.expectEqual(@as(u32, 1), shared(1, 4));
    try std.testing.expectEqual(@as(u32, 8), shared(8, 1));
}
