const std = @import("std");
const assert = std.debug.assert;
const json = @import("json");
const parts = @import("parts.zig");
const Buffer = @import("../../stdx/bounded/buffer.zig");
const Position = Report.Position;
const Registry = @import("../rule/registry.zig");
const Report = @import("report.zig");
const Rule = @import("../rule/rule.zig");
const Terminal = @import("../../cli/terminal.zig");
const Tool = Report.Tool;
pub const Error = json.Writer.CapacityError || std.Io.Writer.Error;
const rows_max: u32 = 1 << 24;

const compact: json.Writer.Options = .{
    .indent = 2,
    .layout = .compact,
    .non_finite = .refused,
    .notation = .ecmascript,
    .utf8 = .checked,
};

const pretty: json.Writer.Options = .{
    .indent = 2,
    .layout = .pretty,
    .non_finite = .refused,
    .notation = .ecmascript,
    .utf8 = .checked,
};

fn document_open(out: *Terminal, report: *Report, options: json.Writer.Options) *json.Writer {
    assert(out.capacity() > 0);
    assert(options.indent >= 1);

    report.sink = .init(out, &.{});
    report.json = .init(&report.sink.writer, options);

    return &report.json;
}

fn document_resume(out: *Terminal, report: *Report) *json.Writer {
    assert(out.capacity() > 0);
    assert(report.sink.writer.buffer.len == 0);

    report.sink.terminal = out;

    return &report.json;
}

pub fn array_begin(out: *Terminal, report: *Report) Error!void {
    assert(report.streamed == 0);

    const writer = document_open(out, report, pretty);

    try writer.array_begin();
}

pub fn array_end(out: *Terminal, report: *Report) Error!void {
    assert(out.capacity() > 0);

    const writer = document_resume(out, report);

    try writer.array_end();

    writer.finish();
}

pub fn gitlab_file(
    comptime Rows: type,
    out: *Terminal,
    report: *Report,
    rows: *const Rows,
) Error!void {
    const writer = document_resume(out, report);

    assert(rows.count() <= rows_max);

    for (0..rows.count()) |index| {
        const row = rows.row(@intCast(index));
        const text = rows.text(row.file);
        const path = parts.shown_path(text);
        const location = parts.position_of(text, row.span.offset);
        const first = parts.line_first_trimmed(text, row.span);
        const fingerprint = parts.fingerprint_of(path, row.code, first);

        report.url.clear();
        report.url.print("{x:0>16}", .{fingerprint}) catch unreachable;

        try writer.object_begin();
        try writer.key("check_name");
        try writer.string(row.code);
        try writer.key("description");
        try writer.string(row.message);
        try writer.key("fingerprint");
        try writer.string(report.url.const_slice());
        try writer.key("location");
        try writer.object_begin();
        try writer.key("lines");
        try writer.object_begin();
        try writer.key("begin");
        try writer.integer(location.line);
        try writer.object_end();
        try writer.key("path");
        try writer.string(path);
        try writer.object_end();
        try writer.key("severity");
        try writer.string(row.severity.gitlab_severity());
        try writer.object_end();
    }
}

pub fn json_file(
    comptime Rows: type,
    out: *Terminal,
    report: *Report,
    rows: *const Rows,
    tool: *const Tool,
) Error!void {
    const writer = document_resume(out, report);

    assert(rows.count() <= rows_max);

    for (0..rows.count()) |index| {
        try write_json_entry(Rows, writer, &report.url, rows, tool, @intCast(index));
    }
}

pub fn rdjson_begin(out: *Terminal, report: *Report) Error!void {
    assert(report.streamed == 0);

    const writer = document_open(out, report, pretty);

    try writer.object_begin();
    try writer.key("diagnostics");
    try writer.array_begin();
}

pub fn rdjson_end(out: *Terminal, report: *Report, tool: *const Tool) Error!void {
    assert(tool.name.len > 0);

    const writer = document_resume(out, report);

    try writer.array_end();
    try writer.key("severity");
    try writer.string("WARNING");
    try writer.key("source");
    try writer.object_begin();
    try writer.key("name");
    try writer.string(tool.name);
    try writer.key("url");
    try writer.string(tool.information_uri);
    try writer.object_end();
    try writer.object_end();

    writer.finish();
}

pub fn rdjson_file(
    comptime Rows: type,
    out: *Terminal,
    report: *Report,
    rows: *const Rows,
    tool: *const Tool,
) Error!void {
    const writer = document_resume(out, report);

    assert(rows.count() <= rows_max);

    for (0..rows.count()) |index| {
        try write_rdjson_entry(Rows, writer, &report.url, rows, tool, @intCast(index));
    }
}

