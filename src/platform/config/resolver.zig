const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const bounded = @import("../../stdx/bounded.zig");
const path = @import("../path.zig");
const path_platform = @import("../path/platform.zig");
const ArrayType = bounded.ArrayType;
const Buffer = bounded.Buffer;
const Span = bounded.Span;

buffer: Buffer,
capacity: Capacity,
directory: Buffer,
failure: Span,
name: u32,
options: Options,
paths: Buffer,
spans: ArrayType(Span),
steps: u32,
target: []u8,

const Resolver = @This();

pub const Capacity = struct {
    config_bytes_max: u32,
    extend_depth_max: u32,
    path_bytes_max: u32,
};

pub const Options = struct {
    file_names: []const []const u8,
    section_file_name: ?[]const u8,
    extend_join: ExtendJoin = .normalized,

    pub const ExtendJoin = enum { normalized, parents_kept };

    pub fn needs_section(options: *const Options, file_path: []const u8) bool {
        const section_file_name = options.section_file_name orelse return false;

        assert(section_file_name.len > 0);

        if (!std.mem.endsWith(u8, file_path, section_file_name)) return false;

        const at = file_path.len - section_file_name.len;

        assert(at <= file_path.len);

        if (at == 0) return true;
        return path.is_separator(file_path[at - 1]);
    }
};

pub const Origin = enum { directory, file };

pub const Discovery = union(enum) {
    absent,
    found: Span,
};

pub const File = struct {
    path: []const u8,
    source: []const u8,
};

pub const Chain = struct {
    io: std.Io,
    read_count: u32,
    remaining: u32,
    resolver: *Resolver,

    pub fn init(resolver: *Resolver, io: std.Io, span: Span) Chain {
        assert(span.length > 0);
        assert(span.end() <= resolver.paths.count());

        resolver.spans.clear();
        resolver.spans.push(span);

        return .{
            .io = io,
            .read_count = 0,
            .remaining = resolver.spans.capacity(),
            .resolver = resolver,
        };
    }

    pub fn pending(chain: *const Chain) bool {
        const resolver = chain.resolver;

        assert(chain.remaining <= resolver.spans.capacity());
        assert(chain.read_count <= resolver.spans.count());

        if (chain.remaining == 0) return false;
        return chain.read_count < resolver.spans.count();
    }

    pub fn next(chain: *Chain) Error!File {
        const resolver = chain.resolver;

        assert(chain.pending());

        const span = resolver.spans.get(chain.read_count);

        chain.read_count += 1;
        chain.remaining -= 1;

        try resolver.file_read(chain.io, span);

        return resolver.file_of(span);
    }

    pub fn extend(chain: *Chain, relative: []const u8) Error!void {
        assert(relative.len <= std.math.maxInt(u32));

        const resolver = chain.resolver;

        assert(chain.read_count > 0);
        assert(chain.read_count == resolver.spans.count());

        const current = resolver.spans.get(chain.read_count - 1);
        const target = try resolver.extend_target(current, relative);
        if (resolver.chain_holds(target)) return error.ExtendCycle;
        if (resolver.spans.full()) return error.DepthExceeded;

        resolver.spans.push(target);

        assert(resolver.spans.count() == chain.read_count + 1);
    }

    pub fn discard(chain: *Chain) void {
        const resolver = chain.resolver;

        assert(chain.read_count > 1);
        assert(chain.read_count == resolver.spans.count());

        chain.read_count -= 1;

        resolver.spans.truncate(chain.read_count);

        assert(resolver.spans.count() == chain.read_count);
    }
};

pub const Files = struct {
    io: std.Io,
    remaining: u32,
    resolver: *Resolver,

    pub fn init(resolver: *Resolver, io: std.Io) Files {
        assert(resolver.spans.count() <= resolver.spans.capacity());

        return .{ .io = io, .remaining = resolver.spans.count(), .resolver = resolver };
    }

    pub fn next(files: *Files) Error!File {
        const resolver = files.resolver;

        assert(files.remaining > 0);
        assert(files.remaining <= resolver.spans.count());

        files.remaining -= 1;

        const span = resolver.spans.get(files.remaining);

        try resolver.file_read(files.io, span);

        return resolver.file_of(span);
    }
};

pub const CapacityError = error{
    DepthExceeded,
    FileTooBig,
    PathTooLong,
    PathsExhausted,
};

pub const InputError = error{ ExtendCycle, PathEmpty, Utf8Invalid };
pub const Error = CapacityError || InputError || path.SystemError;
pub const directory_depth_max: u32 = 64;
pub const extend_key = "extend";
const read_buffer_bytes = 512;

pub fn init(
    gpa: std.mem.Allocator,
    capacity: Capacity,
    options: Options,
) std.mem.Allocator.Error!Resolver {
    assert(capacity.config_bytes_max > 0);
    assert(capacity.extend_depth_max > 0);
    assert(capacity.path_bytes_max > 0);
    assert(capacity.path_bytes_max <= path_platform.path_bytes_max);
    assert(options.file_names.len > 0);

    var buffer = try Buffer.init(gpa, capacity.config_bytes_max);
    errdefer buffer.deinit(gpa);

    var spans = try ArrayType(Span).init(gpa, capacity.extend_depth_max);
    errdefer spans.deinit(gpa);

    var directory = try Buffer.init(gpa, capacity.path_bytes_max);
    errdefer directory.deinit(gpa);

    var paths = try Buffer.init(gpa, capacity.path_bytes_max * capacity.extend_depth_max * 2);
    errdefer paths.deinit(gpa);

    const target = try gpa.alloc(u8, capacity.path_bytes_max);

    return .{
        .buffer = buffer,
        .capacity = capacity,
        .directory = directory,
        .failure = .empty,
        .name = 0,
        .options = options,
        .paths = paths,
        .spans = spans,
        .steps = directory_depth_max,
        .target = target,
    };
}

