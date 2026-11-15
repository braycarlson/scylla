const std = @import("std");
const assert = std.debug.assert;
const Kind = @import("kind.zig").Kind;
const Diagnostic = @import("diagnostic.zig").Diagnostic;
const Dialect = @import("vocabulary.zig").Vocabulary.Dialect;
const RawTextTag = @import("vocabulary.zig").Vocabulary.RawTextTag;
const Span = @import("../../stdx/bounded/span.zig");
const Token = @import("token.zig").Token;
const Tokens = @import("tokens.zig").Tokens;
const generic = @import("../tree.zig");
const lexer = @import("lex.zig");
const tree_dump = @import("../testing/dump.zig").dump;
const tree_dump_named = @import("../testing/dump.zig").dump_named;
const Structure = generic.Structure;
pub const Tree = generic.TreeType(Kind);
const Node = Tree.Node;
pub const Walk = generic.WalkType(Tree);
const frame_depth_max = generic.frame_depth_max;

const Frame = struct {
    child_last: ?u32,
    name_token: ?u32,
    node: ?u32,
    offset: u32,
};

const Shape = struct {
    node: Kind,
    close: Kind,
    error_kind: Diagnostic.Kind,
};

const Implied = struct {
    name: []const u8,
    closers: []const []const u8,
};

