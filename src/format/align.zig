const std = @import("std");
const assert = std.debug.assert;
const bounded = @import("../stdx/bounded.zig");
const scan = @import("../text/scan.zig");
const Buffer = bounded.Buffer;

pub const Carry = enum {
    block,
    none,
    raw,
};

pub const Target = union(enum) {
    assign,
    body,
    comment,
    element,
    field,
    key,
    row: u32,
    tag,
    type,
    value,
};

const Comment = enum {
    block,
    proceed,
    refuse,
};

const Counted = struct {
    at: u32,
    count: u32,
    held: bool,
    indent: u32,
    lnsum: u64,
    previous: u32,

    const none: Counted = .{
        .at = 0,
        .count = 0,
        .held = false,
        .indent = 0,
        .lnsum = 0,
        .previous = 0,
    };
};

const Cut = struct {
    head: u32,
    tail: u32,
};

const ElementRun = struct {
    ends: bool,
    growing: bool,
    lead: u32,
    overhead: u32,
    width: u32,
};

const Filled = struct {
    found: u32,
    from: u32,
    held: bool,
    indent: u32,
    to: u32,

    const none: Filled = .{
        .found = 0,
        .from = 0,
        .held = false,
        .indent = 0,
        .to = 0,
    };
};

const Groups = struct {
    at: u32,
    depth: u32,
    held: bool,
    stack: [group_depth_max]Header,

    const none: Groups = .{
        .at = 0,
        .depth = 0,
        .held = false,
        .stack = @splat(.{ .indent = 0, .from = 0, .to = 0 }),
    };

    fn header_of(groups: *Groups, bytes: []const u8, start: u32) ?[]const u8 {
        assert(start <= bytes.len);
        assert(groups.depth <= group_depth_max);

        const stale = !groups.held or start < groups.at;

        if (stale) {
            groups.* = .none;
            groups.held = true;
        }

        if (!groups.header_of_advance(bytes, start)) {
            groups.held = false;

            return group_of(bytes, start);
        }

        groups.at = start;

        const range = line_at(bytes, start);
        const indent = indent_of(bytes[range.from..range.to]);
        var cursor = groups.depth;

        while (cursor > 0) {
            cursor -= 1;

            const header = groups.stack[cursor];

            if (header.indent < indent) {
                return trim_end(body_of(scan.trim_ascii(bytes[header.from..header.to])));
            }
        }

        return null;
    }

    fn header_of_advance(groups: *Groups, bytes: []const u8, start: u32) bool {
        assert(groups.held);
        assert(groups.at <= start);
        assert(bytes.len <= std.math.maxInt(u32));

        var offset = groups.at;

        while (offset < start) {
            const range = line_at(bytes, offset);
            const line = bytes[range.from..range.to];

            offset = range.to + 1;

            if (scan.trim_ascii(line).len == 0) continue;

            const indent = indent_of(line);

            while (groups.depth > 0) {
                if (groups.stack[groups.depth - 1].indent < indent) break;

                groups.depth -= 1;
            }

            if (groups.depth == group_depth_max) return false;

            groups.stack[groups.depth] = .{ .indent = indent, .from = range.from, .to = range.to };
            groups.depth += 1;
        }

        assert(groups.depth <= group_depth_max);

        return true;
    }
};

const Header = struct {
    indent: u32,
    from: u32,
    to: u32,
};

const Kept = struct {
    from: u32,
    held: bool,
    indent: u32,
    to: u32,
    typed: bool,

    const none: Kept = .{
        .from = 0,
        .held = false,
        .indent = 0,
        .to = 0,
        .typed = false,
    };
};

const Memo = struct {
    counted: Counted,
    filled: Filled,
    groups: Groups,
    kept: Kept,

    const none: Memo = .{
        .counted = .none,
        .filled = .none,
        .groups = .none,
        .kept = .none,
    };
};

const Population = struct {
    lnsum: u64,
    count: u32,
    previous: u32,

    const empty: Population = .{ .lnsum = 0, .count = 0, .previous = 0 };
};

const Quotes = struct {
    backtick: bool,
    double: bool,
    single: bool,
    skip: bool,

    const none: Quotes = .{
        .backtick = false,
        .double = false,
        .single = false,
        .skip = false,
    };

    fn inside(quotes: Quotes) bool {
        assert(quotes.opened() <= 1);

        if (quotes.skip) assert(!quotes.backtick);

        return quotes.backtick or quotes.double or quotes.single;
    }

    fn opened(quotes: Quotes) u32 {
        const backtick: u32 = @intFromBool(quotes.backtick);
        const double: u32 = @intFromBool(quotes.double);
        const single: u32 = @intFromBool(quotes.single);

        assert(backtick + double + single < std.math.maxInt(u32));

        return backtick + double + single;
    }

    fn opens(quotes: *Quotes, byte: u8) void {
        assert(!quotes.inside());
        assert(!quotes.skip);

        switch (byte) {
            '"' => quotes.double = true,
            '\'' => quotes.single = true,
            '`' => quotes.backtick = true,
            else => {},
        }

        assert(quotes.opened() <= 1);
    }

    fn step(quotes: *Quotes, byte: u8) void {
        if (quotes.skip) {
            assert(quotes.inside());

            quotes.skip = false;

            return;
        }

        const escapes = quotes.double or quotes.single;

        if (escapes) {
            if (byte == '\\') {
                quotes.skip = true;

                return;
            }
        }

        assert(quotes.opened() <= 1);

        switch (byte) {
            '"' => {
                const toggles = !quotes.single and !quotes.backtick;

                if (toggles) quotes.double = !quotes.double;
            },
            '\'' => {
                const toggles = !quotes.double and !quotes.backtick;

                if (toggles) quotes.single = !quotes.single;
            },
            '`' => {
                const toggles = !quotes.double and !quotes.single;

                if (toggles) quotes.backtick = !quotes.backtick;
            },
            else => {},
        }

        assert(quotes.opened() <= 1);
    }
};

const Range = struct {
    from: u32,
    to: u32,
};

const Ranked = struct {
    first: u32,
    last: u32,
    count: u32,
    lnsum: u64,
};

const Reading = struct {
    body: []const u8,
    closes: bool,
    fielded: ?Cut,
};

const Run = struct {
    width: u32,
    stop: u32,
};

const Spec = enum {
    bare,
    blank,
    typed,
    valued,
};

const attribute_columns = true;
const block_close = "*/";
const block_open = "/*";
const comment = "//";
const comment_caps = true;
const element_attributes = true;
const element_bodies = true;
const element_lifetimes = true;
const element_runs_end = true;
const element_runs_fill = true;
const group_depth_max: u32 = 64;
const padding_max: u32 = 1024;

comptime {
    assert(padding_max < std.math.maxInt(u32));
    assert(comment[0] == block_open[0]);
}

pub fn @"align"(
    bytes: []const u8,
    target: Target,
    line_width: u32,
    out: *Buffer,
) error{Overflow}!void {
    assert(bytes.len <= std.math.maxInt(u32));
    assert(out.capacity() > 0);
    assert(line_width < std.math.maxInt(u32));
    if (target == .row) assert(target.row < std.math.maxInt(u32));

    out.clear();

    const count: u32 = @intCast(bytes.len);
    var carry: Carry = .none;
    var memo: Memo = .none;
    var offset: u32 = 0;

    while (offset < count) {
        const range = line_at(bytes, offset);
        const line = bytes[range.from..range.to];
        const held = carry != .none;
        const opened = align_opened(bytes, range.from, line, target, &memo);
        const opens = !held and opened != null;
        const grouped = opens and opens_a_group(bytes, range.from, target, &memo.groups);
        const empty: Run = .{ .width = 0, .stop = 0 };
        const run = if (grouped) width_of(bytes, offset, target, line_width, &memo) else empty;
        const widened = if (opened) |found| run.width > columns_of(line, found.head) else false;
        const single = run.stop <= range.to + 1 and !widened;
        const passes = !grouped or single or run.width > padding_max;

        if (passes) {
            carry = crosses(line, carry);

            try out.push(bytes[range.from..@min(range.to + 1, count)]);

            offset = range.to + 1;

            continue;
        }

        try align_run(bytes, offset, run, target, &memo, &carry, out);

        offset = run.stop;
    }

    assert(offset >= count);
    assert(out.count() >= count);
}

fn align_opened(bytes: []const u8, from: u32, line: []const u8, target: Target, memo: *Memo) ?Cut {
    assert(from <= bytes.len);
    assert(line.len <= bytes.len - from);
    if (target == .row) assert(target.row < std.math.maxInt(u32));

    const cut = cut_at(bytes, from, line, target, memo) orelse return null;

    if (columnless(bytes, from, line, target, &memo.groups)) return null;
    return cut;
}

