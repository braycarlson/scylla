const std = @import("std");
const assert = std.debug.assert;
const corpus = @import("corpus.zig");

pub const Argument = struct {
    items: []const Value = &.{},
    name: ?[]const u8 = null,
    range: Range = .{ 0, 0 },
    root: ?[]const u8 = null,
    value: Value = .{},
};

pub const Binding = struct {
    initializer: []const []const u8 = &.{},
    kind: []const u8 = "",
    name: []const u8 = "",
    name_range: Range = .{ 0, 0 },
    scope_range: Range = .{ 0, 0 },
};

const Case = struct {
    extraction: Extraction,
    name: []const u8,
    source: []const u8,
};

const Cases = struct {
    arena: std.heap.ArenaAllocator,
    files: corpus.Files,
    items: []const Case,

    pub fn deinit(cases: *Cases, gpa: std.mem.Allocator) void {
        assert(cases.items.len == cases.files.slice().len);

        cases.files.deinit(gpa);
        cases.arena.deinit();
        cases.* = undefined;
    }
};

pub const Extension = enum { html, py };

const Extraction = struct {
    bindings: []const Binding = &.{},
    kind: []const u8 = "",
    models: []const Model = &.{},
    objects: []const Object = &.{},
    path: []const u8 = "",
    registrations: []const Registration = &.{},
};

pub const Field = struct {
    editable: bool = false,
    kind: []const u8 = "",
    name: []const u8 = "",
    range: Range = .{ 0, 0 },
    relates_to: ?Value = null,
};

pub const Member = struct {
    has_await: bool = false,
    is_async: bool = false,
    kind: []const u8 = "",
    name: []const u8 = "",
    range: Range = .{ 0, 0 },
};

pub const Model = struct {
    app_label: ?[]const u8 = null,
    bases: []const Value = &.{},
    fields: []const Field = &.{},
    name: []const u8 = "",
    range: Range = .{ 0, 0 },
};

pub const Object = struct {
    members: []const Member = &.{},
    range: Range = .{ 0, 0 },
};

pub const Range = [2]u32;

pub const Registration = struct {
    arguments: []const Argument = &.{},
    explicit_name: bool = false,
    legacy: bool = false,
    name: Value = .{},
    name_range: Range = .{ 0, 0 },
    namespace: []const u8 = "",
    range: Range = .{ 0, 0 },
    target: Value = .{},
    target_class: ?[]const u8 = null,
    target_model: ?[]const u8 = null,
    view: ?[]const u8 = null,
};

pub const Value = struct {
    kind: []const u8 = "",
    text: []const u8 = "",
};

const ReadError = error{ Malformed, OutOfMemory, UnknownKey };

const Reader = struct {
    offset: usize,
    text: []const u8,

    fn advance(reader: *Reader, byte_count: usize) ReadError!void {
        assert(byte_count > 0);

        if (reader.offset + byte_count > reader.text.len) return error.Malformed;

        reader.offset += byte_count;
    }

    fn boolean(reader: *Reader) ReadError!bool {
        reader.skip();

        if (reader.take('t')) {
            try reader.advance(3);

            return true;
        }

        if (!reader.take('f')) return error.Malformed;

        try reader.advance(4);

        return false;
    }

    fn byte(reader: *const Reader) u8 {
        assert(reader.offset <= reader.text.len);

        if (reader.offset == reader.text.len) return 0;
        return reader.text[reader.offset];
    }

    fn expect(reader: *Reader, wanted: u8) ReadError!void {
        assert(wanted != 0);

        reader.skip();

        if (reader.byte() != wanted) {
            std.debug.print("expected `{c}` at offset {d}\n", .{ wanted, reader.offset });

            return error.Malformed;
        }

        reader.offset += 1;
    }

    fn null_taken(reader: *Reader) ReadError!bool {
        reader.skip();

        if (reader.byte() != 'n') return false;

        try reader.advance(4);

        return true;
    }

    fn number(reader: *Reader) ReadError!u32 {
        reader.skip();

        const start = reader.offset;

        while (reader.offset < reader.text.len) {
            if (!std.ascii.isDigit(reader.text[reader.offset])) break;

            reader.offset += 1;
        }

        if (reader.offset == start) return error.Malformed;

        return std.fmt.parseInt(u32, reader.text[start..reader.offset], 10) catch {
            return error.Malformed;
        };
    }

    fn skip(reader: *Reader) void {
        assert(reader.offset <= reader.text.len);

        while (reader.offset < reader.text.len) {
            if (!std.ascii.isWhitespace(reader.text[reader.offset])) break;

            reader.offset += 1;
        }
    }

    fn string(reader: *Reader, arena: std.mem.Allocator) ReadError![]const u8 {
        try reader.expect('"');

        var out: std.ArrayList(u8) = .empty;

        while (reader.offset < reader.text.len) {
            const held = reader.byte();

            reader.offset += 1;

            switch (held) {
                '"' => return out.items,
                '\\' => {
                    try out.append(arena, reader.byte());
                    try reader.advance(1);
                },
                0 => return error.Malformed,
                else => try out.append(arena, held),
            }
        }

        return error.Malformed;
    }

    fn take(reader: *Reader, wanted: u8) bool {
        assert(wanted != 0);

        reader.skip();

        if (reader.byte() != wanted) return false;

        reader.offset += 1;

        return true;
    }
};

