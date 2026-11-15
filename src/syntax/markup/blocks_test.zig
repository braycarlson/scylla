const std = @import("std");
const assert = std.debug.assert;
const Document = @import("document.zig").Document;
const Vocabulary = @import("vocabulary.zig").Vocabulary;
const markup_testing = @import("../testing/markup.zig");
const TagSpecification = Vocabulary.TagSpecification;

const Built = struct {
    document: Document,
    map: *const Document.Blocks,
    source: []const u8,

    fn init(built: *Built, gpa: std.mem.Allocator, source: []const u8) !void {
        assert(source.len <= std.math.maxInt(u32));

        built.document = try .init(gpa, capacity);
        errdefer built.document.deinit(gpa);

        built.source = source;

        try built.document.parse(source, &vocabulary);

        built.map = built.document.blocks();

        assert(built.map.tag_slice().len <= tag_count_max);
    }

    fn deinit(built: *Built, gpa: std.mem.Allocator) void {
        built.document.deinit(gpa);
        built.* = undefined;
    }

    fn expect_intermediates(
        built: *const Built,
        name: []const u8,
        expected: []const []const u8,
    ) !void {
        assert(name.len > 0);

        const block = for (built.map.block_slice()) |*block| {
            if (std.mem.eql(u8, built.name_of(block.open.name_token), name)) break block;
        } else {
            std.debug.print("the {s} block does not pair\n", .{name});

            return error.TestUnexpectedResult;
        };

        const intermediates = built.map.intermediates_of(block);

        try std.testing.expectEqual(expected.len, intermediates.len);

        for (intermediates, expected) |tag, text| {
            try std.testing.expectEqualStrings(text, built.name_of(tag.name_token));
        }
    }

    fn expect_names(built: *const Built, expected: []const Named) !void {
        const held = built.map.block_slice();

        try std.testing.expectEqual(expected.len, held.len);

        for (held, expected) |*block, named| {
            try std.testing.expectEqualStrings(named.name, built.name_of(block.open.name_token));
            try std.testing.expectEqual(named.closed, block.is_closed());
        }
    }

    fn name_of(built: *const Built, token: u32) []const u8 {
        const tokens = built.document.tokens();

        assert(token < tokens.len);

        return tokens[token].text(built.source);
    }
};

const Named = struct {
    closed: bool,
    name: []const u8,
};

const capacity: Document.Capacity = .{
    .diagnostic_count_max = 1 << 10,
    .node_count_max = 1 << 12,
    .tag_count_max = tag_count_max,
    .token_count_max = 1 << 14,
};

const tag_count_max: u32 = 1 << 11;

const specifications = [_]TagSpecification{
    .{ .intermediates = &.{"empty"}, .name = "for" },
    .{ .intermediates = &.{ "elif", "else" }, .name = "if" },
    .{ .intermediates = &.{"else"}, .name = "ifequal" },
    .{ .intermediates = &.{"plural"}, .name = "blocktranslate" },
};

const words = [_][]const u8{ "elif", "else", "empty", "plural" };

const vocabulary: Vocabulary = .{
    .dialect = .html,
    .end_prefix = "end",
    .extends_tags = &.{},
    .intermediate_words = &words,
    .only_word = null,
    .raw_text_tags = &markup_testing.raw_text_tags,
    .specifications = &specifications,
    .template_imports = &.{},
};

test "a simple block pairs" {
    const gpa = std.testing.allocator;
    var built: Built = undefined;

    try built.init(gpa, "{% if x %}a{% endif %}");
    defer built.deinit(gpa);

    try built.expect_names(&.{.{ .closed = true, .name = "if" }});
}

test "a block pairs across element boundaries" {
    const gpa = std.testing.allocator;
    var built: Built = undefined;

    try built.init(gpa, "{% if x %}<div>{% endif %}</div>");
    defer built.deinit(gpa);

    try built.expect_names(&.{.{ .closed = true, .name = "if" }});
}