const Builder = struct {
    depth: u32,
    dialect: Dialect,
    outcome: Structure,
    position: u32,
    source: []const u8,
    stack: [frame_depth_max]Frame,
    tokens: []const Token,
    tree: *Tree,

    fn run(builder: *Builder) Structure {
        builder.start(.document, null);

        while (builder.position < builder.tokens.len) {
            const before = builder.position;

            builder.step();

            if (builder.outcome == .too_deep) break;

            if (builder.position <= before) builder.bump();
        }

        builder.close_open_elements();
        builder.finish();

        assert(builder.depth == 0);
        assert(builder.position <= builder.tokens.len);

        return builder.outcome;
    }

    fn step(builder: *Builder) void {
        assert(builder.depth > 0);
        assert(builder.position < builder.tokens.len);

        const kind = builder.current() orelse return;

        switch (kind) {
            .angle_open => builder.parse_open_tag(),
            .angle_open_slash => builder.parse_close_tag(),
            .comment_open, .tag_open, .variable_open => builder.parse_template_construct(kind),
            .doctype_text => builder.parse_declaration(),
            .html_comment_open => builder.parse_html_comment(),
            .angle_close,
            .attribute_name,
            .attribute_text,
            .attribute_value,
            .attribute,
            .close_tag,
            .colon,
            .comma,
            .comment_close,
            .comment_text,
            .doctype,
            .document,
            .dot,
            .element,
            .element_name,
            .equals,
            .error_node,
            .error_token,
            .filter,
            .filter_chain,
            .html_comment,
            .html_comment_close,
            .identifier,
            .number,
            .open_tag,
            .pipe,
            .quote,
            .script_text,
            .slash,
            .slash_angle_close,
            .string,
            .style_text,
            .tag_close,
            .tag_name,
            .template_comment,
            .template_tag,
            .template_variable,
            .text,
            .variable_close,
            .verbatim_text,
            .whitespace,
            => builder.bump(),
        }
    }

    fn parse_open_tag(builder: *Builder) void {
        assert(builder.depth > 0);
        assert(builder.current() == .angle_open);

        const name = builder.element_name_at(builder.position +| 1);

        builder.close_implied_by(name);

        const nests = builder.element_depth() < element_depth_max;

        builder.start(.element, name);
        builder.start(.open_tag, null);
        builder.bump();

        if (builder.current() == .element_name) builder.bump();

        const closed = builder.parse_attributes();

        builder.finish_node();

        if (builder.open_tag_ends(name, closed, nests)) builder.finish_node();
    }

    fn open_tag_ends(builder: *const Builder, name: ?u32, closed: ?Kind, nests: bool) bool {
        assert(builder.depth > 0);
        if (name) |held| assert(held < builder.tokens.len);
        if (closed) |held| assert(held == .angle_close or held == .slash_angle_close);

        if (!nests) return true;

        const closer = closed orelse return true;
        const held = name orelse return closer == .slash_angle_close;
        if (builder.is_void_element(held)) return true;
        if (closer == .angle_close) return false;
        return builder.is_foreign(held);
    }

    fn is_foreign(builder: *const Builder, name: u32) bool {
        var index = builder.depth;

        assert(builder.depth <= frame_depth_max);
        assert(builder.tokens[name].kind == .element_name);

        if (name_listed(&foreign_roots, builder.name_of(name))) return true;

        for (0..builder.depth) |_| {
            index -= 1;

            const held = builder.stack[index].name_token orelse continue;
            if (held == name) continue;

            const ancestor = builder.name_of(held);
            if (name_listed(&integration_points, ancestor)) return false;
            if (name_listed(&foreign_roots, ancestor)) return true;
        }

        return false;
    }

    fn parse_close_tag(builder: *Builder) void {
        assert(builder.depth > 0);
        assert(builder.current() == .angle_open_slash);

        const name = builder.element_name_at(builder.position +| 1);
        const offset = builder.offset_current();

        const unwind = builder.matching_frame(name) orelse {
            builder.record(.unexpected_close_tag, offset, name);
            builder.parse_wrapped_close_tag(.error_node);

            return;
        };

        assert(unwind < unwind_depth_max);

        for (0..unwind) |_| builder.close_unclosed_element();

        builder.parse_wrapped_close_tag(.close_tag);
        builder.finish_node();
    }

    fn parse_attributes(builder: *Builder) ?Kind {
        assert(builder.depth > 0);
        assert(builder.position <= builder.tokens.len);

        for (builder.position..builder.tokens.len) |_| {
            const kind = builder.current() orelse break;

            switch (kind) {
                .angle_close, .slash_angle_close => {
                    builder.bump();

                    return kind;
                },
                .attribute_name => builder.parse_attribute(),
                .comment_open, .tag_open, .variable_open => builder.parse_template_construct(kind),
                else => builder.bump(),
            }
        }

        assert(builder.position == builder.tokens.len);

        return null;
    }

    fn parse_attribute(builder: *Builder) void {
        assert(builder.depth > 0);
        assert(builder.current() == .attribute_name);

        builder.start(.attribute, null);
        builder.bump();

        if (builder.peek_significant() != .equals) {
            builder.finish_node();

            return;
        }

        builder.bump_trivia();
        builder.bump();
        builder.bump_trivia();

        if (builder.current()) |kind| {
            switch (kind) {
                .quote => builder.parse_quoted_value(),
                .attribute_text => builder.parse_unquoted_value(),
                .comment_open, .tag_open, .variable_open => {
                    if (builder.dialect == .django) builder.parse_unquoted_value();
                },
                else => {},
            }
        }

        builder.finish_node();
    }

    fn parse_unquoted_value(builder: *Builder) void {
        assert(builder.depth > 0);
        assert(builder.current() != null);

        if (builder.dialect == .html) return builder.parse_wrapped(.attribute_value);

        builder.start(.attribute_value, null);

        for (builder.position..builder.tokens.len) |_| {
            const kind = builder.current() orelse break;

            if (is_construct_open(kind)) {
                builder.parse_template_construct(kind);
            } else if (is_value_text(kind)) {
                builder.bump();
            } else {
                break;
            }
        }

        builder.finish_node();
    }

    fn parse_quoted_value(builder: *Builder) void {
        assert(builder.depth > 0);
        assert(builder.current() == .quote);

        const offset = builder.offset_current();

        builder.start(.attribute_value, null);
        builder.bump();

        var terminated = false;

        for (builder.position..builder.tokens.len) |_| {
            const kind = builder.current() orelse break;

            if (kind == .quote) {
                builder.bump();
                terminated = true;

                break;
            }

            if (is_construct_open(kind)) {
                builder.parse_template_construct(kind);
            } else if (is_value_text(kind)) {
                builder.bump();
            } else {
                break;
            }
        }

        if (!terminated) builder.record(.unterminated_attribute_value, offset, null);

        builder.finish_node();
    }

    fn parse_template_construct(builder: *Builder, open: Kind) void {
        assert(builder.current() == open);
        assert(is_construct_open(open));

        const shape = construct_shape(open);
        const offset = builder.offset_current();

        builder.start(shape.node, null);
        builder.bump();

        var filter_open = false;
        var terminated = false;

        for (builder.position..builder.tokens.len) |_| {
            const kind = builder.current() orelse break;

            if (kind == shape.close) {
                builder.close_filters(&filter_open);
                builder.bump();
                terminated = true;

                break;
            }

            if (kind == .pipe) builder.open_filter(&filter_open);

            builder.bump();
        }

        builder.close_filters(&filter_open);

        if (!terminated) builder.record(shape.error_kind, offset, null);

        builder.finish_node();
    }

    fn parse_declaration(builder: *Builder) void {
        assert(builder.depth > 0);
        assert(builder.current() == .doctype_text);

        builder.start(.doctype, null);

        for (builder.position..builder.tokens.len) |_| {
            const kind = builder.current() orelse break;

            if (is_construct_open(kind)) {
                builder.parse_template_construct(kind);
            } else if (kind == .doctype_text) {
                const held = builder.tokens[builder.position].text(builder.source);

                builder.bump();

                if (std.mem.endsWith(u8, held, ">")) break;
            } else {
                break;
            }
        }

        builder.finish_node();
    }

    fn parse_html_comment(builder: *Builder) void {
        assert(builder.depth > 0);
        assert(builder.current() == .html_comment_open);

        builder.start(.html_comment, null);
        builder.bump();

        for (builder.position..builder.tokens.len) |_| {
            const kind = builder.current() orelse break;

            if (is_construct_open(kind)) {
                builder.parse_template_construct(kind);
            } else if (kind == .html_comment_close) {
                builder.bump();

                break;
            } else {
                builder.bump();
            }
        }

        builder.finish_node();
    }

    fn parse_wrapped(builder: *Builder, node: Kind) void {
        assert(node.is_node());
        assert(builder.current() != null);

        builder.start(node, null);
        builder.bump();
        builder.finish_node();
    }

    fn parse_wrapped_close_tag(builder: *Builder, wrapper: Kind) void {
        assert(builder.current() == .angle_open_slash);
        assert(wrapper == .close_tag or wrapper == .error_node);

        builder.start(wrapper, null);
        builder.bump();

        for (builder.position..builder.tokens.len) |_| {
            const kind = builder.current() orelse break;

            builder.bump();

            if (kind == .angle_close) break;

            if (kind == .slash_angle_close) {
                if (builder.dialect == .html) break;
            }
        }

        builder.finish_node();
    }

    fn close_filters(builder: *Builder, filter_open: *bool) void {
        assert(builder.depth > 0);

        if (!filter_open.*) return;

        builder.finish_node();
        builder.finish_node();

        filter_open.* = false;
    }

    fn open_filter(builder: *Builder, filter_open: *bool) void {
        assert(builder.current() == .pipe);
        assert(builder.depth > 0);

        if (filter_open.*) {
            builder.finish_node();
        } else {
            builder.start(.filter_chain, null);
        }

        builder.start(.filter, null);

        filter_open.* = true;
    }

    fn close_implied_by(builder: *Builder, opening: ?u32) void {
        assert(builder.depth <= frame_depth_max);
        if (opening) |held| assert(held < builder.tokens.len);

        const opening_token = opening orelse return;

        if (builder.depth == 0) return;

        const open = builder.stack[builder.depth - 1].name_token orelse return;
        const name = builder.name_of(opening_token);
        const open_name = builder.name_of(open);

        for (implied_close) |entry| {
            if (!name_equals(open_name, entry.name)) continue;

            for (entry.closers) |closer| {
                if (name_equals(name, closer)) return builder.finish_node();
            }

            return;
        }
    }

    fn close_open_elements(builder: *Builder) void {
        assert(builder.depth > 0);

        while (builder.depth > 1) builder.close_unclosed_element();

        assert(builder.depth <= 1);
    }

    fn close_unclosed_element(builder: *Builder) void {
        assert(builder.depth <= frame_depth_max);
        assert(builder.depth > 0);

        const frame = builder.stack[builder.depth - 1];

        if (frame.name_token) |name| builder.record(.unclosed_element, frame.offset, name);

        builder.finish_node();
    }

    fn finish(builder: *Builder) void {
        assert(builder.depth <= 1);

        while (builder.depth > 0) builder.finish_node();

        assert(builder.depth == 0);
    }

    fn finish_node(builder: *Builder) void {
        assert(builder.depth <= frame_depth_max);
        assert(builder.position <= builder.tokens.len);

        if (builder.depth == 0) return;

        builder.depth -= 1;

        const frame = builder.stack[builder.depth];
        const node = frame.node orelse return;

        builder.tree.set_token_end(node, builder.position);
    }

    fn start(builder: *Builder, kind: Kind, name_token: ?u32) void {
        assert(builder.depth <= frame_depth_max);
        assert(kind.is_node());
        if (name_token) |held| assert(held < builder.tokens.len);

        if (builder.depth >= frame_depth_max) {
            builder.outcome = .too_deep;

            return;
        }

        const offset = builder.offset_current();
        const parent = if (builder.depth == 0) null else builder.stack[builder.depth - 1].node;
        const index = builder.tree.count();
        const pushed = builder.tree.push(kind, parent, builder.position);

        pushed catch |err| switch (err) {
            error.Truncated => {
                builder.outcome = .{ .truncated = .nodes };

                builder.frame_push(.{
                    .child_last = null,
                    .name_token = name_token,
                    .node = null,
                    .offset = offset,
                });

                return;
            },
        };

        if (builder.depth > 0) builder.link(index);

        builder.frame_push(.{
            .child_last = null,
            .name_token = name_token,
            .node = index,
            .offset = offset,
        });
    }

    fn frame_push(builder: *Builder, frame: Frame) void {
        assert(builder.depth < frame_depth_max);

        builder.stack[builder.depth] = frame;
        builder.depth += 1;

        assert(builder.depth <= frame_depth_max);
    }

    fn link(builder: *Builder, index: u32) void {
        assert(builder.depth > 0);
        assert(index < builder.tree.count());

        const parent = &builder.stack[builder.depth - 1];

        if (parent.child_last) |last| {
            builder.tree.set_sibling_next(last, index);
        } else if (parent.node) |node| {
            builder.tree.set_child_first(node, index);
        } else {}

        parent.child_last = index;
    }

    fn record(builder: *Builder, kind: Diagnostic.Kind, offset: u32, name_token: ?u32) void {
        assert(offset <= builder.source.len);
        if (name_token) |held| assert(held < builder.tokens.len);

        const name: Span = if (name_token) |held| builder.token_span(held) else .empty;

        const recorded = builder.tree.push_diagnostic(.{
            .kind = kind,
            .name = name,
            .span = .{ .length = 0, .offset = offset },
        });

        recorded catch |err| switch (err) {
            error.Truncated => {
                if (builder.outcome == .complete) builder.outcome = .{ .truncated = .diagnostics };
            },
        };
    }

    fn token_span(builder: *const Builder, index: u32) Span {
        assert(index <= builder.tokens.len);
        assert(builder.tokens.len <= std.math.maxInt(u32));

        if (index >= builder.tokens.len) return .empty;
        return builder.tokens[index].span();
    }

    fn bump(builder: *Builder) void {
        if (builder.position >= builder.tokens.len) return;

        builder.position += 1;

        assert(builder.position <= builder.tokens.len);
    }

    fn bump_trivia(builder: *Builder) void {
        assert(builder.depth > 0);
        assert(builder.position <= builder.tokens.len);

        for (builder.position..builder.tokens.len) |_| {
            const kind = builder.current() orelse break;
            if (!kind.is_trivia()) break;

            builder.bump();
        }
    }

    fn current(builder: *const Builder) ?Kind {
        assert(builder.tokens.len <= std.math.maxInt(u32));
        assert(builder.position <= builder.tokens.len);

        if (builder.position >= builder.tokens.len) return null;
        return builder.tokens[builder.position].kind;
    }

    fn offset_current(builder: *const Builder) u32 {
        assert(builder.source.len <= std.math.maxInt(u32));
        assert(builder.position <= builder.tokens.len);

        if (builder.position >= builder.tokens.len) return 0;
        return builder.tokens[builder.position].offset;
    }

    fn peek_significant(builder: *const Builder) ?Kind {
        assert(builder.depth > 0);
        assert(builder.position <= builder.tokens.len);

        if (builder.position >= builder.tokens.len) return null;

        for (builder.tokens[builder.position..]) |held| {
            if (!held.kind.is_trivia()) return held.kind;
        }

        return null;
    }

    fn element_depth(builder: *const Builder) u32 {
        assert(builder.depth <= frame_depth_max);

        var held: u32 = 0;

        for (builder.stack[0..builder.depth]) |frame| {
            if (frame.name_token != null) held += 1;
        }

        assert(held <= builder.depth);

        return held;
    }

    fn element_name_at(builder: *const Builder, position: u32) ?u32 {
        assert(builder.tokens.len <= std.math.maxInt(u32));
        assert(position > 0);

        if (position >= builder.tokens.len) return null;
        if (builder.tokens[position].kind != .element_name) return null;
        return position;
    }

    fn matching_frame(builder: *const Builder, name: ?u32) ?u32 {
        if (name) |held| assert(held < builder.tokens.len);
        assert(builder.depth <= frame_depth_max);

        const name_token = name orelse return null;
        const wanted = builder.name_of(name_token);
        var seen: u32 = 0;
        var index = builder.depth;

        while (index > 0) {
            if (seen >= unwind_depth_max) return null;

            index -= 1;

            const frame = builder.stack[index];

            if (frame.name_token) |held| {
                if (name_equals(builder.name_of(held), wanted)) return seen;
            }

            seen += 1;
        }

        return null;
    }

    fn is_void_element(builder: *const Builder, name: u32) bool {
        assert(builder.tokens[name].kind == .element_name);
        assert(name < builder.tokens.len);

        const text = builder.name_of(name);

        for (void_elements) |element| {
            if (name_equals(text, element)) return true;
        }

        return false;
    }

    fn name_of(builder: *const Builder, index: u32) []const u8 {
        assert(builder.tokens.len <= std.math.maxInt(u32));
        assert(index <= builder.tokens.len);

        if (index >= builder.tokens.len) return "";

        const found = builder.tokens[index];

        assert(found.end() <= builder.source.len);

        return builder.source[found.offset..found.end()];
    }
};

