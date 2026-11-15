const std = @import("std");
const assert = std.debug.assert;
const ArrayType = @import("../../stdx/bounded/array.zig").ArrayType;
const Span = @import("../../stdx/bounded/span.zig");
const Token = @import("token.zig").Token;
const Tree = @import("tree.zig").Tree;
const View = @import("view.zig").View;
const name_hash = std.hash.Fnv1a_32.hash;
const scan = @import("../../text/scan.zig");
const tree_module = @import("tree.zig");
const Structure = @import("../tree.zig").Structure;

pub const Semantic = struct {
    definitions: ArrayType(Definition),
    heads: ArrayType(?u32),
    uses: ArrayType(Use),

    pub const Capacity = struct {
        definition_count_max: u32,
        use_count_max: u32,
    };

    pub fn init(
        semantic: *Semantic,
        gpa: std.mem.Allocator,
        capacity: Capacity,
    ) std.mem.Allocator.Error!void {
        assert(capacity.definition_count_max > 0);
        assert(capacity.use_count_max > 0);

        semantic.definitions = try .init(gpa, capacity.definition_count_max);
        errdefer semantic.definitions.deinit(gpa);

        semantic.heads = try .init(gpa, bucket_count_of(capacity.definition_count_max));
        errdefer semantic.heads.deinit(gpa);

        semantic.uses = try .init(gpa, capacity.use_count_max);

        semantic.heads.fill(null);

        assert(semantic.heads.full());
        assert(semantic.count() == 0);
    }

    pub fn deinit(semantic: *Semantic, gpa: std.mem.Allocator) void {
        assert(semantic.heads.full());
        assert(std.math.isPowerOfTwo(semantic.heads.count()));

        semantic.uses.deinit(gpa);
        semantic.heads.deinit(gpa);
        semantic.definitions.deinit(gpa);
        semantic.* = undefined;
    }

    pub fn build(
        semantic: *Semantic,
        source: []const u8,
        tokens: []const Token,
        tree: *const Tree,
    ) Structure {
        assert(source.len <= std.math.maxInt(u32));
        assert(tokens.len <= std.math.maxInt(u32));

        semantic.clear();

        var builder: Builder = .{
            .outcome = .complete,
            .semantic = semantic,
            .source = source,
            .tokens = tokens,
            .tree = tree,
        };

        builder.collect();
        semantic.resolve(source);

        assert(semantic.count() <= semantic.definitions.capacity());
        assert(semantic.uses.count() <= semantic.uses.capacity());

        return builder.outcome;
    }

    pub fn clear(semantic: *Semantic) void {
        assert(semantic.heads.full());

        @memset(semantic.heads.slice(), null);
        semantic.definitions.clear();
        semantic.uses.clear();

        assert(semantic.count() == 0);
        assert(semantic.uses.empty());
    }

    pub fn count(semantic: *const Semantic) u32 {
        const definition_count = semantic.definitions.count();

        assert(definition_count <= semantic.definitions.capacity());

        return definition_count;
    }

    pub fn definition_slice(semantic: *const Semantic) []const Definition {
        const definitions = semantic.definitions.const_slice();

        assert(definitions.len == semantic.count());
        if (definitions.len > 0) assert(definitions[definitions.len - 1].name.length > 0);

        return definitions;
    }

    pub fn get(semantic: *const Semantic, index: u32) ?Definition {
        if (index >= semantic.count()) return null;

        const definition = semantic.definitions.get(index);

        assert(definition.name.length > 0);
        if (definition.name_previous) |previous| assert(previous < index);

        return definition;
    }

    pub fn use_slice(semantic: *const Semantic) []const Use {
        const uses = semantic.uses.const_slice();

        assert(uses.len <= semantic.uses.capacity());
        if (uses.len > 0) assert(uses[uses.len - 1].definition_count <= semantic.count());

        return uses;
    }

    pub fn uses_of(semantic: *const Semantic, definition: u32) Uses {
        assert(definition < semantic.count());
        assert(semantic.uses.count() <= semantic.uses.capacity());

        return .{
            .definition = definition,
            .position = 0,
            .remaining = semantic.uses.count(),
            .semantic = semantic,
        };
    }

    fn bucket_of(semantic: *const Semantic, hash: u32) u32 {
        const bucket_count = semantic.heads.count();

        assert(std.math.isPowerOfTwo(bucket_count));

        const bucket = hash & (bucket_count - 1);

        assert(bucket < bucket_count);

        return bucket;
    }

    fn push_definition(semantic: *Semantic, definition: *const Definition) error{Truncated}!void {
        assert(definition.name_previous == null);
        assert(semantic.heads.full());

        if (definition.name.length == 0) return;
        if (semantic.definitions.full()) return error.Truncated;

        const index = semantic.count();
        const bucket = semantic.bucket_of(definition.name_hash);
        var held = definition.*;

        held.name_previous = semantic.heads.get(bucket);

        semantic.definitions.push(held);
        semantic.heads.slice()[bucket] = index;

        assert(semantic.count() == index + 1);
        assert(semantic.heads.get(bucket) == index);
    }

    fn resolve(semantic: *Semantic, source: []const u8) void {
        assert(semantic.heads.full());
        assert(semantic.uses.count() <= semantic.uses.capacity());
        assert(source.len <= std.math.maxInt(u32));

        for (semantic.uses.slice()) |*use| {
            const name = use.name.text(source);
            const hash = name_hash(name);
            var position = semantic.heads.get(semantic.bucket_of(hash));
            var found: ?u32 = null;
            var match_count: u32 = 0;

            for (0..semantic.count() + 1) |_| {
                const held = position orelse break;
                const definition = semantic.definitions.get(held);

                if (resolves(&definition, use, hash, source)) {
                    found = held;
                    match_count += 1;
                }

                position = definition.name_previous;
            }

            assert(position == null);
            assert((found == null) == (match_count == 0));

            use.definition = found;
            use.definition_count = match_count;
        }
    }
};

