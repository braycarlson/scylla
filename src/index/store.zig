const std = @import("std");
const assert = std.debug.assert;
const ArrayType = @import("../stdx/bounded/array.zig").ArrayType;
const Bindings = @import("../syntax/binding.zig").Bindings;
const Buffer = @import("../stdx/bounded/buffer.zig");
const CheckError = @import("../syntax/python/check.zig").CheckError;
const Fact = @import("../syntax/fact.zig").Fact;
const FileID = @import("../stdx/file_id.zig").FileID;
const FixedMapType = @import("../stdx/bounded/fixed_map.zig").FixedMapType;
const Front = @import("../syntax/front.zig").Front;
const Language = @import("../syntax/language.zig").Language;
const PRNG = @import("../testing/prng.zig");
const PythonVersion = @import("../syntax/python/stdlib.zig").PythonVersion;
const SourceType = @import("../syntax/language.zig").SourceType;
const Structure = @import("../syntax/tree.zig").Structure;
const Diagnostic = @import("../syntax/diagnostic.zig").Diagnostic;
const Token = @import("../syntax/token.zig");
const css = @import("../syntax/grammars.zig").css;
const front_module = @import("../syntax/front.zig");
const go = @import("../syntax/grammars.zig").go;
const javascript = @import("../syntax/grammars.zig").javascript;
const LineIndex = @import("../text/line_index.zig").LineIndex;
const markup = @import("../syntax/markup.zig");
const odin = @import("../syntax/grammars.zig").odin;
const python = @import("../syntax/grammars.zig").python;
const rust = @import("../syntax/grammars.zig").rust;
const zig = @import("../syntax/grammars.zig").zig;
const Store = @This();

clock: u64,
counter: u64,
eviction: Eviction,
globals: [Language.count][]const []const u8,
index: Table,
limits: Limits,
moves: u64,
pending: ArrayType(u32),
python_version: PythonVersion,
resident_count: u32,
scratch: Front.Scratch,
slots: []Slot,
starts: [Language.count][class_count]u32,
template_imports: []const []const u8,
vocabulary: markup.Vocabulary,

pub const Error = error{ Full, TooLarge };

pub const Eviction = enum {
    least_recently_used,
    reject,
};

pub const Limits = struct {
    file_count_max: u32,
    front: Front.Capacity,
    line_count_max: u32,
    slots: [Language.count][class_count]u32,
    source_bytes_max: u32,

    pub fn class_bytes(class: u32) u32 {
        assert(class < class_count);
        assert(class_bytes_min > 0);

        return class_bytes_min << @intCast(class);
    }

    pub fn class_of(bytes: u32) u32 {
        assert(bytes <= class_bytes(class_count - 1));

        var class: u32 = 0;

        for (0..class_count) |_| {
            if (class_bytes(class) >= bytes) break;

            class += 1;
        }

        assert(class_bytes(class) >= bytes);
        if (class > 0) assert(class_bytes(class - 1) < bytes);

        return class;
    }

    pub fn class_top(limits: *const Limits) u32 {
        assert(limits.source_bytes_max >= class_bytes_min);
        assert(std.math.isPowerOfTwo(limits.source_bytes_max));

        const top = class_of(limits.source_bytes_max);

        assert(class_bytes(top) == limits.source_bytes_max);

        return top;
    }

    pub fn slot_count(limits: *const Limits) u32 {
        var total: u32 = 0;

        for (limits.slots) |classes| {
            for (classes) |slots_held| total +|= slots_held;
        }

        assert(total >= limits.slots[0][0]);

        return total;
    }

    pub fn slot_spec_of(limits: *const Limits, slot_index: u32) SlotSpec {
        assert(slot_index < limits.file_count_max);
        assert(limits.slot_count() == limits.file_count_max);

        var at: u32 = 0;

        for (std.enums.values(Language)) |language| {
            for (limits.slots[@backingInt(language)], 0..) |slots_held, class| {
                const next = at +| slots_held;
                if (slot_index < next) return .{ .class = @intCast(class), .language = language };

                at = next;
            }
        }

        unreachable;
    }
};

pub const SlotSpec = struct {
    class: u32,
    language: Language,
};

pub const BuildScratch = struct {
    scratch: Front.Scratch,

    pub fn init(
        build_scratch: *BuildScratch,
        gpa: std.mem.Allocator,
        limits: *const Limits,
    ) std.mem.Allocator.Error!void {
        assert(limits.front.token_count_max > 0);
        assert(limits.file_count_max > 0);

        try build_scratch.scratch.init(gpa, &limits.front, wanted_of(limits));
    }

    pub fn deinit(build_scratch: *BuildScratch, gpa: std.mem.Allocator) void {
        build_scratch.scratch.deinit(gpa);
        build_scratch.* = undefined;
    }
};

pub const PendingBuilds = struct {
    globals: [Language.count][]const []const u8,
    options: Front.Options,
    pending: []const u32,
    slots: []Slot,

    pub fn build(builds: *const PendingBuilds, at: u32, build_scratch: *BuildScratch) void {
        assert(at < builds.pending.len);

        const slot_index = builds.pending[at];

        assert(slot_index < builds.slots.len);

        const slot = &builds.slots[slot_index];
        const claimed = slot.pending.swap(false, .acq_rel);

        assert(claimed);

        var held = builds.options;

        held.globals = builds.globals[@backingInt(slot.language)];

        slot_build(slot, &build_scratch.scratch, &held);
    }

    pub fn claimable(builds: *const PendingBuilds, at: u32) bool {
        assert(at < builds.pending.len);

        const slot_index = builds.pending[at];

        assert(slot_index < builds.slots.len);

        return builds.slots[slot_index].pending.load(.acquire);
    }

    pub fn count(builds: *const PendingBuilds) u32 {
        assert(builds.pending.len <= builds.slots.len);

        return @intCast(builds.pending.len);
    }
};

