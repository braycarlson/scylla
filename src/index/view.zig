const std = @import("std");
const assert = std.debug.assert;
const CssView = @import("../syntax/grammars.zig").css.ast.View;
const FileID = @import("../stdx/file_id.zig").FileID;
const MarkupTree = @import("../syntax/markup.zig").Document.Tree;
const MarkupView = @import("../syntax/markup.zig").View;
const Step = @import("../syntax/tree.zig").Step;
const Store = @import("store.zig");
const View = @import("../syntax/view.zig").View;
const generic = @import("../syntax/tree.zig");

pub const Node = struct {
    file: FileID,
    index: u32,

    pub fn init(file: FileID, index: u32) Node {
        assert(index != std.math.maxInt(u32));
        assert(file.index() != std.math.maxInt(u32));

        return .{ .file = file, .index = index };
    }
};

pub const Walk = struct {
    inner: Inner,

    const Inner = union(enum) {
        empty,
        go: ViewWalkType("go"),
        javascript: ViewWalkType("javascript"),
        markup: generic.WalkType(MarkupTree),
        odin: ViewWalkType("odin"),
        python: ViewWalkType("python"),
        rust: ViewWalkType("rust"),
        zig: ViewWalkType("zig"),
    };

    pub fn next(walk_state: *Walk) ?Step {
        switch (walk_state.inner) {
            .empty => return null,
            inline else => |*held| return held.next(),
        }
    }
};

fn ViewWalkType(comptime name: []const u8) type {
    assert(name.len <= std.math.maxInt(u32));

    const Inner = @FieldType(View, name);
    const Tree = @typeInfo(@FieldType(Inner, "tree")).pointer.child;

    return generic.WalkType(Tree);
}

pub fn ViewType(comptime name: []const u8) type {
    assert(name.len <= std.math.maxInt(u32));

    return @FieldType(View, name);
}

pub fn view_of(store: *const Store, file: FileID, node: u32) ?View {
    assert(@backingInt(file) != std.math.maxInt(u32));

    const front = store.front_of(file);
    if (node >= front.node_count()) return null;

    const held = front.view(node) orelse return null;

    assert(held.index() == node);

    return held;
}

pub fn css(store: *const Store, file: FileID, node: u32) ?CssView {
    assert(@backingInt(file) != std.math.maxInt(u32));

    const held = store.front_of(file);

    const tables = switch (held.tables) {
        .css => |*tables| tables,
        else => return null,
    };

    const syntax = &tables.syntax;
    if (node >= syntax.tree.count()) return null;

    assert(syntax.tokens.count() == syntax.raw.count());

    return .init(&syntax.tree, syntax.tokens.slice(), syntax.raw.const_slice(), node);
}

pub fn go(store: *const Store, file: FileID, node: u32) ?ViewType("go") {
    assert(node < std.math.maxInt(u32));
    assert(@backingInt(file) != std.math.maxInt(u32));

    return language_view(store, file, node, "go");
}

pub fn javascript(store: *const Store, file: FileID, node: u32) ?ViewType("javascript") {
    assert(node < std.math.maxInt(u32));
    assert(@backingInt(file) != std.math.maxInt(u32));

    return language_view(store, file, node, "javascript");
}

pub fn markup(store: *const Store, file: FileID, node: u32) ?MarkupView {
    assert(@backingInt(file) != std.math.maxInt(u32));

    const held = store.front_of(file).markup() orelse return null;
    if (node >= held.node_count()) return null;
    return held.at(node);
}

pub fn odin(store: *const Store, file: FileID, node: u32) ?ViewType("odin") {
    assert(node < std.math.maxInt(u32));
    assert(@backingInt(file) != std.math.maxInt(u32));

    return language_view(store, file, node, "odin");
}

pub fn python(store: *const Store, file: FileID, node: u32) ?ViewType("python") {
    assert(node < std.math.maxInt(u32));
    assert(@backingInt(file) != std.math.maxInt(u32));

    return language_view(store, file, node, "python");
}

pub fn rust(store: *const Store, file: FileID, node: u32) ?ViewType("rust") {
    assert(node < std.math.maxInt(u32));
    assert(@backingInt(file) != std.math.maxInt(u32));

    return language_view(store, file, node, "rust");
}

pub fn zig(store: *const Store, file: FileID, node: u32) ?ViewType("zig") {
    assert(node < std.math.maxInt(u32));
    assert(@backingInt(file) != std.math.maxInt(u32));

    return language_view(store, file, node, "zig");
}

fn language_view(
    store: *const Store,
    file: FileID,
    node: u32,
    comptime name: []const u8,
) ?ViewType(name) {
    comptime assert(@hasField(View, name));
    assert(node < std.math.maxInt(u32));
    assert(@backingInt(file) != std.math.maxInt(u32));

    const held = view_of(store, file, node) orelse return null;

    switch (held) {
        inline else => |inner, tag| {
            if (comptime !std.mem.eql(u8, @tagName(tag), name)) return null;

            assert(inner.node == node);

            return inner;
        },
    }
}

pub fn walk(store: *const Store, file: FileID) Walk {
    assert(@backingInt(file) != std.math.maxInt(u32));

    const front = store.front_of(file);

    if (front.markup()) |held| {
        return .{ .inner = .{ .markup = generic.walk(MarkupTree, held.tree()) } };
    }

    const root = front.root() orelse return .{ .inner = .empty };

    switch (root) {
        inline else => |inner, tag| {
            const Tree = @typeInfo(@TypeOf(inner.tree)).pointer.child;
            const held = generic.walk(Tree, inner.tree);

            return .{ .inner = @unionInit(Walk.Inner, @tagName(tag), held) };
        },
    }
}

pub fn walk_from(store: *const Store, file: FileID, node: u32) Walk {
    assert(node < std.math.maxInt(u32));
    assert(@backingInt(file) != std.math.maxInt(u32));

    const front = store.front_of(file);

    if (front.markup()) |held| {
        const tree = held.tree();
        return .{ .inner = .{ .markup = generic.walk_from(MarkupTree, tree, node) } };
    }

    const root = view_of(store, file, node) orelse return .{ .inner = .empty };

    switch (root) {
        inline else => |inner, tag| {
            const Tree = @typeInfo(@TypeOf(inner.tree)).pointer.child;
            const held = generic.walk_from(Tree, inner.tree, node);

            return .{ .inner = @unionInit(Walk.Inner, @tagName(tag), held) };
        },
    }
}
