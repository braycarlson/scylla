const std = @import("std");
const assert = std.debug.assert;
const ArrayType = @import("../stdx/bounded/array.zig").ArrayType;
const FileID = @import("../stdx/file_id.zig").FileID;
const Store = @import("store.zig");
const generic = @import("../stdx/graph.zig");
const hash_of = std.hash.Fnv1a_64.hash;
const Graph = @This();

counts: []u32,
cycle_members: ArrayType(FileID),
edges: ArrayType(Edge),
file_count_max: u32,
generations: []?u32,
lengths: ArrayType(u32),
moves: ?u64,
order_held: ArrayType(FileID),
scratch: generic.Scratch,
starts: []u32,

pub const Edge = struct {
    fact: u32,
    from: FileID,
    to: ?u32,

    pub fn resolved(edge: Edge) bool {
        if (edge.to) |target| assert(target != std.math.maxInt(u32));

        return edge.to != null;
    }
};

pub const Cycles = struct {
    cursor: u32,
    graph: *const Graph,
    offset: u32,

    pub fn next(iterator: *Cycles) ?[]const FileID {
        const lengths = iterator.graph.lengths.const_slice();

        assert(iterator.cursor <= lengths.len);

        if (iterator.cursor == lengths.len) return null;

        const start = iterator.offset;
        const end = start + lengths[iterator.cursor];

        assert(end <= iterator.graph.cycle_members.count());

        iterator.cursor += 1;
        iterator.offset = end;

        return iterator.graph.cycle_members.const_slice()[start..end];
    }
};

pub const Dependents = struct {
    cursor: u32,
    graph: *const Graph,
    target: u32,

    pub fn next(dependents: *Dependents) ?FileID {
        const edges = dependents.graph.edges.const_slice();

        assert(dependents.cursor <= edges.len);

        for (0..edges.len) |_| {
            if (dependents.cursor >= edges.len) return null;

            const position = dependents.cursor;
            const edge = edges[position];

            dependents.cursor += 1;

            if (edge.to != dependents.target) continue;
            if (dependents.repeated(position, edge)) continue;
            return edge.from;
        }

        return null;
    }

    fn repeated(dependents: *const Dependents, position: u32, edge: Edge) bool {
        assert(edge.from.index() < dependents.graph.starts.len);

        const graph = dependents.graph;
        const start = graph.starts[edge.from.index()];

        assert(start <= position);

        for (graph.edges.const_slice()[start..position]) |held| {
            if (held.to != dependents.target) continue;
            if (held.from == edge.from) return true;
        }

        return false;
    }
};

const Ordering = struct {
    cycle_members: *ArrayType(FileID),
    lengths: *ArrayType(u32),
    order: *ArrayType(FileID),

    pub fn component(
        ordering: *Ordering,
        members: []const u32,
        looping: bool,
    ) error{Truncated}!void {
        assert(members.len > 0);

        const first = ordering.order.count();

        if (ordering.order.unused_capacity() < members.len) return error.Truncated;

        for (0..members.len) |offset| {
            ordering.order.push(.of(members[members.len - 1 - offset]));
        }

        std.mem.sortUnstable(FileID, ordering.order.slice()[first..], {}, file_less);

        if (!looping) return;
        if (ordering.cycle_members.unused_capacity() < members.len) return error.Truncated;
        if (ordering.lengths.full()) return error.Truncated;

        ordering.cycle_members.push_slice(ordering.order.const_slice()[first..]);
        ordering.lengths.push(@intCast(members.len));
    }
};

const Topology = struct {
    counts: []const u32,
    edges: []const Edge,
    starts: []const u32,
    store: *const Store,

    pub fn edge_count_of(topology: *const Topology, node: u32) u32 {
        assert(node < topology.counts.len);
        assert(topology.counts.len == topology.starts.len);

        return topology.counts[node];
    }

    pub fn edge_target_of(topology: *const Topology, node: u32, ordinal: u32) ?u32 {
        assert(ordinal < topology.counts[node]);

        const edge = topology.edges[topology.starts[node] + ordinal];

        assert(edge.from.index() == node);

        return edge.to;
    }

    pub fn holds(topology: *const Topology, node: u32) bool {
        assert(node < topology.counts.len);

        return topology.store.resident(.of(node));
    }
};

pub const depth_max: u32 = 1 << 16;

