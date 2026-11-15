const std = @import("std");
const assert = std.debug.assert;
const ArrayType = @import("../stdx/bounded/array.zig").ArrayType;
const Binding = @import("binding.zig").Bindings.Binding;
const Call = @import("view.zig").View.Call;
const Front = @import("front.zig").Front;
const FrontCapacity = @import("front.zig").Front.Capacity;
const FunctionView = @import("view.zig").View.Function;
const Language = @import("language.zig").Language;
const Options = @import("front.zig").Front.Options;
const Reference = @import("binding.zig").Bindings.Reference;
const Scratch = @import("front.zig").Front.Scratch;
const Span = @import("../stdx/bounded/span.zig");
const Token = @import("token.zig");
const View = @import("view.zig").View;
const child_count_max = @import("view.zig").child_count_max;
const frame_depth_max = @import("tree.zig").frame_depth_max;
const graph = @import("../stdx/graph.zig");
const parameter_count_max = @import("view.zig").parameter_count_max;
const reference_count_max = @import("binding.zig").reference_count_max;
const scan = @import("../text/scan.zig");
const sort = @import("../stdx/sort.zig");
const stream = @import("stream.zig");

pub const Calls = struct {
    aliases: ArrayType(Alias),
    edges: ArrayType(Edge),
    fields: ArrayType(Field),
    front: ?*const Front,
    front_builds: u32,
    marks: ArrayType(bool),
    names: ArrayType(u32),
    nodes: ArrayType(u32),
    rows: ArrayType(Function),
    scratch: graph.Scratch,
    source: []const u8,

    const Alias = struct {
        name: Span,
        target: Span,
    };

    pub const Capacity = struct {
        edge_count_max: u32,
        function_count_max: u32,
    };

    pub const Edge = struct {
        call: Span,
        source: u32,
        target: u32,
    };

    const Field = struct {
        container: Span,
        indexed: bool,
        name: Span,
        spelled: Span,
    };

    pub const Function = struct {
        binding: ?u32,
        @"comptime": bool,
        container: ?Span,
        edge_count: u32,
        edge_start: u32,
        fallible: bool,
        name: Span,
        node: u32,
        recursive: bool,
        value: bool,
    };

    pub const Returns = struct {
        nothing_words: []const []const u8,
        optional_markers: []const []const u8,
        spelled: bool,
    };

    fn aliases_collect(calls: *Calls, front: *const Front, source: []const u8) void {
        assert(front.source.len == source.len);

        const tokens = front.tokens();

        assert(calls.aliases.empty());

        for (front.nodes_of(.declaration)) |position| {
            const node = front.view(position) orelse continue;
            const declaration = node.as_declaration() orelse continue;
            const name = declaration.name_token() orelse continue;
            const value = declaration.value() orelse continue;

            assert(name < tokens.len);

            if (!is_bare_path(value.span().text(source))) continue;
            if (calls.aliases.full()) return;

            calls.aliases.push(.{ .name = tokens[name].span(), .target = value.span() });
        }

        assert(calls.aliases.count() <= front.nodes_of(.declaration).len);
    }

    fn collect(calls: *Calls, front: *const Front) void {
        const bindings = front.bindings();

        assert(calls.nodes.count() == calls.rows.count());

        for (0..bindings.reference_count()) |index| {
            const reference = bindings.reference_at(@intCast(index));
            if (reference.resolution != .bound) continue;

            const binding = reference.resolution.bound;
            const target = calls.row_of_binding(binding) orelse continue;
            const node = callee_call_of(front, &reference) orelse continue;

            calls.edges_push(node, node.span(), target) catch |err| switch (err) {
                error.Truncated => return,
            };
        }

        assert(calls.edges.count() <= calls.edges.capacity());
    }

    fn container_span_at(calls: *const Calls, node: View) ?Span {
        const rows = calls.rows.const_slice();
        var current = node;

        assert(calls.nodes.count() == rows.len);

        for (0..frame_depth_max) |_| {
            if (calls.row_of_node(current.index())) |row| {
                assert(row < rows.len);

                return rows[row].container;
            }

            current = current.parent() orelse return null;
        }

        return null;
    }

    fn cycles_mark(calls: *Calls) void {
        const count = calls.rows.count();

        calls.marks.clear();

        for (0..count) |_| calls.marks.push(false);

        const called: Called = .{
            .edges = calls.edges.const_slice(),
            .functions = calls.rows.const_slice(),
        };

        var recursion: Recursion = .{ .marks = calls.marks.slice() };

        graph.components(Called, Recursion, count, &calls.scratch, &called, &recursion) catch
            unreachable;

        for (calls.rows.slice(), calls.marks.const_slice()) |*function, marked| {
            if (marked) function.recursive = true;
        }

        assert(calls.marks.count() == count);
        assert(calls.rows.count() == count);
    }

    fn edges_collect(calls: *Calls, front: *const Front, source: []const u8) void {
        assert(calls.edges.empty());
        assert(calls.fields.empty());
        assert(front.source.len == source.len);

        calls.fields_collect(front, source);
        calls.collect(front);
        calls.methods_collect(front, source);

        comptime assert(@sizeOf(Edge) == 16);

        sort.unstable(Edge, calls.edges.slice(), void, {}, edge_less);
        calls.edges_range();
    }

    fn edges_push(calls: *Calls, node: View, call: Span, target: u32) error{Truncated}!void {
        var current: ?View = node;

        assert(target < calls.rows.count());

        for (0..frame_depth_max) |_| {
            const held = current orelse return;

            if (calls.row_of_node(held.index())) |source| {
                if (calls.edges.full()) return error.Truncated;

                assert(source < calls.rows.count());

                calls.edges.push(.{ .call = call, .source = source, .target = target });

                return;
            }

            current = held.parent();
        }
    }

    fn edges_range(calls: *Calls) void {
        const rows = calls.rows.slice();

        for (calls.edges.const_slice(), 0..) |edge, index| {
            const function = &rows[edge.source];

            if (function.edge_count == 0) function.edge_start = @intCast(index);

            assert(function.edge_start + function.edge_count == index);

            function.edge_count += 1;
        }

        for (rows) |function| {
            assert(function.edge_start + function.edge_count <= calls.edges.count());
        }
    }

    fn element_type_of(
        calls: *const Calls,
        front: *const Front,
        name: Span,
        source: []const u8,
    ) ?Span {
        assert(name.end() <= source.len);

        const held = declaring_view_of(front, name) orelse return null;
        if (held.declaring.category() != .loop) return null;

        const iterable = iterable_of(held.declaring) orelse return null;
        const tokens = front.tokens();
        const span = iterable.span();
        const head = walk_head_of(tokens, span, source);
        const resolved = if (head) |found| bound_type_shape_of(front, found.name, source) else null;
        const access: Access = .{ .head = head, .resolved = resolved, .span = span };
        const shape = calls.fields_walk(tokens, &access, null, source) orelse return null;

        assert(shape.spelled.end() <= source.len);

        if (!shape.indexed) return null;
        return shape.spelled;
    }

    fn field_type_of(
        calls: *const Calls,
        held: []const u8,
        name: []const u8,
        source: []const u8,
    ) ?Shape {
        if (held.len == 0) return null;
        if (name.len == 0) return null;
        assert(source.len <= std.math.maxInt(u32));

        var found: ?Shape = null;

        for (calls.fields.const_slice()) |field| {
            if (!std.mem.eql(u8, field.name.text(source), name)) continue;
            if (!std.mem.eql(u8, field.container.text(source), held)) continue;
            if (found != null) return null;

            found = .{ .indexed = field.indexed, .spelled = field.spelled };
        }

        if (found) |shape| assert(shape.spelled.end() <= source.len);

        return found;
    }

    fn fields_collect(calls: *Calls, front: *const Front, source: []const u8) void {
        assert(front.source.len == source.len);

        const tokens = front.tokens();

        for (front.nodes_of(.@"struct")) |position| {
            const node = front.view(position) orelse continue;
            const container = node.as_container() orelse continue;
            const named = container.name_token() orelse continue;
            const held = tokens[named].span();
            var members = container.body().children();

            for (0..child_count_max) |_| {
                const member = members.next() orelse break;
                const name = member.name_token() orelse continue;
                const spelled = member.type_of() orelse continue;
                const leaf = name_first_in(front, spelled.span(), source) orelse continue;

                assert(name < tokens.len);

                if (calls.fields.full()) return;

                calls.fields.push(.{
                    .container = held,
                    .indexed = spells_an_index(spelled.span().text(source)),
                    .name = tokens[name].span(),
                    .spelled = leaf,
                });
            }
        }

        assert(calls.fields.count() <= calls.fields.capacity());
    }

    fn fields_walk(
        calls: *const Calls,
        tokens: []const Token,
        access: *const Access,
        container: ?Span,
        source: []const u8,
    ) ?Shape {
        if (container) |container_span| assert(container_span.end() <= source.len);

        const head = access.head orelse return .{ .indexed = false, .spelled = access.span };
        var held = access.resolved orelse return null;

        assert(head.position < tokens.len);
        assert(access.span.contains(head.name.offset));

        for (tokens[head.position + 1 ..]) |token| {
            if (token.offset >= access.span.end()) break;
            if (token.is_punctuation(.bracket_open)) return null;
            if (token.is_punctuation(.paren_open)) return null;

            const qualifies = token.kind == .identifier or token.kind == .number;
            if (!qualifies) continue;

            const outer = held.spelled.text(source);

            held = calls.field_type_of(outer, token.text(source), source) orelse return null;
        }

        const spelled = held.spelled.text(source);
        if (!receives_itself(spelled)) return held;
        if (!names_a_type_of_itself(spelled)) return null;

        const outer = container orelse return null;
        return .{ .indexed = false, .spelled = outer };
    }

    fn function_push(
        calls: *Calls,
        front: *const Front,
        source: []const u8,
        returns: *const Returns,
        binding: ?u32,
        name: Span,
        node: View,
    ) error{Truncated}!void {
        assert(name.end() <= source.len);
        if (binding) |index| assert(index < front.bindings().count());
        assert(node.index() < front.node_count());

        const function = node.as_function().?;
        const spelled = if (function.returns_span()) |span| spelled_of(source, span) else "";

        if (calls.rows.full()) return error.Truncated;

        calls.rows.push(.{
            .binding = binding,
            .@"comptime" = is_comptime(function, source, spelled),
            .container = container_of(front, node, function, source),
            .edge_count = 0,
            .edge_start = 0,
            .fallible = is_fallible(spelled, returns.optional_markers),
            .name = name,
            .node = node.index(),
            .recursive = false,
            .value = is_value(spelled),
        });

        assert(calls.rows.count() > 0);
    }

    fn functions_collect(
        calls: *Calls,
        front: *const Front,
        source: []const u8,
        returns: *const Returns,
    ) void {
        assert(front.source.len == source.len);

        const bindings = front.bindings();

        assert(calls.rows.empty());

        for (0..bindings.count()) |position| {
            const index: u32 = @intCast(position);
            const binding = bindings.at(index);

            const named = switch (binding.class) {
                .constant, .function, .local, .method => true,
                else => false,
            };

            if (!named) continue;

            const node = function_view_of(front, index, &binding) orelse continue;

            calls.function_push(front, source, returns, index, binding.name, node) catch |err|
                switch (err) {
                    error.Truncated => return,
                };
        }

        calls.methods_unbound_collect(front, source, returns);

        assert(calls.nodes.empty());
    }

    fn method_position_of(
        calls: *const Calls,
        held: []const u8,
        name: []const u8,
        source: []const u8,
    ) ?u32 {
        if (held.len == 0) return null;
        if (name.len == 0) return null;

        const rows = calls.rows.const_slice();
        const names = calls.names.const_slice();
        var found: ?u32 = null;

        assert(held.len <= source.len);
        assert(names.len == rows.len);

        for (names[calls.names_start(name, source)..]) |position| {
            const function = rows[position];
            if (!std.mem.eql(u8, function.name.text(source), name)) break;

            const container = function.container orelse continue;
            if (!std.mem.eql(u8, container.text(source), held)) continue;
            if (found != null) return null;

            found = position;
        }

        if (found) |position| assert(position < calls.rows.count());

        return found;
    }

    fn methods_collect(calls: *Calls, front: *const Front, source: []const u8) void {
        assert(front.source.len == source.len);

        const tokens = front.tokens();

        assert(calls.nodes.count() == calls.rows.count());

        for (front.nodes_of(.call)) |position| {
            const node = front.view(position) orelse continue;
            const call = node.as_call() orelse continue;
            const name = call.name_token() orelse continue;

            assert(name < tokens.len);

            const method = tokens[name].text(source);
            if (calls.function_of(method) == null) continue;

            const head = if (call.receiver()) |receiver|
                calls.receiver_type_of(node, receiver)
            else
                calls.path_head_of(front, node, call, source);

            const held = head orelse continue;
            const target = calls.method_position_of(held, method, source) orelse continue;

            calls.edges_push(node, node.span(), target) catch |err| switch (err) {
                error.Truncated => return,
            };
        }
    }

    fn methods_unbound_collect(
        calls: *Calls,
        front: *const Front,
        source: []const u8,
        returns: *const Returns,
    ) void {
        assert(front.source.len == source.len);

        const tokens = front.tokens();

        calls.nodes_index();

        for (front.nodes_of(.function)) |position| {
            const node = front.view(position) orelse continue;
            const function = node.as_function() orelse continue;
            const name = function.name_token() orelse continue;

            if (function.is_anonymous()) continue;
            if (calls.row_of_node(node.index()) != null) continue;

            assert(name < tokens.len);

            const span = tokens[name].span();

            calls.function_push(front, source, returns, null, span, node) catch |err|
                switch (err) {
                    error.Truncated => break,
                };
        }

        calls.nodes.clear();

        assert(calls.nodes.empty());
    }

    fn names_index(calls: *Calls, source: []const u8) void {
        assert(calls.names.empty());
        assert(source.len <= std.math.maxInt(u32));

        for (0..calls.rows.count()) |position| calls.names.push(@intCast(position));

        const named: Named = .{ .functions = calls.rows.const_slice(), .source = source };

        std.sort.pdq(u32, calls.names.slice(), named, Named.less);

        assert(calls.names.count() == calls.rows.count());
    }

    fn names_start(calls: *const Calls, name: []const u8, source: []const u8) u32 {
        assert(name.len > 0);
        assert(source.len <= std.math.maxInt(u32));

        const bound: NameBound = .{
            .functions = calls.rows.const_slice(),
            .name = name,
            .source = source,
        };

        const names = calls.names.const_slice();
        const first = std.sort.partitionPoint(u32, names, bound, NameBound.before);

        assert(first <= names.len);

        return @intCast(first);
    }

    fn nodes_index(calls: *Calls) void {
        assert(calls.nodes.empty());

        for (0..calls.rows.count()) |position| calls.nodes.push(@intCast(position));

        const rows = calls.rows.const_slice();

        std.sort.pdq(u32, calls.nodes.slice(), rows, node_less);

        assert(calls.nodes.count() == calls.rows.count());
    }

    fn path_head_of(
        calls: *const Calls,
        front: *const Front,
        node: View,
        call: Call,
        source: []const u8,
    ) ?[]const u8 {
        assert(call.view.index() == node.index());
        assert(front.source.len == source.len);

        const callee = call.callee() orelse return null;
        const span = callee.span();
        var head: Span = .empty;
        var names: u32 = 0;
        var separators: u32 = 0;

        for (tokens_from(front.tokens(), span.offset)) |token| {
            if (token.offset >= span.end()) break;

            const text = token.text(source);
            const named = token.kind == .identifier or receives_itself(text);

            if (std.mem.eql(u8, text, "::")) {
                separators += 1;
            } else if (named) {
                if (names == 0) head = token.span();

                names += 1;
            } else {
                return null;
            }
        }

        if (names != 2) return null;
        if (separators != 1) return null;

        assert(head.end() <= span.end());

        if (!receives_itself(head.text(source))) return head.text(source);

        const container = calls.container_span_at(node) orelse return null;
        return container.text(source);
    }

    fn receiver_head_of(
        calls: *const Calls,
        front: *const Front,
        head: *const Head,
        container: ?Span,
        source: []const u8,
    ) ?Shape {
        assert(head.name.end() <= source.len);
        assert(head.position < front.tokens().len);
        if (container) |container_span| assert(container_span.end() <= source.len);

        if (bound_type_shape_of(front, head.name, source)) |shape| return shape;

        if (head.itself) {
            const held = container orelse return null;
            return .{ .indexed = false, .spelled = held };
        }

        const element = calls.element_type_of(front, head.name, source) orelse return null;
        return .{ .indexed = false, .spelled = element };
    }

    fn row_of_binding(calls: *const Calls, binding: u32) ?u32 {
        assert(binding < std.math.maxInt(u32));

        const rows = calls.rows.const_slice();
        const first = std.sort.partitionPoint(Function, rows, binding, binding_before);

        assert(first <= rows.len);

        if (first == rows.len) return null;
        if (rows[first].binding != binding) return null;

        assert(first < rows.len);

        assert(binding < std.math.maxInt(u32));

        return @intCast(first);
    }

    fn row_of_node(calls: *const Calls, node: u32) ?u32 {
        assert(node < std.math.maxInt(u32));

        const rows = calls.rows.const_slice();
        const nodes = calls.nodes.const_slice();
        const bound: NodeBound = .{ .functions = rows, .node = node };
        const first = std.sort.partitionPoint(u32, nodes, bound, NodeBound.before);

        assert(first <= nodes.len);

        if (first == nodes.len) return null;

        const position = nodes[first];

        assert(position < rows.len);

        if (rows[position].node != node) return null;
        return position;
    }

    fn values_mark(
        calls: *Calls,
        front: *const Front,
        source: []const u8,
        returns: *const Returns,
    ) void {
        if (returns.spelled) return;
        assert(front.source.len == source.len);

        const rows = calls.rows.slice();

        assert(calls.nodes.count() == rows.len);

        for (front.nodes_of(.@"return")) |position| {
            const statement = front.view(position) orelse continue;
            if (!returns_something(statement, source, returns.nothing_words)) continue;

            const owner = owner_of(statement) orelse continue;
            const row = calls.row_of_node(owner.index()) orelse continue;
            const function = owner.as_function().?;
            if (function.returns_span() != null) continue;

            assert(row < rows.len);

            rows[row].value = true;
        }
    }

    pub fn init(
        calls: *Calls,
        gpa: std.mem.Allocator,
        capacity: Capacity,
    ) std.mem.Allocator.Error!void {
        assert(capacity.edge_count_max > 0);
        assert(capacity.function_count_max > 0);

        calls.aliases = try .init(gpa, capacity.function_count_max);
        errdefer calls.aliases.deinit(gpa);

        calls.edges = try .init(gpa, capacity.edge_count_max);
        errdefer calls.edges.deinit(gpa);

        calls.fields = try .init(gpa, capacity.function_count_max);
        errdefer calls.fields.deinit(gpa);

        calls.rows = try .init(gpa, capacity.function_count_max);
        errdefer calls.rows.deinit(gpa);

        calls.marks = try .init(gpa, capacity.function_count_max);
        errdefer calls.marks.deinit(gpa);

        calls.names = try .init(gpa, capacity.function_count_max);
        errdefer calls.names.deinit(gpa);

        calls.nodes = try .init(gpa, capacity.function_count_max);
        errdefer calls.nodes.deinit(gpa);

        calls.scratch = try .init(gpa, capacity.function_count_max);
        calls.front = null;
        calls.front_builds = 0;
        calls.source = &.{};

        assert(calls.rows.empty());
        assert(calls.scratch.capacity() == capacity.function_count_max);
    }

    pub fn deinit(calls: *Calls, gpa: std.mem.Allocator) void {
        assert(calls.names.capacity() == calls.rows.capacity());
        assert(calls.nodes.capacity() == calls.rows.capacity());

        calls.scratch.deinit(gpa);
        calls.nodes.deinit(gpa);
        calls.names.deinit(gpa);
        calls.marks.deinit(gpa);
        calls.rows.deinit(gpa);
        calls.fields.deinit(gpa);
        calls.edges.deinit(gpa);
        calls.aliases.deinit(gpa);
        calls.* = undefined;
    }

    pub fn build(calls: *Calls, front: *const Front, returns: *const Returns) void {
        const source = front.source;

        assert(source.len <= std.math.maxInt(u32));
        assert(front.outcome != null);

        calls.aliases.clear();
        calls.edges.clear();
        calls.fields.clear();
        calls.rows.clear();
        calls.names.clear();
        calls.nodes.clear();
        calls.front = front;
        calls.front_builds = front.builds;
        calls.source = source;

        calls.functions_collect(front, source, returns);
        calls.names_index(source);
        calls.nodes_index();
        calls.values_mark(front, source, returns);
        calls.edges_collect(front, source);
        calls.aliases_collect(front, source);
        calls.cycles_mark();

        assert(calls.names.count() == calls.rows.count());
        assert(calls.nodes.count() == calls.rows.count());
    }

    pub fn alias_of(calls: *const Calls, name: []const u8) ?Span {
        assert(name.len <= std.math.maxInt(u32));

        const source = calls.source;

        assert(source.len <= std.math.maxInt(u32));

        for (calls.aliases.const_slice()) |alias| {
            if (std.mem.eql(u8, alias.name.text(source), name)) {
                assert(alias.target.end() <= source.len);

                return alias.target;
            }
        }

        return null;
    }

    pub fn edges_of(calls: *const Calls, function: *const Function) []const Edge {
        const start = function.edge_start;
        const stop = start + function.edge_count;

        assert(stop <= calls.edges.count());

        const edges = calls.edges.const_slice()[start..stop];

        for (edges) |edge| assert(edge.target < calls.rows.count());

        return edges;
    }

    fn front_of(calls: *const Calls) *const Front {
        const front = calls.front.?;

        assert(front.builds == calls.front_builds);

        return front;
    }

    pub fn function_of(calls: *const Calls, name: []const u8) ?*const Function {
        const source = calls.source;

        if (name.len == 0) return null;

        const first = calls.names_start(name, source);
        if (first == calls.names.count()) return null;

        const position = calls.names.get(first);
        const function = &calls.rows.const_slice()[position];
        if (!std.mem.eql(u8, function.name.text(source), name)) return null;

        assert(position < calls.rows.count());
        assert(function.name.length == name.len);

        return function;
    }

    pub fn functions(calls: *const Calls) []const Function {
        const held = calls.rows.const_slice();

        assert(held.len <= calls.rows.capacity());
        assert(calls.names.count() <= held.len);

        return held;
    }

    pub fn method_of(calls: *const Calls, held: []const u8, name: []const u8) ?*const Function {
        assert(held.len <= std.math.maxInt(u32));
        assert(name.len <= std.math.maxInt(u32));

        const source = calls.source;
        const position = calls.method_position_of(held, name, source) orelse return null;
        const function = &calls.rows.const_slice()[position];

        assert(std.mem.eql(u8, function.name.text(source), name));
        assert(std.mem.eql(u8, function.container.?.text(source), held));

        return function;
    }

    pub fn receiver_type_of(calls: *const Calls, node: View, receiver: View) ?[]const u8 {
        assert(std.meta.activeTag(receiver) == std.meta.activeTag(node));

        const front = calls.front_of();
        const source = calls.source;
        const tokens = front.tokens();
        const span = receiver.span();
        const container = calls.container_span_at(node);
        const head = walk_head_of(tokens, span, source);

        const resolved = if (head) |found|
            calls.receiver_head_of(front, &found, container, source)
        else
            null;

        const access: Access = .{ .head = head, .resolved = resolved, .span = span };
        const shape = calls.fields_walk(tokens, &access, container, source) orelse return null;

        assert(shape.spelled.end() <= source.len);

        return shape.spelled.text(source);
    }

    pub fn value_of(calls: *const Calls, name: []const u8) ?bool {
        const source = calls.source;

        if (name.len == 0) return null;

        const first = calls.names_start(name, source);
        const rows = calls.rows.const_slice();
        var held: ?bool = null;

        for (calls.names.const_slice()[first..]) |position| {
            assert(position < rows.len);

            const function = &rows[position];
            if (!std.mem.eql(u8, function.name.text(source), name)) break;

            if (held) |seen| {
                if (seen != function.value) return null;
            } else {
                held = function.value;
            }
        }

        assert(first <= calls.names.count());

        return held;
    }

    pub fn is_value(spelled: []const u8) bool {
        assert(spelled.len <= std.math.maxInt(u32));

        if (spelled.len == 0) return false;

        for (void_types) |void_type| {
            assert(void_type.len > 0);

            if (std.mem.eql(u8, spelled, void_type)) return false;
        }

        return true;
    }
};

