const std = @import("std");
const assert = std.debug.assert;
const builtin = @import("builtin");
const log = @import("../../stdx/log.zig");
const expect = std.testing.expect;
const expectEqualStrings = std.testing.expectEqualStrings;
pub const Platform = enum { posix, windows };
pub const platform_native: Platform = if (builtin.target.os.tag == .windows) .windows else .posix;
pub const CapacityError = error{Overflow};

pub const Join = struct {
    base: []const u8,
    relative: []const u8,
};

pub const Push = struct {
    base: []const u8,
    name: []const u8,
};

pub const Under = struct {
    directory: []const u8,
    path: []const u8,
};

const Segment = struct {
    offset: u32,
    text: []const u8,
};

const Verbatim = struct {
    prefix: []const u8,
    skipped: u32,
};

pub const path_bytes_max: u32 = 1 << 10;
pub const separator: u8 = '/';
const native = PathType(platform_native);
const verbatim = "\\\\?\\";
const verbatim_device = "\\\\.\\";
const verbatim_share = "\\\\?\\UNC\\";

pub fn PathType(comptime platform: Platform) type {
    return struct {
        pub const Segments = struct {
            held: []const u8,
            offset: u32,
            remaining: u32,

            pub fn next(iterator: *Segments) ?[]const u8 {
                const segment = iterator.next_positioned() orelse return null;

                assert(segment.text.len > 0);

                return segment.text;
            }

            fn next_positioned(iterator: *Segments) ?Segment {
                assert(iterator.held.len <= std.math.maxInt(u32));
                assert(iterator.remaining <= segment_count_max(iterator.held));

                if (iterator.remaining == 0) return null;

                for (0..iterator.held.len + 2) |_| {
                    if (iterator.offset > iterator.held.len) return null;

                    const start = iterator.offset;
                    const end = separator_after(iterator.held, start);

                    iterator.offset = end + 1;

                    if (end > start) {
                        iterator.remaining -= 1;

                        return .{ .offset = start, .text = iterator.held[start..end] };
                    }
                }

                unreachable;
            }
        };

        const separators = if (platform == .windows) "/\\" else "/";

        pub fn order(left: []const u8, right: []const u8) std.math.Order {
            assert(left.len <= std.math.maxInt(u32));
            assert(right.len <= std.math.maxInt(u32));

            var lefts: Components = .of(left);
            var rights: Components = .of(right);

            for (0..left.len + right.len + 2) |_| {
                const left_next = lefts.next();
                const right_next = rights.next();
                const held_left = left_next orelse return if (right_next == null) .eq else .lt;
                const held_right = right_next orelse return .gt;
                const rank = std.math.order(held_left.kind.rank(), held_right.kind.rank());

                if (rank != .eq) return rank;

                const text = std.mem.order(u8, held_left.text, held_right.text);

                if (text != .eq) return text;
            }

            unreachable;
        }

        pub fn is_separator(byte: u8) bool {
            if (byte == separator) return true;
            if (platform == .windows) return byte == '\\';
            return false;
        }

        pub fn is_absolute(held: []const u8) bool {
            if (held.len == 0) return false;
            if (is_separator(held[0])) return true;
            if (platform == .posix) return false;
            if (held.len < 2) return false;
            return std.ascii.isAlphabetic(held[0]) and held[1] == ':';
        }

        pub fn directory_of(held: []const u8) []const u8 {
            assert(held.len <= std.math.maxInt(u32));

            const root = root_end(held);

            assert(root <= held.len);

            for (0..held.len - root) |step| {
                const index = held.len - 1 - step;
                if (is_separator(held[index])) return held[0..index];
            }

            if (root > 0) return held[0..root];
            return ".";
        }

        pub fn trimmed(held: []const u8) []const u8 {
            assert(held.len <= std.math.maxInt(u32));

            const root = root_end(held);
            var end = held.len;

            assert(root <= held.len);

            for (0..held.len - root) |_| {
                if (!is_separator(held[end - 1])) break;

                end -= 1;
            }

            assert(end >= root);

            return held[0..end];
        }

        pub fn join(target: []u8, parts: Join) CapacityError!u32 {
            assert(target.len <= std.math.maxInt(u32));
            assert(parts.base.len <= std.math.maxInt(u32));

            if (is_absolute(parts.relative)) return written(target, 0, parts.relative);

            var length = try written(target, 0, trimmed(parts.base));
            var pieces = std.mem.splitAny(u8, parts.relative, separators);

            for (0..parts.relative.len + 1) |_| {
                const part = pieces.next() orelse break;
                if (part.len == 0) continue;
                if (std.mem.eql(u8, part, ".")) continue;

                if (std.mem.eql(u8, part, "..")) {
                    length = parent_end(target[0..length]);

                    continue;
                }

                length = try part_appended(target, length, part);
            }

            assert(length <= target.len);

            return length;
        }

        pub fn popped(held: []const u8) ?[]const u8 {
            assert(held.len <= std.math.maxInt(u32));

            const shape = shape_of(held);
            const end = body_trimmed(held, shape, @intCast(held.len));

            assert(end >= shape.body);

            if (end == shape.body) {
                if (!shape.current) return null;
                return held[0..shape.rooted];
            }

            const start = component_start(held, shape, end);
            const parent = body_trimmed(held, shape, start);

            assert(parent <= start);
            assert(parent >= shape.body);

            return held[0..parent];
        }

        pub fn pushed(target: []u8, parts: Push) CapacityError!u32 {
            assert(target.len <= std.math.maxInt(u32));
            assert(parts.base.len <= std.math.maxInt(u32));

            const base = parts.base;
            const name = parts.name;

            assert(name.len > 0);
            assert(!is_absolute(name));

            var length = try written(target, 0, base);
            const drive_only = platform == .windows and base.len == 2 and base[1] == ':';
            const open = base.len > 0 and !is_separator(base[base.len - 1]);

            if (open) {
                if (!drive_only) length = try written(target, length, &.{separator_native});
            }

            length = try written(target, length, name);

            assert(length == base.len + name.len or length == base.len + name.len + 1);

            return length;
        }

        pub fn components_joined(target: []u8, parts: Join) CapacityError!u32 {
            assert(target.len <= std.math.maxInt(u32));
            assert(parts.base.len <= std.math.maxInt(u32));

            var joined_bytes: [path_bytes_max * 2]u8 = undefined;
            var joined: Assembled = .{ .target = &joined_bytes, .length = 0 };

            try joined.appended(parts.base);
            try joined.path_pushed(parts.relative);

            var collected: Assembled = .{ .target = target, .length = 0 };
            var components: Components = .of(joined.held());

            for (0..joined.length + 2) |_| {
                const component = components.next() orelse break;

                try collected.path_pushed(component.text);
            } else unreachable;

            assert(collected.length <= target.len);

            return collected.length;
        }

        fn parent_of(held: []const u8) []const u8 {
            assert(held.len <= std.math.maxInt(u32));

            const end = parent_end(held);

            assert(end <= held.len);

            return held[0..end];
        }

        pub fn segments(held: []const u8) Segments {
            assert(held.len <= std.math.maxInt(u32));

            return .{ .held = held, .offset = 0, .remaining = segment_count_max(held) };
        }

        fn segments_positioned(held: []const u8) Segments {
            assert(held.len <= std.math.maxInt(u32));

            return segments(held);
        }

        pub fn file_name(held: []const u8) []const u8 {
            assert(held.len <= std.math.maxInt(u32));

            var iterator = segments(held);
            var name: []const u8 = "";

            for (0..held.len + 1) |_| {
                name = iterator.next() orelse break;
            }

            assert(name.len <= held.len);

            return name;
        }

        pub fn contains(under: Under) bool {
            assert(under.directory.len <= std.math.maxInt(u32));

            const prefix = trimmed(under.directory);
            const held = under.path;

            assert(prefix.len <= under.directory.len);

            if (prefix.len == 0) return true;
            if (!std.mem.startsWith(u8, held, prefix)) return false;

            assert(held.len >= prefix.len);

            if (prefix.len == root_end(prefix)) return true;

            const rest = held[prefix.len..];
            if (rest.len == 0) return true;
            return is_separator(rest[0]);
        }

        pub fn relative_into(out: []u8, under: Under) CapacityError!u32 {
            assert(out.len <= std.math.maxInt(u32));
            assert(under.directory.len <= std.math.maxInt(u32));

            const prefix = trimmed(under.directory);
            const held = under.path;
            var rest = held;

            if (prefix.len > 0) {
                if (contains(.{ .directory = prefix, .path = held })) {
                    rest = std.mem.trimStart(u8, held[prefix.len..], separators);
                }
            }

            assert(rest.len <= held.len);

            return written(out, 0, rest);
        }

        pub fn normalised_into(out: []u8, held: []const u8) CapacityError!u32 {
            assert(out.len <= std.math.maxInt(u32));
            assert(held.len <= std.math.maxInt(u32));

            const floor = root_end(held);
            const absolute = floor > 0;
            var length = try written(out, 0, held[0..floor]);
            var parts = std.mem.splitAny(u8, held[floor..], separators);

            for (0..held.len + 1) |_| {
                const part = parts.next() orelse break;
                if (part.len == 0) continue;
                if (std.mem.eql(u8, part, ".")) continue;

                if (std.mem.eql(u8, part, "..")) {
                    if (normalised_folds(out[0..length], floor)) {
                        length = parent_end(out[0..length]);

                        continue;
                    }

                    if (absolute) continue;
                }

                length = try part_appended(out, length, part);
            }

            assert(length >= floor);
            assert(length <= out.len);

            return length;
        }

        fn longest_prefix(roots: []const []const u8, held: []const u8) ?u32 {
            assert(roots.len <= std.math.maxInt(u32));
            assert(held.len <= std.math.maxInt(u32));

            var found: ?u32 = null;
            var length: usize = 0;

            for (roots, 0..) |root, index| {
                const longer = found == null or root.len > length;

                if (longer) {
                    if (contains(.{ .directory = root, .path = held })) {
                        found = @intCast(index);
                        length = root.len;
                    }
                }
            }

            if (found) |index| assert(index < roots.len);

            return found;
        }

        pub fn path_of(bytes: []const u8) ?[]const u8 {
            if (bytes.len > path_bytes_max) return null;

            if (platform == .windows) {
                if (!std.unicode.utf8ValidateSlice(bytes)) return null;
            }

            assert(bytes.len <= path_bytes_max);

            return bytes;
        }

        fn name_bytes(name: []const u8) ?[]const u8 {
            assert(name.len <= std.math.maxInt(u32));

            if (platform == .windows) {
                if (!std.unicode.utf8ValidateSlice(name)) return null;
            }

            return name;
        }

        fn name_bytes_or_empty(name: []const u8) []const u8 {
            assert(name.len <= std.math.maxInt(u32));

            const bytes = name_bytes(name) orelse {
                log.line("a path this platform cannot spell as text is read as empty", .{});

                return "";
            };

            assert(bytes.len == name.len);

            return bytes;
        }

        fn named(bytes: []const u8) []const u8 {
            assert(bytes.len <= std.math.maxInt(u32));

            const held = path_of(bytes) orelse {
                log.line("a path that is not valid text is opened as empty", .{});

                return "";
            };

            assert(held.len <= path_bytes_max);

            return held;
        }

        fn verbatim_of(bytes: []const u8) ?Verbatim {
            if (std.mem.startsWith(u8, bytes, verbatim)) return null;
            if (std.mem.startsWith(u8, bytes, verbatim_device)) return null;

            if (is_share(bytes)) {
                if (!is_plain(bytes, 2)) return null;
                return .{ .prefix = verbatim_share, .skipped = 2 };
            }

            if (is_qualified(bytes)) {
                if (!is_plain(bytes, 0)) return null;
                return .{ .prefix = verbatim, .skipped = 0 };
            }

            return null;
        }

        fn is_plain(bytes: []const u8, from: u32) bool {
            assert(from <= bytes.len);

            var start: usize = from;

            for (from..bytes.len + 1) |index| {
                if (index < bytes.len) {
                    if (!is_separator(bytes[index])) continue;
                }

                const component = bytes[start..index];
                if (component.len == 0) return false;
                if (std.mem.eql(u8, component, ".")) return false;
                if (std.mem.eql(u8, component, "..")) return false;

                start = index + 1;
            }

            assert(start > from);

            return true;
        }

        fn is_qualified(bytes: []const u8) bool {
            if (bytes.len < 3) return false;
            if (!std.ascii.isAlphabetic(bytes[0])) return false;
            if (bytes[1] != ':') return false;
            return is_separator(bytes[2]);
        }

        fn is_share(bytes: []const u8) bool {
            if (bytes.len < 3) return false;
            if (!is_separator(bytes[0])) return false;
            if (!is_separator(bytes[1])) return false;
            return !is_separator(bytes[2]);
        }

        fn normalised_folds(held: []const u8, floor: u32) bool {
            assert(floor <= held.len);

            if (held.len <= floor) return false;
            return !std.mem.eql(u8, file_name(held), "..");
        }

        fn parent_end(held: []const u8) u32 {
            assert(held.len <= std.math.maxInt(u32));

            const root = root_end(held);

            assert(root <= held.len);

            for (0..held.len - root) |step| {
                const index = held.len - 1 - step;

                if (is_separator(held[index])) {
                    assert(index < std.math.maxInt(u32));

                    return @intCast(index);
                }
            }

            return root;
        }

        fn part_appended(target: []u8, length: u32, part: []const u8) error{Overflow}!u32 {
            assert(part.len > 0);
            assert(length <= target.len);

            var end = length;

            if (end > 0) {
                if (!is_separator(target[end - 1])) {
                    if (end >= target.len) return error.Overflow;

                    target[end] = separator;
                    end += 1;
                }
            }

            return written(target, end, part);
        }

        const Shape = struct {
            rooted: u32,
            body: u32,
            current: bool,
            verbatim: bool,
        };

        const Prefix = struct {
            end: u32,
            disk: bool,
            verbatim: bool,
        };

        pub const Component = struct {
            kind: Kind,
            text: []const u8,

            pub const Kind = enum {
                current,
                normal,
                parent,
                prefix,
                root,

                pub fn rank(kind: Kind) u8 {
                    return switch (kind) {
                        .prefix => 0,
                        .root => 1,
                        .current => 2,
                        .parent => 3,
                        .normal => 4,
                    };
                }
            };
        };

        pub const Components = struct {
            held: []const u8,
            offset: u32,
            prefix: Prefix,
            stage: Stage,

            const Stage = enum { body, prefix, start };

            pub fn of(held: []const u8) Components {
                assert(held.len <= std.math.maxInt(u32));

                return .{ .held = held, .offset = 0, .prefix = prefix_of(held), .stage = .prefix };
            }

            pub fn next(components: *Components) ?Component {
                if (components.stage == .prefix) {
                    const end = components.prefix.end;

                    components.stage = .start;
                    components.offset = end;

                    if (end > 0) return .{ .kind = .prefix, .text = components.held[0..end] };
                }

                if (components.stage == .start) {
                    components.stage = .body;

                    if (components.start_next()) |component| return component;
                }

                return components.body_next();
            }

            fn start_next(components: *Components) ?Component {
                const held = components.held;
                const prefix = components.prefix;
                const offset = components.offset;
                const physical = offset < held.len and separator_in(held[offset], prefix.verbatim);

                if (physical) {
                    components.offset += 1;

                    return .{ .kind = .root, .text = separator_text };
                }

                if (prefix.end > 0) {
                    if (prefix.disk) return null;
                    if (prefix.verbatim) return null;
                    return .{ .kind = .root, .text = separator_text };
                }

                const dotted = held.len > 0 and held[0] == '.';
                const alone = held.len == 1 or (held.len > 1 and is_separator(held[1]));

                if (!dotted) return null;
                if (!alone) return null;

                components.offset = 1;

                return .{ .kind = .current, .text = "." };
            }

            fn body_next(components: *Components) ?Component {
                const held = components.held;
                const verbatim_only = components.prefix.verbatim;

                for (0..held.len + 1) |_| {
                    if (components.offset >= held.len) return null;

                    const start = components.offset;
                    const end = separator_from(held, start, verbatim_only);
                    const part = held[start..end];

                    components.offset = if (end < held.len) end + 1 else end;

                    if (part.len == 0) continue;
                    if (std.mem.eql(u8, part, "..")) return .{ .kind = .parent, .text = part };

                    if (std.mem.eql(u8, part, ".")) {
                        if (verbatim_only) return .{ .kind = .current, .text = part };

                        continue;
                    }

                    return .{ .kind = .normal, .text = part };
                }

                unreachable;
            }
        };

        const Assembled = struct {
            target: []u8,
            length: u32,

            fn held(assembled: *const Assembled) []const u8 {
                return assembled.target[0..assembled.length];
            }

            fn appended(assembled: *Assembled, bytes: []const u8) error{Overflow}!void {
                assert(bytes.len <= std.math.maxInt(u32));

                assembled.length = try written(assembled.target, assembled.length, bytes);
            }

            fn separator_needed(assembled: *const Assembled) bool {
                const bytes = assembled.held();
                if (bytes.len == 0) return false;
                if (is_separator(bytes[bytes.len - 1])) return false;

                const prefix = prefix_of(bytes);
                return !prefix.disk or prefix.end < bytes.len;
            }

            fn path_pushed(assembled: *Assembled, text: []const u8) error{Overflow}!void {
                assert(text.len <= std.math.maxInt(u32));

                const prefix = prefix_of(text);
                const after_prefix = prefix.end < text.len;
                const physical = after_prefix and separator_in(text[prefix.end], prefix.verbatim);
                const rooted = physical or (prefix.end > 0 and !prefix.disk);
                const replaced = if (platform == .posix) rooted else prefix.end > 0;
                const separated = assembled.separator_needed();
                const kept_verbatim = prefix_of(assembled.held()).verbatim and text.len > 0;

                if (replaced) {
                    assembled.length = 0;
                } else if (kept_verbatim) {
                    return assembled.verbatim_pushed(text);
                } else {
                    if (rooted) {
                        assembled.length = prefix_of(assembled.held()).end;
                    } else if (separated) {
                        try assembled.appended(separator_text);
                    } else {}
                }

                try assembled.appended(text);
            }

            fn verbatim_pushed(assembled: *Assembled, text: []const u8) error{Overflow}!void {
                assert(text.len > 0);

                var rebuilt_bytes: [path_bytes_max * 2]u8 = undefined;
                var rebuilt: Rebuilt = .{ .target = &rebuilt_bytes };
                var held_components: Components = .of(assembled.held());

                for (0..assembled.length + 2) |_| {
                    const component = held_components.next() orelse break;

                    try rebuilt.component_pushed(component);
                } else unreachable;

                var text_components: Components = .of(text);

                for (0..text.len + 2) |_| {
                    const component = text_components.next() orelse break;

                    switch (component.kind) {
                        .current => {},
                        .normal, .prefix => try rebuilt.component_pushed(component),
                        .parent => rebuilt.normal_popped(),
                        .root => {
                            rebuilt.prefix_kept();
                            try rebuilt.component_pushed(component);
                        },
                    }
                } else unreachable;

                assembled.length = 0;

                try assembled.appended(rebuilt.held());
            }
        };

        const Rebuilt = struct {
            target: []u8,
            floor: u32 = 0,
            length: u32 = 0,
            prefix_end: u32 = 0,
            separated: bool = false,

            fn held(rebuilt: *const Rebuilt) []const u8 {
                return rebuilt.target[0..rebuilt.length];
            }

            fn component_pushed(rebuilt: *Rebuilt, component: Component) error{Overflow}!void {
                assert(component.text.len <= std.math.maxInt(u32));

                const joined = rebuilt.separated and component.kind != .root;

                if (joined) {
                    rebuilt.length = try written(rebuilt.target, rebuilt.length, separator_text);
                }

                rebuilt.length = try written(rebuilt.target, rebuilt.length, component.text);

                rebuilt.separated = switch (component.kind) {
                    .current, .normal, .parent => true,
                    .prefix => !prefix_of(component.text).disk,
                    .root => false,
                };

                if (component.kind == .prefix) rebuilt.prefix_end = rebuilt.length;
                if (component.kind == .current) return;
                if (component.kind == .normal) return;
                if (component.kind == .parent) return;

                rebuilt.floor = rebuilt.length;
            }

            fn prefix_kept(rebuilt: *Rebuilt) void {
                rebuilt.length = rebuilt.prefix_end;
                rebuilt.floor = rebuilt.prefix_end;
                rebuilt.separated = rebuilt.prefix_end > 0;
            }

            fn normal_popped(rebuilt: *Rebuilt) void {
                if (rebuilt.length == rebuilt.floor) return;

                assert(rebuilt.length > rebuilt.floor);

                const tail = rebuilt.target[rebuilt.floor..rebuilt.length];
                const separator_at = std.mem.findScalarLast(u8, tail, separator_native);
                const after = if (separator_at) |at| at + 1 else 0;
                const start: u32 = rebuilt.floor + @as(u32, @intCast(after));
                const last = rebuilt.target[start..rebuilt.length];
                if (std.mem.eql(u8, last, ".")) return;
                if (std.mem.eql(u8, last, "..")) return;

                const kept = if (start > rebuilt.floor) start - 1 else start;
                const prefix_last = rebuilt.floor == rebuilt.prefix_end;

                rebuilt.length = kept;
                rebuilt.separated = kept > rebuilt.floor or prefix_last;

                assert(rebuilt.length >= rebuilt.floor);
            }
        };

        const separator_text: []const u8 = if (platform == .windows) "\\" else "/";
        const separator_native: u8 = if (platform == .windows) '\\' else '/';

        fn shape_of(held: []const u8) Shape {
            assert(held.len <= std.math.maxInt(u32));

            const prefix = prefix_of(held);
            var rooted = prefix.end;

            assert(rooted <= held.len);

            const separated = rooted < held.len and separator_in(held[rooted], prefix.verbatim);

            if (separated) rooted += 1;

            const after = held[prefix.end..];
            const implicit = prefix.end > 0 and !prefix.disk;
            const dotted = after.len > 0 and after[0] == '.';
            const followed = after.len > 1 and separator_in(after[1], prefix.verbatim);
            const alone = after.len == 1 or followed;
            const current = rooted == prefix.end and !implicit and dotted and alone;
            const body = rooted + @intFromBool(current);

            assert(body <= held.len);

            return .{
                .rooted = rooted,
                .body = body,
                .current = current,
                .verbatim = prefix.verbatim,
            };
        }

        fn prefix_of(held: []const u8) Prefix {
            assert(held.len <= std.math.maxInt(u32));

            const none: Prefix = .{ .end = 0, .disk = false, .verbatim = false };
            if (platform == .posix) return none;

            if (std.mem.startsWith(u8, held, verbatim_share)) {
                const server = separator_from(held, verbatim_share.len, true);
                const share = separator_from(held, @min(server + 1, held.len), true);

                return .{ .end = share, .disk = false, .verbatim = true };
            }

            if (std.mem.startsWith(u8, held, verbatim)) {
                const drive = held.len >= 6 and std.ascii.isAlphabetic(held[4]) and held[5] == ':';
                const exact = drive and (held.len == 6 or held[6] == '\\');
                if (exact) return .{ .end = 6, .disk = false, .verbatim = true };
                return .{ .end = separator_from(held, 4, true), .disk = false, .verbatim = true };
            }

            if (std.mem.startsWith(u8, held, verbatim_device)) {
                return .{ .end = separator_from(held, 4, false), .disk = false, .verbatim = false };
            }

            const doubled = held.len > 2 and is_separator(held[0]) and is_separator(held[1]);

            if (doubled) {
                const server = separator_from(held, 2, false);
                const share = separator_from(held, @min(server + 1, held.len), false);
                const unnamed = server == 2 or share <= server + 1;
                if (unnamed) return none;
                return .{ .end = share, .disk = false, .verbatim = false };
            }

            const disk = held.len >= 2 and std.ascii.isAlphabetic(held[0]) and held[1] == ':';
            if (disk) return .{ .end = 2, .disk = true, .verbatim = false };
            return none;
        }

        fn separator_from(held: []const u8, start: usize, verbatim_only: bool) u32 {
            assert(start <= held.len);

            for (start..held.len) |index| {
                if (separator_in(held[index], verbatim_only)) {
                    assert(index < held.len);

                    return @intCast(index);
                }
            }

            assert(held.len <= std.math.maxInt(u32));

            return @intCast(held.len);
        }

        fn separator_in(byte: u8, verbatim_only: bool) bool {
            if (byte < '/') return false;

            if (verbatim_only) return byte == '\\';
            return is_separator(byte);
        }

        fn body_trimmed(held: []const u8, shape: Shape, end_initial: u32) u32 {
            assert(end_initial >= shape.body);
            assert(end_initial <= held.len);

            var end = end_initial;

            for (0..held.len + 1) |_| {
                if (end == shape.body) return end;

                if (separator_in(held[end - 1], shape.verbatim)) {
                    end -= 1;

                    continue;
                }

                const start = component_start(held, shape, end);

                if (shape.verbatim) return end;
                if (!std.mem.eql(u8, held[start..end], ".")) return end;

                end = start;
            }

            unreachable;
        }

        fn component_start(held: []const u8, shape: Shape, end: u32) u32 {
            assert(end >= shape.body);
            assert(end <= held.len);

            var index = end;

            for (0..end - shape.body) |_| {
                if (separator_in(held[index - 1], shape.verbatim)) return index;

                index -= 1;
            }

            assert(index == shape.body);

            return index;
        }

        fn root_end(held: []const u8) u32 {
            assert(held.len <= std.math.maxInt(u32));

            if (held.len == 0) return 0;
            if (is_separator(held[0])) return 1;
            if (!is_absolute(held)) return 0;

            assert(held.len >= 2);

            const separated = held.len > 2 and is_separator(held[2]);
            return if (separated) 3 else 2;
        }

        fn separator_after(held: []const u8, start: u32) u32 {
            assert(start <= held.len);

            const offset = std.mem.findAnyPos(u8, held, start, separators) orelse held.len;

            assert(offset >= start);

            return @intCast(offset);
        }

        fn written(target: []u8, offset: u32, bytes: []const u8) error{Overflow}!u32 {
            assert(offset <= target.len);

            if (bytes.len > target.len - offset) return error.Overflow;

            const end: u32 = offset + @as(u32, @intCast(bytes.len));

            @memcpy(target[offset..end], bytes);
            assert(end <= target.len);

            return end;
        }
    };
}

