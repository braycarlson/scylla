const std = @import("std");
const assert = std.debug.assert;
const Index = @import("../../text/line_index.zig").LineIndex;
const Kind = @import("../../syntax/python/kind.zig").Kind;
const Span = @import("../../stdx/bounded/span.zig");
const Token = @import("../../syntax/token.zig");
const TreeType = @import("../../syntax/tree.zig").TreeType;
const Tree = TreeType(Kind);

pub const Deletion = union(enum) {
    remove: Span,
    replace: Span,
};

pub const Padding = struct {
    after: bool,
    before: bool,
};

const Neighbours = struct {
    current: Span,
    following: Span,
    previous: Span,
};

pub fn statement_deletion(
    source: []const u8,
    tokens: []const Token,
    tree: *const Tree,
    statement: u32,
    index: *const Index,
) Deletion {
    assert(statement < tree.count());
    assert(source.len <= std.math.maxInt(u32));
    assert(tokens.len <= std.math.maxInt(u32));

    const span = tree.at(statement).span(Token, tokens);

    assert(span.end() <= source.len);

    if (is_only_statement(tree, statement)) return .{ .replace = span };

    if (semicolon_after(source, span.end())) |after| {
        const end = blanks_forward(source, after + 1);

        assert(end > span.end());

        return .{ .remove = .{ .offset = span.offset, .length = end - span.offset } };
    }

    if (has_leading_content(source, index, span.offset)) return .{ .remove = span };
    return .{ .remove = whole_lines_of(source, index, span) };
}

pub fn alias_removal(
    source: []const u8,
    tokens: []const Token,
    tree: *const Tree,
    statement: u32,
    position: u32,
    index: *const Index,
) Deletion {
    assert(statement < tree.count());
    assert(source.len <= std.math.maxInt(u32));
    assert(tokens.len <= std.math.maxInt(u32));

    const alias_count = child_count(tree, statement, .alias, 0);

    assert(position < alias_count);

    if (alias_count == 1) return statement_deletion(source, tokens, tree, statement, index);

    const neighbours = neighbour_spans(tree, tokens, statement, .alias, 0, position);
    const gap = gap_span(neighbours, position, alias_count);

    assert(gap.end() <= source.len);

    return .{ .remove = gap };
}

pub fn argument_removal(tokens: []const Token, tree: *const Tree, call: u32, position: u32) Span {
    assert(call < tree.count());
    assert(tokens.len <= std.math.maxInt(u32));

    const argument_count = child_count(tree, call, null, 1);

    assert(position < argument_count);

    const neighbours = neighbour_spans(tree, tokens, call, null, 1, position);
    const gap = gap_span(neighbours, position, argument_count);

    assert(gap.offset <= neighbours.current.offset);
    assert(gap.end() >= neighbours.current.end());

    return gap;
}

pub fn fits(
    source: []const u8,
    index: *const Index,
    span: Span,
    width: u32,
    line_width: u32,
    tab_width: u32,
) bool {
    assert(tab_width > 0);
    assert(span.end() <= source.len);
    assert(width < std.math.maxInt(u32));

    const line_head = index.line_of(span.offset);
    const line_tail = index.line_of(span.end() - @intFromBool(span.length > 0));
    const start = index.line_start(line_head);
    const end = index.line_end(line_tail, source);

    assert(start <= span.offset);
    assert(span.end() <= end);

    const head = columns_of(source[start..span.offset], tab_width);
    const tail = columns_of(without_ending(source[span.end()..end]), tab_width);

    return head + width + tail <= line_width;
}

pub fn padding(source: []const u8, span: Span, replacement: []const u8) Padding {
    assert(span.end() <= source.len);
    assert(source.len <= std.math.maxInt(u32));
    assert(replacement.len <= std.math.maxInt(u32));

    const byte_before: ?u8 = if (span.offset > 0) source[span.offset - 1] else null;
    const byte_after: ?u8 = if (span.end() < source.len) source[span.end()] else null;
    var replacement_head: ?u8 = null;
    var replacement_tail: ?u8 = null;

    if (replacement.len > 0) {
        replacement_head = replacement[0];
        replacement_tail = replacement[replacement.len - 1];
    }

    const result: Padding = .{
        .after = both_words(byte_after, replacement_tail),
        .before = both_words(byte_before, replacement_head),
    };

    if (replacement.len == 0) {
        assert(!result.after);
        assert(!result.before);
    }

    return result;
}

fn both_words(one: ?u8, two: ?u8) bool {
    if (one == null) return false;
    if (two == null) return false;

    const left = one.?;
    const right = two.?;

    return is_word(left) and is_word(right);
}

fn is_only_statement(tree: *const Tree, statement: u32) bool {
    assert(statement < tree.count());

    const parent = tree.parent_of(statement) orelse return false;

    assert(parent < statement);

    if (tree.kind_at(parent) != .block) return false;
    return child_count(tree, parent, null, 0) == 1;
}

