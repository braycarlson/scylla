const std = @import("std");
const assert = std.debug.assert;
const ArrayType = @import("../../../stdx/bounded/array.zig").ArrayType;
const Fixture = @import("fixture.zig");
const FunctionDef = @import("../../../syntax/python/ast.zig").FunctionDef;
const Kind = @import("../../../syntax/python/kind.zig").Kind;
const Semantic = @import("../../../syntax/python/semantic.zig").Semantic;
const Span = @import("../../../stdx/bounded/span.zig");
const TreeType = @import("../../../syntax/tree.zig").TreeType;
const export_slice = @import("../../../syntax/python/semantic.zig").export_slice;
const literal = @import("../../../syntax/python/literal.zig");
const stdlib = @import("../../../syntax/python/stdlib.zig");
const unicode = @import("../../../text/unicode.zig");
const walk = @import("../../../syntax/tree.zig").walk;
const Tree = TreeType(Kind);
pub const Convention = enum { google, numpy };

pub const Definition = struct {
    docstring: ?u32,
    kind: DefinitionKind,
    node: u32,
    visibility: Visibility,
};

pub const DefinitionKind = enum {
    class,
    function,
    method,
    module,
    nested_class,
    nested_function,
};

pub const Section = struct {
    body: Span,
    colon: bool,
    name: Span,
    underline: bool,
};

pub const Visibility = enum { private, public };

const Header = struct {
    colon: bool,
    indent: u32,
    name: Span,
    underline: bool,
};

const Open = struct {
    header: Header,
    start: u32,
};

const ascii_whitespace = " \t\n\x0C\r";
const directive_open = ".. ";
const paragraph_ends = ",;.-\\/]})";

const headers_google = [_][]const u8{
    "args",
    "arguments",
    "attention",
    "attributes",
    "caution",
    "danger",
    "error",
    "example",
    "examples",
    "hint",
    "important",
    "keyword args",
    "keyword arguments",
    "methods",
    "note",
    "notes",
    "other args",
    "other arguments",
    "raises",
    "references",
    "return",
    "returns",
    "see also",
    "tip",
    "todo",
    "warning",
    "warnings",
    "warns",
    "yield",
    "yields",
};

const headers_numpy = [_][]const u8{
    "attributes",
    "examples",
    "extended summary",
    "methods",
    "notes",
    "other parameters",
    "other params",
    "parameters",
    "raises",
    "receives",
    "references",
    "returns",
    "see also",
    "short summary",
    "warnings",
    "warns",
    "yields",
};

comptime {
    assert(headers_google.len == 30);
    assert(headers_numpy.len == 17);
}

pub fn docstring_of(tree: *const Tree, raw: []const Kind, body: u32) ?u32 {
    assert(body < tree.count());
    assert(raw.len <= std.math.maxInt(u32));

    const first = tree.child_first_of(body) orelse return null;
    if (tree.kind_at(first) != .expr) return null;

    const held = tree.child_first_of(first) orelse return null;
    if (tree.kind_at(held) != .constant) return null;

    const node = tree.at(held);
    if (node.token_end <= node.token_start) return null;
    if (raw[node.token_start] != .string_plain) return null;
    return held;
}

pub fn sections(
    source: []const u8,
    content: Span,
    convention: Convention,
    definition: ?FunctionDef,
    out: *ArrayType(Section),
) error{Truncated}!void {
    assert(content.end() <= source.len);
    if (definition) |function| assert(function.view.index() < function.view.tree.count());

    out.clear();

    const text = source[content.offset..content.end()];
    var open: ?Open = null;
    var directive: ?u32 = null;
    var start_previous: u32 = 0;
    var end_previous = line_end_of(text, 0);
    var offset = next_line_of(text, end_previous);

    for (0..text.len + 1) |_| {
        if (offset >= text.len) break;

        const end = line_end_of(text, offset);
        const line = text[offset..end];

        directive = directive_of(line, indent_of(line), directive);

        if (directive == null) {
            const enclosing: ?Header = if (open) |opened| opened.header else null;
            const line_previous = text[start_previous..end_previous];
            const found = header_of(text, offset, end, convention, content.offset);

            if (found) |header| {
                if (opens_section(source, header, line_previous, enclosing, definition)) {
                    try sections_close(out, &open, content.offset + offset);

                    const body = body_start_of(text, end, header.underline);

                    open = .{ .header = header, .start = content.offset + body };
                }
            }
        }

        start_previous = offset;
        end_previous = end;
        offset = next_line_of(text, end);
    }

    try sections_close(out, &open, content.end());

    assert(open == null);
}