const element_count_max: u32 = 1 << 20;
const golden_bytes_max: u32 = 1 << 24;
const golden_root = "tests/fixtures/extraction";
const path_bytes_max: u32 = 4096;
const source_bytes_max: u32 = 1 << 24;
const sources_root = "tests/fixtures/templates";

pub fn extractions(gpa: std.mem.Allocator, comptime extension: Extension) !Cases {
    const selected = switch (extension) {
        .html => html_selected,
        .py => python_selected,
    };

    var files = try corpus.collect(gpa, sources_root, source_bytes_max, selected);
    errdefer files.deinit(gpa);

    if (files.slice().len == 0) {
        std.debug.print("no .{s} fixtures to extract\n", .{@tagName(extension)});

        return error.FixturesMissing;
    }

    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();

    const allocator = arena.allocator();
    const items = try allocator.alloc(Case, files.slice().len);

    for (files.slice(), items) |file, *item| {
        item.* = .{
            .extraction = try extraction_read(allocator, file.name),
            .name = file.name,
            .source = file.source,
        };
    }

    assert(items.len == files.slice().len);

    return .{ .arena = arena, .files = files, .items = items };
}

pub fn residue_contains(names: []const []const u8, name: []const u8) bool {
    assert(name.len > 0);
    assert(names.len <= std.math.maxInt(u32));

    for (names) |held| {
        if (std.mem.eql(u8, held, name)) return true;
    }

    return false;
}

fn html_selected(basename: []const u8) bool {
    assert(basename.len > 0);

    return std.mem.eql(u8, std.Io.Dir.path.extension(basename), ".html");
}

fn python_selected(basename: []const u8) bool {
    assert(basename.len > 0);

    return std.mem.eql(u8, std.Io.Dir.path.extension(basename), ".py");
}

fn extraction_read(arena: std.mem.Allocator, name: []const u8) !Extraction {
    assert(name.len > 0);

    const extension = std.Io.Dir.path.extension(name);

    assert(extension.len > 0);

    var path_buffer: [path_bytes_max]u8 = undefined;
    const stem = name[0 .. name.len - extension.len];
    const path = try std.mem.print(&path_buffer, "{s}/{s}.json", .{ golden_root, stem });
    const limit: std.Io.Limit = .limited(golden_bytes_max);

    const text = std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, arena, limit) catch |err| {
        std.debug.print("reading {s}: {t}\n", .{ path, err });

        return err;
    };

    var reader: Reader = .{ .offset = 0, .text = text };
    return record(Extraction, &reader, arena, extraction_key);
}

fn record(
    comptime T: type,
    reader: *Reader,
    arena: std.mem.Allocator,
    comptime read_key: fn (*Reader, std.mem.Allocator, *T, []const u8) ReadError!void,
) ReadError!T {
    var found: T = .{};

    try reader.expect('{');

    for (0..element_count_max) |_| {
        const key = try reader.string(arena);

        try reader.expect(':');
        try read_key(reader, arena, &found, key);

        if (!reader.take(',')) {
            try reader.expect('}');

            return found;
        }
    }

    return error.Malformed;
}