fn has_leading_content(source: []const u8, index: *const Index, offset: u32) bool {
    assert(offset <= source.len);

    const start = index.line_start(index.line_of(offset));

    assert(start <= offset);

    return !is_blank(source[start..offset]);
}

fn whole_lines_of(source: []const u8, index: *const Index, span: Span) Span {
    assert(span.end() <= source.len);

    const line_head = index.line_of(span.offset);
    const start = index.line_start(line_head);
    const line_tail = index.line_of(span.end() - @intFromBool(span.length > 0));
    const end = index.line_end(line_tail, source);

    assert(start <= span.offset);
    assert(span.end() <= end);

    return .{ .offset = start, .length = end - start };
}

fn semicolon_after(source: []const u8, offset: u32) ?u32 {
    assert(offset <= source.len);

    const end = blanks_forward(source, offset);

    assert(end >= offset);

    if (end < source.len) {
        if (source[end] == ';') return end;
    }

    return null;
}

fn blanks_forward(source: []const u8, offset: u32) u32 {
    assert(source.len <= std.math.maxInt(u32));
    assert(offset < std.math.maxInt(u32));

    var end: u32 = @min(offset, @as(u32, @intCast(source.len)));

    while (end < source.len) : (end += 1) {
        assert(end >= offset);

        if (source[end] != '\t') {
            if (source[end] != ' ') break;
        }
    }

    assert(end <= source.len);

    return end;
}

fn is_blank(bytes: []const u8) bool {
    assert(bytes.len <= std.math.maxInt(u32));

    for (bytes) |byte| {
        if (byte != '\t') {
            if (byte != ' ') return false;
        }
    }

    return true;
}

fn is_word(byte: u8) bool {
    if (byte < '0') return false;

    const result = std.ascii.isAlphanumeric(byte) or byte == '_' or byte >= 0x80;

    if (byte == ' ') assert(!result);

    return result;
}

fn without_ending(bytes: []const u8) []const u8 {
    assert(bytes.len <= std.math.maxInt(u32));

    var end = bytes.len;

    while (end > 0) : (end -= 1) {
        assert(end <= bytes.len);

        if (bytes[end - 1] != '\n') {
            if (bytes[end - 1] != '\r') break;
        }
    }

    assert(end <= bytes.len);

    return bytes[0..end];
}

fn columns_of(bytes: []const u8, tab_width: u32) u32 {
    assert(tab_width > 0);
    assert(bytes.len <= std.math.maxInt(u32));

    var found: u32 = 0;

    for (bytes) |byte| {
        found += if (byte == '\t') tab_width else 1;
    }

    assert(found >= bytes.len);

    return found;
}

fn neighbour_spans(
    tree: *const Tree,
    tokens: []const Token,
    node: u32,
    kind: ?Kind,
    skip: u32,
    position: u32,
) Neighbours {
    assert(node < tree.count());
    assert(tokens.len <= std.math.maxInt(u32));
    assert(position < std.math.maxInt(u32));
    if (kind) |held| assert(held.is_node());

    var result: Neighbours = .{ .current = .empty, .following = .empty, .previous = .empty };
    var at: u32 = 0;
    var seen: u32 = 0;
    var child = tree.child_first_of(node);

    for (0..tree.count()) |_| {
        const index = child orelse break;
        const held = tree.at(index);

        if (kind_matches(held.kind, kind)) {
            if (seen >= skip) {
                if (at + 1 == position) result.previous = held.span(Token, tokens);
                if (at == position) result.current = held.span(Token, tokens);
                if (at == position + 1) result.following = held.span(Token, tokens);

                at += 1;
            }

            seen += 1;
        }

        child = tree.sibling_next_of(index);
    }

    assert(child == null);
    assert(at > position);

    return result;
}

fn kind_matches(held: Kind, wanted: ?Kind) bool {
    if (wanted == null) return true;
    assert(held.is_node());

    const kind = wanted.?;
    return held == kind;
}

fn child_count(tree: *const Tree, node: u32, kind: ?Kind, skip: u32) u32 {
    assert(node < tree.count());
    if (kind) |held| assert(held.is_node());

    var found: u32 = 0;
    var child = tree.child_first_of(node);

    for (0..tree.count()) |_| {
        const index = child orelse break;

        if (kind_matches(tree.kind_at(index), kind)) found += 1;

        child = tree.sibling_next_of(index);
    }

    assert(child == null);
    assert(found <= tree.count());

    return found -| skip;
}

fn gap_span(neighbours: Neighbours, position: u32, count: u32) Span {
    assert(position < count);
    assert(neighbours.current.length <= std.math.maxInt(u32) - neighbours.current.offset);

    if (position + 1 < count) {
        assert(neighbours.following.offset >= neighbours.current.offset);

        return .{
            .offset = neighbours.current.offset,
            .length = neighbours.following.offset - neighbours.current.offset,
        };
    }

    if (position > 0) {
        assert(neighbours.current.end() >= neighbours.previous.end());

        return .{
            .offset = neighbours.previous.end(),
            .length = neighbours.current.end() - neighbours.previous.end(),
        };
    }

    return neighbours.current;
}
