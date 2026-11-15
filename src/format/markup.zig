const std = @import("std");
const assert = std.debug.assert;
const ArrayType = @import("../stdx/bounded/array.zig").ArrayType;
const Blocks = @import("../syntax/markup/blocks.zig").Blocks;
const Buffer = @import("../stdx/bounded/buffer.zig");
const Document = @import("ir.zig").Document;
const FormatterError = @import("formatters.zig").FormatterError;
const Index = @import("../text/line_index.zig").LineIndex;
const LineRange = @import("walk.zig").LineRange;
const Node = @import("../syntax/markup/tree.zig").Tree.Node;
const Options = @import("print.zig").Options;
const Span = @import("../stdx/bounded/span.zig");
const Structure = @import("../syntax/tree.zig").Structure;
const TagSpecification = @import("../syntax/markup/vocabulary.zig").Vocabulary.TagSpecification;
const Token = @import("../syntax/markup/token.zig").Token;
const Tokens = @import("../syntax/markup/tokens.zig").Tokens;
const Tree = @import("../syntax/markup/tree.zig").Tree;
const Vocabulary = @import("../syntax/markup/vocabulary.zig").Vocabulary;
const blocks = @import("../syntax/markup/blocks.zig");
const indent_depth_max = @import("ir.zig").indent_depth_max;
const is_ascii_whitespace = @import("../text/scan.zig").is_ascii_whitespace;
const lexer = @import("../syntax/markup/lex.zig");
const markup_tree = @import("../syntax/markup/tree.zig");
const print = @import("print.zig").print;
const span_of = @import("walk.zig").span_of;

pub const Formatter = struct {
    document: Document,
    layout: Layout,
    scratch: Buffer,

    pub fn init(
        gpa: std.mem.Allocator,
        element_count_max: u32,
        line_count_max: u32,
        scratch_bytes_max: u32,
    ) std.mem.Allocator.Error!Formatter {
        assert(element_count_max > 0);
        assert(line_count_max > 0);
        assert(scratch_bytes_max > 0);

        var document: Document = try .init(gpa, element_count_max, literal_count_max);
        errdefer document.deinit(gpa);

        var layout: Layout = try .init(gpa, line_count_max);
        errdefer layout.deinit(gpa);

        const scratch: Buffer = try .init(gpa, scratch_bytes_max);

        assert(scratch.empty());
        assert(layout.depths.capacity() == line_count_max);

        return .{ .document = document, .layout = layout, .scratch = scratch };
    }

    pub fn deinit(formatter: *Formatter, gpa: std.mem.Allocator) void {
        assert(formatter.scratch.count() <= formatter.scratch.capacity());
        assert(formatter.layout.depths.count() == formatter.layout.verbatim.count());

        formatter.scratch.deinit(gpa);
        formatter.layout.deinit(gpa);
        formatter.document.deinit(gpa);
        formatter.* = undefined;
    }

    pub fn format(formatter: *Formatter, input: *const Input, out: *Buffer) FormatterError!void {
        assert(input.source.len < std.math.maxInt(u32));
        assert(input.index.count() == line_count_of(input.source));

        if (input.tree.diagnostic_slice().len > 0) return error.SourceInvalid;

        formatter.format_printed(input, out) catch |err| switch (err) {
            error.Overflow => return error.OutputExhausted,
        };
    }

    pub fn range(
        formatter: *Formatter,
        input: *const Input,
        lines: LineRange,
        out: *Buffer,
    ) FormatterError!Span {
        assert(lines.first <= lines.last);
        assert(input.source.len < std.math.maxInt(u32));

        try formatter.format(input, out);

        return span_of(out.const_slice(), lines) orelse error.SourceInvalid;
    }

    fn format_printed(
        formatter: *Formatter,
        input: *const Input,
        out: *Buffer,
    ) error{Overflow}!void {
        assert(input.tree.diagnostic_slice().len == 0);
        assert(input.tokens.len < std.math.maxInt(u32));

        formatter.document.clear();
        formatter.scratch.clear();

        try normalize(input, &formatter.scratch);

        const scratch = formatter.scratch.const_slice();

        assert(line_count_of(scratch) == input.index.count());

        try formatter.layout.open(input.index.count());

        depths(input, &formatter.layout);
        marks(input, &formatter.layout);

        try emit(scratch, &formatter.layout, &formatter.document);
        try print(&formatter.document, scratch, &.{}, input.options, out);
    }
};

