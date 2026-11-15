const std = @import("std");
const assert = std.debug.assert;
const Fact = @import("../syntax/fact.zig").Fact;
const FileID = @import("../stdx/file_id.zig").FileID;
const Graph = @import("graph.zig");
const Node = @import("view.zig").Node;
const Store = @import("store.zig");

pub const Target = union(enum) {
    binding: Node,
    maybe,
    missing,
    unresolved,
};

const Forward = struct {
    fact: Fact,
    position: u32,
};

pub const chain_max: u32 = 16;

pub fn target_of(store: *const Store, graph: *const Graph, file: FileID, name: []const u8) Target {
    assert(name.len > 0);

    var current = file;
    var wanted = name;

    for (0..chain_max + 1) |_| {
        const forward = forward_of(store, current, wanted) orelse {
            return landing_of(store, current, wanted);
        };

        const target = edge_of(graph, current, forward.position) orelse return .unresolved;

        wanted = renamed_of(store, current, forward.fact, wanted);
        current = .of(target);
    }

    assert(wanted.len > 0);

    return .maybe;
}

fn forward_of(store: *const Store, file: FileID, name: []const u8) ?Forward {
    assert(name.len > 0);
    assert(@backingInt(file) != std.math.maxInt(u32));

    const position = store.forward_of(file, name) orelse return null;
    const fact = store.facts_of(file)[position];

    assert(fact.specifier_span() != null);
    assert(fact.local_span() != null);

    return .{ .fact = fact, .position = position };
}

fn renamed_of(store: *const Store, file: FileID, fact: Fact, wanted: []const u8) []const u8 {
    assert(wanted.len > 0);
    assert(@backingInt(file) != std.math.maxInt(u32));
    assert(fact.local.length <= std.math.maxInt(u32) - fact.local.offset);

    const remote = fact.remote_span() orelse return wanted;
    const renamed = remote.text(store.source_of(file));

    assert(renamed.len > 0);

    return renamed;
}

fn edge_of(graph: *const Graph, file: FileID, fact: u32) ?u32 {
    assert(@backingInt(file) != std.math.maxInt(u32));

    const edges = graph.edges_of(file);

    assert(edges.len <= graph.count());

    if (fact >= edges.len) return null;

    const edge = edges[fact];

    assert(edge.fact == fact);

    return edge.to;
}

fn landing_of(store: *const Store, file: FileID, name: []const u8) Target {
    assert(name.len > 0);
    assert(@backingInt(file) != std.math.maxInt(u32));

    if (store.declaration_of(file, name)) |node| {
        return .{ .binding = .init(file, node) };
    }

    if (stars(store, file)) return .maybe;
    return .missing;
}

fn stars(store: *const Store, file: FileID) bool {
    assert(@backingInt(file) != std.math.maxInt(u32));

    const facts = store.facts_of(file);

    assert(facts.len <= std.math.maxInt(u32));

    for (facts) |fact| {
        if (fact.local_span() != null) continue;

        switch (fact.kind) {
            .export_all, .import_namespace => return true,
            else => {},
        }
    }

    return false;
}
