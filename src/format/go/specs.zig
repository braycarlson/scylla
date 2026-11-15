const std = @import("std");
const assert = std.debug.assert;
const Buffer = @import("../../stdx/bounded/buffer.zig");
const ascii_whitespace = @import("../../text/scan.zig").ascii_whitespace;

const Line = struct {
    end: u32,
    start: u32,
};

const Spec = struct {
    comment: []const u8,
    indent: []const u8,
    inner: []const u8,
    left: []const u8,
    name: []const u8,
    path: []const u8,
};

const declaration_words = [_][]const u8{ "const ", "func ", "type ", "var " };
const import_run_max = 256;

pub fn sorted_imports(bytes: []const u8, out: *Buffer) error{Overflow}!void {
    assert(bytes.len < std.math.maxInt(u32));

    out.clear();

    var count: u32 = 0;
    var declared = false;
    var inside = false;
    var offset: u32 = 0;
    var run: [import_run_max]Line = undefined;

    while (offset < bytes.len) {
        const end: u32 = @intCast(std.mem.findScalarPos(u8, bytes, offset, '\n') orelse bytes.len);
        const line = bytes[offset..end];
        const collecting = inside and count < import_run_max;

        assert(count <= import_run_max);
        if (count > 0) assert(inside);

        if (collecting) {
            if (spec_of(line) != null) {
                run[count] = .{ .end = end, .start = offset };
                count += 1;
                offset = end + 1;

                continue;
            }
        }

        try flushed(bytes, run[0..count], out);

        count = 0;

        if (std.mem.eql(u8, line, "import (")) {
            if (!declared) inside = true;
        } else if (std.mem.eql(u8, line, ")")) {
            inside = false;
        } else {}

        for (declaration_words) |word| {
            if (std.mem.startsWith(u8, line, word)) declared = true;
        }

        try out.push(line);

        if (end < bytes.len) try out.push("\n");

        offset = end + 1;
    }

    try flushed(bytes, run[0..count], out);
}

fn flushed(bytes: []const u8, run: []Line, out: *Buffer) error{Overflow}!void {
    assert(run.len <= import_run_max);
    assert(bytes.len <= std.math.maxInt(u32));

    if (run.len == 1) {
        assert(spec_at(bytes, run[0]) != null);

        try out.push(bytes[run[0].start..run[0].end]);
        try out.push("\n");

        return;
    }

    flushed_sorted(bytes, run);

    for (run, 0..) |line, at| {
        const spec = spec_at(bytes, line) orelse continue;
        if (duplicated(bytes, run, at, &spec)) continue;

        try push_spec(&spec, out);
    }
}

fn flushed_sorted(bytes: []const u8, run: []Line) void {
    assert(run.len <= import_run_max);
    assert(run.len != 1);
    assert(bytes.len <= std.math.maxInt(u32));

    if (run.len < 2) return;

    for (1..run.len) |at| {
        var scan = at;

        while (scan > 0) : (scan -= 1) {
            const before = spec_at(bytes, run[scan - 1]) orelse break;
            const after = spec_at(bytes, run[scan]) orelse break;
            if (ordered(&before, &after)) break;

            std.mem.swap(Line, &run[scan - 1], &run[scan]);
        }
    }
}

fn duplicated(bytes: []const u8, run: []const Line, at: usize, spec: *const Spec) bool {
    assert(at < run.len);
    assert(spec.path.len >= 2);

    if (at + 1 >= run.len) return false;
    assert(bytes.len <= std.math.maxInt(u32));

    const after = spec_at(bytes, run[at + 1]) orelse return false;
    if (!std.mem.eql(u8, unquoted(after.path), unquoted(spec.path))) return false;
    if (!std.mem.eql(u8, after.name, spec.name)) return false;
    return spec.comment.len == 0;
}

