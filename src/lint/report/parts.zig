const std = @import("std");
const assert = std.debug.assert;
const bounded = @import("../../stdx/bounded.zig");
const scan = @import("../../text/scan.zig");
const Buffer = bounded.Buffer;
const LineIndex = @import("../../text/line_index.zig").LineIndex;
const Position = Report.Position;
const Report = @import("report.zig");
const Row = Report.Row;
const Span = bounded.Span;
const Terminal = @import("../../cli/terminal.zig");
const Text = Report.Text;
const Tool = Report.Tool;
pub const columns_max: u32 = 1 << 22;
pub const fix_context_line_count: u32 = 1;
const path_unknown = "<unknown>";
pub const schema_sarif = "https://json.schemastore.org/sarif-2.1.0.json";
pub const snippet_line_count_max: u32 = 10;
pub const tab_width_columns: u32 = 4;
const utf8_continuation_max: u32 = 3;

pub fn fingerprint_of(path: []const u8, code: []const u8, text: []const u8) u64 {
    assert(code.len > 0);
    assert(path.len <= std.math.maxInt(u32));
    assert(text.len <= std.math.maxInt(u32));

    var hasher = std.hash.Fnv1a_64.init();
    const pieces = [_][]const u8{ path, code, text };

    for (pieces) |piece| {
        hasher.update(piece);
        hasher.update(&.{0xff});
    }

    const hash = hasher.final();

    assert(hash != std.hash.Fnv1a_64.init().value);

    return hash;
}

pub fn fixable_mark(row: *const Row) []const u8 {
    assert(row.code.len > 0);

    if (row.fix != null) return " [*]";
    return "";
}

pub fn line_first_trimmed(text: Text, span: Span) []const u8 {
    assert(text.lines.count() > 0);
    assert(span.length <= std.math.maxInt(u32) - span.offset);

    const length: u32 = @intCast(@min(text.source.len, std.math.maxInt(u32)));
    const line = text.lines.line_of(@min(span.offset, length));

    assert(line < text.lines.count());

    return trimmed_whitespace(line_text(text, line));
}

pub fn line_text(text: Text, line: u32) []const u8 {
    assert(line < text.lines.count());

    const span = text.lines.line_span(line, text.source);

    assert(span.end() <= text.source.len);

    return scan.utf8_or(span.text(text.source), "");
}

pub fn painted_code(out: *Terminal, report: *Report, tool: *const Tool, code: []const u8) void {
    assert(code.len > 0);

    if (!out.is_colored()) {
        out.push(code);

        return;
    }

    url_into(&report.url, tool, code) catch |err| switch (err) {
        error.Overflow => {
            out.painted(code, &.{ Terminal.bold, Terminal.red });

            return;
        },
    };

    report.painted.clear();

    report.painted.print(
        "{s}{s}{s}{s}",
        .{ Terminal.bold, Terminal.red, code, Terminal.reset },
    ) catch |err| {
        switch (err) {
            error.Overflow => {
                out.push(code);

                return;
            },
        }
    };

    out.hyperlink(&.{ .text = report.painted.const_slice(), .url = report.url.const_slice() });
}

pub fn painted_severity_name(out: *Terminal, row: *const Row) void {
    assert(row.code.len > 0);

    const ink = switch (row.severity) {
        .@"error" => Terminal.red,
        .hint, .information => Terminal.blue,
        .warning => Terminal.yellow,
    };

    assert(ink.len > 0);

    out.painted(row.severity.name(), &.{ Terminal.bold, ink });
}

pub fn position_of(text: Text, offset: u32) Position {
    assert(offset < std.math.maxInt(u32));
    assert(text.lines.line_start(text.lines.count() - 1) <= text.source.len);

    const held = text.lines.point_clamped(text.source, offset, .utf32);

    assert(held.line < text.lines.count());
    assert(held.character <= text.source.len);

    return .{ .column = held.character +| 1, .line = held.line +| 1 };
}

