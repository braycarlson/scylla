const std = @import("std");
const assert = std.debug.assert;
const parts = @import("parts.zig");
const scan = @import("../../text/scan.zig");
const Diff = @import("../../cli/diff.zig");
const FileID = @import("../../stdx/file_id.zig").FileID;
const Position = Report.Position;
const Report = @import("report.zig");
const Row = Report.Row;
const Span = @import("../../stdx/bounded/span.zig");
const Terminal = @import("../../cli/terminal.zig");
const Text = Report.Text;
const Tool = Report.Tool;
const characters_max: u32 = 1 << 20;
const rows_max: u32 = 1 << 24;

comptime {
    assert(characters_max * parts.tab_width_columns <= parts.columns_max);
}

fn display_width_columns(text: []const u8, column: u32) u32 {
    const wanted = column -| 1;
    var width_columns: u32 = 0;
    var character_index: u32 = 0;

    assert(text.len <= characters_max);

    for (text) |byte| {
        if (is_continuation(byte)) continue;
        if (character_index >= wanted) break;

        width_columns += if (byte == '\t') parts.tab_width_columns else 1;
        character_index += 1;
    }

    assert(character_index <= wanted);

    return width_columns;
}

fn is_continuation(byte: u8) bool {
    return byte & 0xc0 == 0x80;
}

fn character_count(text: []const u8) u32 {
    var count: u32 = 0;

    assert(text.len <= characters_max);

    for (text) |byte| {
        if (!is_continuation(byte)) count += 1;
    }

    assert(count <= text.len);

    return count;
}

fn write_caret_band(
    out: *Terminal,
    text: []const u8,
    number: u32,
    start: Position,
    end: Position,
) void {
    assert(text.len <= std.math.maxInt(u32));
    assert(number < std.math.maxInt(u32));
    assert(start.line > 0);
    assert(start.line <= end.line);

    const last = character_count(text) +| 1;
    const from = if (number == start.line) start.column else 1;
    const to = if (number == end.line) end.column else last;
    const lead = display_width_columns(text, from);
    const span = @max(display_width_columns(text, to) -| lead, 1);

    assert(span > 0);
    assert(lead <= parts.columns_max);

    parts.push_spaces(out, lead);

    for (0..parts.columns_max) |index| {
        if (index >= span) break;

        out.push("^");
    }
}

fn write_escaped_github(out: *Terminal, message: []const u8) void {
    var run_start: usize = 0;

    assert(message.len <= characters_max);

    for (message, 0..) |byte, index| {
        const escaped: []const u8 = switch (byte) {
            '%' => "%25",
            '\r' => "%0D",
            '\n' => "%0A",
            else => continue,
        };

        out.push(message[run_start..index]);
        out.push(escaped);
        run_start = index + 1;
    }

    assert(run_start <= message.len);

    out.push(message[run_start..]);
}

fn write_escaped_xml(out: *Terminal, text: []const u8) void {
    var run_start: usize = 0;

    assert(text.len <= characters_max);

    for (text, 0..) |byte, index| {
        const escaped: []const u8 = switch (byte) {
            '&' => "&amp;",
            '<' => "&lt;",
            '>' => "&gt;",
            '"' => "&quot;",
            else => continue,
        };

        out.push(text[run_start..index]);
        out.push(escaped);
        run_start = index + 1;
    }

    assert(run_start <= text.len);

    out.push(text[run_start..]);
}

fn write_expanded(out: *Terminal, text: []const u8) void {
    var run_start: usize = 0;

    assert(text.len <= characters_max);

    for (text, 0..) |byte, index| {
        if (byte != '\t') continue;

        out.push(text[run_start..index]);
        parts.push_spaces(out, parts.tab_width_columns);
        run_start = index + 1;
    }

    assert(run_start <= text.len);

    out.push(text[run_start..]);
}