pub const element_depth_max: u32 = 256;
pub const unwind_depth_max: u32 = 64;

const implied_close = [_]Implied{
    .{ .name = "dd", .closers = &.{ "dd", "dt" } },
    .{ .name = "dt", .closers = &.{ "dd", "dt" } },
    .{ .name = "li", .closers = &.{"li"} },
    .{ .name = "option", .closers = &.{ "optgroup", "option" } },
    .{ .name = "p", .closers = &.{
        "address",
        "article",
        "aside",
        "blockquote",
        "div",
        "dl",
        "fieldset",
        "footer",
        "form",
        "h1",
        "h2",
        "h3",
        "h4",
        "h5",
        "h6",
        "header",
        "hr",
        "main",
        "nav",
        "ol",
        "p",
        "pre",
        "section",
        "table",
        "ul",
    } },
    .{ .name = "td", .closers = &.{ "td", "th", "tr" } },
    .{ .name = "th", .closers = &.{ "td", "th", "tr" } },
    .{ .name = "tr", .closers = &.{"tr"} },
};

const foreign_roots = [_][]const u8{
    "math",
    "svg",
};

const integration_points = [_][]const u8{
    "desc",
    "foreignobject",
    "mi",
    "mn",
    "mo",
    "ms",
    "mtext",
    "title",
};

