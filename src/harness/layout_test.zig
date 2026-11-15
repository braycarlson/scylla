const std = @import("std");
const EventsType = @import("../syntax/tree.zig").EventsType;
const Token = @import("../syntax/token.zig");
const TreeType = @import("../syntax/tree.zig").TreeType;
const css = @import("../syntax/css/semantic.zig");
const go = @import("../syntax/go/semantic.zig");
const javascript = @import("../syntax/javascript/semantic.zig");
const odin = @import("../syntax/odin/semantic.zig");
const python = @import("../syntax/python/semantic.zig");
const rust = @import("../syntax/rust/semantic.zig");
const rust_kind = @import("../syntax/rust/kind.zig");
const zig = @import("../syntax/zig/semantic.zig");

test "the hot rows hold their size" {
    try std.testing.expectEqual(12, @sizeOf(Token));
    try std.testing.expectEqual(24, @sizeOf(TreeType(rust_kind.Kind).Node));
    try std.testing.expectEqual(24, @sizeOf(css.Definition));
    try std.testing.expectEqual(44, @sizeOf(go.Semantic.Binding));
    try std.testing.expectEqual(32, @sizeOf(go.Semantic.Reference));
    try std.testing.expectEqual(44, @sizeOf(javascript.Semantic.Binding));
    try std.testing.expectEqual(32, @sizeOf(javascript.Semantic.Reference));
    try std.testing.expectEqual(44, @sizeOf(odin.Semantic.Binding));
    try std.testing.expectEqual(56, @sizeOf(python.Semantic.Binding));
    try std.testing.expectEqual(44, @sizeOf(python.Semantic.Reference));
    try std.testing.expectEqual(44, @sizeOf(rust.Semantic.Binding));
    try std.testing.expectEqual(44, @sizeOf(zig.Semantic.Binding));
}

test "the replay stacks live on the reserved table" {
    try std.testing.expectEqual(20_512, @sizeOf(EventsType(rust_kind.Kind)));
}
