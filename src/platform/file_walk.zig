const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const bounded = @import("../stdx/bounded.zig");
const glob = @import("glob.zig");
const path = @import("path.zig");
const path_platform = @import("path/platform.zig");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;
const expectError = std.testing.expectError;
pub const Excludes = @import("file_walk/excludes.zig");
pub const Ignores = @import("file_walk/ignores.zig");
const Span = bounded.Span;
const FileWalk = @This();

arena: bounded.Buffer,
depth_max: u32,
entries: bounded.ArrayType(Entry),
scratch: bounded.Buffer,
stack: bounded.ArrayType(Pending),

pub const Capacity = struct {
    arena_bytes_max: u32,
    depth_max: u32,
    entry_count_max: u32,
    pending_max: u32,
};

pub const CapacityError = error{
    ArenaExhausted,
    DepthExceeded,
    EntriesExhausted,
    IgnoresExhausted,
    ListingExhausted,
    PathTooLong,
    PendingExhausted,
};

pub const Error = CapacityError || OpenError;
pub const InputError = error{PathEmpty};
pub const OpenError = error{Unopenable};

pub const Options = struct {
    depth_capped: bool = false,
    directories: bool = false,
    excludes: ?*glob.Filter,
    ignores: ?*Ignores,
    preorder: bool = false,
    skipped: []const []const u8,
};

pub const Paths = struct {
    index: u32,
    remaining: u32,
    walk: *const FileWalk,

    pub fn next(iterator: *Paths) ?[]const u8 {
        assert(iterator.remaining <= iterator.walk.count());
        assert(iterator.index + iterator.remaining <= iterator.walk.count());

        if (iterator.remaining == 0) return null;

        const held = iterator.walk.path_of(iterator.index);

        iterator.index += 1;
        iterator.remaining -= 1;

        return held;
    }
};

const Entry = struct {
    path: Span,
};

const Pending = struct {
    depth: u32,
    path: Span,
    read: bool,
    recorded: bool,
};

const dots = [_][]const u8{ ".", ".." };
const listing_count_max: u32 = 1 << 24;

pub const skipped_default = [_][]const u8{
    ".bzr",
    ".direnv",
    ".eggs",
    ".git",
    ".git-rewrite",
    ".hg",
    ".mypy_cache",
    ".nox",
    ".pants.d",
    ".pytype",
    ".ruff_cache",
    ".snapshots",
    ".svn",
    ".tox",
    ".venv",
    "__pycache__",
    "__pypackages__",
    "__snapshots__",
    "build",
    "dist",
    "node_modules",
    "site-packages",
    "snapshots",
    "target",
    "testdata",
    "vendor",
    "venv",
    "zig-cache",
    "zig-out",
};

pub fn init(gpa: std.mem.Allocator, capacity: Capacity) std.mem.Allocator.Error!FileWalk {
    assert(capacity.arena_bytes_max > 0);
    assert(capacity.depth_max > 0);
    assert(capacity.entry_count_max > 0);
    assert(capacity.pending_max > 0);

    var arena = try bounded.Buffer.init(gpa, capacity.arena_bytes_max);
    errdefer arena.deinit(gpa);

    var entries = try bounded.ArrayType(Entry).init(gpa, capacity.entry_count_max);
    errdefer entries.deinit(gpa);

    var scratch = try bounded.Buffer.init(gpa, path_platform.path_bytes_max + 1);
    errdefer scratch.deinit(gpa);

    const stack = try bounded.ArrayType(Pending).init(gpa, capacity.pending_max);

    return .{
        .arena = arena,
        .depth_max = capacity.depth_max,
        .entries = entries,
        .scratch = scratch,
        .stack = stack,
    };
}

pub fn deinit(walk: *FileWalk, gpa: std.mem.Allocator) void {
    walk.stack.deinit(gpa);
    walk.scratch.deinit(gpa);
    walk.entries.deinit(gpa);
    walk.arena.deinit(gpa);
    walk.* = undefined;
}