fn align_run(
    bytes: []const u8,
    offset: u32,
    run: Run,
    target: Target,
    memo: *Memo,
    carry: *Carry,
    out: *Buffer,
) error{Overflow}!void {
    assert(offset < run.stop);
    assert(run.width <= padding_max);
    assert(bytes.len <= std.math.maxInt(u32));
    if (target == .row) assert(target.row < std.math.maxInt(u32));

    var cursor = offset;

    while (cursor < run.stop) {
        const range = line_at(bytes, cursor);
        const text = bytes[range.from..range.to];
        const crossed = carry.* != .none;

        carry.* = crosses(text, carry.*);

        const found = cut_at(bytes, range.from, text, target, memo);
        const cut = if (crossed) null else found;

        if (cut) |held| {
            try align_cell(text, held, run.width, out);
        } else {
            try out.push(text);
        }

        if (range.to < bytes.len) try out.push("\n");

        cursor = range.to + 1;
    }

    assert(cursor >= run.stop);
}

fn align_cell(text: []const u8, cut: Cut, width: u32, out: *Buffer) error{Overflow}!void {
    assert(cut.head <= cut.tail);
    assert(cut.tail <= text.len);
    assert(width < std.math.maxInt(u32));

    try out.push(text[0..cut.head]);

    const gap = @max((width + 1) -| columns_of(text, cut.head), cut.tail - cut.head);

    try padded(out, gap);
    try out.push(text[cut.tail..]);
}

pub fn crosses(line: []const u8, carry: Carry) Carry {
    assert(line.len <= std.math.maxInt(u32));

    var held = carry;
    var offset: usize = 0;
    var quotes: Quotes = .none;

    while (offset < line.len) {
        const rest = line[offset..];

        if (held == .block) {
            const closes = std.mem.startsWith(u8, rest, block_close);

            if (closes) held = .none;

            offset += if (closes) block_close.len else 1;

            continue;
        }

        if (held == .raw) {
            if (rest[0] == '`') held = .none;

            offset += 1;

            continue;
        }

        if (quotes.inside()) {
            quotes.step(rest[0]);
            offset += 1;

            continue;
        }

        if (std.mem.startsWith(u8, rest, comment)) return .none;

        if (std.mem.startsWith(u8, rest, block_open)) {
            held = .block;
            offset += block_open.len;

            continue;
        }

        if (rest[0] == '`') {
            held = .raw;
            offset += 1;

            continue;
        }

        quotes.opens(rest[0]);
        offset += 1;
    }

    assert(offset == line.len);
    assert(!quotes.backtick);

    return held;
}

fn cut_at(bytes: []const u8, start: u32, line: []const u8, target: Target, memo: *Memo) ?Cut {
    assert(start <= bytes.len);
    assert(line.len <= bytes.len - start);
    if (target == .row) assert(target.row < std.math.maxInt(u32));

    const cut = cut_of(line, target) orelse return null;

    if (target == .value) {
        if (!owns_a_value(bytes, start, line, &memo.kept)) return null;
    }

    assert(cut.head <= cut.tail);

    return cut;
}

fn owns_a_value(bytes: []const u8, start: u32, line: []const u8, kept: *Kept) bool {
    assert(start <= bytes.len);
    assert(line.len <= bytes.len - start);

    return switch (spec_of(line)) {
        .typed => true,
        .valued => keeps_a_type(bytes, start, indent_of(line), kept),
        .bare, .blank => false,
    };
}

fn columnless(
    bytes: []const u8,
    start: u32,
    line: []const u8,
    target: Target,
    groups: *Groups,
) bool {
    assert(start <= bytes.len);
    assert(line.len <= bytes.len - start);
    if (target == .row) assert(target.row < std.math.maxInt(u32));

    if (target == .element) {
        if (!attribute_columns) return false;

        const attribute = groups.header_of(bytes, start) orelse return false;
        return attributed(attribute);
    }

    if (target != .comment) return false;

    const body = scan.trim_ascii(body_of(line));
    const named = std.mem.startsWith(u8, body, "case ") or labelled(body);
    const labels = std.mem.endsWith(u8, body, ":") and named;
    if (labels) return !continues_a_list(bytes, start);
    if (!std.mem.endsWith(u8, body, ",")) return false;

    const header = groups.header_of(bytes, start) orelse return false;
    return declares(header) or std.mem.endsWith(u8, header, "struct {");
}

fn opens_a_group(bytes: []const u8, start: u32, target: Target, groups: *Groups) bool {
    assert(start <= bytes.len);
    assert(groups.depth <= group_depth_max);
    if (target == .row) assert(target.row < std.math.maxInt(u32));

    switch (target) {
        .assign, .field, .tag, .value => {},
        .body, .comment, .element, .key, .row, .type => return true,
    }

    const line = groups.header_of(bytes, start) orelse return false;

    return switch (target) {
        .assign => declares(line),
        .field => declares(line) or std.mem.endsWith(u8, line, "struct {") or
            std.mem.endsWith(u8, line, "interface {"),
        .tag => std.mem.endsWith(u8, line, "struct {"),
        .value => specifies(line),
        .body, .comment, .element, .key, .row, .type => unreachable,
    };
}

fn width_of(bytes: []const u8, start: u32, target: Target, line_width: u32, memo: *Memo) Run {
    assert(start < bytes.len);
    assert(line_width < std.math.maxInt(u32));
    if (target == .row) assert(target.row < std.math.maxInt(u32));

    const range = line_at(bytes, start);
    const line = bytes[range.from..range.to];
    const indent = indent_of(line);
    const tagged = struct_tagged(line);

    assert(indent <= line.len);

    switch (target) {
        .element => return elements_run(bytes, start, indent, line_width, &memo.groups),
        .row => |column| return rows_run(bytes, start, indent, column),
        .value => return values_run(bytes, start, indent, &memo.kept),
        .assign, .body, .comment, .field, .key, .tag, .type => {},
    }

    const filled = filled_at(bytes, start, indent, target, memo);
    const run = run_of(bytes, start, indent, target, tagged, memo);

    assert(run.stop >= start);

    return .{ .width = @max(run.width, filled -| 1), .stop = run.stop };
}

fn elements_run(
    bytes: []const u8,
    start: u32,
    indent: u32,
    line_width: u32,
    groups: *Groups,
) Run {
    assert(start < bytes.len);
    assert(indent <= bytes.len - start);
    assert(line_width < std.math.maxInt(u32));

    if (elements_run_attributed(bytes, start, groups)) {
        return .{ .width = 0, .stop = line_at(bytes, start).to + 1 };
    }

    var carry: Carry = .none;
    var offset = start;
    var stop = start;

    var run: ElementRun = .{
        .ends = false,
        .growing = true,
        .lead = if (elements_opened(bytes, start)) indent else 0,
        .overhead = 0,
        .width = 0,
    };

    while (offset < bytes.len) {
        const range = line_at(bytes, offset);
        const line = bytes[range.from..range.to];
        const held = carry != .none;

        carry = crosses(line, carry);

        const active = !held and scan.trim_ascii(line).len > 0;

        if (active) {
            if (!elements_run_line(&run, line, indent, line_width, offset > start)) break;
        } else {
            run.growing = false;
        }

        stop = range.to + 1;
        offset = range.to + 1;

        if (run.ends) break;
    }

    assert(stop >= start);
    assert(run.width <= stop - start);

    return .{ .width = run.width, .stop = stop };
}

fn elements_opened(bytes: []const u8, start: u32) bool {
    assert(start <= bytes.len);

    const before = line_before(bytes, start) orelse return false;
    const body = scan.trim_ascii(bytes[before.from..before.to]);
    if (body.len == 0) return false;
    return std.mem.findScalar(u8, "([{", body[body.len - 1]) != null;
}

fn elements_run_attributed(bytes: []const u8, start: u32, groups: *Groups) bool {
    assert(start < bytes.len);
    assert(groups.depth <= group_depth_max);

    if (!element_attributes) return false;

    const header = groups.header_of(bytes, start) orelse return false;
    return std.mem.startsWith(u8, trim_start(header), "#[");
}

fn elements_run_line(
    run: *ElementRun,
    line: []const u8,
    indent: u32,
    line_width: u32,
    late: bool,
) bool {
    assert(line.len <= std.math.maxInt(u32));
    assert(line_width < std.math.maxInt(u32));

    const body = scan.trim_ascii(line);

    assert(body.len > 0);
    assert(!run.ends);

    if (indent_of(line) != indent) return false;
    if (commented(body)) return false;

    const found = cut_of(line, .element);
    const filled = element_runs_fill and elements_run_fills(line, found);

    const cut = found orelse {
        if (element_runs_end) return false;

        run.growing = false;

        return true;
    };

    const halts = filled and late;
    if (halts) return false;
    if (!run.growing) return true;

    if (!capped(line, cut, indent, line_width, run.lead, &run.overhead)) {
        run.width = @max(run.width, columns_of(line, cut.head));
    }

    run.ends = filled;

    return true;
}

fn elements_run_fills(line: []const u8, found: ?Cut) bool {
    if (found) |held| assert(held.head <= held.tail);

    const cut = found orelse return false;

    assert(cut.head <= cut.tail);
    assert(cut.tail < line.len);

    return separators(line, indent_of(line), cut.head) > 1;
}

