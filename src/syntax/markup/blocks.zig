const std = @import("std");
const assert = std.debug.assert;
const ArrayType = @import("../../stdx/bounded/array.zig").ArrayType;
const Document = @import("document.zig").Document;
const Span = @import("../../stdx/bounded/span.zig");
const Structure = @import("../tree.zig").Structure;
const Token = @import("token.zig").Token;
const Tree = @import("tree.zig").Tree;
const View = @import("view.zig").View;
const Vocabulary = @import("vocabulary.zig").Vocabulary;
const sort = @import("../../stdx/sort.zig");
const TagSpecification = Vocabulary.TagSpecification;

pub const Blocks = struct {
    blocks: ArrayType(Block),
    intermediates: ArrayType(Tag),
    scratch: []Tag,
    stack: ArrayType(OpenBlock),
    tags: ArrayType(Tag),
    unmatched_closers: ArrayType(Tag),
    unmatched_openers: ArrayType(Tag),

    pub const Block = struct {
        close: ?Tag,
        intermediate_count: u32,
        intermediate_first: u32,
        open: Tag,
        span: Span,

        pub fn is_closed(block: *const Block) bool {
            const closed = block.close != null;

            if (closed) assert(block.close.?.span.end() == block.span.end());

            assert(block.open.span.offset == block.span.offset);

            return closed;
        }
    };

    pub const OpenBlock = struct {
        intermediate_count: u32,
        known: bool,
        open: Tag,
    };

    pub const Tag = struct {
        name_token: u32,
        span: Span,

        pub fn name(tag: Tag, tokens: []const Token, source: []const u8) []const u8 {
            assert(tag.name_token < tokens.len);
            assert(source.len <= std.math.maxInt(u32));

            const held = tokens[tag.name_token].text(source);

            assert(held.len > 0);

            return held;
        }
    };

    pub fn init(gpa: std.mem.Allocator, tag_count_max: u32) std.mem.Allocator.Error!Blocks {
        assert(tag_count_max > 0);

        var blocks: ArrayType(Block) = try .init(gpa, tag_count_max);
        errdefer blocks.deinit(gpa);

        var intermediates: ArrayType(Tag) = try .init(gpa, tag_count_max);
        errdefer intermediates.deinit(gpa);

        const scratch = try gpa.alloc(Tag, scratch_count);
        errdefer gpa.free(scratch);

        var stack: ArrayType(OpenBlock) = try .init(gpa, block_depth_max);
        errdefer stack.deinit(gpa);

        var tags: ArrayType(Tag) = try .init(gpa, tag_count_max);
        errdefer tags.deinit(gpa);

        var unmatched_closers: ArrayType(Tag) = try .init(gpa, tag_count_max);
        errdefer unmatched_closers.deinit(gpa);

        const unmatched_openers: ArrayType(Tag) = try .init(gpa, tag_count_max);

        assert(scratch.len == scratch_count);
        assert(tags.capacity() == tag_count_max);

        return .{
            .blocks = blocks,
            .intermediates = intermediates,
            .scratch = scratch,
            .stack = stack,
            .tags = tags,
            .unmatched_closers = unmatched_closers,
            .unmatched_openers = unmatched_openers,
        };
    }

    pub fn deinit(map: *Blocks, gpa: std.mem.Allocator) void {
        assert(map.scratch.len == scratch_count);
        assert(map.stack.capacity() == block_depth_max);

        map.unmatched_openers.deinit(gpa);
        map.unmatched_closers.deinit(gpa);
        map.tags.deinit(gpa);
        map.stack.deinit(gpa);
        gpa.free(map.scratch);
        map.intermediates.deinit(gpa);
        map.blocks.deinit(gpa);
        map.* = undefined;
    }

    pub fn block_slice(map: *const Blocks) []const Block {
        const held = map.blocks.const_slice();

        assert(held.len <= map.blocks.capacity());
        assert(map.intermediates.count() <= map.intermediates.capacity());

        return held;
    }

    pub fn clear(map: *Blocks) void {
        map.blocks.clear();
        map.intermediates.clear();
        map.stack.clear();
        map.tags.clear();
        map.unmatched_closers.clear();
        map.unmatched_openers.clear();

        assert(map.blocks.empty());
        assert(map.scratch.len == scratch_count);
    }

    fn innermost_at(map: *const Blocks, offset: u32) ?Block {
        assert(offset < std.math.maxInt(u32));

        var found: ?Block = null;

        for (map.blocks.const_slice()) |block| {
            if (!block.span.contains(offset)) continue;

            const shorter = if (found) |held| block.span.length < held.span.length else true;

            if (shorter) found = block;
        }

        if (found) |held| assert(held.span.offset <= offset);
        if (found) |held| assert(offset < held.span.end());

        return found;
    }

    pub fn intermediates_of(map: *const Blocks, block: *const Block) []const Tag {
        const first = block.intermediate_first;
        const end = first + block.intermediate_count;

        assert(block.intermediate_count <= intermediate_count_max);
        assert(end <= map.intermediates.count());

        return map.intermediates.const_slice()[first..end];
    }

    pub fn tag_slice(map: *const Blocks) []const Tag {
        const held = map.tags.const_slice();

        assert(held.len <= map.tags.capacity());
        assert(map.blocks.count() <= map.blocks.capacity());

        return held;
    }

    pub fn unmatched_closer_slice(map: *const Blocks) []const Tag {
        const held = map.unmatched_closers.const_slice();

        assert(held.len <= map.unmatched_closers.capacity());
        assert(held.len <= map.tags.count());

        return held;
    }

    pub fn unmatched_opener_slice(map: *const Blocks) []const Tag {
        const held = map.unmatched_openers.const_slice();

        assert(held.len <= map.unmatched_openers.capacity());
        assert(held.len <= map.tags.count());

        return held;
    }
};

