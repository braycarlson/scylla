const std = @import("std");
const assert = std.debug.assert;
const ArrayType = @import("../stdx/bounded/array.zig").ArrayType;
const Category = @import("category.zig").Category;
const Span = @import("../stdx/bounded/span.zig");
const dump = @import("testing/dump.zig").dump;

pub const Structure = union(enum) {
    complete,
    too_deep,
    truncated: Resource,

    pub const Resource = enum {
        bindings,
        checks,
        diagnostics,
        events,
        facts,
        intermediates,
        lines,
        nodes,
        references,
        scopes,
        tags,
        tokens,
    };
};

pub const Step = union(enum) {
    enter: u32,
    leave: u32,
};

pub const Checkpoint = struct {
    index: u32,
};

pub const frame_depth_max: u32 = 1_024;
const sentinel: u32 = std.math.maxInt(u32);

pub fn TreeType(comptime Kind: type) type {
    comptime kind_check(Kind);

    return struct {
        diagnostics: ArrayType(Kind.Diagnostic),
        nodes: ArrayType(Node),

        const Tree = @This();
        pub const CapacityError = error{Truncated};
        pub const Diagnostic = Kind.Diagnostic;

        pub const Node = struct {
            child_first: u32,
            kind: Kind,
            parent: u32,
            sibling_next: u32,
            token_end: u32,
            token_start: u32,

            pub fn span(node: Node, comptime T: type, tokens: []const T) Span {
                comptime positioned_check(T);

                assert(node.token_start <= node.token_end);
                assert(node.token_end <= tokens.len);

                const offset = if (node.token_start < tokens.len)
                    tokens[node.token_start].offset
                else
                    end_of(T, tokens);

                assert(offset <= end_of(T, tokens));

                if (node.token_end <= node.token_start) return .{ .offset = offset, .length = 0 };

                const end = tokens[node.token_end - 1].end();

                assert(end >= offset);

                return .{ .offset = offset, .length = end - offset };
            }
        };

        pub fn init(
            gpa: std.mem.Allocator,
            node_count_max: u32,
            diagnostic_count_max: u32,
        ) std.mem.Allocator.Error!Tree {
            assert(node_count_max > 0);
            assert(diagnostic_count_max > 0);

            var diagnostics: ArrayType(Diagnostic) = try .init(gpa, diagnostic_count_max);
            errdefer diagnostics.deinit(gpa);

            const nodes: ArrayType(Node) = try .init(gpa, node_count_max);

            assert(diagnostics.capacity() == diagnostic_count_max);
            assert(nodes.capacity() == node_count_max);

            return .{ .diagnostics = diagnostics, .nodes = nodes };
        }

        pub fn deinit(tree: *Tree, gpa: std.mem.Allocator) void {
            assert(tree.nodes.capacity() > 0);
            assert(tree.diagnostics.capacity() > 0);

            tree.nodes.deinit(gpa);
            tree.diagnostics.deinit(gpa);
            tree.* = undefined;
        }

        fn ancestor_of(tree: *const Tree, node: u32, kind: Kind) ?u32 {
            assert(node < tree.count());
            assert(kind.is_node());

            var at_node = node;

            for (0..tree.count()) |_| {
                at_node = tree.parent_of(at_node) orelse return null;

                assert(at_node < node);

                if (tree.kind_at(at_node) == kind) return at_node;
            }

            return null;
        }

        pub fn at(tree: *const Tree, index: u32) Node {
            assert(index < tree.count());

            const node = tree.nodes.get(index);

            assert(node.kind.is_node());
            assert(node.token_start <= node.token_end);
            if (node.parent != sentinel) assert(node.parent < index);

            return node;
        }

        pub fn clear(tree: *Tree) void {
            tree.diagnostics.clear();
            tree.nodes.clear();

            assert(tree.count() == 0);
            assert(tree.nodes.capacity() > 0);
            assert(tree.diagnostics.empty());
        }

        pub fn count(tree: *const Tree) u32 {
            assert(tree.nodes.count() <= tree.nodes.capacity());

            return tree.nodes.count();
        }

        pub fn kind_at(tree: *const Tree, index: u32) Kind {
            assert(index < tree.count());

            const kind = tree.nodes.get(index).kind;

            assert(kind.is_node());

            return kind;
        }

        pub fn diagnostic_slice(tree: *const Tree) []const Diagnostic {
            assert(tree.diagnostics.count() <= tree.diagnostics.capacity());

            return tree.diagnostics.const_slice();
        }

        pub fn child_first_of(tree: *const Tree, node: u32) ?u32 {
            assert(node < tree.count());

            const child = link_of(tree.at(node).child_first);

            if (child) |held| assert(held > node);
            if (child) |held| assert(held < tree.count());

            return child;
        }

        pub fn innermost_at(
            tree: *const Tree,
            comptime T: type,
            tokens: []const T,
            offset: u32,
        ) ?u32 {
            assert(tokens.len <= std.math.maxInt(u32));

            var found: ?u32 = null;
            var narrowest: u32 = std.math.maxInt(u32);

            for (tree.nodes.const_slice(), 0..) |node, index| {
                const span = node.span(T, tokens);
                if (span.offset > offset) continue;
                if (offset > span.end()) continue;

                if (span.length < narrowest) {
                    found = @intCast(index);
                    narrowest = span.length;
                }
            }

            if (found) |index| assert(index < tree.count());
            if (found) |index| assert(tree.at(index).span(T, tokens).length == narrowest);
            if (found == null) assert(narrowest == std.math.maxInt(u32));

            return found;
        }

        pub fn sibling_next_of(tree: *const Tree, node: u32) ?u32 {
            assert(node < tree.count());

            const sibling = link_of(tree.at(node).sibling_next);

            if (sibling) |held| assert(held > node);
            if (sibling) |held| assert(held < tree.count());

            return sibling;
        }

        pub fn parent_of(tree: *const Tree, node: u32) ?u32 {
            assert(node < tree.count());

            const parent = link_of(tree.at(node).parent);

            if (parent) |held| assert(tree.at(held).child_first <= node);

            return parent;
        }

        pub fn push(tree: *Tree, kind: Kind, parent: ?u32, token_start: u32) CapacityError!void {
            assert(kind.is_node());
            assert(token_start != sentinel);
            if (parent) |held| assert(held < tree.count());

            if (tree.nodes.full()) return error.Truncated;

            tree.nodes.push(.{
                .child_first = sentinel,
                .kind = kind,
                .parent = parent orelse sentinel,
                .sibling_next = sentinel,
                .token_end = sentinel,
                .token_start = token_start,
            });
        }

        pub fn push_diagnostic(tree: *Tree, held: Diagnostic) CapacityError!void {
            const spanned = comptime @typeInfo(Diagnostic) == .@"struct";

            if (spanned) assert(held.span.length <= std.math.maxInt(u32) - held.span.offset);
            assert(tree.diagnostics.count() <= tree.diagnostics.capacity());
            assert(tree.diagnostics.capacity() > 0);

            if (tree.diagnostics.full()) return error.Truncated;

            tree.diagnostics.push(held);
        }

        pub fn set_child_first(tree: *Tree, node: u32, child: u32) void {
            assert(node < tree.count());
            assert(child != node);
            assert(child > node);
            assert(child < tree.count());
            assert(tree.at(node).child_first == sentinel);

            tree.nodes.slice()[node].child_first = child;
        }

        pub fn set_sibling_next(tree: *Tree, node: u32, sibling: u32) void {
            assert(node < tree.count());
            assert(sibling != node);
            assert(sibling > node);
            assert(sibling < tree.count());
            assert(tree.at(node).sibling_next == sentinel);

            tree.nodes.slice()[node].sibling_next = sibling;
        }

        pub fn set_token_end(tree: *Tree, node: u32, token_end: u32) void {
            assert(node < tree.count());
            assert(token_end >= tree.at(node).token_start);
            assert(token_end != sentinel);
            assert(tree.at(node).token_end == sentinel);

            tree.nodes.slice()[node].token_end = token_end;
        }

        pub fn slice(tree: *const Tree) []const Node {
            assert(tree.nodes.count() <= tree.nodes.capacity());

            return tree.nodes.const_slice();
        }

        pub fn verify(
            tree: *const Tree,
            comptime T: type,
            tokens: []const T,
            source: []const u8,
        ) void {
            assert(tokens.len <= std.math.maxInt(u32));
            assert(source.len <= std.math.maxInt(u32));

            const node_count = tree.count();

            for (tree.slice(), 0..) |node, index| {
                const held: u32 = @intCast(index);

                assert(node.token_start <= node.token_end);
                assert(node.token_end <= tokens.len);
                assert(node.span(T, tokens).end() <= source.len);

                if (tree.child_first_of(held)) |child| assert(child < node_count);
                if (tree.parent_of(held)) |parent| assert(parent < node_count);
                if (tree.sibling_next_of(held)) |sibling| assert(sibling < node_count);

                if (tree.parent_of(held)) |parent| {
                    const outer = tree.nodes.get(parent);

                    assert(outer.token_start <= node.token_start);
                    assert(node.token_end <= outer.token_end);
                }

                if (tree.sibling_next_of(held)) |sibling| {
                    assert(tree.parent_of(sibling) == tree.parent_of(held));
                    assert(node.token_end <= tree.nodes.get(sibling).token_start);
                }
            }

            var steps = walk(Tree, tree);
            var step_count: u32 = 0;

            for (0..steps.step_max) |_| {
                const step = steps.next() orelse break;

                switch (step) {
                    .enter, .leave => |entered| assert(entered < node_count),
                }

                step_count += 1;
            }

            assert(step_count == 2 * node_count);
        }
    };
}

