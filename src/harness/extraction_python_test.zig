const std = @import("std");
const assert = std.debug.assert;
const Argument = extraction.Argument;
const Field = extraction.Field;
const Model = extraction.Model;
const Front = @import("../syntax/front.zig").Front;
const FrontCapacity = @import("../syntax/front.zig").Front.Capacity;
const FrontOptions = @import("../syntax/front.zig").Front.Options;
const Brackets = @import("../syntax/brackets.zig").Brackets;
const Scratch = @import("../syntax/front.zig").Front.Scratch;
const Range = extraction.Range;
const Registration = extraction.Registration;
const Span = @import("../stdx/bounded/span.zig");
const Summary = @import("../syntax/summary.zig").Summary;
const Token = @import("../syntax/token.zig");
const Value = extraction.Value;
const extraction = @import("../testing/extraction.zig");
const markup_testing = @import("../syntax/testing/markup.zig");
const python = @import("../outline/python.zig");

const Built = struct {
    front: Front,
    outline: python.Outline,
    pairs: Brackets,
    scratch: Scratch,
    source: []const u8,
    tokens: []const Token,

    fn init(built: *Built, source: []const u8) !void {
        assert(source.len <= std.math.maxInt(u32));

        const gpa = std.testing.allocator;

        built.source = source;

        try built.scratch.init(gpa, &front_capacity, .initOne(.python));
        errdefer built.scratch.deinit(gpa);

        try built.front.init(gpa, &front_capacity, .python);
        errdefer built.front.deinit(gpa);

        try built.front.parse(&built.scratch, .of(.python), source, &front_options);

        const root = switch (built.front.root().?) {
            .python => |held| held,
            else => unreachable,
        };

        built.tokens = root.tokens;
        built.pairs = try .init(gpa, token_count_max);
        errdefer built.pairs.deinit(gpa);

        try built.pairs.build(source, built.tokens);

        try built.outline.init(gpa, .{
            .row_count_max = row_count_max,
            .segment_count_max = segment_count_max,
        });

        python.build(source, &built.pairs, root, &built.outline);

        assert(built.pairs.count() == built.tokens.len);
        assert(built.outline.definitions.count() <= built.tokens.len);
    }

    fn deinit(built: *Built) void {
        const gpa = std.testing.allocator;

        assert(built.outline.definitions.count() <= row_count_max);
        assert(built.tokens.len <= token_count_max);

        built.outline.deinit(gpa);
        built.pairs.deinit(gpa);
        built.front.deinit(gpa);
        built.scratch.deinit(gpa);
        built.* = undefined;
    }

    fn registrations(built: *const Built, arena: std.mem.Allocator) ![]const Registration {
        var found: std.ArrayList(Registration) = .empty;

        for (built.outline.calls.const_slice()) |*call| {
            const segments = built.callee_segments(call);
            const namespace = built.namespace_of(segments) orelse continue;
            const is_object = std.mem.eql(u8, namespace.name, "object");
            const parameters = parameters_of(is_object);
            const arguments = try built.arguments_of(arena, call, parameters);
            const range = built.call_range(call);

            try found.append(arena, .{
                .arguments = arguments,
                .explicit_name = is_object and built.constructor_names(arguments),
                .legacy = namespace.legacy,
                .name = argument_value(arguments, "unique_name"),
                .name_range = argument_range(arguments, "unique_name") orelse range,
                .namespace = namespace.name,
                .range = range,
                .target = argument_value(arguments, "target"),
                .target_class = if (is_object) argument_root(arguments, "glue") else null,
                .target_model = argument_root(arguments, "target"),
                .view = built.owner_of(call.scope),
            });
        }

        assert(found.items.len <= built.outline.calls.count());

        return found.items;
    }

    fn models(built: *const Built, arena: std.mem.Allocator) ![]const Model {
        var found: std.ArrayList(Model) = .empty;
        const tokens = built.tokens;

        for (built.outline.definitions.const_slice(), 0..) |node, index| {
            if (node.kind != .@"struct") continue;

            const name = node.name;
            const definition: u32 = @intCast(index);
            const bases = try built.bases_of(arena, definition);
            if (bases.len == 0) continue;
            if (glue_based(bases)) continue;

            try found.append(arena, .{
                .app_label = built.app_label_of(definition),
                .bases = bases,
                .fields = try built.fields_of(arena, definition),
                .name = tokens[name].text(built.source),
                .range = built.node_range(definition),
            });
        }

        assert(found.items.len <= built.outline.definitions.count());

        return found.items;
    }

    fn app_label_of(built: *const Built, definition: u32) ?[]const u8 {
        const tokens = built.tokens;

        assert(definition < built.outline.definitions.count());

        for (built.outline.definitions.const_slice(), 0..) |node, index| {
            if (node.kind != .@"struct") continue;

            const parent = node.parent orelse continue;
            if (parent != definition) continue;

            const name = node.name;
            if (!std.mem.eql(u8, tokens[name].text(built.source), meta_class)) continue;

            const inner: u32 = @intCast(index);

            for (built.outline.assignments.const_slice()) |assignment| {
                const scope = assignment.scope orelse continue;
                if (scope != inner) continue;
                if (!assignment.target_is_simple) continue;
                if (!std.mem.eql(u8, assignment.target.text(built.source), "app_label")) continue;
                return built.literal_of(assignment.value_token_start, assignment.value_token_end);
            }
        }

        return null;
    }

    fn arguments_of(
        built: *const Built,
        arena: std.mem.Allocator,
        call: *const python.Call,
        parameters: []const []const u8,
    ) ![]const Argument {
        assert(parameters.len <= std.math.maxInt(u32));

        const tokens = built.tokens;
        const rows = built.argument_rows(call);
        const found = try arena.alloc(Argument, rows.len);
        var positional: u32 = 0;

        for (rows, found) |row, *slot| {
            var name: ?[]const u8 = null;

            if (span_empty(row.name)) {
                if (positional < parameters.len) name = parameters[positional];

                positional += 1;
            } else {
                name = rename(row.name.text(built.source));
            }

            assert(row.value_token_start < row.value_token_end);

            slot.* = .{
                .items = try built.items_of(arena, row.summary),
                .name = name,
                .range = .{
                    tokens[row.value_token_start].offset,
                    tokens[row.value_token_end - 1].end(),
                },
                .root = built.token_root(row.value_token_start, row.value_token_end),
                .value = try built.summary_value(arena, row.summary),
            };
        }

        assert(positional <= rows.len);

        return found;
    }

    fn argument_rows(built: *const Built, call: *const python.Call) []const python.Argument {
        const rows = built.outline.arguments.const_slice();

        assert(call.argument_first + call.argument_count <= rows.len);

        return rows[call.argument_first..][0..call.argument_count];
    }

    fn bases_of(built: *const Built, arena: std.mem.Allocator, definition: u32) ![]const Value {
        var found: std.ArrayList(Value) = .empty;

        assert(definition < built.outline.definitions.count());

        for (built.outline.bases.const_slice()) |base| {
            if (base.class_definition != definition) continue;

            try found.append(arena, try built.dotted_of(arena, base.summary));
        }

        assert(found.items.len <= built.outline.bases.count());

        return found.items;
    }

    fn call_at(built: *const Built, token: u32) ?*const python.Call {
        assert(token < built.tokens.len);

        for (built.outline.calls.const_slice()) |*call| {
            if (built.callee_start(call) == token) return call;
        }

        return null;
    }

    fn call_range(built: *const Built, call: *const python.Call) Range {
        const tokens = built.tokens;
        const first = built.callee_start(call);

        assert(first <= call.paren_open);
        assert(call.paren_open < call.paren_close);

        return .{ tokens[first].offset, tokens[call.paren_close].end() };
    }

    fn callee_segments(built: *const Built, call: *const python.Call) []const Span {
        assert(call.paren_open < call.paren_close);

        return built.outline.segments_of(call.callee_segment_first, call.callee_segment_count);
    }

    fn callee_start(built: *const Built, call: *const python.Call) u32 {
        const tokens = built.tokens;
        const segments = built.callee_segments(call);
        const head = if (segments.len > 0) segments[0].offset else call.paren_open;

        assert(call.paren_open < tokens.len);

        for (0..call.paren_open) |step| {
            const index = call.paren_open - @as(u32, @intCast(step));

            if (tokens[index].offset == head) {
                assert(index < std.math.maxInt(u32));

                return index;
            }
        }

        return call.paren_open;
    }

    fn constructor_names(built: *const Built, arguments: []const Argument) bool {
        assert(arguments.len <= std.math.maxInt(u32));

        const tokens = built.tokens;
        const glue = argument_named(arguments, "glue") orelse return false;

        for (built.outline.calls.const_slice()) |*call| {
            const start = tokens[built.callee_start(call)].offset;
            if (start != glue.range[0]) continue;

            const rows = built.argument_rows(call);

            for (rows) |row| {
                if (span_empty(row.name)) continue;
                if (std.mem.eql(u8, row.name.text(built.source), "name")) return true;
            }

            return false;
        }

        return false;
    }

    fn dotted_of(built: *const Built, arena: std.mem.Allocator, summary: Summary) !Value {
        if (summary == .dotted_name) assert(summary.dotted_name.segment_count > 0);

        switch (summary) {
            .dotted_name => |dotted| {
                const segments = built.dotted_segments(dotted);
                const parts = try arena.alloc([]const u8, segments.len);

                for (segments, parts) |segment, *part| part.* = segment.text(built.source);

                return literal(try join(arena, parts, '.'));
            },
            .call, .dynamic, .literal, .sequence => return dynamic,
        }
    }

    fn dotted_segments(built: *const Built, dotted: Summary.DottedName) []const Span {
        assert(dotted.segment_first + dotted.segment_count <= built.outline.segments.count());

        return built.outline.segments_of(dotted.segment_first, dotted.segment_count);
    }

    fn fields_of(built: *const Built, arena: std.mem.Allocator, definition: u32) ![]const Field {
        const tokens = built.tokens;
        var found: std.ArrayList(Field) = .empty;

        for (built.outline.assignments.const_slice()) |assignment| {
            const scope = assignment.scope orelse continue;
            if (scope != definition) continue;
            if (!assignment.target_is_simple) continue;

            const call = built.call_at(assignment.value_token_start) orelse continue;
            const segments = built.callee_segments(call);
            if (segments.len == 0) continue;

            const kind = segments[segments.len - 1].text(built.source);

            if (!std.mem.endsWith(u8, kind, "Field")) {
                if (!listed(&relation_fields, kind)) continue;
            }

            const arguments = try built.arguments_of(arena, call, &.{"to"});

            try found.append(arena, .{
                .editable = editable(kind, arguments),
                .kind = kind,
                .name = assignment.target.text(built.source),
                .range = .{
                    assignment.target.offset,
                    tokens[assignment.value_token_end - 1].end(),
                },
                .relates_to = relation_target(kind, arguments),
            });
        }

        assert(found.items.len <= built.outline.assignments.count());

        return found.items;
    }

    fn items_of(built: *const Built, arena: std.mem.Allocator, summary: Summary) ![]const Value {
        if (summary == .dotted_name) assert(summary.dotted_name.segment_count > 0);

        const sequence = switch (summary) {
            .sequence => |held| held,
            .call, .dotted_name, .dynamic, .literal => return &.{},
        };

        const items = built.sequence_items(sequence);
        const found = try arena.alloc(Value, items.len);

        for (items, found) |item, *slot| slot.* = built.item_value(item);

        assert(found.len == sequence.item_count);

        return found;
    }

    fn item_value(built: *const Built, summary: Summary) Value {
        if (summary == .dotted_name) assert(summary.dotted_name.segment_count > 0);

        switch (summary) {
            .literal => |held| return literal(held.content.text(built.source)),
            .dotted_name => |dotted| {
                const segments = built.dotted_segments(dotted);
                if (segments.len == 0) return dynamic;

                const text = segments[segments.len - 1].text(built.source);
                if (listed(&access_names, text)) return literal(text);
                return dynamic;
            },
            .call, .dynamic => return dynamic,
            .sequence => unreachable,
        }
    }

    fn literal_of(built: *const Built, start: u32, end: u32) ?[]const u8 {
        if (start >= end) return null;

        const token = built.tokens[start];
        if (token.kind != .string) return null;
        if (start + 1 != end) return null;

        const text = token.text(built.source);
        if (text.len == 0) return null;

        const quote = text[0];

        if (quote != '"') {
            if (quote != '\'') return null;
        }

        assert(text.len >= 2);

        return text[1 .. text.len - 1];
    }

    fn namespace_of(built: *const Built, segments: []const Span) ?Namespace {
        if (segments.len == 0) return null;

        const head = segments[0].text(built.source);

        if (std.mem.eql(u8, head, glue_root)) {
            if (segments.len != 2) return null;

            const found = segments[1].text(built.source);

            for (namespaces) |known| {
                if (std.mem.eql(u8, known, found)) return .{ .legacy = false, .name = known };
            }

            return null;
        }

        const last = segments[segments.len - 1].text(built.source);

        for (legacy_registrations) |entry| {
            if (std.mem.eql(u8, entry.callee, last)) return .{ .legacy = true, .name = entry.name };
        }

        return null;
    }

    fn node_range(built: *const Built, definition: u32) Range {
        assert(definition < std.math.maxInt(u32));

        const tokens = built.tokens;
        const node = built.outline.definitions.get(definition);
        const token_count: u32 = @intCast(tokens.len);
        const end = @min(node.token_end, token_count);
        const header = node.header;

        assert(node.token_start <= end);

        for (0..end - node.token_start) |step| {
            const token = tokens[end - 1 - step];

            switch (token.kind) {
                .newline, .block_end, .block_start => {},
                else => return .{ tokens[header].offset, token.end() },
            }
        }

        return .{ tokens[header].offset, tokens[header].end() };
    }

    fn owner_of(built: *const Built, scope: ?u32) ?[]const u8 {
        if (scope) |held| assert(held < std.math.maxInt(u32));

        const index = scope orelse return null;
        const name = built.outline.definitions.get(index).name;

        assert(name < built.tokens.len);

        return built.tokens[name].text(built.source);
    }

    fn sequence_items(built: *const Built, sequence: Summary.Sequence) []const Summary {
        const items = built.outline.items.const_slice();

        assert(sequence.item_first + sequence.item_count <= items.len);

        return items[sequence.item_first..][0..sequence.item_count];
    }

    fn summary_value(built: *const Built, arena: std.mem.Allocator, summary: Summary) !Value {
        if (summary == .dotted_name) assert(summary.dotted_name.segment_count > 0);

        const sequence = switch (summary) {
            .sequence => |held| held,
            .call, .dotted_name, .dynamic, .literal => return built.item_value(summary),
        };

        const items = built.sequence_items(sequence);
        const parts = try arena.alloc([]const u8, items.len);

        for (items, parts) |item, *part| {
            const held = built.item_value(item);
            if (std.mem.eql(u8, held.kind, dynamic.kind)) return dynamic;

            part.* = held.text;
        }

        return literal(try join(arena, parts, ','));
    }

    fn token_root(built: *const Built, start: u32, end: u32) ?[]const u8 {
        if (start >= end) return null;

        const token = built.tokens[start];

        return switch (token.kind) {
            .identifier, .keyword => token.text(built.source),
            else => null,
        };
    }
};

