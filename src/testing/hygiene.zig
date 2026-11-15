const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;

pub const Options = struct {
    banned: []const []const u8,
    blank_lines_checked: bool = true,
    comments_allowed: bool = true,
    entry_points: []const []const u8,
    file_lines_max: u32 = 8_192,
    function_lines_max: u32 = 70,
    layers: []const Layer = &.{},
    line_columns_max: u32 = 100,
    quiet: bool = false,
    source_directories: []const []const u8 = &.{ "examples", "src" },
    test_roots: []const []const u8,
};

pub const Layer = struct {
    imports: []const []const u8,
    name: []const u8,
};

pub const Source = struct {
    path: []const u8,
    text: [:0]const u8,
};

pub const Sources = std.ArrayList(Source);
pub const Imported = std.StringArrayHashMapUnmanaged(void);
pub const file_count_max = 4_096;
pub const import_count_max = 1 << 16;
pub const layer_count_max = 64;
pub const line_count_max = 1 << 20;
pub const source_bytes_max = 1 << 22;

pub fn check(gpa: std.mem.Allocator, io: std.Io, options: *const Options) !u32 {
    assert(options.entry_points.len > 0);
    assert(options.test_roots.len > 0);

    var sources = try sources_read(gpa, io, options.source_directories);
    defer sources_free(gpa, &sources);

    var problems: u32 = 0;

    for (sources.items) |source| problems += try file_check(gpa, source, options);

    problems += try graph_check(gpa, sources.items, options);
    problems += try layering_check(gpa, sources.items, options);

    assert(sources.items.len >= options.entry_points.len);

    return problems;
}

pub fn layering_check(
    gpa: std.mem.Allocator,
    sources: []const Source,
    options: *const Options,
) !u32 {
    assert(sources.len <= std.math.maxInt(u32));
    assert(options.layers.len <= layer_count_max);

    var problems: u32 = 0;

    for (sources) |source| {
        const from = layer_checked(source.path, options) orelse continue;

        problems += try layering_problems(gpa, source, from, options);
    }

    return problems;
}

fn layer_checked(path: []const u8, options: *const Options) ?usize {
    assert(path.len <= std.math.maxInt(u32));

    const stem = std.Io.Dir.path.stem(path);

    if (std.mem.endsWith(u8, stem, "_test")) return null;
    if (std.mem.endsWith(u8, stem, "_fuzz")) return null;
    return layer_of(path, options);
}

fn layer_of(path: []const u8, options: *const Options) ?usize {
    assert(path.len <= std.math.maxInt(u32));

    if (!std.mem.startsWith(u8, path, "src/")) return null;

    const relative = path["src/".len..];
    const end = std.mem.findScalar(u8, relative, '/') orelse return null;
    const directory = relative[0..end];

    for (options.layers, 0..) |layer, index| {
        if (std.mem.eql(u8, layer.name, directory)) return index;
    }

    return null;
}

fn layer_admits(from: usize, to: usize, options: *const Options) bool {
    assert(from < options.layers.len);
    assert(to < options.layers.len);

    if (from == to) return true;

    const name = options.layers[to].name;

    for (options.layers[from].imports) |allowed| {
        if (std.mem.eql(u8, allowed, name)) return true;
    }

    return false;
}

fn layering_problems(
    gpa: std.mem.Allocator,
    source: Source,
    from: usize,
    options: *const Options,
) !u32 {
    assert(source.path.len > 0);
    assert(from < options.layers.len);

    const directory = std.Io.Dir.path.dirname(source.path) orelse ".";
    const marker = "@import(\"";
    var offset: usize = 0;
    var count: u32 = 0;
    var problems: u32 = 0;

    while (std.mem.findPos(u8, source.text, offset, marker)) |found| {
        count += 1;

        assert(count <= import_count_max);

        const start = found + marker.len;
        const end = std.mem.findScalarPos(u8, source.text, start, '"') orelse break;
        const target = source.text[start..end];

        offset = end;

        if (!std.mem.endsWith(u8, target, ".zig")) continue;

        const resolved = try std.Io.Dir.path.resolveAllocPosix(gpa, &.{ directory, target });
        defer gpa.free(resolved);

        const to = layer_of(resolved, options) orelse continue;
        if (layer_admits(from, to, options)) continue;

        problem_print(options, "{s}: the {s} layer imports {s} from the {s} layer\n", .{
            source.path,
            options.layers[from].name,
            target,
            options.layers[to].name,
        });

        problems += 1;
    }

    return problems;
}