pub fn deinit(resolver: *Resolver, gpa: std.mem.Allocator) void {
    assert(resolver.target.len == resolver.capacity.path_bytes_max);
    assert(resolver.steps <= directory_depth_max);

    resolver.buffer.deinit(gpa);
    resolver.spans.deinit(gpa);
    resolver.directory.deinit(gpa);
    resolver.paths.deinit(gpa);
    gpa.free(resolver.target);
    resolver.* = undefined;
}

pub fn clear(resolver: *Resolver) void {
    resolver.spans.clear();
    resolver.paths.clear();
    resolver.steps = directory_depth_max;
    resolver.failure = .empty;

    assert(resolver.spans.empty());
    assert(resolver.paths.empty());
}

pub fn chain_at(resolver: *const Resolver, index: u32) []const u8 {
    assert(index < resolver.chain_count());

    const held = resolver.path_of(resolver.spans.get(index));

    assert(held.len > 0);

    return held;
}

pub fn chain_count(resolver: *const Resolver) u32 {
    const count = resolver.spans.count();

    assert(count <= resolver.spans.capacity());

    return count;
}

pub fn found(resolver: *const Resolver) ?[]const u8 {
    if (resolver.spans.empty()) return null;

    const held = resolver.path_of(resolver.spans.get(0));

    assert(held.len > 0);

    return held;
}

pub fn path_of(resolver: *const Resolver, span: Span) []const u8 {
    assert(span.length > 0);
    assert(span.end() <= resolver.paths.count());

    return span.text(resolver.paths.const_slice());
}

pub fn diagnostic(resolver: *const Resolver) []const u8 {
    assert(resolver.failure.length > 0);
    assert(resolver.failure.length <= resolver.capacity.path_bytes_max);

    return resolver.path_of(resolver.failure);
}

pub fn record(resolver: *Resolver, file_path: []const u8) Error!Span {
    if (file_path.len == 0) return error.PathEmpty;
    if (file_path.len > resolver.capacity.path_bytes_max) return error.PathTooLong;
    return resolver.intern(file_path);
}

pub fn discover(
    resolver: *Resolver,
    io: std.Io,
    start: []const u8,
    origin: Origin,
) CapacityError!Discovery {
    assert(start.len <= std.math.maxInt(u32));

    const directory = switch (origin) {
        .directory => start,
        .file => path.directory_of(start),
    };

    assert(directory.len <= start.len or directory.len == 1);

    try resolver.discover_start(directory);

    return resolver.discover_next(io);
}

fn discover_start(resolver: *Resolver, directory: []const u8) CapacityError!void {
    assert(directory.len <= std.math.maxInt(u32));

    resolver.directory.clear();
    resolver.name = 0;
    resolver.steps = directory_depth_max;

    const root = if (directory.len == 0) "." else path.trimmed(directory);

    resolver.directory.push(root) catch |err| switch (err) {
        error.Overflow => return error.PathTooLong,
    };

    resolver.steps = 0;

    assert(resolver.directory.count() == root.len);
    assert(resolver.name == 0);
}

fn discover_next(resolver: *Resolver, io: std.Io) CapacityError!Discovery {
    const name_count: u32 = @intCast(resolver.options.file_names.len);

    for (0..directory_depth_max + 1) |_| {
        if (resolver.steps >= directory_depth_max) return .absent;

        assert(resolver.name <= name_count);

        while (resolver.name < name_count) {
            assert(resolver.directory.count() > 0);

            const name = resolver.options.file_names[resolver.name];

            resolver.name += 1;

            const directory = resolver.directory.const_slice();
            const parts: path.Join = .{ .base = directory, .relative = name };

            const length = path.join(resolver.target, parts) catch |err| {
                switch (err) {
                    error.Overflow => continue,
                }
            };

            const candidate = resolver.target[0..length];
            if (!path.is_file(io, candidate)) continue;
            return .{ .found = try resolver.intern(candidate) };
        }

        if (!resolver.ascend()) {
            resolver.steps = directory_depth_max;

            return .absent;
        }

        resolver.name = 0;
        resolver.steps += 1;
    }

    unreachable;
}

fn ascend(resolver: *Resolver) bool {
    const held = resolver.directory.const_slice();
    const climbing = std.mem.eql(u8, held, "..") or std.mem.endsWith(u8, held, "/..");
    const current = std.mem.eql(u8, held, ".");
    const parent = path.directory_of(held);
    const shorter = parent.len < held.len;
    const stepped = shorter and std.mem.startsWith(u8, held, parent);
    const absolute = path.is_absolute(held);

    assert(held.len > 0);

    if (climbing) return resolver.ascend_pushed("/..");

    if (current) {
        resolver.directory.clear();

        return resolver.ascend_pushed("..");
    }

    if (stepped) {
        resolver.directory.truncate(@intCast(parent.len));

        assert(resolver.directory.count() > 0);

        return true;
    }

    if (absolute) return false;

    resolver.directory.clear();

    return resolver.ascend_pushed(".");
}