const Bound = struct {
    declaring: View,
    name: Span,
    reference: View,
};

const Called = struct {
    edges: []const Calls.Edge,
    functions: []const Calls.Function,

    pub fn edge_count_of(called: *const Called, node: u32) u32 {
        assert(node < called.functions.len);

        const function = &called.functions[node];

        assert(function.edge_start + function.edge_count <= called.edges.len);
        assert(function.edge_count <= called.edges.len);

        return function.edge_count;
    }

    pub fn edge_target_of(called: *const Called, node: u32, ordinal: u32) ?u32 {
        assert(node < called.functions.len);

        const function = &called.functions[node];

        assert(ordinal < function.edge_count);

        const edge = called.edges[function.edge_start + ordinal];

        assert(edge.source == node);
        assert(edge.target < called.functions.len);

        return edge.target;
    }

    pub fn holds(called: *const Called, node: u32) bool {
        assert(node < called.functions.len);
        assert(called.functions.len <= std.math.maxInt(u32));

        return true;
    }
};

const Head = struct {
    itself: bool,
    name: Span,
    position: u32,
};

const NameBound = struct {
    functions: []const Calls.Function,
    name: []const u8,
    source: []const u8,

    fn before(bound: NameBound, position: u32) bool {
        assert(position < bound.functions.len);
        assert(bound.name.len > 0);

        const named = bound.functions[position].name.text(bound.source);
        return std.mem.order(u8, named, bound.name) == .lt;
    }
};