pub const Definition = struct {
    kind: DefinitionKind,
    name: Span,
    name_hash: u32,
    name_previous: ?u32,
    node: u32,
};

pub const DefinitionKind = enum {
    id,

    pub fn reads(kind: DefinitionKind, use: UseKind) bool {
        const result = switch (kind) {
            .id => use == .id,
        };

        if (result) assert(std.mem.eql(u8, @tagName(kind), @tagName(use)));

        return result;
    }
};

pub const Use = struct {
    definition: ?u32,
    definition_count: u32,
    kind: UseKind,
    name: Span,
    node: u32,
};

pub const UseKind = enum {
    id,
};

pub const Uses = struct {
    definition: u32,
    position: u32,
    remaining: u32,
    semantic: *const Semantic,

    pub fn next(uses: *Uses) ?u32 {
        const held = uses.semantic.use_slice();

        assert(uses.position <= held.len);
        assert(uses.definition < uses.semantic.count());
        assert(uses.remaining <= held.len);

        if (uses.remaining == 0) return null;

        for (uses.position..held.len) |index| {
            if (held[index].definition == uses.definition) {
                uses.position = @intCast(index + 1);
                uses.remaining -= 1;

                assert(index < held.len);

                return @intCast(index);
            }
        }

        uses.position = @intCast(held.len);

        assert(uses.position == held.len);

        return null;
    }
};

pub const Words = struct {
    end: u32,
    offset: u32,
    remaining: u32,
    source: []const u8,

    pub fn init(source: []const u8, span: Span) Words {
        assert(source.len <= std.math.maxInt(u32));
        assert(span.end() <= source.len);

        return .{
            .end = span.end(),
            .offset = span.offset,
            .remaining = span.length,
            .source = source,
        };
    }

    pub fn next(words: *Words) ?Span {
        assert(words.end <= words.source.len);
        assert(words.offset <= words.end);
        assert(words.remaining <= words.source.len);

        if (words.remaining == 0) return null;

        for (words.offset..words.end) |_| {
            if (!scan.is_ascii_whitespace(words.source[words.offset])) break;

            words.offset += 1;
        }

        if (words.offset >= words.end) return null;

        const from = words.offset;

        for (words.offset..words.end) |_| {
            if (scan.is_ascii_whitespace(words.source[words.offset])) break;

            words.offset += 1;
        }

        assert(words.offset > from);

        words.remaining -= 1;

        return .{ .length = words.offset - from, .offset = from };
    }
};

const Builder = struct {
    outcome: Structure,
    semantic: *Semantic,
    source: []const u8,
    tokens: []const Token,
    tree: *const Tree,

    fn collect(builder: *Builder) void {
        if (builder.tree.count() == 0) return;

        var steps = tree_module.walk(builder.tree);

        for (0..steps.step_max) |_| {
            const step = steps.next() orelse break;

            switch (step) {
                .enter => |node| {
                    if (builder.tree.kind_at(node) == .attribute) builder.attribute(node);
                },
                .leave => {},
            }
        }

        assert(steps.node == null);
        assert(builder.semantic.count() <= builder.tree.count());
    }

    fn attribute(builder: *Builder, node: u32) void {
        assert(node < std.math.maxInt(u32));

        const view: View = .init(builder.tree, builder.tokens, @fromBackingInt(node));
        const attribute_view = view.as_attribute() orelse return;
        const index = attribute_view.name_token() orelse return;
        const value = attribute_view.value() orelse return;

        assert(view.kind() == .attribute);

        if (attribute_repeated(builder.tree, builder.tokens, builder.source, node)) return;
        if (value_templated(value.view)) return;

        const name = view.token_at(index).text(builder.source);
        const span = value.inner_span();
        if (equals_ignore_case(name, "id")) return builder.definition(span, node);
        if (names_any(name, &listed)) return builder.uses_listed(span, node);

        if (names_any(name, &singular)) {
            if (span.length > 0) {
                var words: Words = .init(builder.source, span);
                var word_count: u32 = 0;

                for (0..span.length) |_| {
                    if (words.next() == null) break;

                    word_count += 1;
                }

                if (word_count == 1) return builder.use_of(span, node);
            }
        }

        if (!names_any(name, &fragment)) return;
        if (span.length <= 1) return;
        if (builder.source[span.offset] != '#') return;

        builder.use_of(.{ .length = span.length - 1, .offset = span.offset + 1 }, node);
    }

    fn uses_listed(builder: *Builder, span: Span, node: u32) void {
        assert(span.end() <= builder.source.len);
        assert(node < builder.tree.count());

        var words: Words = .init(builder.source, span);

        for (0..span.length + 1) |_| {
            const word = words.next() orelse break;

            builder.use_of(word, node);
        }

        assert(words.offset == words.end);
    }

    fn definition(builder: *Builder, name: Span, node: u32) void {
        assert(name.end() <= builder.source.len);
        assert(node < builder.tree.count());

        builder.semantic.push_definition(&.{
            .kind = .id,
            .name = name,
            .name_hash = name_hash(name.text(builder.source)),
            .name_previous = null,
            .node = node,
        }) catch |err| switch (err) {
            error.Truncated => builder.outcome = .{ .truncated = .bindings },
        };
    }

    fn use_of(builder: *Builder, name: Span, node: u32) void {
        assert(name.end() <= builder.source.len);
        assert(node < builder.tree.count());

        if (name.length == 0) return;

        if (builder.semantic.uses.full()) {
            builder.outcome = .{ .truncated = .references };

            return;
        }

        builder.semantic.uses.push(.{
            .definition = null,
            .definition_count = 0,
            .kind = .id,
            .name = name,
            .node = node,
        });
    }
};