pub fn definitions(
    source: []const u8,
    semantic: *const Semantic,
    tree: *const Tree,
    raw: []const Kind,
    out: *ArrayType(Definition),
) error{Truncated}!void {
    assert(out.capacity() > 0);
    assert(source.len <= std.math.maxInt(u32));
    assert(raw.len <= std.math.maxInt(u32));

    out.clear();

    if (tree.count() == 0) return;

    const exported = export_slice(semantic).len > 0;

    out.push(.{
        .docstring = docstring_of(tree, raw, 0),
        .kind = .module,
        .node = 0,
        .visibility = .public,
    });

    var steps = walk(Tree, tree);

    for (0..steps.step_max) |_| {
        const step = steps.next() orelse break;

        const node = switch (step) {
            .enter => |entered| entered,
            .leave => continue,
        };

        if (!opens_definition(tree.kind_at(node))) continue;

        const parent = enclosing_definition(tree, node);
        const body = body_of(tree, node);
        const rows = out.const_slice();

        const row: Definition = .{
            .docstring = if (body) |found| docstring_of(tree, raw, found) else null,
            .kind = kind_of(tree, parent, tree.kind_at(node) == .class_def),
            .node = node,
            .visibility = visibility_of(source, semantic, node, parent, exported, rows),
        };

        if (out.full()) return error.Truncated;

        out.push(row);
    }
}

fn opens_section(
    source: []const u8,
    header: Header,
    line_previous: []const u8,
    enclosing: ?Header,
    definition: ?FunctionDef,
) bool {
    assert(header.name.end() <= source.len);
    assert(header.name.length > 0);

    if (header.underline) return true;
    if (!paragraph_ended(line_previous)) return false;
    if (enclosing) |held| assert(held.name.end() <= source.len);
    if (definition) |function| assert(function.view.index() < function.view.tree.count());

    const opened = enclosing orelse return true;
    const verbatim = source[header.name.offset..header.name.end()];

    if (opened.indent < header.indent) {
        if (!canonical(verbatim)) return false;
        if (has_parameter(source, definition, verbatim)) return false;
    }

    if (std.mem.trim(u8, line_previous, ascii_whitespace).len == 0) return true;
    return !std.ascii.isLower(verbatim[0]);
}

fn canonical(name: []const u8) bool {
    assert(name.len > 0);

    var word_start = true;

    for (name) |byte| {
        const upper = std.ascii.isUpper(byte);

        if (word_start) {
            if (!upper) return false;
        } else {
            if (upper) return false;
        }

        word_start = byte == ' ';
    }

    return true;
}

fn has_parameter(source: []const u8, definition: ?FunctionDef, name: []const u8) bool {
    assert(name.len > 0);
    assert(source.len <= std.math.maxInt(u32));

    if (definition == null) return false;

    const function = definition.?;
    var parameters = function.parameters();

    for (0..function.view.tree.count()) |_| {
        const parameter = parameters.next() orelse break;
        const token = parameter.name_token() orelse continue;
        if (std.mem.eql(u8, function.view.token_at(token).text(source), name)) return true;
    }

    return false;
}

fn directive_of(line: []const u8, indent: u32, active: ?u32) ?u32 {
    assert(indent <= line.len);
    if (active) |held| assert(held < std.math.maxInt(u32));

    if (active) |held| {
        if (std.mem.trim(u8, line, ascii_whitespace).len == 0) return held;
        if (indent > held) return held;
    }

    if (std.mem.startsWith(u8, line[indent..], directive_open)) return indent;
    return null;
}

fn indent_of(line: []const u8) u32 {
    assert(line.len <= std.math.maxInt(u32));

    for (line, 0..) |byte, index| {
        if (std.mem.findScalar(u8, ascii_whitespace, byte) == null) {
            assert(index < line.len);

            return @intCast(index);
        }
    }

    assert(line.len <= std.math.maxInt(u32));

    return @intCast(line.len);
}