const Options = struct {
    end_prefix: ?[]const u8,
    specifications: []const TagSpecification,
    words: []const []const u8,
};

const Harvest = struct {
    count: u32,
    first: u32,
};

const Pairer = struct {
    map: *Blocks,
    source: []const u8,
    tokens: []const Token,
    too_deep: bool,
    truncated: ?Structure.Resource,
    vocabulary: *const Vocabulary,

    fn run(pairer: *Pairer) void {
        assert(pairer.map.stack.empty());
        assert(pairer.map.blocks.empty());

        for (pairer.map.tags.const_slice()) |tag| {
            const name = tag.name(pairer.tokens, pairer.source);

            if (pairer.vocabulary.end_prefix) |prefix| {
                assert(prefix.len > 0);

                if (std.mem.startsWith(u8, name, prefix)) {
                    pairer.close(tag, name[prefix.len..]);

                    continue;
                }
            }

            if (pairer.attach_intermediate(tag)) continue;
            if (word_contains(pairer.vocabulary.intermediate_words, name)) continue;

            pairer.open(tag);
        }
    }

    fn finish(pairer: *Pairer) void {
        assert(pairer.map.stack.count() <= block_depth_max);

        for (0..block_depth_max) |_| {
            const open_block = pairer.map.stack.pop() orelse break;

            pairer.push_unclosed(open_block);
        }

        assert(pairer.map.stack.empty());

        sort.unstable(Blocks.Block, pairer.map.blocks.slice(), void, {}, block_less);
        sort.unstable(Blocks.Tag, pairer.map.unmatched_openers.slice(), void, {}, tag_less);
    }

    fn attach_intermediate(pairer: *Pairer, tag: Blocks.Tag) bool {
        assert(tag.span.end() <= pairer.source.len);

        const at = pairer.innermost_known() orelse return false;
        const open_block = pairer.map.stack.get(at);
        const specification = pairer.specification_of(open_block.open) orelse return false;
        const name = tag.name(pairer.tokens, pairer.source);

        assert(open_block.known);

        if (!word_contains(specification.intermediates, name)) return false;

        if (open_block.intermediate_count >= intermediate_count_max) {
            pairer.truncated = pairer.truncated orelse .intermediates;

            return true;
        }

        const slot = at * intermediate_count_max + open_block.intermediate_count;

        assert(slot < pairer.map.scratch.len);

        pairer.map.scratch[slot] = tag;

        pairer.map.stack.slice()[at].intermediate_count = open_block.intermediate_count + 1;

        return true;
    }

    fn close(pairer: *Pairer, tag: Blocks.Tag, target: []const u8) void {
        assert(tag.span.length > 0);
        assert(target.len <= std.math.maxInt(u32));

        const depth = pairer.find_open(target) orelse {
            pairer.push_tag(&pairer.map.unmatched_closers, tag);

            return;
        };

        assert(depth < pairer.map.stack.count());

        for (0..depth) |_| {
            const unclosed = pairer.map.stack.pop() orelse unreachable;

            pairer.push_unclosed(unclosed);
        }

        const open_block = pairer.map.stack.pop() orelse unreachable;
        const harvest = pairer.harvested(pairer.map.stack.count(), open_block.intermediate_count);
        const span = Span.between(open_block.open.span.offset, tag.span.end());

        pairer.push_block(.{
            .close = tag,
            .intermediate_count = harvest.count,
            .intermediate_first = harvest.first,
            .open = open_block.open,
            .span = span,
        });
    }

    fn find_open(pairer: *Pairer, target: []const u8) ?u32 {
        assert(target.len <= std.math.maxInt(u32));

        const stack = pairer.map.stack.const_slice();
        var seen: u32 = 0;

        assert(stack.len <= block_depth_max);

        for (0..stack.len) |step| {
            const open_block = stack[stack.len - 1 - step];

            if (std.mem.eql(u8, open_block.open.name(pairer.tokens, pairer.source), target)) {
                if (seen < pairing_lookback_max) return seen;

                pairer.too_deep = true;

                return null;
            }

            seen += 1;
        }

        assert(seen == stack.len);

        return null;
    }

    fn harvested(pairer: *Pairer, frame: u32, count: u32) Harvest {
        assert(count <= intermediate_count_max);

        const first = pairer.map.intermediates.count();
        var moved: u32 = 0;

        assert(frame < block_depth_max);

        for (0..count) |slot| {
            if (pairer.map.intermediates.full()) {
                pairer.truncated = pairer.truncated orelse .tags;

                break;
            }

            const index = frame * intermediate_count_max + @as(u32, @intCast(slot));

            pairer.map.intermediates.push(pairer.map.scratch[index]);
            moved += 1;
        }

        return .{ .count = moved, .first = first };
    }

    fn innermost_known(pairer: *const Pairer) ?u32 {
        const stack = pairer.map.stack.const_slice();

        assert(stack.len <= block_depth_max);

        for (0..stack.len) |step| {
            const index = stack.len - 1 - step;

            if (stack[index].known) {
                assert(index < stack.len);

                return @intCast(index);
            }
        }

        return null;
    }

    fn open(pairer: *Pairer, tag: Blocks.Tag) void {
        assert(tag.span.end() <= pairer.source.len);

        const known = pairer.specification_of(tag) != null;

        assert(pairer.map.stack.count() <= block_depth_max);

        if (pairer.map.stack.count() >= block_depth_max) {
            if (known) pairer.push_tag(&pairer.map.unmatched_openers, tag);
            if (known) pairer.too_deep = true;
            if (pairer.vocabulary.end_prefix != null) pairer.too_deep = true;

            return;
        }

        pairer.map.stack.push(.{ .intermediate_count = 0, .known = known, .open = tag });

        assert(pairer.map.stack.count() > 0);
    }

    fn push_block(pairer: *Pairer, block: Blocks.Block) void {
        assert(block.span.offset == block.open.span.offset);
        assert(block.span.length > 0);

        if (pairer.map.blocks.full()) {
            pairer.truncated = pairer.truncated orelse .tags;

            return;
        }

        pairer.map.blocks.push(block);
    }

    fn push_tag(pairer: *Pairer, list: *ArrayType(Blocks.Tag), tag: Blocks.Tag) void {
        assert(tag.span.length > 0);
        assert(tag.name_token < pairer.tokens.len);

        if (list.full()) {
            pairer.truncated = pairer.truncated orelse .tags;

            return;
        }

        list.push(tag);
    }

    fn push_unclosed(pairer: *Pairer, open_block: Blocks.OpenBlock) void {
        const frame = pairer.map.stack.count();

        assert(open_block.intermediate_count <= intermediate_count_max);

        if (open_block.known) pairer.push_tag(&pairer.map.unmatched_openers, open_block.open);

        const tail: ?Blocks.Tag = if (open_block.intermediate_count == 0) null else tail: {
            const slot = frame * intermediate_count_max + open_block.intermediate_count - 1;

            break :tail pairer.map.scratch[slot];
        };

        if (tail) |held| assert(held.span.offset > open_block.open.span.offset);

        const harvest = pairer.harvested(frame, open_block.intermediate_count);
        const opened = open_block.open.span;
        const span = if (tail) |held| Span.between(opened.offset, held.span.end()) else opened;

        pairer.push_block(.{
            .close = null,
            .intermediate_count = harvest.count,
            .intermediate_first = harvest.first,
            .open = open_block.open,
            .span = span,
        });
    }

    fn specification_of(pairer: *const Pairer, tag: Blocks.Tag) ?*const TagSpecification {
        assert(tag.name_token < pairer.tokens.len);

        const name = tag.name(pairer.tokens, pairer.source);

        assert(name.len > 0);

        return pairer.vocabulary.specification_of(name);
    }
};

