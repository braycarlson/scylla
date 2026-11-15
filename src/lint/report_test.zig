const std = @import("std");
const assert = std.debug.assert;
const json = @import("json");
const report_testing = @import("testing/report.zig");
const FileID = @import("../stdx/file_id.zig").FileID;
const Format = @import("report.zig").Format;
const LineIndex = @import("../text/line_index.zig").LineIndex;
const Registry = @import("rule.zig").Registry;
const Report = @import("report.zig").Report;
const Rule = @import("rule.zig").Rule;
const Severity = @import("diagnostics.zig").Severity;
const Span = @import("../stdx/bounded/span.zig");
const StaticAllocator = @import("../stdx/static_allocator.zig");
const Terminal = @import("../cli/terminal.zig");
const rule_of = report_testing.rule_of;

const Seed = struct {
    code: []const u8,
    column: u32,
    file: u32,
    length: u32,
    line: u32,
    message: []const u8,
    rule: []const u8,
    severity: Severity,
};

const RelatedSeed = struct {
    line: u32,
    message: []const u8,
    row: u32,
};

const Chunk = struct {
    row_count: u32,
    row_first: u32,
    whole: *const Fixture,

    pub fn count(chunk: *const Chunk) u32 {
        assert(chunk.row_first + chunk.row_count <= chunk.whole.count());

        return chunk.row_count;
    }

    pub fn edit(chunk: *const Chunk, index: u32, at: u32) Report.Row.Edit {
        assert(index < chunk.row_count);
        assert(at < std.math.maxInt(u32));

        return chunk.whole.edit(chunk.row_first + index, at);
    }

    pub fn edit_count(chunk: *const Chunk, index: u32) u32 {
        assert(index < chunk.row_count);

        return chunk.whole.edit_count(chunk.row_first + index);
    }

    pub fn related(chunk: *const Chunk, index: u32, at: u32) Report.Row.Related {
        assert(index < chunk.row_count);
        assert(at < std.math.maxInt(u32));

        return chunk.whole.related(chunk.row_first + index, at);
    }

    pub fn related_count(chunk: *const Chunk, index: u32) u32 {
        assert(index < chunk.row_count);

        return chunk.whole.related_count(chunk.row_first + index);
    }

    pub fn row(chunk: *const Chunk, index: u32) Report.Row {
        assert(index < chunk.row_count);

        return chunk.whole.row(chunk.row_first + index);
    }

    pub fn text(chunk: *const Chunk, file: FileID) Report.Text {
        assert(@backingInt(file) != std.math.maxInt(u32));

        return chunk.whole.text(file);
    }
};

