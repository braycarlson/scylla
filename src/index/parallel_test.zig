const std = @import("std");
const assert = std.debug.assert;
const Diagnostics = @import("../lint/diagnostics.zig");
const FileID = @import("../stdx/file_id.zig").FileID;
const Graph = @import("graph.zig");
const Language = @import("../syntax/language.zig").Language;
const Random = @import("../testing/random.zig");
const Severity = @import("../lint/diagnostics.zig").Severity;
const Span = @import("../stdx/bounded/span.zig");
const Store = @import("store.zig");
const Structure = @import("../syntax/tree.zig").Structure;
const Diagnostic = @import("../syntax/diagnostic.zig").Diagnostic;
const hash_of = std.hash.Fnv1a_64.hash;
const environment = @import("../testing/environment.zig");
const resolve = @import("resolve.zig");
const view = @import("view.zig");

const Finding = struct {
    code: []const u8,
    file: u32,
    offset: u32,

    fn less(context: void, left: Finding, right: Finding) bool {
        _ = context;
        assert(left.code.len <= std.math.maxInt(u32));
        assert(right.code.len <= std.math.maxInt(u32));

        if (left.file != right.file) return left.file < right.file;

        const order = std.mem.order(u8, left.code, right.code);
        if (order != .eq) return order == .lt;
        return left.offset < right.offset;
    }
};

const Worker = struct {
    diagnostics: Diagnostics,
    failed: bool,
    files: std.ArrayList(FileID),
    found: std.ArrayList(Finding),
    graph: *const Graph,
    store: *const Store,

    fn run(worker: *Worker) void {
        assert(worker.found.items.len == 0);

        for (worker.files.items) |file| {
            worker.diagnostics.clear();

            rule_run(worker.store, worker.graph, file, &worker.diagnostics) catch {
                worker.failed = true;

                return;
            };

            for (worker.diagnostics.slice()) |held| {
                if (worker.found.unusedCapacitySlice().len == 0) {
                    worker.failed = true;

                    return;
                }

                worker.found.appendAssumeCapacity(.{
                    .code = held.code,
                    .file = file.index(),
                    .offset = held.span.offset,
                });
            }
        }
    }
};

const Builder = struct {
    builds: *const Store.PendingBuilds,
    scratch: Store.BuildScratch,
    worker: u32,

    fn run(builder: *Builder) void {
        const total = builder.builds.count();
        var at = builder.worker;

        assert(builder.worker < thread_count);

        for (0..total) |_| {
            if (at >= total) break;

            builder.builds.build(at, &builder.scratch);
            at += thread_count;
        }
    }
};