pub const block_depth_max: u32 = 128;
pub const intermediate_count_max: u32 = 32;
pub const pairing_lookback_max: u32 = 64;
const scratch_count: u32 = block_depth_max * intermediate_count_max;

comptime {
    assert(pairing_lookback_max <= block_depth_max);
}

pub fn build(
    map: *Blocks,
    source: []const u8,
    tokens: []const Token,
    tree: *const Tree,
    vocabulary: *const Vocabulary,
) Structure {
    assert(source.len <= std.math.maxInt(u32));
    assert(tokens.len <= std.math.maxInt(u32));

    map.clear();

    var truncated: ?Structure.Resource = null;

    collect(map, source, tokens, tree) catch |err| switch (err) {
        error.Overflow => truncated = .tags,
    };

    var pairer: Pairer = .{
        .map = map,
        .source = source,
        .tokens = tokens,
        .too_deep = false,
        .truncated = truncated,
        .vocabulary = vocabulary,
    };

    pairer.run();
    pairer.finish();

    assert(map.stack.empty());

    if (pairer.truncated) |resource| return .{ .truncated = resource };
    if (pairer.too_deep) return .too_deep;
    return .complete;
}

fn collect(
    map: *Blocks,
    source: []const u8,
    tokens: []const Token,
    tree: *const Tree,
) error{Overflow}!void {
    assert(source.len > 0 or tree.count() <= 1);
    assert(map.tags.empty());
    assert(tokens.len <= std.math.maxInt(u32));

    for (0..tree.count()) |position| {
        const index: u32 = @intCast(position);
        if (tree.kind_at(index) != .template_tag) continue;

        const view: View = .init(tree, tokens, @fromBackingInt(index));
        const tag = view.as_template_tag() orelse continue;
        const name_token = tag.name_token() orelse continue;

        if (map.tags.full()) return error.Overflow;

        map.tags.push(.{ .name_token = name_token, .span = view.span() });
    }
}

