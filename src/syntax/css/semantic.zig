const std = @import("std");
const assert = std.debug.assert;
const ArrayType = @import("../../stdx/bounded/array.zig").ArrayType;
const EventsType = @import("../tree.zig").EventsType;
const Fact = @import("../fact.zig").Fact;
const Facts = @import("../fact.zig").Facts;
const Kind = @import("kind.zig").Kind;
const Parser = @import("parse.zig").Parser;
const Resource = @import("../tree.zig").Structure.Resource;
const Span = @import("../../stdx/bounded/span.zig");
const Structure = @import("../tree.zig").Structure;
const Token = @import("../token.zig");
const Tokens = @import("../tokens.zig");
const TreeType = @import("../tree.zig").TreeType;
const camel_of = @import("../category.zig").camel_of;
const lex = @import("lex.zig").lex;
const name_hash = std.hash.Fnv1a_32.hash;
const raw_of = @import("../raw.zig").raw_of;
const walk = @import("../tree.zig").walk;
const Tree = TreeType(Kind);

pub const Semantic = struct {
    bindings: ArrayType(Definition),
    facts: Facts,
    heads: ArrayType(u32),
    uses: ArrayType(Use),

    pub const Limits = struct {
        binding_count_max: u32,
        fact_count_max: u32,
        reference_count_max: u32,
        scope_count_max: u32,
    };

    pub fn init(
        semantic: *Semantic,
        gpa: std.mem.Allocator,
        limits: *const Limits,
    ) std.mem.Allocator.Error!void {
        assert(limits.binding_count_max > 0);
        assert(limits.fact_count_max > 0);
        assert(limits.reference_count_max > 0);
        assert(limits.scope_count_max > 0);

        semantic.bindings = try .init(gpa, limits.binding_count_max);
        errdefer semantic.bindings.deinit(gpa);

        semantic.facts = try .init(gpa, limits.fact_count_max);
        errdefer semantic.facts.deinit(gpa);

        semantic.heads = try .init(gpa, bucket_count_of(limits.binding_count_max));
        errdefer semantic.heads.deinit(gpa);

        semantic.uses = try .init(gpa, limits.reference_count_max);

        semantic.heads.fill(none);

        assert(semantic.heads.full());
        assert(semantic.count() == 0);
    }

    pub fn deinit(semantic: *Semantic, gpa: std.mem.Allocator) void {
        assert(semantic.heads.full());
        assert(std.math.isPowerOfTwo(semantic.heads.count()));

        semantic.uses.deinit(gpa);
        semantic.heads.deinit(gpa);
        semantic.facts.deinit(gpa);
        semantic.bindings.deinit(gpa);
        semantic.* = undefined;
    }

    pub fn build(
        semantic: *Semantic,
        source: []const u8,
        tokens: []const Token,
        raw: []const Kind,
        tree: *const Tree,
    ) Structure {
        assert(source.len <= std.math.maxInt(u32));
        assert(tokens.len == raw.len);

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

        assert(semantic.count() <= tree.count());
        assert(semantic.uses.count() <= tree.count());

        return builder.outcome;
    }

    pub fn clear(semantic: *Semantic) void {
        assert(semantic.heads.full());

        @memset(semantic.heads.slice(), none);
        semantic.bindings.clear();
        semantic.facts.clear();
        semantic.uses.clear();

        assert(semantic.count() == 0);
        assert(semantic.uses.empty());
    }

    pub fn count(semantic: *const Semantic) u32 {
        const definition_count = semantic.bindings.count();

        assert(definition_count <= semantic.bindings.capacity());
        assert(definition_count < none);

        return definition_count;
    }

    pub fn definition_slice(semantic: *const Semantic) []const Definition {
        const definitions = semantic.bindings.const_slice();

        assert(definitions.len == semantic.count());
        if (definitions.len > 0) assert(definitions[definitions.len - 1].name.length > 0);

        return definitions;
    }

    pub fn fact_slice(semantic: *const Semantic) []const Fact {
        const facts = semantic.facts.slice();

        assert(facts.len <= semantic.facts.items.capacity());
        if (facts.len > 0) assert(facts[facts.len - 1].kind == .import_side_effect);

        return facts;
    }

    pub fn get(semantic: *const Semantic, index: ?u32) ?Definition {
        if (index) |held| assert(held < std.math.maxInt(u32));

        const held = index orelse return null;
        if (held >= semantic.count()) return null;

        const definition = semantic.bindings.get(held);

        assert(definition.name.length > 0);
        assert(definition.name_previous == none or definition.name_previous < held);

        return definition;
    }

    pub fn use_slice(semantic: *const Semantic) []const Use {
        const uses = semantic.uses.const_slice();

        assert(uses.len <= semantic.uses.capacity());
        if (uses.len > 0) assert(uses[uses.len - 1].definition_count <= semantic.count());

        return uses;
    }

    pub fn uses_of(semantic: *const Semantic, definition: ?u32) Uses {
        if (definition) |held| assert(held < semantic.count());

        assert(semantic.uses.count() <= semantic.uses.capacity());

        return .{ .definition = definition orelse none, .position = 0, .semantic = semantic };
    }

    fn bucket_of(semantic: *const Semantic, hash: u32) u32 {
        const bucket_count = semantic.heads.count();

        assert(std.math.isPowerOfTwo(bucket_count));

        const bucket = hash & (bucket_count - 1);

        assert(bucket < bucket_count);

        return bucket;
    }

    fn push_definition(semantic: *Semantic, definition: *const Definition) error{Truncated}!void {
        assert(definition.name_previous == none);
        assert(semantic.heads.full());

        if (definition.name.length == 0) return;
        if (semantic.bindings.full()) return error.Truncated;

        const index = semantic.count();
        const bucket = semantic.bucket_of(definition.name_hash);
        var held = definition.*;

        held.name_previous = semantic.heads.get(bucket);

        semantic.bindings.push(held);
        semantic.heads.slice()[bucket] = index;

        assert(semantic.count() == index + 1);
        assert(semantic.heads.get(bucket) == index);
    }

    fn resolve(semantic: *Semantic, source: []const u8) void {
        assert(semantic.heads.full());
        assert(semantic.uses.count() <= semantic.uses.capacity());
        assert(source.len <= std.math.maxInt(u32));

        for (semantic.uses.slice()) |*use| {
            const hash = name_hash(use.name.text(source));
            var position = semantic.heads.get(semantic.bucket_of(hash));
            var found: u32 = none;
            var match_count: u32 = 0;

            for (0..semantic.count() + 1) |_| {
                if (position == none) break;

                const definition = semantic.bindings.get(position);

                if (resolves(&definition, use, hash, source)) {
                    found = position;
                    match_count += 1;
                }

                position = definition.name_previous;
            }

            assert(position == none);
            assert((found == none) == (match_count == 0));

            use.definition = found;
            use.definition_count = match_count;
        }
    }
};