const Fixture = struct {
    child: LineIndex,
    context: LineIndex,
    views: LineIndex,
    views_bytes: [views_bytes_max]u8,
    views_length: u32,

    fn init(fixture: *Fixture, gpa: std.mem.Allocator) !void {
        fixture.views_length = 0;

        for (1..view_line_count + 1) |line| {
            const piece: []const u8 = switch (line) {
                21, 25, 30 => render_line,
                else => "\n",
            };

            assert(fixture.views_length + piece.len <= views_bytes_max);

            @memcpy(fixture.views_bytes[fixture.views_length..][0..piece.len], piece);
            fixture.views_length += @intCast(piece.len);
        }

        assert(fixture.views_length <= views_bytes_max);

        fixture.child = try LineIndex.init(gpa, line_count_max);
        errdefer fixture.child.deinit(gpa);

        fixture.context = try LineIndex.init(gpa, line_count_max);
        errdefer fixture.context.deinit(gpa);

        fixture.views = try LineIndex.init(gpa, line_count_max);
        errdefer fixture.views.deinit(gpa);

        try fixture.child.build(child);
        try fixture.context.build(context);
        try fixture.views.build(fixture.views_source());
    }

    fn deinit(fixture: *Fixture, gpa: std.mem.Allocator) void {
        fixture.child.deinit(gpa);
        fixture.context.deinit(gpa);
        fixture.views.deinit(gpa);
    }

    fn views_source(fixture: *const Fixture) []const u8 {
        assert(fixture.views_length <= views_bytes_max);

        return fixture.views_bytes[0..fixture.views_length];
    }

    fn related_seed(index: u32, at: u32) ?RelatedSeed {
        var seen: u32 = 0;

        assert(index < seeds.len);

        for (related_seeds) |seed| {
            if (seed.row != index) continue;
            if (seen == at) return seed;

            seen += 1;
        }

        return null;
    }

    pub fn count(fixture: *const Fixture) u32 {
        _ = fixture;

        return seeds.len;
    }

    pub fn edit(fixture: *const Fixture, index: u32, at: u32) Report.Row.Edit {
        _ = fixture;
        _ = index;
        _ = at;

        unreachable;
    }

    pub fn edit_count(fixture: *const Fixture, index: u32) u32 {
        assert(index < fixture.count());

        return 0;
    }

    pub fn related(fixture: *const Fixture, index: u32, at: u32) Report.Row.Related {
        assert(index < fixture.count());
        assert(at < fixture.related_count(index));

        const seed = related_seed(index, at) orelse unreachable;

        return .{
            .file = FileID.of(2),
            .message = seed.message,
            .span = span_at(&fixture.views, seed.line, 28, 21),
        };
    }

    pub fn related_count(fixture: *const Fixture, index: u32) u32 {
        var result: u32 = 0;

        assert(index < fixture.count());

        for (related_seeds) |seed| {
            if (seed.row == index) result += 1;
        }

        return result;
    }

    pub fn row(fixture: *const Fixture, index: u32) Report.Row {
        assert(index < fixture.count());

        const seed = seeds[index];
        const held = if (seed.file == 0) &fixture.child else &fixture.context;

        return .{
            .code = seed.code,
            .file = FileID.of(seed.file),
            .fix = null,
            .message = seed.message,
            .rule = seed.rule,
            .severity = seed.severity,
            .span = span_at(held, seed.line, seed.column, seed.length),
        };
    }

    pub fn text(fixture: *const Fixture, file: FileID) Report.Text {
        assert(file.index() <= 2);

        return switch (file.index()) {
            0 => .{
                .lines = &fixture.child,
                .path = "./templates/django/child.html",
                .source = child,
            },
            1 => .{
                .lines = &fixture.context,
                .path = "./templates/django/context.html",
                .source = context,
            },
            else => .{
                .lines = &fixture.views,
                .path = "./app/location/views.py",
                .source = fixture.views_source(),
            },
        };
    }
};

const ChunkRange = struct {
    row_count: u32,
    row_first: u32,
};

const golden_bytes_max: u32 = 1 << 16;
const line_count_max: u32 = 64;
const out_bytes_max: u32 = 1 << 16;
const report_line_count_max: u32 = 1 << 10;
const view_line_count: u32 = 30;
const views_bytes_max: u32 = 512;

const child = "\n\n\n\n\n{{ block.super }}\n\n\n\n\n\n{% block script %}<script></script>{% " ++
    "endblock %}\n\n\n\n\n\n<link rel=\"stylesheet\" href=\"{% static " ++
    "'location/ap.css' %}\">\n";

const context = "\n\n\n\n\n<ul class=\"{% if locations %}has-items{% endif %}\">\n\n    " ++
    "<li>{{ title }}</li>\n";

const render_line = "    return render(request, 'django/context.html')\n";

const formats = [_]Format{
    .azure,
    .concise,
    .full,
    .github,
    .gitlab,
    .grouped,
    .json,
    .json_lines,
    .junit,
    .pylint,
    .rdjson,
    .sarif,
};

const tool: Report.Tool = .{
    .information_uri = "https://github.com/braycarlson/scylla",
    .name = "scylla",
    .rule_uri_prefix = "https://github.com/braycarlson/scylla/blob/main/docs/rules/",
    .rule_uri_suffix = ".md",
    .version = "<version>",
};

const rules = [_]Rule{
    rule_of(
        "DG004",
        "django/unknown-context-variable",
        "Checks for template variables that no view rendering the template puts " ++
            "in its context, and for variables that some of the rendering views leave out.",
    ),
    rule_of(
        "DG008",
        "django/unknown-block",
        "Checks for `{% block %}` tags in a child template whose name no template " ++
            "in its `{% extends %}` chain defines.",
    ),
    rule_of(
        "DG009",
        "django/block-super-outside-block",
        "Checks for `{{ block.super }}` written outside any `{% block %}`, or in a " ++
            "template that extends nothing.",
    ),
    rule_of(
        "DG013",
        "django/unknown-static",
        "Checks for `{% static %}` tags naming a file no `static/` directory in " ++
            "this project holds.",
    ),
};

