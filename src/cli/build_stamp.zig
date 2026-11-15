const std = @import("std");
const assert = std.debug.assert;
const json = @import("json");
const Buffer = @import("../stdx/bounded/buffer.zig");
const Terminal = @import("terminal.zig");

commit: ?Commit,
version: []const u8,

const BuildStamp = @This();

pub const Commit = struct {
    date: []const u8,
    hash: []const u8,
    commits_since_last_tag: u32,
    tag_last: ?[]const u8,
    short_hash: []const u8,
};

pub const Format = enum { json, text };
pub const document_bytes_max: u32 = 1 << 10;
const line_bytes_max: u32 = 256;
const json_options: json.Writer.Options = .{ .layout = .pretty, .utf8 = .checked };

pub fn stamped(version: []const u8, line: []const u8) BuildStamp {
    assert(version.len > 0);
    assert(line.len <= std.math.maxInt(u32));

    const bare: BuildStamp = .{ .commit = null, .version = version };
    var fields = std.mem.tokenizeAny(u8, line, " \t\r\n");
    const hash = fields.next() orelse return bare;
    const short = fields.next() orelse return bare;
    const date = fields.next() orelse return bare;

    var commit: Commit = .{
        .date = date,
        .hash = hash,
        .commits_since_last_tag = 0,
        .tag_last = null,
        .short_hash = short,
    };

    if (fields.next()) |described| {
        var parts = std.mem.splitScalar(u8, described, '-');

        commit.tag_last = parts.first();
        commit.commits_since_last_tag = std.fmt.parseInt(u32, parts.next() orelse "0", 10) catch 0;
    }

    assert(commit.hash.len > 0);
    assert(commit.short_hash.len > 0);

    return .{ .commit = commit, .version = version };
}

pub fn written(build: *const BuildStamp, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    assert(build.version.len > 0);

    try writer.writeAll(build.version);

    const commit = build.commit orelse return;

    assert(commit.short_hash.len > 0);

    if (commit.commits_since_last_tag > 0) {
        try writer.print("+{d}", .{commit.commits_since_last_tag});
    }

    try writer.print(" ({s} {s})", .{ commit.short_hash, commit.date });
}

pub fn render(
    build: *const BuildStamp,
    out: *Terminal,
    document: *Buffer,
    format: Format,
    binary: []const u8,
) void {
    assert(build.version.len > 0);
    assert(binary.len > 0);

    switch (format) {
        .text => {
            var buffer: [line_bytes_max]u8 = undefined;
            var writer: std.Io.Writer = .fixed(&buffer);

            build.written(&writer) catch |err| switch (err) {
                error.WriteFailed => unreachable,
            };

            out.push(binary);
            out.push(" ");
            out.push(writer.buffered());
            out.push("\n");
        },
        .json => {
            document.clear();

            var sink = document.writer();
            var writer: json.Writer = .init(&sink.interface, json_options);

            if (build.object_written(&writer)) {
                writer.finish();
                out.push(document.const_slice());
            } else |_| {
                out.push("{}");
            }

            out.push("\n");
        },
    }
}

fn object_written(build: *const BuildStamp, writer: *json.Writer) json.Writer.Error!void {
    assert(build.version.len > 0);

    try writer.object_begin();
    try writer.key("commit");

    if (build.commit) |commit| {
        assert(commit.hash.len > 0);

        try writer.object_begin();
        try writer.key("commit_date");
        try writer.string(commit.date);
        try writer.key("commit_hash");
        try writer.string(commit.hash);
        try writer.key("commits_since_last_tag");
        try writer.integer(commit.commits_since_last_tag);
        try writer.key("last_tag");

        if (commit.tag_last) |tag| try writer.string(tag) else try writer.null_value();

        try writer.key("short_commit_hash");
        try writer.string(commit.short_hash);
        try writer.object_end();
    } else {
        try writer.null_value();
    }

    try writer.key("version");
    try writer.string(build.version);
    try writer.object_end();
}

const TestDocument = json.DocumentType(.{ .node_count_max = 64, .text_bytes_max = 1 << 10 });

