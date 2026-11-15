const std = @import("std");
const assert = std.debug.assert;
const Category = @import("category.zig").Category;

const every_kind_module = .{
    @import("css/kind.zig"),
    @import("go/kind.zig"),
    @import("javascript/kind.zig"),
    @import("odin/kind.zig"),
    @import("python/kind.zig"),
    @import("rust/kind.zig"),
    @import("zig/kind.zig"),
};

fn projection_expect_every_kind(comptime module: type) !void {
    var kind_read: u32 = 0;

    comptime assert(module.kind_count > 0);
    comptime assert(@hasDecl(module.Kind, "category"));

    for (0..module.kind_count) |discriminant| {
        const kind = module.Kind.of_u16(@intCast(discriminant)).?;
        const category = kind.category();

        try std.testing.expect(category_listed(category));
        try std.testing.expectEqual(category, kind.category());

        kind_read += 1;
    }

    try std.testing.expectEqual(module.kind_count, kind_read);
    try std.testing.expectEqual(null, module.Kind.of_u16(module.kind_count));
}

fn projection_expect_more_than_one(comptime module: type) !void {
    var seen: u32 = 0;

    comptime assert(module.kind_count > 0);
    comptime assert(Category.count <= 32);

    for (0..module.kind_count) |discriminant| {
        const kind = module.Kind.of_u16(@intCast(discriminant)).?;

        seen |= @as(u32, 1) << @intCast(kind.category().index());
    }

    try std.testing.expect(@popCount(seen) > 1);
}

fn category_listed(category: Category) bool {
    const listed = std.enums.values(Category);

    assert(listed.len == Category.count);
    assert(category.index() < Category.count);

    return std.mem.findScalar(Category, listed, category) != null;
}

test "every kind projects onto one category" {
    inline for (every_kind_module) |module| {
        try projection_expect_every_kind(module);
    }
}

test "the projection reaches more than one category" {
    inline for (every_kind_module) |module| {
        try projection_expect_more_than_one(module);
    }
}