fn block_less(context: void, left: Blocks.Block, right: Blocks.Block) bool {
    assert(@TypeOf(context) == void);
    assert(left.span.length > 0);
    assert(right.span.length > 0);

    if (left.span.offset != right.span.offset) return left.span.offset < right.span.offset;
    return left.span.end() < right.span.end();
}

fn tag_less(context: void, left: Blocks.Tag, right: Blocks.Tag) bool {
    assert(@TypeOf(context) == void);
    assert(left.span.length > 0);
    assert(right.span.length > 0);

    return left.span.offset < right.span.offset;
}

fn word_contains(words: []const []const u8, name: []const u8) bool {
    assert(words.len <= std.math.maxInt(u32));
    assert(name.len > 0);

    for (words) |word| {
        if (std.mem.eql(u8, word, name)) return true;
    }

    return false;
}

const specifications_test = [_]TagSpecification{
    .{ .intermediates = &.{"else"}, .name = "if" },
};

const capacity_test: Document.Capacity = .{
    .diagnostic_count_max = 1 << 4,
    .node_count_max = 1 << 10,
    .tag_count_max = 1 << 9,
    .token_count_max = 1 << 12,
};

fn vocabulary_of(prefix: ?[]const u8) Vocabulary {
    if (prefix) |held| assert(held.len > 0);

    var vocabulary: Vocabulary = .empty;

    vocabulary.end_prefix = prefix;
    vocabulary.intermediate_words = &.{"else"};
    vocabulary.specifications = &specifications_test;

    assert(vocabulary.dialect == .html);

    return vocabulary;
}

