const std = @import("std");
const assert = std.debug.assert;
const Front = @import("../front.zig").Front;
const Language = @import("../language.zig").Language;
const Capacity = @import("../front.zig").Front.Capacity;
const Options = @import("../front.zig").Front.Options;
const Scratch = @import("../front.zig").Front.Scratch;
const View = @import("../view.zig").View;
const environment = @import("../../testing/environment.zig");

const Shown = struct {
    view: View,
    depth: u32,
};

const depth_max: u32 = 1 << 10;

const capacity: Capacity = .{
    .diagnostic_count_max = 1 << 8,
    .event_count_max = 1 << 18,
    .node_count_max = 1 << 16,
    .semantic = .{
        .binding_count_max = 1 << 12,
        .fact_count_max = 1 << 10,
        .reference_count_max = 1 << 12,
        .scope_count_max = 1 << 10,
    },
    .tag_count_max = 1 << 10,
    .token_count_max = 1 << 16,
};

const options: Options = .{
    .globals = &.{},
    .python_version = .py310,
    .vocabulary = .empty,
};

const source_bytes_max: u32 = 1 << 16;
const stack_count_max: u32 = 1 << 12;

fn unescaped(text: []const u8, buffer: []u8) []const u8 {
    assert(buffer.len >= text.len);
    assert(text.len <= source_bytes_max);

    var length: usize = 0;
    var at: usize = 0;

    while (at < text.len) : (at += 1) {
        const escaped = text[at] == '\\' and at + 1 < text.len;

        const replaced: ?u8 = if (escaped) switch (text[at + 1]) {
            'n' => '\n',
            't' => '\t',
            else => null,
        } else null;

        if (replaced) |byte| {
            buffer[length] = byte;
            at += 1;
        } else {
            buffer[length] = text[at];
        }

        length += 1;
    }

    assert(length <= text.len);

    return buffer[0..length];
}

fn kind_name(view: View) []const u8 {
    assert(view.index() < view.node_count());

    const name = switch (view) {
        inline else => |held| @tagName(held.kind()),
    };

    assert(name.len > 0);

    return name;
}

fn shown(front: *const Front, source: []const u8, view: View, depth: u32) void {
    assert(depth < depth_max);
    assert(view.index() < front.node_count());
    assert(front.source.len == source.len);

    const indent: [depth_max * 2]u8 = @splat(' ');

    std.debug.print("{s}{t} #{d} [{d}..{d}]", .{
        indent[0 .. depth * 2],
        view.category(),
        view.index(),
        view.token_start(),
        view.token_end(),
    });

    var positions = view.positions();

    for (0..front.tokens().len + 1) |_| {
        const position = positions.next() orelse break;
        const text = front.tokens()[position].text(source);

        std.debug.print(" \"{s}\"", .{text});
    }

    std.debug.print(" {s}\n", .{kind_name(view)});
}

fn tree_shown(gpa: std.mem.Allocator, front: *const Front, source: []const u8) !void {
    assert(front.source.len == source.len);

    const root = front.root() orelse return;
    var stack: std.ArrayList(Shown) = .empty;
    defer stack.deinit(gpa);

    try stack.append(gpa, .{ .view = root, .depth = 0 });

    for (0..front.node_count() + 1) |_| {
        const top = stack.pop() orelse break;

        shown(front, source, top.view, top.depth);

        const pushed = stack.items.len;
        var children = top.view.children();

        for (0..front.node_count()) |_| {
            const child = children.next() orelse break;

            assert(stack.items.len < stack_count_max);

            try stack.append(gpa, .{ .view = child, .depth = top.depth + 1 });
        }

        std.mem.reverse(Shown, stack.items[pushed..]);
    }

    assert(stack.items.len == 0);
}

fn tables_shown(front: *const Front, source: []const u8) void {
    const bindings = front.bindings();

    assert(source.len <= source_bytes_max);

    for (0..bindings.count()) |index| {
        const binding = bindings.at(@intCast(index));
        const name = binding.name.text(source);
        const values = .{ index, binding.class, name, binding.node, binding.scope };

        std.debug.print("binding #{d} {t} \"{s}\" node #{d} scope {d}\n", values);
    }

    for (0..bindings.reference_count()) |index| {
        const reference = bindings.reference_at(@intCast(index));
        const name = reference.name.text(source);
        const values = .{ index, reference.resolution, name, reference.node, reference.scope };

        std.debug.print("reference #{d} {any} \"{s}\" node #{d} scope {d}\n", values);
    }
}

test "dump" {
    const gpa = std.testing.allocator;
    var named_bytes: [environment.value_bytes_max]u8 = undefined;
    const named = environment.get("DUMP_LANGUAGE", &named_bytes) orelse return;
    var text_bytes: [source_bytes_max]u8 = undefined;
    const text = environment.get("DUMP_SOURCE", &text_bytes) orelse return error.SourceMissing;
    const language = Language.of_name(named) orelse return error.LanguageUnknown;

    if (text.len > source_bytes_max) return error.SourceTooLarge;

    var buffer: [source_bytes_max]u8 = undefined;
    const source = unescaped(text, &buffer);
    var front: Front = undefined;

    try front.init(gpa, &capacity, language);
    defer front.deinit(gpa);

    var wanted: std.EnumSet(Language) = .empty;

    wanted.insert(language);

    var scratch: Scratch = undefined;

    try scratch.init(gpa, &capacity, wanted);
    defer scratch.deinit(gpa);

    front.parse(&scratch, .of(front.language), source, &options) catch |err| {
        std.debug.print("refused {t}\n", .{err});
    };

    std.debug.print("outcome {t}\n", .{front.outcome.?});

    for (front.diagnostics()) |held| {
        const values = .{ held.kind, held.span.offset, held.span.end() };

        std.debug.print("error {t} at {d}..{d}\n", values);
    }

    try tree_shown(gpa, &front, source);
    tables_shown(&front, source);
}