fn capped(
    line: []const u8,
    cut: Cut,
    indent: u32,
    line_width: u32,
    lead: u32,
    overhead: *u32,
) bool {
    assert(cut.head <= cut.tail);
    assert(cut.tail <= line.len);

    if (!comment_caps) return false;
    if (line_width == 0) return false;
    assert(indent < std.math.maxInt(u32));

    if (overhead.* == 0) {
        if (!commented(line[cut.tail..])) return false;

        const length: u32 = @intCast(line.len);

        overhead.* = (columns_of(line, cut.head) -| lead) + columns_of(line, length) -
            columns_of(line, cut.tail);

        return false;
    }

    const inner = columns_of(line, cut.head) -| (indent + 1);
    return inner + overhead.* > line_width;
}

fn rows_run(bytes: []const u8, start: u32, indent: u32, column: u32) Run {
    assert(start < bytes.len);
    assert(indent <= bytes.len - start);
    assert(column < std.math.maxInt(u32));

    var carry: Carry = .none;
    var offset = start;
    var stop = start;
    var width: u32 = 0;

    while (offset < bytes.len) {
        const range = line_at(bytes, offset);
        const line = bytes[range.from..range.to];
        const held = carry != .none;

        carry = crosses(line, carry);

        const coded_line = !held and !commented(scan.trim_ascii(line));

        if (coded_line) {
            if (indent_of(line) != indent) break;

            const cut = cut_of(line, .{ .row = column }) orelse break;

            width = @max(width, columns_of(line, cut.head));
        }

        stop = range.to + 1;
        offset = range.to + 1;
    }

    assert(stop >= start);
    assert(width <= stop - start);

    return .{ .width = width, .stop = stop };
}

fn values_run(bytes: []const u8, start: u32, indent: u32, kept: *Kept) Run {
    assert(start < bytes.len);
    assert(indent <= bytes.len - start);

    const first = line_at(bytes, start).to;
    if (cut_of(bytes[start..first], .value) == null) return .{ .width = 0, .stop = start };

    var edge = start;
    var width: u32 = 0;

    while (line_before(bytes, edge)) |before| {
        assert(before.from < edge);

        const range = line_at(bytes, before.from);
        const line = bytes[range.from..range.to];
        const found = celled_at(bytes, range.from, line, indent, kept) orelse break;

        width = @max(width, found);
        edge = range.from;
    }

    var offset = start;
    var stop = start;

    while (offset < bytes.len) {
        const range = line_at(bytes, offset);
        const line = bytes[range.from..range.to];
        const found = celled_at(bytes, range.from, line, indent, kept) orelse break;

        width = @max(width, found);
        stop = range.to + 1;
        offset = range.to + 1;
    }

    assert(edge <= start);
    assert(stop >= start);

    return .{ .width = width, .stop = stop };
}

fn celled_at(bytes: []const u8, start: u32, line: []const u8, indent: u32, kept: *Kept) ?u32 {
    assert(start <= bytes.len);
    assert(line.len <= bytes.len - start);

    if (indent_of(line) != indent) return null;

    const field = cut_of(line, .field) orelse return null;

    switch (spec_of(line)) {
        .bare => {},
        .blank => return columns_of(line, field.tail),
        .typed => {
            if (cut_of(line, .value)) |cut| return columns_of(line, cut.head);
        },
        .valued => {
            if (keeps_a_type(bytes, start, indent, kept)) return columns_of(line, field.tail);
        },
    }

    if (line_commented(line)) return columns_of(line, coded(line));
    return null;
}

fn keeps_a_type(bytes: []const u8, start: u32, indent: u32, kept: *Kept) bool {
    assert(start <= bytes.len);
    assert(indent < std.math.maxInt(u32));

    const known = kept.held and kept.indent == indent;
    const fresh = known and kept.from <= start and start < kept.to;
    if (fresh) return kept.typed;

    const first = line_at(bytes, start).from;
    var from = first;
    var typed = false;

    while (line_before(bytes, from)) |before| {
        assert(before.from < from);

        const line = bytes[before.from..before.to];
        if (!keeps_a_type_runs(line, indent)) break;

        if (spec_of(line) == .typed) typed = true;

        from = before.from;
    }

    var offset = first;
    var to = first;

    while (offset < bytes.len) {
        const range = line_at(bytes, offset);
        const line = bytes[range.from..range.to];
        if (!keeps_a_type_runs(line, indent)) break;

        if (spec_of(line) == .typed) typed = true;

        to = range.to + 1;
        offset = range.to + 1;
    }

    kept.* = .{ .from = from, .held = true, .indent = indent, .to = to, .typed = typed };

    assert(from <= first);
    assert(to >= first);

    return typed;
}

fn keeps_a_type_runs(line: []const u8, indent: u32) bool {
    if (indent_of(line) != indent) return false;
    return cut_of(line, .value) != null;
}

fn filled_at(bytes: []const u8, start: u32, indent: u32, target: Target, memo: *Memo) u32 {
    assert(start < bytes.len);
    assert(indent < std.math.maxInt(u32));
    if (target == .row) assert(target.row < std.math.maxInt(u32));

    if (target != .comment) return 0;

    const header = memo.groups.header_of(bytes, start) orelse return 0;
    if (!declares(header)) return 0;

    const filled = memo.filled;
    const known = filled.held and filled.indent == indent;
    const fresh = known and filled.from <= start and start < filled.to;
    if (fresh) return filled.found;

    const from = line_at(bytes, start).from;
    var found: u32 = 0;
    var edge = from;

    while (line_before(bytes, edge)) |before| {
        assert(before.from < edge);

        const range = line_at(bytes, before.from);
        const line = bytes[range.from..range.to];
        if (!blocked(line, indent)) break;

        found = @max(found, valued_at(line) orelse 0);
        edge = range.from;
    }

    var offset = from;

    while (offset < bytes.len) {
        const range = line_at(bytes, offset);
        const line = bytes[range.from..range.to];
        if (!blocked(line, indent)) break;

        found = @max(found, valued_at(line) orelse 0);
        offset = range.to + 1;
    }

    memo.filled = .{ .found = found, .from = edge, .held = true, .indent = indent, .to = offset };

    assert(edge <= from);
    assert(offset >= from);

    return found;
}

fn blocked(line: []const u8, indent: u32) bool {
    assert(line.len <= std.math.maxInt(u32));

    const body = scan.trim_ascii(line);

    assert(body.len <= line.len);

    if (body.len == 0) return false;
    if (indent_of(line) != indent) return false;
    if (std.mem.findScalar(u8, body, ' ') == null) return false;

    assert(body.len > 1);

    return !commented(body);
}

fn valued_at(line: []const u8) ?u32 {
    assert(line.len <= std.math.maxInt(u32));

    const indent: usize = indent_of(line);
    var depth: i32 = 0;
    var quotes: Quotes = .none;

    assert(indent <= line.len);

    for (line[indent..], indent..) |byte, held| {
        if (quotes.inside()) {
            quotes.step(byte);

            continue;
        }

        if (commented(line[held..])) return null;

        switch (byte) {
            '(', '[', '{' => depth += 1,
            ')', ']', '}' => depth -= 1,
            '=' => {
                const level = depth == 0 and held > indent;
                const spaced = level and line[held - 1] == ' ' and byte_is(line, held + 1, ' ');

                if (spaced) {
                    const returned = columns_of(line, @intCast(held));

                    assert(returned < std.math.maxInt(u32));

                    return returned;
                }
            },
            else => quotes.opens(byte),
        }
    }

    assert(@abs(depth) <= line.len);

    return null;
}

fn run_of(
    bytes: []const u8,
    start: u32,
    indent: u32,
    target: Target,
    tagged: bool,
    memo: *Memo,
) Run {
    assert(start < bytes.len);
    assert(target != .row);
    assert(indent < std.math.maxInt(u32));

    var sums = run_of_sums(bytes, start, indent, target, &memo.counted);
    var carry: Carry = .none;
    var listed = false;
    var offset = start;
    var stop = start;
    var width: u32 = 0;

    while (offset < bytes.len) {
        const range = line_at(bytes, offset);
        const line = bytes[range.from..range.to];
        const held = carry != .none;

        carry = crosses(line, carry);

        if (held) {
            stop = range.to + 1;
            offset = range.to + 1;

            continue;
        }

        const spanned = depth_of(line);
        const spans = target == .comment and spanned > 0 and listed;

        if (indent_of(line) != indent) break;
        if (run_of_tags(line, target, tagged)) break;
        if (spans) break;
        if (columnless(bytes, range.from, line, target, &memo.groups)) break;

        const cut = cut_of(line, target) orelse break;
        const element = std.mem.endsWith(u8, trim_end(body_of(line)), ",");
        const weighs = target == .key or (target == .comment and element);
        const entry = ranked(line);

        if (weighs) {
            if (!run_of_weigh(&entry, &sums, offset > start)) break;
        }

        const nests = target == .key and (spanned > 0 or carry != .none);
        if (nests) break;

        if (entry) |*found| run_of_add(&sums, found);

        listed = element;
        width = @max(width, columns_of(line, cut.head));
        stop = range.to + 1;
        offset = range.to + 1;

        if (run_of_ends(line, target, element, spanned)) break;
    }

    assert(stop >= start);

    return .{ .width = width, .stop = stop };
}