fn segment_count_max(held: []const u8) u32 {
    assert(held.len <= std.math.maxInt(u32));

    const count: u32 = @intCast(@divFloor(held.len + 1, 2));

    assert(count <= held.len);

    return count;
}

fn copied_into(out: []u8, bytes: []const u8) u32 {
    assert(out.len <= std.math.maxInt(u32));
    assert(bytes.len <= std.math.maxInt(u32));

    const width = @min(out.len, bytes.len);

    @memcpy(out[0..width], bytes[0..width]);
    assert(width <= out.len);
    assert(width <= bytes.len);

    return @intCast(width);
}

const Held = struct {
    bytes: [path_bytes_max]u8,
    length: u32,

    fn slice(held: *const Held) []const u8 {
        return held.bytes[0..held.length];
    }
};

fn held_joined(comptime platform: Platform, base: []const u8, relative: []const u8) !Held {
    assert(base.len <= std.math.maxInt(u32));
    assert(relative.len <= std.math.maxInt(u32));

    var held: Held = .{ .bytes = undefined, .length = 0 };

    held.length = try PathType(platform).join(&held.bytes, .{ .base = base, .relative = relative });

    return held;
}

fn expect_joined(
    comptime platform: Platform,
    expected: []const u8,
    base: []const u8,
    relative: []const u8,
) !void {
    assert(base.len <= std.math.maxInt(u32));
    assert(relative.len <= std.math.maxInt(u32));

    const held = try held_joined(platform, base, relative);

    try expectEqualStrings(expected, held.slice());
}