fn ordered(before: *const Spec, after: *const Spec) bool {
    assert(before.path.len >= 2);
    assert(after.path.len >= 2);

    const keys_before = [_][]const u8{ unquoted(before.path), before.name, before.comment };
    const keys_after = [_][]const u8{ unquoted(after.path), after.name, after.comment };

    for (keys_before, keys_after) |left, right| {
        switch (std.mem.order(u8, left, right)) {
            .lt => return true,
            .gt => return false,
            .eq => {},
        }
    }

    return true;
}

fn unquoted(text: []const u8) []const u8 {
    assert(text.len >= 2);
    assert(text[0] == text[text.len - 1]);

    if (text.len < 2) return "";

    const quote = text[0];
    const quoting = quote == '"' or quote == '`';
    if (!quoting) return "";
    if (text[text.len - 1] != quote) return "";
    return text[1 .. text.len - 1];
}

fn spec_at(bytes: []const u8, line: Line) ?Spec {
    assert(line.start <= line.end);
    assert(line.end <= bytes.len);

    return spec_of(bytes[line.start..line.end]);
}

fn spec_of(line: []const u8) ?Spec {
    assert(std.mem.findScalar(u8, line, '\n') == null);

    const indent = std.mem.findNone(u8, line, "\t") orelse line.len;
    const body = line[indent..];
    const left = block_comments(body);
    const name = body[left .. left + named_length(body[left..])];
    var at = left + name.len;

    if (name.len > 0) {
        if (at >= body.len) return null;

        if (body[at] == ' ') {
            at += 1;
        } else {
            if (!std.mem.startsWith(u8, body[at..], "/*")) return null;
        }
    }

    const inner_start = at;

    at += block_comments(body[at..]);

    const inner = std.mem.trimEnd(u8, body[inner_start..at], ascii_whitespace);
    const quoted = literal_length(body[at..]) orelse return null;
    const path = body[at .. at + quoted];
    const comment = std.mem.trim(u8, body[at + quoted ..], ascii_whitespace);

    if (comment.len > 0) {
        if (comment[0] != '/') return null;
    }

    assert(path.len >= 2);
    assert(at + quoted <= body.len);

    return .{
        .comment = comment,
        .indent = line[0..indent],
        .inner = inner,
        .left = std.mem.trimEnd(u8, body[0..left], ascii_whitespace),
        .name = name,
        .path = path,
    };
}

fn named_length(text: []const u8) usize {
    assert(text.len <= std.math.maxInt(u32));

    var width: usize = 0;

    for (text) |byte| {
        const naming = std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '.' or byte >= 0x80;
        if (!naming) break;

        width += 1;
    }

    assert(width <= text.len);
    if (width < text.len) assert(!std.ascii.isAlphanumeric(text[width]));

    return width;
}

fn push_spec(spec: *const Spec, out: *Buffer) error{Overflow}!void {
    assert(spec.path.len >= 2);
    assert(std.mem.findNone(u8, spec.indent, "\t") == null);

    try out.push(spec.indent);

    for ([_][]const u8{ spec.left, spec.name }) |part| {
        if (part.len == 0) continue;

        try out.push(part);
        try out.push(" ");
    }

    try out.push(spec.path);

    for ([_][]const u8{ spec.inner, spec.comment }) |part| {
        if (part.len == 0) continue;

        try out.push(" ");
        try out.push(part);
    }

    try out.push("\n");
}

fn block_comments(text: []const u8) usize {
    assert(text.len <= std.math.maxInt(u32));

    var at: usize = 0;

    while (at < text.len) {
        if (!std.mem.startsWith(u8, text[at..], "/*")) break;

        const end = std.mem.find(u8, text[at + 2 ..], "*/") orelse return at;

        at += 2 + end + 2;
        at += std.mem.findNone(u8, text[at..], " ") orelse text.len - at;
    }

    assert(at <= text.len);
    if (at > 0) assert(std.mem.startsWith(u8, text, "/*"));

    return at;
}