fn run_of_sums(
    bytes: []const u8,
    start: u32,
    indent: u32,
    target: Target,
    counted: *Counted,
) Population {
    assert(start < bytes.len);
    assert(target != .element);
    assert(indent < std.math.maxInt(u32));

    return switch (target) {
        .comment, .key => population(bytes, start, indent, counted),
        .assign, .body, .element, .field, .row, .tag, .type, .value => .empty,
    };
}

fn run_of_tags(line: []const u8, target: Target, tagged: bool) bool {
    assert(target != .element);
    assert(target != .value);
    assert(line.len <= std.math.maxInt(u32));

    return switch (target) {
        .comment, .tag => struct_tagged(line) != tagged,
        .assign, .body, .element, .field, .key, .row, .type, .value => false,
    };
}

fn run_of_weigh(entry: *const ?Ranked, sums: *Population, late: bool) bool {
    const found = entry.* orelse return true;

    assert(found.count > 0);
    assert(found.first > 0);

    if (!parts_run(found.first, sums.previous, sums.lnsum, sums.count)) return true;
    if (late) return false;

    sums.count = 0;
    sums.lnsum = 0;

    return true;
}

fn run_of_add(sums: *Population, entry: *const Ranked) void {
    assert(entry.count > 0);
    assert(entry.last > 0);

    sums.count += entry.count;
    sums.lnsum += entry.lnsum;
    sums.previous = entry.last;
}

fn run_of_ends(line: []const u8, target: Target, element: bool, spanned: i32) bool {
    assert(line.len > 0);
    if (target == .row) assert(target.row < std.math.maxInt(u32));

    const listing = target == .comment or target == .key;
    const elements = element and elements_of(line) > 1 and listing;
    const closes = target == .key and spanned < 0;
    const spans = target == .comment and spanned != 0;

    if (element) assert(std.mem.findScalar(u8, line, ',') != null);

    return elements or closes or spans;
}

fn population(bytes: []const u8, start: u32, indent: u32, counted: *Counted) Population {
    assert(start <= bytes.len);
    assert(indent < std.math.maxInt(u32));

    const known = counted.held and counted.indent == indent;
    const stale = !known or counted.at > start;

    if (stale) {
        const head = list_head(bytes, start, indent);

        counted.* = .{
            .at = head,
            .count = 0,
            .held = true,
            .indent = indent,
            .lnsum = 0,
            .previous = 0,
        };
    }

    var sums: Population = .{
        .lnsum = counted.lnsum,
        .count = counted.count,
        .previous = counted.previous,
    };

    var offset = counted.at;

    while (offset < start) {
        const range = line_at(bytes, offset);
        const line = bytes[range.from..range.to];

        offset = range.to + 1;

        if (population_resets(line, indent)) {
            sums = .empty;

            continue;
        }

        if (indent_of(line) != indent) continue;

        const entry = ranked(line) orelse continue;

        if (parts_run(entry.first, sums.previous, sums.lnsum, sums.count)) {
            sums.count = 0;
            sums.lnsum = 0;
        }

        run_of_add(&sums, &entry);
    }

    counted.* = .{
        .at = start,
        .count = sums.count,
        .held = true,
        .indent = indent,
        .lnsum = sums.lnsum,
        .previous = sums.previous,
    };

    assert(offset >= start);

    return sums;
}

fn population_resets(line: []const u8, indent: u32) bool {
    if (scan.trim_ascii(line).len == 0) return true;

    const held = indent_of(line);

    assert(held < line.len);

    if (held < indent) return true;
    return held == indent and parts_entries(line, indent);
}

fn list_head(bytes: []const u8, start: u32, indent: u32) u32 {
    assert(start <= bytes.len);
    assert(indent < std.math.maxInt(u32));

    var head = start;
    var offset = start;

    while (line_before(bytes, offset)) |before| {
        assert(before.from < offset);

        const line = bytes[before.from..before.to];
        if (scan.trim_ascii(line).len == 0) break;
        if (indent_of(line) < indent) break;

        const parts = indent_of(line) == indent and parts_entries(line, indent);
        if (parts) break;

        head = before.from;
        offset = before.from;
    }

    assert(head <= start);

    return head;
}

fn parts_entries(line: []const u8, indent: u32) bool {
    assert(line.len <= std.math.maxInt(u32));
    assert(indent < std.math.maxInt(u32));

    const held = line[@min(indent, line.len)..];

    assert(held.len <= line.len);

    return commented(held);
}

fn ranked(line: []const u8) ?Ranked {
    if (depth_of(line) != 0) return null;

    if (cut_of(line, .key)) |key| {
        const width = columns_of(line, key.head) -| (indent_of(line) + 1);
        if (width == 0) return null;

        assert(width <= line.len);

        return .{ .first = width, .last = width, .count = 1, .lnsum = log2_of(width) };
    }

    const entry = elements_ranked(line);

    if (entry) |found| assert(found.count > 0);

    return entry;
}

fn elements_ranked(line: []const u8) ?Ranked {
    assert(line.len <= std.math.maxInt(u32));

    const indent: usize = indent_of(line);
    const body = trim_end(body_of(line));
    if (body.len <= indent) return null;

    var depth: i32 = 0;
    var entry: Ranked = .{ .first = 0, .last = 0, .count = 0, .lnsum = 0 };
    var quotes: Quotes = .none;
    var start = indent;

    for (indent..body.len + 1) |held| {
        const byte = if (held < body.len) body[held] else ',';

        if (quotes.inside()) {
            quotes.step(byte);

            continue;
        }

        switch (byte) {
            '(', '[', '{' => depth += 1,
            ')', ']', '}' => depth -= 1,
            ',' => {
                if (depth == 0) {
                    assert(start <= held);

                    elements_ranked_count(&entry, body[start..held]);
                    start = elements_ranked_skip(body, held + 1);
                }
            },
            else => quotes.opens(byte),
        }
    }

    if (entry.count == 0) return null;

    assert(entry.first > 0);

    return entry;
}

fn elements_ranked_count(entry: *Ranked, segment: []const u8) void {
    assert(segment.len <= std.math.maxInt(u32));

    const width = columns_of(segment, @intCast(segment.len));

    assert(width <= segment.len);

    if (width == 0) return;

    if (entry.count == 0) entry.first = width;

    entry.count += 1;
    entry.last = width;
    entry.lnsum += log2_of(width);

    assert(entry.first > 0);
}

fn elements_ranked_skip(body: []const u8, from: usize) usize {
    assert(body.len <= std.math.maxInt(u32));
    assert(from < std.math.maxInt(u32));

    var start = from;

    while (start < body.len) : (start += 1) {
        if (body[start] != ' ') break;
    }

    assert(start >= from);

    return start;
}

fn parts_run(size: u32, previous: u32, lnsum: u64, count: u32) bool {
    assert(lnsum <= @as(u64, count) * (32 << 16));

    const ratio: u32 = 86630;
    const small: u32 = 40;

    if (previous == 0) return false;
    if (size == 0) return false;
    if (count == 0) return false;

    const tiny = previous <= small and size <= small;
    if (tiny) return false;

    const mean = std.math.cast(u32, @divFloor(lnsum, count)) orelse std.math.maxInt(u32);
    const held = log2_of(size);

    assert(held < 32 << 16);

    return held + ratio <= mean or held >= mean +| ratio;
}

fn log2_of(value: u32) u32 {
    assert(value < std.math.maxInt(u32));

    const one: u64 = 1 << 16;
    const two: u64 = 2 << 16;

    if (value == 0) return 0;

    const bits = std.math.log2_int(u32, value);
    var found: u64 = @as(u64, bits) << 16;
    var held: u64 = (@as(u64, value) << 16) >> bits;
    var step: u64 = one >> 1;

    while (step > 0) : (step >>= 1) {
        assert(held >= one);
        assert(held < two);

        held = (held * held) >> 16;

        if (held >= two) {
            held >>= 1;
            found += step;
        }
    }

    return std.math.cast(u32, found) orelse std.math.maxInt(u32);
}

fn elements_of(line: []const u8) u32 {
    assert(line.len <= std.math.maxInt(u32));

    const body = trim_end(body_of(line));
    if (!std.mem.endsWith(u8, body, ",")) return 1;

    var depth: i32 = 0;
    var found: u32 = 0;
    var quotes: Quotes = .none;

    for (body) |byte| {
        if (quotes.inside()) {
            quotes.step(byte);

            continue;
        }

        switch (byte) {
            '(', '[', '{' => depth += 1,
            ')', ']', '}' => depth -= 1,
            ',' => {
                if (depth == 0) found += 1;
            },
            else => quotes.opens(byte),
        }
    }

    assert(found <= body.len);
    assert(@abs(depth) <= body.len);

    return found;
}