pub const Input = struct {
    index: *const Index,
    map: *const Blocks,
    options: Options,
    source: []const u8,
    tokens: []const Token,
    tree: *const Tree,
};

const Layout = struct {
    depths: ArrayType(?u32),
    verbatim: ArrayType(bool),

    fn init(gpa: std.mem.Allocator, line_count_max: u32) error{OutOfMemory}!Layout {
        assert(line_count_max > 0);

        var depths_held: ArrayType(?u32) = try .init(gpa, line_count_max);
        errdefer depths_held.deinit(gpa);

        const verbatim: ArrayType(bool) = try .init(gpa, line_count_max);

        assert(depths_held.empty());
        assert(verbatim.capacity() == line_count_max);

        return .{ .depths = depths_held, .verbatim = verbatim };
    }

    fn deinit(layout: *Layout, gpa: std.mem.Allocator) void {
        assert(layout.depths.capacity() == layout.verbatim.capacity());
        assert(layout.depths.count() == layout.verbatim.count());

        layout.verbatim.deinit(gpa);
        layout.depths.deinit(gpa);
        layout.* = undefined;
    }

    fn claim(layout: *Layout, line: u32, depth: u32) void {
        assert(line < layout.depths.count());
        assert(layout.depths.count() == layout.verbatim.count());
        assert(depth < std.math.maxInt(u32));

        const held = &layout.depths.slice()[line];

        if (held.* == null) held.* = depth;

        assert(held.* != null);
    }

    fn depth_of(layout: *const Layout, line: u32) u32 {
        assert(line < layout.depths.count());
        assert(layout.depths.count() == layout.verbatim.count());

        return layout.depths.get(line) orelse 0;
    }

    fn is_verbatim(layout: *const Layout, line: u32) bool {
        assert(line < layout.verbatim.count());
        assert(layout.depths.count() == layout.verbatim.count());

        return layout.verbatim.get(line);
    }

    fn mark(layout: *Layout, first: u32, last: u32) void {
        assert(first <= last);
        assert(last < layout.verbatim.count());

        @memset(layout.verbatim.slice()[first .. last + 1], true);
    }

    fn open(layout: *Layout, line_count: u32) error{Overflow}!void {
        assert(line_count > 0);
        assert(layout.depths.capacity() == layout.verbatim.capacity());

        layout.depths.clear();
        layout.verbatim.clear();

        if (line_count > layout.depths.capacity()) return error.Overflow;

        for (0..line_count) |_| {
            layout.depths.push(null);
            layout.verbatim.push(false);
        }

        assert(layout.depths.count() == line_count);
        assert(layout.verbatim.count() == line_count);
    }

    fn opens_verbatim(layout: *const Layout, line: u32) bool {
        assert(line < layout.verbatim.count());
        assert(!layout.is_verbatim(line));

        const next = line + 1;
        if (next >= layout.verbatim.count()) return false;
        return layout.is_verbatim(next);
    }
};

const Opened = struct {
    close: ?u32,
    open: ?u32,
};

const Quoting = struct {
    escaped: bool,
    quote: ?u8,

    const outside: Quoting = .{ .escaped = false, .quote = null };

    fn advance(quoting: *Quoting, byte: u8) void {
        if (quoting.escaped) assert(quoting.quote != null);

        const held = quoting.quote orelse {
            const quotes = byte == '"' or byte == '\'';

            if (quotes) quoting.quote = byte;

            return;
        };

        if (quoting.escaped) {
            quoting.escaped = false;
        } else if (byte == '\\') {
            quoting.escaped = true;
        } else if (byte == held) {
            quoting.quote = null;
        } else {}
    }
};

