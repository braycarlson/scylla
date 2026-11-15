const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const bounded = @import("../../stdx/bounded.zig");
const glob = @import("../glob.zig");
const path = @import("../path.zig");
const scan = @import("../../text/scan.zig");
const FileWalk = @import("../file_walk.zig");
const path_platform = @import("../path/platform.zig");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;
const expectError = std.testing.expectError;
const Span = bounded.Span;
const Ignores = @This();

arena: bounded.Buffer,
excludes: bounded.Buffer,
files: bounded.ArrayType(File),
lines: bounded.ArrayType(Line),
options: Options,
patterns: glob.Patterns,
scratch: bounded.Buffer,
states: glob.Patterns.Scratch,
text: bounded.Buffer,

pub const Capacity = struct {
    arena_bytes_max: u32,
    file_count_max: u32,
    line_count_max: u32,
    text_bytes_max: u32,
};

pub const CapacityError = error{
    ArenaExhausted,
    FilesExhausted,
    LinesExhausted,
    PathTooLong,
    TextExhausted,
};

pub const Kind = enum { directory, file };

pub const Options = struct {
    dot_ignore: bool = false,
    git: bool = true,
    parents: bool = true,
    repository_required: bool = false,
};

const File = struct {
    base: Span,
    lead: Span,
    line_end: u32,
    line_start: u32,
    origin: Origin,
};

const Origin = enum(u8) { dot_ignore, exclude, global, gitignore, repository };

const Compiled = union(enum) {
    line: Line,
    skipped,
};

const Line = struct {
    anchored: bool,
    directory_only: bool,
    negated: bool,
    row_end: u32,
    row_start: u32,
};

const Ancestors = struct {
    count: u32,
    ends: [ancestor_count_max]u32,

    fn of(absolute: []const u8) Ancestors {
        assert(absolute.len > 0);
        assert(path.is_absolute(absolute));

        var ancestors: Ancestors = .{ .count = 0, .ends = undefined };
        var below = absolute;

        for (0..ancestor_count_max) |_| {
            const parent = path.directory_of(below);
            if (parent.len == 0) break;
            if (parent.len >= below.len) break;

            ancestors.ends[ancestors.count] = @intCast(parent.len);
            ancestors.count += 1;
            below = parent;
        }

        assert(ancestors.count <= ancestor_count_max);

        return ancestors;
    }

    fn directory(ancestors: *const Ancestors, absolute: []const u8, index: u32) []const u8 {
        assert(index < ancestors.count);

        const end = ancestors.ends[index];

        assert(end <= absolute.len);

        return absolute[0..end];
    }
};

const ancestor_count_max: u32 = 64;
const dot_ignore_file = ".ignore";
const exclude_file = ".git/info/exclude";
const ignore_file = ".gitignore";
const repository_markers = [_][]const u8{ ".git", ".jj" };

const options_default: Options = .{
    .dot_ignore = false,
    .git = true,
    .parents = true,
    .repository_required = false,
};

pub fn init(
    gpa: std.mem.Allocator,
    capacity: Capacity,
    options: Options,
) std.mem.Allocator.Error!Ignores {
    assert(capacity.arena_bytes_max > 0);
    assert(capacity.file_count_max > 0);
    assert(capacity.line_count_max > 0);
    assert(capacity.text_bytes_max > 0);

    var arena = try bounded.Buffer.init(gpa, capacity.arena_bytes_max);
    errdefer arena.deinit(gpa);

    var excludes = try bounded.Buffer.init(gpa, path_platform.path_bytes_max);
    errdefer excludes.deinit(gpa);

    var files = try bounded.ArrayType(File).init(gpa, capacity.file_count_max);
    errdefer files.deinit(gpa);

    var lines = try bounded.ArrayType(Line).init(gpa, capacity.line_count_max);
    errdefer lines.deinit(gpa);

    var patterns = try glob.Patterns.init(gpa, .{
        .byte_count_max = capacity.text_bytes_max,
        .class_count_max = capacity.line_count_max,
        .pattern_count_max = capacity.line_count_max,
    });

    errdefer patterns.deinit(gpa);

    var scratch = try bounded.Buffer.init(gpa, path_platform.path_bytes_max);
    errdefer scratch.deinit(gpa);

    var states = try patterns.scratch_init(gpa);
    errdefer states.deinit(gpa);

    const text = try bounded.Buffer.init(gpa, capacity.text_bytes_max);

    return .{
        .arena = arena,
        .excludes = excludes,
        .files = files,
        .lines = lines,
        .options = options,
        .patterns = patterns,
        .scratch = scratch,
        .states = states,
        .text = text,
    };
}