const Named = struct {
    functions: []const Calls.Function,
    source: []const u8,

    fn less(named: Named, left: u32, right: u32) bool {
        assert(left < named.functions.len);
        assert(right < named.functions.len);

        const left_name = named.functions[left].name.text(named.source);
        const right_name = named.functions[right].name.text(named.source);

        return switch (std.mem.order(u8, left_name, right_name)) {
            .lt => true,
            .gt => false,
            .eq => left < right,
        };
    }
};

const NodeBound = struct {
    functions: []const Calls.Function,
    node: u32,

    fn before(bound: NodeBound, position: u32) bool {
        assert(position < bound.functions.len);
        assert(bound.functions.len <= std.math.maxInt(u32));

        return bound.functions[position].node < bound.node;
    }
};

const Recursion = struct {
    marks: []bool,

    pub fn component(recursion: *Recursion, members: []const u32, looping: bool) void {
        assert(members.len > 0);
        assert(members.len <= recursion.marks.len);

        if (!looping) return;

        for (members) |member| recursion.marks[member] = true;
    }
};

const Shape = struct {
    indexed: bool,
    spelled: Span,
};

const Access = struct {
    head: ?Head,
    resolved: ?Shape,
    span: Span,
};

const void_types = [_][]const u8{ "()", "!noreturn", "!void", "None", "noreturn", "void" };