const void_elements = [_][]const u8{
    "area",
    "base",
    "br",
    "col",
    "embed",
    "hr",
    "img",
    "input",
    "link",
    "meta",
    "param",
    "source",
    "track",
    "wbr",
};

pub fn build(source: []const u8, tokens: []const Token, tree: *Tree) Structure {
    assert(source.len <= std.math.maxInt(u32));
    assert(tokens.len <= std.math.maxInt(u32));

    return build_dialect(source, tokens, tree, .html);
}

pub fn build_dialect(
    source: []const u8,
    tokens: []const Token,
    tree: *Tree,
    dialect: Dialect,
) Structure {
    assert(source.len <= std.math.maxInt(u32));
    assert(tokens.len <= std.math.maxInt(u32));

    tree.clear();

    var builder: Builder = .{
        .depth = 0,
        .dialect = dialect,
        .outcome = .complete,
        .position = 0,
        .source = source,
        .stack = undefined,
        .tokens = tokens,
        .tree = tree,
    };

    const outcome = builder.run();

    assert(tree.count() > 0);
    assert(builder.depth == 0);

    return outcome;
}

pub fn dump(
    out: *std.Io.Writer,
    tree: *const Tree,
    tokens: []const Token,
    source: []const u8,
) error{WriteFailed}!void {
    assert(source.len <= std.math.maxInt(u32));
    assert(tokens.len <= std.math.maxInt(u32));

    try tree_dump(Kind, Token, out, tree, tokens, source, token_name);

    const errors = tree.diagnostic_slice();
    if (errors.len == 0) return;

    try out.writeAll("\nerrors:\n");

    for (errors) |held| {
        try out.print("  {s}@{d}\n", .{ held.kind.title(), held.span.offset });
    }
}