pub fn deinit(ignores: *Ignores, gpa: std.mem.Allocator) void {
    ignores.text.deinit(gpa);
    ignores.states.deinit(gpa);
    ignores.scratch.deinit(gpa);
    ignores.patterns.deinit(gpa);
    ignores.lines.deinit(gpa);
    ignores.files.deinit(gpa);
    ignores.excludes.deinit(gpa);
    ignores.arena.deinit(gpa);
    ignores.* = undefined;
}

pub fn clear(ignores: *Ignores) void {
    ignores.arena.clear();
    ignores.files.clear();
    ignores.lines.clear();
    ignores.patterns.clear();
    assert(ignores.files.empty());
    assert(ignores.lines.empty());
}

pub fn count(ignores: *const Ignores) u32 {
    const file_count = ignores.files.count();

    assert(file_count <= ignores.files.capacity());

    return file_count;
}

pub fn covers(ignores: *Ignores, held: []const u8, kind: Kind) bool {
    assert(held.len > 0);

    var decided: std.EnumArray(Origin, ?bool) = .initFill(null);
    var repository = false;

    for (ignores.files.const_slice()) |*file| {
        assert(file.line_start <= file.line_end);

        const base = file.base.text(ignores.arena.const_slice());
        const relative = relative_to(base, held) orelse continue;
        if (relative.len == 0) continue;

        if (file.origin == .repository) {
            repository = true;

            decided.set(.exclude, null);
            decided.set(.gitignore, null);

            continue;
        }

        if (ignores.file_decided(file, relative, kind)) |ignored| {
            decided.set(file.origin, ignored);
        }
    }

    return ignores.decision(&decided, repository);
}

pub fn options_set(ignores: *Ignores, options: Options) void {
    ignores.options = options;
}

fn file_decided(ignores: *Ignores, file: *const File, relative: []const u8, kind: Kind) ?bool {
    assert(relative.len > 0);
    assert(file.origin != .repository);

    const lead = file.lead.text(ignores.arena.const_slice());
    const lines = ignores.lines.const_slice()[file.line_start..file.line_end];
    const name = name_of(relative);
    var anchored: Anchored = .unwritten;
    var decided: ?bool = null;

    for (lines) |*line| {
        if (line.directory_only) {
            if (kind != .directory) continue;
        }

        const subject = if (line.anchored)
            ignores.anchored_subject(&anchored, lead, relative) orelse continue
        else
            name;

        const rows: Span = .between(line.row_start, line.row_end);
        const matched = ignores.patterns.matches_within(&ignores.states, rows, subject);

        if (matched) decided = !line.negated;
    }

    return decided;
}

const Anchored = enum { overflowed, unwritten, written };

fn anchored_subject(
    ignores: *Ignores,
    anchored: *Anchored,
    lead: []const u8,
    relative: []const u8,
) ?[]const u8 {
    assert(relative.len > 0);
    assert(lead.len <= std.math.maxInt(u32));

    switch (anchored.*) {
        .overflowed => return null,
        .written => return ignores.scratch.const_slice(),
        .unwritten => {},
    }

    subject_write(&ignores.scratch, lead, relative) catch |err| switch (err) {
        error.Overflow => {
            anchored.* = .overflowed;

            return null;
        },
    };

    anchored.* = .written;

    return ignores.scratch.const_slice();
}

fn decision(
    ignores: *const Ignores,
    decided: *const std.EnumArray(Origin, ?bool),
    repository: bool,
) bool {
    assert(decided.get(.repository) == null);

    if (decided.get(.dot_ignore)) |ignored| return ignored;

    if (ignores.options.repository_required) {
        if (!repository) return false;
    }

    if (decided.get(.gitignore)) |ignored| return ignored;
    if (decided.get(.exclude)) |ignored| return ignored;
    if (!repository) return false;
    return decided.get(.global) orelse false;
}

pub fn excludes_set(ignores: *Ignores, file_path: []const u8) CapacityError!void {
    assert(file_path.len <= std.math.maxInt(u32));

    ignores.excludes.clear();

    ignores.excludes.push(file_path) catch |err| switch (err) {
        error.Overflow => return error.PathTooLong,
    };

    assert(ignores.excludes.count() == file_path.len);
}

pub fn read(ignores: *Ignores, io: std.Io, directory: []const u8) CapacityError!void {
    assert(directory.len > 0);

    if (ignores.options.git) {
        if (holds_repository(io, directory)) {
            try ignores.marker_push(directory);
            try ignores.read_named(io, directory, exclude_file, .exclude, directory, "");
        }

        try ignores.read_named(io, directory, ignore_file, .gitignore, directory, "");
    }

    if (ignores.options.dot_ignore) {
        try ignores.read_named(io, directory, dot_ignore_file, .dot_ignore, directory, "");
    }

    assert(ignores.files.count() <= ignores.files.capacity());
}

