const std = @import("std");
const assert = std.debug.assert;
const bounded = @import("../../stdx/bounded.zig");
const glob = @import("engine.zig");
const path = @import("../path.zig");
const Anchoring = glob.Anchoring;
const Error = glob.Error;
const Patterns = @import("patterns.zig").PatternsType(glob.platform_native);
const path_platform = @import("../path/platform.zig");
const Row = glob.Row;
const Span = bounded.Span;

anchoring: Anchoring,
base: bounded.ArrayType(u8),
excludes: Patterns,
includes: Patterns,
per_file_patterns: Patterns,
root: bounded.ArrayType(u8),
scratch: glob.Scratch,
sets: bounded.ArrayType(Row),

const Filter = @This();

pub const Capacity = struct {
    byte_count_max: u32,
    class_count_max: u32,
    pattern_count_max: u32,
};

pub fn init(
    gpa: std.mem.Allocator,
    capacity: Capacity,
    anchoring: Anchoring,
) std.mem.Allocator.Error!Filter {
    assert(capacity.pattern_count_max > 0);
    assert(capacity.byte_count_max > 0);

    var base: bounded.ArrayType(u8) = try .init(gpa, path_platform.path_bytes_max);
    errdefer base.deinit(gpa);

    var excludes = try patterns_init(gpa, capacity);
    errdefer excludes.deinit(gpa);

    var includes = try patterns_init(gpa, capacity);
    errdefer includes.deinit(gpa);

    var per_file_patterns = try patterns_init(gpa, capacity);
    errdefer per_file_patterns.deinit(gpa);

    var root: bounded.ArrayType(u8) = try .init(gpa, path_platform.path_bytes_max);
    errdefer root.deinit(gpa);

    var scratch = try excludes.scratch_init(gpa);
    errdefer scratch.deinit(gpa);

    const sets: bounded.ArrayType(Row) = try .init(gpa, capacity.pattern_count_max);

    return .{
        .anchoring = anchoring,
        .base = base,
        .excludes = excludes,
        .includes = includes,
        .per_file_patterns = per_file_patterns,
        .root = root,
        .scratch = scratch,
        .sets = sets,
    };
}

pub fn deinit(filter: *Filter, gpa: std.mem.Allocator) void {
    assert(filter.sets.count() <= filter.per_file_patterns.count());
    assert(filter.base.count() <= path_platform.path_bytes_max);

    filter.base.deinit(gpa);
    filter.excludes.deinit(gpa);
    filter.includes.deinit(gpa);
    filter.per_file_patterns.deinit(gpa);
    filter.root.deinit(gpa);
    filter.scratch.deinit(gpa);
    filter.sets.deinit(gpa);
    filter.* = undefined;
}

pub fn base_set(filter: *Filter, directory: []const u8) error{Overflow}!void {
    assert(directory.len <= std.math.maxInt(u32));

    try cleaned_into(directory, &filter.base);
}

pub fn clear(filter: *Filter) void {
    filter.base.clear();
    filter.excludes.clear();
    filter.includes.clear();
    filter.per_file_patterns.clear();
    filter.root.clear();
    filter.sets.clear();

    assert(filter.excludes.empty());
    assert(filter.includes.empty());
}

pub fn exclude(filter: *Filter, pattern: []const u8) Error!void {
    assert(pattern.len <= std.math.maxInt(u32));

    try pushed_whole(&filter.excludes, pattern, filter.anchoring);
}

pub fn exclude_clear(filter: *Filter) void {
    filter.excludes.clear();

    assert(filter.excludes.empty());
}

pub fn exclude_matches(filter: *Filter, relative_path: []const u8) bool {
    assert(relative_path.len <= std.math.maxInt(u32));

    if (filter.excludes.empty()) return false;
    return filter.excludes.matches(&filter.scratch, relative_path);
}

pub fn excluded(filter: *Filter, subject: []const u8) bool {
    if (filter.excludes.empty()) return false;
    assert(subject.len <= std.math.maxInt(u32));

    var scratch: [path_platform.path_bytes_max]u8 = undefined;
    const length = filter.relative(subject, &scratch) catch return false;

    assert(length <= scratch.len);

    return filter.excludes.matches(&filter.scratch, scratch[0..length]);
}

pub fn include(filter: *Filter, pattern: []const u8) Error!void {
    assert(pattern.len <= std.math.maxInt(u32));

    try pushed_whole(&filter.includes, pattern, filter.anchoring);
}