fn write_snippet(out: *Terminal, text: Text, span: Span, start: Position, end: Position) u32 {
    assert(span.length <= std.math.maxInt(u32) - span.offset);
    assert(text.lines.line_start(text.lines.count() - 1) <= text.source.len);
    assert(start.line > 0);
    assert(start.line <= end.line);

    const length: u32 = @intCast(@min(text.source.len, std.math.maxInt(u32)));
    const first = text.lines.line_of(@min(span.offset, length));
    var last = text.lines.line_of(@min(span.end(), length));

    if (last > first) {
        if (text.lines.line_start(last) == span.end()) last -= 1;
    }

    const shown_last = @min(last, (first + parts.snippet_line_count_max) -| 1);
    const truncated = last > shown_last;
    const gutter = scan.decimal_width(shown_last +| 1);

    assert(shown_last >= first);
    assert(gutter > 0);

    parts.push_spaces(out, gutter);
    out.push(" |\n");

    for (first..shown_last + 1) |line_index| {
        const line: u32 = @intCast(line_index);
        const held = parts.line_text(text, line);
        const number = line +| 1;

        parts.push_spaces(out, gutter - scan.decimal_width(number));
        out.push_format("{d} | ", .{number});
        write_expanded(out, held);
        out.push("\n");

        if (number != start.line) {
            if (number != end.line) continue;
        }

        parts.push_spaces(out, gutter);
        out.push(" | ");
        write_caret_band(out, held, number, start, end);
        out.push("\n");
    }

    if (truncated) {
        parts.push_spaces(out, gutter);
        out.push(" | ...\n");
    }

    parts.push_spaces(out, gutter);
    out.push(" |\n");

    return gutter;
}

fn grouped_width(comptime Rows: type, rows: *const Rows, row_first: u32) u32 {
    assert(row_first < rows.count());

    const file = rows.row(row_first).file;
    var width_columns: u32 = 1;

    for (row_first..rows.count()) |index| {
        const row = rows.row(@intCast(index));
        if (row.file != file) break;

        const location = parts.position_of(rows.text(row.file), row.span.offset);

        width_columns = @max(width_columns, location_width(location));
    }

    assert(width_columns >= 1);

    return width_columns;
}

fn location_width(location: Position) u32 {
    assert(location.line > 0);
    assert(location.column > 0);

    const result = scan.decimal_width(location.line) + scan.decimal_width(location.column) + 1;

    assert(result >= 3);

    return result;
}

pub fn junit_close(out: *Terminal) void {
    assert(out.capacity() > 0);

    out.push("</testsuites>\n");
}

pub fn junit_file(comptime Rows: type, report: *Report, rows: *const Rows) void {
    assert(report.body.capacity() > 0);

    const streamed_before = report.streamed;

    junit_suites(Rows, &report.body, rows);
    report.streamed +|= rows.count();

    assert(report.streamed >= streamed_before);
}

pub fn junit_open(out: *Terminal, count: u32, tool: *const Tool) void {
    assert(tool.name.len > 0);
    assert(count < std.math.maxInt(u32));

    out.push("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n");

    out.push_line(
        "<testsuites name=\"{s}\" tests=\"{d}\" failures=\"{d}\">",
        .{ tool.name, count, count },
    );
}

fn junit_suites(comptime Rows: type, out: *Terminal, rows: *const Rows) void {
    assert(out.capacity() > 0);

    var current: ?FileID = null;

    assert(rows.count() <= rows_max);

    for (0..rows.count()) |index| {
        const file = rows.row(@intCast(index)).file;

        if (current) |held| {
            if (held == file) continue;
        }

        if (junit_seen(Rows, rows, file, @intCast(index))) continue;

        current = file;

        write_testsuite(Rows, out, rows, file);
    }
}

fn junit_seen(comptime Rows: type, rows: *const Rows, file: FileID, index: u32) bool {
    assert(index < rows.count());
    assert(@backingInt(file) != std.math.maxInt(u32));

    for (0..index) |earlier| {
        if (rows.row(@intCast(earlier)).file == file) return true;
    }

    return false;
}

pub fn render_azure(comptime Rows: type, out: *Terminal, rows: *const Rows) void {
    assert(out.capacity() > 0);
    assert(rows.count() <= rows_max);

    for (0..rows.count()) |index| {
        const row = rows.row(@intCast(index));
        const text = rows.text(row.file);
        const path = parts.shown_path(text);
        const location = parts.position_of(text, row.span.offset);
        const level = row.severity.azure_kind();

        out.push_format(
            "##vso[task.logissue type={s};sourcepath={s};" ++
                "linenumber={d};columnnumber={d};code={s};]",
            .{ level, path, location.line, location.column, row.code },
        );

        out.push(scan.utf8_or(row.message, ""));
        out.push("\n");
    }
}