pub fn sources_read(gpa: std.mem.Allocator, io: std.Io, directories: []const []const u8) !Sources {
    assert(directories.len > 0);

    var sources: Sources = .empty;
    errdefer sources_free(gpa, &sources);

    for (directories) |name| try directory_read(gpa, io, &sources, name);

    const path = try gpa.dupe(u8, "build.zig");
    errdefer gpa.free(path);

    try sources.append(gpa, .{ .path = path, .text = try source_read(gpa, io, path) });

    return sources;
}

pub fn sources_free(gpa: std.mem.Allocator, sources: *Sources) void {
    for (sources.items) |source| {
        gpa.free(source.path);
        gpa.free(source.text);
    }

    sources.deinit(gpa);
}

pub fn file_check(gpa: std.mem.Allocator, source: Source, options: *const Options) !u32 {
    assert(source.path.len > 0);

    var problems = file_name_check(source.path, options);

    problems += lines_check(source, options);
    problems += try functions_check(gpa, source, options);

    if (!options.comments_allowed) problems += comments_check(source, options);
    if (options.blank_lines_checked) problems += blank_lines_check(source, options);

    return problems;
}

pub fn graph_check(gpa: std.mem.Allocator, sources: []const Source, options: *const Options) !u32 {
    assert(sources.len > 0);

    var problems = try imports_check(gpa, sources, options);

    problems += try test_roots_check(gpa, sources, options);

    return problems;
}

pub fn declares_tests(text: []const u8) bool {
    assert(text.len <= std.math.maxInt(u32));

    var lines = std.mem.splitScalar(u8, text, '\n');
    var number: u32 = 0;

    while (lines.next()) |line| {
        number += 1;

        assert(number <= line_count_max);

        if (std.mem.startsWith(u8, std.mem.trimStart(u8, line, " "), "test ")) return true;
    }

    return false;
}

pub fn imports_collect(gpa: std.mem.Allocator, source: Source, imported: *Imported) !void {
    assert(source.path.len > 0);

    const directory = std.Io.Dir.path.dirname(source.path) orelse ".";
    const marker = "@import(\"";
    var offset: usize = 0;
    var count: u32 = 0;

    while (std.mem.findPos(u8, source.text, offset, marker)) |found| {
        count += 1;

        assert(count <= import_count_max);

        const start = found + marker.len;
        const end = std.mem.findScalarPos(u8, source.text, start, '"') orelse break;
        const target = source.text[start..end];

        offset = end;

        if (!std.mem.endsWith(u8, target, ".zig")) continue;

        const resolved = try std.Io.Dir.path.resolveAllocPosix(gpa, &.{ directory, target });
        const entry = try imported.getOrPut(gpa, resolved);

        if (entry.found_existing) gpa.free(resolved);
    }
}

pub fn imported_free(gpa: std.mem.Allocator, imported: *Imported) void {
    for (imported.keys()) |key| gpa.free(key);

    imported.deinit(gpa);
}

pub fn is_listed(paths: []const []const u8, path: []const u8) bool {
    assert(paths.len <= file_count_max);
    assert(path.len <= std.math.maxInt(u32));

    for (paths) |listed| {
        if (std.mem.eql(u8, path, listed)) return true;
    }

    return false;
}

fn directory_read(gpa: std.mem.Allocator, io: std.Io, sources: *Sources, name: []const u8) !void {
    assert(name.len > 0);

    var directory = try std.Io.Dir.cwd().openDir(io, name, .{ .iterate = true });
    defer directory.close(io);

    var walker = try directory.walk(gpa);
    defer walker.deinit();

    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.basename, ".zig")) continue;

        assert(sources.items.len < file_count_max);

        const path = try gpa.print("{s}/{s}", .{ name, entry.path });
        errdefer gpa.free(path);

        if (builtin.target.os.tag == .windows) std.mem.replaceScalar(u8, path, '\\', '/');

        try sources.append(gpa, .{ .path = path, .text = try source_read(gpa, io, path) });
    }
}