const ascii_whitespace = " \t\n\x0c\r";
const closers = [_][]const u8{ "#}", "%}", "}}" };
const literal_count_max: u32 = 4;
const modifiers = "+-";
const openers = [_][]const u8{ "{#", "{%", "{{" };
const verbatim_elements = [_][]const u8{ "listing", "pre", "script", "style", "textarea", "xmp" };

comptime {
    for (ascii_whitespace) |byte| assert(is_ascii_whitespace(byte));

    assert(openers.len == closers.len);
}

fn normalize(input: *const Input, scratch: *Buffer) error{Overflow}!void {
    assert(scratch.empty());
    assert(input.source.len < std.math.maxInt(u32));

    var cursor: u32 = 0;

    for (input.tree.slice()) |node| {
        switch (node.kind) {
            .template_tag, .template_variable => {},
            else => continue,
        }

        const span = node.span(Token, input.tokens);
        const bytes = span.text(input.source);

        if (span.offset < cursor) continue;
        if (std.mem.findScalar(u8, bytes, '\n') != null) continue;

        try scratch.push(input.source[cursor..span.offset]);
        try tightened(bytes, scratch);
        cursor = span.end();
    }

    try scratch.push(input.source[cursor..]);

    assert(cursor <= input.source.len);
}

fn tightened(bytes: []const u8, out: *Buffer) error{Overflow}!void {
    assert(std.mem.findScalar(u8, bytes, '\n') == null);

    const open = opener_of(bytes) orelse return out.push(bytes);
    const close = closer_of(bytes) orelse return out.push(bytes);
    if (bytes.len < open.len + close.len) return out.push(bytes);

    const body = bytes[open.len .. bytes.len - close.len];
    const lead = modifier_length(body, 0);
    const trail = if (body.len > lead) modifier_length(body, body.len - 1) else 0;
    const inner = body[lead .. body.len - trail];

    assert(lead + inner.len + trail == body.len);

    if (!quotes_closed(inner)) return out.push(bytes);

    try out.push(open);
    try out.push(body[0..lead]);

    if (!is_blank(inner)) {
        const spaced_lead = lead == 0 or is_ascii_whitespace(inner[0]);
        const spaced_trail = trail == 0 or is_ascii_whitespace(inner[inner.len - 1]);

        if (spaced_lead) try out.push(" ");

        try squeezed(inner, out);

        if (spaced_trail) try out.push(" ");
    }

    try out.push(body[lead + inner.len ..]);
    try out.push(close);
}

fn modifier_length(body: []const u8, offset: usize) u32 {
    assert(offset <= body.len);

    if (offset == body.len) return 0;
    return @intFromBool(std.mem.findScalar(u8, modifiers, body[offset]) != null);
}

fn opener_of(bytes: []const u8) ?[]const u8 {
    assert(bytes.len <= std.math.maxInt(u32));

    for (openers) |held| {
        assert(held.len == 2);

        if (std.mem.startsWith(u8, bytes, held)) return held;
    }

    return null;
}

fn closer_of(bytes: []const u8) ?[]const u8 {
    assert(bytes.len <= std.math.maxInt(u32));

    for (closers) |held| {
        assert(held.len == 2);

        if (std.mem.endsWith(u8, bytes, held)) return held;
    }

    return null;
}

fn squeezed(body: []const u8, out: *Buffer) error{Overflow}!void {
    assert(body.len > 0);
    assert(!is_blank(body));
    assert(quotes_closed(body));

    var quoting: Quoting = .outside;
    var spaced = false;
    var written = false;

    for (body) |byte| {
        const quoted = quoting.quote != null;

        quoting.advance(byte);

        if (quoted) {
            try out.push_byte(byte);

            spaced = false;

            continue;
        }

        if (is_ascii_whitespace(byte)) {
            spaced = written;

            continue;
        }

        if (spaced) try out.push_byte(' ');

        try out.push_byte(byte);

        spaced = false;
        written = true;
    }

    assert(written);
    assert(quoting.quote == null);
}