fn repeated_test(
    gpa: std.mem.Allocator,
    source: *std.ArrayList(u8),
    parts: []const []const u8,
    middle_count: u32,
) !void {
    assert(parts.len == 3);
    assert(middle_count <= block_depth_max + 1);

    source.clearRetainingCapacity();

    try source.appendSlice(gpa, parts[0]);

    for (0..middle_count) |_| try source.appendSlice(gpa, parts[1]);

    try source.appendSlice(gpa, parts[2]);
}

fn paired_test(document: *Document, source: []const u8, prefix: ?[]const u8) !void {
    assert(source.len <= std.math.maxInt(u32));
    if (prefix) |held| assert(held.len > 0);

    const vocabulary = vocabulary_of(prefix);

    document.* = try .init(std.testing.allocator, capacity_test);
    errdefer document.deinit(std.testing.allocator);

    try document.parse(source, &vocabulary);
}

test "the end prefix names the closer" {
    var document: Document = undefined;

    try paired_test(&document, "{% if a %}x{% endif %}", "end");
    defer document.deinit(std.testing.allocator);

    const map = document.blocks();

    try std.testing.expectEqual(1, map.block_slice().len);
    try std.testing.expect(map.block_slice()[0].is_closed());
    try std.testing.expectEqual(0, map.unmatched_closer_slice().len);
}

test "another prefix names another closer" {
    var closed: Document = undefined;

    try paired_test(&closed, "{% if a %}x{% /if %}", "/");
    defer closed.deinit(std.testing.allocator);

    var open: Document = undefined;

    try paired_test(&open, "{% if a %}x{% endif %}", "/");
    defer open.deinit(std.testing.allocator);

    try std.testing.expectEqual(1, closed.blocks().block_slice().len);
    try std.testing.expect(closed.blocks().block_slice()[0].is_closed());
    try std.testing.expectEqual(1, open.blocks().unmatched_opener_slice().len);
    try std.testing.expectEqual(0, open.blocks().unmatched_closer_slice().len);
}

test "a vocabulary without an end prefix closes nothing" {
    var document: Document = undefined;

    try paired_test(&document, "{% if a %}x{% endif %}", null);
    defer document.deinit(std.testing.allocator);

    const map = document.blocks();

    try std.testing.expectEqual(1, map.unmatched_opener_slice().len);
    try std.testing.expectEqual(0, map.unmatched_closer_slice().len);

    for (map.block_slice()) |*block| {
        try std.testing.expect(!block.is_closed());
    }
}