fn source_read(gpa: std.mem.Allocator, io: std.Io, path: []const u8) ![:0]const u8 {
    assert(path.len > 0);

    const text = try std.Io.Dir.cwd().readFileAllocOptions(
        io,
        path,
        gpa,
        .limited(source_bytes_max),
        .of(u8),
        0,
    );

    assert(text.len <= source_bytes_max);

    return text;
}

fn file_name_check(path: []const u8, options: *const Options) u32 {
    assert(path.len > 0);

    const name = std.Io.Dir.path.basename(path);

    assert(name.len > 0);

    const allowed = "abcdefghijklmnopqrstuvwxyz0123456789_.";
    if (std.mem.findNone(u8, name, allowed) == null) return 0;

    problem_print(options, "{s}: the file name is not snake case\n", .{path});

    return 1;
}

fn lines_check(source: Source, options: *const Options) u32 {
    assert(source.path.len > 0);

    var problems: u32 = 0;
    var number: u32 = 0;
    var lines = std.mem.splitScalar(u8, source.text, '\n');

    while (lines.next()) |line| {
        number += 1;

        assert(number <= line_count_max);

        problems += line_check(source.path, number, line, options);
    }

    if (!std.mem.endsWith(u8, source.text, "\n")) {
        problem_print(options, "{s}: the file does not end with a newline\n", .{source.path});

        problems += 1;
    }

    return problems;
}

fn line_check(path: []const u8, number: u32, line: []const u8, options: *const Options) u32 {
    assert(path.len > 0);
    assert(number > 0);
    assert(line.len <= source_bytes_max);

    var problems: u32 = 0;

    if (std.mem.findScalar(u8, line, '\t') != null) {
        problem_print(options, "{s}:{d}: the line carries a tab\n", .{ path, number });

        problems += 1;
    }

    if (std.mem.findScalar(u8, line, '\r') != null) {
        problem_print(options, "{s}:{d}: the line carries a carriage return\n", .{ path, number });

        problems += 1;
    }

    if (std.mem.endsWith(u8, line, " ")) {
        problem_print(options, "{s}:{d}: the line carries trailing whitespace\n", .{
            path,
            number,
        });

        problems += 1;
    }

    const columns = std.unicode.utf8CountCodepoints(line) catch line.len;

    if (columns > options.line_columns_max) {
        if (std.mem.find(u8, line, "https://") == null) {
            problem_print(options, "{s}:{d}: the line is {d} columns wide\n", .{
                path,
                number,
                columns,
            });

            problems += 1;
        }
    }

    for (options.banned) |pattern| {
        if (std.mem.find(u8, line, pattern) == null) continue;

        problem_print(options, "{s}:{d}: the line carries {s}\n", .{ path, number, pattern });

        problems += 1;
    }

    return problems;
}

fn functions_check(gpa: std.mem.Allocator, source: Source, options: *const Options) !u32 {
    assert(source.path.len > 0);
    assert(options.function_lines_max > 0);

    var ast = try std.zig.Ast.parse(gpa, source.text, .{ .mode = .zig, .recover = true });
    defer ast.deinit(gpa);

    var problems: u32 = 0;

    for (0..ast.nodes.len) |index| {
        const node: std.zig.Ast.Node.Index = @fromBackingInt(@intCast(index));
        if (ast.nodeTag(node) != .fn_decl) continue;
        if (returns_a_type(&ast, node)) continue;

        const first = ast.tokenLocation(0, ast.firstToken(node)).line;
        const last = ast.tokenLocation(0, ast.lastToken(node)).line;
        const lines = last - first + 1;

        assert(last >= first);

        if (lines > options.function_lines_max) {
            problem_print(options, "{s}:{d}: the function is {d} lines long\n", .{
                source.path,
                first + 1,
                lines,
            });

            problems += 1;
        }
    }

    return problems;
}

pub fn returns_a_type(ast: *const std.zig.Ast, node: std.zig.Ast.Node.Index) bool {
    assert(ast.nodeTag(node) == .fn_decl);

    var buffer: [1]std.zig.Ast.Node.Index = undefined;

    const prototype = ast.fullFnProto(&buffer, ast.nodeData(node).node_and_node[0]) orelse {
        return false;
    };

    const return_type = prototype.ast.return_type.unwrap() orelse return false;
    return std.mem.eql(u8, ast.getNodeSource(return_type), "type");
}