const Slot = struct {
    class: u32,
    declarations: FixedMapType(u32),
    flavor: SourceType.Flavor,
    forwards: FixedMapType(u32),
    front: Front,
    generation: u32,
    hash: u64,
    language: Language,
    lines: LineIndex,
    path_hash: u64,
    pending: std.atomic.Value(bool),
    rebuilds: u32,
    resident: bool,
    sequence: u64,
    source: Buffer,
    structure: ?Structure,
    touch: u64,

    fn init(
        slot: *Slot,
        gpa: std.mem.Allocator,
        spec: SlotSpec,
        limits: *const Limits,
    ) std.mem.Allocator.Error!void {
        const top = limits.class_top();

        assert(spec.class <= top);

        const shift = top - spec.class;
        const shrunk = front_module.capacity_shrunk(&limits.front, shift);

        slot.source = try .init(gpa, Limits.class_bytes(spec.class));
        errdefer slot.source.deinit(gpa);

        slot.lines = try .init(gpa, front_module.count_shrunk(limits.line_count_max, shift));
        errdefer slot.lines.deinit(gpa);

        try slot.front.init(gpa, &shrunk, spec.language);
        errdefer slot.front.deinit(gpa);

        const semantic = shrunk.semantic.?;

        slot.declarations = try .init(gpa, semantic.binding_count_max);
        errdefer slot.declarations.deinit(gpa);

        slot.forwards = try .init(gpa, semantic.fact_count_max);
        errdefer slot.forwards.deinit(gpa);

        assert(slot.declarations.entry_count_max == semantic.binding_count_max);
        assert(slot.forwards.entry_count_max == semantic.fact_count_max);

        slot.class = spec.class;
        slot.generation = 0;
        slot.language = spec.language;
        slot.pending = .init(false);
        slot.rebuilds = 0;

        slot.vacate();

        assert(!slot.resident);
    }

    fn deinit(slot: *Slot, gpa: std.mem.Allocator) void {
        assert(slot.source.count() <= slot.source.capacity());
        assert(slot.class < class_count);

        slot.declarations.deinit(gpa);
        slot.forwards.deinit(gpa);
        slot.front.deinit(gpa);
        slot.lines.deinit(gpa);
        slot.source.deinit(gpa);
        slot.* = undefined;
    }

    fn index_build(slot: *Slot) void {
        const source = slot.source.const_slice();
        const facts = slot.front.facts();

        slot.index_clear();

        assert(facts.len <= slot.forwards.entry_count_max);

        for (facts, 0..) |fact, position| {
            if (fact.specifier_span() == null) continue;

            const named = fact.local_span() orelse continue;
            if (named.length > name_bytes_max) continue;

            const local = named.text(source);

            slot.forwards.insert(local, @intCast(position)) catch |err| switch (err) {
                error.Duplicate => {},
                error.Overflow => unreachable,
            };
        }

        switch (slot.language) {
            .css, .markup => return,
            else => {},
        }

        const bindings = slot.front.bindings();
        const binding_count = bindings.count();

        assert(binding_count <= slot.declarations.entry_count_max);

        for (0..binding_count) |step| {
            const binding = bindings.at(@intCast(binding_count - 1 - step));
            if (binding.scope != 0) continue;
            if (binding.name.length == 0) continue;
            if (binding.name.length > name_bytes_max) continue;

            const name = binding.name.text(source);

            slot.declarations.insert(name, binding.node) catch |err| switch (err) {
                error.Duplicate => {},
                error.Overflow => unreachable,
            };
        }

        assert(slot.forwards.count() <= facts.len);
        assert(slot.declarations.count() <= binding_count);
    }

    fn index_clear(slot: *Slot) void {
        slot.declarations.clear();
        slot.forwards.clear();

        assert(slot.declarations.count() == 0);
        assert(slot.forwards.count() == 0);
    }

    fn vacate(slot: *Slot) void {
        slot.hash = 0;
        slot.path_hash = 0;
        slot.resident = false;
        slot.sequence = 0;

        slot.source.clear();
        slot.structure = null;

        slot.front.clear();
        slot.index_clear();
        slot.flavor = .plain;
        slot.touch = 0;

        slot.lines.clear();

        assert(!slot.resident);
        assert(slot.source.count() == 0);
    }
};

const Table = struct {
    count: u32,
    occupied_max: u32,
    keys: []u64,
    states: []State,
    values: []u32,

    const State = enum {
        empty,
        full,
    };

    fn init(gpa: std.mem.Allocator, occupied_max: u32) error{OutOfMemory}!Table {
        assert(occupied_max > 0);

        const capacity = std.math.ceilPowerOfTwoAssert(u32, occupied_max * 2);

        assert(capacity >= occupied_max * 2);

        const keys = try gpa.alloc(u64, capacity);
        errdefer gpa.free(keys);

        const states = try gpa.alloc(State, capacity);
        errdefer gpa.free(states);

        const values = try gpa.alloc(u32, capacity);

        @memset(states, .empty);
        @memset(keys, 0);
        @memset(values, 0);

        return .{
            .count = 0,
            .occupied_max = occupied_max,
            .keys = keys,
            .states = states,
            .values = values,
        };
    }

    fn deinit(table: *Table, gpa: std.mem.Allocator) void {
        assert(table.count <= table.occupied_max);

        gpa.free(table.values);
        gpa.free(table.states);
        gpa.free(table.keys);
        table.* = undefined;
    }

    fn clear(table: *Table) void {
        @memset(table.states, .empty);

        table.count = 0;

        assert(table.count == 0);
    }

    fn get(table: *const Table, key: u64) ?u32 {
        var position = table.position_of(key);

        for (0..table.states.len) |_| {
            switch (table.states[position]) {
                .empty => return null,
                .full => if (table.keys[position] == key) return table.values[position],
            }

            position = table.position_next(position);
        }

        unreachable;
    }

    fn position_next(table: *const Table, position: usize) usize {
        assert(position < table.states.len);
        assert(std.math.isPowerOfTwo(table.states.len));

        return (position + 1) & (table.states.len - 1);
    }

    fn position_of(table: *const Table, key: u64) usize {
        const mask: u64 = table.states.len - 1;
        const position: usize = @intCast(mix_of(key) & mask);

        assert(position < table.states.len);

        return position;
    }

    fn insert(table: *Table, key: u64, value: u32) void {
        assert(table.count < table.occupied_max);
        assert(table.occupied_max * 2 <= table.states.len);
        assert(value < std.math.maxInt(u32));

        var position = table.position_of(key);

        for (0..table.states.len) |_| {
            switch (table.states[position]) {
                .empty => {
                    table.keys[position] = key;
                    table.states[position] = .full;
                    table.values[position] = value;
                    table.count += 1;

                    assert(table.count <= table.occupied_max);

                    return;
                },
                .full => if (table.keys[position] == key) {
                    table.values[position] = value;

                    return;
                },
            }

            position = table.position_next(position);
        }

        unreachable;
    }

    fn remove(table: *Table, key: u64) void {
        var position = table.position_of(key);

        for (0..table.states.len) |_| {
            switch (table.states[position]) {
                .empty => return,
                .full => if (table.keys[position] == key) {
                    table.vacate(position);
                    table.count -= 1;

                    return;
                },
            }

            position = table.position_next(position);
        }

        unreachable;
    }

    fn vacate(table: *Table, start: usize) void {
        assert(table.states[start] == .full);

        const mask = table.states.len - 1;
        var hole = start;
        var position = table.position_next(start);

        for (0..table.states.len) |_| {
            if (table.states[position] == .empty) break;

            const home = table.position_of(table.keys[position]);
            const displacement = (position -% home) & mask;
            const gap = (position -% hole) & mask;

            if (displacement >= gap) {
                table.keys[hole] = table.keys[position];
                table.values[hole] = table.values[position];
                hole = position;
            }

            position = table.position_next(position);
        } else unreachable;

        table.states[hole] = .empty;
    }
};

pub const class_bytes_min: u32 = 1 << 10;
pub const class_count: u32 = 13;
pub const name_bytes_max: u32 = 256;
const hash_of = std.hash.Fnv1a_64.hash;