fn ascend_pushed(resolver: *Resolver, bytes: []const u8) bool {
    assert(bytes.len > 0);

    resolver.directory.push(bytes) catch |err| switch (err) {
        error.Overflow => return false,
    };

    assert(resolver.directory.count() >= bytes.len);

    return true;
}

fn chain_holds(resolver: *const Resolver, target: Span) bool {
    assert(target.length <= std.math.maxInt(u32) - target.offset);

    const wanted = resolver.path_of(target);

    assert(wanted.len > 0);

    for (resolver.spans.const_slice()) |held| {
        if (std.mem.eql(u8, resolver.path_of(held), wanted)) return true;
    }

    return false;
}

fn extend_target(resolver: *Resolver, span: Span, relative: []const u8) Error!Span {
    if (relative.len == 0) return error.PathEmpty;
    if (relative.len > resolver.capacity.path_bytes_max) return error.PathTooLong;
    assert(span.length <= std.math.maxInt(u32) - span.offset);

    const base = path.directory_of(resolver.path_of(span));
    const parts: path.Join = .{ .base = base, .relative = relative };

    const joined_or = switch (resolver.options.extend_join) {
        .normalized => path.join(resolver.target, parts),
        .parents_kept => path.components_joined(resolver.target, parts),
    };

    const joined = joined_or catch |err| switch (err) {
        error.Overflow => return error.PathTooLong,
    };

    assert(joined <= resolver.target.len);

    return resolver.intern(resolver.target[0..joined]);
}

fn intern(resolver: *Resolver, bytes: []const u8) CapacityError!Span {
    assert(bytes.len > 0);

    const offset = resolver.paths.count();

    resolver.paths.push(bytes) catch |err| switch (err) {
        error.Overflow => return error.PathsExhausted,
    };

    const span: Span = .{ .offset = offset, .length = @intCast(bytes.len) };

    assert(span.end() == resolver.paths.count());

    return span;
}

fn file_read(resolver: *Resolver, io: std.Io, span: Span) Error!void {
    assert(span.length <= std.math.maxInt(u32) - span.offset);

    resolver.buffer.clear();
    resolver.failure = span;

    const file = try path.open(io, resolver.path_of(span));
    defer file.close(io);

    var reader_buffer: [read_buffer_bytes]u8 = undefined;
    var file_reader = file.reader(io, &reader_buffer);

    resolver.buffer.read_from(&file_reader.interface) catch |err| switch (err) {
        error.Overflow => return error.FileTooBig,
        error.ReadFailed => {
            const cause = file_reader.err orelse return error.Unexpected;
            return path.system_error_of(cause);
        },
    };

    if (!std.unicode.utf8ValidateSlice(resolver.buffer.const_slice())) return error.Utf8Invalid;

    resolver.failure = .empty;

    assert(resolver.buffer.count() <= resolver.buffer.capacity());
}

fn file_of(resolver: *const Resolver, span: Span) File {
    assert(span.length <= std.math.maxInt(u32) - span.offset);

    const file: File = .{ .path = resolver.path_of(span), .source = resolver.buffer.const_slice() };

    assert(file.path.len > 0);
    assert(file.source.len <= resolver.capacity.config_bytes_max);

    return file;
}

const Applied = enum { missing, read };

const Recorder = struct {
    gpa: std.mem.Allocator,
    sections: bool,
    sources: std.ArrayList([]u8),

    fn init(gpa: std.mem.Allocator, sections: bool) Recorder {
        return .{ .gpa = gpa, .sections = sections, .sources = .empty };
    }

    fn deinit(recorder: *Recorder) void {
        for (recorder.sources.items) |source| recorder.gpa.free(source);

        recorder.sources.deinit(recorder.gpa);
    }

    fn apply(recorder: *Recorder, file: File) std.mem.Allocator.Error!Applied {
        assert(file.path.len <= std.math.maxInt(u32));

        if (recorder.sections) {
            if (test_options.needs_section(file.path)) {
                if (!std.mem.startsWith(u8, file.source, "[tool.tool]")) return .missing;
            }
        }

        const copy = try recorder.gpa.dupe(u8, file.source);
        errdefer recorder.gpa.free(copy);

        try recorder.sources.append(recorder.gpa, copy);

        return .read;
    }

    fn expect_sources(recorder: *const Recorder, expected: []const []const u8) !void {
        try std.testing.expectEqual(expected.len, recorder.sources.items.len);

        for (expected, recorder.sources.items) |wanted, held| {
            try std.testing.expectEqualStrings(wanted, held);
        }
    }
};

