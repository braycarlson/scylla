const std = @import("std");
const assert = std.debug.assert;

pub const Format = enum {
    azure,
    concise,
    full,
    github,
    gitlab,
    grouped,
    json,
    json_lines,
    junit,
    pylint,
    rdjson,
    sarif,

    pub fn colors(format: Format) bool {
        const result = switch (format) {
            .concise, .full, .grouped => true,
            .azure, .github, .gitlab, .json, .json_lines, .junit, .pylint, .rdjson, .sarif => false,
        };

        if (result) assert(format != .sarif);

        return result;
    }

    pub fn name(format: Format) []const u8 {
        const result: []const u8 = switch (format) {
            .azure => "azure",
            .concise => "concise",
            .full => "full",
            .github => "github",
            .gitlab => "gitlab",
            .grouped => "grouped",
            .json => "json",
            .json_lines => "json-lines",
            .junit => "junit",
            .pylint => "pylint",
            .rdjson => "rdjson",
            .sarif => "sarif",
        };

        assert(result.len > 0);
        assert(result.len <= format_name_bytes_max);

        return result;
    }

    pub fn of(text: []const u8) ?Format {
        if (text.len > format_name_bytes_max) return null;

        for (format_names) |entry| {
            if (std.mem.eql(u8, entry.name, text)) {
                assert(entry.name.len == text.len);

                return entry.format;
            }
        }

        return null;
    }
};

const FormatName = struct {
    format: Format,
    name: []const u8,
};

const format_name_bytes_max: u32 = 16;

const format_names = [_]FormatName{
    .{ .format = .azure, .name = "azure" },
    .{ .format = .concise, .name = "concise" },
    .{ .format = .concise, .name = "text" },
    .{ .format = .full, .name = "full" },
    .{ .format = .full, .name = "human" },
    .{ .format = .github, .name = "github" },
    .{ .format = .gitlab, .name = "gitlab" },
    .{ .format = .grouped, .name = "grouped" },
    .{ .format = .json, .name = "json" },
    .{ .format = .json_lines, .name = "json-lines" },
    .{ .format = .junit, .name = "junit" },
    .{ .format = .pylint, .name = "pylint" },
    .{ .format = .rdjson, .name = "rdjson" },
    .{ .format = .sarif, .name = "sarif" },
};

test Format {
    const format = Format.of("json-lines") orelse return error.TestUnexpectedResult;

    try std.testing.expectEqual(Format.json_lines, format);
    try std.testing.expect(!format.colors());
    try std.testing.expect(Format.full.colors());
}

test "every format name parses and spells itself" {
    const formats = [_]Format{
        .azure,
        .concise,
        .full,
        .github,
        .gitlab,
        .grouped,
        .json,
        .json_lines,
        .junit,
        .pylint,
        .rdjson,
        .sarif,
    };

    for (formats) |format| {
        try std.testing.expectEqual(@as(?Format, format), Format.of(format.name()));
    }

    try std.testing.expectEqual(@as(?Format, .concise), Format.of("text"));
    try std.testing.expectEqual(@as(?Format, .full), Format.of("human"));
    try std.testing.expectEqual(@as(?Format, null), Format.of("nonsense"));
    try std.testing.expect(Format.grouped.colors());
    try std.testing.expect(!Format.sarif.colors());
}
