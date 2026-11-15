const std = @import("std");
const assert = std.debug.assert;
const Span = @import("../stdx/bounded/span.zig");
const core = @import("semantic.zig");
const go = @import("go/semantic.zig");
const javascript = @import("javascript/semantic.zig");
const odin = @import("odin/semantic.zig");
const python = @import("python/semantic.zig");
const rust = @import("rust/semantic.zig");
const zig = @import("zig/semantic.zig");

pub const Bindings = union(enum) {
    empty,
    go: *const go.Semantic,
    javascript: *const javascript.Semantic,
    odin: *const odin.Semantic,
    python: *const python.Semantic,
    rust: *const rust.Semantic,
    zig: *const zig.Semantic,

    pub const Binding = core.Row;
    pub const Class = core.BindingClass;
    pub const Reference = core.ReferenceRow;
    pub const Resolution = core.Resolution;
    pub const Scope = core.ScopeRow;

    pub const BindingReferences = struct {
        binding: u32,
        bindings: Bindings,
        pending: ?u32,
        remaining: u32,

        pub fn next(iterator: *BindingReferences) ?Reference {
            assert(iterator.remaining <= iterator.bindings.reference_count());

            if (iterator.remaining == 0) return null;

            const index = iterator.pending orelse return null;
            const reference = iterator.bindings.reference_at(index);

            assert(reference.resolution.bound == iterator.binding);

            iterator.pending = iterator.bindings.reference_next_of(index);
            iterator.remaining -= 1;

            return reference;
        }
    };

    pub const ScopeBindings = struct {
        bindings: Bindings,
        index: u32,
        remaining: u32,
        scope: u32,

        pub fn next(iterator: *ScopeBindings) ?u32 {
            assert(iterator.remaining <= iterator.bindings.count());
            assert(iterator.index + iterator.remaining == iterator.bindings.count());

            for (0..iterator.remaining) |_| {
                const index = iterator.index;

                iterator.index += 1;
                iterator.remaining -= 1;

                if (iterator.bindings.at(index).scope == iterator.scope) return index;
            }

            assert(iterator.remaining == 0);

            return null;
        }
    };

    pub fn count(bindings: Bindings) u32 {
        const binding_count: u32 = switch (bindings) {
            .empty => 0,
            inline else => |semantic| semantic.count(),
        };

        if (bindings == .empty) assert(binding_count == 0);
        if (binding_count > 0) assert(bindings.scope_count() > 0);

        return binding_count;
    }

    pub fn at(bindings: Bindings, index: u32) Binding {
        assert(index < bindings.count());

        const binding: Binding = switch (bindings) {
            .empty => unreachable,
            inline else => |held| held.row(index),
        };

        assert(binding.scope < bindings.scope_count());

        return binding;
    }

    pub fn members_of(bindings: Bindings, scope: u32) ScopeBindings {
        assert(scope < bindings.scope_count());

        const iterator: ScopeBindings = .{
            .bindings = bindings,
            .index = 0,
            .remaining = bindings.count(),
            .scope = scope,
        };

        assert(iterator.remaining == bindings.count());

        return iterator;
    }

    pub fn reference_bound_named(bindings: Bindings, name: Span) ?u32 {
        assert(name.length <= std.math.maxInt(u32) - name.offset);
        if (bindings == .empty) return null;

        const found: ?u32 = switch (bindings) {
            .empty => null,
            inline else => |semantic| semantic.reference_bound_named(name),
        };

        if (found) |index| assert(index < bindings.reference_count());

        return found;
    }

    fn reference_first_of(bindings: Bindings, binding: u32) ?u32 {
        assert(binding < bindings.count());

        const found: ?u32 = switch (bindings) {
            .empty => unreachable,
            inline else => |semantic| semantic.reference_first_of(binding),
        };

        if (found) |index| assert(index < bindings.reference_count());

        return found;
    }

    fn reference_next_of(bindings: Bindings, index: u32) ?u32 {
        assert(index < bindings.reference_count());

        const found: ?u32 = switch (bindings) {
            .empty => unreachable,
            inline else => |semantic| semantic.reference_next_of(index),
        };

        if (found) |next| assert(next > index);

        return found;
    }

    pub fn reference_count(bindings: Bindings) u32 {
        const held: u32 = switch (bindings) {
            .empty => 0,
            inline else => |semantic| @intCast(semantic.reference_slice().len),
        };

        if (bindings == .empty) assert(held == 0);
        if (held > 0) assert(bindings.scope_count() > 0);

        return held;
    }

    pub fn reference_at(bindings: Bindings, index: u32) Reference {
        assert(index < bindings.reference_count());

        const reference: Reference = switch (bindings) {
            .empty => unreachable,
            inline else => |held| held.reference_row(index),
        };

        assert(reference.scope < bindings.scope_count());

        return reference;
    }

    pub fn references_of(bindings: Bindings, binding: u32) BindingReferences {
        assert(binding < bindings.count());

        const iterator: BindingReferences = .{
            .binding = binding,
            .bindings = bindings,
            .pending = bindings.reference_first_of(binding),
            .remaining = bindings.reference_count(),
        };

        if (iterator.pending) |index| assert(index < bindings.reference_count());

        return iterator;
    }

    pub fn scope_count(bindings: Bindings) u32 {
        const held: u32 = switch (bindings) {
            .empty => 0,
            inline else => |semantic| @intCast(semantic.scope_slice().len),
        };

        if (bindings == .empty) assert(held == 0);
        if (held > 0) assert(bindings != .empty);

        return held;
    }

    pub fn scope_at(bindings: Bindings, index: u32) Scope {
        assert(index < bindings.scope_count());

        const scope: Scope = switch (bindings) {
            .empty => unreachable,
            inline else => |held| held.scope_row(index),
        };

        if (scope.parent) |parent| assert(parent < bindings.scope_count());
        if (scope.parent) |parent| assert(parent < index);

        return scope;
    }
};

pub const reference_count_max = core.reference_count_max;

test "an empty table holds no binding, reference or scope" {
    const bindings: Bindings = .empty;

    try std.testing.expectEqual(0, bindings.count());
    try std.testing.expectEqual(0, bindings.reference_count());
    try std.testing.expectEqual(0, bindings.scope_count());
}