fn quotes_closed(bytes: []const u8) bool {
    assert(bytes.len < std.math.maxInt(u32));

    var quoting: Quoting = .outside;

    for (bytes) |byte| quoting.advance(byte);

    return quoting.quote == null;
}

fn depths(input: *const Input, layout: *Layout) void {
    assert(layout.depths.count() == input.index.count());
    assert(input.tokens.len < std.math.maxInt(u32));

    const token_count: u32 = @intCast(input.tokens.len);
    var steps = markup_tree.walk(input.tree);
    var cursor: u32 = 0;
    var depth: u32 = 0;

    for (0..steps.step_max) |_| {
        const step = steps.next() orelse break;

        switch (step) {
            .enter => |node| {
                claim(input, layout, &cursor, input.tree.at(node).token_start, depth);
                depth = entered(input, node, depth);
            },
            .leave => |node| {
                claim(input, layout, &cursor, input.tree.at(node).token_end, depth);
                depth = left(input, node, depth);
            },
        }
    }

    claim(input, layout, &cursor, token_count, depth);

    assert(cursor == token_count);
}

fn claim(input: *const Input, layout: *Layout, cursor: *u32, stop: u32, depth: u32) void {
    assert(stop <= input.tokens.len);
    assert(layout.depths.count() == input.index.count());
    assert(depth < std.math.maxInt(u32));

    if (cursor.* >= stop) return;

    for (input.tokens[cursor.*..stop]) |token| {
        if (token.kind == .whitespace) continue;

        claim_token(input, layout, token, depth);
    }

    cursor.* = stop;
}

fn claim_token(input: *const Input, layout: *Layout, token: Token, depth: u32) void {
    assert(token.length > 0);
    assert(token.kind != .whitespace);
    assert(depth < std.math.maxInt(u32));

    const bytes = token.text(input.source);
    var start: usize = 0;

    for (0..bytes.len) |_| {
        if (start >= bytes.len) break;

        const newline = std.mem.findScalarPos(u8, bytes, start, '\n');
        const stop = if (newline) |held| held + 1 else bytes.len;
        const line = bytes[start..stop];
        const lead = line.len - std.mem.trimStart(u8, line, ascii_whitespace).len;

        if (lead < line.len) {
            const offset: u32 = token.offset + @as(u32, @intCast(start + lead));

            layout.claim(input.index.line_of(offset), depth);
        }

        start = stop;
    }

    assert(start == bytes.len);
}

fn entered(input: *const Input, node: u32, depth: u32) u32 {
    assert(node < std.math.maxInt(u32));

    const held = input.tree.at(node);

    switch (held.kind) {
        .close_tag => {
            assert(depth < std.math.maxInt(u32));

            return depth -| 1;
        },
        .template_tag => {},
        else => return depth,
    }

    assert(held.token_start < held.token_end);

    const offset = held.span(Token, input.tokens).offset;

    if (closes(input.map, offset)) {
        assert(depth -| 1 < std.math.maxInt(u32));

        return depth -| 1;
    }

    if (intermediates(input.map, offset)) {
        assert(depth -| 1 < std.math.maxInt(u32));

        return depth -| 1;
    }

    return depth;
}

fn left(input: *const Input, node: u32, depth: u32) u32 {
    assert(node < std.math.maxInt(u32));
    assert(depth < std.math.maxInt(u32));

    const held = input.tree.at(node);

    switch (held.kind) {
        .open_tag => {
            const parent = input.tree.parent_of(node) orelse return depth;
            if (!paired(input.tree, parent)) return depth;
            assert(depth + 1 < std.math.maxInt(u32));

            return depth + 1;
        },
        .template_tag => {},
        else => return depth,
    }

    assert(held.token_start < held.token_end);

    const offset = held.span(Token, input.tokens).offset;

    if (opens(input.map, offset)) {
        assert(depth + 1 < std.math.maxInt(u32));

        return depth + 1;
    }

    if (intermediates(input.map, offset)) {
        assert(depth + 1 < std.math.maxInt(u32));

        return depth + 1;
    }

    return depth;
}