pub fn read_parents(ignores: *Ignores, io: std.Io, root: []const u8) CapacityError!void {
    assert(root.len <= std.math.maxInt(u32));

    const held = path.trimmed(root);

    assert(held.len > 0);

    var buffer: [path_platform.path_bytes_max]u8 = undefined;
    const absolute = absolute_of(io, held, &buffer) orelse return ignores.global_read(io, held, "");
    const ancestors: Ancestors = .of(absolute);
    const top = if (ignores.options.git) repository_of(io, &ancestors, absolute) else null;
    const lead_top = if (top) |index| lead_of(absolute, ancestors.ends[index]) else "";

    try ignores.global_read(io, held, lead_top);

    if (!ignores.options.parents) return;

    if (ignores.options.dot_ignore) {
        try ignores.read_dot_ignore_files(io, &ancestors, absolute, held);
    }

    if (top) |index| try ignores.read_repository(io, &ancestors, index, absolute, held);
}

fn global_read(
    ignores: *Ignores,
    io: std.Io,
    held: []const u8,
    lead: []const u8,
) CapacityError!void {
    assert(held.len > 0);
    assert(lead.len <= std.math.maxInt(u32));

    if (!ignores.options.git) return;
    if (ignores.excludes.count() == 0) return;

    try ignores.read_file(io, ignores.excludes.const_slice(), .global, held, lead);
}

fn read_dot_ignore_files(
    ignores: *Ignores,
    io: std.Io,
    ancestors: *const Ancestors,
    absolute: []const u8,
    held: []const u8,
) CapacityError!void {
    assert(ignores.options.dot_ignore);
    assert(ignores.options.parents);
    assert(absolute.len <= std.math.maxInt(u32));
    assert(held.len <= std.math.maxInt(u32));

    for (0..ancestors.count) |step| {
        const index: u32 = ancestors.count - 1 - @as(u32, @intCast(step));
        const directory = ancestors.directory(absolute, index);
        const lead = lead_of(absolute, ancestors.ends[index]);

        try ignores.read_named(io, directory, dot_ignore_file, .dot_ignore, held, lead);
    }
}

fn read_repository(
    ignores: *Ignores,
    io: std.Io,
    ancestors: *const Ancestors,
    top: u32,
    absolute: []const u8,
    held: []const u8,
) CapacityError!void {
    assert(top < ancestors.count);
    assert(ignores.options.git);
    assert(absolute.len <= std.math.maxInt(u32));
    assert(held.len <= std.math.maxInt(u32));

    const top_directory = ancestors.directory(absolute, top);

    try ignores.marker_push(held);

    try ignores.read_named(
        io,
        top_directory,
        exclude_file,
        .exclude,
        held,
        lead_of(absolute, ancestors.ends[top]),
    );

    for (0..top + 1) |step| {
        const index: u32 = top - @as(u32, @intCast(step));
        const directory = ancestors.directory(absolute, index);
        const lead = lead_of(absolute, ancestors.ends[index]);

        try ignores.read_named(io, directory, ignore_file, .gitignore, held, lead);
    }
}

fn repository_of(io: std.Io, ancestors: *const Ancestors, absolute: []const u8) ?u32 {
    assert(ancestors.count <= ancestor_count_max);

    if (holds_repository(io, absolute)) return null;

    for (0..ancestors.count) |index| {
        const directory = ancestors.directory(absolute, @intCast(index));

        if (holds_repository(io, directory)) {
            assert(index < ancestors.count);

            return @intCast(index);
        }
    }

    return null;
}

fn marker_push(ignores: *Ignores, base: []const u8) CapacityError!void {
    assert(base.len > 0);

    if (ignores.files.full()) return error.FilesExhausted;

    const base_span = interned(&ignores.arena, base) orelse return error.ArenaExhausted;
    const lead_span = interned(&ignores.arena, "") orelse return error.ArenaExhausted;
    const line_count = ignores.lines.count();

    ignores.files.push(.{
        .base = base_span,
        .lead = lead_span,
        .line_end = line_count,
        .line_start = line_count,
        .origin = .repository,
    });

    assert(ignores.files.count() > 0);
}

fn read_named(
    ignores: *Ignores,
    io: std.Io,
    directory: []const u8,
    name: []const u8,
    origin: Origin,
    base: []const u8,
    lead: []const u8,
) CapacityError!void {
    assert(directory.len > 0);
    assert(origin != .repository);
    assert(name.len <= std.math.maxInt(u32));
    assert(base.len <= std.math.maxInt(u32));
    assert(lead.len <= std.math.maxInt(u32));

    var buffer: [path_platform.path_bytes_max]u8 = undefined;
    const length = path.join(&buffer, .{ .base = directory, .relative = name }) catch return;

    try ignores.read_file(io, buffer[0..length], origin, base, lead);
}

