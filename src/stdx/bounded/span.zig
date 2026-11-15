const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;

offset: u32,
length: u32,

const Span = @This();
pub const empty: Span = .{ .offset = 0, .length = 0 };

pub fn between(start: u32, stop: u32) Span {
    assert(ordered(start, stop));

    const span: Span = .{ .offset = start, .length = stop - start };

    assert(span.end() == stop);

    return span;
}

pub fn contains(span: Span, offset: u32) bool {
    assert(span.length <= std.math.maxInt(u32) - span.offset);

    if (offset < span.offset) return false;

    const result = offset < span.end();

    if (result) assert(span.length > 0);

    return result;
}

pub fn end(span: Span) u32 {
    assert(span.length <= std.math.maxInt(u32) - span.offset);

    return span.offset + span.length;
}

fn ordered(start: u32, stop: u32) bool {
    return stop >= start;
}

pub fn shifted(span: Span, base: u32) Span {
    assert(span.end() <= std.math.maxInt(u32) - base);

    const moved: Span = .{ .offset = base + span.offset, .length = span.length };

    assert(moved.length == span.length);
    assert(moved.end() - span.end() == base);

    return moved;
}

pub fn text(span: Span, source: []const u8) []const u8 {
    assert(source.len <= std.math.maxInt(u32));
    assert(span.end() <= source.len);

    return source[span.offset..span.end()];
}

test Span {
    const source = "const linter = 1;";
    const name = Span.between(6, 12);

    try std.testing.expectEqualStrings("linter", name.text(source));
    try std.testing.expectEqual(12, name.end());
    try std.testing.expect(name.contains(6));
    try std.testing.expect(!name.contains(12));
    try std.testing.expectEqual(Span{ .offset = 16, .length = 6 }, name.shifted(10));
}

test "a span opens where it is told and carries its length" {
    const span: Span = .{ .offset = 4, .length = 6 };

    try std.testing.expectEqual(4, span.offset);
    try std.testing.expectEqual(6, span.length);
    try std.testing.expectEqual(10, span.end());
}

test "a span between two offsets reaches the second" {
    try std.testing.expectEqual(Span{ .offset = 4, .length = 6 }, between(4, 10));
    try std.testing.expectEqual(Span{ .offset = 7, .length = 0 }, between(7, 7));
}

test "a shifted span keeps its length" {
    const span: Span = .{ .offset = 4, .length = 6 };
    const last = span.shifted(std.math.maxInt(u32) - span.end());

    try std.testing.expectEqual(Span{ .offset = 14, .length = 6 }, span.shifted(10));
    try std.testing.expectEqual(span, span.shifted(0));
    try std.testing.expectEqual(std.math.maxInt(u32), last.end());
    try std.testing.expectEqual(span.length, last.length);
}

test "a span between a reversed pair is refused" {
    try std.testing.expect(!ordered(10, 4));
}

test "a span contains its offsets and not its end" {
    const span: Span = .{ .offset = 4, .length = 6 };

    try std.testing.expect(span.contains(4));
    try std.testing.expect(span.contains(9));
    try std.testing.expect(!span.contains(3));
    try std.testing.expect(!span.contains(10));
    try std.testing.expect(!(Span{ .offset = 4, .length = 0 }).contains(4));
    try std.testing.expect(!empty.contains(0));
}

const test_probe_path = "zig-out/bin/guard_probe" ++ builtin.target.exeFileExt();

const test_term_panicked: std.process.Child.Term = switch (builtin.target.os.tag) {
    .windows => .{ .exited = 3 },
    else => .{ .signal = .ABRT },
};

test "a shift past the address space fails at the shift" {
    const done = try std.process.run(std.testing.allocator, std.testing.io, .{
        .argv = &.{ test_probe_path, "shift" },
    });

    defer std.testing.allocator.free(done.stderr);
    defer std.testing.allocator.free(done.stdout);

    try std.testing.expectEqual(test_term_panicked, done.term);
}
