const std = @import("std");
const assert = std.debug.assert;
const ArrayType = @import("../stdx/bounded/array.zig").ArrayType;
const Span = @import("../stdx/bounded/span.zig");
const camel_of = @import("category.zig").camel_of;

pub const Fact = struct {
    binding: BindingIndex,
    kind: FactKind,
    local: Span,
    remote: Span,
    specifier: Span,

    pub const Kind = FactKind;

    pub const BindingIndex = enum(u32) {
        none = std.math.maxInt(u32),
        _,

        pub fn of(binding: ?u32) BindingIndex {
            if (binding) |held| assert(held < std.math.maxInt(u32));

            const held = binding orelse return .none;
            const index: BindingIndex = @fromBackingInt(held);

            assert(index != .none);

            return index;
        }

        pub fn unwrap(index: BindingIndex) ?u32 {
            if (index == .none) return null;
            return @backingInt(index);
        }
    };

    pub fn local_span(fact: Fact) ?Span {
        assert(fact.local.length <= std.math.maxInt(u32) - fact.local.offset);

        return span_named(fact.local);
    }

    pub fn remote_span(fact: Fact) ?Span {
        assert(fact.local.length <= std.math.maxInt(u32) - fact.local.offset);

        return span_named(fact.remote);
    }

    pub fn specifier_span(fact: Fact) ?Span {
        assert(fact.local.length <= std.math.maxInt(u32) - fact.local.offset);

        return span_named(fact.specifier);
    }

    fn span_named(span: Span) ?Span {
        if (span.length == 0) return null;
        return span;
    }
};

pub const FactKind = union(enum) {
    export_all,
    export_default,
    export_named,
    extends,
    import_default,
    import_named,
    import_namespace,
    import_side_effect,
    import_type,
    include: Include,
    reexport,

    pub const Include = struct {
        only: bool,
    };

    pub fn exports(kind: FactKind) bool {
        if (kind == .include) return false;

        return switch (kind) {
            .export_all, .export_default, .export_named, .reexport => true,
            else => false,
        };
    }

    pub fn imports(kind: FactKind) bool {
        if (kind == .include) return true;

        return !kind.exports();
    }

    pub fn name(kind: FactKind) []const u8 {
        const text: []const u8 = switch (kind) {
            inline else => |_, tag| comptime camel_of(@tagName(tag)),
        };

        assert(text.len > 0);
        assert(std.ascii.isUpper(text[0]));

        return text;
    }
};

pub const Facts = struct {
    items: ArrayType(Fact),

    pub fn init(gpa: std.mem.Allocator, fact_count_max: u32) std.mem.Allocator.Error!Facts {
        assert(fact_count_max > 0);

        const items: ArrayType(Fact) = try .init(gpa, fact_count_max);

        assert(items.capacity() == fact_count_max);
        assert(items.empty());

        return .{ .items = items };
    }

    pub fn deinit(facts: *Facts, gpa: std.mem.Allocator) void {
        facts.items.deinit(gpa);
        facts.* = undefined;
    }

    pub fn clear(facts: *Facts) void {
        facts.items.clear();

        assert(facts.count() == 0);
        assert(!facts.full());
    }

    pub fn count(facts: *const Facts) u32 {
        return facts.items.count();
    }

    pub fn full(facts: *const Facts) bool {
        const result = facts.items.full();

        if (result) assert(facts.count() == facts.items.capacity());
        if (!result) assert(facts.count() < facts.items.capacity());

        return result;
    }

    pub fn push(facts: *Facts, fact: Fact) error{Truncated}!void {
        assert(fact.local.length <= std.math.maxInt(u32) - fact.local.offset);
        assert(fact.remote.length <= std.math.maxInt(u32) - fact.remote.offset);
        assert(fact.specifier.length <= std.math.maxInt(u32) - fact.specifier.offset);

        if (facts.items.full()) return error.Truncated;

        const fact_count_before = facts.count();

        facts.items.push(fact);

        assert(facts.count() == fact_count_before + 1);
        assert(std.meta.eql(facts.items.get(fact_count_before), fact));
    }

    pub fn slice(facts: *const Facts) []const Fact {
        return facts.items.const_slice();
    }
};

comptime {
    assert(@sizeOf(Fact) == 32);
    assert(@typeInfo(FactKind).@"union".field_names.len == 11);
}

test "a fact reads an absent binding and its empty spans as null" {
    const specifier: Span = .{ .offset = 7, .length = 5 };

    const bare: Fact = .{
        .binding = .none,
        .kind = .import_side_effect,
        .local = .empty,
        .remote = .empty,
        .specifier = specifier,
    };

    const bound: Fact = .{
        .binding = .of(3),
        .kind = .import_named,
        .local = specifier,
        .remote = specifier,
        .specifier = specifier,
    };

    try std.testing.expectEqual(null, bare.binding.unwrap());
    try std.testing.expectEqual(null, bare.local_span());
    try std.testing.expectEqual(null, bare.remote_span());
    try std.testing.expectEqual(specifier, bare.specifier_span().?);
    try std.testing.expectEqual(3, bound.binding.unwrap().?);
    try std.testing.expectEqual(Fact.BindingIndex.none, Fact.BindingIndex.of(null));
}

test "a template fact imports" {
    const extends: FactKind = .extends;
    const only: FactKind = .{ .include = .{ .only = true } };
    const partial: FactKind = .{ .include = .{ .only = false } };

    try std.testing.expect(extends.imports());
    try std.testing.expect(only.imports());
    try std.testing.expect(!partial.exports());
    try std.testing.expectEqualStrings("Extends", extends.name());
    try std.testing.expectEqualStrings("Include", only.name());
}