pub fn init(
    store: *Store,
    gpa: std.mem.Allocator,
    limits: *const Limits,
    eviction: Eviction,
) error{OutOfMemory}!void {
    assert(limits.file_count_max > 0);
    assert(limits.line_count_max > 0);
    assert(limits.slot_count() == limits.file_count_max);

    const top = limits.class_top();

    for (limits.slots) |classes| {
        for (classes, 0..) |slots_held, class| {
            if (slots_held > 0) assert(class <= top);
        }
    }

    store.slots = try gpa.alloc(Slot, limits.file_count_max);
    errdefer gpa.free(store.slots);

    try store.slots_init(gpa, limits);
    errdefer for (store.slots) |*slot| slot.deinit(gpa);

    store.index = try .init(gpa, limits.file_count_max);
    errdefer store.index.deinit(gpa);

    store.pending = try .init(gpa, limits.file_count_max);
    errdefer store.pending.deinit(gpa);

    try store.scratch.init(gpa, &limits.front, wanted_of(limits));

    store.clock = 0;
    store.counter = 0;
    store.eviction = eviction;
    store.globals = @splat(&.{});
    store.limits = limits.*;
    store.moves = 0;
    store.python_version = .py310;
    store.resident_count = 0;
    store.template_imports = &.{};
    store.vocabulary = .empty;

    store.starts_init();

    assert(store.count() == 0);
}

fn slots_init(store: *Store, gpa: std.mem.Allocator, limits: *const Limits) !void {
    var ready: u32 = 0;
    errdefer for (store.slots[0..ready]) |*slot| slot.deinit(gpa);

    for (store.slots, 0..) |*slot, slot_index| {
        try slot.init(gpa, limits.slot_spec_of(@intCast(slot_index)), limits);

        ready += 1;
    }

    assert(ready == limits.file_count_max);
    assert(ready == store.slots.len);
}

fn starts_init(store: *Store) void {
    var at: u32 = 0;

    for (std.enums.values(Language)) |language| {
        for (&store.starts[@backingInt(language)], 0..) |*start, class| {
            start.* = at;
            at += store.limits.slots[@backingInt(language)][class];
        }
    }

    assert(at == store.limits.file_count_max);
    assert(at == store.slots.len);
}

pub fn deinit(store: *Store, gpa: std.mem.Allocator) void {
    assert(store.slots.len == store.limits.file_count_max);

    store.scratch.deinit(gpa);
    store.pending.deinit(gpa);
    store.index.deinit(gpa);

    for (store.slots) |*slot| slot.deinit(gpa);

    gpa.free(store.slots);
    store.* = undefined;
}

pub fn clear(store: *Store) void {
    for (store.slots) |*slot| {
        slot.rebuilds = 0;

        slot.vacate();
        slot.pending.store(false, .release);
    }

    store.pending.clear();
    store.clock = 0;
    store.counter = 0;
    store.moves += 1;
    store.resident_count = 0;

    store.index.clear();

    assert(store.count() == 0);
    assert(store.index.count == 0);
}

pub fn count(store: *const Store) u32 {
    const resident_count = store.resident_count;

    assert(resident_count <= store.limits.file_count_max);
    assert(resident_count <= store.index.occupied_max);

    return resident_count;
}

pub fn moves_count(store: *const Store) u64 {
    assert(store.slots.len == store.limits.file_count_max);
    assert(store.resident_count <= store.limits.file_count_max);

    return store.moves;
}

pub fn insert(store: *Store, path_hash: u64, kind: SourceType, source: []const u8) Error!u32 {
    assert(source.len <= std.math.maxInt(u32));
    assert(kind.valid());

    assert(store.index.get(path_hash) == null or
        store.slots[store.index.get(path_hash).?].path_hash == path_hash);

    return store.insert_with(path_hash, kind, source, false, hash_of(source));
}

pub fn insert_pending(
    store: *Store,
    path_hash: u64,
    kind: SourceType,
    source: []const u8,
) Error!u32 {
    assert(source.len <= std.math.maxInt(u32));
    assert(kind.valid());

    assert(store.index.get(path_hash) == null or
        store.slots[store.index.get(path_hash).?].path_hash == path_hash);

    return store.insert_with(path_hash, kind, source, true, hash_of(source));
}

pub fn insert_pending_hashed(
    store: *Store,
    path_hash: u64,
    kind: SourceType,
    source: []const u8,
    hash: u64,
) Error!u32 {
    assert(hash == hash_of(source));
    assert(kind.valid());

    assert(store.index.get(path_hash) == null or
        store.slots[store.index.get(path_hash).?].path_hash == path_hash);

    return store.insert_with(path_hash, kind, source, true, hash);
}

fn insert_with(
    store: *Store,
    path_hash: u64,
    kind: SourceType,
    source: []const u8,
    deferred: bool,
    hash: u64,
) Error!u32 {
    assert(source.len <= std.math.maxInt(u32));

    assert(kind.valid());

    if (source.len > store.limits.source_bytes_max) return error.TooLarge;
    assert(hash == hash_of(source));

    assert(store.index.get(path_hash) == null or
        store.slots[store.index.get(path_hash).?].path_hash == path_hash);

    const class = Limits.class_of(@intCast(source.len));

    if (store.index.get(path_hash)) |held| {
        const slot = &store.slots[held];

        assert(slot.resident);

        if (slot.language == kind.language) {
            if (slot.flavor == kind.flavor) {
                if (slot.hash == hash) {
                    store.touch(.of(held));

                    return held;
                }

                if (slot.class >= class) {
                    store.settled(held, path_hash, kind, hash, source, deferred);

                    return held;
                }
            }
        }

        const moved = try store.vacancy_of(kind.language, class);

        store.index.remove(path_hash);
        store.release(held);
        store.settled(moved, path_hash, kind, hash, source, deferred);
        store.index.insert(path_hash, moved);

        assert(store.slots[moved].resident);

        return moved;
    }

    const target = try store.vacancy_of(kind.language, class);

    store.settled(target, path_hash, kind, hash, source, deferred);
    store.index.insert(path_hash, target);

    assert(store.slots[target].resident);

    return target;
}

pub fn evict(store: *Store, file: FileID) void {
    assert(@backingInt(file) != std.math.maxInt(u32));

    const slot_index = file.index();

    assert(slot_index < store.limits.file_count_max);
    assert(store.slots[slot_index].resident);

    store.index.remove(store.slots[slot_index].path_hash);
    store.release(slot_index);

    assert(!store.slots[slot_index].resident);
}

pub fn find(store: *const Store, path_hash: u64) ?u32 {
    assert(store.index.get(path_hash) == null or
        store.slots[store.index.get(path_hash).?].path_hash == path_hash);

    const slot_index = store.index.get(path_hash) orelse return null;

    assert(slot_index < store.limits.file_count_max);
    assert(store.slots[slot_index].resident);

    return slot_index;
}

pub fn files(store: *const Store) Files {
    assert(store.slots.len == store.limits.file_count_max);

    return .{ .cursor = 0, .store = store };
}

