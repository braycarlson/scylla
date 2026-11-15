const std = @import("std");
const assert = std.debug.assert;
const bounded = @import("../stdx/bounded.zig");
const Diagnostics = @import("diagnostics.zig");
const Buffer = bounded.Buffer;
const Diagnostic = Diagnostics.Diagnostic;
const Message = Diagnostics.Message;
const Span = bounded.Span;
const StaticAllocator = @import("../stdx/static_allocator.zig");
const scan = @import("../text/scan.zig");

arena: Buffer,
claimed: bounded.ArrayType(Span),
edits: bounded.ArrayType(Edit),
items: bounded.ArrayType(Fix),
overflowed: bool,
pending: ?Pending,
planned: bounded.ArrayType(Edit),
selected: bounded.ArrayType(u32),

const Fixes = @This();

pub const Capacity = struct {
    edit_count_max: u32,
    fix_count_max: u32,
    text_bytes_max: u32,
};

pub const CapacityError = error{ EditsExhausted, TargetExhausted, TextExhausted };

pub const Applicability = enum(u8) {
    display_only,
    unsafe,
    safe,

    pub fn fix_note(applicability: Applicability) ?[]const u8 {
        return switch (applicability) {
            .display_only => "This fix is shown for reference and is never applied",
            .safe => null,
            .unsafe => "This is an unsafe fix and may change runtime behavior",
        };
    }

    fn name(applicability: Applicability) []const u8 {
        const text: []const u8 = switch (applicability) {
            .display_only => "display-only",
            .safe => "safe",
            .unsafe => "unsafe",
        };

        assert(text.len > 0);

        return text;
    }

    fn rank(applicability: Applicability) u8 {
        const value = @backingInt(applicability);

        assert(value <= @backingInt(Applicability.safe));

        return value;
    }

    pub fn reaches(applicability: Applicability, minimum: Applicability) bool {
        const result = switch (applicability) {
            .display_only => false,
            .safe => true,
            .unsafe => minimum == .unsafe,
        };

        if (result) assert(applicability != .display_only);

        return result;
    }
};

pub const Edit = struct {
    replacement: Span,
    span: Span,
};

const Piece = union(enum) {
    formatted: Span,
    literal: []const u8,
    source: Span,
};

const Marker = struct {
    source: u32,
    target: u32,
};

const Claimed = enum { full, selected, skipped };

pub const Fix = struct {
    applicability: Applicability,
    edit_count: u32,
    edit_start: u32,
    isolation: ?u32,
    title: Message,
};

pub const Pending = struct {
    applicability: Applicability,
    arena_start: u32,
    edit_count: u32,
    edit_start: u32,
    failure: ?CapacityError,
    isolation: ?u32,
    title: Message,
};

pub fn init(gpa: std.mem.Allocator, capacity: Capacity) std.mem.Allocator.Error!Fixes {
    assert(capacity.edit_count_max > 0);
    assert(capacity.fix_count_max > 0);
    assert(capacity.text_bytes_max > 0);

    var arena = try Buffer.init(gpa, capacity.text_bytes_max);
    errdefer arena.deinit(gpa);

    var claimed = try bounded.ArrayType(Span).init(gpa, capacity.edit_count_max);
    errdefer claimed.deinit(gpa);

    var edits = try bounded.ArrayType(Edit).init(gpa, capacity.edit_count_max);
    errdefer edits.deinit(gpa);

    var items = try bounded.ArrayType(Fix).init(gpa, capacity.fix_count_max);
    errdefer items.deinit(gpa);

    var planned = try bounded.ArrayType(Edit).init(gpa, capacity.edit_count_max);
    errdefer planned.deinit(gpa);

    const selected = try bounded.ArrayType(u32).init(gpa, capacity.fix_count_max);

    return .{
        .arena = arena,
        .claimed = claimed,
        .edits = edits,
        .items = items,
        .overflowed = false,
        .pending = null,
        .planned = planned,
        .selected = selected,
    };
}

pub fn deinit(fixes: *Fixes, gpa: std.mem.Allocator) void {
    assert(fixes.items.count() <= fixes.items.capacity());
    assert(fixes.edits.count() <= fixes.edits.capacity());

    fixes.arena.deinit(gpa);
    fixes.claimed.deinit(gpa);
    fixes.edits.deinit(gpa);
    fixes.items.deinit(gpa);
    fixes.planned.deinit(gpa);
    fixes.selected.deinit(gpa);
    fixes.* = undefined;
}

pub fn at(fixes: *const Fixes, fix_index: u32) Fix {
    assert(fix_index < fixes.items.count());

    const held = fixes.items.get(fix_index);

    assert(held.edit_start + held.edit_count <= fixes.edits.count());

    return held;
}

pub fn clear(fixes: *Fixes) void {
    fixes.arena.clear();
    fixes.claimed.clear();
    fixes.edits.clear();
    fixes.items.clear();
    fixes.planned.clear();
    fixes.selected.clear();
    fixes.overflowed = false;
    fixes.pending = null;

    assert(fixes.count() == 0);
    assert(!fixes.is_overflowed());
}

pub fn close(fixes: *Fixes) ?u32 {
    const pending = fixes.pending orelse return null;

    fixes.pending = null;

    if (pending.failure != null) {
        fixes.rewind(&pending);

        return null;
    }

    if (pending.edit_count == 0) {
        fixes.rewind(&pending);

        return null;
    }

    if (fixes.items.full()) {
        fixes.overflowed = true;

        fixes.rewind(&pending);

        return null;
    }

    const fix_index = fixes.items.count();

    fixes.items.push(.{
        .applicability = pending.applicability,
        .edit_count = pending.edit_count,
        .edit_start = pending.edit_start,
        .isolation = pending.isolation,
        .title = pending.title,
    });

    assert(fix_index < fixes.count());
    assert(fixes.pending == null);
    assert(fixes.items.get(fix_index).edit_count > 0);

    return fix_index;
}

pub fn count(fixes: *const Fixes) u32 {
    const held = fixes.items.count();

    assert(held <= fixes.items.capacity());
    assert(fixes.edits.count() <= fixes.edits.capacity());

    return held;
}

pub fn discard(fixes: *Fixes) void {
    const pending = fixes.pending orelse return;

    fixes.pending = null;

    fixes.rewind(&pending);

    assert(fixes.pending == null);
}

pub fn edit(fixes: *Fixes, span: Span, replacement: []const u8) CapacityError!void {
    assert(fixes.pending != null);
    assert(span.length <= std.math.maxInt(u32) - span.offset);
    assert(replacement.len <= std.math.maxInt(u32));

    const pending = &fixes.pending.?;

    assert(pending.edit_start <= fixes.edits.count());

    if (pending.failure) |failure| return failure;

    const arena_before = fixes.arena.count();

    fixes.arena.push(replacement) catch |err| switch (err) {
        error.Overflow => {
            fixes.overflowed = true;
            pending.failure = error.TextExhausted;

            return error.TextExhausted;
        },
    };

    const replacement_span: Span = .{
        .length = @intCast(replacement.len),
        .offset = arena_before,
    };

    try fixes.edit_pushed(span, replacement_span, arena_before);
}

pub fn edit_formatted(
    fixes: *Fixes,
    span: Span,
    comptime format: []const u8,
    arguments: anytype,
) CapacityError!void {
    comptime assert(format.len > 0);
    assert(fixes.pending != null);
    assert(span.length <= std.math.maxInt(u32) - span.offset);
    comptime assert(@typeInfo(@TypeOf(arguments)) == .@"struct");

    const pending = &fixes.pending.?;
    if (pending.failure) |failure| return failure;

    const arena_before = fixes.arena.count();

    const replacement = fixes.written(format, arguments, arena_before) orelse {
        pending.failure = error.TextExhausted;

        return error.TextExhausted;
    };

    try fixes.edit_pushed(span, replacement, arena_before);
}

