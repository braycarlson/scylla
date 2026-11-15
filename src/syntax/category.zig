const std = @import("std");
const assert = std.debug.assert;

pub const Category = enum(u8) {
    assignment,
    attribute,
    block,
    branch,
    call,
    condition,
    declaration,
    except,
    expression,
    file,
    function,
    import,
    lambda,
    loop,
    match,
    name,
    other,
    parameter,
    parameters,
    @"return",
    @"struct",
    @"try",
    type,
    value,

    pub const count = @typeInfo(Category).@"enum".field_names.len;

    pub fn index(category: Category) u32 {
        const position: u32 = @backingInt(category);

        assert(position < count);

        return position;
    }

    pub fn title(category: Category) []const u8 {
        const text: []const u8 = switch (category) {
            inline else => |tag| comptime camel_of(@tagName(tag)),
        };

        assert(text.len > 0);
        assert(std.ascii.isUpper(text[0]));

        return text;
    }
};

pub fn camel_of(comptime snake: []const u8) []const u8 {
    assert(snake.len > 0);

    comptime {
        assert(snake.len > 0);
        assert(std.ascii.isLower(snake[0]));

        var buffer: [snake.len]u8 = undefined;
        var length: usize = 0;
        var upper = true;

        for (snake) |byte| {
            if (byte == '_') {
                upper = true;

                continue;
            }

            buffer[length] = if (upper) std.ascii.toUpper(byte) else byte;
            length += 1;
            upper = false;
        }

        assert(length > 0);
        assert((length == snake.len) == (std.mem.findScalar(u8, snake, '_') == null));

        const camel = buffer[0..length].*;

        assert(std.ascii.isUpper(camel[0]));
        assert(std.mem.findScalar(u8, &camel, '_') == null);

        return &camel;
    }
}

comptime {
    assert(Category.count == 24);
}

test "every category is named in title case and indexed in order" {
    for (std.enums.values(Category), 0..) |category, position| {
        try std.testing.expectEqual(position, category.index());
        try std.testing.expect(std.ascii.isUpper(category.title()[0]));
    }

    try std.testing.expectEqualStrings("Assignment", Category.assignment.title());
    try std.testing.expectEqualStrings("Return", Category.@"return".title());
    try std.testing.expectEqualStrings("Value", Category.value.title());
}