pub fn render_concise(
    comptime Rows: type,
    out: *Terminal,
    report: *Report,
    rows: *const Rows,
    tool: *const Tool,
) void {
    assert(tool.name.len > 0);
    assert(rows.count() <= rows_max);

    for (0..rows.count()) |index| {
        const row = rows.row(@intCast(index));

        write_headline(Rows, out, report, rows, tool, &row);
        write_related(Rows, out, rows, @intCast(index));
    }
}

pub fn render_full(
    comptime Rows: type,
    out: *Terminal,
    report: *Report,
    rows: *const Rows,
    tool: *const Tool,
) void {
    assert(tool.name.len > 0);
    assert(rows.count() <= rows_max);

    for (0..rows.count()) |index| {
        const row = rows.row(@intCast(index));
        const text = rows.text(row.file);

        write_headline(Rows, out, report, rows, tool, &row);

        const start = parts.position_of(text, row.span.offset);
        const end = parts.position_of(text, row.span.end());
        const gutter = write_snippet(out, text, row.span, start, end);

        if (row.fix) |fix| {
            parts.push_spaces(out, gutter);
            out.push(" = help: ");
            out.push(scan.utf8_or(fix.title, ""));
            out.push("\n");
            write_fix_diff(Rows, out, report, rows, @intCast(index), text);

            if (fix.applicability.fix_note()) |note| {
                parts.push_spaces(out, gutter);
                out.push_line(" = note: {s}", .{note});
            }
        }

        write_related(Rows, out, rows, @intCast(index));
        out.push("\n");
    }
}

pub fn render_github(comptime Rows: type, out: *Terminal, rows: *const Rows) void {
    assert(out.capacity() > 0);
    assert(rows.count() <= rows_max);

    for (0..rows.count()) |index| {
        const row = rows.row(@intCast(index));
        const text = rows.text(row.file);
        const path = parts.shown_path(text);
        const location = parts.position_of(text, row.span.offset);
        const level = row.severity.github_level();

        out.push_format(
            "::{s} file={s},line={d},col={d},title={s} {s}::",
            .{ level, path, location.line, location.column, row.code, row.rule },
        );

        write_escaped_github(out, scan.utf8_or(row.message, ""));
        out.push("\n");
    }
}

pub fn render_grouped(
    comptime Rows: type,
    out: *Terminal,
    report: *Report,
    rows: *const Rows,
    tool: *const Tool,
) void {
    assert(tool.name.len > 0);

    var current: ?FileID = null;
    var width_columns: u32 = 1;

    assert(rows.count() <= rows_max);

    for (0..rows.count()) |index| {
        const row = rows.row(@intCast(index));
        const text = rows.text(row.file);
        const location = parts.position_of(text, row.span.offset);

        if (current != row.file) {
            if (report.streamed > 0) out.push("\n");

            out.push_line("{s}:", .{parts.shown_path(text)});
            current = row.file;
            width_columns = grouped_width(Rows, rows, @intCast(index));
        }

        out.push_format("  {d}:{d}", .{ location.line, location.column });
        parts.push_spaces(out, width_columns -| location_width(location));
        out.push("  ");
        parts.painted_severity_name(out, &row);
        out.push(" ");
        parts.painted_code(out, report, tool, row.code);
        out.push(parts.fixable_mark(&row));
        out.push(" ");
        out.push(scan.utf8_or(row.message, ""));
        out.push("\n");
        report.streamed +|= 1;
    }
}

pub fn render_junit(
    comptime Rows: type,
    out: *Terminal,
    rows: *const Rows,
    tool: *const Tool,
) void {
    assert(tool.name.len > 0);
    assert(rows.count() <= rows_max);

    junit_open(out, rows.count(), tool);
    junit_suites(Rows, out, rows);
    junit_close(out);
}