test "the innermost block at an offset is the shortest that covers it" {
    const source = "{% if a %}{% for b in c %}X{% endfor %}{% endif %}";
    var document: Document = undefined;

    try paired_test(&document, source, "end");
    defer document.deinit(std.testing.allocator);

    const offset: u32 = @intCast(std.mem.findScalar(u8, source, 'X') orelse unreachable);
    const found = document.blocks().innermost_at(offset);
    const innermost = found orelse return error.TestUnexpectedResult;

    try std.testing.expectEqualStrings("for", innermost.open.name(document.tokens(), source));
}

test "an open block past its intermediate slots reports the intermediates exhausted" {
    const gpa = std.testing.allocator;
    const vocabulary = vocabulary_of("end");
    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(gpa);

    var document: Document = try .init(gpa, capacity_test);
    defer document.deinit(gpa);

    const parts = [_][]const u8{ "{% if a %}", "{% else %}", "{% endif %}" };

    try repeated_test(gpa, &source, &parts, intermediate_count_max);
    try document.parse(source.items, &vocabulary);

    const fitted = document.blocks().block_slice()[0];

    try std.testing.expectEqual(intermediate_count_max, fitted.intermediate_count);
    try repeated_test(gpa, &source, &parts, intermediate_count_max + 1);

    const outgrown = document.parse(source.items, &vocabulary);

    try std.testing.expectError(error.IntermediatesExhausted, outgrown);

    const kept = document.blocks().block_slice()[0];

    try std.testing.expect(kept.is_closed());
    try std.testing.expectEqual(intermediate_count_max, kept.intermediate_count);
}

test "a closer past the pairing lookback reports the depth exceeded" {
    const gpa = std.testing.allocator;
    const vocabulary = vocabulary_of("end");
    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(gpa);

    var document: Document = try .init(gpa, capacity_test);
    defer document.deinit(gpa);

    const parts = [_][]const u8{ "{% if a %}", "{% csrf_token %}", "{% endif %}" };

    try repeated_test(gpa, &source, &parts, pairing_lookback_max - 1);
    try document.parse(source.items, &vocabulary);
    try std.testing.expect(document.blocks().block_slice()[0].is_closed());

    try repeated_test(gpa, &source, &parts, pairing_lookback_max);

    const refused = document.parse(source.items, &vocabulary);

    try std.testing.expectError(error.BlockDepthExceeded, refused);
    try std.testing.expectEqual(1, document.blocks().unmatched_closer_slice().len);
    try std.testing.expectEqual(1, document.blocks().unmatched_opener_slice().len);
}

test "an opener past the block depth reports the depth exceeded" {
    const gpa = std.testing.allocator;
    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(gpa);

    var document: Document = try .init(gpa, capacity_test);
    defer document.deinit(gpa);

    const vocabulary = vocabulary_of("end");
    const parts = [_][]const u8{ "", "{% if a %}", "" };
    const map = document.blocks();

    try repeated_test(gpa, &source, &parts, block_depth_max);
    try document.parse(source.items, &vocabulary);
    try std.testing.expectEqual(block_depth_max, map.unmatched_opener_slice().len);
    try repeated_test(gpa, &source, &parts, block_depth_max + 1);

    const refused = document.parse(source.items, &vocabulary);

    try std.testing.expectError(error.BlockDepthExceeded, refused);
    try std.testing.expectEqual(block_depth_max + 1, map.unmatched_opener_slice().len);
}

test "a vocabulary that pairs nothing leaves tags past the block depth unpaired without an error" {
    const gpa = std.testing.allocator;
    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(gpa);

    var document: Document = try .init(gpa, capacity_test);
    defer document.deinit(gpa);

    const parts = [_][]const u8{ "", "{% csrf_token %}", "" };

    try repeated_test(gpa, &source, &parts, block_depth_max + 1);
    try document.parse(source.items, &.empty);
    try std.testing.expectEqual(0, document.blocks().tag_slice().len);
    try std.testing.expectEqual(0, document.blocks().block_slice().len);
    try std.testing.expect(document.node_count() > block_depth_max);
}