fn read_file(
    ignores: *Ignores,
    io: std.Io,
    file_path: []const u8,
    origin: Origin,
    base: []const u8,
    lead: []const u8,
) CapacityError!void {
    assert(file_path.len > 0);
    assert(origin != .repository);
    assert(base.len <= std.math.maxInt(u32));
    assert(lead.len <= std.math.maxInt(u32));

    const file = path.open(io, file_path) catch return;
    defer file.close(io);

    ignores.text_read(io, file) catch |err| switch (err) {
        error.TextExhausted => return error.TextExhausted,
        error.Unreadable => return,
    };

    const line_start = ignores.lines.count();

    try ignores.lines_compile();

    const line_end = ignores.lines.count();
    if (line_start == line_end) return;
    if (ignores.files.full()) return error.FilesExhausted;

    const base_span = interned(&ignores.arena, base) orelse return error.ArenaExhausted;
    const lead_span = interned(&ignores.arena, lead) orelse return error.ArenaExhausted;

    ignores.files.push(.{
        .base = base_span,
        .lead = lead_span,
        .line_end = line_end,
        .line_start = line_start,
        .origin = origin,
    });
}

fn text_read(
    ignores: *Ignores,
    io: std.Io,
    file: std.Io.File,
) error{ TextExhausted, Unreadable }!void {
    if (builtin.target.os.tag != .windows) assert(file.handle >= 0);

    ignores.text.clear();

    var reader = file.reader(io, &.{});

    const length = reader.interface.readSliceShort(ignores.text.bytes) catch {
        return error.Unreadable;
    };

    if (length == ignores.text.bytes.len) return error.TextExhausted;

    ignores.text.length = @intCast(length);

    assert(ignores.text.count() < ignores.text.capacity());
}

fn lines_compile(ignores: *Ignores) CapacityError!void {
    const text = ignores.text.const_slice();
    var lines = std.mem.splitScalar(u8, text, '\n');
    var line_count: u32 = 0;

    while (lines.next()) |line| {
        line_count += 1;

        assert(line_count <= text.len + 1);

        const held = switch (try compiled(&ignores.patterns, line)) {
            .skipped => continue,
            .line => |held| held,
        };

        if (ignores.lines.full()) return error.LinesExhausted;

        ignores.lines.push(held);
    }
}

fn compiled(patterns: *glob.Patterns, line: []const u8) CapacityError!Compiled {
    assert(line.len <= std.math.maxInt(u32));

    var pattern = std.mem.trim(u8, line, scan.ascii_whitespace);
    if (pattern.len == 0) return .skipped;
    if (pattern[0] == '#') return .skipped;

    const negated = pattern[0] == '!';

    if (negated) pattern = pattern[1..];

    const directory_only = std.mem.endsWith(u8, pattern, "/");

    if (directory_only) pattern = pattern[0 .. pattern.len - 1];

    const leading = std.mem.startsWith(u8, pattern, "/");

    if (leading) pattern = pattern[1..];

    if (pattern.len == 0) return .skipped;

    const anchored = leading or std.mem.findScalar(u8, pattern, path.separator) != null;
    const row_start = patterns.count();
    const pushed = if (anchored) patterns.push_anchored(pattern) else patterns.push(pattern);

    pushed catch |err| {
        patterns.truncate(row_start);

        return skipped_or_exhausted(err);
    };

    assert(patterns.count() >= row_start);

    return .{
        .line = .{
            .anchored = anchored,
            .directory_only = directory_only,
            .negated = negated,
            .row_end = patterns.count(),
            .row_start = row_start,
        },
    };
}

fn skipped_or_exhausted(err: glob.Error) CapacityError!Compiled {
    return switch (err) {
        error.BytesExhausted => error.TextExhausted,
        error.ClassesExhausted, error.PatternsExhausted => error.LinesExhausted,
        error.BraceTooDeep,
        error.BraceUnclosed,
        error.ClassUnclosed,
        error.DoubleStarComponent,
        error.Empty,
        error.EscapeUnfinished,
        error.VariantsExhausted,
        => .skipped,
    };
}

fn absolute_of(
    io: std.Io,
    held: []const u8,
    buffer: *[path_platform.path_bytes_max]u8,
) ?[]const u8 {
    assert(held.len > 0);

    const length = std.Io.Dir.cwd().realPathFile(io, held, buffer) catch return null;
    if (length == 0) return null;

    assert(length <= buffer.len);

    return buffer[0..length];
}

fn holds_repository(io: std.Io, directory: []const u8) bool {
    assert(directory.len > 0);

    for (repository_markers) |marker| {
        var buffer: [path_platform.path_bytes_max]u8 = undefined;
        const parts: path.Join = .{ .base = directory, .relative = marker };
        const length = path.join(&buffer, parts) catch continue;

        assert(length <= buffer.len);

        if (path.stat_of(io, buffer[0..length]) != null) return true;
    }

    return false;
}

