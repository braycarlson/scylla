const std = @import("std");
const assert = std.debug.assert;
const Token = @import("../syntax/token.zig");
const TreeType = @import("../syntax/tree.zig").TreeType;

pub const Jsx = enum {
    attribute,
    closing,
    element,
    expression,
    none,
    opening,
    self_closing,
    text,
};

fn WrapsType(comptime Kind: type) type {
    assert(@hasDecl(Kind, "Diagnostic"));
    assert(@hasDecl(Kind, "is_node"));

    return struct {
        grouped: fn (Kind) bool,
        wraps: fn (Kind) bool,
    };
}

const Piece = union(enum) {
    empty_line,
    expression,
    newline,
    tag: bool,
    whitespace,
    word: bool,
};

const PieceRange = struct {
    from: u32,
    to: u32,
};

const child_count_max: u32 = 512;
const jsx_whitespace = " \n\t\r";
const jsx_child: u16 = 1 << 14;
const jsx_hole: u16 = 1 << 10;
const jsx_tag: u16 = 1 << 9;
const jsx_text: u16 = 1 << 11;
const jsx_tight: u16 = 1 << 13;
const jsx_wide: u16 = 1 << 12;
const jsx_wrap: u16 = 1 << 15;
const spread_attributes = true;
const spread_tights = true;
const jsx_marks: u16 = jsx_child | jsx_hole | jsx_tag | jsx_text | jsx_tight | jsx_wide | jsx_wrap;

comptime {
    assert(@popCount(jsx_marks) == 7);
    assert(child_count_max > 0);
}

pub fn marked(
    comptime Kind: type,
    tree: *const TreeType(Kind),
    source: []const u8,
    tokens: []const Token,
    comptime jsx: fn (Kind) Jsx,
    comptime rules: *const WrapsType(Kind),
    flags: []u16,
) void {
    comptime assert(@hasDecl(Kind, "Diagnostic"));
    comptime assert(@hasDecl(Kind, "is_node"));
    assert(source.len <= std.math.maxInt(u32));
    assert(tokens.len < std.math.maxInt(u32));
    assert(flags.len <= std.math.maxInt(u32));

    marked_tags(Kind, tree, jsx, flags);

    for (tree.slice(), 0..) |node, index| {
        const position: u32 = @intCast(index);
        const kind = jsx(node.kind);
        const boxed = kind == .element or kind == .self_closing;

        if (boxed) {
            if (wrapped(Kind, tree, jsx, rules, position)) {
                marks(flags, node.token_start, node.token_start + 1, jsx_wrap);
            }
        }

        switch (kind) {
            .element => {
                childed(Kind, tree, jsx, position, flags);

                if (wide(Kind, tree, source, tokens, jsx, position)) {
                    marks(flags, node.token_start, node.token_start + 1, jsx_wide);
                }
            },
            .opening, .self_closing => {
                if (tight(Kind, tree, source, tokens, jsx, position)) {
                    marks(flags, node.token_start, node.token_start + 1, jsx_tight);
                }
            },
            .attribute, .closing, .expression, .none, .text => {},
        }
    }

    marked_texts(flags);
}

pub fn roles(mark: u16) u16 {
    if (mark & jsx_wrap != 0) assert(mark & jsx_tag != 0);

    const result = mark & jsx_marks;

    assert(result & ~jsx_marks == 0);
    assert(result <= mark);

    return result;
}

fn marked_tags(
    comptime Kind: type,
    tree: *const TreeType(Kind),
    comptime jsx: fn (Kind) Jsx,
    flags: []u16,
) void {
    assert(tree.count() == tree.slice().len);
    assert(flags.len <= std.math.maxInt(u32));

    for (tree.slice()) |node| {
        assert(node.token_start <= node.token_end);

        switch (jsx(node.kind)) {
            .closing, .opening, .self_closing => {
                marks(flags, node.token_start, node.token_end, jsx_tag);
            },
            .expression => {
                clears(flags, node.token_start, node.token_end, jsx_tag);
                holed(flags, node.token_start, node.token_end);
            },
            .text => marks(flags, node.token_start, node.token_end, jsx_text),
            .attribute, .element, .none => {},
        }
    }
}

