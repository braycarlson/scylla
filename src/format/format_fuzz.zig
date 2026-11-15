const std = @import("std");
const assert = std.debug.assert;
const Buffer = @import("../stdx/bounded/buffer.zig");
const Formatters = @import("../format.zig").Formatters;
const Front = @import("../syntax/front.zig").Front;
const Language = @import("../syntax/language.zig").Language;

pub const FormatHarness = struct {
    first: Buffer,
    formatters: Formatters,
    language: Language,
    second: Buffer,

    pub fn init(
        harness: *FormatHarness,
        gpa: std.mem.Allocator,
        language: Language,
    ) std.mem.Allocator.Error!void {
        assert(language.lexes());

        harness.language = language;
        harness.first = try .init(gpa, out_bytes_max);
        errdefer harness.first.deinit(gpa);

        harness.second = try .init(gpa, out_bytes_max);
        errdefer harness.second.deinit(gpa);

        try harness.formatters.init(gpa, &format_capacity, .initOne(language), &.{});

        assert(harness.first.empty());
        assert(harness.second.empty());
    }

    pub fn deinit(harness: *FormatHarness, gpa: std.mem.Allocator) void {
        assert(harness.first.capacity() == out_bytes_max);
        assert(harness.second.capacity() == out_bytes_max);

        harness.formatters.deinit(gpa);
        harness.second.deinit(gpa);
        harness.first.deinit(gpa);
        harness.* = undefined;
    }

    pub fn check(harness: *FormatHarness, source: []const u8) void {
        assert(harness.first.capacity() > 0);
        assert(source.len <= std.math.maxInt(u32));

        if (source.len > std.math.maxInt(u32)) return;

        harness.pass(source, &harness.first) catch return;
        harness.pass(harness.first.const_slice(), &harness.second) catch unreachable;

        assert(std.mem.eql(u8, harness.first.const_slice(), harness.second.const_slice()));
    }

    fn pass(harness: *FormatHarness, source: []const u8, out: *Buffer) Formatters.Error!void {
        assert(source.len <= std.math.maxInt(u32));
        assert(out.capacity() == out_bytes_max);

        out.clear();

        return harness.formatters.format(.of(harness.language), source, out);
    }
};

const format_capacity: Formatters.Capacity = .{
    .arena_bytes_max = 1 << 22,
    .element_count_max = 1 << 18,
    .front = front_capacity,
    .line_count_max = 1 << 14,
    .pragma_count_max = 1 << 10,
};

const front_capacity: Front.Capacity = .{
    .diagnostic_count_max = 1 << 10,
    .event_count_max = 1 << 19,
    .node_count_max = 1 << 16,
    .semantic = null,
    .tag_count_max = 1 << 12,
    .token_count_max = 1 << 16,
};

const out_bytes_max: u32 = 1 << 22;

test "formatting a formatted python source changes nothing" {
    const gpa = std.testing.allocator;
    const harness = try gpa.create(FormatHarness);
    defer gpa.destroy(harness);

    try harness.init(gpa, .python);
    defer harness.deinit(gpa);

    harness.check("def  f( a,b ):\n    return a+b\n");

    try std.testing.expectEqualStrings(
        "def f(a, b):\n    return a + b\n",
        harness.first.const_slice(),
    );

    try std.testing.expectEqualStrings(harness.first.const_slice(), harness.second.const_slice());
}