pub const Files = struct {
    cursor: u32,
    store: *const Store,

    pub fn next(iterator: *Files) ?FileID {
        const slots = iterator.store.slots;

        assert(iterator.cursor <= slots.len);

        for (0..slots.len) |_| {
            if (iterator.cursor >= slots.len) return null;

            const slot_index = iterator.cursor;

            iterator.cursor += 1;

            if (slots[slot_index].resident) return .of(slot_index);
        }

        return null;
    }
};

pub fn globals_set(store: *Store, language: Language, names: []const []const u8) void {
    assert(names.len <= std.math.maxInt(u32));

    store.globals[@backingInt(language)] = names;

    assert(store.globals[@backingInt(language)].len == names.len);
}

pub fn python_version_set(store: *Store, version: PythonVersion) void {
    store.python_version = version;

    assert(store.python_version == version);
}

pub fn template_imports_set(store: *Store, names: []const []const u8) void {
    assert(names.len <= std.math.maxInt(u32));

    store.template_imports = names;

    assert(store.template_imports.len == names.len);
}

pub fn vocabulary_set(store: *Store, vocabulary: markup.Vocabulary) void {
    assert(store.slots.len == store.limits.file_count_max);
    if (vocabulary.end_prefix) |prefix| assert(prefix.len > 0);

    store.vocabulary = vocabulary;

    assert(store.vocabulary.extends_tags.len == vocabulary.extends_tags.len);
}

pub fn pending_builds(store: *Store) PendingBuilds {
    assert(store.pending.count() <= store.limits.file_count_max);

    return .{
        .globals = store.globals,
        .options = store.options(),
        .pending = store.pending.const_slice(),
        .slots = store.slots,
    };
}

pub fn pending_clear(store: *Store) void {
    for (store.pending.const_slice()) |slot_index| {
        assert(!store.slots[slot_index].pending.load(.acquire));
    }

    store.pending.clear();

    assert(store.pending.empty());
}

pub fn pending_count(store: *const Store) u32 {
    assert(store.pending.count() <= store.limits.file_count_max);

    return store.pending.count();
}

pub fn is_pending(store: *const Store, file: FileID) bool {
    assert(@backingInt(file) != std.math.maxInt(u32));

    const slot_index = file.index();

    assert(slot_index < store.limits.file_count_max);

    return store.slots[slot_index].pending.load(.acquire);
}

pub fn bindings_of(store: *const Store, file: FileID) Bindings {
    assert(@backingInt(file) != std.math.maxInt(u32));

    return store.slot_of(file).front.bindings();
}

pub fn declaration_of(store: *const Store, file: FileID, name: []const u8) ?u32 {
    assert(@backingInt(file) != std.math.maxInt(u32));

    const slot = store.slot_of(file);

    assert(name.len > 0);
    assert(slot.front.source.ptr == slot.source.const_slice().ptr);

    switch (slot.language) {
        .css, .markup => return slot.front.declaration_of(name),
        else => {},
    }

    if (name.len > name_bytes_max) return slot.front.declaration_of(name);

    const node = slot.declarations.get(name) orelse return null;

    assert(node < slot.front.node_count());
    assert(slot.front.declaration_of(name).? == node);

    return node;
}

pub fn diagnostics_of(store: *const Store, file: FileID) []const Diagnostic {
    assert(@backingInt(file) != std.math.maxInt(u32));

    return store.slot_of(file).front.diagnostics();
}

pub fn facts_of(store: *const Store, file: FileID) []const Fact {
    assert(@backingInt(file) != std.math.maxInt(u32));

    return store.slot_of(file).front.facts();
}

pub fn forward_of(store: *const Store, file: FileID, name: []const u8) ?u32 {
    assert(@backingInt(file) != std.math.maxInt(u32));

    const slot = store.slot_of(file);
    const source = slot.source.const_slice();
    const facts = slot.front.facts();

    assert(name.len > 0);

    if (name.len > name_bytes_max) return forward_scanned(facts, source, name);

    const position = slot.forwards.get(name) orelse return null;
    const fact = facts[position];

    assert(fact.specifier_span() != null);
    assert(std.mem.eql(u8, fact.local_span().?.text(source), name));
    assert(forward_scanned(facts, source, name).? == position);

    return position;
}

fn forward_scanned(facts: []const Fact, source: []const u8, name: []const u8) ?u32 {
    assert(name.len > 0);
    assert(facts.len <= std.math.maxInt(u32));
    assert(source.len <= std.math.maxInt(u32));

    for (facts, 0..) |fact, position| {
        if (fact.specifier_span() == null) continue;

        const local = fact.local_span() orelse continue;
        if (!std.mem.eql(u8, local.text(source), name)) continue;
        assert(position < facts.len);

        return @intCast(position);
    }

    return null;
}

pub fn front_of(store: *const Store, file: FileID) *const Front {
    assert(@backingInt(file) != std.math.maxInt(u32));

    return &store.slot_of(file).front;
}

pub fn generation_of(store: *const Store, file: FileID) u32 {
    assert(@backingInt(file) != std.math.maxInt(u32));

    const slot_index = file.index();

    assert(slot_index < store.limits.file_count_max);

    return store.slots[slot_index].generation;
}

pub fn css_semantic(store: *const Store, file: FileID) ?*const css.Semantic {
    assert(@backingInt(file) != std.math.maxInt(u32));

    return front_module.css_semantic_of(store.front_of(file));
}

pub fn go_semantic(store: *const Store, file: FileID) ?*const go.Semantic {
    assert(@backingInt(file) != std.math.maxInt(u32));

    return switch (store.bindings_of(file)) {
        .go => |held| held,
        .empty, .javascript, .odin, .python, .rust, .zig => null,
    };
}

pub fn has_errors_of(store: *const Store, file: FileID) bool {
    assert(@backingInt(file) != std.math.maxInt(u32));

    return store.slot_of(file).front.has_diagnostics();
}

pub fn hash_of_file(store: *const Store, file: FileID) u64 {
    assert(@backingInt(file) != std.math.maxInt(u32));

    return store.slot_of(file).hash;
}

pub fn javascript_semantic(store: *const Store, file: FileID) ?*const javascript.Semantic {
    assert(@backingInt(file) != std.math.maxInt(u32));

    return switch (store.bindings_of(file)) {
        .javascript => |held| held,
        .empty, .go, .odin, .python, .rust, .zig => null,
    };
}

pub fn language_of(store: *const Store, file: FileID) Language {
    assert(@backingInt(file) != std.math.maxInt(u32));

    return store.slot_of(file).language;
}

pub fn limits_of(store: *const Store) *const Limits {
    assert(store.limits.file_count_max == store.slots.len);

    return &store.limits;
}

pub fn lines_of(store: *const Store, file: FileID) *const LineIndex {
    assert(@backingInt(file) != std.math.maxInt(u32));

    return &store.slot_of(file).lines;
}