const LegacyRegistration = struct {
    callee: []const u8,
    name: []const u8,
};

const Namespace = struct {
    legacy: bool,
    name: []const u8,
};

const node_count_max: u32 = 1 << 16;
const row_count_max: u32 = 1 << 13;
const segment_count_max: u32 = 1 << 14;
const token_count_max: u32 = 1 << 17;

const front_capacity: FrontCapacity = .{
    .diagnostic_count_max = 1 << 10,
    .event_count_max = 1 << 18,
    .node_count_max = node_count_max,
    .semantic = .{
        .binding_count_max = 1 << 14,
        .fact_count_max = 1 << 10,
        .reference_count_max = 1 << 16,
        .scope_count_max = 1 << 10,
    },
    .tag_count_max = 1 << 6,
    .token_count_max = token_count_max,
};

const front_options: FrontOptions = .{
    .globals = &.{},
    .python_version = .py310,
    .vocabulary = .empty,
};

const access_names = [_][]const u8{ "CHANGE", "DELETE", "VIEW" };
const glue_base = "BaseGlue";
const glue_root = "Glue";
const meta_class = "Meta";
const non_editable_fields = [_][]const u8{ "AutoField", "BigAutoField", "SmallAutoField" };
const object_parameters = [_][]const u8{ "request", "glue" };
const registration_parameters = [_][]const u8{ "request", "unique_name", "target", "access" };
const relation_fields = [_][]const u8{ "ForeignKey", "ManyToManyField", "OneToOneField" };
const dynamic: Value = .{ .kind = "Dynamic", .text = "" };