fn expect_normalised(
    comptime platform: Platform,
    expected: []const u8,
    held_path: []const u8,
) !void {
    assert(held_path.len <= std.math.maxInt(u32));

    var held: Held = .{ .bytes = undefined, .length = 0 };

    held.length = try PathType(platform).normalised_into(&held.bytes, held_path);

    try expectEqualStrings(expected, held.slice());
}

fn expect_relative(
    comptime platform: Platform,
    expected: []const u8,
    root: []const u8,
    held_path: []const u8,
) !void {
    assert(root.len <= std.math.maxInt(u32));
    assert(held_path.len <= std.math.maxInt(u32));

    var held: Held = .{ .bytes = undefined, .length = 0 };
    const under: Under = .{ .directory = root, .path = held_path };

    held.length = try PathType(platform).relative_into(&held.bytes, under);

    try expectEqualStrings(expected, held.slice());
}

fn expect_verbatim(bytes: []const u8, prefix: []const u8, skipped: u32) !void {
    assert(bytes.len <= std.math.maxInt(u32));

    const found = PathType(.windows).verbatim_of(bytes) orelse return error.TestUnexpectedResult;

    try std.testing.expectEqualStrings(prefix, found.prefix);
    try std.testing.expectEqual(skipped, found.skipped);
}