pub const Definition = struct {
    kind: DefinitionKind,
    name: Span,
    name_hash: u32,
    name_previous: u32,
    node: u32,
};

pub const DefinitionKind = enum {
    class,
    custom_property,
    font_family,
    id,
    keyframes,

    pub fn reads(kind: DefinitionKind, use: UseKind) bool {
        const result = switch (kind) {
            .class, .id => false,
            .custom_property => use == .custom_property,
            .font_family => use == .font_family,
            .keyframes => use == .keyframes,
        };

        if (result) assert(std.mem.eql(u8, @tagName(kind), @tagName(use)));
        if (kind == .class) assert(!result);

        return result;
    }
};

pub const Use = struct {
    definition: u32,
    definition_count: u32,
    kind: UseKind,
    name: Span,
    node: u32,
};

pub const UseKind = enum {
    custom_property,
    font_family,
    keyframes,
};

const Uses = struct {
    definition: u32,
    position: u32,
    semantic: *const Semantic,

    pub fn next(uses: *Uses) ?u32 {
        const held = uses.semantic.use_slice();

        assert(uses.position <= held.len);

        for (uses.position..held.len) |index| {
            if (held[index].definition == uses.definition) {
                uses.position = @intCast(index + 1);

                assert(index < std.math.maxInt(u32));

                return @intCast(index);
            }
        }

        uses.position = @intCast(held.len);

        assert(uses.position == held.len);

        return null;
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

        var steps = walk(Tree, builder.tree);

        for (0..steps.step_max) |_| {
            const step = steps.next() orelse break;

            switch (step) {
                .enter => |node| builder.enter(node),
                .leave => {},
            }
        }

        assert(steps.node == null);
        assert(builder.semantic.count() <= builder.tree.count());
    }

    fn enter(builder: *Builder, node: u32) void {
        const definition_count = builder.semantic.count();

        assert(node < builder.tree.count());

        switch (builder.kind_of(node)) {
            .call_expression => builder.call(node),
            .class_name => builder.class(node),
            .declaration => builder.declaration(node),
            .id_name => builder.identifier(node),
            .import_statement => builder.import(node),
            .keyframes_name => builder.keyframes(node),
            else => {},
        }

        assert(builder.semantic.count() >= definition_count);
    }

    fn class(builder: *Builder, node: u32) void {
        assert(builder.kind_of(node) == .class_name);

        if (builder.kind_of(builder.parent_of(node)) != .class_selector) return;

        const name = builder.span_of(node);

        assert(name.end() <= builder.source.len);

        builder.define(.class, name, node);
    }

    fn identifier(builder: *Builder, node: u32) void {
        assert(builder.kind_of(node) == .id_name);

        if (builder.kind_of(builder.parent_of(node)) != .id_selector) return;

        const name = builder.span_of(node);

        assert(name.end() <= builder.source.len);

        builder.define(.id, name, node);
    }

    fn keyframes(builder: *Builder, node: u32) void {
        assert(builder.kind_of(node) == .keyframes_name);

        const quoted = builder.child_of(node, .string_value);
        const name = if (quoted) |held| builder.unquoted(held) else builder.span_of(node);

        assert(name.end() <= builder.source.len);

        if (name.length == 0) return;

        builder.define(.keyframes, name, node);
    }

    fn declaration(builder: *Builder, node: u32) void {
        assert(builder.kind_of(node) == .declaration);

        if (builder.rooted(node)) return;

        const held = builder.child_of(node, .property_name) orelse return;
        const name = builder.span_of(held);
        const property = builder.text_of(name);

        assert(held > node);

        if (std.mem.startsWith(u8, property, "--")) {
            builder.define(.custom_property, name, held);

            return;
        }

        if (std.mem.eql(u8, property, "font-family")) {
            builder.family(node, held);

            return;
        }

        if (std.mem.eql(u8, property, "animation-name")) builder.values(node, held, .keyframes);
    }

    fn family(builder: *Builder, node: u32, property: u32) void {
        assert(builder.kind_of(node) == .declaration);
        assert(builder.kind_of(property) == .property_name);

        if (!builder.faced(node)) {
            builder.values(node, property, .font_family);

            return;
        }

        var held = builder.children(node);

        for (0..builder.tree.count()) |_| {
            const child = held.next() orelse break;
            if (child == property) continue;
            if (!builder.names(child)) continue;

            builder.define(.font_family, builder.unquoted(child), child);
        }
    }

    fn faced(builder: *const Builder, node: u32) bool {
        assert(node < builder.tree.count());
        assert(builder.kind_of(node) == .declaration);

        const block = builder.parent_of(node);
        const rule = builder.parent_of(block);
        if (builder.kind_of(rule) != .at_rule) return false;

        const keyword = builder.child_of(rule, .at_keyword) orelse return false;
        return std.mem.eql(u8, builder.text_of(builder.span_of(keyword)), "@font-face");
    }

    fn rooted(builder: *const Builder, node: u32) bool {
        assert(node < builder.tree.count());

        var held: ?u32 = node;

        for (0..builder.tree.count()) |_| {
            const current = held orelse return false;

            if (builder.kind_of(current) == .declaration) {
                return builder.kind_of(builder.parent_of(current)) == .stylesheet;
            }

            held = builder.parent_of(current);
        }

        return false;
    }

    fn names(builder: *const Builder, node: u32) bool {
        assert(node < builder.tree.count());

        const kind = builder.kind_of(node);
        const result = kind == .plain_value or kind == .string_value;

        if (result) assert(kind != .error_node);

        return result;
    }

    fn values(builder: *Builder, node: u32, property: u32, kind: UseKind) void {
        assert(builder.kind_of(node) == .declaration);
        assert(builder.kind_of(property) == .property_name);

        var held = builder.children(node);

        for (0..builder.tree.count()) |_| {
            const child = held.next() orelse break;
            if (child == property) continue;
            if (!builder.names(child)) continue;

            builder.read(kind, builder.unquoted(child), child);
        }
    }

    fn call(builder: *Builder, node: u32) void {
        assert(builder.kind_of(node) == .call_expression);

        if (builder.rooted(node)) return;

        const function = builder.child_of(node, .function_name) orelse return;
        if (!std.mem.eql(u8, builder.text_of(builder.span_of(function)), "var")) return;

        const arguments = builder.child_of(node, .arguments) orelse return;
        var held = builder.children(arguments);

        assert(arguments > node);

        for (0..builder.tree.count()) |_| {
            const child = held.next() orelse return;
            if (builder.kind_of(child) != .plain_value) continue;

            const name = builder.span_of(child);
            if (!std.mem.startsWith(u8, builder.text_of(name), "--")) continue;

            builder.read(.custom_property, name, child);

            return;
        }
    }

    fn import(builder: *Builder, node: u32) void {
        const fact_count = builder.semantic.facts.count();

        assert(builder.kind_of(node) == .import_statement);

        const specifier = builder.specifier_of(node);
        if (std.meta.eql(specifier, Span.empty)) return;

        builder.semantic.facts.push(.{
            .binding = .none,
            .kind = .import_side_effect,
            .local = .empty,
            .remote = .empty,
            .specifier = specifier,
        }) catch |err| switch (err) {
            error.Truncated => builder.truncate(.facts),
        };

        if (builder.outcome == .complete) assert(builder.semantic.facts.count() == fact_count + 1);
    }

    fn specifier_of(builder: *const Builder, node: u32) Span {
        assert(builder.kind_of(node) == .import_statement);

        if (builder.child_of(node, .string_value)) |held| return builder.unquoted(held);

        const expression = builder.child_of(node, .call_expression);
        const arguments = builder.child_of(expression, .arguments) orelse return .empty;
        var held = builder.children(arguments);

        assert(arguments > node);

        for (0..builder.tree.count()) |_| {
            const child = held.next() orelse break;
            if (builder.names(child)) return builder.unquoted(child);
        }

        return .empty;
    }

    fn define(builder: *Builder, kind: DefinitionKind, name: Span, node: u32) void {
        assert(name.end() <= builder.source.len);
        assert(node < builder.tree.count());

        builder.semantic.push_definition(&.{
            .kind = kind,
            .name = name,
            .name_hash = name_hash(builder.text_of(name)),
            .name_previous = none,
            .node = node,
        }) catch |err| switch (err) {
            error.Truncated => builder.truncate(.bindings),
        };
    }

    fn read(builder: *Builder, kind: UseKind, name: Span, node: u32) void {
        assert(name.end() <= builder.source.len);
        assert(node < builder.tree.count());

        if (builder.semantic.uses.full()) {
            builder.truncate(.references);

            return;
        }

        builder.semantic.uses.push(.{
            .definition = none,
            .definition_count = 0,
            .kind = kind,
            .name = name,
            .node = node,
        });
    }

    fn truncate(builder: *Builder, resource: Resource) void {
        assert(builder.outcome != .too_deep);

        if (builder.outcome == .complete) builder.outcome = .{ .truncated = resource };

        assert(builder.outcome == .truncated);
    }

    fn kind_of(builder: *const Builder, node: ?u32) Kind {
        if (node) |held| assert(held < std.math.maxInt(u32));

        const held = node orelse return .error_node;

        assert(held < builder.tree.count());

        const kind = builder.tree.kind_at(held);

        assert(kind.is_node());

        return kind;
    }

    fn children(builder: *const Builder, node: u32) Children {
        assert(node < builder.tree.count());

        const child_first = builder.tree.child_first_of(node);

        if (child_first) |held| assert(held > node);

        return .{ .node = child_first, .tree = builder.tree };
    }

    fn child_of(builder: *const Builder, node: ?u32, kind: Kind) ?u32 {
        if (node) |held| assert(held < std.math.maxInt(u32));

        const parent = node orelse return null;

        assert(parent < builder.tree.count());
        assert(kind.is_node());

        var held = builder.children(parent);

        for (0..builder.tree.count()) |_| {
            const child = held.next() orelse return null;
            if (builder.kind_of(child) == kind) return child;
        }

        return null;
    }

    fn parent_of(builder: *const Builder, node: ?u32) ?u32 {
        if (node) |held| assert(held < std.math.maxInt(u32));

        const held = node orelse return null;

        assert(held < builder.tree.count());

        const parent = builder.tree.parent_of(held);

        if (parent) |above| assert(above < held);

        return parent;
    }

    fn span_of(builder: *const Builder, node: u32) Span {
        assert(node < builder.tree.count());

        const span = builder.tree.at(node).span(Token, builder.tokens);

        assert(span.end() <= builder.source.len);

        return span;
    }

    fn text_of(builder: *const Builder, name: Span) []const u8 {
        assert(name.end() <= builder.source.len);

        const text = name.text(builder.source);

        assert(text.len == name.length);

        return text;
    }

    fn unquoted(builder: *const Builder, node: u32) Span {
        assert(node < none);

        const held = builder.span_of(node);
        if (builder.kind_of(node) != .string_value) return held;
        if (held.length < 2) return held;

        const inner: Span = .{ .length = held.length - 2, .offset = held.offset + 1 };

        assert(inner.end() < held.end());
        assert(inner.offset > held.offset);

        return inner;
    }
};