const seeds = [_]Seed{
    .{
        .code = "DG009",
        .column = 4,
        .file = 0,
        .length = 11,
        .line = 6,
        .message = "`{{ block.super }}` outside any `{% block %}` renders nothing",
        .rule = "django/block-super-outside-block",
        .severity = .warning,
    },
    .{
        .code = "DG008",
        .column = 1,
        .file = 0,
        .length = 49,
        .line = 12,
        .message = "`script` is not a block `django/base.html` or its parents define",
        .rule = "django/unknown-block",
        .severity = .warning,
    },
    .{
        .code = "DG013",
        .column = 41,
        .file = 0,
        .length = 15,
        .line = 18,
        .message = "`location/ap.css` is not a file under any `static/` directory this " ++
            "project has",
        .rule = "django/unknown-static",
        .severity = .warning,
    },
    .{
        .code = "DG004",
        .column = 18,
        .file = 1,
        .length = 9,
        .line = 6,
        .message = "`locations` is not in the context of any view that renders this template. " ++
            "Rendered by `detail_view` in `./app/location/views.py`, `list_view` in " ++
            "`./app/location/views.py`, `stale_view` in `./app/location/views.py`",
        .rule = "django/unknown-context-variable",
        .severity = .warning,
    },
    .{
        .code = "DG004",
        .column = 12,
        .file = 1,
        .length = 5,
        .line = 8,
        .message = "`title` is read here, but `list_view` in `./app/location/views.py`, " ++
            "`stale_view` in `./app/location/views.py` render this template without it",
        .rule = "django/unknown-context-variable",
        .severity = .warning,
    },
};

const related_seeds = [_]RelatedSeed{
    .{ .line = 21, .message = "rendered here by `detail_view` without `locations`", .row = 3 },
    .{ .line = 25, .message = "rendered here by `list_view` without `locations`", .row = 3 },
    .{ .line = 30, .message = "rendered here by `stale_view` without `locations`", .row = 3 },
    .{ .line = 25, .message = "rendered here by `list_view` without `title`", .row = 4 },
    .{ .line = 30, .message = "rendered here by `stale_view` without `title`", .row = 4 },
};

fn span_at(held: *const LineIndex, line: u32, column: u32, length: u32) Span {
    assert(line > 0);
    assert(column > 0);
    assert(length < std.math.maxInt(u32));

    const start = held.line_start(line - 1) + column - 1;
    return .{ .offset = start, .length = length };
}

fn registry_init(gpa: std.mem.Allocator) !Registry {
    var registry: Registry = try .init(gpa, rules.len);

    for (&rules) |*item| registry.register(item);

    assert(registry.count() == rules.len);

    return registry;
}

fn report_init(gpa: std.mem.Allocator, format: Format) !Report {
    const sizes: Report.Capacity = .{
        .body_bytes_max = out_bytes_max,
        .line_count_max = report_line_count_max,
    };

    return Report.init(gpa, sizes, &.{ .format = format, .tool = tool });
}

fn terminal_init(gpa: std.mem.Allocator) !Terminal {
    comptime assert(out_bytes_max >= golden_bytes_max);

    return Terminal.init(gpa, &.{ .buffer_bytes_max = out_bytes_max, .target = .memory });
}

fn rendered_rows(
    gpa: std.mem.Allocator,
    format: Format,
    comptime Rows: type,
    rows: *const Rows,
) ![]u8 {
    var registry = try registry_init(gpa);
    defer registry.deinit(gpa);

    var static_allocator: StaticAllocator = .init(gpa);
    defer static_allocator.deinit();

    const static = static_allocator.allocator();
    var held = try report_init(static, format);
    defer held.deinit(static);

    var out = try terminal_init(static);
    defer out.deinit(static);

    static_allocator.transition_from_init_to_static();
    held.begin(&out);
    held.render_file(Rows, &out, rows);
    held.end(&out, &registry);
    static_allocator.transition_from_static_to_deinit();

    try std.testing.expect(!out.is_truncated());
    try std.testing.expect(!out.is_failed());

    return gpa.dupe(u8, out.contents());
}

fn rendered(gpa: std.mem.Allocator, format: Format) ![]u8 {
    const fixture = try gpa.create(Fixture);
    defer gpa.destroy(fixture);

    try fixture.init(gpa);
    defer fixture.deinit(gpa);

    return rendered_rows(gpa, format, Fixture, fixture);
}