test "a text path reads back" {
    const bytes = "/tmp/scylla.rs";
    const held = native.path_of(bytes) orelse return error.TestUnexpectedResult;

    try expectEqualStrings(bytes, native.name_bytes(held) orelse return error.TestUnexpectedResult);
    try expectEqualStrings(bytes, native.name_bytes_or_empty(held));
}

test "a missing path is empty" {
    try std.testing.expectEqual(0, native.named("").len);
}

test "a non text path is refused" {
    try expect(PathType(.windows).path_of(&.{ 0xff, 0xfe }) == null);
}

test "a directory drops the last part" {
    try expectEqualStrings("/a/b", native.directory_of("/a/b/c.toml"));
    try expectEqualStrings("/", native.directory_of("/a"));
    try expectEqualStrings(".", native.directory_of("c.toml"));
}

test "a trailing separator is trimmed but the root stays" {
    try expectEqualStrings("/a/b", native.trimmed("/a/b/"));
    try expectEqualStrings("/", native.trimmed("/"));
    try expectEqualStrings("", native.trimmed(""));
}

test "a relative path resolves against its base" {
    try expect_joined(.posix, "/a/c/scylla.toml", "/a/b", "../c/scylla.toml");
    try expect_joined(.posix, "/a/b/c", "/a/b/", "c");
    try expect_joined(.posix, "/c", "/", "c");
    try expect_joined(.posix, "c", "", "c");
    try expect_joined(.posix, "/a/c/d", "/a", "./c//d");
    try expect_joined(.posix, "/c", "/a", "../../c");
}