pub fn render_json_lines(
    comptime Rows: type,
    out: *Terminal,
    report: *Report,
    rows: *const Rows,
    tool: *const Tool,
) Error!void {
    assert(rows.count() <= rows_max);

    for (0..rows.count()) |index| {
        const writer = document_open(out, report, compact);

        try write_json_entry(Rows, writer, &report.url, rows, tool, @intCast(index));

        writer.finish();
        out.push("\n");
    }
}

pub fn sarif_begin(out: *Terminal, report: *Report) Error!void {
    assert(report.streamed == 0);

    const writer = document_open(out, report, pretty);

    try writer.object_begin();
    try writer.key("$schema");
    try writer.string(parts.schema_sarif);
    try writer.key("runs");
    try writer.array_begin();
    try writer.object_begin();
    try writer.key("results");
    try writer.array_begin();
}

pub fn sarif_end(
    out: *Terminal,
    report: *Report,
    rules: *const Registry,
    tool: *const Tool,
) Error!void {
    assert(tool.name.len > 0);

    const writer = document_resume(out, report);

    try writer.array_end();
    try writer.key("tool");
    try writer.object_begin();
    try writer.key("driver");
    try writer.object_begin();
    try writer.key("informationUri");
    try writer.string(tool.information_uri);
    try writer.key("name");
    try writer.string(tool.name);
    try writer.key("rules");
    try writer.array_begin();

    for (rules.slice()) |*held| try sarif_rule(writer, &report.url, held, tool);

    try writer.array_end();
    try writer.key("version");
    try writer.string(tool.version);
    try writer.object_end();
    try writer.object_end();
    try writer.object_end();
    try writer.array_end();
    try writer.key("version");
    try writer.string("2.1.0");
    try writer.object_end();

    writer.finish();
}

fn sarif_rule(writer: *json.Writer, url: *Buffer, rule: *const Rule, tool: *const Tool) Error!void {
    assert(url.capacity() > 0);
    assert(rule.code.len > 0);

    url_written(url, tool, rule.code);

    try writer.object_begin();
    try writer.key("helpUri");
    try writer.string(url.const_slice());
    try writer.key("id");
    try writer.string(rule.code);
    try writer.key("name");
    try writer.string(rule.name);
    try writer.key("shortDescription");
    try writer.object_begin();
    try writer.key("text");
    try writer.string(rule.summary);
    try writer.object_end();
    try writer.object_end();
}

fn url_written(url: *Buffer, tool: *const Tool, code: []const u8) void {
    assert(code.len > 0);

    parts.url_into(url, tool, code) catch |err| switch (err) {
        error.Overflow => assert(url.count() <= url.capacity()),
    };
}

pub fn sarif_file(
    comptime Rows: type,
    out: *Terminal,
    report: *Report,
    rows: *const Rows,
) Error!void {
    const writer = document_resume(out, report);

    assert(rows.count() <= rows_max);

    for (0..rows.count()) |index| {
        try write_sarif_result(Rows, writer, rows, @intCast(index));
    }
}

pub fn statistics_json(out: *Terminal, report: *Report, tool: *const Tool) Error!void {
    assert(tool.name.len > 0);
    assert(!report.tally.empty());

    const writer = document_open(out, report, pretty);

    try writer.array_begin();

    for (report.tally.const_slice()) |held| {
        url_written(&report.url, tool, held.code);

        try writer.object_begin();
        try writer.key("code");
        try writer.string(held.code);
        try writer.key("count");
        try writer.integer(held.count);
        try writer.key("fixable");
        try writer.boolean(held.fixable_count == held.count);
        try writer.key("fixable_count");
        try writer.integer(held.fixable_count);
        try writer.key("name");
        try writer.string(held.rule);
        try writer.key("url");
        try writer.string(report.url.const_slice());
        try writer.object_end();
    }

    try writer.array_end();

    writer.finish();
    out.push("\n");
}

fn write_json_entry(
    comptime Rows: type,
    writer: *json.Writer,
    url: *Buffer,
    rows: *const Rows,
    tool: *const Tool,
    index: u32,
) Error!void {
    assert(index < rows.count());

    const row = rows.row(index);
    const text = rows.text(row.file);
    const start = parts.position_of(text, row.span.offset);
    const end = parts.position_of(text, row.span.end());

    assert(start.line <= end.line);

    url_written(url, tool, row.code);

    try writer.object_begin();
    try writer.key("code");
    try writer.string(row.code);
    try writer.key("column");
    try writer.integer(start.column);
    try writer.key("end_column");
    try writer.integer(end.column);
    try writer.key("end_line");
    try writer.integer(end.line);
    try writer.key("file");
    try writer.string(parts.shown_path(text));
    try writer.key("fixable");
    try writer.boolean(row.fix != null);
    try writer.key("line");
    try writer.integer(start.line);
    try writer.key("message");
    try writer.string(row.message);
    try writer.key("related");
    try writer.array_begin();
    try write_json_related(Rows, writer, rows, index);
    try writer.array_end();
    try writer.key("rule");
    try writer.string(row.rule);
    try writer.key("severity");
    try writer.string(row.severity.name());
    try writer.key("url");
    try writer.string(url.const_slice());
    try writer.object_end();
}