const Children = struct {
    node: ?u32,
    tree: *const Tree,

    fn next(held: *Children) ?u32 {
        const node = held.node orelse return null;

        held.node = held.tree.sibling_next_of(node);

        if (held.node) |sibling| assert(sibling > node);

        return node;
    }
};

const bucket_count_min: u32 = 16;
const none: u32 = std.math.maxInt(u32);

comptime {
    assert(std.math.isPowerOfTwo(bucket_count_min));
    assert(bucket_count_min < none);
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
    assert(use.name.end() <= source.len);

    if (definition.name_hash != hash) return false;
    if (!definition.kind.reads(use.kind)) return false;
    return std.mem.eql(u8, definition.name.text(source), use.name.text(source));
}

test "a font face defines a family and a rule reads one" {
    var fixture: Fixture = undefined;

    try fixture.init(&limits_fixture);
    defer fixture.deinit();

    try std.testing.expectEqual(.complete, try fixture.build(source_fonts));
    try fixture.expect_rows(.definitions, &.{ "FontFamily Scylla", "Class card" });
    try fixture.expect_rows(.uses, &.{ "Scylla FontFamily reads 0 of 1", "serif FontFamily none" });
    try fixture.expect_rows(.facts, &.{});
}

test "a keyframes statement defines a name an animation name reads" {
    var fixture: Fixture = undefined;

    try fixture.init(&limits_fixture);
    defer fixture.deinit();

    try std.testing.expectEqual(.complete, try fixture.build(source_keyframes));
    try fixture.expect_rows(.definitions, &.{ "Keyframes slide", "Class card", "Class panel" });
    try fixture.expect_rows(.uses, &.{ "slide Keyframes reads 0 of 1", "missing Keyframes none" });
    try fixture.expect_rows(.facts, &.{});
}

