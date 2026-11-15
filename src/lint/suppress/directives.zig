const std = @import("std");
const assert = std.debug.assert;
const ArrayType = @import("../../stdx/bounded/array.zig").ArrayType;
const Span = @import("../../stdx/bounded/span.zig");
const unicode = @import("../../text/unicode.zig");

codes: ArrayType(Span),
file_wide: ArrayType(u32),
markers: ArrayType(Marker),
open: ArrayType(u32),
ranges: ArrayType(Range),
scans: ArrayType(Scan),

const Directives = @This();
pub const Kind = enum { off, ok, on };
pub const Level = enum { file, line };

pub const Spelling = struct {
    file_suffix: []const u8,
    off: []const u8,
    ok: []const u8,
    on: []const u8,
};

pub const Names = struct {
    code: []const u8,
    rule: []const u8,
};

pub const Marker = struct {
    code_count: u32,
    code_first: u32,
    comment: ?Span,
    kind: Kind,
    level: Level,
    line: u32,
    malformed: bool,
    range: Span,
    reason: ?Span,
};

pub const Range = struct {
    closed: bool,
    end_line: u32,
    off: u32,
    on: ?u32,
    start_line: u32,
};

pub const Scan = struct {
    file_wide_count: u32,
    file_wide_first: u32,
    marker_count: u32,
    marker_first: u32,
    range_count: u32,
    range_first: u32,
};

pub const Capacity = struct {
    code_count_max: u32,
    marker_count_max: u32,
    scan_count_max: u32,
};

pub const Error = error{DirectivesOutgrown};

pub const View = struct {
    scan: Scan,
    source: []const u8,
    directives: *const Directives,

    pub fn is_empty(view: *const View) bool {
        return view.scan.marker_count == 0;
    }

    pub fn markers(view: *const View) []const Marker {
        const first = view.scan.marker_first;
        const held = view.directives.markers.const_slice()[first..][0..view.scan.marker_count];

        assert(held.len == view.scan.marker_count);

        return held;
    }

    pub fn marker(view: *const View, index: u32) ?Marker {
        assert(index < std.math.maxInt(u32));

        if (index < view.scan.marker_count) return view.markers()[index];

        return null;
    }

    pub fn ranges(view: *const View) []const Range {
        const first = view.scan.range_first;
        const held = view.directives.ranges.const_slice()[first..][0..view.scan.range_count];

        assert(held.len == view.scan.range_count);

        return held;
    }

    pub fn codes_of(view: *const View, held: *const Marker) []const Span {
        const codes = view.directives.codes.const_slice()[held.code_first..][0..held.code_count];

        for (codes) |code| assert(code.end() <= view.source.len);

        return codes;
    }

    pub fn code_text(view: *const View, held: *const Marker, index: u32) []const u8 {
        assert(index < held.code_count);

        return view.codes_of(held)[index].text(view.source);
    }

    pub fn reason_of(view: *const View, held: *const Marker) ?[]const u8 {
        const reason = held.reason orelse return null;

        assert(reason.length > 0);

        return reason.text(view.source);
    }

    fn covers(view: *const View, held: *const Marker, names: Names) bool {
        assert(names.code.len > 0);

        if (held.code_count == 0) return true;

        for (view.codes_of(held)) |span| {
            const candidate = span.text(view.source);

            if (std.mem.eql(u8, candidate, names.code)) return true;
            if (std.mem.eql(u8, candidate, names.rule)) return true;
        }

        return false;
    }

    pub fn matching(view: *const View, line: u32, names: Names) ?u32 {
        assert(line < line_count_max);
        assert(names.code.len > 0);

        if (view.at(line, names)) |index| return index;
        if (view.at(line -| 1, names)) |index| return index;
        if (view.in_range(line, names)) |index| return index;

        const file_wide = view.directives.file_wide.const_slice();

        for (file_wide[view.scan.file_wide_first..][0..view.scan.file_wide_count]) |index| {
            assert(index < view.scan.marker_count);

            if (view.covers(&view.markers()[index], names)) return index;
        }

        return null;
    }

    pub fn on_line(view: *const View, line: u32) ?Marker {
        assert(line < line_count_max);

        const index = view.line_marker(line) orelse return null;

        return view.markers()[index];
    }

    pub fn suppresses(view: *const View, line: u32, names: Names) bool {
        assert(line < line_count_max);
        assert(names.code.len > 0);

        return view.matching(line, names) != null;
    }

    fn at(view: *const View, line: u32, names: Names) ?u32 {
        assert(line < line_count_max);
        assert(names.code.len > 0);

        const index = view.line_marker(line) orelse return null;

        if (!view.covers(&view.markers()[index], names)) return null;

        return index;
    }

    fn in_range(view: *const View, line: u32, names: Names) ?u32 {
        assert(line < line_count_max);
        assert(names.code.len > 0);

        for (view.ranges()) |span| {
            if (line < span.start_line) continue;
            if (line > span.end_line) continue;

            assert(span.off < view.scan.marker_count);

            if (view.covers(&view.markers()[span.off], names)) return span.off;
        }

        return null;
    }

    fn line_marker(view: *const View, line: u32) ?u32 {
        assert(line < line_count_max);

        const held = view.markers();
        var low: u32 = 0;
        var high: u32 = @intCast(held.len);

        for (0..search_steps_max) |_| {
            if (low >= high) break;

            const middle = low + (high - low) / 2;

            if (held[middle].line < line) {
                low = middle + 1;
            } else {
                high = middle;
            }
        } else unreachable;

        if (low >= held.len) return null;
        if (held[low].line != line) return null;
        if (held[low].kind != .ok) return null;
        if (held[low].level != .line) return null;

        return low;
    }
};