fn literal_length(text: []const u8) ?usize {
    assert(text.len < std.math.maxInt(u32));
    assert(std.mem.findScalar(u8, text, '\n') == null);

    if (text.len == 0) return null;

    const quote = text[0];
    const quoting = quote == '"' or quote == '`';
    if (!quoting) return null;

    var at: usize = 1;

    while (at < text.len) {
        const escaped = quote == '"' and text[at] == '\\';

        if (escaped) {
            at += 2;

            continue;
        }

        if (text[at] == quote) {
            assert(at + 1 <= text.len);

            return at + 1;
        }

        at += 1;
    }

    return null;
}

const Case = struct {
    input: []const u8,
    expected: []const u8,
};

test "sorted_imports sorts each run of specs by path, name, and comment" {
    const cases = [_]Case{
        .{
            .input = "package p\n\nimport (\n\t\"os\"\n\t\"fmt\"\n)\n",
            .expected = "package p\n\nimport (\n\t\"fmt\"\n\t\"os\"\n)\n",
        },
        .{
            .input = "import (\n\t\"os\"\n\t\"fmt\"\n\n\t\"github.com/x/y\"\n\t\"bytes\"\n)\n",
            .expected = "import (\n\t\"fmt\"\n\t\"os\"\n\n\t\"bytes\"\n\t\"github.com/x/y\"\n)\n",
        },
        .{
            .input = "import (\n\t\"os\" // os\n\t\"fmt\" // fmt\n)\n",
            .expected = "import (\n\t\"fmt\" // fmt\n\t\"os\" // os\n)\n",
        },
        .{
            .input = "import (\n\t\"os\"\n\t// group\n\t\"fmt\"\n\t\"bytes\"\n)\n",
            .expected = "import (\n\t\"os\"\n\t// group\n\t\"bytes\"\n\t\"fmt\"\n)\n",
        },
        .{
            .input = "import (\n\t\"a\\\"b\"\n\t\"a\"\n)\n",
            .expected = "import (\n\t\"a\"\n\t\"a\\\"b\"\n)\n",
        },
        .{
            .input = "import (\n\t`os`\n\t\"fmt\"\n)\n",
            .expected = "import (\n\t\"fmt\"\n\t`os`\n)\n",
        },
        .{
            .input = "import (\n\t_ \"os\"\n\t. \"fmt\"\n\t\"bytes\"\n)\n",
            .expected = "import (\n\t\"bytes\"\n\t. \"fmt\"\n\t_ \"os\"\n)\n",
        },
        .{
            .input = "import (\n\t\"fmt\" // b\n\t\"fmt\" // a\n)\n",
            .expected = "import (\n\t\"fmt\" // a\n\t\"fmt\" // b\n)\n",
        },
        .{
            .input = "import (\n\t\"ab\"\n\t\"a\"\n\t\"a/b\"\n)\n",
            .expected = "import (\n\t\"a\"\n\t\"a/b\"\n\t\"ab\"\n)\n",
        },
        .{
            .input = "import (\n\t\"os\"\n\t\"fmt\"",
            .expected = "import (\n\t\"fmt\"\n\t\"os\"\n",
        },
    };

    try cases_sorted(&cases);
}

test "sorted_imports drops duplicates and rewrites block comments" {
    const cases = [_]Case{
        .{
            .input = "import (\n\tb \"fmt\"\n\ta \"fmt\"\n\t\"fmt\"\n\t\"fmt\"\n)\n",
            .expected = "import (\n\t\"fmt\"\n\ta \"fmt\"\n\tb \"fmt\"\n)\n",
        },
        .{
            .input = "import (\n\t\"fmt\" // one\n\t\"fmt\"\n)\n",
            .expected = "import (\n\t\"fmt\" // one\n)\n",
        },
        .{
            .input = "import (\n\t/* c */ \"os\"\n\tx /* d */ \"fmt\"\n)\n",
            .expected = "import (\n\tx \"fmt\" /* d */\n\t/* c */ \"os\"\n)\n",
        },
        .{
            .input = "import (\n\tx/* c */\"os\"\n\t\"fmt\"\n)\n",
            .expected = "import (\n\t\"fmt\"\n\tx \"os\" /* c */\n)\n",
        },
    };

    try cases_sorted(&cases);
}

