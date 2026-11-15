const std = @import("std");
const assert = std.debug.assert;
const json = @import("json");
const Clock = @import("../stdx/timing/clock.zig");

begun: bool,
opened: Clock,
token: ?Token,

const Progress = @This();

pub const Kind = enum {
    begin,
    end,
    report,
};

pub const Step = struct {
    cancellable: ?bool = null,
    kind: Kind,
    message: ?[]const u8 = null,
    percentage: ?i64 = null,
    title: ?[]const u8 = null,
};

pub const Token = union(enum) {
    source: []const u8,
    text: []const u8,
};

pub const delay_ns: u64 = 250 * std.time.ns_per_ms;
pub const method = "$/progress";

pub fn init(io: std.Io, token: ?Token) Progress {
    if (token) |held| assert(token_bytes(held).len > 0);

    const progress: Progress = .{ .begun = false, .opened = .init(io), .token = token };

    assert(!progress.begun);

    return progress;
}

fn token_bytes(token: Token) []const u8 {
    assert(token == .source or token == .text);

    return switch (token) {
        .source, .text => |bytes| bytes,
    };
}

pub fn is_due(progress: *const Progress) bool {
    if (progress.token == null) return false;

    return progress.opened.nanoseconds() >= delay_ns;
}

pub fn percentage_of(checked: u32, count: u32) i64 {
    assert(checked <= count);

    const scaled: u64 = @as(u64, checked) * 100;
    const percentage: i64 = @intCast(@divFloor(scaled, @as(u64, @max(count, 1))));

    assert(percentage >= 0);
    assert(percentage <= 100);

    return percentage;
}

pub fn write(progress: *const Progress, writer: *json.Writer, step: Step) json.Writer.Error!void {
    if (step.percentage) |held| assert(held >= 0);
    if (step.percentage) |held| assert(held <= 100);

    try writer.object_begin();
    try writer.key("token");

    if (progress.token) |token| {
        switch (token) {
            .source => |source| try writer.raw(source),
            .text => |text| try writer.string(text),
        }
    } else {
        try writer.null_value();
    }

    try writer.key("value");
    try writer.object_begin();
    try writer.key("kind");
    try writer.string(@tagName(step.kind));

    if (step.cancellable) |held| {
        try writer.key("cancellable");
        try writer.boolean(held);
    }

    if (step.title) |held| {
        try writer.key("title");
        try writer.string(held);
    }

    if (step.message) |held| {
        try writer.key("message");
        try writer.string(held);
    }

    if (step.percentage) |held| {
        try writer.key("percentage");
        try writer.integer(held);
    }

    try writer.object_end();
    try writer.object_end();
}

fn test_written(progress: *const Progress, bytes: []u8, step: Step) ![]const u8 {
    assert(bytes.len > 0);
    if (step.percentage) |held| assert(held <= 100);

    var sink: std.Io.Writer = .fixed(bytes);
    var writer: json.Writer = .init(&sink, .{});

    try progress.write(&writer, step);

    writer.finish();

    return sink.buffered();
}

test "a step echoes its token and writes only the keys it carries" {
    var bytes: [256]u8 = undefined;
    const echoed: Progress = .init(std.testing.io, .{ .source = "7" });
    const begun = try test_written(&echoed, &bytes, .{
        .kind = .begin,
        .message = "m",
        .title = "t",
    });

    try std.testing.expectEqualStrings(
        "{\"token\":7,\"value\":{\"kind\":\"begin\",\"title\":\"t\",\"message\":\"m\"}}",
        begun,
    );

    const named: Progress = .init(std.testing.io, .{ .text = "scan/1" });
    const reported = try test_written(&named, &bytes, .{
        .cancellable = false,
        .kind = .report,
        .percentage = 50,
    });

    try std.testing.expectEqualStrings(
        "{\"token\":\"scan/1\",\"value\":{\"kind\":\"report\",\"cancellable\":false," ++
            "\"percentage\":50}}",
        reported,
    );

    const absent: Progress = .init(std.testing.io, null);
    const ended = try test_written(&absent, &bytes, .{ .kind = .end });

    try std.testing.expectEqualStrings("{\"token\":null,\"value\":{\"kind\":\"end\"}}", ended);
    try std.testing.expect(!absent.is_due());
}

test "a percentage is the floor of the checked share" {
    try std.testing.expectEqual(0, percentage_of(0, 0));
    try std.testing.expectEqual(33, percentage_of(1, 3));
    try std.testing.expectEqual(100, percentage_of(3, 3));
}