fn comments_check(source: Source, options: *const Options) u32 {
    assert(source.path.len > 0);

    var tokenizer = std.zig.Tokenizer.init(source.text);
    var gap_start: usize = 0;
    var count: u32 = 0;
    var problems: u32 = 0;

    while (count <= source.text.len) : (count += 1) {
        const token = tokenizer.next();

        problems += gap_check(source, gap_start, token.loc.start, options);

        switch (token.tag) {
            .container_doc_comment, .doc_comment => {
                problem_print(options, "{s}:{d}: the line carries a doc comment\n", .{
                    source.path,
                    line_of(source.text, token.loc.start),
                });

                problems += 1;
            },
            .eof => break,
            else => {},
        }

        gap_start = token.loc.end;
    }

    assert(count <= source.text.len);

    return problems;
}

fn gap_check(source: Source, start: usize, end: usize, options: *const Options) u32 {
    assert(start <= end);
    assert(end <= source.text.len);

    const text = source.text[0..end];
    var cursor = start;
    var problems: u32 = 0;

    while (std.mem.findPos(u8, text, cursor, "//")) |offset| {
        assert(offset >= cursor);

        problem_print(options, "{s}:{d}: the line carries a comment\n", .{
            source.path,
            line_of(source.text, offset),
        });

        problems += 1;
        cursor = std.mem.findScalarPos(u8, text, offset, '\n') orelse text.len;
    }

    return problems;
}

fn line_of(text: []const u8, offset: usize) u32 {
    assert(offset <= text.len);

    const line: u32 = @intCast(std.mem.countScalar(u8, text[0..offset], '\n') + 1);

    assert(line <= offset + 1);

    return line;
}

fn blank_lines_check(source: Source, options: *const Options) u32 {
    assert(source.path.len > 0);

    if (std.mem.endsWith(u8, source.text, "\n\n")) {
        problem_print(options, "{s}: the file ends with more than one newline\n", .{source.path});

        return 1;
    }

    const text = std.mem.trimEnd(u8, source.text, "\n");
    var problems: u32 = 0;
    var number: u32 = 0;
    var above: []const u8 = "";
    var lines = std.mem.splitScalar(u8, text, '\n');

    while (lines.next()) |line| {
        number += 1;

        assert(number <= line_count_max);

        if (line.len == 0) {
            problems += blank_check(source.path, number, above, lines.peek() orelse "", options);
        }

        above = line;
    }

    if (number > options.file_lines_max) {
        const arguments = .{ source.path, options.file_lines_max };

        problem_print(options, "{s}: the file is longer than {d} lines\n", arguments);

        problems += 1;
    }

    return problems;
}

fn blank_check(
    path: []const u8,
    number: u32,
    above: []const u8,
    below: []const u8,
    options: *const Options,
) u32 {
    assert(number > 0);
    assert(path.len <= std.math.maxInt(u32));
    assert(above.len <= std.math.maxInt(u32));
    assert(below.len <= std.math.maxInt(u32));

    if (number > 1) {
        if (above.len == 0) {
            return blank_problem(path, number, "follows another blank line", options);
        }
    }

    if (std.mem.endsWith(u8, std.mem.trimEnd(u8, above, " "), "{")) {
        return blank_problem(path, number, "opens a block", options);
    }

    if (std.mem.startsWith(u8, std.mem.trimStart(u8, below, " "), "}")) {
        return blank_problem(path, number, "closes a block", options);
    }

    const above_indent = declaration_indent(above) orelse return 0;
    const below_indent = declaration_indent(below) orelse return 0;
    if (above_indent != below_indent) return 0;
    return blank_problem(path, number, "parts two declarations", options);
}

fn blank_problem(path: []const u8, number: u32, problem: []const u8, options: *const Options) u32 {
    assert(path.len > 0);
    assert(problem.len > 0);
    assert(number < std.math.maxInt(u32));

    problem_print(options, "{s}:{d}: the blank line {s}\n", .{ path, number, problem });

    return 1;
}

fn declaration_indent(line: []const u8) ?usize {
    if (!std.mem.endsWith(u8, std.mem.trimEnd(u8, line, " "), ";")) return null;

    const rest = std.mem.trimStart(u8, line, " ");
    const indent = line.len - rest.len;
    const unexported = if (std.mem.startsWith(u8, rest, "pub ")) rest["pub ".len..] else rest;

    assert(indent <= line.len);

    if (std.mem.startsWith(u8, unexported, "const ")) return indent;
    if (std.mem.startsWith(u8, unexported, "var ")) return indent;
    return null;
}