pub fn run(walk: *FileWalk, io: std.Io, root: []const u8, options: *const Options) Error!void {
    assert(root.len <= std.math.maxInt(u32));

    walk.clear();

    const trimmed = path.trimmed(root);
    if (trimmed.len == 0) return error.Unopenable;

    const span = copied(&walk.arena, trimmed) orelse return error.ArenaExhausted;

    walk.stack.push(.{ .depth = 0, .path = span, .read = true, .recorded = false });

    if (options.ignores) |ignores| {
        ignores.clear();
        ignores.read_parents(io, trimmed) catch |err| return ignores_exhausted(err);
    }

    var opened = false;
    var directory_count: u32 = 0;

    while (walk.stack.pop()) |directory| {
        directory_count += 1;

        assert(directory_count <= walk.arena.capacity());

        try walk.visit(io, directory, options, &opened);
    }

    if (!opened) return error.Unopenable;
}

fn clear(walk: *FileWalk) void {
    walk.arena.clear();
    walk.entries.clear();
    walk.scratch.clear();
    walk.stack.clear();
    assert(walk.empty());
    assert(walk.stack.empty());
}

pub fn count(walk: *const FileWalk) u32 {
    const entry_count = walk.entries.count();

    assert(entry_count <= walk.entries.capacity());

    return entry_count;
}

fn empty(walk: *const FileWalk) bool {
    return walk.count() == 0;
}

pub fn path_of(walk: *const FileWalk, index: u32) []const u8 {
    assert(index < walk.entries.count());

    const entry = walk.entries.get(index);

    assert(entry.path.end() <= walk.arena.count());
    assert(entry.path.length > 0);

    return entry.path.text(walk.arena.const_slice());
}

pub fn paths(walk: *const FileWalk) Paths {
    assert(walk.entries.count() <= walk.entries.capacity());

    return .{ .index = 0, .remaining = walk.count(), .walk = walk };
}

pub fn record(walk: *FileWalk, held: []const u8) (CapacityError || InputError)!void {
    if (held.len == 0) return error.PathEmpty;
    if (held.len > path_platform.path_bytes_max) return error.PathTooLong;
    if (walk.entries.full()) return error.EntriesExhausted;

    const span = copied(&walk.arena, held) orelse return error.ArenaExhausted;

    walk.entries.push(.{ .path = span });
    assert(span.length == held.len);
}

pub fn sort(walk: *FileWalk) void {
    const arena = walk.arena.const_slice();

    std.sort.pdq(Entry, walk.entries.slice(), arena, entry_less);
    assert(walk.sorted());
}

pub fn dedup(walk: *FileWalk) void {
    const arena = walk.arena.const_slice();
    const entries = walk.entries.slice();
    if (entries.len == 0) return;

    var kept: u32 = 1;

    for (entries[1..]) |entry| {
        const previous = entries[kept - 1];
        if (std.mem.eql(u8, previous.path.text(arena), entry.path.text(arena))) continue;

        entries[kept] = entry;
        kept += 1;
    }

    walk.entries.truncate(kept);
    assert(walk.sorted());
}

fn sorted(walk: *const FileWalk) bool {
    const arena = walk.arena.const_slice();
    return std.sort.isSorted(Entry, walk.entries.const_slice(), arena, entry_less);
}

fn entry_less(arena: []const u8, left: Entry, right: Entry) bool {
    assert(arena.len <= std.math.maxInt(u32));
    assert(left.path.length <= std.math.maxInt(u32) - left.path.offset);
    assert(right.path.length <= std.math.maxInt(u32) - right.path.offset);

    return path.order(left.path.text(arena), right.path.text(arena)) == .lt;
}

fn ignores_exhausted(err: Ignores.CapacityError) CapacityError {
    return switch (err) {
        error.ArenaExhausted,
        error.FilesExhausted,
        error.LinesExhausted,
        error.PathTooLong,
        error.TextExhausted,
        => error.IgnoresExhausted,
    };
}

fn visit(
    walk: *FileWalk,
    io: std.Io,
    directory: Pending,
    options: *const Options,
    opened: *bool,
) Error!void {
    assert(directory.read or directory.recorded);
    if (directory.recorded) assert(options.preorder);

    if (directory.recorded) try walk.span_record(directory.path);

    if (!directory.read) return;

    const pushed_before = walk.stack.count();
    const outcome = walk.read(io, directory, options, opened);

    if (options.preorder) std.mem.reverse(Pending, walk.stack.slice()[pushed_before..]);

    return outcome;
}