const Listed = union(enum) {
    named: Named,
    plain: bool,
    unclosed,
};

const Named = struct {
    end: u32,
    list_offset: u32,
    list: []const u8,
};

const Commented = struct {
    comment: ?Span,
    reason: ?Span,

    const none: Commented = .{ .comment = null, .reason = null };
};

const Paired = struct {
    close: []const u8,
    open: []const u8,
};

const line_count_max: u32 = 1 << 24;
const search_steps_max: u32 = 34;
const trailing_comments = [_][]const u8{ "//", "#" };

const paired_comments = [_]Paired{
    .{ .open = "{#", .close = "#}" },
    .{ .open = "<!--", .close = "-->" },
    .{ .open = "/*", .close = "*/" },
};

pub fn init(gpa: std.mem.Allocator, capacity: *const Capacity) error{OutOfMemory}!Directives {
    assert(capacity.marker_count_max > 0);
    assert(capacity.scan_count_max > 0);

    var directives: Directives = undefined;

    directives.codes = try .init(gpa, capacity.code_count_max);
    errdefer directives.codes.deinit(gpa);

    directives.file_wide = try .init(gpa, capacity.marker_count_max);
    errdefer directives.file_wide.deinit(gpa);

    directives.markers = try .init(gpa, capacity.marker_count_max);
    errdefer directives.markers.deinit(gpa);

    directives.open = try .init(gpa, capacity.marker_count_max);
    errdefer directives.open.deinit(gpa);

    directives.ranges = try .init(gpa, capacity.marker_count_max);
    errdefer directives.ranges.deinit(gpa);

    directives.scans = try .init(gpa, capacity.scan_count_max);

    assert(directives.markers.empty());

    return directives;
}

pub fn deinit(directives: *Directives, gpa: std.mem.Allocator) void {
    directives.scans.deinit(gpa);
    directives.ranges.deinit(gpa);
    directives.open.deinit(gpa);
    directives.markers.deinit(gpa);
    directives.file_wide.deinit(gpa);
    directives.codes.deinit(gpa);
    directives.* = undefined;
}

pub fn clear(directives: *Directives) void {
    directives.codes.clear();
    directives.file_wide.clear();
    directives.markers.clear();
    directives.open.clear();
    directives.ranges.clear();
    directives.scans.clear();

    assert(directives.markers.empty());
    assert(directives.scans.empty());
}

pub fn view_of(directives: *const Directives, index: u32, source: []const u8) View {
    assert(index < directives.scans.count());
    assert(source.len < std.math.maxInt(u32));

    return .{
        .scan = directives.scans.get(index),
        .source = source,
        .directives = directives,
    };
}

