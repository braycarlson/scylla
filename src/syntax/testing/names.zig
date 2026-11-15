const std = @import("std");
const assert = std.debug.assert;
const camel_of = @import("../category.zig").camel_of;
const css = @import("../css/kind.zig");
const go = @import("../go/kind.zig");
const javascript = @import("../javascript/kind.zig");
const markup = @import("../markup/kind.zig");
const odin = @import("../odin/kind.zig");
const python = @import("../python/kind.zig");
const rust = @import("../rust/kind.zig");
const zig = @import("../zig/kind.zig");

const Naming = struct {
    nodes_camel: bool,
    node_suffix_stripped: bool,
    renamed: []const Renamed,
};

const Renamed = struct {
    name: []const u8,
    tag: []const u8,
};

const node_suffix = "_node";

const naming_css: Naming = .{
    .nodes_camel = false,
    .node_suffix_stripped = false,
    .renamed = &.{
        .{ .name = "comment", .tag = "comment_node" },
        .{ .name = "identifier", .tag = "identifier_node" },
        .{ .name = "js_comment", .tag = "javascript_comment" },
        .{ .name = "unit", .tag = "unit_node" },
    },
};

const naming_go: Naming = .{
    .nodes_camel = true,
    .node_suffix_stripped = false,
    .renamed = &.{},
};

const naming_javascript: Naming = .{
    .nodes_camel = false,
    .node_suffix_stripped = true,
    .renamed = &.{},
};

const naming_markup: Naming = .{
    .nodes_camel = true,
    .node_suffix_stripped = false,
    .renamed = &.{
        .{ .name = "HTMLComment", .tag = "html_comment" },
        .{ .name = "HTMLCommentClose", .tag = "html_comment_close" },
        .{ .name = "HTMLCommentOpen", .tag = "html_comment_open" },
    },
};

const naming_odin: Naming = .{
    .nodes_camel = false,
    .node_suffix_stripped = false,
    .renamed = &.{
        .{ .name = "character", .tag = "character_node" },
        .{ .name = "comment", .tag = "comment_node" },
        .{ .name = "float", .tag = "float_node" },
        .{ .name = "identifier", .tag = "identifier_node" },
        .{ .name = "number", .tag = "number_node" },
    },
};

const naming_python: Naming = .{
    .nodes_camel = true,
    .node_suffix_stripped = false,
    .renamed = &.{
        .{ .name = "Name", .tag = "name_node" },
    },
};

const naming_rust: Naming = .{
    .nodes_camel = true,
    .node_suffix_stripped = false,
    .renamed = &.{},
};

const naming_zig: Naming = .{
    .nodes_camel = false,
    .node_suffix_stripped = false,
    .renamed = &.{
        .{ .name = "bang_equal", .tag = "bang_equal_node" },
        .{ .name = "equal_equal", .tag = "equal_equal_node" },
        .{ .name = "identifier", .tag = "identifier_node" },
    },
};

pub fn name_of(comptime Kind: type, kind: Kind) []const u8 {
    assert(kind.is_token() or kind.is_node());

    const table = comptime table_of(Kind);
    const held = table[@backingInt(kind)];

    assert(held.len > 0);

    return held;
}

pub fn kind_of(comptime Kind: type, name: []const u8) ?Kind {
    const map = comptime map_of(Kind);

    assert(name.len > 0);

    const found = map.get(name) orelse return null;

    assert(std.mem.eql(u8, name_of(Kind, found), name));

    return found;
}

fn naming_of(comptime Kind: type) Naming {
    if (Kind == css.Kind) return naming_css;
    if (Kind == go.Kind) return naming_go;
    if (Kind == javascript.Kind) return naming_javascript;
    if (Kind == markup.Kind) return naming_markup;
    if (Kind == odin.Kind) return naming_odin;
    if (Kind == python.Kind) return naming_python;
    if (Kind == rust.Kind) return naming_rust;
    if (Kind == zig.Kind) return naming_zig;

    @compileError("no oracle naming for " ++ @typeName(Kind));
}