fn struct_tagged(line: []const u8) bool {
    assert(line.len <= std.math.maxInt(u32));

    const cut = cut_of(line, .type) orelse return false;

    assert(cut.head <= cut.tail);
    assert(cut.tail < line.len);

    return line[cut.tail] == '`';
}

fn spec_of(line: []const u8) Spec {
    assert(line.len <= std.math.maxInt(u32));

    const indent: usize = indent_of(line);
    const cut = cut_of(line, .field) orelse return .bare;
    const at: usize = cut.tail;

    assert(indent < at);
    assert(at < line.len);

    if (commented(line[at..])) return .blank;
    if (assigns_at(line, at, indent)) return .valued;
    return .typed;
}

fn line_commented(line: []const u8) bool {
    assert(line.len <= std.math.maxInt(u32));

    const body = body_of(line);

    assert(body.len <= line.len);

    return body.len != line.len;
}

fn coded(line: []const u8) u32 {
    assert(line.len <= std.math.maxInt(u32));

    const code = trim_end(body_of(line));

    assert(code.len <= line.len);

    return @intCast(code.len);
}

fn continues_a_list(bytes: []const u8, start: u32) bool {
    assert(start <= bytes.len);

    const before = line_before(bytes, line_at(bytes, start).from) orelse return false;
    const range = line_at(bytes, before.from);

    assert(range.from == before.from);
    assert(range.to <= start);

    return std.mem.endsWith(u8, trim_end(body_of(bytes[range.from..range.to])), ",");
}

fn labelled(body: []const u8) bool {
    if (body.len <= 1) return false;

    for (body[0 .. body.len - 1]) |byte| {
        const named = std.ascii.isAlphanumeric(byte) or byte == '_';
        if (!named) return false;
    }

    return true;
}

fn attributed(header: []const u8) bool {
    assert(header.len <= std.math.maxInt(u32));

    const held = trim_start(header);
    const opens = std.mem.startsWith(u8, held, "#[") or std.mem.startsWith(u8, held, "#![");

    assert(held.len <= header.len);

    if (!opens) return false;
    return std.mem.find(u8, held, "derive(") == null;
}

fn declares(line: []const u8) bool {
    assert(line.len <= std.math.maxInt(u32));

    const declared = std.mem.eql(u8, line, "type (") or specifies(line);

    if (declared) assert(std.mem.endsWith(u8, line, " ("));

    return declared;
}

fn specifies(line: []const u8) bool {
    assert(line.len <= std.math.maxInt(u32));

    const specified = std.mem.eql(u8, line, "const (") or std.mem.eql(u8, line, "var (");

    if (specified) assert(std.mem.endsWith(u8, line, " ("));

    return specified;
}

fn cut_of(line: []const u8, target: Target) ?Cut {
    assert(line.len <= std.math.maxInt(u32));
    if (target == .row) assert(target.row < std.math.maxInt(u32));

    var read = reading(line, target);

    if (target == .type) read.fielded = cut_of_scan(line, .field, &reading(line, .field));

    const cut = cut_of_scan(line, target, &read);

    if (cut) |found| assert(found.head <= found.tail);
    if (cut) |found| assert(found.tail < line.len);

    return cut;
}

fn cut_of_scan(line: []const u8, target: Target, read: *const Reading) ?Cut {
    assert(read.body.len <= line.len);

    const indent: usize = indent_of(line);

    assert(indent <= line.len);

    if (!admits(line, target, indent, read)) return null;

    var block = false;
    var depth: i32 = 0;
    var held = indent;
    var quotes: Quotes = .none;

    while (held < line.len) {
        const byte = line[held];

        if (block) {
            const closes = std.mem.startsWith(u8, line[held..], block_close);

            if (closes) block = false;

            held += if (closes) block_close.len else 1;

            continue;
        }

        if (quotes.inside()) {
            quotes.step(byte);
            held += 1;

            continue;
        }

        switch (cut_of_comment(line, target, held, indent, read)) {
            .block => {
                block = true;
                held += block_open.len;

                continue;
            },
            .proceed => {},
            .refuse => return null,
        }

        const nested = depth != 0 and target != .comment;
        const cuts = !nested and cuts_at(line, target, held, indent, read);
        if (cuts) return cut_before(line, indent, held);

        switch (byte) {
            '(', '[', '{' => depth += 1,
            ')', ']', '}' => depth -= 1,
            else => {},
        }

        if (!lifetime_at(line, held, target)) quotes.opens(byte);

        held += 1;
    }

    assert(held == line.len);

    return null;
}

fn cut_of_comment(
    line: []const u8,
    target: Target,
    held: usize,
    indent: usize,
    read: *const Reading,
) Comment {
    assert(indent <= held);
    assert(held < line.len);
    if (target == .row) assert(target.row < std.math.maxInt(u32));

    const rest = line[held..];

    if (std.mem.startsWith(u8, rest, block_open)) {
        if (!comments(target)) return .refuse;
        if (held == indent) return .refuse;

        const closed = std.mem.endsWith(u8, trim_end(rest), block_close);
        return if (closed) .proceed else .block;
    }

    if (!std.mem.startsWith(u8, rest, comment)) return .proceed;
    if (held == indent) return .refuse;

    switch (target) {
        .comment, .element, .field, .type => {},
        .assign, .body, .key, .row, .tag, .value => return .refuse,
    }

    if (!cuts_at(line, target, held, indent, read)) return .refuse;
    return .proceed;
}

fn reading(line: []const u8, target: Target) Reading {
    assert(line.len <= std.math.maxInt(u32));
    if (target == .row) assert(target.row < std.math.maxInt(u32));

    const body = trim_end(body_of(line));
    const closes = target == .key and closing(line);

    assert(body.len <= line.len);

    if (closes) assert(body.len > 0);

    return .{ .body = body, .closes = closes, .fielded = null };
}

fn closing(line: []const u8) bool {
    assert(line.len <= std.math.maxInt(u32));

    const body = trim_end(body_of(line));

    assert(body.len <= line.len);

    if (body.len == 0) return false;

    return switch (body[body.len - 1]) {
        ')', ']', '}' => depth_of(line) < 0,
        else => false,
    };
}

fn depth_of(line: []const u8) i32 {
    assert(line.len <= std.math.maxInt(u32));

    var block = false;
    var depth: i32 = 0;
    var held: usize = 0;
    var quotes: Quotes = .none;

    while (held < line.len) {
        const byte = line[held];
        const rest = line[held..];

        if (block) {
            const closes = std.mem.startsWith(u8, rest, block_close);

            if (closes) block = false;

            held += if (closes) block_close.len else 1;

            continue;
        }

        if (quotes.inside()) {
            quotes.step(byte);
            held += 1;

            continue;
        }

        if (std.mem.startsWith(u8, rest, comment)) break;

        if (std.mem.startsWith(u8, rest, block_open)) {
            block = true;
            held += block_open.len;

            continue;
        }

        switch (byte) {
            '(', '[', '{' => depth += 1,
            ')', ']', '}' => depth -= 1,
            else => {},
        }

        quotes.opens(byte);
        held += 1;
    }

    assert(held <= line.len);
    assert(@abs(depth) <= held);

    return depth;
}

fn admits(line: []const u8, target: Target, indent: usize, read: *const Reading) bool {
    assert(indent <= line.len);
    assert(read.body.len <= line.len);
    if (target == .row) assert(target.row < std.math.maxInt(u32));

    const listed = std.mem.endsWith(u8, read.body, ",");

    return switch (target) {
        .assign, .value => std.mem.findScalar(u8, line, '=') != null,
        .body => std.mem.startsWith(u8, line[indent..], "func ") and
            std.mem.endsWith(u8, read.body, "}"),
        .comment, .element => std.mem.findScalar(u8, line, '/') != null,
        .field => indent < line.len and fields_lead(line[indent]),
        .key => (listed or read.closes) and std.mem.findScalar(u8, line, ':') != null,
        .row => |column| listed and !arrowed(line, indent) and
            separators(line, indent, line.len) > column,
        .tag => std.mem.endsWith(u8, read.body, "`") or std.mem.endsWith(u8, read.body, "\""),
        .type => read.fielded != null and !worded(line, indent) and
            std.mem.findAny(u8, line, "`\"/") != null,
    };
}