pub fn render_pylint(comptime Rows: type, out: *Terminal, rows: *const Rows) void {
    assert(out.capacity() > 0);
    assert(rows.count() <= rows_max);

    for (0..rows.count()) |index| {
        const row = rows.row(@intCast(index));
        const text = rows.text(row.file);
        const path = parts.shown_path(text);
        const location = parts.position_of(text, row.span.offset);

        out.push_format("{s}:{d}: [{s}] ", .{ path, location.line, row.code });
        out.push(scan.utf8_or(row.message, ""));
        out.push("\n");
    }
}

fn write_fix_diff(
    comptime Rows: type,
    out: *Terminal,
    report: *Report,
    rows: *const Rows,
    index: u32,
    text: Text,
) void {
    assert(index < rows.count());
    assert(text.lines.line_start(text.lines.count() - 1) <= text.source.len);

    const edit_count = rows.edit_count(index);
    if (edit_count == 0) return;

    const length: u32 = @intCast(@min(text.source.len, std.math.maxInt(u32)));
    var lowest: u32 = std.math.maxInt(u32);
    var highest: u32 = 0;

    for (0..edit_count) |at| {
        const edit = rows.edit(index, @intCast(at));

        lowest = @min(lowest, edit.span.offset);
        highest = @max(highest, edit.span.end());
    }

    const first = text.lines.line_of(@min(lowest, length)) -| parts.fix_context_line_count;

    const last = @min(
        text.lines.line_of(@min(highest, length)) +| parts.fix_context_line_count,
        text.lines.count() -| 1,
    );

    const window_start = text.lines.line_start(first);
    const window_end = text.lines.line_end(last, text.source);
    if (window_start > window_end) return;

    assert(window_end <= length);

    write_fix_window(Rows, report, rows, index, text, window_start, window_end) catch |err| {
        switch (err) {
            error.Overflow => return,
        }
    };

    const before = text.source[window_start..window_end];
    const texts: Diff.Texts = .{ .after = report.window.const_slice(), .before = before };

    report.diff.write_window(out, &texts, first +| 1) catch |err| switch (err) {
        error.LinesExhausted => return,
    };
}

fn write_fix_window(
    comptime Rows: type,
    report: *Report,
    rows: *const Rows,
    index: u32,
    text: Text,
    window_start: u32,
    window_end: u32,
) error{Overflow}!void {
    assert(window_start <= window_end);
    assert(window_end <= text.source.len);
    assert(index < std.math.maxInt(u32));

    report.window.clear();

    var cursor = window_start;

    for (0..rows.edit_count(index)) |at| {
        const edit = rows.edit(index, @intCast(at));
        const start = @min(@max(edit.span.offset, cursor), window_end);
        const end = @min(@max(edit.span.end(), start), window_end);

        try report.window.push(text.source[@min(cursor, start)..start]);
        try report.window.push(edit.replacement);
        cursor = end;
    }

    try report.window.push(text.source[cursor..window_end]);
}

fn write_headline(
    comptime Rows: type,
    out: *Terminal,
    report: *Report,
    rows: *const Rows,
    tool: *const Tool,
    row: *const Row,
) void {
    assert(tool.name.len > 0);

    const text = rows.text(row.file);
    const path = parts.shown_path(text);
    const location = parts.position_of(text, row.span.offset);

    assert(row.code.len > 0);

    out.push_format("{s}:{d}:{d}: ", .{ path, location.line, location.column });
    parts.painted_severity_name(out, row);
    out.push(" ");
    parts.painted_code(out, report, tool, row.code);
    out.push(parts.fixable_mark(row));
    out.push(" ");
    out.push(scan.utf8_or(row.message, ""));
    out.push("\n");
}

fn write_related(comptime Rows: type, out: *Terminal, rows: *const Rows, index: u32) void {
    assert(out.capacity() > 0);
    assert(index < rows.count());

    for (0..rows.related_count(index)) |at| {
        const related = rows.related(index, @intCast(at));
        const text = rows.text(related.file);
        const path = parts.shown_path(text);
        const location = parts.position_of(text, related.span.offset);

        out.push_format("    {s}:{d}:{d}: ", .{ path, location.line, location.column });
        out.push(scan.utf8_or(related.message, ""));
        out.push("\n");
    }
}