pub fn scan(directives: *Directives, spelling: *const Spelling, source: []const u8) Error!View {
    assert(source.len < std.math.maxInt(u32));
    assert(spelling.ok.len > 0);

    if (directives.scans.full()) return error.DirectivesOutgrown;

    var held: Scan = .{
        .file_wide_count = 0,
        .file_wide_first = directives.file_wide.count(),
        .marker_count = 0,
        .marker_first = directives.markers.count(),
        .range_count = 0,
        .range_first = directives.ranges.count(),
    };

    const line_last = try directives.scan_lines(spelling, source, &held);

    try directives.paired(source, &held, line_last);

    directives.scans.push(held);

    assert(held.range_count <= held.marker_count);

    return directives.view_of(directives.scans.count() - 1, source);
}

fn scan_lines(
    directives: *Directives,
    spelling: *const Spelling,
    source: []const u8,
    held: *Scan,
) Error!u32 {
    assert(spelling.ok.len > 0);
    assert(source.len < std.math.maxInt(u32));

    var start: u32 = 0;
    var line: u32 = 0;
    var line_last: u32 = 0;

    for (0..line_count_max) |_| {
        if (start >= source.len) break;

        const newline = std.mem.findScalarPos(u8, source, start, '\n');
        const stop: u32 = if (newline) |index| @intCast(index + 1) else @intCast(source.len);
        const text = std.mem.trimEnd(u8, std.mem.trimEnd(u8, source[start..stop], "\n"), "\r");

        line_last = line;

        if (marker_found(spelling, text)) |found| {
            const marker = try directives.marker_read(spelling, source, text, line, start, found);

            if (directives.markers.full()) return error.DirectivesOutgrown;

            if (marker.level == .file) {
                assert(marker.kind == .ok);

                directives.file_wide.push(held.marker_count);
                held.file_wide_count += 1;
            }

            directives.markers.push(marker);
            held.marker_count += 1;
        }

        assert(stop > start);

        start = stop;
        line += 1;
    } else unreachable;

    return line_last;
}

fn marker_read(
    directives: *Directives,
    spelling: *const Spelling,
    source: []const u8,
    text: []const u8,
    line: u32,
    base: u32,
    found: Found,
) Error!Marker {
    assert(found.start < text.len);
    assert(base + text.len <= source.len);
    assert(line < line_count_max);

    const kind = found.kind;
    const start = found.start;
    const after_word = start + @as(u32, @intCast(word_of(spelling, kind).len));
    const suffix = spelling.file_suffix;
    const file_level = kind == .ok and std.mem.startsWith(u8, text[after_word..], suffix);
    const suffix_width: u32 = if (file_level) @intCast(suffix.len) else 0;
    const end_word: u32 = after_word + suffix_width;
    const rest = text[end_word..];
    const trimmed = trim_start(rest);
    const gap: u32 = @intCast(rest.len - trimmed.len);

    var marker: Marker = .{
        .code_count = 0,
        .code_first = directives.codes.count(),
        .comment = null,
        .kind = kind,
        .level = if (file_level) .file else .line,
        .line = line,
        .malformed = false,
        .range = undefined,
        .reason = null,
    };

    const end = switch (listed(trimmed, kind, gap, end_word)) {
        .named => |named| named: {
            marker.code_count = try directives.codes_push(named, base);

            break :named named.end;
        },
        .plain => |malformed| plain: {
            marker.malformed = malformed;

            break :plain end_word;
        },
        .unclosed => {
            marker.malformed = true;
            marker.range = spanned(base, start, @intCast(text.len));

            return marker;
        },
    };

    const commented_held = commented(text, start, end, base);

    marker.comment = commented_held.comment;
    marker.reason = commented_held.reason;
    marker.range = spanned(base, start, end);

    assert(marker.range.text(source).len == end - start);

    return marker;
}

const Found = struct {
    kind: Kind,
    start: u32,
};

fn marker_found(spelling: *const Spelling, text: []const u8) ?Found {
    assert(spelling.ok.len > 0);
    assert(text.len < std.math.maxInt(u32));

    var best: ?Found = null;

    for ([_]Kind{ .ok, .off, .on }) |kind| {
        const at = std.mem.find(u8, text, word_of(spelling, kind)) orelse continue;

        if (best) |held| {
            if (at >= held.start) continue;
        }

        best = .{ .kind = kind, .start = @intCast(at) };
    }

    if (best) |held| assert(held.start < text.len);

    return best;
}

fn word_of(spelling: *const Spelling, kind: Kind) []const u8 {
    assert(spelling.ok.len > 0);

    return switch (kind) {
        .off => spelling.off,
        .ok => spelling.ok,
        .on => spelling.on,
    };
}

