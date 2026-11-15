const std = @import("std");
const assert = std.debug.assert;
const bounded = @import("../../stdx/bounded.zig");
const json_report = @import("json.zig");
const parts = @import("parts.zig");
const scan = @import("../../text/scan.zig");
const text_report = @import("text.zig");
const Applicability = @import("../fixes.zig").Applicability;
const Buffer = bounded.Buffer;
const Diff = @import("../../cli/diff.zig");
const FileID = @import("../../stdx/file_id.zig").FileID;
const Format = @import("format.zig").Format;
const JsonWriter = @import("json").Writer;
const LineIndex = @import("../../text/line_index.zig").LineIndex;
const Registry = @import("../rule/registry.zig");
const Severity = @import("../diagnostics.zig").Severity;
const Span = bounded.Span;
const Terminal = @import("../../cli/terminal.zig");

body: Terminal,
diff: Diff,
format: Format,
json: JsonWriter,
painted: Buffer,
sink: Terminal.Sink,
streamed: u32,
tally: bounded.ArrayType(Count),
tool: Tool,
url: Buffer,
window: Buffer,

const Report = @This();

pub const Capacity = struct {
    body_bytes_max: u32,
    line_count_max: u32,
};

pub const Count = struct {
    code: []const u8,
    count: u32,
    fixable_count: u32,
    rule: []const u8,
};

pub const Options = struct {
    format: Format,
    tool: Tool,
};

pub const Position = struct {
    column: u32,
    line: u32,
};

pub const Row = struct {
    code: []const u8,
    file: FileID,
    fix: ?Fix,
    message: []const u8,
    rule: []const u8,
    severity: Severity,
    span: Span,

    pub const Edit = struct {
        replacement: []const u8,
        span: Span,
    };

    pub const Fix = struct {
        applicability: Applicability,
        title: []const u8,
    };

    pub const Related = struct {
        file: FileID,
        message: []const u8,
        span: Span,
    };
};

pub const Text = struct {
    lines: *const LineIndex,
    path: []const u8,
    source: []const u8,
};

pub const Tool = struct {
    information_uri: []const u8,
    name: []const u8,
    rule_uri_prefix: []const u8,
    rule_uri_suffix: []const u8,
    version: []const u8,
};

const painted_bytes_max: u32 = 256;
pub const tally_rows_max: u32 = 256;
const url_bytes_max: u32 = 1 << 10;
const window_bytes_max: u32 = 1 << 16;

comptime {
    assert(std.fmt.count("{d}", .{std.math.maxInt(u32)}) <= painted_bytes_max);
    assert(std.fmt.count("{x:0>16}", .{std.math.maxInt(u64)}) <= url_bytes_max);
}

pub fn init(
    gpa: std.mem.Allocator,
    capacity: Capacity,
    options: *const Options,
) std.mem.Allocator.Error!Report {
    assert(capacity.body_bytes_max > 0);
    assert(capacity.line_count_max > 0);
    assert(options.tool.name.len > 0);

    var body = try Terminal.init(gpa, &.{
        .buffer_bytes_max = capacity.body_bytes_max,
        .target = .memory,
    });

    errdefer body.deinit(gpa);

    var diff = try Diff.init(gpa, capacity.line_count_max);
    errdefer diff.deinit(gpa);

    var painted = try Buffer.init(gpa, painted_bytes_max);
    errdefer painted.deinit(gpa);

    var tally = try bounded.ArrayType(Count).init(gpa, tally_rows_max);
    errdefer tally.deinit(gpa);

    var url = try Buffer.init(gpa, url_bytes_max);
    errdefer url.deinit(gpa);

    const window = try Buffer.init(gpa, window_bytes_max);

    assert(tally.empty());
    assert(window.empty());

    return .{
        .body = body,
        .diff = diff,
        .format = options.format,
        .json = undefined,
        .painted = painted,
        .sink = undefined,
        .streamed = 0,
        .tally = tally,
        .tool = options.tool,
        .url = url,
        .window = window,
    };
}

pub fn deinit(report: *Report, gpa: std.mem.Allocator) void {
    assert(report.tally.capacity() == tally_rows_max);
    assert(report.url.capacity() == url_bytes_max);

    report.body.deinit(gpa);
    report.diff.deinit(gpa);
    report.painted.deinit(gpa);
    report.tally.deinit(gpa);
    report.url.deinit(gpa);
    report.window.deinit(gpa);
    report.* = undefined;
}