fn is_fallible(spelled: []const u8, optional_markers: []const []const u8) bool {
    assert(spelled.len <= std.math.maxInt(u32));

    if (spelled.len == 0) return false;
    if (scan.find(spelled, "error") != null) return true;
    assert(optional_markers.len <= std.math.maxInt(u32));

    for (optional_markers) |marker| {
        assert(marker.len > 0);

        if (scan.find(spelled, marker) != null) return true;
    }

    return false;
}

fn assigned_function_of(front: *const Front, binding: u32) ?View {
    assert(binding < front.bindings().count());

    var references = front.bindings().references_of(binding);

    for (0..reference_count_max) |_| {
        const reference = references.next() orelse return null;
        const named = front.view(reference.node) orelse continue;
        const assignment = named.parent() orelse continue;
        if (assignment.category() != .assignment) continue;

        var children = assignment.children();
        const target = children.next() orelse continue;
        if (target.index() != named.index()) continue;

        const value = children.next() orelse continue;
        if (value.as_function() == null) continue;

        assert(value.index() > assignment.index());

        return value;
    }

    return null;
}

fn binding_before(binding: u32, function: Calls.Function) bool {
    assert(binding < std.math.maxInt(u32));
    assert(function.name.length <= std.math.maxInt(u32) - function.name.offset);

    const held = function.binding orelse std.math.maxInt(u32);

    return held < binding;
}