fn interned(arena: *bounded.Buffer, bytes: []const u8) ?Span {
    assert(bytes.len <= std.math.maxInt(u32));

    const offset = arena.count();

    arena.push(bytes) catch return null;
    assert(arena.count() - offset == bytes.len);

    return .{ .offset = offset, .length = @intCast(bytes.len) };
}

fn lead_of(absolute: []const u8, end: u32) []const u8 {
    assert(end <= absolute.len);

    var rest = absolute[end..];

    for (0..rest.len) |_| {
        if (rest.len == 0) break;
        if (!path.is_separator(rest[0])) break;

        rest = rest[1..];
    }

    assert(rest.len <= absolute.len - end);

    return rest;
}

fn relative_to(directory: []const u8, held: []const u8) ?[]const u8 {
    assert(directory.len > 0);

    if (!std.mem.startsWith(u8, held, directory)) return null;

    const rest = held[directory.len..];
    if (rest.len == 0) return rest;
    if (path.is_separator(directory[directory.len - 1])) return rest;
    if (path.is_separator(rest[0])) return rest[1..];
    return null;
}

fn subject_write(
    scratch: *bounded.Buffer,
    lead: []const u8,
    relative: []const u8,
) error{Overflow}!void {
    assert(relative.len > 0);
    assert(lead.len <= std.math.maxInt(u32));

    scratch.clear();

    if (lead.len > 0) {
        try portable_push(scratch, lead);
        try scratch.push_byte(path.separator);
    }

    try portable_push(scratch, relative);
}

fn name_of(relative: []const u8) []const u8 {
    assert(relative.len > 0);

    var start = relative.len;

    for (0..relative.len) |_| {
        if (start == 0) break;
        if (path.is_separator(relative[start - 1])) break;

        start -= 1;
    }

    assert(start <= relative.len);

    return relative[start..];
}

fn portable_push(scratch: *bounded.Buffer, bytes: []const u8) error{Overflow}!void {
    assert(bytes.len <= std.math.maxInt(u32));

    const start = scratch.count();

    if (path_platform.platform_native == .windows) {
        for (bytes) |byte| {
            try scratch.push_byte(if (path.is_separator(byte)) path.separator else byte);
        }
    } else {
        try scratch.push(bytes);
    }

    assert(scratch.count() - start == bytes.len);
}

const capacity_walk_test: FileWalk.Capacity = .{
    .arena_bytes_max = 1 << 16,
    .depth_max = 64,
    .entry_count_max = 256,
    .pending_max = 64,
};

const capacity_test: Capacity = .{
    .arena_bytes_max = 1 << 12,
    .file_count_max = 16,
    .line_count_max = 64,
    .text_bytes_max = 1 << 12,
};

const Written = struct {
    relative: []const u8,
    text: []const u8,
};

const Root = struct {
    bytes: [path_platform.path_bytes_max]u8,
    length: u32,

    fn slice(root: *const Root) []const u8 {
        return root.bytes[0..root.length];
    }
};

fn tree_test(tmp: *std.testing.TmpDir, files: []const Written) !Root {
    assert(files.len <= std.math.maxInt(u32));

    const io = std.testing.io;
    var root: Root = .{ .bytes = undefined, .length = 0 };
    const written = try std.mem.print(&root.bytes, ".zig-cache/tmp/{s}", .{&tmp.sub_path});

    root.length = @intCast(written.len);

    for (files) |file| {
        const parent = std.Io.Dir.path.dirname(file.relative);

        if (parent) |directory| try tmp.dir.createDirPath(io, directory);

        try tmp.dir.writeFile(io, .{ .sub_path = file.relative, .data = file.text });
    }

    return root;
}

fn expect_walked(root: []const u8, expected: []const []const u8) !void {
    assert(root.len > 0);
    assert(expected.len <= std.math.maxInt(u32));

    try expect_walked_excluding(root, null, expected);
}

fn expect_walked_excluding(
    root: []const u8,
    excludes: ?[]const u8,
    expected: []const []const u8,
) !void {
    assert(root.len > 0);
    if (excludes) |held| assert(held.len > 0);
    assert(expected.len <= std.math.maxInt(u32));

    try expect_walked_with(root, options_default, excludes, expected);
}

fn expect_walked_with(
    root: []const u8,
    options: Options,
    excludes: ?[]const u8,
    expected: []const []const u8,
) !void {
    assert(root.len <= std.math.maxInt(u32));
    if (excludes) |held| assert(held.len <= std.math.maxInt(u32));

    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var walk = try FileWalk.init(gpa, capacity_walk_test);
    defer walk.deinit(gpa);

    var ignores = try Ignores.init(gpa, capacity_test, options);
    defer ignores.deinit(gpa);

    if (excludes) |held| try ignores.excludes_set(held);

    try walk.run(io, root, &.{
        .excludes = null,
        .ignores = &ignores,
        .skipped = &.{".git"},
    });

    walk.sort();

    try expectEqual(expected.len, walk.count());

    var walked_paths = walk.paths();

    for (expected) |relative| {
        const walked = walked_paths.next() orelse return error.TestUnexpectedResult;

        try expectEqualStrings(relative, walked[root.len + 1 ..]);
    }
}