pub fn begin(report: *Report, out: *Terminal) void {
    report.body.clear();
    report.streamed = 0;

    switch (report.format) {
        .gitlab, .json => json_report.array_begin(out, report) catch unreachable,
        .rdjson => json_report.rdjson_begin(out, report) catch unreachable,
        .sarif => json_report.sarif_begin(out, report) catch unreachable,
        .azure, .concise, .full, .github, .grouped, .json_lines, .junit, .pylint => {},
    }

    assert(report.streamed == 0);
    assert(report.body.empty());
}

pub fn end(report: *Report, out: *Terminal, rules: *const Registry) void {
    assert(report.tool.name.len > 0);

    if (report.format == .junit) {
        if (report.streamed > 0) assert(!report.body.empty());
    }

    switch (report.format) {
        .gitlab, .json => json_report.array_end(out, report) catch unreachable,
        .junit => {
            text_report.junit_open(out, report.streamed, &report.tool);
            out.push(report.body.contents());
            text_report.junit_close(out);
        },
        .rdjson => json_report.rdjson_end(out, report, &report.tool) catch unreachable,
        .sarif => json_report.sarif_end(out, report, rules, &report.tool) catch unreachable,
        .azure, .concise, .full, .github, .grouped, .json_lines, .pylint => {},
    }
}

pub fn is_truncated(report: *const Report) bool {
    assert(report.tally.count() <= tally_rows_max);
    assert(report.body.capacity() > 0);

    return report.body.is_truncated();
}

pub fn render_file(report: *Report, comptime Rows: type, out: *Terminal, rows: *const Rows) void {
    comptime rows_check(Rows);

    const streamed_before = report.streamed;
    const tool = &report.tool;

    if (report.format != .junit) assert(report.body.empty());

    switch (report.format) {
        .azure => text_report.render_azure(Rows, out, rows),
        .concise => text_report.render_concise(Rows, out, report, rows, tool),
        .full => text_report.render_full(Rows, out, report, rows, tool),
        .github => text_report.render_github(Rows, out, rows),
        .gitlab => json_report.gitlab_file(Rows, out, report, rows) catch unreachable,
        .grouped => text_report.render_grouped(Rows, out, report, rows, tool),
        .json => json_report.json_file(Rows, out, report, rows, tool) catch unreachable,
        .json_lines => {
            json_report.render_json_lines(Rows, out, report, rows, tool) catch unreachable;
        },
        .junit => text_report.junit_file(Rows, report, rows),
        .pylint => text_report.render_pylint(Rows, out, rows),
        .rdjson => json_report.rdjson_file(Rows, out, report, rows, tool) catch unreachable,
        .sarif => json_report.sarif_file(Rows, out, report, rows) catch unreachable,
    }

    assert(report.streamed >= streamed_before);
}

pub fn statistics(report: *Report, out: *Terminal) bool {
    assert(report.tally.count() <= tally_rows_max);
    assert(report.tool.name.len > 0);

    if (report.tally.empty()) {
        if (report.format == .json) out.push("[]\n");

        return switch (report.format) {
            .concise, .full, .json => true,
            else => false,
        };
    }

    switch (report.format) {
        .concise, .full => {
            statistics_text(out, report, &report.tool);

            return true;
        },
        .json => {
            json_report.statistics_json(out, report, &report.tool) catch unreachable;

            return true;
        },
        .azure, .github, .gitlab, .grouped, .json_lines, .junit, .pylint, .rdjson, .sarif => {
            return false;
        },
    }
}

pub fn streamed_count(report: *const Report) u32 {
    assert(report.body.capacity() > 0);

    if (report.format == .junit) {
        if (report.streamed > 0) assert(!report.body.empty());
    }

    return report.streamed;
}

pub fn tally_fill(report: *Report, counted: []const Count) void {
    assert(counted.len <= tally_rows_max);

    report.tally.clear();

    for (counted) |held| {
        assert(held.count > 0);
        assert(held.fixable_count <= held.count);

        report.tally.push(held);
    }

    std.mem.sortUnstable(Count, report.tally.slice(), {}, tallied_less);

    assert(report.tally.count() == counted.len);
}

fn render(
    report: *Report,
    comptime Rows: type,
    out: *Terminal,
    rows: *const Rows,
    rules: *const Registry,
) void {
    comptime rows_check(Rows);

    assert(report.tool.name.len > 0);
    assert(out.capacity() > 0);

    if (report.format == .junit) {
        text_report.render_junit(Rows, out, rows, &report.tool);

        return;
    }

    report.begin(out);
    report.render_file(Rows, out, rows);
    report.end(out, rules);
}