pub fn include_clear(filter: *Filter) void {
    filter.includes.clear();

    assert(filter.includes.empty());
}

pub fn include_matches(filter: *Filter, relative_path: []const u8) bool {
    assert(relative_path.len <= std.math.maxInt(u32));

    if (filter.includes.empty()) return false;
    return filter.includes.matches(&filter.scratch, relative_path);
}

pub fn included(filter: *Filter, subject: []const u8) bool {
    if (filter.includes.empty()) return true;
    assert(subject.len <= std.math.maxInt(u32));

    var scratch: [path_platform.path_bytes_max]u8 = undefined;
    const length = filter.relative(subject, &scratch) catch return false;

    assert(length <= scratch.len);

    if (filter.includes.matches(&filter.scratch, scratch[0..length])) return true;
    return filter.includes.matches(&filter.scratch, path.file_name(subject));
}

pub fn per_file(filter: *Filter, pattern: []const u8) (Error || error{SetsExhausted})!u32 {
    if (filter.sets.full()) return error.SetsExhausted;
    assert(pattern.len <= std.math.maxInt(u32));

    const start = filter.per_file_patterns.count();

    try pushed_whole(&filter.per_file_patterns, pattern, filter.anchoring);

    const end = filter.per_file_patterns.count();

    assert(end > start);

    filter.sets.push(.{ .end = end, .start = start });

    const returned = filter.sets.count() - 1;

    assert(returned < std.math.maxInt(u32));

    return returned;
}

pub fn per_file_clear(filter: *Filter) void {
    filter.per_file_patterns.clear();
    filter.sets.clear();

    assert(filter.sets.empty());
}

pub fn per_file_matches(filter: *Filter, set: u32, subject: []const u8) bool {
    assert(set < filter.sets.count());
    assert(subject.len <= std.math.maxInt(u32));

    const row = filter.sets.get(set);

    assert(row.start < row.end);

    var scratch: [path_platform.path_bytes_max]u8 = undefined;
    const length = filter.relative(subject, &scratch) catch return false;
    const patterns = &filter.per_file_patterns;
    const rows: Span = .between(row.start, row.end);
    if (patterns.matches_within(&filter.scratch, rows, scratch[0..length])) return true;
    return patterns.matches_within(&filter.scratch, rows, subject);
}

pub fn relative(filter: *const Filter, subject: []const u8, out: []u8) error{Overflow}!u32 {
    assert(filter.root.count() <= path_platform.path_bytes_max);
    assert(filter.base.count() <= path_platform.path_bytes_max);
    assert(subject.len <= std.math.maxInt(u32));
    assert(out.len <= std.math.maxInt(u32));

    var scratch: [path_platform.path_bytes_max]u8 = undefined;
    const length = try path.normalised_into(&scratch, subject);
    const held = scratch[0..length];
    const root = filter.root.const_slice();

    const direct = filter.root.empty() or filter.base.empty() or path.is_absolute(held) or
        path.contains(.{ .directory = root, .path = held });

    if (direct) return path.relative_into(out, .{ .directory = root, .path = held });

    var joined: [path_platform.path_bytes_max]u8 = undefined;
    const end = try path.join(&joined, .{ .base = filter.base.const_slice(), .relative = held });

    return path.relative_into(out, .{ .directory = root, .path = joined[0..end] });
}

pub fn relative_of(filter: *const Filter, subject: []const u8, out: []u8) []const u8 {
    assert(subject.len <= std.math.maxInt(u32));
    assert(out.len <= std.math.maxInt(u32));

    const length = filter.relative(subject, out) catch return subject;

    assert(length <= out.len);

    return out[0..length];
}

pub fn root_clear(filter: *Filter) void {
    filter.base.clear();
    filter.root.clear();

    assert(filter.root.empty());
}

pub fn root_set(filter: *Filter, directory: []const u8) error{Overflow}!void {
    assert(directory.len <= std.math.maxInt(u32));

    try cleaned_into(directory, &filter.root);
}

fn cleaned_into(directory: []const u8, out: *bounded.ArrayType(u8)) error{Overflow}!void {
    assert(out.capacity() == path_platform.path_bytes_max);
    assert(directory.len <= std.math.maxInt(u32));

    out.clear();

    var scratch: [path_platform.path_bytes_max]u8 = undefined;
    const length = try path.normalised_into(&scratch, directory);
    if (out.unused_capacity() < length) return error.Overflow;

    out.push_slice(scratch[0..length]);

    assert(out.count() == length);
}