fn bound_type_shape_of(front: *const Front, name: Span, source: []const u8) ?Shape {
    assert(name.end() <= source.len);

    const held = declaring_view_of(front, name) orelse return null;
    const spelled = type_span_of(front, &held) orelse return null;
    const leading = name_first_in(front, spelled, source) orelse return null;

    assert(spelled.end() <= source.len);
    assert(leading.end() <= spelled.end());

    return .{ .indexed = spells_an_index(spelled.text(source)), .spelled = leading };
}

fn callee_call_of(front: *const Front, reference: *const Reference) ?View {
    var current = front.view(reference.node);

    assert(reference.resolution == .bound);

    for (0..frame_depth_max) |_| {
        const held = current orelse return null;

        if (held.as_call()) |call| {
            const position = call.name_token() orelse return null;
            const tokens = front.tokens();

            assert(position < tokens.len);

            if (tokens[position].offset != reference.name.offset) return null;
            return held;
        }

        current = held.parent();
    }

    return null;
}

fn case_type_span_of(bound: *const Bound) ?Span {
    const switched = bound.declaring.parent() orelse return null;
    var current = bound.reference;

    for (0..frame_depth_max) |_| {
        const enclosing = current.parent() orelse return null;
        const grandparent = enclosing.parent() orelse return null;

        assert(grandparent.index() < enclosing.index());

        if (grandparent.index() == switched.index()) {
            const spelled = current.child_first() orelse return null;

            assert(current.index() > switched.index());

            return spelled.span();
        }

        current = enclosing;
    }

    return null;
}

fn container_name_of(front: *const Front, node: View, source: []const u8) ?Span {
    assert(node.category() == .@"struct");
    assert(front.source.len == source.len);

    if (node.as_container()) |container| {
        if (container.name_token()) |name| {
            assert(name < front.tokens().len);

            return front.tokens()[name].span();
        }
    }

    if (this_alias_of(front, node, source)) |name| return name;
    return header_name_of(front, node, source);
}

fn container_of(front: *const Front, node: View, function: FunctionView, source: []const u8) ?Span {
    assert(function.view.index() == node.index());
    assert(front.source.len == source.len);

    if (function.receiver()) |receiver| {
        if (name_last_in(front, receiver.span(), source)) |name| {
            if (!receives_itself(name.text(source))) return name;
        }
    }

    var current = node;

    for (0..frame_depth_max) |_| {
        const parent = current.parent() orelse return null;

        assert(parent.index() < current.index());

        if (parent.category() == .@"struct") {
            if (container_name_of(front, parent, source)) |name| return name;
        }

        current = parent;
    }

    return null;
}

fn declaring_view_of(front: *const Front, name: Span) ?Bound {
    assert(name.end() <= front.source.len);

    const bindings = front.bindings();
    const index = bindings.reference_bound_named(name) orelse return null;
    const reference = bindings.reference_at(index);

    assert(reference.name.offset == name.offset);
    assert(reference.resolution == .bound);

    const binding = bindings.at(reference.resolution.bound);
    const declared = front.view(binding.node) orelse return null;
    const referenced = front.view(reference.node) orelse return null;

    assert(declared.index() == binding.node);
    assert(referenced.index() == reference.node);

    return .{
        .declaring = declared.declaring_of(),
        .name = binding.name,
        .reference = referenced,
    };
}

fn edge_less(context: void, left: Calls.Edge, right: Calls.Edge) bool {
    _ = context;
    assert(left.call.length > 0);
    assert(right.call.length > 0);

    if (left.source != right.source) return left.source < right.source;
    if (left.call.offset != right.call.offset) return left.call.offset < right.call.offset;
    return left.target < right.target;
}

fn name_first_in(front: *const Front, span: Span, source: []const u8) ?Span {
    var previous: ?Token = null;

    assert(span.end() <= source.len);

    for (tokens_from(front.tokens(), span.offset)) |token| {
        if (token.offset >= span.end()) break;

        const quoted = if (previous) |held| std.mem.eql(u8, held.text(source), "'") else false;

        previous = token;

        assert(token.offset >= span.offset);

        if (spells_a_name(token, quoted, source)) return token.span();
    }

    return null;
}

fn function_view_of(front: *const Front, index: u32, binding: *const Binding) ?View {
    assert(index < front.bindings().count());

    const named = front.view(binding.node) orelse return null;
    const held = named.declaring_of();
    if (held.as_function() != null) return held;

    if (held.as_declaration()) |declaration| {
        if (declaration.value()) |value| {
            if (value.as_function() != null) return value;
        }
    }

    if (assigned_function_of(front, index)) |assigned| return assigned;

    const owner = owner_of(held) orelse return null;
    const function = owner.as_function() orelse return null;
    const position = function.name_token() orelse return null;
    const tokens = front.tokens();

    assert(position < tokens.len);
    assert(owner.index() < held.index());

    if (tokens[position].offset != binding.name.offset) return null;
    return owner;
}