fn read(
    walk: *FileWalk,
    io: std.Io,
    directory: Pending,
    options: *const Options,
    opened: *bool,
) Error!void {
    assert(directory.read);
    assert(directory.depth <= walk.depth_max);
    assert(directory.path.length > 0);

    if (options.ignores) |ignores| {
        const held = directory.path.text(walk.arena.const_slice());

        ignores.read(io, held) catch |err| return ignores_exhausted(err);
    }

    walk.scratch.clear();

    walk.scratch.push(directory.path.text(walk.arena.const_slice())) catch |err| switch (err) {
        error.Overflow => return error.PathTooLong,
    };

    var handle = std.Io.Dir.cwd().openDir(io, walk.scratch.const_slice(), .{
        .iterate = true,
    }) catch return;

    defer handle.close(io);

    opened.* = true;

    var iterator = handle.iterate();

    for (0..listing_count_max) |_| {
        const listing = iterator.next(io) catch return;
        const held = listing orelse return;

        try walk.read_listing(io, directory, options, held);
    }

    return error.ListingExhausted;
}

fn read_listing(
    walk: *FileWalk,
    io: std.Io,
    directory: Pending,
    options: *const Options,
    listing: std.Io.Dir.Entry,
) Error!void {
    assert(listing.name.len > 0);
    assert(directory.path.length <= std.math.maxInt(u32) - directory.path.offset);

    if (name_skipped(listing.name, options.skipped)) return;
    if (listing.kind == .sym_link) return;

    joined(&walk.scratch, walk.arena.const_slice(), directory.path, listing.name) catch |err| {
        return switch (err) {
            error.Overflow => error.PathTooLong,
        };
    };

    if (options.excludes) |excludes| {
        if (excludes.excluded(walk.scratch.const_slice())) return;
    }

    const descend = switch (listing.kind) {
        .directory => true,
        .file => false,
        else => probe(io, walk.scratch.const_slice()),
    };

    if (options.ignores) |ignores| {
        const kind: Ignores.Kind = if (descend) .directory else .file;
        if (ignores.covers(walk.scratch.const_slice(), kind)) return;
    }

    return walk.admitted(directory.depth, descend, options);
}

fn admitted(walk: *FileWalk, depth: u32, descend: bool, options: *const Options) Error!void {
    assert(depth <= walk.depth_max);
    assert(walk.scratch.count() > 0);

    const deeper = depth + 1;

    if (descend) {
        if (deeper > walk.depth_max) {
            if (!options.depth_capped) return error.DepthExceeded;
        }
    }

    const span = copied(&walk.arena, walk.scratch.const_slice()) orelse {
        return error.ArenaExhausted;
    };

    if (!descend) return walk.span_record(span);

    const pending: Pending = .{
        .depth = deeper,
        .path = span,
        .read = !options.depth_capped or deeper < walk.depth_max,
        .recorded = options.directories and options.preorder,
    };

    if (options.directories) {
        if (!options.preorder) try walk.span_record(span);
    }

    if (!pending.read) {
        if (!pending.recorded) return;
    }

    if (walk.stack.full()) return error.PendingExhausted;

    walk.stack.push(pending);
}

fn span_record(walk: *FileWalk, span: Span) CapacityError!void {
    assert(span.length > 0);
    assert(span.end() <= walk.arena.count());

    if (walk.entries.full()) return error.EntriesExhausted;

    walk.entries.push(.{ .path = span });
}

fn name_skipped(name: []const u8, skipped: []const []const u8) bool {
    assert(name.len > 0);
    assert(skipped.len <= std.math.maxInt(u32));

    for (dots) |dot| {
        if (std.mem.eql(u8, name, dot)) return true;
    }

    for (skipped) |held| {
        if (std.mem.eql(u8, name, held)) return true;
    }

    return false;
}

fn copied(arena: *bounded.Buffer, bytes: []const u8) ?Span {
    assert(bytes.len <= std.math.maxInt(u32));

    const offset = arena.count();

    arena.push(bytes) catch return null;
    assert(arena.count() - offset == bytes.len);

    return .{ .offset = offset, .length = @intCast(bytes.len) };
}