test "an absolute path replaces the base" {
    try expect_joined(.posix, "/etc/scylla.toml", "/a/b", "/etc/scylla.toml");
}

test "a join past the buffer is refused" {
    var target: [8]u8 = undefined;
    const climbing: Join = .{ .base = "/a/b", .relative = "../c/scylla.toml" };
    const absolute: Join = .{ .base = "/a/b", .relative = "/etc/scylla.toml" };

    try std.testing.expectError(error.Overflow, native.join(&target, climbing));
    try std.testing.expectError(error.Overflow, native.join(&target, absolute));
}

test "a copy stops at the target" {
    var out: [4]u8 = undefined;

    try std.testing.expectEqual(4, copied_into(&out, "abcdef"));
    try expectEqualStrings("abcd", &out);
    try std.testing.expectEqual(2, copied_into(&out, "xy"));
    try expectEqualStrings("xy", out[0..2]);
}

test "a windows path has a directory" {
    const windows = PathType(.windows);
    const posix = PathType(.posix);

    try expectEqualStrings("C:\\work", windows.directory_of("C:\\work\\a.rs"));
    try expectEqualStrings("C:\\", windows.directory_of("C:\\work"));
    try expectEqualStrings(".", posix.directory_of("C:\\work\\a.rs"));
    try expectEqualStrings(".", posix.directory_of("C:\\work"));
}

test "a windows path loses its trailing separator" {
    try expectEqualStrings("C:\\work", PathType(.windows).trimmed("C:\\work\\"));
    try expectEqualStrings("C:\\work\\", PathType(.posix).trimmed("C:\\work\\"));
}

