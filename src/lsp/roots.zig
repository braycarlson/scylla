const std = @import("std");
const assert = std.debug.assert;
const bounded = @import("../stdx/bounded.zig");
const json = @import("json");
const path_module = @import("../platform/path.zig");
const protocol = @import("protocol.zig");
const uri = @import("../platform/uri.zig");
const ArrayType = bounded.ArrayType;
const Buffer = bounded.Buffer;
const Document = json.Document;
const Node = json.Node;

pub const Roots = struct {
    arena: Buffer,
    list: ArrayType([]const u8),
    path: Buffer,

    pub const Capacity = struct {
        path_bytes_max: u32,
        root_count_max: u32,
    };

    pub const CapacityError = error{Overflow};
    pub const Error = CapacityError || InputError;
    pub const InputError = error{Empty};

    pub fn init(gpa: std.mem.Allocator, capacity: Capacity) std.mem.Allocator.Error!Roots {
        assert(capacity.root_count_max > 0);
        assert(capacity.path_bytes_max > 0);

        var arena: Buffer = try .init(gpa, capacity.root_count_max * capacity.path_bytes_max);
        errdefer arena.deinit(gpa);

        var list: ArrayType([]const u8) = try .init(gpa, capacity.root_count_max);
        errdefer list.deinit(gpa);

        const path = try Buffer.init(gpa, capacity.path_bytes_max);

        assert(list.empty());
        assert(path.capacity() == capacity.path_bytes_max);

        return .{ .arena = arena, .list = list, .path = path };
    }

    pub fn deinit(roots: *Roots, gpa: std.mem.Allocator) void {
        assert(roots.path.capacity() > 0);

        roots.path.deinit(gpa);
        roots.list.deinit(gpa);
        roots.arena.deinit(gpa);
        roots.* = undefined;
    }

    pub fn at(roots: *const Roots, index: u32) []const u8 {
        assert(index < roots.count());

        return roots.list.get(index);
    }

    pub fn clear(roots: *Roots) void {
        roots.list.clear();
        roots.arena.clear();

        assert(roots.count() == 0);
    }

    pub fn count(roots: *const Roots) u32 {
        return roots.list.count();
    }

    pub fn deepest(roots: *const Roots, held: []const u8) ?u32 {
        assert(held.len <= std.math.maxInt(u32));

        var found: ?u32 = null;
        var root_length: usize = 0;

        for (0..roots.count()) |index| {
            const root = roots.at(@intCast(index));
            if (root.len < root_length) continue;
            if (!path_module.contains(.{ .directory = root, .path = held })) continue;

            found = @intCast(index);
            root_length = root.len;
        }

        if (found) |position| assert(position < roots.count());

        return found;
    }

    pub fn full(roots: *const Roots) bool {
        return roots.list.full();
    }

    pub fn index_of(roots: *const Roots, root: []const u8) ?u32 {
        assert(root.len <= std.math.maxInt(u32));

        for (roots.slice(), 0..) |held, index| {
            if (!std.mem.eql(u8, held, root)) continue;

            assert(index < roots.count());

            return @intCast(index);
        }

        return null;
    }

    pub fn push(roots: *Roots, root: []const u8) Error!void {
        assert(root.len <= std.math.maxInt(u32));

        if (root.len == 0) return error.Empty;
        if (roots.list.full()) return error.Overflow;

        const span = try roots.arena.intern(root);

        roots.list.push(roots.arena.slice_of(span));

        assert(std.mem.eql(u8, roots.at(roots.count() - 1), root));
    }

    pub fn read(roots: *Roots, document: *const Document, params: Node) Error!void {
        assert(@backingInt(params) < document.node_count);

        var failure: ?Error = null;

        if (!roots.read_folders(document, params, &failure)) {
            roots.read_root(document, params, &failure);
        }

        if (failure) |err| return err;
    }

    pub fn record(roots: *Roots, root: []const u8) Error!void {
        assert(root.len <= std.math.maxInt(u32));

        const held = path_module.trimmed(root);
        if (held.len == 0) return error.Empty;
        if (roots.index_of(held) != null) return;
        if (roots.list.full()) return error.Overflow;

        const span = try roots.arena.intern(held);

        roots.list.push(roots.arena.slice_of(span));

        assert(std.mem.eql(u8, roots.at(roots.count() - 1), held));
    }

    pub fn remove(roots: *Roots, root: []const u8) bool {
        assert(root.len <= std.math.maxInt(u32));

        const index = roots.index_of(root) orelse return false;
        const removed = roots.at(index);
        const arena_start = @intFromPtr(roots.arena.const_slice().ptr);
        const start: u32 = @intCast(@intFromPtr(removed.ptr) - arena_start);
        const gap: u32 = @intCast(removed.len);

        assert(start + gap <= roots.arena.count());

        roots.arena.splice(.between(start, start + gap), "") catch |err| switch (err) {
            error.Overflow => unreachable,
        };

        roots.list.shift_tail(.{ .from = index + 1, .to = index });

        for (roots.list.slice()[index..]) |*held| {
            const moved: u32 = @intCast(@intFromPtr(held.ptr) - arena_start - gap);

            held.* = roots.arena.const_slice()[moved..][0..held.len];
        }

        assert(roots.index_of(root) == null);

        return true;
    }

    pub fn slice(roots: *const Roots) []const []const u8 {
        return roots.list.const_slice();
    }

    fn path_of_uri(roots: *Roots, document: *const Document, held: Node) bool {
        assert(@backingInt(held) < document.node_count);

        const text = document.text_of(held) orelse return false;

        uri.decode(&roots.path, text) catch |err| switch (err) {
            error.Overflow, error.SchemeNotFile => return false,
        };

        assert(roots.path.count() <= roots.path.capacity());

        return true;
    }

    fn read_folders(roots: *Roots, document: *const Document, params: Node, failure: *?Error) bool {
        assert(@backingInt(params) < document.node_count);

        const folders = document.member(params, "workspaceFolders") orelse return false;
        if (document.kind_of(folders) != .array) return false;

        var named = false;
        var walk = document.items(folders);

        for (0..protocol.change_count_max) |_| {
            const folder = walk.next() orelse break;
            const held = document.member(folder, "uri") orelse continue;
            if (!roots.path_of_uri(document, held)) continue;

            named = true;

            roots.record_kept(failure);
        }

        return named;
    }

    fn read_root(roots: *Roots, document: *const Document, params: Node, failure: *?Error) void {
        assert(@backingInt(params) < document.node_count);

        if (document.member(params, "rootUri")) |held| {
            if (roots.path_of_uri(document, held)) return roots.record_kept(failure);
        }

        const root_path = document.member(params, "rootPath") orelse return;
        const text = document.text_of(root_path) orelse return;

        roots.path.clear();

        roots.path.push(text) catch |err| switch (err) {
            error.Overflow => return,
        };

        roots.record_kept(failure);
    }

    fn record_kept(roots: *Roots, failure: *?Error) void {
        const prior_count = roots.count();

        assert(roots.path.count() <= roots.path.capacity());

        roots.record(roots.path.const_slice()) catch |err| {
            assert(roots.count() == prior_count);

            if (failure.* == null) failure.* = err;

            return;
        };

        assert(roots.count() >= prior_count);
    }
};