test "an intermediate attaches without opening a block of its own" {
    const gpa = std.testing.allocator;
    var built: Built = undefined;

    try built.init(gpa, "{% for a in b %}x{% empty %}y{% endfor %}");
    defer built.deinit(gpa);

    try std.testing.expectEqual(1, built.map.block_slice().len);
    try built.expect_intermediates("for", &.{"empty"});
}

test "a known opener with no end is reported" {
    const gpa = std.testing.allocator;
    var built: Built = undefined;

    try built.init(gpa, "{% if x %}body");
    defer built.deinit(gpa);

    try std.testing.expectEqual(1, built.map.unmatched_opener_slice().len);
    try std.testing.expectEqual(0, built.map.unmatched_closer_slice().len);
}

test "a single tag is not reported as unclosed" {
    const gpa = std.testing.allocator;
    var built: Built = undefined;

    try built.init(gpa, "{% django_glue_init %}{% csrf_token %}");
    defer built.deinit(gpa);

    try std.testing.expectEqual(0, built.map.unmatched_opener_slice().len);
}

test "a custom tag pairs generically" {
    const gpa = std.testing.allocator;
    var built: Built = undefined;

    try built.init(gpa, "{% mytag %}body{% endmytag %}");
    defer built.deinit(gpa);

    try std.testing.expectEqual(1, built.map.block_slice().len);
    try std.testing.expect(built.map.block_slice()[0].is_closed());
}

test "a closer with no opener is reported" {
    const gpa = std.testing.allocator;
    var built: Built = undefined;

    try built.init(gpa, "{% endif %}");
    defer built.deinit(gpa);

    try std.testing.expectEqual(1, built.map.unmatched_closer_slice().len);
}

test "a legacy block still pairs" {
    const gpa = std.testing.allocator;
    var built: Built = undefined;

    try built.init(gpa, "{% ifequal a b %}x{% else %}y{% endifequal %}");
    defer built.deinit(gpa);

    try built.expect_names(&.{.{ .closed = true, .name = "ifequal" }});
}

test "a crossed pair is tolerated" {
    const gpa = std.testing.allocator;
    var built: Built = undefined;

    try built.init(gpa, "{% if a %}{% for b in c %}{% endif %}{% endfor %}");
    defer built.deinit(gpa);

    try std.testing.expectEqual(2, built.map.block_slice().len);
    try std.testing.expectEqual(1, built.map.unmatched_opener_slice().len);
}

test "an intermediate reaches past a tag that opens no block" {
    const gpa = std.testing.allocator;
    var built: Built = undefined;

    try built.init(
        gpa,
        "{% for item in items %}\n{% cycle 'a' 'b' %}\n{% empty %}\nnone\n{% endfor %}\n",
    );

    defer built.deinit(gpa);

    try built.expect_intermediates("for", &.{"empty"});
}

test "an intermediate does not reach past another open block" {
    const gpa = std.testing.allocator;
    var built: Built = undefined;

    try built.init(
        gpa,
        "{% for item in items %}\n{% if x %}\n{% empty %}\n{% endif %}\n{% endfor %}\n",
    );

    defer built.deinit(gpa);

    try built.expect_intermediates("for", &.{});
}

test "the blocks come back sorted by span" {
    const gpa = std.testing.allocator;
    var built: Built = undefined;

    try built.init(gpa, "{% if a %}{% for b in c %}{% endfor %}{% endif %}{% if d %}{% endif %}");
    defer built.deinit(gpa);

    const held = built.map.block_slice();

    for (held[0..held.len -| 1], held[@min(held.len, 1)..]) |before, after| {
        const ordered = if (before.span.offset == after.span.offset)
            before.span.end() <= after.span.end()
        else
            before.span.offset < after.span.offset;

        try std.testing.expect(ordered);
    }
}

test "every tag the tree carries is collected" {
    const gpa = std.testing.allocator;
    var built: Built = undefined;

    try built.init(gpa, "{% if a %}{{ value }}{% endif %}{# note #}{% for b in c %}{% endfor %}");
    defer built.deinit(gpa);

    try std.testing.expectEqual(4, built.map.tag_slice().len);
}