test "a name joins a windows directory with a forward slash" {
    const held = try held_joined(.windows, "C:\\work", "scylla.toml");
    const held_posix = try held_joined(.posix, "C:\\work", "scylla.toml");

    try expectEqualStrings("C:\\work/scylla.toml", held.slice());
    try expectEqualStrings("C:\\work/scylla.toml", held_posix.slice());
    try expectEqualStrings("C:\\work", PathType(.windows).directory_of(held.slice()));
}

test "a drive root is the floor of its path" {
    try expect_normalised(.windows, "C:", "C:");
    try expect_normalised(.windows, "C:\\", "C:\\");
    try expect_normalised(.windows, "C:/", "C:/");
    try expect_normalised(.windows, "C:\\", "C:\\a\\..\\..");
    try expect_normalised(.windows, "C:/b", "C:/a/../../b");
    try expect_normalised(.windows, "C:", "C:..");
    try expect_joined(.windows, "C:\\c", "C:\\", "c");
    try expect_joined(.windows, "C:/c", "C:/", "c");
    try expect_joined(.windows, "C:/c", "C:", "c");
    try expect_joined(.windows, "C:\\c", "C:\\a", "..\\..\\c");
    try expect_normalised(.posix, "C:\\a\\..\\..", "C:\\a\\..\\..");
    try expect_normalised(.posix, "", "C:/a/../..");
    try expect_joined(.posix, "C:/c", "C:/", "c");
}

test "a drive root is its own directory" {
    const windows = PathType(.windows);
    const posix = PathType(.posix);

    try expectEqualStrings("C:\\", windows.directory_of("C:\\file"));
    try expectEqualStrings("C:/", windows.directory_of("C:/file"));
    try expectEqualStrings("C:\\", windows.directory_of("C:\\"));
    try expectEqualStrings("C:", windows.directory_of("C:"));
    try expectEqualStrings("C:\\", windows.trimmed("C:\\"));
    try expectEqualStrings("C:/", windows.trimmed("C:/"));
    try expect(windows.contains(.{ .directory = "C:\\", .path = "C:\\a" }));
    try expect_relative(.windows, "a", "C:\\", "C:\\a");
    try expectEqualStrings("C:", posix.directory_of("C:/file"));
    try expectEqualStrings("C:", posix.trimmed("C:/"));
    try expect(posix.contains(.{ .directory = "C:/", .path = "C:/a" }));
}

test "a drive letter is an absolute path" {
    const windows = PathType(.windows);
    const posix = PathType(.posix);

    try expect(windows.is_absolute("C:\\shared\\scylla.toml"));
    try expect(windows.is_absolute("C:/shared/scylla.toml"));
    try expect(!posix.is_absolute("C:\\shared\\scylla.toml"));
    try expect(!posix.is_absolute("C:/shared/scylla.toml"));
    try expect(native.is_absolute("/shared/scylla.toml"));
    try expect(!native.is_absolute("shared/scylla.toml"));
    try expect(!windows.is_absolute("CC:/shared"));
    try expect(!posix.is_absolute("CC:/shared"));
}

const JoinCase = struct {
    base: []const u8,
    relative: []const u8,
    posix: []const u8,
    windows: []const u8,
};

const join_cases = [_]JoinCase{
    .{
        .base = "/a/b",
        .relative = "./../c//d.toml",
        .posix = "/a/b/../c/d.toml",
        .windows = "\\a\\b\\..\\c\\d.toml",
    },
    .{
        .base = "C:/x/y",
        .relative = "../z.toml",
        .posix = "C:/x/y/../z.toml",
        .windows = "C:\\x\\y\\..\\z.toml",
    },
    .{
        .base = "C:\\x\\y",
        .relative = "../z.toml",
        .posix = "C:\\x\\y/../z.toml",
        .windows = "C:\\x\\y\\..\\z.toml",
    },
    .{
        .base = "\\\\server\\share\\x",
        .relative = "../z.toml",
        .posix = "\\\\server\\share\\x/../z.toml",
        .windows = "\\\\server\\share\\x\\..\\z.toml",
    },
    .{
        .base = "//server/share/x",
        .relative = "../z.toml",
        .posix = "/server/share/x/../z.toml",
        .windows = "//server/share\\x\\..\\z.toml",
    },
    .{
        .base = "C:x",
        .relative = "y.toml",
        .posix = "C:x/y.toml",
        .windows = "C:x\\y.toml",
    },
    .{
        .base = "C:",
        .relative = "y.toml",
        .posix = "C:/y.toml",
        .windows = "C:y.toml",
    },
    .{
        .base = "C:\\x",
        .relative = "/abs/z.toml",
        .posix = "/abs/z.toml",
        .windows = "C:\\abs\\z.toml",
    },
    .{
        .base = "C:\\x",
        .relative = "D:\\other\\z.toml",
        .posix = "C:\\x/D:\\other\\z.toml",
        .windows = "D:\\other\\z.toml",
    },
    .{
        .base = "C:\\x",
        .relative = "D:rel\\z.toml",
        .posix = "C:\\x/D:rel\\z.toml",
        .windows = "D:rel\\z.toml",
    },
    .{
        .base = "\\\\?\\C:\\x\\y",
        .relative = "../z.toml",
        .posix = "\\\\?\\C:\\x\\y/../z.toml",
        .windows = "\\\\?\\C:\\x\\z.toml",
    },
    .{
        .base = "\\\\?\\C:\\x\\y",
        .relative = "./a/./b.toml",
        .posix = "\\\\?\\C:\\x\\y/a/b.toml",
        .windows = "\\\\?\\C:\\x\\y\\a\\b.toml",
    },
    .{
        .base = "\\\\?\\UNC\\server\\share\\x",
        .relative = "../z.toml",
        .posix = "\\\\?\\UNC\\server\\share\\x/../z.toml",
        .windows = "\\\\?\\UNC\\server\\share\\z.toml",
    },
    .{
        .base = "x/y",
        .relative = "./../z.toml",
        .posix = "x/y/../z.toml",
        .windows = "x\\y\\..\\z.toml",
    },
    .{
        .base = ".",
        .relative = "z.toml",
        .posix = "./z.toml",
        .windows = ".\\z.toml",
    },
    .{
        .base = "./x",
        .relative = "z.toml",
        .posix = "./x/z.toml",
        .windows = ".\\x\\z.toml",
    },
    .{
        .base = "x",
        .relative = "/z.toml",
        .posix = "/z.toml",
        .windows = "\\z.toml",
    },
    .{
        .base = "\\\\server\\share",
        .relative = "z.toml",
        .posix = "\\\\server\\share/z.toml",
        .windows = "\\\\server\\share\\z.toml",
    },
    .{
        .base = "C:\\",
        .relative = "z.toml",
        .posix = "C:\\/z.toml",
        .windows = "C:\\z.toml",
    },
    .{
        .base = "/",
        .relative = "z.toml",
        .posix = "/z.toml",
        .windows = "\\z.toml",
    },
    .{
        .base = "a//b/./c",
        .relative = "",
        .posix = "a/b/c",
        .windows = "a\\b\\c",
    },
    .{
        .base = "C:\\x\\.",
        .relative = "y",
        .posix = "C:\\x\\./y",
        .windows = "C:\\x\\y",
    },
    .{
        .base = "\\\\.\\COM1",
        .relative = "x",
        .posix = "\\\\.\\COM1/x",
        .windows = "\\\\.\\COM1\\x",
    },
    .{
        .base = "//server",
        .relative = "x",
        .posix = "/server/x",
        .windows = "//server\\x\\",
    },
    .{
        .base = "\\\\server\\share\\x",
        .relative = "\\abs\\z.toml",
        .posix = "\\\\server\\share\\x/\\abs\\z.toml",
        .windows = "\\\\server\\share\\abs\\z.toml",
    },
    .{
        .base = "/a/b",
        .relative = "../../../../z.toml",
        .posix = "/a/b/../../../../z.toml",
        .windows = "\\a\\b\\..\\..\\..\\..\\z.toml",
    },
    .{
        .base = "C:\\a",
        .relative = "..\\..\\z.toml",
        .posix = "C:\\a/..\\..\\z.toml",
        .windows = "C:\\a\\..\\..\\z.toml",
    },
    .{
        .base = "./",
        .relative = "./z.toml",
        .posix = "./z.toml",
        .windows = ".\\z.toml",
    },
    .{
        .base = "..",
        .relative = "z.toml",
        .posix = "../z.toml",
        .windows = "..\\z.toml",
    },
    .{
        .base = "C:.\\x",
        .relative = "y",
        .posix = "C:.\\x/y",
        .windows = "C:x\\y",
    },
};