const test_initialize =
    \\{"rootUri":"file:///root","rootPath":"/root","workspaceFolders":[{"uri":
++
    \\"file:///one%20two"},{"name":"x"},{"uri":"file:///three"}],"capabilities":
++
    \\{"general":{"positionEncodings":["utf-16",7,"utf-8"]}}}
;

const TestDocument = json.DocumentType(.{ .node_count_max = 64, .text_bytes_max = 256 });

fn test_root(document: *TestDocument, message: []const u8) !Node {
    assert(message.len <= std.math.maxInt(u32));

    try document.parse(message);

    return document.root();
}

test Roots {
    var document: json.DocumentType(.{ .node_count_max = 16, .text_bytes_max = 64 }) = undefined;

    var roots: Roots = try .init(std.testing.allocator, .{
        .path_bytes_max = 64,
        .root_count_max = 4,
    });

    defer roots.deinit(std.testing.allocator);

    try document.parse("{\"workspaceFolders\":[{\"uri\":\"file:///home/one\"}]}");
    try roots.read(&document.base, document.root());

    try std.testing.expectEqual(1, roots.count());
    try std.testing.expectEqualStrings("/home/one", roots.at(0));
    try std.testing.expectEqual(@as(?u32, 0), roots.deepest("/home/one/a.zig"));
}

test "workspace folders win over the root uri and path" {
    const gpa = std.testing.allocator;
    var document: TestDocument = undefined;
    var roots: Roots = try .init(gpa, .{ .path_bytes_max = 64, .root_count_max = 4 });
    defer roots.deinit(gpa);

    try roots.read(&document.base, try test_root(&document, test_initialize));
    try std.testing.expectEqual(@as(u32, 2), roots.count());
    try std.testing.expectEqualStrings("/one two", roots.at(0));
    try std.testing.expectEqualStrings("/three", roots.at(1));

    roots.clear();

    const uri_params = try test_root(&document, "{\"rootUri\":\"file:///r/\",\"rootPath\":\"/p\"}");

    try roots.read(&document.base, uri_params);
    try std.testing.expectEqual(@as(u32, 1), roots.count());
    try std.testing.expectEqualStrings("/r", roots.at(0));

    roots.clear();

    const path_params = try test_root(&document, "{\"rootUri\":null,\"rootPath\":\"/p/q\"}");

    try roots.read(&document.base, path_params);
    try std.testing.expectEqual(@as(u32, 1), roots.count());
    try std.testing.expectEqualStrings("/p/q", roots.at(0));

    roots.clear();

    const escaped_params = try test_root(&document, "{\"rootUri\":\"file:\\/\\/\\/r\\/s\"}");

    try roots.read(&document.base, escaped_params);
    try std.testing.expectEqual(@as(u32, 1), roots.count());
    try std.testing.expectEqualStrings("/r/s", roots.at(0));
}