pub fn dump_named(
    out: *std.Io.Writer,
    tree: *const Tree,
    tokens: []const Token,
    source: []const u8,
    comptime name_of: fn (Kind) []const u8,
) error{WriteFailed}!void {
    assert(source.len <= std.math.maxInt(u32));
    assert(tokens.len <= std.math.maxInt(u32));

    const Names = struct {
        pub fn node(kind: Kind) []const u8 {
            assert(kind.is_node());

            return name_of(kind);
        }

        pub fn token(held: Token) []const u8 {
            assert(held.kind.is_token());

            return name_of(held.kind);
        }
    };

    try tree_dump_named(Kind, Token, out, tree, tokens, source, Names);
}

pub fn walk(tree: *const Tree) Walk {
    assert(tree.diagnostic_slice().len <= tree.diagnostics.capacity());
    assert(tree.count() <= tree.nodes.capacity());

    return generic.walk(Tree, tree);
}

pub fn walk_from(tree: *const Tree, node: u32) Walk {
    assert(tree.count() <= tree.nodes.capacity());
    assert(node < tree.count());

    return generic.walk_from(Tree, tree, node);
}

fn token_name(held: Token) []const u8 {
    assert(held.length > 0);
    assert(held.kind.is_token());

    return held.kind.name();
}

fn construct_shape(open: Kind) Shape {
    assert(is_construct_open(open));

    return switch (open) {
        .comment_open => .{
            .node = .template_comment,
            .close = .comment_close,
            .error_kind = .unterminated_template_comment,
        },
        .tag_open => .{
            .node = .template_tag,
            .close = .tag_close,
            .error_kind = .unterminated_template_tag,
        },
        else => .{
            .node = .template_variable,
            .close = .variable_close,
            .error_kind = .unterminated_template_variable,
        },
    };
}

fn is_construct_open(kind: Kind) bool {
    if (!kind.is_token()) return false;

    return switch (kind) {
        .comment_open, .tag_open, .variable_open => true,
        else => false,
    };
}

fn is_value_text(kind: Kind) bool {
    if (!kind.is_token()) return false;

    return switch (kind) {
        .attribute_text, .verbatim_text => true,
        else => false,
    };
}

fn name_equals(name: []const u8, other: []const u8) bool {
    assert(name.len <= std.math.maxInt(u32));
    assert(other.len <= std.math.maxInt(u32));

    return std.ascii.eqlIgnoreCase(name, other);
}

fn name_listed(names: []const []const u8, name: []const u8) bool {
    assert(names.len <= std.math.maxInt(u32));
    assert(name.len <= std.math.maxInt(u32));

    for (names) |listed| {
        if (name_equals(listed, name)) return true;
    }

    return false;
}

const Built = struct {
    tokens: Tokens,
    tree: Tree,

    fn init(built: *Built, gpa: std.mem.Allocator, source: []const u8) !void {
        assert(source.len <= std.math.maxInt(u32));

        built.tokens = try .init(gpa, 1 << 10);
        errdefer built.tokens.deinit(gpa);

        built.tree = try .init(gpa, 1 << 10, 1 << 4);
        errdefer built.tree.deinit(gpa);

        lexer.lex(source, &built.tokens) catch |err| switch (err) {
            error.Truncated => return error.TestUnexpectedResult,
        };

        _ = build(source, built.tokens.slice(), &built.tree);
    }

    fn deinit(built: *Built, gpa: std.mem.Allocator) void {
        built.tree.deinit(gpa);
        built.tokens.deinit(gpa);
    }
};

test "a solidus closes only an element the HTML parser lets it close" {
    const gpa = std.testing.allocator;

    const cases = [_]struct { []const u8, []const u8, []const u8 }{
        .{ "<div/><p></p>", "p", "div" },
        .{ "<br/><p></p>", "p", "" },
        .{ "<svg><path/><g></g></svg>", "g", "svg" },
        .{ "<svg/><p></p>", "p", "" },
        .{ "<svg><foreignObject><div/><p></p></foreignObject></svg>", "p", "div" },
        .{ "<math><mi/><mo></mo></math>", "mo", "math" },
        .{ "<math><mi><span/><b></b></mi></math>", "b", "span" },
        .{ "<svg><title/><g></g></svg>", "g", "svg" },
        .{ "<custom-element/><p></p>", "p", "custom-element" },
        .{ "<svg><desc><i/><b></b></desc></svg>", "b", "i" },
    };

    var tokens: Tokens = try .init(gpa, 1 << 8);
    defer tokens.deinit(gpa);

    var tree: Tree = try .init(gpa, 1 << 8, 1 << 4);
    defer tree.deinit(gpa);

    for (cases) |case| {
        for ([_]Dialect{ .html, .django }) |dialect| {
            try lexer.lex_dialect(case[0], &tokens, &.{}, dialect);

            const outcome = build_dialect(case[0], tokens.slice(), &tree, dialect);
            const parent = parent_named(&tree, tokens.slice(), case[0], case[1]);

            try std.testing.expectEqual(Structure.complete, outcome);
            try std.testing.expectEqualStrings(case[2], parent);
        }
    }
}

fn parent_named(
    tree: *const Tree,
    tokens: []const Token,
    source: []const u8,
    name: []const u8,
) []const u8 {
    assert(name.len > 0);
    assert(tokens.len <= std.math.maxInt(u32));
    assert(source.len <= std.math.maxInt(u32));

    for (tree.slice(), 0..) |node, index| {
        if (node.kind != .element) continue;
        if (!std.mem.eql(u8, element_named(node, tokens, source), name)) continue;

        const parent = tree.parent_of(@intCast(index)) orelse unreachable;
        const above = tree.at(parent);
        if (above.kind != .element) return "";
        return element_named(above, tokens, source);
    }

    unreachable;
}