fn patterns_init(gpa: std.mem.Allocator, capacity: Capacity) std.mem.Allocator.Error!Patterns {
    assert(capacity.byte_count_max > 0);
    assert(capacity.class_count_max > 0);

    return Patterns.init(gpa, .{
        .byte_count_max = capacity.byte_count_max,
        .class_count_max = capacity.class_count_max,
        .pattern_count_max = capacity.pattern_count_max,
    });
}

fn pushed_whole(patterns: *Patterns, pattern: []const u8, anchoring: Anchoring) Error!void {
    assert(pattern.len <= std.math.maxInt(u32));

    const row_count = patterns.count();

    patterns.push_anchoring(pattern, anchoring) catch |err| {
        patterns.truncate(row_count);

        assert(patterns.count() == row_count);

        return err;
    };

    assert(patterns.count() > row_count);
}

const capacity_test: Capacity = .{
    .byte_count_max = 1_024,
    .class_count_max = 32,
    .pattern_count_max = 32,
};

fn expect_relative(filter: *const Filter, expected: []const u8, subject: []const u8) !void {
    assert(subject.len <= std.math.maxInt(u32));

    var out: [64]u8 = undefined;
    const length = try filter.relative(subject, &out);

    try std.testing.expectEqualStrings(expected, out[0..length]);
}

test Filter {
    const gpa = std.testing.allocator;

    const capacity: Capacity = .{
        .byte_count_max = 1_024,
        .class_count_max = 8,
        .pattern_count_max = 8,
    };

    var filter: Filter = try .init(gpa, capacity, .unanchored);
    defer filter.deinit(gpa);

    try filter.include("src/**/*.rs");
    try filter.exclude("generated");
    try std.testing.expect(filter.included("src/main.rs"));
    try std.testing.expect(!filter.included("docs/guide.md"));
    try std.testing.expect(filter.excluded("src/generated/table.rs"));
    try std.testing.expect(!filter.excluded("src/main.rs"));
    try std.testing.expectError(error.BraceUnclosed, filter.exclude("{a,b"));
}

test "a filter rewrites a path relative to its root through its base" {
    const gpa = std.testing.allocator;
    var filter: Filter = try .init(gpa, capacity_test, .inferred);
    defer filter.deinit(gpa);

    try expect_relative(&filter, "/project/src/main.rs", "/project/src/main.rs");
    try filter.root_set("/project/");
    try expect_relative(&filter, "src/main.rs", "/project/src/main.rs");
    try expect_relative(&filter, "lib.rs", "/project/./src/../lib.rs");
    try expect_relative(&filter, "src/main.rs", "./src/main.rs");
    try expect_relative(&filter, "/elsewhere/x.rs", "/elsewhere/x.rs");
    try expect_relative(&filter, "", "/project");
    try filter.base_set("/project/src");
    try expect_relative(&filter, "src/main.rs", "main.rs");
    try expect_relative(&filter, "lib.rs", "../lib.rs");
    try expect_relative(&filter, "src/main.rs", "/project/src/main.rs");
    try expect_relative(&filter, "/elsewhere/x.rs", "/elsewhere/x.rs");
    try std.testing.expectError(error.Overflow, filter.relative("/project/x", &.{}));
}

test "a filter includes and excludes against the relative path" {
    const gpa = std.testing.allocator;
    var filter: Filter = try .init(gpa, capacity_test, .inferred);
    defer filter.deinit(gpa);

    try filter.root_set("/project");
    try std.testing.expect(filter.included("/project/a.rs"));
    try std.testing.expect(!filter.excluded("/project/a.rs"));

    try filter.include("src/**/*.rs");
    try filter.exclude("src/generated/*");

    try std.testing.expect(filter.included("/project/src/main.rs"));
    try std.testing.expect(filter.included("/project/src/deep/main.rs"));
    try std.testing.expect(!filter.included("/project/docs/x.md"));
    try std.testing.expect(filter.excluded("/project/src/generated/x.rs"));
    try std.testing.expect(!filter.excluded("/project/src/main.rs"));
    try std.testing.expect(!filter.includes.empty());
    try std.testing.expect(!filter.excludes.empty());

    filter.clear();

    try std.testing.expect(filter.included("/project/docs/x.md"));
    try expect_relative(&filter, "/project/docs/x.md", "/project/docs/x.md");
}