fn listed(trimmed: []const u8, kind: Kind, gap: u32, end: u32) Listed {
    assert(trimmed.len < std.math.maxInt(u32));
    assert(gap <= end + trimmed.len);

    if (!std.mem.startsWith(u8, trimmed, "(")) return .{ .plain = kind != .ok };

    const list = trimmed[1..];
    const close = std.mem.findScalar(u8, list, ')') orelse return .unclosed;

    assert(close < list.len);

    return .{ .named = .{
        .end = end + gap + @as(u32, @intCast(close)) + 2,
        .list = list[0..close],
        .list_offset = end + gap + 1,
    } };
}

fn codes_push(directives: *Directives, named: Named, base: u32) Error!u32 {
    assert(named.list.len < std.math.maxInt(u32));
    assert(base <= std.math.maxInt(u32) - named.list_offset);

    var pieces = std.mem.splitScalar(u8, named.list, ',');
    var offset: u32 = named.list_offset;
    var count: u32 = 0;

    for (0..named.list.len + 1) |_| {
        const piece = pieces.next() orelse break;
        const leading = trim_start(piece);
        const code = trim_end(leading);
        const code_offset = offset + @as(u32, @intCast(piece.len - leading.len));

        offset += @as(u32, @intCast(piece.len)) + 1;

        if (code.len == 0) continue;

        if (directives.codes.full()) return error.DirectivesOutgrown;

        directives.codes.push(.{ .offset = base + code_offset, .length = @intCast(code.len) });
        count += 1;
    } else unreachable;

    assert(count <= named.list.len);

    return count;
}

fn commented(text: []const u8, start: u32, end: u32, base: u32) Commented {
    assert(start <= end);
    assert(end <= text.len);
    assert(base <= std.math.maxInt(u32) - text.len);

    const head = trim_end(text[0..start]);
    const after = text[end..];

    for (paired_comments) |pair| {
        if (!std.mem.endsWith(u8, head, pair.open)) continue;

        const lead: u32 = @intCast(head.len - pair.open.len);
        const at = std.mem.find(u8, after, pair.close) orelse return .none;
        const stop = end + @as(u32, @intCast(at + pair.close.len));

        return .{
            .comment = spanned(base, lead, stop),
            .reason = spoken(after[0..at], base + end),
        };
    }

    for (trailing_comments) |open| {
        if (!std.mem.endsWith(u8, head, open)) continue;

        const lead: u32 = @intCast(head.len - open.len);

        return .{
            .comment = spanned(base, lead, @intCast(text.len)),
            .reason = spoken(after, base + end),
        };
    }

    return .none;
}

fn spoken(reason: []const u8, offset: u32) ?Span {
    assert(reason.len < std.math.maxInt(u32));
    assert(offset <= std.math.maxInt(u32) - reason.len);

    const leading = trim_start(reason);
    const trimmed = trim_end(leading);

    if (trimmed.len == 0) return null;

    const skipped: u32 = @intCast(reason.len - leading.len);

    return .{ .offset = offset + skipped, .length = @intCast(trimmed.len) };
}

fn spanned(base: u32, start: u32, end: u32) Span {
    assert(start <= end);
    assert(base <= std.math.maxInt(u32) - end);

    return .{ .offset = base + start, .length = end - start };
}

fn paired(directives: *Directives, source: []const u8, held: *Scan, line_last: u32) Error!void {
    assert(source.len < std.math.maxInt(u32));
    assert(line_last < line_count_max);

    const view: View = .{ .scan = held.*, .source = source, .directives = directives };
    const markers = view.markers();

    directives.open.clear();

    for (markers, 0..) |marker, index| {
        switch (marker.kind) {
            .off => directives.open.push(@intCast(index)),
            .ok => {},
            .on => {
                const position = open_matching(directives, &view, &marker) orelse continue;
                const off = open_remove(directives, position);

                try directives.range_push(held, .{
                    .closed = true,
                    .end_line = marker.line,
                    .off = off,
                    .on = @intCast(index),
                    .start_line = markers[off].line,
                });
            },
        }
    }

    for (directives.open.const_slice()) |off| {
        try directives.range_push(held, .{
            .closed = false,
            .end_line = line_last,
            .off = off,
            .on = null,
            .start_line = markers[off].line,
        });
    }

    const scan_ranges = directives.ranges.slice()[held.range_first..][0..held.range_count];

    std.sort.insertion(Range, scan_ranges, {}, range_less);

    assert(std.sort.isSorted(Range, scan_ranges, {}, range_less));
}