pub fn EventsType(comptime Kind: type) type {
    comptime kind_check(Kind);

    return struct {
        chain: [frame_depth_max]?Kind,
        depth: u32,
        frames: [frame_depth_max]Frame,
        items: ArrayType(Event),
        open: [frame_depth_max]u32,
        outcome: Structure,

        const Events = @This();
        const Tree = TreeType(Kind);

        pub const Event = union(enum) {
            anchor: Anchor,
            finish,
            layout: u32,
            start: Start,
            token: u32,
            tombstone,
        };

        pub const Anchor = struct {
            forward_parent: u32,
        };

        pub const Start = struct {
            forward_parent: u32,
            kind: Kind,
        };

        const Frame = struct {
            child_last: u32,
            node: u32,
            token_start: u32,
        };

        const Replay = struct {
            attributed: u32,
            depth: u32,
            events: *Events,
            outcome: Structure,
            position: u32,
            tree: *Tree,

            fn run(replay_state: *Replay) Structure {
                assert(replay_state.tree.count() == 0);

                const event_count = replay_state.events.count();

                for (0..event_count) |index| {
                    switch (replay_state.events.items.get(@intCast(index))) {
                        .anchor => |anchor| replay_state.open_chain(null, anchor.forward_parent),
                        .finish => replay_state.close(),
                        .layout => |position| replay_state.skip(position),
                        .start => |held| replay_state.open_chain(held.kind, held.forward_parent),
                        .token => |position| replay_state.advance(position),
                        .tombstone => {},
                    }
                }

                while (replay_state.depth > 0) {
                    replay_state.close();
                }

                assert(replay_state.depth == 0);
                assert(replay_state.tree.count() <= event_count);

                return replay_state.outcome;
            }

            fn advance(replay_state: *Replay, position: u32) void {
                assert(position != sentinel);
                assert(position >= replay_state.position);
                assert(replay_state.attributed <= replay_state.position);

                replay_state.position = position + 1;
                replay_state.attributed = replay_state.position;
            }

            fn close(replay_state: *Replay) void {
                if (replay_state.depth == 0) return;

                replay_state.depth -= 1;

                const frame = replay_state.events.frames[replay_state.depth];
                if (frame.node == sentinel) return;

                const child_end = if (frame.child_last == sentinel)
                    frame.token_start
                else
                    replay_state.tree.at(frame.child_last).token_end;

                const token_end = @max(replay_state.attributed, frame.token_start, child_end);

                assert(token_end <= replay_state.position);
                assert(frame.node < replay_state.tree.count());

                replay_state.tree.set_token_end(frame.node, token_end);
            }

            fn link(replay_state: *Replay, index: u32) void {
                assert(replay_state.depth > 0);
                assert(index < replay_state.tree.count());

                const parent = &replay_state.events.frames[replay_state.depth - 1];

                assert(replay_state.tree.at(index).parent == parent.node);
                if (parent.child_last != sentinel) assert(parent.child_last < index);

                if (parent.child_last == sentinel) {
                    if (parent.node != sentinel) {
                        replay_state.tree.set_child_first(parent.node, index);
                    }
                } else {
                    replay_state.tree.set_sibling_next(parent.child_last, index);
                }

                parent.child_last = index;
            }

            fn open(replay_state: *Replay, kind: Kind) void {
                assert(kind.is_node());

                if (replay_state.depth >= frame_depth_max) {
                    replay_state.outcome = .too_deep;

                    return;
                }

                const depth = replay_state.depth;
                const frames = &replay_state.events.frames;
                const parent = if (depth == 0) null else link_of(frames[depth - 1].node);
                const index = replay_state.tree.count();

                if (parent) |held| assert(held < index);

                const pushed = replay_state.tree.push(kind, parent, replay_state.position);

                pushed catch |err| switch (err) {
                    error.Truncated => {
                        if (replay_state.outcome == .complete) {
                            replay_state.outcome = .{ .truncated = .nodes };
                        }

                        replay_state.frame_push(sentinel);

                        return;
                    },
                };

                if (depth > 0) replay_state.link(index);

                replay_state.frame_push(index);

                assert(replay_state.tree.count() == index + 1);
            }

            fn frame_push(replay_state: *Replay, node: u32) void {
                assert(replay_state.depth < frame_depth_max);
                if (node != sentinel) assert(node < replay_state.tree.count());

                replay_state.events.frames[replay_state.depth] = .{
                    .child_last = sentinel,
                    .node = node,
                    .token_start = replay_state.position,
                };

                replay_state.depth += 1;
            }

            fn open_chain(replay_state: *Replay, kind: ?Kind, forward_parent: u32) void {
                if (kind) |first| assert(first.is_node());
                const event_count = replay_state.events.count();

                if (forward_parent != sentinel) assert(forward_parent < event_count);

                const events = replay_state.events;
                var chained: u32 = 0;
                var next = forward_parent;

                for (0..events.count()) |_| {
                    if (next == sentinel) break;
                    if (chained >= frame_depth_max) break;

                    assert(next < events.count());

                    const event = events.items.get(next);

                    events.items.slice()[next] = .tombstone;

                    switch (event) {
                        .anchor => |anchor| next = anchor.forward_parent,
                        .start => |held| {
                            events.chain[chained] = held.kind;
                            chained += 1;
                            next = held.forward_parent;
                        },
                        .finish, .layout, .token, .tombstone => break,
                    }
                }

                assert(chained <= frame_depth_max);

                if (next != sentinel) replay_state.outcome = .too_deep;

                for (events.chain[0..chained]) |wrapper| {
                    replay_state.open(wrapper.?);
                }

                if (kind) |first| replay_state.open(first);
            }

            fn skip(replay_state: *Replay, position: u32) void {
                assert(position != sentinel);
                assert(position >= replay_state.position);
                assert(replay_state.attributed <= replay_state.position);

                replay_state.position = position + 1;
            }
        };

        pub fn init(events: *Events, gpa: std.mem.Allocator, event_count_max: u32) !void {
            assert(event_count_max > 0);

            events.* = .{
                .chain = @splat(null),
                .depth = 0,
                .frames = @splat(.{ .child_last = sentinel, .node = sentinel, .token_start = 0 }),
                .items = try .init(gpa, event_count_max),
                .open = @splat(sentinel),
                .outcome = .complete,
            };

            assert(events.count() == 0);
        }

        pub fn deinit(events: *Events, gpa: std.mem.Allocator) void {
            assert(events.depth <= frame_depth_max);
            assert(events.items.capacity() > 0);

            events.items.deinit(gpa);
            events.* = undefined;
        }

        fn abandon(events: *Events) void {
            assert(events.depth <= frame_depth_max);

            if (events.depth == 0) return;

            events.depth -= 1;

            const index = events.open[events.depth];
            if (index == sentinel) return;

            assert(index < events.count());
            assert(events.items.get(index) == .start);

            events.items.slice()[index] = .tombstone;
        }

        pub fn checkpoint(events: *Events) Checkpoint {
            const index = events.count();
            const recorded = events.record(.{ .anchor = .{ .forward_parent = sentinel } });

            if (recorded) |held| assert(held == index);

            assert(index <= events.count());

            return .{ .index = index };
        }

        pub fn clear(events: *Events) void {
            events.depth = 0;

            events.items.clear();
            events.outcome = .complete;

            assert(events.count() == 0);
            assert(events.items.capacity() > 0);
        }

        pub fn count(events: *const Events) u32 {
            assert(events.items.count() <= events.items.capacity());

            return events.items.count();
        }

        pub fn finish(events: *Events) void {
            assert(events.depth <= frame_depth_max);

            if (events.depth == 0) return;

            events.depth -= 1;

            if (events.open[events.depth] == sentinel) return;

            assert(events.open[events.depth] < events.count());

            _ = events.record(.finish);
        }

        pub fn layout(events: *Events, position: u32) void {
            assert(position != sentinel);
            assert(events.depth <= frame_depth_max);

            _ = events.record(.{ .layout = position });
        }

        pub fn replay(events: *Events, tree: *Tree) Structure {
            assert(tree.count() == 0);

            var machine: Replay = .{
                .attributed = 0,
                .depth = 0,
                .events = events,
                .outcome = events.outcome,
                .position = 0,
                .tree = tree,
            };

            const outcome = machine.run();

            assert(tree.count() <= events.count());
            if (outcome == .complete) assert(events.outcome == .complete);

            return outcome;
        }

        pub fn slice(events: *const Events) []const Event {
            assert(events.items.count() <= events.items.capacity());

            return events.items.const_slice();
        }

        pub fn start(events: *Events, kind: Kind) void {
            assert(kind.is_node());
            assert(events.depth <= frame_depth_max);

            const recorded = events.record(.{
                .start = .{ .forward_parent = sentinel, .kind = kind },
            });

            if (recorded) |index| assert(index < events.count());

            events.frame_open(recorded);
        }

        pub fn start_at(events: *Events, held: Checkpoint, kind: Kind) void {
            assert(kind.is_node());
            assert(held.index <= events.count());

            const recorded = events.record(.{
                .start = .{ .forward_parent = sentinel, .kind = kind },
            });

            if (recorded) |index| events.chain_link(held.index, index);

            events.frame_open(recorded);
        }

        pub fn retag(events: *Events, held: Checkpoint, from: Kind, to: Kind) bool {
            assert(held.index < events.count());
            assert(from.is_node());
            assert(to.is_node());

            const items = events.items.slice();

            var next = switch (items[held.index]) {
                .anchor => |anchor| anchor.forward_parent,
                else => return false,
            };

            for (0..frame_depth_max) |_| {
                if (next == sentinel) return false;

                assert(next < events.count());
                assert(next > held.index);

                switch (items[next]) {
                    .start => |*opened| {
                        if (opened.kind == from) {
                            opened.kind = to;

                            return true;
                        }

                        next = opened.forward_parent;
                    },
                    else => return false,
                }
            }

            return false;
        }

        pub fn outermost(events: *const Events, held: Checkpoint) ?Kind {
            assert(held.index < events.count());

            const items = events.items.const_slice();

            const next = switch (items[held.index]) {
                .anchor => |anchor| anchor.forward_parent,
                else => return null,
            };

            if (next == sentinel) return null;

            assert(next < events.count());
            assert(next > held.index);

            return switch (items[next]) {
                .start => |opened| opened.kind,
                else => null,
            };
        }

        pub fn started(events: *const Events, held: Checkpoint) ?Kind {
            assert(held.index <= events.count());

            const items = events.items.const_slice();
            const next = held.index + 1;
            if (next >= items.len) return null;

            const parented = switch (items[held.index]) {
                .anchor => |anchor| anchor.forward_parent != sentinel,
                else => true,
            };

            if (parented) return null;

            return switch (items[next]) {
                .start => |opened| opened.kind,
                else => null,
            };
        }

        pub fn token(events: *Events, position: u32) void {
            assert(position != sentinel);
            assert(events.depth <= frame_depth_max);

            _ = events.record(.{ .token = position });
        }

        fn chain_link(events: *Events, from: u32, to: u32) void {
            assert(from < to);
            assert(to < events.count());
            assert(events.items.get(to) == .start);

            const items = events.items.slice();

            const onward = switch (items[from]) {
                .anchor => |anchor| anchor.forward_parent,
                .start => |held| held.forward_parent,
                .finish, .layout, .token, .tombstone => return,
            };

            if (onward != sentinel) assert(onward < to);

            forward_parent_set(events, to, onward);
            forward_parent_set(events, from, to);
        }

        fn forward_parent_set(events: *Events, index: u32, value: u32) void {
            if (value != sentinel) assert(value < events.count());
            assert(index < events.count());

            const event = &events.items.slice()[index];

            switch (event.*) {
                .anchor => |*anchor| anchor.forward_parent = value,
                .start => |*held| held.forward_parent = value,
                .finish, .layout, .token, .tombstone => unreachable,
            }
        }

        fn frame_open(events: *Events, index: ?u32) void {
            if (index) |held| assert(held < events.count());
            if (index) |held| assert(events.items.get(held) == .start);

            if (events.depth >= frame_depth_max) {
                events.outcome = .too_deep;

                return;
            }

            events.open[events.depth] = index orelse sentinel;
            events.depth += 1;

            assert(events.depth <= frame_depth_max);
        }

        fn record(events: *Events, event: Event) ?u32 {
            assert(events.count() <= events.items.capacity());
            assert(event != .tombstone);

            if (events.items.full()) {
                if (events.outcome == .complete) events.outcome = .{ .truncated = .events };

                return null;
            }

            const index = events.count();

            events.items.push(event);

            assert(events.count() == index + 1);
            assert(index < events.items.capacity());

            return index;
        }
    };
}

