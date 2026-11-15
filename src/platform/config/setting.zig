const std = @import("std");
const assert = std.debug.assert;
const Buffer = @import("../../stdx/bounded/buffer.zig");
const json = @import("json");

default: []const u8,
description: []const u8,
example: []const u8,
kind: Kind,
name: []const u8,

const Setting = @This();

pub const Kind = enum {
    boolean,
    integer,
    map,
    strings,
    text,

    fn schema(kind: Kind) []const u8 {
        return switch (kind) {
            .boolean => "boolean",
            .integer => "integer",
            .map => "object",
            .strings => "array",
            .text => "string",
        };
    }
};

pub const CapacityError = error{Overflow};
pub const name_bytes_max: u32 = 64;
const schema_uri = "https://json-schema.org/draft/2020-12/schema";

pub fn documentation_write(out: *Buffer, settings: []const Setting) CapacityError!void {
    assert(settings.len <= std.math.maxInt(u32));

    const written_before = out.count();

    try out.push("# Settings\n\n");
    try out.push("Every key is accepted in `snake_case` and `kebab-case`.\n\n");

    for (settings) |*setting| {
        try documentation_setting_write(out, setting);
    }

    assert(out.count() > written_before);
}

fn documentation_setting_write(out: *Buffer, setting: *const Setting) CapacityError!void {
    assert(setting.name.len > 0);
    assert(setting.example.len > 0);

    try out.push("## `");
    try out.push(setting.name);
    try out.push("`\n\n");
    try out.push(setting.description);
    try out.push("\n\n");

    if (setting.default.len > 0) {
        try out.push("Default: `");
        try out.push(setting.default);
        try out.push("`\n\n");
    }

    try out.push("```toml\n");
    try out.push(setting.example);
    try out.push("\n```\n\n");
}

pub fn kebab_of(name: []const u8, buffer: *[name_bytes_max]u8) ?[]const u8 {
    assert(name.len <= name_bytes_max);

    var underscored = false;

    for (name, 0..) |byte, index| {
        if (byte == '_') {
            buffer[index] = '-';
            underscored = true;

            continue;
        }

        buffer[index] = byte;
    }

    if (!underscored) return null;

    const spelled = buffer[0..name.len];

    assert(std.mem.findScalar(u8, spelled, '_') == null);

    return spelled;
}

pub fn schema_write(
    writer: *json.Writer,
    title: []const u8,
    settings: []const Setting,
) json.Writer.Error!void {
    assert(title.len > 0);
    assert(settings.len > 0);

    try writer.object_begin();
    try writer.key("$schema");
    try writer.string(schema_uri);
    try writer.key("title");
    try writer.string(title);
    try writer.key("type");
    try writer.string("object");
    try writer.key("additionalProperties");
    try writer.boolean(false);
    try writer.key("properties");
    try writer.object_begin();

    for (settings) |*setting| {
        var kebab: [name_bytes_max]u8 = undefined;

        try setting.property_write(writer, setting.name);

        if (kebab_of(setting.name, &kebab)) |spelled| {
            try setting.property_write(writer, spelled);
        }
    }

    try writer.object_end();
    try writer.object_end();
}

fn default_write(setting: *const Setting, writer: *json.Writer) json.Writer.Error!void {
    assert(setting.default.len > 0);

    switch (setting.kind) {
        .boolean, .integer => try writer.raw(setting.default),
        .map, .strings, .text => try writer.string(setting.default),
    }
}

fn property_write(
    setting: *const Setting,
    writer: *json.Writer,
    spelling: []const u8,
) json.Writer.Error!void {
    assert(spelling.len > 0);
    assert(spelling.len == setting.name.len);

    try writer.key(spelling);
    try writer.object_begin();
    try writer.key("type");
    try writer.string(setting.kind.schema());
    try writer.key("description");
    try writer.string(setting.description);

    if (setting.default.len > 0) {
        try writer.key("default");
        try setting.default_write(writer);
    }

    try writer.object_end();
}

const test_settings = [_]Setting{
    .{
        .default = "2",
        .description = "The assertions a function is expected to carry.",
        .example = "assertions_min = 2",
        .kind = .integer,
        .name = "assertions_min",
    },
    .{
        .default = "",
        .description = "A \"quoted\" description.",
        .example = "select = []",
        .kind = .strings,
        .name = "select",
    },
    .{
        .default = "auto",
        .description = "Colour.",
        .example = "color = \"auto\"",
        .kind = .text,
        .name = "color",
    },
};