fn range_push(directives: *Directives, held: *Scan, range: Range) Error!void {
    assert(range.start_line <= range.end_line);

    if (directives.ranges.full()) return error.DirectivesOutgrown;

    directives.ranges.push(range);
    held.range_count += 1;

    assert(range.start_line <= range.end_line);
}

fn range_less(_: void, left: Range, right: Range) bool {
    assert(left.start_line <= left.end_line);
    assert(right.start_line <= right.end_line);

    return left.start_line < right.start_line;
}

fn open_matching(directives: *const Directives, view: *const View, on: *const Marker) ?u32 {
    const open = directives.open.const_slice();
    var position: u32 = @intCast(open.len);

    for (0..open.len) |_| {
        position -= 1;

        if (codes_same(view, &view.markers()[open[position]], on)) return position;
    }

    assert(position == 0);

    return null;
}

fn open_remove(directives: *Directives, position: u32) u32 {
    assert(position < directives.open.count());

    const open = directives.open.slice();
    const removed = open[position];

    @memmove(open[position .. open.len - 1], open[position + 1 ..]);
    directives.open.truncate(@intCast(open.len - 1));

    return removed;
}

fn codes_same(view: *const View, left: *const Marker, right: *const Marker) bool {
    if (left.code_count != right.code_count) return false;

    for (view.codes_of(left)) |span| {
        const code = span.text(view.source);
        var found = false;

        for (view.codes_of(right)) |other| {
            if (std.mem.eql(u8, other.text(view.source), code)) found = true;
        }

        if (!found) return false;
    }

    return true;
}

fn trim_start(text: []const u8) []const u8 {
    assert(text.len < std.math.maxInt(u32));

    var offset: u32 = 0;

    for (0..text.len + 1) |_| {
        if (offset >= text.len) break;

        const width = whitespace_width(text, offset) orelse break;

        offset += width;
    } else unreachable;

    assert(offset <= text.len);

    return text[offset..];
}

fn trim_end(text: []const u8) []const u8 {
    assert(text.len < std.math.maxInt(u32));

    var end: u32 = @intCast(text.len);

    for (0..text.len + 1) |_| {
        if (end == 0) break;

        const width = whitespace_width_before(text, end) orelse break;

        end -= width;
    } else unreachable;

    assert(end <= text.len);

    return text[0..end];
}

fn whitespace_width(text: []const u8, offset: u32) ?u32 {
    assert(offset < text.len);

    const byte = text[offset];

    if (byte < 0x80) return if (ascii_whitespace(byte)) 1 else null;

    const scalar = unicode.decode(text, offset) orelse return null;

    if (!white_space(scalar.value)) return null;

    return scalar.width;
}

fn whitespace_width_before(text: []const u8, end: u32) ?u32 {
    assert(end > 0);
    assert(end <= text.len);

    const byte = text[end - 1];

    if (byte < 0x80) return if (ascii_whitespace(byte)) 1 else null;

    const scalar = unicode.decode_before(text, end) orelse return null;

    if (!white_space(scalar.value)) return null;

    return scalar.width;
}

fn white_space(scalar: u21) bool {
    assert(scalar >= 0x80);

    if (unicode.is_line_terminator(scalar)) return true;
    if (scalar == byte_order_mark) return false;

    return unicode.is_whitespace(scalar);
}

const byte_order_mark: u21 = 0xfeff;

fn ascii_whitespace(byte: u8) bool {
    assert(byte < 0x80);

    return switch (byte) {
        '\t', '\n', 0x0b, 0x0c, '\r', ' ' => true,
        else => false,
    };
}

const capacity_test: Capacity = .{
    .code_count_max = 64,
    .marker_count_max = 64,
    .scan_count_max = 8,
};

const access_verb_test: Names = .{ .code = "GL001", .rule = "glue/access-verb" };
const namespace_mismatch_test: Names = .{ .code = "GL009", .rule = "glue/namespace-mismatch" };
const unregistered_name_test: Names = .{ .code = "GL015", .rule = "glue/unregistered-name" };

const spelling_test: Spelling = .{
    .file_suffix = "-file",
    .off = "lint: off",
    .ok = "lint: ok",
    .on = "lint: on",
};