pub fn WalkType(comptime Links: type) type {
    comptime links_check(Links);

    return struct {
        entering: bool,
        links: *const Links,
        node: ?u32,
        root: ?u32,
        scan: u32,
        step_max: u32,
        steps: u32,

        const Walk = @This();

        pub fn next(walk_state: *Walk) ?Step {
            const node = walk_state.node orelse return null;

            assert(node < walk_state.links.count());
            if (walk_state.root) |root| assert(node >= root);

            walk_state.steps += 1;

            assert(walk_state.steps <= walk_state.step_max);

            if (walk_state.entering) {
                if (walk_state.links.child_first_of(node)) |child| {
                    walk_state.node = child;
                } else {
                    walk_state.entering = false;
                }

                return .{ .enter = node };
            }

            walk_state.advance(node);

            return .{ .leave = node };
        }

        fn advance(walk_state: *Walk, node: u32) void {
            assert(node < walk_state.links.count());
            assert(!walk_state.entering);

            if (walk_state.root) |root| {
                if (node == root) {
                    walk_state.node = null;

                    return;
                }
            }

            const parent = walk_state.links.parent_of(node) orelse {
                walk_state.node = walk_state.root_next();
                walk_state.entering = walk_state.node != null;

                return;
            };

            if (walk_state.links.sibling_next_of(node)) |sibling| {
                walk_state.entering = true;
                walk_state.node = sibling;
            } else {
                walk_state.entering = false;
                walk_state.node = parent;
            }
        }

        fn root_next(walk_state: *Walk) ?u32 {
            const node_count = walk_state.links.count();

            assert(walk_state.root == null);

            for (0..node_count) |_| {
                if (walk_state.scan >= node_count) return null;

                const candidate = walk_state.scan;

                walk_state.scan += 1;

                if (walk_state.links.parent_of(candidate) == null) return candidate;
            }

            return null;
        }
    };
}