fn element_named(node: Node, tokens: []const Token, source: []const u8) []const u8 {
    assert(node.kind == .element);
    assert(tokens.len <= std.math.maxInt(u32));
    assert(source.len <= std.math.maxInt(u32));

    const name = tokens[node.token_start + 1];

    assert(name.kind == .element_name);

    return source[name.offset..name.end()];
}

test "an unclosed element names its tag" {
    const gpa = std.testing.allocator;
    const source = "<div><span>a</div>\n";
    var built: Built = undefined;

    try built.init(gpa, source);
    defer built.deinit(gpa);

    const held = built.tree.diagnostic_slice()[0];

    try std.testing.expectEqual(Diagnostic.Kind.unclosed_element, held.kind);
    try std.testing.expectEqualStrings("span", held.name.text(source));
    try std.testing.expectEqual(5, held.span.offset);
}

test "an unexpected close tag names its tag" {
    const gpa = std.testing.allocator;
    const source = "<div></p></div>\n";
    var built: Built = undefined;

    try built.init(gpa, source);
    defer built.deinit(gpa);

    const held = built.tree.diagnostic_slice()[0];

    try std.testing.expectEqual(Diagnostic.Kind.unexpected_close_tag, held.kind);
    try std.testing.expectEqualStrings("p", held.name.text(source));
    try std.testing.expectEqual(5, held.span.offset);
}

test "an unterminated construct names nothing" {
    const gpa = std.testing.allocator;
    var built: Built = undefined;

    try built.init(gpa, "{{ a ");
    defer built.deinit(gpa);

    const errors = built.tree.diagnostic_slice();

    try std.testing.expectEqual(1, errors.len);
    try std.testing.expectEqual(Diagnostic.Kind.unterminated_template_variable, errors[0].kind);
    try std.testing.expectEqual(Span.empty, errors[0].name);
}

test "a dump lists the tree then its errors" {
    const gpa = std.testing.allocator;
    const source = "<p>a";
    var built: Built = undefined;

    try built.init(gpa, source);
    defer built.deinit(gpa);

    var buffer: [1 << 10]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buffer);

    try dump(&out, &built.tree, built.tokens.slice(), source);

    try std.testing.expectEqualStrings(
        "document@0..4\n  element@0..4\n    open_tag@0..3\n      angle_open@0..1 \"<\"\n" ++
            "      element_name@1..2 \"p\"\n      angle_close@2..3 \">\"\n    text@3..4 \"a\"\n" ++
            "\nerrors:\n  UnclosedElement@0\n",
        out.buffered(),
    );
}

test "a starved dump reports the overflow" {
    const gpa = std.testing.allocator;
    const source = "<p>a</p>\n";
    var built: Built = undefined;

    try built.init(gpa, source);
    defer built.deinit(gpa);

    var buffer: [8]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buffer);

    try std.testing.expectError(
        error.WriteFailed,
        dump(&out, &built.tree, built.tokens.slice(), source),
    );
}

test "a Django declaration holds the constructs inside it" {
    const gpa = std.testing.allocator;

    const cases = [_]struct { dumped: []const u8, source: []const u8 }{
        .{
            .dumped = "document@0..13\n  doctype@0..12\n    doctype_text@0..3 \"<!x\"\n" ++
                "    template_tag@3..10\n      tag_open@3..5 \"{%\"\n" ++
                "      whitespace@5..6 \" \"\n      tag_name@6..7 \"a\"\n" ++
                "      whitespace@7..8 \" \"\n      tag_close@8..10 \"%}\"\n" ++
                "    doctype_text@10..12 \"y>\"\n  text@12..13 \"z\"\n",
            .source = "<!x{% a %}y>z",
        },
        .{
            .dumped = "document@0..10\n  doctype@0..10\n    doctype_text@0..3 \"<!x\"\n" ++
                "    template_variable@3..10\n      variable_open@3..5 \"{{\"\n" ++
                "      whitespace@5..6 \" \"\n      identifier@6..7 \"y\"\n" ++
                "      whitespace@7..8 \" \"\n      variable_close@8..10 \"}}\"\n",
            .source = "<!x{{ y }}",
        },
    };

    for (cases) |case| {
        var tokens: Tokens = try .init(gpa, 1 << 6);
        defer tokens.deinit(gpa);

        var tree: Tree = try .init(gpa, 1 << 6, 1 << 4);
        defer tree.deinit(gpa);

        try lexer.lex_dialect(case.source, &tokens, &.{}, .django);

        const outcome = build_dialect(case.source, tokens.slice(), &tree, .django);
        var buffer: [1 << 10]u8 = undefined;
        var out: std.Io.Writer = .fixed(&buffer);

        try dump(&out, &tree, tokens.slice(), case.source);

        try std.testing.expectEqual(Structure.complete, outcome);
        try std.testing.expectEqualStrings(case.dumped, out.buffered());
    }
}