fn closes(map: *const Blocks, offset: u32) bool {
    for (map.block_slice()) |*block| {
        const close = block.close orelse continue;

        assert(close.span.offset >= block.open.span.end());

        if (close.span.offset == offset) return true;
    }

    return false;
}

fn intermediates(map: *const Blocks, offset: u32) bool {
    for (map.block_slice()) |*block| {
        if (!block.is_closed()) continue;

        for (map.intermediates_of(block)) |held| {
            assert(held.span.offset > block.open.span.offset);

            if (held.span.offset == offset) return true;
        }
    }

    return false;
}

fn opens(map: *const Blocks, offset: u32) bool {
    for (map.block_slice()) |*block| {
        if (!block.is_closed()) continue;
        if (block.open.span.offset == offset) return true;
    }

    return false;
}

fn paired(tree: *const Tree, element: u32) bool {
    assert(element < tree.count());

    if (tree.kind_at(element) != .element) return false;

    const opened = opened_of(tree, element);

    if (opened.close != null) assert(opened.open != null);

    return opened.close != null;
}

fn opened_of(tree: *const Tree, node: u32) Opened {
    assert(node < tree.count());

    var opened: Opened = .{ .close = null, .open = null };
    var child = tree.child_first_of(node);

    for (0..tree.count()) |_| {
        const held = child orelse break;

        switch (tree.kind_at(held)) {
            .close_tag => opened.close = held,
            .open_tag => opened.open = held,
            else => {},
        }

        child = tree.sibling_next_of(held);
    }

    if (opened.open) |open| assert(tree.at(open).parent == node);
    if (opened.close) |close| assert(tree.at(close).parent == node);

    return opened;
}

fn name_of(tree: *const Tree, tokens: []const Token, source: []const u8, node: u32) []const u8 {
    assert(node < tree.count());
    assert(tokens.len < std.math.maxInt(u32));
    assert(source.len <= std.math.maxInt(u32));

    var child = tree.child_first_of(node);

    for (0..tree.count()) |_| {
        const held = child orelse break;
        const open = tree.at(held);

        if (open.kind == .open_tag) {
            for (tokens[open.token_start..open.token_end]) |token| {
                if (token.kind == .element_name) return token.text(source);
            }
        }

        child = tree.sibling_next_of(held);
    }

    return "";
}

fn marks(input: *const Input, layout: *Layout) void {
    assert(layout.verbatim.count() == input.index.count());
    assert(input.tree.count() > 0);

    for (input.tree.slice(), 0..) |*node, position| {
        switch (node.kind) {
            .element => marks_element(input, layout, @intCast(position)),
            .html_comment, .template_comment => mark(input, layout, node.span(Token, input.tokens)),
            .template_tag => marks_template(input, layout, node),
            else => {},
        }
    }
}

fn marks_template(input: *const Input, layout: *Layout, node: *const Node) void {
    assert(node.kind == .template_tag);
    assert(node.token_end <= input.tokens.len);

    for (input.tokens[node.token_start..node.token_end]) |token| {
        if (token.kind == .verbatim_text) mark(input, layout, token.span());
    }
}

fn marks_element(input: *const Input, layout: *Layout, element: u32) void {
    assert(element < input.tree.count());
    assert(input.tree.kind_at(element) == .element);

    const name = name_of(input.tree, input.tokens, input.source, element);
    if (!verbatim_named(name)) return;

    const opened = opened_of(input.tree, element);
    const open = opened.open orelse return;
    const close = opened.close orelse return;
    const start = input.tree.at(open).span(Token, input.tokens).end();
    const end = input.tree.at(close).span(Token, input.tokens).offset;
    if (end <= start) return;

    mark(input, layout, .{ .offset = start, .length = end - start });
}