fn joined(
    scratch: *bounded.Buffer,
    arena: []const u8,
    parent: Span,
    name: []const u8,
) error{Overflow}!void {
    assert(name.len > 0);
    assert(arena.len <= std.math.maxInt(u32));
    assert(parent.length <= std.math.maxInt(u32) - parent.offset);

    scratch.clear();

    try scratch.push(parent.text(arena));
    try scratch.push_byte(path.separator);
    try scratch.push(name);
    assert(scratch.count() == parent.length + 1 + name.len);
}

fn probe(io: std.Io, held: []const u8) bool {
    assert(held.len > 0);

    var handle = std.Io.Dir.cwd().openDir(io, held, .{}) catch return false;

    handle.close(io);

    return true;
}

const capacity_test: Capacity = .{
    .arena_bytes_max = 1 << 16,
    .depth_max = 64,
    .entry_count_max = 256,
    .pending_max = 64,
};

const files_test = [_][]const u8{
    "a.html",
    "b.py",
    "templates/page.html",
    "templates/admin/list.html",
    "static/app.js",
    "static/vendor/lib.js",
    ".git/config",
    ".hidden/keep.html",
};

const skipped_test = [_][]const u8{".git"};
const options_plain: Options = .{ .excludes = null, .ignores = null, .skipped = &skipped_test };

const Root = struct {
    bytes: [path_platform.path_bytes_max]u8,
    length: u32,

    fn slice(root: *const Root) []const u8 {
        return root.bytes[0..root.length];
    }
};

fn root_of(tmp: *const std.testing.TmpDir) !Root {
    var root: Root = .{ .bytes = undefined, .length = 0 };
    const written = try std.mem.print(&root.bytes, ".zig-cache/tmp/{s}", .{&tmp.sub_path});

    root.length = @intCast(written.len);

    return root;
}

fn tree_test(tmp: *std.testing.TmpDir) !Root {
    for (files_test) |file| {
        try write_test(tmp, file);
    }

    return root_of(tmp);
}

fn write_test(tmp: *std.testing.TmpDir, relative: []const u8) !void {
    assert(relative.len <= std.math.maxInt(u32));

    const io = std.testing.io;

    if (std.Io.Dir.path.dirname(relative)) |parent| try tmp.dir.createDirPath(io, parent);

    try tmp.dir.writeFile(io, .{ .sub_path = relative, .data = "" });
}

const Walked = struct {
    paths: std.ArrayList([]const u8),

    fn deinit(walked: *Walked, gpa: std.mem.Allocator) void {
        for (walked.paths.items) |held| {
            gpa.free(held);
        }

        walked.paths.deinit(gpa);
    }

    fn contains(walked: *const Walked, needle: []const u8) bool {
        assert(needle.len <= std.math.maxInt(u32));

        for (walked.paths.items) |held| {
            if (std.mem.find(u8, held, needle) != null) return true;
        }

        return false;
    }

    fn starts_with(walked: *const Walked, prefix: []const u8) bool {
        assert(prefix.len <= std.math.maxInt(u32));

        for (walked.paths.items) |held| {
            if (std.mem.startsWith(u8, held, prefix)) return true;
        }

        return false;
    }

    fn equals(walked: *const Walked, expected: []const u8) bool {
        assert(expected.len <= std.math.maxInt(u32));

        for (walked.paths.items) |held| {
            if (std.mem.eql(u8, held, expected)) return true;
        }

        return false;
    }
};

fn walked_test(root: []const u8, excludes: ?*glob.Filter) !Walked {
    assert(root.len <= std.math.maxInt(u32));
    if (excludes) |filter| assert(!filter.excludes.empty());

    const gpa = std.testing.allocator;
    var walk = try FileWalk.init(gpa, capacity_test);
    defer walk.deinit(gpa);

    const options: Options = .{ .excludes = excludes, .ignores = null, .skipped = &skipped_test };

    try walk.run(std.testing.io, root, &options);

    walk.sort();

    var result: Walked = .{ .paths = .empty };
    errdefer result.deinit(gpa);

    var held_paths = walk.paths();

    for (0..walk.count() + 1) |_| {
        const held = held_paths.next() orelse break;

        assert(held_paths.index <= walk.count());

        const relative = if (held.len > root.len) held[root.len + 1 ..] else held;

        try result.paths.append(gpa, try gpa.dupe(u8, relative));
    } else unreachable;

    return result;
}