const Tree = struct {
    root_bytes: [path_platform.path_bytes_max]u8,
    root_length: usize,
    tmp: std.testing.TmpDir,

    fn init(tree: *Tree) !void {
        tree.tmp = std.testing.tmpDir(.{});
        errdefer tree.tmp.cleanup();

        tree.root_length = try tree.tmp.dir.realPath(std.testing.io, &tree.root_bytes);
    }

    fn deinit(tree: *Tree) void {
        tree.tmp.cleanup();
    }

    fn bytes(tree: *const Tree, out: []u8, name: []const u8) ![]const u8 {
        assert(out.len <= std.math.maxInt(u32));
        assert(name.len <= std.math.maxInt(u32));

        return std.mem.print(out, "{s}/{s}", .{ tree.root_bytes[0..tree.root_length], name });
    }

    fn directory(tree: *const Tree, name: []const u8) !void {
        assert(name.len <= std.math.maxInt(u32));

        try tree.tmp.dir.createDirPath(std.testing.io, name);
    }

    fn seed(tree: *const Tree, name: []const u8, text: []const u8) !void {
        assert(name.len <= std.math.maxInt(u32));
        assert(text.len <= std.math.maxInt(u32));

        if (std.Io.Dir.path.dirname(name)) |parent| try tree.directory(parent);

        try tree.tmp.dir.writeFile(std.testing.io, .{ .sub_path = name, .data = text });
    }
};

const test_capacity: Capacity = .{
    .config_bytes_max = 1 << 12,
    .extend_depth_max = 4,
    .path_bytes_max = 256,
};

const test_options: Options = .{
    .file_names = &.{ "tool.toml", ".tool.toml", "pyproject.toml" },
    .section_file_name = "pyproject.toml",
};

const test_discovery_count_max = directory_depth_max * 3 + 1;

const Extended = union(enum) {
    absent,
    target: []const u8,
};

fn extend_line(out: []u8, source: []const u8) !Extended {
    assert(out.len <= std.math.maxInt(u32));
    assert(source.len <= std.math.maxInt(u32));

    var lines = std.mem.splitScalar(u8, source, '\n');

    for (0..source.len + 1) |_| {
        const line = lines.next() orelse break;
        if (!std.mem.startsWith(u8, line, extend_key)) continue;

        const rest = std.mem.trim(u8, line[extend_key.len..], &std.ascii.whitespace);
        const assigned = if (std.mem.startsWith(u8, rest, "=")) rest[1..] else "";
        const value = std.mem.trim(u8, assigned, &std.ascii.whitespace);
        if (value.len < 2) return error.Malformed;
        if (value[0] != '"') return error.Malformed;
        if (value[value.len - 1] != '"') return error.Malformed;

        const inner = value[1 .. value.len - 1];

        @memcpy(out[0..inner.len], inner);

        return .{ .target = out[0..inner.len] };
    }

    return .absent;
}

fn chain_collected(resolver: *Resolver, span: Span) !void {
    assert(span.length <= std.math.maxInt(u32) - span.offset);

    var chain: Chain = .init(resolver, std.testing.io, span);
    var relative: [path_platform.path_bytes_max]u8 = undefined;

    for (0..resolver.capacity.extend_depth_max) |_| {
        if (!chain.pending()) return;

        const file = try chain.next();

        switch (try extend_line(&relative, file.source)) {
            .absent => return,
            .target => |target| try chain.extend(target),
        }
    }
}

fn files_applied(resolver: *Resolver, recorder: *Recorder) !Applied {
    var files: Files = .init(resolver, std.testing.io);
    var read_any = false;
    const count = resolver.chain_count();

    for (0..count) |index| {
        const file = try files.next();

        switch (try recorder.apply(file)) {
            .read => read_any = true,
            .missing => {
                if (index + 1 == count) {
                    if (!read_any) return .missing;
                }
            },
        }
    }

    return .read;
}

fn loaded_from(resolver: *Resolver, span: Span, recorder: *Recorder) !Applied {
    assert(span.length <= std.math.maxInt(u32) - span.offset);

    try chain_collected(resolver, span);

    return files_applied(resolver, recorder);
}

fn discovered(resolver: *Resolver, directory: []const u8, recorder: *Recorder) !Applied {
    assert(directory.len <= std.math.maxInt(u32));

    resolver.clear();
    try resolver.discover_start(directory);

    for (0..test_discovery_count_max) |_| {
        const span = switch (try resolver.discover_next(std.testing.io)) {
            .absent => return .missing,
            .found => |config| config,
        };

        const applied = try loaded_from(resolver, span, recorder);
        if (applied != .missing) return applied;
    }

    unreachable;
}

fn loaded(resolver: *Resolver, file_path: []const u8, recorder: *Recorder) !Applied {
    assert(file_path.len <= std.math.maxInt(u32));

    resolver.clear();

    const span = try resolver.record(file_path);
    return loaded_from(resolver, span, recorder);
}

test Resolver {
    var tree: Tree = undefined;

    try tree.init();
    defer tree.deinit();

    try tree.seed("base.toml", "select = [\"GL\"]\n");
    try tree.seed("project/tool.toml", "extend = \"../base.toml\"\nselect = [\"HS\"]\n");

    var resolver = try Resolver.init(std.testing.allocator, test_capacity, test_options);
    defer resolver.deinit(std.testing.allocator);

    var start_buffer: [path_platform.path_bytes_max]u8 = undefined;
    const start = try tree.bytes(&start_buffer, "project");

    const config = switch (try resolver.discover(std.testing.io, start, .directory)) {
        .absent => return error.ConfigMissing,
        .found => |span| span,
    };

    var chain: Chain = .init(&resolver, std.testing.io, config);
    var relative: [path_platform.path_bytes_max]u8 = undefined;

    for (0..test_capacity.extend_depth_max) |_| {
        if (!chain.pending()) break;

        const file = try chain.next();

        switch (try extend_line(&relative, file.source)) {
            .absent => break,
            .target => |target| try chain.extend(target),
        }
    }

    var files: Files = .init(&resolver, std.testing.io);
    const base = try files.next();

    try std.testing.expectEqualStrings("select = [\"GL\"]\n", base.source);

    const project = try files.next();

    try std.testing.expect(std.mem.endsWith(u8, project.path, "tool.toml"));
    try std.testing.expectEqual(@as(u32, 0), files.remaining);
    try std.testing.expectEqual(@as(u32, 2), resolver.chain_count());
}