fn scanned_test(source: []const u8) !Directives {
    assert(source.len < std.math.maxInt(u32));

    var directives: Directives = try .init(std.testing.allocator, &capacity_test);
    errdefer directives.deinit(std.testing.allocator);

    _ = try directives.scan(&spelling_test, source);

    return directives;
}

fn view_test(directives: *const Directives, source: []const u8) View {
    assert(source.len < std.math.maxInt(u32));

    return directives.view_of(0, source);
}

fn marker_first_test(directives: *const Directives, source: []const u8) Marker {
    assert(source.len < std.math.maxInt(u32));

    const view = view_test(directives, source);

    return view.marker(0) orelse @panic("the text carries a marker");
}

fn text_at_test(source: []const u8, span: Span) []const u8 {
    assert(span.end() <= source.len);

    return span.text(source);
}

fn spanned_test(start: u32, end: u32) Span {
    assert(start <= end);

    return .{ .offset = start, .length = end - start };
}

test "a marker suppresses its own line" {
    const source = "<div></div>  {# lint: ok(glue/unregistered-name) #}";
    var directives = try scanned_test(source);
    defer directives.deinit(std.testing.allocator);

    const view = view_test(&directives, source);

    try std.testing.expect(view.suppresses(0, unregistered_name_test));
    try std.testing.expect(!view.suppresses(0, namespace_mismatch_test));
}

test "a marker may name the code instead of the id" {
    const source = "<div></div>  {# lint: ok(GL015) #}";
    var directives = try scanned_test(source);
    defer directives.deinit(std.testing.allocator);

    const view = view_test(&directives, source);

    try std.testing.expect(view.suppresses(0, unregistered_name_test));
    try std.testing.expect(!view.suppresses(0, namespace_mismatch_test));
}

test "a marker suppresses the line below it" {
    const source = "# lint: ok(glue/registration-args)\nGlue.model(request)\n";
    var directives = try scanned_test(source);
    defer directives.deinit(std.testing.allocator);

    const view = view_test(&directives, source);
    const registration_args: Names = .{ .code = "GL011", .rule = "glue/registration-args" };

    try std.testing.expect(view.suppresses(1, registration_args));
}

test "a bare marker suppresses every rule" {
    const source = "// lint: ok\n";
    var directives = try scanned_test(source);
    defer directives.deinit(std.testing.allocator);

    const view = view_test(&directives, source);

    try std.testing.expect(view.suppresses(0, .{ .code = "GL001", .rule = "anything/at-all" }));
}

test "several rules may share a marker" {
    const source = "{# lint: ok(glue/unregistered-name, GL009) #}";
    var directives = try scanned_test(source);
    defer directives.deinit(std.testing.allocator);

    const view = view_test(&directives, source);

    try std.testing.expect(view.suppresses(0, unregistered_name_test));
    try std.testing.expect(view.suppresses(0, namespace_mismatch_test));
    try std.testing.expect(!view.suppresses(0, access_verb_test));
}

test "text without a marker suppresses nothing" {
    const source = "<p>lint is not ok here</p>";
    var directives = try scanned_test(source);
    defer directives.deinit(std.testing.allocator);

    try std.testing.expect(view_test(&directives, source).is_empty());
}

test "a file marker reaches every line" {
    const source = "{# lint: ok-file #}\n<p>one</p>\n<p>two</p>\n";
    var directives = try scanned_test(source);
    defer directives.deinit(std.testing.allocator);

    const view = view_test(&directives, source);

    try std.testing.expect(view.suppresses(0, access_verb_test));
    try std.testing.expect(view.suppresses(2, access_verb_test));
    try std.testing.expectEqual(@as(usize, 1), view.markers().len);
    try std.testing.expectEqual(Level.file, marker_first_test(&directives, source).level);
}

test "a file marker may name the rules it covers" {
    const source = "<p>one</p>\n{# lint: ok-file(GL001, AL002) #}\n<p>two</p>\n";
    var directives = try scanned_test(source);
    defer directives.deinit(std.testing.allocator);

    const view = view_test(&directives, source);
    const shadowed_name: Names = .{ .code = "AL002", .rule = "alpine/shadowed-name" };

    try std.testing.expect(view.suppresses(0, access_verb_test));
    try std.testing.expect(view.suppresses(2, shadowed_name));
    try std.testing.expect(!view.suppresses(2, namespace_mismatch_test));
}