fn streamed(gpa: std.mem.Allocator, format: Format, ranges: []const ChunkRange) ![]u8 {
    assert(ranges.len <= std.math.maxInt(u32));

    const fixture = try gpa.create(Fixture);
    defer gpa.destroy(fixture);

    try fixture.init(gpa);
    defer fixture.deinit(gpa);

    var registry = try registry_init(gpa);
    defer registry.deinit(gpa);

    var static_allocator: StaticAllocator = .init(gpa);
    defer static_allocator.deinit();

    const static = static_allocator.allocator();
    var held = try report_init(static, format);
    defer held.deinit(static);

    var out = try terminal_init(static);
    defer out.deinit(static);

    static_allocator.transition_from_init_to_static();
    held.begin(&out);

    for (ranges) |range| {
        const chunk: Chunk = .{
            .row_count = range.row_count,
            .row_first = range.row_first,
            .whole = fixture,
        };

        held.render_file(Chunk, &out, &chunk);
    }

    held.end(&out, &registry);
    static_allocator.transition_from_static_to_deinit();

    try std.testing.expect(!out.is_truncated());
    try std.testing.expect(!out.is_failed());
    try std.testing.expect(!held.is_truncated());

    return gpa.dupe(u8, out.contents());
}

fn golden_read(gpa: std.mem.Allocator, format: Format) ![]u8 {
    var name_buffer: [16]u8 = undefined;
    const tag = @tagName(format);

    assert(tag.len <= name_buffer.len);

    @memcpy(name_buffer[0..tag.len], tag);
    std.mem.replaceScalar(u8, name_buffer[0..tag.len], '_', '-');

    var path_buffer: [64]u8 = undefined;

    const path = try std.mem.print(&path_buffer, "tests/fixtures/report/{s}.txt", .{
        name_buffer[0..tag.len],
    });

    assert(path.len < path_buffer.len);

    return std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        path,
        gpa,
        .limited(golden_bytes_max),
    );
}

test "every format matches the reference bytes" {
    const gpa = std.testing.allocator;

    for (formats) |format| {
        const golden = try golden_read(gpa, format);
        defer gpa.free(golden);

        const whole = try rendered(gpa, format);
        defer gpa.free(whole);

        try std.testing.expectEqualStrings(golden, whole);
    }
}

test "streaming a run file by file matches rendering it whole" {
    const gpa = std.testing.allocator;

    const split = [_]ChunkRange{
        .{ .row_first = 0, .row_count = 3 },
        .{ .row_first = 3, .row_count = 2 },
    };

    const split_empty = [_]ChunkRange{
        .{ .row_first = 0, .row_count = 3 },
        .{ .row_first = 3, .row_count = 0 },
        .{ .row_first = 3, .row_count = 2 },
    };

    for (formats) |format| {
        const whole = try rendered(gpa, format);
        defer gpa.free(whole);

        const streamed_split = try streamed(gpa, format, &split);
        defer gpa.free(streamed_split);

        const streamed_split_empty = try streamed(gpa, format, &split_empty);
        defer gpa.free(streamed_split_empty);

        try std.testing.expectEqualStrings(whole, streamed_split);
        try std.testing.expectEqualStrings(whole, streamed_split_empty);
    }
}

test "streaming an empty run matches rendering it whole" {
    const gpa = std.testing.allocator;
    const fixture = try gpa.create(Fixture);
    defer gpa.destroy(fixture);

    try fixture.init(gpa);
    defer fixture.deinit(gpa);

    const empty: Chunk = .{ .row_count = 0, .row_first = 0, .whole = fixture };

    for (formats) |format| {
        const streamed_empty = try streamed(gpa, format, &.{});
        defer gpa.free(streamed_empty);

        const whole_empty = try rendered_rows(gpa, format, Chunk, &empty);
        defer gpa.free(whole_empty);

        try std.testing.expectEqualStrings(whole_empty, streamed_empty);
    }
}