fn header_name_of(front: *const Front, node: View, source: []const u8) ?Span {
    assert(node.index() < front.node_count());

    const span = node.span();
    var first: ?Span = null;
    var implements = false;
    var previous: ?Token = null;

    assert(span.end() <= source.len);

    for (tokens_from(front.tokens(), span.offset)) |token| {
        if (token.offset >= span.end()) break;
        if (token.kind == .block_start) break;

        const quoted = if (previous) |held| std.mem.eql(u8, held.text(source), "'") else false;

        previous = token;

        if (token.is_keyword(.loop)) {
            if (std.mem.eql(u8, token.text(source), "for")) {
                implements = true;
                first = null;

                continue;
            }
        }

        if (first == null) {
            if (spells_a_name(token, quoted, source)) {
                first = token.span();

                if (implements) return first;
            }
        }
    }

    if (first) |name| assert(name.offset >= span.offset);

    return first;
}

fn is_bare_path(text: []const u8) bool {
    if (text.len == 0) return false;

    const leading = std.ascii.isAlphabetic(text[0]) or text[0] == '_';
    if (!leading) return false;

    for (text) |byte| {
        const allowed = std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '.' or byte == ':';
        if (!allowed) return false;
    }

    return true;
}

fn is_comptime(function: FunctionView, source: []const u8, spelled: []const u8) bool {
    assert(spelled.len <= source.len);

    if (std.mem.eql(u8, scan.trim_ascii(spelled), "type")) return true;
    assert(function.view.index() < function.view.node_count());

    var parameters = function.parameters();

    for (0..parameter_count_max + 1) |_| {
        const parameter = parameters.next() orelse return false;
        const span = parameter.type_span orelse continue;

        assert(span.end() <= source.len);

        if (std.mem.eql(u8, scan.trim_ascii(span.text(source)), "type")) return true;
    }

    return false;
}

fn iterable_of(held: View) ?View {
    assert(held.category() == .loop);

    var children = held.children();
    var found: ?View = null;

    for (0..child_count_max) |_| {
        const child = children.next() orelse break;
        if (child.category() == .block) break;

        found = child;
    }

    if (found) |child| assert(child.index() > held.index());

    return found;
}

fn name_last_in(front: *const Front, span: Span, source: []const u8) ?Span {
    var found: ?Span = null;
    var previous: ?Token = null;

    assert(span.end() <= source.len);

    for (tokens_from(front.tokens(), span.offset)) |token| {
        if (token.offset >= span.end()) break;

        const quoted = if (previous) |held| std.mem.eql(u8, held.text(source), "'") else false;

        previous = token;

        if (spells_a_name(token, quoted, source)) found = token.span();
    }

    if (found) |name| assert(name.end() <= span.end());

    return found;
}

fn names_a_type_of_itself(spelled: []const u8) bool {
    assert(spelled.len <= std.math.maxInt(u32));

    const text = scan.trim_ascii(spelled);

    assert(text.len <= spelled.len);
    if (text.len > 0) assert(!scan.is_ascii_whitespace(text[0]));

    return scan.word_in(&.{ "Self", "cls" }, text);
}

fn node_less(functions: []const Calls.Function, left: u32, right: u32) bool {
    assert(left < functions.len);
    assert(right < functions.len);

    const left_node = functions[left].node;
    const right_node = functions[right].node;
    if (left_node != right_node) return left_node < right_node;
    return left < right;
}

fn owner_of(view: View) ?View {
    assert(view.index() < view.node_count());

    var current = view.parent();

    for (0..frame_depth_max) |_| {
        const held = current orelse return null;
        const category = held.category();

        assert(held.index() < view.index());

        const owns = category == .function or category == .lambda;

        if (owns) {
            assert(held.as_function() != null);

            return held;
        }

        current = held.parent();
    }

    return null;
}

fn parameter_end_of(front: *const Front, from: u32) u32 {
    assert(from <= front.source.len);

    var depth: u32 = 0;

    for (tokens_from(front.tokens(), from)) |token| {
        assert(token.offset >= from);

        const punctuation = switch (token.kind) {
            .punctuation => |held| held,
            else => continue,
        };

        switch (punctuation) {
            .bracket_open, .paren_open => depth += 1,
            .bracket_close => depth -|= 1,
            .paren_close => {
                if (depth == 0) return token.offset;

                depth -= 1;
            },
            .comma => {
                if (depth == 0) return token.offset;
            },
            else => {},
        }
    }

    assert(depth <= front.tokens().len);

    return std.math.maxInt(u32);
}

fn parameter_type_span_of(front: *const Front, bound: *const Bound) ?Span {
    const limit = parameter_end_of(front, bound.name.end());
    var children = bound.declaring.children();

    assert(bound.declaring.category() == .parameters);
    assert(limit >= bound.name.end());

    for (0..child_count_max) |_| {
        const child = children.next() orelse return null;
        const offset = child.span().offset;
        if (offset < bound.name.end()) continue;
        if (offset >= limit) continue;
        return child.span();
    }

    return null;
}

fn receives_itself(receiver: []const u8) bool {
    assert(receiver.len <= std.math.maxInt(u32));

    const text = scan.trim_ascii(receiver);
    const stripped = if (std.mem.startsWith(u8, text, "&")) text[1..] else text;
    const bare = std.mem.trimStart(u8, stripped, scan.ascii_whitespace);

    assert(text.len <= receiver.len);
    assert(bare.len <= text.len);

    return scan.word_in(&.{ "self", "Self", "cls", "this" }, bare);
}

fn returns_something(statement: View, source: []const u8, nothing_words: []const []const u8) bool {
    assert(statement.category() == .@"return");
    assert(source.len <= std.math.maxInt(u32));
    assert(nothing_words.len <= std.math.maxInt(u32));

    var children = statement.children();
    const first = children.next() orelse return false;

    if (children.next() != null) return true;

    const text = scan.trim_ascii(first.span().text(source));

    for (nothing_words) |word| {
        assert(word.len > 0);

        if (std.mem.eql(u8, text, word)) return false;
    }

    return true;
}

fn spelled_of(source: []const u8, span: Span) []const u8 {
    assert(span.end() <= source.len);

    const text = scan.trim_ascii(span.text(source));
    var stripped = text;

    if (std.mem.startsWith(u8, text, "->")) {
        stripped = text[2..];
    } else if (std.mem.startsWith(u8, text, ":")) {
        stripped = text[1..];
    } else {}

    const spelled = scan.trim_ascii(stripped);

    assert(spelled.len <= span.length);

    return spelled;
}