pub fn walk(comptime Links: type, links: *const Links) WalkType(Links) {
    const node_count = links.count();

    return .{
        .entering = node_count > 0,
        .links = links,
        .node = if (node_count > 0) 0 else null,
        .root = null,
        .scan = 1,
        .step_max = step_max_of(node_count),
        .steps = 0,
    };
}

pub fn walk_from(comptime Links: type, links: *const Links, node: u32) WalkType(Links) {
    const node_count = links.count();

    assert(node < node_count);

    return .{
        .entering = true,
        .links = links,
        .node = node,
        .root = node,
        .scan = node_count,
        .step_max = step_max_of(node_count),
        .steps = 0,
    };
}

pub fn IndexType(comptime Kind: type) type {
    comptime kind_check(Kind);

    return struct {
        positions: ArrayType(u32),
        starts: [Category.count + 1]u32,

        const Index = @This();
        const Tree = TreeType(Kind);

        pub fn init(gpa: std.mem.Allocator, node_count_max: u32) std.mem.Allocator.Error!Index {
            assert(node_count_max > 0);

            const positions: ArrayType(u32) = try .init(gpa, node_count_max);

            assert(positions.capacity() == node_count_max);

            return .{ .positions = positions, .starts = @splat(0) };
        }

        pub fn deinit(index: *Index, gpa: std.mem.Allocator) void {
            assert(index.positions.capacity() > 0);
            assert(index.count() <= index.positions.capacity());

            index.positions.deinit(gpa);
            index.* = undefined;
        }

        pub fn build(index: *Index, tree: *const Tree) void {
            assert(tree.count() <= index.positions.capacity());

            index.clear();

            var counts: [Category.count]u32 = @splat(0);

            for (tree.slice()) |node| {
                counts[node.kind.category().index()] += 1;
            }

            var running: u32 = 0;

            for (counts, 0..) |category_count, slot| {
                index.starts[slot] = running;
                running += category_count;
            }

            index.starts[Category.count] = running;

            assert(running == tree.count());
            assert(index.starts[0] == 0);

            for (0..tree.count()) |_| {
                index.positions.push(sentinel);
            }

            var cursors = index.starts;
            const positions = index.positions.slice();

            for (tree.slice(), 0..) |node, position| {
                const slot = node.kind.category().index();
                const target = cursors[slot];

                assert(target < index.starts[slot + 1]);
                assert(positions[target] == sentinel);

                positions[target] = @intCast(position);
                cursors[slot] = target + 1;
            }

            assert(index.count() == tree.count());
        }

        pub fn clear(index: *Index) void {
            index.positions.clear();
            index.starts = @splat(0);

            assert(index.count() == 0);
            assert(index.positions.capacity() > 0);
        }

        pub fn count(index: *const Index) u32 {
            assert(index.positions.count() <= index.positions.capacity());

            return index.positions.count();
        }

        pub fn of(index: *const Index, category: Category) []const u32 {
            const slot = category.index();
            const start = index.starts[slot];
            const end = index.starts[slot + 1];

            assert(slot < Category.count);
            assert(start <= end);
            assert(end <= index.positions.count());

            return index.positions.const_slice()[start..end];
        }
    };
}