test Ignores {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tree_test(&tmp, &.{
        .{ .relative = ".gitignore", .text = "*.log\n" },
        .{ .relative = "debug.log", .text = "" },
        .{ .relative = "main.rs", .text = "" },
    });

    var ignores = try Ignores.init(gpa, capacity_test, .{ .parents = false });
    defer ignores.deinit(gpa);

    var walk = try FileWalk.init(gpa, capacity_walk_test);
    defer walk.deinit(gpa);

    var log_buffer: [path_platform.path_bytes_max]u8 = undefined;
    const log_parts: path.Join = .{ .base = root.slice(), .relative = "debug.log" };
    const log_length = try path.join(&log_buffer, log_parts);

    try walk.run(io, root.slice(), &.{ .excludes = null, .ignores = &ignores, .skipped = &.{} });
    try expectEqual(2, walk.count());
    try expect(ignores.covers(log_buffer[0..log_length], .file));
}

test "a bare name is ignored at any depth" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tree_test(&tmp, &.{
        .{ .relative = ".gitignore", .text = "notes.txt\n" },
        .{ .relative = "notes.txt", .text = "" },
        .{ .relative = "deep/notes.txt", .text = "" },
        .{ .relative = "deep/page.html", .text = "" },
    });

    try expect_walked(root.slice(), &.{ ".gitignore", "deep/page.html" });
}

test "a trailing slash names a directory and takes everything under it" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tree_test(&tmp, &.{
        .{ .relative = ".gitignore", .text = "build/\n" },
        .{ .relative = "build", .text = "" },
        .{ .relative = "build.html", .text = "" },
        .{ .relative = "out/build/page.html", .text = "" },
        .{ .relative = "templates/page.html", .text = "" },
    });

    try expect_walked(
        root.slice(),
        &.{ ".gitignore", "build", "build.html", "templates/page.html" },
    );
}

test "a slash anchors a pattern to its own directory" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tree_test(&tmp, &.{
        .{ .relative = ".gitignore", .text = "/vendor/*.html\n" },
        .{ .relative = "vendor/widget.html", .text = "" },
        .{ .relative = "nested/vendor/widget.html", .text = "" },
    });

    try expect_walked(root.slice(), &.{ ".gitignore", "nested/vendor/widget.html" });
}

test "a leading slash anchors a bare name to its own directory" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tree_test(&tmp, &.{
        .{ .relative = ".gitignore", .text = "/vendor\n" },
        .{ .relative = "vendor/widget.html", .text = "" },
        .{ .relative = "nested/vendor/widget.html", .text = "" },
    });

    try expect_walked(root.slice(), &.{ ".gitignore", "nested/vendor/widget.html" });
}

test "a negation takes an earlier match back" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tree_test(&tmp, &.{
        .{ .relative = ".gitignore", .text = "*.html\n!keep.html\n" },
        .{ .relative = "keep.html", .text = "" },
        .{ .relative = "page.html", .text = "" },
    });

    try expect_walked(root.slice(), &.{ ".gitignore", "keep.html" });
}

test "a file under an ignored directory cannot be re included" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tree_test(&tmp, &.{
        .{ .relative = ".gitignore", .text = "build/\n!build/keep.html\n" },
        .{ .relative = "build/keep.html", .text = "" },
        .{ .relative = "page.html", .text = "" },
    });

    try expect_walked(root.slice(), &.{ ".gitignore", "page.html" });
}

test "a nested file governs its own directory and wins over the root" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tree_test(&tmp, &.{
        .{ .relative = ".gitignore", .text = "*.log\n" },
        .{ .relative = "app/.gitignore", .text = "!debug.log\ncache/\n" },
        .{ .relative = "app/debug.log", .text = "" },
        .{ .relative = "app/cache/page.html", .text = "" },
        .{ .relative = "app/page.html", .text = "" },
        .{ .relative = "root.log", .text = "" },
    });

    try expect_walked(
        root.slice(),
        &.{ ".gitignore", "app/.gitignore", "app/debug.log", "app/page.html" },
    );
}

test "a file above the root governs the root by its own spelling" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tree_test(&tmp, &.{
        .{ .relative = ".git/HEAD", .text = "ref: refs/heads/main\n" },
        .{ .relative = ".gitignore", .text = "/project/build/\n*.tmp\n" },
        .{ .relative = "project/build/page.html", .text = "" },
        .{ .relative = "project/page.html", .text = "" },
        .{ .relative = "project/scratch.tmp", .text = "" },
    });

    var project: [path_platform.path_bytes_max]u8 = undefined;
    const length = try path.join(&project, .{ .base = root.slice(), .relative = "project" });

    try expect_walked(project[0..length], &.{"page.html"});
}