fn write_json_related(
    comptime Rows: type,
    writer: *json.Writer,
    rows: *const Rows,
    index: u32,
) Error!void {
    assert(index < rows.count());

    for (0..rows.related_count(index)) |at| {
        const related = rows.related(index, @intCast(at));
        const held = rows.text(related.file);
        const location = parts.position_of(held, related.span.offset);

        try writer.object_begin();
        try writer.key("column");
        try writer.integer(location.column);
        try writer.key("file");
        try writer.string(parts.shown_path(held));
        try writer.key("line");
        try writer.integer(location.line);
        try writer.key("message");
        try writer.string(related.message);
        try writer.object_end();
    }
}

fn write_range(writer: *json.Writer, start: Position, end: Position) Error!void {
    assert(start.line > 0);
    assert(end.line >= start.line);

    try writer.object_begin();
    try writer.key("end");
    try writer.object_begin();
    try writer.key("column");
    try writer.integer(end.column);
    try writer.key("line");
    try writer.integer(end.line);
    try writer.object_end();
    try writer.key("start");
    try writer.object_begin();
    try writer.key("column");
    try writer.integer(start.column);
    try writer.key("line");
    try writer.integer(start.line);
    try writer.object_end();
    try writer.object_end();
}

fn write_rdjson_entry(
    comptime Rows: type,
    writer: *json.Writer,
    url: *Buffer,
    rows: *const Rows,
    tool: *const Tool,
    index: u32,
) Error!void {
    assert(index < rows.count());

    const row = rows.row(index);
    const text = rows.text(row.file);
    const start = parts.position_of(text, row.span.offset);
    const end = parts.position_of(text, row.span.end());

    assert(start.line <= end.line);

    url_written(url, tool, row.code);

    try writer.object_begin();
    try writer.key("code");
    try writer.object_begin();
    try writer.key("url");
    try writer.string(url.const_slice());
    try writer.key("value");
    try writer.string(row.code);
    try writer.object_end();
    try writer.key("location");
    try writer.object_begin();
    try writer.key("path");
    try writer.string(parts.shown_path(text));
    try writer.key("range");
    try write_range(writer, start, end);
    try writer.object_end();
    try writer.key("message");
    try writer.string(row.message);
    try writer.key("severity");
    try writer.string(row.severity.rdjson_severity());
    try writer.key("suggestions");
    try writer.array_begin();

    if (row.fix != null) {
        for (0..rows.edit_count(index)) |at| {
            const edit = rows.edit(index, @intCast(at));

            try writer.object_begin();
            try writer.key("range");

            try write_range(
                writer,
                parts.position_of(text, edit.span.offset),
                parts.position_of(text, edit.span.end()),
            );

            try writer.key("text");
            try writer.string(edit.replacement);
            try writer.object_end();
        }
    }

    try writer.array_end();
    try writer.object_end();
}

fn write_sarif_result(
    comptime Rows: type,
    writer: *json.Writer,
    rows: *const Rows,
    index: u32,
) Error!void {
    assert(index < rows.count());

    const row = rows.row(index);
    const text = rows.text(row.file);
    const start = parts.position_of(text, row.span.offset);
    const end = parts.position_of(text, row.span.end());

    assert(start.line <= end.line);

    try writer.object_begin();
    try writer.key("level");
    try writer.string(row.severity.sarif_level());
    try writer.key("locations");
    try writer.array_begin();
    try writer.object_begin();
    try writer.key("physicalLocation");
    try writer.object_begin();
    try writer.key("artifactLocation");
    try writer.object_begin();
    try writer.key("uri");
    try writer.string(parts.shown_path(text));
    try writer.object_end();
    try writer.key("region");
    try writer.object_begin();
    try writer.key("endColumn");
    try writer.integer(end.column);
    try writer.key("endLine");
    try writer.integer(end.line);
    try writer.key("startColumn");
    try writer.integer(start.column);
    try writer.key("startLine");
    try writer.integer(start.line);
    try writer.object_end();
    try writer.object_end();
    try writer.object_end();
    try writer.array_end();
    try writer.key("message");
    try writer.object_begin();
    try writer.key("text");
    try writer.string(row.message);
    try writer.object_end();
    try writer.key("ruleId");
    try writer.string(row.code);
    try writer.object_end();
}