fn test_seeded(distance: u32) BuildStamp {
    assert(distance < 1 << 16);

    return .{
        .commit = .{
            .date = "2026-08-16",
            .hash = "53b0f5d924110e5b26fbf09f6fd3a03d67b475b7",
            .commits_since_last_tag = distance,
            .tag_last = "v0.0.1",
            .short_hash = "53b0f5d92",
        },
        .version = "0.0.0",
    };
}

fn test_display(build: *const BuildStamp) ![]const u8 {
    var buffer: [line_bytes_max]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try build.written(&writer);

    return std.testing.allocator.dupe(u8, writer.buffered());
}

fn test_rendered(build: *const BuildStamp, format: Format) ![]const u8 {
    const gpa = std.testing.allocator;

    var out: Terminal = try .init(gpa, &.{
        .buffer_bytes_max = 1 << 10,
        .colored = false,
        .target = .memory,
    });
    defer out.deinit(gpa);

    var document: Buffer = try .init(gpa, document_bytes_max);
    defer document.deinit(gpa);

    build.render(&out, &document, format, "sample");

    return gpa.dupe(u8, out.contents());
}

test "a bare version prints the number alone" {
    const build: BuildStamp = .{ .commit = null, .version = "0.0.0" };
    const text = try test_display(&build);
    defer std.testing.allocator.free(text);

    try std.testing.expectEqualStrings("0.0.0", text);
}

test "a tagged commit prints the hash and the date" {
    const text = try test_display(&test_seeded(0));
    defer std.testing.allocator.free(text);

    try std.testing.expectEqualStrings("0.0.0 (53b0f5d92 2026-08-16)", text);
}

test "a commit past the tag counts the distance" {
    const text = try test_display(&test_seeded(24));
    defer std.testing.allocator.free(text);

    try std.testing.expectEqualStrings("0.0.0+24 (53b0f5d92 2026-08-16)", text);
}

test "the text form names the binary" {
    const rendered = try test_rendered(&test_seeded(0), .text);
    defer std.testing.allocator.free(rendered);

    try std.testing.expectEqualStrings("sample 0.0.0 (53b0f5d92 2026-08-16)\n", rendered);
}

test "the json form carries the version and the commit" {
    const gpa = std.testing.allocator;
    const rendered = try test_rendered(&test_seeded(3), .json);
    defer gpa.free(rendered);

    var document: TestDocument = undefined;

    try document.parse(rendered);

    const root = document.root();
    const version = document.member(root, "version") orelse return error.TestUnexpectedResult;
    const commit = document.member(root, "commit") orelse return error.TestUnexpectedResult;
    const tag = document.member(commit, "last_tag") orelse return error.TestUnexpectedResult;

    try std.testing.expect(document.text_is(version, "0.0.0"));
    try std.testing.expect(document.text_is(tag, "v0.0.1"));
}

test "a stamped line splits into the hash, the date, the tag, and the distance" {
    const head = "53b0f5d924110e5b26fbf09f6fd3a03d67b475b7 53b0f5d92 2026-08-16";
    const tagged = stamped("0.1.0", head ++ " v0.0.1");
    const ahead = stamped("0.1.0", head ++ " v0.0.1-24-g53b0f5d92");
    const untagged = stamped("0.1.0", head);
    const text = try test_display(&ahead);
    defer std.testing.allocator.free(text);

    try std.testing.expectEqualStrings("0.1.0+24 (53b0f5d92 2026-08-16)", text);
    try std.testing.expectEqual(@as(u32, 0), tagged.commit.?.commits_since_last_tag);
    try std.testing.expectEqualStrings("v0.0.1", tagged.commit.?.tag_last.?);
    try std.testing.expectEqualStrings("v0.0.1", ahead.commit.?.tag_last.?);
    try std.testing.expectEqual(null, untagged.commit.?.tag_last);
    try std.testing.expectEqual(null, stamped("0.1.0", "").commit);
    try std.testing.expectEqual(null, stamped("0.1.0", "53b0f5d92").commit);
}