test "a read records every root that fits and reports the first it dropped" {
    const gpa = std.testing.allocator;
    var document: TestDocument = undefined;
    var roots: Roots = try .init(gpa, .{ .path_bytes_max = 64, .root_count_max = 1 });
    defer roots.deinit(gpa);

    const params = try test_root(&document, test_initialize);

    try std.testing.expectError(error.Overflow, roots.read(&document.base, params));
    try std.testing.expectEqual(@as(u32, 1), roots.count());
    try std.testing.expectEqualStrings("/one two", roots.at(0));
}

test "the deepest root holding a path is found" {
    var roots: Roots = try .init(std.testing.allocator, .{
        .path_bytes_max = 32,
        .root_count_max = 4,
    });

    defer roots.deinit(std.testing.allocator);

    try roots.record("/home");
    try roots.record("/home/one/");
    try roots.record("/home/one");
    try std.testing.expectError(error.Empty, roots.record(""));
    try std.testing.expectEqual(@as(u32, 2), roots.count());
    try std.testing.expectEqual(@as(?u32, 1), roots.deepest("/home/one/a.rs"));
    try std.testing.expectEqual(@as(?u32, 1), roots.deepest("/home/one"));
    try std.testing.expectEqual(@as(?u32, 0), roots.deepest("/home/oneself/a.rs"));
    try std.testing.expectEqual(@as(?u32, null), roots.deepest("/homeless"));
    try std.testing.expectEqual(@as(?u32, null), roots.deepest("/tmp/a.rs"));
}

test "a full root table refuses the next root" {
    const gpa = std.testing.allocator;
    var roots: Roots = try .init(gpa, .{ .path_bytes_max = 8, .root_count_max = 2 });
    defer roots.deinit(gpa);

    try roots.record("/a");
    try roots.record("/b");
    try std.testing.expectError(error.Overflow, roots.record("/c"));
    try roots.record("/a");
    try std.testing.expectEqual(@as(u32, 2), roots.count());

    var narrow: Roots = try .init(gpa, .{ .path_bytes_max = 4, .root_count_max = 4 });
    defer narrow.deinit(gpa);

    try narrow.record("/aaaaaaaaaaa");
    try std.testing.expectError(error.Overflow, narrow.record("/bbbbbbbbbbb"));
    try std.testing.expectEqual(@as(u32, 1), narrow.count());
}

test "a root is removed and the ones after it keep their bytes" {
    const gpa = std.testing.allocator;
    var roots: Roots = try .init(gpa, .{ .path_bytes_max = 16, .root_count_max = 4 });
    defer roots.deinit(gpa);

    try roots.record("/a");
    try roots.record("/bb");
    try roots.record("/ccc");
    const removed = roots.remove("/bb");
    const removed_again = roots.remove("/bb");

    try std.testing.expect(removed);
    try std.testing.expect(!removed_again);
    try std.testing.expectEqual(@as(u32, 2), roots.count());
    try std.testing.expectEqualStrings("/a", roots.slice()[0]);
    try std.testing.expectEqualStrings("/ccc", roots.slice()[1]);
    try std.testing.expectEqual(@as(u32, 6), roots.arena.count());

    try roots.record("/dddd");
    try std.testing.expectEqualStrings("/dddd", roots.at(2));
    const removed_first = roots.remove("/a");

    try std.testing.expect(removed_first);
    try std.testing.expectEqualStrings("/ccc", roots.at(0));
    try std.testing.expectEqualStrings("/dddd", roots.at(1));
    try std.testing.expectEqual(@as(?u32, 1), roots.index_of("/dddd"));
}

test "a push keeps a repeated root where a record folds it" {
    const gpa = std.testing.allocator;
    var roots: Roots = try .init(gpa, .{ .path_bytes_max = 8, .root_count_max = 3 });
    defer roots.deinit(gpa);

    try roots.push("/a");
    try roots.push("/a");
    try roots.record("/a/");
    try std.testing.expectEqual(@as(u32, 2), roots.count());
    try std.testing.expectEqualStrings("/a", roots.at(1));
    try std.testing.expectError(error.Empty, roots.push(""));

    try roots.push("/b");
    try std.testing.expectError(error.Overflow, roots.push("/c"));
}