fn opens_definition(kind: Kind) bool {
    if (!kind.is_node()) return false;

    return switch (kind) {
        .async_function_def, .class_def, .function_def => true,
        else => false,
    };
}

fn kind_of(tree: *const Tree, parent: ?u32, class: bool) DefinitionKind {
    if (parent) |held| assert(held < tree.count());

    const above = parent orelse return if (class) .class else .function;

    assert(above < tree.count());

    if (class) return .nested_class;
    if (tree.kind_at(above) == .class_def) return .method;
    return .nested_function;
}

fn body_of(tree: *const Tree, node: u32) ?u32 {
    assert(node < tree.count());

    var child = tree.child_first_of(node);

    for (0..tree.count()) |_| {
        const held = child orelse return null;
        if (tree.kind_at(held) == .block) return held;

        child = tree.sibling_next_of(held);
    }

    unreachable;
}

fn enclosing_definition(tree: *const Tree, node: u32) ?u32 {
    assert(node < tree.count());

    var held = tree.parent_of(node);

    for (0..tree.count() + 1) |_| {
        const above = held orelse return null;
        if (opens_definition(tree.kind_at(above))) return above;

        held = tree.parent_of(above);
    }

    return null;
}

fn visibility_of(
    source: []const u8,
    semantic: *const Semantic,
    node: u32,
    parent: ?u32,
    exported: bool,
    rows: []const Definition,
) Visibility {
    assert(source.len <= std.math.maxInt(u32));
    assert(node < std.math.maxInt(u32));
    if (parent) |held| assert(held < node);

    const name = name_of(source, semantic, node);

    assert(rows.len > 0);

    if (private_name(name)) return .private;

    const above = parent orelse {
        if (!exported) return .public;

        for (export_slice(semantic)) |span| {
            if (std.mem.eql(u8, source[span.offset..span.end()], name)) return .public;
        }

        return .private;
    };

    var index = rows.len;

    for (0..rows.len) |_| {
        index -= 1;

        if (rows[index].node == above) return rows[index].visibility;
    }

    return .private;
}

fn private_name(name: []const u8) bool {
    if (name.len == 0) return false;
    if (stdlib.is_dunder(name)) return false;
    return name[0] == '_';
}

fn name_of(source: []const u8, semantic: *const Semantic, node: u32) []const u8 {
    assert(source.len <= std.math.maxInt(u32));

    for (semantic.binding_slice()) |binding| {
        if (binding.node != node) continue;

        switch (binding.kind) {
            .class_definition, .function_definition => {},
            else => continue,
        }

        return source[binding.name.offset..binding.name.end()];
    }

    return "";
}

fn line_end_of(text: []const u8, offset: u32) u32 {
    assert(offset <= text.len);

    const end = std.mem.findScalarPos(u8, text, offset, '\n') orelse text.len;
    assert(end <= text.len);

    return @intCast(end);
}

fn next_line_of(text: []const u8, end: u32) u32 {
    assert(end <= text.len);

    if (end < text.len) {
        assert(end + 1 <= text.len);

        return end + 1;
    }

    assert(end == text.len);

    return @intCast(text.len);
}

fn header_of(
    text: []const u8,
    offset: u32,
    end: u32,
    convention: Convention,
    base: u32,
) ?Header {
    assert(offset <= end);
    assert(end <= text.len);
    assert(base < std.math.maxInt(u32));

    const start = offset + indent_of(text[offset..end]);
    const line = std.mem.trimEnd(u8, text[start..end], ascii_whitespace);
    const words = leading_words(line);
    const name = std.mem.trimEnd(u8, words, ascii_whitespace);
    const suffix = std.mem.trim(u8, line[words.len..], ascii_whitespace);

    const headers: []const []const u8 = switch (convention) {
        .google => &headers_google,
        .numpy => &headers_numpy,
    };

    if (!header_known(headers, name)) return null;

    const colon = std.mem.eql(u8, suffix, ":");

    if (suffix.len > 0) {
        if (!colon) return null;
    }

    return .{
        .colon = colon,
        .indent = start - offset,
        .name = .{ .offset = base + start, .length = @intCast(name.len) },
        .underline = underlined(text, next_line_of(text, end)),
    };
}