fn marked_texts(flags: []u16) void {
    assert(flags.len < std.math.maxInt(u32));

    if (flags.len == 0) return;

    for (1..flags.len) |position| {
        const text_here = flags[position] & jsx_text != 0;
        const text_before = flags[position - 1] & jsx_text != 0;
        const joined = text_here and text_before;

        if (joined) flags[position] &= ~jsx_child;
        if (joined) assert(flags[position] & jsx_child == 0);
    }
}

fn wrapped(
    comptime Kind: type,
    tree: *const TreeType(Kind),
    comptime jsx: fn (Kind) Jsx,
    comptime rules: *const WrapsType(Kind),
    index: u32,
) bool {
    assert(index < tree.count());

    var above = tree.parent_of(index);

    for (0..tree.count()) |_| {
        const held = above orelse break;

        assert(held < index);

        if (!rules.grouped(tree.kind_at(held))) break;

        above = tree.parent_of(held);
    }

    const parent_index = above orelse return false;
    const parent = tree.kind_at(parent_index);

    return jsx(parent) == .none and rules.wraps(parent);
}

fn marks(flags: []u16, from: u32, to: u32, bit: u16) void {
    assert(from <= to);
    assert(@popCount(bit) == 1);
    assert(flags.len <= std.math.maxInt(u32));

    const stop = @min(to, flags.len);
    if (stop <= from) return;

    for (flags[from..stop]) |*mark| {
        mark.* |= bit;
    }
}

fn clears(flags: []u16, from: u32, to: u32, bit: u16) void {
    assert(from <= to);
    assert(@popCount(bit) == 1);
    assert(flags.len <= std.math.maxInt(u32));

    const stop = @min(to, flags.len);
    if (stop <= from) return;

    for (flags[from..stop]) |*mark| {
        mark.* &= ~bit;
    }
}

fn holed(flags: []u16, from: u32, to: u32) void {
    assert(flags.len < std.math.maxInt(u32));
    assert(from < std.math.maxInt(u32));
    assert(to < std.math.maxInt(u32));

    if (to <= from) return;

    marked_one(flags, from, jsx_hole);
    marked_one(flags, to - 1, jsx_hole);

    if (from < flags.len) assert(flags[from] & jsx_hole != 0);
}

fn marked_one(flags: []u16, position: u32, bit: u16) void {
    assert(@popCount(bit) == 1);
    assert(flags.len < std.math.maxInt(u32));
    assert(position < std.math.maxInt(u32));

    if (position < flags.len) flags[position] |= bit;
}

fn childed(
    comptime Kind: type,
    tree: *const TreeType(Kind),
    comptime jsx: fn (Kind) Jsx,
    index: u32,
    flags: []u16,
) void {
    assert(index < tree.count());
    assert(jsx(tree.kind_at(index)) == .element);
    assert(flags.len <= std.math.maxInt(u32));

    var held: ?u32 = null;
    var scan = tree.child_first_of(index);

    for (0..tree.count()) |_| {
        const child_index = scan orelse break;
        const child = tree.at(child_index);
        const kind = jsx(child.kind);

        scan = tree.sibling_next_of(child_index);

        if (kind == .opening) {
            held = child.token_end;

            continue;
        }

        if (kind == .closing) continue;

        if (held) |from| {
            if (from < child.token_start) {
                marks(flags, from, child.token_start, jsx_text);
                marked_one(flags, from, jsx_child);
            }
        }

        held = child.token_end;

        marked_one(flags, child.token_start, jsx_child);
    }

    const stop = closing(Kind, tree, jsx, index) orelse tree.at(index).token_end;
    const from = held orelse return;

    if (from < stop) {
        marks(flags, from, stop, jsx_text);
        marked_one(flags, from, jsx_child);
    }
}