test "a custom property use reads every declaration of its name" {
    var fixture: Fixture = undefined;

    try fixture.init(&limits_fixture);
    defer fixture.deinit();

    try std.testing.expectEqual(.complete, try fixture.build(source_properties));

    try fixture.expect_rows(.definitions, &.{
        "CustomProperty --brand",
        "CustomProperty --space",
        "Class card",
        "CustomProperty --brand",
    });

    try fixture.expect_rows(.uses, &.{
        "--brand CustomProperty reads 0 of 2",
        "--space CustomProperty reads 1 of 1",
        "--missing CustomProperty none",
    });

    try fixture.expect_rows(.facts, &.{});

    var brand = fixture.semantic.uses_of(0);
    const brand_first = brand.next();
    const brand_second = brand.next();
    var missing = fixture.semantic.uses_of(null);
    const missing_first = missing.next();
    const missing_second = missing.next();

    try std.testing.expectEqual(0, brand_first.?);
    try std.testing.expectEqual(null, brand_second);
    try std.testing.expectEqual(2, missing_first.?);
    try std.testing.expectEqual(null, missing_second);
    try std.testing.expectEqual(0, fixture.semantic.get(3).?.name_previous);
    try std.testing.expectEqual(null, fixture.semantic.get(null));
    try std.testing.expectEqual(null, fixture.semantic.get(4));
}

