const std = @import("std");
const assert = std.debug.assert;

pub const Vocabulary = struct {
    dialect: Dialect,
    end_prefix: ?[]const u8,
    extends_tags: []const []const u8,
    intermediate_words: []const []const u8,
    only_word: ?[]const u8,
    raw_text_tags: []const RawTextTag,
    specifications: []const TagSpecification,
    template_imports: []const []const u8,

    pub const Dialect = enum {
        html,
        django,
    };

    pub const RawTextTag = struct {
        body: Body,
        end: []const u8,
        name: []const u8,
        stage: Stage,

        pub const Body = enum {
            markup,
            text,
        };

        pub const Stage = enum {
            lexer,
            parser,
        };
    };

    pub const TagSpecification = struct {
        intermediates: []const []const u8,
        name: []const u8,
    };

    pub const empty: Vocabulary = .{
        .dialect = .html,
        .end_prefix = null,
        .extends_tags = &.{},
        .intermediate_words = &.{},
        .only_word = null,
        .raw_text_tags = &.{},
        .specifications = &.{},
        .template_imports = &.{},
    };

    pub fn pairs(vocabulary: *const Vocabulary) bool {
        const result = vocabulary.end_prefix != null or vocabulary.specifications.len > 0;

        if (vocabulary.end_prefix) |prefix| assert(prefix.len > 0);

        return result;
    }

    pub fn specification_of(
        vocabulary: *const Vocabulary,
        name: []const u8,
    ) ?*const TagSpecification {
        assert(name.len > 0);
        assert(vocabulary.specifications.len <= std.math.maxInt(u32));

        for (vocabulary.specifications) |*specification| {
            if (std.mem.eql(u8, specification.name, name)) return specification;
        }

        return null;
    }
};

test Vocabulary {
    const django: Vocabulary = .{
        .dialect = .html,
        .end_prefix = "end",
        .extends_tags = &.{"extends"},
        .intermediate_words = &.{ "elif", "else" },
        .only_word = "only",
        .raw_text_tags = &.{
            .{ .body = .text, .end = "endverbatim", .name = "verbatim", .stage = .lexer },
        },
        .specifications = &.{.{ .intermediates = &.{ "elif", "else" }, .name = "if" }},
        .template_imports = &.{ "extends", "include" },
    };

    const specification = django.specification_of("if") orelse return error.TestUnexpectedResult;

    try std.testing.expectEqual(2, specification.intermediates.len);
    try std.testing.expect(django.specification_of("for") == null);
    try std.testing.expect(Vocabulary.empty.specification_of("if") == null);
    try std.testing.expect(django.pairs());
    try std.testing.expect(!Vocabulary.empty.pairs());
    try std.testing.expectEqual(Vocabulary.Dialect.html, Vocabulary.empty.dialect);
}