fn imports_check(gpa: std.mem.Allocator, sources: []const Source, options: *const Options) !u32 {
    assert(sources.len > 0);
    assert(options.entry_points.len > 0);

    var imported: Imported = .empty;
    defer imported_free(gpa, &imported);

    for (sources) |source| try imports_collect(gpa, source, &imported);

    var problems: u32 = 0;

    for (sources) |source| {
        if (std.mem.eql(u8, source.path, "build.zig")) continue;
        if (imported.contains(source.path)) continue;
        if (is_listed(options.entry_points, source.path)) continue;

        problem_print(options, "{s}: the file is imported from nowhere\n", .{source.path});

        problems += 1;
    }

    return problems;
}

fn test_roots_check(gpa: std.mem.Allocator, sources: []const Source, options: *const Options) !u32 {
    assert(sources.len > 0);
    assert(options.test_roots.len > 0);

    var reached: Imported = .empty;
    defer imported_free(gpa, &reached);

    for (options.test_roots) |root| try reached.put(gpa, try gpa.dupe(u8, root), {});

    var index: usize = 0;

    while (index < reached.count()) : (index += 1) {
        assert(reached.count() <= file_count_max);

        const source = source_named(sources, reached.keys()[index]) orelse continue;

        try imports_collect(gpa, source, &reached);
    }

    var problems: u32 = 0;

    for (sources) |source| {
        if (reached.contains(source.path)) continue;
        if (!declares_tests(source.text)) continue;

        problem_print(options, "{s}: the tests are reached from no test root\n", .{source.path});

        problems += 1;
    }

    return problems;
}

fn problem_print(options: *const Options, comptime format: []const u8, arguments: anytype) void {
    comptime assert(format.len > 0);
    comptime assert(@typeInfo(@TypeOf(arguments)) == .@"struct");

    if (options.quiet) return;

    std.debug.print(format, arguments);
}

fn source_named(sources: []const Source, path: []const u8) ?Source {
    assert(sources.len > 0);
    assert(path.len > 0);

    for (sources) |source| {
        if (std.mem.eql(u8, source.path, path)) return source;
    }

    return null;
}

const test_options: Options = .{
    .banned = &.{"Self = " ++ "@This()"},
    .entry_points = &.{ "src/main.zig", "src/unit_tests.zig" },
    .quiet = true,
    .test_roots = &.{"src/unit_tests.zig"},
};

fn test_source(text: [:0]const u8) Source {
    assert(text.len > 0);

    return .{ .path = "src/sample.zig", .text = text };
}

const TestPiece = struct {
    count: usize = 1,
    text: []const u8,
};

fn test_sized(buffer: []u8, pieces: []const TestPiece) [:0]const u8 {
    assert(buffer.len > 0);
    assert(pieces.len > 0);

    var writer: std.Io.Writer = .fixed(buffer);

    for (pieces) |piece| writer.splatBytesAll(piece.text, piece.count) catch unreachable;

    writer.writeByte(0) catch unreachable;

    const written = writer.buffered();

    assert(written.len > 0);

    return written[0 .. written.len - 1 :0];
}

fn test_function(buffer: []u8, head: []const u8, body_count: usize, tail: []const u8) [:0]const u8 {
    assert(buffer.len > 0);
    assert(head.len > 0);
    assert(body_count > 0);
    assert(tail.len > 0);

    return test_sized(buffer, &.{
        .{ .text = head },
        .{ .count = body_count, .text = "            _ = 0;\n" },
        .{ .text = tail },
    });
}

test "tabs, carriage returns, trailing spaces, wide lines, and a missing newline are found" {
    var buffer: [1 << 12]u8 = undefined;

    const text = test_sized(&buffer, &.{
        .{ .text = "const\ttab = 1;\nconst carriage = 2;\r\nconst trailing = 3; \n" },
        .{ .text = "const wide = \"" },
        .{ .count = 85, .text = "x" },
        .{ .text = "\";\nconst narrow = \"" },
        .{ .count = 82, .text = "\u{21b5}" },
        .{ .text = "\";" },
    });

    try std.testing.expectEqual(5, lines_check(test_source(text), &test_options));
    try std.testing.expectEqual(0, lines_check(test_source("const value = 1;\n"), &test_options));
}