const test_rdjson_expected =
    \\{
    \\  "diagnostics": [
    \\    {
    \\      "code": {
    \\        "url": "https://example.invalid/rules/TP001.md",
    \\        "value": "TP001"
    \\      },
    \\      "location": {
    \\        "path": "templates/page.html",
    \\        "range": {
    \\          "end": {
    \\            "column": 19,
    \\            "line": 2
    \\          },
    \\          "start": {
    \\            "column": 2,
    \\            "line": 2
    \\          }
    \\        }
    \\      },
    \\      "message": "`block.super` outside any block",
    \\      "severity": "WARNING",
    \\      "suggestions": [
    \\        {
    \\          "range": {
    \\            "end": {
    \\              "column": 19,
    \\              "line": 2
    \\            },
    \\            "start": {
    \\              "column": 2,
    \\              "line": 2
    \\            }
    \\          },
    \\          "text": "{% block body %}{{ block.super }}{% endblock %}"
    \\        }
    \\      ]
    \\    },
    \\    {
    \\      "code": {
    \\        "url": "https://example.invalid/rules/TP002.md",
    \\        "value": "TP002"
    \\      },
    \\      "location": {
    \\        "path": "templates/page.html",
    \\        "range": {
    \\          "end": {
    \\            "column": 6,
    \\            "line": 1
    \\          },
    \\          "start": {
    \\            "column": 1,
    \\            "line": 1
    \\          }
    \\        }
    \\      },
    \\      "message": "`div` is never closed % of the time",
    \\      "severity": "ERROR",
    \\      "suggestions": []
    \\    }
    \\  ],
    \\  "severity": "WARNING",
    \\  "source": {
    \\    "name": "tool",
    \\    "url": "https://example.invalid/tool"
    \\  }
    \\}
;

const TestDocument = json.DocumentType(.{ .node_count_max = 256, .text_bytes_max = 1 << 12 });
const test_element_count_max: u32 = 1 << 24;

fn test_rendered(format: Format) ![]u8 {
    return report_testing.rendered(std.testing.allocator, format);
}

fn test_expect_rendered(format: Format, expected: []const u8) !void {
    const text = try test_rendered(format);
    defer std.testing.allocator.free(text);

    try std.testing.expectEqualStrings(expected, text);
}

test "the gitlab format carries what code quality reads" {
    const text = try test_rendered(.gitlab);
    defer std.testing.allocator.free(text);

    try std.testing.expectEqualStrings(
        \\[
        \\  {
        \\    "check_name": "TP001",
        \\    "description": "`block.super` outside any block",
        \\    "fingerprint": "97ad2eb8eaa705f7",
        \\    "location": {
        \\      "lines": {
        \\        "begin": 2
        \\      },
        \\      "path": "templates/page.html"
        \\    },
        \\    "severity": "minor"
        \\  },
        \\  {
        \\    "check_name": "TP002",
        \\    "description": "`div` is never closed % of the time",
        \\    "fingerprint": "13d52df7505df7b5",
        \\    "location": {
        \\      "lines": {
        \\        "begin": 1
        \\      },
        \\      "path": "templates/page.html"
        \\    },
        \\    "severity": "major"
        \\  }
        \\]
    , text);
}

test "the json format carries every field a row has" {
    const text = try test_rendered(.json);
    defer std.testing.allocator.free(text);

    try std.testing.expectEqualStrings(
        \\[
        \\  {
        \\    "code": "TP001",
        \\    "column": 2,
        \\    "end_column": 19,
        \\    "end_line": 2,
        \\    "file": "templates/page.html",
        \\    "fixable": true,
        \\    "line": 2,
        \\    "message": "`block.super` outside any block",
        \\    "related": [],
        \\    "rule": "template/super-outside-block",
        \\    "severity": "warning",
        \\    "url": "https://example.invalid/rules/TP001.md"
        \\  },
        \\  {
        \\    "code": "TP002",
        \\    "column": 1,
        \\    "end_column": 6,
        \\    "end_line": 1,
        \\    "file": "templates/page.html",
        \\    "fixable": false,
        \\    "line": 1,
        \\    "message": "`div` is never closed % of the time",
        \\    "related": [
        \\      {
        \\        "column": 12,
        \\        "file": "app/views.py",
        \\        "line": 2,
        \\        "message": "rendered here"
        \\      }
        \\    ],
        \\    "rule": "template/unclosed",
        \\    "severity": "error",
        \\    "url": "https://example.invalid/rules/TP002.md"
        \\  }
        \\]
    , text);
}