fn rows_check(comptime Rows: type) void {
    const required = .{
        .{ "count", fn (*const Rows) u32 },
        .{ "edit", fn (*const Rows, u32, u32) Row.Edit },
        .{ "edit_count", fn (*const Rows, u32) u32 },
        .{ "related", fn (*const Rows, u32, u32) Row.Related },
        .{ "related_count", fn (*const Rows, u32) u32 },
        .{ "row", fn (*const Rows, u32) Row },
        .{ "text", fn (*const Rows, FileID) Text },
    };

    inline for (required) |entry| {
        const name = entry[0];

        if (!@hasDecl(Rows, name)) {
            @compileError(@typeName(Rows) ++ " lacks pub fn " ++ name);
        }

        if (@TypeOf(@field(Rows, name)) != entry[1]) {
            @compileError(@typeName(Rows) ++ "." ++ name ++ " is not " ++ @typeName(entry[1]));
        }
    }
}

fn tally_slice(report: *const Report) []const Count {
    assert(report.tally.count() <= tally_rows_max);

    return report.tally.const_slice();
}

fn statistics_text(out: *Terminal, report: *Report, tool: *const Tool) void {
    assert(!report.tally.empty());

    var width_columns: u32 = 1;
    var code_columns: u32 = 0;
    var any_fixable = false;

    for (report.tally.const_slice()) |held| {
        width_columns = @max(width_columns, scan.decimal_width(held.count));
        code_columns = @max(code_columns, @as(u32, @intCast(held.code.len)));
        any_fixable = any_fixable or held.fixable_count > 0;
    }

    assert(code_columns > 0);

    for (0..report.tally.count()) |at| {
        const held = report.tally.get(@intCast(at));

        parts.push_spaces(out, width_columns - scan.decimal_width(held.count));
        report.painted.clear();
        report.painted.print("{d}", .{held.count}) catch unreachable;
        out.painted(report.painted.const_slice(), &.{Terminal.bold});
        out.push("  ");
        parts.painted_code(out, report, tool, held.code);
        parts.push_spaces(out, code_columns - @as(u32, @intCast(held.code.len)));
        out.push("  ");

        if (any_fixable) out.push(fixability_mark(&held));

        out.push(held.rule);
        out.push("\n");
    }
}

fn fixability_mark(held: *const Count) []const u8 {
    assert(held.count > 0);
    assert(held.fixable_count <= held.count);

    if (held.fixable_count == held.count) return "[*] ";
    if (held.fixable_count > 0) return "[-] ";
    return "[ ] ";
}

fn tallied(report: *Report, comptime Rows: type, rows: *const Rows, unsafe_fixes: bool) void {
    comptime rows_check(Rows);
    assert(report.tally.capacity() == tally_rows_max);

    report.tally.clear();

    for (0..rows.count()) |index| {
        const row = rows.row(@intCast(index));
        const fixable = tallied_fixable(&row, unsafe_fixes);

        if (tallied_entry(report, row.code)) |entry| {
            entry.count +|= 1;

            if (fixable) entry.fixable_count +|= 1;

            continue;
        }

        if (report.tally.full()) continue;

        report.tally.push(.{
            .code = row.code,
            .count = 1,
            .fixable_count = @intFromBool(fixable),
            .rule = row.rule,
        });
    }

    std.mem.sortUnstable(Count, report.tally.slice(), {}, tallied_less);

    assert(report.tally.count() <= rows.count());
}

fn tallied_entry(report: *Report, code: []const u8) ?*Count {
    assert(code.len > 0);
    assert(report.tally.count() <= tally_rows_max);

    for (report.tally.slice()) |*held| {
        if (std.mem.eql(u8, held.code, code)) return held;
    }

    return null;
}

fn tallied_fixable(row: *const Row, unsafe_fixes: bool) bool {
    assert(row.code.len > 0);

    const fix = row.fix orelse return false;

    if (unsafe_fixes) return true;
    return fix.applicability == .safe;
}

fn tallied_less(context: void, left: Count, right: Count) bool {
    _ = context;

    assert(left.code.len > 0);
    assert(right.code.len > 0);

    if (left.count != right.count) return left.count > right.count;
    return std.mem.order(u8, left.code, right.code) == .lt;
}

const test_out_bytes_max: u32 = 1 << 14;
const test_page = "<div>\n\t{{ block.super }}\n</div>\n";

const test_tool: Tool = .{
    .information_uri = "https://example.invalid/tool",
    .name = "tool",
    .rule_uri_prefix = "https://example.invalid/rules/",
    .rule_uri_suffix = ".md",
    .version = "1.2.3",
};

