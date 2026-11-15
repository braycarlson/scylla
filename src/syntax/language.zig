const std = @import("std");
const assert = std.debug.assert;

pub const Language = enum {
    css,
    go,
    javascript,
    markup,
    odin,
    python,
    rust,
    typescript,
    zig,

    pub const count = @typeInfo(Language).@"enum".field_names.len;

    pub fn lexes(language: Language) bool {
        const result = language != .markup;

        if (!result) assert(language.extensions().len == 0);

        return result;
    }

    pub fn extensions(language: Language) []const []const u8 {
        const result: []const []const u8 = switch (language) {
            .css => &.{"css"},
            .go => &.{"go"},
            .javascript => &.{ "cjs", "js", "jsx", "mjs" },
            .markup => &.{},
            .odin => &.{"odin"},
            .python => &.{ "py", "pyi" },
            .rust => &.{"rs"},
            .typescript => &.{ "cts", "mts", "ts", "tsx" },
            .zig => &.{"zig"},
        };

        assert(result.len <= extension_count_per_language_max);

        for (result) |extension| {
            assert(extension.len <= extension_length_max);

            assert(of_extension(extension).? == language);
        }

        return result;
    }

    pub fn name(language: Language) []const u8 {
        const text = @tagName(language);

        assert(of_name(text).? == language);

        return text;
    }

    pub fn of_extension(extension: []const u8) ?Language {
        assert(extension.len > 0);
        assert(std.mem.findScalar(u8, extension, '.') == null);

        const language = extension_languages.get(extension) orelse return null;

        assert(language != .markup);

        return language;
    }

    pub fn of_name(text: []const u8) ?Language {
        assert(text.len <= std.math.maxInt(u32));

        return std.meta.stringToEnum(Language, text);
    }

    pub fn of_path(path: []const u8) ?Language {
        assert(path.len > 0);

        const extension = extension_of(path) orelse return null;

        assert(extension.len > 0);
        assert(extension.len < path.len);

        return of_extension(extension);
    }
};

pub const SourceType = struct {
    flavor: Flavor,
    language: Language,

    pub const Flavor = enum {
        plain,
        stub,
        tsx,
    };

    pub fn of(language: Language) SourceType {
        return .{ .flavor = .plain, .language = language };
    }

    pub fn of_path(path: []const u8) ?SourceType {
        assert(path.len > 0);

        const extension = extension_of(path) orelse return null;
        const language = Language.of_extension(extension) orelse return null;

        const flavor: Flavor = if (std.mem.eql(u8, extension, "pyi"))
            .stub
        else if (std.mem.eql(u8, extension, "tsx"))
            .tsx
        else
            .plain;

        const result: SourceType = .{ .flavor = flavor, .language = language };

        assert(result.valid());

        return result;
    }

    pub fn valid(source_type: SourceType) bool {
        return switch (source_type.flavor) {
            .plain => true,
            .stub => source_type.language == .python,
            .tsx => source_type.language == .typescript,
        };
    }
};

const extension_count_per_language_max: u32 = 4;
const extension_length_max: u32 = 4;
const identifier_length_max: u32 = 16;

comptime {
    for (std.enums.values(Language)) |language| {
        assert(@tagName(language).len <= identifier_length_max);
    }
}

const extension_languages = std.StaticStringMap(Language).initComptime(.{
    .{ "cjs", .javascript },
    .{ "css", .css },
    .{ "cts", .typescript },
    .{ "go", .go },
    .{ "js", .javascript },
    .{ "jsx", .javascript },
    .{ "mjs", .javascript },
    .{ "mts", .typescript },
    .{ "odin", .odin },
    .{ "py", .python },
    .{ "pyi", .python },
    .{ "rs", .rust },
    .{ "ts", .typescript },
    .{ "tsx", .typescript },
    .{ "zig", .zig },
});

fn extension_of(path: []const u8) ?[]const u8 {
    assert(path.len <= std.math.maxInt(u32));

    var dot: ?usize = null;

    for (path, 0..) |byte, offset| {
        if (byte == '/') dot = null;
        if (byte == '.') dot = offset;
    }

    const found = dot orelse return null;
    if (found + 1 >= path.len) return null;

    assert(found < path.len);

    const extension = path[found + 1 ..];

    assert(std.mem.findScalar(u8, extension, '.') == null);
    assert(std.mem.findScalar(u8, extension, '/') == null);

    return extension;
}