test "a selector defines each class and id it names and no pseudo class" {
    var fixture: Fixture = undefined;

    try fixture.init(&limits_fixture);
    defer fixture.deinit();

    try std.testing.expectEqual(.complete, try fixture.build(source_selectors));

    try fixture.expect_rows(.definitions, &.{
        "Class card",
        "Class inner",
        "Id main",
        "Class card",
        "Id footer",
    });

    try fixture.expect_rows(.uses, &.{});

    try fixture.expect_rows(.facts, &.{
        "ImportSideEffect reset.css",
        "ImportSideEffect theme.css",
    });
}

test "a family name keeps the space its escape holds" {
    var fixture: Fixture = undefined;

    try fixture.init(&limits_fixture);
    defer fixture.deinit();

    try std.testing.expectEqual(.complete, try fixture.build(source_escape));

    try fixture.expect_rows(.definitions, &.{
        "FontFamily Font",
        "FontFamily Awesome\\ 5",
        "FontFamily Brands",
        "Class fab",
    });

    try fixture.expect_rows(.uses, &.{
        "Font FontFamily reads 0 of 1",
        "Awesome\\ 5 FontFamily reads 1 of 1",
        "Brands FontFamily reads 2 of 1",
    });
}

test "a declaration outside every rule declares and reads nothing" {
    var fixture: Fixture = undefined;

    try fixture.init(&limits_fixture);
    defer fixture.deinit();

    try std.testing.expectEqual(.complete, try fixture.build(source_rootless));
    try fixture.expect_rows(.definitions, &.{ "Class card", "CustomProperty --kept" });
    try fixture.expect_rows(.uses, &.{"--kept CustomProperty reads 1 of 1"});
}