pub fn init(
    gpa: std.mem.Allocator,
    edge_count_max: u32,
    file_count_max: u32,
) error{OutOfMemory}!Graph {
    assert(edge_count_max > 0);
    assert(file_count_max > 0);
    assert(file_count_max <= depth_max);

    const counts = try gpa.alloc(u32, file_count_max);
    errdefer gpa.free(counts);

    const generations = try gpa.alloc(?u32, file_count_max);
    errdefer gpa.free(generations);

    const starts = try gpa.alloc(u32, file_count_max);
    errdefer gpa.free(starts);

    var cycle_members: ArrayType(FileID) = try .init(gpa, file_count_max);
    errdefer cycle_members.deinit(gpa);

    var edges: ArrayType(Edge) = try .init(gpa, edge_count_max);
    errdefer edges.deinit(gpa);

    var lengths: ArrayType(u32) = try .init(gpa, file_count_max);
    errdefer lengths.deinit(gpa);

    var order_held: ArrayType(FileID) = try .init(gpa, file_count_max);
    errdefer order_held.deinit(gpa);

    var graph: Graph = .{
        .counts = counts,
        .cycle_members = cycle_members,
        .edges = edges,
        .file_count_max = file_count_max,
        .generations = generations,
        .lengths = lengths,
        .moves = null,
        .order_held = order_held,
        .scratch = try .init(gpa, file_count_max),
        .starts = starts,
    };

    graph.clear();

    assert(graph.counts.len == file_count_max);
    assert(graph.starts.len == file_count_max);

    return graph;
}

pub fn deinit(graph: *Graph, gpa: std.mem.Allocator) void {
    assert(graph.counts.len == graph.file_count_max);

    graph.scratch.deinit(gpa);
    graph.order_held.deinit(gpa);
    graph.lengths.deinit(gpa);
    graph.edges.deinit(gpa);
    graph.cycle_members.deinit(gpa);
    gpa.free(graph.starts);
    gpa.free(graph.generations);
    gpa.free(graph.counts);
    graph.* = undefined;
}

pub fn build(
    graph: *Graph,
    store: *const Store,
    comptime Resolver: type,
    resolver: *const Resolver,
) error{Truncated}!void {
    comptime assert(@hasDecl(Resolver, "resolve"));

    graph.clear();
    graph.moves = store.moves_count();

    var files = store.files();

    for (0..graph.file_count_max) |_| {
        const file = files.next() orelse break;

        graph.generations[file.index()] = store.generation_of(file);

        graph.edges_read(store, file, Resolver, resolver) catch |err| {
            graph.clear();

            return err;
        };
    }

    graph.order_read(store) catch |err| {
        graph.clear();

        return err;
    };

    assert(graph.order_held.count() <= graph.file_count_max);
}

pub fn clear(graph: *Graph) void {
    graph.moves = null;

    graph.cycle_members.clear();
    graph.edges.clear();
    graph.lengths.clear();
    graph.order_held.clear();

    @memset(graph.counts, 0);
    @memset(graph.generations, null);
    @memset(graph.starts, 0);

    assert(graph.edges.count() == 0);
    assert(graph.order_held.count() == 0);
}

pub fn count(graph: *const Graph) u32 {
    assert(graph.edges.count() <= graph.edges.capacity());

    return graph.edges.count();
}

pub fn current(graph: *const Graph, store: *const Store) bool {
    if (graph.moves == store.moves_count()) return true;

    for (graph.generations, 0..) |generation, index| {
        const held = generation orelse continue;
        const file: FileID = .of(@intCast(index));
        if (!store.resident(file)) return false;
        if (store.generation_of(file) != held) return false;
    }

    return true;
}

pub fn cycles(graph: *const Graph) Cycles {
    assert(graph.lengths.count() <= graph.cycle_members.count());

    return .{ .cursor = 0, .graph = graph, .offset = 0 };
}

pub fn dependents_of(graph: *const Graph, file: FileID) Dependents {
    assert(file.index() < graph.file_count_max);

    return .{ .cursor = 0, .graph = graph, .target = file.index() };
}

pub fn edges_of(graph: *const Graph, file: FileID) []const Edge {
    assert(@backingInt(file) != std.math.maxInt(u32));

    const index = file.index();

    assert(index < graph.file_count_max);

    const start = graph.starts[index];
    const end = start + graph.counts[index];

    assert(end <= graph.edges.count());

    return graph.edges.const_slice()[start..end];
}

pub fn generation_of(graph: *const Graph, file: FileID) ?u32 {
    assert(@backingInt(file) != std.math.maxInt(u32));

    const index = file.index();

    assert(index < graph.file_count_max);

    return graph.generations[index];
}