fn excludes_test(gpa: std.mem.Allocator) !glob.Filter {
    return glob.Filter.init(gpa, .{
        .byte_count_max = 256,
        .class_count_max = 8,
        .pattern_count_max = 8,
    }, .inferred);
}

test FileWalk {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try write_test(&tmp, "src/main.rs");
    try write_test(&tmp, "node_modules/left.js");

    const root = try root_of(&tmp);

    const capacity: Capacity = .{
        .arena_bytes_max = 1 << 12,
        .depth_max = 8,
        .entry_count_max = 16,
        .pending_max = 16,
    };

    var walk: FileWalk = try .init(gpa, capacity);
    defer walk.deinit(gpa);

    const options: Options = .{
        .excludes = null,
        .ignores = null,
        .skipped = &FileWalk.skipped_default,
    };

    try walk.run(io, root.slice(), &options);
    try expectEqual(1, walk.count());
    try expect(std.mem.endsWith(u8, walk.path_of(0), "main.rs"));
    try expectError(error.Unopenable, walk.run(io, "/no/such/directory", &options));
}

test "every file under the root is found" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tree_test(&tmp);
    var walked = try walked_test(root.slice(), null);
    defer walked.deinit(std.testing.allocator);

    const expected = [_][]const u8{
        ".hidden/keep.html",
        "a.html",
        "b.py",
        "static/app.js",
        "static/vendor/lib.js",
        "templates/admin/list.html",
        "templates/page.html",
    };

    try expectEqual(expected.len, walked.paths.items.len);

    for (expected, walked.paths.items) |want, held| {
        try expectEqualStrings(want, held);
    }
}

test "a skipped directory is never walked" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tree_test(&tmp);
    var walked = try walked_test(root.slice(), null);
    defer walked.deinit(gpa);

    try expect(!walked.contains(".git"));

    var walk = try FileWalk.init(gpa, capacity_test);
    defer walk.deinit(gpa);

    const options: Options = .{
        .excludes = null,
        .ignores = null,
        .skipped = &.{ ".git", "static" },
    };

    try walk.run(std.testing.io, root.slice(), &options);

    var app = false;
    var page = false;
    var held_paths = walk.paths();

    for (0..walk.count() + 1) |_| {
        const held = held_paths.next() orelse break;

        assert(held_paths.index <= walk.count());

        if (std.mem.endsWith(u8, held, "app.js")) app = true;
        if (std.mem.endsWith(u8, held, "a.html")) page = true;
    } else unreachable;

    try expect(!app);
    try expect(page);
}

test "a symbolic link is never followed" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tree_test(&tmp);

    tmp.dir.symLink(io, "static", "linked", .{ .is_directory = true }) catch |err| switch (err) {
        error.PermissionDenied => {
            if (builtin.target.os.tag != .windows) return err;
            return error.SkipZigTest;
        },
        else => return err,
    };

    try tmp.dir.symLink(io, "a.html", "linked.html", .{});

    var walked = try walked_test(root.slice(), null);
    defer walked.deinit(std.testing.allocator);

    try expect(!walked.starts_with("linked"));
    try expect(walked.equals("static/app.js"));
}

test "a walk asked for directories reports each one it descends into" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tree_test(&tmp);

    try tmp.dir.createDirPath(std.testing.io, "empty/nested");

    var walk = try FileWalk.init(gpa, capacity_test);
    defer walk.deinit(gpa);

    const options: Options = .{
        .directories = true,
        .excludes = null,
        .ignores = null,
        .skipped = &skipped_test,
    };

    try walk.run(std.testing.io, root.slice(), &options);

    walk.sort();

    const expected = [_][]const u8{
        ".hidden",
        ".hidden/keep.html",
        "a.html",
        "b.py",
        "empty",
        "empty/nested",
        "static",
        "static/app.js",
        "static/vendor",
        "static/vendor/lib.js",
        "templates",
        "templates/admin",
        "templates/admin/list.html",
        "templates/page.html",
    };

    try expectEqual(expected.len, walk.count());

    var held_paths = walk.paths();

    for (expected) |want| {
        const held = held_paths.next() orelse return error.TestUnexpectedResult;

        try expectEqualStrings(want, held[root.length + 1 ..]);
    }

    const held_paths_next = held_paths.next();

    try expect(held_paths_next == null);
    try expectEqual(0, held_paths.remaining);
}