fn end_of(comptime T: type, tokens: []const T) u32 {
    assert(tokens.len <= std.math.maxInt(u32));

    if (tokens.len == 0) return 0;
    const end = tokens[tokens.len - 1].end();

    assert(end >= tokens[0].offset);

    return end;
}

fn link_of(raw: u32) ?u32 {
    if (raw == sentinel) return null;
    return raw;
}

fn step_max_of(node_count: u32) u32 {
    assert(node_count <= (sentinel - 1) / 2);

    return 2 * node_count + 1;
}

fn kind_check(comptime Kind: type) void {
    assert(@hasDecl(Kind, "Diagnostic"));
    assert(@hasDecl(Kind, "category"));
    assert(@hasDecl(Kind, "is_node"));
    assert(@hasDecl(Kind, "is_token"));
    assert(@hasDecl(Kind, "name"));
}

fn links_check(comptime Links: type) void {
    assert(@hasDecl(Links, "count"));
    assert(@hasDecl(Links, "child_first_of"));
    assert(@hasDecl(Links, "sibling_next_of"));
    assert(@hasDecl(Links, "parent_of"));
}

pub fn positioned_check(comptime T: type) void {
    assert(@hasField(T, "offset"));
    assert(@hasDecl(T, "end"));
}

const TestKind = enum {
    attribute,
    bin_op,
    @"error",
    name_node,
    word,

    pub const Diagnostic = u32;

    pub fn category(kind: TestKind) Category {
        assert(kind.is_node() != kind.is_token());

        return switch (kind) {
            .attribute => .attribute,
            .bin_op => .expression,
            .@"error" => .other,
            .name_node => .name,
            .word => .value,
        };
    }

    pub fn is_node(kind: TestKind) bool {
        return kind != .word;
    }

    pub fn is_token(kind: TestKind) bool {
        return kind == .word;
    }

    pub fn name(kind: TestKind) []const u8 {
        return switch (kind) {
            .attribute => "Attribute",
            .bin_op => "BinOp",
            .@"error" => "Error",
            .name_node => "Name",
            .word => "Word",
        };
    }
};

const Spot = struct {
    length: u32,
    offset: u32,

    pub fn end(spot: Spot) u32 {
        assert(spot.length <= std.math.maxInt(u32) - spot.offset);

        return spot.offset + spot.length;
    }
};

const TestTree = TreeType(TestKind);
const TestEvents = EventsType(TestKind);