pub fn markup_errors_of(store: *const Store, file: FileID) []const markup.Document.Diagnostic {
    assert(@backingInt(file) != std.math.maxInt(u32));

    const held = store.slot_of(file).front.markup() orelse return &.{};
    return held.diagnostics();
}

pub fn markup_tokens_of(store: *const Store, file: FileID) []const markup.Token {
    assert(@backingInt(file) != std.math.maxInt(u32));

    const held = store.slot_of(file).front.markup() orelse return &.{};
    return held.tokens();
}

pub fn markup_tree_of(store: *const Store, file: FileID) ?*const markup.Document.Tree {
    assert(@backingInt(file) != std.math.maxInt(u32));

    const held = store.slot_of(file).front.markup() orelse return null;
    return held.tree();
}

pub fn odin_semantic(store: *const Store, file: FileID) ?*const odin.Semantic {
    assert(@backingInt(file) != std.math.maxInt(u32));

    return switch (store.bindings_of(file)) {
        .odin => |held| held,
        .empty, .go, .javascript, .python, .rust, .zig => null,
    };
}

pub fn path_hash_of(store: *const Store, file: FileID) u64 {
    assert(@backingInt(file) != std.math.maxInt(u32));

    return store.slot_of(file).path_hash;
}

pub fn python_checks_of(store: *const Store, file: FileID) []const CheckError {
    assert(@backingInt(file) != std.math.maxInt(u32));

    return front_module.python_checks_of(&store.slot_of(file).front);
}

pub fn python_semantic(store: *const Store, file: FileID) ?*const python.Semantic {
    assert(@backingInt(file) != std.math.maxInt(u32));

    return switch (store.bindings_of(file)) {
        .python => |held| held,
        .empty, .go, .javascript, .odin, .rust, .zig => null,
    };
}

pub fn rebuilds_of(store: *const Store, file: FileID) u32 {
    assert(@backingInt(file) != std.math.maxInt(u32));

    return store.slot_of(file).rebuilds;
}

pub fn resident(store: *const Store, file: FileID) bool {
    assert(@backingInt(file) != std.math.maxInt(u32));

    const slot_index = file.index();

    assert(slot_index < store.limits.file_count_max);

    return store.slots[slot_index].resident;
}

pub fn rust_semantic(store: *const Store, file: FileID) ?*const rust.Semantic {
    assert(@backingInt(file) != std.math.maxInt(u32));

    return switch (store.bindings_of(file)) {
        .rust => |held| held,
        .empty, .go, .javascript, .odin, .python, .zig => null,
    };
}

pub fn sequence_of(store: *const Store, file: FileID) u64 {
    assert(@backingInt(file) != std.math.maxInt(u32));

    const sequence = store.slot_of(file).sequence;

    assert(sequence > 0);

    return sequence;
}

pub fn slot_bytes_of(store: *const Store, slot_index: u32) u32 {
    assert(slot_index < store.limits.file_count_max);

    return Limits.class_bytes(store.slots[slot_index].class);
}

pub fn slot_language_of(store: *const Store, slot_index: u32) Language {
    assert(slot_index < store.limits.file_count_max);

    return store.slots[slot_index].language;
}

pub fn source_of(store: *const Store, file: FileID) []const u8 {
    assert(@backingInt(file) != std.math.maxInt(u32));

    return store.slot_of(file).source.const_slice();
}

pub fn structure_of(store: *const Store, file: FileID) ?Structure {
    assert(@backingInt(file) != std.math.maxInt(u32));

    return store.slot_of(file).structure;
}

pub fn tokens_of(store: *const Store, file: FileID) []const Token {
    assert(@backingInt(file) != std.math.maxInt(u32));

    return store.slot_of(file).front.tokens();
}

pub fn zig_semantic(store: *const Store, file: FileID) ?*const zig.Semantic {
    assert(@backingInt(file) != std.math.maxInt(u32));

    return switch (store.bindings_of(file)) {
        .zig => |held| held,
        .empty, .go, .javascript, .odin, .python, .rust => null,
    };
}

pub fn touch(store: *Store, file: FileID) void {
    assert(@backingInt(file) != std.math.maxInt(u32));

    const slot_index = file.index();

    assert(slot_index < store.limits.file_count_max);
    assert(store.slots[slot_index].resident);

    store.clock += 1;
    store.slots[slot_index].touch = store.clock;

    assert(store.slots[slot_index].touch == store.clock);
}

fn slot_of(store: *const Store, file: FileID) *const Slot {
    assert(slot_resident(store, file));

    const slot_index = file.index();

    assert(slot_index < store.limits.file_count_max);
    assert(!store.slots[slot_index].pending.load(.acquire));

    return &store.slots[slot_index];
}

pub fn slot_resident(store: *const Store, file: FileID) bool {
    assert(file.index() < store.limits.file_count_max);
    assert(store.slots.len == store.limits.file_count_max);

    return store.slots[file.index()].resident;
}

fn options(store: *const Store) Front.Options {
    assert(store.template_imports.len <= std.math.maxInt(u32));
    assert(store.globals.len == Language.count);

    var vocabulary = store.vocabulary;
    vocabulary.template_imports = store.template_imports;

    return .{
        .globals = &.{},
        .python_version = store.python_version,
        .vocabulary = vocabulary,
    };
}

fn place(store: *Store, slot_index: u32, path_hash: u64, hash: u64, source: []const u8) void {
    assert(slot_index < store.limits.file_count_max);
    assert(source.len <= store.limits.source_bytes_max);
    assert((store.index.get(path_hash) orelse slot_index) == slot_index);
    if (store.slots[slot_index].resident) assert(store.slots[slot_index].hash != hash);

    store.moves += 1;

    const slot = &store.slots[slot_index];
    const rebuilds = slot.rebuilds;

    assert(source.len <= Limits.class_bytes(slot.class));
    assert(!slot.pending.load(.acquire));

    if (!slot.resident) {
        store.counter += 1;
        slot.sequence = store.counter;
        store.resident_count += 1;
    }

    slot.lines.clear();
    slot.source.clear();
    slot.front.clear();
    slot.index_clear();
    slot.source.push(source) catch unreachable;
    slot.generation +%= 1;
    slot.hash = hash;
    slot.path_hash = path_hash;
    slot.rebuilds = rebuilds + 1;
    slot.resident = true;
    slot.structure = null;
    store.clock += 1;
    slot.touch = store.clock;

    assert(slot.resident);
    assert(slot.rebuilds == rebuilds + 1);
}

fn settled(
    store: *Store,
    slot_index: u32,
    path_hash: u64,
    kind: SourceType,
    hash: u64,
    source: []const u8,
    deferred: bool,
) void {
    assert(slot_index < store.slots.len);
    assert(source.len <= std.math.maxInt(u32));
    assert((store.index.get(path_hash) orelse slot_index) == slot_index);
    if (store.slots[slot_index].resident) assert(store.slots[slot_index].hash != hash);

    store.place(slot_index, path_hash, hash, source);

    const slot = &store.slots[slot_index];

    assert(slot.language == kind.language);

    slot.flavor = kind.flavor;

    if (!deferred) {
        var held = store.options();

        held.globals = store.globals[@backingInt(slot.language)];

        slot_build(slot, &store.scratch, &held);

        return;
    }

    slot.pending.store(true, .release);
    store.pending.push(slot_index);

    assert(store.pending.count() <= store.limits.file_count_max);
}