fn edit_pushed(fixes: *Fixes, span: Span, replacement: Span, arena_before: u32) CapacityError!void {
    const pending = &fixes.pending.?;

    assert(pending.failure == null);
    assert(replacement.offset == arena_before);

    if (fixes.edits.full()) {
        fixes.arena.truncate(arena_before);
        fixes.overflowed = true;
        pending.failure = error.EditsExhausted;

        return error.EditsExhausted;
    }

    fixes.edits.push(.{ .replacement = replacement, .span = span });
    pending.edit_count += 1;

    assert(pending.edit_start + pending.edit_count == fixes.edits.count());
}

pub fn edits_of(fixes: *const Fixes, held: *const Fix) []const Edit {
    const start = held.edit_start;
    const stop = start + held.edit_count;

    assert(held.edit_count > 0);
    assert(stop <= fixes.edits.count());

    return fixes.edits.const_slice()[start..stop];
}

pub fn fix_of(fixes: *const Fixes, held: *const Diagnostic) ?Fix {
    assert(held.code.len > 0);

    const fix_index = held.fix orelse return null;

    assert(fix_index < fixes.items.count());

    return fixes.at(fix_index);
}

pub fn is_overflowed(fixes: *const Fixes) bool {
    assert(fixes.items.count() <= fixes.items.capacity());
    assert(fixes.edits.count() <= fixes.edits.capacity());

    return fixes.overflowed;
}

pub fn is_pending(fixes: *const Fixes) bool {
    assert(fixes.items.count() <= fixes.items.capacity());
    if (fixes.pending) |held| assert(held.edit_start <= fixes.edits.count());

    return fixes.pending != null;
}

pub fn open(fixes: *Fixes, title: []const u8, applicability: Applicability, isolation: ?u32) void {
    assert(title.len > 0);
    assert(fixes.pending == null);
    if (isolation) |held| assert(held < std.math.maxInt(u32));

    fixes.opened(.{ .static = title }, applicability, isolation);
}

pub fn open_formatted(
    fixes: *Fixes,
    applicability: Applicability,
    isolation: ?u32,
    comptime format: []const u8,
    arguments: anytype,
) void {
    comptime assert(format.len > 0);
    assert(fixes.pending == null);
    if (isolation) |held| assert(held < std.math.maxInt(u32));
    comptime assert(@typeInfo(@TypeOf(arguments)) == .@"struct");

    const start = fixes.arena.count();
    var title: Message = .{ .static = Diagnostics.message_unwritten };

    if (fixes.written(format, arguments, start)) |span| {
        title = .{ .arena = span };
    }

    fixes.opened(title, applicability, isolation);
}

fn opened(fixes: *Fixes, title: Message, applicability: Applicability, isolation: ?u32) void {
    assert(fixes.pending == null);
    if (isolation) |held| assert(held < std.math.maxInt(u32));
    if (title == .arena) assert(title.arena.end() <= fixes.arena.count());

    const arena_start = switch (title) {
        .arena => |span| span.offset,
        .static => fixes.arena.count(),
    };

    fixes.pending = .{
        .applicability = applicability,
        .arena_start = arena_start,
        .edit_count = 0,
        .edit_start = fixes.edits.count(),
        .failure = null,
        .isolation = isolation,
        .title = title,
    };

    assert(fixes.pending != null);
}

pub fn reshape(fixes: *Fixes, fix_index: u32, applicability: Applicability) void {
    assert(fix_index < std.math.maxInt(u32));

    if (fix_index >= fixes.items.count()) return;

    fixes.items.slice()[fix_index].applicability = applicability;

    assert(fixes.items.get(fix_index).applicability == applicability);
}

pub fn title_of(fixes: *const Fixes, held: *const Fix) []const u8 {
    assert(held.edit_count > 0);

    switch (held.title) {
        .arena => |span| {
            assert(span.end() <= fixes.arena.count());

            return span.text(fixes.arena.const_slice());
        },
        .static => |text| return text,
    }
}

fn written(fixes: *Fixes, comptime format: []const u8, arguments: anytype, start: u32) ?Span {
    assert(start == fixes.arena.count());
    comptime assert(format.len > 0);
    comptime assert(@typeInfo(@TypeOf(arguments)) == .@"struct");

    fixes.arena.print(format, arguments) catch |err| switch (err) {
        error.Overflow => {
            fixes.overflowed = true;

            return null;
        },
    };

    assert(fixes.arena.count() >= start);

    return Span.between(start, fixes.arena.count());
}

fn render(
    fixes: *Fixes,
    span: Span,
    source: []const u8,
    scratch: []const u8,
    pieces: []const Piece,
) CapacityError!void {
    assert(fixes.pending != null);
    assert(source.len <= std.math.maxInt(u32));
    assert(scratch.len <= std.math.maxInt(u32));
    assert(pieces.len <= std.math.maxInt(u32));

    const pending = &fixes.pending.?;
    if (pending.failure) |failure| return failure;

    const arena_before = fixes.arena.count();

    for (pieces) |piece| {
        const bytes = switch (piece) {
            .formatted => |held| held.text(scratch),
            .literal => |held| held,
            .source => |held| held.text(source),
        };

        fixes.arena.push(bytes) catch |err| switch (err) {
            error.Overflow => {
                fixes.arena.truncate(arena_before);
                fixes.overflowed = true;
                pending.failure = error.TextExhausted;

                return error.TextExhausted;
            },
        };
    }

    assert(fixes.arena.count() >= arena_before);

    if (fixes.edits.full()) {
        fixes.arena.truncate(arena_before);
        fixes.overflowed = true;
        pending.failure = error.EditsExhausted;

        return error.EditsExhausted;
    }

    const replacement = Span.between(arena_before, fixes.arena.count());

    fixes.edits.push(.{ .replacement = replacement, .span = span });
    pending.edit_count += 1;
}

pub fn replacement_of(fixes: *const Fixes, held: *const Edit) []const u8 {
    assert(held.replacement.end() <= fixes.arena.count());
    assert(held.replacement.length <= fixes.arena.capacity());

    return held.replacement.text(fixes.arena.const_slice());
}

fn rewind(fixes: *Fixes, pending: *const Pending) void {
    assert(pending.edit_start <= fixes.edits.count());

    fixes.arena.truncate(pending.arena_start);
    fixes.edits.truncate(pending.edit_start);

    assert(fixes.edits.count() == pending.edit_start);
}

pub fn apply(
    fixes: *Fixes,
    target: *Buffer,
    source: []const u8,
    minimum: Applicability,
) CapacityError!u32 {
    assert(minimum != .display_only);
    assert(source.len <= std.math.maxInt(u32));

    _ = fixes.plan(minimum);

    return fixes.apply_selected(target, source);
}

pub fn apply_ordered(
    fixes: *Fixes,
    target: *Buffer,
    source: []const u8,
    minimum: Applicability,
    ordered: []const u32,
) CapacityError!u32 {
    assert(minimum != .display_only);
    assert(source.len <= std.math.maxInt(u32));
    assert(ordered.len <= std.math.maxInt(u32));

    fixes.plan_ordered(minimum, ordered);

    return fixes.apply_selected(target, source);
}

pub fn applied_slice(fixes: *const Fixes) []const u32 {
    const held = fixes.selected.const_slice();

    assert(held.len <= fixes.items.count());

    return held;
}

fn apply_selected(fixes: *Fixes, target: *Buffer, source: []const u8) CapacityError!u32 {
    assert(source.len <= std.math.maxInt(u32));

    fixes.planned.clear();

    const selected = fixes.selected.slice();
    const length: u32 = @intCast(source.len);
    var applied_count: u32 = 0;
    var cursor: u32 = 0;

    for (selected) |fix_index| {
        const held = fixes.at(fix_index);
        const edits = fixes.edits_of(&held);
        if (!spliceable(source, edits, cursor, length)) continue;

        assert(fixes.planned.unused_capacity() >= edits.len);

        for (edits) |item| {
            fixes.planned.push(item);
            cursor = item.span.end();
        }

        selected[applied_count] = fix_index;
        applied_count += 1;
    }

    assert(applied_count <= selected.len);

    fixes.selected.truncate(applied_count);

    try splice(source, fixes, fixes.planned.const_slice(), target);

    return applied_count;
}