const TestRows = struct {
    lines: LineIndex,

    fn init(gpa: std.mem.Allocator) !TestRows {
        var lines = try LineIndex.init(gpa, 16);
        errdefer lines.deinit(gpa);

        try lines.build(test_page);

        assert(lines.count() > 0);

        return .{ .lines = lines };
    }

    fn deinit(rows: *TestRows, gpa: std.mem.Allocator) void {
        rows.lines.deinit(gpa);
    }

    pub fn count(rows: *const TestRows) u32 {
        assert(rows.lines.count() > 0);

        return 2;
    }

    pub fn edit(rows: *const TestRows, index: u32, at: u32) Row.Edit {
        assert(index < rows.count());
        assert(at == 0);

        return .{
            .replacement = "{% block body %}{{ block.super }}{% endblock %}",
            .span = .{ .offset = 7, .length = 17 },
        };
    }

    pub fn edit_count(rows: *const TestRows, index: u32) u32 {
        assert(index < rows.count());

        return @intFromBool(index == 0);
    }

    pub fn related(rows: *const TestRows, index: u32, at: u32) Row.Related {
        assert(index < rows.count());
        assert(at == 0);

        return .{
            .file = FileID.of(0),
            .message = "opened here",
            .span = .{ .offset = 0, .length = 5 },
        };
    }

    pub fn related_count(rows: *const TestRows, index: u32) u32 {
        assert(index < rows.count());

        return @intFromBool(index == 1);
    }

    pub fn row(rows: *const TestRows, index: u32) Row {
        assert(index < rows.count());

        if (index == 0) {
            return .{
                .code = "TP001",
                .file = FileID.of(0),
                .fix = .{ .applicability = .unsafe, .title = "Wrap the super call in a block" },
                .message = "`block.super` outside any block",
                .rule = "template/super-outside-block",
                .severity = .warning,
                .span = .{ .offset = 7, .length = 17 },
            };
        }

        return .{
            .code = "TP002",
            .file = FileID.of(0),
            .fix = null,
            .message = "`div` is never closed",
            .rule = "template/unclosed",
            .severity = .@"error",
            .span = .{ .offset = 0, .length = 5 },
        };
    }

    pub fn text(rows: *const TestRows, file: FileID) Text {
        assert(file.index() == 0);
        assert(rows.lines.count() > 0);

        return .{ .lines = &rows.lines, .path = "templates/page.html", .source = test_page };
    }
};

fn test_report(gpa: std.mem.Allocator, format: Format) !Report {
    const sizes: Capacity = .{ .body_bytes_max = test_out_bytes_max, .line_count_max = 64 };
    return Report.init(gpa, sizes, &.{ .format = format, .tool = test_tool });
}

fn test_memory(gpa: std.mem.Allocator) !Terminal {
    return Terminal.init(gpa, &.{ .buffer_bytes_max = test_out_bytes_max, .target = .memory });
}

test Report {
    const gpa = std.testing.allocator;
    var rows = try TestRows.init(gpa);
    defer rows.deinit(gpa);

    var registry: Registry = try .init(gpa, 4);
    defer registry.deinit(gpa);

    const sizes: Report.Capacity = .{ .body_bytes_max = 1 << 12, .line_count_max = 64 };
    var report: Report = try .init(gpa, sizes, &.{ .format = .pylint, .tool = test_tool });
    defer report.deinit(gpa);

    var out: Terminal = try .init(gpa, &.{ .buffer_bytes_max = 1 << 12, .target = .memory });
    defer out.deinit(gpa);

    report.begin(&out);
    report.render_file(TestRows, &out, &rows);
    report.end(&out, &registry);

    try std.testing.expectEqualStrings(
        "templates/page.html:2: [TP001] `block.super` outside any block\n" ++
            "templates/page.html:1: [TP002] `div` is never closed\n",
        out.contents(),
    );

    try std.testing.expectEqual(@as(u32, 0), report.streamed_count());
    try std.testing.expect(!report.is_truncated());
}

test "a whole render matches a stream of one file in every format" {
    const gpa = std.testing.allocator;
    var rows = try TestRows.init(gpa);
    defer rows.deinit(gpa);

    var registry: Registry = try .init(gpa, 4);
    defer registry.deinit(gpa);

    for (std.enums.values(Format)) |format| {
        var whole_report = try test_report(gpa, format);
        defer whole_report.deinit(gpa);

        var whole = try test_memory(gpa);
        defer whole.deinit(gpa);

        var streamed_report = try test_report(gpa, format);
        defer streamed_report.deinit(gpa);

        var streamed = try test_memory(gpa);
        defer streamed.deinit(gpa);

        whole_report.render(TestRows, &whole, &rows, &registry);
        streamed_report.begin(&streamed);
        streamed_report.render_file(TestRows, &streamed, &rows);
        streamed_report.end(&streamed, &registry);

        try std.testing.expect(!whole.is_truncated());
        try std.testing.expectEqualStrings(whole.contents(), streamed.contents());
    }
}