fn verbatim_named(name: []const u8) bool {
    assert(name.len <= std.math.maxInt(u32));

    for (verbatim_elements) |held| {
        assert(held.len > 0);

        if (std.ascii.eqlIgnoreCase(held, name)) return true;
    }

    return false;
}

fn mark(input: *const Input, layout: *Layout, span: Span) void {
    assert(span.end() <= input.source.len);
    assert(layout.verbatim.count() == input.index.count());

    if (span.length == 0) return;

    const first = input.index.line_of(span.offset) + 1;
    const last = input.index.line_of(span.end());
    if (last < first) return;

    layout.mark(first, last);
}

fn emit(bytes: []const u8, layout: *const Layout, document: *Document) error{Overflow}!void {
    assert(line_count_of(bytes) == layout.verbatim.count());
    assert(document.count() == 0);

    const last = line_last_of(bytes, layout) orelse {
        if (bytes.len == 0) return;
        return document.push(.hard_line);
    };

    var indent: u32 = 0;
    var offset: u32 = 0;
    var pieces = std.mem.splitScalar(u8, bytes, '\n');

    for (0..last + 1) |line| {
        const held = pieces.next() orelse unreachable;
        const span: Span = .{ .offset = offset, .length = @intCast(held.len) };

        offset += span.length + 1;

        try emit_line(document, layout, bytes, span, @intCast(line), &indent);
    }

    try level(document, &indent, 0);

    assert(indent == 0);
}

fn emit_line(
    document: *Document,
    layout: *const Layout,
    bytes: []const u8,
    span: Span,
    line: u32,
    indent: *u32,
) error{Overflow}!void {
    assert(span.end() <= bytes.len);
    assert(line < layout.verbatim.count());

    const text = span.text(bytes);
    const verbatim = layout.is_verbatim(line);
    const empty = if (verbatim) text.len == 0 else is_blank(text);
    if (empty) return document.push(.hard_line);

    const wanted: u32 = if (verbatim) 0 else layout.depth_of(line);

    try level(document, indent, wanted);

    if (verbatim) {
        try document.push(.{ .verbatim = span });
    } else if (layout.opens_verbatim(line)) {
        try document.push(.{ .verbatim = trimmed_start(bytes, span) });
    } else {
        try document.push(.{ .text = .{ .source = .document, .span = trimmed(bytes, span) } });
    }

    try document.push(.hard_line);
}

fn line_last_of(bytes: []const u8, layout: *const Layout) ?u32 {
    assert(line_count_of(bytes) == layout.verbatim.count());
    assert(layout.verbatim.count() > 0);

    var found: ?u32 = null;
    var pieces = std.mem.splitScalar(u8, bytes, '\n');

    for (0..layout.verbatim.count()) |position| {
        const held = pieces.next() orelse unreachable;
        const line: u32 = @intCast(position);
        const empty = if (layout.is_verbatim(line)) held.len == 0 else is_blank(held);

        if (!empty) found = line;
    }

    if (found) |line| assert(line < layout.verbatim.count());

    return found;
}

fn level(document: *Document, indent: *u32, wanted: u32) error{Overflow}!void {
    assert(indent.* <= indent_depth_max);

    if (wanted > indent_depth_max) return error.Overflow;

    if (indent.* > wanted) {
        for (0..indent.* - wanted) |_| try document.push(.dedent);
    }

    if (indent.* < wanted) {
        for (0..wanted - indent.*) |_| try document.push(.indent);
    }

    indent.* = wanted;

    assert(indent.* == document.indent_depth);
}