test "a preorder walk lists each directory before its contents and siblings in listing order" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const created = [_][]const u8{ "b/y/q", "a/z", "c", "b/x", "a/w/v", "d" };

    for (created) |relative| {
        try tmp.dir.createDirPath(io, relative);
    }

    const root = try root_of(&tmp);
    var walk = try FileWalk.init(gpa, capacity_test);
    defer walk.deinit(gpa);

    const options: Options = .{
        .directories = true,
        .excludes = null,
        .ignores = null,
        .preorder = true,
        .skipped = &skipped_test,
    };

    try walk.run(io, root.slice(), &options);
    try expectEqual(10, walk.count());

    for (0..walk.count()) |index| {
        try preorder_check(&walk, root.slice(), @intCast(index));
    }

    try siblings_check(&walk, root.slice(), root.slice());

    for (0..walk.count()) |index| {
        try siblings_check(&walk, root.slice(), walk.path_of(@intCast(index)));
    }
}

fn preorder_check(walk: *const FileWalk, root: []const u8, index: u32) !void {
    assert(root.len <= std.math.maxInt(u32));
    assert(index < std.math.maxInt(u32));

    const held = walk.path_of(index);
    const parent = std.Io.Dir.path.dirname(held).?;

    if (!std.mem.eql(u8, parent, root)) {
        var parent_index: ?u32 = null;

        for (0..index) |before| {
            if (std.mem.eql(u8, walk.path_of(@intCast(before)), parent)) {
                parent_index = @intCast(before);
            }
        }

        try expect(parent_index != null);
    }

    var inside = true;

    for (index + 1..walk.count()) |after| {
        const below = descends_test(walk.path_of(@intCast(after)), held);

        if (below) try expect(inside);

        inside = below;
    }
}

fn descends_test(held: []const u8, ancestor: []const u8) bool {
    assert(held.len <= std.math.maxInt(u32));
    assert(ancestor.len <= std.math.maxInt(u32));

    if (held.len <= ancestor.len + 1) return false;
    if (!std.mem.startsWith(u8, held, ancestor)) return false;

    return held[ancestor.len] == path.separator;
}

fn siblings_check(walk: *const FileWalk, root: []const u8, parent: []const u8) !void {
    const io = std.testing.io;

    assert(std.mem.startsWith(u8, parent, root));

    var handle = try std.Io.Dir.cwd().openDir(io, parent, .{ .iterate = true });
    defer handle.close(io);

    var iterator = handle.iterate();
    var index: u32 = 0;

    for (0..listing_count_max) |_| {
        const listing = try iterator.next(io) orelse return;

        for (index..walk.count()) |position| {
            index = @intCast(position + 1);

            const held = walk.path_of(@intCast(position));
            if (!std.mem.eql(u8, std.Io.Dir.path.dirname(held).?, parent)) continue;

            try expectEqualStrings(listing.name, path.file_name(held));

            break;
        } else return error.TestUnexpectedResult;
    }

    return error.TestUnexpectedResult;
}

test "a directory is never reported as a file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tree_test(&tmp);
    var walked = try walked_test(root.slice(), null);
    defer walked.deinit(std.testing.allocator);

    try expect(!walked.equals("templates"));
    try expect(!walked.equals("static/vendor"));
}

test "a trailing separator on the root changes nothing" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tree_test(&tmp);
    var slashed_buffer: [path_platform.path_bytes_max]u8 = undefined;
    const slashed = try std.mem.print(&slashed_buffer, "{s}///", .{root.slice()});
    var plain = try FileWalk.init(gpa, capacity_test);
    defer plain.deinit(gpa);

    var trailed = try FileWalk.init(gpa, capacity_test);
    defer trailed.deinit(gpa);

    try plain.run(io, root.slice(), &options_plain);
    try trailed.run(io, slashed, &options_plain);
    try expectEqual(plain.count(), trailed.count());
}

test "an excluded directory is not descended into" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tree_test(&tmp);
    var excludes = try excludes_test(gpa);
    defer excludes.deinit(gpa);

    var pattern_buffer: [path_platform.path_bytes_max]u8 = undefined;
    const pattern = try std.mem.print(&pattern_buffer, "{s}/static", .{root.slice()});

    try excludes.exclude(pattern);

    var walked = try walked_test(root.slice(), &excludes);
    defer walked.deinit(gpa);

    try expect(!walked.starts_with("static"));
    try expect(walked.equals("templates/page.html"));
}