fn table_of(comptime Kind: type) [@typeInfo(Kind).@"enum".field_names.len][]const u8 {
    const naming = naming_of(Kind);
    const count = @typeInfo(Kind).@"enum".field_names.len;
    var held: [count][]const u8 = undefined;

    @setEvalBranchQuota(1_000_000);

    for (std.enums.values(Kind), 0..) |kind, index| {
        held[index] = default_name_of(Kind, naming, kind);
    }

    for (naming.renamed) |renamed| {
        assert(@hasField(Kind, renamed.tag));
        assert(!std.mem.eql(u8, renamed.name, renamed.tag));

        held[@backingInt(@field(Kind, renamed.tag))] = renamed.name;
    }

    for (held, 0..) |name, index| {
        for (held[0..index]) |earlier| assert(!std.mem.eql(u8, name, earlier));
    }

    return held;
}

fn default_name_of(comptime Kind: type, comptime naming: Naming, comptime kind: Kind) []const u8 {
    comptime assert(kind.is_token() or kind.is_node());
    assert(naming.renamed.len <= std.math.maxInt(u32));

    const tag = @tagName(kind);
    if (naming.nodes_camel) return camel_of(tag);
    if (kind.is_token()) return camel_of(tag);
    if (!naming.node_suffix_stripped) return tag;
    if (kind == .error_node) return tag;
    if (!std.mem.endsWith(u8, tag, node_suffix)) return tag;

    assert(tag.len > node_suffix.len);

    return tag[0 .. tag.len - node_suffix.len];
}

fn kinds_of(comptime Kind: type) []const Kind {
    @setEvalBranchQuota(1_000_000);

    const held = std.enums.values(Kind);

    assert(held.len == @typeInfo(Kind).@"enum".field_names.len);

    return held;
}

fn map_of(comptime Kind: type) std.StaticStringMap(Kind) {
    const table = table_of(Kind);
    var pairs: [table.len]struct { []const u8, Kind } = undefined;

    @setEvalBranchQuota(1_000_000);

    for (table, std.enums.values(Kind), &pairs) |name, kind, *pair| pair.* = .{ name, kind };

    return .initComptime(pairs);
}

test "every oracle name maps back to its kind" {
    inline for (.{ css.Kind, go.Kind, javascript.Kind, markup.Kind }) |Kind| {
        for (comptime kinds_of(Kind)) |kind| {
            try std.testing.expectEqual(kind, kind_of(Kind, name_of(Kind, kind)).?);
        }
    }

    inline for (.{ odin.Kind, python.Kind, rust.Kind, zig.Kind }) |Kind| {
        for (comptime kinds_of(Kind)) |kind| {
            try std.testing.expectEqual(kind, kind_of(Kind, name_of(Kind, kind)).?);
        }
    }
}

test "the oracle names follow each oracle's spelling" {
    try std.testing.expectEqualStrings("Ident", name_of(go.Kind, .ident));
    try std.testing.expectEqualStrings("IncDecStmt", name_of(go.Kind, .inc_dec_stmt));
    try std.testing.expectEqualStrings("Identifier", name_of(javascript.Kind, .identifier));
    try std.testing.expectEqualStrings("identifier", name_of(javascript.Kind, .identifier_node));
    try std.testing.expectEqualStrings("error_node", name_of(javascript.Kind, .error_node));
    try std.testing.expectEqualStrings("HTMLComment", name_of(markup.Kind, .html_comment));
    try std.testing.expectEqualStrings("AutoCastKeyword", name_of(odin.Kind, .auto_cast_keyword));
    try std.testing.expectEqualStrings("character", name_of(odin.Kind, .character_node));
    try std.testing.expectEqualStrings("struct", name_of(odin.Kind, .@"struct"));
    try std.testing.expectEqualStrings("Name", name_of(python.Kind, .name_node));

    try std.testing.expectEqualStrings(
        "LessLessPipeEqual",
        name_of(zig.Kind, .less_less_pipe_equal),
    );

    try std.testing.expectEqualStrings("bang_equal", name_of(zig.Kind, .bang_equal_node));
    try std.testing.expectEqualStrings("js_comment", name_of(css.Kind, .javascript_comment));
    try std.testing.expectEqual(null, kind_of(zig.Kind, "no_such_kind"));
}