fn trimmed(bytes: []const u8, span: Span) Span {
    assert(span.end() <= bytes.len);

    const held = span.text(bytes);
    const start = held.len - std.mem.trimStart(u8, held, ascii_whitespace).len;
    const kept = std.mem.trim(u8, held, ascii_whitespace);

    assert(kept.len > 0);
    assert(start + kept.len <= held.len);

    return .{ .offset = span.offset + @as(u32, @intCast(start)), .length = @intCast(kept.len) };
}

fn trimmed_start(bytes: []const u8, span: Span) Span {
    assert(span.end() <= bytes.len);

    const held = span.text(bytes);
    const kept = std.mem.trimStart(u8, held, ascii_whitespace);
    const start: u32 = @intCast(held.len - kept.len);

    assert(kept.len > 0);
    assert(start + kept.len == held.len);

    return .{ .offset = span.offset + start, .length = @intCast(kept.len) };
}

fn is_blank(bytes: []const u8) bool {
    assert(bytes.len < std.math.maxInt(u32));

    return std.mem.trimStart(u8, bytes, ascii_whitespace).len == 0;
}

fn line_count_of(bytes: []const u8) u32 {
    assert(bytes.len < std.math.maxInt(u32));

    const newline_count: u32 = @intCast(std.mem.count(u8, bytes, "\n"));

    assert(newline_count <= bytes.len);

    return newline_count + 1;
}

const test_specifications = [_]TagSpecification{
    .{ .intermediates = &.{ "elif", "else" }, .name = "if" },
};

const test_words = [_][]const u8{ "elif", "else" };

fn expect_formatted(source: []const u8, expected: []const u8) !void {
    assert(source.len <= std.math.maxInt(u32));

    const gpa = std.testing.allocator;
    var formatter: Formatter = try .init(gpa, 1 << 14, 1 << 10, 1 << 16);
    defer formatter.deinit(gpa);

    var index: Index = try .init(gpa, 1 << 10);
    defer index.deinit(gpa);

    var map: Blocks = try .init(gpa, 1 << 8);
    defer map.deinit(gpa);

    var out: Buffer = try .init(gpa, 1 << 16);
    defer out.deinit(gpa);

    var tokens: Tokens = try .init(gpa, 1 << 12);
    defer tokens.deinit(gpa);

    var tree: Tree = try .init(gpa, 1 << 12, 1 << 6);
    defer tree.deinit(gpa);

    var vocabulary: Vocabulary = .empty;

    vocabulary.end_prefix = "end";
    vocabulary.intermediate_words = &test_words;
    vocabulary.specifications = &test_specifications;

    try index.build(source);
    try lexer.lex(source, &tokens);
    _ = markup_tree.build(source, tokens.slice(), &tree);

    try std.testing.expectEqual(
        Structure.complete,
        blocks.build(&map, source, tokens.slice(), &tree, &vocabulary),
    );

    const input: Input = .{
        .index = &index,
        .map = &map,
        .options = .default,
        .source = source,
        .tokens = tokens.slice(),
        .tree = &tree,
    };

    try formatter.format(&input, &out);
    try std.testing.expectEqualStrings(expected, out.const_slice());
}

test "an element indents its children" {
    try expect_formatted("<div>\n<p>a</p>\n</div>\n", "<div>\n    <p>a</p>\n</div>\n");
    try expect_formatted("<br>\n<hr>\n", "<br>\n<hr>\n");
}

test "a paired template tag indents its body" {
    try expect_formatted(
        "{% if a %}\nx\n{% else %}\ny\n{% endif %}\n",
        "{% if a %}\n    x\n{% else %}\n    y\n{% endif %}\n",
    );
}

test "a single line tag is tightened" {
    try expect_formatted("{{  a|title  }}\n", "{{ a|title }}\n");
    try expect_formatted("{%if  a%}\n{%endif%}\n", "{% if a %}\n{% endif %}\n");
    try expect_formatted("{{}}\n", "{{}}\n");
    try expect_formatted("{% trans  \"a   b\"  %}\n", "{% trans \"a   b\" %}\n");
}