const legacy_registrations = [_]LegacyRegistration{
    .{ .callee = "glue_function", .name = "function" },
    .{ .callee = "glue_model_object", .name = "model" },
    .{ .callee = "glue_query_set", .name = "queryset" },
    .{ .callee = "glue_template", .name = "template" },
};

const namespaces = [_][]const u8{
    "collection",
    "form",
    "function",
    "json",
    "model",
    "object",
    "queryset",
    "template",
};

fn literal(text: []const u8) Value {
    assert(text.len <= std.math.maxInt(u32));

    return .{ .kind = "Literal", .text = text };
}

fn argument_named(arguments: []const Argument, name: []const u8) ?*const Argument {
    assert(name.len > 0);
    assert(arguments.len <= std.math.maxInt(u32));

    for (arguments) |*held| {
        const named = held.name orelse continue;
        if (std.mem.eql(u8, named, name)) return held;
    }

    return null;
}

fn argument_range(arguments: []const Argument, name: []const u8) ?Range {
    assert(arguments.len <= std.math.maxInt(u32));
    assert(name.len > 0);

    const found = argument_named(arguments, name) orelse return null;

    assert(found.range[0] <= found.range[1]);

    return found.range;
}

fn argument_root(arguments: []const Argument, name: []const u8) ?[]const u8 {
    assert(arguments.len <= std.math.maxInt(u32));
    assert(name.len > 0);

    const found = argument_named(arguments, name) orelse return null;

    assert(found.name != null);

    return found.root;
}