test "a Django raw body inside a quoted value stays in the value" {
    const gpa = std.testing.allocator;

    const raw_text_tags = [_]RawTextTag{
        .{ .body = .text, .end = "endcomment", .name = "comment", .stage = .parser },
        .{ .body = .text, .end = "endverbatim", .name = "verbatim", .stage = .lexer },
    };

    const sources = [_][]const u8{
        "<a b=\"x{% comment %}q{% endcomment %}y\">z</a>",
        "<a b=\"x{% comment %}\"q>{% endcomment %}y\">z</a>",
        "<a b='x{% verbatim %}{{ q }}{% endverbatim %}y'>z</a>",
    };

    for (sources) |source| {
        var tokens: Tokens = try .init(gpa, 1 << 6);
        defer tokens.deinit(gpa);

        var tree: Tree = try .init(gpa, 1 << 6, 1 << 4);
        defer tree.deinit(gpa);

        try lexer.lex_dialect(source, &tokens, &raw_text_tags, .django);

        const outcome = build_dialect(source, tokens.slice(), &tree, .django);
        var value: ?u32 = null;

        for (tree.slice(), 0..) |node, index| {
            if (node.kind == .attribute_value) value = @intCast(index);
        }

        const span = tree.at(value.?).span(Token, tokens.slice());
        const quote = source[span.offset];

        try std.testing.expectEqual(Structure.complete, outcome);
        try std.testing.expectEqual(0, tree.diagnostic_slice().len);
        try std.testing.expectEqual(quote, source[span.end() - 1]);
        try std.testing.expectEqual(std.mem.findScalarLast(u8, source, quote).?, span.end() - 1);
    }
}

test "a Django unquoted value runs across the constructs inside it" {
    const cases = [_]Unquoted{
        .{
            .names = &.{ "href", "class" },
            .source = "<a href={{ url }} class=\"x\">y</a>",
            .values = &.{ "{{ url }}", "\"x\"" },
        },
        .{
            .names = &.{"href"},
            .source = "<a href={% url 'a' %}?resend=True>y</a>",
            .values = &.{"{% url 'a' %}?resend=True"},
        },
        .{
            .names = &.{"@click"},
            .source = "<a @click=go({{ id }})>y</a>",
            .values = &.{"go({{ id }})"},
        },
        .{
            .names = &.{ "x", "e" },
            .source = "<a x=a{% comment %}b c{% endcomment %}d e>y</a>",
            .values = &.{"a{% comment %}b c{% endcomment %}d"},
        },
        .{
            .names = &.{ "x", "z" },
            .source = "<a x= {{ y }} z>y</a>",
            .values = &.{"{{ y }}"},
        },
        .{
            .names = &.{ "x", "c" },
            .source = "<a x=a=b c>y</a>",
            .values = &.{"a=b"},
        },
        .{
            .names = &.{ "x", "c" },
            .source = "<a x={{ y }}=z c>y</a>",
            .values = &.{"{{ y }}=z"},
        },
        .{
            .names = &.{"x"},
            .source = "<a x={{ y }}/></a>",
            .values = &.{"{{ y }}/"},
        },
    };

    for (cases) |case| try unquoted_expect(&case);
}

test "a Django solidus splits attributes and joins unquoted values the way HTML does" {
    const cases = [_]Unquoted{
        .{
            .names = &.{"x-show"},
            .source = "<p/x-show=\"go((\"></p>",
            .values = &.{"\"go((\""},
        },
        .{
            .names = &.{ "a", "x-show" },
            .source = "<p a/x-show=\"go((\"></p>",
            .values = &.{"\"go((\""},
        },
        .{
            .names = &.{ "a", "x-show" },
            .source = "<p a=\"1\"/x-show=\"go((\"></p>",
            .values = &.{ "\"1\"", "\"go((\"" },
        },
        .{
            .names = &.{"x-show"},
            .source = "<p x-show/=\"go((\"></p>",
            .values = &.{},
        },
        .{
            .names = &.{"href"},
            .source = "<a href=/path/>y</a>",
            .values = &.{"/path/"},
        },
        .{
            .names = &.{"a"},
            .source = "<p a=/>z</p>",
            .values = &.{"/"},
        },
        .{
            .names = &.{"a"},
            .source = "<p a= />z</p>",
            .values = &.{"/"},
        },
        .{
            .names = &.{ "a", "b" },
            .source = "<p a/ b></p>",
            .values = &.{},
        },
        .{
            .names = &.{"src"},
            .source = "<img src=/a.png/>",
            .values = &.{"/a.png/"},
        },
    };

    for (cases) |case| try unquoted_expect(&case);
}

const Unquoted = struct {
    names: []const []const u8,
    source: []const u8,
    values: []const []const u8,
};

fn unquoted_expect(case: *const Unquoted) !void {
    const gpa = std.testing.allocator;

    const raw_text_tags = [_]RawTextTag{
        .{ .body = .text, .end = "endcomment", .name = "comment", .stage = .parser },
    };

    var tokens: Tokens = try .init(gpa, 1 << 7);
    defer tokens.deinit(gpa);

    var tree: Tree = try .init(gpa, 1 << 7, 1 << 4);
    defer tree.deinit(gpa);

    try lexer.lex_dialect(case.source, &tokens, &raw_text_tags, .django);

    const outcome = build_dialect(case.source, tokens.slice(), &tree, .django);
    var name_count: u32 = 0;
    var value_count: u32 = 0;

    for (tokens.slice()) |held| {
        if (held.kind != .attribute_name) continue;

        try std.testing.expect(name_count < case.names.len);
        try std.testing.expectEqualStrings(case.names[name_count], held.text(case.source));

        name_count += 1;
    }

    for (tree.slice()) |node| {
        if (node.kind != .attribute_value) continue;

        const span = node.span(Token, tokens.slice());

        try std.testing.expect(value_count < case.values.len);
        try std.testing.expectEqualStrings(case.values[value_count], span.text(case.source));

        value_count += 1;
    }

    try std.testing.expectEqual(Structure.complete, outcome);
    try std.testing.expectEqual(0, tree.diagnostic_slice().len);
    try std.testing.expectEqual(case.names.len, name_count);
    try std.testing.expectEqual(case.values.len, value_count);
}