test "sorted_imports leaves lines it cannot read and blocks after a declaration" {
    const cases = [_]Case{
        .{
            .input = "func f() {}\nimport (\n\t\"os\"\n\t\"fmt\"\n)\n",
            .expected = "func f() {}\nimport (\n\t\"os\"\n\t\"fmt\"\n)\n",
        },
        .{ .input = "import (\n\t\"os\"\n)\n", .expected = "import (\n\t\"os\"\n)\n" },
        .{
            .input = "import (\n\tx\t\"os\"\n\t\"fmt\"\n)\n",
            .expected = "import (\n\tx\t\"os\"\n\t\"fmt\"\n)\n",
        },
        .{
            .input = "import (\n\t\"os\" x\n\t\"fmt\"\n)\n",
            .expected = "import (\n\t\"os\" x\n\t\"fmt\"\n)\n",
        },
        .{
            .input = "import (\n\t/* c \"os\"\n\t\"fmt\"\n)\n",
            .expected = "import (\n\t/* c \"os\"\n\t\"fmt\"\n)\n",
        },
        .{
            .input = "import (\n\t\"os\"\n\t\"fmt\"\n)\nimport (\n\t\"b\"\n\t\"a\"\n)\n",
            .expected = "import (\n\t\"fmt\"\n\t\"os\"\n)\nimport (\n\t\"a\"\n\t\"b\"\n)\n",
        },
        .{
            .input = "import (\n\t\"os\"\n\t\"fmt\"\n)\nconst x = 1\n" ++
                "import (\n\t\"b\"\n\t\"a\"\n)\n",
            .expected = "import (\n\t\"fmt\"\n\t\"os\"\n)\nconst x = 1\n" ++
                "import (\n\t\"b\"\n\t\"a\"\n)\n",
        },
    };

    try cases_sorted(&cases);
}

test "sorted_imports flushes a run when it reaches the run limit" {
    var input = try Buffer.init(std.testing.allocator, 4096);
    defer input.deinit(std.testing.allocator);

    var expected = try Buffer.init(std.testing.allocator, 4096);
    defer expected.deinit(std.testing.allocator);

    var out = try Buffer.init(std.testing.allocator, 4096);
    defer out.deinit(std.testing.allocator);

    try input.push("import (\n");
    try expected.push("import (\n");

    for (0..258) |step| {
        var line: [16]u8 = undefined;

        try input.push(try std.mem.print(&line, "\t\"p{d:0>3}\"\n", .{257 - step}));
    }

    for (2..258) |index| {
        var line: [16]u8 = undefined;

        try expected.push(try std.mem.print(&line, "\t\"p{d:0>3}\"\n", .{index}));
    }

    try input.push(")\n");
    try expected.push("\t\"p001\"\n\t\"p000\"\n)\n");
    try sorted_imports(input.const_slice(), &out);
    try std.testing.expectEqual(@as(u32, 2075), out.count());
    try std.testing.expectEqualStrings(expected.const_slice(), out.const_slice());
}

test "sorted_imports reports overflow" {
    var out = try Buffer.init(std.testing.allocator, 14);
    defer out.deinit(std.testing.allocator);

    const input = "import (\n\t\"os\"\n\t\"fmt\"\n)\n";

    try std.testing.expectError(error.Overflow, sorted_imports(input, &out));
    try std.testing.expectEqualStrings("import (\n\t", out.const_slice());
}

fn cases_sorted(cases: []const Case) !void {
    assert(cases.len <= std.math.maxInt(u32));

    var out = try Buffer.init(std.testing.allocator, 4096);
    defer out.deinit(std.testing.allocator);

    for (cases) |case| {
        try sorted_imports(case.input, &out);
        try std.testing.expectEqualStrings(case.expected, out.const_slice());
    }
}
