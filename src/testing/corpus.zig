const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const environment = @import("environment.zig");

const Variable = enum {
    css,
    golden,
    gotypes,
    markup,
    ols,
    oxlint,
    root,
    ruff,
    scip,
    tsscope,
    zls,

    pub fn name(variable: Variable) [:0]const u8 {
        const held: [:0]const u8 = switch (variable) {
            .css => "SCYLLA_CORPUS_CSS",
            .golden => "SCYLLA_CORPUS_GOLDEN",
            .gotypes => "SCYLLA_CORPUS_GOTYPES",
            .markup => "SCYLLA_CORPUS_MARKUP",
            .ols => "SCYLLA_CORPUS_OLS",
            .oxlint => "SCYLLA_CORPUS_OXLINT",
            .root => "SCYLLA_CORPUS",
            .ruff => "SCYLLA_CORPUS_RUFF",
            .scip => "SCYLLA_CORPUS_SCIP",
            .tsscope => "SCYLLA_CORPUS_TSSCOPE",
            .zls => "SCYLLA_CORPUS_ZLS",
        };

        assert(std.mem.startsWith(u8, held, variable_prefix));
        assert(!std.mem.eql(u8, held, required_variable));

        return held;
    }
};

pub const File = struct {
    name: []const u8,
    source: []const u8,

    pub fn less_than(context: void, left: File, right: File) bool {
        assert(@TypeOf(context) == void);
        assert(left.name.len > 0);
        assert(right.name.len > 0);

        return std.mem.order(u8, left.name, right.name) == .lt;
    }

    pub fn weight(file: *const File) u64 {
        assert(file.name.len > 0);
        assert(file.source.len <= std.math.maxInt(u32));

        return file.source.len;
    }
};

pub const Files = struct {
    list: std.ArrayList(File),
    owned: bool = true,

    pub fn deinit(files: *Files, gpa: std.mem.Allocator) void {
        assert(files.list.items.len <= files.list.capacity);
        assert(files.list.items.len <= entry_count_max);

        if (files.owned) {
            for (files.list.items) |file| {
                gpa.free(file.name);
                gpa.free(file.source);
            }
        }

        files.list.deinit(gpa);
        files.* = undefined;
    }

    pub fn slice(files: *const Files) []const File {
        assert(files.list.items.len <= entry_count_max);

        return files.list.items;
    }

    pub fn strided(files: *Files, gpa: std.mem.Allocator, held_stride: u32) void {
        assert(held_stride > 0);
        assert(files.list.items.len <= entry_count_max);

        const listed = files.list.items.len;
        var kept: usize = 0;

        for (files.list.items, 1..) |file, seen| {
            if (seen % held_stride == 0) {
                files.list.items[kept] = file;
                kept += 1;
            } else if (files.owned) {
                gpa.free(file.name);
                gpa.free(file.source);
            } else {}
        }

        files.list.shrinkRetainingCapacity(kept);

        assert(kept == listed / held_stride);
        if (held_stride == 1) assert(kept == listed);
    }
};

pub const Walker = struct {
    entry: std.Io.Dir.Walker.Entry,
    inner: std.Io.Dir.SelectiveWalker,
    walked: u32,

    pub fn init(gpa: std.mem.Allocator, root: std.Io.Dir) !Walker {
        if (builtin.target.os.tag != .windows) assert(root.handle >= 0);

        const walker: Walker = .{
            .entry = undefined,
            .inner = try root.walkSelectively(gpa),
            .walked = 0,
        };

        assert(walker.inner.stack.items.len == 1);
        assert(walker.walked == 0);

        return walker;
    }

    pub fn deinit(walker: *Walker) void {
        assert(walker.walked <= entry_count_max);
        assert(walker.inner.stack.items.len <= walker.walked + 1);

        walker.inner.deinit();
        walker.* = undefined;
    }

    pub fn advance(walker: *Walker, io: std.Io) !bool {
        while (try walker.inner.next(io)) |entry| {
            walker.walked += 1;

            assert(walker.walked <= entry_count_max);

            switch (try visit_of(io, entry)) {
                .descend => {
                    var directory = entry;

                    directory.kind = .directory;

                    try walker.inner.enter(io, directory);
                },
                .skip => {},
                .yield => {
                    walker.entry = entry;

                    return true;
                },
            }
        }

        return false;
    }
};

const Visit = enum {
    descend,
    skip,
    yield,
};

const Root = struct {
    directory: ?std.Io.Dir,
    entries: []Entry,
    path: []const u8,

    fn source_of(
        root: *const Root,
        io: std.Io,
        arena: std.mem.Allocator,
        entry: *Entry,
        limit: u32,
    ) ?[]const u8 {
        assert(limit > 0);
        assert(entry.basename_start < entry.path.len);

        switch (entry.state) {
            .failed => return null,
            .loaded => |source| return if (source.len < limit) source else null,
            .longer_than => |length| if (limit <= length) return null,
            .unread => {},
        }

        const directory = root.directory.?;
        const read = directory.readFileAlloc(io, entry.path, arena, .limited(limit));

        const source = read catch |err| {
            entry.state = switch (err) {
                error.StreamTooLong => .{ .longer_than = limit },
                else => .failed,
            };

            return null;
        };

        assert(source.len < limit);

        entry.state = .{ .loaded = source };

        return source;
    }
};