fn cuts_at(
    line: []const u8,
    target: Target,
    held: usize,
    indent: usize,
    read: *const Reading,
) bool {
    assert(indent <= held);
    assert(held < line.len);
    if (target == .row) assert(target.row < std.math.maxInt(u32));

    return switch (target) {
        .assign => assigns_at(line, held, indent),
        .body => bodies_at(line, held, indent, read.body),
        .comment => commented(line[held..]) and held > indent and !operates(line, held, indent),
        .element => elements_at(line, held, indent),
        .field => fields_at(line, held, indent),
        .key => keys_at(line, held, indent, read),
        .row => |column| rows_at(line, held, indent, column, read.body),
        .tag => tags_at(line, held, indent, read.body),
        .type => types_at(line, held, indent, read.fielded),
        .value => assigns_at(line, held, indent),
    };
}

fn assigns_at(line: []const u8, held: usize, indent: usize) bool {
    assert(indent <= line.len);
    assert(held < line.len);

    if (line[held] != '=') return false;
    if (held <= indent) return false;
    if (line[held - 1] != ' ') return false;
    if (byte_is(line, held + 1, '=')) return false;
    if (held < 2) return true;

    return switch (line[held - 2]) {
        '!', ':', '<', '=', '>' => false,
        else => true,
    };
}

fn bodies_at(line: []const u8, held: usize, indent: usize, body: []const u8) bool {
    assert(indent <= held);
    assert(held < line.len);

    if (held <= indent) return false;
    if (line[held] != '{') return false;
    if (line[held - 1] != ' ') return false;
    if (!std.mem.startsWith(u8, line[indent..], "func ")) return false;
    assert(body.len <= std.math.maxInt(u32));

    return std.mem.endsWith(u8, body, "}");
}

fn operates(line: []const u8, held: usize, indent: usize) bool {
    assert(indent <= held);
    assert(held <= line.len);

    const code = trim_end(line[indent..held]);
    if (std.mem.endsWith(u8, code, "++")) return false;
    if (std.mem.endsWith(u8, code, "--")) return false;
    if (code.len == 0) return false;

    return switch (code[code.len - 1]) {
        '!', '%', '&', '*', '+', '-', '/', '<', '=', '>', '^', '|' => true,
        else => false,
    };
}

fn elements_at(line: []const u8, held: usize, indent: usize) bool {
    assert(indent <= held);
    assert(held < line.len);

    if (held <= indent) return false;
    if (!commented(line[held..])) return false;
    if (line[indent] == '$') return false;

    const code = trim_end(line[indent..held]);

    return std.mem.endsWith(u8, code, ",") or
        (element_bodies and std.mem.endsWith(u8, code, "}"));
}

fn fields_at(line: []const u8, held: usize, indent: usize) bool {
    assert(indent <= held);
    assert(held < line.len);

    if (held <= indent) return false;
    if (line[held] == ' ') return false;
    if (line[held - 1] != ' ') return false;

    const start = blank_start(line, indent, held);
    if (start == indent) return false;
    if (!fields_lead(line[indent])) return false;
    if (line[start - 1] == ',') return false;

    for (line[indent..start]) |byte| {
        const named = std.ascii.isAlphanumeric(byte) or byte >= 0x80;

        const marked = switch (byte) {
            '*', ',', '.', ' ', '_' => true,
            else => false,
        };

        const plain = named or marked;
        if (!plain) return false;
    }

    return true;
}

fn fields_lead(byte: u8) bool {
    if (byte < '*') return false;

    const marked = byte == '*' or byte == '_';
    const leads = lettered(byte) or marked;

    if (leads) assert(byte != ' ');

    return leads;
}

fn keys_at(line: []const u8, held: usize, indent: usize, read: *const Reading) bool {
    assert(indent <= held);
    assert(held < line.len);

    if (held <= indent) return false;
    if (line[held] == ' ') return false;

    const listed = std.mem.endsWith(u8, read.body, ",") or read.closes;
    if (!listed) return false;

    const start = blank_start(line, indent, held);
    if (start == held) return false;
    if (start <= indent + 1) return false;
    if (line[start - 1] != ':') return false;
    return line[start - 2] != ':' and !byte_is(line, start, '=');
}

fn rows_at(line: []const u8, held: usize, indent: usize, column: u32, body: []const u8) bool {
    assert(indent <= held);
    assert(held < line.len);

    if (held <= indent) return false;
    if (line[held] == ' ') return false;
    if (!std.mem.endsWith(u8, body, ",")) return false;
    if (commented(line[held..])) return false;
    if (arrowed(line, indent)) return false;
    assert(column < std.math.maxInt(u32));

    const start = blank_start(line, indent, held);
    if (start == held) return false;
    if (start <= indent) return false;
    if (line[start - 1] != ',') return false;
    return separators(line, indent, start) == column + 1;
}

fn tags_at(line: []const u8, held: usize, indent: usize, body: []const u8) bool {
    assert(indent <= held);
    assert(held < line.len);

    if (held <= indent) return false;
    if (line[held - 1] != ' ') return false;
    assert(body.len <= line.len);

    const quote = line[held];
    const quoted = quote == '`' or quote == '"';
    if (!quoted) return false;
    return body.len > held + 1 and body[body.len - 1] == quote;
}

fn types_at(line: []const u8, held: usize, indent: usize, fielded: ?Cut) bool {
    assert(indent <= held);
    assert(held < line.len);

    if (held <= indent) return false;
    if (line[held] == ' ') return false;
    if (line[held - 1] != ' ') return false;
    if (fielded) |unwrapped| assert(unwrapped.head <= unwrapped.tail);

    const quoted = line[held] == '`' or line[held] == '"';
    const trailing = quoted or commented(line[held..]);
    if (!trailing) return false;
    if (worded(line, indent)) return false;
    if (!celled(line, indent, held, true)) return false;

    const cut = fielded orelse return false;
    return cut.tail < held and celled(line, cut.tail, held, false);
}

fn celled(line: []const u8, from: usize, held: usize, whole: bool) bool {
    assert(from <= held);
    assert(held <= line.len);

    const cell = trim_end(line[from..held]);

    if (!whole) {
        if (cell.len == 0) return false;
        if (!celled_leads(cell[0])) return false;
    }

    var depth: i32 = 0;
    var quotes: Quotes = .none;

    for (cell) |byte| {
        if (quotes.inside()) {
            quotes.step(byte);

            continue;
        }

        quotes.step(byte);

        const assigns = byte == '=' or byte == ':' or byte == ';';
        const stops = whole and assigns;
        if (stops) return false;

        switch (byte) {
            '(', '[', '{' => depth += 1,
            ')', ']', '}' => depth -= 1,
            ' ' => {
                const splits = depth == 0 and !whole;
                if (splits) return false;
            },
            else => {},
        }
    }

    return true;
}

fn celled_leads(byte: u8) bool {
    if (byte < '*') return false;

    const named = std.ascii.isAlphanumeric(byte) or byte >= 0x80;

    const marked = switch (byte) {
        '*', '<', '[', '_' => true,
        else => false,
    };

    if (named) assert(byte != ' ');

    return named or marked;
}

fn worded(line: []const u8, indent: usize) bool {
    assert(line.len <= std.math.maxInt(u32));
    assert(indent < std.math.maxInt(u32));

    const words = [_][]const u8{
        "break",
        "case",
        "chan",
        "const",
        "continue",
        "default",
        "defer",
        "else",
        "fallthrough",
        "for",
        "func",
        "go",
        "goto",
        "if",
        "import",
        "interface",
        "map",
        "package",
        "range",
        "return",
        "select",
        "struct",
        "switch",
        "type",
        "var",
    };

    const rest = line[@min(indent, line.len)..];
    var length: usize = 0;

    while (length < rest.len) : (length += 1) {
        const byte = rest[length];
        const named = std.ascii.isAlphanumeric(byte) or byte == '_';
        if (!named) break;
    }

    assert(length <= rest.len);

    for (words) |word| {
        if (std.mem.eql(u8, word, rest[0..length])) return true;
    }

    return false;
}

fn lettered(byte: u8) bool {
    if (byte < 'A') return false;

    const letter = std.ascii.isAlphabetic(byte) or byte >= 0x80;

    if (letter) assert(!std.ascii.isDigit(byte));

    return letter;
}

fn arrowed(line: []const u8, indent: usize) bool {
    assert(indent <= line.len);

    var depth: i32 = 0;
    var held = indent;
    var quotes: Quotes = .none;

    while (held + 1 < line.len) : (held += 1) {
        const byte = line[held];

        if (quotes.inside()) {
            quotes.step(byte);

            continue;
        }

        switch (byte) {
            '(', '[', '{' => depth += 1,
            ')', ']', '}' => depth -= 1,
            '=' => {
                const arrow = depth == 0 and line[held + 1] == '>';
                if (arrow) return true;
            },
            else => quotes.opens(byte),
        }
    }

    assert(@abs(depth) <= line.len);

    return false;
}

fn separators(line: []const u8, indent: usize, stop: usize) u32 {
    assert(indent <= stop);
    assert(stop <= line.len);

    var depth: i32 = 0;
    var found: u32 = 0;
    var quotes: Quotes = .none;

    for (line[indent..stop]) |byte| {
        if (quotes.inside()) {
            quotes.step(byte);

            continue;
        }

        switch (byte) {
            '(', '[', '{' => depth += 1,
            ')', ']', '}' => depth -= 1,
            ',' => {
                if (depth == 0) found += 1;
            },
            else => quotes.opens(byte),
        }
    }

    assert(found <= stop - indent);

    return found;
}