const Fixture = struct {
    events: TestEvents,
    tree: TestTree,

    fn init(fixture: *Fixture, event_count_max: u32, node_count_max: u32) !void {
        assert(event_count_max > 0);
        assert(node_count_max > 0);

        try fixture.events.init(std.testing.allocator, event_count_max);
        errdefer fixture.events.deinit(std.testing.allocator);

        fixture.tree = try .init(std.testing.allocator, node_count_max, 4);
    }

    fn deinit(fixture: *Fixture) void {
        assert(fixture.tree.nodes.capacity() > 0);

        fixture.tree.deinit(std.testing.allocator);
        fixture.events.deinit(std.testing.allocator);
    }

    fn replay(fixture: *Fixture) Structure {
        return fixture.events.replay(&fixture.tree);
    }
};

fn spots(comptime spot_count: u32) [spot_count]Spot {
    assert(spot_count < std.math.maxInt(u32));

    var held: [spot_count]Spot = undefined;

    for (&held, 0..) |*spot, index| {
        spot.* = .{ .length = 1, .offset = @intCast(index) };
    }

    if (spot_count > 0) assert(held[spot_count - 1].end() == spot_count);

    return held;
}

fn word_name(_: Spot) []const u8 {
    return "Word";
}

fn nested(fixture: *Fixture) !void {
    try fixture.init(64, 64);

    const events = &fixture.events;

    events.start(.bin_op);
    events.token(0);
    events.start(.name_node);
    events.token(1);
    events.finish();
    events.start(.attribute);
    events.start(.name_node);
    events.token(2);
    events.finish();
    events.finish();
    events.finish();

    assert(events.depth == 0);
    assert(events.count() == 11);

    try std.testing.expectEqual(Structure.complete, fixture.replay());
}

fn forest(fixture: *Fixture) !void {
    try fixture.init(64, 64);

    for (0..3) |position| {
        fixture.events.start(.bin_op);
        fixture.events.start(.name_node);
        fixture.events.token(@intCast(position));
        fixture.events.finish();
        fixture.events.finish();
    }

    assert(fixture.events.depth == 0);
    assert(fixture.events.count() == 15);

    try std.testing.expectEqual(Structure.complete, fixture.replay());
}

fn steps_collect(steps: *WalkType(TestTree), collected: []Step) []const Step {
    assert(collected.len <= std.math.maxInt(u32));

    var step_count: u32 = 0;

    for (0..steps.step_max) |_| {
        const step = steps.next() orelse break;

        collected[step_count] = step;
        step_count += 1;
    }

    assert(steps.node == null);
    assert(step_count % 2 == 0);
    assert(step_count <= steps.step_max);

    return collected[0..step_count];
}

fn entered_collect(tree: *const TestTree, entered: []u32) u32 {
    assert(entered.len <= std.math.maxInt(u32));

    var buffer: [64]Step = undefined;
    var steps = walk(TestTree, tree);
    var entered_count: u32 = 0;

    for (steps_collect(&steps, &buffer)) |step| {
        switch (step) {
            .enter => |node| {
                entered[entered_count] = node;
                entered_count += 1;
            },
            .leave => {},
        }
    }

    assert(entered_count <= tree.count());

    return entered_count;
}

test "a flat start and finish replays in preorder" {
    var fixture: Fixture = undefined;

    try fixture.init(32, 32);
    defer fixture.deinit();

    fixture.events.start(.bin_op);
    fixture.events.token(0);
    fixture.events.start(.name_node);
    fixture.events.token(1);
    fixture.events.finish();
    fixture.events.finish();

    try std.testing.expect(TestKind.word.is_token());
    try std.testing.expect(!TestKind.word.is_node());
    try std.testing.expectEqual(Structure.complete, fixture.replay());
    try std.testing.expectEqual(2, fixture.tree.count());

    const tree = &fixture.tree;
    const outer = tree.at(0);
    const inner = tree.at(1);

    try std.testing.expectEqual(TestKind.bin_op, outer.kind);
    try std.testing.expectEqual(null, tree.parent_of(0));
    try std.testing.expectEqual(1, tree.child_first_of(0));
    try std.testing.expectEqual(0, outer.token_start);
    try std.testing.expectEqual(2, outer.token_end);
    try std.testing.expectEqual(TestKind.name_node, inner.kind);
    try std.testing.expectEqual(0, tree.parent_of(1));
    try std.testing.expectEqual(null, tree.child_first_of(1));
    try std.testing.expectEqual(null, tree.sibling_next_of(1));
    try std.testing.expectEqual(1, inner.token_start);
    try std.testing.expectEqual(2, inner.token_end);

    const two = spots(2);

    try std.testing.expectEqual(Span{ .offset = 0, .length = 2 }, outer.span(Spot, &two));
}

test "a chain of checkpoints wraps outermost last" {
    var fixture: Fixture = undefined;

    try fixture.init(32, 32);
    defer fixture.deinit();

    const events = &fixture.events;
    const held = events.checkpoint();

    events.start(.name_node);
    events.token(0);
    events.finish();

    events.start_at(held, .attribute);
    events.token(1);
    events.token(2);
    events.finish();

    events.start_at(held, .attribute);
    events.token(3);
    events.token(4);
    events.finish();

    try std.testing.expectEqual(Structure.complete, fixture.replay());
    try std.testing.expectEqual(3, fixture.tree.count());

    const tree = &fixture.tree;

    try std.testing.expectEqual(TestKind.attribute, tree.kind_at(0));
    try std.testing.expectEqual(null, tree.parent_of(0));
    try std.testing.expectEqual(1, tree.child_first_of(0));
    try std.testing.expectEqual(0, tree.at(0).token_start);
    try std.testing.expectEqual(5, tree.at(0).token_end);
    try std.testing.expectEqual(TestKind.attribute, tree.kind_at(1));
    try std.testing.expectEqual(0, tree.parent_of(1));
    try std.testing.expectEqual(2, tree.child_first_of(1));
    try std.testing.expectEqual(0, tree.at(1).token_start);
    try std.testing.expectEqual(3, tree.at(1).token_end);
    try std.testing.expectEqual(TestKind.name_node, tree.kind_at(2));
    try std.testing.expectEqual(1, tree.parent_of(2));
    try std.testing.expectEqual(1, tree.at(2).token_end);
}