test "a relative walk climbs past the working directory" {
    var held = try Resolver.init(std.testing.allocator, test_capacity, test_options);
    defer held.deinit(std.testing.allocator);

    try held.discover_start("src/lex");

    try std.testing.expect(held.ascend());
    try std.testing.expectEqualStrings("src", held.directory.const_slice());
    try std.testing.expect(held.ascend());
    try std.testing.expectEqualStrings(".", held.directory.const_slice());
    try std.testing.expect(held.ascend());
    try std.testing.expectEqualStrings("..", held.directory.const_slice());
    try std.testing.expect(held.ascend());
    try std.testing.expectEqualStrings("../..", held.directory.const_slice());

    try held.discover_start("/a");

    try std.testing.expect(held.ascend());
    try std.testing.expectEqualStrings("/", held.directory.const_slice());
    try std.testing.expect(!held.ascend());
}

test "a relative start finds the working directory config" {
    const options: Options = .{ .file_names = &.{"build.zig"}, .section_file_name = null };
    var held = try Resolver.init(std.testing.allocator, test_capacity, options);
    defer held.deinit(std.testing.allocator);

    const config = switch (try held.discover(std.testing.io, "src/lex/rust.rs", .file)) {
        .absent => return error.TestUnexpectedResult,
        .found => |span| span,
    };

    try std.testing.expectEqualStrings("./build.zig", held.path_of(config));
}

test "discovery with no config file returns missing" {
    var tree: Tree = undefined;

    try tree.init();
    defer tree.deinit();

    var held = try Resolver.init(std.testing.allocator, test_capacity, test_options);
    defer held.deinit(std.testing.allocator);

    var recorder: Recorder = .init(std.testing.allocator, true);
    defer recorder.deinit();

    var start_buffer: [path_platform.path_bytes_max]u8 = undefined;
    const applied = try discovered(&held, try tree.bytes(&start_buffer, ""), &recorder);

    try std.testing.expectEqual(Applied.missing, applied);
    try std.testing.expectEqual(0, recorder.sources.items.len);
    try std.testing.expect(held.found() == null);
}

test "discovery walks up from the starting directory" {
    var tree: Tree = undefined;

    try tree.init();
    defer tree.deinit();

    try tree.seed("tool.toml", "select = [\"GL\"]\n");
    try tree.directory("a/b");

    var held = try Resolver.init(std.testing.allocator, test_capacity, test_options);
    defer held.deinit(std.testing.allocator);

    var recorder: Recorder = .init(std.testing.allocator, true);
    defer recorder.deinit();

    var start_buffer: [path_platform.path_bytes_max]u8 = undefined;
    var found_buffer: [path_platform.path_bytes_max]u8 = undefined;
    const applied = try discovered(&held, try tree.bytes(&start_buffer, "a/b"), &recorder);

    try std.testing.expectEqual(Applied.read, applied);
    try recorder.expect_sources(&.{"select = [\"GL\"]\n"});

    try std.testing.expectEqualStrings(
        try tree.bytes(&found_buffer, "tool.toml"),
        held.found() orelse return error.TestUnexpectedResult,
    );

    try std.testing.expectEqual(1, held.chain_count());
}

test "the nearest config wins and the first name beats the later ones" {
    var tree: Tree = undefined;

    try tree.init();
    defer tree.deinit();

    try tree.seed("tool.toml", "select = [\"GL\"]\n");
    try tree.seed("a/.tool.toml", "select = [\"HS\"]\n");
    try tree.seed("a/pyproject.toml", "[tool.tool]\nselect = [\"AL\"]\n");

    var held = try Resolver.init(std.testing.allocator, test_capacity, test_options);
    defer held.deinit(std.testing.allocator);

    var recorder: Recorder = .init(std.testing.allocator, true);
    defer recorder.deinit();

    var start_buffer: [path_platform.path_bytes_max]u8 = undefined;
    const applied = try discovered(&held, try tree.bytes(&start_buffer, "a"), &recorder);

    try std.testing.expectEqual(Applied.read, applied);
    try recorder.expect_sources(&.{"select = [\"HS\"]\n"});
}

test "a pyproject with no section does not stop the walk" {
    var tree: Tree = undefined;

    try tree.init();
    defer tree.deinit();

    try tree.seed("tool.toml", "select = [\"GL\"]\n");
    try tree.seed("a/pyproject.toml", "[tool.other]\nx = 1\n");

    var held = try Resolver.init(std.testing.allocator, test_capacity, test_options);
    defer held.deinit(std.testing.allocator);

    var recorder: Recorder = .init(std.testing.allocator, true);
    defer recorder.deinit();

    var start_buffer: [path_platform.path_bytes_max]u8 = undefined;
    const applied = try discovered(&held, try tree.bytes(&start_buffer, "a"), &recorder);

    try std.testing.expectEqual(Applied.read, applied);
    try recorder.expect_sources(&.{"select = [\"GL\"]\n"});
}