const bucket_count_min: u32 = 16;
const fragment = [_][]const u8{ "href", "usemap", "xlink:href" };

const listed = [_][]const u8{
    "aria-activedescendant",
    "aria-controls",
    "aria-describedby",
    "aria-details",
    "aria-errormessage",
    "aria-flowto",
    "aria-labelledby",
    "aria-owns",
    "headers",
};

const singular = [_][]const u8{ "for", "form", "list" };

comptime {
    assert(std.math.isPowerOfTwo(bucket_count_min));
}

fn bucket_count_of(definition_count_max: u32) u32 {
    assert(definition_count_max > 0);
    assert(definition_count_max <= 1 << 31);

    const power = std.math.ceilPowerOfTwoAssert(u32, definition_count_max);
    const bucket_count = @max(power, bucket_count_min);

    assert(std.math.isPowerOfTwo(bucket_count));
    assert(bucket_count >= definition_count_max);

    return bucket_count;
}

fn resolves(definition: *const Definition, use: *const Use, hash: u32, source: []const u8) bool {
    assert(definition.name.length > 0);
    assert(use.name.length > 0);

    if (definition.name_hash != hash) return false;
    if (!definition.kind.reads(use.kind)) return false;
    assert(source.len <= std.math.maxInt(u32));

    return std.mem.eql(u8, definition.name.text(source), use.name.text(source));
}

fn value_templated(value: View) bool {
    assert(value.kind() == .attribute_value);

    var children = value.children();

    for (0..value.tree.count()) |_| {
        const child = children.next() orelse return false;
        if (child.kind() != .quote) return true;
    }

    return false;
}

fn names_any(name: []const u8, wanted: []const []const u8) bool {
    assert(wanted.len > 0);
    assert(name.len <= std.math.maxInt(u32));

    for (wanted) |held| {
        if (equals_ignore_case(name, held)) return true;
    }

    return false;
}

pub fn attribute_repeated(
    tree: *const Tree,
    tokens: []const Token,
    source: []const u8,
    node: u32,
) bool {
    assert(node < tree.count());
    assert(tree.kind_at(node) == .attribute);
    assert(tokens.len <= std.math.maxInt(u32));
    assert(source.len <= std.math.maxInt(u32));

    const name = attribute_name(tree, tokens, source, node) orelse return false;
    const parent = tree.parent_of(node) orelse return false;
    var sibling = tree.child_first_of(parent);

    for (0..tree.count()) |_| {
        const held = sibling orelse return false;
        if (held == node) return false;

        if (tree.kind_at(held) == .attribute) {
            if (attribute_name(tree, tokens, source, held)) |earlier| {
                if (std.ascii.eqlIgnoreCase(earlier, name)) return true;
            }
        }

        sibling = tree.sibling_next_of(held);
    }

    return false;
}

fn attribute_name(
    tree: *const Tree,
    tokens: []const Token,
    source: []const u8,
    node: u32,
) ?[]const u8 {
    assert(source.len <= std.math.maxInt(u32));
    assert(node < tree.count());

    const held = tree.at(node);

    if (held.token_end > tokens.len) return null;
    if (held.token_start >= held.token_end) return null;

    for (held.token_start..held.token_end) |index| {
        const token = tokens[index];
        if (token.kind != .attribute_name) continue;
        if (token.offset + token.length > source.len) return null;
        if (token.length == 0) return null;
        return source[token.offset..][0..token.length];
    }

    return null;
}

fn equals_ignore_case(held: []const u8, wanted: []const u8) bool {
    assert(wanted.len > 0);

    if (held.len != wanted.len) return false;

    for (held, wanted) |left, right| {
        assert(!std.ascii.isUpper(right));

        if (std.ascii.toLower(left) != right) return false;
    }

    return true;
}