fn test_contains(text: []const u8, needle: []const u8) bool {
    assert(text.len <= std.math.maxInt(u32));
    assert(needle.len <= std.math.maxInt(u32));

    return std.mem.find(u8, text, needle) != null;
}

test Setting {
    var out = try Buffer.init(std.testing.allocator, 1 << 10);
    defer out.deinit(std.testing.allocator);

    try documentation_write(&out, test_settings[0..1]);

    const text = out.const_slice();
    var kebab: [name_bytes_max]u8 = undefined;
    const spelled = kebab_of("assertions_min", &kebab) orelse return error.KebabMissing;

    try std.testing.expect(test_contains(text, "## `assertions_min`\n\n"));
    try std.testing.expect(test_contains(text, "Default: `2`\n\n"));
    try std.testing.expectEqualStrings("assertions-min", spelled);
}

test "a schema lists each setting under both spellings" {
    var bytes: [1 << 12]u8 = undefined;
    var sink: std.Io.Writer = .fixed(&bytes);
    var writer: json.Writer = .init(&sink, .{});

    try schema_write(&writer, "tool.toml", &test_settings);

    writer.finish();

    const text = sink.buffered();

    const head = "{\"$schema\":\"https://json-schema.org/draft/2020-12/schema\"," ++
        "\"title\":\"tool.toml\",";

    const assertions = "\"assertions_min\":{\"type\":\"integer\",\"description\":" ++
        "\"The assertions a function is expected to carry.\",\"default\":2}";

    const select = "\"select\":{\"type\":\"array\",\"description\":" ++
        "\"A \\\"quoted\\\" description.\"";

    const color = "\"color\":{\"type\":\"string\",\"description\":\"Colour.\"," ++
        "\"default\":\"auto\"}";

    try std.testing.expect(std.unicode.utf8ValidateSlice(text));
    try std.testing.expect(std.mem.startsWith(u8, text, head));
    try std.testing.expect(test_contains(text, "\"additionalProperties\":false"));
    try std.testing.expect(test_contains(text, assertions));
    try std.testing.expect(test_contains(text, "\"assertions-min\":{\"type\":\"integer\""));
    try std.testing.expect(test_contains(text, select ++ "}"));
    try std.testing.expect(!test_contains(text, select ++ ",\"default\""));
    try std.testing.expect(test_contains(text, color));
    try std.testing.expectEqual(1, std.mem.count(u8, text, "\"color\""));
    try std.testing.expect(std.mem.endsWith(u8, text, "}}"));
}

test "the documentation writes a section for each setting" {
    var out = try Buffer.init(std.testing.allocator, 1 << 12);
    defer out.deinit(std.testing.allocator);

    try documentation_write(&out, &test_settings);

    const text = out.const_slice();

    const head = "# Settings\n\nEvery key is accepted in `snake_case` and `kebab-case`.\n\n" ++
        "## `assertions_min`\n\n";

    const assertions = "Default: `2`\n\n```toml\nassertions_min = 2\n```\n";
    const select = "## `select`\n\nA \"quoted\" description.\n\n```toml\nselect = []\n```\n";

    try std.testing.expect(std.mem.startsWith(u8, text, head));
    try std.testing.expect(test_contains(text, assertions));
    try std.testing.expect(test_contains(text, select));
    try std.testing.expect(!test_contains(text, "Default: ``"));

    var small = try Buffer.init(std.testing.allocator, 16);
    defer small.deinit(std.testing.allocator);

    try std.testing.expectError(error.Overflow, documentation_write(&small, &test_settings));
}

test "a kebab spelling appears only where an underscore did" {
    var buffer: [name_bytes_max]u8 = undefined;
    const spelled = kebab_of("line_length_max", &buffer) orelse return error.TestUnexpectedResult;

    try std.testing.expectEqualStrings("line-length-max", spelled);
    try std.testing.expect(kebab_of("select", &buffer) == null);
    try std.testing.expectEqualStrings("object", Kind.map.schema());
    try std.testing.expectEqualStrings("boolean", Kind.boolean.schema());
}