test "the tally counts each code once and sorts by count" {
    const gpa = std.testing.allocator;
    var rows = try TestRows.init(gpa);
    defer rows.deinit(gpa);

    var report = try test_report(gpa, .full);
    defer report.deinit(gpa);

    report.tallied(TestRows, &rows, false);

    const expected = [_]Count{
        .{
            .code = "TP001",
            .count = 1,
            .fixable_count = 0,
            .rule = "template/super-outside-block",
        },
        .{
            .code = "TP002",
            .count = 1,
            .fixable_count = 0,
            .rule = "template/unclosed",
        },
    };

    try std.testing.expectEqual(expected.len, report.tally_slice().len);

    for (expected, report.tally_slice()) |want, held| {
        try std.testing.expectEqualStrings(want.code, held.code);
        try std.testing.expectEqual(want.count, held.count);
        try std.testing.expectEqual(want.fixable_count, held.fixable_count);
        try std.testing.expectEqualStrings(want.rule, held.rule);
    }

    report.tallied(TestRows, &rows, true);

    try std.testing.expectEqual(@as(u32, 1), report.tally_slice()[0].fixable_count);
}

test "the text statistics align counts and mark fixability" {
    const gpa = std.testing.allocator;
    var rows = try TestRows.init(gpa);
    defer rows.deinit(gpa);

    var report = try test_report(gpa, .full);
    defer report.deinit(gpa);

    var out = try test_memory(gpa);
    defer out.deinit(gpa);

    report.tallied(TestRows, &rows, true);

    try std.testing.expect(report.statistics(&out));

    try std.testing.expectEqualStrings(
        "1  TP001  [*] template/super-outside-block\n1  TP002  [ ] template/unclosed\n",
        out.contents(),
    );

    report.format = .sarif;

    try std.testing.expect(!report.statistics(&out));
}

test "the json statistics count each code of the rows" {
    const gpa = std.testing.allocator;
    var rows = try TestRows.init(gpa);
    defer rows.deinit(gpa);

    var report = try test_report(gpa, .json);
    defer report.deinit(gpa);

    var out = try test_memory(gpa);
    defer out.deinit(gpa);

    report.tallied(TestRows, &rows, false);

    try std.testing.expect(report.statistics(&out));

    try std.testing.expectEqualStrings(
        \\[
        \\  {
        \\    "code": "TP001",
        \\    "count": 1,
        \\    "fixable": false,
        \\    "fixable_count": 0,
        \\    "name": "template/super-outside-block",
        \\    "url": "https://example.invalid/rules/TP001.md"
        \\  },
        \\  {
        \\    "code": "TP002",
        \\    "count": 1,
        \\    "fixable": false,
        \\    "fixable_count": 0,
        \\    "name": "template/unclosed",
        \\    "url": "https://example.invalid/rules/TP002.md"
        \\  }
        \\]
        \\
    , out.contents());
}

test "a filled tally sorts by count" {
    const gpa = std.testing.allocator;
    var report = try test_report(gpa, .full);
    defer report.deinit(gpa);

    const counted = [_]Count{
        .{
            .code = "TP001",
            .count = 1,
            .fixable_count = 0,
            .rule = "template/super-outside-block",
        },
        .{
            .code = "TP002",
            .count = 3,
            .fixable_count = 2,
            .rule = "template/unclosed",
        },
    };

    report.tally_fill(&counted);

    try std.testing.expectEqual(counted.len, report.tally_slice().len);

    for ([_]Count{ counted[1], counted[0] }, report.tally_slice()) |want, held| {
        try std.testing.expectEqualStrings(want.code, held.code);
        try std.testing.expectEqual(want.count, held.count);
        try std.testing.expectEqual(want.fixable_count, held.fixable_count);
        try std.testing.expectEqualStrings(want.rule, held.rule);
    }
}

test "an empty tally writes an empty json array" {
    const gpa = std.testing.allocator;
    var report = try test_report(gpa, .json);
    defer report.deinit(gpa);

    var out = try test_memory(gpa);
    defer out.deinit(gpa);

    try std.testing.expect(report.statistics(&out));
    try std.testing.expectEqualStrings("[]\n", out.contents());
}