pub fn order(graph: *const Graph) []const FileID {
    assert(graph.order_held.count() <= graph.file_count_max);

    return graph.order_held.const_slice();
}

fn edges_read(
    graph: *Graph,
    store: *const Store,
    file: FileID,
    comptime Resolver: type,
    resolver: *const Resolver,
) error{Truncated}!void {
    assert(@backingInt(file) != std.math.maxInt(u32));

    const index = file.index();
    const start = graph.edges.count();
    const source = store.source_of(file);

    graph.starts[index] = start;

    for (store.facts_of(file), 0..) |fact, position| {
        const target: ?u32 = if (fact.specifier_span()) |specifier|
            resolver.resolve(specifier.text(source), file, store)
        else
            null;

        if (graph.edges.full()) return error.Truncated;

        graph.edges.push(.{ .fact = @intCast(position), .from = file, .to = target });
    }

    graph.counts[index] = graph.edges.count() - start;

    assert(graph.starts[index] + graph.counts[index] == graph.edges.count());
}

fn order_read(graph: *Graph, store: *const Store) error{Truncated}!void {
    const topology: Topology = .{
        .counts = graph.counts,
        .edges = graph.edges.const_slice(),
        .starts = graph.starts,
        .store = store,
    };

    var ordering: Ordering = .{
        .cycle_members = &graph.cycle_members,
        .lengths = &graph.lengths,
        .order = &graph.order_held,
    };

    try generic.components(
        Topology,
        Ordering,
        graph.file_count_max,
        &graph.scratch,
        &topology,
        &ordering,
    );
}

fn file_less(context: void, left: FileID, right: FileID) bool {
    _ = context;

    assert(@backingInt(left) != std.math.maxInt(u32));
    assert(@backingInt(right) != std.math.maxInt(u32));

    return left.index() < right.index();
}

const Language = @import("../syntax/language.zig").Language;

const SourceTest = struct {
    name: []const u8,
    source: []const u8,
};

const FindResolver = struct {
    pub fn resolve(
        resolver: *const FindResolver,
        specifier: []const u8,
        from: FileID,
        store: *const Store,
    ) ?u32 {
        _ = resolver;
        _ = from;
        assert(specifier.len <= std.math.maxInt(u32));

        return store.find(hash_of(specifier));
    }
};

fn limits_test(file_count_max: u32) Store.Limits {
    assert(file_count_max < std.math.maxInt(u32));

    var slots: [Language.count][Store.class_count]u32 = @splat(@splat(0));

    slots[@backingInt(Language.python)][Store.Limits.class_of(1_024)] = file_count_max;

    return .{
        .file_count_max = file_count_max,
        .front = .{
            .diagnostic_count_max = 32,
            .event_count_max = 2_048,
            .node_count_max = 1_024,
            .semantic = .{
                .binding_count_max = 128,
                .fact_count_max = 128,
                .reference_count_max = 128,
                .scope_count_max = 32,
            },
            .tag_count_max = 128,
            .token_count_max = 512,
        },
        .line_count_max = 128,
        .slots = slots,
        .source_bytes_max = 1_024,
    };
}

fn store_test(store: *Store, gpa: std.mem.Allocator, sources: []const SourceTest) !void {
    assert(sources.len <= std.math.maxInt(u32));

    const limits = limits_test(@intCast(sources.len));

    try store.init(gpa, &limits, .reject);
    errdefer store.deinit(gpa);

    for (sources) |held| _ = try store.insert(hash_of(held.name), .of(.python), held.source);
}

fn count_test(iterator: anytype) u32 {
    comptime assert(@typeInfo(@TypeOf(iterator)) == .pointer);

    var total: u32 = 0;

    for (0..depth_max) |_| {
        _ = iterator.next() orelse break;

        total += 1;
    }

    return total;
}

test "a linear chain orders dependencies first" {
    const gpa = std.testing.allocator;
    var store: Store = undefined;

    try store_test(&store, gpa, &.{
        .{ .name = "a", .source = "import b\n" },
        .{ .name = "b", .source = "import c\n" },
        .{ .name = "c", .source = "x = 1\n" },
    });

    defer store.deinit(gpa);

    var graph: Graph = try .init(gpa, 16, 3);
    defer graph.deinit(gpa);

    try graph.build(&store, FindResolver, &.{});
    try std.testing.expectEqual(2, graph.count());

    const found = graph.order();

    try std.testing.expectEqual(3, found.len);
    try std.testing.expectEqualStrings("x = 1\n", store.source_of(found[0]));
    try std.testing.expectEqualStrings("import c\n", store.source_of(found[1]));
    try std.testing.expectEqualStrings("import b\n", store.source_of(found[2]));

    var cycles_found = graph.cycles();

    try std.testing.expectEqual(0, count_test(&cycles_found));
}