test "a trailing separator on the start directory is ignored" {
    var tree: Tree = undefined;

    try tree.init();
    defer tree.deinit();

    try tree.seed("tool.toml", "x = 1\n");

    var held = try Resolver.init(std.testing.allocator, test_capacity, test_options);
    defer held.deinit(std.testing.allocator);

    var recorder: Recorder = .init(std.testing.allocator, true);
    defer recorder.deinit();

    var start_buffer: [path_platform.path_bytes_max]u8 = undefined;
    const start = try tree.bytes(&start_buffer, "/");

    try std.testing.expectEqual(Applied.read, try discovered(&held, start, &recorder));
}

test "a missing config named explicitly is unreadable" {
    var tree: Tree = undefined;

    try tree.init();
    defer tree.deinit();

    var held = try Resolver.init(std.testing.allocator, test_capacity, test_options);
    defer held.deinit(std.testing.allocator);

    var recorder: Recorder = .init(std.testing.allocator, false);
    defer recorder.deinit();

    var file_buffer: [path_platform.path_bytes_max]u8 = undefined;
    const file_path = try tree.bytes(&file_buffer, "nope.toml");

    try std.testing.expectError(error.FileNotFound, loaded(&held, file_path, &recorder));
    try std.testing.expectEqualStrings(file_path, held.diagnostic());
}

test "a config that is not UTF-8 is unreadable and says why" {
    var tree: Tree = undefined;

    try tree.init();
    defer tree.deinit();

    try tree.seed("tool.toml", "name = \"\xff\xfe\"\n");

    var held = try Resolver.init(std.testing.allocator, test_capacity, test_options);
    defer held.deinit(std.testing.allocator);

    var recorder: Recorder = .init(std.testing.allocator, false);
    defer recorder.deinit();

    var file_buffer: [path_platform.path_bytes_max]u8 = undefined;
    const file_path = try tree.bytes(&file_buffer, "tool.toml");

    try std.testing.expectError(error.Utf8Invalid, loaded(&held, file_path, &recorder));
    try std.testing.expectEqualStrings(file_path, held.diagnostic());
    try std.testing.expectEqual(0, recorder.sources.items.len);
}

test "a config applies the one it extends first" {
    var tree: Tree = undefined;

    try tree.init();
    defer tree.deinit();

    try tree.seed("base.toml", "select = [\"GL\"]\n");
    try tree.seed("child/tool.toml", "extend = \"../base.toml\"\nselect = [\"HS\"]\n");

    var held = try Resolver.init(std.testing.allocator, test_capacity, test_options);
    defer held.deinit(std.testing.allocator);

    var recorder: Recorder = .init(std.testing.allocator, true);
    defer recorder.deinit();

    var start_buffer: [path_platform.path_bytes_max]u8 = undefined;
    var child_buffer: [path_platform.path_bytes_max]u8 = undefined;
    var base_buffer: [path_platform.path_bytes_max]u8 = undefined;
    const applied = try discovered(&held, try tree.bytes(&start_buffer, "child"), &recorder);

    try std.testing.expectEqual(Applied.read, applied);

    try recorder.expect_sources(&.{
        "select = [\"GL\"]\n",
        "extend = \"../base.toml\"\nselect = [\"HS\"]\n",
    });

    try std.testing.expectEqual(2, held.chain_count());

    try std.testing.expectEqualStrings(
        try tree.bytes(&child_buffer, "child/tool.toml"),
        held.chain_at(0),
    );

    try std.testing.expectEqualStrings(
        try tree.bytes(&base_buffer, "base.toml"),
        held.chain_at(1),
    );
}

test "a cycle in the extend chain is an error rather than a loop" {
    var tree: Tree = undefined;

    try tree.init();
    defer tree.deinit();

    try tree.seed("a.toml", "extend = \"b.toml\"\n");
    try tree.seed("b.toml", "extend = \"a.toml\"\n");

    var held = try Resolver.init(std.testing.allocator, test_capacity, test_options);
    defer held.deinit(std.testing.allocator);

    var recorder: Recorder = .init(std.testing.allocator, false);
    defer recorder.deinit();

    var file_buffer: [path_platform.path_bytes_max]u8 = undefined;
    const file_path = try tree.bytes(&file_buffer, "a.toml");

    try std.testing.expectError(error.ExtendCycle, loaded(&held, file_path, &recorder));
    try std.testing.expectEqual(0, recorder.sources.items.len);
}

test "a chain past the depth is refused" {
    var tree: Tree = undefined;

    try tree.init();
    defer tree.deinit();

    try tree.seed("a.toml", "extend = \"b.toml\"\n");
    try tree.seed("b.toml", "extend = \"c.toml\"\n");
    try tree.seed("c.toml", "extend = \"d.toml\"\n");
    try tree.seed("d.toml", "extend = \"e.toml\"\n");
    try tree.seed("e.toml", "x = 1\n");

    var held = try Resolver.init(std.testing.allocator, test_capacity, test_options);
    defer held.deinit(std.testing.allocator);

    var recorder: Recorder = .init(std.testing.allocator, false);
    defer recorder.deinit();

    var file_buffer: [path_platform.path_bytes_max]u8 = undefined;
    const file_path = try tree.bytes(&file_buffer, "a.toml");

    try std.testing.expectError(error.DepthExceeded, loaded(&held, file_path, &recorder));
}