fn splice(
    source: []const u8,
    fixes: *const Fixes,
    edits: []const Edit,
    out: *Buffer,
) CapacityError!void {
    assert(source.len <= std.math.maxInt(u32));
    assert(edits.len <= std.math.maxInt(u32));

    ascending_edits(source, edits);

    out.clear();

    var cursor: u32 = 0;
    var spliced_length: u64 = source.len;

    for (edits) |*held| {
        try copy_through(source, fixes, held, cursor, out);

        cursor = held.span.end();
        spliced_length = spliced_length - held.span.length + held.replacement.length;
    }

    out.push(source[cursor..]) catch |err| switch (err) {
        error.Overflow => {
            out.clear();

            return error.TargetExhausted;
        },
    };

    assert(cursor <= source.len);
    assert(out.count() == spliced_length);
}

fn apply_mapped(
    source: []const u8,
    fixes: *const Fixes,
    edits: []const Edit,
    out: *Buffer,
    markers: *bounded.ArrayType(Marker),
) CapacityError!void {
    assert(source.len <= std.math.maxInt(u32));
    assert(edits.len <= std.math.maxInt(u32));

    ascending_edits(source, edits);

    out.clear();
    markers.clear();

    var cursor: u32 = 0;

    for (edits) |*held| {
        copy_through(source, fixes, held, cursor, out) catch |err| {
            markers.clear();

            return err;
        };

        if (markers.unused_capacity() < 2) {
            out.clear();
            markers.clear();

            return error.TargetExhausted;
        }

        const target = out.count();

        markers.push(.{ .source = held.span.offset, .target = target });
        markers.push(.{ .source = held.span.end(), .target = target });
        cursor = held.span.end();
    }

    out.push(source[cursor..]) catch |err| switch (err) {
        error.Overflow => {
            out.clear();
            markers.clear();

            return error.TargetExhausted;
        },
    };
}

fn offset_after(markers: []const Marker, offset: u32) u32 {
    assert(markers.len <= std.math.maxInt(u32));
    assert(offset < std.math.maxInt(u32));

    var low: usize = 0;
    var high: usize = markers.len;

    for (0..markers.len + 1) |_| {
        if (low >= high) break;

        const middle = low + (high - low) / 2;

        if (markers[middle].source <= offset) {
            low = middle + 1;
        } else {
            high = middle;
        }
    }

    assert(low == high);

    if (low == 0) return offset;

    const held = markers[low - 1];

    if (low < markers.len) {
        if (markers[low].target == held.target) return held.target;
    }

    assert(offset >= held.source);

    return held.target + (offset - held.source);
}

fn ascending_edits(source: []const u8, edits: []const Edit) void {
    assert(source.len <= std.math.maxInt(u32));
    assert(edits.len <= std.math.maxInt(u32));

    const length: u32 = @intCast(source.len);
    var cursor: u32 = 0;

    for (edits) |held| {
        assert(held.span.offset >= cursor);
        assert(held.span.end() <= length);

        cursor = held.span.end();
    }
}

fn copy_through(
    source: []const u8,
    fixes: *const Fixes,
    held: *const Edit,
    cursor: u32,
    out: *Buffer,
) CapacityError!void {
    assert(held.span.offset >= cursor);
    assert(source.len <= std.math.maxInt(u32));

    out.push(source[cursor..held.span.offset]) catch |err| switch (err) {
        error.Overflow => {
            out.clear();

            return error.TargetExhausted;
        },
    };

    out.push(fixes.replacement_of(held)) catch |err| switch (err) {
        error.Overflow => {
            out.clear();

            return error.TargetExhausted;
        },
    };

    assert(out.count() >= held.replacement.length);
}

fn spliceable(source: []const u8, edits: []const Edit, cursor: u32, length: u32) bool {
    assert(edits.len <= std.math.maxInt(u32));
    assert(cursor <= length);
    assert(source.len == length);

    var cursor_edit = cursor;

    for (edits) |held| {
        if (held.span.offset < cursor_edit) return false;
        if (held.span.end() > length) return false;
        if (!scan.is_char_boundary(source, held.span.offset)) return false;
        if (!scan.is_char_boundary(source, held.span.end())) return false;

        cursor_edit = held.span.end();
    }

    assert(cursor_edit >= cursor);

    return true;
}

fn plan(fixes: *Fixes, minimum: Applicability) []const u32 {
    fixes.claimed.clear();
    fixes.selected.clear();

    const fix_count = fixes.count();
    const ordered = ascending(fixes);
    var claimed_end: u32 = 0;
    var visited: u32 = 0;
    var fix_index_prior: ?u32 = null;

    for (0..fix_count) |step| {
        const fix_index: u32 = if (ordered)
            @intCast(step)
        else
            next_of(fixes, fix_index_prior) orelse break;

        fix_index_prior = fix_index;
        visited += 1;

        if (fixes.plan_claim(fix_index, minimum, &claimed_end) == .full) break;
    }

    assert(visited <= fix_count);
    assert(fixes.selected.count() <= fix_count);

    return fixes.selected.const_slice();
}

fn plan_ordered(fixes: *Fixes, minimum: Applicability, ordered: []const u32) void {
    assert(ordered.len <= std.math.maxInt(u32));

    fixes.claimed.clear();
    fixes.selected.clear();

    var claimed_end: u32 = 0;

    for (ordered) |fix_index| {
        assert(fix_index < fixes.count());

        if (fixes.plan_claim(fix_index, minimum, &claimed_end) == .full) break;
    }

    assert(fixes.selected.count() <= ordered.len);
}

fn plan_claim(fixes: *Fixes, fix_index: u32, minimum: Applicability, claimed_end: *u32) Claimed {
    assert(fix_index < fixes.items.count());

    const claimed = &fixes.claimed;
    const selected = &fixes.selected;
    const held = fixes.at(fix_index);
    if (!held.applicability.reaches(minimum)) return .skipped;
    if (isolated(fixes, selected.const_slice(), held.isolation)) return .skipped;

    const edits = fixes.edits_of(&held);
    if (claimed.unused_capacity() < edits.len) return .full;
    if (selected.full()) return .full;
    if (plan_clashes(claimed.const_slice(), claimed_end.*, edits)) return .skipped;
    if (self_overlapping(edits)) return .skipped;

    for (edits) |item| {
        claimed_end.* = @max(claimed_end.*, item.span.end());

        claimed.push(item.span);
    }

    selected.push(fix_index);

    assert(!selected.empty());

    return .selected;
}

fn plan_clashes(claimed: []const Span, claimed_end: u32, edits: []const Edit) bool {
    assert(edits.len > 0);
    if (claimed.len == 0) assert(claimed_end == 0);

    for (edits) |held| {
        if (held.span.offset <= claimed_end) {
            if (overlaps_any(claimed, held.span)) return true;
        }
    }

    return false;
}

fn ascending(fixes: *const Fixes) bool {
    var start_prior: u32 = 0;

    assert(fixes.items.count() <= fixes.items.capacity());

    for (fixes.items.const_slice()) |*held| {
        assert(held.edit_count > 0);

        const start = start_of(fixes, held);
        if (start < start_prior) return false;

        start_prior = start;
    }

    return true;
}

fn isolated(fixes: *const Fixes, selected: []const u32, isolation: ?u32) bool {
    assert(selected.len <= fixes.selected.capacity());
    if (isolation) |held| assert(held < std.math.maxInt(u32));

    const group = isolation orelse return false;

    for (selected) |fix_index| {
        assert(fix_index < fixes.items.count());

        if (fixes.at(fix_index).isolation == group) return true;
    }

    return false;
}