fn closing(
    comptime Kind: type,
    tree: *const TreeType(Kind),
    comptime jsx: fn (Kind) Jsx,
    index: u32,
) ?u32 {
    assert(index < tree.count());

    var scan = tree.child_first_of(index);

    for (0..tree.count()) |_| {
        const child_index = scan orelse break;
        const child = tree.at(child_index);

        assert(child_index > index);

        if (jsx(child.kind) == .closing) return child.token_start;

        scan = tree.sibling_next_of(child_index);
    }

    return null;
}

fn tight(
    comptime Kind: type,
    tree: *const TreeType(Kind),
    source: []const u8,
    tokens: []const Token,
    comptime jsx: fn (Kind) Jsx,
    index: u32,
) bool {
    assert(index < tree.count());
    assert(source.len <= std.math.maxInt(u32));

    const node = tree.at(index);
    if (commented(tokens, node.token_start, node.token_end)) return false;

    var attributes: u32 = 0;
    var single = true;
    var scan = tree.child_first_of(index);

    for (0..tree.count()) |_| {
        const child_index = scan orelse break;
        const child = tree.at(child_index);
        const kind = jsx(child.kind);
        const counted = kind == .attribute or (spread_tights and kind == .expression);

        if (counted) {
            const stringly_attribute = kind == .attribute and
                stringly(source, tokens, child.token_start, child.token_end);

            attributes += 1;
            single = single and stringly_attribute;
        }

        scan = tree.sibling_next_of(child_index);
    }

    if (attributes == 0) return jsx(tree.kind_at(index)) == .self_closing;

    assert(attributes <= tree.count());

    return attributes == 1 and single;
}

fn commented(tokens: []const Token, from: u32, to: u32) bool {
    assert(from <= to);
    assert(tokens.len <= std.math.maxInt(u32));

    const stop = @min(to, tokens.len);

    assert(stop <= tokens.len);

    if (stop <= from) return false;

    for (tokens[from..stop]) |token| {
        if (token.kind == .comment) return true;
    }

    return false;
}

fn stringly(source: []const u8, tokens: []const Token, from: u32, to: u32) bool {
    assert(from <= to);
    assert(to <= tokens.len);

    if (to != from + 3) return false;
    assert(source.len <= std.math.maxInt(u32));

    const token = tokens[to - 1];
    return token.kind == .string and std.mem.findScalar(u8, token.text(source), '\n') == null;
}

fn wide(
    comptime Kind: type,
    tree: *const TreeType(Kind),
    source: []const u8,
    tokens: []const Token,
    comptime jsx: fn (Kind) Jsx,
    index: u32,
) bool {
    assert(index < tree.count());
    assert(tokens.len < std.math.maxInt(u32));
    assert(source.len <= std.math.maxInt(u32));

    var pieces: [child_count_max]Piece = @splat(.whitespace);
    var count: u32 = 0;
    var expressions: u32 = 0;
    var held = false;
    var scan = tree.child_first_of(index);

    for (0..tree.count()) |_| {
        const child_index = scan orelse break;
        const child = tree.at(child_index);
        const kind = jsx(child.kind);

        scan = tree.sibling_next_of(child_index);

        switch (kind) {
            .closing => {},
            .opening => held = held or attributed(Kind, tree, jsx, child_index) > 1,
            .element, .self_closing => {
                held = true;

                pushed(&pieces, &count, .{ .tag = kind == .self_closing });
            },
            .expression => {
                if (spacing(source, tokens, child.token_start, child.token_end)) {
                    pushed(&pieces, &count, .whitespace);
                } else {
                    expressions += 1;

                    pushed(&pieces, &count, .expression);
                }
            },
            .text => texted(source, tokens, child.token_start, child.token_end, &pieces, &count),
            .attribute, .none => {},
        }
    }

    held = held or expressions > 1;

    const range = trimmed(&pieces, count) orelse return false;
    return held or breaks(pieces[range.from..range.to]);
}

fn attributed(
    comptime Kind: type,
    tree: *const TreeType(Kind),
    comptime jsx: fn (Kind) Jsx,
    node: u32,
) u32 {
    assert(node < tree.count());

    var count: u32 = 0;
    var scan = tree.child_first_of(node);

    for (0..tree.count()) |_| {
        const child_index = scan orelse break;
        const kind = jsx(tree.kind_at(child_index));
        const counted = kind == .attribute or (spread_attributes and kind == .expression);

        count += @intFromBool(counted);
        scan = tree.sibling_next_of(child_index);
    }

    assert(count < tree.count());

    return count;
}