test "a Django close tag runs on past a self-closing solidus to its angle" {
    const gpa = std.testing.allocator;
    const source = "<b></b/>x<i>";
    var tokens: Tokens = try .init(gpa, 1 << 6);
    defer tokens.deinit(gpa);

    var tree: Tree = try .init(gpa, 1 << 6, 1 << 4);
    defer tree.deinit(gpa);

    try lexer.lex_dialect(source, &tokens, &.{}, .django);

    const outcome = build_dialect(source, tokens.slice(), &tree, .django);
    var close_tag: ?u32 = null;

    for (tree.slice(), 0..) |node, index| {
        if (node.kind == .close_tag) close_tag = @intCast(index);
    }

    const span = tree.at(close_tag.?).span(Token, tokens.slice());

    try std.testing.expectEqual(Structure.complete, outcome);
    try std.testing.expectEqualStrings("</b/>x<i>", span.text(source));
}

const Rendered = struct {
    constructs: []const [2]u32,
    elements: []const u8,
    source: []const u8,
};

fn rendered_expect(case: *const Rendered) !void {
    const gpa = std.testing.allocator;

    const raw_text_tags = [_]RawTextTag{
        .{ .body = .text, .end = "endcomment", .name = "comment", .stage = .parser },
        .{ .body = .markup, .end = "endverbatim", .name = "verbatim", .stage = .lexer },
    };

    var tokens: Tokens = try .init(gpa, 1 << 7);
    defer tokens.deinit(gpa);

    var tree: Tree = try .init(gpa, 1 << 7, 1 << 4);
    defer tree.deinit(gpa);

    try lexer.lex_dialect(case.source, &tokens, &raw_text_tags, .django);

    _ = build_dialect(case.source, tokens.slice(), &tree, .django);

    var buffer: [1 << 8]u8 = undefined;
    var elements: std.Io.Writer = .fixed(&buffer);
    var construct_count: u32 = 0;

    for (tree.slice()) |node| {
        switch (node.kind) {
            .attribute => {
                const name = tokens.slice()[node.token_start];

                try std.testing.expectEqual(Kind.attribute_name, name.kind);
                try elements.print(" {s}", .{name.text(case.source)});
            },
            .element => {
                const name = element_named(node, tokens.slice(), case.source);

                if (elements.buffered().len > 0) try elements.writeByte(';');

                try elements.writeAll(name);
            },
            .template_comment, .template_tag, .template_variable => {
                const span = node.span(Token, tokens.slice());

                try std.testing.expect(construct_count < case.constructs.len);
                try std.testing.expectEqual(case.constructs[construct_count][0], span.offset);
                try std.testing.expectEqual(case.constructs[construct_count][1], span.end());

                construct_count += 1;
            },
            else => {},
        }
    }

    try std.testing.expectEqual(case.constructs.len, construct_count);
    try std.testing.expectEqualStrings(case.elements, elements.buffered());
}

test "a Django markup body lexes as the markup Django renders from it" {
    const cases = [_]Rendered{
        .{
            .constructs = &.{ .{ 0, 14 }, .{ 46, 63 }, .{ 63, 70 } },
            .elements = "a href",
            .source = "{% verbatim %}<a href=\"{{ x }}\">{% if y %}</a>{% endverbatim %}{{ z }}",
        },
        .{
            .constructs = &.{ .{ 8, 22 }, .{ 42, 59 } },
            .elements = "script",
            .source = "<script>{% verbatim %}var a = \"</script>\";{% endverbatim %}</script>",
        },
        .{
            .constructs = &.{ .{ 0, 14 }, .{ 24, 41 }, .{ 41, 48 } },
            .elements = "b",
            .source = "{% verbatim %}{# c #}<b>{% endverbatim %}{# d #}",
        },
        .{
            .constructs = &.{ .{ 0, 16 }, .{ 40, 59 } },
            .elements = "u;i",
            .source = "{% verbatim x %}<u>{% endverbatim %}</u>{% endverbatim x %}<i>",
        },
        .{
            .constructs = &.{ .{ 5, 19 }, .{ 30, 47 } },
            .elements = "div x-data",
            .source = "<div {% verbatim %}x-data=\"{}\"{% endverbatim %}>",
        },
        .{
            .constructs = &.{ .{ 10, 24 }, .{ 31, 48 } },
            .elements = "p title",
            .source = "<p title=\"{% verbatim %}{{ a }}{% endverbatim %}\">",
        },
        .{
            .constructs = &.{ .{ 5, 19 }, .{ 27, 44 } },
            .elements = "em",
            .source = "<!-- {% verbatim %} --><em>{% endverbatim %}",
        },
        .{
            .constructs = &.{ .{ 0, 14 }, .{ 24, 41 } },
            .elements = "textarea",
            .source = "{% verbatim %}<textarea>{% endverbatim %}</textarea>",
        },
        .{
            .constructs = &.{ .{ 0, 14 }, .{ 14, 31 } },
            .elements = "s",
            .source = "{% verbatim %}{% endverbatim %}<s>",
        },
    };

    for (&cases) |*case| try rendered_expect(case);
}