const Key = struct {
    start: u32,
    fix_index: u32,

    fn less(left: Key, right: Key) bool {
        if (left.fix_index == right.fix_index) assert(left.start == right.start);

        if (left.start != right.start) return left.start < right.start;
        return left.fix_index < right.fix_index;
    }
};

fn key_of(fixes: *const Fixes, fix_index: u32) Key {
    assert(fix_index < fixes.items.count());

    const held = fixes.at(fix_index);
    return .{ .start = start_of(fixes, &held), .fix_index = fix_index };
}

fn next_of(fixes: *const Fixes, fix_index_prior: ?u32) ?u32 {
    if (fix_index_prior) |held| assert(held < std.math.maxInt(u32));

    const prior: ?Key = if (fix_index_prior) |held| key_of(fixes, held) else null;
    var best: ?Key = null;

    for (0..fixes.count()) |candidate_index| {
        const candidate = key_of(fixes, @intCast(candidate_index));

        if (prior) |held| {
            if (!held.less(candidate)) continue;
        }

        if (best) |held| {
            if (!candidate.less(held)) continue;
        }

        best = candidate;
    }

    const found = best orelse return null;

    if (prior) |held| assert(held.less(found));

    return found.fix_index;
}

pub fn overlaps(left: Span, right: Span) bool {
    assert(left.length <= std.math.maxInt(u32) - left.offset);
    assert(right.length <= std.math.maxInt(u32) - right.offset);

    const result = overlaps_ordered(left, right);

    assert(result == overlaps_ordered(right, left));

    if (left.length == 0) {
        if (right.length == 0) assert(result == (left.offset == right.offset));
    }

    return result;
}

fn overlaps_ordered(left: Span, right: Span) bool {
    if (left.offset == right.offset) return true;
    if (left.offset >= right.end()) return false;
    return right.offset < left.end();
}

fn overlaps_any(claimed: []const Span, span: Span) bool {
    assert(claimed.len <= std.math.maxInt(u32));
    assert(span.length <= std.math.maxInt(u32) - span.offset);

    for (claimed) |held| {
        if (overlaps(held, span)) return true;
    }

    return false;
}

fn self_overlapping(edits: []const Edit) bool {
    assert(edits.len > 0);

    for (edits, 0..) |held, position| {
        for (edits[position + 1 ..]) |other| {
            if (overlaps(other.span, held.span)) return true;
        }
    }

    return false;
}

fn start_of(fixes: *const Fixes, held: *const Fix) u32 {
    const edits = fixes.edits_of(held);

    assert(edits.len > 0);

    return edits[0].span.offset;
}

const test_ladder = [_]Applicability{ .display_only, .safe, .unsafe };
const test_pass_edit_count_max: u32 = 32;
const test_pass_fix_count_max: u32 = 16;
const test_mapped_bytes_max: u32 = 1 << 8;
const test_mapped_edit_count_max: u32 = 1 << 6;
const test_source_bytes_max: u32 = 1 << 12;

fn test_reserved() !Fixes {
    return Fixes.init(std.testing.allocator, .{
        .edit_count_max = 16,
        .fix_count_max = 8,
        .text_bytes_max = 64,
    });
}

fn test_sized(fix_count_max: u32, edit_count_max: u32, text_bytes_max: u32) !Fixes {
    assert(fix_count_max < std.math.maxInt(u32));
    assert(edit_count_max < std.math.maxInt(u32));
    assert(text_bytes_max < std.math.maxInt(u32));

    return Fixes.init(std.testing.allocator, .{
        .edit_count_max = edit_count_max,
        .fix_count_max = fix_count_max,
        .text_bytes_max = text_bytes_max,
    });
}

fn test_span(offset: u32, length: u32) Span {
    assert(offset < std.math.maxInt(u32));
    assert(length < std.math.maxInt(u32));

    return .{ .length = length, .offset = offset };
}

fn test_one(fixes: *Fixes, title: []const u8, span: Span, replacement: []const u8) !u32 {
    assert(title.len <= std.math.maxInt(u32));
    assert(span.length <= std.math.maxInt(u32) - span.offset);
    assert(replacement.len <= std.math.maxInt(u32));

    fixes.open(title, .safe, null);

    try fixes.edit(span, replacement);

    return fixes.close().?;
}

fn test_rendered(fixes: *const Fixes, fix_index: u32) []const u8 {
    assert(fix_index < std.math.maxInt(u32));

    const held = fixes.at(fix_index);
    const edits = fixes.edits_of(&held);

    assert(edits.len == 1);

    return fixes.replacement_of(&edits[0]);
}

fn test_planned(fixes: *Fixes, minimum: Applicability, target: *[32]u32) []const u32 {
    const selected = fixes.plan(minimum);

    @memcpy(target[0..selected.len], selected);

    return target[0..selected.len];
}

const TestHarness = struct {
    fixes: Fixes,
    target: Buffer,

    fn init(gpa: std.mem.Allocator, target_bytes_max: u32) !TestHarness {
        assert(target_bytes_max < std.math.maxInt(u32));

        return .{
            .fixes = try Fixes.init(gpa, .{
                .edit_count_max = test_pass_edit_count_max,
                .fix_count_max = test_pass_fix_count_max,
                .text_bytes_max = 1_024,
            }),
            .target = try Buffer.init(gpa, target_bytes_max),
        };
    }

    fn deinit(harness: *TestHarness, gpa: std.mem.Allocator) void {
        harness.fixes.deinit(gpa);
        harness.target.deinit(gpa);
    }

    fn applied(harness: *TestHarness, source: []const u8, minimum: Applicability) !u32 {
        assert(source.len <= std.math.maxInt(u32));

        return harness.fixes.apply(&harness.target, source, minimum);
    }
};

const TestMapped = struct {
    marker_count: u32,
    markers: [test_mapped_edit_count_max * 2]Marker,
    text_bytes: [test_mapped_bytes_max]u8,
    text_length: u32,

    fn text(mapped: *const TestMapped) []const u8 {
        assert(mapped.text_length <= test_mapped_bytes_max);

        return mapped.text_bytes[0..mapped.text_length];
    }

    fn markers_slice(mapped: *const TestMapped) []const Marker {
        assert(mapped.marker_count <= test_mapped_edit_count_max * 2);

        return mapped.markers[0..mapped.marker_count];
    }
};

const TestReplace = struct {
    replacement: []const u8,
    span: Span,
};

fn test_mapped_one(
    mapped: *TestMapped,
    source: []const u8,
    span: Span,
    replacement: []const u8,
) !void {
    assert(source.len <= std.math.maxInt(u32));
    assert(replacement.len <= std.math.maxInt(u32));

    const edits: []const TestReplace = &.{.{ .replacement = replacement, .span = span }};

    try test_mapped_many(mapped, source, edits, test_mapped_edit_count_max * 2);
}

fn test_mapped_many(
    mapped: *TestMapped,
    source: []const u8,
    edits: []const TestReplace,
    marker_count_max: u32,
) !void {
    assert(marker_count_max > 0);
    assert(source.len <= std.math.maxInt(u32));
    assert(edits.len <= std.math.maxInt(u32));

    const gpa = std.testing.allocator;
    var fixes = try test_sized(test_mapped_edit_count_max, test_mapped_edit_count_max, 1 << 10);
    defer fixes.deinit(gpa);

    var out = try Buffer.init(gpa, test_source_bytes_max);
    defer out.deinit(gpa);

    var markers: bounded.ArrayType(Marker) = try .init(gpa, marker_count_max);
    defer markers.deinit(gpa);

    fixes.open("rewrite", .safe, null);

    for (edits) |held| try fixes.edit(held.span, held.replacement);

    const index = fixes.close().?;
    const held = fixes.at(index);
    const held_edits = fixes.edits_of(&held);
    var applied = true;

    apply_mapped(source, &fixes, held_edits, &out, &markers) catch |err| switch (err) {
        error.EditsExhausted, error.TargetExhausted, error.TextExhausted => applied = false,
    };

    try std.testing.expectEqual(applied, markers.count() == held_edits.len * 2);

    test_mapped_store(mapped, out.const_slice(), markers.const_slice());
}

