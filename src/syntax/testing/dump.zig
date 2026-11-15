const std = @import("std");
const assert = std.debug.assert;
const is_grapheme_extended = @import("../../testing/printable.zig").is_grapheme_extended;
const is_printable = @import("../../testing/printable.zig").is_printable;
const tree_module = @import("../tree.zig");
const Span = @import("../../stdx/bounded/span.zig");
const TreeType = tree_module.TreeType;

pub fn dump(
    comptime Kind: type,
    comptime T: type,
    out: *std.Io.Writer,
    tree: *const TreeType(Kind),
    tokens: []const T,
    source: []const u8,
    comptime token_name: fn (T) []const u8,
) error{WriteFailed}!void {
    assert(tokens.len <= std.math.maxInt(u32));

    comptime tree_module.positioned_check(T);

    assert(source.len <= std.math.maxInt(u32));

    const Names = struct {
        pub fn node(kind: Kind) []const u8 {
            assert(kind.is_node());

            return kind.name();
        }

        pub fn token(held: T) []const u8 {
            assert(held.offset <= held.end());

            return token_name(held);
        }
    };

    return dump_named(Kind, T, out, tree, tokens, source, Names);
}

pub fn dump_named(
    comptime Kind: type,
    comptime T: type,
    out: *std.Io.Writer,
    tree: *const TreeType(Kind),
    tokens: []const T,
    source: []const u8,
    comptime Names: type,
) error{WriteFailed}!void {
    assert(tokens.len <= std.math.maxInt(u32));

    comptime tree_module.positioned_check(T);
    comptime assert(@hasDecl(Names, "node"));
    comptime assert(@hasDecl(Names, "token"));

    assert(source.len <= std.math.maxInt(u32));

    var dumper: DumperType(Kind, T, Names.node, Names.token) = .{
        .depth = 0,
        .out = out,
        .position = 0,
        .skipped = 0,
        .source = source,
        .tokens = tokens,
    };

    var steps = tree_module.walk(TreeType(Kind), tree);

    for (0..steps.step_max) |_| {
        const step = steps.next() orelse break;

        switch (step) {
            .enter => |node| try dumper.entered(tree.at(node), node == 0),
            .leave => |node| try dumper.left(tree.at(node).token_end),
        }
    }

    assert(dumper.depth == 0);
    assert(steps.node == null);
}

fn DumperType(
    comptime Kind: type,
    comptime T: type,
    comptime node_name: fn (Kind) []const u8,
    comptime token_name: fn (T) []const u8,
) type {
    return struct {
        depth: u32,
        out: *std.Io.Writer,
        position: u32,
        skipped: u32,
        source: []const u8,
        tokens: []const T,

        const Dumper = @This();
        const Node = TreeType(Kind).Node;

        fn entered(dumper: *Dumper, node: Node, root: bool) error{WriteFailed}!void {
            assert(node.token_start <= node.token_end);

            const empty = !root and node.token_start == node.token_end;

            if (dumper.skipped > 0) {
                dumper.skipped += 1;

                return;
            }

            if (empty) {
                dumper.skipped += 1;

                return;
            }

            try dumper.tokens_dumped(node.token_start);

            const span = node.span(T, dumper.tokens);

            try indent_dumped(dumper.out, dumper.depth);
            try dumper.out.writeAll(node_name(node.kind));
            try span_dumped(dumper.out, span);
            try dumper.out.writeByte('\n');

            assert(dumper.depth < tree_module.frame_depth_max);

            dumper.depth += 1;
        }

        fn left(dumper: *Dumper, token_end: u32) error{WriteFailed}!void {
            assert(token_end <= dumper.tokens.len);

            if (dumper.skipped > 0) {
                dumper.skipped -= 1;

                return;
            }

            try dumper.tokens_dumped(token_end);

            assert(dumper.depth > 0);

            dumper.depth -= 1;
        }

        fn tokens_dumped(dumper: *Dumper, end: u32) error{WriteFailed}!void {
            assert(end <= dumper.tokens.len);

            while (dumper.position < end) : (dumper.position += 1) {
                const token = dumper.tokens[dumper.position];
                const span = Span.between(token.offset, token.end());

                assert(span.end() <= dumper.source.len);

                try indent_dumped(dumper.out, dumper.depth);
                try dumper.out.writeAll(token_name(token));
                try span_dumped(dumper.out, span);
                try dumper.out.writeAll(" \"");
                try escaped_dumped(dumper.out, span.text(dumper.source));
                try dumper.out.writeAll("\"\n");
            }

            assert(dumper.position >= end);
        }
    };
}

fn escaped_dumped(out: *std.Io.Writer, text: []const u8) error{WriteFailed}!void {
    assert(text.len <= std.math.maxInt(u32));

    if (!std.unicode.utf8ValidateSlice(text)) {
        assert(text.len > 0);

        for (text) |byte| {
            try out.print("\\x{x:0>2}", .{byte});
        }

        return;
    }

    var codepoints = std.unicode.Utf8View.initUnchecked(text).iterator();

    for (0..text.len) |_| {
        const codepoint = codepoints.nextCodepoint() orelse break;

        try character_dumped(out, codepoint);
    }

    assert(codepoints.i == text.len);
}

fn character_dumped(out: *std.Io.Writer, codepoint: u21) error{WriteFailed}!void {
    assert(codepoint <= 0x10ffff);

    switch (codepoint) {
        0 => try out.writeAll("\\0"),
        '\t' => try out.writeAll("\\t"),
        '\r' => try out.writeAll("\\r"),
        '\n' => try out.writeAll("\\n"),
        '\\' => try out.writeAll("\\\\"),
        '"' => try out.writeAll("\\\""),
        '\'' => try out.writeByte('\''),
        else => {
            const escaped = is_grapheme_extended(codepoint) or !is_printable(codepoint);

            if (escaped) return out.print("\\u{{{x}}}", .{codepoint});

            var buffer: [4]u8 = undefined;
            const width = std.unicode.utf8Encode(codepoint, &buffer) catch unreachable;

            assert(width > 0);

            try out.writeAll(buffer[0..width]);
        },
    }
}

fn indent_dumped(out: *std.Io.Writer, depth: u32) error{WriteFailed}!void {
    assert(depth <= tree_module.frame_depth_max);

    for (0..depth) |_| {
        try out.writeAll("  ");
    }
}

fn span_dumped(out: *std.Io.Writer, span: Span) error{WriteFailed}!void {
    assert(span.length <= std.math.maxInt(u32) - span.offset);

    try out.print("@{d}..{d}", .{ span.offset, span.end() });
}

test "a dump escapes text the way rust debug formatting does" {
    var buffer: [64]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buffer);

    try escaped_dumped(&out, "e\u{301}\u{a0}\u{e4}\t\"'\x00\x7f\u{1f600}\u{feff}");

    try std.testing.expectEqualStrings(
        "e\\u{301}\\u{a0}\u{e4}\\t\\\"'\\0\\u{7f}\u{1f600}\\u{feff}",
        out.buffered(),
    );
}