pub fn push_spaces(out: *Terminal, count: u32) void {
    assert(count <= columns_max);

    for (0..columns_max) |index| {
        if (index >= count) break;

        out.push(" ");
    }
}

pub fn shown_path(text: Text) []const u8 {
    assert(text.lines.line_start(text.lines.count() - 1) <= text.source.len);

    const result = scan.utf8_or(text.path, path_unknown);

    assert(result.len > 0);

    return result;
}

pub fn url_into(url: *Buffer, tool: *const Tool, code: []const u8) Buffer.CapacityError!void {
    assert(code.len > 0);

    url.clear();
    try url.push(tool.rule_uri_prefix);
    try url.push(code);
    try url.push(tool.rule_uri_suffix);

    assert(url.count() >= code.len);
}

fn trimmed_whitespace(text: []const u8) []const u8 {
    assert(text.len <= std.math.maxInt(u32));

    var start: usize = 0;
    var stop: usize = text.len;

    for (0..text.len) |_| {
        const width = whitespace_width_at(text, start);
        if (width == 0) break;

        start += width;
    }

    for (0..text.len) |_| {
        if (stop <= start) break;

        const width = whitespace_width_before(text[start..stop]);
        if (width == 0) break;

        stop -= width;
    }

    assert(start <= stop);
    assert(stop <= text.len);

    return text[start..stop];
}

fn whitespace_width_at(text: []const u8, offset: usize) usize {
    assert(offset <= text.len);

    if (offset >= text.len) return 0;

    const width = std.unicode.utf8ByteSequenceLength(text[offset]) catch return 0;
    if (offset + width > text.len) return 0;

    const sequence = text[offset..][0..width];

    const point = switch (width) {
        1 => sequence[0],
        2 => std.unicode.utf8Decode2(sequence[0..2].*),
        3 => std.unicode.utf8Decode3(sequence[0..3].*),
        4 => std.unicode.utf8Decode4(sequence[0..4].*),
        else => unreachable,
    } catch return 0;

    if (!is_whitespace(point)) return 0;
    return width;
}

fn whitespace_width_before(text: []const u8) usize {
    assert(text.len > 0);

    var start = text.len - 1;

    for (0..utf8_continuation_max) |_| {
        if (start == 0) break;
        if (text[start] & 0xc0 != 0x80) break;

        start -= 1;
    }

    const width = whitespace_width_at(text, start);
    if (start + width != text.len) return 0;
    return width;
}

fn is_whitespace(point: u21) bool {
    return switch (point) {
        0x09...0x0d, 0x20, 0x85, 0xa0, 0x1680, 0x2000...0x200a => true,
        0x2028, 0x2029, 0x202f, 0x205f, 0x3000 => true,
        else => false,
    };
}

test "a line is trimmed of the whitespace rust trims" {
    try std.testing.expectEqualStrings("a b", trimmed_whitespace("\x0b\u{00a0} a b\u{3000}\t"));
    try std.testing.expectEqualStrings("", trimmed_whitespace(" \u{2028} "));
    try std.testing.expectEqualStrings("\u{00e9}", trimmed_whitespace("\u{00e9}"));
}

test "locations are one based character columns" {
    const gpa = std.testing.allocator;
    const source = "<div>\n\t{{ block.super }}\n</div>\n";
    var lines: LineIndex = try .init(gpa, 16);
    defer lines.deinit(gpa);

    try lines.build(source);

    const text: Text = .{ .lines = &lines, .path = "templates/page.html", .source = source };

    try std.testing.expectEqual(Position{ .column = 1, .line = 1 }, position_of(text, 0));
    try std.testing.expectEqual(Position{ .column = 2, .line = 2 }, position_of(text, 7));
    try std.testing.expectEqual(Position{ .column = 1, .line = 4 }, position_of(text, 999));
}

test "a fingerprint matches the reference renderer" {
    const fingerprint = fingerprint_of(
        "./templates/django/child.html",
        "DG009",
        "{{ block.super }}",
    );

    try std.testing.expectEqual(@as(u64, 0xbd26_916e_ae1d_a9a4), fingerprint);
}