test "an anchored include also matches by file name" {
    const gpa = std.testing.allocator;
    var filter: Filter = try .init(gpa, capacity_test, .anchored);
    defer filter.deinit(gpa);

    try filter.root_set("/project");
    try filter.include("Makefile");

    try std.testing.expect(filter.included("/project/Makefile"));
    try std.testing.expect(filter.included("/project/deep/Makefile"));
    try std.testing.expect(!filter.included("/project/deep/Makefile.in"));
}

test "a per file set matches its own patterns only" {
    const gpa = std.testing.allocator;
    var filter: Filter = try .init(gpa, capacity_test, .inferred);
    defer filter.deinit(gpa);

    try filter.root_set("/project");
    try std.testing.expectEqual(0, try filter.per_file("tests/*.py"));
    try std.testing.expectEqual(1, try filter.per_file("{a,b}.py"));
    try std.testing.expect(filter.per_file_matches(0, "/project/tests/x.py"));
    try std.testing.expect(!filter.per_file_matches(1, "/project/tests/x.py"));
    try std.testing.expect(filter.per_file_matches(1, "/project/a.py"));
    try std.testing.expect(filter.per_file_matches(1, "/project/b.py"));
    try std.testing.expect(!filter.per_file_matches(0, "/project/a.py"));
    try std.testing.expect(filter.per_file_matches(0, "tests/x.py"));
}

test "a refused pattern leaves the filter as it was" {
    const gpa = std.testing.allocator;
    var filter: Filter = try .init(gpa, capacity_test, .inferred);
    defer filter.deinit(gpa);

    try std.testing.expectError(error.BraceUnclosed, filter.exclude("{a,b"));
    try std.testing.expect(filter.excludes.empty());
    try std.testing.expectError(error.Empty, filter.include(""));
    try std.testing.expect(filter.includes.empty());
    try std.testing.expectError(error.ClassUnclosed, filter.per_file("[abc"));
    try std.testing.expectEqual(0, try filter.per_file("ok.py"));
    try std.testing.expect(filter.per_file_matches(0, "ok.py"));
}

test "a filled set table refuses another set" {
    const gpa = std.testing.allocator;
    var capacity = capacity_test;

    capacity.pattern_count_max = 1;

    var filter: Filter = try .init(gpa, capacity, .inferred);
    defer filter.deinit(gpa);

    try std.testing.expectEqual(0, try filter.per_file("a.py"));
    try std.testing.expectError(error.SetsExhausted, filter.per_file("b.py"));
}

test "a raw match reads the relative path as given and a cleared list forgets it" {
    const gpa = std.testing.allocator;
    var filter: Filter = try .init(gpa, capacity_test, .inferred);
    defer filter.deinit(gpa);

    try filter.root_set("/project");
    try filter.exclude("vendor");
    try filter.include("*.py");
    try std.testing.expect(filter.exclude_matches("vendor/page.html"));
    try std.testing.expect(!filter.exclude_matches("vendored/page.html"));
    try std.testing.expect(filter.include_matches("app/x.py"));
    try std.testing.expect(!filter.include_matches("app/x.js"));

    filter.exclude_clear();
    filter.include_clear();

    try std.testing.expect(!filter.exclude_matches("vendor/page.html"));
    try std.testing.expect(!filter.include_matches("app/x.py"));
}

test "a cleared per file table and root start over" {
    const gpa = std.testing.allocator;
    var filter: Filter = try .init(gpa, capacity_test, .inferred);
    defer filter.deinit(gpa);

    var out: [path_platform.path_bytes_max]u8 = undefined;
    const subject = "/project/tests/x.py";

    try filter.root_set("/project");
    try std.testing.expectEqual(0, try filter.per_file("tests/*.py"));
    try std.testing.expectEqualStrings("tests/x.py", filter.relative_of(subject, &out));
    try std.testing.expectEqualStrings("/project/x", filter.relative_of("/project/x", &.{}));

    filter.per_file_clear();
    filter.root_clear();

    try std.testing.expectEqual(0, try filter.per_file("a.py"));
    try std.testing.expect(filter.per_file_matches(0, "a.py"));
    try std.testing.expectEqualStrings(subject, filter.relative_of(subject, &out));
}