fn header_known(headers: []const []const u8, name: []const u8) bool {
    assert(headers.len > 0);
    assert(name.len <= std.math.maxInt(u32));

    for (headers) |header| {
        if (std.ascii.eqlIgnoreCase(header, name)) return true;
    }

    return false;
}

fn leading_words(line: []const u8) []const u8 {
    assert(line.len <= std.math.maxInt(u32));

    if (!std.unicode.utf8ValidateSlice(line)) return leading_words_bytes(line);

    var offset: u32 = 0;

    for (0..line.len) |_| {
        if (offset >= line.len) break;

        const width = std.unicode.utf8ByteSequenceLength(line[offset]) catch unreachable;
        const sequence = line[offset..][0..width];

        const scalar = switch (width) {
            1 => sequence[0],
            2 => std.unicode.utf8Decode2(sequence[0..2].*),
            3 => std.unicode.utf8Decode3(sequence[0..3].*),
            4 => std.unicode.utf8Decode4(sequence[0..4].*),
            else => unreachable,
        } catch unreachable;

        if (!leading_words_scalar(scalar)) return line[0..offset];

        offset += width;
    }

    assert(offset == line.len);

    return line;
}

fn leading_words_bytes(line: []const u8) []const u8 {
    assert(line.len <= std.math.maxInt(u32));

    for (line, 0..) |byte, index| {
        if (std.ascii.isAlphanumeric(byte)) continue;
        if (std.mem.findScalar(u8, ascii_whitespace, byte) != null) continue;
        return line[0..index];
    }

    return line;
}

fn leading_words_scalar(scalar: u21) bool {
    assert(scalar <= 0x10FFFF);

    if (scalar < 0x80) {
        const byte: u8 = @intCast(scalar);
        if (std.ascii.isAlphanumeric(byte)) return true;
        return std.mem.findScalar(u8, " \t\n\x0B\x0C\r", byte) != null;
    }

    if (unicode.is_alphanumeric(scalar)) return true;

    return switch (scalar) {
        0x85, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000 => true,
        else => false,
    };
}

fn underlined(text: []const u8, offset: u32) bool {
    assert(text.len <= std.math.maxInt(u32));
    assert(offset <= text.len);

    const end = line_end_of(text, offset);
    const line = std.mem.trim(u8, text[offset..end], ascii_whitespace);
    if (line.len == 0) return false;

    for (line) |byte| {
        if (byte != '-') {
            if (byte != '=') return false;
        }
    }

    return true;
}

fn paragraph_ended(line: []const u8) bool {
    assert(line.len <= std.math.maxInt(u32));

    const held = std.mem.trim(u8, line, ascii_whitespace);
    if (held.len == 0) return true;
    return std.mem.findScalar(u8, paragraph_ends, held[held.len - 1]) != null;
}

fn body_start_of(text: []const u8, end: u32, underline: bool) u32 {
    assert(text.len <= std.math.maxInt(u32));
    assert(end < std.math.maxInt(u32));

    const after = next_line_of(text, end);
    if (!underline) return after;
    return next_line_of(text, line_end_of(text, after));
}

fn sections_close(out: *ArrayType(Section), open: *?Open, end: u32) error{Truncated}!void {
    assert(end < std.math.maxInt(u32));

    const held = open.* orelse return;

    open.* = null;

    if (out.full()) return error.Truncated;

    out.push(.{
        .body = .{ .offset = held.start, .length = end -| held.start },
        .colon = held.header.colon,
        .name = held.header.name,
        .underline = held.header.underline,
    });
}

const row_count_max: u32 = 1 << 6;

const Row = struct {
    name: []const u8,
    body: []const u8,
    colon: bool,
    underline: bool,
};

const Rows = struct {
    count: u32,
    items: [row_count_max]Row,
};

const Defined = struct {
    kind: DefinitionKind,
    visibility: Visibility,
    documented: bool,
};

fn sectioned(comptime text: []const u8, convention: Convention) !Rows {
    assert(text.len <= std.math.maxInt(u32));

    return sectioned_in("\"\"\"" ++ text ++ "\"\"\"\n", convention);
}