fn test_mapped_store(mapped: *TestMapped, text: []const u8, markers: []const Marker) void {
    assert(text.len <= test_mapped_bytes_max);
    assert(markers.len <= test_mapped_edit_count_max * 2);

    @memcpy(mapped.text_bytes[0..text.len], text);
    @memcpy(mapped.markers[0..markers.len], markers);

    mapped.text_length = @intCast(text.len);
    mapped.marker_count = @intCast(markers.len);
}

test Fixes {
    const gpa = std.testing.allocator;
    const source = "let value = 1;";

    var fixes: Fixes = try .init(gpa, .{
        .edit_count_max = 8,
        .fix_count_max = 4,
        .text_bytes_max = 256,
    });

    defer fixes.deinit(gpa);

    var target: Buffer = try .init(gpa, 64);
    defer target.deinit(gpa);

    fixes.open("Rename to `total`", .safe, null);

    try fixes.edit(.{ .length = 5, .offset = 4 }, "total");

    const fix_index = fixes.close().?;
    const fix = fixes.at(fix_index);
    const applied = try fixes.apply(&target, source, .safe);

    try std.testing.expectEqualStrings("Rename to `total`", fixes.title_of(&fix));
    try std.testing.expectEqual(@as(u32, 1), applied);
    try std.testing.expectEqualStrings("let total = 1;", target.const_slice());
}

test "a formatted replacement reads back what was written" {
    var fixes = try test_reserved();
    defer fixes.deinit(std.testing.allocator);

    fixes.open("Rename", .safe, null);

    try fixes.edit_formatted(test_span(4, 5), "total_{d}", .{7});

    const fix_index = fixes.close().?;
    const held = fixes.at(fix_index);

    try std.testing.expectEqualStrings("total_7", fixes.replacement_of(&fixes.edits_of(&held)[0]));
}

test "a formatted replacement that does not fit discards its fix" {
    var fixes = try test_sized(4, 4, 8);
    defer fixes.deinit(std.testing.allocator);

    fixes.open("Rename", .safe, null);

    try std.testing.expectError(
        error.TextExhausted,
        fixes.edit_formatted(test_span(0, 1), "{s}", .{"a replacement far past the arena"}),
    );

    try std.testing.expectEqual(null, fixes.close());
    try std.testing.expect(fixes.is_overflowed());
}

test "a formatted title reads back what was written" {
    var fixes = try test_reserved();
    defer fixes.deinit(std.testing.allocator);

    fixes.open_formatted(.safe, null, "Rename to `{s}`", .{"total"});

    try fixes.edit(test_span(4, 5), "total");

    const fix_index = fixes.close().?;
    const held = fixes.at(fix_index);

    try std.testing.expectEqualStrings("Rename to `total`", fixes.title_of(&held));
    try std.testing.expectEqualStrings("total", fixes.replacement_of(&fixes.edits_of(&held)[0]));
}

test "a reshaped fix carries the applicability it was given" {
    var fixes = try test_reserved();
    defer fixes.deinit(std.testing.allocator);

    fixes.open("Rename", .safe, null);

    try fixes.edit(test_span(4, 5), "total");

    const fix_index = fixes.close().?;

    fixes.reshape(fix_index, .unsafe);

    try std.testing.expectEqual(Applicability.unsafe, fixes.at(fix_index).applicability);

    fixes.reshape(1, .safe);
}

test "an arena that fills says so and discards the fix" {
    var fixes = try test_sized(4, 4, 4);
    defer fixes.deinit(std.testing.allocator);

    fixes.open("Rename", .safe, null);

    try std.testing.expect(fixes.is_pending());
    try std.testing.expectError(error.TextExhausted, fixes.edit(test_span(0, 1), "far too long"));
    try std.testing.expectError(error.TextExhausted, fixes.edit(test_span(2, 1), "a"));
    try std.testing.expectEqual(null, fixes.close());
    try std.testing.expect(!fixes.is_pending());
    try std.testing.expect(fixes.is_overflowed());
}

test "a table that ran out of room says so" {
    var fixes = try test_sized(1, 4, 1 << 8);
    defer fixes.deinit(std.testing.allocator);

    try std.testing.expect(!fixes.is_overflowed());

    for (0..2) |_| {
        fixes.open("Rename", .safe, null);

        try fixes.edit(test_span(0, 1), "a");

        _ = fixes.close();
    }

    try std.testing.expect(fixes.is_overflowed());

    fixes.clear();

    try std.testing.expect(!fixes.is_overflowed());
}

test "a closed fix reads back what went in" {
    var fixes = try test_reserved();
    defer fixes.deinit(std.testing.allocator);

    fixes.open("Rename", .safe, 3);

    try fixes.edit(test_span(4, 5), "total");
    try fixes.edit(test_span(12, 0), ";");

    const fix_index = fixes.close().?;

    try std.testing.expectEqual(@as(u32, 0), fix_index);
    try std.testing.expectEqual(@as(u32, 1), fixes.count());

    const held = fixes.at(fix_index);

    try std.testing.expectEqual(Applicability.safe, held.applicability);
    try std.testing.expectEqual(@as(u32, 2), held.edit_count);
    try std.testing.expectEqual(@as(?u32, 3), held.isolation);
    try std.testing.expectEqualStrings("Rename", fixes.title_of(&held));

    const edits = fixes.edits_of(&held);

    try std.testing.expectEqual(@as(usize, 2), edits.len);
    try std.testing.expectEqual(test_span(4, 5), edits[0].span);
    try std.testing.expectEqualStrings("total", fixes.replacement_of(&edits[0]));
    try std.testing.expectEqual(test_span(12, 0), edits[1].span);
    try std.testing.expectEqualStrings(";", fixes.replacement_of(&edits[1]));
}

test "an edit table overflow discards the open fix" {
    var fixes = try test_sized(4, 2, 64);
    defer fixes.deinit(std.testing.allocator);

    fixes.open("First", .safe, null);

    try fixes.edit(test_span(0, 1), "a");
    try fixes.edit(test_span(2, 1), "b");
    try std.testing.expectError(error.EditsExhausted, fixes.edit(test_span(4, 1), "c"));
    try std.testing.expectEqual(null, fixes.close());
    try std.testing.expectEqual(@as(u32, 0), fixes.count());

    const fix_index = try test_one(&fixes, "Second", test_span(0, 1), "z");

    try std.testing.expectEqual(@as(u32, 0), fix_index);
    try std.testing.expectEqual(@as(u32, 1), fixes.count());
}

test "an arena overflow discards the open fix" {
    var fixes = try test_sized(4, 8, 4);
    defer fixes.deinit(std.testing.allocator);

    fixes.open("First", .safe, null);

    try fixes.edit(test_span(0, 1), "ab");
    try std.testing.expectError(error.TextExhausted, fixes.edit(test_span(2, 1), "cde"));
    try std.testing.expectEqual(null, fixes.close());
    try std.testing.expectEqual(@as(u32, 0), fixes.count());

    const fix_index = try test_one(&fixes, "Second", test_span(0, 1), "wxyz");

    try std.testing.expectEqual(@as(u32, 0), fix_index);

    const held = fixes.at(fix_index);
    const edits = fixes.edits_of(&held);

    try std.testing.expectEqualStrings("wxyz", fixes.replacement_of(&edits[0]));
}