fn lifetime_at(line: []const u8, held: usize, target: Target) bool {
    assert(held < line.len);

    if (!element_lifetimes) return false;
    if (target != .element) return false;
    if (line[held] != '\'') return false;

    const after = held + 1;
    const named = after < line.len and (std.ascii.isAlphabetic(line[after]) or line[after] == '_');

    if (named) assert(line[after] != '\'');

    return named and !byte_is(line, held + 2, '\'');
}

fn cut_before(line: []const u8, indent: usize, held: usize) ?Cut {
    assert(indent <= held);
    assert(held < line.len);

    const start = blank_start(line, indent, held);
    if (start == indent) return null;
    return .{ .head = @intCast(start), .tail = @intCast(held) };
}

fn blank_start(line: []const u8, indent: usize, held: usize) usize {
    assert(indent <= held);
    assert(held <= line.len);

    var start = held;

    while (start > indent) {
        if (line[start - 1] != ' ') break;

        start -= 1;
    }

    assert(start >= indent);

    return start;
}

fn group_of(bytes: []const u8, start: u32) ?[]const u8 {
    assert(start <= bytes.len);

    if (start == 0) return null;

    const range = line_at(bytes, start);
    const indent = indent_of(bytes[range.from..range.to]);
    var end = start;

    while (line_before(bytes, end)) |before| {
        assert(before.from < end);

        const held = bytes[before.from..before.to];
        const text = scan.trim_ascii(held);
        const header = text.len > 0 and indent_of(held) < indent;
        if (header) return trim_end(body_of(text));

        end = before.from;
    }

    return null;
}

fn body_of(line: []const u8) []const u8 {
    assert(line.len <= std.math.maxInt(u32));

    var held: usize = 0;
    var quotes: Quotes = .none;

    while (held < line.len) : (held += 1) {
        const opens = !quotes.inside() and std.mem.startsWith(u8, line[held..], comment);
        if (opens) break;

        quotes.step(line[held]);
    }

    assert(held <= line.len);

    if (held < line.len) assert(line[held] == '/');

    return line[0..held];
}

fn indent_of(line: []const u8) u32 {
    assert(line.len <= std.math.maxInt(u32));

    const indent = std.mem.findNone(u8, line, " \t") orelse line.len;

    assert(indent <= line.len);

    if (indent < line.len) assert(line[indent] != ' ');

    return @intCast(indent);
}

fn columns_of(line: []const u8, width: u32) u32 {
    assert(line.len <= std.math.maxInt(u32));
    assert(width < std.math.maxInt(u32));

    const stop = @min(width, line.len);
    var found: u32 = 0;

    for (line[0..stop]) |byte| {
        if (byte & 0xC0 != 0x80) found += 1;
    }

    assert(found <= stop);
    assert(found <= width);

    return found;
}

fn line_at(bytes: []const u8, offset: u32) Range {
    assert(offset <= bytes.len);

    const end = std.mem.findScalarPos(u8, bytes, offset, '\n') orelse bytes.len;

    assert(end >= offset);

    return .{ .from = offset, .to = @intCast(end) };
}

fn line_before(bytes: []const u8, from: u32) ?Range {
    assert(from <= bytes.len);

    if (from == 0) return null;

    const end = from - 1;
    var held = end;

    while (held > 0) {
        if (bytes[held - 1] == '\n') break;

        held -= 1;
    }

    assert(held <= end);

    return .{ .from = held, .to = end };
}

fn padded(out: *Buffer, width: u32) error{Overflow}!void {
    assert(width < std.math.maxInt(u32));

    const count = out.count();

    for (0..width) |_| try out.push(" ");

    assert(out.count() == count + width);
}

fn comments(target: Target) bool {
    if (target == .assign) return false;

    return switch (target) {
        .body, .comment, .element, .field, .type => true,
        .assign, .key, .row, .tag, .value => false,
    };
}

fn commented(text: []const u8) bool {
    assert(text.len <= std.math.maxInt(u32));

    const opens = std.mem.startsWith(u8, text, comment) or
        std.mem.startsWith(u8, text, block_open);

    if (opens) assert(text[0] == '/');

    return opens;
}

fn byte_is(line: []const u8, offset: usize, byte: u8) bool {
    assert(line.len <= std.math.maxInt(u32));
    assert(offset <= std.math.maxInt(u32));

    if (offset < line.len) return line[offset] == byte;
    return false;
}

fn trim_end(text: []const u8) []const u8 {
    assert(text.len <= std.math.maxInt(u32));

    const trimmed = std.mem.trimEnd(u8, text, scan.ascii_whitespace);

    assert(trimmed.len <= text.len);

    if (trimmed.len > 0) assert(!scan.is_ascii_whitespace(trimmed[trimmed.len - 1]));

    return trimmed;
}

fn trim_start(text: []const u8) []const u8 {
    assert(text.len <= std.math.maxInt(u32));

    const trimmed = std.mem.trimStart(u8, text, scan.ascii_whitespace);

    assert(trimmed.len <= text.len);

    if (trimmed.len > 0) assert(!scan.is_ascii_whitespace(trimmed[0]));

    return trimmed;
}

test "crosses carries block comments raw strings and quotes" {
    const Case = struct {
        carry: Carry,
        line: []const u8,
        expected: Carry,
    };

    const cases = [_]Case{
        .{ .carry = .none, .line = "plain", .expected = .none },
        .{ .carry = .none, .line = "a /* b", .expected = .block },
        .{ .carry = .none, .line = "x */ y", .expected = .none },
        .{ .carry = .none, .line = "x ` y", .expected = .raw },
        .{ .carry = .none, .line = "\"/*\" z", .expected = .none },
        .{ .carry = .none, .line = "'`' q", .expected = .none },
        .{ .carry = .none, .line = "a // /*", .expected = .none },
        .{ .carry = .block, .line = "plain", .expected = .block },
        .{ .carry = .block, .line = "a /* b", .expected = .block },
        .{ .carry = .block, .line = "x */ y", .expected = .none },
        .{ .carry = .block, .line = "x ` y", .expected = .block },
        .{ .carry = .raw, .line = "plain", .expected = .raw },
        .{ .carry = .raw, .line = "x */ y", .expected = .raw },
        .{ .carry = .raw, .line = "x ` y", .expected = .none },
        .{ .carry = .raw, .line = "'`' q", .expected = .none },
    };

    for (cases) |held| {
        try std.testing.expectEqual(held.expected, crosses(held.line, held.carry));
    }
}

fn expect_aligned(target: Target, line_width: u32, source: []const u8, expected: []const u8) !void {
    assert(line_width < std.math.maxInt(u32));
    assert(source.len <= std.math.maxInt(u32));
    if (target == .row) assert(target.row < std.math.maxInt(u32));

    var out = try Buffer.init(std.testing.allocator, 4096);
    defer out.deinit(std.testing.allocator);

    try @"align"(source, target, line_width, &out);
    try std.testing.expectEqualStrings(expected, out.const_slice());
}

test "a const block aligns trailing comments past the widest value" {
    try expect_aligned(
        .comment,
        100,
        "const (\n\ta = 1 // one\n\tlonger = 2 // two\n)\n",
        "const (\n\ta = 1      // one\n\tlonger = 2 // two\n)\n",
    );

    try expect_aligned(
        .comment,
        100,
        "x = 1 // one\nlonger = 2 // two\ni++ // three\n",
        "x = 1      // one\nlonger = 2 // two\ni++        // three\n",
    );

    try expect_aligned(
        .comment,
        100,
        "x = 1 /* a */ // one\nlonger = 2 // two\n",
        "x = 1 /* a */ // one\nlonger = 2 // two\n",
    );
}

test "labels raw strings struct tags and lists break comment runs" {
    try expect_aligned(
        .comment,
        100,
        "switch x {\ncase 1: // one\n\ty = 1 // a\n\tlonger = 2 // b\n}\n",
        "switch x {\ncase 1: // one\n\ty = 1      // a\n\tlonger = 2 // b\n}\n",
    );

    try expect_aligned(
        .comment,
        100,
        "a := `raw\nmore // not` // one\nlonger = 2 // two\nc = 3 // three\n",
        "a := `raw\nmore // not` // one\nlonger = 2 // two\nc = 3      // three\n",
    );

    try expect_aligned(
        .comment,
        100,
        "type T struct {\n\tA int `json:\"a\"` // one\n\tB string // two\n\tC int // three\n}\n",
        "type T struct {\n\tA int `json:\"a\"` // one\n\tB string // two\n\tC int    // three\n}\n",
    );

    try expect_aligned(
        .comment,
        100,
        "x := []int{\n\t1, // one\n\t22, 33, // two\n\t4444, // three\n}\n",
        "x := []int{\n\t1,      // one\n\t22, 33, // two\n\t4444, // three\n}\n",
    );

    try expect_aligned(
        .comment,
        0,
        "a = f( // one\n\tx)\nlonger = 2 // two\n",
        "a = f( // one\n\tx)\nlonger = 2 // two\n",
    );
}