test "a custom property holding a block defines its name and reads what the block reads" {
    var fixture: Fixture = undefined;

    try fixture.init(&limits_fixture);
    defer fixture.deinit();

    try std.testing.expectEqual(.complete, try fixture.build(source_block_value));

    try fixture.expect_rows(.definitions, &.{
        "CustomProperty --theme",
        "CustomProperty --after",
        "CustomProperty --line",
    });

    try fixture.expect_rows(.uses, &.{"--line CustomProperty reads 2 of 1"});
}

test "a keyframes name that opens with an escape is defined and read" {
    var fixture: Fixture = undefined;

    try fixture.init(&limits_fixture);
    defer fixture.deinit();

    try std.testing.expectEqual(.complete, try fixture.build(source_escaped_keyframes));
    try fixture.expect_rows(.definitions, &.{ "Keyframes \\@spin", "Class a" });
    try fixture.expect_rows(.uses, &.{"\\@spin Keyframes reads 0 of 1"});
}

test "a custom property whose name holds escapes is defined and read whole" {
    var fixture: Fixture = undefined;

    try fixture.init(&limits_fixture);
    defer fixture.deinit();

    try std.testing.expectEqual(.complete, try fixture.build(source_escaped_property));

    try fixture.expect_rows(.definitions, &.{
        "CustomProperty --a\\.b\\.c",
        "CustomProperty --plain",
        "Class a",
    });

    try fixture.expect_rows(.uses, &.{"--a\\.b\\.c CustomProperty reads 0 of 1"});
}

test "a keyframes name written as a string is defined by what it quotes" {
    var fixture: Fixture = undefined;

    try fixture.init(&limits_fixture);
    defer fixture.deinit();

    try std.testing.expectEqual(.complete, try fixture.build(source_quoted_keyframes));
    try fixture.expect_rows(.definitions, &.{ "Keyframes fade", "Class a", "Class b" });

    try fixture.expect_rows(.uses, &.{
        "fade Keyframes reads 0 of 1",
        "fade Keyframes reads 0 of 1",
    });
}

test "every use that names a definition names one it can read" {
    for (every_fixture) |source| {
        var fixture: Fixture = undefined;

        try fixture.init(&limits_fixture);
        defer fixture.deinit();

        try std.testing.expectEqual(.complete, try fixture.build(source));

        for (fixture.semantic.use_slice()) |use| {
            if (use.definition == none) {
                try std.testing.expectEqual(0, use.definition_count);

                continue;
            }

            const definition = fixture.semantic.get(use.definition).?;

            try std.testing.expect(definition.kind.reads(use.kind));
            try std.testing.expectEqualStrings(definition.name.text(source), use.name.text(source));
            try std.testing.expect(use.definition_count > 0);
        }
    }
}