fn write_testsuite(comptime Rows: type, out: *Terminal, rows: *const Rows, file: FileID) void {
    assert(rows.count() > 0);
    assert(@backingInt(file) != std.math.maxInt(u32));

    const text = rows.text(file);
    const path = parts.shown_path(text);
    var count: u32 = 0;

    for (0..rows.count()) |index| {
        if (rows.row(@intCast(index)).file == file) count += 1;
    }

    assert(count > 0);

    out.push("  <testsuite name=\"");
    write_escaped_xml(out, path);
    out.push_line("\" tests=\"{d}\" failures=\"{d}\">", .{ count, count });

    for (0..rows.count()) |index| {
        const row = rows.row(@intCast(index));
        if (row.file != file) continue;

        const location = parts.position_of(text, row.span.offset);

        out.push_format(
            "    <testcase name=\"{s} {d}:{d}\" classname=\"",
            .{ row.code, location.line, location.column },
        );

        write_escaped_xml(out, path);
        out.push_format("\">\n      <failure type=\"{s}\" message=\"", .{row.code});
        write_escaped_xml(out, scan.utf8_or(row.message, ""));

        out.push_line(
            "\">{s} at {d}:{d}</failure>\n    </testcase>",
            .{ row.severity.name(), location.line, location.column },
        );
    }

    out.push("  </testsuite>\n");
}

const test_out_bytes_max: u32 = 1 << 14;

fn test_memory(gpa: std.mem.Allocator) !Terminal {
    return Terminal.init(gpa, &.{ .buffer_bytes_max = test_out_bytes_max, .target = .memory });
}

fn test_band(text: []const u8, number: u32, start: Position, end: Position) ![]u8 {
    assert(text.len <= std.math.maxInt(u32));
    assert(number < std.math.maxInt(u32));
    assert(start.line > 0);
    assert(start.line <= end.line);

    const gpa = std.testing.allocator;
    var out = try test_memory(gpa);
    defer out.deinit(gpa);

    write_caret_band(&out, text, number, start, end);

    return gpa.dupe(u8, out.contents());
}

fn test_expect_band(
    expected: []const u8,
    text: []const u8,
    number: u32,
    start: Position,
    end: Position,
) !void {
    assert(text.len <= std.math.maxInt(u32));
    assert(number < std.math.maxInt(u32));
    assert(start.line > 0);
    assert(start.line <= end.line);

    const band = try test_band(text, number, start, end);
    defer std.testing.allocator.free(band);

    try std.testing.expectEqualStrings(expected, band);
}

test "carets sit under the range they mark" {
    const start: Position = .{ .column = 5, .line = 1 };
    const end: Position = .{ .column = 8, .line = 1 };

    try test_expect_band("    ^^^", "abcdefgh", 1, start, end);
}

test "a tab widens the run up to the carets" {
    const start: Position = .{ .column = 2, .line = 1 };
    const end: Position = .{ .column = 4, .line = 1 };

    try std.testing.expectEqual(@as(u32, 4), display_width_columns("\tab", 2));
    try test_expect_band("    ^^", "\tab", 1, start, end);
}

test "an empty range still takes one caret" {
    const at: Position = .{ .column = 3, .line = 1 };

    try test_expect_band("  ^", "abcd", 1, at, at);
}

test "a range running past a line is marked to that line s end" {
    const start: Position = .{ .column = 3, .line = 1 };
    const end: Position = .{ .column = 2, .line = 3 };

    try test_expect_band("  ^^", "abcd", 1, start, end);
    try test_expect_band("^", "abcd", 3, start, end);
}

test "workflow commands escape what would end them" {
    const gpa = std.testing.allocator;
    var out = try test_memory(gpa);
    defer out.deinit(gpa);

    write_escaped_github(&out, "a\nb%c\rd");

    try std.testing.expectEqualStrings("a%0Ab%25c%0Dd", out.contents());
}

test "markup in a message is escaped for xml" {
    const gpa = std.testing.allocator;
    var out = try test_memory(gpa);
    defer out.deinit(gpa);

    write_escaped_xml(&out, "a <b> & \"c\" 'd'");

    try std.testing.expectEqualStrings("a &lt;b&gt; &amp; &quot;c&quot; 'd'", out.contents());
}