test "a declaration group aligns its assignments" {
    try expect_aligned(
        .assign,
        100,
        "const (\n\ta = 1\n\tlonger = 2\n)\n",
        "const (\n\ta      = 1\n\tlonger = 2\n)\n",
    );

    try expect_aligned(
        .assign,
        100,
        "var (\n\ta = 1\n\tlonger = 2\n)\n",
        "var (\n\ta      = 1\n\tlonger = 2\n)\n",
    );

    try expect_aligned(
        .assign,
        100,
        "const (\n\ta == 1\n\tlonger = 2\n\tc = 3\n)\n",
        "const (\n\ta == 1\n\tlonger = 2\n\tc      = 3\n)\n",
    );

    try expect_aligned(
        .assign,
        100,
        "const (\n\ta = 1\n\n\tlonger = 2\n)\n",
        "const (\n\ta = 1\n\n\tlonger = 2\n)\n",
    );

    try expect_aligned(.assign, 100, "x = 1\nlonger = 2\n", "x = 1\nlonger = 2\n");
}

test "a var block aligns values only beside a typed spec" {
    try expect_aligned(
        .value,
        100,
        "var (\n\ta int = 1\n\tlonger string = \"x\"\n)\n",
        "var (\n\ta int         = 1\n\tlonger string = \"x\"\n)\n",
    );

    try expect_aligned(
        .value,
        100,
        "var (\n\ta = 1\n\tlonger = 2\n)\n",
        "var (\n\ta = 1\n\tlonger = 2\n)\n",
    );

    try expect_aligned(
        .value,
        100,
        "var (\n\ta int = 1\n\tb = 2\n\tlonger string = \"x\"\n)\n",
        "var (\n\ta int         = 1\n\tb             = 2\n\tlonger string = \"x\"\n)\n",
    );
}

test "struct fields align their types" {
    try expect_aligned(
        .field,
        100,
        "type T struct {\n\ta int\n\tlonger string\n}\n",
        "type T struct {\n\ta      int\n\tlonger string\n}\n",
    );

    try expect_aligned(
        .field,
        100,
        "type T struct {\n\ta, b int\n\tlonger string\n\t*Embedded\n}\n",
        "type T struct {\n\ta, b   int\n\tlonger string\n\t*Embedded\n}\n",
    );

    try expect_aligned(
        .field,
        100,
        "type I interface {\n\tA()\n\tLonger(x int) error\n}\n",
        "type I interface {\n\tA()\n\tLonger(x int) error\n}\n",
    );
}

test "struct tags align and interface tags do not" {
    try expect_aligned(
        .tag,
        100,
        "type T struct {\n\tA int `json:\"a\"`\n\tLonger string `json:\"longer\"`\n}\n",
        "type T struct {\n\tA int         `json:\"a\"`\n\tLonger string `json:\"longer\"`\n}\n",
    );

    try expect_aligned(
        .tag,
        100,
        "type I interface {\n\tA int `json:\"a\"`\n\tLonger string `json:\"longer\"`\n}\n",
        "type I interface {\n\tA int `json:\"a\"`\n\tLonger string `json:\"longer\"`\n}\n",
    );
}

test "the column after a field type aligns" {
    try expect_aligned(
        .type,
        100,
        "type T struct {\n\tA int `json:\"a\"`\n\tB string `json:\"b\"`\n}\n",
        "type T struct {\n\tA int    `json:\"a\"`\n\tB string `json:\"b\"`\n}\n",
    );

    try expect_aligned(
        .type,
        100,
        "type T struct {\n\tA int // one\n\tLonger string // two\n}\n",
        "type T struct {\n\tA int         // one\n\tLonger string // two\n}\n",
    );
}

test "keys align until a nested value or a size break" {
    try expect_aligned(
        .key,
        100,
        "x = {\n    a: 1,\n    longer: 2,\n}\n",
        "x = {\n    a:      1,\n    longer: 2,\n}\n",
    );

    try expect_aligned(
        .key,
        100,
        "x = .{\n    a: 1,\n    bbbb: 2 }\n",
        "x = .{\n    a:    1,\n    bbbb: 2 }\n",
    );

    const key_wide: [50]u8 = @splat('b');
    const sized = "x = {\n    a: 1,\n    " ++ key_wide ++ ": 2,\n    cc: 3,\n}\n";

    try expect_aligned(.key, 100, sized, sized);

    const nested = "x = {\n    a: 1,\n    bb: f(\n        y,\n    ),\n    ccc: 3,\n}\n";

    try expect_aligned(.key, 100, nested, nested);
}

test "rows align one column at a time" {
    const rows = "x = .{\n    1, 22, 333,\n    4444, 5, 6,\n};\n";

    try expect_aligned(
        .{ .row = 0 },
        100,
        rows,
        "x = .{\n    1,    22, 333,\n    4444, 5, 6,\n};\n",
    );

    try expect_aligned(
        .{ .row = 1 },
        100,
        rows,
        "x = .{\n    1, 22,   333,\n    4444, 5, 6,\n};\n",
    );

    const arrowed_rows = "x = .{\n    1 => 22, 333,\n    4444, 5, 6,\n};\n";

    try expect_aligned(.{ .row = 0 }, 100, arrowed_rows, arrowed_rows);

    try expect_aligned(
        .{ .row = 0 },
        100,
        "x = .{\n    1, 22, // c\n    4444, 5, // d\n};\n",
        "x = .{\n    1,    22, // c\n    4444, 5, // d\n};\n",
    );

    try expect_aligned(
        .{ .row = 0 },
        100,
        "x = .{\n    1, 22,\n    // note\n    4444, 5,\n};\n",
        "x = .{\n    1,    22,\n    // note\n    4444, 5,\n};\n",
    );
}

test "elements align trailing comments" {
    try expect_aligned(
        .element,
        100,
        "foo(\n    a, // one\n    bbbbb, // two\n);\n",
        "foo(\n    a,     // one\n    bbbbb, // two\n);\n",
    );

    try expect_aligned(
        .element,
        100,
        "f(\n    'a, // one\n    bbbbb, // two\n);\n",
        "f(\n    'a,    // one\n    bbbbb, // two\n);\n",
    );

    try expect_aligned(
        .element,
        100,
        "x(\n    a, b, // one\n    ccccc, // two\n    d, // three\n);\n",
        "x(\n    a, b, // one\n    ccccc, // two\n    d,     // three\n);\n",
    );

    const attribute = "#[cfg_attr(\n    a, // one\n    bbbbb, // two\n)]\n";
    const blocks = "foo(\n    a, /* one */\n    bbbbb, /* two\n    more */\n    c, // three\n);\n";

    try expect_aligned(.element, 100, attribute, attribute);
    try expect_aligned(.element, 100, blocks, blocks);
}

test "a line width caps element comments" {
    const source = "foo(\n    a, // a long comment here\n    bbbbbbbbbb, // two\n" ++
        "    c, // three\n);\n";

    try expect_aligned(.element, 20, source, source);
    try expect_aligned(.element, 30, source, source);

    try expect_aligned(
        .element,
        100,
        source,
        "foo(\n    a,          // a long comment here\n    bbbbbbbbbb, // two\n" ++
            "    c,          // three\n);\n",
    );
}

test "one-line function bodies align" {
    try expect_aligned(
        .body,
        100,
        "func a() { return 1 }\nfunc longer() { return 2 }\n",
        "func a()      { return 1 }\nfunc longer() { return 2 }\n",
    );

    const spread = "func a() { return 1 }\nfunc longer() {\n\treturn 2\n}\n";

    try expect_aligned(.body, 100, spread, spread);
}

test "padding past the maximum passes lines through" {
    const digits: [1020]u8 = @splat('1');
    const digits_wide: [1021]u8 = @splat('1');
    const padding: [1020]u8 = @splat(' ');
    const fits = "x = " ++ digits ++ " // a\ny = 2 // b\n";
    const fitted = "x = " ++ digits ++ " // a\ny = 2" ++ padding ++ "// b\n";
    const wide = "x = " ++ digits_wide ++ " // a\ny = 2 // b\n";

    try expect_aligned(.comment, 100, fits, fitted);
    try expect_aligned(.comment, 100, wide, wide);
}

test "an outgrown buffer reports overflow" {
    var out = try Buffer.init(std.testing.allocator, 25);
    defer out.deinit(std.testing.allocator);

    const source = "const (\n\ta = 1 // one\n\tlonger = 2 // two\n)\n";

    try std.testing.expectError(error.Overflow, @"align"(source, .comment, 100, &out));
    try std.testing.expectEqualStrings("const (\n\ta = 1      ", out.const_slice());
}