test "an abandoned start leaves its tokens to the parent" {
    var fixture: Fixture = undefined;

    try fixture.init(32, 32);
    defer fixture.deinit();

    fixture.events.start(.bin_op);
    fixture.events.token(0);
    fixture.events.start(.name_node);
    fixture.events.token(1);
    fixture.events.abandon();
    fixture.events.token(2);
    fixture.events.finish();

    try std.testing.expectEqual(Structure.complete, fixture.replay());
    try std.testing.expectEqual(1, fixture.tree.count());

    const only = fixture.tree.at(0);

    try std.testing.expectEqual(TestKind.bin_op, only.kind);
    try std.testing.expectEqual(null, fixture.tree.child_first_of(0));
    try std.testing.expectEqual(0, only.token_start);
    try std.testing.expectEqual(3, only.token_end);
}

test "siblings link in order and stay disjoint" {
    var fixture: Fixture = undefined;

    try fixture.init(32, 32);
    defer fixture.deinit();

    fixture.events.start(.bin_op);

    for (0..3) |position| {
        fixture.events.start(.name_node);
        fixture.events.token(@intCast(position));
        fixture.events.finish();
    }

    fixture.events.finish();

    try std.testing.expectEqual(Structure.complete, fixture.replay());

    const tree = &fixture.tree;

    try std.testing.expectEqual(4, tree.count());
    try std.testing.expectEqual(1, tree.child_first_of(0));
    try std.testing.expectEqual(2, tree.sibling_next_of(1));
    try std.testing.expectEqual(3, tree.sibling_next_of(2));
    try std.testing.expectEqual(null, tree.sibling_next_of(3));

    for (1..4) |index| {
        const node = tree.at(@intCast(index));

        try std.testing.expectEqual(0, tree.parent_of(@intCast(index)));
        try std.testing.expectEqual(index - 1, node.token_start);
        try std.testing.expectEqual(index, node.token_end);
    }
}

test "a starved tree truncates" {
    var fixture: Fixture = undefined;

    try fixture.init(32, 1);
    defer fixture.deinit();

    fixture.events.start(.bin_op);
    fixture.events.start(.name_node);
    fixture.events.token(0);
    fixture.events.finish();
    fixture.events.finish();

    try std.testing.expectEqual(Structure{ .truncated = .nodes }, fixture.replay());
    try std.testing.expectEqual(1, fixture.tree.count());
}

test "a starved event buffer truncates" {
    var fixture: Fixture = undefined;

    try fixture.init(2, 32);
    defer fixture.deinit();

    fixture.events.start(.bin_op);
    fixture.events.token(0);
    fixture.events.token(1);
    fixture.events.finish();

    try std.testing.expectEqual(Structure{ .truncated = .events }, fixture.events.outcome);
    try std.testing.expectEqual(Structure{ .truncated = .events }, fixture.replay());
}

test "a starved event buffer carries a checkpoint without panicking" {
    var fixture: Fixture = undefined;

    try fixture.init(1, 32);
    defer fixture.deinit();

    fixture.events.token(0);

    const held = fixture.events.checkpoint();

    try std.testing.expectEqual(fixture.events.count(), held.index);

    fixture.events.start_at(held, .bin_op);
    fixture.events.finish();

    try std.testing.expectEqual(Structure{ .truncated = .events }, fixture.events.outcome);
    try std.testing.expectEqual(Structure{ .truncated = .events }, fixture.replay());
}

test "a replay repeats itself after a clear" {
    var fixture: Fixture = undefined;

    try fixture.init(32, 32);
    defer fixture.deinit();

    fixture.events.start(.bin_op);
    fixture.events.token(0);
    fixture.events.finish();

    _ = fixture.replay();

    var first: [1]TestTree.Node = undefined;

    @memcpy(&first, fixture.tree.slice());
    fixture.tree.clear();
    fixture.events.clear();
    fixture.events.start(.bin_op);
    fixture.events.token(0);
    fixture.events.finish();

    _ = fixture.replay();

    try std.testing.expectEqualSlices(TestTree.Node, &first, fixture.tree.slice());
    try std.testing.expectEqual(0, fixture.events.depth);
}

test "every node enters once and leaves once" {
    var fixture: Fixture = undefined;

    try nested(&fixture);
    defer fixture.deinit();

    var entered: [4]u32 = @splat(0);
    var left: [4]u32 = @splat(0);
    var buffer: [16]Step = undefined;
    var steps = walk(TestTree, &fixture.tree);

    for (steps_collect(&steps, &buffer)) |step| {
        switch (step) {
            .enter => |node| entered[node] += 1,
            .leave => |node| left[node] += 1,
        }
    }

    try std.testing.expectEqual(4, fixture.tree.count());
    try std.testing.expectEqualSlices(u32, &.{ 1, 1, 1, 1 }, &entered);
    try std.testing.expectEqualSlices(u32, &.{ 1, 1, 1, 1 }, &left);
}

test "the enter order is index order" {
    var fixture: Fixture = undefined;

    try nested(&fixture);
    defer fixture.deinit();

    var entered: [4]u32 = undefined;
    const entered_count = entered_collect(&fixture.tree, &entered);

    try std.testing.expectEqualSlices(u32, &.{ 0, 1, 2, 3 }, entered[0..entered_count]);
}

test "a parent leaves after its last child" {
    var fixture: Fixture = undefined;

    try nested(&fixture);
    defer fixture.deinit();

    const tree = &fixture.tree;
    var positions: [4]u32 = @splat(sentinel);
    var buffer: [16]Step = undefined;
    var steps = walk(TestTree, tree);

    for (steps_collect(&steps, &buffer), 0..) |step, position| {
        switch (step) {
            .enter => {},
            .leave => |node| positions[node] = @intCast(position),
        }
    }

    for (0..tree.count()) |node| {
        var child = tree.child_first_of(@intCast(node));

        while (child) |held| {
            try std.testing.expect(positions[held] < positions[node]);

            child = tree.sibling_next_of(held);
        }
    }
}

