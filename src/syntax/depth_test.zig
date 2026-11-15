const std = @import("std");
const assert = std.debug.assert;
const Front = @import("front.zig").Front;
const Language = @import("language.zig").Language;
const Capacity = @import("front.zig").Front.Capacity;
const Options = @import("front.zig").Front.Options;
const Scratch = @import("front.zig").Front.Scratch;

const Case = struct {
    close: []const u8,
    language: Language,
    open: []const u8,
    separator: []const u8,
};

const Read = struct {
    error_count: u32,
    parsed: Front.Error!void,
};

const element_count: u32 = 4_096;
const source_bytes_max: u32 = 1 << 17;

const every_case = [_]Case{
    .{ .close = "}\n", .language = .css, .open = ":root {\n", .separator = "" },
    .{
        .close = "}\n",
        .language = .go,
        .open = "package held\n\nvar Held = []int{",
        .separator = ", ",
    },
    .{ .close = "];\n", .language = .javascript, .open = "const held = [", .separator = ", " },
    .{
        .close = "}\n",
        .language = .odin,
        .open = "package held\n\nheld := []int{",
        .separator = ", ",
    },
    .{ .close = "]\n", .language = .python, .open = "held = [", .separator = ", " },
    .{
        .close = "];\n",
        .language = .rust,
        .open = "pub const HELD: &[u32] = &[",
        .separator = ", ",
    },
    .{ .close = "];\n", .language = .typescript, .open = "const held = [", .separator = ", " },
    .{
        .close = "};\n",
        .language = .zig,
        .open = "pub const held = [_]u32{",
        .separator = ", ",
    },
};

const capacity_test: Capacity = .{
    .diagnostic_count_max = 1 << 10,
    .event_count_max = 1 << 22,
    .node_count_max = 1 << 20,
    .semantic = .{
        .binding_count_max = 1 << 14,
        .fact_count_max = 1 << 12,
        .reference_count_max = 1 << 14,
        .scope_count_max = 1 << 12,
    },
    .tag_count_max = 1 << 12,
    .token_count_max = 1 << 20,
};

const options_test: Options = .{
    .globals = &.{},
    .python_version = .py310,
    .vocabulary = .empty,
};

fn source_of(case: *const Case, buffer: []u8) ![]const u8 {
    assert(buffer.len == source_bytes_max);

    var writer: std.Io.Writer = .fixed(buffer);

    assert(case.open.len > 0);

    try writer.writeAll(case.open);

    for (0..element_count) |index| {
        if (index > 0) try writer.writeAll(case.separator);

        if (case.language == .css) {
            try writer.print("    --k{d}: 0;\n", .{index});

            continue;
        }

        try writer.print("{d}", .{index % 9});
    }

    try writer.writeAll(case.close);

    return writer.buffered();
}

fn read(language: Language, source: []const u8) !Read {
    const gpa = std.testing.allocator;

    assert(source.len <= source_bytes_max);
    assert(language != .markup);

    var scratch: Scratch = undefined;

    try scratch.init(gpa, &capacity_test, .initOne(language));
    defer scratch.deinit(gpa);

    var front: Front = undefined;

    try front.init(gpa, &capacity_test, language);
    defer front.deinit(gpa);

    const parsed = front.parse(&scratch, .of(front.language), source, &options_test);
    return .{ .error_count = @intCast(front.diagnostics().len), .parsed = parsed };
}

test "a flat literal of four thousand elements is not nesting" {
    const gpa = std.testing.allocator;
    const buffer = try gpa.alloc(u8, source_bytes_max);
    defer gpa.free(buffer);

    for (&every_case) |*case| {
        errdefer std.debug.print("{s} reads {d} flat elements\n", .{
            case.language.name(),
            element_count,
        });

        const source = try source_of(case, buffer);
        const held = try read(case.language, source);

        try held.parsed;
        try std.testing.expectEqual(0, held.error_count);
    }
}