fn argument_value(arguments: []const Argument, name: []const u8) Value {
    assert(arguments.len <= std.math.maxInt(u32));
    assert(name.len > 0);

    const found = argument_named(arguments, name) orelse return dynamic;

    assert(found.value.kind.len > 0);

    return found.value;
}

fn editable(kind: []const u8, arguments: []const Argument) bool {
    assert(kind.len > 0);

    if (listed(&non_editable_fields, kind)) return false;
    assert(arguments.len <= std.math.maxInt(u32));

    for ([_][]const u8{ "auto_now", "auto_now_add" }) |name| {
        const text = literal_text(arguments, name) orelse continue;
        if (std.mem.eql(u8, text, "True")) return false;
    }

    const text = literal_text(arguments, "editable") orelse return true;
    return !std.mem.eql(u8, text, "False");
}

fn glue_based(bases: []const Value) bool {
    assert(bases.len > 0);

    for (bases) |base| {
        if (!std.mem.eql(u8, base.kind, "Literal")) continue;
        if (std.mem.eql(u8, base.text, glue_base)) return true;
    }

    return false;
}

fn join(arena: std.mem.Allocator, parts: []const []const u8, separator: u8) ![]const u8 {
    assert(parts.len <= std.math.maxInt(u32));
    assert(std.ascii.isPrint(separator));

    var out: std.ArrayList(u8) = .empty;

    for (parts, 0..) |part, index| {
        if (index > 0) try out.append(arena, separator);

        try out.appendSlice(arena, part);
    }

    assert(out.items.len >= parts.len -| 1);

    return out.items;
}