fn spacing(source: []const u8, tokens: []const Token, from: u32, to: u32) bool {
    assert(from <= to);
    assert(to <= tokens.len);

    if (to != from + 3) return false;
    assert(source.len <= std.math.maxInt(u32));

    const text = tokens[from + 1].text(source);
    return std.mem.eql(u8, text, "\" \"") or std.mem.eql(u8, text, "' '");
}

fn texted(
    source: []const u8,
    tokens: []const Token,
    from: u32,
    to: u32,
    pieces: *[child_count_max]Piece,
    count: *u32,
) void {
    assert(from <= to);
    assert(to <= tokens.len);
    assert(source.len <= std.math.maxInt(u32));

    for (tokens[from..to]) |token| {
        const text = token.text(source);
        var scan: u32 = 0;

        while (scan < text.len) {
            const white = jsx_white(text[scan]);
            var stop = scan;

            while (stop < text.len) : (stop += 1) {
                if (jsx_white(text[stop]) != white) break;
            }

            assert(stop > scan);

            const chunk = text[scan..stop];
            const first = scan == 0;
            const last = stop == text.len;

            if (white) {
                texted_white(pieces, count, chunk, first, last);
            } else {
                pushed(pieces, count, .{ .word = lettered(chunk) == 1 });
            }

            scan = stop;
        }
    }
}

fn texted_white(
    pieces: *[child_count_max]Piece,
    count: *u32,
    chunk: []const u8,
    first: bool,
    last: bool,
) void {
    assert(chunk.len > 0);
    assert(jsx_white(chunk[0]));

    const sole = first and last;
    if (sole) return whited(pieces, count, chunk);

    const edge = first or last;
    if (!edge) return;

    const lines = std.mem.findScalar(u8, chunk, '\n') != null;

    pushed(pieces, count, if (lines) .newline else .whitespace);
}

fn jsx_white(byte: u8) bool {
    if (byte > ' ') return false;

    const result = std.mem.findScalar(u8, jsx_whitespace, byte) != null;

    if (result) assert(byte <= ' ');
    if (!result) assert(byte != ' ');

    return result;
}

fn whited(pieces: *[child_count_max]Piece, count: *u32, chunk: []const u8) void {
    assert(chunk.len > 0);
    assert(count.* <= child_count_max);

    const lines = std.mem.count(u8, chunk, "\n");
    if (lines > 1) return pushed(pieces, count, .empty_line);

    if (lines == 0) pushed(pieces, count, .whitespace);
}

fn lettered(word: []const u8) u32 {
    assert(word.len < std.math.maxInt(u32));

    var count: u32 = 0;

    for (word) |byte| {
        count += @intFromBool(byte & 0xC0 != 0x80);
    }

    assert(count <= word.len);

    return count;
}

fn pushed(pieces: *[child_count_max]Piece, count: *u32, piece: Piece) void {
    if (count.* == child_count_max) return;

    if (count.* > 0) {
        if (blank(pieces[count.* - 1])) {
            if (piece == .whitespace) {
                pieces[count.* - 1] = piece;

                return;
            }

            if (blank(piece)) return;
        }
    }

    pieces[count.*] = piece;
    count.* += 1;

    assert(count.* <= child_count_max);
}

fn blank(piece: Piece) bool {
    if (piece == .expression) return false;

    const result = switch (piece) {
        .empty_line, .newline, .whitespace => true,
        .expression, .tag, .word => false,
    };

    if (piece == .whitespace) assert(result);
    if (piece == .expression) assert(!result);

    return result;
}

fn trimmed(pieces: *const [child_count_max]Piece, count: u32) ?PieceRange {
    assert(count <= child_count_max);

    var from: u32 = 0;
    var to = count;

    if (to > from) {
        if (lined(pieces[to - 1])) to -= 1;
    }

    if (to > from) {
        if (lined(pieces[from])) from += 1;
    }

    if (to <= from) return null;

    assert(to <= count);

    return .{ .from = from, .to = to };
}