test "an excluded file is left out while its neighbours stay" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tree_test(&tmp);
    var excludes = try excludes_test(gpa);
    defer excludes.deinit(gpa);

    try excludes.exclude("*.py");

    var walked = try walked_test(root.slice(), &excludes);
    defer walked.deinit(gpa);

    try expect(!walked.contains(".py"));
    try expect(walked.equals("a.html"));
}

test "an exclude pattern reads a dotted root the way an include does" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    _ = try tree_test(&tmp);

    const sub_path = &tmp.sub_path;
    var dotted_buffer: [path_platform.path_bytes_max]u8 = undefined;
    const dotted = try std.mem.print(&dotted_buffer, "./.zig-cache/tmp/{s}", .{sub_path});
    var pattern_buffer: [path_platform.path_bytes_max]u8 = undefined;
    const pattern = try std.mem.print(&pattern_buffer, ".zig-cache/tmp/{s}/static", .{sub_path});
    var excludes = try excludes_test(gpa);
    defer excludes.deinit(gpa);

    try excludes.exclude(pattern);

    var walk = try FileWalk.init(gpa, capacity_test);
    defer walk.deinit(gpa);

    const options: Options = .{ .excludes = &excludes, .ignores = null, .skipped = &skipped_test };

    try walk.run(std.testing.io, dotted, &options);

    for (0..walk.count()) |index| {
        try expect(std.mem.find(u8, walk.path_of(@intCast(index)), "/static/") == null);
    }

    try expect(walk.count() > 0);
}

test "a root that names nothing says so" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var walk = try FileWalk.init(gpa, capacity_test);
    defer walk.deinit(gpa);

    try expectError(error.Unopenable, walk.run(io, "/no/such/directory/anywhere", &options_plain));
    try expectError(error.Unopenable, walk.run(io, "", &options_plain));
    try expect(walk.empty());
}

test "an empty directory walks to nothing" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try root_of(&tmp);
    var walked = try walked_test(root.slice(), null);
    defer walked.deinit(std.testing.allocator);

    try expectEqual(0, walked.paths.items.len);
}

test "a tree deeper than the stack is refused" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var name_buffer: [256]u8 = undefined;
    var name = std.Io.Writer.fixed(&name_buffer);

    for (0..12) |index| {
        try name.print("d{d}/", .{index});
    }

    try name.writeAll("leaf.html");
    try write_test(&tmp, name.buffered());

    const root = try root_of(&tmp);
    var capacity = capacity_test;

    capacity.depth_max = 2;

    var walk = try FileWalk.init(gpa, capacity);
    defer walk.deinit(gpa);

    try expectError(error.DepthExceeded, walk.run(std.testing.io, root.slice(), &options_plain));
}

test "a capped walk reports what lies within its depth and reads no deeper" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try write_test(&tmp, "d0/d1/d2/deep.html");
    try write_test(&tmp, "d0/shallow.html");

    const root = try root_of(&tmp);
    var capacity = capacity_test;

    capacity.depth_max = 2;

    var walk = try FileWalk.init(gpa, capacity);
    defer walk.deinit(gpa);

    const options: Options = .{
        .depth_capped = true,
        .directories = true,
        .excludes = null,
        .ignores = null,
        .skipped = &skipped_test,
    };

    try walk.run(std.testing.io, root.slice(), &options);

    walk.sort();

    const expected = [_][]const u8{ "d0", "d0/d1", "d0/shallow.html" };

    try expectEqual(expected.len, walk.count());

    for (expected, 0..) |want, index| {
        const held = walk.path_of(@intCast(index));

        try expectEqualStrings(want, held[root.length + 1 ..]);
    }

    try expectError(error.DepthExceeded, walk.run(std.testing.io, root.slice(), &options_plain));
}