fn sectioned_in(source: []const u8, convention: Convention) !Rows {
    assert(source.len <= std.math.maxInt(u32));

    const gpa = std.testing.allocator;
    var fixture: Fixture = undefined;

    try fixture.init(gpa);
    defer fixture.deinit();

    var out: ArrayType(Section) = try .init(gpa, row_count_max);
    defer out.deinit(gpa);

    try fixture.build(source);

    const node = fixture.first(.constant).?;
    const function = fixture.first(.function_def);
    const definition = if (function) |found| fixture.view(found).as_function() else null;
    const token = fixture.view(node).token_at(fixture.tree.at(node).token_start);
    const content = literal.shape_of(token.text(source), token.offset).?.content;

    try sections(source, content, convention, definition, &out);

    var rows: Rows = .{ .count = 0, .items = undefined };

    for (out.const_slice()) |section| {
        rows.items[rows.count] = .{
            .name = source[section.name.offset..section.name.end()],
            .body = source[section.body.offset..section.body.end()],
            .colon = section.colon,
            .underline = section.underline,
        };

        rows.count += 1;
    }

    return rows;
}

fn documented(comptime parameters: []const u8, comptime text: []const u8) []const u8 {
    assert(parameters.len <= std.math.maxInt(u32));
    assert(text.len <= std.math.maxInt(u32));

    return "def func(" ++ parameters ++ "):\n    \"\"\"" ++ text ++ "\"\"\"\n";
}

fn defined_expect(source: []const u8, expected: []const Defined) !void {
    assert(source.len <= std.math.maxInt(u32));

    const gpa = std.testing.allocator;
    var fixture: Fixture = undefined;

    try fixture.init(gpa);
    defer fixture.deinit();

    var out: ArrayType(Definition) = try .init(gpa, 1 << 8);
    defer out.deinit(gpa);

    try fixture.build(source);
    try definitions(source, &fixture.semantic, &fixture.tree, fixture.raw.const_slice(), &out);

    try std.testing.expectEqual(expected.len, out.count());

    for (out.const_slice(), expected) |row, wanted| {
        try std.testing.expectEqual(wanted.kind, row.kind);
        try std.testing.expectEqual(wanted.visibility, row.visibility);
        try std.testing.expectEqual(wanted.documented, row.docstring != null);
    }
}

fn docstring_expect(source: []const u8, expected: bool) !void {
    assert(source.len <= std.math.maxInt(u32));

    var fixture: Fixture = undefined;

    try fixture.init(std.testing.allocator);
    defer fixture.deinit();

    try fixture.build(source);

    const function = fixture.first(.function_def);
    const body = if (function) |found| body_of(&fixture.tree, found) else 0;

    try std.testing.expect(body != null);

    const docstring = docstring_of(&fixture.tree, fixture.raw.const_slice(), body.?);

    try std.testing.expectEqual(expected, docstring != null);
}

test "a google docstring reads its headers and their bodies" {
    const held = try sectioned(
        "Read a value.\n\nArgs:\n    value: The value.\n\nReturns:\n    The value.\n",
        .google,
    );

    try std.testing.expectEqual(2, held.count);
    try std.testing.expectEqualStrings("Args", held.items[0].name);
    try std.testing.expectEqualStrings("    value: The value.\n\n", held.items[0].body);
    try std.testing.expect(held.items[0].colon);
    try std.testing.expect(!held.items[0].underline);
    try std.testing.expectEqualStrings("Returns", held.items[1].name);
    try std.testing.expectEqualStrings("    The value.\n", held.items[1].body);
}

test "a numpy docstring reads past the underline below the header" {
    const held = try sectioned(
        "Read a value.\n\nParameters\n----------\nvalue : int\n\nReturns\n-------\nint\n",
        .numpy,
    );

    try std.testing.expectEqual(2, held.count);
    try std.testing.expectEqualStrings("Parameters", held.items[0].name);
    try std.testing.expectEqualStrings("value : int\n\n", held.items[0].body);
    try std.testing.expect(!held.items[0].colon);
    try std.testing.expect(held.items[0].underline);
    try std.testing.expectEqualStrings("Returns", held.items[1].name);
    try std.testing.expectEqualStrings("int\n", held.items[1].body);
}