test "a marker records the span of its own text" {
    const source = "<p>x</p>{# lint: ok(GL001) #}\n";
    var directives = try scanned_test(source);
    defer directives.deinit(std.testing.allocator);

    const marker = marker_first_test(&directives, source);

    try std.testing.expectEqual(spanned_test(11, 26), marker.range);
    try std.testing.expectEqualStrings("lint: ok(GL001)", text_at_test(source, marker.range));
}

test "a marker records the comment that holds it alone" {
    const source = "<p>x</p>{# lint: ok(GL001) #}\n";
    var directives = try scanned_test(source);
    defer directives.deinit(std.testing.allocator);

    const comment = marker_first_test(&directives, source).comment orelse {
        return error.TestUnexpectedResult;
    };

    try std.testing.expectEqual(spanned_test(8, 29), comment);
    try std.testing.expectEqualStrings("{# lint: ok(GL001) #}", text_at_test(source, comment));
}

test "a comment holding prose as well records no comment span" {
    const source = "{# TODO drop this lint: ok(GL001) #}\n";
    var directives = try scanned_test(source);
    defer directives.deinit(std.testing.allocator);

    const view = view_test(&directives, source);

    try std.testing.expectEqual(null, marker_first_test(&directives, source).comment);
    try std.testing.expect(view.suppresses(0, access_verb_test));
}

test "every comment shape records its own span" {
    const Case = struct { source: []const u8, expected: []const u8 };

    const cases = [_]Case{
        .{ .source = "<!-- lint: ok -->", .expected = "<!-- lint: ok -->" },
        .{ .source = "/* lint: ok */", .expected = "/* lint: ok */" },
        .{ .source = "let a = 1; // lint: ok", .expected = "// lint: ok" },
        .{ .source = "value = 1  # lint: ok", .expected = "# lint: ok" },
    };

    for (cases) |case| {
        var directives = try scanned_test(case.source);
        defer directives.deinit(std.testing.allocator);

        const comment = marker_first_test(&directives, case.source).comment orelse {
            return error.TestUnexpectedResult;
        };

        try std.testing.expectEqualStrings(case.expected, text_at_test(case.source, comment));
    }
}

test "an unclosed comment records no comment span" {
    const source = "{# lint: ok(GL001)\n";
    var directives = try scanned_test(source);
    defer directives.deinit(std.testing.allocator);

    try std.testing.expectEqual(null, marker_first_test(&directives, source).comment);
}

test "carriage returns do not shift a marker span" {
    const source = "<p>x</p>\r\n{# lint: ok(GL001) #}\r\n";
    var directives = try scanned_test(source);
    defer directives.deinit(std.testing.allocator);

    const marker = marker_first_test(&directives, source);

    try std.testing.expectEqual(@as(u32, 1), marker.line);
    try std.testing.expectEqualStrings("lint: ok(GL001)", text_at_test(source, marker.range));
}

test "the marker that matches is the one reported" {
    const source = "{# lint: ok(GL001) #}\n<p>x</p>{# lint: ok(GL009) #}\n";
    var directives = try scanned_test(source);
    defer directives.deinit(std.testing.allocator);

    const view = view_test(&directives, source);

    try std.testing.expectEqual(@as(?u32, 1), view.matching(1, namespace_mismatch_test));
    try std.testing.expectEqual(@as(?u32, 0), view.matching(1, access_verb_test));
}

test "a trailing reason is read and leaves the comment span whole" {
    const source = "<p>x</p>{# lint: ok(GL001) the api is legacy #}\n";
    var directives = try scanned_test(source);
    defer directives.deinit(std.testing.allocator);

    const view = view_test(&directives, source);
    const marker = view.marker(0) orelse return error.TestUnexpectedResult;

    try std.testing.expectEqual(@as(u32, 1), marker.code_count);
    try std.testing.expectEqualStrings("GL001", view.code_text(&marker, 0));
    try std.testing.expectEqualStrings("the api is legacy", view.reason_of(&marker).?);

    const comment = marker.comment orelse return error.TestUnexpectedResult;

    try std.testing.expectEqualStrings(
        "{# lint: ok(GL001) the api is legacy #}",
        text_at_test(source, comment),
    );
}