test "a walk larger than the entry table is truncated" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    for (0..32) |index| {
        var name_buffer: [32]u8 = undefined;
        const name = try std.mem.print(&name_buffer, "file{d}.html", .{index});

        try write_test(&tmp, name);
    }

    const root = try root_of(&tmp);
    var capacity = capacity_test;

    capacity.entry_count_max = 4;

    var walk = try FileWalk.init(gpa, capacity);
    defer walk.deinit(gpa);

    try expectError(error.EntriesExhausted, walk.run(std.testing.io, root.slice(), &options_plain));
}

test "a walk that outgrows its arena is truncated" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tree_test(&tmp);
    var capacity = capacity_test;

    capacity.arena_bytes_max = 64;

    var walk = try FileWalk.init(gpa, capacity);
    defer walk.deinit(gpa);

    try expectError(error.ArenaExhausted, walk.run(std.testing.io, root.slice(), &options_plain));
}

test "a walk with more pending directories than its stack holds is refused" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tree_test(&tmp);
    var capacity = capacity_test;

    capacity.pending_max = 1;

    var walk = try FileWalk.init(gpa, capacity);
    defer walk.deinit(gpa);

    const outcome = walk.run(std.testing.io, root.slice(), &options_plain);

    try expectError(error.PendingExhausted, outcome);
}

test "a second run forgets the first" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tree_test(&tmp);
    var walk = try FileWalk.init(gpa, capacity_test);
    defer walk.deinit(gpa);

    try walk.run(io, root.slice(), &options_plain);

    const walked_count = walk.count();

    try walk.run(io, root.slice(), &options_plain);
    try expectEqual(walked_count, walk.count());
}

test "a sorted walk reads the same every time" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tree_test(&tmp);
    var walked_once = try walked_test(root.slice(), null);
    defer walked_once.deinit(gpa);

    var walked_twice = try walked_test(root.slice(), null);
    defer walked_twice.deinit(gpa);

    try expectEqual(walked_once.paths.items.len, walked_twice.paths.items.len);

    for (walked_once.paths.items, walked_twice.paths.items) |left, right| {
        try expectEqualStrings(left, right);
    }
}

test "a walk allocates nothing once its tables are reserved" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tree_test(&tmp);
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const gpa = failing.allocator();
    var walk = try FileWalk.init(gpa, capacity_test);
    defer walk.deinit(gpa);

    try walk.run(io, root.slice(), &options_plain);

    const expected = walk.count();
    const allocations = failing.allocations;

    try walk.run(io, root.slice(), &options_plain);

    walk.sort();

    try expectEqual(expected, walk.count());
    try expectEqual(allocations, failing.allocations);
}

test "a recorded path is walked and a sorted dedup drops the repeats" {
    const gpa = std.testing.allocator;
    var walk = try FileWalk.init(gpa, capacity_test);
    defer walk.deinit(gpa);

    const long: [path_platform.path_bytes_max + 1]u8 = @splat('a');

    try walk.record("/tmp/b.rs");
    try walk.record("/tmp/a.rs");
    try walk.record("/tmp/b.rs");
    try expectError(error.PathEmpty, walk.record(""));
    try expectError(error.PathTooLong, walk.record(&long));
    try expectEqual(3, walk.count());

    walk.sort();
    walk.dedup();

    try expectEqual(2, walk.count());
    try expectEqualStrings("/tmp/a.rs", walk.path_of(0));
    try expectEqualStrings("/tmp/b.rs", walk.path_of(1));

    walk.dedup();

    try expectEqual(2, walk.count());
}

test "a full walk refuses another record" {
    const gpa = std.testing.allocator;
    var capacity = capacity_test;

    capacity.entry_count_max = 1;

    var walk = try FileWalk.init(gpa, capacity);
    defer walk.deinit(gpa);

    try walk.record("/tmp/a.rs");
    try expectError(error.EntriesExhausted, walk.record("/tmp/b.rs"));
    try expectEqual(1, walk.count());
}

test "the default skip list is sorted and names no product" {
    var found_git = false;
    var found_modules = false;

    for (skipped_default[1..], skipped_default[0 .. skipped_default.len - 1]) |held, before| {
        try expect(!std.mem.lessThan(u8, held, before));
    }

    for (skipped_default) |held| {
        if (std.mem.eql(u8, held, ".git")) found_git = true;
        if (std.mem.eql(u8, held, "node_modules")) found_modules = true;
    }

    try expect(found_git);
    try expect(found_modules);
}