test "a components join keeps what rust's join and components collect keep" {
    for (join_cases) |case| {
        var target: [path_bytes_max]u8 = undefined;
        const parts: Join = .{ .base = case.base, .relative = case.relative };
        const posix = try PathType(.posix).components_joined(&target, parts);

        try expectEqualStrings(case.posix, target[0..posix]);

        const windows = try PathType(.windows).components_joined(&target, parts);

        try expectEqualStrings(case.windows, target[0..windows]);
    }
}

test "a qualified path becomes verbatim" {
    try expect_verbatim("C:\\deep\\file.rs", verbatim, 0);
    try expect_verbatim("C:/deep/file.rs", verbatim, 0);
    try expect_verbatim("\\\\host\\share\\file.rs", verbatim_share, 2);
}

test "a path the prefix cannot spell is left alone" {
    const windows = PathType(.windows);

    try expect(windows.verbatim_of("deep\\file.rs") == null);
    try expect(windows.verbatim_of("C:\\deep\\.\\file.rs") == null);
    try expect(windows.verbatim_of("C:\\deep\\..\\file.rs") == null);
    try expect(windows.verbatim_of("C:\\deep\\\\file.rs") == null);
    try expect(windows.verbatim_of("\\\\?\\C:\\deep\\file.rs") == null);
    try expect(windows.verbatim_of("\\\\.\\pipe\\name") == null);
}

test "segments skip empty parts and the file name is the last" {
    var iterator = native.segments("/a//b/c/");
    const one = iterator.next().?;
    const two = iterator.next().?;
    const three = iterator.next().?;
    const past = iterator.next();

    try expectEqualStrings("a", one);
    try expectEqualStrings("b", two);
    try expectEqualStrings("c", three);
    try expect(past == null);

    var empty = native.segments("");
    var root = native.segments("/");
    const empty_first = empty.next();
    const root_first = root.next();

    try expect(empty_first == null);
    try expect(root_first == null);
    try expectEqualStrings("c.rs", native.file_name("/a/b/c.rs"));
    try expectEqualStrings("b", native.file_name("a/b/"));
    try expectEqualStrings("c.rs", native.file_name("c.rs"));
    try expectEqualStrings("", native.file_name("/"));
    try expectEqualStrings("", native.file_name(""));
}

test "a segment iterator never counts past the most segments its path can hold" {
    const held = "a/b/c/d/e";
    var iterator = native.segments(held);

    try std.testing.expectEqual(5, iterator.remaining);

    for (0..5) |_| {
        _ = iterator.next() orelse return error.TestUnexpectedResult;
    }

    try std.testing.expectEqual(0, iterator.remaining);

    const iterator_next = iterator.next();

    try expect(iterator_next == null);

    var spaced = native.segments("//a//");
    const only = spaced.next() orelse return error.TestUnexpectedResult;

    try expectEqualStrings("a", only);

    const spaced_next = spaced.next();

    try expect(spaced_next == null);
    try expect(spaced.remaining <= segment_count_max("//a//"));
}

test "a parent is empty for a bare name and positioned segments keep their offsets" {
    try expectEqualStrings("a/b", native.parent_of("a/b/c.rs"));
    try expectEqualStrings("/", native.parent_of("/a"));
    try expectEqualStrings("/", native.parent_of("/"));
    try expectEqualStrings("", native.parent_of("c.rs"));
    try expectEqualStrings("", native.parent_of(".hidden"));
    try expectEqualStrings("", native.parent_of(""));
    try expectEqualStrings(".", native.directory_of("c.rs"));

    var absolute = native.segments_positioned("/a/b");
    const one = absolute.next_positioned().?;
    const two = absolute.next_positioned().?;
    const absolute_past = absolute.next_positioned();

    try std.testing.expectEqual(1, one.offset);
    try expectEqualStrings("a", one.text);
    try std.testing.expectEqual(3, two.offset);
    try expectEqualStrings("b", two.text);
    try expect(absolute_past == null);

    var relative = native.segments_positioned("a//bc/");
    const three = relative.next_positioned().?;
    const four = relative.next_positioned().?;
    const relative_past = relative.next_positioned();

    try std.testing.expectEqual(0, three.offset);
    try expectEqualStrings("a", three.text);
    try std.testing.expectEqual(3, four.offset);
    try expectEqualStrings("bc", four.text);
    try expect(relative_past == null);

    var empty = native.segments_positioned("");
    var root = native.segments_positioned("/");
    const empty_first = empty.next_positioned();
    const root_first = root.next_positioned();

    try expect(empty_first == null);
    try expect(root_first == null);
}