const Entry = struct {
    basename_start: u32,
    path: []const u8,
    state: State,

    const State = union(enum) {
        failed,
        loaded: []const u8,
        longer_than: u32,
        unread,
    };

    fn basename(entry: *const Entry) []const u8 {
        assert(entry.basename_start < entry.path.len);

        return entry.path[entry.basename_start..];
    }
};

const entry_count_max: u32 = 1 << 22;
const required_variable = "SCYLLA_CORPUS_REQUIRED";
const stride_variable = "SCYLLA_CORPUS_STRIDE";
const variable_prefix = "SCYLLA_CORPUS";

pub fn collect(
    gpa: std.mem.Allocator,
    root: []const u8,
    source_bytes_max: u32,
    comptime selected: fn (basename: []const u8) bool,
) !Files {
    const io = std.testing.io;

    assert(root.len > 0);
    assert(source_bytes_max > 0);

    var files: Files = .{ .list = .empty, .owned = true };
    errdefer files.deinit(gpa);

    var walk_arena: std.heap.ArenaAllocator = .init(gpa);
    defer walk_arena.deinit();

    const walked = try root_walked(walk_arena.allocator(), io, root);
    defer if (walked.directory) |directory| directory.close(io);

    for (walked.entries) |*entry| {
        if (!selected(entry.basename())) continue;

        const source = walked.source_of(io, gpa, entry, source_bytes_max) orelse continue;
        errdefer gpa.free(source);

        const name = try gpa.dupe(u8, entry.path);
        errdefer gpa.free(name);

        try files.list.append(gpa, .{ .name = name, .source = source });
    }

    std.mem.sort(File, files.list.items, {}, File.less_than);

    assert(files.list.items.len <= walked.entries.len);

    return files;
}

fn root_walked(arena: std.mem.Allocator, io: std.Io, path: []const u8) !Root {
    assert(path.len > 0);

    var root: Root = .{ .directory = null, .entries = &.{}, .path = path };
    const opened = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true });

    if (opened) |directory| {
        root.directory = directory;
        root.entries = try entries_walked(arena, io, directory);
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }

    return root;
}

fn entries_walked(arena: std.mem.Allocator, io: std.Io, directory: std.Io.Dir) ![]Entry {
    if (builtin.target.os.tag != .windows) assert(directory.handle >= 0);

    var entries: std.ArrayList(Entry) = .empty;
    var walker = try Walker.init(arena, directory);
    defer walker.deinit();

    while (try walker.advance(io)) {
        const entry = walker.entry;
        const path = try arena.dupe(u8, entry.path);

        if (builtin.target.os.tag == .windows) std.mem.replaceScalar(u8, path, '\\', '/');

        assert(path.len >= entry.basename.len);

        try entries.append(arena, .{
            .basename_start = @intCast(path.len - entry.basename.len),
            .path = path,
            .state = .unread,
        });
    }

    assert(entries.items.len <= walker.walked);

    return entries.items;
}

pub fn named(variable: Variable) ?[]const u8 {
    const io = std.testing.io;
    const key = variable.name();

    assert(key.len >= variable_prefix.len);
    assert(!std.mem.eql(u8, key, stride_variable));

    const value = environment.lasting(key) orelse {
        if (required()) {
            std.debug.panic(
                "{s} is set and {s} is not: a green run would read no corpus",
                .{ required_variable, key },
            );
        }

        return null;
    };

    var directory = std.Io.Dir.cwd().openDir(io, value, .{}) catch |err| {
        std.debug.panic(
            "{s} names `{s}`, which is not a directory: {s}",
            .{ key, value, @errorName(err) },
        );
    };

    directory.close(io);

    return value;
}

fn required() bool {
    comptime assert(std.mem.startsWith(u8, required_variable, variable_prefix));
    comptime assert(required_variable.len > variable_prefix.len);

    return std.testing.environ.containsConstant(required_variable);
}

pub fn stride() u32 {
    var value_bytes: [environment.value_bytes_max]u8 = undefined;
    const value = environment.get(stride_variable, &value_bytes) orelse return 1;

    const parsed = std.fmt.parseUnsigned(u32, value, 10) catch |err| switch (err) {
        error.InvalidCharacter, error.Overflow => return 1,
    };

    const held: u32 = if (parsed > 0) parsed else 1;

    assert(held > 0);
    if (parsed > 0) assert(held == parsed);

    return held;
}

fn visit_of(io: std.Io, entry: std.Io.Dir.Walker.Entry) !Visit {
    assert(entry.basename.len > 0);
    assert(entry.path.len >= entry.basename.len);

    switch (entry.kind) {
        .directory => return .descend,
        .file => return .yield,
        .sym_link => {},
        else => return .skip,
    }

    const stat = entry.dir.statFile(io, entry.basename, .{}) catch |err| switch (err) {
        error.FileNotFound, error.SymLinkLoop => return .skip,
        else => return err,
    };

    return switch (stat.kind) {
        .directory => .descend,
        .file => .yield,
        else => .skip,
    };
}

test "every corpus variable names a scylla corpus root" {
    for (std.enums.values(Variable)) |variable| {
        const key = variable.name();

        try std.testing.expect(std.mem.startsWith(u8, key, variable_prefix));
        try std.testing.expect(!std.mem.eql(u8, key, stride_variable));
    }

    try std.testing.expectEqualStrings("SCYLLA_CORPUS", Variable.root.name());
    try std.testing.expect(stride() > 0);
}