fn list(
    comptime T: type,
    reader: *Reader,
    arena: std.mem.Allocator,
    comptime read: fn (*Reader, std.mem.Allocator) ReadError!T,
) ReadError![]const T {
    var elements: std.ArrayList(T) = .empty;

    try reader.expect('[');

    if (reader.take(']')) return elements.items;

    for (0..element_count_max) |_| {
        try elements.append(arena, try read(reader, arena));

        if (!reader.take(',')) {
            try reader.expect(']');

            return elements.items;
        }
    }

    return error.Malformed;
}

fn unknown(owner: []const u8, key: []const u8) ReadError {
    assert(owner.len > 0);
    assert(key.len <= std.math.maxInt(u32));

    std.debug.print("{s} carries an unknown key `{s}`\n", .{ owner, key });

    return error.UnknownKey;
}

fn optional(reader: *Reader, arena: std.mem.Allocator, out: *?[]const u8) ReadError!void {
    if (try reader.null_taken()) {
        out.* = null;

        return;
    }

    out.* = try reader.string(arena);
}

fn optional_value(reader: *Reader, arena: std.mem.Allocator, out: *?Value) ReadError!void {
    if (try reader.null_taken()) {
        out.* = null;

        return;
    }

    out.* = try value(reader, arena);
}

fn pair(reader: *Reader) ReadError!Range {
    try reader.expect('[');

    const start = try reader.number();

    try reader.expect(',');

    const end = try reader.number();

    try reader.expect(']');

    return .{ start, end };
}

fn read_string(reader: *Reader, arena: std.mem.Allocator) ReadError![]const u8 {
    return reader.string(arena);
}

fn argument(reader: *Reader, arena: std.mem.Allocator) ReadError!Argument {
    return record(Argument, reader, arena, argument_key);
}

fn binding(reader: *Reader, arena: std.mem.Allocator) ReadError!Binding {
    return record(Binding, reader, arena, binding_key);
}

fn field(reader: *Reader, arena: std.mem.Allocator) ReadError!Field {
    return record(Field, reader, arena, field_key);
}

fn member(reader: *Reader, arena: std.mem.Allocator) ReadError!Member {
    return record(Member, reader, arena, member_key);
}

fn model(reader: *Reader, arena: std.mem.Allocator) ReadError!Model {
    return record(Model, reader, arena, model_key);
}

fn object(reader: *Reader, arena: std.mem.Allocator) ReadError!Object {
    return record(Object, reader, arena, object_key);
}

fn registration(reader: *Reader, arena: std.mem.Allocator) ReadError!Registration {
    return record(Registration, reader, arena, registration_key);
}

fn value(reader: *Reader, arena: std.mem.Allocator) ReadError!Value {
    return record(Value, reader, arena, value_key);
}

fn extraction_key(
    reader: *Reader,
    arena: std.mem.Allocator,
    found: *Extraction,
    key: []const u8,
) ReadError!void {
    assert(key.len <= std.math.maxInt(u32));

    const Key = enum { bindings, kind, models, objects, path, registrations };
    const known = std.meta.stringToEnum(Key, key) orelse return unknown("the extraction", key);

    switch (known) {
        .bindings => found.bindings = try list(Binding, reader, arena, binding),
        .kind => found.kind = try reader.string(arena),
        .models => found.models = try list(Model, reader, arena, model),
        .objects => found.objects = try list(Object, reader, arena, object),
        .path => found.path = try reader.string(arena),
        .registrations => {
            found.registrations = try list(Registration, reader, arena, registration);
        },
    }
}

fn argument_key(
    reader: *Reader,
    arena: std.mem.Allocator,
    found: *Argument,
    key: []const u8,
) ReadError!void {
    assert(key.len <= std.math.maxInt(u32));

    const Key = enum { items, name, range, root, value };
    const known = std.meta.stringToEnum(Key, key) orelse return unknown("an argument", key);

    switch (known) {
        .items => found.items = try list(Value, reader, arena, value),
        .name => try optional(reader, arena, &found.name),
        .range => found.range = try pair(reader),
        .root => try optional(reader, arena, &found.root),
        .value => found.value = try value(reader, arena),
    }
}