test "a diamond orders the shared dependency first" {
    const gpa = std.testing.allocator;
    var store: Store = undefined;

    try store_test(&store, gpa, &.{
        .{ .name = "a", .source = "import b\nimport c\n" },
        .{ .name = "b", .source = "import d\n" },
        .{ .name = "c", .source = "import d\n" },
        .{ .name = "d", .source = "x = 1\n" },
    });

    defer store.deinit(gpa);

    var graph: Graph = try .init(gpa, 16, 4);
    defer graph.deinit(gpa);

    try graph.build(&store, FindResolver, &.{});
    try std.testing.expectEqual(4, graph.count());

    const found = graph.order();

    try std.testing.expectEqual(4, found.len);
    try std.testing.expectEqualStrings("x = 1\n", store.source_of(found[0]));
    try std.testing.expectEqualStrings("import b\nimport c\n", store.source_of(found[3]));

    var cycles_found = graph.cycles();
    var shared = graph.dependents_of(.of(3));
    var head = graph.dependents_of(.of(0));

    try std.testing.expectEqual(0, count_test(&cycles_found));
    try std.testing.expectEqual(2, count_test(&shared));
    try std.testing.expectEqual(0, count_test(&head));
}

test "a two file cycle is one component" {
    const gpa = std.testing.allocator;
    var store: Store = undefined;

    try store_test(&store, gpa, &.{
        .{ .name = "a", .source = "import b\n" },
        .{ .name = "b", .source = "import a\n" },
    });

    defer store.deinit(gpa);

    var graph: Graph = try .init(gpa, 16, 2);
    defer graph.deinit(gpa);

    try graph.build(&store, FindResolver, &.{});

    var cycles_found = graph.cycles();
    const cycle = cycles_found.next().?;
    const extra = cycles_found.next();

    try std.testing.expectEqual(null, extra);
    try std.testing.expectEqualSlices(FileID, &.{ .of(0), .of(1) }, cycle);
    try std.testing.expectEqual(2, graph.order().len);
}

test "a self import is a cycle of one" {
    const gpa = std.testing.allocator;
    var store: Store = undefined;

    try store_test(&store, gpa, &.{
        .{ .name = "a", .source = "import a\n" },
        .{ .name = "b", .source = "x = 1\n" },
    });

    defer store.deinit(gpa);

    var graph: Graph = try .init(gpa, 16, 2);
    defer graph.deinit(gpa);

    try graph.build(&store, FindResolver, &.{});

    var cycles_found = graph.cycles();
    const cycle = cycles_found.next().?;
    const extra = cycles_found.next();

    try std.testing.expectEqual(null, extra);
    try std.testing.expectEqualSlices(FileID, &.{.of(0)}, cycle);
}

test "an unresolved specifier keeps its edge" {
    const gpa = std.testing.allocator;
    var store: Store = undefined;

    try store_test(&store, gpa, &.{.{ .name = "a", .source = "import missing\n" }});
    defer store.deinit(gpa);

    var graph: Graph = try .init(gpa, 16, 1);
    defer graph.deinit(gpa);

    try graph.build(&store, FindResolver, &.{});

    const edges = graph.edges_of(.of(0));

    try std.testing.expectEqual(1, edges.len);
    try std.testing.expect(!edges[0].resolved());
    try std.testing.expectEqual(null, edges[0].to);
    try std.testing.expectEqual(FileID.of(0), edges[0].from);
    try std.testing.expectEqual(1, graph.order().len);
}

const CountingResolver = struct {
    asked: *u32,

    pub fn resolve(
        resolver: *const CountingResolver,
        specifier: []const u8,
        from: FileID,
        store: *const Store,
    ) ?u32 {
        _ = from;

        resolver.asked.* += 1;

        assert(specifier.len > 0);

        return store.find(hash_of(specifier));
    }
};