fn lined(piece: Piece) bool {
    if (piece == .expression) return false;

    const result = piece == .empty_line or piece == .newline;

    if (result) assert(blank(piece));
    if (piece == .whitespace) assert(!result);

    return result;
}

fn breaks(pieces: []const Piece) bool {
    assert(pieces.len > 0);
    assert(pieces.len <= child_count_max);

    for (pieces, 0..) |piece, index| {
        const before: ?Piece = if (index > 0) pieces[index - 1] else null;
        const next = piece_at(pieces, index + 1);
        const after = piece_at(pieces, index + 2);

        const held = switch (piece) {
            .empty_line => true,
            .expression, .tag => breaks_boxed(piece, next),
            .newline => !soft(before, next, after, piece_at(pieces, index + 3)),
            .whitespace => false,
            .word => |single| !single and self_closed(next),
        };

        if (held) return true;
    }

    return false;
}

fn breaks_boxed(piece: Piece, next: ?Piece) bool {
    assert(piece == .expression or piece == .tag);
    if (next == null) return false;

    const held = next.?;
    if (held == .expression) return true;
    if (held == .tag) return true;

    const word_wide = switch (held) {
        .word => |single| !single,
        .empty_line, .expression, .newline, .tag, .whitespace => false,
    };

    const result = self_closed(piece) and word_wide;

    if (result) assert(piece == .tag);

    return result;
}

fn soft(before: ?Piece, next: ?Piece, after: ?Piece, later: ?Piece) bool {
    if (before) |held| assert(!blank(held));
    if (next) |held| assert(!blank(held));
    if (after) |held| assert(!blank(held) or later == null or !blank(later.?));

    if (worded(before)) |single| return single and !self_closed(next);

    if (worded(next)) |single| {
        const closed_after = self_closed(after);
        const newline_after = if (after) |held| held == .newline else false;
        const lined_after = newline_after and self_closed(later);

        return single and !closed_after and !lined_after;
    }

    return false;
}

fn worded(piece: ?Piece) ?bool {
    if (piece == null) return null;

    const held = piece.?;

    const result: ?bool = switch (held) {
        .word => |single| single,
        .empty_line, .expression, .newline, .tag, .whitespace => null,
    };

    if (result != null) assert(held == .word);

    return result;
}

fn self_closed(piece: ?Piece) bool {
    if (piece == null) return false;

    const held = piece.?;

    const result = switch (held) {
        .tag => |closes| closes,
        .empty_line, .expression, .newline, .whitespace, .word => false,
    };

    if (result) assert(held == .tag);

    return result;
}

fn piece_at(pieces: []const Piece, index: usize) ?Piece {
    assert(index > 0);
    assert(pieces.len <= child_count_max);

    if (index < pieces.len) return pieces[index];
    return null;
}