fn binding_key(
    reader: *Reader,
    arena: std.mem.Allocator,
    found: *Binding,
    key: []const u8,
) ReadError!void {
    assert(key.len <= std.math.maxInt(u32));

    const Key = enum { initializer, kind, name, name_range, scope_range };
    const known = std.meta.stringToEnum(Key, key) orelse return unknown("a binding", key);

    switch (known) {
        .initializer => found.initializer = try list([]const u8, reader, arena, read_string),
        .kind => found.kind = try reader.string(arena),
        .name => found.name = try reader.string(arena),
        .name_range => found.name_range = try pair(reader),
        .scope_range => found.scope_range = try pair(reader),
    }
}

fn field_key(
    reader: *Reader,
    arena: std.mem.Allocator,
    found: *Field,
    key: []const u8,
) ReadError!void {
    assert(key.len <= std.math.maxInt(u32));

    const Key = enum { editable, kind, name, range, relates_to };
    const known = std.meta.stringToEnum(Key, key) orelse return unknown("a field", key);

    switch (known) {
        .editable => found.editable = try reader.boolean(),
        .kind => found.kind = try reader.string(arena),
        .name => found.name = try reader.string(arena),
        .range => found.range = try pair(reader),
        .relates_to => try optional_value(reader, arena, &found.relates_to),
    }
}

fn member_key(
    reader: *Reader,
    arena: std.mem.Allocator,
    found: *Member,
    key: []const u8,
) ReadError!void {
    assert(key.len <= std.math.maxInt(u32));

    const Key = enum { has_await, is_async, kind, name, range };
    const known = std.meta.stringToEnum(Key, key) orelse return unknown("a member", key);

    switch (known) {
        .has_await => found.has_await = try reader.boolean(),
        .is_async => found.is_async = try reader.boolean(),
        .kind => found.kind = try reader.string(arena),
        .name => found.name = try reader.string(arena),
        .range => found.range = try pair(reader),
    }
}

fn model_key(
    reader: *Reader,
    arena: std.mem.Allocator,
    found: *Model,
    key: []const u8,
) ReadError!void {
    assert(key.len <= std.math.maxInt(u32));

    const Key = enum { app_label, bases, fields, name, range };
    const known = std.meta.stringToEnum(Key, key) orelse return unknown("a model", key);

    switch (known) {
        .app_label => try optional(reader, arena, &found.app_label),
        .bases => found.bases = try list(Value, reader, arena, value),
        .fields => found.fields = try list(Field, reader, arena, field),
        .name => found.name = try reader.string(arena),
        .range => found.range = try pair(reader),
    }
}

fn object_key(
    reader: *Reader,
    arena: std.mem.Allocator,
    found: *Object,
    key: []const u8,
) ReadError!void {
    assert(key.len <= std.math.maxInt(u32));

    const Key = enum { members, range };
    const known = std.meta.stringToEnum(Key, key) orelse return unknown("an object", key);

    switch (known) {
        .members => found.members = try list(Member, reader, arena, member),
        .range => found.range = try pair(reader),
    }
}

fn registration_key(
    reader: *Reader,
    arena: std.mem.Allocator,
    found: *Registration,
    key: []const u8,
) ReadError!void {
    assert(key.len <= std.math.maxInt(u32));

    const Key = enum {
        arguments,
        explicit_name,
        legacy,
        name,
        name_range,
        namespace,
        range,
        target,
        target_class,
        target_model,
        view,
    };

    const known = std.meta.stringToEnum(Key, key) orelse return unknown("a registration", key);

    switch (known) {
        .arguments => found.arguments = try list(Argument, reader, arena, argument),
        .explicit_name => found.explicit_name = try reader.boolean(),
        .legacy => found.legacy = try reader.boolean(),
        .name => found.name = try value(reader, arena),
        .name_range => found.name_range = try pair(reader),
        .namespace => found.namespace = try reader.string(arena),
        .range => found.range = try pair(reader),
        .target => found.target = try value(reader, arena),
        .target_class => try optional(reader, arena, &found.target_class),
        .target_model => try optional(reader, arena, &found.target_model),
        .view => try optional(reader, arena, &found.view),
    }
}

fn value_key(
    reader: *Reader,
    arena: std.mem.Allocator,
    found: *Value,
    key: []const u8,
) ReadError!void {
    assert(key.len <= std.math.maxInt(u32));

    const Key = enum { kind, text };
    const known = std.meta.stringToEnum(Key, key) orelse return unknown("a value", key);

    switch (known) {
        .kind => found.kind = try reader.string(arena),
        .text => found.text = try reader.string(arena),
    }
}