test "a rendered piece of each kind lands alone" {
    const source = "import os, sys";
    const scratch = "os\nimport sys";
    var fixes = try test_reserved();
    defer fixes.deinit(std.testing.allocator);

    fixes.open("Source", .safe, null);

    try fixes.render(test_span(0, 14), source, scratch, &.{.{ .source = test_span(7, 2) }});
    try std.testing.expectEqual(@as(u32, 0), fixes.close());

    fixes.open("Literal", .safe, null);

    try fixes.render(test_span(0, 14), source, scratch, &.{.{ .literal = "pass" }});
    try std.testing.expectEqual(@as(u32, 1), fixes.close());

    fixes.open("Formatted", .safe, null);

    try fixes.render(test_span(0, 14), source, scratch, &.{.{ .formatted = test_span(0, 13) }});
    try std.testing.expectEqual(@as(u32, 2), fixes.close());
    try std.testing.expectEqualStrings("os", test_rendered(&fixes, 0));
    try std.testing.expectEqualStrings("pass", test_rendered(&fixes, 1));
    try std.testing.expectEqualStrings("os\nimport sys", test_rendered(&fixes, 2));
}

test "a rendered fix composes the three piece kinds in order" {
    const source = "import os, sys";
    const scratch = "    ";
    var fixes = try test_reserved();
    defer fixes.deinit(std.testing.allocator);

    fixes.open("Split", .safe, null);

    try fixes.render(test_span(0, 14), source, scratch, &.{
        .{ .source = test_span(0, 9) },
        .{ .literal = "\n" },
        .{ .formatted = test_span(0, 4) },
        .{ .source = test_span(11, 3) },
    });

    try std.testing.expectEqual(@as(u32, 0), fixes.close());
    try std.testing.expectEqualStrings("import os\n    sys", test_rendered(&fixes, 0));
}

test "a rendered fix over no pieces is a deletion" {
    const source = "import os";
    var fixes = try test_reserved();
    defer fixes.deinit(std.testing.allocator);

    fixes.open("Delete", .safe, null);

    try fixes.render(test_span(0, 9), source, &.{}, &.{});
    try std.testing.expectEqual(@as(u32, 0), fixes.close());
    try std.testing.expectEqualStrings("", test_rendered(&fixes, 0));

    const held = fixes.at(0);
    const edits = fixes.edits_of(&held);

    try std.testing.expectEqual(test_span(0, 9), edits[0].span);
    try std.testing.expectEqual(@as(u32, 0), edits[0].replacement.length);
}

test "a rendered fix that outgrows the arena is discarded whole" {
    const source = "import os, sys";
    var fixes = try test_sized(4, 8, 8);
    defer fixes.deinit(std.testing.allocator);

    fixes.open("First", .safe, null);

    const refused = fixes.render(test_span(0, 14), source, &.{}, &.{
        .{ .source = test_span(0, 6) },
        .{ .literal = "abcdef" },
    });

    try std.testing.expectError(error.TextExhausted, refused);
    try std.testing.expectEqual(null, fixes.close());
    try std.testing.expectEqual(@as(u32, 0), fixes.count());
    try std.testing.expect(fixes.is_overflowed());

    fixes.open("Second", .safe, null);

    try fixes.render(test_span(0, 14), source, &.{}, &.{.{ .literal = "pass" }});
    try std.testing.expectEqual(@as(u32, 0), fixes.close());
    try std.testing.expectEqualStrings("pass", test_rendered(&fixes, 0));
}

test "a rendered import splits into two statements" {
    const gpa = std.testing.allocator;
    const source = "import os, sys\n";
    const first = test_span(7, 2);
    const second = test_span(11, 3);
    var fixes = try test_reserved();
    defer fixes.deinit(gpa);

    var out = try Buffer.init(gpa, test_source_bytes_max);
    defer out.deinit(gpa);

    try std.testing.expectEqualStrings("os", first.text(source));
    try std.testing.expectEqualStrings("sys", second.text(source));

    fixes.open("Split the import", .safe, null);

    try fixes.render(test_span(0, second.end()), source, "", &.{
        .{ .source = test_span(0, first.end()) },
        .{ .literal = "\nimport " },
        .{ .source = second },
    });

    const index = fixes.close().?;
    const fix = fixes.at(index);

    try splice(source, &fixes, fixes.edits_of(&fix), &out);
    try std.testing.expectEqualStrings("import os\nimport sys\n", out.const_slice());
}

test "a fix that edits nothing closes to nothing" {
    var fixes = try test_reserved();
    defer fixes.deinit(std.testing.allocator);

    fixes.open("Empty", .safe, null);

    try std.testing.expectEqual(null, fixes.close());
    try std.testing.expectEqual(@as(u32, 0), fixes.count());
    try std.testing.expectEqual(null, fixes.close());
}

test "a cleared table forgets every fix" {
    var fixes = try test_reserved();
    defer fixes.deinit(std.testing.allocator);

    _ = try test_one(&fixes, "Rename", test_span(0, 1), "x");

    fixes.clear();

    try std.testing.expectEqual(@as(u32, 0), fixes.count());
    try std.testing.expectEqual(@as(u32, 0), try test_one(&fixes, "Rename", test_span(0, 1), "y"));
}

test "reaches ranks the strength ladder" {
    for (test_ladder) |applicability| {
        for (test_ladder) |minimum| {
            const expected = switch (applicability) {
                .display_only => false,
                .safe => true,
                .unsafe => minimum == .unsafe,
            };

            try std.testing.expectEqual(expected, applicability.reaches(minimum));
        }
    }

    try std.testing.expect(Applicability.display_only.rank() < Applicability.unsafe.rank());
    try std.testing.expect(Applicability.unsafe.rank() < Applicability.safe.rank());
    try std.testing.expectEqualStrings("display-only", Applicability.display_only.name());
}

test "a plan keeps the earlier of an overlapping pair" {
    var fixes = try test_reserved();
    defer fixes.deinit(std.testing.allocator);

    _ = try test_one(&fixes, "Second", test_span(1, 3), "c");
    _ = try test_one(&fixes, "First", test_span(0, 3), "b");

    var target: [32]u32 = undefined;

    try std.testing.expectEqualSlices(u32, &.{1}, test_planned(&fixes, .safe, &target));
}

test "a plan never selects a display only fix" {
    var fixes = try test_reserved();
    defer fixes.deinit(std.testing.allocator);

    fixes.open("Show", .display_only, null);

    try fixes.edit(test_span(0, 1), "a");

    const fix_index = fixes.close().?;
    var target: [32]u32 = undefined;

    try std.testing.expectEqual(@as(u32, 0), fix_index);
    try std.testing.expectEqual(@as(usize, 0), test_planned(&fixes, .safe, &target).len);
    try std.testing.expectEqual(@as(usize, 0), test_planned(&fixes, .unsafe, &target).len);
}

test "a plan holds an unsafe fix back until the minimum reaches it" {
    var fixes = try test_reserved();
    defer fixes.deinit(std.testing.allocator);

    fixes.open("Discard", .unsafe, null);

    try fixes.edit(test_span(0, 0), "_ = ");

    const fix_index = fixes.close().?;
    var target: [32]u32 = undefined;

    try std.testing.expectEqual(@as(u32, 0), fix_index);
    try std.testing.expectEqual(@as(usize, 0), test_planned(&fixes, .safe, &target).len);
    try std.testing.expectEqualSlices(u32, &.{0}, test_planned(&fixes, .unsafe, &target));
}

test "a plan selects one fix from an isolation group" {
    var fixes = try test_reserved();
    defer fixes.deinit(std.testing.allocator);

    fixes.open("First", .safe, 7);

    try fixes.edit(test_span(0, 3), "1");
    try std.testing.expectEqual(@as(u32, 0), fixes.close());

    fixes.open("Second", .safe, 7);

    try fixes.edit(test_span(4, 3), "2");
    try std.testing.expectEqual(@as(u32, 1), fixes.close());

    fixes.open("Third", .safe, null);

    try fixes.edit(test_span(8, 3), "3");
    try std.testing.expectEqual(@as(u32, 2), fixes.close());

    var target: [32]u32 = undefined;

    try std.testing.expectEqualSlices(u32, &.{ 0, 2 }, test_planned(&fixes, .safe, &target));
}