test "a malformed extend stops the chain at the caller's fault" {
    var tree: Tree = undefined;

    try tree.init();
    defer tree.deinit();

    try tree.seed("a.toml", "extend = 3\n");

    var held = try Resolver.init(std.testing.allocator, test_capacity, test_options);
    defer held.deinit(std.testing.allocator);

    var recorder: Recorder = .init(std.testing.allocator, false);
    defer recorder.deinit();

    var file_buffer: [path_platform.path_bytes_max]u8 = undefined;
    const file_path = try tree.bytes(&file_buffer, "a.toml");

    try std.testing.expectError(error.Malformed, loaded(&held, file_path, &recorder));
    try std.testing.expectEqual(1, held.chain_count());
}

test "an extend naming a missing file is unreadable" {
    var tree: Tree = undefined;

    try tree.init();
    defer tree.deinit();

    try tree.seed("a.toml", "extend = \"gone.toml\"\n");

    var held = try Resolver.init(std.testing.allocator, test_capacity, test_options);
    defer held.deinit(std.testing.allocator);

    var recorder: Recorder = .init(std.testing.allocator, false);
    defer recorder.deinit();

    var file_buffer: [path_platform.path_bytes_max]u8 = undefined;
    var gone_buffer: [path_platform.path_bytes_max]u8 = undefined;
    const file_path = try tree.bytes(&file_buffer, "a.toml");

    try std.testing.expectError(error.FileNotFound, loaded(&held, file_path, &recorder));

    try std.testing.expectEqualStrings(
        try tree.bytes(&gone_buffer, "gone.toml"),
        held.diagnostic(),
    );
}

test "a config past the byte ceiling is too big" {
    var tree: Tree = undefined;

    try tree.init();
    defer tree.deinit();

    const line = "x = 1\n";
    var text: [line.len << 11]u8 = undefined;

    for (0..1 << 11) |index| {
        @memcpy(text[index * line.len ..][0..line.len], line);
    }

    try tree.seed("a.toml", &text);

    var held = try Resolver.init(std.testing.allocator, test_capacity, test_options);
    defer held.deinit(std.testing.allocator);

    var recorder: Recorder = .init(std.testing.allocator, false);
    defer recorder.deinit();

    var file_buffer: [path_platform.path_bytes_max]u8 = undefined;
    const file_path = try tree.bytes(&file_buffer, "a.toml");

    try std.testing.expectError(error.FileTooBig, loaded(&held, file_path, &recorder));
}

test "the files come base first and stop where the caller stops" {
    var tree: Tree = undefined;

    try tree.init();
    defer tree.deinit();

    try tree.seed("base.toml", "x = 1\n");
    try tree.seed("tool.toml", "extend = \"base.toml\"\n");

    var held = try Resolver.init(std.testing.allocator, test_capacity, test_options);
    defer held.deinit(std.testing.allocator);

    var start_buffer: [path_platform.path_bytes_max]u8 = undefined;
    var base_buffer: [path_platform.path_bytes_max]u8 = undefined;

    try held.discover_start(try tree.bytes(&start_buffer, ""));

    const config = switch (try held.discover_next(std.testing.io)) {
        .absent => return error.TestUnexpectedResult,
        .found => |span| span,
    };

    try chain_collected(&held, config);

    var files: Files = .init(&held, std.testing.io);
    const first = try files.next();

    try std.testing.expectEqualStrings(try tree.bytes(&base_buffer, "base.toml"), first.path);
    try std.testing.expectEqualStrings("x = 1\n", first.source);
    try std.testing.expectEqual(@as(u32, 1), files.remaining);
}

test "a discarded file ends the chain before it" {
    var tree: Tree = undefined;

    try tree.init();
    defer tree.deinit();

    try tree.seed("a.toml", "extend = \"b.toml\"\n");
    try tree.seed("b.toml", "extend = \"c.toml\"\n");

    var held = try Resolver.init(std.testing.allocator, test_capacity, test_options);
    defer held.deinit(std.testing.allocator);

    var file_buffer: [path_platform.path_bytes_max]u8 = undefined;
    const config = try held.record(try tree.bytes(&file_buffer, "a.toml"));
    var chain: Chain = .init(&held, std.testing.io, config);

    _ = try chain.next();

    try chain.extend("b.toml");
    _ = try chain.next();

    chain.discard();

    try std.testing.expect(!chain.pending());
    try std.testing.expectEqual(@as(u32, 1), held.chain_count());

    var files: Files = .init(&held, std.testing.io);
    const only = try files.next();

    try std.testing.expectEqualStrings("extend = \"b.toml\"\n", only.source);
    try std.testing.expectEqual(@as(u32, 0), files.remaining);
}