test "every json line is a document of its own" {
    const gpa = std.testing.allocator;
    const text = try test_rendered(.json_lines);
    defer gpa.free(text);

    try std.testing.expectEqualStrings(
        "{\"code\":\"TP001\",\"column\":2,\"end_column\":19,\"end_line\":2," ++
            "\"file\":\"templates/page.html\",\"fixable\":true,\"line\":2," ++
            "\"message\":\"`block.super` outside any block\",\"related\":[]," ++
            "\"rule\":\"template/super-outside-block\",\"severity\":\"warning\"," ++
            "\"url\":\"https://example.invalid/rules/TP001.md\"}\n" ++
            "{\"code\":\"TP002\",\"column\":1,\"end_column\":6,\"end_line\":1," ++
            "\"file\":\"templates/page.html\",\"fixable\":false,\"line\":1," ++
            "\"message\":\"`div` is never closed % of the time\",\"related\":[{\"column\":12," ++
            "\"file\":\"app/views.py\",\"line\":2,\"message\":\"rendered here\"}]," ++
            "\"rule\":\"template/unclosed\",\"severity\":\"error\"," ++
            "\"url\":\"https://example.invalid/rules/TP002.md\"}\n",
        text,
    );

    var document: TestDocument = undefined;
    var json_lines = std.mem.splitScalar(u8, text[0 .. text.len - 1], '\n');

    while (json_lines.next()) |line| {
        try document.parse(line);
        try std.testing.expect(document.member(document.root(), "code") != null);
    }
}

test "the rdjson format names its source and lists the edits" {
    const text = try test_rendered(.rdjson);
    defer std.testing.allocator.free(text);

    try std.testing.expectEqualStrings(test_rdjson_expected, text);
}

test "the sarif format lists every rule and result" {
    const gpa = std.testing.allocator;
    const text = try test_rendered(.sarif);
    defer gpa.free(text);

    var document: TestDocument = undefined;

    try document.parse(text);

    const root = document.root();
    const version = document.member(root, "version") orelse return error.TestUnexpectedResult;

    try std.testing.expect(document.text_is(version, "2.1.0"));

    const runs = document.member(root, "runs") orelse return error.TestUnexpectedResult;
    var run_items = document.items(runs);
    const run = run_items.next() orelse return error.TestUnexpectedResult;
    const run_tool = document.member(run, "tool") orelse return error.TestUnexpectedResult;
    const driver = document.member(run_tool, "driver") orelse return error.TestUnexpectedResult;
    const driver_name = document.member(driver, "name") orelse return error.TestUnexpectedResult;

    const driver_version = document.member(driver, "version") orelse {
        return error.TestUnexpectedResult;
    };

    const driver_rules = document.member(driver, "rules");
    const results = document.member(run, "results");

    try std.testing.expect(document.text_is(driver_name, "tool"));
    try std.testing.expect(document.text_is(driver_version, "1.2.3"));
    try std.testing.expectEqual(@as(u32, 2), test_element_count(&document.base, driver_rules));
    try std.testing.expectEqual(@as(u32, 2), test_element_count(&document.base, results));

    try std.testing.expect(std.mem.startsWith(u8, text, "{\n  \"$schema\": " ++
        "\"https://json.schemastore.org/sarif-2.1.0.json\",\n  \"runs\": [\n    {\n" ++
        "      \"results\": [\n        {\n          \"level\": \"warning\",\n"));

    try std.testing.expect(std.mem.find(u8, text, "            {\n" ++
        "              \"helpUri\": \"https://example.invalid/rules/TP001.md\",\n" ++
        "              \"id\": \"TP001\",\n" ++
        "              \"name\": \"template/super-outside-block\",\n" ++
        "              \"shortDescription\": {\n" ++
        "                \"text\": \"Checks for a super call outside any block.\"\n" ++
        "              }\n            },\n") != null);

    try std.testing.expect(std.mem.endsWith(u8, text, "\n  \"version\": \"2.1.0\"\n}"));
}

fn test_element_count(document: *const json.Document, array: ?json.Node) u32 {
    if (array) |held| assert(@backingInt(held) < document.node_count);

    const held = array orelse return 0;

    assert(document.kind_of(held) == .array);

    var elements = document.items(held);
    var count: u32 = 0;

    while (elements.next()) |_| {
        count += 1;

        assert(count <= test_element_count_max);
    }

    return count;
}