test "a plan selects one fix from isolation group zero" {
    var fixes = try test_reserved();
    defer fixes.deinit(std.testing.allocator);

    fixes.open("First", .safe, 0);

    try fixes.edit(test_span(0, 3), "1");
    try std.testing.expectEqual(@as(u32, 0), fixes.close());

    fixes.open("Second", .safe, 0);

    try fixes.edit(test_span(4, 3), "2");
    try std.testing.expectEqual(@as(u32, 1), fixes.close());

    var target: [32]u32 = undefined;

    try std.testing.expectEqualSlices(u32, &.{0}, test_planned(&fixes, .safe, &target));
}

test "a plan selects every disjoint fix in one pass" {
    const gpa = std.testing.allocator;
    const source = "def f(l):\n    return l\n";
    const parameter = test_span(6, 1);
    const returned = test_span(21, 1);
    var fixes = try test_reserved();
    defer fixes.deinit(gpa);

    var out = try Buffer.init(gpa, test_source_bytes_max);
    defer out.deinit(gpa);

    try std.testing.expectEqualStrings("l", parameter.text(source));
    try std.testing.expectEqualStrings("l", returned.text(source));

    _ = try test_one(&fixes, "Rename", parameter, "value");
    _ = try test_one(&fixes, "Rename", returned, "value");

    var target: [32]u32 = undefined;
    const selected = test_planned(&fixes, .safe, &target);

    try std.testing.expectEqual(@as(usize, 2), selected.len);
    try std.testing.expectEqualSlices(u32, &.{ 0, 1 }, selected);
    try std.testing.expectEqual(@as(u32, 2), try fixes.apply(&out, source, .safe));
    try std.testing.expectEqualStrings("def f(value):\n    return value\n", out.const_slice());
}

test "a second plan repeats the first" {
    var fixes = try test_reserved();
    defer fixes.deinit(std.testing.allocator);

    _ = try test_one(&fixes, "Second", test_span(6, 2), "y");
    _ = try test_one(&fixes, "First", test_span(0, 2), "x");
    _ = try test_one(&fixes, "Third", test_span(1, 2), "z");

    var target_first: [32]u32 = undefined;
    var target_second: [32]u32 = undefined;
    const first = test_planned(&fixes, .safe, &target_first);
    const second = test_planned(&fixes, .safe, &target_second);

    try std.testing.expectEqualSlices(u32, &.{ 1, 0 }, first);
    try std.testing.expectEqualSlices(u32, first, second);
}

test "an apply splices every edit shape" {
    const gpa = std.testing.allocator;
    const source = "let value = 1;";
    var fixes = try test_reserved();
    defer fixes.deinit(gpa);

    var out = try Buffer.init(gpa, 64);
    defer out.deinit(gpa);

    fixes.open("Every", .safe, null);

    try fixes.edit(test_span(0, 0), "pub ");
    try fixes.edit(test_span(4, 5), "total");
    try fixes.edit(test_span(9, 1), "");
    try fixes.edit(test_span(13, 1), ";;");

    const fix_index = fixes.close().?;
    const held = fixes.at(fix_index);

    try splice(source, &fixes, fixes.edits_of(&held), &out);
    try std.testing.expectEqualStrings("pub let total= 1;;", out.const_slice());
}

test "an ordered apply keeps the first of the order it was given" {
    var fixes = try test_reserved();
    defer fixes.deinit(std.testing.allocator);

    var target = try Buffer.init(std.testing.allocator, test_source_bytes_max);
    defer target.deinit(std.testing.allocator);

    const first = try test_one(&fixes, "one", test_span(0, 5), "one");
    const second = try test_one(&fixes, "two", test_span(3, 5), "two");
    const order = [_]u32{ second, first };
    const source = "abcdefghij";
    const applied_count = try fixes.apply_ordered(&target, source, .safe, &order);

    try std.testing.expectEqual(@as(u32, 1), applied_count);
    try std.testing.expectEqualSlices(u32, &.{second}, fixes.applied_slice());
    try std.testing.expectEqualStrings("abctwoij", target.const_slice());

    const reversed = [_]u32{first};
    const again = try fixes.apply_ordered(&target, source, .safe, &reversed);

    try std.testing.expectEqual(@as(u32, 1), again);
    try std.testing.expectEqualStrings("onefghij", target.const_slice());
}

test "an edit landing inside a character is never spliced" {
    var fixes = try test_reserved();
    defer fixes.deinit(std.testing.allocator);

    var target = try Buffer.init(std.testing.allocator, test_source_bytes_max);
    defer target.deinit(std.testing.allocator);

    _ = try test_one(&fixes, "cut", test_span(1, 1), "x");
    _ = try test_one(&fixes, "tail", test_span(4, 1), "y");

    const source = "\u{1f600}z";
    const applied_count = try fixes.apply(&target, source, .safe);

    try std.testing.expectEqual(@as(u32, 1), applied_count);
    try std.testing.expectEqualStrings("\u{1f600}y", target.const_slice());
}

test "an apply over no edits copies the source" {
    const gpa = std.testing.allocator;
    const source = "let value = 1;";
    var fixes = try test_reserved();
    defer fixes.deinit(gpa);

    var out = try Buffer.init(gpa, 64);
    defer out.deinit(gpa);

    try splice(source, &fixes, &.{}, &out);
    try std.testing.expectEqualStrings(source, out.const_slice());
}

test "an apply that outgrows the target clears it" {
    const gpa = std.testing.allocator;
    const source = "let value = 1;";
    var fixes = try test_reserved();
    defer fixes.deinit(gpa);

    var out = try Buffer.init(gpa, 8);
    defer out.deinit(gpa);

    fixes.open("Rename", .safe, null);

    try fixes.edit(test_span(4, 5), "a_longer_name");

    const fix_index = fixes.close().?;
    const held = fixes.at(fix_index);

    try std.testing.expectError(
        error.TargetExhausted,
        splice(source, &fixes, fixes.edits_of(&held), &out),
    );

    try std.testing.expect(out.empty());
}

test "an apply runs on a frozen thread" {
    const source = "let value = 1;";
    var static_allocator = StaticAllocator.init(std.testing.allocator);
    defer static_allocator.deinit();

    const gpa = static_allocator.allocator();

    var fixes = try Fixes.init(gpa, .{
        .edit_count_max = 16,
        .fix_count_max = 8,
        .text_bytes_max = 64,
    });

    defer fixes.deinit(gpa);

    var out = try Buffer.init(gpa, 64);
    defer out.deinit(gpa);

    static_allocator.transition_from_init_to_static();
    defer static_allocator.transition_from_static_to_deinit();

    fixes.open("Rename", .safe, null);

    try fixes.edit(test_span(4, 5), "total");
    try std.testing.expectEqual(@as(u32, 0), fixes.close());

    const selected = fixes.plan(.safe);

    try std.testing.expectEqualSlices(u32, &.{0}, selected);

    const held = fixes.at(selected[0]);
    const edits = fixes.edits_of(&held);
    const kept = [1]Edit{edits[0]};

    try splice(source, &fixes, &kept, &out);
    try std.testing.expectEqualStrings("let total = 1;", out.const_slice());
}

test "a pass that outgrows the target applies nothing" {
    const source = "let value = 1;";
    var static_allocator = StaticAllocator.init(std.testing.allocator);
    defer static_allocator.deinit();

    var harness = try TestHarness.init(static_allocator.allocator(), 8);
    defer harness.deinit(static_allocator.allocator());

    static_allocator.transition_from_init_to_static();
    defer static_allocator.transition_from_static_to_deinit();

    harness.fixes.open("Rename", .safe, null);

    try harness.fixes.edit(test_span(4, 5), "a_very_long_replacement");
    try std.testing.expect(harness.fixes.close() != null);
    try std.testing.expectError(error.TargetExhausted, harness.applied(source, .safe));
    try std.testing.expect(harness.target.empty());
}