fn release(store: *Store, slot_index: u32) void {
    assert(slot_index < store.limits.file_count_max);
    assert(!store.slots[slot_index].pending.load(.acquire));

    store.moves += 1;

    const slot = &store.slots[slot_index];

    if (slot.resident) store.resident_count -= 1;

    slot.generation +%= 1;

    slot.vacate();

    assert(!slot.resident);
}

fn vacancy_of(store: *Store, language: Language, class: u32) Error!u32 {
    assert(@backingInt(language) < store.starts.len);

    const top = store.limits.class_top();

    assert(class <= top);

    var oldest: ?u32 = null;
    var oldest_touch: u64 = std.math.maxInt(u64);

    for (class..top + 1) |held| {
        const start = store.starts[@backingInt(language)][held];
        const slot_slots_held = store.limits.slots[@backingInt(language)][held];

        for (start..start + slot_slots_held) |slot_index| {
            const slot = &store.slots[slot_index];

            if (!slot.resident) {
                assert(slot_index < std.math.maxInt(u32));

                return @intCast(slot_index);
            }

            if (slot.pending.load(.acquire)) continue;

            if (slot.touch < oldest_touch) {
                oldest = @intCast(slot_index);
                oldest_touch = slot.touch;
            }
        }
    }

    const evicted = oldest orelse return error.Full;

    if (store.eviction == .reject) return error.Full;

    store.evict(.of(evicted));

    assert(!store.slots[evicted].resident);

    return evicted;
}

fn slot_build(slot: *Slot, scratch: *Front.Scratch, held_options: *const Front.Options) void {
    const source = slot.source.const_slice();
    var indexed = true;

    slot.lines.build(source) catch |err| switch (err) {
        error.Truncated => indexed = false,
    };

    const source_type: SourceType = .{ .flavor = slot.flavor, .language = slot.language };
    const parsed = slot.front.parse(scratch, source_type, source, held_options);
    const built: Structure = if (parsed) |_| .complete else |_| slot.front.outcome.?;

    slot.structure = if (indexed) built else .{ .truncated = .lines };

    slot.index_build();

    if (!indexed) assert(slot.structure.? == .truncated);
    assert(source_type.valid());
}

fn wanted_of(limits: *const Limits) std.EnumSet(Language) {
    var wanted: std.EnumSet(Language) = .empty;

    for (std.enums.values(Language)) |language| {
        for (limits.slots[@backingInt(language)]) |slots_held| {
            if (slots_held > 0) wanted.insert(language);
        }
    }

    assert(wanted.count() <= Language.count);

    return wanted;
}

fn mix_of(key: u64) u64 {
    var hash = key;

    hash ^= hash >> 33;
    hash *%= 0xff51_afd7_ed55_8ccd;
    hash ^= hash >> 33;

    return hash;
}

const source_css_test = "a { color: red; }\n";
const source_python_test = "import os\n\n\ndef run():\n    return os\n";
const source_python_other_test = "import sys\n\n\ndef run():\n    return sys\n";
const source_rust_test = "fn run() -> u32 {\n    1\n}\n";
const source_template_test = "<div>{% block body %}{% endblock %}</div>\n";

const Mix = struct {
    slots: u32,
    language: Language,
};

fn limits_test(mix: []const Mix) Limits {
    assert(mix.len <= std.math.maxInt(u32));

    var slots: [Language.count][class_count]u32 = @splat(@splat(0));
    var total: u32 = 0;

    for (mix) |held| {
        slots[@backingInt(held.language)][Limits.class_of(4_096)] = held.slots;
        total += held.slots;
    }

    return .{
        .file_count_max = total,
        .front = .{
            .diagnostic_count_max = 64,
            .event_count_max = 4_096,
            .node_count_max = 2_048,
            .semantic = .{
                .binding_count_max = 256,
                .fact_count_max = 256,
                .reference_count_max = 256,
                .scope_count_max = 64,
            },
            .tag_count_max = 256,
            .token_count_max = 1_024,
        },
        .line_count_max = 256,
        .slots = slots,
        .source_bytes_max = 4_096,
    };
}

fn classed_limits_test() Limits {
    var limits = limits_test(&.{.{ .slots = 0, .language = .python }});

    limits.slots[@backingInt(Language.python)][0] = 1;
    limits.slots[@backingInt(Language.python)][2] = 1;
    limits.file_count_max = 2;

    return limits;
}

test "an insert reads back" {
    const gpa = std.testing.allocator;
    const limits = limits_test(&.{.{ .slots = 2, .language = .python }});
    var store: Store = undefined;

    try store.init(gpa, &limits, .reject);
    defer store.deinit(gpa);

    const index = try store.insert(hash_of("a.py"), .of(.python), source_python_test);
    const file: FileID = .of(index);

    try std.testing.expectEqual(1, store.count());
    try std.testing.expectEqualStrings(source_python_test, store.source_of(file));
    try std.testing.expectEqual(Language.python, store.language_of(file));
    try std.testing.expectEqual(Structure.complete, store.structure_of(file));
    try std.testing.expectEqual(hash_of(source_python_test), store.hash_of_file(file));
    try std.testing.expectEqual(index, store.find(hash_of("a.py")).?);
    try std.testing.expectEqual(null, store.find(hash_of("b.py")));
    try std.testing.expectEqual(0, store.diagnostics_of(file).len);
    try std.testing.expect(store.tokens_of(file).len > 0);
    try std.testing.expectEqual(6, store.lines_of(file).count());
}

test "an eviction never takes a slot whose build is pending" {
    const gpa = std.testing.allocator;
    const limits = limits_test(&.{.{ .slots = 2, .language = .python }});
    var store: Store = undefined;

    try store.init(gpa, &limits, .least_recently_used);
    defer store.deinit(gpa);

    const first = try store.insert_pending(hash_of("a.py"), .of(.python), source_python_test);

    const second = try store.insert_pending(
        hash_of("b.py"),
        .of(.python),
        source_python_other_test,
    );

    try std.testing.expect(store.is_pending(.of(first)));
    try std.testing.expect(store.is_pending(.of(second)));

    const third = store.insert_pending(hash_of("c.py"), .of(.python), source_python_test);

    try std.testing.expectError(error.Full, third);
    try std.testing.expect(store.is_pending(.of(first)));
    try std.testing.expect(store.is_pending(.of(second)));
    try std.testing.expectEqual(2, store.pending_count());
}