test "a directory contains itself and what sits under it" {
    try expect(native.contains(.{ .directory = "/a/b", .path = "/a/b" }));
    try expect(native.contains(.{ .directory = "/a/b/", .path = "/a/b" }));
    try expect(native.contains(.{ .directory = "/a/b", .path = "/a/b/c" }));
    try expect(native.contains(.{ .directory = "/", .path = "/a" }));
    try expect(native.contains(.{ .directory = "/", .path = "/" }));
    try expect(native.contains(.{ .directory = "", .path = "anything" }));
    try expect(!native.contains(.{ .directory = "/a/b", .path = "/a/bc" }));
    try expect(!native.contains(.{ .directory = "/a/b", .path = "/a" }));
    try expect(!native.contains(.{ .directory = "/a/b", .path = "" }));
    try expect(!native.contains(.{ .directory = "/", .path = "a" }));
}

test "a path under the root loses the root and any other path is kept" {
    var out: [4]u8 = undefined;
    const outgrown: Under = .{ .directory = "/a", .path = "/a/bcdefgh" };

    try expect_relative(.posix, "c/d.rs", "/a/b", "/a/b/c/d.rs");
    try expect_relative(.posix, "c", "/a/b/", "/a/b//c");
    try expect_relative(.posix, "", "/a/b", "/a/b");
    try expect_relative(.posix, "/a/bc/d", "/a/b", "/a/bc/d");
    try expect_relative(.posix, "/a/b", "", "/a/b");
    try expect_relative(.posix, "a", "/", "/a");
    try expect_relative(.posix, "", "/a", "");
    try std.testing.expectError(error.Overflow, native.relative_into(&out, outgrown));
}

test "a normalised path folds dots and stays at its root" {
    var three: [3]u8 = undefined;
    var none: [0]u8 = undefined;

    try expect_normalised(.posix, "b/c", "./a/../b/./c/");
    try expect_normalised(.posix, "/c", "/a/b/../../c");
    try expect_normalised(.posix, "/", "/a/../..");
    try expect_normalised(.posix, "/", "/..");
    try expect_normalised(.posix, "/", "/");
    try expect_normalised(.posix, "../a", "../a");
    try expect_normalised(.posix, "../b", "a/../../b");
    try expect_normalised(.posix, "../..", "../..");
    try expect_normalised(.posix, "a/b", "a//b");
    try expect_normalised(.posix, "", ".");
    try expect_normalised(.posix, "", "");
    try expect_normalised(.posix, "", "a/..");
    try std.testing.expectError(error.Overflow, native.normalised_into(&three, "/abc"));
    try std.testing.expectError(error.Overflow, native.normalised_into(&none, "/"));
}

test "the longest prefix is the deepest root holding the path" {
    const roots = [_][]const u8{ "/a", "/a/b/c", "/a/b", "/x" };

    try std.testing.expectEqual(1, native.longest_prefix(&roots, "/a/b/c/d.rs"));
    try std.testing.expectEqual(2, native.longest_prefix(&roots, "/a/b/x.rs"));
    try std.testing.expectEqual(0, native.longest_prefix(&roots, "/a/x.rs"));
    try std.testing.expectEqual(null, native.longest_prefix(&roots, "/y"));
    try std.testing.expectEqual(null, native.longest_prefix(&.{}, "/y"));
    try std.testing.expectEqual(1, native.longest_prefix(&.{ "", "/y" }, "/y/z"));
}

test "a parent and a push follow the rust path rules" {
    const posix = PathType(.posix);
    const windows = PathType(.windows);

    const posix_parents = [_][2][]const u8{
        .{ ".", "" },
        .{ "./", "" },
        .{ "./a", "." },
        .{ "a", "" },
        .{ "a/", "" },
        .{ "a/.", "" },
        .{ "a/./", "" },
        .{ "a//b", "a" },
        .{ "/a", "/" },
        .{ "/a/b/", "/a" },
        .{ "..", "" },
        .{ "../x", ".." },
        .{ "../proj/templates", "../proj" },
        .{ "a/b/./", "a" },
        .{ "./.", "" },
        .{ "x/../y", "x/.." },
    };

    const windows_parents = [_][2][]const u8{
        .{ "\\\\?\\C:\\x\\y", "\\\\?\\C:\\x" },
        .{ "\\\\?\\C:\\x", "\\\\?\\C:\\" },
        .{ "\\\\?\\UNC\\host\\share\\x", "\\\\?\\UNC\\host\\share\\" },
        .{ "C:\\x", "C:\\" },
        .{ "C:x", "C:" },
        .{ "a\\b", "a" },
        .{ ".\\templates", "." },
        .{ "\\\\host\\share\\x", "\\\\host\\share\\" },
    };

    var buffer: [64]u8 = undefined;

    for (posix_parents) |pair| {
        try std.testing.expectEqualStrings(pair[1], posix.popped(pair[0]).?);
    }

    for (windows_parents) |pair| {
        try std.testing.expectEqualStrings(pair[1], windows.popped(pair[0]).?);
    }

    try expect(posix.popped("") == null);
    try expect(posix.popped("/") == null);
    try expect(posix.popped("//") == null);
    try expect(windows.popped("\\\\?\\C:\\") == null);
    try expect(windows.popped("C:\\") == null);
    try expect(windows.popped("\\\\?\\UNC\\host\\share\\") == null);
    try expect_pushed(posix, "n", "", &buffer);
    try expect_pushed(posix, "a/n", "a", &buffer);
    try expect_pushed(posix, "a/n", "a/", &buffer);
    try expect_pushed(posix, "/n", "/", &buffer);
    try expect_pushed(posix, "./a/n", "./a", &buffer);
    try expect_pushed(windows, "C:n", "C:", &buffer);
    try expect_pushed(windows, "a\\n", "a", &buffer);
    try expect_pushed(windows, "a/n", "a/", &buffer);

    const verbatim_parts: Push = .{ .base = "\\\\?\\C:\\x", .name = "scylla.toml" };
    const verbatim_pushed = try windows.pushed(&buffer, verbatim_parts);

    try std.testing.expectEqualStrings("\\\\?\\C:\\x\\scylla.toml", buffer[0..verbatim_pushed]);
}

fn expect_pushed(
    comptime Paths: type,
    expected: []const u8,
    base: []const u8,
    buffer: []u8,
) !void {
    assert(base.len <= std.math.maxInt(u32));
    assert(buffer.len <= std.math.maxInt(u32));

    const length = try Paths.pushed(buffer, .{ .base = base, .name = "n" });

    try std.testing.expectEqualStrings(expected, buffer[0..length]);
}