test "the repository exclude file ranks below every gitignore" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tree_test(&tmp, &.{
        .{ .relative = ".git/HEAD", .text = "ref: refs/heads/main\n" },
        .{ .relative = ".git/info/exclude", .text = "*.tmp\nkeep.html\n" },
        .{ .relative = ".gitignore", .text = "!keep.html\n" },
        .{ .relative = "keep.html", .text = "" },
        .{ .relative = "page.html", .text = "" },
        .{ .relative = "scratch.tmp", .text = "" },
    });

    try expect_walked(root.slice(), &.{ ".gitignore", "keep.html", "page.html" });
}

test "a global excludes file governs a repository and nothing outside one" {
    var tmp_global = std.testing.tmpDir(.{});
    defer tmp_global.cleanup();

    var tmp_repository = std.testing.tmpDir(.{});
    defer tmp_repository.cleanup();

    var tmp_plain = std.testing.tmpDir(.{});
    defer tmp_plain.cleanup();

    const global = try tree_test(&tmp_global, &.{
        .{ .relative = "ignore", .text = "*.log\n" },
    });

    const repository = try tree_test(&tmp_repository, &.{
        .{ .relative = ".git/HEAD", .text = "ref: refs/heads/main\n" },
        .{ .relative = ".git/info/exclude", .text = "!kept.log\n" },
        .{ .relative = "debug.log", .text = "" },
        .{ .relative = "kept.log", .text = "" },
    });

    const plain = try tree_test(&tmp_plain, &.{
        .{ .relative = "debug.log", .text = "" },
    });

    var excludes: [path_platform.path_bytes_max]u8 = undefined;
    const length = try path.join(&excludes, .{ .base = global.slice(), .relative = "ignore" });
    var hermetic = options_default;

    hermetic.parents = false;

    try expect_walked_with(repository.slice(), hermetic, excludes[0..length], &.{"kept.log"});
    try expect_walked_with(plain.slice(), hermetic, excludes[0..length], &.{"debug.log"});
}

const options_crate: Options = .{
    .dot_ignore = true,
    .git = true,
    .parents = true,
    .repository_required = true,
};

test "a dot ignore file is honoured with or without a repository" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tree_test(&tmp, &.{
        .{ .relative = ".ignore", .text = "templates/y.html\n" },
        .{ .relative = "templates/x.html", .text = "" },
        .{ .relative = "templates/y.html", .text = "" },
    });

    var alone = options_crate;

    alone.git = false;
    alone.parents = false;

    try expect_walked_with(root.slice(), alone, null, &.{ ".ignore", "templates/x.html" });
    try expect_walked_with(root.slice(), options_crate, null, &.{ ".ignore", "templates/x.html" });
}

test "a gitignore needs a repository when one is required" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tree_test(&tmp, &.{
        .{ .relative = ".gitignore", .text = "*.html\n" },
        .{ .relative = "page.html", .text = "" },
    });

    var detached = options_crate;

    detached.parents = false;

    try expect_walked_with(root.slice(), detached, null, &.{ ".gitignore", "page.html" });

    try tmp.dir.createDirPath(io, ".git");

    try expect_walked_with(root.slice(), detached, null, &.{".gitignore"});
}

test "a dot ignore file outranks every gitignore" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tree_test(&tmp, &.{
        .{ .relative = ".git/HEAD", .text = "ref: refs/heads/main\n" },
        .{ .relative = ".gitignore", .text = "keep.html\n!drop.html\n" },
        .{ .relative = "app/.ignore", .text = "!keep.html\ndrop.html\n" },
        .{ .relative = "app/drop.html", .text = "" },
        .{ .relative = "app/keep.html", .text = "" },
        .{ .relative = "keep.html", .text = "" },
    });

    try expect_walked_with(
        root.slice(),
        options_crate,
        null,
        &.{ ".gitignore", "app/.ignore", "app/keep.html" },
    );
}

test "a gitignore above a nested repository does not reach into it" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tree_test(&tmp, &.{
        .{ .relative = ".git/HEAD", .text = "ref: refs/heads/main\n" },
        .{ .relative = ".gitignore", .text = "*.tmp\n" },
        .{ .relative = "inner/.git/HEAD", .text = "ref: refs/heads/main\n" },
        .{ .relative = "inner/kept.tmp", .text = "" },
        .{ .relative = "outer.tmp", .text = "" },
    });

    try expect_walked_with(root.slice(), options_crate, null, &.{ ".gitignore", "inner/kept.tmp" });
}