test "an eviction passes over a pending slot for a settled one" {
    const gpa = std.testing.allocator;
    const limits = limits_test(&.{.{ .slots = 2, .language = .python }});
    var store: Store = undefined;

    try store.init(gpa, &limits, .least_recently_used);
    defer store.deinit(gpa);

    const settled_index = try store.insert(hash_of("a.py"), .of(.python), source_python_test);

    const waiting = try store.insert_pending(
        hash_of("b.py"),
        .of(.python),
        source_python_other_test,
    );

    const third = try store.insert(hash_of("c.py"), .of(.python), source_python_test);

    try std.testing.expectEqual(settled_index, third);
    try std.testing.expect(store.is_pending(.of(waiting)));
    try std.testing.expectEqual(null, store.find(hash_of("a.py")));
    try std.testing.expectEqual(waiting, store.find(hash_of("b.py")).?);
    try std.testing.expectEqual(third, store.find(hash_of("c.py")).?);
}

test "identical bytes reuse the slot without a rebuild" {
    const gpa = std.testing.allocator;
    const limits = limits_test(&.{.{ .slots = 2, .language = .python }});
    var store: Store = undefined;

    try store.init(gpa, &limits, .reject);
    defer store.deinit(gpa);

    const first = try store.insert(hash_of("a.py"), .of(.python), source_python_test);
    const again = try store.insert(hash_of("a.py"), .of(.python), source_python_test);

    try std.testing.expectEqual(first, again);
    try std.testing.expectEqual(1, store.count());
    try std.testing.expectEqual(1, store.rebuilds_of(.of(first)));
}

test "changed bytes rebuild the same slot" {
    const gpa = std.testing.allocator;
    const limits = limits_test(&.{.{ .slots = 2, .language = .python }});
    var store: Store = undefined;

    try store.init(gpa, &limits, .reject);
    defer store.deinit(gpa);

    const first = try store.insert(hash_of("a.py"), .of(.python), source_python_test);
    const again = try store.insert(hash_of("a.py"), .of(.python), source_python_other_test);
    const file: FileID = .of(again);

    try std.testing.expectEqual(first, again);
    try std.testing.expectEqual(1, store.count());
    try std.testing.expectEqual(2, store.rebuilds_of(file));
    try std.testing.expectEqualStrings(source_python_other_test, store.source_of(file));
    try std.testing.expectEqual(hash_of(source_python_other_test), store.hash_of_file(file));
}

test "a full store rejects under reject" {
    const gpa = std.testing.allocator;
    const limits = limits_test(&.{.{ .slots = 1, .language = .python }});
    var store: Store = undefined;

    try store.init(gpa, &limits, .reject);
    defer store.deinit(gpa);

    const first = try store.insert(hash_of("a.py"), .of(.python), source_python_test);
    const second = store.insert(hash_of("b.py"), .of(.python), source_python_other_test);

    try std.testing.expectError(error.Full, second);
    try std.testing.expectEqual(1, store.count());
    try std.testing.expectEqual(first, store.find(hash_of("a.py")).?);
    try std.testing.expectEqual(null, store.find(hash_of("b.py")));
}

test "a full store evicts the least recently touched slot" {
    const gpa = std.testing.allocator;
    const limits = limits_test(&.{.{ .slots = 2, .language = .python }});
    var store: Store = undefined;

    try store.init(gpa, &limits, .least_recently_used);
    defer store.deinit(gpa);

    const first = try store.insert(hash_of("a.py"), .of(.python), source_python_test);
    const second = try store.insert(hash_of("b.py"), .of(.python), source_python_other_test);

    store.touch(.of(first));

    const third = try store.insert(hash_of("c.py"), .of(.python), source_python_test);

    try std.testing.expectEqual(second, third);
    try std.testing.expectEqual(2, store.count());
    try std.testing.expectEqual(first, store.find(hash_of("a.py")).?);
    try std.testing.expectEqual(null, store.find(hash_of("b.py")));
    try std.testing.expectEqual(third, store.find(hash_of("c.py")).?);
}

test "an evicting store survives churn through many distinct paths" {
    const gpa = std.testing.allocator;
    const limits = limits_test(&.{.{ .slots = 8, .language = .python }});
    var store: Store = undefined;

    try store.init(gpa, &limits, .least_recently_used);
    defer store.deinit(gpa);

    for (0..4_096) |round| {
        const path_hash: u64 = 0x1000 + round;
        const index = try store.insert(path_hash, .of(.python), source_python_test);

        try std.testing.expectEqual(index, store.find(path_hash).?);
    }

    try std.testing.expectEqual(8, store.count());
}

test "the path index agrees with a model through inserts and removals" {
    const gpa = std.testing.allocator;
    const occupied_max: u32 = 32;
    const key_count: u32 = 96;
    var table = try Table.init(gpa, occupied_max);
    defer table.deinit(gpa);

    var prng: PRNG = .init(0x51A7_E1D0_C0FF_EE01);
    var model: [key_count]?u32 = @splat(null);
    var model_count: u32 = 0;

    for (0..20_000) |step| {
        const key = prng.int_inclusive(u32, key_count - 1);
        const value: u32 = @intCast(step);
        const full = model_count == occupied_max;
        const inserting = if (full) false else prng.boolean();

        if (inserting) {
            if (model[key] == null) model_count += 1;

            model[key] = value;

            table.insert(key, value);
        } else {
            if (model[key] != null) model_count -= 1;

            model[key] = null;

            table.remove(key);
        }

        try std.testing.expectEqual(model_count, table.count);

        for (model, 0..) |held, index| {
            try std.testing.expectEqual(held, table.get(index));
        }
    }
}

test "an eviction frees the slot for the next insert" {
    const gpa = std.testing.allocator;
    const limits = limits_test(&.{.{ .slots = 1, .language = .python }});
    var store: Store = undefined;

    try store.init(gpa, &limits, .reject);
    defer store.deinit(gpa);

    const first = try store.insert(hash_of("a.py"), .of(.python), source_python_test);

    store.evict(.of(first));

    try std.testing.expectEqual(0, store.count());
    try std.testing.expectEqual(null, store.find(hash_of("a.py")));

    const second = try store.insert(hash_of("b.py"), .of(.python), source_python_other_test);

    try std.testing.expectEqual(first, second);
    try std.testing.expectEqual(1, store.count());
    try std.testing.expectEqualStrings(source_python_other_test, store.source_of(.of(second)));
}

test "a store holds several languages at once" {
    const gpa = std.testing.allocator;

    const limits = limits_test(&.{
        .{ .slots = 1, .language = .css },
        .{ .slots = 1, .language = .markup },
        .{ .slots = 1, .language = .python },
        .{ .slots = 1, .language = .rust },
    });

    var store: Store = undefined;

    try store.init(gpa, &limits, .reject);
    defer store.deinit(gpa);

    const sheet = try store.insert(hash_of("a.css"), .of(.css), source_css_test);
    const page = try store.insert(hash_of("a.html"), .of(.markup), source_template_test);
    const script = try store.insert(hash_of("a.py"), .of(.python), source_python_test);
    const crate = try store.insert(hash_of("a.rs"), .of(.rust), source_rust_test);

    try std.testing.expectEqual(4, store.count());
    try std.testing.expectEqual(Structure.complete, store.structure_of(.of(sheet)));
    try std.testing.expectEqual(Structure.complete, store.structure_of(.of(page)));
    try std.testing.expectEqual(Structure.complete, store.structure_of(.of(script)));
    try std.testing.expectEqual(Structure.complete, store.structure_of(.of(crate)));
    try std.testing.expectEqual(0, store.tokens_of(.of(page)).len);
    try std.testing.expect(store.markup_tokens_of(.of(page)).len > 0);
    try std.testing.expectEqual(0, store.markup_errors_of(.of(page)).len);
}