test Language {
    try std.testing.expectEqual(Language.zig, Language.of_extension("zig").?);
    try std.testing.expectEqual(Language.python, Language.of_name("python").?);
    try std.testing.expect(Language.zig.lexes());
    try std.testing.expectEqualStrings("zig", Language.zig.name());
}

test SourceType {
    const tsx = SourceType.of_path("src/app.tsx").?;
    const stub = SourceType.of_path("typing.pyi").?;

    try std.testing.expectEqual(Language.typescript, tsx.language);
    try std.testing.expectEqual(SourceType.Flavor.tsx, tsx.flavor);
    try std.testing.expectEqual(SourceType.Flavor.stub, stub.flavor);
    try std.testing.expectEqual(SourceType.of(.zig), SourceType.of_path("main.zig").?);
    try std.testing.expect(!SourceType.valid(.{ .flavor = .tsx, .language = .python }));
}

test "an extension comes from the last dot" {
    try std.testing.expectEqualStrings("rs", extension_of("file:///tmp/main.rs").?);
    try std.testing.expectEqualStrings("py", extension_of("/a.b/main.py").?);
    try std.testing.expectEqual(null, extension_of("/a.b/Makefile"));
    try std.testing.expectEqual(null, extension_of("main."));
    try std.testing.expectEqual(null, extension_of(""));
    try std.testing.expectEqualStrings("2\\Makefile", extension_of("C:\\v1.2\\Makefile").?);
    try std.testing.expectEqualStrings("rs", extension_of("C:\\work\\main.rs").?);
}

test "a path resolves to its language by extension" {
    try std.testing.expectEqual(Language.zig, Language.of_path("src/stdx/iops.zig").?);
    try std.testing.expectEqual(Language.typescript, Language.of_path("app/view.tsx").?);
    try std.testing.expectEqual(Language.typescript, Language.of_path("a.d.ts").?);
    try std.testing.expectEqual(Language.javascript, Language.of_path("x.cjs").?);
    try std.testing.expectEqual(Language.zig, Language.of_path(".zig").?);
}

test "a path without a known extension resolves to nothing" {
    try std.testing.expectEqual(null, Language.of_path("README.md"));
    try std.testing.expectEqual(null, Language.of_path("Makefile"));
    try std.testing.expectEqual(null, Language.of_path("trailing."));
    try std.testing.expectEqual(null, Language.of_path("dir.zig/file"));
    try std.testing.expectEqual(null, Language.of_path("page.markup"));
}

test "a source type reads its dialect from the path" {
    const marked = SourceType.of_path("src/app.tsx").?;
    const plain = SourceType.of_path("src/app.ts").?;

    try std.testing.expectEqual(Language.typescript, marked.language);
    try std.testing.expectEqual(SourceType.Flavor.tsx, marked.flavor);
    try std.testing.expectEqual(Language.typescript, plain.language);
    try std.testing.expectEqual(SourceType.Flavor.plain, plain.flavor);
    try std.testing.expectEqual(SourceType.Flavor.plain, SourceType.of(.javascript).flavor);
    try std.testing.expectEqual(null, SourceType.of_path("README"));
}

test "a source type reads a python stub from the path" {
    const stub = SourceType.of_path("stdlib/os/__init__.pyi").?;
    const module = SourceType.of_path("stdlib/os/__init__.py").?;

    try std.testing.expectEqual(Language.python, stub.language);
    try std.testing.expectEqual(SourceType.Flavor.stub, stub.flavor);
    try std.testing.expectEqual(Language.python, module.language);
    try std.testing.expectEqual(SourceType.Flavor.plain, module.flavor);
    try std.testing.expectEqual(SourceType.Flavor.plain, SourceType.of(.python).flavor);
}

test "a language is found by its name" {
    try std.testing.expectEqual(Language.typescript, Language.of_name("typescript").?);
    try std.testing.expectEqual(Language.markup, Language.of_name("markup").?);
    try std.testing.expectEqual(null, Language.of_name("cobol"));
    try std.testing.expectEqualStrings("javascript", Language.javascript.name());
}