fn listed(known: []const []const u8, text: []const u8) bool {
    assert(known.len > 0);
    assert(text.len <= std.math.maxInt(u32));

    for (known) |held| {
        if (std.mem.eql(u8, held, text)) return true;
    }

    return false;
}

fn literal_text(arguments: []const Argument, name: []const u8) ?[]const u8 {
    assert(arguments.len <= std.math.maxInt(u32));
    assert(name.len > 0);

    const found = argument_value(arguments, name);
    if (std.mem.eql(u8, found.kind, "Literal")) return found.text;
    return null;
}

fn parameters_of(is_object: bool) []const []const u8 {
    if (is_object) return &object_parameters;
    return &registration_parameters;
}

fn relation_target(kind: []const u8, arguments: []const Argument) ?Value {
    if (!listed(&relation_fields, kind)) return null;
    assert(arguments.len <= std.math.maxInt(u32));

    const found = argument_named(arguments, "to") orelse return null;

    if (std.mem.eql(u8, found.value.kind, "Literal")) {
        if (found.value.text.len == 0) return dynamic;
    }

    return found.value;
}

fn rename(name: []const u8) []const u8 {
    assert(name.len > 0);

    if (std.mem.eql(u8, name, "model_object")) return "target";
    return name;
}

fn span_empty(span: Span) bool {
    if (span.offset != 0) return false;
    return span.length == 0;
}