fn spells_a_name(token: Token, quoted: bool, source: []const u8) bool {
    assert(token.end() <= source.len);

    if (token.kind != .identifier) return false;
    if (quoted) return false;
    return !std.mem.eql(u8, token.text(source), "'");
}

fn spells_an_index(spelled: []const u8) bool {
    assert(spelled.len <= std.math.maxInt(u32));

    return std.mem.findScalar(u8, spelled, '[') != null;
}

fn this_alias_of(front: *const Front, node: View, source: []const u8) ?Span {
    assert(front.source.len == source.len);
    assert(node.index() < front.node_count());

    const container = node.as_container() orelse return null;
    var members = container.body().children();

    assert(node.category() == .@"struct");

    for (0..child_count_max) |_| {
        const member = members.next() orelse return null;
        const declaration = member.as_declaration() orelse continue;
        const value = declaration.value() orelse continue;
        if (!std.mem.eql(u8, scan.trim_ascii(value.span().text(source)), "@This()")) continue;

        const name = member.name_token() orelse return null;

        assert(name < front.tokens().len);

        return front.tokens()[name].span();
    }

    return null;
}

fn tokens_from(tokens: []const Token, offset: u32) []const Token {
    assert(tokens.len <= std.math.maxInt(u32));
    assert(offset < std.math.maxInt(u32));

    const first = stream.index_starting_from(Token, tokens, offset);

    assert(first <= tokens.len);
    if (first < tokens.len) assert(tokens[first].offset >= offset);

    return tokens[first..];
}

fn type_span_of(front: *const Front, bound: *const Bound) ?Span {
    const declaring = bound.declaring;

    assert(std.meta.activeTag(bound.declaring) == std.meta.activeTag(bound.reference));

    if (declaring.category() == .assignment) {
        if (declaring.parent()) |parent| {
            if (parent.category() == .match) return case_type_span_of(bound);
        }
    }

    if (declaring.category() == .parameters) return parameter_type_span_of(front, bound);
    if (declaring.type_of()) |spelled| return spelled.span();

    const declaration = declaring.as_declaration() orelse return null;
    const value = declaration.value() orelse return null;

    assert(value.index() > declaring.index());

    if (value.as_container() != null) return bound.name;
    return value.span();
}

fn walk_head_of(tokens: []const Token, span: Span, source: []const u8) ?Head {
    assert(tokens.len <= std.math.maxInt(u32));
    assert(span.end() <= source.len);

    const first = stream.index_starting_from(Token, tokens, span.offset);

    assert(first <= tokens.len);

    for (tokens[first..], first..) |token, position| {
        if (token.offset >= span.end()) return null;
        if (token.is_punctuation(.bracket_open)) return null;
        if (token.is_punctuation(.paren_open)) return null;

        const itself = receives_itself(token.text(source));
        const qualifies = token.kind == .identifier or itself;

        if (qualifies) {
            return .{ .itself = itself, .name = token.span(), .position = @intCast(position) };
        }
    }

    return null;
}

const Built = struct {
    front: Front,
    scratch: Scratch,
    tables: Calls,

    fn init(
        built: *Built,
        language: Language,
        source: []const u8,
        returns: *const Calls.Returns,
    ) !void {
        const gpa = std.testing.allocator;

        assert(source.len <= std.math.maxInt(u32));
        assert(language != .css);

        try built.scratch.init(gpa, &capacity_test, .initOne(language));
        errdefer built.scratch.deinit(gpa);

        try built.front.init(gpa, &capacity_test, language);
        errdefer built.front.deinit(gpa);

        try built.front.parse(&built.scratch, .of(language), source, &options_test);

        try built.tables.init(gpa, capacity_tables_test);
        built.tables.build(&built.front, returns);
    }

    fn deinit(built: *Built) void {
        const gpa = std.testing.allocator;

        assert(built.front.outcome.? == .complete);
        assert(built.tables.rows.count() <= capacity_tables_test.function_count_max);

        built.tables.deinit(gpa);
        built.front.deinit(gpa);
        built.scratch.deinit(gpa);
        built.* = undefined;
    }
};

const capacity_test: FrontCapacity = .{
    .diagnostic_count_max = 1 << 6,
    .event_count_max = 1 << 14,
    .node_count_max = 1 << 12,
    .semantic = .{
        .binding_count_max = 1 << 10,
        .fact_count_max = 1 << 8,
        .reference_count_max = 1 << 10,
        .scope_count_max = 1 << 8,
    },
    .tag_count_max = 1 << 8,
    .token_count_max = 1 << 12,
};

const options_test: Options = .{
    .globals = &.{},
    .python_version = .py310,
    .vocabulary = .empty,
};

const returns_test: Calls.Returns = .{
    .nothing_words = &.{"None"},
    .optional_markers = &.{ "Option<", "Result<" },
    .spelled = true,
};

const capacity_tables_test: Calls.Capacity = .{ .edge_count_max = 256, .function_count_max = 64 };

test Calls {
    const gpa = std.testing.allocator;
    const source = "fn helper() -> u32 {\n    1\n}\n\nfn open() -> u32 {\n    helper()\n}\n";
    var scratch: Scratch = undefined;

    try scratch.init(gpa, &capacity_test, .initOne(.rust));
    defer scratch.deinit(gpa);

    var front: Front = undefined;

    try front.init(gpa, &capacity_test, .rust);
    defer front.deinit(gpa);

    try front.parse(&scratch, .of(.rust), source, &.{});

    var calls: Calls = undefined;

    try calls.init(gpa, .{ .edge_count_max = 16, .function_count_max = 16 });
    defer calls.deinit(gpa);

    calls.build(&front, &returns_test);

    const open = calls.function_of("open").?;
    const edges = calls.edges_of(open);
    const target = calls.functions()[edges[0].target];

    try std.testing.expectEqual(2, calls.functions().len);
    try std.testing.expectEqual(1, edges.len);
    try std.testing.expectEqualStrings("helper", target.name.text(source));
}

test "every function and method takes a row" {
    var built: Built = undefined;

    try built.init(.rust, source_rust_test, &returns_test);
    defer built.deinit();

    const tables = &built.tables;
    const functions = tables.functions();
    const expected = [_][]const u8{ "helper", "open", "other", "quiet", "run" };
    var names: [expected.len][]const u8 = undefined;

    try std.testing.expectEqual(expected.len, functions.len);

    for (functions, 0..) |*function, index| names[index] = function.name.text(source_rust_test);

    std.mem.sort([]const u8, &names, {}, text_less);

    for (expected, names) |wanted, name| try std.testing.expectEqualStrings(wanted, name);

    const open = tables.function_of("open").?;

    try std.testing.expectEqualStrings("Port", open.container.?.text(source_rust_test));
    try std.testing.expect(open.fallible);
    try std.testing.expect(open.value);

    const quiet = tables.function_of("quiet").?;

    try std.testing.expect(!quiet.fallible);
    try std.testing.expect(!quiet.value);
    try std.testing.expectEqual(null, tables.function_of("missing"));
}