test "a subtree walk stays inside the subtree" {
    var fixture: Fixture = undefined;

    try nested(&fixture);
    defer fixture.deinit();

    var buffer: [16]Step = undefined;
    var steps = walk_from(TestTree, &fixture.tree, 2);
    const visited = steps_collect(&steps, &buffer);

    try std.testing.expectEqualSlices(
        Step,
        &.{ .{ .enter = 2 }, .{ .enter = 3 }, .{ .leave = 3 }, .{ .leave = 2 } },
        visited,
    );
}

test "an empty tree walks to nothing" {
    var tree: TestTree = try .init(std.testing.allocator, 4, 2);
    defer tree.deinit(std.testing.allocator);

    var steps = walk(TestTree, &tree);
    const step = steps.next();

    try std.testing.expectEqual(0, tree.count());
    try std.testing.expectEqual(null, step);
}

test "a lone node enters and leaves" {
    var fixture: Fixture = undefined;

    try fixture.init(8, 8);
    defer fixture.deinit();

    fixture.events.start(.name_node);
    fixture.events.token(0);
    fixture.events.finish();

    try std.testing.expectEqual(Structure.complete, fixture.replay());

    var buffer: [4]Step = undefined;
    var steps = walk(TestTree, &fixture.tree);
    const visited = steps_collect(&steps, &buffer);

    try std.testing.expectEqualSlices(Step, &.{ .{ .enter = 0 }, .{ .leave = 0 } }, visited);
}

test "a forest walks every root" {
    var fixture: Fixture = undefined;

    try forest(&fixture);
    defer fixture.deinit();

    var entered: [6]u32 = undefined;
    const entered_count = entered_collect(&fixture.tree, &entered);

    try std.testing.expectEqual(6, fixture.tree.count());
    try std.testing.expectEqualSlices(u32, &.{ 0, 1, 2, 3, 4, 5 }, entered[0..entered_count]);

    var buffer: [16]Step = undefined;
    var steps = walk(TestTree, &fixture.tree);

    try std.testing.expectEqual(12, steps_collect(&steps, &buffer).len);
}

test "an ancestor search climbs to the kind it names" {
    var fixture: Fixture = undefined;

    try nested(&fixture);
    defer fixture.deinit();

    try std.testing.expectEqual(2, fixture.tree.ancestor_of(3, .attribute));
    try std.testing.expectEqual(0, fixture.tree.ancestor_of(3, .bin_op));
    try std.testing.expectEqual(null, fixture.tree.ancestor_of(3, .name_node));
    try std.testing.expectEqual(null, fixture.tree.ancestor_of(0, .bin_op));
}

test "the innermost node at an offset is the narrowest cover" {
    var fixture: Fixture = undefined;

    try nested(&fixture);
    defer fixture.deinit();

    const tokens = spots(3);

    try std.testing.expectEqual(1, fixture.tree.innermost_at(Spot, &tokens, 1));
    try std.testing.expectEqual(2, fixture.tree.innermost_at(Spot, &tokens, 3));
    try std.testing.expectEqual(null, fixture.tree.innermost_at(Spot, &tokens, 5));
}

test "a dump writes nodes and tokens in walk order" {
    var fixture: Fixture = undefined;

    try nested(&fixture);
    defer fixture.deinit();

    const tokens = spots(3);
    var buffer: [1 << 10]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buffer);

    try dump(TestKind, Spot, &out, &fixture.tree, &tokens, "a'c", word_name);

    try std.testing.expectEqualStrings(
        "BinOp@0..3\n  Word@0..1 \"a\"\n  Name@1..2\n    Word@1..2 \"'\"\n" ++
            "  Attribute@2..3\n    Name@2..3\n      Word@2..3 \"c\"\n",
        out.buffered(),
    );
}

test "a dump escapes bytes that are not text" {
    var fixture: Fixture = undefined;

    try fixture.init(8, 8);
    defer fixture.deinit();

    fixture.events.start(.name_node);
    fixture.events.token(0);
    fixture.events.finish();

    try std.testing.expectEqual(Structure.complete, fixture.replay());

    const tokens = spots(1);
    var buffer: [1 << 8]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buffer);
    var starved_buffer: [4]u8 = undefined;
    var starved: std.Io.Writer = .fixed(&starved_buffer);

    try dump(TestKind, Spot, &out, &fixture.tree, &tokens, &.{0xff}, word_name);

    try std.testing.expectEqualStrings("Name@0..1\n  Word@0..1 \"\\xff\"\n", out.buffered());

    try std.testing.expectError(
        error.WriteFailed,
        dump(TestKind, Spot, &starved, &fixture.tree, &tokens, "\n", word_name),
    );
}

test "an error row records and reads back" {
    var tree: TestTree = try .init(std.testing.allocator, 4, 2);
    defer tree.deinit(std.testing.allocator);

    try tree.push_diagnostic(7);
    try tree.push_diagnostic(9);

    try std.testing.expectError(error.Truncated, tree.push_diagnostic(11));
    try std.testing.expectEqualSlices(u32, &.{ 7, 9 }, tree.diagnostic_slice());

    tree.clear();

    try std.testing.expectEqual(0, tree.diagnostic_slice().len);
}

test "an index groups node positions by category in tree order" {
    var fixture: Fixture = undefined;

    try nested(&fixture);
    defer fixture.deinit();

    var index: IndexType(TestKind) = try .init(std.testing.allocator, 8);
    defer index.deinit(std.testing.allocator);

    index.build(&fixture.tree);

    try std.testing.expectEqual(4, index.count());
    try std.testing.expectEqualSlices(u32, &.{ 1, 3 }, index.of(.name));
    try std.testing.expectEqualSlices(u32, &.{2}, index.of(.attribute));
    try std.testing.expectEqualSlices(u32, &.{0}, index.of(.expression));
    try std.testing.expectEqual(0, index.of(.value).len);
}