test "a language with no slots refuses every insert" {
    const gpa = std.testing.allocator;
    const limits = limits_test(&.{.{ .slots = 1, .language = .python }});
    var store: Store = undefined;

    try store.init(gpa, &limits, .least_recently_used);
    defer store.deinit(gpa);

    const refused = store.insert(hash_of("a.rs"), .of(.rust), source_rust_test);

    try std.testing.expectError(error.Full, refused);
    try std.testing.expectEqual(0, store.count());
}

test "a source past the byte limit is refused" {
    const gpa = std.testing.allocator;
    const limits = limits_test(&.{.{ .slots = 1, .language = .python }});
    var store: Store = undefined;

    try store.init(gpa, &limits, .reject);
    defer store.deinit(gpa);

    const long: [4_097]u8 = @splat('#');
    const refused = store.insert(hash_of("a.py"), .of(.python), &long);

    try std.testing.expectError(error.TooLarge, refused);
    try std.testing.expectEqual(0, store.count());
}

test "a file lands in the smallest class that holds it" {
    const gpa = std.testing.allocator;
    const limits = classed_limits_test();
    var store: Store = undefined;

    try store.init(gpa, &limits, .reject);
    defer store.deinit(gpa);

    const small = try store.insert(hash_of("a.py"), .of(.python), source_python_test);
    const long: [2_048]u8 = @splat('#');
    const large = try store.insert(hash_of("b.py"), .of(.python), &long);

    try std.testing.expectEqual(0, small);
    try std.testing.expectEqual(1, large);
    try std.testing.expectEqual(1_024, store.slot_bytes_of(small));
    try std.testing.expectEqual(4_096, store.slot_bytes_of(large));
    try std.testing.expectEqual(2, store.count());
}

test "a small file borrows a larger slot when its class is full" {
    const gpa = std.testing.allocator;
    const limits = classed_limits_test();
    var store: Store = undefined;

    try store.init(gpa, &limits, .reject);
    defer store.deinit(gpa);

    const first = try store.insert(hash_of("a.py"), .of(.python), source_python_test);
    const second = try store.insert(hash_of("b.py"), .of(.python), source_python_other_test);
    const long: [2_048]u8 = @splat('#');
    const third = store.insert(hash_of("c.py"), .of(.python), &long);

    try std.testing.expectEqual(0, first);
    try std.testing.expectEqual(1, second);
    try std.testing.expectError(error.Full, third);
    try std.testing.expectEqual(2, store.count());
}

test "a file that outgrows its slot moves to a larger one" {
    const gpa = std.testing.allocator;
    const limits = classed_limits_test();
    var store: Store = undefined;

    try store.init(gpa, &limits, .reject);
    defer store.deinit(gpa);

    const first = try store.insert(hash_of("a.py"), .of(.python), source_python_test);
    const long: [2_048]u8 = @splat('#');
    const moved = try store.insert(hash_of("a.py"), .of(.python), &long);

    try std.testing.expectEqual(0, first);
    try std.testing.expectEqual(1, moved);
    try std.testing.expectEqual(1, store.count());
    try std.testing.expectEqual(moved, store.find(hash_of("a.py")).?);
    try std.testing.expect(!store.resident(.of(first)));
    try std.testing.expectEqualStrings(&long, store.source_of(.of(moved)));
}

test "a file that shrinks keeps its slot" {
    const gpa = std.testing.allocator;
    const limits = classed_limits_test();
    var store: Store = undefined;

    try store.init(gpa, &limits, .reject);
    defer store.deinit(gpa);

    const long: [2_048]u8 = @splat('#');
    const first = try store.insert(hash_of("a.py"), .of(.python), &long);
    const again = try store.insert(hash_of("a.py"), .of(.python), source_python_test);

    try std.testing.expectEqual(1, first);
    try std.testing.expectEqual(first, again);
    try std.testing.expectEqual(1, store.count());
    try std.testing.expectEqual(2, store.rebuilds_of(.of(again)));
}

test "clear empties every slot" {
    const gpa = std.testing.allocator;
    const limits = limits_test(&.{.{ .slots = 2, .language = .python }});
    var store: Store = undefined;

    try store.init(gpa, &limits, .reject);
    defer store.deinit(gpa);

    _ = try store.insert(hash_of("a.py"), .of(.python), source_python_test);
    _ = try store.insert(hash_of("b.py"), .of(.python), source_python_other_test);

    store.clear();

    try std.testing.expectEqual(0, store.count());
    try std.testing.expectEqual(null, store.find(hash_of("a.py")));

    const again = try store.insert(hash_of("a.py"), .of(.python), source_python_test);

    try std.testing.expectEqual(1, store.rebuilds_of(.of(again)));
}

test "a vocabulary reaches every markup slot" {
    const gpa = std.testing.allocator;
    const source = "{% extends 'b.html' %}{% include 'c.html' only %}\n";
    const limits = limits_test(&.{.{ .slots = 2, .language = .markup }});
    var vocabulary: markup.Vocabulary = .empty;
    var store: Store = undefined;

    try store.init(gpa, &limits, .reject);
    defer store.deinit(gpa);

    vocabulary.extends_tags = &.{"extends"};
    vocabulary.only_word = "only";

    store.template_imports_set(&.{ "extends", "include" });

    const plain = try store.insert(hash_of("a.html"), .of(.markup), source);
    const plain_facts = store.facts_of(.of(plain));

    try std.testing.expectEqual(FactKindTest{ .include = .{ .only = false } }, plain_facts[0].kind);
    try std.testing.expectEqual(FactKindTest{ .include = .{ .only = false } }, plain_facts[1].kind);

    store.vocabulary_set(vocabulary);

    const worded = try store.insert(hash_of("b.html"), .of(.markup), source);
    const worded_facts = store.facts_of(.of(worded));

    try std.testing.expectEqual(FactKindTest.extends, worded_facts[0].kind);
    try std.testing.expectEqual(FactKindTest{ .include = .{ .only = true } }, worded_facts[1].kind);
}

const FactKindTest = @import("../syntax/fact.zig").FactKind;

test "an accessor rejects a vacant slot" {
    const gpa = std.testing.allocator;
    const limits = limits_test(&.{.{ .slots = 1, .language = .python }});
    var store: Store = undefined;

    try store.init(gpa, &limits, .reject);
    defer store.deinit(gpa);

    try std.testing.expect(!store.slot_resident(.of(0)));

    _ = try store.insert(hash_of("a.py"), .of(.python), source_python_test);

    try std.testing.expect(store.slot_resident(.of(0)));
}