test "a script reason runs to the end of the line" {
    const source = "var x = 1; // lint: ok(HS008) legacy island\n";
    var directives = try scanned_test(source);
    defer directives.deinit(std.testing.allocator);

    const view = view_test(&directives, source);
    const marker = view.marker(0) orelse return error.TestUnexpectedResult;

    try std.testing.expectEqualStrings("legacy island", view.reason_of(&marker).?);
}

test "an off and on pair covers the lines between them" {
    const source = "{# lint: off(GL001) #}\n<p>x</p>\n<p>y</p>\n{# lint: on(GL001) #}\n";
    var directives = try scanned_test(source);
    defer directives.deinit(std.testing.allocator);

    const view = view_test(&directives, source);

    try std.testing.expect(view.suppresses(1, .{ .code = "GL001", .rule = "glue/anything" }));
    try std.testing.expect(view.suppresses(2, .{ .code = "GL001", .rule = "glue/anything" }));
    try std.testing.expect(!view.suppresses(1, .{ .code = "GL002", .rule = "glue/other" }));

    const span = if (view.ranges().len > 0) view.ranges()[0] else return error.TestUnexpectedResult;

    try std.testing.expect(span.closed);
    try std.testing.expectEqual(@as(u32, 0), span.start_line);
    try std.testing.expectEqual(@as(u32, 3), span.end_line);
}

test "an unclosed off runs to the end of the file" {
    const source = "{# lint: off(GL001) #}\n<p>x</p>\n<p>y</p>\n";
    var directives = try scanned_test(source);
    defer directives.deinit(std.testing.allocator);

    const view = view_test(&directives, source);
    const span = if (view.ranges().len > 0) view.ranges()[0] else return error.TestUnexpectedResult;

    try std.testing.expect(!span.closed);
    try std.testing.expect(view.suppresses(2, .{ .code = "GL001", .rule = "glue/anything" }));
}

test "an on naming other codes does not close the off beside it" {
    const source = "{# lint: off(GL001) #}\n<p>x</p>\n{# lint: on(GL002) #}\n<p>y</p>\n";
    var directives = try scanned_test(source);
    defer directives.deinit(std.testing.allocator);

    const view = view_test(&directives, source);
    const span = if (view.ranges().len > 0) view.ranges()[0] else return error.TestUnexpectedResult;

    try std.testing.expect(!span.closed);
}

test "a code list that never closes reads as malformed" {
    const source = "<p>x</p>{# lint: ok(GL001 #}\n";
    var directives = try scanned_test(source);
    defer directives.deinit(std.testing.allocator);

    try std.testing.expect(marker_first_test(&directives, source).malformed);
}

test "an off naming no rule reads as malformed" {
    const source = "{# lint: off #}\n<p>x</p>\n";
    var directives = try scanned_test(source);
    defer directives.deinit(std.testing.allocator);

    try std.testing.expect(marker_first_test(&directives, source).malformed);
}

test "scans of two sources keep their own markers" {
    var directives: Directives = try .init(std.testing.allocator, &capacity_test);
    defer directives.deinit(std.testing.allocator);

    const first = "{# lint: off(GL001) #}\n";
    const second = "<p>x</p>\n{# lint: ok(GL009) #}\n";

    _ = try directives.scan(&spelling_test, first);
    _ = try directives.scan(&spelling_test, second);

    const view_first = directives.view_of(0, first);
    const view_second = directives.view_of(1, second);

    try std.testing.expectEqual(@as(usize, 1), view_first.ranges().len);
    try std.testing.expectEqual(@as(usize, 0), view_second.ranges().len);
    try std.testing.expect(view_second.suppresses(1, namespace_mismatch_test));
    try std.testing.expect(!view_second.suppresses(1, access_verb_test));
    try std.testing.expectEqual(@as(u32, 1), view_second.markers()[0].line);
}

test "unicode whitespace trims as rust trims it" {
    try std.testing.expectEqualStrings("a", trim_start("\u{00a0}\u{3000} a"));
    try std.testing.expectEqualStrings("a", trim_end("a \u{2029}\u{0085}"));
    try std.testing.expectEqualStrings("a\u{00e9}", trim_end("a\u{00e9}"));
    try std.testing.expectEqualStrings("\u{feff}a", trim_start("\u{feff}a"));
    try std.testing.expectEqualStrings("", trim_start(" \t\r\n"));
}