test "a header missing its colon or its underline still opens a section" {
    const numpy = try sectioned("Read a value.\n\nParameters\nvalue : int\n", .numpy);

    try std.testing.expectEqual(1, numpy.count);
    try std.testing.expectEqualStrings("Parameters", numpy.items[0].name);
    try std.testing.expectEqualStrings("value : int\n", numpy.items[0].body);
    try std.testing.expect(!numpy.items[0].colon);
    try std.testing.expect(!numpy.items[0].underline);

    const google = try sectioned("Read a value.\n\nArgs\n    text\n", .google);

    try std.testing.expectEqual(1, google.count);
    try std.testing.expectEqualStrings("Args", google.items[0].name);
    try std.testing.expect(!google.items[0].colon);
}

test "a letter outside ascii is part of the leading words" {
    const held = try sectioned(
        "Read a value.\n\nArgs\u{e9}:\n    value: The value.\n\nArgs:\n    other: The other.\n",
        .google,
    );

    try std.testing.expectEqual(1, held.count);
    try std.testing.expectEqualStrings("Args", held.items[0].name);
}

test "a header is read in any case and keeps the bytes the author wrote" {
    const held = try sectioned("Read a value.\n\nreturns:\n    The value.\n", .google);

    try std.testing.expectEqual(1, held.count);
    try std.testing.expectEqualStrings("returns", held.items[0].name);
    try std.testing.expect(held.items[0].colon);
}

test "an underline opens a section even mid paragraph" {
    const held = try sectioned("Read a value.\nmore text\nReturns\n=======\nint\n", .numpy);

    try std.testing.expectEqual(1, held.count);
    try std.testing.expectEqualStrings("Returns", held.items[0].name);
    try std.testing.expect(held.items[0].underline);
}

test "a word that is no header opens no section" {
    const notable = try sectioned("Read a value.\n\nNotable:\n    text\n", .google);
    const sentence = try sectioned("Read a value.\n\nReturns the value.\n", .google);
    const paragraph = try sectioned("Read a value.\nmore text\nReturns:\n    int\n", .google);
    const summary = try sectioned("Returns:\n    int\n", .google);
    const numpy = try sectioned("Read a value.\n\nParameters:\n    int\n", .google);

    try std.testing.expectEqual(0, notable.count);
    try std.testing.expectEqual(0, sentence.count);
    try std.testing.expectEqual(0, paragraph.count);
    try std.testing.expectEqual(0, summary.count);
    try std.testing.expectEqual(0, numpy.count);
}

test "a deeper header in another case is a subsection" {
    const source = documented(
        "args",
        "Toggle the gizmo.\n\n    Args:\n        args: The arguments.\n    ",
    );

    const held = try sectioned_in(source, .google);

    try std.testing.expectEqual(1, held.count);
    try std.testing.expectEqualStrings("Args", held.items[0].name);
    try std.testing.expectEqualStrings("        args: The arguments.\n    ", held.items[0].body);
}

test "a deeper header spelled exactly opens a section unless a parameter bears its name" {
    const text = "Toggle the gizmo.\n\n    Args:\n        first: The first.\n" ++
        "        Args:\n            The arguments.\n    ";

    const lower = try sectioned_in(documented("args", text), .google);

    try std.testing.expectEqual(2, lower.count);
    try std.testing.expectEqualStrings("        first: The first.\n", lower.items[0].body);
    try std.testing.expectEqualStrings("Args", lower.items[1].name);
    try std.testing.expectEqualStrings("            The arguments.\n    ", lower.items[1].body);

    const exact = try sectioned_in(documented("Args", text), .google);

    try std.testing.expectEqual(1, exact.count);

    const bare = try sectioned(
        "Toggle the gizmo.\n\nArgs:\n    first: The first.\n    Args:\n        text\n",
        .google,
    );

    try std.testing.expectEqual(2, bare.count);
}

test "a lower case header under a blank line opens a section" {
    const text = "Toggle the gizmo.\n\n    Args:\n        args: The arguments.\n\n" ++
        "    returns:\n        The value.\n    ";

    const held = try sectioned_in(documented("args", text), .google);

    try std.testing.expectEqual(2, held.count);
    try std.testing.expectEqualStrings("returns", held.items[1].name);
    try std.testing.expectEqualStrings("        The value.\n    ", held.items[1].body);
}