test "one edit splices into the target" {
    const source = "let value = 1;";
    var static_allocator = StaticAllocator.init(std.testing.allocator);
    defer static_allocator.deinit();

    var harness = try TestHarness.init(static_allocator.allocator(), 1_024);
    defer harness.deinit(static_allocator.allocator());

    static_allocator.transition_from_init_to_static();
    defer static_allocator.transition_from_static_to_deinit();

    harness.fixes.open("Rename", .safe, null);

    try harness.fixes.edit(test_span(4, 5), "total");
    try std.testing.expect(harness.fixes.close() != null);
    try std.testing.expectEqual(@as(u32, 1), try harness.applied(source, .safe));
    try std.testing.expectEqualStrings("let total = 1;", harness.target.const_slice());
}

test "an unsafe fix is held back" {
    const source = "work();";
    var static_allocator = StaticAllocator.init(std.testing.allocator);
    defer static_allocator.deinit();

    var harness = try TestHarness.init(static_allocator.allocator(), 1_024);
    defer harness.deinit(static_allocator.allocator());

    static_allocator.transition_from_init_to_static();
    defer static_allocator.transition_from_static_to_deinit();

    harness.fixes.open("Discard", .unsafe, null);

    try harness.fixes.edit(test_span(0, 0), "_ = ");
    try std.testing.expect(harness.fixes.close() != null);
    try std.testing.expectEqual(@as(u32, 0), try harness.applied(source, .safe));
    try std.testing.expectEqualStrings(source, harness.target.const_slice());
    try std.testing.expectEqual(@as(u32, 1), try harness.applied(source, .unsafe));
    try std.testing.expectEqualStrings("_ = work();", harness.target.const_slice());
}

test "an overlapping fix waits for the next pass" {
    const source = "aaaa";
    var static_allocator = StaticAllocator.init(std.testing.allocator);
    defer static_allocator.deinit();

    var harness = try TestHarness.init(static_allocator.allocator(), 1_024);
    defer harness.deinit(static_allocator.allocator());

    static_allocator.transition_from_init_to_static();
    defer static_allocator.transition_from_static_to_deinit();

    harness.fixes.open("First", .safe, null);

    try harness.fixes.edit(test_span(0, 3), "b");
    try std.testing.expect(harness.fixes.close() != null);

    harness.fixes.open("Second", .safe, null);

    try harness.fixes.edit(test_span(1, 3), "c");
    try std.testing.expect(harness.fixes.close() != null);
    try std.testing.expectEqual(@as(u32, 1), try harness.applied(source, .safe));
    try std.testing.expectEqualStrings("ba", harness.target.const_slice());
}

test "one fix per isolation group lands in a pass" {
    const source = "one two";
    var static_allocator = StaticAllocator.init(std.testing.allocator);
    defer static_allocator.deinit();

    var harness = try TestHarness.init(static_allocator.allocator(), 1_024);
    defer harness.deinit(static_allocator.allocator());

    static_allocator.transition_from_init_to_static();
    defer static_allocator.transition_from_static_to_deinit();

    harness.fixes.open("First", .safe, 7);

    try harness.fixes.edit(test_span(0, 3), "1");
    try std.testing.expect(harness.fixes.close() != null);

    harness.fixes.open("Second", .safe, 7);

    try harness.fixes.edit(test_span(4, 3), "2");
    try std.testing.expect(harness.fixes.close() != null);
    try std.testing.expectEqual(@as(u32, 1), try harness.applied(source, .safe));
    try std.testing.expectEqualStrings("1 two", harness.target.const_slice());
}

test "an insertion before an offset shifts it" {
    var mapped: TestMapped = undefined;

    try test_mapped_one(&mapped, "value = read()\n", test_span(0, 0), "import os\n");
    try std.testing.expectEqualStrings("import os\nvalue = read()\n", mapped.text());
    try std.testing.expectEqual(10, offset_after(mapped.markers_slice(), 0));
    try std.testing.expectEqual(18, offset_after(mapped.markers_slice(), 8));
}

test "a deletion after an offset leaves it alone" {
    var mapped: TestMapped = undefined;

    try test_mapped_one(&mapped, "value = read()\n", test_span(8, 6), "");
    try std.testing.expectEqualStrings("value = \n", mapped.text());
    try std.testing.expectEqual(0, offset_after(mapped.markers_slice(), 0));
    try std.testing.expectEqual(5, offset_after(mapped.markers_slice(), 5));
}

test "an offset inside a replaced span maps to the replacement end" {
    var mapped: TestMapped = undefined;

    try test_mapped_one(&mapped, "value = read()\n", test_span(8, 6), "x");
    try std.testing.expectEqualStrings("value = x\n", mapped.text());
    try std.testing.expectEqual(9, offset_after(mapped.markers_slice(), 8));
    try std.testing.expectEqual(9, offset_after(mapped.markers_slice(), 11));
    try std.testing.expectEqual(9, offset_after(mapped.markers_slice(), 13));
    try std.testing.expectEqual(9, offset_after(mapped.markers_slice(), 14));
}

test "an offset past a shortened span shifts back by what it lost" {
    var mapped: TestMapped = undefined;

    try test_mapped_one(&mapped, "value = read()\nother = 2\n", test_span(8, 6), "x");
    try std.testing.expectEqualStrings("value = x\nother = 2\n", mapped.text());
    try std.testing.expectEqual(10, offset_after(mapped.markers_slice(), 15));
    try std.testing.expectEqual(19, offset_after(mapped.markers_slice(), 24));
}

test "two edits shift an offset by what both of them moved" {
    var mapped: TestMapped = undefined;

    try test_mapped_many(&mapped, "a = read()\nb = read()\nc = 3\n", &.{
        .{ .replacement = "x", .span = test_span(4, 6) },
        .{ .replacement = "yy", .span = test_span(15, 6) },
    }, test_mapped_edit_count_max * 2);

    const markers = mapped.markers_slice();

    try std.testing.expectEqualStrings("a = x\nb = yy\nc = 3\n", mapped.text());
    try std.testing.expectEqual(0, offset_after(markers, 0));
    try std.testing.expectEqual(6, offset_after(markers, 11));
    try std.testing.expectEqual(12, offset_after(markers, 18));
    try std.testing.expectEqual(13, offset_after(markers, 22));
    try std.testing.expectEqual(18, offset_after(markers, 27));
}

test "two adjacent edits map the seam to the second replacement end" {
    var mapped: TestMapped = undefined;

    try test_mapped_many(&mapped, "ab\n", &.{
        .{ .replacement = "xx", .span = test_span(0, 1) },
        .{ .replacement = "", .span = test_span(1, 1) },
    }, test_mapped_edit_count_max * 2);

    const markers = mapped.markers_slice();

    try std.testing.expectEqualStrings("xx\n", mapped.text());
    try std.testing.expectEqual(2, offset_after(markers, 0));
    try std.testing.expectEqual(2, offset_after(markers, 1));
    try std.testing.expectEqual(2, offset_after(markers, 2));
    try std.testing.expectEqual(3, offset_after(markers, 3));
}

test "a marker table that fills rolls the whole application back" {
    var mapped: TestMapped = undefined;

    try test_mapped_many(&mapped, "ab\n", &.{
        .{ .replacement = "x", .span = test_span(0, 1) },
        .{ .replacement = "y", .span = test_span(1, 1) },
    }, 3);

    try std.testing.expectEqualStrings("", mapped.text());
    try std.testing.expectEqual(0, mapped.markers_slice().len);
}

test "an empty map answers every offset with itself" {
    try std.testing.expectEqual(0, offset_after(&.{}, 0));
    try std.testing.expectEqual(41, offset_after(&.{}, 41));
}