test "a table that fills reports rather than grows" {
    var fixture: Fixture = undefined;

    try fixture.init(&.{
        .binding_count_max = 2,
        .fact_count_max = 1,
        .reference_count_max = 2,
        .scope_count_max = 1,
    });

    defer fixture.deinit();

    try std.testing.expect(try fixture.build(source_selectors) != .complete);
}

const Fixture = struct {
    events: Events,
    parser: *Parser,
    raw: ArrayType(Kind),
    semantic: Semantic,
    source: []const u8,
    tokens: Tokens,
    tree: Tree,

    fn init(fixture: *Fixture, limits: *const Semantic.Limits) !void {
        const gpa = std.testing.allocator;

        try fixture.events.init(gpa, fixture_event_count_max);
        errdefer fixture.events.deinit(gpa);

        fixture.parser = try gpa.create(Parser);
        errdefer gpa.destroy(fixture.parser);

        fixture.raw = try .init(gpa, fixture_token_count_max);
        errdefer fixture.raw.deinit(gpa);

        try fixture.semantic.init(gpa, limits);
        errdefer fixture.semantic.deinit(gpa);

        fixture.tokens = try .init(gpa, fixture_token_count_max);
        errdefer fixture.tokens.deinit(gpa);

        fixture.tree = try .init(gpa, fixture_token_count_max, fixture_error_count_max);
        fixture.source = "";

        assert(fixture.raw.capacity() == fixture.tokens.items.capacity());
        assert(fixture.semantic.count() == 0);
    }

    fn deinit(fixture: *Fixture) void {
        const gpa = std.testing.allocator;

        assert(fixture.raw.capacity() == fixture_token_count_max);
        assert(fixture.tokens.items.capacity() == fixture_token_count_max);

        fixture.tree.deinit(gpa);
        fixture.tokens.deinit(gpa);
        fixture.semantic.deinit(gpa);
        fixture.raw.deinit(gpa);
        gpa.destroy(fixture.parser);
        fixture.events.deinit(gpa);
        fixture.* = undefined;
    }

    fn build(fixture: *Fixture, source: []const u8) !Structure {
        assert(source.len < fixture_token_count_max);
        assert(source.len > 0);

        fixture.source = source;

        fixture.tokens.clear();

        try lex(source, &fixture.tokens);
        try raw_of(Kind, fixture.tokens.slice(), &fixture.raw);

        const parsed = fixture.parser.build(
            source,
            fixture.tokens.slice(),
            fixture.raw.const_slice(),
            &fixture.events,
            &fixture.tree,
        );

        try std.testing.expectEqual(.complete, parsed);

        return fixture.semantic.build(
            source,
            fixture.tokens.slice(),
            fixture.raw.const_slice(),
            &fixture.tree,
        );
    }

    fn expect_rows(fixture: *const Fixture, table: Table, expected: []const []const u8) !void {
        const row_count = switch (table) {
            .definitions => fixture.semantic.definition_slice().len,
            .facts => fixture.semantic.fact_slice().len,
            .uses => fixture.semantic.use_slice().len,
        };

        assert(fixture.source.len > 0);

        try std.testing.expectEqual(expected.len, row_count);

        for (expected, 0..) |wanted, index| {
            var buffer: [row_bytes_max]u8 = undefined;
            const row = try fixture.row_of(table, @intCast(index), &buffer);

            try std.testing.expectEqualStrings(wanted, row);
        }
    }

    fn row_of(fixture: *const Fixture, table: Table, index: u32, buffer: []u8) ![]const u8 {
        assert(index < none);

        const source = fixture.source;

        assert(buffer.len == row_bytes_max);

        switch (table) {
            .definitions => {
                const definition = fixture.semantic.definition_slice()[index];
                const name = definition.name.text(source);

                return std.mem.print(buffer, "{s} {s}", .{ title_of(definition.kind), name });
            },
            .facts => {
                const fact = fixture.semantic.fact_slice()[index];
                const specifier = fact.specifier.text(source);

                return std.mem.print(buffer, "{s} {s}", .{ fact.kind.name(), specifier });
            },
            .uses => return fixture.use_row(index, buffer),
        }
    }

    fn use_row(fixture: *const Fixture, index: u32, buffer: []u8) ![]const u8 {
        assert(index < none);

        const use = fixture.semantic.use_slice()[index];
        const name = use.name.text(fixture.source);
        const title = title_of(use.kind);

        assert(buffer.len == row_bytes_max);

        if (use.definition == none) {
            assert(use.definition_count == 0);

            return std.mem.print(buffer, "{s} {s} none", .{ name, title });
        }

        return std.mem.print(buffer, "{s} {s} reads {d} of {d}", .{
            name,
            title,
            use.definition,
            use.definition_count,
        });
    }
};