test "a lower case header with no underline inside a section is a subsection" {
    const text = "Toggle the gizmo.\n\n    Parameters:\n    -----\n" ++
        "    parameters:\n        The arguments.\n    ";

    const held = try sectioned_in(documented("parameters", text), .numpy);

    try std.testing.expectEqual(1, held.count);
    try std.testing.expectEqualStrings("Parameters", held.items[0].name);

    const underlined_rows = try sectioned(
        "Toggle the gizmo.\n\nParameters\n----------\nvalue : int.\nreturns\n-------\nint\n",
        .numpy,
    );

    try std.testing.expectEqual(2, underlined_rows.count);
    try std.testing.expectEqualStrings("returns", underlined_rows.items[1].name);
}

test "a directive swallows the headers indented inside it" {
    const held = try sectioned(
        "Read a value.\n\n.. note::\n\n    Args:\n        text\n\nReturns:\n    int\n",
        .google,
    );

    try std.testing.expectEqual(1, held.count);
    try std.testing.expectEqualStrings("Returns", held.items[0].name);

    const nested = try sectioned(
        "Read a value.\n\n.. note::\n    .. warning::\n        Args:\n    Raises:\n",
        .google,
    );

    try std.testing.expectEqual(0, nested.count);
}

test "a module docstring reads off the module body" {
    try docstring_expect("\"doc\"\nvalue = 1\n", true);
    try docstring_expect("value = 1\n\"doc\"\n", false);
}

test "a constant that is no plain string is no docstring" {
    try docstring_expect("def read():\n    ...\n", false);
    try docstring_expect("def read():\n    42\n", false);
    try docstring_expect("def read():\n    b\"doc\"\n", false);
    try docstring_expect("def read():\n    None\n", false);
    try docstring_expect("def read():\n    \"doc\"\n", true);
}

test "every definition reads its kind and its docstring" {
    const source = "\"module\"\n" ++
        "class Holder:\n" ++
        "    \"class\"\n" ++
        "    def read(self):\n" ++
        "        \"method\"\n" ++
        "        def inner():\n" ++
        "            pass\n" ++
        "def free():\n" ++
        "    pass\n";

    try defined_expect(source, &.{
        .{ .kind = .module, .visibility = .public, .documented = true },
        .{ .kind = .class, .visibility = .public, .documented = true },
        .{ .kind = .method, .visibility = .public, .documented = true },
        .{ .kind = .nested_function, .visibility = .public, .documented = false },
        .{ .kind = .function, .visibility = .public, .documented = false },
    });
}

test "a leading underscore makes a definition private" {
    try defined_expect("def _read():\n    pass\n", &.{
        .{ .kind = .module, .visibility = .public, .documented = false },
        .{ .kind = .function, .visibility = .private, .documented = false },
    });
}

test "a definition inside a private one is private too" {
    const source = "def _read():\n" ++
        "    def inner():\n" ++
        "        pass\n";

    try defined_expect(source, &.{
        .{ .kind = .module, .visibility = .public, .documented = false },
        .{ .kind = .function, .visibility = .private, .documented = false },
        .{ .kind = .nested_function, .visibility = .private, .documented = false },
    });
}

test "a definition two levels inside a hidden one is private too" {
    const source = "__all__ = [\"read\"]\n" ++
        "def other():\n" ++
        "    class Inner:\n" ++
        "        def deep(self):\n" ++
        "            pass\n";

    try defined_expect(source, &.{
        .{ .kind = .module, .visibility = .public, .documented = false },
        .{ .kind = .function, .visibility = .private, .documented = false },
        .{ .kind = .nested_class, .visibility = .private, .documented = false },
        .{ .kind = .method, .visibility = .private, .documented = false },
    });
}

test "a module that writes dunder all hides what it leaves out" {
    const source = "__all__ = [\"read\"]\n" ++
        "def read():\n    pass\n" ++
        "def other():\n    pass\n";

    try defined_expect(source, &.{
        .{ .kind = .module, .visibility = .public, .documented = false },
        .{ .kind = .function, .visibility = .public, .documented = false },
        .{ .kind = .function, .visibility = .private, .documented = false },
    });
}

test "a dunder method stays public" {
    try defined_expect("class Holder:\n    def __init__(self):\n        pass\n", &.{
        .{ .kind = .module, .visibility = .public, .documented = false },
        .{ .kind = .class, .visibility = .public, .documented = false },
        .{ .kind = .method, .visibility = .public, .documented = false },
    });
}