test "the json statistics are one object a code" {
    const gpa = std.testing.allocator;
    const sizes: Report.Capacity = .{ .body_bytes_max = out_bytes_max, .line_count_max = 64 };
    var held = try Report.init(gpa, sizes, &.{ .format = .json, .tool = report_testing.tool });
    defer held.deinit(gpa);

    var out = try terminal_init(gpa);
    defer out.deinit(gpa);

    const counted = [_]Report.Count{
        .{ .code = "TP002", .count = 1, .fixable_count = 0, .rule = "template/unclosed" },
        .{
            .code = "TP001",
            .count = 1,
            .fixable_count = 0,
            .rule = "template/super-outside-block",
        },
    };

    held.tally_fill(&counted);

    const written = held.statistics(&out);

    try std.testing.expect(written);

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

test "the azure format logs one issue a row" {
    try test_expect_rendered(.azure, "##vso[task.logissue type=warning;" ++
        "sourcepath=templates/page.html;" ++
        "linenumber=2;columnnumber=2;code=TP001;]`block.super` outside any block\n" ++
        "##vso[task.logissue type=error;sourcepath=templates/page.html;" ++
        "linenumber=1;columnnumber=1;code=TP002;]`div` is never closed % of the time\n");
}

test "the concise format is one headline a row with its related lines" {
    try test_expect_rendered(.concise, "templates/page.html:2:2: warning TP001 [*] " ++
        "`block.super` outside any block\n" ++
        "templates/page.html:1:1: error TP002 `div` is never closed % of the time\n" ++
        "    app/views.py:2:12: rendered here\n");
}

test "the full format quotes the line and shows the fix" {
    try test_expect_rendered(.full, "templates/page.html:2:2: warning TP001 [*] " ++
        "`block.super` outside any block\n" ++
        "  |\n" ++
        "2 |     {{ block.super }}\n" ++
        "  |     ^^^^^^^^^^^^^^^^^\n" ++
        "  |\n" ++
        "  = help: Wrap the super call in a block\n" ++
        "  |\n" ++
        "1 | <div>\n" ++
        "  - \t{{ block.super }}\n" ++
        "2 + \t{% block body %}{{ block.super }}{% endblock %}\n" ++
        "3 | </div>\n" ++
        "  |\n" ++
        "  = note: This is an unsafe fix and may change runtime behavior\n" ++
        "\n" ++
        "templates/page.html:1:1: error TP002 `div` is never closed % of the time\n" ++
        "  |\n" ++
        "1 | <div>\n" ++
        "  | ^^^^^\n" ++
        "  |\n" ++
        "    app/views.py:2:12: rendered here\n" ++
        "\n");
}

test "the github format writes workflow commands" {
    try test_expect_rendered(.github, "::warning file=templates/page.html,line=2,col=2," ++
        "title=TP001 template/super-outside-block::`block.super` outside any block\n" ++
        "::error file=templates/page.html,line=1,col=1," ++
        "title=TP002 template/unclosed::`div` is never closed %25 of the time\n");
}

test "the grouped format names the file once and aligns the locations" {
    try test_expect_rendered(.grouped, "templates/page.html:\n" ++
        "  2:2  warning TP001 [*] `block.super` outside any block\n" ++
        "  1:1  error TP002 `div` is never closed % of the time\n");
}

test "the junit format wraps one suite a file" {
    try test_expect_rendered(.junit, "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" ++
        "<testsuites name=\"tool\" tests=\"2\" failures=\"2\">\n" ++
        "  <testsuite name=\"templates/page.html\" tests=\"2\" failures=\"2\">\n" ++
        "    <testcase name=\"TP001 2:2\" classname=\"templates/page.html\">\n" ++
        "      <failure type=\"TP001\" message=\"`block.super` outside any block\">" ++
        "warning at 2:2</failure>\n" ++
        "    </testcase>\n" ++
        "    <testcase name=\"TP002 1:1\" classname=\"templates/page.html\">\n" ++
        "      <failure type=\"TP002\" message=\"`div` is never closed % of the time\">" ++
        "error at 1:1</failure>\n" ++
        "    </testcase>\n" ++
        "  </testsuite>\n" ++
        "</testsuites>\n");
}

test "the pylint format is path line and code" {
    try test_expect_rendered(.pylint, "templates/page.html:2: [TP001] " ++
        "`block.super` outside any block\n" ++
        "templates/page.html:1: [TP002] `div` is never closed % of the time\n");
}