test "a call becomes an edge from the caller to the callee" {
    var built: Built = undefined;

    try built.init(.rust, source_rust_test, &returns_test);
    defer built.deinit();

    const tables = &built.tables;
    const open = tables.function_of("open").?;
    const edges = tables.edges_of(open);
    const target = tables.functions()[edges[0].target];

    try std.testing.expectEqual(1, edges.len);
    try std.testing.expectEqualStrings("helper", target.name.text(source_rust_test));
    try std.testing.expectEqualStrings("helper()", edges[0].call.text(source_rust_test));
}

test "a method call through a field resolves by the field type" {
    var built: Built = undefined;

    try built.init(.rust, source_rust_test, &returns_test);
    defer built.deinit();

    const tables = &built.tables;
    const run = tables.function_of("run").?;
    const edges = tables.edges_of(run);
    const target = tables.functions()[edges[0].target];

    try std.testing.expectEqual(1, edges.len);
    try std.testing.expectEqualStrings("open", target.name.text(source_rust_test));
    try std.testing.expect(tables.method_of("Port", "open") != null);
    try std.testing.expectEqual(null, tables.method_of("Server", "open"));
}

test "a cycle marks every member recursive" {
    var built: Built = undefined;

    try built.init(.rust, source_rust_test, &returns_test);
    defer built.deinit();

    const tables = &built.tables;

    for ([_][]const u8{ "helper", "other" }) |name| {
        try std.testing.expect(tables.function_of(name).?.recursive);
    }

    for ([_][]const u8{ "open", "run", "quiet" }) |name| {
        try std.testing.expect(!tables.function_of(name).?.recursive);
    }
}

test "value of answers by the spelled return or the returned value" {
    var built: Built = undefined;

    try built.init(.rust, source_rust_test, &returns_test);
    defer built.deinit();

    try std.testing.expectEqual(true, built.tables.value_of("run"));
    try std.testing.expectEqual(false, built.tables.value_of("quiet"));
    try std.testing.expectEqual(null, built.tables.value_of("missing"));

    const unspelled: Calls.Returns = .{
        .nothing_words = &.{"None"},
        .optional_markers = &.{},
        .spelled = false,
    };

    var python: Built = undefined;

    try python.init(.python, source_python_test, &unspelled);
    defer python.deinit();

    try std.testing.expectEqual(true, python.tables.value_of("gives"));
    try std.testing.expectEqual(false, python.tables.value_of("gives_nothing"));
    try std.testing.expectEqual(false, python.tables.value_of("quiet"));
}

test "an alias names the path it stands for" {
    const source = "const held = std.mem;\nconst count = 4;\n\nfn run() void {}\n";
    var built: Built = undefined;

    try built.init(.zig, source, &returns_test);
    defer built.deinit();

    const target = built.tables.alias_of("held").?;

    try std.testing.expectEqualStrings("std.mem", target.text(source));
    try std.testing.expectEqual(null, built.tables.alias_of("count"));
}

test "a class method called through this closes a cycle" {
    const source = "class Walker {\n    walk(node) {\n        return this.helper(node);\n" ++
        "    }\n\n    helper(node) {\n        return this.walk(node);\n    }\n}\n";

    var built: Built = undefined;

    try built.init(.javascript, source, &returns_test);
    defer built.deinit();

    for ([_][]const u8{ "walk", "helper" }) |name| {
        try std.testing.expect(built.tables.method_of("Walker", name).?.recursive);
    }
}

test "a lambda bound to a name is a function of that name" {
    const source = "const arrow = (d) => arrow(d - 1);\n\nconst viaConst = function (d) {\n" ++
        "    return viaConst(d - 1);\n};\n\nconst count = 4;\n";

    var built: Built = undefined;

    try built.init(.javascript, source, &returns_test);
    defer built.deinit();

    for ([_][]const u8{ "arrow", "viaConst" }) |name| {
        try std.testing.expect(built.tables.function_of(name).?.recursive);
    }

    try std.testing.expectEqual(null, built.tables.function_of("count"));
}

test "a variable assigned a function literal is a function of that name" {
    const source = "package main\n\nfunc run() int {\n    var inner func(int) int\n" ++
        "    inner = func(d int) int {\n        return inner(d - 1)\n    }\n" ++
        "    return inner(3)\n}\n";

    var built: Built = undefined;

    try built.init(.go, source, &returns_test);
    defer built.deinit();

    const inner = built.tables.function_of("inner").?;
    const run = built.tables.function_of("run").?;

    try std.testing.expect(inner.recursive);
    try std.testing.expect(!run.recursive);
}

test "a call through a local container resolves to its member" {
    const source = "const S = struct {\n    fn step(d: u32) u32 {\n" ++
        "        return viaStruct(d - 1);\n    }\n};\n\n" ++
        "fn viaStruct(d: u32) u32 {\n    return S.step(d);\n}\n";

    var built: Built = undefined;

    try built.init(.zig, source, &returns_test);
    defer built.deinit();

    const outer = built.tables.function_of("viaStruct").?;
    const step = built.tables.method_of("S", "step").?;

    try std.testing.expect(outer.recursive);
    try std.testing.expect(step.recursive);
}

test "a fallible return is read from the markers" {
    try std.testing.expect(is_fallible("Result<(), Error>", &.{"Result<"}));
    try std.testing.expect(is_fallible("error", &.{}));
    try std.testing.expect(is_fallible("?u32", &.{"?"}));
    try std.testing.expect(!is_fallible("u32", &.{"Result<"}));
    try std.testing.expect(!is_fallible("", &.{"Result<"}));
    try std.testing.expect(Calls.is_value("u32"));
    try std.testing.expect(!Calls.is_value("void"));
    try std.testing.expect(!Calls.is_value(""));
}

fn text_less(context: void, left: []const u8, right: []const u8) bool {
    _ = context;
    assert(left.len <= std.math.maxInt(u32));
    assert(right.len <= std.math.maxInt(u32));

    return std.mem.order(u8, left, right) == .lt;
}

const source_python_test = "def gives():\n    return 1\n\n\ndef gives_nothing():\n" ++
    "    return None\n\n\ndef quiet():\n    pass\n";

const source_rust_test = "struct Server {\n    port: Port,\n}\n\n" ++
    "struct Port {\n    value: u16,\n}\n\n" ++
    "impl Port {\n    fn open(&self) -> Result<(), Error> {\n        helper();\n\n" ++
    "        Ok(())\n    }\n}\n\nfn helper() {\n    other();\n}\n\n" ++
    "fn other() {\n    helper();\n}\n\nfn run(server: &Server) -> u32 {\n" ++
    "    server.port.open();\n\n    1\n}\n\nfn quiet() {}\n";
