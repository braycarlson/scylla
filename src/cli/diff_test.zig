const std = @import("std");
const assert = std.debug.assert;
const Diff = @import("diff.zig");
const StaticAllocator = @import("../stdx/static_allocator.zig");
const Terminal = @import("terminal.zig");
const context_line_count_default = (Diff.Options{}).context_line_count;
const line_count_max: u32 = 1 << 10;
const out_bytes_max: u32 = 1 << 16;

const Patch = struct {
    bytes: [out_bytes_max]u8,
    length: u32,

    fn text(patch: *const Patch) []const u8 {
        assert(patch.length <= out_bytes_max);

        return patch.bytes[0..patch.length];
    }
};

fn patch_store(patch: *Patch, out: *const Terminal) void {
    const contents = out.contents();

    assert(contents.len <= out_bytes_max);

    @memcpy(patch.bytes[0..contents.len], contents);
    patch.length = @intCast(contents.len);
}

fn unified_into(patch: *Patch, before: []const u8, after: []const u8, context_lines: u32) !void {
    assert(context_lines > 0);
    assert(before.len <= std.math.maxInt(u32));
    assert(after.len <= std.math.maxInt(u32));

    var static_allocator: StaticAllocator = .init(std.testing.allocator);
    defer static_allocator.deinit();

    const gpa = static_allocator.allocator();
    var diff = try Diff.init(gpa, line_count_max);
    defer diff.deinit(gpa);

    var out = try Terminal.init(gpa, &.{ .buffer_bytes_max = out_bytes_max, .target = .memory });
    defer out.deinit(gpa);

    static_allocator.transition_from_init_to_static();
    defer static_allocator.transition_from_static_to_deinit();

    const path = if (context_lines == context_line_count_default) "page.html" else "p";
    const texts: Diff.Texts = .{ .after = after, .before = before };

    try diff.write_unified(&out, path, &texts, .{ .context_line_count = context_lines });

    try std.testing.expect(!out.is_truncated());
    try std.testing.expect(!out.is_failed());

    patch_store(patch, &out);
}

fn expect_unified(before: []const u8, after: []const u8, expected: []const u8) !void {
    assert(before.len <= std.math.maxInt(u32));
    assert(after.len <= std.math.maxInt(u32));

    const patch = try std.testing.allocator.create(Patch);
    defer std.testing.allocator.destroy(patch);

    try unified_into(patch, before, after, context_line_count_default);
    try std.testing.expectEqualStrings(expected, patch.text());
}

fn expect_window(before: []const u8, after: []const u8, first: u32, expected: []const u8) !void {
    assert(first > 0);
    assert(before.len <= std.math.maxInt(u32));
    assert(after.len <= std.math.maxInt(u32));

    var static_allocator: StaticAllocator = .init(std.testing.allocator);
    defer static_allocator.deinit();

    const gpa = static_allocator.allocator();
    var diff = try Diff.init(gpa, line_count_max);
    defer diff.deinit(gpa);

    var out = try Terminal.init(gpa, &.{ .buffer_bytes_max = out_bytes_max, .target = .memory });
    defer out.deinit(gpa);

    static_allocator.transition_from_init_to_static();
    defer static_allocator.transition_from_static_to_deinit();

    try diff.write_window(&out, &.{ .after = after, .before = before }, first);

    try std.testing.expect(!out.is_truncated());
    try std.testing.expectEqualStrings(expected, out.contents());
}

test "two equal texts print nothing" {
    try expect_unified("a\nb\n", "a\nb\n", "");
}

test "one changed line is one hunk with its context" {
    try expect_unified(
        "a\nb\nc\n",
        "a\nB\nc\n",
        "--- page.html\n+++ page.html\n@@ -1,3 +1,3 @@\n a\n-b\n+B\n c\n",
    );
}

test "a change far from another opens a second hunk" {
    const before = "a\nb\nc\nd\ne\nf\ng\nh\ni\nj\nk\nl\n";
    const after = "A\nb\nc\nd\ne\nf\ng\nh\ni\nj\nk\nL\n";
    const patch = try std.testing.allocator.create(Patch);
    defer std.testing.allocator.destroy(patch);

    try unified_into(patch, before, after, context_line_count_default);

    const text = patch.text();

    try std.testing.expect(std.mem.startsWith(u8, text, "--- page.html\n+++ page.html\n@@ "));
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, text, "@@ -"));
    try std.testing.expect(std.mem.find(u8, text, "@@ -1,4 +1,4 @@\n-a\n+A\n b\n c\n d\n") != null);
    try std.testing.expect(std.mem.find(u8, text, "@@ -9,4 +9,4 @@\n i\n j\n k\n-l\n+L\n") != null);
}

test "a narrower context shortens the hunk" {
    const patch = try std.testing.allocator.create(Patch);
    defer std.testing.allocator.destroy(patch);

    try unified_into(patch, "a\nb\nc\nd\ne\n", "a\nb\nC\nd\ne\n", 1);

    try std.testing.expectEqualStrings(
        "--- p\n+++ p\n@@ -2,3 +2,3 @@\n b\n-c\n+C\n d\n",
        patch.text(),
    );
}

test "an insertion and a deletion are spelled in the header" {
    try expect_unified(
        "a\nb\n",
        "a\nb\nc\n",
        "--- page.html\n+++ page.html\n@@ -1,2 +1,3 @@\n a\n b\n+c\n",
    );

    try expect_unified(
        "a\nb\nc\n",
        "a\nb\n",
        "--- page.html\n+++ page.html\n@@ -1,3 +1,2 @@\n a\n b\n-c\n",
    );
}

test "a missing final newline is noted on both sides" {
    try expect_unified(
        "a",
        "b",
        "--- page.html\n+++ page.html\n@@ -1 +1 @@\n-a\n\\ No newline at end of file\n+b\n" ++
            "\\ No newline at end of file\n",
    );
}

test "carriage returns do not make two lines differ" {
    try expect_unified("a\r\nb\r\n", "a\nb\n", "");
}

test "the window numbers the kept lines and marks the moved ones" {
    try expect_window("a\nb\nc\n", "a\nB\nc\n", 1, "  |\n1 | a\n  - b\n2 + B\n3 | c\n  |\n");
}

test "the window starts counting where it is told" {
    try expect_window("b\nc\n", "B\nc\n", 9, "   |\n   - b\n 9 + B\n10 | c\n   |\n");
}