test "tags, texts and children carry their marks" {
    const source = "<div>hello</div><img src=\"x\"/>";

    const tokens = [_]Token{
        .{ .offset = 0, .length = 1, .kind = .{ .punctuation = .less } },
        .{ .offset = 1, .length = 3, .kind = .identifier },
        .{ .offset = 4, .length = 1, .kind = .{ .punctuation = .greater } },
        .{ .offset = 5, .length = 5, .kind = .identifier },
        .{ .offset = 10, .length = 2, .kind = .{ .punctuation = .other } },
        .{ .offset = 12, .length = 3, .kind = .identifier },
        .{ .offset = 15, .length = 1, .kind = .{ .punctuation = .greater } },
        .{ .offset = 16, .length = 1, .kind = .{ .punctuation = .less } },
        .{ .offset = 17, .length = 3, .kind = .identifier },
        .{ .offset = 21, .length = 3, .kind = .identifier },
        .{ .offset = 24, .length = 1, .kind = .{ .punctuation = .assign } },
        .{ .offset = 25, .length = 3, .kind = .string },
        .{ .offset = 28, .length = 2, .kind = .{ .punctuation = .other } },
    };

    const nodes = [_]TestNode{
        .{ .kind = .program, .token_start = 0, .token_end = 13, .parent = null },
        .{ .kind = .element, .token_start = 0, .token_end = 7, .parent = 0 },
        .{ .kind = .opening, .token_start = 0, .token_end = 3, .parent = 1 },
        .{ .kind = .text, .token_start = 3, .token_end = 4, .parent = 1 },
        .{ .kind = .closing, .token_start = 4, .token_end = 7, .parent = 1 },
        .{ .kind = .self_closing, .token_start = 7, .token_end = 13, .parent = 0 },
        .{ .kind = .attribute, .token_start = 9, .token_end = 12, .parent = 5 },
    };

    var tree: TestTree = try .init(std.testing.allocator, 16, 1);
    defer tree.deinit(std.testing.allocator);

    try tree_build(&tree, &nodes);

    var flags: [tokens.len]u16 = @splat(0);

    marked(TestKind, &tree, source, &tokens, test_jsx, &test_rules, &flags);

    const expected = [_]u16{
        jsx_tag | jsx_wrap,
        jsx_tag,
        jsx_tag,
        jsx_text | jsx_child,
        jsx_tag,
        jsx_tag,
        jsx_tag,
        jsx_tag | jsx_wrap | jsx_tight,
        jsx_tag,
        jsx_tag,
        jsx_tag,
        jsx_tag,
        jsx_tag,
    };

    try std.testing.expectEqualSlices(u16, &expected, &flags);
    try std.testing.expectEqual(jsx_tag | jsx_wrap, roles(flags[0] | 1));
}

test "an element of two expressions is wide and its holes are marked" {
    const source = "<a>{x}{y}</a>";

    const kinds = [_]Token.Kind{
        .{ .punctuation = .less },
        .identifier,
        .{ .punctuation = .greater },
        .block_start,
        .identifier,
        .block_end,
        .block_start,
        .identifier,
        .block_end,
        .{ .punctuation = .other },
        .identifier,
        .{ .punctuation = .greater },
    };

    const lengths = [_]u32{ 1, 1, 1, 1, 1, 1, 1, 1, 1, 2, 1, 1 };

    const nodes = [_]TestNode{
        .{ .kind = .program, .token_start = 0, .token_end = 12, .parent = null },
        .{ .kind = .element, .token_start = 0, .token_end = 12, .parent = 0 },
        .{ .kind = .opening, .token_start = 0, .token_end = 3, .parent = 1 },
        .{ .kind = .expression, .token_start = 3, .token_end = 6, .parent = 1 },
        .{ .kind = .expression, .token_start = 6, .token_end = 9, .parent = 1 },
        .{ .kind = .closing, .token_start = 9, .token_end = 12, .parent = 1 },
    };

    var tokens: [kinds.len]Token = undefined;
    var offset: u32 = 0;

    for (kinds, lengths, 0..) |kind, length, index| {
        tokens[index] = .{ .offset = offset, .length = length, .kind = kind };
        offset += length;
    }

    var tree: TestTree = try .init(std.testing.allocator, 16, 1);
    defer tree.deinit(std.testing.allocator);

    try tree_build(&tree, &nodes);

    var flags: [kinds.len]u16 = @splat(0);

    marked(TestKind, &tree, source, &tokens, test_jsx, &test_rules, &flags);

    const expected = [_]u16{
        jsx_tag | jsx_wrap | jsx_wide,
        jsx_tag,
        jsx_tag,
        jsx_hole | jsx_child,
        0,
        jsx_hole,
        jsx_hole | jsx_child,
        0,
        jsx_hole,
        jsx_tag,
        jsx_tag,
        jsx_tag,
    };

    try std.testing.expectEqualSlices(u16, &expected, &flags);
}