test "an empty specifier is an unresolved edge that is not resolved" {
    const gpa = std.testing.allocator;
    var store: Store = undefined;

    try store_test(&store, gpa, &.{
        .{ .name = "a", .source = "__all__ = [\"x\"]\nimport b\n" },
        .{ .name = "b", .source = "y = 1\n" },
    });

    defer store.deinit(gpa);

    var graph: Graph = try .init(gpa, 16, 2);
    defer graph.deinit(gpa);

    var asked: u32 = 0;

    try graph.build(&store, CountingResolver, &.{ .asked = &asked });
    try std.testing.expectEqual(1, asked);

    const edges = graph.edges_of(.of(0));

    try std.testing.expectEqual(2, edges.len);
    try std.testing.expectEqual(0, edges[0].fact);
    try std.testing.expect(!edges[0].resolved());
    try std.testing.expectEqual(null, edges[0].to);
    try std.testing.expect(edges[1].resolved());
    try std.testing.expectEqual(1, edges[1].to.?);

    var dependents = graph.dependents_of(.of(1));
    var cycles_found = graph.cycles();

    try std.testing.expectEqual(1, count_test(&dependents));
    try std.testing.expectEqualSlices(FileID, &.{ .of(1), .of(0) }, graph.order());
    try std.testing.expectEqual(0, count_test(&cycles_found));
}

test "a file nobody imports still reaches the order" {
    const gpa = std.testing.allocator;
    var store: Store = undefined;

    try store_test(&store, gpa, &.{
        .{ .name = "a", .source = "import b\n" },
        .{ .name = "b", .source = "x = 1\n" },
        .{ .name = "c", .source = "y = 2\n" },
    });

    defer store.deinit(gpa);

    var graph: Graph = try .init(gpa, 16, 3);
    defer graph.deinit(gpa);

    try graph.build(&store, FindResolver, &.{});

    var dependents = graph.dependents_of(.of(2));

    try std.testing.expectEqual(3, graph.order().len);
    try std.testing.expectEqual(0, graph.edges_of(.of(2)).len);
    try std.testing.expectEqual(0, count_test(&dependents));
}

test "an overflowing edge table clears the graph" {
    const gpa = std.testing.allocator;
    var store: Store = undefined;

    try store_test(&store, gpa, &.{
        .{ .name = "a", .source = "import b\nimport c\n" },
        .{ .name = "b", .source = "x = 1\n" },
        .{ .name = "c", .source = "y = 2\n" },
    });

    defer store.deinit(gpa);

    var graph: Graph = try .init(gpa, 1, 3);
    defer graph.deinit(gpa);

    try std.testing.expectError(error.Truncated, graph.build(&store, FindResolver, &.{}));
    try std.testing.expectEqual(0, graph.count());
    try std.testing.expectEqual(0, graph.order().len);

    var cycles_found = graph.cycles();

    try std.testing.expectEqual(0, count_test(&cycles_found));
    try std.testing.expectEqual(0, graph.edges_of(.of(0)).len);
}

const NamedResolver = struct {
    names: []const SourceIndexTest,

    pub fn resolve(
        resolver: *const NamedResolver,
        specifier: []const u8,
        from: FileID,
        store: *const Store,
    ) ?u32 {
        _ = from;
        _ = store;
        assert(specifier.len <= std.math.maxInt(u32));

        for (resolver.names) |held| {
            if (std.mem.eql(u8, held.name, specifier)) return held.index;
        }

        return null;
    }
};

const SourceIndexTest = struct {
    index: u32,
    name: []const u8,
};

test "a resolver that captures a name table outside the store resolves" {
    const gpa = std.testing.allocator;
    var store: Store = undefined;

    try store_test(&store, gpa, &.{
        .{ .name = "a", .source = "import base\n" },
        .{ .name = "b", .source = "import shared\n" },
        .{ .name = "c", .source = "x = 1\n" },
    });

    defer store.deinit(gpa);

    const names = [_]SourceIndexTest{
        .{ .index = 2, .name = "base" },
        .{ .index = 2, .name = "shared" },
    };

    var graph: Graph = try .init(gpa, 16, 3);
    defer graph.deinit(gpa);

    try graph.build(&store, NamedResolver, &.{ .names = &names });
    try std.testing.expectEqual(2, graph.count());
    try std.testing.expect(graph.edges_of(.of(0))[0].resolved());
    try std.testing.expectEqual(2, graph.edges_of(.of(0))[0].to.?);
    try std.testing.expectEqual(2, graph.edges_of(.of(1))[0].to.?);

    var dependents = graph.dependents_of(.of(2));

    try std.testing.expectEqual(2, count_test(&dependents));
    try std.testing.expectEqual(2, names.len);
}