const Events = EventsType(Kind);

const Table = enum {
    definitions,
    facts,
    uses,
};

const fixture_error_count_max: u32 = 1 << 8;
const fixture_event_count_max: u32 = 1 << 16;
const fixture_token_count_max: u32 = 1 << 14;
const row_bytes_max = 128;

const limits_fixture: Semantic.Limits = .{
    .binding_count_max = 1 << 10,
    .fact_count_max = 1 << 10,
    .reference_count_max = 1 << 10,
    .scope_count_max = 1 << 10,
};

const every_fixture = [_][]const u8{
    source_block_value,
    source_escaped_keyframes,
    source_escaped_property,
    source_fonts,
    source_keyframes,
    source_properties,
    source_quoted_keyframes,
    source_rootless,
    source_selectors,
};

const source_block_value =
    \\:root {
    \\    --theme: {
    \\        border: 1px solid var(--line);
    \\        font-family: Inner;
    \\    };
    \\    --after: {color: red;} --swallowed: blue;
    \\    --line: gray;
    \\}
    \\
;

const source_escaped_keyframes =
    \\@keyframes \@spin {
    \\    from {
    \\        opacity: 0;
    \\    }
    \\}
    \\
    \\.a {
    \\    animation-name: \@spin;
    \\}
    \\
;

const source_escaped_property =
    \\:root {
    \\    --a\.b\.c: #fcba03;
    \\    --plain: red;
    \\}
    \\
    \\.a {
    \\    color: var(--a\.b\.c);
    \\}
    \\
;

const source_escape = "@font-face { font-family: Font Awesome\\ 5 Brands; }\n" ++
    ".fab { font-family: Font Awesome\\ 5 Brands; }\n";

const source_fonts =
    \\@font-face {
    \\    font-family: "Scylla";
    \\    src: url(scylla.woff2);
    \\}
    \\
    \\.card {
    \\    font-family: "Scylla", serif;
    \\}
    \\
;

const source_keyframes =
    \\@keyframes slide {
    \\    from {
    \\        opacity: 0;
    \\    }
    \\
    \\    to {
    \\        opacity: 1;
    \\    }
    \\}
    \\
    \\.card {
    \\    animation-name: slide;
    \\}
    \\
    \\.panel {
    \\    animation-name: missing;
    \\}
    \\
;

const source_properties =
    \\:root {
    \\    --brand: #123456;
    \\    --space: 4px;
    \\}
    \\
    \\.card {
    \\    color: var(--brand);
    \\    padding: var(--space, 2px);
    \\    margin: var(--missing);
    \\    --brand: #654321;
    \\}
    \\
;

const source_quoted_keyframes =
    \\@keyframes "fade" {
    \\    from {
    \\        opacity: 0;
    \\    }
    \\}
    \\
    \\@keyframes "" {
    \\    to {
    \\        opacity: 1;
    \\    }
    \\}
    \\
    \\.a {
    \\    animation-name: fade;
    \\}
    \\
    \\.b {
    \\    animation-name: "fade";
    \\}
    \\
;

const source_rootless =
    \\--loose: red;
    \\color: var(--loose);
    \\
    \\.card {
    \\    --kept: blue;
    \\    color: var(--kept);
    \\}
    \\
;

const source_selectors =
    \\@import "reset.css";
    \\@import url("theme.css");
    \\
    \\.card > .inner,
    \\#main .card:hover {
    \\    color: red;
    \\}
    \\
    \\#footer::before {
    \\    content: "";
    \\}
    \\
;

fn title_of(value: anytype) []const u8 {
    comptime assert(@typeInfo(@TypeOf(value)) == .@"enum");

    const title: []const u8 = switch (value) {
        inline else => |tag| comptime camel_of(@tagName(tag)),
    };

    assert(title.len > 0);
    assert(std.ascii.isUpper(title[0]));

    return title;
}