test "a path that cannot be recorded says why" {
    var held = try Resolver.init(std.testing.allocator, .{
        .config_bytes_max = 1 << 12,
        .extend_depth_max = 1,
        .path_bytes_max = 8,
    }, test_options);

    defer held.deinit(std.testing.allocator);

    try std.testing.expectError(error.PathEmpty, held.record(""));
    try std.testing.expectError(error.PathTooLong, held.record("123456789"));

    _ = try held.record("12345678");
    _ = try held.record("12345678");

    try std.testing.expectError(error.PathsExhausted, held.record("1"));

    held.clear();

    const span = try held.record("a.toml");

    try std.testing.expectEqualStrings("a.toml", held.path_of(span));
}

test "a start directory past the path bound is refused rather than missed" {
    var held = try Resolver.init(std.testing.allocator, .{
        .config_bytes_max = 1 << 12,
        .extend_depth_max = 1,
        .path_bytes_max = 8,
    }, test_options);

    defer held.deinit(std.testing.allocator);

    const refused = held.discover(std.testing.io, "abcdefghijk", .directory);

    try std.testing.expectError(error.PathTooLong, refused);
}

test "an empty extend names no file" {
    var tree: Tree = undefined;

    try tree.init();
    defer tree.deinit();

    try tree.seed("a.toml", "extend = \"\"\n");

    var held = try Resolver.init(std.testing.allocator, test_capacity, test_options);
    defer held.deinit(std.testing.allocator);

    var file_buffer: [path_platform.path_bytes_max]u8 = undefined;
    const config = try held.record(try tree.bytes(&file_buffer, "a.toml"));
    var chain: Chain = .init(&held, std.testing.io, config);
    var relative: [path_platform.path_bytes_max]u8 = undefined;
    const file = try chain.next();

    const target = switch (try extend_line(&relative, file.source)) {
        .absent => return error.TestUnexpectedResult,
        .target => |held_target| held_target,
    };

    try std.testing.expectEqual(@as(usize, 0), target.len);
    try std.testing.expectError(error.PathEmpty, chain.extend(target));
}

test "a section file is recognised by its last segment only" {
    try std.testing.expect(test_options.needs_section("pyproject.toml"));
    try std.testing.expect(test_options.needs_section("/a/b/pyproject.toml"));
    try std.testing.expect(!test_options.needs_section("/a/b/mypyproject.toml"));
    try std.testing.expect(!test_options.needs_section("/a/b/pyproject.toml.bak"));
}

test "discover starts from the directory of a file unless rooted" {
    var tree: Tree = undefined;

    try tree.init();
    defer tree.deinit();

    try tree.seed("tool.toml", "x = 1\n");
    try tree.seed("a/b/main.rs", "");

    var held = try Resolver.init(std.testing.allocator, test_capacity, test_options);
    defer held.deinit(std.testing.allocator);

    var start_buffer: [path_platform.path_bytes_max]u8 = undefined;
    var expected_buffer: [path_platform.path_bytes_max]u8 = undefined;
    const expected = try tree.bytes(&expected_buffer, "tool.toml");
    const file = try tree.bytes(&start_buffer, "a/b/main.rs");

    const from_file = switch (try held.discover(std.testing.io, file, .file)) {
        .absent => return error.TestUnexpectedResult,
        .found => |span| span,
    };

    try std.testing.expectEqualStrings(expected, held.path_of(from_file));

    const directory = try tree.bytes(&start_buffer, "a/b");

    const rooted = switch (try held.discover(std.testing.io, directory, .directory)) {
        .absent => return error.TestUnexpectedResult,
        .found => |span| span,
    };

    try std.testing.expectEqualStrings(expected, held.path_of(rooted));
}

test "a config extended through extend applies the base first" {
    var tree: Tree = undefined;

    try tree.init();
    defer tree.deinit();

    try tree.seed("base.toml", "select = [\"GL\"]\n");
    try tree.seed("child/tool.toml", "extend = \"../base.toml\"\n");

    var held = try Resolver.init(std.testing.allocator, test_capacity, test_options);
    defer held.deinit(std.testing.allocator);

    var recorder: Recorder = .init(std.testing.allocator, false);
    defer recorder.deinit();

    var start_buffer: [path_platform.path_bytes_max]u8 = undefined;
    const start = try tree.bytes(&start_buffer, "child");

    const config = switch (try held.discover(std.testing.io, start, .directory)) {
        .absent => return error.TestUnexpectedResult,
        .found => |span| span,
    };

    var chain: Chain = .init(&held, std.testing.io, config);
    var relative: [path_platform.path_bytes_max]u8 = undefined;

    for (0..test_capacity.extend_depth_max) |_| {
        if (!chain.pending()) break;

        const file = try chain.next();

        switch (try extend_line(&relative, file.source)) {
            .absent => break,
            .target => |target| try chain.extend(target),
        }
    }

    try std.testing.expectEqual(Applied.read, try files_applied(&held, &recorder));
    try std.testing.expectEqual(2, recorder.sources.items.len);
    try std.testing.expectEqualStrings("select = [\"GL\"]\n", recorder.sources.items[0]);
}

test "a kept-parents join keeps each parent step and drops the current one" {
    var target: [64]u8 = undefined;
    const parts: path.Join = .{ .base = "/a/b", .relative = "./../c//d.toml" };
    const length = try path.components_joined(&target, parts);
    const windows = builtin.target.os.tag == .windows;
    const expected = if (windows) "\\a\\b\\..\\c\\d.toml" else "/a/b/../c/d.toml";

    try std.testing.expectEqualStrings(expected, target[0..length]);
}