test "a tag holding a comment takes no tight layout" {
    const source = "<img src=\"x\" /* c */ />";

    const tokens = [_]Token{
        .{ .offset = 0, .length = 1, .kind = .{ .punctuation = .less } },
        .{ .offset = 1, .length = 3, .kind = .identifier },
        .{ .offset = 5, .length = 3, .kind = .identifier },
        .{ .offset = 8, .length = 1, .kind = .{ .punctuation = .assign } },
        .{ .offset = 9, .length = 3, .kind = .string },
        .{ .offset = 13, .length = 7, .kind = .comment },
        .{ .offset = 21, .length = 2, .kind = .{ .punctuation = .other } },
    };

    const nodes = [_]TestNode{
        .{ .kind = .program, .token_start = 0, .token_end = 7, .parent = null },
        .{ .kind = .self_closing, .token_start = 0, .token_end = 7, .parent = 0 },
        .{ .kind = .attribute, .token_start = 2, .token_end = 5, .parent = 1 },
    };

    var tree: TestTree = try .init(std.testing.allocator, 16, 1);
    defer tree.deinit(std.testing.allocator);

    try tree_build(&tree, &nodes);

    var flags: [tokens.len]u16 = @splat(0);

    marked(TestKind, &tree, source, &tokens, test_jsx, &test_rules, &flags);

    try std.testing.expectEqual(jsx_tag | jsx_wrap, flags[0]);
    try std.testing.expectEqual(jsx_tag, flags[5]);
}

test "text pieces break on blank lines and between boxes" {
    try std.testing.expect(breaks(&.{ .{ .word = true }, .empty_line, .{ .word = true } }));
    try std.testing.expect(breaks(&.{ .expression, .{ .tag = false } }));
    try std.testing.expect(!breaks(&.{ .{ .word = true }, .newline, .{ .word = true } }));
    try std.testing.expect(breaks(&.{ .{ .word = false }, .{ .tag = true } }));
    try std.testing.expect(!breaks(&.{ .{ .word = false }, .whitespace, .expression }));

    var pieces: [child_count_max]Piece = @splat(.whitespace);
    var count: u32 = 0;

    pushed(&pieces, &count, .newline);
    pushed(&pieces, &count, .whitespace);
    pushed(&pieces, &count, .empty_line);
    pushed(&pieces, &count, .{ .word = true });
    pushed(&pieces, &count, .newline);

    try std.testing.expectEqual(@as(u32, 3), count);
    try std.testing.expectEqual(PieceRange{ .from = 0, .to = 2 }, trimmed(&pieces, count).?);
}

const Category = @import("../syntax/category.zig").Category;

const TestKind = enum {
    attribute,
    closing,
    element,
    expression,
    opening,
    program,
    self_closing,
    text,

    pub const Diagnostic = u32;

    pub fn category(kind: TestKind) Category {
        assert(kind.is_node());

        return .other;
    }

    pub fn is_node(_: TestKind) bool {
        return true;
    }

    pub fn is_token(_: TestKind) bool {
        return false;
    }

    pub fn name(kind: TestKind) []const u8 {
        return @tagName(kind);
    }
};

const TestNode = struct {
    kind: TestKind,
    token_start: u32,
    token_end: u32,
    parent: ?u32,
};

const TestTree = TreeType(TestKind);
const test_rules: WrapsType(TestKind) = .{ .grouped = test_grouped, .wraps = test_wraps };

fn test_grouped(_: TestKind) bool {
    return false;
}

fn test_wraps(kind: TestKind) bool {
    return kind == .program;
}

fn test_jsx(kind: TestKind) Jsx {
    return switch (kind) {
        .attribute => .attribute,
        .closing => .closing,
        .element => .element,
        .expression => .expression,
        .opening => .opening,
        .program => .none,
        .self_closing => .self_closing,
        .text => .text,
    };
}

fn tree_build(tree: *TestTree, nodes: []const TestNode) !void {
    assert(nodes.len <= std.math.maxInt(u32));

    var children_last: [16]?u32 = @splat(null);

    for (nodes, 0..) |node, index| {
        const position: u32 = @intCast(index);

        try tree.push(node.kind, node.parent, node.token_start);
        tree.set_token_end(position, node.token_end);

        const parent = node.parent orelse continue;

        if (children_last[parent]) |sibling| {
            tree.set_sibling_next(sibling, position);
        } else {
            tree.set_child_first(parent, position);
        }

        children_last[parent] = position;
    }
}