test "banned text is found on its line" {
    const source = test_source("const Self = " ++ "@This();\nconst value = 1;\n");

    try std.testing.expectEqual(1, lines_check(source, &test_options));
}

test "a function over seventy lines is found and one of exactly seventy is not" {
    const gpa = std.testing.allocator;
    var buffer: [1 << 12]u8 = undefined;
    const seventy = test_function(&buffer, "fn seventy() void {\n", 68, "}\n");

    try std.testing.expectEqual(0, try functions_check(gpa, test_source(seventy), &test_options));

    const longer = test_function(&buffer, "fn longer() void {\n", 69, "}\n");

    try std.testing.expectEqual(1, try functions_check(gpa, test_source(longer), &test_options));
}

test "a function that returns a type is measured by its methods rather than as a whole" {
    const gpa = std.testing.allocator;
    var buffer: [1 << 12]u8 = undefined;
    const head = "fn GenericType() type {\n    return struct {\n        fn method() void {\n";
    const tail = "        }\n    };\n}\n";
    const short = test_function(&buffer, head, 60, tail);

    try std.testing.expectEqual(0, try functions_check(gpa, test_source(short), &test_options));

    const long = test_function(&buffer, head, 69, tail);

    try std.testing.expectEqual(1, try functions_check(gpa, test_source(long), &test_options));
}

test "a comment is found between tokens and never inside a string" {
    const source = test_source(
        \\//! container
        \\const url = "https://example.com";
        \\const text =
        \\    \\// inside a multiline string
        \\;
        \\const value = 1; // trailing
        \\/// documentation
        \\const other = 2;
        \\
    );

    try std.testing.expectEqual(3, comments_check(source, &test_options));
    const clean = test_source("const value = 1;\n");

    try std.testing.expectEqual(0, comments_check(clean, &test_options));
}

test "a blank line never opens a block, closes one, parts declarations, or doubles" {
    const source = test_source(
        \\const a = 1;
        \\
        \\const b = 2;
        \\
        \\fn run() void {
        \\
        \\    use(a);
        \\
        \\}
        \\
        \\
        \\fn done() void {}
        \\
    );

    try std.testing.expectEqual(4, blank_lines_check(source, &test_options));

    const doubled = test_source("const a = 1;\n\n");
    const packed_pair = test_source("const a = 1;\nconst b = 2;\n");

    try std.testing.expectEqual(1, blank_lines_check(doubled, &test_options));
    try std.testing.expectEqual(0, blank_lines_check(packed_pair, &test_options));
}

test "a file declares tests only through a test declaration" {
    try std.testing.expect(declares_tests("const a = 1;\ntest \"a\" {}\n"));
    try std.testing.expect(declares_tests("const b = struct {\n    test {}\n};\n"));
    try std.testing.expect(!declares_tests("const text =\n    \\\\test \"in a string\"\n;\n"));
    try std.testing.expect(!declares_tests("const latest = 1;\n"));
}

test "imports resolve against the importing directory and tests are reached transitively" {
    const gpa = std.testing.allocator;

    const sources = [_]Source{
        .{ .path = "src/main.zig", .text = "const menu = @import(\"menu.zig\");\n" },
        .{
            .path = "src/unit_tests.zig",
            .text = "comptime {\n    _ = @import(\"menu.zig\");\n}\n",
        },
        .{
            .path = "src/menu.zig",
            .text = "const process = @import(\"platform/linux/process.zig\");\n",
        },
        .{ .path = "src/platform/interface.zig", .text = "test \"interface\" {}\n" },
        .{
            .path = "src/platform/linux/process.zig",
            .text = "const interface = @import(\"../interface.zig\");\ntest \"process\" {}\n",
        },
        .{
            .path = "src/orphan.zig",
            .text = "const main = @import(\"main.zig\");\ntest \"orphan\" {}\n",
        },
    };

    try std.testing.expectEqual(1, try imports_check(gpa, &sources, &test_options));
    try std.testing.expectEqual(1, try test_roots_check(gpa, &sources, &test_options));
    try std.testing.expectEqual(0, try graph_check(gpa, sources[0..5], &test_options));
}