test "a verbatim body keeps every byte" {
    try expect_formatted(
        "<div>\n<pre>\n  a  \n</pre>\n</div>\n",
        "<div>\n    <pre>\n  a  \n</pre>\n</div>\n",
    );
}

test "the line that opens a verbatim body keeps its trailing blanks" {
    try expect_formatted("{# a  \nb #}\n", "{# a  \nb #}\n");

    try expect_formatted(
        "<div>\n<!-- c \t\n d -->\n<pre>  \n e\n</pre>\n</div>\n",
        "<div>\n    <!-- c \t\n d -->\n    <pre>  \n e\n</pre>\n</div>\n",
    );
}

test "a blank trimmed after an escape leaves the string on its line" {
    try expect_formatted("{{ 'a\\\t\nb' }}\n", "{{ 'a\\\nb' }}\n");
    try expect_formatted("{{ 'a\\\nb' }}\n", "{{ 'a\\\nb' }}\n");
}

test "a whitespace preserving body keeps every byte" {
    try expect_formatted(
        "<div>\n<xmp>\n  <b>  \n</xmp>\n<listing>\n a\n</listing>\n</div>\n",
        "<div>\n    <xmp>\n  <b>  \n</xmp>\n    <listing>\n a\n</listing>\n</div>\n",
    );
}

test "a trailing blank run becomes one newline" {
    try expect_formatted("<p>a</p>\n\n\n", "<p>a</p>\n");
    try expect_formatted("   \n\n", "\n");
    try expect_formatted("", "");
}

test "an interior blank line survives" {
    try expect_formatted("<p>a</p>\n\n<p>b</p>\n", "<p>a</p>\n\n<p>b</p>\n");
}

test "a comment keeps every line after its first" {
    try expect_formatted(
        "{#\n    a\n  b\n#}\n<div>\n<!-- c\n      d -->\n</div>\n",
        "{#\n    a\n  b\n#}\n<div>\n    <!-- c\n      d -->\n</div>\n",
    );

    try expect_formatted(
        "{#\n    a\n#}\n{%- if a %}\n<div>\nx\n</div>\n{%- endif %}\n",
        "{#\n    a\n#}\n{%- if a %}\n<div>\n    x\n</div>\n{%- endif %}\n",
    );
}

test "a construct whose quote stays open is left as written" {
    const source = "{{}}\n{{ \"{{selected}} / {{total}} files\" | t: {selected: 2} }}\n";
    const formatted = "{{}}\n{{ \"{{selected}} / {{ total }} files\" | t: {selected: 2} }}\n";

    try expect_formatted(source, formatted);
    try expect_formatted(formatted, formatted);
    try expect_formatted("{{  \"a   b  }}\n", "{{  \"a   b  }}\n");
    try expect_formatted("{{  a 'b -}}\n", "{{  a 'b -}}\n");
}

test "an escaped quote stays inside its string" {
    try expect_formatted("{{  \"a\\\"  b\"  }}\n", "{{ \"a\\\"  b\" }}\n");
    try expect_formatted("{{ \"a\\\"  b\" }}\n", "{{ \"a\\\"  b\" }}\n");
    try expect_formatted("{%  trans  'it\\'s   so'  %}\n", "{% trans 'it\\'s   so' %}\n");
}

test "a whitespace control marker stays on its delimiter" {
    try expect_formatted("{%- if a -%}\n", "{%- if a -%}\n");
    try expect_formatted("{%-if  a-%}\n", "{%-if a-%}\n");
    try expect_formatted("{%+  if a  +%}\n", "{%+ if a +%}\n");
    try expect_formatted("{{  x  -}}\n", "{{ x -}}\n");
    try expect_formatted("{{-1}}\n", "{{-1 }}\n");
    try expect_formatted("{{ -1 }}\n", "{{ -1 }}\n");
    try expect_formatted("{{-}}\n{{--}}\n{{- }}\n", "{{-}}\n{{--}}\n{{-}}\n");
}