test "every registration the oracle recorded comes back field for field" {
    const gpa = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();

    const allocator = arena.allocator();
    const residue = try markup_testing.residue_read(allocator, "residue-extraction.json");
    var cases = try extraction.extractions(gpa, .py);
    defer cases.deinit(gpa);

    var compared: u32 = 0;

    for (cases.items) |*case| {
        if (extraction.residue_contains(residue.items, case.name)) continue;

        var built: Built = undefined;

        try built.init(case.source);
        defer built.deinit();

        const found = try built.registrations(allocator);
        const recorded = case.extraction.registrations;

        std.testing.expectEqual(recorded.len, found.len) catch |err| {
            std.debug.print("{s}: the registration counts differ\n", .{case.name});

            return err;
        };

        for (found, recorded, 0..) |came, held, index| {
            std.testing.expectEqualDeep(held, came) catch |err| {
                std.debug.print("{s}: registration {d} differs\n", .{ case.name, index });

                return err;
            };

            compared += 1;
        }
    }

    try std.testing.expectEqual(26, compared);
}

test "every model the oracle recorded comes back field for field" {
    const gpa = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();

    const allocator = arena.allocator();
    const residue = try markup_testing.residue_read(allocator, "residue-extraction.json");
    var cases = try extraction.extractions(gpa, .py);
    defer cases.deinit(gpa);

    var compared: u32 = 0;

    for (cases.items) |*case| {
        if (extraction.residue_contains(residue.items, case.name)) continue;

        var built: Built = undefined;

        try built.init(case.source);
        defer built.deinit();

        const found = try built.models(allocator);
        const recorded = case.extraction.models;

        std.testing.expectEqual(recorded.len, found.len) catch |err| {
            std.debug.print("{s}: the model counts differ\n", .{case.name});

            return err;
        };

        for (found, recorded, 0..) |came, held, index| {
            std.testing.expectEqualDeep(held, came) catch |err| {
                std.debug.print("{s}: model {d} differs\n", .{ case.name, index });

                return err;
            };

            compared += 1;
        }
    }

    try std.testing.expectEqual(12, compared);
}