test "a dot ignore file above the root governs it without a repository" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tree_test(&tmp, &.{
        .{ .relative = ".ignore", .text = "/project/build/\n*.tmp\n" },
        .{ .relative = "project/build/page.html", .text = "" },
        .{ .relative = "project/page.html", .text = "" },
        .{ .relative = "project/scratch.tmp", .text = "" },
    });

    var project: [path_platform.path_bytes_max]u8 = undefined;
    const length = try path.join(&project, .{ .base = root.slice(), .relative = "project" });
    var walked_alone = options_crate;

    walked_alone.parents = false;

    try expect_walked_with(project[0..length], options_crate, null, &.{"page.html"});

    try expect_walked_with(
        project[0..length],
        walked_alone,
        null,
        &.{ "build/page.html", "page.html", "scratch.tmp" },
    );
}

test "the exclude file of a repository above the root governs it" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tree_test(&tmp, &.{
        .{ .relative = ".git/info/exclude", .text = "*.log\n" },
        .{ .relative = "project/debug.log", .text = "" },
        .{ .relative = "project/page.html", .text = "" },
    });

    var project: [path_platform.path_bytes_max]u8 = undefined;
    const length = try path.join(&project, .{ .base = root.slice(), .relative = "project" });

    try expect(path.is_directory(io, project[0..length]));
    try expect_walked_with(project[0..length], options_crate, null, &.{"page.html"});
}

test "comments and blank lines are not patterns" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tree_test(&tmp, &.{
        .{ .relative = ".gitignore", .text = "# nothing here\n\n   \n" },
        .{ .relative = "page.html", .text = "" },
    });

    try expect_walked(root.slice(), &.{ ".gitignore", "page.html" });
}

test "the tables are cleared between walks" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp_ignored = std.testing.tmpDir(.{});
    defer tmp_ignored.cleanup();

    var tmp_plain = std.testing.tmpDir(.{});
    defer tmp_plain.cleanup();

    const root_ignored = try tree_test(&tmp_ignored, &.{
        .{ .relative = ".gitignore", .text = "*.html\n" },
        .{ .relative = "page.html", .text = "" },
    });

    const root_plain = try tree_test(&tmp_plain, &.{
        .{ .relative = "page.html", .text = "" },
    });

    var walk = try FileWalk.init(gpa, capacity_walk_test);
    defer walk.deinit(gpa);

    var detached = options_default;

    detached.parents = false;

    var ignores = try Ignores.init(gpa, capacity_test, detached);
    defer ignores.deinit(gpa);

    const options: FileWalk.Options = .{ .excludes = null, .ignores = &ignores, .skipped = &.{} };

    try walk.run(io, root_ignored.slice(), &options);
    try expectEqual(1, ignores.count());
    try walk.run(io, root_plain.slice(), &options);
    try expectEqual(0, ignores.count());
    try expectEqual(1, walk.count());
}

test "an ignore file that cannot be read is passed over like a missing one" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tree_test(&tmp, &.{
        .{ .relative = ".gitignore/inner.txt", .text = "" },
        .{ .relative = "page.html", .text = "" },
    });

    try expect_walked(root.slice(), &.{ ".gitignore/inner.txt", "page.html" });
}

test "an ignore line too large for the pattern table refuses the walk" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const lead = "*.log\n";
    const class = "[ab]";
    const class_count = 33;
    var text: [lead.len + class.len * class_count + 1]u8 = undefined;

    @memcpy(text[0..lead.len], lead);

    for (0..class_count) |index| {
        @memcpy(text[lead.len + index * class.len ..][0..class.len], class);
    }

    text[text.len - 1] = '\n';

    const root = try tree_test(&tmp, &.{
        .{ .relative = ".gitignore", .text = &text },
        .{ .relative = "page.html", .text = "" },
    });

    var detached = options_default;

    detached.parents = false;

    var ignores = try Ignores.init(gpa, capacity_test, detached);
    defer ignores.deinit(gpa);

    try expectError(error.LinesExhausted, ignores.read(io, root.slice()));

    var walk = try FileWalk.init(gpa, capacity_walk_test);
    defer walk.deinit(gpa);

    const options: FileWalk.Options = .{ .excludes = null, .ignores = &ignores, .skipped = &.{} };

    try expectError(error.IgnoresExhausted, walk.run(io, root.slice(), &options));
}

test "a reconfigured table reads by its new options" {
    const gpa = std.testing.allocator;
    const overlong: [path_platform.path_bytes_max + 1]u8 = @splat('a');
    var ignores = try Ignores.init(gpa, capacity_test, .{});
    defer ignores.deinit(gpa);

    try expect(ignores.options.git);
    try expect(!ignores.options.dot_ignore);

    ignores.options_set(options_crate);

    try expect(ignores.options.dot_ignore);
    try expect(ignores.options.repository_required);
    try expectError(error.PathTooLong, ignores.excludes_set(&overlong));
}