const Resolver = struct {
    pub fn resolve(
        resolver: *const Resolver,
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

const file_count: u32 = 24;
const round_count_default: u32 = 256;
const seed_churn: u64 = 0x51A9_C3F7_20E4_86BD;
const soup_lengths = [_]u32{ 0, 1, 7, 64, 1_024 };
const thread_count: u32 = 4;
const finding_count_max: u32 = 1 << 12;
const diagnostic_bytes_max: u32 = 1 << 12;
const key_count: u32 = 16;
const source_bytes_max: u32 = 128;
const walk_step_max: u32 = 1 << 16;
const languages = [_]Language{ .css, .go, .javascript, .markup, .python, .rust };
const read_count = Store.count;
const read_css_semantic = Store.css_semantic;
const read_moves = Store.moves_count;
const read_bindings = Store.bindings_of;
const read_declaration = Store.declaration_of;
const read_diagnostics = Store.diagnostics_of;
const read_facts = Store.facts_of;
const read_files = Store.files;
const read_find = Store.find;
const read_forward = Store.forward_of;
const read_front = Store.front_of;
const read_generation = Store.generation_of;
const read_go_semantic = Store.go_semantic;
const read_has_errors = Store.has_errors_of;
const read_hash = Store.hash_of_file;
const read_is_pending = Store.is_pending;
const read_javascript_semantic = Store.javascript_semantic;
const read_language = Store.language_of;
const read_limits = Store.limits_of;
const read_lines = Store.lines_of;
const read_markup_errors = Store.markup_errors_of;
const read_markup_tokens = Store.markup_tokens_of;
const read_markup_tree = Store.markup_tree_of;
const read_odin_semantic = Store.odin_semantic;
const read_path_hash = Store.path_hash_of;
const read_pending_count = Store.pending_count;
const read_python_checks = Store.python_checks_of;
const read_python_semantic = Store.python_semantic;
const read_rebuilds = Store.rebuilds_of;
const read_resident = Store.resident;
const read_rust_semantic = Store.rust_semantic;
const read_sequence = Store.sequence_of;
const read_slot_bytes = Store.slot_bytes_of;
const read_slot_language = Store.slot_language_of;
const read_slot_resident = Store.slot_resident;
const read_source = Store.source_of;
const read_structure = Store.structure_of;
const read_tokens = Store.tokens_of;
const read_zig_semantic = Store.zig_semantic;
const read_view = @import("view.zig").view_of;
const read_css_view = view.css;
const read_go_view = view.go;
const read_javascript_view = view.javascript;
const read_markup_view = view.markup;
const read_odin_view = view.odin;
const read_python_view = view.python;
const read_rust_view = view.rust;
const read_walk = view.walk;
const read_walk_from = view.walk_from;
const read_zig_view = view.zig;
const graph_count = Graph.count;
const graph_current = Graph.current;
const graph_cycles = Graph.cycles;
const graph_dependents = Graph.dependents_of;
const graph_edges = Graph.edges_of;
const graph_generation = Graph.generation_of;
const graph_order = Graph.order;

fn limits_of(file_count_max: u32) Store.Limits {
    assert(file_count_max < std.math.maxInt(u32));

    var slots: [Language.count][Store.class_count]u32 = @splat(@splat(0));

    for (languages) |language| {
        slots[@backingInt(language)][Store.Limits.class_of(4_096)] = file_count_max;
    }

    return .{
        .file_count_max = file_count_max * @as(u32, languages.len),
        .front = .{
            .diagnostic_count_max = 64,
            .event_count_max = 4_096,
            .node_count_max = 2_048,
            .semantic = .{
                .binding_count_max = 256,
                .fact_count_max = 256,
                .reference_count_max = 256,
                .scope_count_max = 64,
            },
            .tag_count_max = 256,
            .token_count_max = 1_024,
        },
        .line_count_max = 256,
        .slots = slots,
        .source_bytes_max = 4_096,
    };
}

fn source_of(buffer: []u8, index: u32) ![]const u8 {
    assert(index < file_count);
    assert(buffer.len <= std.math.maxInt(u32));

    if (index == 0) {
        return std.mem.print(buffer, "value{d} = {d}\n\n\ndef run():\n    return 1\n", .{
            index,
            index,
        });
    }

    const template = "import m{d:0>2}\nvalue{d} = {d}\n\n\ndef run():\n    return 1\n";
    return std.mem.print(buffer, template, .{ index - 1, index, index });
}

fn key_of(buffer: []u8, index: u32) ![]const u8 {
    assert(index < file_count);
    assert(buffer.len <= std.math.maxInt(u32));

    return std.mem.print(buffer, "m{d:0>2}", .{index});
}

fn project_init(store: *Store, graph: *Graph, gpa: std.mem.Allocator) !void {
    const limits = limits_of(file_count);

    try store.init(gpa, &limits, .reject);
    errdefer store.deinit(gpa);

    for (0..file_count) |index| {
        var key_buffer: [8]u8 = undefined;
        var source_buffer: [source_bytes_max]u8 = undefined;
        const key = try key_of(&key_buffer, @intCast(index));
        const source = try source_of(&source_buffer, @intCast(index));

        _ = try store.insert(hash_of(key), .of(.python), source);
    }

    graph.* = try .init(gpa, 256, limits.file_count_max);
    errdefer graph.deinit(gpa);

    try graph.build(store, Resolver, &.{});
}

fn recorded(diagnostics: *Diagnostics, code: []const u8, severity: Severity, span: Span) !void {
    assert(code.len > 0);

    try diagnostics.push(.{
        .code = code,
        .fix = null,
        .message = .{ .static = "a recorded finding" },
        .related_count = 0,
        .related_start = 0,
        .rule = null,
        .severity = severity,
        .span = span,
    });
}

fn rule_run(store: *const Store, graph: *const Graph, file: FileID, out: *Diagnostics) !void {
    assert(@backingInt(file) != std.math.maxInt(u32));

    var walk = view.walk(store, file);

    for (0..walk_step_max) |_| {
        const step = walk.next() orelse break;

        const node = switch (step) {
            .enter => |held| held,
            .leave => continue,
        };

        const held = view.python(store, file, node) orelse continue;

        try recorded(out, "PAR001", .hint, held.span());
    }

    const index = file.index();
    if (index == 0) return;

    var name_buffer: [16]u8 = undefined;
    const name = try std.mem.print(&name_buffer, "value{d}", .{index - 1});

    const code: []const u8 = switch (resolve.target_of(store, graph, file, name)) {
        .binding => "PAR010",
        .maybe => "PAR011",
        .missing => "PAR012",
        .unresolved => "PAR013",
    };

    try recorded(out, code, .warning, .{ .length = 1, .offset = index });
}

fn files_of(gpa: std.mem.Allocator, store: *const Store) !std.ArrayList(FileID) {
    var found: std.ArrayList(FileID) = .empty;
    errdefer found.deinit(gpa);

    var files = store.files();

    for (0..store.limits.file_count_max) |_| {
        const file = files.next() orelse break;

        try found.append(gpa, file);
    }

    return found;
}

fn baseline(
    gpa: std.mem.Allocator,
    store: *const Store,
    graph: *const Graph,
    files: []const FileID,
) !std.ArrayList(Finding) {
    assert(files.len <= std.math.maxInt(u32));

    var found: std.ArrayList(Finding) = .empty;
    errdefer found.deinit(gpa);

    var held: Diagnostics = try .init(gpa, .{
        .related_count_max = finding_count_max,
        .row_count_max = finding_count_max,
        .text_bytes_max = diagnostic_bytes_max,
    });

    defer held.deinit(gpa);

    for (files) |file| {
        held.clear();
        try rule_run(store, graph, file, &held);

        for (held.slice()) |diagnostic| {
            try found.append(gpa, .{
                .code = diagnostic.code,
                .file = file.index(),
                .offset = diagnostic.span.offset,
            });
        }
    }

    std.mem.sortUnstable(Finding, found.items, {}, Finding.less);

    return found;
}

fn merged(
    gpa: std.mem.Allocator,
    store: *const Store,
    graph: *const Graph,
    files: []const FileID,
    stride: u32,
) !std.ArrayList(Finding) {
    assert(files.len <= std.math.maxInt(u32));
    assert(stride < std.math.maxInt(u32));

    var workers: [thread_count]Worker = undefined;
    var ready: u32 = 0;
    defer for (workers[0..ready]) |*worker| {
        worker.found.deinit(gpa);
        worker.files.deinit(gpa);
        worker.diagnostics.deinit(gpa);
    };

    for (&workers) |*worker| {
        worker.diagnostics = try .init(gpa, .{
            .related_count_max = finding_count_max,
            .row_count_max = finding_count_max,
            .text_bytes_max = diagnostic_bytes_max,
        });

        worker.failed = false;
        worker.files = .empty;
        worker.found = .empty;
        worker.graph = graph;
        worker.store = store;
        ready += 1;

        try worker.found.ensureTotalCapacity(gpa, finding_count_max);
    }

    for (files, 0..) |file, position| {
        const spread = position * thread_count / files.len;
        const shard = if (stride == 0) spread else position % thread_count;

        try workers[shard].files.append(gpa, file);
    }

    try workers_run(&workers);

    return merged_collect(gpa, &workers);
}

fn workers_run(workers: *[thread_count]Worker) !void {
    var threads: [thread_count]std.Thread = undefined;
    var spawned: u32 = 0;
    defer for (threads[0..spawned]) |thread| thread.join();

    for (workers) |*worker| {
        threads[spawned] = try std.Thread.spawn(.{}, Worker.run, .{worker});
        spawned += 1;
    }

    assert(spawned == thread_count);
}

fn merged_collect(gpa: std.mem.Allocator, workers: *[thread_count]Worker) !std.ArrayList(Finding) {
    var found: std.ArrayList(Finding) = .empty;
    errdefer found.deinit(gpa);

    for (workers) |*worker| {
        try std.testing.expect(!worker.failed);
        try found.appendSlice(gpa, worker.found.items);
    }

    std.mem.sortUnstable(Finding, found.items, {}, Finding.less);

    return found;
}

fn expect_findings_equal(expected: []const Finding, actual: []const Finding) !void {
    try std.testing.expectEqual(expected.len, actual.len);

    for (expected, actual) |left, right| {
        try std.testing.expectEqualStrings(left.code, right.code);
        try std.testing.expectEqual(left.file, right.file);
        try std.testing.expectEqual(left.offset, right.offset);
    }
}

fn rounds() !u32 {
    var held_bytes: [environment.value_bytes_max]u8 = undefined;

    const held = environment.get("SCYLLA_ADVERSARIAL", &held_bytes) orelse {
        return round_count_default;
    };

    return std.fmt.parseInt(u32, held, 10);
}

fn soup(random: *Random, buffer: []u8) []const u8 {
    const length = soup_lengths[random.below(soup_lengths.len)];

    assert(length <= buffer.len);

    for (buffer[0..length]) |*byte| byte.* = @intCast(random.below(256));

    return buffer[0..length];
}

fn findable(store: *const Store, keys: []const [3]u8) u32 {
    assert(keys.len <= std.math.maxInt(u32));

    var found: u32 = 0;

    for (keys) |*key| {
        if (store.find(hash_of(key)) != null) found += 1;
    }

    assert(found <= keys.len);

    return found;
}

fn churn(gpa: std.mem.Allocator, eviction: Store.Eviction) !void {
    const limits = limits_of(4);
    var store: Store = undefined;

    try store.init(gpa, &limits, eviction);
    defer store.deinit(gpa);

    var random: Random = .init(seed_churn ^ @as(u64, @intFromBool(eviction == .reject)));
    var keys: [key_count][3]u8 = undefined;

    for (&keys, 0..) |*key, index| _ = try std.mem.print(key, "f{d:0>2}", .{index});

    const round_count_total = try rounds();

    for (0..round_count_total) |round| {
        try churn_round(&store, &random, &keys, round);
    }

    store.clear();

    try std.testing.expectEqual(0, store.count());
}

fn churn_round(store: *Store, random: *Random, keys: []const [3]u8, round: usize) !void {
    assert(keys.len <= std.math.maxInt(u32));

    var buffer: [1_024]u8 = undefined;
    const language = languages[random.below(languages.len)];
    const key = &keys[random.below(key_count)];
    const source = soup(random, &buffer);

    if (store.insert(hash_of(key), .of(language), source)) |index| {
        const file: FileID = .of(index);

        try std.testing.expectEqualSlices(u8, source, store.source_of(file));
        try std.testing.expectEqual(language, store.language_of(file));
        try std.testing.expectEqual(index, store.find(hash_of(key)).?);
    } else |err| switch (err) {
        error.Full, error.TooLarge => {},
    }

    try std.testing.expectEqual(findable(store, keys), store.count());
    try std.testing.expect(store.count() <= store.limits.file_count_max);

    if (round % 8 != 0) return;

    var held: [file_count]FileID = undefined;
    var held_count: u32 = 0;
    var files = store.files();

    for (0..store.limits.file_count_max) |_| {
        const file = files.next() orelse break;

        held[held_count] = file;
        held_count += 1;
    }

    for (held[0..held_count]) |file| store.evict(file);

    try std.testing.expectEqual(0, store.count());
    try std.testing.expectEqual(0, findable(store, keys));
}

fn slot_reads(store: *const Store, held: FileID) !void {
    assert(@backingInt(held) != std.math.maxInt(u32));

    const slot_language = read_slot_language(store, held.index());
    var files = read_files(store);
    var file_total: u32 = 0;

    for (0..file_count + 1) |_| {
        _ = files.next() orelse break;

        file_total += 1;
    }

    try std.testing.expectEqual(file_count, read_count(store));
    try std.testing.expect(read_moves(store) >= file_count);
    try std.testing.expectEqual(0, read_diagnostics(store, held).len);
    try std.testing.expect(!read_has_errors(store, held));
    try std.testing.expectEqual(held.index(), read_find(store, hash_of("m00")).?);
    try std.testing.expect(read_lines(store, held).count() > 0);
    try std.testing.expect(read_source(store, held).len > 0);
    try std.testing.expectEqual(Structure.complete, read_structure(store, held));
    try std.testing.expect(read_tokens(store, held).len > 0);
    try std.testing.expectEqual(file_count, file_total);
    try std.testing.expectEqual(Language.python, read_language(store, held));
    try std.testing.expectEqual(store.limits.file_count_max, read_limits(store).file_count_max);
    try std.testing.expect(read_resident(store, held));
    try std.testing.expect(read_slot_resident(store, held));
    try std.testing.expect(read_hash(store, held) != 0);
    try std.testing.expectEqual(hash_of("m00"), read_path_hash(store, held));
    try std.testing.expectEqual(1, read_generation(store, held));
    try std.testing.expectEqual(1, read_rebuilds(store, held));
    try std.testing.expect(read_sequence(store, held) > 0);
    try std.testing.expect(read_slot_bytes(store, held.index()) >= read_source(store, held).len);
    try std.testing.expectEqual(read_language(store, held), slot_language);
    try std.testing.expectEqual(store.facts_of(held).len, read_facts(store, held).len);
    try std.testing.expectEqual(null, read_declaration(store, held, "missing_name"));
    try std.testing.expectEqual(null, read_forward(store, held, "missing_name"));
    try std.testing.expectEqual(0, read_markup_errors(store, held).len);
    try std.testing.expectEqual(0, read_markup_tokens(store, held).len);
    try std.testing.expectEqual(null, read_markup_tree(store, held));
    try std.testing.expect(read_front(store, held).node_count() > 0);
    try std.testing.expect(read_bindings(store, held) == .python);
}

fn view_reads(store: *const Store, held: FileID) !void {
    assert(@backingInt(held) != std.math.maxInt(u32));

    var walk = read_walk(store, held);
    var walk_from = read_walk_from(store, held, 0);
    const walked = walk.next();
    const walked_from = walk_from.next();

    try std.testing.expect(walked != null);
    try std.testing.expect(walked_from != null);
    try std.testing.expectEqual(0, read_python_checks(store, held).len);
    try std.testing.expect(read_python_semantic(store, held) != null);
    try std.testing.expect(read_python_view(store, held, 0) != null);
    try std.testing.expect(read_view(store, held, 0) != null);
    try std.testing.expect(read_css_semantic(store, held) == null);
    try std.testing.expect(read_css_view(store, held, 0) == null);
    try std.testing.expect(read_go_semantic(store, held) == null);
    try std.testing.expect(read_go_view(store, held, 0) == null);
    try std.testing.expect(read_javascript_semantic(store, held) == null);
    try std.testing.expect(read_javascript_view(store, held, 0) == null);
    try std.testing.expect(read_markup_view(store, held, 0) == null);
    try std.testing.expect(read_odin_semantic(store, held) == null);
    try std.testing.expect(read_odin_view(store, held, 0) == null);
    try std.testing.expect(read_rust_semantic(store, held) == null);
    try std.testing.expect(read_rust_view(store, held, 0) == null);
    try std.testing.expect(read_zig_semantic(store, held) == null);
    try std.testing.expect(read_zig_view(store, held, 0) == null);
}

fn graph_reads(graph: *const Graph, store: *const Store, held: FileID) !void {
    assert(@backingInt(held) != std.math.maxInt(u32));

    var cycles = graph_cycles(graph);
    var dependents = graph_dependents(graph, held);
    var dependents_direct = graph.dependents_of(held);
    const cycle = cycles.next();
    const dependent_total = iterated_count(&dependents);
    const dependent_direct_total = iterated_count(&dependents_direct);

    try std.testing.expectEqual(file_count, graph_order(graph).len);
    try std.testing.expect(graph_count(graph) > 0);
    try std.testing.expect(graph_current(graph, store));
    try std.testing.expect(cycle == null);
    try std.testing.expectEqual(read_generation(store, held), graph_generation(graph, held).?);
    try std.testing.expectEqual(dependent_direct_total, dependent_total);
    try std.testing.expectEqual(graph.edges_of(held).len, graph_edges(graph, held).len);
}

fn iterated_count(iterator: anytype) u32 {
    comptime assert(@typeInfo(@TypeOf(iterator)) == .pointer);

    var total: u32 = 0;

    for (0..walk_step_max) |_| {
        _ = iterator.next() orelse break;

        total += 1;
    }

    assert(total < walk_step_max);

    return total;
}

test "the store is shared across threads and read only" {
    const gpa = std.testing.allocator;
    var store: Store = undefined;
    var graph: Graph = undefined;

    try project_init(&store, &graph, gpa);
    defer store.deinit(gpa);
    defer graph.deinit(gpa);

    var files = try files_of(gpa, &store);
    defer files.deinit(gpa);

    const held = files.items[0];

    try slot_reads(&store, held);
    try view_reads(&store, held);
    try graph_reads(&graph, &store, held);
}

test "every read accessor is named in the table" {
    const gpa = std.testing.allocator;
    const limit: std.Io.Limit = .limited(1 << 20);
    const cwd = std.Io.Dir.cwd();
    const table_path = "src/index/parallel_test.zig";
    const table = try cwd.readFileAlloc(std.testing.io, table_path, gpa, limit);
    defer gpa.free(table);

    var checked: u32 = 0;

    for ([_][]const u8{ "graph", "store", "view" }) |name| {
        var path_buffer: [64]u8 = undefined;
        const path = try std.mem.print(&path_buffer, "src/index/{s}.zig", .{name});
        const source = try cwd.readFileAlloc(std.testing.io, path, gpa, limit);
        defer gpa.free(source);

        checked += try accessors_checked(table, source);
    }

    try std.testing.expect(checked > 30);
}

fn accessors_checked(table: []const u8, source: []const u8) !u32 {
    assert(table.len <= std.math.maxInt(u32));
    assert(source.len <= std.math.maxInt(u32));

    var checked: u32 = 0;
    var lines = std.mem.splitScalar(u8, source, '\n');

    for (0..source.len + 1) |_| {
        const line = lines.next() orelse break;
        const rest = strip_prefix(line, "pub fn ") orelse continue;
        const open = std.mem.findScalar(u8, rest, '(') orelse continue;
        const tail = rest[open + 1 ..];
        const reads_store = std.mem.startsWith(u8, tail, "store: *const Store");
        const reads_graph = std.mem.startsWith(u8, tail, "graph: *const Graph");

        if (!reads_store) {
            if (!reads_graph) continue;
        }

        var pattern_buffer: [64]u8 = undefined;
        const pattern = try std.mem.print(&pattern_buffer, ".{s};", .{rest[0..open]});

        try std.testing.expect(std.mem.find(u8, table, pattern) != null);

        checked += 1;
    }

    return checked;
}

fn strip_prefix(line: []const u8, prefix: []const u8) ?[]const u8 {
    assert(prefix.len > 0);

    if (!std.mem.startsWith(u8, line, prefix)) return null;
    return line[prefix.len..];
}

test "a fan out matches the single threaded run" {
    const gpa = std.testing.allocator;
    var store: Store = undefined;
    var graph: Graph = undefined;

    try project_init(&store, &graph, gpa);
    defer store.deinit(gpa);
    defer graph.deinit(gpa);

    var files = try files_of(gpa, &store);
    defer files.deinit(gpa);

    var single = try baseline(gpa, &store, &graph, files.items);
    defer single.deinit(gpa);

    var fanned = try merged(gpa, &store, &graph, files.items, 0);
    defer fanned.deinit(gpa);

    try expect_findings_equal(single.items, fanned.items);
}

test "a second interleaving reports the same bytes" {
    const gpa = std.testing.allocator;
    var store: Store = undefined;
    var graph: Graph = undefined;

    try project_init(&store, &graph, gpa);
    defer store.deinit(gpa);
    defer graph.deinit(gpa);

    var files = try files_of(gpa, &store);
    defer files.deinit(gpa);

    var first = try merged(gpa, &store, &graph, files.items, 0);
    defer first.deinit(gpa);

    var second = try merged(gpa, &store, &graph, files.items, 1);
    defer second.deinit(gpa);

    try expect_findings_equal(first.items, second.items);
    try std.testing.expect(first.items.len > 0);
}

test "a rejecting store churns without leaking a slot" {
    try churn(std.testing.allocator, .reject);
}

test "an evicting store churns without leaking a slot" {
    try churn(std.testing.allocator, .least_recently_used);
}

test "pending builds run in parallel and match the serial answer" {
    const gpa = std.testing.allocator;
    const limits = limits_of(file_count);
    var serial: Store = undefined;

    try serial.init(gpa, &limits, .reject);
    defer serial.deinit(gpa);

    var parallel: Store = undefined;

    try parallel.init(gpa, &limits, .reject);
    defer parallel.deinit(gpa);

    for (0..file_count) |index| {
        var key_buffer: [8]u8 = undefined;
        var source_buffer: [source_bytes_max]u8 = undefined;
        const key = try key_of(&key_buffer, @intCast(index));
        const source = try source_of(&source_buffer, @intCast(index));
        const built = try serial.insert(hash_of(key), .of(.python), source);
        const placed = try parallel.insert_pending(hash_of(key), .of(.python), source);

        try std.testing.expectEqual(built, placed);
    }

    try std.testing.expectEqual(file_count, parallel.pending_count());
    try builders_run(gpa, &parallel, &limits);
    parallel.pending_clear();

    try std.testing.expectEqual(0, parallel.pending_count());
    try std.testing.expectEqual(0, read_pending_count(&parallel));
    try std.testing.expectEqual(serial.count(), parallel.count());

    for (0..file_count) |index| try twins_match(&serial, &parallel, @intCast(index));
}

fn builders_run(gpa: std.mem.Allocator, store: *Store, limits: *const Store.Limits) !void {
    const builds = store.pending_builds();
    var builders: [thread_count]Builder = undefined;
    var ready: u32 = 0;
    defer for (builders[0..ready]) |*builder| builder.scratch.deinit(gpa);

    for (&builders, 0..) |*builder, worker| {
        try builder.scratch.init(gpa, limits);

        builder.builds = &builds;
        builder.worker = @intCast(worker);
        ready += 1;
    }

    var threads: [thread_count]std.Thread = undefined;
    var spawned: u32 = 0;
    defer for (threads[0..spawned]) |thread| thread.join();

    for (&builders) |*builder| {
        threads[spawned] = try std.Thread.spawn(.{}, Builder.run, .{builder});
        spawned += 1;
    }

    assert(spawned <= thread_count);
}

fn twins_match(serial: *const Store, parallel: *const Store, index: u32) !void {
    assert(index < std.math.maxInt(u32));

    var key_buffer: [8]u8 = undefined;
    const key = try key_of(&key_buffer, index);
    const file: FileID = .of(serial.find(hash_of(key)).?);
    const twin: FileID = .of(parallel.find(hash_of(key)).?);

    try std.testing.expect(!read_is_pending(parallel, twin));
    try std.testing.expectEqual(serial.structure_of(file), parallel.structure_of(twin));
    try std.testing.expectEqualStrings(serial.source_of(file), parallel.source_of(twin));
    try std.testing.expectEqual(serial.tokens_of(file).len, parallel.tokens_of(twin).len);
    try std.testing.expectEqual(serial.facts_of(file).len, parallel.facts_of(twin).len);

    try std.testing.expectEqualSlices(
        Diagnostic,
        serial.diagnostics_of(file),
        parallel.diagnostics_of(twin),
    );

    try std.testing.expectEqual(serial.lines_of(file).count(), parallel.lines_of(twin).count());
}

test "a pending slot refuses a second build" {
    const gpa = std.testing.allocator;
    const limits = limits_of(file_count);
    var store: Store = undefined;

    try store.init(gpa, &limits, .reject);
    defer store.deinit(gpa);

    var source_buffer: [source_bytes_max]u8 = undefined;
    const source = try source_of(&source_buffer, 0);
    const placed = try store.insert_pending(hash_of("m00"), .of(.python), source);
    var scratch: Store.BuildScratch = undefined;

    try scratch.init(gpa, &limits);
    defer scratch.deinit(gpa);

    const builds = store.pending_builds();

    try std.testing.expect(builds.claimable(0));

    builds.build(0, &scratch);

    try std.testing.expect(!builds.claimable(0));
    try std.testing.expect(!store.is_pending(.of(placed)));
}
