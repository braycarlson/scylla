const std = @import("std");
const assert = std.debug.assert;
const Diagnostics = @import("../lint/diagnostics.zig");
const FileID = @import("../stdx/file_id.zig").FileID;
const Graph = @import("graph.zig");
const Language = @import("../syntax/language.zig").Language;
const Node = @import("view.zig").Node;
const Severity = @import("../lint/diagnostics.zig").Severity;
const Span = @import("../stdx/bounded/span.zig");
const Store = @import("store.zig");
const Target = @import("resolve.zig").Target;
const hash_of = std.hash.Fnv1a_64.hash;
const resolve = @import("resolve.zig");
const view = @import("view.zig");

const Mix = struct {
    language: Language,
    slots: u32,
};

const Keyed = struct {
    key: []const u8,
    path: []const u8,
};

const Project = struct {
    graph: Graph,
    store: Store,

    fn deinit(project: *Project, gpa: std.mem.Allocator) void {
        assert(project.graph.file_count_max > 0);

        project.graph.deinit(gpa);
        project.store.deinit(gpa);
        project.* = undefined;
    }
};

const SpecifierResolver = struct {
    pub fn resolve(
        resolver: *const SpecifierResolver,
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

const source_main =
    "import helper\nfrom missing import thing\n\n\ndef run():\n    return helper\n";

const source_helper = "def thing():\n    return 1\n\n\ndef other():\n    return 2\n";
const diagnostic_count_max: u32 = 64;
const diagnostic_bytes_max: u32 = 1 << 12;
const fixture_bytes_max: u32 = 1 << 13;
const path_bytes_max: u32 = 256;
const walk_step_max: u32 = 1 << 16;
const fixture_root = "tests/fixtures/project";

const chain = [_]Keyed{
    .{ .key = "m00", .path = "m00.py" },
    .{ .key = "m01", .path = "m01.py" },
    .{ .key = "m02", .path = "m02.py" },
    .{ .key = "m03", .path = "m03.py" },
    .{ .key = "m04", .path = "m04.py" },
    .{ .key = "m05", .path = "m05.py" },
    .{ .key = "m06", .path = "m06.py" },
    .{ .key = "m07", .path = "m07.py" },
    .{ .key = "m08", .path = "m08.py" },
    .{ .key = "m09", .path = "m09.py" },
    .{ .key = "m10", .path = "m10.py" },
    .{ .key = "m11", .path = "m11.py" },
    .{ .key = "m12", .path = "m12.py" },
    .{ .key = "m13", .path = "m13.py" },
    .{ .key = "m14", .path = "m14.py" },
    .{ .key = "m15", .path = "m15.py" },
    .{ .key = "m16", .path = "m16.py" },
    .{ .key = "m17", .path = "m17.py" },
    .{ .key = "m18", .path = "m18.py" },
    .{ .key = "m19", .path = "m19.py" },
};

const cycle = [_]Keyed{
    .{ .key = "a", .path = "a.py" },
    .{ .key = "b", .path = "b.py" },
};

const django = [_]Keyed{
    .{ .key = "base.html", .path = "base.html" },
    .{ .key = "page.html", .path = "page.html" },
    .{ .key = "partial.html", .path = "partial.html" },
};

const package = [_]Keyed{
    .{ .key = "main", .path = "main.py" },
    .{ .key = "pkg", .path = "pkg/__init__.py" },
    .{ .key = "pkg.models", .path = "pkg/models.py" },
};

const star = [_]Keyed{
    .{ .key = "main", .path = "main.py" },
    .{ .key = "pkg", .path = "pkg/__init__.py" },
    .{ .key = "pkg.models", .path = "pkg/models.py" },
};

const barrel = [_]Keyed{
    .{ .key = "lib", .path = "lib.ts" },
    .{ .key = "lib/inner", .path = "inner.ts" },
    .{ .key = "lib/inner/widget", .path = "widget.ts" },
    .{ .key = "main", .path = "main.ts" },
};

fn recorded(
    diagnostics: *Diagnostics,
    code: []const u8,
    severity: Severity,
    span: Span,
) !void {
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

fn rule_definitions(store: *const Store, file: FileID, out: *Diagnostics) !void {
    assert(@backingInt(file) != std.math.maxInt(u32));

    var walk = view.walk(store, file);

    for (0..walk_step_max) |_| {
        const step = walk.next() orelse break;

        const node = switch (step) {
            .enter => |held| held,
            .leave => continue,
        };

        const held = view.python(store, file, node) orelse continue;
        if (held.kind() != .function_def) continue;

        try recorded(out, "PRJ001", .warning, held.span());
    }
}

fn rule_imports(store: *const Store, file: FileID, out: *Diagnostics) !void {
    assert(@backingInt(file) != std.math.maxInt(u32));

    const source = store.source_of(file);

    for (store.facts_of(file)) |fact| {
        if (!fact.kind.imports()) continue;

        var path_buffer: [path_bytes_max]u8 = undefined;
        const specifier = fact.specifier.text(source);
        const path = try std.mem.print(&path_buffer, "{s}.py", .{specifier});
        if (store.find(hash_of(path)) != null) continue;

        try recorded(out, "PRJ002", .@"error", fact.specifier);
    }
}

fn rule_collected(
    gpa: std.mem.Allocator,
    store: *const Store,
    file: FileID,
    out: *Diagnostics,
) !void {
    assert(@backingInt(file) != std.math.maxInt(u32));

    var collected: std.ArrayList(Node) = .empty;
    defer collected.deinit(gpa);

    var walk = view.walk(store, file);

    for (0..walk_step_max) |_| {
        const step = walk.next() orelse break;

        const node = switch (step) {
            .enter => |held| held,
            .leave => continue,
        };

        const held = view.python(store, file, node) orelse continue;
        if (held.kind() != .function_def) continue;

        try collected.append(gpa, .init(file, node));
    }

    for (collected.items) |held| {
        const found = view.python(store, held.file, held.index).?;

        try recorded(out, "PRJ003", .hint, found.span());
    }
}

fn limits_of(mix: []const Mix) Store.Limits {
    assert(mix.len <= std.math.maxInt(u32));

    var slots: [Language.count][Store.class_count]u32 = @splat(@splat(0));
    var total: u32 = 0;

    for (mix) |held| {
        slots[@backingInt(held.language)][Store.Limits.class_of(8_192)] = held.slots;
        total += held.slots;
    }

    return .{
        .file_count_max = total,
        .front = .{
            .diagnostic_count_max = 64,
            .event_count_max = 8_192,
            .node_count_max = 4_096,
            .semantic = .{
                .binding_count_max = 512,
                .fact_count_max = 512,
                .reference_count_max = 512,
                .scope_count_max = 128,
            },
            .tag_count_max = 512,
            .token_count_max = 2_048,
        },
        .line_count_max = 512,
        .slots = slots,
        .source_bytes_max = 8_192,
    };
}

fn project_init(store: *Store, gpa: std.mem.Allocator) !void {
    const limits = limits_of(&.{.{ .language = .python, .slots = 4 }});

    try store.init(gpa, &limits, .reject);
    errdefer store.deinit(gpa);

    _ = try store.insert(hash_of("main.py"), .of(.python), source_main);
    _ = try store.insert(hash_of("helper.py"), .of(.python), source_helper);
}

fn file_of(store: *const Store, key: []const u8) FileID {
    assert(key.len <= std.math.maxInt(u32));

    const index = store.find(hash_of(key)).?;

    assert(store.resident(.of(index)));

    return .of(index);
}

fn tree_of(
    project: *Project,
    gpa: std.mem.Allocator,
    name: []const u8,
    files: []const Keyed,
    language: Language,
) !void {
    assert(name.len > 0);
    assert(files.len <= std.math.maxInt(u32));

    const limits = limits_of(&.{.{ .language = language, .slots = @intCast(files.len) }});

    try project.store.init(gpa, &limits, .reject);
    errdefer project.store.deinit(gpa);

    project.store.template_imports_set(&.{ "extends", "include" });

    for (files) |held| {
        var path_buffer: [path_bytes_max]u8 = undefined;

        const path = try std.mem.print(&path_buffer, "{s}/{s}/{s}", .{
            fixture_root,
            name,
            held.path,
        });

        const limit: std.Io.Limit = .limited(fixture_bytes_max);
        const source = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, gpa, limit);
        defer gpa.free(source);

        const index = try project.store.insert(hash_of(held.key), .of(language), source);

        try std.testing.expectEqual(.complete, project.store.structure_of(.of(index)));
    }

    project.graph = try .init(gpa, 64, @intCast(files.len));
    errdefer project.graph.deinit(gpa);

    try project.graph.build(&project.store, SpecifierResolver, &.{});
}

fn reaches(store: *const Store, node: Node) bool {
    assert(node.index != std.math.maxInt(u32));

    var walk = view.walk(store, node.file);

    for (0..walk_step_max) |_| {
        const step = walk.next() orelse return false;

        switch (step) {
            .enter => |held| if (held == node.index) return true,
            .leave => {},
        }
    }

    return false;
}

fn node_of(store: *const Store, file: FileID, name: []const u8) u32 {
    assert(name.len > 0);
    assert(@backingInt(file) != std.math.maxInt(u32));

    const node = store.declaration_of(file, name).?;

    assert(node < store.front_of(file).node_count());

    return node;
}

test "an intra file rule reads one slot" {
    const gpa = std.testing.allocator;
    var store: Store = undefined;

    try project_init(&store, gpa);
    defer store.deinit(gpa);

    var diagnostics: Diagnostics = try .init(gpa, .{
        .related_count_max = diagnostic_count_max,
        .row_count_max = diagnostic_count_max,
        .text_bytes_max = diagnostic_bytes_max,
    });

    defer diagnostics.deinit(gpa);

    try rule_definitions(&store, file_of(&store, "main.py"), &diagnostics);
    try std.testing.expectEqual(1, diagnostics.count());

    var second: Diagnostics = try .init(gpa, .{
        .related_count_max = diagnostic_count_max,
        .row_count_max = diagnostic_count_max,
        .text_bytes_max = diagnostic_bytes_max,
    });

    defer second.deinit(gpa);

    try rule_definitions(&store, file_of(&store, "helper.py"), &second);
    try std.testing.expectEqual(2, second.count());

    for (second.slice()) |held| try std.testing.expectEqualStrings("PRJ001", held.code);
}

test "a cross file rule reaches the second slot through the store" {
    const gpa = std.testing.allocator;
    var store: Store = undefined;

    try project_init(&store, gpa);
    defer store.deinit(gpa);

    var diagnostics: Diagnostics = try .init(gpa, .{
        .related_count_max = diagnostic_count_max,
        .row_count_max = diagnostic_count_max,
        .text_bytes_max = diagnostic_bytes_max,
    });

    defer diagnostics.deinit(gpa);

    const main = file_of(&store, "main.py");

    try rule_imports(&store, main, &diagnostics);

    const found = diagnostics.slice();

    try std.testing.expectEqual(1, found.len);
    try std.testing.expectEqualStrings("PRJ002", found[0].code);
    try std.testing.expectEqualStrings("missing", found[0].span.text(store.source_of(main)));
}

test "a rule holds node handles past the traversal" {
    const gpa = std.testing.allocator;
    var store: Store = undefined;

    try project_init(&store, gpa);
    defer store.deinit(gpa);

    var diagnostics: Diagnostics = try .init(gpa, .{
        .related_count_max = diagnostic_count_max,
        .row_count_max = diagnostic_count_max,
        .text_bytes_max = diagnostic_bytes_max,
    });

    defer diagnostics.deinit(gpa);

    try rule_collected(gpa, &store, file_of(&store, "helper.py"), &diagnostics);

    const found = diagnostics.slice();

    try std.testing.expectEqual(2, found.len);
    try std.testing.expectEqualStrings("PRJ003", found[0].code);
    try std.testing.expectEqualStrings("PRJ003", found[1].code);
    try std.testing.expect(found[0].span.offset < found[1].span.offset);
}

test "a view of the wrong language is none" {
    const gpa = std.testing.allocator;

    const limits = limits_of(&.{
        .{ .language = .python, .slots = 1 },
        .{ .language = .rust, .slots = 1 },
    });

    var store: Store = undefined;

    try store.init(gpa, &limits, .reject);
    defer store.deinit(gpa);

    const script: FileID = .of(try store.insert(
        hash_of("a.py"),
        .of(.python),
        source_helper,
    ));

    const crate: FileID = .of(try store.insert(hash_of("a.rs"), .of(.rust), "fn run() {}\n"));

    try std.testing.expect(view.python(&store, script, 0) != null);
    try std.testing.expect(view.rust(&store, script, 0) == null);
    try std.testing.expect(view.rust(&store, crate, 0) != null);
    try std.testing.expect(view.python(&store, crate, 0) == null);
    try std.testing.expect(view.markup(&store, crate, 0) == null);
}

test "a node past the tree is none" {
    const gpa = std.testing.allocator;
    var store: Store = undefined;

    try project_init(&store, gpa);
    defer store.deinit(gpa);

    const main = file_of(&store, "main.py");

    try std.testing.expect(view.python(&store, main, 0) != null);
    try std.testing.expect(view.python(&store, main, std.math.maxInt(u32) - 1) == null);
}

test "the facts table is the shared shape every front end fills" {
    const gpa = std.testing.allocator;
    var store: Store = undefined;

    try project_init(&store, gpa);
    defer store.deinit(gpa);

    const facts = store.facts_of(file_of(&store, "main.py"));

    try std.testing.expectEqual(2, facts.len);

    for (facts) |held| try std.testing.expect(held.kind.imports());
}

test "a package reexport resolves to the class it names" {
    const gpa = std.testing.allocator;
    var project: Project = undefined;

    try tree_of(&project, gpa, "python-package", &package, .python);
    defer project.deinit(gpa);

    const store = &project.store;
    const main = file_of(store, "main");
    const models = file_of(store, "pkg.models");
    const found = resolve.target_of(store, &project.graph, main, "Widget");
    const node = found.binding;

    try std.testing.expectEqual(models, node.file);
    try std.testing.expectEqual(store.declaration_of(models, "Widget").?, node.index);
    try std.testing.expect(reaches(store, node));

    const hidden = resolve.target_of(store, &project.graph, main, "Hidden");

    try std.testing.expectEqual(Target.missing, hidden);
}

test "a barrel two levels deep follows the rename" {
    const gpa = std.testing.allocator;
    var project: Project = undefined;

    try tree_of(&project, gpa, "typescript-barrel", &barrel, .typescript);
    defer project.deinit(gpa);

    const store = &project.store;
    const main = file_of(store, "main");
    const widget = file_of(store, "lib/inner/widget");
    const found = resolve.target_of(store, &project.graph, main, "Widget");
    const node = found.binding;

    try std.testing.expectEqual(widget, node.file);
    try std.testing.expectEqual(store.declaration_of(widget, "Thing").?, node.index);
    try std.testing.expect(reaches(store, node));
}

test "a star reexport answers maybe" {
    const gpa = std.testing.allocator;
    var project: Project = undefined;

    try tree_of(&project, gpa, "star-reexport", &star, .python);
    defer project.deinit(gpa);

    const main = file_of(&project.store, "main");
    const found = resolve.target_of(&project.store, &project.graph, main, "Widget");

    try std.testing.expectEqual(Target.maybe, found);
}

test "a cycle still terminates" {
    const gpa = std.testing.allocator;
    var project: Project = undefined;

    try tree_of(&project, gpa, "cycle", &cycle, .python);
    defer project.deinit(gpa);

    const store = &project.store;
    const first = file_of(store, "a");
    const second = file_of(store, "b");
    var cycles = project.graph.cycles();
    const looped = cycles.next();
    const extra = cycles.next();

    try std.testing.expect(looped != null);
    try std.testing.expect(extra == null);

    const value = resolve.target_of(store, &project.graph, first, "value");
    const other = resolve.target_of(store, &project.graph, second, "other");
    const value_expected: Target = .{ .binding = .init(second, node_of(store, second, "value")) };
    const other_expected: Target = .{ .binding = .init(first, node_of(store, first, "other")) };

    try std.testing.expectEqual(value_expected, value);
    try std.testing.expectEqual(other_expected, other);
}

test "a chain past the bound answers maybe" {
    const gpa = std.testing.allocator;
    var project: Project = undefined;

    try tree_of(&project, gpa, "chain", &chain, .python);
    defer project.deinit(gpa);

    const store = &project.store;
    const head = file_of(store, "m00");
    const near = file_of(store, "m17");
    const far = resolve.target_of(store, &project.graph, head, "value");

    try std.testing.expectEqual(Target.maybe, far);

    const found = resolve.target_of(store, &project.graph, near, "value");

    try std.testing.expectEqual(file_of(store, "m19"), found.binding.file);
}

test "a template tree resolves through the same machinery" {
    const gpa = std.testing.allocator;
    var project: Project = undefined;

    try tree_of(&project, gpa, "django", &django, .markup);
    defer project.deinit(gpa);

    const store = &project.store;
    const base = file_of(store, "base.html");
    const page = file_of(store, "page.html");
    const partial = file_of(store, "partial.html");
    const edges = project.graph.edges_of(page);

    try std.testing.expectEqual(2, edges.len);

    for (edges) |held| try std.testing.expect(held.resolved());

    try std.testing.expectEqual(base.index(), edges[0].to.?);
    try std.testing.expectEqual(partial.index(), edges[1].to.?);
    try std.testing.expectEqual(0, project.graph.edges_of(base).len);

    var dependents = project.graph.dependents_of(base);
    const dependent = dependents.next();
    const extra = dependents.next();

    try std.testing.expect(dependent != null);
    try std.testing.expect(extra == null);

    const body = resolve.target_of(store, &project.graph, page, "body");

    try std.testing.expectEqual(Target.missing, body);
}

const barrel_module_count: u32 = 50;
const barrel_importer_count: u32 = 3;
const generated_bytes_max: u32 = 4_096;
const collision_probe_max: u32 = 1 << 16;

fn module_key(buffer: []u8, index: u32) ![]const u8 {
    assert(buffer.len <= std.math.maxInt(u32));
    assert(index < std.math.maxInt(u32));

    return std.mem.print(buffer, "m{d}", .{index});
}

fn generated_project(project: *Project, gpa: std.mem.Allocator) !void {
    const file_count = 1 + barrel_module_count + barrel_importer_count;
    const limits = limits_of(&.{.{ .language = .python, .slots = file_count }});

    try project.store.init(gpa, &limits, .reject);
    errdefer project.store.deinit(gpa);

    var source_buffer: [generated_bytes_max]u8 = undefined;
    var barrel_source: std.ArrayList(u8) = .empty;
    defer barrel_source.deinit(gpa);

    for (0..barrel_module_count) |index| {
        var key_buffer: [16]u8 = undefined;
        const key = try module_key(&key_buffer, @intCast(index));

        const source = try std.mem.print(
            &source_buffer,
            "def x{d}():\n    return {d}\n",
            .{ index, index },
        );

        _ = try project.store.insert(hash_of(key), .of(.python), source);

        try barrel_source.print(gpa, "from {s} import x{d}\n", .{ key, index });
    }

    _ = try project.store.insert(hash_of("barrel"), .of(.python), barrel_source.items);

    for (0..barrel_importer_count) |index| {
        var key_buffer: [16]u8 = undefined;
        const key = try std.mem.print(&key_buffer, "importer{d}", .{index});
        const wanted: u32 = barrel_module_count - 1 - @as(u32, @intCast(index));
        const source = try std.mem.print(&source_buffer, "from barrel import x{d}\n", .{wanted});

        _ = try project.store.insert(hash_of(key), .of(.python), source);
    }

    project.graph = try .init(gpa, 256, file_count);
    errdefer project.graph.deinit(gpa);

    try project.graph.build(&project.store, SpecifierResolver, &.{});
}

test "a barrel of many reexports resolves each importer through two hops" {
    const gpa = std.testing.allocator;
    var project: Project = undefined;

    try generated_project(&project, gpa);
    defer project.deinit(gpa);

    const store = &project.store;

    for (0..barrel_importer_count) |index| {
        var key_buffer: [16]u8 = undefined;
        var name_buffer: [16]u8 = undefined;
        const key = try std.mem.print(&key_buffer, "importer{d}", .{index});
        const wanted: u32 = barrel_module_count - 1 - @as(u32, @intCast(index));
        const name = try std.mem.print(&name_buffer, "x{d}", .{wanted});
        const importer = file_of(store, key);
        const found = resolve.target_of(store, &project.graph, importer, name);
        const module = file_of(store, try module_key(&key_buffer, wanted));

        try std.testing.expectEqual(module, found.binding.file);
        try std.testing.expectEqual(store.declaration_of(module, name).?, found.binding.index);
        try std.testing.expectEqual(wanted, store.forward_of(file_of(store, "barrel"), name).?);
    }

    const absent = resolve.target_of(store, &project.graph, file_of(store, "importer0"), "absent");

    try std.testing.expectEqual(Target.missing, absent);
}

fn module_letter(index: usize) u8 {
    assert(index < 26);

    return 'a' + @as(u8, @intCast(index));
}

fn colliding_names(buffers: *[3][16]u8, mask: u64) ![3][]const u8 {
    var names: [3][]const u8 = undefined;
    var found: u32 = 0;
    const first = try std.mem.print(&buffers[0], "n{d}", .{0});
    const bucket = hash_of(first) & mask;

    names[0] = first;
    found = 1;

    for (1..collision_probe_max) |index| {
        if (found == names.len) break;

        var probe_buffer: [16]u8 = undefined;
        const probe = try std.mem.print(&probe_buffer, "n{d}", .{index});
        if (hash_of(probe) & mask != bucket) continue;

        names[found] = try std.mem.print(&buffers[found], "{s}", .{probe});
        found += 1;
    }

    try std.testing.expectEqual(names.len, found);

    for (names) |name| try std.testing.expectEqual(bucket, hash_of(name) & mask);

    return names;
}

test "names sharing a hash bucket each resolve to their own fact and declaration" {
    const gpa = std.testing.allocator;
    const limits = limits_of(&.{.{ .language = .python, .slots = 4 }});
    const mask = std.math.ceilPowerOfTwoAssert(u32, limits.front.semantic.?.fact_count_max * 2) - 1;
    var buffers: [3][16]u8 = undefined;
    const names = try colliding_names(&buffers, mask);
    var project: Project = undefined;

    try project.store.init(gpa, &limits, .reject);
    errdefer project.store.deinit(gpa);

    var source_buffer: [generated_bytes_max]u8 = undefined;

    const main_source = try std.mem.print(
        &source_buffer,
        "from a import {s}\nfrom b import {s}\nfrom c import {s}\n",
        .{ names[0], names[1], names[2] },
    );

    _ = try project.store.insert(hash_of("main"), .of(.python), main_source);

    for (names, 0..) |name, index| {
        var key_buffer: [16]u8 = undefined;
        const key = try std.mem.print(&key_buffer, "{c}", .{module_letter(index)});
        var module_buffer: [generated_bytes_max]u8 = undefined;

        const source = try std.mem.print(
            &module_buffer,
            "{s} = 1\n{s}_other = 2\n",
            .{ name, name },
        );

        _ = try project.store.insert(hash_of(key), .of(.python), source);
    }

    project.graph = try .init(gpa, 64, 4);
    errdefer project.graph.deinit(gpa);

    try project.graph.build(&project.store, SpecifierResolver, &.{});
    defer project.deinit(gpa);

    const store = &project.store;
    const main = file_of(store, "main");

    for (names, 0..) |name, index| {
        var key_buffer: [16]u8 = undefined;
        const key = try std.mem.print(&key_buffer, "{c}", .{module_letter(index)});
        const module = file_of(store, key);
        const found = resolve.target_of(store, &project.graph, main, name);

        try std.testing.expectEqual(@as(u32, @intCast(index)), store.forward_of(main, name).?);
        try std.testing.expectEqual(module, found.binding.file);
        try std.testing.expectEqual(store.declaration_of(module, name).?, found.binding.index);
    }

    try std.testing.expectEqual(null, store.forward_of(main, "n1"));
}
